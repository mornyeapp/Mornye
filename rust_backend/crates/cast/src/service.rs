//! The one object the app talks to, through `call(method, args)` with JSON
//! arguments and results, and two events: `castStatus` (the session snapshot,
//! in the Android plugin's shape) and `castDevices` (`{"devices": [...]}`).
//!
//! | method       | arguments                          | result            |
//! |--------------|------------------------------------|-------------------|
//! | `discover`   | `{"on": bool, "kinds"?: [kind]}`   | null              |
//! | `devices`    |                                    | `[device]`        |
//! | `connect`    | `{"deviceId"}`                     | null              |
//! | `disconnect` |                                    | null              |
//! | `state`      |                                    | snapshot          |
//! | `position`   |                                    | milliseconds      |
//! | `load`       | `{"url","mime","token",...}`       | null              |
//! | `play`, `pause`, `stop` |                         | null              |
//! | `seek`       | `{"position": ms}`                 | null              |
//! | `volume`     | `{"volume": 0..1}`                 | null              |
//! | `serve`      | `{"host"}` (the receiver's address)| null              |
//! | `register`   | `{"source","mime"}`                | `{"url"}`         |
//! | `clearMedia`, `closeMedia` |                      | null              |
//!
//! Kinds are `cast`, `dlna`, `fcast` and `roku`; without `kinds` all are
//! browsed. Android keeps Google's sender for Google Cast and uses this one
//! for the other kinds and the media methods.

use crate::discovery::{Device, Discovery, Kind, Registry};
use crate::media::{MediaServer, local_address_towards};
use crate::sender::Emit;
use crate::session::{self, Control, Item, Session};
use crate::status::Status;
use serde_json::{Value, json};
use std::collections::{BTreeMap, BTreeSet};
use std::future::Future;
use std::net::IpAddr;
use std::sync::{Arc, Mutex};
use std::time::Duration;

pub struct CastService {
    runtime: tokio::runtime::Runtime,
    emit: Emit,
    devices: Arc<Mutex<BTreeMap<String, Device>>>,
    discovery: Mutex<Option<Discovery>>,
    session: Arc<tokio::sync::Mutex<Option<Session>>>,
    status: Arc<Mutex<Status>>,
    media: Arc<Mutex<Option<MediaServer>>>,
}

impl CastService {
    /// `emit` receives `(event, payload)` on a Cast thread.
    pub fn new(emit: impl Fn(&str, Value) + Send + Sync + 'static) -> std::io::Result<Self> {
        let runtime = tokio::runtime::Builder::new_multi_thread()
            .worker_threads(2)
            .thread_name("mornye-cast")
            .enable_all()
            .build()?;
        Ok(Self {
            runtime,
            emit: Arc::new(emit),
            devices: Arc::default(),
            discovery: Mutex::default(),
            session: Arc::default(),
            status: Arc::default(),
            media: Arc::default(),
        })
    }

    /// Runs one method; blocks the calling thread, which must not be a Tokio
    /// worker of this service.
    pub fn call(&self, method: &str, args: &Value) -> Result<Value, String> {
        let text = |key: &str| args[key].as_str().map(str::to_owned);
        match method {
            "discover" => {
                let mut discovery = self.discovery.lock().expect("cast discovery");
                if args["on"].as_bool() == Some(true) {
                    let running = discovery.get_or_insert_with(|| {
                        let emit = Arc::clone(&self.emit);
                        Discovery::new(Registry::new(Arc::clone(&self.devices), move |list| {
                            emit("castDevices", json!({"devices": list}));
                        }))
                    });
                    running.set(&kinds(&args["kinds"]), self.runtime.handle())?;
                } else {
                    *discovery = None;
                    self.devices.lock().expect("cast devices").clear();
                }
                Ok(Value::Null)
            }
            "devices" => Ok(json!(
                self.devices
                    .lock()
                    .expect("cast devices")
                    .values()
                    .collect::<Vec<_>>()
            )),
            "state" => Ok(self.status.lock().expect("cast status").snapshot()),
            "position" => Ok(json!(
                self.status.lock().expect("cast status").position_ms()
            )),
            "connect" => {
                let id = text("deviceId").ok_or("connect needs a deviceId")?;
                let device = self
                    .devices
                    .lock()
                    .expect("cast devices")
                    .get(&id)
                    .cloned()
                    .ok_or_else(|| gone(&id))?;
                let kind = device.kind;
                let (slot, status, emit) = (
                    Arc::clone(&self.session),
                    Arc::clone(&self.status),
                    Arc::clone(&self.emit),
                );
                let result = self.wait(async move {
                    let mut slot = slot.lock().await;
                    if let Some(previous) = slot.take() {
                        let _ = previous.control(Control::Disconnect).await;
                    }
                    *slot = Some(session::connect(device, status, emit).await?);
                    Ok(Value::Null)
                });
                if result.is_ok()
                    && let Some(server) = self.media.lock().expect("cast media").as_ref()
                {
                    server.set_dlna(kind == Kind::Dlna);
                }
                result
            }
            "disconnect" => {
                let slot = Arc::clone(&self.session);
                self.wait(async move {
                    if let Some(session) = slot.lock().await.take() {
                        let _ = session.control(Control::Disconnect).await;
                    }
                    Ok(Value::Null)
                })
            }
            "load" => {
                let item = Item::from_request(args)?;
                self.control(Control::Load(Box::new(item)))
            }
            "play" => self.control(Control::Play),
            "pause" => self.control(Control::Pause),
            "stop" => self.control(Control::Stop),
            "seek" => {
                let seconds = args["position"].as_f64().unwrap_or_default() / 1000.0;
                self.control(Control::Seek(seconds))
            }
            "volume" => {
                let level = args["volume"].as_f64().unwrap_or_default();
                self.control(Control::Volume(level.clamp(0.0, 1.0)))
            }
            "serve" => {
                let host: IpAddr = text("host")
                    .and_then(|host| host.parse().ok())
                    .ok_or("serve needs the TV's address")?;
                let failed =
                    |error: std::io::Error| format!("Could not share audio with the TV: {error}");
                let local = local_address_towards(host).map_err(failed)?;
                // Only a live DLNA session; an ended one says nothing of
                // the receiver the app serves now.
                let dlna = {
                    let status = self.status.lock().expect("cast status");
                    status.connected
                        && status.device.as_ref().map(|device| device.kind) == Some(Kind::Dlna)
                };
                // This device's address changes with its network; a server
                // kept on the old one would answer nobody.
                let bound = self.media.lock().expect("cast media");
                if let Some(server) = bound
                    .as_ref()
                    .filter(|server| server.address().ip() == local)
                {
                    server.set_dlna(dlna);
                    return Ok(Value::Null);
                }
                drop(bound);
                let media = Arc::clone(&self.media);
                self.wait(async move {
                    let server = MediaServer::bind(local).await.map_err(failed)?;
                    server.set_dlna(dlna);
                    *media.lock().expect("cast media") = Some(server);
                    Ok(Value::Null)
                })
            }
            "register" => {
                let source = text("source").ok_or("register needs a source")?;
                let mime = text("mime").ok_or("register needs a mime type")?;
                let media = self.media.lock().expect("cast media");
                let server = media.as_ref().ok_or("No Cast media server")?;
                let url = server
                    .register(&source, &mime)
                    .map_err(|error| error.to_string())?;
                Ok(json!({"url": url}))
            }
            "clearMedia" => {
                if let Some(server) = self.media.lock().expect("cast media").as_ref() {
                    server.clear();
                }
                Ok(Value::Null)
            }
            "closeMedia" => {
                self.media.lock().expect("cast media").take();
                Ok(Value::Null)
            }
            _ => Err(format!("Unknown Cast method {method}")),
        }
    }

    /// The kind of the session's receiver, also after it disconnected.
    fn kind(&self) -> Option<Kind> {
        let status = self.status.lock().expect("cast status");
        status.device.as_ref().map(|device| device.kind)
    }

    fn control(&self, control: Control) -> Result<Value, String> {
        let slot = Arc::clone(&self.session);
        let disconnected = match self.kind() {
            None | Some(Kind::Cast) => "TV is disconnected",
            Some(_) => "Device is disconnected",
        };
        self.wait(async move {
            let guard = slot.lock().await;
            let session = guard
                .as_ref()
                .filter(|session| !session.is_closed())
                .ok_or(disconnected)?
                .clone();
            drop(guard);
            session.control(control).await.map(|()| Value::Null)
        })
    }

    fn wait(
        &self,
        work: impl Future<Output = Result<Value, String>> + Send + 'static,
    ) -> Result<Value, String> {
        let (reply, answer) = std::sync::mpsc::channel();
        self.runtime.spawn(async move {
            let _ = reply.send(work.await);
        });
        answer
            .recv_timeout(Duration::from_secs(40))
            .map_err(|_| "Cast did not answer".to_owned())?
    }
}

/// The kinds `discover` browses: the listed ones, or all when absent.
fn kinds(listed: &Value) -> BTreeSet<Kind> {
    match listed.as_array() {
        Some(names) => names
            .iter()
            .filter_map(Value::as_str)
            .filter_map(Kind::parse)
            .collect(),
        None => Kind::ALL.into_iter().collect(),
    }
}

fn gone(id: &str) -> String {
    let cast = Kind::ALL
        .into_iter()
        .filter(|kind| *kind != Kind::Cast)
        .all(|kind| !id.starts_with(&format!("{}:", kind.name())));
    if cast {
        "This TV is no longer on the network".into()
    } else {
        "This device is no longer on the network".into()
    }
}

impl Drop for CastService {
    fn drop(&mut self) {
        self.discovery.lock().expect("cast discovery").take();
        let slot = Arc::clone(&self.session);
        let _ = self.wait(async move {
            if let Some(session) = slot.lock().await.take() {
                let _ = session.control(Control::Disconnect).await;
            }
            Ok(Value::Null)
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn discovery_kinds_default_to_all() {
        assert_eq!(kinds(&Value::Null).len(), 4);
        let listed = kinds(&json!(["dlna", "fcast", "roku", "other"]));
        assert_eq!(
            listed.into_iter().collect::<Vec<_>>(),
            [Kind::Dlna, Kind::Fcast, Kind::Roku]
        );
        assert!(kinds(&json!([])).is_empty());
    }

    #[test]
    fn kinds_not_built_or_not_known_are_ignored_without_error() {
        let service = CastService::new(|_, _| {}).unwrap();
        let only = json!({"on": true, "kinds": ["roku", "airplay"]});
        assert_eq!(service.call("discover", &only), Ok(Value::Null));
        assert_eq!(service.call("devices", &Value::Null), Ok(json!([])));
        let off = json!({"on": false});
        assert_eq!(service.call("discover", &off), Ok(Value::Null));
    }

    #[test]
    fn a_missing_device_is_worded_for_its_kind() {
        assert_eq!(gone("abc123"), "This TV is no longer on the network");
        assert_eq!(
            gone("dlna:uuid:1"),
            "This device is no longer on the network"
        );
    }
}
