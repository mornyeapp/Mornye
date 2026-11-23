//! What the app knows about the session, shared by every receiver kind so
//! `state` and `position` answer without waiting on the connection. The
//! snapshot keeps the Android plugin's shape, which the app's player reads.

use crate::discovery::Device;
use serde_json::{Value, json};
use std::time::Instant;

/// Android's `MediaStatus` player states, which the app's player reads.
pub(crate) mod state {
    pub(crate) const UNKNOWN: i64 = 0;
    pub(crate) const IDLE: i64 = 1;
    pub(crate) const PLAYING: i64 = 2;
    pub(crate) const PAUSED: i64 = 3;
    pub(crate) const BUFFERING: i64 = 4;
    pub(crate) const LOADING: i64 = 5;
}

/// Idle reasons the snapshot turns into `finished` and `failed`.
pub(crate) const FINISHED: &str = "FINISHED";
pub(crate) const ERROR: &str = "ERROR";

#[derive(Default)]
pub(crate) struct Status {
    pub(crate) device: Option<Device>,
    pub(crate) connected: bool,
    pub(crate) revision: u64,
    /// 0 to 1; `None` for a receiver whose volume the app cannot know or set,
    /// which the snapshot then leaves out.
    pub(crate) volume: Option<f64>,
    pub(crate) media_session: Option<i64>,
    pub(crate) token: Option<i64>,
    pub(crate) current_time: f64,
    pub(crate) reported: Option<Instant>,
    pub(crate) duration: f64,
    pub(crate) player_state: i64,
    pub(crate) idle_reason: Option<String>,
}

impl Status {
    /// A new session on `device`; nothing of the previous one carries over.
    pub(crate) fn start(&mut self, device: Device, volume: Option<f64>) {
        *self = Self {
            device: Some(device),
            connected: true,
            revision: self.revision + 1,
            volume,
            ..Self::default()
        };
    }

    /// A newly loaded item, waiting for play as a Cast load without autoplay.
    pub(crate) fn begin_item(&mut self, token: i64, duration: f64) {
        self.token = Some(token);
        self.duration = duration.max(0.0);
        self.player_state = state::PAUSED;
        self.idle_reason = None;
        self.report(0.0);
    }

    /// The receiver's position in seconds, as of now.
    pub(crate) fn report(&mut self, seconds: f64) {
        self.current_time = seconds.max(0.0);
        self.reported = Some(Instant::now());
    }

    pub(crate) fn position_seconds(&self) -> f64 {
        let mut seconds = self.current_time;
        if self.player_state == state::PLAYING
            && let Some(at) = self.reported
        {
            seconds += at.elapsed().as_secs_f64();
        }
        if self.duration > 0.0 {
            seconds = seconds.min(self.duration);
        }
        seconds
    }

    pub(crate) fn position_ms(&self) -> i64 {
        (self.position_seconds() * 1000.0) as i64
    }

    pub(crate) fn snapshot(&self) -> Value {
        let Some(device) = self.device.as_ref().filter(|_| self.connected) else {
            let mut snapshot = json!({"connected": false, "revision": self.revision});
            if let Some(device) = &self.device {
                snapshot["kind"] = json!(device.kind);
            }
            return snapshot;
        };
        let mut snapshot = json!({
            "connected": true,
            "kind": device.kind,
            "deviceId": device.id,
            "revision": self.revision,
            "deviceName": device.name,
            "host": device.host.to_string(),
            "token": self.token,
            "position": self.position_ms(),
            "duration": (self.duration * 1000.0) as i64,
            "state": self.player_state,
            "finished": self.idle_reason.as_deref() == Some(FINISHED),
            "failed": self.idle_reason.as_deref() == Some(ERROR),
        });
        if let Some(volume) = self.volume {
            snapshot["volume"] = json!(volume);
        }
        snapshot
    }
}
