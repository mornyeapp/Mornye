//! The HTTP server a Cast receiver streams from. Only registered media is
//! exposed, through unguessable URLs on the interface that reaches the
//! receiver, so source paths and NAS credentials stay on this device. Files
//! are sent as they are (single byte ranges for seeking); URLs, such as the
//! app's loopback proxy for network songs, are relayed.

use bytes::Bytes;
use futures_util::TryStreamExt;
use http::header::{
    ACCEPT_ENCODING, ACCEPT_RANGES, ACCESS_CONTROL_ALLOW_HEADERS, ACCESS_CONTROL_ALLOW_METHODS,
    ACCESS_CONTROL_ALLOW_ORIGIN, ACCESS_CONTROL_EXPOSE_HEADERS, CACHE_CONTROL, CONTENT_LENGTH,
    CONTENT_RANGE, CONTENT_TYPE, HeaderValue, RANGE,
};
use http::{Method, Request, Response, StatusCode, Uri};
use http_body_util::combinators::BoxBody;
use http_body_util::{BodyExt, Empty, StreamBody};
use hyper::body::{Frame, Incoming};
use hyper::server::conn::http1;
use hyper::service::service_fn;
use hyper_rustls::{HttpsConnector, HttpsConnectorBuilder};
use hyper_util::client::legacy::{Client, connect::HttpConnector};
use hyper_util::rt::{TokioExecutor, TokioIo, TokioTimer};
use std::collections::HashMap;
use std::convert::Infallible;
use std::io::{self, SeekFrom};
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr, UdpSocket};
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tokio::io::{AsyncRead, AsyncReadExt, AsyncSeekExt};
use tokio::net::TcpListener;
use tokio_util::io::ReaderStream;
use tokio_util::sync::CancellationToken;

type Body = BoxBody<Bytes, io::Error>;
type RelayClient = Client<HttpsConnector<HttpConnector>, Empty<Bytes>>;

/// Read size for file bodies.
const CHUNK: usize = 64 * 1024;
/// The port Cast receivers listen on, used only to pick the local route.
const CAST_PORT: u16 = 8009;

#[derive(Clone)]
enum Location {
    File(PathBuf),
    Url(Uri),
}

#[derive(Clone)]
struct Source {
    location: Location,
    mime: HeaderValue,
}

struct Shared {
    sources: Mutex<HashMap<String, Source>>,
    client: RelayClient,
}

/// A running media server; dropping it stops listening and ends every
/// response in flight.
pub struct MediaServer {
    shared: Arc<Shared>,
    local: SocketAddr,
    shutdown: CancellationToken,
}

impl MediaServer {
    /// Listens on the local address that routes to `receiver`. Call inside a
    /// Tokio runtime, which then runs the server.
    pub async fn for_receiver(receiver: IpAddr) -> io::Result<Self> {
        Self::bind(local_address_towards(receiver)?).await
    }

    /// Listens on `address` with an OS-assigned port; tests bind loopback.
    pub async fn bind(address: IpAddr) -> io::Result<Self> {
        let listener = TcpListener::bind(SocketAddr::new(address, 0)).await?;
        let local = listener.local_addr()?;
        let shared = Arc::new(Shared {
            sources: Mutex::default(),
            client: relay_client()?,
        });
        let shutdown = CancellationToken::new();
        tokio::spawn(accept(listener, Arc::clone(&shared), shutdown.clone()));
        Ok(Self {
            shared,
            local,
            shutdown,
        })
    }

    /// Exposes `source`, a file path or an `http(s)` URL, and answers the URL
    /// the receiver loads it from.
    pub fn register(&self, source: &str, mime: &str) -> io::Result<String> {
        let invalid = |message: &str| io::Error::new(io::ErrorKind::InvalidInput, message);
        let mime = HeaderValue::from_str(mime).map_err(|_| invalid("invalid media type"))?;
        let location = if source.starts_with("http://") || source.starts_with("https://") {
            Location::Url(source.parse().map_err(|_| invalid("invalid media URL"))?)
        } else if let Some(path) = source.strip_prefix("file://") {
            Location::File(PathBuf::from(percent_decode(path)))
        } else {
            Location::File(PathBuf::from(source))
        };
        let token = token()?;
        self.shared
            .sources
            .lock()
            .expect("cast media sources")
            .insert(token.clone(), Source { location, mime });
        Ok(format!("http://{}/media/{token}", self.local))
    }

    /// Withdraws every registered URL.
    pub fn clear(&self) {
        self.shared
            .sources
            .lock()
            .expect("cast media sources")
            .clear();
    }

    pub fn address(&self) -> SocketAddr {
        self.local
    }
}

impl Drop for MediaServer {
    fn drop(&mut self) {
        self.shutdown.cancel();
    }
}

/// The local address the OS would use to reach `receiver`. Connecting a UDP
/// socket only selects the route; nothing is sent.
fn local_address_towards(receiver: IpAddr) -> io::Result<IpAddr> {
    let any = match receiver {
        IpAddr::V4(_) => IpAddr::V4(Ipv4Addr::UNSPECIFIED),
        IpAddr::V6(_) => IpAddr::V6(Ipv6Addr::UNSPECIFIED),
    };
    let socket = UdpSocket::bind(SocketAddr::new(any, 0))?;
    socket.connect(SocketAddr::new(receiver, CAST_PORT))?;
    Ok(socket.local_addr()?.ip())
}

fn token() -> io::Result<String> {
    let mut bytes = [0u8; 24];
    getrandom::fill(&mut bytes).map_err(|error| io::Error::other(error.to_string()))?;
    Ok(bytes.iter().map(|byte| format!("{byte:02x}")).collect())
}

fn percent_decode(text: &str) -> String {
    let bytes = text.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut index = 0;
    while index < bytes.len() {
        let hex = |at: usize| (bytes.get(at).copied()).and_then(|byte| (byte as char).to_digit(16));
        if bytes[index] == b'%'
            && let (Some(high), Some(low)) = (hex(index + 1), hex(index + 2))
        {
            out.push((high * 16 + low) as u8);
            index += 3;
        } else {
            out.push(bytes[index]);
            index += 1;
        }
    }
    String::from_utf8_lossy(&out).into_owned()
}

fn relay_client() -> io::Result<RelayClient> {
    let mut http = HttpConnector::new();
    http.enforce_http(false);
    http.set_connect_timeout(Some(Duration::from_secs(10)));
    http.set_nodelay(true);
    let connector = HttpsConnectorBuilder::new()
        .with_tls_config(mornye_network::tls_client_config()?)
        .https_or_http()
        .enable_http1()
        .wrap_connector(http);
    Ok(Client::builder(TokioExecutor::new())
        .pool_timer(TokioTimer::new())
        .pool_idle_timeout(Duration::from_secs(30))
        .build(connector))
}

async fn accept(listener: TcpListener, shared: Arc<Shared>, shutdown: CancellationToken) {
    loop {
        let stream = tokio::select! {
            () = shutdown.cancelled() => return,
            accepted = listener.accept() => match accepted {
                Ok((stream, _)) => stream,
                Err(_) => {
                    // Out of descriptors and similar: back off, keep serving.
                    tokio::time::sleep(Duration::from_millis(100)).await;
                    continue;
                }
            },
        };
        let _ = stream.set_nodelay(true);
        let shared = Arc::clone(&shared);
        let shutdown = shutdown.clone();
        tokio::spawn(async move {
            let service = service_fn(move |request| {
                let shared = Arc::clone(&shared);
                async move { Ok::<_, Infallible>(handle(&shared, request).await) }
            });
            let connection = http1::Builder::new()
                .timer(TokioTimer::new())
                .header_read_timeout(Duration::from_secs(30))
                .serve_connection(TokioIo::new(stream), service);
            tokio::select! {
                _ = connection => {}
                () = shutdown.cancelled() => {}
            }
        });
    }
}

async fn handle(shared: &Shared, request: Request<Incoming>) -> Response<Body> {
    // A seek or track change can close an in-flight receiver request, and a
    // relayed source can fail; the receiver retries or reports the error.
    let mut response = respond(shared, &request)
        .await
        .unwrap_or_else(|_| status(StatusCode::BAD_GATEWAY));
    let headers = response.headers_mut();
    headers.insert(ACCESS_CONTROL_ALLOW_ORIGIN, HeaderValue::from_static("*"));
    headers.insert(
        ACCESS_CONTROL_ALLOW_HEADERS,
        HeaderValue::from_static("Range"),
    );
    headers.insert(
        ACCESS_CONTROL_EXPOSE_HEADERS,
        HeaderValue::from_static("Content-Range, Accept-Ranges"),
    );
    headers.insert(CACHE_CONTROL, HeaderValue::from_static("no-store"));
    response
}

async fn respond(shared: &Shared, request: &Request<Incoming>) -> io::Result<Response<Body>> {
    let source = request
        .uri()
        .path()
        .strip_prefix("/media/")
        .and_then(|token| {
            shared
                .sources
                .lock()
                .expect("cast media sources")
                .get(token)
                .cloned()
        });
    let Some(source) = source else {
        return Ok(status(StatusCode::NOT_FOUND));
    };
    let head = match *request.method() {
        Method::GET => false,
        Method::HEAD => true,
        Method::OPTIONS => {
            let mut response = status(StatusCode::NO_CONTENT);
            response.headers_mut().insert(
                ACCESS_CONTROL_ALLOW_METHODS,
                HeaderValue::from_static("GET, HEAD, OPTIONS"),
            );
            return Ok(response);
        }
        _ => return Ok(status(StatusCode::METHOD_NOT_ALLOWED)),
    };
    let range = request.headers().get(RANGE);
    match source.location {
        Location::File(path) => file(path, source.mime, range, head).await,
        Location::Url(uri) => relay(&shared.client, uri, source.mime, range, head).await,
    }
}

async fn file(
    path: PathBuf,
    mime: HeaderValue,
    range: Option<&HeaderValue>,
    head: bool,
) -> io::Result<Response<Body>> {
    let Ok(mut file) = tokio::fs::File::open(&path).await else {
        return Ok(status(StatusCode::NOT_FOUND));
    };
    let len = file.metadata().await?.len();
    let mut builder = Response::builder()
        .header(CONTENT_TYPE, mime)
        .header(ACCEPT_RANGES, "bytes");
    let range = range
        .and_then(|value| value.to_str().ok())
        .map_or(ByteRange::Full, |value| parse_range(value, len));
    let (start, end) = match range {
        ByteRange::Full => (0, len),
        ByteRange::Partial(start, last) => {
            builder = builder
                .status(StatusCode::PARTIAL_CONTENT)
                .header(CONTENT_RANGE, format!("bytes {start}-{last}/{len}"));
            (start, last + 1)
        }
        ByteRange::Unsatisfiable => {
            return builder
                .status(StatusCode::RANGE_NOT_SATISFIABLE)
                .header(CONTENT_RANGE, format!("bytes */{len}"))
                .body(empty())
                .map_err(io::Error::other);
        }
    };
    let body = if head || start == end {
        empty()
    } else {
        file.seek(SeekFrom::Start(start)).await?;
        reader_body(file.take(end - start))
    };
    builder
        .header(CONTENT_LENGTH, end - start)
        .body(body)
        .map_err(io::Error::other)
}

async fn relay(
    client: &RelayClient,
    uri: Uri,
    mime: HeaderValue,
    range: Option<&HeaderValue>,
    head: bool,
) -> io::Result<Response<Body>> {
    let mut upstream = Request::builder()
        .method(if head { Method::HEAD } else { Method::GET })
        .uri(uri)
        .header(ACCEPT_ENCODING, "identity");
    if let Some(range) = range {
        upstream = upstream.header(RANGE, range);
    }
    let reply = client
        .request(upstream.body(Empty::new()).map_err(io::Error::other)?)
        .await
        .map_err(io::Error::other)?;
    let mut builder = Response::builder()
        .status(reply.status())
        .header(CONTENT_TYPE, mime);
    for name in [CONTENT_RANGE, ACCEPT_RANGES, CONTENT_LENGTH] {
        if let Some(value) = reply.headers().get(&name) {
            builder = builder.header(name, value);
        }
    }
    let body = if head {
        empty()
    } else {
        reply.into_body().map_err(io::Error::other).boxed()
    };
    builder.body(body).map_err(io::Error::other)
}

fn reader_body(reader: impl AsyncRead + Send + Sync + 'static) -> Body {
    BodyExt::boxed(StreamBody::new(
        ReaderStream::with_capacity(reader, CHUNK).map_ok(Frame::data),
    ))
}

fn empty() -> Body {
    Empty::new().map_err(|never| match never {}).boxed()
}

fn status(code: StatusCode) -> Response<Body> {
    let mut response = Response::new(empty());
    *response.status_mut() = code;
    response
}

/// The answer to a `Range` header for a `len`-byte file.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum ByteRange {
    /// No usable range: send everything (also for multi-range requests).
    Full,
    /// Inclusive byte positions.
    Partial(u64, u64),
    Unsatisfiable,
}

fn parse_range(header: &str, len: u64) -> ByteRange {
    let header = header.trim();
    let Some(spec) = header
        .get(..6)
        .filter(|unit| unit.eq_ignore_ascii_case("bytes="))
        .map(|_| &header[6..])
    else {
        return ByteRange::Full;
    };
    let Some((first, last)) = spec.split_once('-').filter(|_| !spec.contains(',')) else {
        return ByteRange::Full;
    };
    let (first, last) = (first.trim(), last.trim());
    if first.is_empty() {
        return match last.parse::<u64>() {
            Ok(0) => ByteRange::Unsatisfiable,
            Ok(_) if len == 0 => ByteRange::Unsatisfiable,
            Ok(suffix) => ByteRange::Partial(len.saturating_sub(suffix), len - 1),
            Err(_) => ByteRange::Full,
        };
    }
    let Ok(start) = first.parse::<u64>() else {
        return ByteRange::Full;
    };
    let end = if last.is_empty() {
        u64::MAX
    } else {
        match last.parse::<u64>() {
            Ok(end) if end >= start => end,
            _ => return ByteRange::Full,
        }
    };
    if start >= len {
        return ByteRange::Unsatisfiable;
    }
    ByteRange::Partial(start, end.min(len - 1))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ranges_follow_rfc_9110_single_ranges() {
        assert_eq!(parse_range("bytes=1-2", 4), ByteRange::Partial(1, 2));
        assert_eq!(parse_range("bytes=2-", 4), ByteRange::Partial(2, 3));
        assert_eq!(parse_range("bytes=-1", 4), ByteRange::Partial(3, 3));
        assert_eq!(parse_range("bytes=-10", 4), ByteRange::Partial(0, 3));
        assert_eq!(parse_range("bytes=1-99", 4), ByteRange::Partial(1, 3));
        assert_eq!(parse_range("bytes=4-", 4), ByteRange::Unsatisfiable);
        assert_eq!(parse_range("bytes=-0", 4), ByteRange::Unsatisfiable);
        assert_eq!(parse_range("bytes=0-1,2-3", 4), ByteRange::Full);
        assert_eq!(parse_range("items=0-1", 4), ByteRange::Full);
        assert_eq!(parse_range("bytes=3-1", 4), ByteRange::Full);
    }

    #[test]
    fn file_urls_decode_to_paths() {
        assert_eq!(percent_decode("/a%20b/%E3%81%82.flac"), "/a b/あ.flac");
        assert_eq!(percent_decode("/100%"), "/100%");
    }
}
