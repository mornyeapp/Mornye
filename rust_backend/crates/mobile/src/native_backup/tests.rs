use super::*;
use std::cell::Cell;
use tempfile::TempDir;

struct Fixture {
    dir: TempDir,
    db: Connection,
    request: Value,
}
fn track(id: &str) -> Value {
    json!({"id":id,"trackName":format!("Track {id}"),"artistName":"Artist","albumName":"Album","filePath":format!("/music/{id}.flac"),"service":"provider","downloadedAt":"2026-10-06T19:00:00.000+07:00","hasLyrics":true,"hasReplayGain":true})
}

#[test]
fn actual_complete_dart_history_codec_and_path_identity_parity() {
    let fixture: Value = serde_json::from_str(include_str!(
        "../../../../../test/fixtures/native_backup_contract.json"
    ))
    .unwrap();
    for row in fixture.as_array().unwrap() {
        let encoded = encode(&row["input"]).unwrap();
        assert_eq!(
            Value::Object(encoded.clone()),
            row["encoded"],
            "encoding {:?}",
            row["input"]["id"]
        );
        assert_eq!(
            Value::Object(decode(&encoded, &json!({}))),
            row["decoded"],
            "decoding {:?}",
            row["input"]["id"]
        );
        let expected = row["path_keys"]
            .as_array()
            .unwrap()
            .iter()
            .map(|v| v.as_str().unwrap().to_string())
            .collect::<std::collections::BTreeSet<_>>();
        assert_eq!(
            build(row["input"]["filePath"].as_str().unwrap(), false).unwrap(),
            expected
        );
    }
}

#[test]
fn ios_export_rebases_only_app_owned_paths_and_keeps_import_verbatim() {
    let old = "/var/mobile/Containers/Data/Application/AAAA/Documents/Music/track.flac";
    let current = "/var/mobile/Containers/Data/Application/BBBB/Documents";
    assert_eq!(
        rebase_ios(old, current),
        "/var/mobile/Containers/Data/Application/BBBB/Documents/Music/track.flac"
    );
    for path in [
        "/var/mobile/Containers/Data/Application/AAAA/tmp/a.flac",
        "/var/mobile/Containers/Data/Application/AAAA/Documents/../tmp/a.flac",
        "/external/Music/a.flac",
    ] {
        assert_eq!(rebase_ios(path, current), path);
    }
    let mut row = track("old");
    row["filePath"] = old.into();
    assert_eq!(encode(&row).unwrap()["file_path"], old);
}

#[test]
fn cancelling_restore_after_swap_keeps_old_rows_and_path_keys() {
    let fixture = Fixture::new();
    fixture.restore(&[track("old")], 1, &|| Ok(())).unwrap();
    let calls = Cell::new(0);
    let check = || {
        calls.set(calls.get() + 1);
        if calls.get() == 8 {
            Err("cancelled during restore".into())
        } else {
            Ok(())
        }
    };
    assert!(fixture.restore(&[track("new")], 1, &check).is_err());
    assert_eq!(calls.get(), 8);
    assert_eq!(fixture.ids(), ["old"]);
    assert!(
        fixture
            .db
            .query_row(
                "SELECT COUNT(*) FROM history_path_keys WHERE item_id='old'",
                [],
                |row| row.get::<_, i64>(0)
            )
            .unwrap()
            > 0
    );
}
impl Fixture {
    fn new() -> Self {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("history.db");
        let db = Connection::open(&path).unwrap();
        let values = encode(&track("schema")).unwrap();
        let columns = values
            .keys()
            .map(|key| {
                format!(
                    "{key} {}",
                    if key == "id" {
                        "TEXT PRIMARY KEY"
                    } else if key == "sort_added"
                        || key.ends_with("scan_version")
                        || ["saf_repaired", "explicit", "has_lyrics", "has_replaygain"]
                            .contains(&key.as_str())
                    {
                        "INTEGER"
                    } else {
                        "TEXT"
                    }
                )
            })
            .collect::<Vec<_>>()
            .join(",");
        db.execute_batch(&format!("PRAGMA journal_mode=WAL;PRAGMA user_version=16;PRAGMA recursive_triggers=ON;CREATE TABLE history({columns});CREATE TABLE history_path_keys(item_id TEXT,path_key TEXT,PRIMARY KEY(item_id,path_key));CREATE VIRTUAL TABLE history_search_fts USING fts5(search_text,content='history',content_rowid='rowid',tokenize='trigram');CREATE TRIGGER history_fts_ai AFTER INSERT ON history BEGIN INSERT INTO history_search_fts(rowid,search_text) VALUES(new.rowid,new.search_text);END;CREATE TRIGGER history_fts_ad AFTER DELETE ON history BEGIN INSERT INTO history_search_fts(history_search_fts,rowid,search_text) VALUES('delete',old.rowid,old.search_text);END;")).unwrap();
        let request = json!({"history_path":path.to_str().unwrap(),"platform":"ios"});
        Self { dir, db, request }
    }
    fn restore(&self, rows: &[Value], expected: u64, check: Check<'_>) -> Result<Value, String> {
        let path = self.dir.path().join("input.ndjson");
        let mut file = File::create(&path).unwrap();
        for row in rows {
            writeln!(file, "{row}").unwrap();
        }
        let mut request = self.request.clone();
        request["operation"] = "backup_history_import".into();
        request["ndjson_path"] = path.to_str().unwrap().into();
        request["expected_count"] = expected.into();
        execute(&request, check)
    }
    fn ids(&self) -> Vec<String> {
        self.db
            .prepare("SELECT id FROM history ORDER BY id")
            .unwrap()
            .query_map([], |row| row.get(0))
            .unwrap()
            .map(Result::unwrap)
            .collect()
    }
}

#[test]
fn backup_replace_round_trip_preserves_flags_dates_keys_order_and_fts() {
    let fixture = Fixture::new();
    fixture.restore(&[track("old")], 1, &|| Ok(())).unwrap();
    fixture
        .restore(&[track("b"), track("a")], 2, &|| Ok(()))
        .unwrap();
    assert_eq!(fixture.ids(), ["a", "b"]);
    assert!(
        fixture
            .db
            .query_row("SELECT COUNT(*) FROM history_path_keys", [], |r| r
                .get::<_, i64>(0))
            .unwrap()
            > 0
    );
    assert_eq!(
        fixture
            .db
            .query_row(
                "SELECT COUNT(*) FROM history_search_fts WHERE history_search_fts MATCH ?",
                ["old"],
                |r| r.get::<_, i64>(0)
            )
            .unwrap(),
        0
    );
    let output = fixture.dir.path().join("export.ndjson");
    let mut request = fixture.request.clone();
    request["operation"] = "backup_history_export".into();
    request["ndjson_path"] = output.to_str().unwrap().into();
    let result = execute(&request, &|| Ok(())).unwrap();
    assert_eq!(result["count"], 2);
    assert_eq!(result["published"], true);
    let rows = fs::read_to_string(output)
        .unwrap()
        .lines()
        .map(|line| serde_json::from_str::<Value>(line).unwrap())
        .collect::<Vec<_>>();
    assert_eq!(rows[0]["id"], "b");
    assert_eq!(rows[0]["downloadedAt"], "2026-10-06T12:00:00.000Z");
    assert_eq!(rows[0]["hasLyrics"], true);
    assert_eq!(rows[0]["hasReplayGain"], true);
    fixture.restore(&[], 0, &|| Ok(())).unwrap();
    assert!(fixture.ids().is_empty());
    fixture.restore(&rows, 2, &|| Ok(())).unwrap();
    assert_eq!(fixture.ids(), ["a", "b"]);
}

#[test]
fn corrupt_count_cancel_and_invalid_rows_keep_history_and_keys() {
    for failure in ["count", "invalid", "cancel"] {
        let fixture = Fixture::new();
        fixture.restore(&[track("old")], 1, &|| Ok(())).unwrap();
        let old_keys = fixture
            .db
            .query_row("SELECT COUNT(*) FROM history_path_keys", [], |r| {
                r.get::<_, i64>(0)
            })
            .unwrap();
        let mut rows = (0..550)
            .map(|i| track(&format!("new-{i}")))
            .collect::<Vec<_>>();
        if failure == "invalid" {
            rows[540]["filePath"] = Value::Null;
        }
        let calls = Cell::new(0);
        let check = || {
            calls.set(calls.get() + 1);
            if failure == "cancel" && calls.get() > 520 {
                Err("cancelled".into())
            } else {
                Ok(())
            }
        };
        assert!(
            fixture
                .restore(&rows, if failure == "count" { 549 } else { 550 }, &check)
                .is_err()
        );
        assert_eq!(fixture.ids(), ["old"]);
        assert_eq!(
            fixture
                .db
                .query_row("SELECT COUNT(*) FROM history_path_keys", [], |r| r
                    .get::<_, i64>(0))
                .unwrap(),
            old_keys
        );
    }
}

#[test]
fn merge_replaces_ids_without_clearing_unrelated_downloads() {
    let fixture = Fixture::new();
    fixture.restore(&[track("old")], 1, &|| Ok(())).unwrap();
    let input = fixture.dir.path().join("merge.ndjson");
    fs::write(&input, format!("{}\n", track("new"))).unwrap();
    let mut request = fixture.request.clone();
    request["operation"] = "backup_history_import".into();
    request["ndjson_path"] = input.to_str().unwrap().into();
    request["mode"] = "merge".into();
    execute(&request, &|| Ok(())).unwrap();
    assert_eq!(fixture.ids(), ["new", "old"]);
}

#[test]
fn legacy_split_streams_history_and_retains_category_semantics() {
    let fixture = Fixture::new();
    let input = fixture.dir.path().join("backup.json");
    let history = fixture.dir.path().join("legacy.ndjson");
    let metadata = fixture.dir.path().join("legacy.json");
    let original = json!({"magic":"spotiflac-backup","format_version":1,"app_version":"5.0","data":{"settings":{"theme":"light"},"history":[track("one"),12,track("two")],"collections":{"loved":["one"]}}});
    fs::write(&input, original.to_string()).unwrap();
    let request = json!({"operation":"backup_split_legacy","input_path":input.to_str().unwrap(),"ndjson_path":history.to_str().unwrap(),"metadata_path":metadata.to_str().unwrap()});
    let result = execute(&request, &|| Ok(())).unwrap();
    assert_eq!(result["count"], 2);
    assert_eq!(result["published"], true);
    let parsed: Value = serde_json::from_reader(File::open(metadata).unwrap()).unwrap();
    assert_eq!(parsed["data"]["history"], json!([]));
    assert_eq!(parsed["data"]["settings"], original["data"]["settings"]);
    assert_eq!(fs::read_to_string(history).unwrap().lines().count(), 2);
}

#[test]
fn legacy_split_accepts_current_app_marker() {
    let fixture = Fixture::new();
    let input = fixture.dir.path().join("backup.json");
    let history = fixture.dir.path().join("legacy.ndjson");
    let metadata = fixture.dir.path().join("legacy.json");
    fs::write(&input, r#"{"magic":"mornye-backup","data":{"history":[]}}"#).unwrap();
    let request = json!({
        "operation": "backup_split_legacy", "input_path": input,
        "ndjson_path": history, "metadata_path": metadata,
    });
    assert_eq!(execute(&request, &|| Ok(())).unwrap()["count"], 0);
}

#[test]
fn legacy_duplicate_history_uses_last_field_and_invalid_backup_cleans_output() {
    let fixture = Fixture::new();
    let input = fixture.dir.path().join("backup.json");
    let history = fixture.dir.path().join("legacy.ndjson");
    let metadata = fixture.dir.path().join("legacy.json");
    let request = json!({"operation":"backup_split_legacy","input_path":input.to_str().unwrap(),"ndjson_path":history.to_str().unwrap(),"metadata_path":metadata.to_str().unwrap()});
    fs::write(
        &input,
        format!(
            "{{\"magic\":\"spotiflac-backup\",\"data\":{{\"history\":[{}],\"history\":[]}}}}",
            track("old")
        ),
    )
    .unwrap();
    assert_eq!(execute(&request, &|| Ok(())).unwrap()["count"], 0);
    fs::remove_file(&history).unwrap();
    fs::remove_file(&metadata).unwrap();
    fs::write(&input, "{\"magic\":\"wrong\",\"data\":{\"history\":[]}}").unwrap();
    assert!(execute(&request, &|| Ok(())).is_err());
    assert!(!history.exists());
    assert!(!metadata.exists());
}
