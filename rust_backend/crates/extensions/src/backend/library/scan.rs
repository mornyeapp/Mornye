//! One scan owner, bounded worker results and shared full/incremental traversal.

use super::{Backend, FolderImage, library_extension, modified_time, scan_time};
use crate::files::SyncBatch;
use cap_std::fs::OpenOptions;
use serde::Serialize;
use serde_json::{Value, json};
use std::collections::{BTreeMap, BTreeSet};
use std::io::{BufRead, BufReader, BufWriter, Read, Write};
use std::path::Path;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Condvar, Mutex, TryLockError, mpsc};
use std::thread;
use std::time::Duration;

type Check<'a> = &'a (dyn Fn() -> Result<(), String> + Sync);

/// How often a paused scan re-checks backend shutdown and its request lease.
const PAUSE_POLL: Duration = Duration::from_millis(250);

/// How many failed files a finished scan lists with their reason. The error
/// count still includes the rest.
const REPORTED_FAILURES: usize = 100;

#[derive(Default)]
pub(in crate::backend) struct ScanState {
    current: Mutex<Option<Arc<Run>>>,
    owner: Mutex<()>,
    // Pausing is scan-wide rather than per run so a pause requested just
    // before the native scan starts still holds it at its first checkpoint.
    paused_flag: AtomicBool,
    paused: Mutex<bool>,
    resumed: Condvar,
    /// The CUE sheets each folder's last scan found, so an unchanged sheet is
    /// not read again.
    cue_sheets: Mutex<BTreeMap<String, BTreeMap<String, KnownCue>>>,
}

/// The audio reference of a CUE sheet with the size and time it was read at.
struct KnownCue {
    size: u64,
    modified: i64,
    file_name: String,
}

#[derive(Default)]
struct Run {
    cancelled: AtomicBool,
    failed: AtomicBool,
    failure: Mutex<Option<String>>,
    progress: Mutex<Progress>,
}

#[derive(Default, Serialize)]
struct Progress {
    total_files: usize,
    scanned_files: usize,
    current_file: String,
    error_count: usize,
    progress_pct: f64,
    is_complete: bool,
    /// `{path, message}` for each failed file; reported once complete so
    /// progress updates stay small.
    #[serde(skip)]
    failures: Vec<Value>,
}

struct AudioFile {
    path: String,
    modified: i64,
    size: u64,
    /// The folder image this file falls back to without embedded artwork.
    folder_image: Option<Arc<FolderImage>>,
    /// Whether the directory listing contained a matching `.lrc` sidecar.
    has_lrc_sidecar: bool,
}

impl AudioFile {
    fn expect_folder_image(&self) {
        if let Some(image) = &self.folder_image {
            image.artwork.expect_song();
        }
    }

    fn folder_image_done(&self) {
        if let Some(image) = &self.folder_image {
            image.artwork.song_done();
        }
    }
}

struct ScanSummary {
    deleted: Vec<String>,
    skipped: usize,
    total: usize,
    run: Arc<Run>,
}

impl Backend {
    pub fn get_library_scan_progress(&self) -> Result<Value, String> {
        let _operation = self.enter()?;
        let current = self.library_scan.current.lock().expect("library scan lock");
        let Some(run) = current.as_ref() else {
            return serde_json::to_value(Progress::default()).map_err(|error| error.to_string());
        };
        let progress = run.progress.lock().expect("scan progress lock");
        let mut value = serde_json::to_value(&*progress).map_err(|error| error.to_string())?;
        if progress.is_complete && !progress.failures.is_empty() {
            value["failures"] = progress.failures.clone().into();
        }
        Ok(value)
    }

    pub fn cancel_library_scan(&self) -> Result<(), String> {
        let _operation = self.enter()?;
        if let Some(run) = self
            .library_scan
            .current
            .lock()
            .expect("library scan lock")
            .as_ref()
        {
            run.cancelled.store(true, Ordering::Release);
        }
        // Wake paused workers so they observe the cancellation.
        self.set_library_scan_paused(false);
        Ok(())
    }

    /// Holds the scan at its next checkpoint. Workers keep their position in
    /// memory, so [`Self::resume_library_scan`] continues with the next file.
    pub fn pause_library_scan(&self) -> Result<(), String> {
        let _operation = self.enter()?;
        self.set_library_scan_paused(true);
        Ok(())
    }

    pub fn resume_library_scan(&self) -> Result<(), String> {
        let _operation = self.enter()?;
        self.set_library_scan_paused(false);
        Ok(())
    }

    fn set_library_scan_paused(&self, paused: bool) {
        let mut guard = self
            .library_scan
            .paused
            .lock()
            .expect("library scan pause lock");
        *guard = paused;
        self.library_scan
            .paused_flag
            .store(paused, Ordering::Release);
        drop(guard);
        self.library_scan.resumed.notify_all();
    }

    fn wait_while_library_scan_paused(&self, run: &Run, check: Check<'_>) -> Result<(), String> {
        let state = &self.library_scan;
        if !state.paused_flag.load(Ordering::Acquire) {
            return Ok(());
        }
        let mut paused = state.paused.lock().expect("library scan pause lock");
        while *paused && !run.cancelled.load(Ordering::Acquire) {
            paused = state
                .resumed
                .wait_timeout(paused, PAUSE_POLL)
                .expect("library scan pause lock")
                .0;
            if *paused {
                drop(paused);
                // Shutdown and released request leases still end a paused scan.
                self.check()?;
                check()?;
                paused = state.paused.lock().expect("library scan pause lock");
            }
        }
        Ok(())
    }

    pub fn scan_library_folder_incremental(
        &self,
        folder: &str,
        existing_json: &str,
        check: Check<'_>,
    ) -> Result<Value, String> {
        // Go tolerates invalid snapshot JSON. A bad value does not discard other
        // valid paths from an otherwise well-formed object.
        let value: Value = serde_json::from_str(existing_json).unwrap_or(Value::Null);
        let existing = value
            .as_object()
            .map(|object| {
                object
                    .iter()
                    .filter_map(|(path, value)| {
                        value
                            .as_i64()
                            .or_else(|| value.is_null().then_some(0))
                            .map(|value| (path.clone(), value))
                    })
                    .collect()
            })
            .unwrap_or_default();
        self.incremental(folder, existing, check)
    }

    pub fn scan_library_folder_incremental_from_snapshot(
        &self,
        folder: &str,
        snapshot: &str,
        check: Check<'_>,
    ) -> Result<Value, String> {
        let _operation = self.enter()?;
        let mut existing = BTreeMap::new();
        if !snapshot.is_empty() {
            self.check()?;
            check()?;
            let input = self
                .environment()
                .native_files()?
                .resolve_legacy(snapshot)?;
            input.native_display()?;
            let file = input
                .open(OpenOptions::new().read(true))
                .map_err(|error| format!("failed to load incremental snapshot: {error}"))?;
            let mut reader = BufReader::new(file);
            let mut line = Vec::new();
            loop {
                self.check()?;
                check()?;
                line.clear();
                let read = (&mut reader)
                    .take(64 * 1024)
                    .read_until(b'\n', &mut line)
                    .map_err(|error| format!("failed to load incremental snapshot: {error}"))?;
                if read == 0 {
                    break;
                }
                if read == 64 * 1024 && line.last() != Some(&b'\n') {
                    return Err(
                        "failed to load incremental snapshot: bufio.Scanner: token too long".into(),
                    );
                }
                if line.last() == Some(&b'\n') {
                    line.pop();
                }
                if line.last() == Some(&b'\r') {
                    line.pop();
                }
                let line = String::from_utf8_lossy(&line);
                if let Some((time, path)) = line.split_once('\t')
                    && let Ok(time) = time.parse::<i64>()
                {
                    existing.insert(path.into(), time);
                }
            }
        }
        self.incremental(folder, existing, check)
    }

    fn incremental(
        &self,
        folder: &str,
        existing: BTreeMap<String, i64>,
        check: Check<'_>,
    ) -> Result<Value, String> {
        let mut tracks = Vec::new();
        let summary = self.scan_library(
            folder,
            Some(&existing),
            true,
            &mut |value| {
                tracks.push(value);
                Ok(())
            },
            check,
        )?;
        // json! serializes every value again by reference; moving the rows
        // into the map avoids a second copy of the whole delta.
        let mut delta = serde_json::Map::new();
        delta.insert("scanned".into(), Value::Array(tracks));
        delta.insert(
            "deletedPaths".into(),
            if summary.deleted.is_empty() {
                Value::Null
            } else {
                summary.deleted.into()
            },
        );
        delta.insert("skippedCount".into(), summary.skipped.into());
        delta.insert("totalFiles".into(), summary.total.into());
        Ok(Value::Object(delta))
    }

    pub fn scan_library_folder_to_ndjson_file(
        &self,
        folder: &str,
        output: &str,
        check: Check<'_>,
    ) -> Result<u64, String> {
        let _operation = self.enter()?;
        let check = || self.check().and_then(|()| check());
        check()?;
        if output.is_empty() {
            return Err("output path is empty".into());
        }
        if supported(output) {
            return Err("scan output must not overwrite an audio or CUE file".into());
        }
        let files = self.environment().native_files()?;
        let output = files.resolve_legacy(output)?;
        output.native_display()?;
        let _lock = files.lock(&output, &check)?;
        let mut stage = output
            .stage_existing_parent()
            .map_err(|error| format!("create scan output: {error}"))?;
        let mut count = 0;
        let summary;
        {
            let mut writer = BufWriter::with_capacity(64 * 1024, &mut stage.file);
            summary = self.scan_library(
                folder,
                None,
                false,
                &mut |value| {
                    serde_json::to_writer(&mut writer, &value)
                        .map_err(|error| error.to_string())?;
                    writer.write_all(b"\n").map_err(|error| error.to_string())?;
                    count += 1;
                    Ok(())
                },
                &check,
            )?;
            writer
                .flush()
                .map_err(|error| format!("flush scan output: {error}"))?;
        }
        stage.publish(&|| {
            check()?;
            if summary.run.cancelled.load(Ordering::Acquire) {
                Err("scan cancelled".into())
            } else {
                Ok(())
            }
        })?;
        Ok(count)
    }

    fn collect_library_files(
        &self,
        folder: &str,
        check: Check<'_>,
    ) -> Result<Vec<AudioFile>, String> {
        let files = self.environment().native_files()?;
        // Each entry records whether its parent directory was already
        // validated. Children then need one lstat of their own name instead of
        // re-checking every ancestor plus two more stats per file; on FUSE SD
        // cards, USB drives and network mounts each of those is a round trip.
        // The last field carries a folder image: the one a file uses, or for
        // a directory, the image of its parent.
        let mut pending: Vec<(String, bool, Option<Arc<FolderImage>>, bool)> =
            vec![(folder.to_owned(), false, None, false)];
        let mut collected = Vec::new();
        while let Some((path, parent_validated, inherited, has_lrc_sidecar)) = pending.pop() {
            check()?;
            let input = files.resolve_legacy(&path)?;
            let metadata = if parent_validated {
                input.native_child_metadata().map_err(|error| {
                    if error.kind() == std::io::ErrorKind::NotFound {
                        format!("walk library path {path}: {error}")
                    } else {
                        error.to_string()
                    }
                })?
            } else {
                input.native_display()?;
                input
                    .metadata()
                    .map_err(|error| format!("walk library path {path}: {error}"))?
            };
            if metadata.is_dir() {
                let entries = input
                    .entries()
                    .map_err(|error| format!("walk library path {path}: {error}"))?;
                // Record matching `.lrc` sidecar stems from the listing so
                // tracks without sidecars skip two failed open probes each.
                let mut lrc_stems = BTreeSet::new();
                for (name, directory) in &entries {
                    if !*directory
                        && let Some((stem, ext)) = name.rsplit_once('.')
                        && ext.eq_ignore_ascii_case("lrc")
                    {
                        lrc_stems.insert(stem.to_lowercase());
                    }
                }
                // Folder images come from this listing, so songs never list
                // their folder. A disc folder without one uses its parent's.
                let own = folder_image(&files, &path, &entries);
                let image = own.clone().or_else(|| {
                    inherited.filter(|_| {
                        Path::new(&path).file_name().is_some_and(|name| {
                            mornye_core::cover::is_disc_folder(&name.to_string_lossy())
                        })
                    })
                });
                for (name, directory) in entries.into_iter().rev() {
                    if !directory && (!supported(&name) || staging(&name)) {
                        continue;
                    }
                    let has_lrc = !directory
                        && !lrc_stems.is_empty()
                        && name
                            .rsplit_once('.')
                            .is_some_and(|(stem, _)| lrc_stems.contains(&stem.to_lowercase()));
                    pending.push((
                        crate::files::clean(&Path::new(&path).join(name))
                            .to_string_lossy()
                            .into_owned(),
                        true,
                        if directory {
                            own.clone()
                        } else {
                            image.clone()
                        },
                        has_lrc,
                    ));
                }
            } else if supported(&path) && !staging(&path) {
                collected.push(AudioFile {
                    path,
                    modified: modified_time(&metadata),
                    size: metadata.len(),
                    folder_image: inherited,
                    has_lrc_sidecar,
                });
            }
        }
        Ok(collected)
    }

    fn scan_library(
        &self,
        folder: &str,
        existing: Option<&BTreeMap<String, i64>>,
        ordered: bool,
        sink: &mut dyn FnMut(Value) -> Result<(), String>,
        check: Check<'_>,
    ) -> Result<ScanSummary, String> {
        let _operation = self.enter()?;
        check()?;
        if folder.is_empty() {
            return Err("folder path is empty".into());
        }
        // Retain the app data capability for this scan instead of reopening its
        // directory for every track. Path resolution still checks live grants.
        let files = self.environment().native_files()?;
        let input = files.resolve_legacy(folder)?;
        input.native_display()?;
        let metadata = input
            .metadata()
            .map_err(|error| format!("folder not found: {error}"))?;
        if !metadata.is_dir() {
            return Err(format!("path is not a folder: {folder}"));
        }
        let run = Arc::new(Run::default());
        if let Some(previous) = self
            .library_scan
            .current
            .lock()
            .expect("library scan lock")
            .replace(run.clone())
        {
            previous.cancelled.store(true, Ordering::Release);
        }
        let check = || {
            // Wait before taking the failure lock so paused workers do not
            // serialize on it. In the common running/unfailed case this path
            // stays completely lock-free across parallel scan workers.
            self.wait_while_library_scan_paused(&run, check)?;
            if run.failed.load(Ordering::Acquire) {
                let failure = run.failure.lock().expect("scan failure lock");
                if let Some(error) = failure.as_ref() {
                    return Err(error.clone());
                }
            }
            let result = self.check().and_then(|()| {
                if run.cancelled.load(Ordering::Acquire) {
                    Err("scan cancelled".into())
                } else {
                    check()
                }
            });
            if let Err(error) = &result {
                let mut failure = run.failure.lock().expect("scan failure lock");
                if failure.is_none() {
                    *failure = Some(error.clone());
                    run.failed.store(true, Ordering::Release);
                }
            }
            result
        };
        let _owner = loop {
            check()?;
            match self.library_scan.owner.try_lock() {
                Ok(owner) => break owner,
                Err(TryLockError::WouldBlock) => thread::sleep(Duration::from_millis(5)),
                Err(TryLockError::Poisoned(_)) => return Err("library scan owner poisoned".into()),
            }
        };
        let current = self.collect_library_files(folder, &check)?;
        let total = current.len();
        run.progress.lock().expect("scan progress lock").total_files = total;
        let paths: BTreeSet<_> = current.iter().map(|file| file.path.as_str()).collect();
        let mut cue_times = BTreeMap::new();
        let mut deleted = Vec::new();
        if let Some(existing) = existing {
            for (path, time) in existing {
                let base = cue_base(path);
                if let Some(base) = base {
                    cue_times.entry(base).or_insert(*time);
                }
                if !paths.contains(base.unwrap_or(path)) {
                    deleted.push(path.clone());
                }
            }
        }
        let mut skipped = 0;
        let mut unchanged = BTreeSet::new();
        let tasks: Vec<_> = current
            .iter()
            .filter(|file| {
                let old = existing
                    .and_then(|existing| existing.get(&file.path))
                    .copied()
                    .or_else(|| {
                        (library_extension(&file.path, "") == "cue")
                            .then(|| cue_times.get(file.path.as_str()).copied())
                            .flatten()
                    });
                if old == Some(file.modified) {
                    skipped += 1;
                    unchanged.insert(file.path.as_str());
                    false
                } else {
                    true
                }
            })
            .collect();
        let time = scan_time();
        // Thumbnails get one folder flush when the scan finishes, also when
        // it fails.
        let covers = SyncBatch::default();
        let mut referenced = BTreeSet::new();
        let mut parsed = BTreeMap::new();
        let mut known = self
            .library_scan
            .cue_sheets
            .lock()
            .expect("library scan CUE lock")
            .remove(folder)
            .unwrap_or_default();
        let mut sheets = BTreeMap::new();
        // An unchanged CUE still owns its backing audio. Inspect all current
        // sheets so incremental scans never re-add that audio as a full album.
        // A sheet the scan skips keeps the reference read at its size and time.
        for file in &current {
            check()?;
            if library_extension(&file.path, "") != "cue" {
                continue;
            }
            let reused = known.remove(&file.path).filter(|cue| {
                unchanged.contains(file.path.as_str())
                    && (cue.size, cue.modified) == (file.size, file.modified)
            });
            let (file_name, sheet) = match reused {
                Some(cue) => (cue.file_name, None),
                None => match self.parse_cue_file(&file.path, &check) {
                    Ok(sheet) => (sheet.file_name.clone(), Some(sheet)),
                    Err(_) => continue,
                },
            };
            sheets.insert(
                file.path.clone(),
                KnownCue {
                    size: file.size,
                    modified: file.modified,
                    file_name: file_name.clone(),
                },
            );
            if !file_name.is_empty()
                && let Ok(audio) =
                    self.resolve_cue_audio(&file.path, &file_name, "", Some(&paths), &check)
            {
                referenced.insert(audio.clone());
                if let Some(sheet) = sheet {
                    parsed.insert(file.path.as_str(), (sheet, audio));
                }
            }
        }
        self.library_scan
            .cue_sheets
            .lock()
            .expect("library scan CUE lock")
            .insert(folder.to_owned(), sheets);
        check()?;
        let mut results: BTreeMap<usize, Vec<Value>> = BTreeMap::new();
        let mut audio = Vec::new();
        let mut completed = skipped;
        for (index, file) in tasks.iter().enumerate() {
            check()?;
            if library_extension(&file.path, "") == "cue" {
                let result = match parsed.get(file.path.as_str()) {
                    Some((sheet, audio)) => self.scan_cue_sheet(
                        &file.path,
                        sheet,
                        audio,
                        "",
                        file.modified,
                        "",
                        &time,
                        Some(&covers),
                        file.folder_image.as_deref(),
                        &check,
                    ),
                    None => self.scan_cue_file_for_library(
                        &file.path,
                        "",
                        "",
                        file.modified,
                        "",
                        &time,
                        &check,
                    ),
                }
                .map(|value| value.as_array().expect("cue track array").clone());
                check()?;
                completed += 1;
                update(&run, completed, &file.path, result.as_ref().err());
                if let Ok(tracks) = result {
                    if ordered {
                        results.insert(index, tracks);
                    } else {
                        for value in tracks {
                            sink(value)?;
                        }
                    }
                }
            } else if referenced.contains(&file.path) {
                completed += 1;
                update(&run, completed, &file.path, None);
            } else {
                audio.push((index, *file));
            }
        }
        // Allow short bursts without parking workers after each result. At most
        // 96 completed tracks wait; NDJSON still uses bounded memory. Tag reads
        // mostly wait on storage, so slow media benefits from more files in
        // flight than the core count; artwork decoding stays serialized.
        let workers = if audio.len() < 16 {
            1
        } else {
            thread::available_parallelism()
                .map_or(2, usize::from)
                .clamp(2, 6)
        };
        // A folder image's artwork is kept from its first song to its last.
        for (_, file) in &audio {
            file.expect_folder_image();
        }
        let next = AtomicUsize::new(0);
        let stop = AtomicBool::new(false);
        thread::scope(|scope| -> Result<(), String> {
            let (sender, receiver) = mpsc::sync_channel(workers * 16);
            for _ in 0..workers {
                let sender = sender.clone();
                let (audio, next, stop, check, time, files, covers) =
                    (&audio, &next, &stop, &check, &time, &files, &covers);
                scope.spawn(move || {
                    while !stop.load(Ordering::Acquire) {
                        let Some((index, file)) = audio.get(next.fetch_add(1, Ordering::AcqRel))
                        else {
                            break;
                        };
                        let result = check().and_then(|()| {
                            self.scan_audio_file(
                                files,
                                &file.path,
                                "",
                                &format!("{}|{}|{}", file.path, file.size, file.modified),
                                time,
                                file.modified,
                                Some(covers),
                                file.folder_image.as_deref(),
                                Some(file.has_lrc_sidecar),
                                check,
                            )
                        });
                        file.folder_image_done();
                        if sender.send((*index, file.path.as_str(), result)).is_err() {
                            break;
                        }
                    }
                });
            }
            drop(sender);
            let mut failure = None;
            for (index, path, result) in receiver {
                completed += 1;
                update(&run, completed, path, result.as_ref().err());
                if failure.is_none() {
                    let emit = check().and_then(|()| {
                        if let Ok(value) = result {
                            if ordered {
                                results.insert(index, vec![value]);
                            } else {
                                sink(value)?;
                            }
                        }
                        Ok(())
                    });
                    if let Err(error) = emit {
                        failure = Some(error);
                        stop.store(true, Ordering::Release);
                    }
                }
            }
            failure.map_or(Ok(()), Err)
        })?;
        covers.flush();
        check()?;
        for (_, values) in results {
            for value in values {
                check()?;
                sink(value)?;
            }
        }
        check()?;
        // Share the existing duplicate index. A scan may observe edits/deletes
        // after a previously cached lookup; never retain that stale snapshot.
        if existing.is_none() || !tasks.is_empty() || !deleted.is_empty() {
            self.environment()
                .invalidate_isrc_cache(folder)
                .map_err(|error| error.to_string())?;
        }
        let mut progress = run.progress.lock().expect("scan progress lock");
        progress.scanned_files = total;
        progress.is_complete = true;
        progress.progress_pct = 100.0;
        drop(progress);
        Ok(ScanSummary {
            deleted,
            skipped,
            total,
            run,
        })
    }
}

/// The folder image among the `entries` of `directory`. A linked, special or
/// unreadable image only costs the fallback, never the scan.
fn folder_image(
    files: &crate::files::ExtensionFiles,
    directory: &str,
    entries: &[(String, bool)],
) -> Option<Arc<FolderImage>> {
    let name = mornye_core::cover::folder_image(
        entries
            .iter()
            .filter(|(_, directory)| !directory)
            .map(|(name, _)| name.as_str()),
    )?;
    let path = crate::files::clean(&Path::new(directory).join(name))
        .to_string_lossy()
        .into_owned();
    let metadata = files
        .resolve_legacy(&path)
        .ok()?
        .native_child_metadata()
        .ok()
        .filter(|metadata| metadata.is_file())?;
    Some(Arc::new(FolderImage {
        path,
        size: metadata.len(),
        modified: modified_time(&metadata),
        artwork: Default::default(),
    }))
}

fn cue_base(path: &str) -> Option<&str> {
    path.rfind("#track")
        .filter(|index| *index > 0)
        .map(|index| &path[..index])
}

fn supported(path: &str) -> bool {
    matches!(
        library_extension(path, "").as_str(),
        "flac"
            | "m4a"
            | "mp4"
            | "aac"
            | "mp3"
            | "opus"
            | "ogg"
            | "ape"
            | "wv"
            | "mpc"
            | "wav"
            | "aiff"
            | "aif"
            | "dsf"
            | "dff"
            | "cue"
    )
}

fn staging(path: &str) -> bool {
    let name = Path::new(path)
        .file_name()
        .unwrap_or_default()
        .to_string_lossy()
        .to_lowercase();
    name.ends_with(".partial")
        || name
            .rsplit_once('.')
            .is_some_and(|(stem, _)| stem.ends_with(".partial"))
}

fn update(run: &Run, completed: usize, path: &str, error: Option<&String>) {
    let mut progress = run.progress.lock().expect("scan progress lock");
    progress.scanned_files = completed;
    progress.current_file = Path::new(path)
        .file_name()
        .unwrap_or_default()
        .to_string_lossy()
        .into_owned();
    if let Some(error) = error {
        progress.error_count += 1;
        if progress.failures.len() < REPORTED_FAILURES {
            progress
                .failures
                .push(json!({"path": path, "message": error}));
        }
    }
    if progress.total_files > 0 {
        progress.progress_pct = completed as f64 / progress.total_files as f64 * 100.0;
    }
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;
    use crate::RuntimeLimits;
    use crate::backend::cover::tests::{artwork, flac_with_picture};
    use std::fs;
    use std::path::PathBuf;

    fn backend(root: &Path, library: &Path) -> Backend {
        let backend = Backend::new(
            &root.join("sources"),
            &root.join("data"),
            "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
            "1",
            RuntimeLimits::default(),
        )
        .unwrap();
        backend
            .environment()
            .set_allowed_download_directories(&[library.to_path_buf()])
            .unwrap();
        backend
    }

    fn walk(backend: &Backend, folder: &Path) -> Result<Vec<AudioFile>, String> {
        backend.collect_library_files(&folder.to_string_lossy(), &|| Ok(()))
    }

    #[test]
    fn walk_keeps_order_size_and_time_with_one_stat_per_child() {
        let root = tempfile::tempdir().unwrap();
        let library = fs::canonicalize(root.path()).unwrap().join("library");
        fs::create_dir_all(library.join("A/B")).unwrap();
        fs::write(library.join("A/B/song.flac"), b"flac bytes").unwrap();
        fs::write(library.join("A/c.mp3"), b"mp3").unwrap();
        fs::write(library.join("notes.txt"), b"ignored").unwrap();
        fs::write(library.join("A/B/song.lrc"), b"[00:01.00]Lyrics").unwrap();
        fs::write(library.join("A/c.LRC"), b"[00:01.00]Lyrics").unwrap();
        fs::write(library.join("x.partial.flac"), b"staging").unwrap();
        let backend = backend(root.path(), &library);

        let files = walk(&backend, &library).unwrap();

        let expected = [library.join("A/B/song.flac"), library.join("A/c.mp3")];
        assert_eq!(
            files
                .iter()
                .map(|file| file.path.clone())
                .collect::<Vec<_>>(),
            expected
                .iter()
                .map(|path| path.to_string_lossy().into_owned())
                .collect::<Vec<_>>(),
        );
        for (file, path) in files.iter().zip(&expected) {
            let metadata = fs::metadata(path).unwrap();
            let modified = metadata
                .modified()
                .unwrap()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_millis() as i64;
            assert_eq!(file.size, metadata.len());
            assert_eq!(file.modified, modified);
        }
    }

    #[cfg(unix)]
    #[test]
    fn walk_still_rejects_nested_symlinks() {
        let root = tempfile::tempdir().unwrap();
        let library = fs::canonicalize(root.path()).unwrap().join("library");
        fs::create_dir_all(library.join("A")).unwrap();
        fs::write(library.join("A/song.flac"), b"flac").unwrap();
        std::os::unix::fs::symlink(library.join("A/song.flac"), library.join("A/link.flac"))
            .unwrap();
        let backend = backend(root.path(), &library);

        let error = walk(&backend, &library).err().expect("linked file");
        assert_eq!(
            error,
            "native media path must not contain symlinks or special files"
        );

        fs::remove_file(library.join("A/link.flac")).unwrap();
        // A linked directory with an audio-like name reaches the stat check.
        std::os::unix::fs::symlink(library.join("A"), library.join("B.flac")).unwrap();
        let error = walk(&backend, &library).err().expect("linked directory");
        assert_eq!(
            error,
            "native media path must not contain symlinks or special files"
        );
    }

    fn paused_library(root: &Path) -> (Backend, String) {
        let library = fs::canonicalize(root).unwrap().join("library");
        fs::create_dir_all(&library).unwrap();
        for index in 0..3 {
            fs::write(library.join(format!("{index}.mp3")), b"not audio").unwrap();
        }
        let backend = backend(root, &library);
        backend.pause_library_scan().unwrap();
        (backend, library.to_string_lossy().into_owned())
    }

    fn wait_for_run(backend: &Backend) {
        while backend
            .library_scan
            .current
            .lock()
            .expect("library scan lock")
            .is_none()
        {
            thread::sleep(Duration::from_millis(5));
        }
    }

    #[test]
    fn paused_scan_holds_its_position_until_resumed() {
        let root = tempfile::tempdir().unwrap();
        let (backend, folder) = paused_library(root.path());

        thread::scope(|scope| {
            let scan =
                scope.spawn(|| backend.scan_library_folder_incremental(&folder, "{}", &|| Ok(())));
            wait_for_run(&backend);
            thread::sleep(Duration::from_millis(300));
            assert!(!scan.is_finished());
            let progress = backend.get_library_scan_progress().unwrap();
            assert_eq!(progress["scanned_files"], 0);
            assert_eq!(progress["is_complete"], false);

            backend.resume_library_scan().unwrap();
            let result = scan.join().unwrap().unwrap();
            assert_eq!(result["totalFiles"], 3);
        });
        let progress = backend.get_library_scan_progress().unwrap();
        assert_eq!(progress["scanned_files"], 3);
        assert_eq!(progress["is_complete"], true);
    }

    #[test]
    fn finished_scan_lists_each_unreadable_file_with_its_reason() {
        use std::os::unix::fs::PermissionsExt;
        let root = tempfile::tempdir().unwrap();
        let library = fs::canonicalize(root.path()).unwrap().join("library");
        fs::create_dir_all(&library).unwrap();
        fs::write(library.join("readable.mp3"), b"not audio").unwrap();
        let locked = library.join("locked.flac");
        fs::write(&locked, b"fLaC").unwrap();
        fs::set_permissions(&locked, fs::Permissions::from_mode(0o000)).unwrap();
        if fs::File::open(&locked).is_ok() {
            // Running as root: nothing on this host is unreadable.
            return;
        }
        let backend = backend(root.path(), &library);

        let result = backend
            .scan_library_folder_incremental(&library.to_string_lossy(), "{}", &|| Ok(()))
            .unwrap();

        assert_eq!(result["totalFiles"], 2);
        let progress = backend.get_library_scan_progress().unwrap();
        assert_eq!(progress["error_count"], 1);
        let failures = progress["failures"].as_array().unwrap();
        assert_eq!(failures.len(), 1);
        assert_eq!(failures[0]["path"], locked.to_string_lossy().as_ref());
        assert!(!failures[0]["message"].as_str().unwrap().is_empty());
    }

    /// Writes `albums` folders of `tracks` FLAC files; the songs of one album
    /// embed the same 1200 px picture. Returns the canonical library folder.
    fn library_with_artwork(root: &Path, albums: u32, tracks: u32, seed: u32) -> PathBuf {
        let library = fs::canonicalize(root).unwrap().join("library");
        for album in 0..albums {
            let flac = flac_with_picture(&artwork(seed.wrapping_add(album), 1200));
            let folder = library.join(format!("{album:04}"));
            fs::create_dir_all(&folder).unwrap();
            for track in 0..tracks {
                fs::write(folder.join(format!("{track:02}.flac")), &flac).unwrap();
            }
        }
        library
    }

    fn thumbnails(covers: &Path) -> Vec<(String, Vec<u8>)> {
        let mut files: Vec<_> = fs::read_dir(covers)
            .unwrap()
            .map(|entry| {
                let path = entry.unwrap().path();
                let name = path.file_name().unwrap().to_string_lossy().into_owned();
                (name, fs::read(path).unwrap())
            })
            .collect();
        files.sort();
        files
    }

    #[test]
    fn scan_thumbnails_are_whole_files_even_when_the_scan_stops() {
        let root = tempfile::tempdir().unwrap();
        let library = library_with_artwork(root.path(), 2, 3, 7_000);
        let expected: Vec<_> = (0..2)
            .map(|album| {
                let art = artwork(7_000 + album, 1200);
                mornye_core::cover::library_thumbnail(&art, &|| Ok(())).unwrap()
            })
            .collect();
        let backend = backend(root.path(), &library);
        let covers = root.path().join("data/library_covers");
        backend
            .set_library_cover_cache_directory(&covers.to_string_lossy())
            .unwrap();
        let folder = library.to_string_lossy();

        let stopped = backend.scan_library_folder_incremental(&folder, "{}", &|| {
            let written = fs::read_dir(&covers).map_or(0, |entries| {
                entries
                    .filter(|entry| {
                        !entry
                            .as_ref()
                            .unwrap()
                            .file_name()
                            .to_string_lossy()
                            .ends_with(".partial")
                    })
                    .count()
            });
            if written >= 2 {
                Err("scan cancelled".into())
            } else {
                Ok(())
            }
        });
        assert_eq!(stopped.unwrap_err(), "scan cancelled");
        let partial = thumbnails(&covers);
        assert!(!partial.is_empty() && partial.len() < 6);
        for (name, bytes) in &partial {
            assert!(name.starts_with("cover_"), "{name}");
            assert!(expected.iter().any(|thumbnail| **thumbnail == **bytes));
        }

        let result = backend
            .scan_library_folder_incremental(&folder, "{}", &|| Ok(()))
            .unwrap();
        let scanned = result["scanned"].as_array().unwrap();
        assert_eq!(scanned.len(), 6);
        for row in scanned {
            let path = Path::new(row["filePath"].as_str().unwrap());
            let album: usize = path
                .parent()
                .unwrap()
                .file_name()
                .unwrap()
                .to_str()
                .unwrap()
                .parse()
                .unwrap();
            let cover = row["coverPath"].as_str().unwrap();
            assert_eq!(Path::new(cover).parent().unwrap(), covers);
            assert_eq!(fs::read(cover).unwrap(), *expected[album]);
        }
        assert_eq!(thumbnails(&covers).len(), 6);
    }

    #[test]
    fn a_scan_stores_one_thumbnail_file_per_picture_under_every_song_name() {
        use std::os::unix::fs::MetadataExt;
        let root = tempfile::tempdir().unwrap();
        let library = library_with_artwork(root.path(), 2, 3, 8_000);
        let backend = backend(root.path(), &library);
        let covers = root.path().join("data/library_covers");
        backend
            .set_library_cover_cache_directory(&covers.to_string_lossy())
            .unwrap();

        let result = backend
            .scan_library_folder_incremental(&library.to_string_lossy(), "{}", &|| Ok(()))
            .unwrap();

        let mut albums: BTreeMap<String, BTreeSet<u64>> = BTreeMap::new();
        let mut names = BTreeSet::new();
        for row in result["scanned"].as_array().unwrap() {
            let song = Path::new(row["filePath"].as_str().unwrap());
            let cover = row["coverPath"].as_str().unwrap();
            assert!(names.insert(cover.to_owned()));
            albums
                .entry(song.parent().unwrap().to_string_lossy().into_owned())
                .or_default()
                .insert(fs::metadata(cover).unwrap().ino());
        }
        assert_eq!(names.len(), 6);
        assert_eq!(thumbnails(&covers).len(), 6);
        let files: BTreeSet<_> = albums.values().flatten().collect();
        if cfg!(any(target_vendor = "apple", target_os = "linux")) {
            assert!(albums.values().all(|inodes| inodes.len() == 1));
            assert_eq!(files.len(), 2);
        } else {
            assert_eq!(files.len(), 6);
        }
    }

    /// A FLAC file with stream info and no picture block.
    fn flac_without_picture() -> Vec<u8> {
        let mut info = [0; 34];
        let packed = (44_100_u64 << 44) | (1_u64 << 41) | (15_u64 << 36) | 44_100;
        info[10..18].copy_from_slice(&packed.to_be_bytes());
        let mut flac = b"fLaC\x80".to_vec();
        flac.extend(&(info.len() as u32).to_be_bytes()[1..]);
        flac.extend(info);
        flac.extend([0xff, 0xf8]);
        flac
    }

    /// Scans `library` in full and maps each song's path below it to the
    /// bytes of its cover, if any.
    fn scanned_covers(root: &Path, library: &Path) -> BTreeMap<String, Option<Vec<u8>>> {
        scanned_covers_with(root, library, &|| Ok(()))
    }

    fn scanned_covers_with(
        root: &Path,
        library: &Path,
        check: Check<'_>,
    ) -> BTreeMap<String, Option<Vec<u8>>> {
        let backend = backend(root, library);
        let covers = root.join("data/library_covers");
        backend
            .set_library_cover_cache_directory(&covers.to_string_lossy())
            .unwrap();
        let result = backend
            .scan_library_folder_incremental(&library.to_string_lossy(), "{}", check)
            .unwrap();
        result["scanned"]
            .as_array()
            .unwrap()
            .iter()
            .map(|row| {
                let path = row["filePath"].as_str().unwrap();
                let song = path
                    .strip_prefix(&*library.to_string_lossy())
                    .unwrap()
                    .trim_start_matches('/')
                    .to_owned();
                let cover = row["coverPath"].as_str().map(|cover| {
                    assert_eq!(Path::new(cover).parent().unwrap(), covers);
                    fs::read(cover).unwrap()
                });
                (song, cover)
            })
            .collect()
    }

    fn thumbnail(art: &[u8]) -> Vec<u8> {
        mornye_core::cover::library_thumbnail(art, &|| Ok(()))
            .unwrap()
            .to_vec()
    }

    #[test]
    fn songs_without_embedded_art_use_their_folder_image() {
        let root = tempfile::tempdir().unwrap();
        let library = fs::canonicalize(root.path()).unwrap().join("library");
        let album = library.join("Album");
        fs::create_dir_all(&album).unwrap();
        let art = artwork(9_000, 1200);
        fs::write(album.join("cover.jpg"), &art).unwrap();
        for track in ["01.flac", "02.flac"] {
            fs::write(album.join(track), flac_without_picture()).unwrap();
        }
        // CUE tracks share the same artwork path.
        let cue = library.join("Cue");
        fs::create_dir_all(&cue).unwrap();
        let cue_art = artwork(9_001, 600);
        fs::write(cue.join("folder.jpg"), &cue_art).unwrap();
        fs::write(cue.join("album.flac"), flac_without_picture()).unwrap();
        fs::write(
            cue.join("album.cue"),
            "FILE \"album.flac\" WAVE\nTRACK 01 AUDIO\nTITLE \"One\"\nINDEX 01 00:00:00\n",
        )
        .unwrap();
        let none = library.join("None");
        fs::create_dir_all(&none).unwrap();
        fs::write(none.join("01.flac"), flac_without_picture()).unwrap();
        fs::write(none.join("back.jpg"), &art).unwrap();

        let covers = scanned_covers(root.path(), &library);

        assert_eq!(covers.len(), 4);
        assert_eq!(covers["Album/01.flac"], Some(thumbnail(&art)));
        assert_eq!(covers["Album/02.flac"], Some(thumbnail(&art)));
        assert_eq!(covers["Cue/album.cue#track01"], Some(thumbnail(&cue_art)));
        assert_eq!(covers["None/01.flac"], None);
    }

    #[test]
    fn embedded_art_wins_over_the_folder_image() {
        let root = tempfile::tempdir().unwrap();
        let library = fs::canonicalize(root.path()).unwrap().join("library");
        let album = library.join("Album");
        fs::create_dir_all(&album).unwrap();
        let embedded = artwork(9_100, 1200);
        fs::write(album.join("01.flac"), flac_with_picture(&embedded)).unwrap();
        fs::write(album.join("02.flac"), flac_without_picture()).unwrap();
        let folder = artwork(9_101, 1200);
        fs::write(album.join("cover.jpg"), &folder).unwrap();

        let covers = scanned_covers(root.path(), &library);

        assert_eq!(covers["Album/01.flac"], Some(thumbnail(&embedded)));
        assert_eq!(covers["Album/02.flac"], Some(thumbnail(&folder)));
    }

    #[test]
    fn folder_images_follow_stem_priority_ignore_case_and_skip_apple_double() {
        let root = tempfile::tempdir().unwrap();
        let library = fs::canonicalize(root.path()).unwrap().join("library");
        let arts: Vec<_> = (0..6).map(|seed| artwork(9_200 + seed, 400)).collect();
        for (folder, images) in [
            (
                "Priority",
                [("album.jpg", 0), ("front.png", 1), ("folder.jpeg", 2)],
            ),
            (
                "Case",
                [("Folder.JPG", 0), ("COVER.PNG", 3), ("AlbumArt.webp", 1)],
            ),
            (
                "Double",
                [("._cover.jpg", 0), ("._folder.jpg", 1), ("front.jpg", 4)],
            ),
            (
                "Hidden",
                [("._cover.jpg", 0), (".folder.jpg", 1), ("cover.gif", 5)],
            ),
        ] {
            let folder = library.join(folder);
            fs::create_dir_all(&folder).unwrap();
            fs::write(folder.join("01.flac"), flac_without_picture()).unwrap();
            for (name, art) in images {
                fs::write(folder.join(name), &arts[art]).unwrap();
            }
        }

        let covers = scanned_covers(root.path(), &library);

        assert_eq!(covers["Priority/01.flac"], Some(thumbnail(&arts[2])));
        assert_eq!(covers["Case/01.flac"], Some(thumbnail(&arts[3])));
        assert_eq!(covers["Double/01.flac"], Some(thumbnail(&arts[4])));
        assert_eq!(covers["Hidden/01.flac"], None);
    }

    #[test]
    fn disc_folders_without_an_image_use_their_parents() {
        let root = tempfile::tempdir().unwrap();
        let library = fs::canonicalize(root.path()).unwrap().join("library");
        let album = library.join("Album");
        let parent = artwork(9_300, 800);
        let own = artwork(9_301, 800);
        for folder in ["CD1", "Disc 2 - Live", "Disk 03", "Extras"] {
            fs::create_dir_all(album.join(folder)).unwrap();
            fs::write(album.join(folder).join("01.flac"), flac_without_picture()).unwrap();
        }
        fs::write(album.join("cover.jpg"), &parent).unwrap();
        fs::write(album.join("Disk 03/folder.jpg"), &own).unwrap();
        // Only one level up: a disc folder's own subfolders do not inherit.
        fs::create_dir_all(album.join("CD1/Scans")).unwrap();
        fs::write(album.join("CD1/Scans/01.flac"), flac_without_picture()).unwrap();

        let covers = scanned_covers(root.path(), &library);

        assert_eq!(covers["Album/CD1/01.flac"], Some(thumbnail(&parent)));
        assert_eq!(
            covers["Album/Disc 2 - Live/01.flac"],
            Some(thumbnail(&parent))
        );
        assert_eq!(covers["Album/Disk 03/01.flac"], Some(thumbnail(&own)));
        assert_eq!(covers["Album/Extras/01.flac"], None);
        assert_eq!(covers["Album/CD1/Scans/01.flac"], None);
    }

    #[test]
    fn a_replaced_folder_image_gives_a_new_thumbnail() {
        let root = tempfile::tempdir().unwrap();
        let library = fs::canonicalize(root.path()).unwrap().join("library");
        let album = library.join("Album");
        fs::create_dir_all(&album).unwrap();
        fs::write(album.join("01.flac"), flac_without_picture()).unwrap();
        let image = album.join("cover.jpg");
        let old = artwork(9_400, 900);
        fs::write(&image, &old).unwrap();
        let old_time = std::time::SystemTime::now() - Duration::from_secs(3600);
        fs::File::options()
            .write(true)
            .open(&image)
            .unwrap()
            .set_modified(old_time)
            .unwrap();
        assert_eq!(
            scanned_covers(root.path(), &library)["Album/01.flac"],
            Some(thumbnail(&old))
        );

        let new = artwork(9_401, 900);
        fs::write(&image, &new).unwrap();
        assert_eq!(
            scanned_covers(root.path(), &library)["Album/01.flac"],
            Some(thumbnail(&new))
        );
    }

    /// A PNG beyond the 8 MiB thumbnail cache budget, `extra` bytes apart in
    /// size. Trailing bytes leave the decoded pixels unchanged.
    fn large_png(red: u8, extra: usize) -> Vec<u8> {
        let mut png = std::io::Cursor::new(Vec::new());
        image::RgbImage::from_pixel(1000, 1000, image::Rgb([red, 90, 150]))
            .write_to(&mut png, image::ImageFormat::Png)
            .unwrap();
        let mut png = png.into_inner();
        png.resize((8 << 20) + 1 + extra, 0);
        png
    }

    fn written_thumbnails(covers: &Path) -> usize {
        fs::read_dir(covers).map_or(0, |entries| {
            entries
                .filter(|entry| {
                    !entry
                        .as_ref()
                        .unwrap()
                        .file_name()
                        .to_string_lossy()
                        .ends_with(".partial")
                })
                .count()
        })
    }

    #[test]
    fn a_scan_reads_a_folder_image_once_and_the_next_scan_reads_it_again() {
        let root = tempfile::tempdir().unwrap();
        let library = fs::canonicalize(root.path()).unwrap().join("library");
        let album = library.join("Album");
        fs::create_dir_all(&album).unwrap();
        for track in 0..3 {
            fs::write(
                album.join(format!("{track:02}.flac")),
                flac_without_picture(),
            )
            .unwrap();
        }
        let image = album.join("cover.png");
        let (old, new) = (large_png(10, 0), large_png(20, 1));
        fs::write(&image, &old).unwrap();
        let covers = root.path().join("data/library_covers");
        let replaced = AtomicBool::new(false);

        // Once the first song has its thumbnail, the image changes on disk.
        // Every song of this scan still gets the image it started with.
        let scanned = scanned_covers_with(root.path(), &library, &|| {
            if !replaced.load(Ordering::Acquire) && written_thumbnails(&covers) > 0 {
                fs::write(&image, &new).unwrap();
                replaced.store(true, Ordering::Release);
            }
            Ok(())
        });

        assert!(replaced.load(Ordering::Acquire));
        assert_eq!(scanned.len(), 3);
        let expected = Some(thumbnail(&old));
        assert!(scanned.values().all(|cover| *cover == expected));
        let scanned = scanned_covers(root.path(), &library);
        let expected = Some(thumbnail(&new));
        assert!(scanned.values().all(|cover| *cover == expected));
    }

    #[test]
    fn folder_artwork_is_released_after_the_last_song_that_uses_it() {
        let root = tempfile::tempdir().unwrap();
        let library = fs::canonicalize(root.path()).unwrap().join("library");
        let album = library.join("Album");
        // Album's image covers its disc folders and its own song; Extras and
        // Other have their own.
        for folder in ["CD1", "CD2", "Extras"] {
            fs::create_dir_all(album.join(folder)).unwrap();
            fs::write(album.join(folder).join("01.flac"), b"flac").unwrap();
        }
        fs::write(album.join("CD1/02.flac"), b"flac").unwrap();
        fs::write(album.join("z.flac"), b"flac").unwrap();
        fs::write(album.join("cover.jpg"), b"image").unwrap();
        fs::write(album.join("Extras/folder.jpg"), b"image").unwrap();
        fs::create_dir_all(library.join("Other")).unwrap();
        fs::write(library.join("Other/01.flac"), b"flac").unwrap();
        fs::write(library.join("Other/cover.jpg"), b"image").unwrap();
        let backend = backend(root.path(), &library);
        let files = walk(&backend, &library).unwrap();
        assert_eq!(files.len(), 6);
        for file in &files {
            file.expect_folder_image();
        }

        let reads = AtomicUsize::new(0);
        for (index, file) in files.iter().enumerate() {
            let image = file.folder_image.as_ref().unwrap();
            image
                .artwork
                .get_or_read(&|| Ok(()), || {
                    reads.fetch_add(1, Ordering::Relaxed);
                    let cover = mornye_core::tags::CoverArt {
                        data: b"image".to_vec(),
                        mime: "image/jpeg".into(),
                    };
                    Ok(crate::backend::cover::LibraryArtwork::new(
                        cover,
                        &|| Ok(()),
                    ))
                })
                .unwrap();
            file.folder_image_done();
            let later = files[index + 1..]
                .iter()
                .any(|later| Arc::ptr_eq(later.folder_image.as_ref().unwrap(), image));
            assert_eq!(image.artwork.is_held(), later, "{}", file.path);
        }
        assert_eq!(reads.load(Ordering::Relaxed), 3);
    }

    #[test]
    fn songs_of_a_folder_share_one_thumbnail_of_a_large_folder_image() {
        use std::os::unix::fs::MetadataExt;
        let root = tempfile::tempdir().unwrap();
        let library = fs::canonicalize(root.path()).unwrap().join("library");
        let album = library.join("Album");
        fs::create_dir_all(&album).unwrap();
        // Enough songs for several scan workers.
        for track in 0..20 {
            fs::write(
                album.join(format!("{track:02}.flac")),
                flac_without_picture(),
            )
            .unwrap();
        }
        let image = large_png(30, 0);
        fs::write(album.join("folder.png"), &image).unwrap();

        let scanned = scanned_covers(root.path(), &library);

        assert_eq!(scanned.len(), 20);
        let expected = Some(thumbnail(&image));
        assert!(scanned.values().all(|cover| *cover == expected));
        let covers = root.path().join("data/library_covers");
        let names = fs::read_dir(&covers).unwrap().count();
        let files: BTreeSet<_> = fs::read_dir(&covers)
            .unwrap()
            .map(|entry| entry.unwrap().metadata().unwrap().ino())
            .collect();
        assert_eq!(names, 20);
        if cfg!(any(target_vendor = "apple", target_os = "linux")) {
            assert_eq!(files.len(), 1);
        }
    }

    /// Writes `album.cue` naming `audio` beside `a.flac` and `b.flac` and
    /// returns its path.
    fn cue_beside_two_songs(library: &Path, audio: &str) -> PathBuf {
        let folder = library.join("Cue");
        fs::create_dir_all(&folder).unwrap();
        for song in ["a.flac", "b.flac"] {
            fs::write(folder.join(song), flac_without_picture()).unwrap();
        }
        let cue = folder.join("album.cue");
        fs::write(
            &cue,
            format!("FILE \"{audio}\" WAVE\nTRACK 01 AUDIO\nINDEX 01 00:00:00\n"),
        )
        .unwrap();
        cue
    }

    fn modified_millis(path: &Path) -> i64 {
        fs::metadata(path)
            .unwrap()
            .modified()
            .unwrap()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_millis() as i64
    }

    /// Scans with a snapshot that holds the CUE track at `cue_time` and lists
    /// the scanned file names.
    fn scanned_beside_cue(
        backend: &Backend,
        library: &Path,
        cue: &Path,
        cue_time: i64,
    ) -> Vec<String> {
        let snapshot = json!({format!("{}#track01", cue.to_string_lossy()): cue_time});
        let result = backend
            .scan_library_folder_incremental(
                &library.to_string_lossy(),
                &snapshot.to_string(),
                &|| Ok(()),
            )
            .unwrap();
        result["scanned"]
            .as_array()
            .unwrap()
            .iter()
            .map(|row| {
                Path::new(row["filePath"].as_str().unwrap())
                    .file_name()
                    .unwrap()
                    .to_string_lossy()
                    .into_owned()
            })
            .collect()
    }

    #[test]
    fn an_unchanged_cue_sheet_is_not_read_again() {
        let root = tempfile::tempdir().unwrap();
        let library = fs::canonicalize(root.path()).unwrap().join("library");
        let cue = cue_beside_two_songs(&library, "a.flac");
        let backend = backend(root.path(), &library);
        let time = modified_millis(&cue);
        assert_eq!(
            scanned_beside_cue(&backend, &library, &cue, time),
            ["b.flac"]
        );

        // Same size and time: the scan keeps the reference it read before,
        // as it keeps an unchanged song.
        let original = fs::metadata(&cue).unwrap().modified().unwrap();
        fs::write(
            &cue,
            "FILE \"b.flac\" WAVE\nTRACK 01 AUDIO\nINDEX 01 00:00:00\n",
        )
        .unwrap();
        let file = fs::File::options().write(true).open(&cue).unwrap();
        file.set_modified(original).unwrap();
        assert_eq!(
            scanned_beside_cue(&backend, &library, &cue, time),
            ["b.flac"]
        );

        // A new time reads the sheet again.
        file.set_modified(original + Duration::from_secs(10))
            .unwrap();
        let time = modified_millis(&cue);
        assert_eq!(
            scanned_beside_cue(&backend, &library, &cue, time),
            ["a.flac"]
        );
    }

    #[test]
    fn an_unchanged_cue_sheet_follows_its_audio_file() {
        let root = tempfile::tempdir().unwrap();
        let library = fs::canonicalize(root.path()).unwrap().join("library");
        let cue = cue_beside_two_songs(&library, "album.flac");
        let backend = backend(root.path(), &library);
        let time = modified_millis(&cue);
        // Without album.flac the sheet falls back to another extension.
        fs::write(library.join("Cue/album.mp3"), b"not audio").unwrap();
        assert_eq!(
            scanned_beside_cue(&backend, &library, &cue, time),
            ["a.flac", "b.flac"]
        );
        fs::write(library.join("Cue/album.flac"), flac_without_picture()).unwrap();
        assert_eq!(
            scanned_beside_cue(&backend, &library, &cue, time),
            ["a.flac", "album.mp3", "b.flac"]
        );
    }

    #[test]
    fn cue_audio_the_walk_found_needs_no_probe() {
        let root = tempfile::tempdir().unwrap();
        let library = fs::canonicalize(root.path()).unwrap().join("library");
        fs::create_dir_all(&library).unwrap();
        let backend = backend(root.path(), &library);
        let cue = library.join("album.cue").to_string_lossy().into_owned();
        let audio = library.join("album.flac").to_string_lossy().into_owned();
        let walked = BTreeSet::from([audio.as_str()]);

        assert_eq!(
            backend
                .resolve_cue_audio(&cue, "album.flac", "", Some(&walked), &|| Ok(()))
                .unwrap(),
            audio
        );
        assert!(
            backend
                .resolve_cue_audio(&cue, "album.flac", "", None, &|| Ok(()))
                .is_err()
        );
    }

    #[test]
    fn incremental_delta_matches_the_json_the_scan_always_returned() {
        let root = tempfile::tempdir().unwrap();
        let library = library_with_artwork(root.path(), 1, 3, 8_500);
        let backend = backend(root.path(), &library);
        let unchanged = library.join("0000/00.flac");
        let modified = fs::metadata(&unchanged)
            .unwrap()
            .modified()
            .unwrap()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_millis() as i64;
        let gone = library
            .join("0000/gone.flac")
            .to_string_lossy()
            .into_owned();
        let snapshots = [
            json!({unchanged.to_string_lossy(): modified, &gone: 5}),
            json!({}),
        ];
        for (snapshot, deleted, skipped) in [
            (&snapshots[0], json!([gone]), 1),
            (&snapshots[1], Value::Null, 0),
        ] {
            let result = backend
                .scan_library_folder_incremental(
                    &library.to_string_lossy(),
                    &snapshot.to_string(),
                    &|| Ok(()),
                )
                .unwrap();
            let tracks = result["scanned"].as_array().unwrap().clone();
            assert_eq!(tracks.len(), 3 - skipped);
            let previous = json!({"scanned":tracks,"deletedPaths":deleted,"skippedCount":skipped,"totalFiles":3});
            assert_eq!(result.to_string(), previous.to_string());
        }
    }

    #[test]
    #[ignore = "manual scan timing with many thumbnails"]
    fn scan_timing_with_many_thumbnails() {
        use std::os::unix::fs::MetadataExt;
        let setting = |name: &str, default: u32| {
            std::env::var(name).map_or(default, |value| value.parse().unwrap())
        };
        let albums = setting("MORNYE_BENCH_ALBUMS", 100);
        let tracks = setting("MORNYE_BENCH_TRACKS", 10);
        let root = tempfile::tempdir().unwrap();
        // The thumbnail cache is process-wide; fresh pictures keep runs apart.
        let seed = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .subsec_nanos();
        let library = library_with_artwork(root.path(), albums, tracks, seed);
        let backend = backend(root.path(), &library);
        let covers = root.path().join("data/library_covers");
        backend
            .set_library_cover_cache_directory(&covers.to_string_lossy())
            .unwrap();
        let output = root.path().join("data/scan.ndjson");

        let start = std::time::Instant::now();
        let count = backend
            .scan_library_folder_to_ndjson_file(
                &library.to_string_lossy(),
                &output.to_string_lossy(),
                &|| Ok(()),
            )
            .unwrap();
        let elapsed = start.elapsed();

        let (mut names, mut logical, mut stored) = (0, 0, 0);
        let mut inodes = BTreeSet::new();
        for entry in fs::read_dir(&covers).unwrap() {
            let metadata = entry.unwrap().metadata().unwrap();
            names += 1;
            logical += metadata.len();
            if inodes.insert(metadata.ino()) {
                stored += metadata.blocks() * 512;
            }
        }
        assert_eq!(count, u64::from(albums * tracks));
        eprintln!(
            "{count} songs, {albums} pictures: scan {:.2} s, {names} thumbnails of {} KB, {} files, {} MB named, {} MB on disk",
            elapsed.as_secs_f64(),
            (logical / names.max(1)) >> 10,
            inodes.len(),
            logical >> 20,
            stored >> 20,
        );
    }

    #[test]
    fn cancel_releases_a_paused_scan() {
        let root = tempfile::tempdir().unwrap();
        let (backend, folder) = paused_library(root.path());

        thread::scope(|scope| {
            let scan =
                scope.spawn(|| backend.scan_library_folder_incremental(&folder, "{}", &|| Ok(())));
            wait_for_run(&backend);
            backend.cancel_library_scan().unwrap();
            assert_eq!(scan.join().unwrap().unwrap_err(), "scan cancelled");
        });
        // Cancelling also clears the pause, so the next scan is not held.
        let result = backend
            .scan_library_folder_incremental(&folder, "{}", &|| Ok(()))
            .unwrap();
        assert_eq!(result["totalFiles"], 3);
    }
}
