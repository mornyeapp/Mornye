//! Mornye Link host for Android and iOS: the same `link*` methods the
//! desktop runs (`mornye_link::bridge`), so a phone can share its Library
//! with another phone. Events (`linkRequest`, `linkMessage`, `linkClients`,
//! `linkPaired`, `linkPairingEnded`) are pulled with `next_event`, as the
//! platforms do for Cast.

use mornye_link::bridge::{AppBridge, BridgePaths};
use serde_json::Value;
use std::collections::VecDeque;
use std::path::PathBuf;
use std::sync::{Arc, Condvar, Mutex};
use std::time::Duration;

/// Events past this many unread are dropped oldest first. Only an app that
/// stopped reading reaches it; a dropped request then times out on the
/// server like an unanswered one.
const MAX_QUEUED_EVENTS: usize = 4096;

#[derive(Debug, thiserror::Error, uniffi::Error)]
#[uniffi(flat_error)]
pub enum LinkBridgeError {
    #[error("{0}")]
    Failed(String),
}

#[derive(Default)]
struct Events {
    queue: Mutex<VecDeque<String>>,
    ready: Condvar,
}

#[derive(uniffi::Object)]
pub struct LinkBridge {
    bridge: AppBridge,
    paths: Mutex<BridgePaths>,
    events: Arc<Events>,
}

#[uniffi::export]
impl LinkBridge {
    #[uniffi::constructor]
    pub fn new() -> Arc<Self> {
        let events = Arc::new(Events::default());
        let sink = Arc::clone(&events);
        let bridge = AppBridge::new(Arc::new(move |method, arguments| {
            let mut queue = sink.queue.lock().expect("link events");
            if queue.len() == MAX_QUEUED_EVENTS {
                queue.pop_front();
            }
            queue.push_back(
                serde_json::json!({"method": method, "arguments": arguments}).to_string(),
            );
            sink.ready.notify_all();
        }));
        Arc::new(Self {
            bridge,
            paths: Mutex::new(BridgePaths::default()),
            events,
        })
    }

    /// Runs a `link*` method with JSON arguments; answers JSON. The app
    /// first sends `linkConfigure {"appSupportDir", "tempDir", "appVersion"}`,
    /// the paths the desktop reads from its runtime config.
    pub fn call(&self, method: String, args_json: String) -> Result<String, LinkBridgeError> {
        let args = if args_json.trim().is_empty() {
            Value::Null
        } else {
            serde_json::from_str(&args_json)
                .map_err(|error| LinkBridgeError::Failed(error.to_string()))?
        };
        if method == "linkConfigure" {
            let text = |key: &str| args.get(key).and_then(Value::as_str).unwrap_or("");
            *self.paths.lock().expect("link paths") = BridgePaths {
                app_support_dir: PathBuf::from(text("appSupportDir")),
                temp_dir: PathBuf::from(text("tempDir")),
                // The phone builds have no ffmpeg binary for the server.
                ffmpeg_path: None,
                app_version: text("appVersion").to_owned(),
            };
            return Ok(Value::Null.to_string());
        }
        let paths = self.paths.lock().expect("link paths").clone();
        self.bridge
            .call(&paths, &method, &args)
            .map(|value| value.to_string())
            .map_err(|error| LinkBridgeError::Failed(error.message().to_owned()))
    }

    /// The next `{"method","arguments"}` JSON, or none after `timeout_ms`.
    pub fn next_event(&self, timeout_ms: u64) -> Option<String> {
        let queue = self.events.queue.lock().expect("link events");
        let (mut queue, _) = self
            .events
            .ready
            .wait_timeout_while(queue, Duration::from_millis(timeout_ms), |queue| {
                queue.is_empty()
            })
            .expect("link events");
        queue.pop_front()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn configure_then_answer_while_stopped() {
        let bridge = LinkBridge::new();
        let dir = tempfile::tempdir().unwrap();
        assert!(
            bridge
                .call("linkDevices".to_owned(), String::new())
                .is_err()
        );
        let configure = serde_json::json!({
            "appSupportDir": dir.path(),
            "tempDir": dir.path(),
            "appVersion": "1.0.0",
        });
        bridge
            .call("linkConfigure".to_owned(), configure.to_string())
            .unwrap();
        assert_eq!(
            bridge
                .call("linkDevices".to_owned(), String::new())
                .unwrap(),
            "[]"
        );
        let status: Value = serde_json::from_str(
            &bridge
                .call("linkStatus".to_owned(), "{}".to_owned())
                .unwrap(),
        )
        .unwrap();
        assert_eq!(status["running"], false);
        assert!(bridge.next_event(0).is_none());
        assert!(
            bridge
                .call("linkStart".to_owned(), "not json".to_owned())
                .is_err()
        );
    }
}
