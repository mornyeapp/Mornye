//! Song files the phone sends so the desktop can play them
//! (`PUT /mornye/v1/files/<name>`), kept in `<state_dir>/received/`. A body
//! streams into a part file that is renamed into place once complete, and
//! the folder is pruned after every upload so it stays bounded.

use bytes::Bytes;
use http_body_util::BodyExt;
use hyper::body::Body;
use std::fs;
use std::io;
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use tokio::io::AsyncWriteExt;

/// Folder under the state dir.
const RECEIVED_DIR: &str = "received";
/// The largest accepted file (413 beyond).
pub(crate) const MAX_UPLOAD: u64 = 2 << 30;
/// Total size of the completed files kept; the oldest go first.
const MAX_RECEIVED: u64 = 4 << 30;
/// Part files left behind by an interrupted upload are removed after this.
const STALE_PART: Duration = Duration::from_secs(60 * 60);
/// Extensions a received file may carry.
const EXTENSIONS: &[&str] = &[
    "flac", "mp3", "m4a", "mp4", "aac", "ogg", "oga", "opus", "wav", "aif", "aiff", "aifc", "wv",
    "ape", "dsf", "dff", "mka", "wma", "webm",
];
/// Ends the name of the part file an upload streams into.
const PART_SUFFIX: &str = ".part";

/// `<state_dir>/received` as an absolute path: where received files are
/// kept, reported to the app as `receivedDir`.
pub fn received_dir(state_dir: &Path) -> PathBuf {
    let dir = state_dir.join(RECEIVED_DIR);
    std::path::absolute(&dir).unwrap_or(dir)
}

/// Whether `name` is 32 lowercase hex digits, a dot and a known audio
/// extension, for example `0123456789abcdef0123456789abcdef.flac`.
pub(crate) fn valid_name(name: &str) -> bool {
    let Some((stem, extension)) = name.split_once('.') else {
        return false;
    };
    stem.len() == 32
        && stem
            .bytes()
            .all(|byte| matches!(byte, b'0'..=b'9' | b'a'..=b'f'))
        && EXTENSIONS.contains(&extension)
}

/// Why an upload was refused.
#[derive(Debug)]
pub(crate) enum ReceiveError {
    /// The body is larger than the limit.
    TooLarge,
    /// The body broke off or could not be read (a client disconnect).
    Unreadable,
    /// The file could not be written.
    Storage(io::Error),
}

/// Stores `body` as `dir/<name>` (at most [`MAX_UPLOAD`] bytes), then prunes
/// `dir`. Returns the bytes written.
pub(crate) async fn upload<B>(dir: &Path, name: &str, body: B) -> Result<u64, ReceiveError>
where
    B: Body<Data = Bytes> + Unpin,
{
    let written = receive(dir, name, body, MAX_UPLOAD).await?;
    let (dir, keep) = (dir.to_owned(), name.to_owned());
    let _ = tokio::task::spawn_blocking(move || prune(&dir, MAX_RECEIVED, STALE_PART, &keep)).await;
    Ok(written)
}

/// Streams `body` into a part file in `dir` and renames it to `dir/<name>`
/// once complete, replacing an earlier copy. Nothing is left behind when it
/// fails or is dropped half way.
pub(crate) async fn receive<B>(
    dir: &Path,
    name: &str,
    mut body: B,
    limit: u64,
) -> Result<u64, ReceiveError>
where
    B: Body<Data = Bytes> + Unpin,
{
    tokio::fs::create_dir_all(dir)
        .await
        .map_err(ReceiveError::Storage)?;
    let path = dir.join(format!(".{name}.{:016x}{PART_SUFFIX}", unique()));
    let mut file = tokio::fs::File::options()
        .write(true)
        .create_new(true)
        .open(&path)
        .await
        .map_err(ReceiveError::Storage)?;
    let part = PartFile { path, kept: false };
    let copied = async {
        let mut written = 0u64;
        while let Some(frame) = body.frame().await {
            let frame = frame.map_err(|_| ReceiveError::Unreadable)?;
            let Ok(data) = frame.into_data() else {
                continue;
            };
            written += data.len() as u64;
            if written > limit {
                return Err(ReceiveError::TooLarge);
            }
            file.write_all(&data).await.map_err(ReceiveError::Storage)?;
        }
        Ok(written)
    }
    .await;
    // Waits for writes still in flight, so the file is closed before it is
    // renamed or removed.
    let flushed = file.flush().await;
    drop(file);
    let written = copied?;
    flushed.map_err(ReceiveError::Storage)?;
    tokio::fs::rename(&part.path, dir.join(name))
        .await
        .map_err(ReceiveError::Storage)?;
    part.keep();
    Ok(written)
}

/// Removes part files older than `stale_after`, then completed files,
/// oldest modification first, until those left total at most `max_bytes`.
/// `keep` (the file just received) counts toward the total but is never
/// removed. Other files are left alone.
pub(crate) fn prune(dir: &Path, max_bytes: u64, stale_after: Duration, keep: &str) {
    let Ok(entries) = fs::read_dir(dir) else {
        return;
    };
    let now = SystemTime::now();
    let mut total = 0u64;
    let mut files: Vec<(SystemTime, u64, PathBuf)> = Vec::new();
    for entry in entries.filter_map(Result::ok) {
        let Ok(metadata) = entry.metadata() else {
            continue;
        };
        let file_name = entry.file_name();
        let Some(name) = file_name.to_str().filter(|_| metadata.is_file()) else {
            continue;
        };
        let modified = metadata.modified().unwrap_or(now);
        if name.starts_with('.') && name.ends_with(PART_SUFFIX) {
            if now
                .duration_since(modified)
                .is_ok_and(|age| age > stale_after)
            {
                let _ = fs::remove_file(entry.path());
            }
            continue;
        }
        if !valid_name(name) {
            continue;
        }
        total += metadata.len();
        if name != keep {
            files.push((modified, metadata.len(), entry.path()));
        }
    }
    files.sort();
    for (_, len, path) in files {
        if total <= max_bytes {
            break;
        }
        if fs::remove_file(path).is_ok() {
            total -= len;
        }
    }
}

/// A part file removed on drop unless kept.
struct PartFile {
    path: PathBuf,
    kept: bool,
}

impl PartFile {
    /// The part file was renamed into place: nothing to remove.
    fn keep(mut self) {
        self.kept = true;
    }
}

impl Drop for PartFile {
    fn drop(&mut self) {
        if !self.kept {
            let _ = fs::remove_file(&self.path);
        }
    }
}

/// A random value for part file names, else the time.
fn unique() -> u64 {
    getrandom::u64().unwrap_or_else(|_| {
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map_or(0, |elapsed| elapsed.as_nanos() as u64)
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use http_body_util::{Full, StreamBody};
    use hyper::body::Frame;

    const NAME: &str = "0123456789abcdef0123456789abcdef.flac";

    fn names(dir: &Path) -> Vec<String> {
        let mut names: Vec<String> = fs::read_dir(dir)
            .map(|entries| {
                entries
                    .filter_map(Result::ok)
                    .map(|entry| entry.file_name().to_string_lossy().into_owned())
                    .collect()
            })
            .unwrap_or_default();
        names.sort();
        names
    }

    /// Writes `len` bytes to `dir/name`, modified `age` ago.
    fn aged(dir: &Path, name: &str, len: usize, age: Duration) {
        let path = dir.join(name);
        fs::write(&path, vec![0; len]).expect("write");
        fs::File::options()
            .write(true)
            .open(&path)
            .and_then(|file| file.set_modified(SystemTime::now() - age))
            .expect("set mtime");
    }

    #[test]
    fn names_are_hex_digests_with_an_audio_extension() {
        assert!(valid_name(NAME));
        assert!(valid_name("ffffffffffffffffffffffffffffffff.webm"));
        for name in [
            "0123456789ABCDEF0123456789abcdef.flac",
            "0123456789abcdef0123456789abcde.flac",
            "0123456789abcdef0123456789abcdef0.flac",
            "0123456789abcdef0123456789abcdef.FLAC",
            "0123456789abcdef0123456789abcdef.txt",
            "0123456789abcdef0123456789abcdef.flac.part",
            "0123456789abcdef0123456789abcdef",
            "../123456789abcdef0123456789abcdef.flac",
            "0123456789abcdef/123456789abcdef.flac",
            "",
        ] {
            assert!(!valid_name(name), "{name}");
        }
    }

    #[tokio::test]
    async fn receive_streams_into_place_and_replaces_an_earlier_copy() {
        let dir = tempfile::tempdir().expect("temp dir");
        let target = dir.path().join("received");
        let chunks: Vec<Result<Frame<Bytes>, io::Error>> = vec![
            Ok(Frame::data(Bytes::from_static(b"fLaC"))),
            Ok(Frame::data(Bytes::from_static(b" audio"))),
        ];
        let body = StreamBody::new(futures_util::stream::iter(chunks));
        let written = receive(&target, NAME, body, 100).await.expect("stored");
        assert_eq!(written, 10);
        assert_eq!(fs::read(target.join(NAME)).expect("file"), b"fLaC audio");
        let again = receive(&target, NAME, Full::new(Bytes::from_static(b"new")), 100)
            .await
            .expect("stored");
        assert_eq!(again, 3);
        assert_eq!(fs::read(target.join(NAME)).expect("file"), b"new");
        assert_eq!(names(&target), [NAME]);
    }

    #[tokio::test]
    async fn failed_receives_leave_no_part_file() {
        let dir = tempfile::tempdir().expect("temp dir");
        let large = receive(dir.path(), NAME, Full::new(Bytes::from(vec![1; 11])), 10).await;
        assert!(matches!(large, Err(ReceiveError::TooLarge)), "{large:?}");
        let chunks: Vec<Result<Frame<Bytes>, io::Error>> = vec![
            Ok(Frame::data(Bytes::from_static(b"partial"))),
            Err(io::Error::from(io::ErrorKind::ConnectionReset)),
        ];
        let broken = receive(
            dir.path(),
            NAME,
            StreamBody::new(futures_util::stream::iter(chunks)),
            100,
        )
        .await;
        assert!(
            matches!(broken, Err(ReceiveError::Unreadable)),
            "{broken:?}"
        );
        assert!(names(dir.path()).is_empty(), "{:?}", names(dir.path()));
    }

    #[test]
    fn prune_keeps_the_newest_files_within_the_limit() {
        let dir = tempfile::tempdir().expect("temp dir");
        let hour = Duration::from_secs(60 * 60);
        let file = |digit: char| format!("{}.flac", digit.to_string().repeat(32));
        aged(dir.path(), &file('1'), 40, Duration::from_secs(500));
        aged(dir.path(), &file('2'), 40, Duration::from_secs(400));
        aged(dir.path(), &file('3'), 40, Duration::from_secs(300));
        aged(dir.path(), &file('4'), 40, Duration::from_secs(200));
        // The file just received is the oldest here, yet it stays.
        aged(dir.path(), &file('0'), 40, Duration::from_secs(900));
        aged(dir.path(), &format!(".{}.1.part", file('5')), 40, hour * 2);
        aged(
            dir.path(),
            &format!(".{}.2.part", file('6')),
            40,
            Duration::ZERO,
        );
        aged(dir.path(), "notes.txt", 1000, hour * 2);
        prune(dir.path(), 120, hour, &file('0'));
        assert_eq!(
            names(dir.path()),
            [
                format!(".{}.2.part", file('6')),
                file('0'),
                file('3'),
                file('4'),
                "notes.txt".to_owned(),
            ]
        );
        prune(dir.path(), 1000, hour, &file('0'));
        assert_eq!(names(dir.path()).len(), 5, "within the limit");
    }
}
