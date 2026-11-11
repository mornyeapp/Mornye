//! Library folder watching for desktop (DESIGN 6.2): `notify` watches the
//! configured library folders recursively and reports changed roots as the
//! inbound call `libraryFolderChanged {"root": "<watched path>"}`. Rust only
//! throttles per root; Dart debounces and runs the existing incremental scan.

use notify::event::ModifyKind;
use notify::{Event, EventKind, RecommendedWatcher, RecursiveMode, Watcher};
use serde_json::json;
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

/// At most one report per root in this window; Dart's debounce is longer.
const THROTTLE: Duration = Duration::from_millis(500);

type Emitter = Arc<dyn Fn(&str) + Send + Sync>;

pub(crate) struct LibraryWatcher {
    emit: Emitter,
    active: Mutex<Option<RecommendedWatcher>>,
}

impl Default for LibraryWatcher {
    fn default() -> Self {
        Self::new(Arc::new(|root| {
            crate::runtime::inbound("libraryFolderChanged", json!({"root": root}));
        }))
    }
}

/// A watched root: the path Dart passed, and its canonical form, because
/// FSEvents reports resolved paths (`/private/var` for `/var`).
struct Root {
    original: String,
    paths: Vec<PathBuf>,
}

impl LibraryWatcher {
    pub(crate) fn new(emit: Emitter) -> Self {
        Self {
            emit,
            active: Mutex::new(None),
        }
    }

    /// Replaces the watched set. Returns the roots that are being watched;
    /// missing or unreadable folders are skipped.
    pub(crate) fn watch(&self, folders: &[String]) -> Result<Vec<String>, String> {
        let mut active = self.active.lock().expect("watcher lock");
        // Drop the old watcher first so its thread stops reporting.
        active.take();
        let roots: Vec<Root> = folders
            .iter()
            .filter(|folder| !folder.trim().is_empty() && Path::new(folder).is_dir())
            .map(|folder| {
                let mut paths = vec![PathBuf::from(folder)];
                if let Ok(canonical) = std::fs::canonicalize(folder)
                    && canonical != paths[0]
                {
                    paths.push(canonical);
                }
                Root {
                    original: folder.clone(),
                    paths,
                }
            })
            .collect();
        if roots.is_empty() {
            return Ok(Vec::new());
        }
        let roots = Arc::new(roots);
        let emit = Arc::clone(&self.emit);
        let handler_roots = Arc::clone(&roots);
        let mut last: HashMap<usize, Instant> = HashMap::new();
        let mut watcher = notify::recommended_watcher(move |event: notify::Result<Event>| {
            let Ok(event) = event else { return };
            if !is_content_change(&event.kind) {
                return;
            }
            for path in event.paths.iter().filter(|path| !is_ignored(path)) {
                let Some(index) = handler_roots
                    .iter()
                    .position(|root| root.paths.iter().any(|base| path.starts_with(base)))
                else {
                    continue;
                };
                let now = Instant::now();
                if last
                    .get(&index)
                    .is_some_and(|previous| now.duration_since(*previous) < THROTTLE)
                {
                    continue;
                }
                last.insert(index, now);
                emit(&handler_roots[index].original);
            }
        })
        .map_err(|error| error.to_string())?;
        let mut watched = Vec::new();
        for root in roots.iter() {
            match watcher.watch(&root.paths[0], RecursiveMode::Recursive) {
                Ok(()) => watched.push(root.original.clone()),
                Err(error) => {
                    crate::runtime::log("warn", &format!("Cannot watch library folder: {error}"))
                }
            }
        }
        *active = Some(watcher);
        Ok(watched)
    }

    pub(crate) fn stop(&self) {
        self.active.lock().expect("watcher lock").take();
    }
}

fn is_content_change(kind: &EventKind) -> bool {
    match kind {
        EventKind::Create(_) | EventKind::Remove(_) | EventKind::Any => true,
        EventKind::Modify(modify) => !matches!(modify, ModifyKind::Metadata(_)),
        EventKind::Access(_) | EventKind::Other => false,
    }
}

/// Hidden files (`.DS_Store`, editor swap files) and partial downloads,
/// including FFmpeg stages that keep their format after `.partial`.
pub(crate) fn is_ignored(path: &Path) -> bool {
    let Some(name) = path.file_name().and_then(|name| name.to_str()) else {
        return false;
    };
    let lower = name.to_ascii_lowercase();
    name.starts_with('.')
        || name.ends_with('~')
        || [".part", ".tmp", ".crdownload", ".partial"]
            .iter()
            .any(|suffix| lower.ends_with(suffix))
        || lower
            .rsplit_once('.')
            .is_some_and(|(stem, _)| stem.ends_with(".partial"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::mpsc;

    #[test]
    fn ignores_hidden_and_partial_files() {
        assert!(is_ignored(Path::new("/m/.DS_Store")));
        assert!(is_ignored(Path::new("/m/a.flac.part")));
        assert!(is_ignored(Path::new("/m/a.TMP")));
        assert!(is_ignored(Path::new("/m/mornye-00ff.partial")));
        assert!(is_ignored(Path::new("/m/a.mornye-1.partial.flac")));
        assert!(!is_ignored(Path::new("/m/a.flac")));
        assert!(!is_ignored(Path::new("/m/partial.flac")));
        assert!(!is_content_change(&EventKind::Access(
            notify::event::AccessKind::Any
        )));
        assert!(is_content_change(&EventKind::Create(
            notify::event::CreateKind::File
        )));
    }

    #[test]
    fn reports_the_changed_root() {
        let directory = tempfile::tempdir().unwrap();
        let root = directory.path().join("music");
        let other = directory.path().join("missing");
        std::fs::create_dir_all(root.join("album")).unwrap();
        let (sender, receiver) = mpsc::channel::<String>();
        let sender = Mutex::new(sender);
        let watcher = LibraryWatcher::new(Arc::new(move |root| {
            let _ = sender.lock().unwrap().send(root.to_owned());
        }));
        let root_text = root.to_string_lossy().into_owned();
        let watched = watcher
            .watch(&[root_text.clone(), other.to_string_lossy().into_owned()])
            .unwrap();
        assert_eq!(watched, vec![root_text.clone()]);
        // FSEvents may deliver events from before the watch started; drain
        // them and wait out their throttle window.
        std::thread::sleep(Duration::from_millis(300));
        while receiver.try_recv().is_ok() {}
        std::thread::sleep(THROTTLE + Duration::from_millis(100));
        std::fs::write(root.join("album").join("track.flac"), b"x").unwrap();
        let reported = receiver.recv_timeout(Duration::from_secs(10)).unwrap();
        assert_eq!(reported, root_text);
        watcher.stop();
    }
}
