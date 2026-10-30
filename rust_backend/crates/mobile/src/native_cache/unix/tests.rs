use super::*;
use std::{cell::Cell, fs::File, os::unix::fs::symlink};
use tempfile::TempDir;

fn old_file(root: &Path, name: &str, size: usize, age: Duration) -> PathBuf {
    let path = root.join(name);
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    fs::write(&path, vec![0; size]).unwrap();
    File::options()
        .write(true)
        .open(&path)
        .unwrap()
        .set_times(fs::FileTimes::new().set_modified(SystemTime::now() - age))
        .unwrap();
    path
}

fn trim_request(root: &Path) -> Value {
    json!({
        "operation": "cache_trim_budget", "directory": root,
        "max_bytes": 250, "target_bytes": 150, "minimum_age_ms": 60_000,
    })
}

fn prune_request(root: &Path, references: &[PathBuf]) -> Value {
    json!({
        "operation": "cache_prune_library", "directory": root,
        "referenced_paths": references, "minimum_age_ms": 0,
    })
}

#[test]
fn trims_oldest_payloads_but_keeps_metadata_links_and_recent_writes() {
    let fixture = TempDir::new().unwrap();
    let root = fixture.path().join("covers");
    fs::create_dir(&root).unwrap();
    let oldest = old_file(&root, "old", 100, Duration::from_secs(3600));
    let newer = old_file(&root, "nested/newer", 100, Duration::from_secs(600));
    let recent = old_file(&root, "active", 100, Duration::ZERO);
    let metadata = old_file(&root, "cache.json", 1000, Duration::from_secs(7200));
    let outside = old_file(fixture.path(), "outside", 1000, Duration::from_secs(7200));
    symlink(&outside, root.join("outside-link")).unwrap();
    symlink(fixture.path(), root.join("directory-link")).unwrap();
    let mut request = trim_request(&root);
    request["max_bytes"] = json!(350);
    assert_eq!(execute(&request, &|| Ok(())).unwrap()["deleted"], 0);
    request["max_bytes"] = json!(250);
    assert_eq!(execute(&request, &|| Ok(())).unwrap()["deleted"], 2);
    assert!(!oldest.exists() && !newer.exists());
    assert!(recent.exists() && metadata.exists() && outside.exists());
    assert!(
        fs::symlink_metadata(root.join("outside-link"))
            .unwrap()
            .is_symlink()
    );
}

#[test]
fn keeps_references_through_root_aliases_and_linked_reference_paths() {
    let fixture = TempDir::new().unwrap();
    let root = fixture.path().join("covers");
    fs::create_dir(&root).unwrap();
    let alias = fixture.path().join("alias");
    symlink(&root, &alias).unwrap();
    let canonical = old_file(&root, "canonical.jpg", 1, Duration::from_secs(600));
    let legacy = old_file(&root, "legacy.jpg", 1, Duration::from_secs(600));
    let linked = old_file(&root, "linked.jpg", 1, Duration::from_secs(600));
    let orphan = old_file(&root, "orphan.jpg", 1, Duration::from_secs(600));
    let reference_link = fixture.path().join("reference-link");
    symlink(&linked, &reference_link).unwrap();
    let result = execute(
        &prune_request(
            &alias,
            &[
                fs::canonicalize(&canonical).unwrap(),
                alias.join("legacy.jpg"),
                reference_link,
                alias.join("already-missing.jpg"),
            ],
        ),
        &|| Ok(()),
    )
    .unwrap();
    assert_eq!(result["deleted"], 1);
    assert!(canonical.exists() && legacy.exists() && linked.exists());
    assert!(!orphan.exists());
}

#[test]
fn preserves_changed_payloads_between_listing_and_eviction() {
    let fixture = TempDir::new().unwrap();
    old_file(fixture.path(), "modified", 10, Duration::from_secs(600));
    let replaced = old_file(fixture.path(), "replaced", 10, Duration::from_secs(600));
    let linked = old_file(fixture.path(), "linked", 10, Duration::from_secs(600));
    let outside_fixture = TempDir::new().unwrap();
    let outside = old_file(
        outside_fixture.path(),
        "outside",
        10,
        Duration::from_secs(600),
    );
    let root = root(fixture.path().to_str().unwrap()).unwrap().unwrap();
    let entries = collect(&root, false, &|| Ok(())).unwrap();
    fs::write(fixture.path().join("modified"), b"new bytes").unwrap();
    fs::rename(&replaced, fixture.path().join("previous")).unwrap();
    fs::write(&replaced, b"replacement").unwrap();
    fs::remove_file(&linked).unwrap();
    symlink(&outside, &linked).unwrap();
    for entry in entries {
        assert!(!remove(&entry).unwrap());
    }
    assert_eq!(fs::read(&outside).unwrap().len(), 10);
    assert_eq!(fs::read(&replaced).unwrap(), b"replacement");
}

#[test]
fn directory_replacement_never_redirects_deletion_outside_cache() {
    let fixture = TempDir::new().unwrap();
    let outside_fixture = TempDir::new().unwrap();
    let child = fixture.path().join("child");
    fs::create_dir(&child).unwrap();
    old_file(&child, "cover", 1, Duration::from_secs(600));
    let outside = old_file(outside_fixture.path(), "cover", 1, Duration::from_secs(600));
    let root = root(fixture.path().to_str().unwrap()).unwrap().unwrap();
    let entries = collect(&root, false, &|| Ok(())).unwrap();
    fs::rename(&child, fixture.path().join("previous-child")).unwrap();
    symlink(outside_fixture.path(), &child).unwrap();
    assert!(remove(&entries[0]).unwrap());
    assert!(outside.exists());
}

#[test]
fn cancellation_never_deletes_before_complete_reference_lookup_and_listing() {
    let fixture = TempDir::new().unwrap();
    old_file(fixture.path(), "orphan", 1, Duration::from_secs(600));
    let checks = Cell::new(0);
    let result = execute(&prune_request(fixture.path(), &[]), &|| {
        checks.set(checks.get() + 1);
        if checks.get() >= 3 {
            Err("cancelled".into())
        } else {
            Ok(())
        }
    });
    assert!(result.is_err());
    assert!(fixture.path().join("orphan").exists());
}

#[test]
fn cancellation_after_eviction_reports_partial_committed_result() {
    let fixture = TempDir::new().unwrap();
    for i in 0..4 {
        old_file(
            fixture.path(),
            &format!("orphan{i}"),
            1,
            Duration::from_secs(600),
        );
    }
    let result = execute(&prune_request(fixture.path(), &[]), &|| {
        if fs::read_dir(fixture.path()).unwrap().count() < 4 {
            Err("cancelled".into())
        } else {
            Ok(())
        }
    })
    .unwrap();
    assert_eq!(result["deleted"], 1);
    assert_eq!(result["cancelled"], true);
    assert_eq!(result["committed"], true);
    assert_eq!(fs::read_dir(fixture.path()).unwrap().count(), 3);
}

#[test]
fn invalid_budget_paths_and_schema_fail_before_any_deletion() {
    let fixture = TempDir::new().unwrap();
    let payload = old_file(fixture.path(), "cover", 100, Duration::from_secs(600));
    let mut request = trim_request(fixture.path());
    request["target_bytes"] = json!(251);
    assert!(execute(&request, &|| Ok(())).is_err());
    request["directory"] = json!("relative");
    assert!(execute(&request, &|| Ok(())).is_err());
    let db = fixture.path().join("local_library.db");
    Connection::open(&db)
        .unwrap()
        .execute_batch("PRAGMA user_version=16")
        .unwrap();
    request = prune_request(fixture.path(), &[]);
    request["library_path"] = json!(db);
    assert!(execute(&request, &|| Ok(())).is_err());
    assert!(payload.exists());
    request["library_path"] = json!(fixture.path().join("missing/local_library.db"));
    assert!(execute(&request, &|| Ok(())).is_err());
    assert!(!fixture.path().join("missing/local_library.db").exists());
}

#[test]
fn missing_directory_is_empty_and_recent_unreferenced_covers_survive() {
    let fixture = TempDir::new().unwrap();
    assert_eq!(
        execute(&trim_request(&fixture.path().join("missing")), &|| Ok(())).unwrap()["deleted"],
        0
    );
    let active = old_file(fixture.path(), "active", 1, Duration::ZERO);
    let old = old_file(fixture.path(), "old", 1, Duration::from_secs(600));
    let mut request = prune_request(fixture.path(), &[]);
    request["minimum_age_ms"] = json!(60_000);
    assert_eq!(execute(&request, &|| Ok(())).unwrap()["deleted"], 1);
    assert!(active.exists());
    assert!(!old.exists());
}

#[test]
fn hard_linked_covers_lose_only_their_own_name() {
    let fixture = TempDir::new().unwrap();
    let first = old_file(fixture.path(), "first.jpg", 3, Duration::from_secs(600));
    let second = fixture.path().join("second.jpg");
    fs::hard_link(&first, &second).unwrap();
    // The new name keeps the inode's old mtime; linking it updated the ctime.
    let mut request = prune_request(fixture.path(), &[]);
    request["minimum_age_ms"] = json!(60_000);
    assert_eq!(execute(&request, &|| Ok(())).unwrap()["deleted"], 0);
    assert!(first.exists() && second.exists());

    let request = prune_request(fixture.path(), std::slice::from_ref(&second));
    assert_eq!(execute(&request, &|| Ok(())).unwrap()["deleted"], 1);
    assert!(!first.exists());
    assert_eq!(fs::read(&second).unwrap(), vec![0; 3]);
}

#[test]
fn a_referenced_subsonic_cover_keeps_the_pointer_to_its_refreshed_file() {
    let fixture = TempDir::new().unwrap();
    let (kept, gone) = ("a".repeat(64), "b".repeat(64));
    let age = Duration::from_secs(600);
    let refreshed = old_file(
        fixture.path(),
        &format!("subsonic_{kept}_{}.image", "c".repeat(48)),
        1,
        age,
    );
    let pointer = old_file(
        fixture.path(),
        &format!("subsonic_{kept}.image.current"),
        1,
        age,
    );
    let etag = old_file(
        fixture.path(),
        &format!("subsonic_{kept}_{}.image.etag", "c".repeat(48)),
        1,
        age,
    );
    let replaced = old_file(fixture.path(), &format!("subsonic_{kept}.image"), 1, age);
    let replaced_etag = old_file(
        fixture.path(),
        &format!("subsonic_{kept}.image.etag"),
        1,
        age,
    );
    let orphan = old_file(
        fixture.path(),
        &format!("subsonic_{gone}.image.current"),
        1,
        age,
    );
    let result = execute(
        &prune_request(fixture.path(), std::slice::from_ref(&refreshed)),
        &|| Ok(()),
    )
    .unwrap();
    assert_eq!(result["deleted"], 3);
    assert!(refreshed.exists() && pointer.exists() && etag.exists());
    assert!(!replaced.exists() && !replaced_etag.exists() && !orphan.exists());
}

#[test]
fn database_retains_all_sources_and_blocks_concurrent_reference_writers() {
    let fixture = TempDir::new().unwrap();
    let root = fixture.path().join("covers");
    fs::create_dir(&root).unwrap();
    let retained = old_file(&root, "disabled-source", 1, Duration::from_secs(600));
    let orphan = old_file(&root, "orphan", 1, Duration::from_secs(600));
    let db_path = fixture.path().join("local_library.db");
    let db = Connection::open(&db_path).unwrap();
    db.execute_batch("PRAGMA user_version=17; PRAGMA journal_mode=WAL; CREATE TABLE library(id TEXT PRIMARY KEY, source_id TEXT, cover_path TEXT); CREATE TABLE library_sources(id TEXT PRIMARY KEY, enabled INTEGER); INSERT INTO library_sources VALUES('disabled',0);").unwrap();
    db.execute(
        "INSERT INTO library VALUES('existing','disabled',?)",
        [retained.to_str().unwrap()],
    )
    .unwrap();
    db.busy_timeout(Duration::ZERO).unwrap();
    let blocked = Cell::new(0);
    let mut request = prune_request(&root, &[]);
    request["library_path"] = json!(db_path);
    let result = execute(&request, &|| {
        if let Err(error) = db.execute("UPDATE library SET source_id=source_id", []) {
            assert!(matches!(error, rusqlite::Error::SqliteFailure(ref error, _) if error.code == rusqlite::ErrorCode::DatabaseBusy));
            blocked.set(blocked.get() + 1);
        }
        Ok(())
    }).unwrap();
    assert!(blocked.get() > 0);
    assert_eq!(result["deleted"], 1);
    assert!(retained.exists());
    assert!(!orphan.exists());
    db.execute("UPDATE library SET source_id=source_id", [])
        .unwrap();
    assert_eq!(
        db.query_row("SELECT count(*) FROM library", [], |row| row
            .get::<_, i64>(0))
            .unwrap(),
        1
    );
}

#[test]
#[ignore = "manual realistic native cache worker timing"]
fn benchmark_5000_payloads() {
    let fixture = TempDir::new().unwrap();
    for i in 0..5000 {
        old_file(
            fixture.path(),
            &format!("cover{i}"),
            1024,
            Duration::from_secs(600),
        );
    }
    let retained: Vec<_> = (0..4000)
        .map(|i| fixture.path().join(format!("cover{i}")))
        .collect();
    let started = std::time::Instant::now();
    let result = execute(&prune_request(fixture.path(), &retained), &|| Ok(())).unwrap();
    println!(
        "native_prune_5000_ms={:.3} deleted={}",
        started.elapsed().as_secs_f64() * 1000.0,
        result["deleted"]
    );
    assert_eq!(result["deleted"], 1000);
    assert!(retained.iter().all(|path| path.exists()));
}
