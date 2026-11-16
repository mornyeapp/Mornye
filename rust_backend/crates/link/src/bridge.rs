//! The app glue around [`LinkServer`] that the desktop and phone backends
//! share (`LINK_CONTRACT.md` section 6): the `link*` methods, and a [`Host`]
//! that turns each request the server forwards into the event `linkRequest`
//! and waits for the app's `linkReply`. The server's other events
//! (`linkMessage`, `linkClients`, `linkPaired`, `linkPairingEnded`) go to the
//! same [`Emitter`] unchanged.
//!
//! Call every method from a plain thread, not from inside an async task:
//! starting and stopping the server builds and shuts down its own runtime.

use crate::{Host, HostError, LinkConfig, LinkServer, Tuning};
use futures_util::future::BoxFuture;
use serde_json::{Value, json};
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use tokio::sync::oneshot;

/// The most files one `linkEmbeddedPictures` call reads.
pub const MAX_PICTURE_PROBES: usize = 1000;

/// Delivers an event to the app: the method name and its arguments.
pub type Emitter = Arc<dyn Fn(&str, Value) + Send + Sync>;
type Waiting = Arc<Mutex<HashMap<String, oneshot::Sender<Result<Value, HostError>>>>>;

/// Where the app keeps its files; the server state lives in
/// `<app_support_dir>/link`.
#[derive(Debug, Clone, Default)]
pub struct BridgePaths {
    pub app_support_dir: PathBuf,
    pub temp_dir: PathBuf,
    pub ffmpeg_path: Option<PathBuf>,
    pub app_version: String,
}

/// Why a method failed: bad arguments, or the server could not do it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum BridgeError {
    Invalid(String),
    Failure(String),
}

impl BridgeError {
    pub fn message(&self) -> &str {
        match self {
            Self::Invalid(message) | Self::Failure(message) => message,
        }
    }
}

type BridgeResult = Result<Value, BridgeError>;

/// A started server's summary and why mDNS advertising is off, if it is.
pub struct Started {
    pub summary: Value,
    pub discovery_error: Option<String>,
}

/// The app side of the server: events out, `linkReply` back.
struct AppHost {
    emit: Emitter,
    waiting: Waiting,
    next_id: AtomicU64,
}

impl Host for AppHost {
    fn request(
        &self,
        op: &str,
        device_id: &str,
        args: Value,
    ) -> BoxFuture<'static, Result<Value, HostError>> {
        let request_id = (self.next_id.fetch_add(1, Ordering::Relaxed) + 1).to_string();
        let (sender, receiver) = oneshot::channel();
        self.waiting
            .lock()
            .expect("link requests")
            .insert(request_id.clone(), sender);
        // The server drops the future on its timeout; forget the request then.
        let forget = Forget {
            waiting: Arc::clone(&self.waiting),
            request_id: request_id.clone(),
        };
        (self.emit)(
            "linkRequest",
            json!({"requestId": request_id, "op": op, "deviceId": device_id, "args": args}),
        );
        Box::pin(async move {
            let _forget = forget;
            receiver
                .await
                .unwrap_or_else(|_| Err(HostError::new("unavailable", "The app did not answer")))
        })
    }

    fn event(&self, method: &str, args: Value) {
        (self.emit)(method, args);
    }
}

struct Forget {
    waiting: Waiting,
    request_id: String,
}

impl Drop for Forget {
    fn drop(&mut self) {
        self.waiting
            .lock()
            .expect("link requests")
            .remove(&self.request_id);
    }
}

/// One app's Link server, started and stopped by the `link*` methods.
pub struct AppBridge {
    host: Arc<AppHost>,
    /// Shared so a slow call (catalog loading) does not hold the lock; the
    /// server stops when the last holder lets go.
    server: Mutex<Option<Arc<LinkServer>>>,
}

impl AppBridge {
    pub fn new(emit: Emitter) -> Self {
        Self {
            host: Arc::new(AppHost {
                emit,
                waiting: Arc::default(),
                next_id: AtomicU64::new(0),
            }),
            server: Mutex::new(None),
        }
    }

    /// Runs the `link*` method `method` and answers its JSON reply.
    pub fn call(&self, paths: &BridgePaths, method: &str, args: &Value) -> BridgeResult {
        match method {
            "linkStart" => self.start(paths, args).map(|started| {
                let mut summary = started.summary;
                if let Some(error) = started.discovery_error {
                    summary["discoveryError"] = Value::from(error);
                }
                summary
            }),
            "linkStop" => {
                self.stop();
                Ok(Value::Null)
            }
            "linkStatus" => Ok(self.status(paths)),
            "linkSetCatalog" => self.set_catalog(args),
            "linkBeginPairing" => self.begin_pairing(),
            "linkEndPairing" => {
                self.end_pairing();
                Ok(Value::Null)
            }
            "linkDevices" => self.devices(paths),
            "linkRevoke" => self.revoke(paths, args),
            "linkCreateKey" => self.create_key(args),
            "linkReply" => self.reply(args),
            "linkSend" => self.send(args),
            "linkEmbeddedPictures" => self.embedded_pictures(args),
            _ => Err(BridgeError::Invalid(format!("Unknown method: {method}"))),
        }
    }

    fn current(&self) -> Option<Arc<LinkServer>> {
        self.server.lock().expect("link server").clone()
    }

    fn running(&self) -> Result<Arc<LinkServer>, BridgeError> {
        self.current()
            .ok_or_else(|| BridgeError::Failure("Mornye Link is not running".to_owned()))
    }

    /// `linkStart {"name", "port"?, "platform"?, "features"?, "advertise"?}`.
    /// Restarts a running server. `advertise: false` leaves mDNS to the app.
    pub fn start(&self, paths: &BridgePaths, args: &Value) -> Result<Started, BridgeError> {
        let port = match number(args, "port") {
            None => 0,
            Some(port) => u16::try_from(port)
                .map_err(|_| BridgeError::Invalid("port must be between 0 and 65535".to_owned()))?,
        };
        let features = match args.get("features").filter(|value| !value.is_null()) {
            None => None,
            Some(value) => Some(strings(value).ok_or_else(|| {
                BridgeError::Invalid("features must be a list of strings".to_owned())
            })?),
        };
        let link_config = LinkConfig {
            state_dir: state_dir(paths)?,
            temp_dir: paths.temp_dir.clone(),
            name: text(args, "name").unwrap_or("").to_owned(),
            port,
            ffmpeg_path: paths.ffmpeg_path.clone(),
            app_version: paths.app_version.clone(),
            platform: text(args, "platform").unwrap_or("").trim().to_owned(),
            features,
        };
        let mut slot = self.server.lock().expect("link server");
        if let Some(previous) = slot.take() {
            stop(previous);
        }
        // Phones advertise through the platform's own service discovery:
        // iOS only lets entitled apps open raw multicast sockets, and
        // Android drops multicast to apps that hold no multicast lock.
        let tuning = Tuning {
            advertise: args
                .get("advertise")
                .and_then(Value::as_bool)
                .unwrap_or(true),
            ..Tuning::default()
        };
        let host: Arc<dyn Host> = self.host.clone();
        let server =
            LinkServer::start_with(link_config, host, tuning).map_err(BridgeError::Failure)?;
        let started = Started {
            summary: server.summary(),
            discovery_error: server.discovery_error().map(str::to_owned),
        };
        *slot = Some(Arc::new(server));
        Ok(started)
    }

    /// `linkStop`. Safe when stopped.
    pub fn stop(&self) {
        let server = self.server.lock().expect("link server").take();
        if let Some(server) = server {
            stop(server);
        }
    }

    /// `linkStatus`: `{"running": false, "receivedDir"}` while stopped
    /// (`receivedDir` only once `app_support_dir` is configured).
    pub fn status(&self, paths: &BridgePaths) -> Value {
        if let Some(server) = self.current() {
            return server.status();
        }
        let mut status = json!({"running": false});
        if let Ok(dir) = state_dir(paths) {
            status["receivedDir"] = Value::from(crate::received_dir(&dir).to_string_lossy());
        }
        status
    }

    /// `linkSetCatalog {"path"}`.
    pub fn set_catalog(&self, args: &Value) -> BridgeResult {
        let path = text(args, "path")
            .filter(|path| !path.is_empty())
            .ok_or_else(|| BridgeError::Invalid("path is required".to_owned()))?;
        self.running()?
            .set_catalog(Path::new(path))
            .map_err(BridgeError::Failure)
    }

    /// `linkBeginPairing`.
    pub fn begin_pairing(&self) -> BridgeResult {
        self.running()?
            .begin_pairing()
            .map_err(BridgeError::Failure)
    }

    /// `linkEndPairing`. Safe when stopped.
    pub fn end_pairing(&self) {
        if let Some(server) = self.current() {
            server.end_pairing();
        }
    }

    /// `linkDevices`; while stopped, the stored devices.
    pub fn devices(&self, paths: &BridgePaths) -> BridgeResult {
        match self.current() {
            Some(server) => Ok(server.devices()),
            None => crate::stored_devices(&state_dir(paths)?).map_err(BridgeError::Failure),
        }
    }

    /// `linkRevoke {"deviceId"}`; works while stopped too.
    pub fn revoke(&self, paths: &BridgePaths, args: &Value) -> BridgeResult {
        let device_id = required(args, "deviceId")?;
        let revoked = match self.current() {
            Some(server) => server.revoke(device_id),
            None => crate::revoke_stored(&state_dir(paths)?, device_id),
        };
        revoked.map(|()| Value::Null).map_err(BridgeError::Failure)
    }

    /// `linkCreateKey {"name"}`.
    pub fn create_key(&self, args: &Value) -> BridgeResult {
        self.running()?
            .create_key(text(args, "name").unwrap_or(""))
            .map_err(BridgeError::Failure)
    }

    /// `linkReply {"requestId", "result"?, "error"?: {"code", "message"}}`.
    /// A reply to a request that already timed out is ignored.
    pub fn reply(&self, args: &Value) -> BridgeResult {
        let request_id = required(args, "requestId")?;
        let reply = match args.get("error").filter(|error| !error.is_null()) {
            Some(error) => {
                let text = |key: &str| error.get(key).and_then(Value::as_str).unwrap_or("");
                let code = Some(text("code"))
                    .filter(|code| !code.is_empty())
                    .unwrap_or("error");
                Err(HostError::new(code, text("message")))
            }
            None => Ok(args.get("result").cloned().unwrap_or(Value::Null)),
        };
        let sender = self
            .host
            .waiting
            .lock()
            .expect("link requests")
            .remove(request_id);
        if let Some(sender) = sender {
            let _ = sender.send(reply);
        }
        Ok(Value::Null)
    }

    /// `linkEmbeddedPictures {"paths": [String]}`: `{"pictures": [bool|null]}`,
    /// whether each audio file embeds a picture the server would serve, null
    /// when it is not a readable file. Works while stopped.
    pub fn embedded_pictures(&self, args: &Value) -> BridgeResult {
        let paths = args
            .get("paths")
            .and_then(Value::as_array)
            .filter(|paths| paths.len() <= MAX_PICTURE_PROBES)
            .ok_or_else(|| {
                BridgeError::Invalid(format!(
                    "paths must be a list of at most {MAX_PICTURE_PROBES} paths"
                ))
            })?;
        let pictures: Vec<Value> = paths
            .iter()
            .map(|path| {
                path.as_str()
                    .filter(|path| !path.is_empty())
                    .and_then(|path| crate::embeds_picture(Path::new(path)))
                    .map_or(Value::Null, Value::Bool)
            })
            .collect();
        Ok(json!({"pictures": pictures}))
    }

    /// `linkSend {"deviceId"?, "message"}`: `{"delivered": <int>}`.
    pub fn send(&self, args: &Value) -> BridgeResult {
        let message = args
            .get("message")
            .filter(|message| !message.is_null())
            .cloned()
            .ok_or_else(|| BridgeError::Invalid("message is required".to_owned()))?;
        let device_id = text(args, "deviceId").filter(|id| !id.is_empty());
        let delivered = self
            .current()
            .map_or(0, |server| server.send(device_id, message));
        Ok(json!({"delivered": delivered}))
    }
}

/// Stops now when nothing else holds the server, else when the last call
/// using it returns.
fn stop(server: Arc<LinkServer>) {
    if let Ok(server) = Arc::try_unwrap(server) {
        server.stop();
    }
}

/// `<app_support_dir>/link`.
fn state_dir(paths: &BridgePaths) -> Result<PathBuf, BridgeError> {
    if paths.app_support_dir.as_os_str().is_empty() {
        return Err(BridgeError::Failure(
            "app_support_dir is not configured".to_owned(),
        ));
    }
    Ok(paths.app_support_dir.join("link"))
}

fn text<'a>(args: &'a Value, key: &str) -> Option<&'a str> {
    args.get(key)?.as_str()
}

/// A whole number, also from a float or an unsigned value, like the
/// desktop's argument reader.
fn number(args: &Value, key: &str) -> Option<i64> {
    let value = args.get(key)?;
    value
        .as_i64()
        .or_else(|| value.as_u64().map(|value| value as i64))
        .or_else(|| value.as_f64().map(|value| value as i64))
}

fn strings(value: &Value) -> Option<Vec<String>> {
    value
        .as_array()?
        .iter()
        .map(|value| value.as_str().map(str::to_owned))
        .collect()
}

fn required<'a>(args: &'a Value, key: &str) -> Result<&'a str, BridgeError> {
    text(args, key)
        .filter(|value| !value.is_empty())
        .ok_or_else(|| BridgeError::Invalid(format!("{key} is required")))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::future::Future;

    type Calls = Arc<Mutex<Vec<(String, Value)>>>;

    fn bridge() -> (AppBridge, Calls) {
        let calls: Calls = Arc::default();
        let recorded = Arc::clone(&calls);
        let bridge = AppBridge::new(Arc::new(move |method, args| {
            recorded.lock().unwrap().push((method.to_owned(), args));
        }));
        (bridge, calls)
    }

    fn block_on<T>(future: impl Future<Output = T>) -> T {
        tokio::runtime::Builder::new_current_thread()
            .build()
            .unwrap()
            .block_on(future)
    }

    fn invalid(result: BridgeResult) -> bool {
        matches!(result, Err(BridgeError::Invalid(_)))
    }

    #[test]
    fn link_reply_completes_the_pending_request() {
        let (bridge, calls) = bridge();
        let pending = bridge
            .host
            .request("state", "phone", json!({"_method": "GET"}));
        let (method, arguments) = calls.lock().unwrap()[0].clone();
        assert_eq!(method, "linkRequest");
        assert_eq!(arguments["op"], "state");
        assert_eq!(arguments["deviceId"], "phone");
        assert_eq!(arguments["args"], json!({"_method": "GET"}));
        let request_id = arguments["requestId"].as_str().unwrap().to_owned();

        let replied = bridge
            .reply(&json!({"requestId": request_id, "result": {"playing": true}}))
            .unwrap();
        assert_eq!(replied, Value::Null);
        assert_eq!(block_on(pending), Ok(json!({"playing": true})));
        assert!(bridge.host.waiting.lock().unwrap().is_empty());
    }

    #[test]
    fn link_reply_errors_reach_the_server() {
        let (bridge, calls) = bridge();
        let pending = bridge.host.request("resolve", "phone", json!({}));
        let request_id = calls.lock().unwrap()[0].1["requestId"].clone();
        bridge
            .reply(&json!({
                "requestId": request_id,
                "error": {"code": "not_found", "message": "No such track"},
            }))
            .unwrap();
        assert_eq!(
            block_on(pending),
            Err(HostError::new("not_found", "No such track"))
        );
    }

    #[test]
    fn abandoned_requests_are_forgotten() {
        let (bridge, calls) = bridge();
        let pending = bridge.host.request("state", "phone", json!({}));
        let request_id = calls.lock().unwrap()[0].1["requestId"].clone();
        drop(pending);
        assert!(bridge.host.waiting.lock().unwrap().is_empty());
        assert_eq!(
            bridge
                .reply(&json!({"requestId": request_id, "result": {}}))
                .unwrap(),
            Value::Null
        );
        assert!(invalid(bridge.reply(&json!({}))));
    }

    #[test]
    fn events_reach_the_emitter() {
        let (bridge, calls) = bridge();
        bridge
            .host
            .event("linkPairingEnded", json!({"reason": "expired"}));
        assert_eq!(
            calls.lock().unwrap()[0],
            ("linkPairingEnded".to_owned(), json!({"reason": "expired"}))
        );
    }

    #[test]
    fn calls_dispatch_by_name() {
        let (bridge, _) = bridge();
        let dir = tempfile::tempdir().unwrap();
        let paths = BridgePaths {
            app_support_dir: dir.path().to_owned(),
            ..BridgePaths::default()
        };
        assert_eq!(
            bridge.call(&paths, "linkStatus", &json!({})).unwrap()["running"],
            false
        );
        assert_eq!(
            bridge.call(&paths, "linkDevices", &json!({})).unwrap(),
            json!([])
        );
        assert_eq!(
            bridge.call(&paths, "linkStop", &json!({})).unwrap(),
            Value::Null
        );
        assert_eq!(
            bridge
                .call(&paths, "linkSend", &json!({"message": {"type": "x"}}))
                .unwrap(),
            json!({"delivered": 0})
        );
        assert!(invalid(bridge.call(&paths, "linkElsewhere", &json!({}))));
        assert_eq!(
            bridge.call(&paths, "linkBeginPairing", &json!({})),
            Err(BridgeError::Failure(
                "Mornye Link is not running".to_owned()
            ))
        );
    }

    #[test]
    fn start_checks_its_arguments() {
        let (bridge, _) = bridge();
        let dir = tempfile::tempdir().unwrap();
        let paths = BridgePaths {
            app_support_dir: dir.path().to_owned(),
            ..BridgePaths::default()
        };
        let error = |args: Value| bridge.start(&paths, &args).err();
        assert!(matches!(
            error(json!({"port": 70000})),
            Some(BridgeError::Invalid(_))
        ));
        assert!(matches!(
            error(json!({"features": "downloads"})),
            Some(BridgeError::Invalid(_))
        ));
        assert!(matches!(
            error(json!({"features": [1]})),
            Some(BridgeError::Invalid(_))
        ));
        assert_eq!(
            bridge
                .start(&BridgePaths::default(), &json!({"name": "Desk"}))
                .err(),
            Some(BridgeError::Failure(
                "app_support_dir is not configured".to_owned()
            ))
        );
    }
}
