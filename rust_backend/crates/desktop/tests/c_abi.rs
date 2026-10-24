//! Calls the exported C ABI in-process, as Dart does through `dart:ffi`.
//! The library keeps process-wide state, so every test shares one
//! initialization and uses its own call IDs.

use mornye_desktop::{
    implemented_methods, kind, mornye_call, mornye_cancel, mornye_free, mornye_init,
    mornye_subscribe, mornye_unsubscribe,
};
use serde_json::{Value, json};
use std::collections::{HashMap, HashSet};
use std::ffi::CString;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Condvar, Mutex, Once, OnceLock};
use std::time::{Duration, Instant};

type Event = (i32, Vec<u8>);

#[derive(Default)]
struct Inbox {
    events: Mutex<HashMap<u64, Vec<Event>>>,
    changed: Condvar,
}

fn inbox() -> &'static Inbox {
    static INBOX: OnceLock<Inbox> = OnceLock::new();
    INBOX.get_or_init(Inbox::default)
}

extern "C" fn callback(id: u64, kind: i32, data: *const u8, len: usize) {
    let bytes = if data.is_null() {
        Vec::new()
    } else {
        // SAFETY: the library passes a buffer of `len` bytes that stays valid
        // until `mornye_free`.
        #[allow(unsafe_code)]
        unsafe { std::slice::from_raw_parts(data, len) }.to_vec()
    };
    // Dart copies, then frees.
    #[allow(unsafe_code)]
    unsafe {
        mornye_free(data.cast_mut(), len)
    };
    let inbox = inbox();
    inbox
        .events
        .lock()
        .unwrap()
        .entry(id)
        .or_default()
        .push((kind, bytes));
    inbox.changed.notify_all();
}

struct Fixture {
    root: PathBuf,
}

fn fixture() -> &'static Fixture {
    static FIXTURE: OnceLock<Fixture> = OnceLock::new();
    static INIT: Once = Once::new();
    let fixture = FIXTURE.get_or_init(|| {
        let root = tempfile::tempdir().unwrap().keep();
        for name in [
            "support",
            "documents",
            "temp",
            "extensions",
            "data",
            "music",
        ] {
            std::fs::create_dir_all(root.join(name)).unwrap();
        }
        Fixture { root }
    });
    INIT.call_once(|| {
        let config = json!({
            "app_support_dir": fixture.root.join("support"),
            "documents_dir": fixture.root.join("documents"),
            "temp_dir": fixture.root.join("temp"),
            "ffmpeg_path": null,
            "ffprobe_path": null,
        })
        .to_string();
        #[allow(unsafe_code)]
        unsafe {
            mornye_init(Some(callback), config.as_ptr(), config.len())
        };
    });
    fixture
}

fn next_id() -> u64 {
    static NEXT: AtomicU64 = AtomicU64::new(1_000);
    NEXT.fetch_add(1, Ordering::SeqCst)
}

fn wait_for(id: u64, timeout: Duration) -> Event {
    wait_matching(id, timeout, |_| true)
}

/// Takes the first event for `id` that `matches`, leaving the others; pushed
/// events (id 0) from tests running in parallel share one list.
fn wait_matching(id: u64, timeout: Duration, matches: impl Fn(&Event) -> bool) -> Event {
    let inbox = inbox();
    let deadline = Instant::now() + timeout;
    let mut events = inbox.events.lock().unwrap();
    loop {
        if let Some(list) = events.get_mut(&id)
            && let Some(index) = list.iter().position(&matches)
        {
            return list.remove(index);
        }
        let remaining = deadline.saturating_duration_since(Instant::now());
        assert!(!remaining.is_zero(), "no callback for id {id}");
        events = inbox.changed.wait_timeout(events, remaining).unwrap().0;
    }
}

fn call_raw(method: &str, args: &str, bytes: Option<&[u8]>) -> (i32, Vec<u8>) {
    fixture();
    let id = next_id();
    let method = CString::new(method).unwrap();
    let (pointer, len) = bytes.map_or((std::ptr::null(), 0), |bytes| (bytes.as_ptr(), bytes.len()));
    #[allow(unsafe_code)]
    unsafe {
        mornye_call(id, method.as_ptr(), args.as_ptr(), args.len(), pointer, len)
    };
    wait_for(id, Duration::from_secs(30))
}

fn call(method: &str, args: Value) -> Result<Value, Value> {
    let (kind, data) = call_raw(method, &args.to_string(), None);
    let value: Value = serde_json::from_slice(&data).unwrap();
    match kind {
        kind::RESULT => Ok(value),
        kind::ERROR => Err(value),
        other => panic!("unexpected kind {other}"),
    }
}

#[test]
fn sanitize_filename_returns_result_payload() {
    let result = call("sanitizeFilename", json!({"filename": "a/b:c?.flac"})).unwrap();
    let expected = mornye_mobile::sanitize_filename("a/b:c?.flac".into());
    assert_eq!(result, Value::String(expected));
}

#[test]
fn build_filename_and_backend_implementations() {
    let name = call(
        "buildFilename",
        json!({"template": "{artist} - {title}", "metadata": r#"{"artist":"A","title":"T"}"#}),
    )
    .unwrap();
    assert_eq!(name, "A - T");
    let implementations = call("getBackendImplementations", Value::Null).unwrap();
    assert_eq!(implementations["downloads"], "rust");
}

#[test]
fn unknown_method_is_unimplemented() {
    let error = call("pickSafTree", Value::Null).unwrap_err();
    assert_eq!(error["code"], "unimplemented");
    assert!(error["message"].as_str().unwrap().contains("pickSafTree"));
    assert_eq!(error["details"], Value::Null);
}

#[test]
fn binary_argument_is_restored_under_its_key() {
    let args = json!({
        "request_id": "palette-job",
        "request_json": r#"{"operation":"palette"}"#,
        "$bytes_key": "bytes",
    })
    .to_string();
    let rgba: Vec<u8> = [255u8, 0, 0, 255].repeat(64);
    let (kind, data) = call_raw("runNativeDataJob", &args, Some(&rgba));
    assert_eq!(kind, kind::RESULT, "{}", String::from_utf8_lossy(&data));
    let result: Value = serde_json::from_slice(&data).unwrap();
    let job: Value = serde_json::from_str(result.as_str().unwrap()).unwrap();
    assert!(job["colors"].is_array(), "{job}");

    let (kind, data) = call_raw("runNativeDataJob", r#"{"request_id":"x"}"#, Some(&rgba));
    assert_eq!(kind, kind::ERROR);
    let error: Value = serde_json::from_slice(&data).unwrap();
    assert_eq!(error["code"], "invalid_arguments");
}

#[test]
fn owner_methods_require_initialization_then_round_trip_settings() {
    let fixture = fixture();
    // Before initExtensionSystem the hosts report the generic error.
    let error = call("getInstalledExtensions", Value::Null).unwrap_err();
    assert_eq!(error["code"], "ERROR");
    assert!(
        error["message"]
            .as_str()
            .unwrap()
            .contains("not initialized")
    );

    let init = json!({
        "extensions_dir": fixture.root.join("extensions"),
        "data_dir": fixture.root.join("data"),
        // 32 zero bytes, base64-encoded.
        "master_key": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
        "allowed_directories": [fixture.root.join("music")],
    });
    assert_eq!(
        call("initExtensionSystem", init.clone()).unwrap(),
        Value::Null
    );
    assert_eq!(call("initExtensionSystem", init).unwrap(), Value::Null);

    assert_eq!(call("getInstalledExtensions", Value::Null).unwrap(), "[]");
    assert_eq!(
        call("setLoggingEnabled", json!({"enabled": true})).unwrap(),
        Value::Null
    );
    let logs: Value = serde_json::from_str(
        call("getLogsSince", json!({"index": 0}))
            .unwrap()
            .as_str()
            .unwrap(),
    )
    .unwrap();
    assert!(logs["logs"].is_array(), "{logs}");
    assert_eq!(
        call("setLyricsFetchOptions", json!({"options_json": "{}"})).unwrap(),
        r#"{"success":true}"#
    );
    assert_eq!(
        call("setProviderPriority", json!({"priority": "[]"})).unwrap(),
        Value::Null
    );
    assert_eq!(call("getProviderPriority", Value::Null).unwrap(), "[]");

    let token = call(
        "acquireDownloadDirectory",
        json!({"path": fixture.root.join("music")}),
    )
    .unwrap();
    assert!(token.as_str().is_some_and(|token| token.len() == 36));
    assert_eq!(
        call("releaseDownloadDirectory", json!({"token": token})).unwrap(),
        Value::Null
    );
    let progress = call("getLibraryScanProgress", Value::Null).unwrap();
    assert!(progress.is_object(), "{progress}");
}

#[test]
fn library_scan_progress_is_pushed_while_subscribed() {
    fixture();
    mornye_subscribe(kind::LIBRARY_SCAN_PROGRESS);
    mornye_subscribe(kind::LIBRARY_SCAN_PROGRESS);
    let (event_kind, data) = wait_matching(0, Duration::from_secs(10), |(event_kind, _)| {
        *event_kind == kind::LIBRARY_SCAN_PROGRESS
    });
    mornye_unsubscribe(kind::LIBRARY_SCAN_PROGRESS);
    mornye_unsubscribe(kind::LIBRARY_SCAN_PROGRESS);
    assert_eq!(event_kind, kind::LIBRARY_SCAN_PROGRESS);
    let payload: Value = serde_json::from_slice(&data).unwrap();
    assert!(payload.is_object(), "{payload}");
}

#[test]
fn cancel_and_free_tolerate_unknown_ids_and_null() {
    fixture();
    mornye_cancel(u64::MAX);
    #[allow(unsafe_code)]
    unsafe {
        mornye_free(std::ptr::null_mut(), 0)
    };
    // A second init keeps the first configuration and state.
    #[allow(unsafe_code)]
    unsafe {
        mornye_init(Some(callback), std::ptr::null(), 0)
    };
    assert!(call("sanitizeFilename", json!({"filename": "x"})).is_ok());
}

#[test]
fn method_table_covers_the_host_contract() {
    let methods = implemented_methods();
    let unique: HashSet<_> = methods.iter().collect();
    assert_eq!(unique.len(), methods.len(), "duplicate method names");
    // Rust calls the mobile hosts wrap (`osMethods` in AppDelegate.swift).
    for method in [
        "downloadCoverToFile",
        "releaseMemory",
        "releaseMemoryUnderPressure",
        "setLibraryCoverCacheDir",
        "scanLibraryFolderToNDJSONFile",
        "scanLibraryFolderIncremental",
        "getLibraryScanProgress",
        "cancelLibraryScan",
        "pauseLibraryScan",
        "resumeLibraryScan",
        "parseCueSheet",
        "extractCoverToFile",
        "rewriteSplitArtistTags",
        "writeM4AFreeformTags",
        "ensureAC4Config",
        "writeAC4Metadata",
        "reEnrichFile",
        "checkHiResAuthenticity",
        "getBackendImplementations",
        "readFileMetadata",
        "editFileMetadata",
        "readAudioMetadata",
        "downloadByStrategy",
        "runPostProcessingV2",
    ] {
        assert!(unique.contains(&method), "missing {method}");
    }
}

fn wait_inbound(method: &str, timeout: Duration) -> Value {
    let (_, data) = wait_matching(0, timeout, |(event_kind, data)| {
        *event_kind == kind::INBOUND_CALL
            && serde_json::from_slice::<Value>(data).is_ok_and(|value| value["method"] == method)
    });
    serde_json::from_slice::<Value>(&data).unwrap()["arguments"].clone()
}

#[test]
fn keep_awake_begins_and_ends_idempotently() {
    fixture();
    assert_eq!(call("endKeepAwake", Value::Null).unwrap(), json!(false));
    let begun = call("beginKeepAwake", json!({"reason": "Mornye test"})).unwrap();
    // macOS and Windows always hold; Linux needs systemd-inhibit.
    if cfg!(any(target_os = "macos", windows)) {
        assert_eq!(begun, json!(true));
    }
    assert_eq!(
        call("beginKeepAwake", json!({"reason": "Mornye test"})).unwrap(),
        begun
    );
    assert_eq!(call("endKeepAwake", Value::Null).unwrap(), begun);
    assert_eq!(call("endKeepAwake", Value::Null).unwrap(), json!(false));
}

#[test]
fn library_watcher_reports_changed_roots() {
    let root = fixture().root.join("music");
    let folder = root.to_string_lossy().into_owned();
    let watched = call(
        "watchLibraryFolders",
        json!({"paths": [folder, "/definitely/missing/folder"]}),
    )
    .unwrap();
    assert_eq!(watched, json!([folder]));
    std::thread::sleep(Duration::from_millis(800));
    std::fs::write(root.join("watched.flac"), b"x").unwrap();
    let arguments = wait_inbound("libraryFolderChanged", Duration::from_secs(10));
    assert_eq!(arguments["root"], json!(folder));
    assert_eq!(
        call("unwatchLibraryFolders", Value::Null).unwrap(),
        Value::Null
    );
    assert!(call("watchLibraryFolders", json!({"paths": "x"})).is_err());
}

#[test]
fn link_methods_answer_while_stopped() {
    let received = fixture().root.join("support").join("link").join("received");
    assert_eq!(
        call("linkStatus", Value::Null).unwrap(),
        json!({"running": false, "receivedDir": received})
    );
    assert_eq!(call("linkDevices", Value::Null).unwrap(), json!([]));
    assert_eq!(
        call("linkReply", json!({"requestId": "gone", "result": {}})).unwrap(),
        Value::Null
    );
    assert_eq!(
        call("linkReply", json!({})).unwrap_err()["code"],
        "invalid_arguments"
    );
    assert_eq!(
        call("linkSend", json!({"message": {"type": "x"}})).unwrap(),
        json!({"delivered": 0})
    );
    assert_eq!(call("linkEndPairing", Value::Null).unwrap(), Value::Null);
    assert_eq!(call("linkStop", Value::Null).unwrap(), Value::Null);
    assert!(call("linkBeginPairing", Value::Null).is_err());
}

#[test]
fn discord_presence_reports_a_status() {
    fixture();
    assert_eq!(
        call("discordPresenceInitialize", Value::Null).unwrap(),
        json!(true)
    );
    call(
        "discordPresenceUpdate",
        json!({"title": "Song", "artist": "Artist", "state": "Artist", "artwork": ""}),
    )
    .unwrap();
    // "active" when a Discord client runs on this machine.
    let status = wait_inbound("discordPresenceStatus", Duration::from_secs(15));
    assert!(status == "active" || status == "unavailable", "{status}");
    call("discordPresenceClear", Value::Null).unwrap();
    call("discordPresenceShutdown", Value::Null).unwrap();
}
