//! Turns a catalog song's path into a file the server can read. A plain path
//! opens directly, as it always has. A URI (an Android storage access
//! `content://` document) only the app can open: the server forwards
//! [`OPEN_OP`] without a device, the app lends a path it may read, and the
//! server forwards [`CLOSE_OP`] once its response is finished, the client went
//! away, or anything failed on the way. The lease is named before the app is
//! asked, so even an open that times out or is abandoned is closed.

use crate::types::{Host, Shared};
use serde_json::{Value, json};
use std::fs::Metadata;
use std::io::{self, Seek};
use std::path::Path;
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Duration;
use tokio::sync::{Mutex, OwnedSemaphorePermit, Semaphore};

/// Asks the app to lend a file: `{"uri","lease"}`, answered `{"path"}`.
pub(crate) const OPEN_OP: &str = "server/files/open";
/// Ends a lease: `{"lease"}`.
pub(crate) const CLOSE_OP: &str = "server/files/close";
/// Files lent at once; more requests wait for one to be returned.
const MAX_LEASES: usize = 8;
/// How long a request waits for a lease before it gives up.
const LEASE_WAIT: Duration = Duration::from_secs(10);

/// Lease names, unique for the process so a late close never meets a new
/// lease of the same name.
static NEXT_LEASE: AtomicU64 = AtomicU64::new(0);

/// Whether `op` is one only the server itself forwards, which a phone may not
/// send.
pub(crate) fn is_server_op(op: &str) -> bool {
    op == "server" || op.starts_with("server/")
}

/// Whether only the app can open `path`: a URI rather than a file path.
pub(crate) fn needs_app(path: &Path) -> bool {
    let Some((scheme, _)) = path.to_str().and_then(|text| text.split_once("://")) else {
        return false;
    };
    let mut chars = scheme.chars();
    chars
        .next()
        .is_some_and(|first| first.is_ascii_alphabetic())
        && chars.all(|c| c.is_ascii_alphanumeric() || matches!(c, '+' | '-' | '.'))
        && !scheme.eq_ignore_ascii_case("file")
}

/// The name a song's file goes by: the last part of its path, a URI's decoded
/// document name, else its title and suffix.
pub(crate) fn file_name(path: &Path, title: &str, suffix: &str) -> String {
    let fallback = || format!("{title}.{suffix}");
    if !needs_app(path) {
        return path
            .file_name()
            .map(|name| name.to_string_lossy().into_owned())
            .unwrap_or_else(fallback);
    }
    let text = path.to_string_lossy();
    let segment = text.rsplit('/').next().unwrap_or_default();
    let decoded = percent_decode(segment.split(['?', '#']).next().unwrap_or_default());
    // A document id such as `primary:Music/Artist/Song.flac`.
    let name = decoded.rsplit(['/', ':']).next().unwrap_or_default().trim();
    match name.rfind('.') {
        Some(dot) if dot > 0 && dot + 1 < name.len() => name.to_owned(),
        _ => fallback(),
    }
}

fn percent_decode(text: &str) -> String {
    let bytes = text.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut index = 0;
    while index < bytes.len() {
        let hex = |at: usize| bytes.get(at).and_then(|byte| (*byte as char).to_digit(16));
        match (bytes[index], hex(index + 1), hex(index + 2)) {
            (b'%', Some(high), Some(low)) => {
                out.push((high * 16 + low) as u8);
                index += 3;
            }
            (byte, _, _) => {
                out.push(byte);
                index += 1;
            }
        }
    }
    String::from_utf8_lossy(&out).into_owned()
}

/// The server's leases on files the app lends.
pub(crate) struct Leases {
    permits: Arc<Semaphore>,
    wait: Duration,
    /// Held from asking the app until the server holds its own copy of the
    /// descriptor: the app gives up its oldest descriptor when it holds too
    /// many, so one lent file is copied before the next is asked for.
    opening: Mutex<()>,
}

impl Leases {
    /// At most `max` files lent at once; a request waits `wait` for one.
    pub(crate) fn new(max: usize, wait: Duration) -> Self {
        Self {
            permits: Arc::new(Semaphore::new(max)),
            wait,
            opening: Mutex::new(()),
        }
    }
}

impl Default for Leases {
    fn default() -> Self {
        Self::new(MAX_LEASES, LEASE_WAIT)
    }
}

/// The app's lease on one file. Dropping it forwards [`CLOSE_OP`] and frees
/// its place.
pub(crate) struct Lease {
    host: Arc<dyn Host>,
    id: String,
    _permit: OwnedSemaphorePermit,
}

impl Drop for Lease {
    fn drop(&mut self) {
        // The host sends the request when called; awaiting the reply only
        // lets it forget the request in good order.
        let closed = self.host.request(CLOSE_OP, "", json!({ "lease": self.id }));
        if let Ok(runtime) = tokio::runtime::Handle::try_current() {
            drop(runtime.spawn(closed));
        }
    }
}

/// Why a file could not be opened.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum OpenError {
    /// Not a readable file, or the app could not lend it.
    Missing,
    /// Every lease was taken and none was returned in time.
    Busy,
}

/// A song's file open for reading, and the lease that keeps a lent one
/// readable. Hold the lease until done reading.
pub(crate) struct Readable {
    pub(crate) file: tokio::fs::File,
    pub(crate) metadata: Metadata,
    pub(crate) lease: Option<Lease>,
}

/// Opens the catalog file at `path`, directly or through the app.
pub(crate) async fn open(shared: &Shared, path: &Path) -> Result<Readable, OpenError> {
    if !needs_app(path) {
        let file = tokio::fs::File::open(path)
            .await
            .map_err(|_| OpenError::Missing)?;
        let metadata = file.metadata().await.map_err(|_| OpenError::Missing)?;
        return regular(file, metadata, None);
    }
    let uri = path.to_str().ok_or(OpenError::Missing)?;
    let leases = &shared.leases;
    let permit = tokio::time::timeout(leases.wait, Arc::clone(&leases.permits).acquire_owned())
        .await
        .map_err(|_| OpenError::Busy)?
        .map_err(|_| OpenError::Busy)?;
    let lease = Lease {
        host: Arc::clone(&shared.host),
        id: (NEXT_LEASE.fetch_add(1, Ordering::Relaxed) + 1).to_string(),
        _permit: permit,
    };
    let file = {
        let _opening = leases.opening.lock().await;
        let reply = shared
            .host
            .request(OPEN_OP, "", json!({ "uri": uri, "lease": lease.id }))
            .await
            .map_err(|_| OpenError::Missing)?;
        let lent = reply
            .get("path")
            .and_then(Value::as_str)
            .ok_or(OpenError::Missing)?;
        let mut file = duplicate(lent).map_err(|_| OpenError::Missing)?;
        // A copy shares the descriptor's position; reading starts at the top.
        file.rewind().map_err(|_| OpenError::Missing)?;
        file
    };
    let file = tokio::fs::File::from_std(file);
    let metadata = file.metadata().await.map_err(|_| OpenError::Missing)?;
    regular(file, metadata, Some(lease))
}

fn regular(
    file: tokio::fs::File,
    metadata: Metadata,
    lease: Option<Lease>,
) -> Result<Readable, OpenError> {
    if !metadata.is_file() {
        return Err(OpenError::Missing);
    }
    Ok(Readable {
        file,
        metadata,
        lease,
    })
}

/// The file behind the path the app lent. A descriptor path
/// (`/proc/self/fd/N`, `/dev/fd/N`) is duplicated: Android refuses to reopen
/// a proxied descriptor, and the copy stays readable whatever the app does
/// with its own. Any other path is opened.
fn duplicate(lent: &str) -> io::Result<std::fs::File> {
    #[cfg(unix)]
    if let Some(number) = lent
        .strip_prefix("/proc/self/fd/")
        .or_else(|| lent.strip_prefix("/dev/fd/"))
    {
        use std::os::fd::BorrowedFd;
        let descriptor = number
            .parse::<i32>()
            .ok()
            .filter(|descriptor| *descriptor >= 0)
            .ok_or(io::ErrorKind::InvalidData)?;
        // The app keeps the descriptor open until the lease closes, which
        // is after this copy is made.
        #[allow(unsafe_code)]
        let owned = unsafe { BorrowedFd::borrow_raw(descriptor) }.try_clone_to_owned()?;
        return Ok(std::fs::File::from(owned));
    }
    std::fs::File::open(lent)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_uris_need_the_app() {
        for path in [
            "content://com.example.documents/tree/a/document/a%3AMusic%2FSong.flac",
            "content://media/external/audio/media/12",
        ] {
            assert!(needs_app(Path::new(path)), "{path}");
        }
        for path in [
            "/music/Song.flac",
            "/music/odd://name.flac",
            "C:\\Music\\Song.flac",
            "file:///music/Song.flac",
            "relative/Song.flac",
        ] {
            assert!(!needs_app(Path::new(path)), "{path}");
        }
    }

    #[test]
    fn a_uri_is_named_by_its_document() {
        let name = |path: &str| file_name(Path::new(path), "Title", "flac");
        assert_eq!(
            name(
                "content://com.example.documents/tree/a%3AMusic/document/a%3AMusic%2FBand%2FCaf%C3%A9.flac"
            ),
            "Café.flac"
        );
        assert_eq!(
            name("content://com.example.documents/document/a%3ASong.mp3"),
            "Song.mp3"
        );
        assert_eq!(
            name("content://media/external/audio/media/12"),
            "Title.flac"
        );
        assert_eq!(name("/music/Band/Song.m4a"), "Song.m4a");
        assert_eq!(name("/"), "Title.flac");
    }

    #[test]
    fn server_ops_are_told_apart() {
        assert!(is_server_op(OPEN_OP));
        assert!(is_server_op(CLOSE_OP));
        assert!(is_server_op("server"));
        assert!(!is_server_op("servers/x"));
        assert!(!is_server_op("handoff/play"));
    }
}
