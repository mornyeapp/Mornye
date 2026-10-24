//! OpenSubsonic objects built from the catalog: song `Child`, `AlbumID3`,
//! the legacy album directory `Child`, and artists.

use crate::catalog::{Catalog, VARIOUS_ARTISTS};
use serde_json::{Map, Value, json};

/// A song `Child` (OpenSubsonic fields included).
pub(crate) fn song(catalog: &Catalog, index: usize) -> Value {
    let song = &catalog.songs()[index];
    let album = &catalog.albums()[song.album];
    let artist = &catalog.artists()[song.artist_ref];
    let owner = &catalog.artists()[album.artist];
    let mut child = Map::new();
    put(&mut child, "id", song.id.as_str());
    put(&mut child, "parent", album.id.as_str());
    put(&mut child, "isDir", false);
    put(&mut child, "title", song.title.as_str());
    put(&mut child, "album", album.name.as_str());
    put(&mut child, "artist", song.artist.as_str());
    put(&mut child, "displayArtist", song.artist.as_str());
    put(
        &mut child,
        "artists",
        json!([{ "id": artist.id, "name": song.artist }]),
    );
    put(&mut child, "displayAlbumArtist", album.artist_name.as_str());
    put(
        &mut child,
        "albumArtists",
        json!([{ "id": owner.id, "name": album.artist_name }]),
    );
    put(&mut child, "albumId", album.id.as_str());
    put(&mut child, "artistId", artist.id.as_str());
    put_some(&mut child, "track", song.track);
    put_some(&mut child, "discNumber", song.disc);
    put_some(&mut child, "year", song.year);
    if let Some(genre) = &song.genre {
        put(&mut child, "genre", genre.as_str());
        put(&mut child, "genres", json!([{ "name": genre }]));
    }
    put_some(&mut child, "coverArt", catalog.song_cover_id(index));
    put_some(&mut child, "size", song.size);
    put(&mut child, "contentType", content_type(&song.suffix));
    if !song.suffix.is_empty() {
        put(&mut child, "suffix", song.suffix.as_str());
    }
    put_some(&mut child, "duration", song.duration_secs());
    put_some(&mut child, "bitRate", song.bit_rate);
    put_some(&mut child, "samplingRate", song.sample_rate);
    put_some(&mut child, "bitDepth", song.bit_depth);
    put_some(&mut child, "channelCount", song.channels);
    put(&mut child, "path", display_path(catalog, index));
    put_some(&mut child, "created", song.added_ms.map(iso8601));
    put(&mut child, "type", "music");
    put(&mut child, "mediaType", "song");
    put(&mut child, "isVideo", false);
    if let Some(isrc) = &song.isrc {
        put(&mut child, "isrc", json!([isrc]));
    }
    let mut gain = Map::new();
    put_some(&mut gain, "trackGain", song.track_gain);
    put_some(&mut gain, "albumGain", song.album_gain);
    put_some(&mut gain, "trackPeak", song.track_peak);
    put_some(&mut gain, "albumPeak", song.album_peak);
    if !gain.is_empty() {
        put(&mut child, "replayGain", gain);
    }
    put(
        &mut child,
        "explicitStatus",
        if song.explicit { "explicit" } else { "" },
    );
    Value::Object(child)
}

/// An `AlbumID3` without songs.
pub(crate) fn album_id3(catalog: &Catalog, index: usize) -> Map<String, Value> {
    let album = &catalog.albums()[index];
    let owner = &catalog.artists()[album.artist];
    let mut value = Map::new();
    put(&mut value, "id", album.id.as_str());
    put(&mut value, "name", album.name.as_str());
    put(&mut value, "artist", album.artist_name.as_str());
    put(&mut value, "artistId", owner.id.as_str());
    put(&mut value, "displayArtist", album.artist_name.as_str());
    put(
        &mut value,
        "artists",
        json!([{ "id": owner.id, "name": album.artist_name }]),
    );
    put_some(&mut value, "coverArt", catalog.album_cover_id(index));
    put(&mut value, "songCount", album.songs.len());
    put(&mut value, "duration", album.duration_secs);
    put(&mut value, "created", album_created(catalog, index));
    put_some(&mut value, "year", album.year);
    if let Some(genre) = &album.genre {
        put(&mut value, "genre", genre.as_str());
        put(&mut value, "genres", json!([{ "name": genre }]));
    }
    put(
        &mut value,
        "isCompilation",
        album.artist_name == VARIOUS_ARTISTS,
    );
    put(&mut value, "mediaType", "album");
    value
}

/// An `AlbumID3` with its songs (`getAlbum`).
pub(crate) fn album_with_songs(catalog: &Catalog, index: usize) -> Value {
    let mut value = album_id3(catalog, index);
    let songs = catalog.albums()[index]
        .songs
        .iter()
        .map(|member| song(catalog, *member))
        .collect();
    put(&mut value, "song", Value::Array(songs));
    Value::Object(value)
}

/// An album as a legacy directory `Child` (`getAlbumList`, `search2`,
/// artist directories).
pub(crate) fn album_dir(catalog: &Catalog, index: usize) -> Value {
    let album = &catalog.albums()[index];
    let owner = &catalog.artists()[album.artist];
    let mut value = Map::new();
    put(&mut value, "id", album.id.as_str());
    put(&mut value, "parent", owner.id.as_str());
    put(&mut value, "isDir", true);
    put(&mut value, "title", album.name.as_str());
    put(&mut value, "name", album.name.as_str());
    put(&mut value, "album", album.name.as_str());
    put(&mut value, "artist", album.artist_name.as_str());
    put(&mut value, "artistId", owner.id.as_str());
    put_some(&mut value, "year", album.year);
    put_some(&mut value, "genre", album.genre.as_deref());
    put_some(&mut value, "coverArt", catalog.album_cover_id(index));
    put(&mut value, "songCount", album.songs.len());
    put(&mut value, "duration", album.duration_secs);
    put(&mut value, "created", album_created(catalog, index));
    put(&mut value, "mediaType", "album");
    Value::Object(value)
}

/// An artist (`ArtistID3`, also used for the legacy `Artist`).
pub(crate) fn artist(catalog: &Catalog, index: usize) -> Map<String, Value> {
    let artist = &catalog.artists()[index];
    let mut value = Map::new();
    put(&mut value, "id", artist.id.as_str());
    put(&mut value, "name", artist.name.as_str());
    put_some(&mut value, "coverArt", catalog.artist_cover_id(index));
    put(&mut value, "albumCount", artist.browse_albums().len());
    value
}

/// `{"id","name"}` of an artist, for the star forward.
pub(crate) fn artist_ref(catalog: &Catalog, index: usize) -> Value {
    let artist = &catalog.artists()[index];
    json!({ "id": artist.id, "name": artist.name })
}

fn album_created(catalog: &Catalog, index: usize) -> String {
    iso8601(
        catalog.albums()[index]
            .added_ms
            .unwrap_or(catalog.generated_ms()),
    )
}

/// A relative display path, `<album artist>/<album>/<file name>`; the
/// absolute desktop path never leaves the server.
fn display_path(catalog: &Catalog, index: usize) -> String {
    let song = &catalog.songs()[index];
    let album = &catalog.albums()[song.album];
    let file = song
        .path
        .file_name()
        .map(|name| name.to_string_lossy().into_owned())
        .unwrap_or_else(|| format!("{}.{}", song.title, song.suffix));
    format!(
        "{}/{}/{}",
        path_part(&album.artist_name),
        path_part(&album.name),
        path_part(&file)
    )
}

fn path_part(text: &str) -> String {
    text.chars()
        .map(|c| if matches!(c, '/' | '\\') { '_' } else { c })
        .collect()
}

/// The MIME type for a file suffix.
pub(crate) fn content_type(suffix: &str) -> &'static str {
    match suffix {
        "mp3" => "audio/mpeg",
        "flac" => "audio/flac",
        "m4a" | "m4b" | "mp4" | "alac" => "audio/mp4",
        "aac" => "audio/aac",
        "ogg" | "oga" | "opus" => "audio/ogg",
        "wav" => "audio/wav",
        "aif" | "aiff" | "aifc" => "audio/aiff",
        "wv" => "audio/x-wavpack",
        "ape" => "audio/x-ape",
        "dsf" => "audio/x-dsf",
        "dff" => "audio/x-dff",
        "wma" => "audio/x-ms-wma",
        "mka" => "audio/x-matroska",
        "webm" => "audio/webm",
        "mpc" => "audio/x-musepack",
        "tta" => "audio/x-tta",
        _ => "application/octet-stream",
    }
}

/// ISO-8601 UTC with milliseconds, for example `2026-10-25T08:30:00.000Z`.
pub(crate) fn iso8601(ms: i64) -> String {
    let ms = ms.clamp(0, 253_402_300_799_999);
    let secs = ms / 1000;
    let (year, month, day) = civil_from_days(secs / 86_400);
    let time = secs % 86_400;
    format!(
        "{year:04}-{month:02}-{day:02}T{:02}:{:02}:{:02}.{:03}Z",
        time / 3600,
        time % 3600 / 60,
        time % 60,
        ms % 1000
    )
}

/// Gregorian date of a day count since 1970-01-01 (Howard Hinnant).
fn civil_from_days(days: i64) -> (i64, i64, i64) {
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let day = doy - (153 * mp + 2) / 5 + 1;
    let month = if mp < 10 { mp + 3 } else { mp - 9 };
    let year = yoe + era * 400 + i64::from(month <= 2);
    (year, month, day)
}

pub(crate) fn put(map: &mut Map<String, Value>, key: &str, value: impl Into<Value>) {
    map.insert(key.to_owned(), value.into());
}

pub(crate) fn put_some<T: Into<Value>>(map: &mut Map<String, Value>, key: &str, value: Option<T>) {
    if let Some(value) = value {
        map.insert(key.to_owned(), value.into());
    }
}
