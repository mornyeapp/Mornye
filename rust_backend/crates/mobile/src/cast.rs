//! Google Cast for Android and iOS (`mornye_cast::CastService`). Android
//! keeps Google's sender and uses the media server methods; iOS uses the
//! whole service. Events are pulled with `next_event`, as the platforms do
//! for download progress.

use std::collections::VecDeque;
use std::sync::{Arc, Condvar, Mutex};
use std::time::Duration;

/// Events past this many unread are dropped oldest first; a status snapshot
/// replaces the ones before it anyway.
const MAX_QUEUED_EVENTS: usize = 64;

#[derive(Debug, thiserror::Error, uniffi::Error)]
#[uniffi(flat_error)]
pub enum CastBridgeError {
    #[error("{0}")]
    Failed(String),
}

#[derive(Default)]
struct Events {
    queue: Mutex<VecDeque<String>>,
    ready: Condvar,
}

#[derive(uniffi::Object)]
pub struct CastBridge {
    service: mornye_cast::CastService,
    events: Arc<Events>,
}

#[uniffi::export]
impl CastBridge {
    #[uniffi::constructor]
    pub fn new() -> Result<Arc<Self>, CastBridgeError> {
        let events = Arc::new(Events::default());
        let sink = Arc::clone(&events);
        let service = mornye_cast::CastService::new(move |event, payload| {
            let mut queue = sink.queue.lock().expect("cast events");
            if queue.len() == MAX_QUEUED_EVENTS {
                queue.pop_front();
            }
            queue.push_back(serde_json::json!({"event": event, "payload": payload}).to_string());
            sink.ready.notify_all();
        })
        .map_err(|error| CastBridgeError::Failed(error.to_string()))?;
        Ok(Arc::new(Self { service, events }))
    }

    /// Runs a `CastService` method with JSON arguments; answers JSON.
    pub fn call(&self, method: String, args_json: String) -> Result<String, CastBridgeError> {
        let args = if args_json.trim().is_empty() {
            serde_json::Value::Null
        } else {
            serde_json::from_str(&args_json)
                .map_err(|error| CastBridgeError::Failed(error.to_string()))?
        };
        self.service
            .call(&method, &args)
            .map(|value| value.to_string())
            .map_err(CastBridgeError::Failed)
    }

    /// The next `{"event","payload"}` JSON, or none after `timeout_ms`.
    pub fn next_event(&self, timeout_ms: u64) -> Option<String> {
        let queue = self.events.queue.lock().expect("cast events");
        let (mut queue, _) = self
            .events
            .ready
            .wait_timeout_while(queue, Duration::from_millis(timeout_ms), |queue| {
                queue.is_empty()
            })
            .expect("cast events");
        queue.pop_front()
    }
}
