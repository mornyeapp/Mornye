//! The media server over real sockets: files with ranges, relays, and the
//! headers DLNA renderers look for.

use mornye_cast::MediaServer;
use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};

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
    let range = range.map(|value| ("Range", value));
    fetch_with(url, method, range.as_slice())
}

fn fetch_with(url: &str, method: &str, headers: &[(&str, &str)]) -> Reply {
    let rest = url.strip_prefix("http://").unwrap();
    let (host, path) = rest.split_once('/').unwrap();
    let mut stream = TcpStream::connect(host).unwrap();
    let headers: String = headers
        .iter()
        .map(|(name, value)| format!("{name}: {value}\r\n"))
        .collect();
    write!(
        stream,
        "{method} /{path} HTTP/1.1\r\nHost: {host}\r\n{headers}Connection: close\r\n\r\n"
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

/// A source that refuses HEAD, as some streaming servers do.
fn source_without_head() -> String {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let address = listener.local_addr().unwrap();
    std::thread::spawn(move || {
        // HEAD, the GET standing in for it, and a real GET.
        for stream in listener.incoming().take(3) {
            let mut stream = stream.unwrap();
            let mut request = [0u8; 2048];
            let read = stream.read(&mut request).unwrap();
            let reply = if request[..read].starts_with(b"HEAD") {
                "HTTP/1.1 405 Method Not Allowed\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            } else {
                "HTTP/1.1 200 OK\r\nContent-Length: 4\r\nConnection: close\r\n\r\nabcd"
            };
            stream.write_all(reply.as_bytes()).unwrap();
        }
    });
    format!("http://{address}/song")
}

#[tokio::test(flavor = "multi_thread")]
async fn dlna_renderers_get_their_headers_and_cast_receivers_do_not() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("song.flac");
    std::fs::write(&path, vec![7u8; 5000]).unwrap();
    let server = MediaServer::bind("127.0.0.1".parse().unwrap())
        .await
        .unwrap();
    let song = server
        .register(path.to_str().unwrap(), "audio/flac")
        .unwrap();
    let cover = server
        .register(path.to_str().unwrap(), "image/jpeg")
        .unwrap();
    let relayed = server
        .register(&source_without_head(), "audio/mpeg")
        .unwrap();
    let (song, cover, relayed, server) = tokio::task::spawn_blocking(move || {
        let plain = fetch(&song, "GET", None);
        assert_eq!(plain.status, 200);
        assert_eq!(plain.header("contentFeatures.dlna.org"), None);
        assert_eq!(plain.header("transferMode.dlna.org"), None);

        let asked = fetch_with(
            &song,
            "HEAD",
            &[
                ("getcontentFeatures.dlna.org", "1"),
                ("transferMode.dlna.org", "streaming"),
            ],
        );
        assert_eq!(asked.status, 200);
        assert_eq!(asked.header("content-length"), Some("5000"));
        assert_eq!(asked.header("content-type"), Some("audio/flac"));
        assert_eq!(asked.header("transferMode.dlna.org"), Some("Streaming"));
        assert_eq!(
            asked.header("contentFeatures.dlna.org"),
            Some("DLNA.ORG_OP=01;DLNA.ORG_CI=0;DLNA.ORG_FLAGS=01700000000000000000000000000000")
        );
        let ranged = fetch_with(
            &song,
            "GET",
            &[("Range", "bytes=0-"), ("getcontentFeatures.dlna.org", "1")],
        );
        assert_eq!(ranged.status, 206);
        assert_eq!(ranged.header("content-range"), Some("bytes 0-4999/5000"));
        assert!(ranged.header("contentFeatures.dlna.org").is_some());

        let timed = fetch_with(&song, "GET", &[("TimeSeekRange.dlna.org", "npt=10.0-")]);
        assert_eq!(timed.status, 406, "only byte ranges are offered");

        server.set_dlna(true);
        let image = fetch(&cover, "GET", None);
        assert_eq!(image.header("transferMode.dlna.org"), Some("Interactive"));
        assert!(
            image
                .header("contentFeatures.dlna.org")
                .unwrap()
                .contains("DLNA.ORG_FLAGS=00F")
        );
        let head = fetch(&relayed, "HEAD", None);
        assert_eq!(
            head.status, 200,
            "a source without HEAD answers its GET headers"
        );
        assert_eq!(head.header("content-length"), Some("4"));
        assert!(head.body.is_empty());
        assert_eq!(head.header("transferMode.dlna.org"), Some("Streaming"));
        assert_eq!(fetch(&relayed, "GET", None).body, b"abcd");
        (song, cover, relayed, server)
    })
    .await
    .unwrap();
    drop((song, cover, relayed, server));
}
