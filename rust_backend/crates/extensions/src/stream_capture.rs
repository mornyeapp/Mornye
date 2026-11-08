//! In-flight stream URL capture from extension download invocations.
//!
//! Extensions that implement audio streaming via their `download()` method
//! call the host function `file.download(url, path, options)` or
//! `file.downloadSegments(...)`. When stream capture is active for an item,
//! the host captures the remote URL and HTTP request headers without writing
//! any bytes to disk, enabling direct online playback.

use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::sync::{LazyLock, Mutex};

/// Captured remote audio stream information from an extension.
#[derive(Clone, Debug, Default, Serialize, Deserialize, PartialEq, Eq)]
pub struct CapturedStream {
    pub url: String,
    pub headers: BTreeMap<String, String>,
    pub format: Option<String>,
}

static CAPTURES: LazyLock<Mutex<BTreeMap<String, CapturedStream>>> =
    LazyLock::new(|| Mutex::new(BTreeMap::new()));

/// RAII guard that associates a capture token with an active stream resolution
/// and guarantees removal upon completion or drop.
pub struct StreamCaptureGuard {
    token: String,
}

impl StreamCaptureGuard {
    pub fn new(token: String) -> Self {
        Self { token }
    }

    pub fn token(&self) -> &str {
        &self.token
    }

    /// Retrieve the captured stream if one was recorded, removing it from registry.
    pub fn take(self) -> Option<CapturedStream> {
        let mut guard = CAPTURES.lock().ok()?;
        guard.remove(&self.token)
    }
}

impl Drop for StreamCaptureGuard {
    fn drop(&mut self) {
        if let Ok(mut captures) = CAPTURES.lock() {
            captures.remove(&self.token);
        }
    }
}

/// Record a stream capture for the given token.
pub fn record_capture(token: &str, stream: CapturedStream) {
    if let Ok(mut captures) = CAPTURES.lock() {
        captures.insert(token.to_owned(), stream);
    }
}

/// True if `token` indicates an active stream capture session.
pub fn is_capture_active(token: &str) -> bool {
    token.starts_with("stream-capture-")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn capture_guard_records_and_takes() {
        let token = "stream-capture-test-1".to_string();
        let guard = StreamCaptureGuard::new(token.clone());

        assert!(is_capture_active(&token));
        assert!(!is_capture_active("regular-download-item"));

        let mut headers = BTreeMap::new();
        headers.insert("User-Agent".into(), "Mornye/1.0".into());
        headers.insert("Range".into(), "bytes=0-".into());

        record_capture(
            &token,
            CapturedStream {
                url: "https://stream.example.com/audio.mp4".into(),
                headers: headers.clone(),
                format: Some("m4a".into()),
            },
        );

        let captured = guard.take().expect("captured stream must be present");
        assert_eq!(captured.url, "https://stream.example.com/audio.mp4");
        assert_eq!(captured.headers, headers);
        assert_eq!(captured.format.as_deref(), Some("m4a"));
    }

    #[test]
    fn capture_guard_cleans_up_on_drop() {
        let token = "stream-capture-test-drop".to_string();
        {
            let _guard = StreamCaptureGuard::new(token.clone());
            record_capture(
                &token,
                CapturedStream {
                    url: "https://stream.example.com/dropped.mp3".into(),
                    headers: BTreeMap::new(),
                    format: None,
                },
            );
            assert!(CAPTURES.lock().unwrap().contains_key(&token));
        }
        // Dropped: must be cleaned up
        assert!(!CAPTURES.lock().unwrap().contains_key(&token));
    }
}
