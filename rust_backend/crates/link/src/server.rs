//! The listener (contract section 2): one TCP port on every interface, TLS
//! with the pinned certificate, HTTP/1.1 with keep-alive and upgrades. The
//! port is the requested one, else the persisted one, else the first free
//! port of 47710..=47729, else an OS-assigned port.

use crate::pairing::Pairing;
use crate::store::Store;
use crate::types::{Host, HostError, Shared};
use crate::ws::Clients;
use futures_util::future::BoxFuture;
use hyper::server::conn::http1;
use hyper::service::service_fn;
use hyper_util::rt::{TokioIo, TokioTimer};
use serde_json::{Value, json};
use socket2::{Domain, Protocol, Socket, Type};
use std::convert::Infallible;
use std::io;
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr};
use std::sync::Arc;
use std::sync::atomic::AtomicU64;
use std::time::Duration;
use tokio::net::TcpListener;
use tokio_rustls::TlsAcceptor;
use tokio_util::sync::CancellationToken;
use tokio_util::task::TaskTracker;

/// Request bodies and WebSocket messages are limited to 8 MiB.
pub(crate) const MAX_BODY: usize = 8 << 20;
/// Ports tried after the requested and persisted ones.
const DEFAULT_PORTS: std::ops::RangeInclusive<u16> = 47710..=47729;
const HANDSHAKE_TIMEOUT: Duration = Duration::from_secs(10);
const HEADER_TIMEOUT: Duration = Duration::from_secs(30);

/// Timing and binding knobs. The defaults follow the contract; tests shorten
/// the timers, bind loopback only and skip mDNS.
#[derive(Debug, Clone)]
pub struct Tuning {
    /// How long the app has to answer a forwarded request (504 after).
    pub request_timeout: Duration,
    /// How long a pairing PIN stays valid.
    pub pairing_ttl: Duration,
    /// Minimum time between pairing requests from one address (429).
    pub pair_interval: Duration,
    /// WebSocket ping period.
    pub ping_interval: Duration,
    /// WebSocket clients silent this long are dropped; also the time a new
    /// client has to send `hello`.
    pub idle_timeout: Duration,
    /// Listen on this address only; `None` listens on every interface.
    pub bind: Option<IpAddr>,
    /// Advertise over mDNS.
    pub advertise: bool,
}

impl Default for Tuning {
    fn default() -> Self {
        Self {
            request_timeout: Duration::from_secs(20),
            pairing_ttl: Duration::from_secs(5 * 60),
            pair_interval: Duration::from_secs(1),
            ping_interval: Duration::from_secs(20),
            idle_timeout: Duration::from_secs(60),
            bind: None,
            advertise: true,
        }
    }
}

/// Everything a running server shares between connections.
pub(crate) struct State {
    pub(crate) shared: Arc<Shared>,
    pub(crate) store: Store,
    pub(crate) pairing: Pairing,
    pub(crate) clients: Clients,
    pub(crate) fingerprint: String,
    /// The bound listener address.
    pub(crate) local: SocketAddr,
    pub(crate) tuning: Tuning,
    pub(crate) shutdown: CancellationToken,
    pub(crate) tasks: TaskTracker,
    pub(crate) catalog_version: AtomicU64,
}

impl State {
    pub(crate) fn name(&self) -> &str {
        &self.shared.config.name
    }

    pub(crate) fn port(&self) -> u16 {
        self.local.port()
    }

    /// `linkClients` with the current client list.
    pub(crate) fn emit_clients(&self) {
        self.shared
            .host
            .event("linkClients", json!({"clients": self.clients.list()}));
    }

    pub(crate) fn emit_pairing_ended(&self, reason: &str) {
        self.shared
            .host
            .event("linkPairingEnded", json!({"reason": reason}));
    }

    /// The addresses phones can reach, as `https://<ip>:<port>`. An IPv4
    /// fallback listener lists IPv4 addresses only.
    pub(crate) fn addresses(&self) -> Vec<String> {
        let listening = self.local.ip();
        let mut ips = if listening.is_unspecified() {
            interface_addresses()
        } else {
            vec![listening]
        };
        if listening.is_ipv4() {
            ips.retain(IpAddr::is_ipv4);
        }
        ips.into_iter()
            .map(|ip| format!("https://{}", SocketAddr::new(ip, self.port())))
            .collect()
    }
}

/// Wraps the app so every forwarded request, from `/mornye/v1` or the
/// Subsonic layer, fails with `timeout` after `request_timeout`.
pub(crate) struct TimedHost {
    pub(crate) inner: Arc<dyn Host>,
    pub(crate) timeout: Duration,
}

impl Host for TimedHost {
    fn request(
        &self,
        op: &str,
        device_id: &str,
        args: Value,
    ) -> BoxFuture<'static, Result<Value, HostError>> {
        let reply = self.inner.request(op, device_id, args);
        let timeout = self.timeout;
        Box::pin(async move {
            tokio::time::timeout(timeout, reply)
                .await
                .unwrap_or_else(|_| {
                    Err(HostError::new("timeout", "The app did not answer in time"))
                })
        })
    }

    fn event(&self, method: &str, args: Value) {
        self.inner.event(method, args);
    }
}

/// Binds following the port policy. Must run inside the server runtime.
pub(crate) fn bind(
    requested: u16,
    persisted: u16,
    only: Option<IpAddr>,
) -> Result<TcpListener, String> {
    let mut candidates: Vec<u16> = Vec::new();
    for port in [requested, persisted].into_iter().chain(DEFAULT_PORTS) {
        if port != 0 && !candidates.contains(&port) {
            candidates.push(port);
        }
    }
    // Last resort: any free port.
    candidates.push(0);
    let mut last_error = None;
    for port in candidates {
        match bind_port(port, only) {
            Ok(listener) => return Ok(listener),
            Err(error) => last_error = Some(error),
        }
    }
    Err(format!(
        "Mornye Link could not listen: {}",
        last_error.map_or_else(|| "no port".to_owned(), |error| error.to_string())
    ))
}

/// One port: IPv6 dual-stack when possible, else IPv4 on every interface.
fn bind_port(port: u16, only: Option<IpAddr>) -> io::Result<TcpListener> {
    if let Some(ip) = only {
        return listen(SocketAddr::new(ip, port), false);
    }
    match listen(
        SocketAddr::new(IpAddr::V6(Ipv6Addr::UNSPECIFIED), port),
        true,
    ) {
        Ok(listener) => Ok(listener),
        Err(error) if error.kind() == io::ErrorKind::AddrInUse => Err(error),
        Err(_) => listen(
            SocketAddr::new(IpAddr::V4(Ipv4Addr::UNSPECIFIED), port),
            false,
        ),
    }
}

fn listen(address: SocketAddr, dual_stack: bool) -> io::Result<TcpListener> {
    let socket = Socket::new(
        Domain::for_address(address),
        Type::STREAM,
        Some(Protocol::TCP),
    )?;
    if dual_stack {
        socket.set_only_v6(false)?;
    }
    // Windows lets SO_REUSEADDR take over a busy port, so only Unix uses it
    // (to rebind while old connections linger in TIME_WAIT).
    #[cfg(unix)]
    socket.set_reuse_address(true)?;
    socket.set_nonblocking(true)?;
    socket.bind(&address.into())?;
    socket.listen(1024)?;
    TcpListener::from_std(socket.into())
}

/// Accepts connections until `state.shutdown` fires.
pub(crate) async fn serve(state: Arc<State>, listener: TcpListener, acceptor: TlsAcceptor) {
    loop {
        let accepted = tokio::select! {
            _ = state.shutdown.cancelled() => break,
            accepted = listener.accept() => accepted,
        };
        let (tcp, peer) = match accepted {
            Ok(connection) => connection,
            Err(_) => {
                // Out of descriptors or a reset before accept: back off.
                tokio::time::sleep(Duration::from_millis(50)).await;
                continue;
            }
        };
        let _ = tcp.set_nodelay(true);
        let acceptor = acceptor.clone();
        let connection_state = Arc::clone(&state);
        state.tasks.spawn(async move {
            let Ok(Ok(tls)) = tokio::time::timeout(HANDSHAKE_TIMEOUT, acceptor.accept(tcp)).await
            else {
                return;
            };
            let peer = peer.ip().to_canonical();
            let shutdown = connection_state.shutdown.clone();
            let service_state = Arc::clone(&connection_state);
            let service = service_fn(move |request| {
                let state = Arc::clone(&service_state);
                async move { Ok::<_, Infallible>(crate::api::route(&state, peer, request).await) }
            });
            let mut builder = http1::Builder::new();
            builder
                .keep_alive(true)
                .timer(TokioTimer::new())
                .header_read_timeout(HEADER_TIMEOUT);
            let connection = builder
                .serve_connection(TokioIo::new(tls), service)
                .with_upgrades();
            tokio::pin!(connection);
            tokio::select! {
                _ = connection.as_mut() => {}
                _ = shutdown.cancelled() => {
                    connection.as_mut().graceful_shutdown();
                    let _ = tokio::time::timeout(Duration::from_secs(1), connection).await;
                }
            }
        });
    }
}

/// Non-loopback, non-link-local interface addresses, IPv4 first.
fn interface_addresses() -> Vec<IpAddr> {
    let mut ips: Vec<IpAddr> = if_addrs::get_if_addrs()
        .unwrap_or_default()
        .into_iter()
        .filter(|interface| !interface.is_loopback() && !interface.is_link_local())
        .map(|interface| interface.ip())
        .collect();
    ips.sort_by_key(|ip| (ip.is_ipv6(), *ip));
    ips.dedup();
    ips
}
