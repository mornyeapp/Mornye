//! Collection rows stay on the IO worker until a bounded Dart hydration worker
//! consumes their NDJSON file. The bridge returns only a path and row counts.
use rusqlite::{Connection, OpenFlags, Transaction, types::ValueRef};
use serde_json::{Map, Value, json};
use std::{
    io::{BufWriter, Write},
    path::Path,
    time::Duration,
};

type Check<'a> = &'a dyn Fn() -> Result<(), String>;

const SNAPSHOT_QUERIES: &[(&str, &str)] = &[
    (
        "wishlist",
        "SELECT * FROM wishlist_tracks ORDER BY added_at DESC,rowid DESC",
    ),
    (
        "loved",
        "SELECT * FROM loved_tracks ORDER BY added_at DESC,rowid DESC",
    ),
    (
        "playlist",
        "SELECT p.*, CASE WHEN p.cover_image_path IS NULL OR p.cover_image_path='' THEN (
        SELECT pt.track_json FROM playlist_tracks pt WHERE pt.playlist_id=p.id
        ORDER BY pt.added_at ASC,pt.rowid ASC LIMIT 1
      ) END AS preview_track_json FROM playlists p ORDER BY p.created_at DESC,p.rowid DESC",
    ),
    (
        "membership",
        "SELECT playlist_id,track_key FROM playlist_tracks ORDER BY playlist_id ASC,rowid ASC",
    ),
    (
        "artist",
        "SELECT * FROM favorite_artists ORDER BY added_at DESC,rowid DESC",
    ),
];

fn required<'a>(request: &'a Value, field: &str) -> Result<&'a str, String> {
    request[field]
        .as_str()
        .filter(|value| !value.is_empty())
        .ok_or_else(|| format!("Collection snapshot requires {field}"))
}

fn write_rows(
    transaction: &Transaction<'_>,
    writer: &mut impl Write,
    kind: &str,
    query: &str,
    playlist_id: Option<&str>,
    check: Check<'_>,
) -> Result<u64, String> {
    check()?;
    let mut statement = transaction.prepare(query).map_err(|e| e.to_string())?;
    let columns = statement
        .column_names()
        .map(str::to_owned)
        .collect::<Vec<_>>();
    let mut rows = if let Some(id) = playlist_id {
        statement.query([id])
    } else {
        statement.query([])
    }
    .map_err(|e| e.to_string())?;
    let mut count = 0;
    while let Some(row) = rows.next().map_err(|e| e.to_string())? {
        check()?;
        let mut values = Map::new();
        for (index, name) in columns.iter().enumerate() {
            let value = match row.get_ref(index).map_err(|e| e.to_string())? {
                ValueRef::Null => Value::Null,
                ValueRef::Integer(value) => Value::from(value),
                ValueRef::Real(value) => Value::from(value),
                ValueRef::Text(value) => {
                    Value::from(std::str::from_utf8(value).map_err(|e| e.to_string())?)
                }
                ValueRef::Blob(value) => {
                    Value::Array(value.iter().copied().map(Value::from).collect())
                }
            };
            values.insert(name.clone(), value);
        }
        serde_json::to_writer(&mut *writer, &json!({"kind":kind,"row":values}))
            .map_err(|e| format!("write collection snapshot: {e}"))?;
        writer.write_all(b"\n").map_err(|e| e.to_string())?;
        count += 1;
    }
    Ok(count)
}

pub(crate) fn execute(request: &Value, check: Check<'_>) -> Result<Value, String> {
    check()?;
    if required(request, "operation")? != "collections_snapshot" {
        return Err("Unknown native collection operation".into());
    }
    let database_path = Path::new(required(request, "collections_path")?);
    if !database_path.is_absolute()
        || database_path.file_name().and_then(|name| name.to_str())
            != Some("library_collections.db")
    {
        return Err("Collection snapshot requires existing library_collections.db".into());
    }
    let output_path = Path::new(required(request, "output_path")?);
    if !output_path.is_absolute() {
        return Err("Collection snapshot output path must be absolute".into());
    }
    let mut db = Connection::open_with_flags(database_path, OpenFlags::SQLITE_OPEN_READ_ONLY)
        .map_err(|e| format!("open collection snapshot: {e}"))?;
    db.busy_timeout(Duration::from_secs(5))
        .map_err(|e| e.to_string())?;
    let transaction = db.transaction().map_err(|e| e.to_string())?;
    let version: i64 = transaction
        .pragma_query_value(None, "user_version", |row| row.get(0))
        .map_err(|e| e.to_string())?;
    if version != 2 {
        return Err(format!(
            "Collection schema v{version} is incompatible with native v2"
        ));
    }
    let mut staged = tempfile::NamedTempFile::new_in(
        output_path
            .parent()
            .ok_or("Collection snapshot requires output parent")?,
    )
    .map_err(|e| e.to_string())?;
    let mut counts = Map::new();
    {
        let mut writer = BufWriter::with_capacity(64 * 1024, staged.as_file_mut());
        if let Some(id) = request.get("playlist_id") {
            let id = id
                .as_str()
                .ok_or("Collection playlist_id must be a string")?;
            counts.insert(
                "playlist_track".into(),
                Value::from(write_rows(
                    &transaction,
                    &mut writer,
                    "playlist_track",
                    "SELECT * FROM playlist_tracks WHERE playlist_id=?
                ORDER BY added_at ASC,rowid ASC",
                    Some(id),
                    check,
                )?),
            );
        } else {
            for (kind, sql) in SNAPSHOT_QUERIES {
                counts.insert(
                    (*kind).into(),
                    Value::from(write_rows(
                        &transaction,
                        &mut writer,
                        kind,
                        sql,
                        None,
                        check,
                    )?),
                );
            }
        }
        writer.flush().map_err(|e| e.to_string())?;
    }
    transaction.commit().map_err(|e| e.to_string())?;
    check()?;
    // Never replace an existing result. RAII removes partial files on SQL, IO,
    // schema or cancellation errors before this atomic publication.
    staged
        .persist_noclobber(output_path)
        .map_err(|e| e.to_string())?;
    Ok(json!({"rows_path":output_path,"counts":counts,"published":true,"committed":true}))
}

#[cfg(test)]
mod tests;
