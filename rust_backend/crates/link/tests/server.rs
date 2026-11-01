//! End-to-end tests of the server core over loopback TLS, with a fake app
//! and a client that pins the certificate fingerprint: pairing, Bearer and
//! Subsonic authentication, forwarding, WebSocket sessions, the port policy
//! and the persisted identity.

use bytes::Bytes;
use futures_util::future::BoxFuture;
use futures_util::{SinkExt, StreamExt};
use hmac::{Hmac, KeyInit, Mac};
use http_body_util::{BodyExt, Full, StreamBody};
use hyper::body::Frame;
use hyper_util::rt::TokioIo;
use mornye_link::{Host, HostError, LinkConfig, LinkServer, Tuning};
use rustls::client::danger::{HandshakeSignatureValid, ServerCertVerified, ServerCertVerifier};
use rustls::crypto::CryptoProvider;
use rustls::pki_types::{CertificateDer, ServerName, UnixTime};
use rustls::{DigitallySignedStruct, SignatureScheme};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::convert::Infallible;
use std::future::Future;
use std::net::{IpAddr, Ipv4Addr};
use std::sync::{Arc, Condvar, Mutex};
use std::time::{Duration, Instant};
use tokio::net::TcpStream;
use tokio_rustls::TlsConnector;
use tokio_rustls::client::TlsStream;
use tokio_tungstenite::WebSocketStream;
use tokio_tungstenite::tungstenite::Message;
use tokio_tungstenite::tungstenite::client::IntoClientRequest;

type Socket = WebSocketStream<TlsStream<TcpStream>>;

const WAIT: Duration = Duration::from_secs(5);

/// Records events and answers requests by `op`: `slow` never answers,
/// `missing` and `broken` fail, anything else echoes its arguments.
#[derive(Default)]
struct FakeHost {
    events: Mutex<Vec<(String, Value)>>,
    requests: Mutex<Vec<(String, String, Value)>>,
    changed: Condvar,
}

impl Host for FakeHost {
    fn request(
        &self,
        op: &str,
        device_id: &str,
        args: Value,
    ) -> BoxFuture<'static, Result<Value, HostError>> {
        self.requests
            .lock()
            .unwrap()
            .push((op.to_owned(), device_id.to_owned(), args.clone()));
        let reply = match op {
            "slow" => None,
            "missing" => Some(Err(HostError::new("not_found", "No such item"))),
            "broken" => Some(Err(HostError::new("weird", "Something broke"))),
            _ => Some(Ok(json!({"op": op, "args": args}))),
        };
        Box::pin(async move {
            match reply {
                Some(reply) => reply,
                None => std::future::pending().await,
            }
        })
    }

    fn event(&self, method: &str, args: Value) {
        self.events.lock().unwrap().push((method.to_owned(), args));
        self.changed.notify_all();
    }
}

impl FakeHost {
    fn events(&self, method: &str) -> Vec<Value> {
        self.events
            .lock()
            .unwrap()
            .iter()
            .filter(|(name, _)| name == method)
            .map(|(_, args)| args.clone())
            .collect()
    }

    /// Waits for the `number`-th event named `method` (1-based).
    fn wait_event(&self, method: &str, number: usize) -> Value {
        let deadline = Instant::now() + WAIT;
        let mut events = self.events.lock().unwrap();
        loop {
            let matching: Vec<&Value> = events
                .iter()
                .filter(|(name, _)| name == method)
                .map(|(_, args)| args)
                .collect();
            if matching.len() >= number {
                return matching[number - 1].clone();
            }
            let now = Instant::now();
            assert!(now < deadline, "no {method} event #{number}: {events:?}");
            events = self.changed.wait_timeout(events, deadline - now).unwrap().0;
        }
    }
}

/// Accepts exactly the certificate whose SHA-256 is `fingerprint`, as the
/// phone does.
#[derive(Debug)]
struct Pinned {
    fingerprint: String,
    provider: Arc<CryptoProvider>,
}

impl ServerCertVerifier for Pinned {
    fn verify_server_cert(
        &self,
        end_entity: &CertificateDer<'_>,
        _intermediates: &[CertificateDer<'_>],
        _server_name: &ServerName<'_>,
        _ocsp_response: &[u8],
        _now: UnixTime,
    ) -> Result<ServerCertVerified, rustls::Error> {
        if hex(&Sha256::digest(end_entity.as_ref())) == self.fingerprint {
            Ok(ServerCertVerified::assertion())
        } else {
            Err(rustls::Error::General("fingerprint mismatch".into()))
        }
    }

    fn verify_tls12_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        dss: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, rustls::Error> {
        rustls::crypto::verify_tls12_signature(
            message,
            cert,
            dss,
            &self.provider.signature_verification_algorithms,
        )
    }

    fn verify_tls13_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        dss: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, rustls::Error> {
        rustls::crypto::verify_tls13_signature(
            message,
            cert,
            dss,
            &self.provider.signature_verification_algorithms,
        )
    }

    fn supported_verify_schemes(&self) -> Vec<SignatureScheme> {
        self.provider
            .signature_verification_algorithms
            .supported_schemes()
    }
}

struct Response {
    status: u16,
    body: Bytes,
}

impl Response {
    fn json(&self) -> Value {
        serde_json::from_slice(&self.body)
            .unwrap_or_else(|_| panic!("not JSON: {}", String::from_utf8_lossy(&self.body)))
    }

    fn text(&self) -> String {
        String::from_utf8_lossy(&self.body).into_owned()
    }
}

/// A server in a temporary state folder, bound to loopback, plus a client
/// runtime. Starting and stopping happen outside the client runtime.
struct Fixture {
    dir: tempfile::TempDir,
    host: Arc<FakeHost>,
    tuning: Tuning,
    server: Option<LinkServer>,
    client: tokio::runtime::Runtime,
}

fn test_tuning() -> Tuning {
    Tuning {
        request_timeout: Duration::from_millis(300),
        pair_interval: Duration::ZERO,
        bind: Some(IpAddr::V4(Ipv4Addr::LOCALHOST)),
        advertise: false,
        ..Tuning::default()
    }
}

impl Fixture {
    fn new() -> Self {
        Self::with(test_tuning())
    }

    fn with(tuning: Tuning) -> Self {
        let mut fixture = Self::idle(tuning);
        fixture.start(free_port());
        fixture
    }

    fn idle(tuning: Tuning) -> Self {
        Self {
            dir: tempfile::tempdir().unwrap(),
            host: Arc::default(),
            tuning,
            server: None,
            client: tokio::runtime::Builder::new_current_thread()
                .enable_all()
                .build()
                .unwrap(),
        }
    }

    fn start(&mut self, port: u16) {
        let config = LinkConfig {
            state_dir: self.dir.path().join("link"),
            temp_dir: self.dir.path().join("temp"),
            name: "  Test Desk ".to_owned(),
            port,
            ffmpeg_path: None,
            app_version: "9.9.9".to_owned(),
        };
        let host: Arc<dyn Host> = self.host.clone();
        self.server = Some(LinkServer::start_with(config, host, self.tuning.clone()).unwrap());
    }

    fn stop(&mut self) {
        if let Some(server) = self.server.take() {
            server.stop();
        }
    }

    fn server(&self) -> &LinkServer {
        self.server.as_ref().expect("server running")
    }

    fn run<F: Future>(&self, future: F) -> F::Output {
        self.client.block_on(future)
    }

    fn request(
        &self,
        method: &str,
        path: &str,
        key: Option<&str>,
        body: Option<(&str, &str)>,
    ) -> Response {
        let mut builder = http::Request::builder()
            .method(method)
            .uri(path)
            .header("host", "mornye.local");
        if let Some(key) = key {
            builder = builder.header("authorization", format!("Bearer {key}"));
        }
        if let Some((content_type, _)) = body {
            builder = builder.header("content-type", content_type);
        }
        let body = body.map_or_else(String::new, |(_, body)| body.to_owned());
        let request = builder.body(Full::new(Bytes::from(body))).unwrap();
        let port = self.server().port();
        let fingerprint = self.server().fingerprint().to_owned();
        self.run(send(port, fingerprint, request))
    }

    fn get(&self, path: &str, key: Option<&str>) -> Response {
        self.request("GET", path, key, None)
    }

    fn post_json(&self, path: &str, key: Option<&str>, body: &Value) -> Response {
        let body = body.to_string();
        self.request("POST", path, key, Some(("application/json", &body)))
    }

    /// `PUT` with a binary `body` and the Bearer `key`.
    fn put<B>(&self, path: &str, key: Option<&str>, body: B) -> Response
    where
        B: hyper::body::Body + Send + 'static,
        B::Data: Send,
        B::Error: Into<Box<dyn std::error::Error + Send + Sync>>,
    {
        let mut builder = http::Request::builder()
            .method("PUT")
            .uri(path)
            .header("host", "mornye.local")
            .header("content-type", "application/octet-stream");
        if let Some(key) = key {
            builder = builder.header("authorization", format!("Bearer {key}"));
        }
        let request = builder.body(body).unwrap();
        let port = self.server().port();
        let fingerprint = self.server().fingerprint().to_owned();
        self.run(send(port, fingerprint, request))
    }

    fn begin_pairing(&self) -> String {
        let window = self.server().begin_pairing().unwrap();
        assert_eq!(window["fingerprint"], self.server().fingerprint());
        assert!(window["expiresMs"].as_i64().unwrap() > 0);
        window["pin"].as_str().unwrap().to_owned()
    }

    fn pair_body(&self, pin: &str, device_id: &str) -> Value {
        json!({
            "deviceId": device_id,
            "name": "Pixel",
            "platform": "android",
            "proof": proof(pin, self.server().fingerprint(), device_id),
        })
    }

    /// Pairs `device_id` and returns its API key.
    fn pair(&self, device_id: &str) -> String {
        let pin = self.begin_pairing();
        let response = self.post_json("/mornye/v1/pair", None, &self.pair_body(&pin, device_id));
        assert_eq!(response.status, 200, "{}", response.text());
        response.json()["apiKey"].as_str().unwrap().to_owned()
    }

    /// A key minted for a Subsonic app: `(deviceId, apiKey)`.
    fn subsonic_key(&self) -> (String, String) {
        let key = self.server().create_key("Player").unwrap();
        (
            key["deviceId"].as_str().unwrap().to_owned(),
            key["apiKey"].as_str().unwrap().to_owned(),
        )
    }

    fn device(&self, device_id: &str) -> Option<Value> {
        self.server()
            .devices()
            .as_array()
            .unwrap()
            .iter()
            .find(|device| device["deviceId"] == device_id)
            .cloned()
    }

    fn socket(&self, key: &str) -> Socket {
        let port = self.server().port();
        let fingerprint = self.server().fingerprint().to_owned();
        let key = key.to_owned();
        self.run(async move {
            let tls = connect(port, &fingerprint).await;
            let mut request = "wss://mornye.local/mornye/v1/ws"
                .into_client_request()
                .unwrap();
            request
                .headers_mut()
                .insert("authorization", format!("Bearer {key}").parse().unwrap());
            let (socket, response) = tokio_tungstenite::client_async(request, tls).await.unwrap();
            assert_eq!(response.status(), 101);
            socket
        })
    }

    /// Opens a socket for `device_id` and completes hello/welcome.
    fn session(&self, device_id: &str, key: &str) -> Socket {
        let mut socket = self.socket(key);
        let welcome = self.run(async {
            send_hello(&mut socket, device_id).await;
            next_json(&mut socket).await
        });
        assert_eq!(welcome["type"], "welcome");
        assert_eq!(welcome["serverId"], self.server().server_id());
        assert_eq!(welcome["name"], "Test Desk");
        assert_eq!(welcome["protocol"], 1);
        socket
    }
}

fn free_port() -> u16 {
    std::net::TcpListener::bind((Ipv4Addr::LOCALHOST, 0))
        .unwrap()
        .local_addr()
        .unwrap()
        .port()
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|byte| format!("{byte:02x}")).collect()
}

/// The phone's pairing proof, written from the contract.
fn proof(pin: &str, fingerprint: &str, device_id: &str) -> String {
    let mut mac = <Hmac<Sha256> as KeyInit>::new_from_slice(pin.as_bytes()).unwrap();
    mac.update(format!("mornye-link-pair-v1:{fingerprint}:{device_id}").as_bytes());
    hex(&mac.finalize().into_bytes())
}

async fn connect(port: u16, fingerprint: &str) -> TlsStream<TcpStream> {
    let provider = Arc::new(rustls::crypto::ring::default_provider());
    let config = rustls::ClientConfig::builder_with_provider(Arc::clone(&provider))
        .with_safe_default_protocol_versions()
        .unwrap()
        .dangerous()
        .with_custom_certificate_verifier(Arc::new(Pinned {
            fingerprint: fingerprint.to_owned(),
            provider,
        }))
        .with_no_client_auth();
    let tcp = TcpStream::connect((Ipv4Addr::LOCALHOST, port))
        .await
        .unwrap();
    TlsConnector::from(Arc::new(config))
        .connect(ServerName::try_from("mornye.local").unwrap(), tcp)
        .await
        .unwrap()
}

async fn send<B>(port: u16, fingerprint: String, request: http::Request<B>) -> Response
where
    B: hyper::body::Body + Send + 'static,
    B::Data: Send,
    B::Error: Into<Box<dyn std::error::Error + Send + Sync>>,
{
    let tls = connect(port, &fingerprint).await;
    let (mut sender, connection) = hyper::client::conn::http1::handshake(TokioIo::new(tls))
        .await
        .unwrap();
    tokio::spawn(connection);
    let response = sender.send_request(request).await.unwrap();
    let status = response.status().as_u16();
    let body = response.into_body().collect().await.unwrap().to_bytes();
    Response { status, body }
}

async fn send_hello(socket: &mut Socket, device_id: &str) {
    let hello = json!({
        "type": "hello",
        "deviceId": device_id,
        "name": "Pixel 9",
        "platform": "android",
        "appVersion": "1.2.3",
        "protocol": 1,
    });
    socket
        .send(Message::Text(hello.to_string().into()))
        .await
        .unwrap();
}

async fn next_json(socket: &mut Socket) -> Value {
    loop {
        let message = tokio::time::timeout(WAIT, socket.next())
            .await
            .expect("no message in time")
            .expect("socket closed")
            .unwrap();
        match message {
            Message::Text(text) => return serde_json::from_str(text.as_str()).unwrap(),
            Message::Ping(_) | Message::Pong(_) => {}
            other => panic!("unexpected message {other:?}"),
        }
    }
}

async fn close_code(socket: &mut Socket) -> u16 {
    loop {
        match tokio::time::timeout(WAIT, socket.next())
            .await
            .expect("no close in time")
        {
            Some(Ok(Message::Close(Some(frame)))) => return u16::from(frame.code),
            Some(Ok(Message::Close(None))) => panic!("close without a code"),
            Some(Ok(_)) => {}
            other => panic!("no close frame: {other:?}"),
        }
    }
}

/// The server's close reply after the client closed: `None` when it carries
/// no code, as for a close without one.
async fn close_code_or_none(socket: &mut Socket) -> Option<u16> {
    loop {
        match tokio::time::timeout(WAIT, socket.next())
            .await
            .expect("no close reply in time")
        {
            Some(Ok(Message::Close(frame))) => return frame.map(|frame| u16::from(frame.code)),
            Some(Ok(_)) => {}
            other => panic!("no close reply: {other:?}"),
        }
    }
}

#[test]
fn info_reports_the_identity_without_auth() {
    let fixture = Fixture::new();
    let info = fixture.get("/mornye/v1/info", None);
    assert_eq!(info.status, 200);
    let info = info.json();
    assert_eq!(info["serverId"], fixture.server().server_id());
    assert_eq!(info["name"], "Test Desk");
    assert_eq!(info["protocol"], 1);
    assert_eq!(info["appVersion"], "9.9.9");
    assert_eq!(info["fingerprint"], fixture.server().fingerprint());
    assert_eq!(info["pairing"], false);

    fixture.begin_pairing();
    assert_eq!(fixture.get("/mornye/v1/info", None).json()["pairing"], true);
    fixture.server().end_pairing();
    assert_eq!(
        fixture.host.wait_event("linkPairingEnded", 1)["reason"],
        "cancelled"
    );
    assert_eq!(
        fixture.get("/mornye/v1/info", None).json()["pairing"],
        false
    );

    let missing = fixture.get("/elsewhere", None);
    assert_eq!(missing.status, 404);
    assert_eq!(missing.json(), json!({"error": "not_found"}));
    assert_eq!(
        fixture
            .post_json("/mornye/v1/info", None, &json!({}))
            .status,
        405
    );

    let status = fixture.server().status();
    assert_eq!(status["running"], true);
    assert_eq!(status["port"], fixture.server().port());
    assert_eq!(
        status["addresses"],
        json!([format!("https://127.0.0.1:{}", fixture.server().port())])
    );
    assert_eq!(status["clients"], json!([]));
    assert_eq!(fixture.server().summary()["serverId"], status["serverId"]);
}

#[test]
fn pairing_with_a_valid_proof_stores_the_device() {
    let fixture = Fixture::new();
    let pin = fixture.begin_pairing();
    let response = fixture.post_json("/mornye/v1/pair", None, &fixture.pair_body(&pin, "phone-1"));
    assert_eq!(response.status, 200, "{}", response.text());
    let paired = response.json();
    assert_eq!(paired["serverId"], fixture.server().server_id());
    assert_eq!(paired["name"], "Test Desk");
    assert_eq!(paired["fingerprint"], fixture.server().fingerprint());
    let key = paired["apiKey"].as_str().unwrap();
    assert_eq!(key.len(), 43);

    assert_eq!(
        fixture.host.wait_event("linkPaired", 1),
        json!({"deviceId": "phone-1", "name": "Pixel", "platform": "android"})
    );
    assert_eq!(
        fixture.host.wait_event("linkPairingEnded", 1),
        json!({"reason": "paired"})
    );
    let device = fixture.device("phone-1").unwrap();
    assert_eq!(device["platform"], "android");
    assert_eq!(device["connected"], false);
    assert!(device["pairedMs"].as_i64().unwrap() > 0);

    // The window closed with the success.
    let again = fixture.post_json("/mornye/v1/pair", None, &fixture.pair_body(&pin, "phone-1"));
    assert_eq!(again.status, 403);
    assert_eq!(again.json(), json!({"error": "pairing_closed"}));

    // The key works, and re-pairing replaces it.
    assert_eq!(fixture.get("/mornye/v1/state", Some(key)).status, 200);
    let replaced = fixture.pair("phone-1");
    assert_ne!(replaced, key);
    assert_eq!(fixture.get("/mornye/v1/state", Some(key)).status, 401);
    assert_eq!(fixture.get("/mornye/v1/state", Some(&replaced)).status, 200);
    assert_eq!(fixture.server().devices().as_array().unwrap().len(), 1);

    let invalid = fixture.post_json("/mornye/v1/pair", None, &json!({"deviceId": "x"}));
    assert_eq!(invalid.status, 400);
}

#[test]
fn five_bad_proofs_end_the_window() {
    let fixture = Fixture::new();
    let pin = fixture.begin_pairing();
    let mut bad = fixture.pair_body(&pin, "phone-1");
    bad["proof"] = json!(proof("000000", fixture.server().fingerprint(), "phone-1"));
    if pin == "000000" {
        bad["proof"] = json!(proof("111111", fixture.server().fingerprint(), "phone-1"));
    }
    for _ in 0..5 {
        let response = fixture.post_json("/mornye/v1/pair", None, &bad);
        assert_eq!(response.status, 403);
        assert_eq!(response.json(), json!({"error": "bad_proof"}));
    }
    assert_eq!(
        fixture.host.wait_event("linkPairingEnded", 1),
        json!({"reason": "attempts"})
    );
    // Even the right proof is refused now.
    let response = fixture.post_json("/mornye/v1/pair", None, &fixture.pair_body(&pin, "phone-1"));
    assert_eq!(response.json(), json!({"error": "pairing_closed"}));
    assert!(fixture.host.events("linkPaired").is_empty());
}

#[test]
fn a_proof_for_another_certificate_fails() {
    let fixture = Fixture::new();
    let pin = fixture.begin_pairing();
    let relayed = json!({
        "deviceId": "phone-1",
        "name": "Pixel",
        "platform": "android",
        "proof": proof(&pin, &"0".repeat(64), "phone-1"),
    });
    let response = fixture.post_json("/mornye/v1/pair", None, &relayed);
    assert_eq!(response.json(), json!({"error": "bad_proof"}));
}

#[test]
fn pairing_windows_expire() {
    let fixture = Fixture::with(Tuning {
        pairing_ttl: Duration::from_millis(200),
        ..test_tuning()
    });
    let pin = fixture.begin_pairing();
    assert_eq!(
        fixture.host.wait_event("linkPairingEnded", 1),
        json!({"reason": "expired"})
    );
    let response = fixture.post_json("/mornye/v1/pair", None, &fixture.pair_body(&pin, "phone-1"));
    assert_eq!(response.status, 403);
    assert_eq!(response.json(), json!({"error": "pairing_closed"}));
    assert_eq!(fixture.host.events("linkPairingEnded").len(), 1);
}

#[test]
fn pairing_requests_are_rate_limited_per_address() {
    let fixture = Fixture::with(Tuning {
        pair_interval: Duration::from_secs(30),
        ..test_tuning()
    });
    let body = json!({"deviceId": "phone-1", "proof": "00"});
    let first = fixture.post_json("/mornye/v1/pair", None, &body);
    assert_eq!(first.json(), json!({"error": "pairing_closed"}));
    let second = fixture.post_json("/mornye/v1/pair", None, &body);
    assert_eq!(second.status, 429);
}

#[test]
fn mornye_endpoints_require_a_bearer_key() {
    let fixture = Fixture::new();
    for key in [None, Some("not-a-key")] {
        let response = fixture.get("/mornye/v1/state", key);
        assert_eq!(response.status, 401);
        assert_eq!(response.json(), json!({"error": "unauthorized"}));
        assert_eq!(fixture.get("/mornye/v1/ws", key).status, 401);
    }
    assert!(fixture.host.requests.lock().unwrap().is_empty());
}

#[test]
fn forwards_requests_to_the_app() {
    let fixture = Fixture::new();
    let key = fixture.pair("phone-1");

    let got = fixture.get("/mornye/v1/handoff/current?limit=5&q=a%20b", Some(&key));
    assert_eq!(got.status, 200);
    assert_eq!(
        got.json(),
        json!({
            "op": "handoff/current",
            "args": {"limit": "5", "q": "a b", "_method": "GET"},
        })
    );
    let posted = fixture.post_json(
        "/mornye/v1/command",
        Some(&key),
        &json!({"action": "seek", "args": {"positionMs": 5}}),
    );
    assert_eq!(
        posted.json()["args"],
        json!({"action": "seek", "args": {"positionMs": 5}, "_method": "POST"})
    );
    let empty = fixture.request("POST", "/mornye/v1/downloads", Some(&key), None);
    assert_eq!(empty.json()["args"], json!({"_method": "POST"}));
    {
        let requests = fixture.host.requests.lock().unwrap();
        assert!(requests.iter().all(|(_, device, _)| device == "phone-1"));
        assert_eq!(requests.len(), 3);
    }

    let not_json = fixture.request(
        "POST",
        "/mornye/v1/command",
        Some(&key),
        Some(("application/json", "[1]")),
    );
    assert_eq!(not_json.status, 400);
    assert_eq!(not_json.json()["error"], "invalid");

    let missing = fixture.get("/mornye/v1/missing", Some(&key));
    assert_eq!(missing.status, 404);
    assert_eq!(
        missing.json(),
        json!({"error": "not_found", "message": "No such item"})
    );
    let broken = fixture.get("/mornye/v1/broken", Some(&key));
    assert_eq!(broken.status, 500);
    assert_eq!(broken.json()["error"], "weird");

    let started = Instant::now();
    let slow = fixture.get("/mornye/v1/slow", Some(&key));
    assert_eq!(slow.status, 504);
    assert_eq!(slow.json()["error"], "timeout");
    assert!(started.elapsed() >= Duration::from_millis(300));

    assert_eq!(fixture.get("/mornye/v1/a/../b", Some(&key)).status, 404);
    assert_eq!(
        fixture
            .request("PUT", "/mornye/v1/state", Some(&key), None)
            .status,
        405
    );
}

#[test]
fn phones_upload_song_files_into_the_received_folder() {
    let fixture = Fixture::new();
    let key = fixture.pair("phone-1");
    let name = "0123456789abcdef0123456789abcdef.flac";
    let path = format!("/mornye/v1/files/{name}");
    let body: Vec<u8> = (0..300_000u32).map(|index| (index % 251) as u8).collect();

    let stored = fixture.put(&path, Some(&key), Full::new(Bytes::from(body.clone())));
    assert_eq!(stored.status, 200, "{}", stored.text());
    assert_eq!(stored.json(), json!({"name": name, "size": body.len()}));
    let received = fixture.dir.path().join("link").join("received");
    assert_eq!(std::fs::read(received.join(name)).unwrap(), body);
    let replaced = fixture.put(&path, Some(&key), Full::new(Bytes::from_static(b"fLaC")));
    assert_eq!(replaced.json(), json!({"name": name, "size": 4}));
    assert_eq!(std::fs::read(received.join(name)).unwrap(), b"fLaC");
    let left: Vec<_> = std::fs::read_dir(&received)
        .unwrap()
        .map(|entry| entry.unwrap().file_name())
        .collect();
    assert_eq!(left, [name], "no part file left");

    let received_dir = received.to_string_lossy();
    assert_eq!(
        fixture.server().summary()["receivedDir"],
        received_dir.as_ref()
    );
    assert_eq!(
        fixture.server().status()["receivedDir"],
        received_dir.as_ref()
    );

    let unauthorized = fixture.put(&path, None, Full::new(Bytes::from_static(b"x")));
    assert_eq!(unauthorized.status, 401);
    assert_eq!(unauthorized.json(), json!({"error": "unauthorized"}));
    for bad in [
        "0123456789ABCDEF0123456789abcdef.flac",
        "0123456789abcdef0123456789abcdef.txt",
        "0123456789abcdef0123456789abcdef",
        "..%2Fstate",
        "a/0123456789abcdef0123456789abcdef.flac",
    ] {
        let refused = fixture.put(
            &format!("/mornye/v1/files/{bad}"),
            Some(&key),
            Full::new(Bytes::from_static(b"x")),
        );
        assert_eq!(refused.status, 400, "{bad}");
        assert_eq!(refused.json()["error"], "invalid");
    }
    assert_eq!(fixture.get(&path, Some(&key)).status, 405);
    let posted = fixture.request("POST", &path, Some(&key), Some(("audio/flac", "x")));
    assert_eq!(posted.status, 405);
    assert_eq!(posted.json(), json!({"error": "method_not_allowed"}));

    // A declared length beyond 2 GiB is refused before any byte is read.
    let request = http::Request::builder()
        .method("PUT")
        .uri(&path)
        .header("host", "mornye.local")
        .header("authorization", format!("Bearer {key}"))
        .header("content-length", (3u64 << 30).to_string())
        .body(StreamBody::new(futures_util::stream::pending::<
            Result<Frame<Bytes>, Infallible>,
        >()))
        .unwrap();
    let port = fixture.server().port();
    let fingerprint = fixture.server().fingerprint().to_owned();
    let too_large = fixture.run(send(port, fingerprint, request));
    assert_eq!(too_large.status, 413);
    assert_eq!(too_large.json(), json!({"error": "too_large"}));
    assert_eq!(std::fs::read(received.join(name)).unwrap(), b"fLaC");
    assert!(fixture.host.requests.lock().unwrap().is_empty());
}

#[test]
fn subsonic_requests_authenticate_before_the_subsonic_layer() {
    let fixture = Fixture::new();
    let seen = |device_id: &str| !fixture.device(device_id).unwrap()["lastSeenMs"].is_null();

    // A wrong key never reaches the Subsonic layer.
    let (device, key) = fixture.subsonic_key();
    let refused = fixture.get("/rest/ping.view?apiKey=wrong&f=json", None);
    assert_eq!(refused.status, 200);
    if refused.text().contains("subsonic-response") {
        assert!(refused.text().contains("44"), "{}", refused.text());
    }
    let wrong_password = fixture.get("/rest/ping?u=x&p=wrong&f=json", None);
    if wrong_password.text().contains("subsonic-response") {
        assert!(wrong_password.text().contains("40"));
    }
    assert!(!seen(&device));

    // apiKey on GET.
    assert_eq!(
        fixture
            .get(&format!("/rest/ping.view?apiKey={key}&f=json"), None)
            .status,
        200
    );
    assert!(seen(&device));

    // A salted token in a form POST.
    let (device, key) = fixture.subsonic_key();
    let token = hex(&md5::Md5::digest(format!("{key}s4lt").as_bytes()));
    let form = format!("u=anyone&t={token}&s=s4lt&v=1.16.1&c=test");
    let posted = fixture.request(
        "POST",
        "/rest/getMusicFolders?f=json",
        None,
        Some(("application/x-www-form-urlencoded", &form)),
    );
    assert_eq!(posted.status, 200);
    assert!(seen(&device));

    // OpenSubsonic clients read the extension list before authenticating.
    let extensions = fixture.get("/rest/getOpenSubsonicExtensions?f=json", None);
    assert_eq!(extensions.status, 200);
    assert!(
        extensions.text().contains("apiKeyAuthentication"),
        "{}",
        extensions.text()
    );
    assert!(
        fixture
            .get("/rest/getMusicFolders?f=json", None)
            .text()
            .contains("\"failed\"")
    );

    assert_eq!(fixture.get("/rest/a/b", None).status, 404);
}

#[test]
fn websocket_sessions_forward_and_receive_messages() {
    let fixture = Fixture::new();
    let key = fixture.pair("phone-1");
    let mut socket = fixture.session("phone-1", &key);

    let clients = fixture.host.wait_event("linkClients", 1);
    let client = &clients["clients"][0];
    assert_eq!(client["deviceId"], "phone-1");
    assert_eq!(client["name"], "Pixel 9");
    assert_eq!(client["platform"], "android");
    assert_eq!(client["appVersion"], "1.2.3");
    assert!(client["connectedMs"].as_i64().unwrap() > 0);
    assert_eq!(fixture.server().status()["clients"], clients["clients"]);
    assert_eq!(fixture.device("phone-1").unwrap()["connected"], true);

    let state = json!({"type": "player.state", "state": {"playing": true}});
    fixture
        .run(socket.send(Message::Text(state.to_string().into())))
        .unwrap();
    assert_eq!(
        fixture.host.wait_event("linkMessage", 1),
        json!({"deviceId": "phone-1", "message": state})
    );

    let open = json!({"type": "open", "url": "https://example.com/a"});
    assert_eq!(fixture.server().send(Some("phone-1"), open.clone()), 1);
    assert_eq!(fixture.run(next_json(&mut socket)), open);
    assert_eq!(fixture.server().send(Some("other"), open.clone()), 0);
    assert_eq!(fixture.server().send(None, json!({"type": "x"})), 1);
    assert_eq!(fixture.run(next_json(&mut socket)), json!({"type": "x"}));

    // With the L1b catalog in place the change is pushed to clients.
    let export = fixture.dir.path().join("catalog.ndjson");
    std::fs::write(
        &export,
        "{\"catalogVersion\":1,\"generatedMs\":1,\"count\":0}\n",
    )
    .unwrap();
    if let Ok(result) = fixture.server().set_catalog(&export) {
        assert_eq!(result["version"], 1);
        let changed = fixture.run(next_json(&mut socket));
        assert_eq!(changed["type"], "catalog.changed");
        assert_eq!(changed["version"], 1);
        assert_eq!(changed["songs"], result["songs"]);
    }

    // Revoking closes the socket and forgets the key.
    fixture.server().revoke("phone-1").unwrap();
    assert_eq!(fixture.run(close_code(&mut socket)), 4401);
    assert_eq!(
        fixture.host.wait_event("linkClients", 2),
        json!({"clients": []})
    );
    assert!(fixture.device("phone-1").is_none());
    assert_eq!(fixture.get("/mornye/v1/state", Some(&key)).status, 401);
}

#[test]
fn websocket_requires_hello_from_the_key_device() {
    let fixture = Fixture::new();
    let key = fixture.pair("phone-1");

    let mut socket = fixture.socket(&key);
    let code = fixture.run(async {
        send_hello(&mut socket, "phone-2").await;
        close_code(&mut socket).await
    });
    assert_eq!(code, 4401);

    let mut socket = fixture.socket(&key);
    let code = fixture.run(async {
        let message = json!({"type": "player.state", "state": {}}).to_string();
        socket.send(Message::Text(message.into())).await.unwrap();
        close_code(&mut socket).await
    });
    assert_eq!(code, 4401);
    assert!(fixture.host.events("linkClients").is_empty());
    assert!(fixture.host.events("linkMessage").is_empty());
}

#[test]
fn the_newest_websocket_of_a_device_wins() {
    let fixture = Fixture::new();
    let key = fixture.pair("phone-1");
    let mut first = fixture.session("phone-1", &key);
    let _second = fixture.session("phone-1", &key);
    assert_eq!(fixture.run(close_code(&mut first)), 4409);
    fixture.host.wait_event("linkClients", 2);
    assert_eq!(
        fixture.server().status()["clients"]
            .as_array()
            .unwrap()
            .len(),
        1
    );
    assert_eq!(fixture.server().send(None, json!({"type": "x"})), 1);
}

#[test]
fn a_client_close_is_answered_and_reported() {
    let fixture = Fixture::new();
    let key = fixture.pair("phone-1");
    let mut socket = fixture.session("phone-1", &key);
    fixture.host.wait_event("linkClients", 1);
    let code = fixture.run(async {
        socket.close(None).await.unwrap();
        close_code_or_none(&mut socket).await
    });
    assert_eq!(code, None);
    assert_eq!(
        fixture.host.wait_event("linkClients", 2),
        json!({"clients": []})
    );
    assert_eq!(fixture.device("phone-1").unwrap()["connected"], false);
}

#[test]
fn silent_websocket_clients_are_dropped() {
    let fixture = Fixture::with(Tuning {
        ping_interval: Duration::from_millis(100),
        idle_timeout: Duration::from_millis(300),
        ..test_tuning()
    });
    let key = fixture.pair("phone-1");
    let mut socket = fixture.session("phone-1", &key);
    // Not reading means no pong goes back.
    std::thread::sleep(Duration::from_millis(700));
    // Reading the queued pings makes this client answer them on the closed
    // connection, and under load the reset can arrive before the close
    // frame is read. The frame, when read, must say 1001.
    let code = fixture.run(async {
        loop {
            match tokio::time::timeout(WAIT, socket.next())
                .await
                .expect("no close in time")
            {
                Some(Ok(Message::Close(frame))) => {
                    return frame.map(|frame| u16::from(frame.code));
                }
                Some(Ok(_)) => {}
                Some(Err(_)) | None => return None,
            }
        }
    });
    assert!(matches!(code, Some(1001) | None), "close code {code:?}");
    assert_eq!(
        fixture.host.wait_event("linkClients", 2),
        json!({"clients": []})
    );
}

#[test]
fn stopping_closes_websockets() {
    let mut fixture = Fixture::new();
    let key = fixture.pair("phone-1");
    let mut socket = fixture.session("phone-1", &key);
    let started = Instant::now();
    fixture.stop();
    assert!(started.elapsed() < Duration::from_secs(5));
    assert_eq!(fixture.run(close_code(&mut socket)), 1001);
}

#[test]
fn a_busy_port_falls_back_and_the_choice_is_persisted() {
    let mut fixture = Fixture::idle(test_tuning());
    let busy = std::net::TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).unwrap();
    let busy_port = busy.local_addr().unwrap().port();
    fixture.start(busy_port);
    let chosen = fixture.server().port();
    assert_ne!(chosen, busy_port);
    assert_ne!(chosen, 0);
    fixture.stop();

    // No request: the persisted port is reused.
    fixture.start(0);
    assert_eq!(fixture.server().port(), chosen);
    assert_eq!(fixture.get("/mornye/v1/info", None).status, 200);
}

#[test]
fn restarting_keeps_the_server_identity_and_keys() {
    let mut fixture = Fixture::new();
    let key = fixture.pair("phone-1");
    let server_id = fixture.server().server_id().to_owned();
    let fingerprint = fixture.server().fingerprint().to_owned();
    let port = fixture.server().port();
    fixture.stop();
    assert!(
        mornye_link::stored_devices(&fixture.dir.path().join("link"))
            .unwrap()
            .as_array()
            .unwrap()
            .iter()
            .any(|device| device["deviceId"] == "phone-1" && device["connected"] == false)
    );

    fixture.start(port);
    assert_eq!(fixture.server().server_id(), server_id);
    assert_eq!(fixture.server().fingerprint(), fingerprint);
    assert_eq!(fixture.get("/mornye/v1/state", Some(&key)).status, 200);
    fixture.stop();

    mornye_link::revoke_stored(&fixture.dir.path().join("link"), "phone-1").unwrap();
    fixture.start(port);
    assert_eq!(fixture.get("/mornye/v1/state", Some(&key)).status, 401);
}
