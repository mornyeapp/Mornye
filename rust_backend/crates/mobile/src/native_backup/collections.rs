//! Dart prepares its exact JSON/date codec on a worker. SQLite stages ordered
//! commands locally, then publishes all collections in one short transaction.
use super::{Check, MAX_HISTORY_BYTES, MAX_ROW_BYTES, err, required};
use rusqlite::{Connection, OpenFlags, TransactionBehavior, params_from_iter};
use serde_json::{Value, json};
use std::{
    fs::File,
    io::{BufRead, BufReader, Read},
    path::Path,
    time::Duration,
};

struct Table {
    kind: &'static str,
    name: &'static str,
    columns: &'static [&'static str],
    keys: &'static str,
    insert_sql: &'static str,
}

const TABLES: &[Table] = &[
    Table {
        kind: "wishlist",
        name: "wishlist_tracks",
        columns: &["track_key", "track_json", "added_at"],
        keys: "track_key",
        insert_sql: "INSERT OR REPLACE INTO restore_wishlist_tracks(track_key,track_json,added_at) VALUES(?,?,?)",
    },
    Table {
        kind: "loved",
        name: "loved_tracks",
        columns: &["track_key", "track_json", "added_at"],
        keys: "track_key",
        insert_sql: "INSERT OR REPLACE INTO restore_loved_tracks(track_key,track_json,added_at) VALUES(?,?,?)",
    },
    Table {
        kind: "artist",
        name: "favorite_artists",
        columns: &["artist_key", "artist_json", "added_at"],
        keys: "artist_key",
        insert_sql: "INSERT OR REPLACE INTO restore_favorite_artists(artist_key,artist_json,added_at) VALUES(?,?,?)",
    },
    Table {
        kind: "playlist",
        name: "playlists",
        columns: &["id", "name", "cover_image_path", "created_at", "updated_at"],
        keys: "id",
        insert_sql: "INSERT OR REPLACE INTO restore_playlists(id,name,cover_image_path,created_at,updated_at) VALUES(?,?,?,?,?)",
    },
    Table {
        kind: "playlist_track",
        name: "playlist_tracks",
        columns: &["playlist_id", "track_key", "track_json", "added_at"],
        keys: "playlist_id,track_key",
        insert_sql: "INSERT OR REPLACE INTO restore_playlist_tracks(playlist_id,track_key,track_json,added_at) VALUES(?,?,?,?)",
    },
];

fn stage_batch(db: &mut Connection, rows: &[Value], check: Check<'_>) -> Result<(), String> {
    let transaction = db
        .transaction()
        .map_err(|e| err("stage collection transaction", e))?;
    for row in rows {
        check()?;
        let kind = required(row, "kind")?;
        let table = TABLES
            .iter()
            .find(|table| table.kind == kind)
            .ok_or("Unknown collection restore command")?;
        let values = row["values"]
            .as_object()
            .ok_or("Collection restore values must be an object")?;
        let fields = table
            .columns
            .iter()
            .map(|column| match values.get(*column) {
                Some(Value::String(value)) => Ok(rusqlite::types::Value::Text(value.clone())),
                None | Some(Value::Null) if *column == "cover_image_path" => {
                    Ok(rusqlite::types::Value::Null)
                }
                _ => Err(format!("Collection restore requires string {column}")),
            })
            .collect::<Result<Vec<_>, _>>()?;
        // REPLACE on a playlist in the original schema cascades old members.
        // Temporary staging has no FK triggers, so retain that behavior here.
        if table.kind == "playlist" {
            transaction
                .prepare_cached("DELETE FROM restore_playlist_tracks WHERE playlist_id=?")
                .map_err(|e| err("prepare collection member reset", e))?
                .execute([&fields[0]])
                .map_err(|e| err("stage collection member reset", e))?;
        }
        transaction
            .prepare_cached(table.insert_sql)
            .map_err(|e| err("prepare collection restore", e))?
            .execute(params_from_iter(fields))
            .map_err(|e| err("stage collection restore", e))?;
    }
    check()?;
    transaction
        .commit()
        .map_err(|e| err("commit collection staging", e))
}

pub(super) fn import(request: &Value, check: Check<'_>) -> Result<Value, String> {
    check()?;
    let path = required(request, "collections_path")?;
    if !Path::new(path).is_absolute()
        || Path::new(path).file_name().and_then(|name| name.to_str())
            != Some("library_collections.db")
    {
        return Err("Collection restore requires existing library_collections.db".into());
    }
    let mut db = Connection::open_with_flags(path, OpenFlags::SQLITE_OPEN_READ_WRITE)
        .map_err(|e| err("open collection restore", e))?;
    db.busy_timeout(Duration::from_secs(5))
        .map_err(|e| err("collection restore timeout", e))?;
    let version: i64 = db
        .pragma_query_value(None, "user_version", |row| row.get(0))
        .map_err(|e| err("collection restore schema", e))?;
    if version != 2 {
        return Err(format!(
            "Collection schema v{version} is incompatible with native v2"
        ));
    }
    db.execute_batch(
        "PRAGMA foreign_keys=ON; PRAGMA recursive_triggers=ON; PRAGMA synchronous=NORMAL;",
    )
    .map_err(|e| err("configure collection restore", e))?;
    for table in TABLES {
        db.execute_batch(&format!(
            "CREATE TEMP TABLE restore_{0} AS SELECT {1} FROM main.{0} WHERE 0;
             CREATE UNIQUE INDEX restore_{0}_keys ON restore_{0}({2});",
            table.name,
            table.columns.join(","),
            table.keys,
        ))
        .map_err(|e| err("create collection restore staging", e))?;
    }

    let input_path = required(request, "ndjson_path")?;
    let input = File::open(input_path).map_err(|e| err("open collection commands", e))?;
    let metadata = input
        .metadata()
        .map_err(|e| err("inspect collection commands", e))?;
    if !metadata.is_file() || metadata.len() > MAX_HISTORY_BYTES {
        return Err("Collection commands exceed size limit or are not a file".into());
    }
    let expected = request["expected_count"]
        .as_u64()
        .ok_or("Collection restore requires expected_count")?;
    let mut reader = BufReader::new(input);
    let mut line = Vec::new();
    let mut batch = Vec::with_capacity(500);
    let mut count = 0_u64;
    loop {
        check()?;
        line.clear();
        let length = reader
            .by_ref()
            .take(MAX_ROW_BYTES + 1)
            .read_until(b'\n', &mut line)
            .map_err(|e| err("read collection command", e))?;
        if length == 0 {
            break;
        }
        if length as u64 > MAX_ROW_BYTES {
            return Err("Collection restore row exceeds size limit".into());
        }
        batch.push(serde_json::from_slice(&line).map_err(|e| err("decode collection command", e))?);
        count += 1;
        if batch.len() == 500 {
            stage_batch(&mut db, &batch, check)?;
            batch.clear();
        }
    }
    if !batch.is_empty() {
        stage_batch(&mut db, &batch, check)?;
    }
    if count != expected {
        return Err(format!(
            "Collection restore expected {expected} commands, found {count}"
        ));
    }
    check()?;
    let transaction = db
        .transaction_with_behavior(TransactionBehavior::Immediate)
        .map_err(|e| err("begin collection publication", e))?;
    for name in [
        "playlist_tracks",
        "playlists",
        "wishlist_tracks",
        "loved_tracks",
        "favorite_artists",
    ] {
        transaction
            .execute(&format!("DELETE FROM main.{name}"), [])
            .map_err(|e| err("replace collection", e))?;
        check()?;
    }
    for table in TABLES {
        transaction
            .execute(
                &format!(
                    "INSERT INTO main.{0}({1}) SELECT {1} FROM restore_{0} ORDER BY rowid",
                    table.name,
                    table.columns.join(","),
                ),
                [],
            )
            .map_err(|e| err("publish collection restore", e))?;
        check()?;
    }
    transaction
        .commit()
        .map_err(|e| err("commit collection restore", e))?;
    Ok(json!({"committed": true, "command_count": count}))
}

#[cfg(test)]
mod tests;
