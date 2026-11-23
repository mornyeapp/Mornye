//! A minimal HTTP/1.1 client for devices on the local network: one request
//! per connection, an IP address only (no DNS), and every answer bounded in
//! time and size so a broken device cannot hold a call or fill memory.

use bytes::Bytes;
use http::{Method, Request, StatusCode, header};
use http_body_util::{BodyExt, Full, Limited};
use hyper_util::rt::TokioIo;
use std::io;
use std::net::{IpAddr, SocketAddr};
use std::time::Duration;
use tokio::net::TcpStream;
use tokio::task::JoinHandle;
use url::{Position, Url};

pub(crate) struct Reply {
    pub(crate) status: StatusCode,
    pub(crate) body: String,
}

/// Where `url` points: an `http` URL with an IP address host.
pub(crate) fn address(url: &Url) -> io::Result<SocketAddr> {
    let invalid = || io::Error::new(io::ErrorKind::InvalidInput, "not a local device address");
    if url.scheme() != "http" {
        return Err(invalid());
    }
    let host = match url.host() {
        Some(url::Host::Ipv4(ip)) => IpAddr::V4(ip),
        Some(url::Host::Ipv6(ip)) => IpAddr::V6(ip),
        _ => return Err(invalid()),
    };
    Ok(SocketAddr::new(host, url.port().unwrap_or(80)))
}

/// Sends one request and reads at most `limit` bytes of the answer, all
/// within `timeout`.
pub(crate) async fn request(
    method: Method,
    url: &Url,
    headers: &[(&str, &str)],
    body: String,
    limit: usize,
    timeout: Duration,
) -> io::Result<Reply> {
    let target = address(url)?;
    tokio::time::timeout(timeout, exchange(method, url, target, headers, body, limit))
        .await
        .map_err(|_| io::Error::new(io::ErrorKind::TimedOut, "the device did not answer"))?
}

async fn exchange(
    method: Method,
    url: &Url,
    target: SocketAddr,
    headers: &[(&str, &str)],
    body: String,
    limit: usize,
) -> io::Result<Reply> {
    let stream = TcpStream::connect(target).await?;
    let _ = stream.set_nodelay(true);
    // Title case for devices that compare header names exactly.
    let (mut sender, connection) = hyper::client::conn::http1::Builder::new()
        .title_case_headers(true)
        .handshake(TokioIo::new(stream))
        .await
        .map_err(io::Error::other)?;
    let _driver = Abort(tokio::spawn(connection));
    let host = match target {
        SocketAddr::V4(_) => target.to_string(),
        SocketAddr::V6(v6) => format!("[{}]:{}", v6.ip(), v6.port()),
    };
    let mut builder = Request::builder()
        .method(method)
        .uri(&url[Position::BeforePath..])
        .header(header::HOST, host)
        .header(header::CONNECTION, "close")
        .header(header::CONTENT_LENGTH, body.len());
    for (name, value) in headers {
        builder = builder.header(*name, *value);
    }
    let request = builder
        .body(Full::new(Bytes::from(body)))
        .map_err(io::Error::other)?;
    let response = sender
        .send_request(request)
        .await
        .map_err(io::Error::other)?;
    let status = response.status();
    let bytes = Limited::new(response.into_body(), limit)
        .collect()
        .await
        .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error.to_string()))?
        .to_bytes();
    Ok(Reply {
        status,
        body: String::from_utf8_lossy(&bytes).into_owned(),
    })
}

/// Ends the connection task with the request, whatever happens to it.
struct Abort(JoinHandle<Result<(), hyper::Error>>);

impl Drop for Abort {
    fn drop(&mut self) {
        self.0.abort();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    use tokio::net::TcpListener;

    async fn serve_once(answer: &'static [u8]) -> Url {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let url = Url::parse(&format!("http://{}/x", listener.local_addr().unwrap())).unwrap();
        tokio::spawn(async move {
            let (mut stream, _) = listener.accept().await.unwrap();
            let mut buffer = [0u8; 2048];
            let _ = stream.read(&mut buffer).await;
            let _ = stream.write_all(answer).await;
            // Hold the connection open, as a stuck device would.
            tokio::time::sleep(Duration::from_secs(5)).await;
        });
        url
    }

    #[tokio::test]
    async fn answers_are_bounded_in_size_and_time() {
        let url = serve_once(b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok").await;
        let reply = request(
            Method::GET,
            &url,
            &[],
            String::new(),
            64,
            Duration::from_secs(2),
        )
        .await
        .unwrap();
        assert_eq!((reply.status, reply.body.as_str()), (StatusCode::OK, "ok"));

        let url = serve_once(b"HTTP/1.1 200 OK\r\nContent-Length: 100\r\n\r\n0123456789").await;
        let large = request(
            Method::GET,
            &url,
            &[],
            String::new(),
            4,
            Duration::from_secs(2),
        );
        assert!(large.await.is_err(), "a body over the limit is refused");

        let url = serve_once(b"HTTP/1.1 200 OK\r\nContent-Length: 100\r\n\r\nslow").await;
        let started = std::time::Instant::now();
        let stuck = request(
            Method::GET,
            &url,
            &[],
            String::new(),
            1024,
            Duration::from_millis(200),
        );
        assert!(stuck.await.is_err());
        assert!(started.elapsed() < Duration::from_secs(2));
    }

    #[test]
    fn only_http_ip_addresses_are_used() {
        let parse = |text: &str| address(&Url::parse(text).unwrap()).map(|a| a.to_string());
        assert_eq!(
            parse("http://192.0.2.1:49152/d.xml").unwrap(),
            "192.0.2.1:49152"
        );
        assert_eq!(parse("http://192.0.2.1/d.xml").unwrap(), "192.0.2.1:80");
        assert!(parse("https://192.0.2.1/").is_err());
        assert!(parse("http://renderer.local/").is_err());
    }
}
