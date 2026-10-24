//! Mornye Link on desktop (`LINK_CONTRACT.md` section 6): runs the
//! `mornye-link` HTTPS server for the `link*` methods and bridges it to Dart.
//! A request the server forwards becomes the inbound call `linkRequest`
//! (kind 12), and Dart answers it with `linkReply`; the server's other
//! events become the inbound calls `linkMessage`, `linkClients`,
//! `linkPaired` and `linkPairingEnded`.

use crate::call::{Args, CallError, CallResult, Reply};
use crate::runtime::Config;
use mornye_link::{Host, HostError, LinkConfig, LinkServer};
use serde_json::{Value, json};
use std::collections::HashMap;
use std::future::Future;
use std::path::{Path, PathBuf};
use std::pin::Pin;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use tokio::sync::oneshot;

type Emitter = Arc<dyn Fn(&str, Value) + Send + Sync>;
type Waiting = Arc<Mutex<HashMap<String, oneshot::Sender<Result<Value, HostError>>>>>;
type ReplyFuture = Pin<Box<dyn Future<Output = Result<Value, HostError>> + Send>>;

/// The app side of the server: inbound calls out, `linkReply` back.
struct DesktopHost {
    emit: Emitter,
    waiting: Waiting,
    next_id: AtomicU64,
}

impl Host for DesktopHost {
    fn request(&self, op: &str, device_id: &str, args: Value) -> ReplyFuture {
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

pub(crate) struct Link {
    host: Arc<DesktopHost>,
    /// Shared so a slow call (catalog loading) does not hold the lock; the
    /// server stops when the last holder lets go.
    server: Mutex<Option<Arc<LinkServer>>>,
}

impl Default for Link {
    fn default() -> Self {
        Self::new(Arc::new(|method, args| {
            crate::runtime::inbound(method, args)
        }))
    }
}

impl Link {
    pub(crate) fn new(emit: Emitter) -> Self {
        Self {
            host: Arc::new(DesktopHost {
                emit,
                waiting: Arc::default(),
                next_id: AtomicU64::new(0),
            }),
            server: Mutex::new(None),
        }
    }

    fn current(&self) -> Option<Arc<LinkServer>> {
        self.server.lock().expect("link server").clone()
    }

    fn running(&self) -> Result<Arc<LinkServer>, CallError> {
        self.current()
            .ok_or_else(|| CallError::failure("Mornye Link is not running"))
    }

    /// `linkStart {"name", "port"?}`. Restarts a running server.
    pub(crate) fn start(&self, config: &Config, args: &Args) -> CallResult {
        let port = match args.i64("port") {
            None => 0,
            Some(port) => u16::try_from(port)
                .map_err(|_| CallError::invalid_arguments("port must be between 0 and 65535"))?,
        };
        let link_config = LinkConfig {
            state_dir: state_dir(config)?,
            temp_dir: config.temp_dir.clone(),
            name: args.string("name", ""),
            port,
            ffmpeg_path: config.ffmpeg_path.clone(),
            app_version: config.app_version.clone(),
        };
        let mut slot = self.server.lock().expect("link server");
        if let Some(previous) = slot.take() {
            stop(previous);
        }
        let host: Arc<dyn Host> = self.host.clone();
        let server = LinkServer::start(link_config, host).map_err(CallError::failure)?;
        if let Some(error) = server.discovery_error() {
            crate::runtime::log("warn", error);
        }
        let summary = server.summary();
        *slot = Some(Arc::new(server));
        Ok(summary.into())
    }

    /// `linkStop`. Safe when stopped.
    pub(crate) fn stop(&self) {
        let server = self.server.lock().expect("link server").take();
        if let Some(server) = server {
            stop(server);
        }
    }

    /// `linkStatus`: `{"running": false}` while stopped.
    pub(crate) fn status(&self) -> Value {
        self.current()
            .map_or_else(|| json!({"running": false}), |server| server.status())
    }

    /// `linkSetCatalog {"path"}`.
    pub(crate) fn set_catalog(&self, args: &Args) -> CallResult {
        let path = args
            .opt_string("path")
            .filter(|path| !path.is_empty())
            .ok_or_else(|| CallError::invalid_arguments("path is required"))?;
        let server = self.running()?;
        server
            .set_catalog(Path::new(path))
            .map(Reply::from)
            .map_err(CallError::failure)
    }

    /// `linkBeginPairing`.
    pub(crate) fn begin_pairing(&self) -> CallResult {
        self.running()?
            .begin_pairing()
            .map(Reply::from)
            .map_err(CallError::failure)
    }

    /// `linkEndPairing`. Safe when stopped.
    pub(crate) fn end_pairing(&self) {
        if let Some(server) = self.current() {
            server.end_pairing();
        }
    }

    /// `linkDevices`; while stopped, the stored devices.
    pub(crate) fn devices(&self, config: &Config) -> CallResult {
        match self.current() {
            Some(server) => Ok(server.devices().into()),
            None => mornye_link::stored_devices(&state_dir(config)?)
                .map(Reply::from)
                .map_err(CallError::failure),
        }
    }

    /// `linkRevoke {"deviceId"}`; works while stopped too.
    pub(crate) fn revoke(&self, config: &Config, args: &Args) -> CallResult {
        let device_id = required(args, "deviceId")?;
        let revoked = match self.current() {
            Some(server) => server.revoke(device_id),
            None => mornye_link::revoke_stored(&state_dir(config)?, device_id),
        };
        revoked.map(Reply::from).map_err(CallError::failure)
    }

    /// `linkCreateKey {"name"}`.
    pub(crate) fn create_key(&self, args: &Args) -> CallResult {
        self.running()?
            .create_key(&args.string("name", ""))
            .map(Reply::from)
            .map_err(CallError::failure)
    }

    /// `linkReply {"requestId", "result"?, "error"?: {"code", "message"}}`.
    /// A reply to a request that already timed out is ignored.
    pub(crate) fn reply(&self, args: &Args) -> CallResult {
        let request_id = required(args, "requestId")?;
        let value = args.value();
        let reply = match value.get("error").filter(|error| !error.is_null()) {
            Some(error) => {
                let text = |key: &str| error.get(key).and_then(Value::as_str).unwrap_or("");
                let code = Some(text("code"))
                    .filter(|code| !code.is_empty())
                    .unwrap_or("error");
                Err(HostError::new(code, text("message")))
            }
            None => Ok(value.get("result").cloned().unwrap_or(Value::Null)),
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
        Ok(Reply::null())
    }

    /// `linkSend {"deviceId"?, "message"}`: `{"delivered": <int>}`.
    pub(crate) fn send(&self, args: &Args) -> CallResult {
        let message = args
            .value()
            .get("message")
            .filter(|message| !message.is_null())
            .cloned()
            .ok_or_else(|| CallError::invalid_arguments("message is required"))?;
        let device_id = args.opt_string("deviceId").filter(|id| !id.is_empty());
        let delivered = self
            .current()
            .map_or(0, |server| server.send(device_id, message));
        Ok(json!({"delivered": delivered}).into())
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
fn state_dir(config: &Config) -> Result<PathBuf, CallError> {
    if config.app_support_dir.as_os_str().is_empty() {
        return Err(CallError::failure("app_support_dir is not configured"));
    }
    Ok(config.app_support_dir.join("link"))
}

fn required<'a>(args: &'a Args, key: &str) -> Result<&'a str, CallError> {
    args.opt_string(key)
        .filter(|value| !value.is_empty())
        .ok_or_else(|| CallError::invalid_arguments(format!("{key} is required")))
}

#[cfg(test)]
mod tests {
    use super::*;

    type Calls = Arc<Mutex<Vec<(String, Value)>>>;

    fn link() -> (Link, Calls) {
        let calls: Calls = Arc::default();
        let recorded = Arc::clone(&calls);
        let link = Link::new(Arc::new(move |method, args| {
            recorded.lock().unwrap().push((method.to_owned(), args));
        }));
        (link, calls)
    }

    fn args(value: Value) -> Args {
        Args::decode(value.to_string().as_bytes(), None).unwrap()
    }

    fn block_on<T>(future: impl Future<Output = T>) -> T {
        tokio::runtime::Builder::new_current_thread()
            .build()
            .unwrap()
            .block_on(future)
    }

    #[test]
    fn link_reply_completes_the_pending_request() {
        let (link, calls) = link();
        let pending = link
            .host
            .request("state", "phone", json!({"_method": "GET"}));
        let (method, arguments) = calls.lock().unwrap()[0].clone();
        assert_eq!(method, "linkRequest");
        assert_eq!(arguments["op"], "state");
        assert_eq!(arguments["deviceId"], "phone");
        assert_eq!(arguments["args"], json!({"_method": "GET"}));
        let request_id = arguments["requestId"].as_str().unwrap().to_owned();

        let replied = link
            .reply(&args(
                json!({"requestId": request_id, "result": {"playing": true}}),
            ))
            .unwrap();
        assert_eq!(replied, Reply::null());
        assert_eq!(block_on(pending), Ok(json!({"playing": true})));
        assert!(link.host.waiting.lock().unwrap().is_empty());
    }

    #[test]
    fn link_reply_errors_reach_the_server() {
        let (link, calls) = link();
        let pending = link.host.request("resolve", "phone", json!({}));
        let request_id = calls.lock().unwrap()[0].1["requestId"].clone();
        link.reply(&args(json!({
            "requestId": request_id,
            "error": {"code": "not_found", "message": "No such track"},
        })))
        .unwrap();
        assert_eq!(
            block_on(pending),
            Err(HostError::new("not_found", "No such track"))
        );
    }

    #[test]
    fn abandoned_requests_are_forgotten() {
        let (link, calls) = link();
        let pending = link.host.request("state", "phone", json!({}));
        let request_id = calls.lock().unwrap()[0].1["requestId"].clone();
        drop(pending);
        assert!(link.host.waiting.lock().unwrap().is_empty());
        // A late reply is ignored.
        assert_eq!(
            link.reply(&args(json!({"requestId": request_id, "result": {}})))
                .unwrap(),
            Reply::null()
        );
        assert_eq!(
            link.reply(&args(json!({}))).unwrap_err().code,
            "invalid_arguments"
        );
    }

    #[test]
    fn events_become_inbound_calls() {
        let (link, calls) = link();
        link.host
            .event("linkPairingEnded", json!({"reason": "expired"}));
        assert_eq!(
            calls.lock().unwrap()[0],
            ("linkPairingEnded".to_owned(), json!({"reason": "expired"}))
        );
    }

    #[test]
    fn answers_while_stopped() {
        let (link, _) = link();
        let dir = tempfile::tempdir().unwrap();
        let config = Config {
            app_support_dir: dir.path().to_owned(),
            ..Config::default()
        };
        assert_eq!(link.status(), json!({"running": false}));
        assert_eq!(link.devices(&config).unwrap(), Reply::Json(json!([])));
        assert!(
            link.revoke(&config, &args(json!({"deviceId": "phone"})))
                .is_ok()
        );
        assert!(link.begin_pairing().is_err());
        assert!(link.create_key(&args(json!({"name": "App"}))).is_err());
        assert_eq!(
            link.send(&args(json!({"message": {"type": "x"}}))).unwrap(),
            Reply::Json(json!({"delivered": 0}))
        );
        assert!(link.send(&args(json!({}))).is_err());
        link.end_pairing();
        link.stop();
        assert_eq!(
            link.start(&Config::default(), &args(json!({"name": "Desk"})))
                .unwrap_err()
                .message,
            "app_support_dir is not configured"
        );
        assert_eq!(
            link.start(&config, &args(json!({"port": 70000})))
                .unwrap_err()
                .code,
            "invalid_arguments"
        );
    }
}
