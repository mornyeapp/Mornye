//! The push channel (contract section 7): `GET /mornye/v1/ws` with a Bearer
//! key, JSON text frames. The first client frame must be `hello` for the
//! key's device (else close 4401); the server answers `welcome`, reports the
//! client list as `linkClients`, forwards later frames as `linkMessage`,
//! checks for silence every 20 s, pings after 20 s without a client frame,
//! and drops clients silent for 60 s. One connection per device: a newer one
//! replaces the older (close 4409).

use crate::server::State;
use crate::store::{DeviceRecord, now_ms};
use crate::types::{HttpResponse, full, json};
use bytes::Bytes;
use futures_util::{SinkExt, StreamExt};
use http::header;
use hyper::body::Incoming;
use hyper_util::rt::TokioIo;
use serde::Serialize;
use serde_json::{Value, json as object};
use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tokio::sync::{mpsc, watch};
use tokio::time::Instant;
use tokio_tungstenite::WebSocketStream;
use tokio_tungstenite::tungstenite::Message;
use tokio_tungstenite::tungstenite::handshake::derive_accept_key;
use tokio_tungstenite::tungstenite::protocol::frame::CloseFrame;
use tokio_tungstenite::tungstenite::protocol::{Role, WebSocketConfig};

/// The key's device did not say `hello`, or was revoked.
pub(crate) const CLOSE_UNAUTHORIZED: u16 = 4401;
/// A newer connection from the same device took over.
pub(crate) const CLOSE_REPLACED: u16 = 4409;
/// The server is stopping, or the client went silent.
const CLOSE_GOING_AWAY: u16 = 1001;
/// Same limit as request bodies.
const MAX_MESSAGE: usize = crate::server::MAX_BODY;
/// Bound tiny pushes by count and larger pushes by their combined bytes.
const MAX_OUTGOING: usize = 64;
/// How long sending a close frame may take before the socket is dropped.
const CLOSE_TIMEOUT: Duration = Duration::from_secs(2);

/// `ClientInfo` in `linkStatus` and `linkClients`.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct ClientInfo {
    pub(crate) device_id: String,
    pub(crate) name: String,
    pub(crate) platform: String,
    pub(crate) app_version: String,
    pub(crate) connected_ms: i64,
}

type CloseReason = (u16, &'static str);

struct Client {
    id: u64,
    info: ClientInfo,
    sender: mpsc::Sender<String>,
    pending_bytes: Arc<AtomicUsize>,
    closing: watch::Sender<Option<CloseReason>>,
}

/// The open WebSocket connections, one per device.
#[derive(Default)]
pub(crate) struct Clients {
    by_device: Mutex<HashMap<String, Client>>,
    next_id: AtomicU64,
}

impl Clients {
    /// Registers a connection; an older one for the same device is closed.
    fn insert(
        &self,
        info: ClientInfo,
        sender: mpsc::Sender<String>,
        pending_bytes: Arc<AtomicUsize>,
        closing: watch::Sender<Option<CloseReason>>,
    ) -> u64 {
        let id = self.next_id.fetch_add(1, Ordering::Relaxed) + 1;
        let client = Client {
            id,
            info: info.clone(),
            sender,
            pending_bytes,
            closing,
        };
        let replaced = self
            .by_device
            .lock()
            .expect("link clients")
            .insert(info.device_id, client);
        if let Some(replaced) = replaced {
            let _ = replaced.closing.send(Some((CLOSE_REPLACED, "replaced")));
        }
        id
    }

    /// Unregisters connection `id`. Returns false when it was already gone
    /// (replaced or closed).
    fn remove(&self, device_id: &str, id: u64) -> bool {
        let mut clients = self.by_device.lock().expect("link clients");
        if clients.get(device_id).is_some_and(|client| client.id == id) {
            clients.remove(device_id);
            return true;
        }
        false
    }

    /// Connected clients, oldest first.
    pub(crate) fn list(&self) -> Vec<ClientInfo> {
        let mut clients: Vec<ClientInfo> = self
            .by_device
            .lock()
            .expect("link clients")
            .values()
            .map(|client| client.info.clone())
            .collect();
        clients.sort_by(|a, b| (a.connected_ms, &a.device_id).cmp(&(b.connected_ms, &b.device_id)));
        clients
    }

    pub(crate) fn is_connected(&self, device_id: &str) -> bool {
        self.by_device
            .lock()
            .expect("link clients")
            .contains_key(device_id)
    }

    /// Queues `text` for `device_id`, or every client. Returns how many
    /// clients it was queued for.
    pub(crate) fn send(&self, device_id: Option<&str>, text: &str) -> usize {
        let clients = self.by_device.lock().expect("link clients");
        let mut queued = 0;
        for client in clients.values() {
            if device_id.is_some_and(|id| client.info.device_id != id)
                || client.closing.borrow().is_some()
            {
                continue;
            }
            let pending = client.pending_bytes.load(Ordering::Relaxed);
            if text.len() > MAX_MESSAGE.saturating_sub(pending) {
                let _ = client.closing.send(Some((CLOSE_GOING_AWAY, "slow client")));
                continue;
            }
            client
                .pending_bytes
                .fetch_add(text.len(), Ordering::Relaxed);
            if client.sender.try_send(text.to_owned()).is_ok() {
                queued += 1;
            } else {
                client
                    .pending_bytes
                    .fetch_sub(text.len(), Ordering::Relaxed);
                let _ = client.closing.send(Some((CLOSE_GOING_AWAY, "slow client")));
            }
        }
        queued
    }

    /// Closes and unregisters `device_id`'s connection. Returns whether one
    /// was open.
    pub(crate) fn close(&self, device_id: &str, code: u16, reason: &'static str) -> bool {
        let client = self
            .by_device
            .lock()
            .expect("link clients")
            .remove(device_id);
        if let Some(client) = client {
            let _ = client.closing.send(Some((code, reason)));
            return true;
        }
        false
    }

    /// Closes every connection (server stop).
    pub(crate) fn close_all(&self) {
        let clients: Vec<Client> = self
            .by_device
            .lock()
            .expect("link clients")
            .drain()
            .map(|(_, client)| client)
            .collect();
        for client in clients {
            let _ = client
                .closing
                .send(Some((CLOSE_GOING_AWAY, "server stopping")));
        }
    }
}

/// Answers `GET /mornye/v1/ws` for an authenticated device: `101` now, the
/// session on its own task once hyper hands over the connection.
pub(crate) fn upgrade(
    state: &Arc<State>,
    device: DeviceRecord,
    mut request: http::Request<Incoming>,
) -> HttpResponse {
    let headers = request.headers();
    let has_token = |name: header::HeaderName, token: &str| {
        headers.get_all(name).iter().any(|value| {
            value.to_str().is_ok_and(|value| {
                value
                    .split(',')
                    .any(|part| part.trim().eq_ignore_ascii_case(token))
            })
        })
    };
    let key = headers
        .get(header::SEC_WEBSOCKET_KEY)
        .map(|key| key.as_bytes().to_vec());
    let version_ok = headers
        .get(header::SEC_WEBSOCKET_VERSION)
        .is_some_and(|version| version.as_bytes() == b"13");
    let (Some(key), true, true, true) = (
        key,
        version_ok,
        has_token(header::CONNECTION, "upgrade"),
        has_token(header::UPGRADE, "websocket"),
    ) else {
        return json(
            400,
            &object!({"error": "invalid", "message": "WebSocket upgrade required"}),
        );
    };
    let on_upgrade = hyper::upgrade::on(&mut request);
    let session_state = Arc::clone(state);
    state.tasks.spawn(async move {
        if let Ok(upgraded) = on_upgrade.await {
            session(session_state, device, TokioIo::new(upgraded)).await;
        }
    });
    http::Response::builder()
        .status(101)
        .header(header::CONNECTION, "Upgrade")
        .header(header::UPGRADE, "websocket")
        .header(header::SEC_WEBSOCKET_ACCEPT, derive_accept_key(&key))
        .body(full(Bytes::new()))
        .unwrap_or_else(|_| json(500, &object!({"error": "internal"})))
}

async fn session<S>(state: Arc<State>, device: DeviceRecord, io: S)
where
    S: tokio::io::AsyncRead + tokio::io::AsyncWrite + Unpin,
{
    let config = WebSocketConfig::default()
        .max_message_size(Some(MAX_MESSAGE))
        .max_frame_size(Some(MAX_MESSAGE));
    let mut socket = WebSocketStream::from_raw_socket(io, Role::Server, Some(config)).await;
    let hello = tokio::select! {
        _ = state.shutdown.cancelled() => return,
        hello = tokio::time::timeout(state.tuning.idle_timeout, first_text(&mut socket)) => {
            hello.ok().flatten()
        }
    };
    let Some(info) = hello.and_then(|text| parse_hello(&text, &device)) else {
        close(&mut socket, CLOSE_UNAUTHORIZED, "hello required").await;
        return;
    };
    let device_id = device.device_id;
    let (sender, mut outgoing) = mpsc::channel(MAX_OUTGOING);
    let pending_bytes = Arc::new(AtomicUsize::new(0));
    let (closing, mut closed) = watch::channel(None);
    let id = state
        .clients
        .insert(info, sender, Arc::clone(&pending_bytes), closing);
    let welcome = object!({
        "type": "welcome",
        "serverId": state.shared.server_id,
        "name": state.name(),
        "protocol": 1,
    });
    // Keep disconnects outside the write loop so even a blocked welcome,
    // push or ping can be interrupted. Close signals bypass the text queue.
    let reason = tokio::select! {
        biased;
        _ = state.shutdown.cancelled() => Some((CLOSE_GOING_AWAY, "server stopping")),
        _ = closed.changed() => *closed.borrow(),
        reason = async {
            let timeout = state.tuning.idle_timeout;
            if !send(&mut socket, Message::Text(welcome.to_string().into()), timeout).await {
                return None;
            }
            state.store.touch(&device_id);
            state.emit_clients();

            let period = state.tuning.ping_interval;
            let mut ping = tokio::time::interval_at(Instant::now() + period, period);
            let mut last_heard = Instant::now();
            loop {
                tokio::select! {
                    message = outgoing.recv() => match message {
                        Some(text) => {
                            pending_bytes.fetch_sub(text.len(), Ordering::Relaxed);
                            if !send(&mut socket, Message::Text(text.into()), timeout).await {
                                return None;
                            }
                        }
                        None => return None,
                    },
                    message = socket.next() => match message {
                        Some(Ok(message)) => {
                            last_heard = Instant::now();
                            match message {
                                Message::Text(text) => forward(&state, &device_id, text.as_str()),
                                Message::Close(_) => {
                                    // Sends the close reply tungstenite queued.
                                    let _ = tokio::time::timeout(CLOSE_TIMEOUT, socket.flush()).await;
                                    return None;
                                }
                                // Pings are answered by tungstenite; binary is unused.
                                _ => {}
                            }
                        }
                        Some(Err(_)) | None => return None,
                    },
                    _ = ping.tick() => {
                        let silence = last_heard.elapsed();
                        if silence >= timeout {
                            return Some((CLOSE_GOING_AWAY, "idle"));
                        }
                        if silence >= period
                            && !send(&mut socket, Message::Ping(Bytes::new()), timeout).await
                        {
                            return None;
                        }
                    }
                }
            }
        } => reason,
    };
    if let Some((code, reason)) = reason {
        close(&mut socket, code, reason).await;
    }
    if state.clients.remove(&device_id, id) {
        state.emit_clients();
    }
}

/// A client that stops reading must not retain its session indefinitely.
async fn send<S>(socket: &mut WebSocketStream<S>, message: Message, timeout: Duration) -> bool
where
    S: tokio::io::AsyncRead + tokio::io::AsyncWrite + Unpin,
{
    tokio::time::timeout(timeout, socket.send(message))
        .await
        .is_ok_and(|result| result.is_ok())
}

/// The first text frame, skipping control frames.
async fn first_text<S>(socket: &mut WebSocketStream<S>) -> Option<String>
where
    S: tokio::io::AsyncRead + tokio::io::AsyncWrite + Unpin,
{
    while let Some(message) = socket.next().await {
        match message.ok()? {
            Message::Text(text) => return Some(text.as_str().to_owned()),
            Message::Ping(_) | Message::Pong(_) => {}
            _ => return None,
        }
    }
    None
}

/// The client described by a valid `hello` for `device`.
fn parse_hello(text: &str, device: &DeviceRecord) -> Option<ClientInfo> {
    let hello: Value = serde_json::from_str(text).ok()?;
    if hello.get("type").and_then(Value::as_str) != Some("hello")
        || hello.get("deviceId").and_then(Value::as_str) != Some(device.device_id.as_str())
    {
        return None;
    }
    let field = |key: &str, fallback: &str| {
        hello
            .get(key)
            .and_then(Value::as_str)
            .filter(|value| !value.is_empty())
            .unwrap_or(fallback)
            .to_owned()
    };
    Some(ClientInfo {
        device_id: device.device_id.clone(),
        name: field("name", &device.name),
        platform: field("platform", &device.platform),
        app_version: field("appVersion", ""),
        connected_ms: now_ms(),
    })
}

/// Hands a client frame to the app as `linkMessage`. Frames that are not
/// JSON, and repeated `hello` frames, are dropped.
fn forward(state: &State, device_id: &str, text: &str) {
    let Ok(message) = serde_json::from_str::<Value>(text) else {
        return;
    };
    if message.get("type").and_then(Value::as_str) == Some("hello") {
        return;
    }
    state.store.touch(device_id);
    state.shared.host.event(
        "linkMessage",
        object!({"deviceId": device_id, "message": message}),
    );
}

async fn close<S>(socket: &mut WebSocketStream<S>, code: u16, reason: &'static str)
where
    S: tokio::io::AsyncRead + tokio::io::AsyncWrite + Unpin,
{
    let frame = CloseFrame {
        code: code.into(),
        reason: reason.into(),
    };
    let _ = tokio::time::timeout(CLOSE_TIMEOUT, socket.close(Some(frame))).await;
}

#[cfg(test)]
mod tests;
