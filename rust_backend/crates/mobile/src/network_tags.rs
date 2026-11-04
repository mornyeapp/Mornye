//! Bounded, seekable metadata reads through the app's authenticated loopback
//! proxy. The native reader never receives NAS credentials or external URLs.
use base64::Engine;
use mornye_core::fs::{DEFAULT_TEMP_PREFIX, OpenOptionsPortableExt, write_atomic};
use mornye_core::{lower_hex, tags};
use mornye_network::{
    HttpRequest, NetworkService, NetworkSession, policy::NetworkPermissions, url::UrlParts,
};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::{
    collections::{BTreeMap, VecDeque},
    fs::{self, File},
    io::{self, Read, Seek, SeekFrom, Write},
    path::Path,
    sync::{Arc, OnceLock},
    time::{Duration, Instant, SystemTime},
};

const BLOCK: u64 = 256 * 1024;
const MAX_BYTES: usize = 16 * 1024 * 1024;
const MAX_REQUESTS: usize = 80;
const DEADLINE: Duration = Duration::from_secs(20);

fn proxy_session(url: &str, timeout: Duration) -> Result<NetworkSession, String> {
    let parsed = UrlParts::parse(url).ok_or("invalid network proxy URL")?;
    // Playback routes carry an optional file-type hint for native players.
    let mut route = parsed
        .path
        .strip_prefix(b"/")
        .unwrap_or_default()
        .splitn(2, |byte| *byte == b'.');
    let token = route.next().unwrap_or_default();
    let valid_suffix = route.next().is_none_or(|suffix| {
        (1..=10).contains(&suffix.len())
            && suffix
                .iter()
                .all(|byte| byte.is_ascii_lowercase() || byte.is_ascii_digit())
    });
    if parsed.scheme != "http"
        || parsed.hostname != "127.0.0.1"
        || parsed.port.is_none()
        || parsed.has_credentials
        || !parsed.raw_query.is_empty()
        || !parsed.fragment.is_empty()
        || !valid_suffix
        || token.len() != 48
        || !token.iter().all(u8::is_ascii_hexdigit)
    {
        return Err("URL must reference the local network proxy".into());
    }
    static NETWORK: OnceLock<Result<Arc<NetworkService>, String>> = OnceLock::new();
    let service = NETWORK
        .get_or_init(|| {
            let service = NetworkService::new().map_err(|e| e.to_string())?;
            service.set_allow_private_network(true);
            Ok(service)
        })
        .as_ref()
        .map_err(Clone::clone)?;
    Ok(service
        .session(
            NetworkPermissions {
                domains: vec!["127.0.0.1".into()],
                allow_http: true,
            },
            timeout,
        )
        .direct_media())
}

/// Reconcile a lost NAS rename response with streamed bytes. Credentials and
/// pins remain inside the app's existing proxy; neither file crosses Flutter.
pub(crate) fn matches_upload(
    request: &Value,
    check: &dyn Fn() -> Result<(), String>,
) -> Result<Value, String> {
    check()?;
    let url = crate::data_jobs::string(request, "url")?;
    let path = crate::data_jobs::string(request, "path")?;
    let length = request["length"].as_u64().ok_or("Missing upload length")?;
    let idle = request["idle_timeout_ms"]
        .as_u64()
        .filter(|ms| *ms > 0 && *ms <= 300_000)
        .ok_or("Invalid upload idle timeout")?;
    let metadata = fs::metadata(path).map_err(|error| error.to_string())?;
    if !metadata.is_file() || metadata.len() != length {
        return Ok(json!({"matches": false}));
    }
    let idle = Duration::from_millis(idle);
    let session = proxy_session(url, idle)?;
    let mut stream = session.open_stream(
        HttpRequest {
            url: url.into(),
            method: "GET".into(),
            body: String::new(),
            headers: BTreeMap::from([("Accept-Encoding".into(), "identity".into())]),
            default_json: false,
            user_agent: "Mornye/NetworkUploadRecovery".into(),
        },
        Duration::from_secs(u32::MAX.into()),
        idle,
        check,
    )?;
    let header = |name: &str| {
        stream
            .response
            .headers
            .iter()
            .find(|(key, _)| key.eq_ignore_ascii_case(name))
            .and_then(|(_, values)| values.first())
            .map(String::as_str)
    };
    if stream.response.status != 200
        || header("content-length")
            .and_then(|value| value.parse::<u64>().ok())
            .is_some_and(|value| value != length)
        || header("content-encoding").is_some_and(|value| !value.eq_ignore_ascii_case("identity"))
    {
        return Ok(json!({"matches": false}));
    }
    let mut hash = Sha256::new();
    let mut buffer = [0; 64 * 1024];
    let mut received = 0_u64;
    loop {
        check()?;
        let count = stream.read(&mut buffer, check)?;
        if count == 0 {
            break;
        }
        received = received
            .checked_add(count as u64)
            .ok_or("Upload length overflow")?;
        if received > length {
            return Err("Network destination changed".into());
        }
        hash.update(&buffer[..count]);
    }
    if received != length {
        return Ok(json!({"matches": false}));
    }
    let remote = lower_hex(&hash.finalize());
    let local = crate::data_jobs::hash_file(path, check)?;
    check()?;
    Ok(json!({"matches": remote == local}))
}

pub(crate) fn read(
    url: &str,
    hint: &str,
    check: &dyn Fn() -> Result<(), String>,
) -> Result<Value, String> {
    read_internal(url, hint, None, check)
}

pub(crate) fn read_to_cache(
    url: &str,
    hint: &str,
    cache_directory: &str,
    check: &dyn Fn() -> Result<(), String>,
) -> Result<Value, String> {
    read_internal(url, hint, Some(Path::new(cache_directory)), check)
}

fn read_internal(
    url: &str,
    hint: &str,
    cache_directory: Option<&Path>,
    check: &dyn Fn() -> Result<(), String>,
) -> Result<Value, String> {
    let mut reader = RangeReader::new(url, check)?;
    let mut metadata = tags::read_file_metadata(&mut reader, hint, hint, check)?;
    let extension = tags::file_metadata_extension(hint, hint)?;
    if let Ok(cover) = tags::extract_cover(&mut reader, &extension[1..], check)
        && !cover.data.is_empty()
        && cover.data.len() <= 4 * 1024 * 1024
    {
        if let Some(directory) = cache_directory {
            // Artwork I/O failures preserve successfully parsed tags/lyrics.
            if let Ok((path, digest)) = cache_cover(&cover.data, directory, check) {
                metadata["cover_path"] = path.into();
                metadata["cover_sha256"] = digest.into();
            }
        } else {
            metadata["cover_base64"] = base64::engine::general_purpose::STANDARD
                .encode(cover.data)
                .into();
        }
    }
    check()?;
    Ok(metadata)
}

fn cache_cover(
    bytes: &[u8],
    directory: &Path,
    check: &dyn Fn() -> Result<(), String>,
) -> Result<(String, String), String> {
    check()?;
    if !directory.is_absolute() {
        return Err("Artwork cache must be absolute".into());
    }
    fs::create_dir_all(directory).map_err(|error| error.to_string())?;
    let digest = lower_hex(&Sha256::digest(bytes));
    let target = directory.join(format!("network_cover_{digest}.image"));
    if renew_cached(&target, bytes) {
        return Ok((target.to_string_lossy().into_owned(), digest));
    }
    write_atomic(
        directory,
        &target,
        DEFAULT_TEMP_PREFIX,
        |file| file.write_all(bytes),
        || check().map_err(io::Error::other),
        false,
    )
    .map_err(|error| error.to_string())?;
    let mut files = fs::read_dir(directory)
        .map_err(|error| error.to_string())?
        .filter_map(Result::ok)
        .filter_map(|entry| {
            let name = entry.file_name();
            let name = name.to_string_lossy();
            let legacy = name.strip_suffix(".image").is_some_and(|digest| {
                digest.len() == 64 && digest.bytes().all(|byte| byte.is_ascii_hexdigit())
            });
            if cover_digest(&name).is_none() && !legacy {
                return None;
            }
            let metadata = entry.metadata().ok()?;
            if !metadata.is_file() {
                return None;
            }
            Some((entry.path(), metadata.modified().ok()?))
        })
        .collect::<Vec<_>>();
    files.sort_by_key(|(_, time)| std::cmp::Reverse(*time));
    for (old, _) in files.into_iter().skip(32) {
        if old != target {
            let _ = fs::remove_file(old);
        }
    }
    Ok((target.to_string_lossy().into_owned(), digest))
}

/// Whether `path` already holds `bytes`. Its modification time is then
/// renewed, as a rewrite would, so the trim keeps it among the newest files.
fn renew_cached(path: &Path, bytes: &[u8]) -> bool {
    let Ok(mut file) = File::options()
        .read(true)
        .write(true)
        .nofollow_nonblock()
        .open(path)
    else {
        return false;
    };
    let mut cached = Vec::with_capacity(bytes.len());
    file.metadata()
        .is_ok_and(|metadata| metadata.is_file() && metadata.len() == bytes.len() as u64)
        && (&mut file)
            .take(bytes.len() as u64 + 1)
            .read_to_end(&mut cached)
            .is_ok()
        && cached == bytes
        && file.set_modified(SystemTime::now()).is_ok()
        // A concurrent trim may have removed the name before it was renewed.
        && fs::symlink_metadata(path).is_ok_and(|metadata| metadata.is_file())
}

fn cover_digest(name: &str) -> Option<&str> {
    let digest = name
        .strip_prefix("network_cover_")?
        .strip_suffix(".image")?;
    (digest.len() == 64 && digest.bytes().all(|byte| byte.is_ascii_hexdigit())).then_some(digest)
}

pub(crate) fn promote_cover(
    path: &str,
    directory: &str,
    check: &dyn Fn() -> Result<(), String>,
) -> Result<Value, String> {
    check()?;
    let source = Path::new(path);
    let destination = Path::new(directory);
    if !source.is_absolute() || !destination.is_absolute() {
        return Err("Artwork paths must be absolute".into());
    }
    if !source
        .metadata()
        .is_ok_and(|metadata| metadata.is_file() && metadata.len() > 0)
    {
        return Err("Artwork input must be a nonempty regular file".into());
    }
    // Only our immutable content-addressed cache skips a second hash. Older
    // cache filenames use the same streamed hash as the previous Dart caller.
    let digest = source
        .parent()
        .filter(|parent| {
            parent
                .file_name()
                .is_some_and(|name| name == "network_metadata")
        })
        .and_then(|_| source.file_name())
        .and_then(|name| name.to_str())
        .and_then(cover_digest)
        .map(str::to_owned)
        .map(Ok)
        .unwrap_or_else(|| crate::data_jobs::hash_file(path, check))?;
    fs::create_dir_all(destination).map_err(|error| error.to_string())?;
    let target = destination.join(format!("network_cover_{digest}.image"));
    if !target
        .metadata()
        .is_ok_and(|metadata| metadata.is_file() && metadata.len() > 0)
    {
        let mut input = File::open(source).map_err(|error| error.to_string())?;
        if !input
            .metadata()
            .map_err(|error| error.to_string())?
            .is_file()
        {
            return Err("Artwork input must be a regular file".into());
        }
        write_atomic(
            destination,
            &target,
            DEFAULT_TEMP_PREFIX,
            |file| {
                let mut buffer = [0; 64 * 1024];
                loop {
                    check().map_err(io::Error::other)?;
                    let count = input.read(&mut buffer)?;
                    if count == 0 {
                        return Ok(());
                    }
                    file.write_all(&buffer[..count])?;
                }
            },
            || check().map_err(io::Error::other),
            false,
        )
        .map_err(|error| error.to_string())?;
    }
    Ok(json!({"cover_path": target.to_string_lossy(), "sha256": digest}))
}

struct RangeReader<'a> {
    url: String,
    session: NetworkSession,
    check: &'a dyn Fn() -> Result<(), String>,
    started: Instant,
    size: u64,
    position: u64,
    requests: usize,
    transferred: usize,
    blocks: VecDeque<(u64, Vec<u8>)>,
}

impl<'a> RangeReader<'a> {
    fn new(url: &str, check: &'a dyn Fn() -> Result<(), String>) -> Result<Self, String> {
        let session = proxy_session(url, DEADLINE)?;
        let mut reader = Self {
            url: url.into(),
            session,
            check,
            started: Instant::now(),
            size: 0,
            position: 0,
            requests: 0,
            transferred: 0,
            blocks: VecDeque::new(),
        };
        reader.fetch(0).map_err(|e| e.to_string())?;
        Ok(reader)
    }

    fn check_budget(&self) -> io::Result<()> {
        (self.check)().map_err(io::Error::other)?;
        if self.started.elapsed() >= DEADLINE
            || self.requests >= MAX_REQUESTS
            || self.transferred >= MAX_BYTES
        {
            return Err(io::Error::other("network metadata read budget exceeded"));
        }
        Ok(())
    }

    fn fetch(&mut self, offset: u64) -> io::Result<()> {
        self.check_budget()?;
        self.requests += 1;
        let end = if self.size == 0 {
            offset + BLOCK - 1
        } else {
            (offset + BLOCK - 1).min(self.size - 1)
        };
        let request = HttpRequest {
            url: self.url.clone(),
            method: "GET".into(),
            body: String::new(),
            headers: BTreeMap::from([
                ("Range".into(), format!("bytes={offset}-{end}")),
                ("Accept-Encoding".into(), "identity".into()),
            ]),
            default_json: false,
            user_agent: "Mornye/NetworkMetadata".into(),
        };
        let mut stream = self
            .session
            .open_stream(request, DEADLINE, DEADLINE, || {
                (self.check)()?;
                if self.started.elapsed() >= DEADLINE {
                    Err("metadata timeout".into())
                } else {
                    Ok(())
                }
            })
            .map_err(io::Error::other)?;
        let header = |name: &str| {
            stream
                .response
                .headers
                .iter()
                .find(|(k, _)| k.eq_ignore_ascii_case(name))
                .and_then(|(_, values)| values.first())
                .map(String::as_str)
        };
        let (size, length) = if stream.response.status == 206 {
            let range = header("content-range")
                .and_then(|s| s.strip_prefix("bytes "))
                .ok_or_else(|| io::Error::other("missing metadata range"))?;
            let (span, total) = range
                .split_once('/')
                .ok_or_else(|| io::Error::other("invalid range"))?;
            let (first, last) = span
                .split_once('-')
                .ok_or_else(|| io::Error::other("invalid range"))?;
            let first = first.parse::<u64>().map_err(io::Error::other)?;
            let last = last.parse::<u64>().map_err(io::Error::other)?;
            let size = total.parse::<u64>().map_err(io::Error::other)?;
            if first != offset || last < first || last > end || last >= size {
                return Err(io::Error::other(
                    "server returned an inconsistent metadata range",
                ));
            }
            (size, (last - first + 1) as usize)
        } else if stream.response.status == 200 && offset == 0 {
            let size = header("content-length")
                .and_then(|s| s.parse::<u64>().ok())
                .filter(|size| *size > 0 && *size <= BLOCK)
                .ok_or_else(|| io::Error::other("server must support byte ranges for metadata"))?;
            (size, size as usize)
        } else {
            return Err(io::Error::other("metadata byte range unavailable"));
        };
        if self.size != 0 && self.size != size {
            return Err(io::Error::other("remote file changed during metadata read"));
        }
        self.size = size;
        let mut bytes = vec![0; length];
        let mut count = 0;
        while count < length {
            self.check_budget()?;
            let n = stream
                .read(&mut bytes[count..], || (self.check)())
                .map_err(io::Error::other)?;
            if n == 0 {
                return Err(io::Error::new(
                    io::ErrorKind::UnexpectedEof,
                    "short metadata range",
                ));
            }
            count += n;
            self.transferred += n;
        }
        if self.blocks.len() >= 32 {
            self.blocks.pop_front();
        }
        self.blocks.push_back((offset, bytes));
        Ok(())
    }
}

impl Read for RangeReader<'_> {
    fn read(&mut self, output: &mut [u8]) -> io::Result<usize> {
        if output.is_empty() || self.position >= self.size {
            return Ok(0);
        }
        self.check_budget()?;
        let block = self.position / BLOCK * BLOCK;
        if !self.blocks.iter().any(|(start, _)| *start == block) {
            self.fetch(block)?;
        }
        let (_, bytes) = self
            .blocks
            .iter()
            .find(|(start, _)| *start == block)
            .expect("fetched block");
        let index = (self.position - block) as usize;
        if index >= bytes.len() {
            return Err(io::Error::other("incomplete metadata range"));
        }
        let count = output.len().min(bytes.len() - index);
        output[..count].copy_from_slice(&bytes[index..index + count]);
        self.position += count as u64;
        Ok(count)
    }
}

impl Seek for RangeReader<'_> {
    fn seek(&mut self, position: SeekFrom) -> io::Result<u64> {
        let next = match position {
            SeekFrom::Start(n) => i128::from(n),
            SeekFrom::Current(n) => i128::from(self.position) + i128::from(n),
            SeekFrom::End(n) => i128::from(self.size) + i128::from(n),
        };
        self.position =
            u64::try_from(next).map_err(|_| io::Error::other("invalid metadata seek"))?;
        Ok(self.position)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{
        io::{BufRead, BufReader, Write},
        net::TcpListener,
        sync::atomic::{AtomicBool, AtomicUsize, Ordering},
        thread,
    };

    struct Fixture {
        url: String,
        bytes: Arc<AtomicUsize>,
        stop: Arc<AtomicBool>,
        thread: Option<thread::JoinHandle<()>>,
    }
    impl Fixture {
        fn new(data: Vec<u8>, ranges: bool) -> Self {
            let listener = TcpListener::bind("127.0.0.1:0").unwrap();
            let address = listener.local_addr().unwrap();
            listener.set_nonblocking(true).unwrap();
            let stop = Arc::new(AtomicBool::new(false));
            let bytes = Arc::new(AtomicUsize::new(0));
            let done = stop.clone();
            let transferred = bytes.clone();
            let handle = thread::spawn(move || {
                while !done.load(Ordering::Relaxed) {
                    let Ok((mut socket, _)) = listener.accept() else {
                        thread::sleep(Duration::from_millis(2));
                        continue;
                    };
                    // BSD may inherit the listener's nonblocking flag. The
                    // fixture reads complete request headers with a timeout.
                    socket.set_nonblocking(false).unwrap();
                    socket
                        .set_read_timeout(Some(Duration::from_secs(2)))
                        .unwrap();
                    let mut reader = BufReader::new(socket.try_clone().unwrap());
                    let mut line = String::new();
                    let mut range = (0, data.len() - 1);
                    let mut headers_complete = false;
                    loop {
                        line.clear();
                        if reader.read_line(&mut line).unwrap_or(0) == 0 {
                            break;
                        }
                        if line == "\r\n" {
                            headers_complete = true;
                            break;
                        }
                        if let Some(value) = line.to_lowercase().strip_prefix("range: bytes=") {
                            let (start, end) = value.trim().split_once('-').unwrap();
                            range = (
                                start.parse().unwrap(),
                                end.parse::<usize>().unwrap().min(data.len() - 1),
                            );
                        }
                    }
                    // A connector may abandon an idle socket before sending a
                    // request. Sending a response after EOF/timeout produces an
                    // unsolicited HTTP message and a spurious client failure.
                    if !headers_complete {
                        continue;
                    }
                    if !ranges {
                        range = (0, data.len() - 1);
                    }
                    let body = &data[range.0..=range.1];
                    let header = if ranges {
                        format!(
                            "HTTP/1.1 206 Partial Content\r\nContent-Range: bytes {}-{}/{}\r\n",
                            range.0,
                            range.1,
                            data.len()
                        )
                    } else {
                        "HTTP/1.1 200 OK\r\n".into()
                    };
                    let _ = write!(
                        socket,
                        "{header}Content-Length: {}\r\nConnection: close\r\n\r\n",
                        body.len()
                    );
                    if socket.write_all(body).is_ok() {
                        transferred.fetch_add(body.len(), Ordering::Relaxed);
                    }
                }
            });
            Self {
                url: format!("http://{address}/{}", "a".repeat(48)),
                bytes,
                stop,
                thread: Some(handle),
            }
        }
    }
    impl Drop for Fixture {
        fn drop(&mut self) {
            self.stop.store(true, Ordering::Relaxed);
            self.thread.take().unwrap().join().unwrap();
        }
    }
    fn atom(kind: &[u8; 4], payload: &[u8]) -> Vec<u8> {
        [
            &((payload.len() + 8) as u32).to_be_bytes()[..],
            kind,
            payload,
        ]
        .concat()
    }
    #[test]
    fn accepts_proxy_routes_with_or_without_file_type_hints() {
        for suffix in ["", ".flac", ".mp3", ".m4a", ".opus", ".a123456789"] {
            let url = format!("http://127.0.0.1:12345/{}{suffix}", "a".repeat(48));
            assert!(proxy_session(&url, DEADLINE).is_ok(), "rejected {suffix:?}");
        }
    }

    #[test]
    fn file_type_hints_preserve_proxy_url_restrictions() {
        let token = "a".repeat(48);
        for url in [
            format!("http://127.0.0.1:80/{}g.flac", "a".repeat(47)),
            format!("http://127.0.0.1:80/{}.flac", "a".repeat(47)),
            format!("http://127.0.0.1:80/{}.flac", "a".repeat(49)),
            format!("http://127.0.0.1:80/{token}."),
            format!("http://127.0.0.1:80/{token}.abcdefghijk"),
            format!("http://127.0.0.1:80/{token}.flac.extra"),
            format!("http://127.0.0.1:80/{token}.flac/extra"),
            format!("http://127.0.0.1:80/{token}.fl-ac"),
            format!("http://127.0.0.1:80/{token}.FLAC"),
            format!("http://127.0.0.1:80/{token}.flac?query=value"),
            format!("http://127.0.0.1:80/{token}.flac#fragment"),
            format!("http://user:password@127.0.0.1:80/{token}.flac"),
            format!("http://127.0.0.1/{token}.flac"),
            format!("https://127.0.0.1:80/{token}.flac"),
            format!("http://192.168.1.1:80/{token}.flac"),
            format!("http://example.test:80/{token}.flac"),
        ] {
            assert!(proxy_session(&url, DEADLINE).is_err(), "accepted {url}");
        }
    }

    #[test]
    fn fixture_does_not_respond_to_abandoned_connections() {
        let fixture = Fixture::new(b"abc".to_vec(), false);
        let address = fixture
            .url
            .strip_prefix("http://")
            .unwrap()
            .split('/')
            .next()
            .unwrap();
        let mut socket = std::net::TcpStream::connect(address).unwrap();
        socket
            .set_read_timeout(Some(Duration::from_secs(3)))
            .unwrap();
        assert_eq!(socket.read(&mut [0; 64]).unwrap(), 0);
        assert_eq!(fixture.bytes.load(Ordering::Relaxed), 0);
        let mut local = tempfile::NamedTempFile::new().unwrap();
        local.write_all(b"abc").unwrap();
        assert_eq!(
            matches_upload(
                &json!({"url": fixture.url,
            "path": local.path(), "length": 3, "idle_timeout_ms": 20000}),
                &|| Ok(())
            )
            .unwrap()["matches"],
            true
        );
    }
    #[test]
    fn cache_artwork_is_atomic_content_addressed_and_bounded() {
        let root = tempfile::tempdir().unwrap();
        let cache = root.path().join("network_metadata");
        fs::create_dir(&cache).unwrap();
        // Legacy source-addressed entries participate in the same 32-file cap.
        for value in 0..35 {
            fs::write(cache.join(format!("{value:064x}.image")), [value]).unwrap();
        }
        fs::write(cache.join("unrelated.txt"), b"keep").unwrap();
        let (path, digest) = cache_cover(b"cover bytes", &cache, &|| Ok(())).unwrap();
        assert_eq!(fs::read(&path).unwrap(), b"cover bytes");
        assert_eq!(
            digest,
            crate::data_jobs::hash_file(&path, &|| Ok(())).unwrap()
        );
        let again = cache_cover(b"cover bytes", &cache, &|| Ok(())).unwrap();
        assert_eq!(again.0, path);
        assert_eq!(fs::read_dir(&cache).unwrap().count(), 33);
        let covers = root.path().join("library_covers");
        let promoted = promote_cover(&path, covers.to_str().unwrap(), &|| Ok(())).unwrap();
        let target = promoted["cover_path"].as_str().unwrap();
        assert_eq!(fs::read(target).unwrap(), b"cover bytes");
        fs::remove_file(&path).unwrap();
        assert_eq!(fs::read(target).unwrap(), b"cover bytes");
        assert!(cache_cover(b"cancelled", &cache, &|| Err("cancelled".into())).is_err());
        assert_eq!(fs::read_dir(&covers).unwrap().count(), 1);
    }

    #[cfg(unix)]
    #[test]
    fn cached_artwork_with_the_same_bytes_is_kept_and_renewed() {
        use std::os::unix::fs::MetadataExt;
        let root = tempfile::tempdir().unwrap();
        let cache = root.path().join("network_metadata");
        let (path, _) = cache_cover(b"same cover", &cache, &|| Ok(())).unwrap();
        let old = SystemTime::now() - Duration::from_secs(600);
        File::options()
            .write(true)
            .open(&path)
            .unwrap()
            .set_modified(old)
            .unwrap();
        let inode = fs::metadata(&path).unwrap().ino();

        let (again, _) = cache_cover(b"same cover", &cache, &|| Ok(())).unwrap();
        assert_eq!(again, path);
        let renewed = fs::metadata(&path).unwrap();
        assert_eq!(renewed.ino(), inode);
        assert!(renewed.modified().unwrap() > old + Duration::from_secs(300));

        // A damaged file under the name is replaced.
        fs::write(&path, [0; 10]).unwrap();
        cache_cover(b"same cover", &cache, &|| Ok(())).unwrap();
        assert_eq!(fs::read(&path).unwrap(), b"same cover");
        assert_ne!(fs::metadata(&path).unwrap().ino(), inode);
    }

    #[test]
    fn streamed_upload_recovery_compares_content_and_checks_cancellation() {
        let fixture = Fixture::new(b"abc".to_vec(), false);
        let mut local = tempfile::NamedTempFile::new().unwrap();
        local.write_all(b"abc").unwrap();
        let request =
            json!({"url":fixture.url,"path":local.path(),"length":3,"idle_timeout_ms":20000});
        assert_eq!(
            matches_upload(&request, &|| Ok(())).unwrap()["matches"],
            true
        );
        fs::write(local.path(), b"abd").unwrap();
        assert_eq!(
            matches_upload(&request, &|| Ok(())).unwrap()["matches"],
            false
        );
        assert!(matches_upload(&request, &|| Err("cancelled".into())).is_err());
        let mut invalid = request.clone();
        invalid["url"] = "https://example.test/private".into();
        assert!(matches_upload(&invalid, &|| Ok(())).is_err());
    }
    #[test]
    fn reads_flac_tags_lyrics_cover_without_audio_download() {
        let input = [
            b"fLaC".as_slice(),
            &[0x80, 0, 0, 34],
            &[0; 34],
            &[0xff, 0xf8, 0, 0],
        ]
        .concat();
        let fields = BTreeMap::from([
            ("title".into(), "Title".into()),
            ("artist".into(), "Artist".into()),
            ("lyrics".into(), "[00:01.00]Hello\n[00:02.00]World".into()),
        ]);
        let cover = tags::CoverArt {
            data: b"\xff\xd8\xff\xd9".to_vec(),
            mime: "image/jpeg".into(),
        };
        let mut data = Vec::new();
        tags::rewrite_audio_tags(
            &mut io::Cursor::new(input),
            &mut data,
            "flac",
            &fields,
            Some(&cover.data),
            &|| Ok(()),
        )
        .unwrap();
        data.resize(32 * 1024 * 1024, 0);
        let fixture = Fixture::new(data, true);
        for suffix in ["", ".flac"] {
            let before = fixture.bytes.load(Ordering::Relaxed);
            let url = format!("{}{suffix}", fixture.url);
            let tags = read(&url, "song.flac", &|| Ok(())).unwrap();
            assert_eq!(tags["title"], "Title");
            assert_eq!(tags["artist"], "Artist");
            assert_eq!(tags["lyrics"], fields["lyrics"]);
            assert_eq!(
                tags["cover_base64"],
                base64::engine::general_purpose::STANDARD.encode(&cover.data)
            );
            let cache = tempfile::tempdir().unwrap();
            let response = crate::data_jobs::run_native_data_job(
                json!({
                    "operation": "network_metadata", "url": url,
                    "display_name": "song.flac", "cache_directory": cache.path()
                })
                .to_string(),
                vec![],
                None,
            )
            .unwrap();
            let response: Value = serde_json::from_str(&response).unwrap();
            assert_eq!(response["cacheable"], true);
            let cached = &response["metadata"];
            assert_eq!(cached["title"], "Title");
            assert_eq!(cached["lyrics"], fields["lyrics"]);
            assert!(cached.get("cover_base64").is_none());
            assert_eq!(
                fs::read(cached["cover_path"].as_str().unwrap()).unwrap(),
                cover.data
            );
            assert!(fixture.bytes.load(Ordering::Relaxed) - before < 1024 * 1024);
        }
    }
    #[test]
    fn seeks_past_audio_to_mp4_tail_tags() {
        let mut data = atom(b"ftyp", b"isom\0\0\0\0");
        data.extend(atom(b"mdat", &vec![0; 8 * 1024 * 1024]));
        let mut ilst = Vec::new();
        for (key, value) in [
            (b"\xa9nam", "Tail title"),
            (b"\xa9lyr", "[00:01.00]Tail lyrics"),
        ] {
            ilst.extend(atom(
                key,
                &atom(
                    b"data",
                    &[&[0, 0, 0, 1, 0, 0, 0, 0], value.as_bytes()].concat(),
                ),
            ));
        }
        data.extend(atom(
            b"moov",
            &atom(
                b"udta",
                &atom(
                    b"meta",
                    &[&[0; 4], atom(b"ilst", &ilst).as_slice()].concat(),
                ),
            ),
        ));
        let fixture = Fixture::new(data, true);
        let tags = read(&fixture.url, "song.m4a", &|| Ok(())).unwrap();
        assert_eq!(tags["title"], "Tail title");
        assert_eq!(tags["lyrics"], "[00:01.00]Tail lyrics");
        assert!(fixture.bytes.load(Ordering::Relaxed) < 1024 * 1024);
    }
    #[test]
    fn rejects_non_proxy_urls_and_large_servers_without_ranges() {
        for url in [
            "https://example.com/song",
            "http://192.168.1.1/song",
            "http://127.0.0.1:80/bad",
        ] {
            assert!(RangeReader::new(url, &|| Ok(())).is_err());
        }
        let fixture = Fixture::new(vec![0; 1024 * 1024], false);
        assert!(read(&fixture.url, "song.flac", &|| Ok(())).is_err());
    }
}
