//! Go-compatible successful-lyrics cache with bounded, atomic persistence.

use mornye_core::fs::{
    DEFAULT_TEMP_PREFIX, DirBuilderPortableExt, OpenOptionsPortableExt, write_atomic,
};
use mornye_core::lyrics::LyricsResponse;
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::fs::{self, OpenOptions};
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Condvar, Mutex};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

pub const MAX_ENTRIES: usize = 500;
pub const TTL: Duration = Duration::from_secs(24 * 60 * 60);
const MAX_PERSISTED_BYTES: u64 = 64 << 20;
const APPLE_TIMING_VERSION: u32 = 6;
const LRC_RED_RECORDING_VERSION: u32 = 7;
const SNAPSHOT_VERSION: u32 = LRC_RED_RECORDING_VERSION;
/// Changes appended after a snapshot before the next one replaces both.
const JOURNAL_LIMIT: usize = 64;

#[derive(Clone)]
struct Entry {
    response: Arc<LyricsResponse>,
    expires_at: SystemTime,
}

impl Entry {
    fn persisted_expiry(&self) -> i64 {
        self.expires_at
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_secs() as i64
    }
}

/// `journal` names the journal that continues this snapshot; versions
/// without it ignore the field and the journal.
#[derive(Default, Deserialize, Serialize)]
#[serde(default)]
struct Snapshot {
    version: u32,
    entries: BTreeMap<String, PersistedEntry>,
    journal: u64,
}

#[derive(Deserialize, Serialize)]
struct PersistedEntry {
    response: Option<LyricsResponse>,
    expires_at: i64,
}

/// The journal's first line; it applies only to the snapshot with this ID.
#[derive(Deserialize, Serialize)]
struct JournalHeader {
    base: u64,
}

/// One appended change: a stored entry, or `None` for a removed key.
#[derive(Deserialize)]
struct JournalLine {
    key: String,
    entry: Option<PersistedEntry>,
}

enum Pending {
    Snapshot(BTreeMap<String, Entry>),
    Append(Vec<(String, Option<Entry>)>),
}

#[derive(Default)]
struct State {
    entries: BTreeMap<String, Entry>,
    path: Option<PathBuf>,
    pending: Option<(PathBuf, Pending)>,
    /// The snapshot on disk whose journal takes appends; `None` makes the
    /// next write a full snapshot.
    base: Option<u64>,
    appended: usize,
    /// After a memory drop the next change writes what memory holds as a
    /// full snapshot, as every write did before the journal.
    rewrite: bool,
    writing: bool,
    flush: bool,
    error: Option<String>,
}

#[derive(Default)]
struct Inner {
    state: Mutex<State>,
    ready: Condvar,
}

#[derive(Default)]
pub struct LyricsCache {
    inner: Arc<Inner>,
}

fn clone_response(response: &LyricsResponse) -> LyricsResponse {
    let mut result = response.clone();
    // append([]LyricsLine(nil), empty...) in Go collapses [] to null.
    if result.lines().is_empty() {
        result.lines = None;
    }
    result
}

impl LyricsCache {
    pub fn get(&self, key: &str, now: SystemTime) -> Option<LyricsResponse> {
        let state = self.inner.state.lock().expect("lyrics cache lock");
        state
            .entries
            .get(key)
            .filter(|entry| now <= entry.expires_at)
            .map(|entry| clone_response(&entry.response))
    }

    pub fn set(&self, key: String, response: &LyricsResponse, now: SystemTime) {
        let mut state = self.inner.state.lock().expect("lyrics cache lock");
        let mut changes = Vec::new();
        if state.entries.len() >= MAX_ENTRIES {
            state.entries.retain(|key, entry| {
                let keep = now <= entry.expires_at;
                if !keep {
                    changes.push((key.clone(), None));
                }
                keep
            });
            while state.entries.len() >= MAX_ENTRIES {
                let oldest = state
                    .entries
                    .iter()
                    .min_by_key(|(_, entry)| entry.expires_at)
                    .map(|(key, _)| key.clone())
                    .expect("full lyrics cache");
                state.entries.remove(&oldest);
                changes.push((oldest, None));
            }
        }
        let entry = Entry {
            response: Arc::new(clone_response(response)),
            expires_at: now + TTL,
        };
        state.entries.insert(key.clone(), entry.clone());
        changes.push((key, Some(entry)));
        self.schedule_changes(&mut state, changes);
    }

    pub fn len(&self) -> usize {
        self.inner
            .state
            .lock()
            .expect("lyrics cache lock")
            .entries
            .len()
    }

    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }

    pub fn clear(&self) -> usize {
        let mut state = self.inner.state.lock().expect("lyrics cache lock");
        let count = state.entries.len();
        state.entries.clear();
        self.schedule(&mut state);
        count
    }

    /// Retain the pending disk snapshot even if memory pressure arrives during
    /// the debounce window. A later process can still restore successful data.
    pub fn drop_memory(&self) -> usize {
        let mut state = self.inner.state.lock().expect("lyrics cache lock");
        let count = state.entries.len();
        state.entries.clear();
        state.rewrite = true;
        count
    }

    /// The path must come from the native application's private cache directory.
    /// Missing, invalid or expired files are ignored, matching Go restoration.
    pub fn set_persistence_path(&self, path: &Path, now: SystemTime) {
        if path.as_os_str().is_empty() || path == Path::new(".") {
            return;
        }
        let mut loaded = read_snapshot(path).unwrap_or_default();
        let journal = (loaded.journal != 0 && (1..=SNAPSHOT_VERSION).contains(&loaded.version))
            .then(|| read_journal(path, loaded.journal, &mut loaded.entries))
            .flatten();
        let mut state = self.inner.state.lock().expect("lyrics cache lock");
        state.path = Some(path.to_owned());
        // Entries stored before the path was known reach disk with the next
        // full snapshot.
        (state.base, state.appended) = match journal {
            Some(appended) if state.entries.is_empty() => (Some(loaded.journal), appended),
            _ => (None, 0),
        };
        if (1..=SNAPSHOT_VERSION).contains(&loaded.version) {
            for (key, entry) in loaded.entries {
                if state.entries.len() >= MAX_ENTRIES {
                    break;
                }
                let Some(response) = entry.response else {
                    continue;
                };
                // Refetch results whose recording selection or timing changed,
                // preserving the independent revisions of other providers.
                if (loaded.version < APPLE_TIMING_VERSION && response.provider == "Apple Music")
                    || (loaded.version < LRC_RED_RECORDING_VERSION
                        && response.provider == "lrc.red")
                {
                    continue;
                }
                let Some(expires_at) = u64::try_from(entry.expires_at)
                    .ok()
                    .and_then(|seconds| UNIX_EPOCH.checked_add(Duration::from_secs(seconds)))
                else {
                    continue;
                };
                if now < expires_at {
                    state.entries.entry(key).or_insert_with(|| Entry {
                        response: Arc::new(clone_response(&response)),
                        expires_at,
                    });
                }
            }
        }
        if state.pending.is_some() {
            self.schedule(&mut state);
        }
    }

    /// Flush the last scheduled snapshot and report any persistence error.
    pub fn flush(&self) -> Result<(), String> {
        let mut state = self.inner.state.lock().expect("lyrics cache lock");
        state.flush = true;
        self.inner.ready.notify_all();
        while state.writing {
            state = self.inner.ready.wait(state).expect("lyrics cache lock");
        }
        state.flush = false;
        state.error.clone().map_or(Ok(()), Err)
    }

    fn schedule(&self, state: &mut State) {
        let Some(path) = state.path.clone() else {
            return;
        };
        // Share immutable response bodies across the pending snapshot; writes
        // during the debounce window must not copy every track's lyrics again.
        state.pending = Some((path, Pending::Snapshot(state.entries.clone())));
        state.rewrite = false;
        self.start_writer(state);
    }

    /// Appends changes to the journal while it is short, so a new song does
    /// not rewrite every cached song; otherwise writes a full snapshot.
    fn schedule_changes(&self, state: &mut State, mut changes: Vec<(String, Option<Entry>)>) {
        let Some(path) = state.path.clone() else {
            return;
        };
        let queued = match &mut state.pending {
            None => Some(Vec::new()),
            Some((pending, Pending::Append(queued))) if *pending == path => {
                Some(std::mem::take(queued))
            }
            Some(_) => None,
        };
        match queued {
            Some(mut queued)
                if state.base.is_some()
                    && !state.rewrite
                    && state.appended + queued.len() + changes.len() <= JOURNAL_LIMIT =>
            {
                queued.append(&mut changes);
                state.pending = Some((path, Pending::Append(queued)));
                self.start_writer(state);
            }
            _ => self.schedule(state),
        }
    }

    fn start_writer(&self, state: &mut State) {
        if state.writing {
            return;
        }
        state.writing = true;
        let inner = Arc::clone(&self.inner);
        if let Err(error) = std::thread::Builder::new()
            .name("lyrics-cache".into())
            .spawn(move || persist(inner))
        {
            state.writing = false;
            state.error = Some(error.to_string());
        }
    }
}

impl Drop for LyricsCache {
    fn drop(&mut self) {
        let _ = self.flush();
    }
}

fn read_snapshot(path: &Path) -> Option<Snapshot> {
    let file = OpenOptions::new()
        .read(true)
        .nofollow_nonblock()
        .open(path)
        .ok()?;
    let metadata = file.metadata().ok()?;
    if !metadata.is_file() || metadata.len() > MAX_PERSISTED_BYTES {
        return None;
    }
    let mut bytes = Vec::new();
    file.take(MAX_PERSISTED_BYTES + 1)
        .read_to_end(&mut bytes)
        .ok()?;
    if bytes.len() as u64 > MAX_PERSISTED_BYTES {
        return None;
    }
    serde_json::from_slice(&bytes).ok()
}

fn persist(inner: Arc<Inner>) {
    let mut delay = Duration::from_millis(500);
    let mut state = inner.state.lock().expect("lyrics cache lock");
    loop {
        state = inner
            .ready
            .wait_timeout_while(state, delay, |state| !state.flush)
            .expect("lyrics cache lock")
            .0;
        let Some((path, pending)) = state.pending.take() else {
            break;
        };
        let pending = match pending {
            Pending::Append(_) if state.base.is_none() => Pending::Snapshot(state.entries.clone()),
            pending => pending,
        };
        drop(state);
        match pending {
            Pending::Snapshot(snapshot) => {
                let id = (SystemTime::now()
                    .duration_since(UNIX_EPOCH)
                    .unwrap_or_default()
                    .as_nanos() as u64)
                    .max(1);
                let result = write_snapshot(&path, &snapshot, id);
                state = inner.state.lock().expect("lyrics cache lock");
                state.base = result.is_ok().then_some(id);
                state.appended = 0;
                state.error = result.err().map(|error| error.to_string());
            }
            Pending::Append(changes) => {
                let result = append_journal(&path, &changes);
                state = inner.state.lock().expect("lyrics cache lock");
                state.appended += changes.len();
                state.error = result.err().map(|error| error.to_string());
                if state.error.is_some() {
                    // Replace the journal now rather than lose these changes.
                    state.base = None;
                    let entries = state.entries.clone();
                    state.pending = Some((path, Pending::Snapshot(entries)));
                }
            }
        }
        if state.pending.is_none() {
            break;
        }
        delay = Duration::from_millis(100);
    }
    state.writing = false;
    inner.ready.notify_all();
}

fn journal_path(path: &Path) -> PathBuf {
    let mut journal = path.as_os_str().to_owned();
    journal.push(".journal");
    PathBuf::from(journal)
}

/// Applies the journal continuing snapshot `base` and returns its change
/// count, or `None` when it is missing, belongs to another snapshot or has a
/// damaged line, so the next write replaces it.
fn read_journal(
    path: &Path,
    base: u64,
    entries: &mut BTreeMap<String, PersistedEntry>,
) -> Option<usize> {
    let file = OpenOptions::new()
        .read(true)
        .nofollow_nonblock()
        .open(journal_path(path))
        .ok()?;
    let metadata = file.metadata().ok()?;
    if !metadata.is_file() || metadata.len() > MAX_PERSISTED_BYTES {
        return None;
    }
    let mut bytes = Vec::new();
    file.take(MAX_PERSISTED_BYTES + 1)
        .read_to_end(&mut bytes)
        .ok()?;
    let mut lines = bytes.split(|byte| *byte == b'\n');
    let header: JournalHeader = serde_json::from_slice(lines.next()?).ok()?;
    if header.base != base {
        return None;
    }
    let mut count = 0;
    let mut intact = bytes.ends_with(b"\n");
    for line in lines.filter(|line| !line.is_empty()) {
        match serde_json::from_slice::<JournalLine>(line) {
            Ok(JournalLine {
                key,
                entry: Some(entry),
            }) => {
                entries.insert(key, entry);
            }
            Ok(JournalLine { key, entry: None }) => {
                entries.remove(&key);
            }
            Err(_) => {
                intact = false;
                continue;
            }
        }
        count += 1;
    }
    intact.then_some(count)
}

fn append_journal(path: &Path, changes: &[(String, Option<Entry>)]) -> std::io::Result<()> {
    #[derive(Serialize)]
    struct BorrowedLine<'a> {
        key: &'a str,
        entry: Option<BorrowedEntry<'a>>,
    }
    let mut bytes = Vec::new();
    for (key, entry) in changes {
        serde_json::to_writer(
            &mut bytes,
            &BorrowedLine {
                key,
                entry: entry.as_ref().map(BorrowedEntry::new),
            },
        )?;
        bytes.push(b'\n');
    }
    // Appends are not synced: the snapshot they extend is, and a line lost
    // or torn by a power failure only means that song is fetched again.
    OpenOptions::new()
        .append(true)
        .nofollow_nonblock()
        .open(journal_path(path))?
        .write_all(&bytes)
}

#[derive(Serialize)]
struct BorrowedEntry<'a> {
    response: &'a LyricsResponse,
    expires_at: i64,
}

impl<'a> BorrowedEntry<'a> {
    fn new(entry: &'a Entry) -> Self {
        Self {
            response: &entry.response,
            expires_at: entry.persisted_expiry(),
        }
    }
}

/// Writes the snapshot, then starts its empty journal. A crash between the
/// two leaves the previous journal, which no longer matches and is ignored.
fn write_snapshot(
    path: &Path,
    entries: &BTreeMap<String, Entry>,
    journal: u64,
) -> std::io::Result<()> {
    #[derive(Serialize)]
    struct BorrowedSnapshot<'a> {
        version: u32,
        entries: BTreeMap<&'a str, BorrowedEntry<'a>>,
        journal: u64,
    }
    let snapshot = BorrowedSnapshot {
        version: SNAPSHOT_VERSION,
        entries: entries
            .iter()
            .map(|(key, entry)| (key.as_str(), BorrowedEntry::new(entry)))
            .collect(),
        journal,
    };
    let parent = path
        .parent()
        .filter(|path| !path.as_os_str().is_empty())
        .unwrap_or(Path::new("."));
    fs::DirBuilder::new()
        .recursive(true)
        .unix_mode(0o700)
        .create(parent)?;
    let bytes = serde_json::to_vec(&snapshot)?;
    if bytes.len() as u64 > MAX_PERSISTED_BYTES {
        return Err(std::io::Error::other(
            "lyrics cache exceeds persistence size limit",
        ));
    }
    write_atomic(
        parent,
        path,
        DEFAULT_TEMP_PREFIX,
        |file| file.write_all(&bytes),
        || Ok(()),
        false,
    )?;
    let mut header = serde_json::to_vec(&JournalHeader { base: journal })?;
    header.push(b'\n');
    write_atomic(
        parent,
        &journal_path(path),
        DEFAULT_TEMP_PREFIX,
        |file| file.write_all(&header),
        || Ok(()),
        false,
    )?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn legacy_snapshot_refetches_apple_but_preserves_other_providers() {
        let file = tempfile::NamedTempFile::new().unwrap();
        let now = UNIX_EPOCH + Duration::from_secs(100);
        let apple = LyricsResponse::from_text("[00:01.00]Original", "Apple Music", "Apple Music");
        let other = LyricsResponse::from_text("[00:01.00]Original", "LRCLIB", "LRCLIB");
        for version in 1..APPLE_TIMING_VERSION {
            let snapshot = serde_json::json!({"version": version, "entries": {
                "apple": {"response": apple, "expires_at": 200},
                "other": {"response": other, "expires_at": 200}
            }});
            fs::write(file.path(), serde_json::to_vec(&snapshot).unwrap()).unwrap();
            let cache = LyricsCache::default();
            cache.set_persistence_path(file.path(), now);
            assert!(cache.get("apple", now).is_none());
            assert_eq!(cache.get("other", now).unwrap().provider, "LRCLIB");
        }
    }

    #[test]
    fn legacy_recording_cache_refetches_lrc_red_without_discarding_current_apple() {
        let file = tempfile::NamedTempFile::new().unwrap();
        let now = UNIX_EPOCH + Duration::from_secs(100);
        let red = LyricsResponse::from_text("[00:01.00]Solo", "lrc.red", "lrc.red");
        let apple = LyricsResponse::from_text("[00:01.00]Original", "Apple Music", "Apple Music");
        for version in 1..=SNAPSHOT_VERSION {
            let snapshot = serde_json::json!({"version": version, "entries": {
                "red": {"response": red, "expires_at": 200},
                "apple": {"response": apple, "expires_at": 200}
            }});
            fs::write(file.path(), serde_json::to_vec(&snapshot).unwrap()).unwrap();
            let cache = LyricsCache::default();
            cache.set_persistence_path(file.path(), now);
            assert_eq!(
                cache.get("red", now).is_some(),
                version >= LRC_RED_RECORDING_VERSION,
                "lrc.red snapshot {version}"
            );
            assert_eq!(
                cache.get("apple", now).is_some(),
                version >= APPLE_TIMING_VERSION,
                "Apple snapshot {version}"
            );
        }
    }

    #[test]
    fn current_snapshot_restores_supplementary_text() {
        let directory = tempfile::tempdir().unwrap();
        let file = directory.path().join("lyrics.json");
        let now = UNIX_EPOCH + Duration::from_secs(100);
        let mut lyrics =
            LyricsResponse::from_text("[00:01.009]Original", "Apple Music", "Zarz-LRC");
        let line = &mut lyrics.lines.as_mut().unwrap()[0];
        line.romanization = Some("Romanized".into());
        line.romanization_words = Some(vec![mornye_core::lyrics::LyricsWord {
            text: "Romanized".into(),
            start_time_ms: 1009,
            end_time_ms: 1307,
        }]);
        line.translation = Some("English".into());
        let entries = BTreeMap::from([(
            "apple".into(),
            Entry {
                response: Arc::new(lyrics.clone()),
                expires_at: now + Duration::from_secs(100),
            },
        )]);
        write_snapshot(&file, &entries, 1).unwrap();
        let cache = LyricsCache::default();
        cache.set_persistence_path(&file, now);
        assert_eq!(cache.get("apple", now), Some(lyrics));
    }

    fn song(index: usize) -> LyricsResponse {
        LyricsResponse::from_text(&format!("[00:01.00]Line {index}"), "LRCLIB", "LRCLIB")
    }

    fn restored(path: &Path, now: SystemTime) -> LyricsCache {
        let cache = LyricsCache::default();
        cache.set_persistence_path(path, now);
        cache
    }

    fn keys(cache: &LyricsCache) -> Vec<String> {
        let state = cache.inner.state.lock().unwrap();
        state.entries.keys().cloned().collect()
    }

    #[test]
    fn new_songs_append_to_the_journal_instead_of_rewriting_the_snapshot() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("lyrics.json");
        let now = UNIX_EPOCH + Duration::from_secs(100);
        let cache = restored(&path, now);
        cache.set("song-0".into(), &song(0), now);
        cache.flush().unwrap();
        let snapshot = fs::read(&path).unwrap();
        for index in 1..=10 {
            cache.set(format!("song-{index}"), &song(index), now);
            cache.flush().unwrap();
        }
        assert_eq!(fs::read(&path).unwrap(), snapshot);
        let cache = restored(&path, now);
        for index in 0..=10 {
            assert_eq!(cache.get(&format!("song-{index}"), now), Some(song(index)));
        }
        assert_eq!(cache.len(), 11);
    }

    #[test]
    fn evictions_replay_and_a_long_journal_becomes_a_snapshot() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("lyrics.json");
        let start = UNIX_EPOCH + Duration::from_secs(100);
        let cache = restored(&path, start);
        for index in 0..MAX_ENTRIES + 40 {
            let now = start + Duration::from_secs(index as u64);
            cache.set(format!("song-{index:04}"), &song(index), now);
            if index % 7 == 0 {
                cache.flush().unwrap();
            }
        }
        cache.flush().unwrap();
        let journal = fs::read_to_string(journal_path(&path)).unwrap();
        assert!(journal.lines().count() <= JOURNAL_LIMIT + 1);
        let expected = keys(&cache);
        assert_eq!(expected.len(), MAX_ENTRIES);
        assert_eq!(keys(&restored(&path, start)), expected);
    }

    #[test]
    fn clear_and_memory_drops_persist_what_memory_holds() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("lyrics.json");
        let now = UNIX_EPOCH + Duration::from_secs(100);
        let cache = restored(&path, now);
        for index in 0..3 {
            cache.set(format!("song-{index}"), &song(index), now);
            if index < 2 {
                cache.flush().unwrap();
            }
        }
        // A change still waiting for the writer survives memory pressure.
        cache.drop_memory();
        cache.flush().unwrap();
        assert_eq!(restored(&path, now).len(), 3);
        cache.set("song-3".into(), &song(3), now);
        cache.flush().unwrap();
        assert_eq!(keys(&restored(&path, now)), ["song-3"]);
        cache.set("song-4".into(), &song(4), now);
        cache.clear();
        cache.flush().unwrap();
        assert!(restored(&path, now).is_empty());
    }

    #[test]
    fn a_journal_of_another_snapshot_or_a_torn_line_is_handled() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("lyrics.json");
        let now = UNIX_EPOCH + Duration::from_secs(100);
        let cache = restored(&path, now);
        cache.set("song-0".into(), &song(0), now);
        cache.flush().unwrap();
        cache.set("song-1".into(), &song(1), now);
        cache.flush().unwrap();
        drop(cache);
        let journal = journal_path(&path);
        // A version without the journal rewrote the snapshot.
        let mut snapshot: serde_json::Value =
            serde_json::from_slice(&fs::read(&path).unwrap()).unwrap();
        snapshot.as_object_mut().unwrap().remove("journal");
        fs::write(&path, serde_json::to_vec(&snapshot).unwrap()).unwrap();
        assert_eq!(keys(&restored(&path, now)), ["song-0"]);
        // A torn last line keeps the readable changes; the next write starts
        // a new snapshot that holds them.
        let cache = restored(&path, now);
        for index in 2..4 {
            cache.set(format!("song-{index}"), &song(index), now);
            cache.flush().unwrap();
        }
        drop(cache);
        let mut appended = OpenOptions::new().append(true).open(&journal).unwrap();
        appended
            .write_all(br#"{"key":"song-4","entry":{"resp"#)
            .unwrap();
        drop(appended);
        let cache = restored(&path, now);
        assert_eq!(keys(&cache), ["song-0", "song-2", "song-3"]);
        assert!(cache.inner.state.lock().unwrap().base.is_none());
        cache.set("song-5".into(), &song(5), now);
        cache.flush().unwrap();
        assert_eq!(fs::read_to_string(&journal).unwrap().lines().count(), 1);
        assert_eq!(
            keys(&restored(&path, now)),
            ["song-0", "song-2", "song-3", "song-5"]
        );
    }
}
