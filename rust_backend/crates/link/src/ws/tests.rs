use super::*;
use crate::catalog::Catalog;
use crate::pairing::Pairing;
use crate::server::Tuning;
use crate::store::Store;
use crate::types::{Host, HostError, LinkConfig, Shared};
use futures_util::future::BoxFuture;
use std::sync::RwLock;
use tokio::io::{AsyncReadExt, DuplexStream};
use tokio_util::sync::CancellationToken;
use tokio_util::task::TaskTracker;

struct NoopHost;

impl Host for NoopHost {
    fn request(&self, _: &str, _: &str, _: Value) -> BoxFuture<'static, Result<Value, HostError>> {
        Box::pin(async { Ok(Value::Null) })
    }

    fn event(&self, _: &str, _: Value) {}
}

struct Fixture {
    _dir: tempfile::TempDir,
    state: Arc<State>,
    socket: WebSocketStream<DuplexStream>,
    task: tokio::task::JoinHandle<()>,
}

impl Fixture {
    async fn new(idle_timeout: Duration) -> Self {
        Self::with(Tuning {
            idle_timeout,
            ..Tuning::default()
        })
        .await
    }

    async fn with(tuning: Tuning) -> Self {
        let dir = tempfile::tempdir().unwrap();
        let store = Store::open(dir.path()).unwrap();
        let device = store.upsert("phone", "Phone", "android", false).unwrap();
        let state = Arc::new(State {
            shared: Arc::new(Shared {
                config: LinkConfig {
                    state_dir: dir.path().to_owned(),
                    temp_dir: dir.path().to_owned(),
                    name: "Link test".to_owned(),
                    port: 0,
                    ffmpeg_path: None,
                    app_version: String::new(),
                },
                server_id: store.server_id(),
                host: Arc::new(NoopHost),
                catalog: RwLock::new(Arc::new(Catalog::empty())),
            }),
            store,
            pairing: Pairing::new(tuning.pairing_ttl, tuning.pair_interval),
            clients: Clients::default(),
            fingerprint: String::new(),
            local: "127.0.0.1:0".parse().unwrap(),
            tuning,
            shutdown: CancellationToken::new(),
            tasks: TaskTracker::new(),
            catalog_version: AtomicU64::new(0),
        });
        // A frame cannot fit unless the client keeps reading.
        let (server_io, client_io) = tokio::io::duplex(32);
        let task = tokio::spawn(session(Arc::clone(&state), device, server_io));
        let mut socket = WebSocketStream::from_raw_socket(client_io, Role::Client, None).await;
        socket
            .send(Message::Text(
                object!({"type": "hello", "deviceId": "phone"})
                    .to_string()
                    .into(),
            ))
            .await
            .unwrap();
        Self {
            _dir: dir,
            state,
            socket,
            task,
        }
    }

    async fn welcome(&mut self) {
        assert!(matches!(
            self.socket.next().await,
            Some(Ok(Message::Text(_)))
        ));
    }

    async fn stall_data_write(&mut self) {
        self.welcome().await;
        assert_eq!(self.state.clients.send(Some("phone"), &"x".repeat(8192)), 1);
        self.wait_for_partial_frame().await;
    }

    async fn wait_for_partial_frame(&mut self) {
        // Reading one byte proves the write started, while the rest of the
        // frame still cannot fit. The socket is deliberately not parsed again.
        tokio::time::timeout(Duration::from_secs(1), self.socket.get_mut().read_u8())
            .await
            .expect("the server did not start writing")
            .unwrap();
    }

    async fn finished(self) {
        tokio::time::timeout(Duration::from_secs(3), self.task)
            .await
            .expect("a stalled write retained the session")
            .unwrap();
        assert!(!self.state.clients.is_connected("phone"));
    }
}

#[tokio::test(start_paused = true)]
async fn recent_client_pings_suppress_server_pings_and_keep_the_session_alive() {
    let mut fixture = Fixture::with(Tuning {
        ping_interval: Duration::from_millis(100),
        idle_timeout: Duration::from_millis(300),
        ..Tuning::default()
    })
    .await;
    fixture.welcome().await;
    for _ in 0..5 {
        tokio::time::advance(Duration::from_millis(50)).await;
        fixture
            .socket
            .send(Message::Ping(Bytes::new()))
            .await
            .unwrap();
        assert!(matches!(
            fixture.socket.next().await,
            Some(Ok(Message::Pong(_)))
        ));
        tokio::time::advance(Duration::from_millis(50)).await;
        tokio::task::yield_now().await;
    }
    assert!(fixture.state.clients.is_connected("phone"));
    fixture.state.shutdown.cancel();
    fixture.finished().await;
}

#[tokio::test(start_paused = true)]
async fn silent_clients_are_pinged_then_closed_at_the_idle_deadline() {
    let mut fixture = Fixture::with(Tuning {
        ping_interval: Duration::from_millis(100),
        idle_timeout: Duration::from_millis(300),
        ..Tuning::default()
    })
    .await;
    fixture.welcome().await;
    tokio::time::advance(Duration::from_millis(100)).await;
    // Read the empty ping without tungstenite queuing a pong for it.
    let mut ping = [0; 2];
    fixture
        .socket
        .get_mut()
        .read_exact(&mut ping)
        .await
        .unwrap();
    assert_eq!(ping, [0x89, 0]);
    tokio::time::advance(Duration::from_millis(200)).await;
    assert!(matches!(
        fixture.socket.next().await,
        Some(Ok(Message::Close(Some(frame)))) if u16::from(frame.code) == CLOSE_GOING_AWAY
    ));
    fixture.finished().await;
}

#[tokio::test]
async fn shutdown_interrupts_a_stalled_welcome() {
    let mut fixture = Fixture::new(Duration::from_secs(60)).await;
    fixture.wait_for_partial_frame().await;
    fixture.state.shutdown.cancel();
    fixture.finished().await;
}

#[tokio::test]
async fn revocation_interrupts_a_stalled_data_write() {
    let mut fixture = Fixture::new(Duration::from_secs(60)).await;
    fixture.stall_data_write().await;
    assert!(
        fixture
            .state
            .clients
            .close("phone", CLOSE_UNAUTHORIZED, "revoked")
    );
    fixture.finished().await;
}

#[tokio::test]
async fn stalled_data_writes_have_a_deadline() {
    let mut fixture = Fixture::new(Duration::from_millis(100)).await;
    fixture.stall_data_write().await;
    fixture.finished().await;
}

#[tokio::test]
async fn slow_clients_cannot_queue_unlimited_messages() {
    let mut fixture = Fixture::new(Duration::from_secs(60)).await;
    fixture.stall_data_write().await;
    let queued = (0..1024)
        .take_while(|_| fixture.state.clients.send(Some("phone"), "{}") == 1)
        .count();
    assert!(queued < 1024, "the stalled client's queue kept growing");
    assert_eq!(fixture.state.clients.send(Some("phone"), "{}"), 0);
    fixture.finished().await;
}

#[tokio::test]
async fn slow_clients_cannot_queue_unlimited_bytes() {
    let mut fixture = Fixture::new(Duration::from_secs(60)).await;
    fixture.stall_data_write().await;
    let message = "x".repeat(MAX_MESSAGE / 4);
    for _ in 0..4 {
        assert_eq!(fixture.state.clients.send(Some("phone"), &message), 1);
    }
    assert_eq!(fixture.state.clients.send(Some("phone"), &message), 0);
    fixture.finished().await;
}
