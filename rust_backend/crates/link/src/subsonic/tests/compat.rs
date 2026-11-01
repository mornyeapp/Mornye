//! The phone's Subsonic client must work unchanged against this server.
//! These tests replay what `lib/services/network_storage_subsonic.dart`
//! requests and parses, with the song of `test/support/subsonic_fixture.dart`.

use super::*;
use serde_json::Map;
use std::collections::HashSet;

/// The phone always sends these (`_subsonicTarget`, API key auth).
const PHONE: [(&str, &str); 4] = [
    ("v", "1.16.1"),
    ("c", "Mornye"),
    ("f", "json"),
    ("apiKey", "private-api-key"),
];

const SONG_ID: &str = "song / 日本語?&";

async fn phone(fixture: &Fixture, method: &str, args: &[(&str, &str)]) -> Value {
    let mut params = PHONE.to_vec();
    params.extend_from_slice(args);
    let reply = fixture.raw(method, &params, HeaderMap::new()).await;
    assert_eq!(reply.status, 200, "{method}");
    let response = reply.subsonic();
    assert_eq!(response["status"], "ok", "{method}: {response}");
    response
}

/// `_subsonicList`: absent is empty, anything but a list of objects fails.
fn list(value: &Value) -> Vec<Value> {
    match value {
        Value::Null => Vec::new(),
        Value::Array(items) => {
            assert!(items.iter().all(Value::is_object), "list of maps");
            items.clone()
        }
        other => panic!("expected a list, got {other}"),
    }
}

fn text(value: &Value, key: &str) -> String {
    value[key].as_str().unwrap_or_default().to_owned()
}

/// `SubsonicSong`: validation plus `_metadata()`.
fn phone_song(data: &Value) -> Map<String, Value> {
    let id = text(data, "id");
    assert!(!id.is_empty() && id.len() <= 4096, "song id");
    assert_ne!(data["isDir"], true, "songs are not directories");
    let artist = match text(data, "displayArtist") {
        display if !display.is_empty() => display,
        _ => text(data, "artist"),
    };
    let suffix = text(data, "suffix").to_lowercase();
    let format = if !suffix.is_empty()
        && suffix.len() <= 10
        && suffix
            .chars()
            .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit())
    {
        suffix
    } else {
        match text(data, "contentType").to_lowercase().as_str() {
            "audio/flac" | "audio/x-flac" => "flac",
            "audio/mp4" | "audio/x-m4a" => "m4a",
            "audio/ogg" | "application/ogg" => "ogg",
            "audio/opus" => "opus",
            "audio/wav" | "audio/x-wav" => "wav",
            _ => "mp3",
        }
        .to_owned()
    };
    let mut metadata = Map::new();
    metadata.insert("title".into(), text(data, "title").into());
    metadata.insert("artist".into(), artist.into());
    metadata.insert("album".into(), text(data, "album").into());
    metadata.insert(
        "album_artist".into(),
        text(data, "displayAlbumArtist").into(),
    );
    metadata.insert("format".into(), format.into());
    metadata.insert("genre".into(), text(data, "genre").into());
    metadata.insert(
        "explicit".into(),
        (data["explicitStatus"] == "explicit").into(),
    );
    match &data["isrc"] {
        Value::Array(codes) if !codes.is_empty() => {
            metadata.insert("isrc".into(), codes[0].as_str().unwrap_or_default().into());
        }
        Value::String(code) => {
            metadata.insert("isrc".into(), code.clone().into());
        }
        _ => {}
    }
    if !data["year"].is_null() {
        metadata.insert("date".into(), data["year"].to_string().into());
    }
    for (field, key) in [
        ("duration", "duration"),
        ("track", "track_number"),
        ("discNumber", "disc_number"),
        ("bitRate", "bitrate"),
        ("samplingRate", "sample_rate"),
        ("bitDepth", "bit_depth"),
    ] {
        if let Some(number) = data[field].as_f64() {
            metadata.insert(key.into(), (number as i64).into());
        }
    }
    let gain = &data["replayGain"];
    for (field, key) in [
        ("trackGain", "replaygain_track_gain"),
        ("albumGain", "replaygain_album_gain"),
    ] {
        if let Some(number) = gain[field].as_f64() {
            metadata.insert(key.into(), format!("{number} dB").into());
        }
    }
    for (field, key) in [
        ("trackPeak", "replaygain_track_peak"),
        ("albumPeak", "replaygain_album_peak"),
    ] {
        if let Some(number) = gain[field].as_f64() {
            metadata.insert(key.into(), number.to_string().into());
        }
    }
    metadata
}

/// The fixture's song, exported by the desktop.
fn phone_fixture() -> Fixture {
    Fixture::new(|dir| {
        let audio = write_file(dir, "song.flac", &[0, 1, 2, 3]);
        let cover = write_file(dir, "cover.png", &png(8, 8));
        vec![json!({
            "id": SONG_ID,
            "title": "A song",
            "artist": "An artist",
            "albumArtist": "Album artist",
            "album": "An album",
            "track": 1,
            "disc": 1,
            "durationMs": 243_000,
            "path": audio,
            "size": 4,
            "suffix": "flac",
            "bitRate": 1600,
            "sampleRate": 96_000,
            "bitDepth": 24,
            "channels": 2,
            "isrc": "XXABC2600001",
            "coverPath": cover,
            "trackGain": -4.2,
            "albumGain": -3.5,
        })]
    })
}

#[tokio::test]
async fn phone_browses_searches_and_reads_metadata() {
    let fixture = phone_fixture();
    phone(&fixture, "ping", &[]).await;
    let artists = phone(&fixture, "getArtists", &[]).await;
    let artist_ids: Vec<(String, String)> = list(&artists["artists"]["index"])
        .iter()
        .flat_map(|index| list(&index["artist"]))
        .map(|artist| (text(&artist, "id"), text(&artist, "name")))
        .collect();
    assert_eq!(artist_ids.len(), 1);
    assert_eq!(artist_ids[0].1, "Album artist");
    let artist = phone(&fixture, "getArtist", &[("id", &artist_ids[0].0)]).await;
    let albums = list(&artist["artist"]["album"]);
    assert_eq!(albums.len(), 1);
    assert_eq!(text(&albums[0], "name"), "An album");
    let album_id = text(&albums[0], "id");
    let album = phone(&fixture, "getAlbum", &[("id", &album_id)]).await;
    let songs: Vec<Value> = list(&album["album"]["song"])
        .into_iter()
        .filter(|song| song["isVideo"] != true)
        .collect();
    assert_eq!(songs.len(), 1);
    assert_eq!(text(&songs[0], "id"), SONG_ID);
    assert_eq!(songs[0]["size"], 4);

    let song = phone(&fixture, "getSong", &[("id", SONG_ID)]).await;
    let metadata = phone_song(&song["song"]);
    let expected = json!({
        "title": "A song",
        "artist": "An artist",
        "album": "An album",
        "album_artist": "Album artist",
        "format": "flac",
        "genre": "",
        "explicit": false,
        "isrc": "XXABC2600001",
        "duration": 243,
        "track_number": 1,
        "disc_number": 1,
        "bitrate": 1600,
        "sample_rate": 96_000,
        "bit_depth": 24,
        "replaygain_track_gain": "-4.2 dB",
        "replaygain_album_gain": "-3.5 dB",
    });
    assert_eq!(Value::Object(metadata), expected);
    assert_eq!(song["song"]["contentType"], "audio/flac");

    let search = phone(
        &fixture,
        "search3",
        &[
            ("query", "a song"),
            ("artistCount", "30"),
            ("albumCount", "50"),
            ("songCount", "200"),
        ],
    )
    .await;
    let result = &search["searchResult3"];
    assert_eq!(ids(&Value::Array(list(&result["song"]))), [SONG_ID]);
    assert!(
        list(&result["album"])
            .iter()
            .all(|album| !text(album, "id").is_empty())
    );
    let unicode = phone(&fixture, "search3", &[("query", "日本語")]).await;
    assert!(
        list(&unicode["searchResult3"]["song"]).is_empty(),
        "titles are searched, not ids"
    );
}

#[tokio::test]
async fn phone_streams_with_range_and_fetches_artwork() {
    let fixture = phone_fixture();
    let song = phone(&fixture, "getSong", &[("id", SONG_ID)]).await["song"].clone();
    let mut params = PHONE.to_vec();
    params.extend([("id", SONG_ID), ("format", "raw")]);
    let stream = fixture
        .raw("stream", &params, headers(&[("range", "bytes=1-2")]))
        .await;
    assert_eq!(stream.status, 206);
    assert_eq!(stream.header("content-range"), Some("bytes 1-2/4"));
    assert_eq!(stream.header("accept-ranges"), Some("bytes"));
    assert_eq!(stream.header("content-type"), song["contentType"].as_str());
    assert_eq!(stream.body.as_ref(), [1, 2]);
    let full = fixture.raw("stream", &params, HeaderMap::new()).await;
    assert_eq!(full.header("content-length"), Some("4"));

    let cover_id = text(&song, "coverArt");
    assert!(!cover_id.is_empty());
    let mut params = PHONE.to_vec();
    params.push(("id", &cover_id));
    let cover = fixture.raw("getCoverArt", &params, HeaderMap::new()).await;
    assert_eq!(cover.status, 200);
    assert!(
        cover
            .header("content-type")
            .expect("type")
            .starts_with("image/")
    );
    assert!(!cover.body.is_empty());
}

#[tokio::test]
async fn phone_reads_failures_as_numeric_codes() {
    let fixture = phone_fixture();
    let mut params = PHONE.to_vec();
    params.push(("id", "al-missing"));
    let reply = fixture.raw("getAlbum", &params, HeaderMap::new()).await;
    assert_eq!(reply.status, 200);
    let response = reply.subsonic();
    assert_eq!(response["status"], "failed");
    assert!(response["error"].is_object());
    assert_eq!(response["error"]["code"].as_u64(), Some(70));
}

/// `SubsonicClient.catalog`: pages of 200 alphabetical albums, `getAlbum`
/// for each new one, until a short page.
async fn phone_catalog_sync(fixture: &Fixture) -> (Vec<String>, usize) {
    let mut albums = HashSet::new();
    let mut seen = HashSet::new();
    let mut songs = Vec::new();
    let mut requests = 0;
    let mut offset = 0;
    loop {
        let offset_text = offset.to_string();
        let page = list(
            &phone(
                fixture,
                "getAlbumList2",
                &[
                    ("type", "alphabeticalByName"),
                    ("size", "200"),
                    ("offset", &offset_text),
                ],
            )
            .await["albumList2"]["album"],
        );
        requests += 1;
        let mut new_albums = 0;
        for album in &page {
            let id = text(album, "id");
            assert!(!id.is_empty(), "album id");
            assert!(!text(album, "name").is_empty(), "album name");
            if !albums.insert(id.clone()) {
                continue;
            }
            new_albums += 1;
            let detail = phone(fixture, "getAlbum", &[("id", &id)]).await;
            for song in list(&detail["album"]["song"]) {
                if song["isVideo"] == true {
                    continue;
                }
                phone_song(&song);
                let song_id = text(&song, "id");
                if seen.insert(song_id.clone()) {
                    songs.push(song_id);
                }
            }
        }
        if page.len() < 200 {
            return (songs, requests);
        }
        assert!(new_albums > 0, "pagination advances");
        offset += 200;
    }
}

#[tokio::test]
async fn phone_catalog_sync_pages_albums_and_sees_every_song_once() {
    let fixture = Fixture::new(|_| {
        let mut rows: Vec<Value> = (0..402)
            .map(|index| {
                json!({
                    "id": format!("l:{index}"),
                    "title": format!("Song {index}"),
                    "artist": format!("Artist {}", index % 7),
                    "albumArtist": format!("Artist {}", index / 2 % 7),
                    "album": format!("Album {:03}", index / 2),
                    "path": format!("/music/{index}.flac"),
                })
            })
            .collect();
        rows.extend((0..3).map(|index| {
            json!({
                "id": format!("d:{index}"),
                "title": format!("Loose {index}"),
                "artist": format!("Solo {index}"),
                "path": format!("/music/loose-{index}.mp3"),
            })
        }));
        rows
    });
    let catalog = fixture.catalog();
    assert_eq!(catalog.albums().len(), 204);
    let first = list(
        &phone(
            &fixture,
            "getAlbumList2",
            &[
                ("type", "alphabeticalByName"),
                ("size", "200"),
                ("offset", "0"),
            ],
        )
        .await["albumList2"]["album"],
    );
    assert_eq!(first.len(), 200);
    let (songs, pages) = phone_catalog_sync(&fixture).await;
    assert_eq!(pages, 2);
    let mut expected: Vec<String> = catalog.songs().iter().map(|song| song.id.clone()).collect();
    let mut synced = songs.clone();
    expected.sort();
    synced.sort();
    assert_eq!(synced, expected, "every song exactly once");
    let (again, _) = phone_catalog_sync(&fixture).await;
    assert_eq!(again, songs, "stable order across syncs");
}
