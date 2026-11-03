//! The one object the app talks to, through `call(method, args)` with JSON
//! arguments and results, and two events: `castStatus` (the session snapshot,
//! in the Android plugin's shape) and `castDevices` (`{"devices": [...]}`).
//!
//! | method       | arguments                          | result            |
//! |--------------|------------------------------------|-------------------|
//! | `discover`   | `{"on": bool}`                     | null              |
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
//! Android keeps Google's sender and uses only the media methods.

use crate::discovery::{Device, Discovery};
use crate::media::MediaServer;
use crate::sender::{self, Emit, Sender, Status};
use serde_json::{Value, json};
use std::collections::BTreeMap;
use std::future::Future;
use std::net::IpAddr;
use std::sync::{Arc, Mutex};
use std::time::Duration;

pub struct CastService {
    runtime: tokio::runtime::Runtime,
    emit: Emit,
    devices: Arc<Mutex<BTreeMap<String, Device>>>,
    discovery: Mutex<Option<Discovery>>,
    sender: Arc<tokio::sync::Mutex<Option<Sender>>>,
    status: Arc<Mutex<Status>>,
    media: Arc<Mutex<Option<(IpAddr, MediaServer)>>>,
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
            sender: Arc::default(),
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
                    if discovery.is_none() {
                        let emit = Arc::clone(&self.emit);
                        *discovery =
                            Some(Discovery::start(Arc::clone(&self.devices), move |list| {
                                emit("castDevices", json!({"devices": list}));
                            })?);
                    }
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
                    .ok_or("This TV is no longer on the network")?;
                let (slot, status, emit) = (
                    Arc::clone(&self.sender),
                    Arc::clone(&self.status),
                    Arc::clone(&self.emit),
                );
                self.wait(async move {
                    let mut slot = slot.lock().await;
                    if let Some(previous) = slot.take() {
                        let _ = previous.disconnect().await;
                    }
                    *slot = Some(sender::connect(device, status, emit).await?);
                    Ok(Value::Null)
                })
            }
            "disconnect" => {
                let slot = Arc::clone(&self.sender);
                self.wait(async move {
                    if let Some(sender) = slot.lock().await.take() {
                        let _ = sender.disconnect().await;
                    }
                    Ok(Value::Null)
                })
            }
            "load" => {
                let request = args.clone();
                self.with_sender(move |sender| async move { sender.load(&request).await })
            }
            "play" | "pause" | "stop" => {
                let kind = match method {
                    "play" => "PLAY",
                    "pause" => "PAUSE",
                    _ => "STOP",
                };
                self.with_sender(move |sender| async move { sender.media(kind, json!({})).await })
            }
            "seek" => {
                let seconds = args["position"].as_f64().unwrap_or_default() / 1000.0;
                self.with_sender(move |sender| async move {
                    sender.media("SEEK", json!({"currentTime": seconds})).await
                })
            }
            "volume" => {
                let level = args["volume"].as_f64().unwrap_or_default();
                self.with_sender(move |sender| async move { sender.volume(level).await })
            }
            "serve" => {
                let host: IpAddr = text("host")
                    .and_then(|host| host.parse().ok())
                    .ok_or("serve needs the TV's address")?;
                let bound = self.media.lock().expect("cast media");
                if bound.as_ref().is_some_and(|(address, _)| *address == host) {
                    return Ok(Value::Null);
                }
                drop(bound);
                let media = Arc::clone(&self.media);
                self.wait(async move {
                    let server = MediaServer::for_receiver(host)
                        .await
                        .map_err(|error| format!("Could not share audio with the TV: {error}"))?;
                    *media.lock().expect("cast media") = Some((host, server));
                    Ok(Value::Null)
                })
            }
            "register" => {
                let source = text("source").ok_or("register needs a source")?;
                let mime = text("mime").ok_or("register needs a mime type")?;
                let media = self.media.lock().expect("cast media");
                let (_, server) = media.as_ref().ok_or("No Cast media server")?;
                let url = server
                    .register(&source, &mime)
                    .map_err(|error| error.to_string())?;
                Ok(json!({"url": url}))
            }
            "clearMedia" => {
                if let Some((_, server)) = self.media.lock().expect("cast media").as_ref() {
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

    fn with_sender<F, Fut>(&self, run: F) -> Result<Value, String>
    where
        F: FnOnce(Sender) -> Fut + Send + 'static,
        Fut: Future<Output = Result<(), String>> + Send,
    {
        let slot = Arc::clone(&self.sender);
        self.wait(async move {
            let guard = slot.lock().await;
            let sender = guard
                .as_ref()
                .filter(|sender| !sender.is_closed())
                .ok_or("TV is disconnected")?
                .clone();
            drop(guard);
            run(sender).await.map(|()| Value::Null)
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

impl Drop for CastService {
    fn drop(&mut self) {
        self.discovery.lock().expect("cast discovery").take();
        let slot = Arc::clone(&self.sender);
        let _ = self.wait(async move {
            if let Some(sender) = slot.lock().await.take() {
                let _ = sender.disconnect().await;
            }
            Ok(Value::Null)
        });
    }
}
