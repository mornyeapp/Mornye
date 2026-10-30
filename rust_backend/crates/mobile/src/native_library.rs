//! App-owned Library persistence. The schema remains owned by Dart; scans enter
//! through one worker call and never transfer a library-sized row list to UI.

pub(crate) mod dart_date;
pub(crate) mod path_keys;

use crate::manager::ExtensionManager;
use chrono::Utc;
use rusqlite::{Connection, OpenFlags, TransactionBehavior, params, params_from_iter};
use serde_json::{Map, Value, json};
use std::{
    fs::{self, File, OpenOptions},
    io::{BufRead, BufReader, BufWriter, Read, Write},
    path::Path,
    time::Duration,
};

const SCHEMA_VERSION: i64 = 20;
const SCAN_VERSION: i64 = 4;
const BATCH_SIZE: usize = 300;
const MAX_ROW_BYTES: usize = 16 * 1024 * 1024;
const COLUMNS: &[(&str, &str)] = &[
    ("id", "id"),
    ("trackName", "track_name"),
    ("artistName", "artist_name"),
    ("albumName", "album_name"),
    ("albumArtist", "album_artist"),
    ("filePath", "file_path"),
    ("coverPath", "cover_path"),
    ("scannedAt", "scanned_at"),
    ("fileModTime", "file_mod_time"),
    ("networkFileVersion", "network_file_version"),
    ("isrc", "isrc"),
    ("trackNumber", "track_number"),
    ("totalTracks", "total_tracks"),
    ("discNumber", "disc_number"),
    ("totalDiscs", "total_discs"),
    ("duration", "duration"),
    ("releaseDate", "release_date"),
    ("bitDepth", "bit_depth"),
    ("sampleRate", "sample_rate"),
    ("bitrate", "bitrate"),
    ("genre", "genre"),
    ("composer", "composer"),
    ("label", "label"),
    ("copyright", "copyright"),
    ("format", "format"),
];

type Check<'a> = &'a dyn Fn() -> Result<(), String>;

fn error(context: &str, error: impl std::fmt::Display) -> String {
    format!("{context}: {error}")
}

fn required<'a>(request: &'a Value, key: &str) -> Result<&'a str, String> {
    request[key]
        .as_str()
        .filter(|value| !value.is_empty())
        .ok_or_else(|| format!("Library request requires {key}"))
}

fn open(request: &Value, with_history: bool) -> Result<Connection, String> {
    let path = required(request, "library_path")?;
    if !Path::new(path).is_absolute()
        || Path::new(path).file_name().and_then(|v| v.to_str()) != Some("local_library.db")
    {
        return Err("Library database path must reference local_library.db".into());
    }
    // Never create a missing DB or migrate it from a worker. Dart initializes
    // the current schema and optional FTS/triggers before handing us this path.
    let db = Connection::open_with_flags(path, OpenFlags::SQLITE_OPEN_READ_WRITE)
        .map_err(|e| error("open Library", e))?;
    db.busy_timeout(Duration::from_secs(5))
        .map_err(|e| error("Library busy timeout", e))?;
    let version: i64 = db
        .pragma_query_value(None, "user_version", |row| row.get(0))
        .map_err(|e| error("Library schema version", e))?;
    if version != SCHEMA_VERSION {
        return Err(format!(
            "Library schema v{version} is incompatible with native v{SCHEMA_VERSION}"
        ));
    }
    db.execute_batch("PRAGMA recursive_triggers = ON; PRAGMA synchronous = NORMAL;")
        .map_err(|e| error("configure Library", e))?;
    if with_history {
        let history = required(request, "history_path")?;
        if !Path::new(history).is_absolute()
            || Path::new(history).file_name().and_then(|v| v.to_str()) != Some("history.db")
            || !Path::new(history).is_file()
        {
            return Err("History database must already exist".into());
        }
        db.execute("ATTACH DATABASE ? AS history_db", [history])
            .map_err(|e| error("attach History", e))?;
    }
    Ok(db)
}

fn source_current(db: &Connection, request: &Value) -> Result<(), String> {
    let source = required(request, "source_id")?;
    let path = required(request, "expected_source_path")?;
    let current: bool = db.query_row(
        "SELECT EXISTS(SELECT 1 FROM library_sources WHERE id = ? AND path = ? AND enabled = 1)",
        params![source, path], |row| row.get(0),
    ).map_err(|e| error("check Library source", e))?;
    if !current {
        return Err("Library source changed or was removed during scan".into());
    }
    Ok(())
}

/// Unified native-data dispatcher entry point. All filesystem/SQLite work must
/// execute on the platform worker, never on its method-channel/main thread.
pub(crate) fn execute(request: &Value, check: Check<'_>) -> Result<Value, String> {
    check()?;
    match required(request, "operation")? {
        "library_full_import" => import(request, None, check),
        "library_incremental_import" => {
            let owned;
            let delta = if let Some(path) = request["delta_path"].as_str() {
                let file = File::open(path).map_err(|e| error("open scan delta", e))?;
                owned = serde_json::from_reader(BufReader::new(file))
                    .map_err(|e| error("decode scan delta file", e))?;
                &owned
            } else if let Some(text) = request["delta_json"].as_str() {
                owned = serde_json::from_str(text).map_err(|e| error("decode scan delta", e))?;
                &owned
            } else {
                &request["delta"]
            };
            if !delta.is_object() {
                return Err("Library delta must be an object".into());
            }
            import(request, Some(delta), check)
        }
        "library_snapshot" => snapshot(request, check),
        "library_snapshot_candidates" => snapshot_candidates(request, check),
        _ => Err("Unknown native Library operation".into()),
    }
}

/// The existing native scanner's delta stays native through ingestion. The
/// platform SAF adapter uses library_incremental_import with its native delta.
pub(crate) fn scan_incremental(
    manager: &ExtensionManager,
    request: &Value,
    check: &(dyn Fn() -> Result<(), String> + Sync),
) -> Result<Value, String> {
    let delta = manager
        .inner
        .scan_library_folder_incremental_from_snapshot(
            required(request, "folder_path")?,
            required(request, "snapshot_path")?,
            check,
        )?;
    check()?;
    if delta["cancelled"] == true {
        return Err("Library scan cancelled".into());
    }
    import(request, Some(&delta), check)
}

pub(crate) fn normalized(value: &str) -> String {
    path_keys::dart_lower(path_keys::dart_trim(value))
}

fn text<'a>(row: &'a Value, key: &str) -> Result<&'a str, String> {
    match &row[key] {
        Value::Null => Ok(""),
        Value::String(value) => Ok(value),
        _ => Err(format!("Library row {key} must be a string")),
    }
}

fn flag(value: &Value) -> i64 {
    i64::from(value == &Value::Bool(true) || value.as_f64() == Some(1.0))
}

fn has_replaygain(row: &Value) -> bool {
    if flag(&row["hasReplayGain"]) != 0 {
        return true;
    }
    for key in ["replaygain_track_gain", "replaygain_album_gain"] {
        let value = match &row[key] {
            Value::String(s) => s.clone(),
            Value::Number(n) => n.to_string(),
            _ => continue,
        };
        let trimmed = path_keys::dart_trim(&value);
        let lowered = trimmed.to_lowercase();
        let number = if lowered.ends_with("db") {
            &trimmed[..trimmed.len() - 2]
        } else {
            trimmed
        };
        if number.trim().parse::<f64>().is_ok_and(f64::is_finite) {
            return true;
        }
    }
    false
}

fn numeric(value: &Value) -> Option<i64> {
    value
        .as_i64()
        .or_else(|| value.as_f64().filter(|n| n.is_finite()).map(|n| n as i64))
}

fn scan_timestamp(value: &str) -> i64 {
    dart_date::parse(value)
        .map(|date| date.instant.timestamp_millis())
        .unwrap_or(0)
}

/// Rows built outside the Rust readers, such as the Android DSD/WavPack row,
/// carry no scan time. Stamp them with the import time instead of rejecting
/// the whole scan.
fn stamped(row: &Value) -> Option<Value> {
    if !row.is_object() || !row["scannedAt"].is_null() {
        return None;
    }
    let mut copy = row.clone();
    copy["scannedAt"] = dart_date::iso_utc(&Utc::now()).into();
    Some(copy)
}

fn incremental_row(row: &Value) -> Result<Value, String> {
    let mut canonical = stamped(row).unwrap_or_else(|| row.clone());
    let timestamp = text(&canonical, "scannedAt")?;
    let parsed =
        dart_date::parse(timestamp).ok_or("Invalid incremental Library scannedAt timestamp")?;
    let formatted = dart_date::iso(&parsed);
    canonical["scannedAt"] = formatted.into();
    // Preserve the existing LocalLibraryItem.fromJson(...).toJson() contract,
    // including its numeric truncation and scan-version defaults. Full-scan
    // imports retain the raw scan flags through LibraryRowMapper instead.
    let object = canonical
        .as_object_mut()
        .ok_or("Library row must be an object")?;
    object.remove("audioMetadataScanVersion");
    object.remove("metadataFromFilename");
    for key in [
        "fileModTime",
        "trackNumber",
        "totalTracks",
        "discNumber",
        "totalDiscs",
        "duration",
        "bitDepth",
        "sampleRate",
        "bitrate",
    ] {
        if let Some(value) = object.get(key)
            && !value.is_null()
        {
            let value = numeric(value)
                .ok_or_else(|| format!("Incremental Library {key} must be numeric"))?;
            object.insert(key.into(), value.into());
        }
    }
    Ok(canonical)
}

fn encode(row: &Value, source: &str) -> Result<Map<String, Value>, String> {
    let stamped = stamped(row);
    let row = stamped.as_ref().unwrap_or(row);
    if !row.is_object() || path_keys::dart_trim(text(row, "id")?).is_empty() {
        return Err("Library scan row has no valid id".into());
    }
    let mut values = Map::new();
    for key in ["audioMetadataScanVersion", "fileModTime"] {
        if !row[key].is_null() && !row[key].is_number() {
            return Err(format!("Library {key} must be numeric"));
        }
    }
    for (json_key, column) in COLUMNS {
        values.insert((*column).into(), row[*json_key].clone());
    }
    // Staging CTAS does not retain NOT NULL constraints. Validate required
    // storage fields before staging so corrupt input cannot survive to swap.
    for key in [
        "trackName",
        "artistName",
        "albumName",
        "filePath",
        "scannedAt",
    ] {
        if !row[key].is_string() {
            return Err(format!("Library scan row requires string {key}"));
        }
    }
    values.insert("source_id".into(), source.into());
    values.insert("explicit".into(), flag(&row["explicit"]).into());
    values.insert("has_lyrics".into(), flag(&row["hasLyrics"]).into());
    values.insert(
        "has_replaygain".into(),
        i64::from(has_replaygain(row)).into(),
    );
    values.insert(
        "audio_metadata_scan_version".into(),
        numeric(&row["audioMetadataScanVersion"])
            .unwrap_or(if row["metadataFromFilename"] == true {
                0
            } else {
                SCAN_VERSION
            })
            .into(),
    );
    let track = normalized(text(row, "trackName")?);
    let artist = normalized(text(row, "artistName")?);
    let album = normalized(text(row, "albumName")?);
    let album_artist = if row["albumArtist"].is_null() {
        artist.clone()
    } else {
        normalized(text(row, "albumArtist")?)
    };
    for (key, value) in [
        ("track_name_norm", track.clone()),
        ("artist_name_norm", artist.clone()),
        ("album_name_norm", album.clone()),
        ("album_artist_norm", album_artist.clone()),
        ("match_key", format!("{track}|{artist}")),
        ("album_key", format!("{album}|{album_artist}")),
    ] {
        values.insert(key.into(), value.into());
    }
    let search_album_artist = if path_keys::dart_trim(text(row, "albumArtist")?).is_empty() {
        artist.clone()
    } else {
        album_artist
    };
    values.insert(
        "search_text".into(),
        [track, artist, album, search_album_artist]
            .into_iter()
            .filter(|value| !value.is_empty())
            .collect::<Vec<_>>()
            .join(" ")
            .into(),
    );
    values.insert("sort_genre".into(), normalized(text(row, "genre")?).into());
    values.insert(
        "sort_release".into(),
        path_keys::dart_trim(text(row, "releaseDate")?).into(),
    );
    values.insert(
        "sort_added".into(),
        numeric(&row["fileModTime"])
            .unwrap_or_else(|| scan_timestamp(text(row, "scannedAt").unwrap_or("")))
            .into(),
    );
    Ok(values)
}

fn sql_value(value: &Value) -> Result<rusqlite::types::Value, String> {
    use rusqlite::types::Value as SqlValue;
    match value {
        Value::Null => Ok(SqlValue::Null),
        Value::String(s) => Ok(SqlValue::Text(s.clone())),
        Value::Bool(v) => Ok(SqlValue::Integer(i64::from(*v))),
        Value::Number(n) => n
            .as_i64()
            .map(SqlValue::Integer)
            .or_else(|| n.as_f64().map(SqlValue::Real))
            .ok_or("Invalid Library number".into()),
        _ => Err("Library storage field cannot contain an object or array".into()),
    }
}

fn import(request: &Value, delta: Option<&Value>, check: Check<'_>) -> Result<Value, String> {
    let mut db = open(request, true)?;
    source_current(&db, request)?;
    let source = required(request, "source_id")?;
    let columns = db
        .prepare("PRAGMA table_info(library)")
        .map_err(|e| error("Library columns", e))?
        .query_map([], |row| row.get::<_, String>(1))
        .map_err(|e| error("Library columns", e))?
        .collect::<Result<Vec<_>, _>>()
        .map_err(|e| error("Library columns", e))?;
    let column_list = columns
        .iter()
        .map(|name| format!("\"{}\"", name.replace('"', "\"\"")))
        .collect::<Vec<_>>()
        .join(", ");
    db.execute_batch("CREATE TEMP TABLE native_library_stage AS SELECT * FROM library WHERE 0;
        CREATE UNIQUE INDEX native_library_stage_id ON native_library_stage(id);
        CREATE UNIQUE INDEX native_library_stage_path ON native_library_stage(file_path);
        CREATE TEMP TABLE native_library_keys(item_id TEXT NOT NULL, path_key TEXT NOT NULL, PRIMARY KEY(item_id,path_key));
        CREATE INDEX native_library_keys_key ON native_library_keys(path_key);")
        .map_err(|e| error("stage Library scan", e))?;
    let placeholders = vec!["?"; columns.len()].join(", ");
    let insert = format!(
        "INSERT OR REPLACE INTO native_library_stage ({column_list}) VALUES ({placeholders})"
    );
    let android = request["platform"] == "android";
    let mut streamed = 0_usize;
    let mut invalid = 0_u64;
    let mut first_invalid = None::<String>;
    // The owner protects these paths during publication, as it does for
    // platform read errors. Past 256 entries it preserves every missing row.
    let mut invalid_paths = Vec::<String>::new();
    let mut pending = Vec::with_capacity(BATCH_SIZE);
    let mut flush = |rows: &mut Vec<Value>| -> Result<(), String> {
        if rows.is_empty() {
            return Ok(());
        }
        check()?;
        let transaction = db
            .transaction()
            .map_err(|e| error("stage transaction", e))?;
        for row in rows.drain(..) {
            check()?;
            // One corrupt row is reported and skipped. It must not discard the
            // rest of an otherwise valid scan; the swap below keeps the file's
            // previous entry, as it does for a platform read error.
            let encoded = if delta.is_some() {
                incremental_row(&row).and_then(|canonical| encode(&canonical, source))
            } else {
                encode(&row, source)
            };
            let mapped = match encoded {
                Ok(mapped) => mapped,
                Err(message) => {
                    invalid += 1;
                    let path = row["filePath"].as_str().unwrap_or("<no path>");
                    if first_invalid.is_none() {
                        first_invalid = Some(format!("{path}: {message}"));
                    }
                    if invalid_paths.len() < 256 && path != "<no path>" {
                        invalid_paths.push(path.to_owned());
                    }
                    continue;
                }
            };
            let fields = columns
                .iter()
                .map(|column| sql_value(mapped.get(column).unwrap_or(&Value::Null)))
                .collect::<Result<Vec<_>, _>>()?;
            transaction
                .prepare_cached(&insert)
                .map_err(|e| error("prepare staged row", e))?
                .execute(params_from_iter(fields))
                .map_err(|e| error("stage Library row", e))?;
            let id = text(&row, "id")?;
            transaction
                .execute("DELETE FROM native_library_keys WHERE item_id = ?", [id])
                .map_err(|e| error("replace staged keys", e))?;
            for key in path_keys::build(text(&row, "filePath")?, android)? {
                transaction
                    .prepare_cached("INSERT OR IGNORE INTO native_library_keys VALUES (?, ?)")
                    .map_err(|e| error("prepare staged keys", e))?
                    .execute(params![id, key])
                    .map_err(|e| error("stage path key", e))?;
            }
        }
        transaction
            .commit()
            .map_err(|e| error("commit staged batch", e))?;
        Ok(())
    };
    if let Some(delta) = delta {
        let rows = delta["files"]
            .as_array()
            .or_else(|| delta["scanned"].as_array())
            .ok_or("Native incremental scan requires a rows array")?;
        for row in rows {
            pending.push(row.clone());
            streamed += 1;
            if pending.len() == BATCH_SIZE {
                flush(&mut pending)?;
            }
        }
    } else {
        let expected = request["expected_count"]
            .as_u64()
            .ok_or("Full scan requires expected_count")?;
        let mut reader = BufReader::new(
            File::open(required(request, "ndjson_path")?)
                .map_err(|e| error("open scan NDJSON", e))?,
        );
        let mut line = String::new();
        loop {
            check()?;
            line.clear();
            let bytes = reader
                .by_ref()
                .take((MAX_ROW_BYTES + 1) as u64)
                .read_line(&mut line)
                .map_err(|e| error("read scan NDJSON", e))?;
            if bytes == 0 {
                break;
            }
            if bytes > MAX_ROW_BYTES {
                return Err("Library scan NDJSON row is too large".into());
            }
            if path_keys::dart_trim(&line).is_empty() {
                continue;
            }
            pending.push(serde_json::from_str(&line).map_err(|e| error("decode scan NDJSON", e))?);
            streamed += 1;
            if pending.len() == BATCH_SIZE {
                flush(&mut pending)?;
            }
        }
        if streamed as u64 != expected {
            return Err(format!(
                "Library scan row count mismatch: decoded {streamed}, expected {expected}"
            ));
        }
    }
    flush(&mut pending)?;
    check()?;
    let transaction = db
        .transaction_with_behavior(TransactionBehavior::Immediate)
        .map_err(|e| error("begin Library swap", e))?;
    source_current(&transaction, request)?;
    let history_match = "EXISTS(SELECT 1 FROM native_library_keys sk JOIN history_db.history_path_keys hk ON hk.path_key = sk.path_key WHERE sk.item_id = s.id)";
    let staged: i64 = transaction
        .query_row("SELECT COUNT(*) FROM native_library_stage", [], |row| {
            row.get(0)
        })
        .map_err(|e| error("count staged rows", e))?;
    let skipped: i64 = transaction
        .query_row(
            &format!("SELECT COUNT(*) FROM native_library_stage s WHERE {history_match}"),
            [],
            |row| row.get(0),
        )
        .map_err(|e| error("count excluded downloads", e))?;
    let mut deleted = 0;
    let mut excluded_existing = 0;
    if let Some(delta) = delta {
        // Remove files which became downloads, then apply this source's delta
        // atomically. All deletes remain source-scoped even if aliases overlap.
        let excluded = "source_id = ? AND EXISTS(SELECT 1 FROM library_path_keys lk JOIN history_db.history_path_keys hk ON hk.path_key = lk.path_key WHERE lk.item_id = library.id)";
        transaction.execute(&format!("CREATE TEMP TABLE native_library_excluded AS SELECT id FROM library WHERE {excluded}"), [source]).map_err(|e| error("select downloaded rows", e))?;
        transaction.execute("DELETE FROM library_path_keys WHERE item_id IN(SELECT id FROM native_library_excluded)", []).map_err(|e| error("remove downloaded path keys", e))?;
        excluded_existing += transaction
            .execute(
                "DELETE FROM library WHERE id IN(SELECT id FROM native_library_excluded)",
                [],
            )
            .map_err(|e| error("remove downloaded rows", e))?;
        let paths = delta["removedUris"]
            .as_array()
            .or_else(|| delta["deletedPaths"].as_array());
        // The platform adapter can delete its spilled delta immediately after
        // this operation. Retain its exact removal selection in the private
        // staging database for publication by the live database's owner.
        let retain_removed = request["retain_removed_paths"] == true;
        if retain_removed {
            transaction.execute_batch("CREATE TABLE IF NOT EXISTS main.native_library_removed_paths(ordinal INTEGER PRIMARY KEY,path TEXT NOT NULL); DELETE FROM main.native_library_removed_paths;")
                .map_err(|e| error("stage removed Library paths", e))?;
        }
        if let Some(paths) = paths {
            for (ordinal, path) in paths.iter().enumerate() {
                check()?;
                let path = path
                    .as_str()
                    .ok_or("Deleted Library path must be a string")?;
                if retain_removed {
                    transaction
                        .execute(
                            "INSERT INTO main.native_library_removed_paths VALUES(?,?)",
                            params![ordinal as i64, path],
                        )
                        .map_err(|e| error("retain removed Library path", e))?;
                }
                transaction.execute("DELETE FROM library_path_keys WHERE item_id IN(SELECT id FROM library WHERE source_id = ? AND file_path = ?)", params![source,path]).map_err(|e| error("delete removed path keys", e))?;
                deleted += transaction
                    .execute(
                        "DELETE FROM library WHERE source_id = ? AND file_path = ?",
                        params![source, path],
                    )
                    .map_err(|e| error("delete removed track", e))?;
            }
        }
        // staged/download overlap is the same anti-join used by full scans.
        let ids = format!(
            "SELECT id FROM library WHERE source_id = ? AND file_path IN(SELECT file_path FROM native_library_stage s WHERE {history_match})"
        );
        transaction
            .execute(
                &format!("DELETE FROM library_path_keys WHERE item_id IN({ids})"),
                [source],
            )
            .map_err(|e| error("remove excluded keys", e))?;
        excluded_existing += transaction
            .execute(&format!("DELETE FROM library WHERE id IN({ids})"), [source])
            .map_err(|e| error("remove excluded rows", e))?;
    } else {
        let errors = request["error_count"]
            .as_u64()
            .ok_or("Full scan requires nonnegative error_count")?
            + invalid;
        let where_clause = if errors > 0 {
            "source_id = ? AND (id IN(SELECT id FROM native_library_stage) OR file_path IN(SELECT file_path FROM native_library_stage))"
        } else {
            "source_id = ?"
        };
        transaction.execute(&format!("DELETE FROM library_path_keys WHERE item_id IN(SELECT id FROM library WHERE {where_clause})"), [source]).map_err(|e| error("replace source keys", e))?;
        transaction
            .execute(
                &format!("DELETE FROM library WHERE {where_clause}"),
                [source],
            )
            .map_err(|e| error("replace source rows", e))?;
    }
    check()?;
    transaction.execute(&format!("DELETE FROM library_path_keys WHERE item_id IN(SELECT s.id FROM native_library_stage s WHERE NOT {history_match})"), []).map_err(|e| error("replace imported keys", e))?;
    transaction.execute(&format!("INSERT OR REPLACE INTO library({column_list}) SELECT {} FROM native_library_stage s WHERE NOT {history_match}", columns.iter().map(|c| format!("s.\"{c}\"")).collect::<Vec<_>>().join(", ")), []).map_err(|e| error("swap imported rows", e))?;
    transaction.execute(&format!("INSERT OR IGNORE INTO library_path_keys SELECT sk.item_id,sk.path_key FROM native_library_keys sk JOIN native_library_stage s ON s.id=sk.item_id WHERE NOT {history_match}"), []).map_err(|e| error("swap imported keys", e))?;
    check()?;
    transaction
        .commit()
        .map_err(|e| error("commit Library swap", e))?;
    Ok(
        json!({"committed":true,"inserted":staged-skipped,"upserted":staged-skipped,"skipped":skipped+excluded_existing as i64,"scanned_count":streamed,"invalid_rows":invalid,"invalid_row_error":first_invalid,"invalid_row_paths":invalid_paths,"deleted_count":deleted,"skippedCount":delta.map(|d|d["skippedCount"].clone()).unwrap_or(json!(0)),"totalFiles":delta.map(|d|d["totalFiles"].clone()).unwrap_or(json!(streamed))}),
    )
}

fn snapshot_candidates(request: &Value, check: Check<'_>) -> Result<Value, String> {
    let db = open(request, false)?;
    source_current(&db, request)?;
    let cursor = request["cursor"].as_str().unwrap_or("");
    let limit = request["limit"].as_i64().unwrap_or(500).clamp(1, 500);
    let mut statement = db.prepare("SELECT id,file_path FROM library WHERE source_id=? AND id>? AND COALESCE(file_mod_time,0)=0 AND audio_metadata_scan_version>=4 AND file_path LIKE 'content://%' ORDER BY id LIMIT ?").map_err(|e| error("prepare snapshot backfill", e))?;
    let rows = statement
        .query_map(
            params![required(request, "source_id")?, cursor, limit + 1],
            |row| Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?)),
        )
        .map_err(|e| error("query snapshot backfill", e))?
        .collect::<Result<Vec<_>, _>>()
        .map_err(|e| error("read snapshot backfill", e))?;
    check()?;
    let has_more = rows.len() > limit as usize;
    let rows = rows.into_iter().take(limit as usize).collect::<Vec<_>>();
    Ok(
        json!({"paths":rows.iter().map(|(id,path)|json!({"id":id,"file_path":path})).collect::<Vec<_>>(),"cursor":rows.last().map(|(id,_)|id.as_str()).unwrap_or(cursor),"has_more":has_more}),
    )
}

fn snapshot(request: &Value, check: Check<'_>) -> Result<Value, String> {
    let mut db = open(request, false)?;
    source_current(&db, request)?;
    let path = required(request, "snapshot_path")?;
    if !Path::new(path).is_absolute() || !path.ends_with(".tsv") {
        return Err("Snapshot output must be an absolute TSV path".into());
    }
    let file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(path)
        .map_err(|e| error("create incremental snapshot", e))?;
    let result = (|| {
        // A WAL read snapshot does not hold the persistent writer during file
        // inspection/output. Backfill acquires its own short write transaction.
        let transaction = db.transaction().map_err(|e| error("begin snapshot", e))?;
        source_current(&transaction, request)?;
        let mut statement = transaction.prepare("SELECT file_path,COALESCE(file_mod_time,0),COALESCE(audio_metadata_scan_version,0) FROM library WHERE source_id=? ORDER BY id").map_err(|e| error("prepare snapshot", e))?;
        let mut rows = statement
            .query([required(request, "source_id")?])
            .map_err(|e| error("query snapshot", e))?;
        let mut output = BufWriter::new(file);
        let mut count = 0;
        let mut backfilled = Vec::new();
        while let Some(row) = rows.next().map_err(|e| error("read snapshot", e))? {
            check()?;
            let file_path: String = row.get(0).map_err(|e| error("snapshot file path", e))?;
            let stored: i64 = row.get(1).map_err(|e| error("snapshot timestamp", e))?;
            let version: i64 = row.get(2).map_err(|e| error("snapshot scan version", e))?;
            let mut timestamp = if version < SCAN_VERSION { -1 } else { stored };
            if timestamp == 0 {
                let supplied =
                    numeric(&request["backfilled_mod_times"][&file_path]).filter(|v| *v > 0);
                let discovered = if !file_path.starts_with("content://")
                    && !file_path.starts_with("network://")
                {
                    fs::metadata(&file_path)
                        .ok()
                        .filter(|m| m.is_file())
                        .and_then(|m| m.modified().ok())
                        .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
                        .map(|d| d.as_millis() as i64)
                } else {
                    None
                };
                if let Some(time) = supplied.or(discovered) {
                    timestamp = time;
                    backfilled.push((file_path.clone(), time));
                }
            }
            if file_path.is_empty() {
                continue;
            }
            if file_path.contains(['\n', '\r']) {
                return Err("Snapshot file path contains a line break".into());
            }
            writeln!(output, "{timestamp}\t{file_path}").map_err(|e| error("write snapshot", e))?;
            count += 1;
        }
        drop(rows);
        drop(statement);
        transaction
            .commit()
            .map_err(|e| error("close snapshot read", e))?;
        output.flush().map_err(|e| error("flush snapshot", e))?;
        output
            .get_ref()
            .sync_all()
            .map_err(|e| error("sync snapshot", e))?;
        check()?;
        let write = db
            .transaction_with_behavior(TransactionBehavior::Immediate)
            .map_err(|e| error("begin timestamp backfill", e))?;
        source_current(&write, request)?;
        for (file_path, timestamp) in &backfilled {
            check()?;
            write.execute("UPDATE library SET file_mod_time=?,sort_added=? WHERE source_id=? AND file_path=? AND COALESCE(file_mod_time,0)=0 AND audio_metadata_scan_version>=4",params![timestamp,timestamp,required(request,"source_id")?,file_path]).map_err(|e| error("backfill timestamp", e))?;
        }
        check()?;
        write
            .commit()
            .map_err(|e| error("commit timestamp backfill", e))?;
        Ok(json!({"committed":true,"path":path,"count":count,"backfilled_count":backfilled.len()}))
    })();
    if result.is_err() {
        let _ = fs::remove_file(path);
    }
    result
}

#[cfg(test)]
mod tests;
