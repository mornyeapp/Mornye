//! Read-only cache statistics. Counters are accumulated on the native worker
//! without retaining a list of files or following recursive link cycles.
use serde_json::{Value, json};
use std::{
    collections::HashSet,
    fs::{self, ReadDir},
    path::{Path, PathBuf},
};

#[derive(Default)]
struct Stats {
    files: u64,
    bytes: u64,
}

struct DirectoryFrame {
    entries: ReadDir,
    followed_link: Option<PathBuf>,
}

pub(crate) fn execute(
    request: &Value,
    check: &dyn Fn() -> Result<(), String>,
) -> Result<Value, String> {
    check()?;
    let path = Path::new(crate::data_jobs::string(request, "path")?);
    if !path.is_absolute() {
        return Err("Directory statistics require an absolute path".into());
    }
    let follow_links = request["follow_links"]
        .as_bool()
        .ok_or("Directory statistics require follow_links")?;
    let stats = scan(path, follow_links, check)?;
    Ok(json!({"file_count": stats.files, "total_size_bytes": stats.bytes}))
}

fn scan(
    path: &Path,
    follow_links: bool,
    check: &dyn Fn() -> Result<(), String>,
) -> Result<Stats, String> {
    let mut stats = Stats::default();
    // Directory.exists in the compatibility path follows a root link even
    // when links encountered inside the directory are excluded.
    if !path.is_dir() {
        return Ok(stats);
    }
    let Ok(entries) = fs::read_dir(path) else {
        return Ok(stats);
    };
    let mut followed_links = HashSet::new();
    let mut stack = vec![DirectoryFrame {
        entries,
        followed_link: None,
    }];
    while let Some(frame) = stack.last_mut() {
        check()?;
        let Some(entry) = frame.entries.next() else {
            if let Some(link) = stack.pop().and_then(|frame| frame.followed_link) {
                followed_links.remove(&link);
            }
            continue;
        };
        let Ok(entry) = entry else {
            return Ok(stats);
        };
        let Ok(file_type) = entry.file_type() else {
            return Ok(stats);
        };
        let path = entry.path();
        let metadata = if file_type.is_symlink() {
            if !follow_links {
                continue;
            }
            // Dangling links are listed as links by Dart, not regular files.
            let Ok(metadata) = fs::metadata(&path) else {
                continue;
            };
            Some(metadata)
        } else {
            None
        };
        let kind = metadata.as_ref().map_or(file_type, fs::Metadata::file_type);
        if kind.is_file() {
            stats.files = stats.files.checked_add(1).ok_or("File count overflow")?;
            check()?;
            // Keep the counted entry if it disappears before its size can be
            // read, matching the existing partial-result contract.
            let metadata = match metadata {
                Some(metadata) => metadata,
                None => match entry.metadata() {
                    Ok(metadata) => metadata,
                    Err(_) => return Ok(stats),
                },
            };
            stats.bytes = stats
                .bytes
                .checked_add(metadata.len())
                .ok_or("Directory size overflow")?;
        } else if kind.is_dir() {
            let followed_link = if file_type.is_symlink() {
                // Dart visits a link once per recursive descent. Tracking
                // target directories instead would undercount ordinary paths
                // reached through a link back to an ancestor.
                let (Some(parent), Some(name)) = (path.parent(), path.file_name()) else {
                    return Ok(stats);
                };
                let Ok(parent) = parent.canonicalize() else {
                    return Ok(stats);
                };
                let link = parent.join(name);
                if followed_links.contains(&link) {
                    continue;
                }
                Some(link)
            } else {
                None
            };
            let Ok(entries) = fs::read_dir(&path) else {
                return Ok(stats);
            };
            followed_links.extend(followed_link.iter().cloned());
            stack.push(DirectoryFrame {
                entries,
                followed_link,
            });
        }
    }
    Ok(stats)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::Cell;

    fn request(path: &Path, follow_links: bool) -> Value {
        json!({"path": path, "follow_links": follow_links})
    }

    #[test]
    fn counts_nested_unicode_files_including_empty_files() {
        let root = tempfile::tempdir().unwrap();
        fs::create_dir(root.path().join("nested")).unwrap();
        fs::write(root.path().join("first"), b"1234").unwrap();
        fs::write(root.path().join("nested/音楽"), b"123456").unwrap();
        fs::write(root.path().join("empty"), b"").unwrap();
        for follow in [false, true] {
            assert_eq!(
                execute(&request(root.path(), follow), &|| Ok(())).unwrap(),
                json!({"file_count": 3, "total_size_bytes": 10})
            );
        }
    }

    #[test]
    fn missing_directories_and_file_roots_have_zero_stats() {
        let root = tempfile::tempdir().unwrap();
        let file = root.path().join("file");
        fs::write(&file, b"123").unwrap();
        for path in [root.path().join("missing"), file] {
            assert_eq!(
                execute(&request(&path, false), &|| Ok(())).unwrap(),
                json!({"file_count": 0, "total_size_bytes": 0})
            );
        }
    }

    #[test]
    fn malformed_requests_and_cancellation_are_not_partial_successes() {
        assert!(
            execute(&json!({"path": "relative", "follow_links": false}), &|| Ok(
                ()
            ))
            .is_err()
        );
        assert!(execute(&json!({"path": "/tmp"}), &|| Ok(())).is_err());
        let root = tempfile::tempdir().unwrap();
        fs::write(root.path().join("file"), b"123").unwrap();
        let calls = Cell::new(0);
        let result = execute(&request(root.path(), false), &|| {
            calls.set(calls.get() + 1);
            if calls.get() > 2 {
                Err("cancelled".into())
            } else {
                Ok(())
            }
        });
        assert_eq!(result.unwrap_err(), "cancelled");
        assert!(root.path().join("file").exists());
    }

    #[cfg(unix)]
    #[test]
    fn a_file_removed_before_size_lookup_preserves_partial_counts() {
        let root = tempfile::tempdir().unwrap();
        let file = root.path().join("removed");
        fs::write(&file, b"123").unwrap();
        let calls = Cell::new(0);
        let result = execute(&request(root.path(), false), &|| {
            calls.set(calls.get() + 1);
            if calls.get() == 3 {
                fs::remove_file(&file).unwrap();
            }
            Ok(())
        });
        assert_eq!(
            result.unwrap(),
            json!({"file_count": 1, "total_size_bytes": 0})
        );
    }

    #[cfg(unix)]
    #[test]
    fn links_follow_requested_policy_and_cycles_do_not_hide_aliases() {
        use std::os::unix::fs::symlink;
        let root = tempfile::tempdir().unwrap();
        fs::create_dir(root.path().join("nested")).unwrap();
        fs::write(root.path().join("nested/file"), b"123").unwrap();
        symlink("nested/file", root.path().join("file_link")).unwrap();
        symlink("nested", root.path().join("directory_link")).unwrap();
        symlink("..", root.path().join("nested/cycle")).unwrap();
        symlink("missing", root.path().join("dangling")).unwrap();
        assert_eq!(
            execute(&request(root.path(), false), &|| Ok(())).unwrap(),
            json!({"file_count": 1, "total_size_bytes": 3})
        );
        assert_eq!(
            execute(&request(root.path(), true), &|| Ok(())).unwrap(),
            json!({"file_count": 8, "total_size_bytes": 24})
        );
        let alias = root.path().with_extension("alias");
        symlink(root.path(), &alias).unwrap();
        let actual = execute(&request(&alias, false), &|| Ok(()));
        fs::remove_file(alias).unwrap();
        assert_eq!(
            actual.unwrap(),
            json!({"file_count": 1, "total_size_bytes": 3})
        );
    }
}
