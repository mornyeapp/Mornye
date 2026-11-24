use super::{ExtensionManager, RuntimeLimits};
use crate::runtime::source_compiles;
use crate::storage::{StorageMasterKey, encrypt};
use mornye_core::cancellation::{CancellationDomain, CancellationRegistry};
use serde_json::{Value, json};
use std::fs::File;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::Ordering;
use std::time::{Duration, Instant};

fn manager(directory: &Path) -> ExtensionManager {
    ExtensionManager::new(
        &directory.join("sources"),
        &directory.join("data"),
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
        "1",
        RuntimeLimits::default(),
    )
    .unwrap()
}

fn package(directory: &Path, id: &str, version: &str, source: &str) -> PathBuf {
    let path = directory.join(format!("{id}-{version}.mornye-ext"));
    let mut writer = zip::ZipWriter::new(File::create(&path).unwrap());
    let manifest = json!({"name":id,"displayName":"Example","version":version,
        "description":"Generic installation fixture","type":["metadata_provider"]});
    for (name, body) in [
        ("manifest.json", manifest.to_string()),
        ("index.js", source.into()),
    ] {
        writer
            .start_file(name, zip::write::SimpleFileOptions::default())
            .unwrap();
        writer.write_all(body.as_bytes()).unwrap();
    }
    writer.finish().unwrap();
    path
}

#[test]
fn new_installations_are_usable_and_remain_enabled_after_restart() {
    let directory = tempfile::tempdir().unwrap();
    let archive = package(
        directory.path(),
        "example.install",
        "1",
        "registerExtension({ping(){return 'ready';}});",
    );
    let installed = manager(directory.path());
    let result: Value = serde_json::from_str(&installed.install(&archive).unwrap()).unwrap();
    assert_eq!(result["enabled"], true);
    assert_eq!(
        installed.provider_ids("metadata_provider").unwrap(),
        ["example.install"]
    );
    assert_eq!(
        installed
            .call("example.install", "ping", "[]", None, 0)
            .unwrap(),
        "\"ready\""
    );
    installed.shutdown();

    let reopened = manager(directory.path());
    reopened.load_all().unwrap();
    assert_eq!(
        reopened.provider_ids("metadata_provider").unwrap(),
        ["example.install"]
    );
    assert_eq!(
        reopened
            .call("example.install", "ping", "[]", None, 0)
            .unwrap(),
        "\"ready\""
    );
}

#[test]
fn upgrades_preserve_enabled_and_disabled_choices_after_restart() {
    for enabled in [true, false] {
        for use_install in [true, false] {
            let directory = tempfile::tempdir().unwrap();
            let installed = manager(directory.path());
            let archive = package(
                directory.path(),
                "example.upgrade",
                "1",
                "registerExtension({});",
            );
            installed.install(&archive).unwrap();
            installed.set_enabled("example.upgrade", enabled).unwrap();
            let upgrade = package(
                directory.path(),
                "example.upgrade",
                "2",
                "registerExtension({});",
            );
            let result = if use_install {
                installed.install(&upgrade)
            } else {
                installed.upgrade(&upgrade)
            };
            let result: Value = serde_json::from_str(&result.unwrap()).unwrap();
            assert_eq!(result["version"], "2");
            assert_eq!(result["enabled"], enabled);
            installed.shutdown();

            let reopened = manager(directory.path());
            reopened.load_all().unwrap();
            let entries: Value = serde_json::from_str(&reopened.installed().unwrap()).unwrap();
            assert_eq!(entries[0]["version"], "2");
            assert_eq!(entries[0]["enabled"], enabled);
        }
    }
}

#[test]
fn invalid_installations_remain_disabled_after_restart() {
    let directory = tempfile::tempdir().unwrap();
    let archive = package(
        directory.path(),
        "example.invalid",
        "1",
        "throw Error('invalid fixture');",
    );
    let installed = manager(directory.path());
    let result: Value = serde_json::from_str(&installed.install(&archive).unwrap()).unwrap();
    assert_eq!(result["enabled"], false);
    assert!(
        installed
            .provider_ids("metadata_provider")
            .unwrap()
            .is_empty()
    );
    installed.shutdown();

    let reopened = manager(directory.path());
    reopened.load_all().unwrap();
    let entries: Value = serde_json::from_str(&reopened.installed().unwrap()).unwrap();
    assert_eq!(entries[0]["enabled"], false);
    assert_eq!(entries[0]["status"], "error");
    assert!(
        entries[0]["error_message"]
            .as_str()
            .unwrap()
            .contains("invalid fixture")
    );
}

#[test]
fn unreadable_settings_keep_installed_packages_visible_and_preserve_data() {
    let directory = tempfile::tempdir().unwrap();
    let sources = directory.path().join("sources");
    let data = directory.path().join("data");
    let original_key = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
    let other_key = "AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE=";
    let key = StorageMasterKey::from_base64(original_key).unwrap();
    let ids = ["example.first", "example.second"];
    let mut snapshots = Vec::new();
    for id in ids {
        let source = sources.join(id);
        let private = data.join(id);
        std::fs::create_dir_all(&source).unwrap();
        std::fs::create_dir_all(&private).unwrap();
        std::fs::write(
            source.join("manifest.json"),
            json!({"name":id,"displayName":"Example","version":"1","description":"Storage recovery fixture","type":["metadata_provider"]}).to_string(),
        ).unwrap();
        // Even validation must not execute while private storage is broken.
        std::fs::write(source.join("index.js"), "throw Error('must not run');").unwrap();
        let settings = encrypt(
            br#"{"_enabled":true,"region":"example"}"#,
            &key.derive(id, "settings"),
        )
        .unwrap();
        let credentials = encrypt(
            br#"{"token":"example-secret"}"#,
            &key.derive(id, "credentials"),
        )
        .unwrap();
        std::fs::write(private.join("settings.enc"), &settings).unwrap();
        std::fs::write(private.join(".credentials.enc"), &credentials).unwrap();
        snapshots.push((private, settings, credentials));
    }
    let manager =
        ExtensionManager::new(&sources, &data, other_key, "1", RuntimeLimits::default()).unwrap();
    let loaded: Value = serde_json::from_str(&manager.load_all().unwrap()).unwrap();
    assert_eq!(loaded["loaded"], json!(ids));
    let installed: Value = serde_json::from_str(&manager.installed().unwrap()).unwrap();
    assert_eq!(installed.as_array().unwrap().len(), 2);
    for entry in installed.as_array().unwrap() {
        assert_eq!(entry["enabled"], false);
        assert_eq!(entry["status"], "error");
        assert_eq!(
            entry["error_message"],
            "cipher: message authentication failed"
        );
        assert!(
            manager
                .get(entry["id"].as_str().unwrap())
                .unwrap()
                .engine
                .lock()
                .unwrap()
                .runtime
                .is_none()
        );
    }
    for (private, settings, credentials) in &snapshots {
        assert_eq!(
            std::fs::read(private.join("settings.enc")).unwrap(),
            *settings
        );
        assert_eq!(
            std::fs::read(private.join(".credentials.enc")).unwrap(),
            *credentials
        );
        assert!(!private.join(".cred_salt").exists());
    }
    manager.shutdown();

    // Restoring the correct key makes the existing settings readable again.
    for id in ids {
        std::fs::write(sources.join(id).join("index.js"), "registerExtension({});").unwrap();
    }
    let recovered =
        ExtensionManager::new(&sources, &data, original_key, "1", RuntimeLimits::default())
            .unwrap();
    recovered.load_all().unwrap();
    let installed: Value = serde_json::from_str(&recovered.installed().unwrap()).unwrap();
    for entry in installed.as_array().unwrap() {
        assert_eq!(entry["enabled"], true);
        assert_eq!(entry["status"], "loaded");
        assert_eq!(
            recovered
                .environment
                .settings(entry["id"].as_str().unwrap())
                .unwrap()["region"],
            "example"
        );
    }
}

#[test]
fn manager_and_isolated_vm_share_one_retained_source_allocation() {
    let directory = tempfile::tempdir().unwrap();
    let sources = directory.path().join("sources");
    let source_dir = sources.join("example.memory");
    std::fs::create_dir_all(&source_dir).unwrap();
    let manifest = r#"{"name":"example.memory","displayName":"Example Memory","version":"1","description":"Generic memory fixture","type":["metadata_provider"]}"#;
    std::fs::write(source_dir.join("manifest.json"), manifest).unwrap();
    let source = format!(
        "/*{}*/let calls=0;registerExtension({{next(){{return ++calls;}}}});",
        "x".repeat(4 * 1024 * 1024)
    );
    let source_bytes = source.len();
    std::fs::write(source_dir.join("index.js"), &source).unwrap();
    drop(source);
    let manager = ExtensionManager::new(
        &sources,
        &directory.path().join("data"),
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
        "1",
        RuntimeLimits::default(),
    )
    .unwrap();
    manager.load_all().unwrap();
    manager.set_enabled("example.memory", true).unwrap();
    let entry = manager.get("example.memory").unwrap();
    let mut engine = entry.engine.lock().unwrap();
    let primary = manager.ready(&entry, &mut engine, true).unwrap();
    let retained = engine.source.as_ref().unwrap();
    assert!(Arc::ptr_eq(retained, &primary.shared_source()));
    let isolated = manager
        .environment
        .load_isolated(manifest, retained, RuntimeLimits::default(), &primary)
        .unwrap();
    assert!(Arc::ptr_eq(retained, &isolated.shared_source()));
    assert_eq!(retained.len(), source_bytes);
    drop(engine);
    assert_eq!(primary.call("next", "[]", None, 0).unwrap(), "1");
    assert_eq!(isolated.call("next", "[]", None, 0).unwrap(), "1");
    isolated.shutdown();
    assert_eq!(primary.call("next", "[]", None, 0).unwrap(), "2");
    eprintln!(
        "retained source text: baseline_bytes={} shared_bytes={} saved_bytes={source_bytes}; primary/isolated JS state remains separate",
        source_bytes * 2,
        source_bytes
    );
    manager.shutdown();
}

fn cancelled_call(manager: &ExtensionManager, id: &str) {
    let registry = CancellationRegistry::new(CancellationDomain::ExtensionRequest);
    let lease = Arc::new(registry.acquire("").unwrap());
    std::thread::scope(|scope| {
        let call = scope.spawn(|| manager.call(id, "spin", "[]", Some(Arc::clone(&lease)), 10_000));
        std::thread::sleep(Duration::from_millis(50));
        lease.release();
        assert!(call.join().unwrap().is_err());
    });
}

#[test]
fn reloads_after_cancelled_calls_reuse_the_validated_compile() {
    let directory = tempfile::tempdir().unwrap();
    let source = "/*example.reload*/let calls=0;registerExtension({next(){return ++calls;},spin(){while(true){}}});";
    let archive = package(directory.path(), "example.reload", "1", source);
    let installed = manager(directory.path());
    installed.install(&archive).unwrap();
    assert_eq!(source_compiles(source), 1);
    for _ in 0..2 {
        assert_eq!(
            installed
                .call("example.reload", "next", "[]", None, 0)
                .unwrap(),
            "1"
        );
        cancelled_call(&installed, "example.reload");
    }
    // Each reload starts a new VM: script state restarts, the compile does not.
    assert_eq!(
        installed
            .call("example.reload", "next", "[]", None, 0)
            .unwrap(),
        "1"
    );
    assert_eq!(source_compiles(source), 1);

    // A changed index.js is compiled again instead of running stale bytecode.
    let changed = "/*example.reload changed*/registerExtension({next(){return 'changed';},spin(){while(true){}}});";
    let entry = installed.get("example.reload").unwrap();
    std::fs::write(entry.source.join("index.js"), changed).unwrap();
    cancelled_call(&installed, "example.reload");
    assert_eq!(
        installed
            .call("example.reload", "next", "[]", None, 0)
            .unwrap(),
        "\"changed\""
    );
    assert_eq!(source_compiles(changed), 1);
    installed.shutdown();
}

#[test]
fn startup_validation_compile_serves_the_first_call() {
    let directory = tempfile::tempdir().unwrap();
    let enabled = "/*example.startup*/registerExtension({ping(){return 'enabled';}});";
    let disabled = "/*example.later*/registerExtension({ping(){return 'later';}});";
    let installed = manager(directory.path());
    for (id, source) in [("example.startup", enabled), ("example.later", disabled)] {
        installed
            .install(&package(directory.path(), id, "1", source))
            .unwrap();
    }
    installed.set_enabled("example.later", false).unwrap();
    installed.shutdown();
    let compiled = (source_compiles(enabled), source_compiles(disabled));

    let reopened = manager(directory.path());
    reopened.load_all().unwrap();
    assert_eq!(
        reopened
            .call("example.startup", "ping", "[]", None, 0)
            .unwrap(),
        "\"enabled\""
    );
    assert_eq!(source_compiles(enabled), compiled.0 + 1);
    // Disabled packages are still validated at start; enabling one later
    // compiles it for its new VM.
    assert_eq!(source_compiles(disabled), compiled.1 + 1);
    reopened.set_enabled("example.later", true).unwrap();
    assert_eq!(
        reopened
            .call("example.later", "ping", "[]", None, 0)
            .unwrap(),
        "\"later\""
    );
    reopened.shutdown();
}

#[test]
fn upgrades_never_reuse_the_previous_compile() {
    let directory = tempfile::tempdir().unwrap();
    let first = "/*example.version*/registerExtension({ping(){return 1;}});";
    let second = "/*example.version*/registerExtension({ping(){return 2;}});";
    let installed = manager(directory.path());
    installed
        .install(&package(directory.path(), "example.version", "1", first))
        .unwrap();
    assert_eq!(
        installed
            .call("example.version", "ping", "[]", None, 0)
            .unwrap(),
        "1"
    );
    installed
        .upgrade(&package(directory.path(), "example.version", "2", second))
        .unwrap();
    assert_eq!(
        installed
            .call("example.version", "ping", "[]", None, 0)
            .unwrap(),
        "2"
    );
    assert_eq!(source_compiles(second), 1);
    installed.shutdown();
}

#[test]
fn busy_engine_waiters_wake_on_release_or_cancel_without_polling() {
    let directory = tempfile::tempdir().unwrap();
    let installed = manager(directory.path());
    let archive = package(
        directory.path(),
        "example.busy",
        "1",
        "registerExtension({});",
    );
    installed.install(&archive).unwrap();
    let entry = installed.get("example.busy").unwrap();
    let registry = CancellationRegistry::new(CancellationDomain::ExtensionRequest);
    for cancel in [false, true] {
        let lease = Arc::new(registry.acquire("").unwrap());
        let held = entry.engine.lock().unwrap();
        let attempts = entry.engine.attempts.load(Ordering::Relaxed);
        std::thread::scope(|scope| {
            let waiter = scope.spawn(|| {
                installed
                    .download_engine(&entry, Some(&lease))
                    .map(drop)
                    .map(|()| Instant::now())
                    .map_err(|failure| (failure.to_string(), Instant::now()))
            });
            std::thread::sleep(Duration::from_millis(300));
            let signalled = Instant::now();
            let result = if cancel {
                lease.release();
                let result = waiter.join().unwrap();
                drop(held);
                result
            } else {
                drop(held);
                waiter.join().unwrap()
            };
            let woke = match result {
                Ok(woke) => {
                    assert!(!cancel);
                    woke
                }
                Err((failure, woke)) => {
                    assert!(cancel, "{failure}");
                    woke
                }
            };
            assert!(woke.duration_since(signalled) < Duration::from_millis(200));
        });
        // A 5 ms retry loop would try the lock about 60 times while held.
        let tries = entry.engine.attempts.load(Ordering::Relaxed) - attempts;
        assert!(tries <= 15, "{tries} lock attempts while waiting");
    }
    installed.shutdown();
}

#[test]
fn shutdown_unlocks_inherited_descriptors_without_unlocking_reopened_owner() {
    let directory = tempfile::tempdir().unwrap();
    let open = || {
        ExtensionManager::new(
            &directory.path().join("sources"),
            &directory.path().join("data"),
            "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
            "1",
            RuntimeLimits::default(),
        )
    };
    let manager = open().unwrap();
    // A fork before exec can retain the same open file description even
    // though the manager closes its own descriptor during shutdown.
    let inherited = manager
        .directory_locks
        .lock()
        .unwrap()
        .as_ref()
        .unwrap()
        .iter()
        .map(File::try_clone)
        .collect::<Result<Vec<_>, _>>()
        .unwrap();
    manager.shutdown();
    let reopened = open().unwrap();
    drop(inherited);
    drop(manager);
    assert!(
        open()
            .err()
            .unwrap()
            .to_string()
            .contains("already managed")
    );
    reopened.shutdown();
    assert!(open().is_ok());
}
