//! Types shared by the server core (L1a) and the Subsonic layer (L1b). The
//! contract is `docs/internal/desktop/LINK_CONTRACT.md`; change these only by
//! agreement of both units.

use crate::catalog::Catalog;
use bytes::Bytes;
use futures_util::future::BoxFuture;
use http_body_util::{BodyExt, Full, combinators::BoxBody};
use serde_json::Value;
use std::path::PathBuf;
use std::sync::{Arc, RwLock};

/// Response body: a complete buffer or a stream (files, transcodes).
pub type Body = BoxBody<Bytes, std::io::Error>;
pub type HttpResponse = http::Response<Body>;

/// A complete response body.
pub fn full(bytes: impl Into<Bytes>) -> Body {
    Full::new(bytes.into())
        .map_err(|never| match never {})
        .boxed()
}

/// A complete response with `status`, `content_type` and `body`.
pub fn respond(status: u16, content_type: &str, body: impl Into<Bytes>) -> HttpResponse {
    http::Response::builder()
        .status(status)
        .header(http::header::CONTENT_TYPE, content_type)
        .body(full(body))
        .unwrap_or_else(|_| http::Response::new(full(Bytes::new())))
}

/// A JSON response.
pub fn json(status: u16, value: &Value) -> HttpResponse {
    respond(status, "application/json", value.to_string())
}

/// Why the app (Dart) could not answer a forwarded request.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HostError {
    /// `invalid`, `not_found`, `unavailable`, `timeout` or any other code.
    pub code: String,
    pub message: String,
}

impl HostError {
    pub fn new(code: &str, message: impl Into<String>) -> Self {
        Self {
            code: code.to_owned(),
            message: message.into(),
        }
    }

    /// The HTTP status for `/mornye/v1` replies (contract section 6).
    pub fn http_status(&self) -> u16 {
        match self.code.as_str() {
            "invalid" => 400,
            "not_found" => 404,
            "unavailable" => 503,
            "timeout" => 504,
            _ => 500,
        }
    }
}

/// The app side of the bridge. On desktop it is implemented by
/// `mornye-desktop` over the FFI callback (`linkRequest` inbound calls answered
/// by `linkReply`); tests use an in-memory fake.
pub trait Host: Send + Sync + 'static {
    /// Forwards `op` for `device_id` and resolves with the app's JSON reply.
    fn request(
        &self,
        op: &str,
        device_id: &str,
        args: Value,
    ) -> BoxFuture<'static, Result<Value, HostError>>;

    /// A fire-and-forget inbound call (`linkMessage`, `linkClients`,
    /// `linkPaired`, `linkPairingEnded`).
    fn event(&self, method: &str, args: Value);
}

/// Server settings fixed at start.
#[derive(Debug, Clone)]
pub struct LinkConfig {
    /// `<app_support_dir>/link`: certificate, key, `server.json`, `devices.json`.
    pub state_dir: PathBuf,
    /// Scratch space, for example the resized cover cache.
    pub temp_dir: PathBuf,
    /// Shown to phones and advertised over mDNS.
    pub name: String,
    /// Preferred port; 0 uses the persisted port or the default range.
    pub port: u16,
    pub ffmpeg_path: Option<PathBuf>,
    pub app_version: String,
}

/// An authenticated client.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Device {
    pub device_id: String,
    pub name: String,
    /// `android`, `ios`, `macos`, `windows`, `linux` or `subsonic`.
    pub platform: String,
}

/// What the Subsonic layer needs from the running server.
pub struct Shared {
    pub config: LinkConfig,
    pub server_id: String,
    pub host: Arc<dyn Host>,
    /// Replaced as a whole by `linkSetCatalog`.
    pub catalog: RwLock<Arc<Catalog>>,
}

impl Shared {
    /// The current catalog snapshot.
    pub fn catalog(&self) -> Arc<Catalog> {
        match self.catalog.read() {
            Ok(guard) => Arc::clone(&guard),
            Err(poisoned) => Arc::clone(&poisoned.into_inner()),
        }
    }
}

/// One Subsonic call after authentication.
pub struct SubsonicRequest {
    /// Method name without `.view`, for example `getAlbum`.
    pub method: String,
    /// Query parameters merged with a form-urlencoded body, in order.
    pub params: Vec<(String, String)>,
    /// Request headers (`Range`, `If-None-Match`).
    pub headers: http::HeaderMap,
    pub device: Device,
}

impl SubsonicRequest {
    /// The first value of `name`.
    pub fn param(&self, name: &str) -> Option<&str> {
        param(&self.params, name)
    }

    /// Every value of `name` (`id` repeats in `star`, `createPlaylist`).
    pub fn params_all(&self, name: &str) -> Vec<&str> {
        self.params
            .iter()
            .filter(|(key, _)| key == name)
            .map(|(_, value)| value.as_str())
            .collect()
    }
}

/// The first value of `name` in `params`.
pub fn param<'a>(params: &'a [(String, String)], name: &str) -> Option<&'a str> {
    params
        .iter()
        .find(|(key, _)| key == name)
        .map(|(_, value)| value.as_str())
}
