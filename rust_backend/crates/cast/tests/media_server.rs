//! The media server over real sockets: files with ranges, and relays.

use mornye_cast::MediaServer;
use std::io::{Read, Write};
use std::net::TcpStream;

struct Reply {
    status: u16,
    headers: Vec<(String, String)>,
    body: Vec<u8>,
}

impl Reply {
    fn header(&self, name: &str) -> Option<&str> {
        self.headers
            .iter()
            .find(|(key, _)| key.eq_ignore_ascii_case(name))
            .map(|(_, value)| value.as_str())
    }
}

/// One request on its own connection (`Connection: close`), read to the end.
fn fetch(url: &str, method: &str, range: Option<&str>) -> Reply {
    let rest = url.strip_prefix("http://").unwrap();
    let (host, path) = rest.split_once('/').unwrap();
    let mut stream = TcpStream::connect(host).unwrap();
    let range = range
        .map(|value| format!("Range: {value}\r\n"))
        .unwrap_or_default();
    write!(
        stream,
        "{method} /{path} HTTP/1.1\r\nHost: {host}\r\n{range}Connection: close\r\n\r\n"
    )
    .unwrap();
    let mut raw = Vec::new();
    stream.read_to_end(&mut raw).unwrap();
    let split = raw
        .windows(4)
        .position(|window| window == b"\r\n\r\n")
        .unwrap();
    let head = String::from_utf8(raw[..split].to_vec()).unwrap();
    let mut lines = head.split("\r\n");
    let status = lines
        .next()
        .unwrap()
        .split(' ')
        .nth(1)
        .unwrap()
        .parse()
        .unwrap();
    let headers = lines
        .filter_map(|line| line.split_once(':'))
        .map(|(key, value)| (key.to_owned(), value.trim().to_owned()))
        .collect();
    Reply {
        status,
        headers,
        body: raw[split + 4..].to_vec(),
    }
}

#[tokio::test(flavor = "multi_thread")]
async fn files_stream_whole_or_by_range_and_relays_pass_ranges_through() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("song one.flac");
    let content: Vec<u8> = (0..100_000u32).map(|index| (index % 251) as u8).collect();
    std::fs::write(&path, &content).unwrap();
    let server = MediaServer::bind("127.0.0.1".parse().unwrap())
        .await
        .unwrap();
    let url = server
        .register(path.to_str().unwrap(), "audio/flac")
        .unwrap();
    let file_url = format!("file://{}", path.to_str().unwrap().replace(' ', "%20"));
    let by_file_url = server.register(&file_url, "audio/flac").unwrap();
    let relayed = server.register(&url, "audio/flac").unwrap();
    assert_ne!(url, relayed, "every registration gets its own token");

    let results = tokio::task::spawn_blocking(move || {
        let whole = fetch(&url, "GET", None);
        assert_eq!(whole.status, 200);
        assert_eq!(whole.header("content-type"), Some("audio/flac"));
        assert_eq!(whole.header("accept-ranges"), Some("bytes"));
        assert_eq!(whole.header("access-control-allow-origin"), Some("*"));
        assert_eq!(whole.body, content);

        let part = fetch(&url, "GET", Some("bytes=1000-1999"));
        assert_eq!(part.status, 206);
        assert_eq!(part.header("content-range"), Some("bytes 1000-1999/100000"));
        assert_eq!(part.body, content[1000..2000]);

        let tail = fetch(&by_file_url, "GET", Some("bytes=-10"));
        assert_eq!(tail.body, content[99_990..]);

        let head = fetch(&url, "HEAD", None);
        assert_eq!(head.header("content-length"), Some("100000"));
        assert!(head.body.is_empty());

        let past = fetch(&url, "GET", Some("bytes=100000-"));
        assert_eq!(past.status, 416);
        assert_eq!(past.header("content-range"), Some("bytes */100000"));

        let relay = fetch(&relayed, "GET", Some("bytes=50000-50009"));
        assert_eq!(relay.status, 206);
        assert_eq!(
            relay.header("content-range"),
            Some("bytes 50000-50009/100000")
        );
        assert_eq!(relay.body, content[50_000..50_010]);

        let unknown = fetch(&url.replace("/media/", "/media/0"), "GET", None);
        assert_eq!(unknown.status, 404);
        let post = fetch(&url, "POST", None);
        assert_eq!(post.status, 405);
        (url, relayed)
    })
    .await
    .unwrap();

    server.clear();
    let (url, relayed) = results;
    let gone = tokio::task::spawn_blocking(move || {
        (
            fetch(&url, "GET", None).status,
            fetch(&relayed, "GET", None).status,
        )
    })
    .await
    .unwrap();
    assert_eq!(gone, (404, 404), "cleared URLs stop working");
}
