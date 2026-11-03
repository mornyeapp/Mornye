//! Process-wide state behind the C ABI: configuration, the callback, in-flight
//! calls, the worker pool, the backend owner, and event subscriptions.

use crate::backend::Backend;
use crate::call::{Args, CallError, CallResult, CallState, Reply};
use crate::cast::Cast;
use crate::discord::Discord;
use crate::events::Events;
use crate::keep_awake::KeepAwake;
use crate::link::Link;
use crate::pool::Pool;
use crate::watcher::LibraryWatcher;
use crate::{crash_log, dispatch, kind};
use serde_json::Value;
use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::{Arc, Mutex, OnceLock, RwLock};

/// `mornye_callback`: `(id, kind, data, len)`. Every non-null `data` buffer
/// must be released with `mornye_free`.
pub type MornyeCallback = extern "C" fn(id: u64, kind: i32, data: *const u8, len: usize);

/// Paths Dart passes to `mornye_init`.
#[derive(Debug, Clone, Default)]
pub struct Config {
    pub app_support_dir: PathBuf,
    pub documents_dir: PathBuf,
    pub temp_dir: PathBuf,
    pub ffmpeg_path: Option<PathBuf>,
    pub ffprobe_path: Option<PathBuf>,
    /// Optional `app_version` key; extensions see it as the host version.
    pub app_version: String,
}

impl Config {
    pub fn parse(json: &[u8]) -> Result<Self, String> {
        let value: Value = if json.is_empty() {
            Value::Object(Default::default())
        } else {
            serde_json::from_slice(json).map_err(|error| error.to_string())?
        };
        let object = value
            .as_object()
            .ok_or("Desktop configuration must be a JSON object")?;
        let text = |key: &str| object.get(key).and_then(Value::as_str).unwrap_or("");
        let path = |key: &str| {
            Some(text(key))
                .filter(|value| !value.is_empty())
                .map(PathBuf::from)
        };
        let app_support_dir = PathBuf::from(text("app_support_dir"));
        let temp_dir = path("temp_dir").unwrap_or_else(std::env::temp_dir);
        Ok(Self {
            app_support_dir,
            documents_dir: PathBuf::from(text("documents_dir")),
            temp_dir,
            ffmpeg_path: path("ffmpeg_path"),
            ffprobe_path: path("ffprobe_path"),
            app_version: Some(text("app_version"))
                .filter(|value| !value.is_empty())
                .unwrap_or("1")
                .to_owned(),
        })
    }
}

pub(crate) struct Runtime {
    pub(crate) config: Config,
    pub(crate) backend: Backend,
    pub(crate) events: Events,
    pub(crate) keep_awake: KeepAwake,
    pub(crate) discord: Discord,
    pub(crate) watcher: LibraryWatcher,
    pub(crate) link: Link,
    pub(crate) cast: Cast,
    pool: Pool,
    calls: Mutex<HashMap<u64, Arc<CallState>>>,
}

static RUNTIME: OnceLock<Runtime> = OnceLock::new();
static CALLBACK: RwLock<Option<MornyeCallback>> = RwLock::new(None);

/// Idempotent. A later call replaces the callback (a Dart hot restart creates
/// a new one) and keeps the first configuration and backend state.
pub(crate) fn init(callback: Option<MornyeCallback>, config: &[u8]) {
    *CALLBACK.write().expect("callback lock") = callback;
    if RUNTIME.get().is_some() {
        return;
    }
    let config = Config::parse(config).unwrap_or_else(|error| {
        log("error", &format!("Invalid desktop configuration: {error}"));
        Config::parse(b"{}").expect("default configuration")
    });
    crash_log::install(&config.app_support_dir);
    let _ = RUNTIME.get_or_init(|| Runtime {
        backend: Backend::new(&config),
        config,
        events: Events::default(),
        keep_awake: KeepAwake::default(),
        discord: Discord::default(),
        watcher: LibraryWatcher::default(),
        link: Link::default(),
        cast: Cast::default(),
        pool: Pool::default(),
        calls: Mutex::new(HashMap::new()),
    });
}

pub(crate) fn get() -> Option<&'static Runtime> {
    RUNTIME.get()
}

/// Hands `data` to the callback. The buffer is leaked here and reclaimed by
/// `mornye_free`; without a callback it is dropped.
pub(crate) fn emit(id: u64, kind: i32, data: Vec<u8>) {
    let Some(callback) = *CALLBACK.read().expect("callback lock") else {
        return;
    };
    if data.is_empty() {
        callback(id, kind, std::ptr::null(), 0);
        return;
    }
    let data = Box::into_raw(data.into_boxed_slice());
    let len = data.len();
    callback(id, kind, data.cast::<u8>(), len);
}

/// Kind 13 record, the desktop equivalent of the hosts' `NSLog`/`Log.w`.
pub(crate) fn log(level: &str, message: &str) {
    if let Some(runtime) = get()
        && runtime.events.logs_enabled()
    {
        let record = serde_json::json!({"level": level, "tag": "Mornye", "message": message});
        emit(0, kind::LOG, record.to_string().into_bytes());
    }
}

/// Kind 12: a host to Dart MethodChannel call.
pub(crate) fn inbound(method: &str, arguments: Value) {
    let payload = serde_json::json!({"method": method, "arguments": arguments});
    emit(0, kind::INBOUND_CALL, payload.to_string().into_bytes());
}

fn reply(id: u64, result: CallResult) {
    match result {
        Ok(Reply::Json(value)) => emit(id, kind::RESULT, value.to_string().into_bytes()),
        Ok(Reply::Binary(bytes)) => emit(id, kind::BINARY_RESULT, bytes),
        Err(error) => emit(id, kind::ERROR, error.to_json()),
    }
}

impl Runtime {
    pub(crate) fn call(&'static self, id: u64, method: &str, args: &[u8], bytes: Option<Vec<u8>>) {
        let Some(entry) = dispatch::find(method) else {
            reply(id, Err(CallError::unimplemented(method)));
            return;
        };
        let args = match Args::decode(args, bytes) {
            Ok(args) => args,
            Err(error) => return reply(id, Err(error)),
        };
        let state = Arc::new(CallState::default());
        if let Err(error) = dispatch::prepare(self, entry.name, &args, &state) {
            return reply(id, Err(error));
        }
        if entry.inline {
            return reply(id, dispatch::run(self, entry, &args, &state));
        }
        self.calls
            .lock()
            .expect("calls lock")
            .insert(id, Arc::clone(&state));
        self.pool.submit(move || {
            let result = if state.is_cancelled() {
                dispatch::abandon(self, entry.name, &args, &state);
                Err(CallError::cancelled())
            } else {
                dispatch::run(self, entry, &args, &state)
            };
            self.calls.lock().expect("calls lock").remove(&id);
            reply(id, result);
        });
    }

    pub(crate) fn cancel(&self, id: u64) {
        let state = self.calls.lock().expect("calls lock").get(&id).cloned();
        if let Some(state) = state {
            state.cancel();
        }
    }
}
