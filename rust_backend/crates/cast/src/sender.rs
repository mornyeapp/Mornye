//! A Cast v2 sender: TLS to the receiver's port 8009, the Default Media
//! Receiver launched on it, and media commands to that app. Status is kept
//! in the shape the Android plugin reports, so the app's player treats both
//! the same way.
//!
//! Receivers present self-signed certificates and senders without Google's
//! SDK do not run its device authentication, so the certificate is not
//! checked; the channel carries only media URLs, metadata and commands.

use crate::discovery::Device;
use crate::proto::{self, CONNECTION, HEARTBEAT, MEDIA, Message, RECEIVER};
use rustls::client::danger::{HandshakeSignatureValid, ServerCertVerified, ServerCertVerifier};
use rustls::crypto::{CryptoProvider, verify_tls12_signature, verify_tls13_signature};
use rustls::pki_types::{CertificateDer, ServerName, UnixTime};
use rustls::{DigitallySignedStruct, SignatureScheme};
use serde_json::{Value, json};
use std::collections::HashMap;
use std::io;
use std::net::SocketAddr;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use tokio::io::{AsyncReadExt, AsyncWriteExt, ReadHalf, WriteHalf};
use tokio::net::TcpStream;
use tokio::sync::{mpsc, oneshot};
use tokio_rustls::TlsConnector;
use tokio_rustls::client::TlsStream;

pub(crate) type Emit = Arc<dyn Fn(&str, Value) + Send + Sync>;

const DEFAULT_MEDIA_RECEIVER: &str = "CC1AD845";
const SENDER: &str = "sender-0";
const PLATFORM: &str = "receiver-0";
const CONNECT_TIMEOUT: Duration = Duration::from_secs(8);
const LAUNCH_TIMEOUT: Duration = Duration::from_secs(20);
const HEARTBEAT_INTERVAL: Duration = Duration::from_secs(5);
/// Receivers answer pings within seconds; silence this long is a lost link.
const SILENCE_LIMIT: Duration = Duration::from_secs(16);
/// How often position updates go out while playing, as on Android.
const PROGRESS_INTERVAL: Duration = Duration::from_millis(500);

/// Android's `MediaStatus` player states, which the app's player reads.
mod state {
    pub(super) const UNKNOWN: i64 = 0;
    pub(super) const IDLE: i64 = 1;
    pub(super) const PLAYING: i64 = 2;
    pub(super) const PAUSED: i64 = 3;
    pub(super) const BUFFERING: i64 = 4;
    pub(super) const LOADING: i64 = 5;
}

/// What the app knows about the session, shared with the service so state
/// and position answer without waiting on the connection.
#[derive(Default)]
pub(crate) struct Status {
    pub(crate) device: Option<Device>,
    pub(crate) connected: bool,
    pub(crate) revision: u64,
    volume: f64,
    media_session: Option<i64>,
    token: Option<i64>,
    current_time: f64,
    reported: Option<Instant>,
    duration: f64,
    player_state: i64,
    idle_reason: Option<String>,
}

impl Status {
    pub(crate) fn position_ms(&self) -> i64 {
        let mut seconds = self.current_time;
        if self.player_state == state::PLAYING
            && let Some(at) = self.reported
        {
            seconds += at.elapsed().as_secs_f64();
        }
        if self.duration > 0.0 {
            seconds = seconds.min(self.duration);
        }
        (seconds * 1000.0) as i64
    }

    pub(crate) fn snapshot(&self) -> Value {
        let Some(device) = self.device.as_ref().filter(|_| self.connected) else {
            return json!({"connected": false, "revision": self.revision});
        };
        json!({
            "connected": true,
            "deviceId": device.id,
            "revision": self.revision,
            "deviceName": device.name,
            "host": device.host.to_string(),
            "volume": self.volume,
            "token": self.token,
            "position": self.position_ms(),
            "duration": (self.duration * 1000.0) as i64,
            "state": self.player_state,
            "finished": self.idle_reason.as_deref() == Some("FINISHED"),
            "failed": self.idle_reason.as_deref() == Some("ERROR"),
        })
    }

    fn apply_media(&mut self, entry: &Value, token: Option<i64>) {
        let session = entry["mediaSessionId"].as_i64();
        if session != self.media_session {
            // A new item: nothing of the old one carries over.
            self.media_session = session;
            self.token = None;
            self.duration = 0.0;
        }
        if let Some(token) = token {
            self.token = Some(token);
        }
        let media = &entry["media"];
        if let Some(token) = media["customData"]["mornyeToken"].as_i64() {
            self.token = Some(token);
        }
        if let Some(duration) = media["duration"].as_f64().filter(|value| *value > 0.0) {
            self.duration = duration;
        }
        if let Some(time) = entry["currentTime"].as_f64() {
            self.current_time = time;
            self.reported = Some(Instant::now());
        }
        self.player_state = match entry["playerState"].as_str() {
            Some("IDLE") => state::IDLE,
            Some("PLAYING") => state::PLAYING,
            Some("PAUSED") => state::PAUSED,
            Some("BUFFERING") => state::BUFFERING,
            Some("LOADING") => state::LOADING,
            _ => state::UNKNOWN,
        };
        self.idle_reason = entry["idleReason"].as_str().map(str::to_owned);
    }
}

enum Command {
    Load(Value, i64, oneshot::Sender<Result<(), String>>),
    Media(&'static str, Value, oneshot::Sender<Result<(), String>>),
    Volume(f64, oneshot::Sender<Result<(), String>>),
    Disconnect(oneshot::Sender<Result<(), String>>),
}

/// A live session; dropping every clone ends the connection without
/// stopping the TV.
#[derive(Clone)]
pub(crate) struct Sender {
    commands: mpsc::UnboundedSender<Command>,
}

impl Sender {
    pub(crate) fn is_closed(&self) -> bool {
        self.commands.is_closed()
    }

    pub(crate) async fn load(&self, request: &Value) -> Result<(), String> {
        let text = |key: &str| request[key].as_str().unwrap_or_default();
        let url = request["url"].as_str().ok_or("load needs a url")?;
        let token = request["token"].as_i64().ok_or("load needs a token")?;
        let mut metadata = json!({
            "metadataType": 3,
            "title": text("title"),
            "artist": text("artist"),
            "albumName": text("album"),
        });
        if let Some(artwork) = request["artwork"].as_str() {
            metadata["images"] = json!([{"url": artwork}]);
        }
        let mut media = json!({
            "contentId": url,
            "contentUrl": url,
            "streamType": "BUFFERED",
            "contentType": request["mime"].as_str().ok_or("load needs a mime type")?,
            "metadata": metadata,
            "customData": {"mornyeToken": token},
        });
        if let Some(duration) = request["duration"].as_i64().filter(|ms| *ms > 0) {
            media["duration"] = json!(duration as f64 / 1000.0);
        }
        self.ask(|reply| Command::Load(media, token, reply)).await
    }

    pub(crate) async fn media(&self, kind: &'static str, extra: Value) -> Result<(), String> {
        self.ask(|reply| Command::Media(kind, extra, reply)).await
    }

    pub(crate) async fn volume(&self, level: f64) -> Result<(), String> {
        self.ask(|reply| Command::Volume(level.clamp(0.0, 1.0), reply))
            .await
    }

    pub(crate) async fn disconnect(&self) -> Result<(), String> {
        self.ask(Command::Disconnect).await
    }

    async fn ask(
        &self,
        command: impl FnOnce(oneshot::Sender<Result<(), String>>) -> Command,
    ) -> Result<(), String> {
        let (reply, answer) = oneshot::channel();
        self.commands
            .send(command(reply))
            .map_err(|_| "TV is disconnected".to_owned())?;
        match tokio::time::timeout(Duration::from_secs(25), answer).await {
            Ok(Ok(result)) => result,
            Ok(Err(_)) => Err("TV is disconnected".into()),
            Err(_) => Err("TV did not answer".into()),
        }
    }
}

/// Connects, launches the Default Media Receiver and starts the session.
pub(crate) async fn connect(
    device: Device,
    status: Arc<Mutex<Status>>,
    emit: Emit,
) -> Result<Sender, String> {
    let fail = |error: io::Error| format!("Could not reach {}: {error}", device.name);
    let mut link = tokio::time::timeout(CONNECT_TIMEOUT, Link::open(&device))
        .await
        .map_err(|_| format!("{} did not answer", device.name))?
        .map_err(fail)?;
    let (transport, session) = tokio::time::timeout(LAUNCH_TIMEOUT, link.launch())
        .await
        .map_err(|_| format!("{} did not start the player", device.name))??;
    link.send(&transport, CONNECTION, json!({"type": "CONNECT"}))
        .await
        .map_err(fail)?;
    let id = link.request_id();
    link.send(
        &transport,
        MEDIA,
        json!({"type": "GET_STATUS", "requestId": id}),
    )
    .await
    .map_err(fail)?;
    {
        let mut status = status.lock().expect("cast status");
        *status = Status {
            device: Some(device),
            connected: true,
            revision: status.revision + 1,
            volume: link.volume,
            ..Status::default()
        };
        emit("castStatus", status.snapshot());
    }
    let (commands, receiver) = mpsc::unbounded_channel();
    let actor = Actor {
        link,
        transport,
        session,
        status,
        emit,
        commands: receiver,
        pending: HashMap::new(),
        last_seen: Instant::now(),
    };
    tokio::spawn(actor.run());
    Ok(Sender { commands })
}

struct Link {
    writer: WriteHalf<TlsStream<TcpStream>>,
    incoming: mpsc::Receiver<Message>,
    next_request: i64,
    volume: f64,
}

impl Link {
    async fn open(device: &Device) -> io::Result<Self> {
        let stream = TcpStream::connect(SocketAddr::new(device.host, device.port)).await?;
        stream.set_nodelay(true)?;
        let provider = Arc::new(rustls::crypto::ring::default_provider());
        let config = rustls::ClientConfig::builder_with_provider(Arc::clone(&provider))
            .with_safe_default_protocol_versions()
            .map_err(io::Error::other)?
            .dangerous()
            .with_custom_certificate_verifier(Arc::new(AnyCertificate(provider)))
            .with_no_client_auth();
        let stream = TlsConnector::from(Arc::new(config))
            .connect(ServerName::IpAddress(device.host.into()), stream)
            .await?;
        let (reader, writer) = tokio::io::split(stream);
        let (frames, incoming) = mpsc::channel(64);
        tokio::spawn(read_frames(reader, frames));
        let mut link = Self {
            writer,
            incoming,
            next_request: 0,
            volume: 0.0,
        };
        link.send(PLATFORM, CONNECTION, json!({"type": "CONNECT"}))
            .await?;
        Ok(link)
    }

    fn request_id(&mut self) -> i64 {
        self.next_request += 1;
        self.next_request
    }

    async fn send(&mut self, destination: &str, namespace: &str, payload: Value) -> io::Result<()> {
        let frame = Message::new(SENDER, destination, namespace, payload.to_string()).encode();
        self.writer.write_all(&frame).await?;
        self.writer.flush().await
    }

    /// Launches the Default Media Receiver (joining it when it already runs)
    /// and answers its transport and session ids.
    async fn launch(&mut self) -> Result<(String, String), String> {
        let lost = |error: io::Error| format!("Connection lost: {error}");
        let id = self.request_id();
        self.send(
            PLATFORM,
            RECEIVER,
            json!({"type": "LAUNCH", "appId": DEFAULT_MEDIA_RECEIVER, "requestId": id}),
        )
        .await
        .map_err(lost)?;
        loop {
            let message = self
                .incoming
                .recv()
                .await
                .ok_or("The TV closed the connection")?;
            let payload: Value = serde_json::from_str(&message.payload).unwrap_or_default();
            match (message.namespace.as_str(), payload["type"].as_str()) {
                (HEARTBEAT, Some("PING")) => {
                    self.send(&message.source, HEARTBEAT, json!({"type": "PONG"}))
                        .await
                        .map_err(lost)?;
                }
                (RECEIVER, Some("RECEIVER_STATUS")) => {
                    if let Some(level) = payload["status"]["volume"]["level"].as_f64() {
                        self.volume = level;
                    }
                    if let Some(app) = running_app(&payload) {
                        return Ok(app);
                    }
                }
                (RECEIVER, Some("LAUNCH_ERROR" | "INVALID_REQUEST")) => {
                    return Err(format!(
                        "The TV could not start the player ({})",
                        payload["reason"].as_str().unwrap_or("unknown reason")
                    ));
                }
                _ => {}
            }
        }
    }
}

/// The Default Media Receiver's (transport id, session id), when running.
fn running_app(receiver_status: &Value) -> Option<(String, String)> {
    receiver_status["status"]["applications"]
        .as_array()?
        .iter()
        .find(|app| app["appId"] == DEFAULT_MEDIA_RECEIVER)
        .and_then(|app| {
            Some((
                app["transportId"].as_str()?.to_owned(),
                app["sessionId"].as_str()?.to_owned(),
            ))
        })
}

async fn read_frames(mut reader: ReadHalf<TlsStream<TcpStream>>, frames: mpsc::Sender<Message>) {
    let mut length = [0u8; 4];
    loop {
        if reader.read_exact(&mut length).await.is_err() {
            return;
        }
        let len = u32::from_be_bytes(length) as usize;
        if len > proto::MAX_FRAME {
            return;
        }
        let mut body = vec![0u8; len];
        if reader.read_exact(&mut body).await.is_err() {
            return;
        }
        let Ok(message) = Message::decode(&body) else {
            return;
        };
        if frames.send(message).await.is_err() {
            return;
        }
    }
}

struct Pending {
    reply: oneshot::Sender<Result<(), String>>,
    /// The item a `LOAD` starts, assigned to the media session it creates.
    token: Option<i64>,
}

struct Actor {
    link: Link,
    transport: String,
    session: String,
    status: Arc<Mutex<Status>>,
    emit: Emit,
    commands: mpsc::UnboundedReceiver<Command>,
    pending: HashMap<i64, Pending>,
    last_seen: Instant,
}

enum Flow {
    Continue,
    End,
}

impl Actor {
    async fn run(mut self) {
        let mut heartbeat = tokio::time::interval(HEARTBEAT_INTERVAL);
        let mut progress = tokio::time::interval(PROGRESS_INTERVAL);
        loop {
            let flow = tokio::select! {
                message = self.link.incoming.recv() => match message {
                    Some(message) => self.receive(message).await,
                    None => Flow::End,
                },
                command = self.commands.recv() => match command {
                    Some(command) => self.command(command).await,
                    None => Flow::End,
                },
                _ = heartbeat.tick() => {
                    if self.last_seen.elapsed() > SILENCE_LIMIT {
                        Flow::End
                    } else {
                        self.send(PLATFORM, HEARTBEAT, json!({"type": "PING"})).await
                    }
                }
                _ = progress.tick() => {
                    let status = self.status.lock().expect("cast status");
                    if status.player_state == state::PLAYING {
                        (self.emit)("castStatus", status.snapshot());
                    }
                    Flow::Continue
                }
            };
            if matches!(flow, Flow::End) {
                break;
            }
        }
        for (_, pending) in self.pending.drain() {
            let _ = pending.reply.send(Err("TV is disconnected".into()));
        }
        let mut status = self.status.lock().expect("cast status");
        status.connected = false;
        (self.emit)("castStatus", status.snapshot());
    }

    async fn send(&mut self, destination: &str, namespace: &str, payload: Value) -> Flow {
        match self.link.send(destination, namespace, payload).await {
            Ok(()) => Flow::Continue,
            Err(_) => Flow::End,
        }
    }

    async fn request(
        &mut self,
        namespace: &str,
        mut payload: Value,
        reply: oneshot::Sender<Result<(), String>>,
        token: Option<i64>,
    ) -> Flow {
        let id = self.link.request_id();
        payload["requestId"] = json!(id);
        let destination = if namespace == MEDIA {
            self.transport.clone()
        } else {
            PLATFORM.to_owned()
        };
        self.pending.insert(id, Pending { reply, token });
        self.send(&destination, namespace, payload).await
    }

    async fn command(&mut self, command: Command) -> Flow {
        match command {
            Command::Load(media, token, reply) => {
                let payload = json!({
                    "type": "LOAD",
                    "sessionId": self.session,
                    "media": media,
                    "autoplay": false,
                    "currentTime": 0,
                });
                self.request(MEDIA, payload, reply, Some(token)).await
            }
            Command::Media(kind, extra, reply) => {
                let session = self.status.lock().expect("cast status").media_session;
                let Some(session) = session else {
                    let _ = reply.send(Err("Nothing is loaded on the TV".into()));
                    return Flow::Continue;
                };
                let mut payload = json!({"type": kind, "mediaSessionId": session});
                if let (Some(payload), Some(extra)) = (payload.as_object_mut(), extra.as_object()) {
                    payload.extend(extra.clone());
                }
                self.request(MEDIA, payload, reply, None).await
            }
            Command::Volume(level, reply) => {
                let payload = json!({"type": "SET_VOLUME", "volume": {"level": level}});
                self.request(RECEIVER, payload, reply, None).await
            }
            Command::Disconnect(reply) => {
                // Stop the player on the TV, as Android's endCurrentSession(true).
                let stop = json!({"type": "STOP", "sessionId": self.session, "requestId": 0});
                let _ = self.link.send(PLATFORM, RECEIVER, stop).await;
                let close = json!({"type": "CLOSE"});
                let transport = self.transport.clone();
                let _ = self.link.send(&transport, CONNECTION, close.clone()).await;
                let _ = self.link.send(PLATFORM, CONNECTION, close).await;
                let _ = reply.send(Ok(()));
                Flow::End
            }
        }
    }

    async fn receive(&mut self, message: Message) -> Flow {
        self.last_seen = Instant::now();
        let payload: Value = serde_json::from_str(&message.payload).unwrap_or_default();
        let kind = payload["type"].as_str().unwrap_or_default();
        let request = payload["requestId"].as_i64().filter(|id| *id != 0);
        match message.namespace.as_str() {
            HEARTBEAT if kind == "PING" => {
                return self
                    .send(&message.source, HEARTBEAT, json!({"type": "PONG"}))
                    .await;
            }
            CONNECTION if kind == "CLOSE" => {
                if message.source == self.transport || message.source == PLATFORM {
                    return Flow::End;
                }
            }
            RECEIVER if kind == "RECEIVER_STATUS" => {
                // Another app took the TV, or the player was stopped there.
                if running_app(&payload).is_none_or(|(_, session)| session != self.session) {
                    return Flow::End;
                }
                let mut status = self.status.lock().expect("cast status");
                if let Some(level) = payload["status"]["volume"]["level"].as_f64() {
                    status.volume = level;
                }
                (self.emit)("castStatus", status.snapshot());
                drop(status);
                self.answer(request, Ok(()));
            }
            MEDIA if kind == "MEDIA_STATUS" => {
                let token = request
                    .and_then(|id| self.pending.get(&id))
                    .and_then(|pending| pending.token);
                let mut status = self.status.lock().expect("cast status");
                match payload["status"]
                    .as_array()
                    .and_then(|entries| entries.first())
                {
                    Some(entry) => status.apply_media(entry, token),
                    None => {
                        status.player_state = state::IDLE;
                        status.media_session = None;
                    }
                }
                (self.emit)("castStatus", status.snapshot());
                drop(status);
                self.answer(request, Ok(()));
            }
            RECEIVER | MEDIA => {
                if matches!(
                    kind,
                    "LOAD_FAILED"
                        | "LOAD_CANCELLED"
                        | "INVALID_REQUEST"
                        | "INVALID_PLAYER_STATE"
                        | "LAUNCH_ERROR"
                        | "ERROR"
                ) {
                    if kind == "LOAD_FAILED" {
                        let mut snapshot = self.status.lock().expect("cast status").snapshot();
                        snapshot["error"] = json!("Cast receiver could not play this file");
                        (self.emit)("castStatus", snapshot);
                    }
                    self.answer(request, Err(format!("TV rejected the request ({kind})")));
                }
            }
            _ => {}
        }
        Flow::Continue
    }

    fn answer(&mut self, request: Option<i64>, result: Result<(), String>) {
        if let Some(pending) = request.and_then(|id| self.pending.remove(&id)) {
            let _ = pending.reply.send(result);
        }
    }
}

#[derive(Debug)]
struct AnyCertificate(Arc<CryptoProvider>);

impl ServerCertVerifier for AnyCertificate {
    fn verify_server_cert(
        &self,
        _end_entity: &CertificateDer<'_>,
        _intermediates: &[CertificateDer<'_>],
        _server_name: &ServerName<'_>,
        _ocsp_response: &[u8],
        _now: UnixTime,
    ) -> Result<ServerCertVerified, rustls::Error> {
        Ok(ServerCertVerified::assertion())
    }

    fn verify_tls12_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        dss: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, rustls::Error> {
        verify_tls12_signature(
            message,
            cert,
            dss,
            &self.0.signature_verification_algorithms,
        )
    }

    fn verify_tls13_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        dss: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, rustls::Error> {
        verify_tls13_signature(
            message,
            cert,
            dss,
            &self.0.signature_verification_algorithms,
        )
    }

    fn supported_verify_schemes(&self) -> Vec<SignatureScheme> {
        self.0.signature_verification_algorithms.supported_schemes()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn device() -> Device {
        Device {
            id: "device-1".into(),
            name: "Living Room".into(),
            model: "Speaker".into(),
            host: "192.0.2.10".parse().unwrap(),
            port: 8009,
        }
    }

    #[test]
    fn snapshots_use_the_android_status_shape() {
        let mut status = Status {
            device: Some(device()),
            connected: true,
            revision: 2,
            volume: 0.4,
            ..Status::default()
        };
        status.apply_media(
            &json!({
                "mediaSessionId": 7,
                "playerState": "PAUSED",
                "currentTime": 12.5,
                "media": {"duration": 200.0, "customData": {"mornyeToken": 9}},
            }),
            None,
        );
        let snapshot = status.snapshot();
        assert_eq!(snapshot["state"], 3);
        assert_eq!(snapshot["token"], 9);
        assert_eq!(snapshot["position"], 12_500);
        assert_eq!(snapshot["duration"], 200_000);
        assert_eq!(snapshot["host"], "192.0.2.10");
        assert_eq!(snapshot["finished"], false);
    }

    #[test]
    fn a_partial_status_keeps_the_items_token_until_the_session_changes() {
        let mut status = Status::default();
        status.apply_media(
            &json!({"mediaSessionId": 1, "playerState": "BUFFERING"}),
            Some(4),
        );
        status.apply_media(
            &json!({"mediaSessionId": 1, "playerState": "IDLE", "idleReason": "FINISHED"}),
            None,
        );
        assert_eq!(status.token, Some(4));
        assert_eq!(status.idle_reason.as_deref(), Some("FINISHED"));
        status.apply_media(
            &json!({"mediaSessionId": 2, "playerState": "PLAYING"}),
            None,
        );
        assert_eq!(status.token, None);
    }

    #[test]
    fn disconnected_snapshots_carry_only_the_revision() {
        let status = Status {
            device: Some(device()),
            revision: 3,
            ..Status::default()
        };
        assert_eq!(
            status.snapshot(),
            json!({"connected": false, "revision": 3})
        );
    }
}
