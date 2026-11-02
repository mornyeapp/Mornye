//! Unix implementation of native cache directory operations, driven by JSON requests.

use rusqlite::{Connection, OpenFlags, TransactionBehavior};
use rustix::fd::OwnedFd;
use rustix::fs::{
    AtFlags, Dir, FileType, Mode, OFlags, Stat, fstat, open, openat, statat, unlinkat,
};
use serde_json::{Value, json};
use std::{
    collections::HashSet,
    ffi::CString,
    fs,
    os::unix::ffi::OsStrExt,
    path::{Path, PathBuf},
    sync::Arc,
    time::{Duration, SystemTime, UNIX_EPOCH},
};

type Check<'a> = &'a dyn Fn() -> Result<(), String>;
const MAX_ENTRIES: usize = 250_000;
const MAX_DIRECTORIES: usize = 4096;
const MAX_ERRORS: usize = 100;

struct CacheRoot {
    fd: Arc<OwnedFd>,
    display: PathBuf,
    canonical: PathBuf,
}

struct Entry {
    parent: Arc<OwnedFd>,
    name: CString,
    display: PathBuf,
    canonical: PathBuf,
    stat: Stat,
}

#[derive(Default)]
struct Outcome {
    deleted: usize,
    errors: Vec<String>,
    error_count: usize,
    cancelled: bool,
}

impl Outcome {
    fn error(&mut self, entry: &Entry, error: impl std::fmt::Display) {
        self.error_count += 1;
        if self.errors.len() < MAX_ERRORS {
            self.errors.push(format!(
                "Failed deleting stale library cover cache {}: {error}",
                entry.display.display()
            ));
        }
    }

    fn value(self) -> Value {
        json!({
            "deleted": self.deleted,
            "errors": self.errors,
            "error_count": self.error_count,
            "cancelled": self.cancelled,
            // Filesystem eviction cannot be rolled back. Never discard a
            // partial result when cancellation arrives after a deletion.
            "committed": self.deleted > 0,
        })
    }

    fn check(&mut self, check: Check<'_>) -> Result<bool, String> {
        match check() {
            Ok(()) => Ok(true),
            Err(_) if self.deleted > 0 => {
                self.cancelled = true;
                Ok(false)
            }
            Err(error) => Err(error),
        }
    }
}

fn required<'a>(request: &'a Value, key: &str) -> Result<&'a str, String> {
    request[key]
        .as_str()
        .filter(|v| !v.is_empty())
        .ok_or_else(|| format!("Cache maintenance requires {key}"))
}

fn number(request: &Value, key: &str) -> Result<u64, String> {
    request[key]
        .as_u64()
        .ok_or_else(|| format!("Cache maintenance requires nonnegative {key}"))
}

fn root(path: &str) -> Result<Option<CacheRoot>, String> {
    let display = PathBuf::from(path);
    if !display.is_absolute() {
        return Err("Cache directory must be absolute".into());
    }
    // A root alias is valid (iOS /var and /private/var are aliases); children
    // are opened relative to this descriptor with NOFOLLOW below.
    let fd = match open(
        &display,
        OFlags::RDONLY | OFlags::DIRECTORY | OFlags::CLOEXEC,
        Mode::empty(),
    ) {
        Ok(fd) => Arc::new(fd),
        Err(rustix::io::Errno::NOENT | rustix::io::Errno::NOTDIR) => return Ok(None),
        Err(error) => return Err(format!("Open cache directory: {error}")),
    };
    let canonical =
        fs::canonicalize(&display).map_err(|e| format!("Resolve cache directory: {e}"))?;
    let current = rustix::fs::stat(&canonical).map_err(|e| e.to_string())?;
    let opened = fstat(&fd).map_err(|e| e.to_string())?;
    if current.st_dev != opened.st_dev || current.st_ino != opened.st_ino {
        return Err("Cache directory changed while opening".into());
    }
    Ok(Some(CacheRoot {
        fd,
        display,
        canonical,
    }))
}

fn regular(stat: &Stat) -> bool {
    FileType::from_raw_mode(stat.st_mode) == FileType::RegularFile
}

fn modified(stat: &Stat) -> i128 {
    i128::from(stat.st_mtime) * 1_000_000_000 + i128::from(stat.st_mtime_nsec)
}

/// When a Library cover name appeared. A hard link shares its inode's mtime,
/// so a thumbnail linked moments ago (desktop and iOS) counts from the ctime
/// that linking updates; a file with one name keeps its mtime.
fn named(stat: &Stat) -> i128 {
    let changed = i128::from(stat.st_ctime) * 1_000_000_000 + i128::from(stat.st_ctime_nsec);
    if stat.st_nlink > 1 {
        modified(stat).max(changed)
    } else {
        modified(stat)
    }
}

fn unchanged(before: &Stat, after: &Stat) -> bool {
    regular(after)
        && before.st_dev == after.st_dev
        && before.st_ino == after.st_ino
        && before.st_size == after.st_size
        && modified(before) == modified(after)
        && before.st_ctime == after.st_ctime
        && before.st_ctime_nsec == after.st_ctime_nsec
}

fn cutoff(request: &Value) -> Result<i128, String> {
    let age_ns = if request.get("minimum_age_us").is_some() {
        i128::from(number(request, "minimum_age_us")?) * 1000
    } else {
        i128::from(number(request, "minimum_age_ms")?) * 1_000_000
    };
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|e| e.to_string())?;
    Ok(now.as_nanos() as i128 - age_ns)
}

/// Finish traversal before any deletion: a failed listing or resource bound
/// never turns incomplete information into permission to evict files.
fn collect(root: &CacheRoot, exclude_json: bool, check: Check<'_>) -> Result<Vec<Entry>, String> {
    let mut files = Vec::new();
    let mut pending = vec![(
        root.fd.clone(),
        root.display.clone(),
        root.canonical.clone(),
    )];
    let mut directory_count = 0;
    while let Some((parent, display, canonical)) = pending.pop() {
        check()?;
        directory_count += 1;
        if directory_count > MAX_DIRECTORIES {
            return Err("Cache maintenance directory limit exceeded".into());
        }
        let entries = Dir::read_from(&parent).map_err(|e| format!("List cache directory: {e}"))?;
        for entry in entries {
            check()?;
            let entry = entry.map_err(|e| format!("Read cache entry: {e}"))?;
            let name = entry.file_name();
            if name.to_bytes() == b"." || name.to_bytes() == b".." {
                continue;
            }
            let stat = match statat(&parent, name, AtFlags::SYMLINK_NOFOLLOW) {
                Ok(stat) => stat,
                // Concurrent eviction/rename is normal during cache listing.
                Err(rustix::io::Errno::NOENT) => continue,
                Err(error) => return Err(format!("Stat cache entry: {error}")),
            };
            let name_path = std::ffi::OsStr::from_bytes(name.to_bytes());
            let child_display = display.join(name_path);
            let child_canonical = canonical.join(name_path);
            match FileType::from_raw_mode(stat.st_mode) {
                FileType::Directory => {
                    if directory_count + pending.len() >= MAX_DIRECTORIES {
                        return Err("Cache maintenance directory limit exceeded".into());
                    }
                    let fd = match openat(
                        &parent,
                        name,
                        OFlags::RDONLY | OFlags::DIRECTORY | OFlags::CLOEXEC | OFlags::NOFOLLOW,
                        Mode::empty(),
                    ) {
                        Ok(fd) => fd,
                        Err(
                            rustix::io::Errno::NOENT
                            | rustix::io::Errno::LOOP
                            | rustix::io::Errno::NOTDIR,
                        ) => continue,
                        Err(error) => return Err(format!("Open cache child directory: {error}")),
                    };
                    let opened = fstat(&fd).map_err(|e| e.to_string())?;
                    if opened.st_dev == stat.st_dev && opened.st_ino == stat.st_ino {
                        pending.push((Arc::new(fd), child_display, child_canonical));
                    }
                }
                FileType::RegularFile => {
                    if exclude_json && name.to_bytes().ends_with(b".json") {
                        continue;
                    }
                    if files.len() >= MAX_ENTRIES {
                        return Err("Cache maintenance file limit exceeded".into());
                    }
                    files.push(Entry {
                        parent: parent.clone(),
                        name: name.to_owned(),
                        display: child_display,
                        canonical: child_canonical,
                        stat,
                    });
                }
                _ => {} // Links and nonregular entries are always retained.
            }
        }
    }
    Ok(files)
}

fn remove(entry: &Entry) -> Result<bool, String> {
    let current = match statat(
        &entry.parent,
        entry.name.as_c_str(),
        AtFlags::SYMLINK_NOFOLLOW,
    ) {
        Ok(stat) => stat,
        Err(rustix::io::Errno::NOENT) => return Ok(false),
        Err(error) => return Err(error.to_string()),
    };
    if !unchanged(&entry.stat, &current) {
        return Ok(false);
    }
    match unlinkat(&entry.parent, entry.name.as_c_str(), AtFlags::empty()) {
        Ok(()) => Ok(true),
        Err(rustix::io::Errno::NOENT) => Ok(false),
        Err(error) => Err(error.to_string()),
    }
}

pub(super) fn execute(request: &Value, check: Check<'_>) -> Result<Value, String> {
    check()?;
    match required(request, "operation")? {
        "cache_trim_budget" => trim(request, check),
        "cache_prune_library" => prune(request, check),
        _ => Err("Unknown native cache operation".into()),
    }
}

fn trim(request: &Value, check: Check<'_>) -> Result<Value, String> {
    let maximum = number(request, "max_bytes")?;
    let target = number(request, "target_bytes")?;
    if target > maximum {
        return Err("Cache target cannot exceed maximum".into());
    }
    let cutoff = cutoff(request)?;
    let Some(root) = root(required(request, "directory")?)? else {
        return Ok(Outcome::default().value());
    };
    let mut entries = collect(&root, true, check)?;
    let mut total = entries.iter().try_fold(0_u64, |sum, entry| {
        sum.checked_add(u64::try_from(entry.stat.st_size).map_err(|e| e.to_string())?)
            .ok_or_else(|| "Cache size overflow".to_string())
    })?;
    let mut outcome = Outcome::default();
    if total <= maximum {
        return Ok(outcome.value());
    }
    entries.sort_by_key(|entry| modified(&entry.stat));
    for entry in entries {
        if total <= target || !outcome.check(check)? {
            break;
        }
        if modified(&entry.stat) > cutoff {
            continue;
        }
        // A failed eviction is expected while another download/cache task
        // replaces a payload, matching Dart's best-effort budget sweep.
        if remove(&entry) == Ok(true) {
            total = total.saturating_sub(entry.stat.st_size as u64);
            outcome.deleted += 1;
        }
    }
    Ok(outcome.value())
}

fn references(
    request: &Value,
    db: Option<&Connection>,
    check: Check<'_>,
) -> Result<HashSet<PathBuf>, String> {
    let mut paths = HashSet::new();
    if let Some(db) = db {
        // Hidden, disabled and unavailable sources still own their covers.
        let mut query = db.prepare("SELECT DISTINCT cover_path FROM library WHERE cover_path IS NOT NULL AND cover_path != ''")
            .map_err(|e| format!("Query cover references: {e}"))?;
        let mut rows = query.query([]).map_err(|e| e.to_string())?;
        while let Some(row) = rows.next().map_err(|e| e.to_string())? {
            check()?;
            paths.insert(PathBuf::from(
                row.get::<_, String>(0).map_err(|e| e.to_string())?,
            ));
        }
    } else {
        let entries = request["referenced_paths"]
            .as_array()
            .ok_or("Cache pruning requires cover references")?;
        for path in entries {
            check()?;
            paths.insert(PathBuf::from(
                path.as_str().ok_or("Cover reference must be a string")?,
            ));
        }
    }
    let companions: Vec<_> = paths
        .iter()
        .filter_map(|path| subsonic_companions(path))
        .flatten()
        .collect();
    paths.extend(companions);
    let mut canonical = Vec::new();
    for path in &paths {
        check()?;
        if let Ok(path) = fs::canonicalize(path) {
            canonical.push(path);
        }
    }
    paths.extend(canonical);
    Ok(paths)
}

/// A Subsonic cover (`subsonic_<hash>.image`, or `subsonic_<hash>_<id>.image`
/// after a refresh) is found again through `subsonic_<hash>.image.current`.
/// Its ETag stays beside it in `<cover>.etag`.
fn subsonic_companions(path: &Path) -> Option<[PathBuf; 2]> {
    let name = path.file_name()?.to_str()?;
    let hash = name.strip_prefix("subsonic_")?.strip_suffix(".image")?;
    let hash = hash.split_once('_').map_or(hash, |(hash, _)| hash);
    (hash.len() == 64 && hash.bytes().all(|byte| byte.is_ascii_hexdigit())).then(|| {
        [
            path.with_file_name(format!("subsonic_{hash}.image.current")),
            path.with_file_name(format!("{name}.etag")),
        ]
    })
}

fn prune(request: &Value, check: Check<'_>) -> Result<Value, String> {
    let cutoff = cutoff(request)?;
    let Some(root) = root(required(request, "directory")?)? else {
        return Ok(Outcome::default().value());
    };
    let mut db = if let Some(path) = request["library_path"].as_str() {
        let path = Path::new(path);
        if !path.is_absolute()
            || path.file_name().and_then(|v| v.to_str()) != Some("local_library.db")
        {
            return Err("Cache pruning requires existing local_library.db".into());
        }
        let db = Connection::open_with_flags(path, OpenFlags::SQLITE_OPEN_READ_WRITE)
            .map_err(|e| format!("Open cover references: {e}"))?;
        db.busy_timeout(Duration::from_secs(5))
            .map_err(|e| e.to_string())?;
        let version: i64 = db
            .pragma_query_value(None, "user_version", |row| row.get(0))
            .map_err(|e| e.to_string())?;
        if version != 17 && version != 18 {
            return Err(format!(
                "Cover reference schema v{version} is incompatible with native v17/v18"
            ));
        }
        Some(db)
    } else {
        None
    };
    // The provider holds its scan single-flight guard throughout this job.
    // An immediate SQLite transaction additionally prevents either native or
    // Flutter writers changing cover references during the filesystem sweep.
    let transaction = db
        .as_mut()
        .map(|db| db.transaction_with_behavior(TransactionBehavior::Immediate))
        .transpose()
        .map_err(|e| format!("Lock cover references: {e}"))?;
    let retained = references(request, transaction.as_deref(), check)?;
    let entries = collect(&root, false, check)?;
    let mut outcome = Outcome::default();
    for entry in entries {
        if !outcome.check(check)? {
            break;
        }
        if retained.contains(&entry.display)
            || retained.contains(&entry.canonical)
            || named(&entry.stat) > cutoff
        {
            continue;
        }
        match remove(&entry) {
            Ok(true) => outcome.deleted += 1,
            Ok(false) => {}
            Err(error) => outcome.error(&entry, error),
        }
    }
    // Read-only reference transaction; drop rolls it back without touching
    // Library rows. Deletions themselves are reported even after cancellation.
    Ok(outcome.value())
}

#[cfg(test)]
mod tests;
