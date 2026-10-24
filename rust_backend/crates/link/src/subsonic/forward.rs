//! Subsonic calls the app answers (contract section 6.2): playlists, stars,
//! scrobbles and the play queue. Song ids are expanded into `SongInfo`
//! before forwarding; ids in replies are expanded into full objects, and
//! ids the catalog no longer has are dropped.

use super::objects::{self, iso8601, put, put_some};
use super::{Failure, Payload, code, flag, number, payload, required};
use crate::catalog::Catalog;
use crate::types::{HostError, Shared, SubsonicRequest};
use serde_json::{Map, Value, json};
use std::collections::BTreeSet;

/// Owner reported for playlists and the play queue.
const OWNER: &str = "mornye";

const METHODS: &[&str] = &[
    "getPlaylists",
    "getPlaylist",
    "createPlaylist",
    "updatePlaylist",
    "deletePlaylist",
    "star",
    "unstar",
    "getStarred",
    "getStarred2",
    "scrobble",
    "getPlayQueue",
    "savePlayQueue",
];

pub(super) fn handles(method: &str) -> bool {
    METHODS.contains(&method)
}

pub(super) async fn call(
    shared: &Shared,
    catalog: &Catalog,
    request: &SubsonicRequest,
) -> Result<Payload, Failure> {
    match request.method.as_str() {
        "getPlaylists" => {
            let reply = ask(shared, request, "subsonic/getPlaylists", json!({})).await?;
            let playlists: Vec<Value> = reply
                .get("playlists")
                .and_then(Value::as_array)
                .map(|list| {
                    list.iter()
                        .filter_map(|item| playlist(catalog, item, false))
                        .collect()
                })
                .unwrap_or_default();
            Ok(payload("playlists", json!({ "playlist": playlists })))
        }
        "getPlaylist" => {
            let id = required(request, "id")?;
            let reply = ask(shared, request, "subsonic/getPlaylist", json!({ "id": id })).await?;
            playlist_reply(catalog, &reply)
        }
        "createPlaylist" => {
            let playlist_id = request.param("playlistId").filter(|id| !id.is_empty());
            let name = request.param("name").filter(|name| !name.is_empty());
            if playlist_id.is_none() && name.is_none() {
                return Err(Failure::missing("name"));
            }
            let mut args = Map::new();
            put_some(&mut args, "playlistId", playlist_id);
            put_some(&mut args, "name", name);
            put(
                &mut args,
                "songs",
                song_infos(catalog, &request.params_all("songId")),
            );
            let reply = ask(
                shared,
                request,
                "subsonic/createPlaylist",
                Value::Object(args),
            )
            .await?;
            playlist_reply(catalog, &reply)
        }
        "updatePlaylist" => {
            let playlist_id = required(request, "playlistId")?;
            let mut args = Map::new();
            put(&mut args, "playlistId", playlist_id);
            put_some(&mut args, "name", request.param("name"));
            put_some(&mut args, "comment", request.param("comment"));
            put(
                &mut args,
                "songsToAdd",
                song_infos(catalog, &request.params_all("songIdToAdd")),
            );
            let removed: Vec<u64> = request
                .params_all("songIndexToRemove")
                .into_iter()
                .filter_map(|index| index.trim().parse().ok())
                .collect();
            put(&mut args, "songIndexesToRemove", removed);
            ask(
                shared,
                request,
                "subsonic/updatePlaylist",
                Value::Object(args),
            )
            .await?;
            Ok(Payload::new())
        }
        "deletePlaylist" => {
            let id = required(request, "id")?;
            ask(
                shared,
                request,
                "subsonic/deletePlaylist",
                json!({ "id": id }),
            )
            .await?;
            Ok(Payload::new())
        }
        "star" | "unstar" => {
            let args = star_args(catalog, request)?;
            let op = format!("subsonic/{}", request.method);
            ask(shared, request, &op, args).await?;
            Ok(Payload::new())
        }
        "getStarred" | "getStarred2" => {
            let legacy = request.method == "getStarred";
            let starred = starred(shared, catalog, request).await?;
            let artists: Vec<Value> = starred
                .artists
                .iter()
                .map(|artist| Value::Object(objects::artist(catalog, *artist)))
                .collect();
            let albums: Vec<Value> = starred
                .albums
                .iter()
                .map(|album| {
                    if legacy {
                        objects::album_dir(catalog, *album)
                    } else {
                        Value::Object(objects::album_id3(catalog, *album))
                    }
                })
                .collect();
            let songs: Vec<Value> = starred
                .songs
                .iter()
                .map(|song| objects::song(catalog, *song))
                .collect();
            let key = if legacy { "starred" } else { "starred2" };
            Ok(payload(
                key,
                json!({ "artist": artists, "album": albums, "song": songs }),
            ))
        }
        "scrobble" => {
            let ids = request.params_all("id");
            if ids.is_empty() {
                return Err(Failure::missing("id"));
            }
            let times = request.params_all("time");
            let now = now_ms();
            let mut songs = Vec::new();
            let mut times_ms = Vec::new();
            for (position, id) in ids.iter().enumerate() {
                let Some(index) = catalog.song_index(id) else {
                    continue;
                };
                songs.push(song_info(catalog, index));
                times_ms.push(
                    times
                        .get(position)
                        .and_then(|time| time.trim().parse::<i64>().ok())
                        .unwrap_or(now),
                );
            }
            if songs.is_empty() {
                return Err(Failure::not_found("Song"));
            }
            let args = json!({
                "songs": songs,
                "timesMs": times_ms,
                "submission": flag(request, "submission").unwrap_or(true),
            });
            ask(shared, request, "subsonic/scrobble", args).await?;
            Ok(Payload::new())
        }
        "getPlayQueue" => {
            let reply = ask(shared, request, "subsonic/getPlayQueue", json!({})).await?;
            let songs = known_songs(catalog, reply.get("songIds"));
            if songs.is_empty() {
                return Ok(Payload::new());
            }
            let mut queue = Map::new();
            let entries: Vec<Value> = songs
                .iter()
                .map(|song| objects::song(catalog, *song))
                .collect();
            put(&mut queue, "entry", entries);
            put_some(
                &mut queue,
                "current",
                text(reply.get("currentId")).filter(|id| catalog.song_index(id).is_some()),
            );
            put(
                &mut queue,
                "position",
                integer(reply.get("positionMs")).unwrap_or(0).max(0),
            );
            put(&mut queue, "username", OWNER);
            put(
                &mut queue,
                "changed",
                iso8601(integer(reply.get("changedMs")).unwrap_or_else(now_ms)),
            );
            put(
                &mut queue,
                "changedBy",
                text(reply.get("changedBy")).unwrap_or_default(),
            );
            Ok(payload("playQueue", Value::Object(queue)))
        }
        "savePlayQueue" => {
            let mut args = Map::new();
            put(
                &mut args,
                "songs",
                song_infos(catalog, &request.params_all("id")),
            );
            put_some(
                &mut args,
                "currentId",
                request.param("current").filter(|id| !id.is_empty()),
            );
            put(
                &mut args,
                "positionMs",
                number::<i64>(request, "position").unwrap_or(0).max(0),
            );
            ask(
                shared,
                request,
                "subsonic/savePlayQueue",
                Value::Object(args),
            )
            .await?;
            Ok(Payload::new())
        }
        _ => Err(Failure::new(code::GENERIC, "not implemented")),
    }
}

/// Starred items as catalog indexes.
pub(super) struct Starred {
    pub(super) songs: Vec<usize>,
    pub(super) albums: Vec<usize>,
    pub(super) artists: Vec<usize>,
}

/// Asks the app for starred ids (`getStarred`, `getStarred2` and the
/// `starred` album list share one op).
pub(super) async fn starred(
    shared: &Shared,
    catalog: &Catalog,
    request: &SubsonicRequest,
) -> Result<Starred, Failure> {
    let reply = ask(shared, request, "subsonic/getStarred", json!({})).await?;
    let ids = |key: &str| -> Vec<&str> {
        reply
            .get(key)
            .and_then(Value::as_array)
            .map(|list| list.iter().filter_map(Value::as_str).collect())
            .unwrap_or_default()
    };
    Ok(Starred {
        songs: known_songs(catalog, reply.get("songIds")),
        albums: ids("albumIds")
            .into_iter()
            .filter_map(|id| catalog.album_index(id))
            .collect(),
        // The app may name artists instead of computing ids, so the id rule
        // stays in one place.
        artists: ids("artistIds")
            .into_iter()
            .filter_map(|id| catalog.artist_index(id))
            .chain(
                ids("artistNames")
                    .into_iter()
                    .filter_map(|name| catalog.artist_index_by_name(name)),
            )
            .collect::<BTreeSet<_>>()
            .into_iter()
            .collect(),
    })
}

/// Forwards `op` for the calling device; app errors map to Subsonic codes.
async fn ask(
    shared: &Shared,
    request: &SubsonicRequest,
    op: &str,
    args: Value,
) -> Result<Value, Failure> {
    shared
        .host
        .request(op, &request.device.device_id, args)
        .await
        .map_err(host_failure)
}

pub(super) fn host_failure(error: HostError) -> Failure {
    let code = match error.code.as_str() {
        "not_found" => code::NOT_FOUND,
        "invalid" => code::MISSING_PARAMETER,
        _ => code::GENERIC,
    };
    let message = if error.message.is_empty() {
        error.code
    } else {
        error.message
    };
    Failure::new(code, message)
}

/// `star`/`unstar` args: `id` may name a song, album or artist; `albumId`
/// and `artistId` name albums and artists.
fn star_args(catalog: &Catalog, request: &SubsonicRequest) -> Result<Value, Failure> {
    let ids = request.params_all("id");
    let album_ids = request.params_all("albumId");
    let artist_ids = request.params_all("artistId");
    if ids.is_empty() && album_ids.is_empty() && artist_ids.is_empty() {
        return Err(Failure::missing("id"));
    }
    let mut songs = Vec::new();
    let mut albums = Vec::new();
    let mut artists = Vec::new();
    for id in ids {
        if let Some(index) = catalog.song_index(id) {
            songs.push(song_info(catalog, index));
        } else if let Some(index) = catalog.album_index(id) {
            albums.push(album_ref(catalog, index));
        } else if let Some(index) = catalog.artist_index(id) {
            artists.push(objects::artist_ref(catalog, index));
        }
    }
    albums.extend(
        album_ids
            .into_iter()
            .filter_map(|id| catalog.album_index(id))
            .map(|index| album_ref(catalog, index)),
    );
    artists.extend(
        artist_ids
            .into_iter()
            .filter_map(|id| catalog.artist_index(id))
            .map(|index| objects::artist_ref(catalog, index)),
    );
    if songs.is_empty() && albums.is_empty() && artists.is_empty() {
        return Err(Failure::not_found("Item"));
    }
    Ok(json!({ "songs": songs, "albums": albums, "artists": artists }))
}

fn album_ref(catalog: &Catalog, index: usize) -> Value {
    let album = &catalog.albums()[index];
    json!({ "id": album.id, "name": album.name, "artist": album.artist_name })
}

/// `SongInfo` for each known id, unknown ids dropped.
fn song_infos(catalog: &Catalog, ids: &[&str]) -> Vec<Value> {
    ids.iter()
        .filter_map(|id| catalog.song_index(id))
        .map(|index| song_info(catalog, index))
        .collect()
}

/// `SongInfo` (contract section 6.2).
pub(super) fn song_info(catalog: &Catalog, index: usize) -> Value {
    let song = &catalog.songs()[index];
    json!({
        "id": song.id,
        "title": song.title,
        "artist": song.artist,
        "album": song.album_name,
        "albumArtist": song.album_artist,
        "durationMs": song.duration_ms,
        "isrc": song.isrc,
        "matchKey": song.match_key,
        "path": song.path.to_string_lossy(),
    })
}

/// `{"playlist": Playlist}` replies, rendered with entries.
fn playlist_reply(catalog: &Catalog, reply: &Value) -> Result<Payload, Failure> {
    let value = reply
        .get("playlist")
        .and_then(|item| playlist(catalog, item, true))
        .ok_or_else(|| Failure::new(code::GENERIC, "The app sent an invalid playlist"))?;
    Ok(payload("playlist", value))
}

/// A Subsonic playlist from the app's `Playlist`; `None` without an id.
fn playlist(catalog: &Catalog, item: &Value, entries: bool) -> Option<Value> {
    let id = text(item.get("id")).filter(|id| !id.is_empty())?;
    let songs = known_songs(catalog, item.get("songIds"));
    let created = integer(item.get("createdMs"));
    let changed = integer(item.get("changedMs")).or(created).unwrap_or(0);
    let mut value = Map::new();
    put(&mut value, "id", id);
    put(
        &mut value,
        "name",
        text(item.get("name")).unwrap_or_default(),
    );
    put_some(&mut value, "comment", text(item.get("comment")));
    put(&mut value, "owner", OWNER);
    put(&mut value, "public", false);
    put(&mut value, "songCount", songs.len());
    let duration: u64 = songs
        .iter()
        .filter_map(|song| catalog.songs()[*song].duration_secs())
        .sum();
    put(&mut value, "duration", duration);
    put(&mut value, "created", iso8601(created.unwrap_or(changed)));
    put(&mut value, "changed", iso8601(changed));
    put_some(
        &mut value,
        "coverArt",
        songs.iter().find_map(|song| catalog.song_cover_id(*song)),
    );
    if entries {
        let entries: Vec<Value> = songs
            .iter()
            .map(|song| objects::song(catalog, *song))
            .collect();
        put(&mut value, "entry", entries);
    }
    Some(Value::Object(value))
}

/// Catalog indexes of the string ids in `value`, unknown ids dropped.
fn known_songs(catalog: &Catalog, value: Option<&Value>) -> Vec<usize> {
    value
        .and_then(Value::as_array)
        .map(|ids| {
            ids.iter()
                .filter_map(Value::as_str)
                .filter_map(|id| catalog.song_index(id))
                .collect()
        })
        .unwrap_or_default()
}

/// A string, or a number rendered as one.
fn text(value: Option<&Value>) -> Option<String> {
    match value? {
        Value::String(text) => Some(text.clone()),
        Value::Number(number) => Some(number.to_string()),
        _ => None,
    }
}

fn integer(value: Option<&Value>) -> Option<i64> {
    let value = value?;
    value
        .as_i64()
        .or_else(|| value.as_f64().map(|value| value as i64))
}

fn now_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |elapsed| {
            i64::try_from(elapsed.as_millis()).unwrap_or(i64::MAX)
        })
}
