//! History codecs and ZIP payloads stay on the native worker. Backup category
//! selection, archive layout and presentation remain owned by Flutter.
mod archive;
mod collections;
mod legacy;

use crate::native_library::path_keys::{build, dart_trim, dart_upper, regex_whitespace};
use crate::native_library::{dart_date, normalized};
use rusqlite::{Connection, OpenFlags, TransactionBehavior, params, params_from_iter};
use serde_json::{Map, Value, json};
use std::{
    fs::{self, File, OpenOptions},
    io::{BufRead, BufReader, BufWriter, Read, Write},
    path::Path,
    time::Duration,
};

type Check<'a> = &'a dyn Fn() -> Result<(), String>;
const MAX_HISTORY_BYTES: u64 = 512 << 20;
const MAX_ROW_BYTES: u64 = 16 << 20;
const BATCH_SIZE: usize = 500;
const COLUMNS: &[(&str, &str)] = &[
    ("id", "id"),
    ("trackName", "track_name"),
    ("artistName", "artist_name"),
    ("albumName", "album_name"),
    ("albumArtist", "album_artist"),
    ("coverUrl", "cover_url"),
    ("filePath", "file_path"),
    ("originFilePath", "origin_file_path"),
    ("storageMode", "storage_mode"),
    ("downloadTreeUri", "download_tree_uri"),
    ("safRelativeDir", "saf_relative_dir"),
    ("safFileName", "saf_file_name"),
    ("service", "service"),
    ("downloadedAt", "downloaded_at"),
    ("isrc", "isrc"),
    ("spotifyId", "spotify_id"),
    ("trackNumber", "track_number"),
    ("totalTracks", "total_tracks"),
    ("discNumber", "disc_number"),
    ("totalDiscs", "total_discs"),
    ("duration", "duration"),
    ("releaseDate", "release_date"),
    ("quality", "quality"),
    ("bitDepth", "bit_depth"),
    ("sampleRate", "sample_rate"),
    ("bitrate", "bitrate"),
    ("format", "format"),
    ("genre", "genre"),
    ("composer", "composer"),
    ("label", "label"),
    ("copyright", "copyright"),
];

fn err(context: &str, error: impl std::fmt::Display) -> String {
    format!("{context}: {error}")
}
fn required<'a>(request: &'a Value, field: &str) -> Result<&'a str, String> {
    request[field]
        .as_str()
        .filter(|v| !v.is_empty())
        .ok_or_else(|| format!("Backup requires {field}"))
}
fn output_path<'a>(request: &'a Value, field: &str) -> Result<&'a str, String> {
    let path = required(request, field)?;
    if !Path::new(path).is_absolute() {
        return Err("Backup output path must be absolute".into());
    }
    Ok(path)
}
fn open(request: &Value, writable: bool) -> Result<Connection, String> {
    let path = required(request, "history_path")?;
    if !Path::new(path).is_absolute()
        || Path::new(path).file_name().and_then(|v| v.to_str()) != Some("history.db")
    {
        return Err("Backup database must reference existing history.db".into());
    }
    let db = Connection::open_with_flags(
        path,
        if writable {
            OpenFlags::SQLITE_OPEN_READ_WRITE
        } else {
            OpenFlags::SQLITE_OPEN_READ_ONLY
        },
    )
    .map_err(|e| err("open History backup", e))?;
    db.busy_timeout(Duration::from_secs(5))
        .map_err(|e| err("History timeout", e))?;
    let version: i64 = db
        .pragma_query_value(None, "user_version", |row| row.get(0))
        .map_err(|e| err("History schema", e))?;
    // v18 adds the independent offline copy's network origin.
    if version != 18 && version != 17 && version != 16 {
        return Err(format!(
            "History schema v{version} is incompatible with native v16/v17/v18"
        ));
    }
    db.execute_batch("PRAGMA recursive_triggers=ON; PRAGMA synchronous=NORMAL;")
        .map_err(|e| err("configure History backup", e))?;
    Ok(db)
}

pub(crate) fn execute(request: &Value, check: Check<'_>) -> Result<Value, String> {
    check()?;
    match required(request, "operation")? {
        "backup_history_export" => export(request, check),
        "backup_history_import" => import(request, check),
        "backup_collections_import" => collections::import(request, check),
        "backup_split_legacy" => legacy::split(request, check),
        "backup_archive_write" => archive::write(request, check),
        "backup_archive_read" => archive::read(request, check),
        _ => Err("Unknown native backup operation".into()),
    }
}

fn scalar(value: &Value) -> Result<rusqlite::types::Value, String> {
    use rusqlite::types::Value as Sql;
    match value {
        Value::Null => Ok(Sql::Null),
        Value::String(s) => Ok(Sql::Text(s.clone())),
        Value::Bool(v) => Ok(Sql::Integer(i64::from(*v))),
        Value::Number(n) => n
            .as_i64()
            .map(Sql::Integer)
            .or_else(|| n.as_f64().map(Sql::Real))
            .ok_or("Invalid backup number".into()),
        _ => Err("Backup storage field cannot contain an object or array".into()),
    }
}
fn text<'a>(row: &'a Value, key: &str) -> Result<&'a str, String> {
    match &row[key] {
        Value::Null => Ok(""),
        Value::String(s) => Ok(s),
        _ => Err(format!("Backup {key} must be a string")),
    }
}
fn number(value: &Value) -> Option<i64> {
    value
        .as_i64()
        .or_else(|| value.as_f64().filter(|v| v.is_finite()).map(|v| v as i64))
}
fn date(value: &str) -> Option<(String, i64)> {
    let parsed = dart_date::parse(value)?;
    Some((
        dart_date::iso_utc(&parsed.instant),
        parsed.instant.timestamp_millis(),
    ))
}
fn replaygain(row: &Value) -> bool {
    if row["hasReplayGain"] == true || row["hasReplayGain"].as_f64() == Some(1.0) {
        return true;
    }
    ["replaygain_track_gain", "replaygain_album_gain"]
        .iter()
        .any(|key| {
            let s = match &row[*key] {
                Value::String(s) => s.clone(),
                Value::Number(n) => n.to_string(),
                _ => return false,
            };
            let trimmed = dart_trim(&s);
            let value = if trimmed.to_ascii_lowercase().ends_with("db") {
                dart_trim(&trimmed[..trimmed.len() - 2])
            } else {
                trimmed
            };
            value.parse::<f64>().is_ok_and(f64::is_finite)
        })
}

fn encode(row: &Value) -> Result<Map<String, Value>, String> {
    if !row.is_object() {
        return Err("Backup history row must be an object".into());
    }
    for key in [
        "id",
        "trackName",
        "artistName",
        "albumName",
        "filePath",
        "service",
        "downloadedAt",
    ] {
        if !row[key].is_string() {
            return Err(format!("Backup history requires string {key}"));
        }
    }
    for key in ["lyricsMetadataScanVersion", "replayGainMetadataScanVersion"] {
        if !row[key].is_null() && !row[key].is_number() {
            return Err(format!("Backup {key} must be numeric"));
        }
    }
    let mut values = Map::new();
    for (key, column) in COLUMNS {
        values.insert((*column).into(), row[*key].clone());
    }
    let parsed_date = date(text(row, "downloadedAt")?);
    if let Some((date, _)) = &parsed_date {
        values.insert("downloaded_at".into(), date.clone().into());
    }
    for (key, column) in [
        ("safRepaired", "saf_repaired"),
        ("explicit", "explicit"),
        ("hasLyrics", "has_lyrics"),
    ] {
        values.insert(column.into(), i64::from(row[key] == true).into());
    }
    values.insert("has_replaygain".into(), i64::from(replaygain(row)).into());
    values.insert(
        "lyrics_metadata_scan_version".into(),
        number(&row["lyricsMetadataScanVersion"])
            .unwrap_or(i64::from(row.get("hasLyrics").is_some()))
            .into(),
    );
    values.insert(
        "replaygain_metadata_scan_version".into(),
        number(&row["replayGainMetadataScanVersion"])
            .unwrap_or(0)
            .into(),
    );
    let track = normalized(text(row, "trackName")?);
    let artist = normalized(text(row, "artistName")?);
    let album = normalized(text(row, "albumName")?);
    let album_artist = if dart_trim(text(row, "albumArtist")?).is_empty() {
        artist.clone()
    } else {
        normalized(text(row, "albumArtist")?)
    };
    let isrc = dart_upper(dart_trim(text(row, "isrc")?))
        .chars()
        .filter(|ch| *ch != '-' && !regex_whitespace(*ch))
        .collect::<String>();
    values.insert(
        "spotify_id_norm".into(),
        normalized(text(row, "spotifyId")?).into(),
    );
    values.insert("isrc_norm".into(), isrc.into());
    values.insert(
        "match_key".into(),
        if track.is_empty() {
            String::new()
        } else {
            format!("{track}|{artist}")
        }
        .into(),
    );
    values.insert("album_key".into(), format!("{album}|{album_artist}").into());
    values.insert(
        "search_text".into(),
        [&track, &artist, &album, &album_artist]
            .into_iter()
            .filter(|v| !v.is_empty())
            .cloned()
            .collect::<Vec<_>>()
            .join(" ")
            .into(),
    );
    for (column, value) in [
        ("sort_track", track),
        ("sort_artist", artist),
        ("sort_album", album),
        ("sort_album_artist", album_artist),
        ("sort_genre", normalized(text(row, "genre")?)),
        (
            "sort_release",
            dart_trim(text(row, "releaseDate")?).to_string(),
        ),
    ] {
        values.insert(column.into(), value.into());
    }
    values.insert(
        "sort_added".into(),
        parsed_date.map(|(_, time)| time).unwrap_or(0).into(),
    );
    Ok(values)
}

fn export(request: &Value, check: Check<'_>) -> Result<Value, String> {
    let db = open(request, false)?;
    let output = output_path(request, "ndjson_path")?;
    let file = OpenOptions::new()
        .create_new(true)
        .write(true)
        .open(output)
        .map_err(|e| err("create History export", e))?;
    let result = (|| {
        let mut writer = BufWriter::new(file);
        let mut statement = db
            .prepare("SELECT * FROM history ORDER BY sort_added DESC,id DESC")
            .map_err(|e| err("prepare History export", e))?;
        let columns = statement
            .column_names()
            .map(str::to_owned)
            .collect::<Vec<_>>();
        let mut rows = statement
            .query([])
            .map_err(|e| err("query History export", e))?;
        let mut count = 0_u64;
        let mut bytes = 0_u64;
        while let Some(row) = rows.next().map_err(|e| err("read History export", e))? {
            check()?;
            let mut stored = Map::new();
            for (index, column) in columns.iter().enumerate() {
                use rusqlite::types::ValueRef;
                let value = match row
                    .get_ref(index)
                    .map_err(|e| err("read History value", e))?
                {
                    ValueRef::Null => Value::Null,
                    ValueRef::Integer(n) => n.into(),
                    ValueRef::Real(n) => json!(n),
                    ValueRef::Text(v) => String::from_utf8(v.to_vec())
                        .map_err(|e| err("History UTF-8", e))?
                        .into(),
                    ValueRef::Blob(_) => {
                        return Err("History backup cannot encode binary column".into());
                    }
                };
                stored.insert(column.clone(), value);
            }
            let json = decode(&stored, request);
            let encoded = serde_json::to_vec(&json).map_err(|e| err("encode History export", e))?;
            bytes += encoded.len() as u64 + 1;
            if bytes > MAX_HISTORY_BYTES {
                return Err("History backup exceeds size limit".into());
            }
            writer
                .write_all(&encoded)
                .and_then(|_| writer.write_all(b"\n"))
                .map_err(|e| err("write History export", e))?;
            count += 1;
        }
        writer
            .flush()
            .and_then(|_| writer.get_ref().sync_all())
            .map_err(|e| err("publish History export", e))?;
        check()?;
        Ok(json!({"published":true,"count":count,"path":output}))
    })();
    if result.is_err() {
        let _ = fs::remove_file(output);
    }
    result
}

fn decode(stored: &Map<String, Value>, request: &Value) -> Map<String, Value> {
    let mut json = Map::new();
    for (key, column) in COLUMNS {
        json.insert(
            (*key).into(),
            stored.get(*column).cloned().unwrap_or(Value::Null),
        );
    }
    if request["platform"] == "ios"
        && let Some(documents) = request["documents_path"].as_str()
        && let Some(path) = json["filePath"].as_str()
    {
        json.insert("filePath".into(), rebase_ios(path, documents).into());
    }
    for (key, column) in [
        ("safRepaired", "saf_repaired"),
        ("explicit", "explicit"),
        ("hasLyrics", "has_lyrics"),
        ("hasReplayGain", "has_replaygain"),
    ] {
        json.insert(
            key.into(),
            (stored.get(column).and_then(Value::as_i64) == Some(1)).into(),
        );
    }
    for (key, column) in [
        ("lyricsMetadataScanVersion", "lyrics_metadata_scan_version"),
        (
            "replayGainMetadataScanVersion",
            "replaygain_metadata_scan_version",
        ),
    ] {
        json.insert(
            key.into(),
            stored
                .get(column)
                .filter(|v| !v.is_null())
                .cloned()
                .unwrap_or(json!(0)),
        );
    }
    json
}

fn rebase_ios(path: &str, documents: &str) -> String {
    use std::sync::OnceLock;
    static ROOT: OnceLock<regex::Regex> = OnceLock::new();
    let regex=ROOT.get_or_init(||regex::Regex::new(r"(?i)^(?:/private)?/var/mobile/Containers/Data/Application/[A-F0-9\-]+|^/[^\n]+/Library/Developer/CoreSimulator/Devices/[A-F0-9\-]+/data/Containers/Data/Application/[A-F0-9\-]+").expect("iOS container pattern"));
    let Some(current) = regex.find(documents) else {
        return path.into();
    };
    let Some(previous) = regex.find(path) else {
        return path.into();
    };
    if &documents[current.end()..] != "/Documents" || !path[previous.end()..].starts_with('/') {
        return path.into();
    }
    let suffix = &path[previous.end()..];
    if suffix.split('/').any(|v| v == "..")
        || ![
            "/Documents",
            "/Library/Application Support",
            "/Library/Caches",
        ]
        .iter()
        .any(|root| suffix == *root || suffix.starts_with(&format!("{root}/")))
    {
        return path.into();
    }
    format!("{}{suffix}", &documents[..current.end()])
}

fn import(request: &Value, check: Check<'_>) -> Result<Value, String> {
    let mut db = open(request, true)?;
    let input = required(request, "ndjson_path")?;
    if fs::metadata(input)
        .map_err(|e| err("History backup metadata", e))?
        .len()
        > MAX_HISTORY_BYTES
    {
        return Err("History backup exceeds size limit".into());
    }
    let columns = db
        .prepare("PRAGMA table_info(history)")
        .map_err(|e| err("History columns", e))?
        .query_map([], |row| row.get::<_, String>(1))
        .map_err(|e| err("History columns", e))?
        .collect::<Result<Vec<_>, _>>()
        .map_err(|e| err("History columns", e))?;
    let column_list = columns
        .iter()
        .map(|v| format!("\"{}\"", v.replace('"', "\"\"")))
        .collect::<Vec<_>>()
        .join(",");
    db.execute_batch("CREATE TEMP TABLE native_backup_stage AS SELECT * FROM history WHERE 0;
        CREATE UNIQUE INDEX native_backup_stage_id ON native_backup_stage(id);
        CREATE TEMP TABLE native_backup_keys(item_id TEXT NOT NULL,path_key TEXT NOT NULL,PRIMARY KEY(item_id,path_key));").map_err(|e|err("stage History restore",e))?;
    let insert = format!(
        "INSERT OR REPLACE INTO native_backup_stage({column_list}) VALUES({})",
        vec!["?"; columns.len()].join(",")
    );
    let android = request["platform"] == "android";
    let mut count = 0_u64;
    let mut batch = Vec::with_capacity(BATCH_SIZE);
    let mut flush = |batch: &mut Vec<Value>| -> Result<(), String> {
        check()?;
        let transaction = db
            .transaction()
            .map_err(|e| err("stage restore transaction", e))?;
        for row in batch.drain(..) {
            check()?;
            let values = encode(&row)?;
            let fields = columns
                .iter()
                .map(|column| scalar(values.get(column).unwrap_or(&Value::Null)))
                .collect::<Result<Vec<_>, _>>()?;
            transaction
                .prepare_cached(&insert)
                .map_err(|e| err("prepare restore row", e))?
                .execute(params_from_iter(fields))
                .map_err(|e| err("stage restore row", e))?;
            let id = text(&row, "id")?;
            transaction
                .execute("DELETE FROM native_backup_keys WHERE item_id=?", [id])
                .map_err(|e| err("replace restore keys", e))?;
            for key in build(text(&row, "filePath")?, android)? {
                transaction
                    .prepare_cached("INSERT OR IGNORE INTO native_backup_keys VALUES(?,?)")
                    .map_err(|e| err("prepare restore keys", e))?
                    .execute(params![id, key])
                    .map_err(|e| err("stage restore keys", e))?;
            }
        }
        transaction
            .commit()
            .map_err(|e| err("commit restore staging", e))
    };
    let mut reader = BufReader::new(File::open(input).map_err(|e| err("open History backup", e))?);
    loop {
        check()?;
        let mut line = String::new();
        let bytes = reader
            .by_ref()
            .take(MAX_ROW_BYTES + 1)
            .read_line(&mut line)
            .map_err(|e| err("read History backup", e))?;
        if bytes == 0 {
            break;
        }
        if bytes as u64 > MAX_ROW_BYTES {
            return Err("History backup row exceeds size limit".into());
        }
        if dart_trim(&line).is_empty() {
            continue;
        }
        let row: Value =
            serde_json::from_str(&line).map_err(|e| err("decode History backup", e))?;
        // Legacy archive restore skipped JSON values that were not objects.
        if !row.is_object() {
            continue;
        }
        batch.push(row);
        count += 1;
        if batch.len() == BATCH_SIZE {
            flush(&mut batch)?;
        }
    }
    flush(&mut batch)?;
    if let Some(expected) = request["expected_count"].as_u64()
        && count != expected
    {
        return Err(format!(
            "History backup count mismatch: {count}, expected {expected}"
        ));
    }
    check()?;
    let transaction = db
        .transaction_with_behavior(TransactionBehavior::Immediate)
        .map_err(|e| err("begin History restore", e))?;
    let replace = request["mode"].as_str().unwrap_or("replace") == "replace";
    if replace {
        transaction
            .execute_batch("DELETE FROM history_path_keys; DELETE FROM history;")
            .map_err(|e| err("clear restored History", e))?;
    } else if request["mode"] != "merge" {
        return Err("Invalid History restore mode".into());
    } else {
        transaction.execute("DELETE FROM history_path_keys WHERE item_id IN(SELECT id FROM native_backup_stage)",[]).map_err(|e|err("replace restored History keys",e))?;
    }
    check()?;
    transaction.execute(&format!("INSERT OR REPLACE INTO history({column_list}) SELECT {column_list} FROM native_backup_stage"),[]).map_err(|e|err("swap restored History",e))?;
    transaction.execute("INSERT OR IGNORE INTO history_path_keys SELECT item_id,path_key FROM native_backup_keys",[]).map_err(|e|err("swap restored keys",e))?;
    let imported: i64 = transaction
        .query_row("SELECT COUNT(*) FROM native_backup_stage", [], |row| {
            row.get(0)
        })
        .map_err(|e| err("count restored History", e))?;
    check()?;
    transaction
        .commit()
        .map_err(|e| err("commit History restore", e))?;
    Ok(json!({"committed":true,"count":count,"imported":imported}))
}

#[cfg(test)]
mod tests;
