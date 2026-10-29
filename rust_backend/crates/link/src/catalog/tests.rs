use super::*;
use serde_json::{Value, json};
use std::io::Write;

const HEADER: &str = r#"{"catalogVersion":1,"generatedMs":1700000000000,"count":3}"#;

fn read(lines: &[String]) -> Result<Catalog, String> {
    Catalog::read(lines.join("\n").as_bytes())
}

fn row(id: &str, title: &str, artist: &str, extra: Value) -> String {
    let mut value = json!({
        "id": id,
        "title": title,
        "artist": artist,
        "path": format!("/music/{id}.flac"),
    });
    if let (Some(object), Value::Object(extra)) = (value.as_object_mut(), extra) {
        object.extend(extra);
    }
    value.to_string()
}

fn catalog(rows: &[String]) -> Catalog {
    let mut lines = vec![HEADER.to_owned()];
    lines.extend_from_slice(rows);
    read(&lines).expect("catalog loads")
}

fn album_of<'a>(catalog: &'a Catalog, song_id: &str) -> &'a Album {
    &catalog.albums()[catalog.song(song_id).expect("song").album]
}

/// The cover files tried first for `id`.
fn cover_files<'a>(catalog: &'a Catalog, id: &str) -> Vec<&'a Path> {
    catalog
        .cover_source(id)
        .map(|source| source.files)
        .unwrap_or_default()
}

/// The first cover file behind `id`.
fn cover_file<'a>(catalog: &'a Catalog, id: &str) -> Option<&'a Path> {
    cover_files(catalog, id).first().copied()
}

/// The audio files tried for an embedded cover behind `id`.
fn embedded<'a>(catalog: &'a Catalog, id: &str) -> Vec<(&'a Path, &'static str)> {
    catalog
        .cover_source(id)
        .map(|source| source.embedded)
        .unwrap_or_default()
}

#[test]
fn rejects_missing_or_invalid_headers() {
    assert!(read(&[]).unwrap_err().contains("missing"));
    assert!(read(&[String::new()]).unwrap_err().contains("missing"));
    assert!(
        read(&["not json".to_owned()])
            .unwrap_err()
            .contains("not valid JSON")
    );
    assert!(
        read(&[r#"{"generatedMs":1}"#.to_owned()])
            .unwrap_err()
            .contains("catalogVersion")
    );
    assert!(
        read(&[r#"{"catalogVersion":2}"#.to_owned()])
            .unwrap_err()
            .contains("unsupported")
    );
    assert!(read(&["[1]".to_owned()]).unwrap_err().contains("object"));
    let header_only = read(&[HEADER.to_owned()]).expect("empty catalog");
    assert_eq!(header_only.song_count(), 0);
    assert_eq!(header_only.generated_ms(), 1_700_000_000_000);
}

#[test]
fn load_reads_a_file_and_reports_unreadable_paths() {
    let dir = tempfile::tempdir().expect("temp dir");
    let path = dir.path().join("catalog.ndjson");
    let mut file = std::fs::File::create(&path).expect("create");
    writeln!(file, "\u{FEFF}{HEADER}").expect("write");
    writeln!(file, "{}", row("l:1", "One", "Artist", json!({}))).expect("write");
    drop(file);
    let catalog = Catalog::load(&path).expect("loads");
    assert_eq!(catalog.song_count(), 1);
    assert!(
        Catalog::load(&dir.path().join("missing.ndjson"))
            .unwrap_err()
            .contains("unreadable")
    );
}

#[test]
fn skips_invalid_lines_and_tolerates_unknown_fields() {
    let catalog = catalog(&[
        row("l:1", "One", "Artist", json!({ "futureField": [1, 2] })),
        "{not json".to_owned(),
        String::new(),
        r#"{"id":"l:2","title":"No path","artist":"A"}"#.to_owned(),
        r#"{"id":"l:3","artist":"A","path":"/x.flac"}"#.to_owned(),
        r#"{"title":"No id","artist":"A","path":"/x.flac"}"#.to_owned(),
        r#"{"id":"","title":"Empty id","artist":"A","path":"/x.flac"}"#.to_owned(),
        r#"{"id":"l:4","title":"Null artist","artist":null,"path":"/x.flac"}"#.to_owned(),
        row("l:1", "Duplicate", "Artist", json!({})),
        row(
            "l:5",
            "",
            "",
            json!({
                "album": null,
                "track": "3",
                "disc": 1.0,
                "year": "2001",
                "durationMs": 61_499,
                "bitRate": 1_411_000,
                "sampleRate": "44100",
                "trackGain": "-4.2 dB",
                "albumPeak": 0.98,
                "explicit": 1,
                "isrc": " XXABC2600001 ",
                "coverPath": "",
            }),
        ),
    ]);
    assert_eq!(catalog.song_count(), 2);
    assert_eq!(catalog.skipped_rows(), 7);
    let song = catalog.song("l:5").expect("lenient row");
    assert_eq!(song.title, "l:5", "empty title falls back to the file stem");
    assert_eq!(song.artist, UNKNOWN_ARTIST);
    assert_eq!(song.track, Some(3));
    assert_eq!(song.disc, Some(1));
    assert_eq!(song.year, Some(2001));
    assert_eq!(song.duration_secs(), Some(61));
    assert_eq!(song.bit_rate, Some(1411), "bits per second read as kbps");
    assert_eq!(song.sample_rate, Some(44_100));
    assert_eq!(song.track_gain, Some(-4.2));
    assert_eq!(song.album_peak, Some(0.98));
    assert!(song.explicit);
    assert_eq!(song.isrc.as_deref(), Some("XXABC2600001"));
    assert_eq!(song.cover_path, None);
    assert_eq!(song.suffix, "flac", "suffix falls back to the extension");
}

#[test]
fn groups_albums_and_orders_songs_by_disc_track_and_title() {
    let catalog = catalog(&[
        row(
            "l:b",
            "Beta",
            "Band",
            json!({ "album": "Record", "albumArtist": "Band", "disc": 1, "track": 2 }),
        ),
        row(
            "l:c",
            "Gamma",
            "Band",
            json!({ "album": "Record", "albumArtist": "band ", "disc": 2, "track": 1 }),
        ),
        row(
            "l:a",
            "Alpha",
            "Guest",
            json!({ "album": "RECORD", "albumArtist": "BAND", "disc": 1, "track": 1 }),
        ),
        row(
            "l:z",
            "Zeta",
            "Band",
            json!({ "album": "Record", "albumArtist": "Band" }),
        ),
        row("l:x", "Loose", "Solo", json!({})),
        row("l:y", "Also loose", "solo", json!({ "album": "" })),
    ]);
    let album = album_of(&catalog, "l:a");
    let order: Vec<&str> = album
        .songs
        .iter()
        .map(|index| catalog.songs()[*index].id.as_str())
        .collect();
    assert_eq!(order, ["l:z", "l:a", "l:b", "l:c"]);
    assert_eq!(album.name, "Record", "first seen spelling");
    assert_eq!(album.artist_name, "Band", "album artist owns the album");
    assert_eq!(album.id, short_id("al-", "band|record"));
    let guest = &catalog.artists()[catalog.song("l:a").expect("song").artist_ref];
    assert_eq!(guest.name, "Guest");
    assert!(guest.albums.is_empty());
    assert_eq!(
        guest.browse_albums(),
        [catalog.song("l:a").expect("song").album]
    );
    let loose = album_of(&catalog, "l:x");
    assert_eq!(loose.name, UNKNOWN_ALBUM);
    assert_eq!(loose.songs.len(), 2, "no album tag groups per artist");
    assert_eq!(catalog.albums().len(), 2);
    let album_artists: Vec<&str> = catalog
        .album_artists()
        .iter()
        .map(|index| catalog.artists()[*index].name.as_str())
        .collect();
    assert_eq!(album_artists, ["Band", "Solo"]);
}

#[test]
fn album_key_wins_and_mixed_artists_become_various() {
    let catalog = catalog(&[
        row(
            "l:1",
            "One",
            "Alpha",
            json!({ "album": "Hits", "albumKey": "comp-1" }),
        ),
        row(
            "l:2",
            "Two",
            "Beta",
            json!({ "album": "Hits", "albumKey": "comp-1" }),
        ),
        row(
            "l:3",
            "Three",
            "Alpha",
            json!({ "album": "Hits", "albumKey": "other" }),
        ),
    ]);
    let compilation = album_of(&catalog, "l:1");
    assert_eq!(compilation.id, short_id("al-", "comp-1"));
    assert_eq!(compilation.artist_name, VARIOUS_ARTISTS);
    assert_eq!(compilation.songs.len(), 2);
    assert_eq!(album_of(&catalog, "l:3").artist_name, "Alpha");
    assert_ne!(album_of(&catalog, "l:3").id, compilation.id);
}

#[test]
fn ids_follow_the_contract_and_stay_stable_across_reloads() {
    assert_eq!(short_id("al-", "abc"), "al-ba7816bf8f01cfea");
    let rows = [
        row("l:1", "One", "Árvore  Band", json!({ "album": "First" })),
        row("d:9", "Two", "Other", json!({ "album": "Second" })),
    ];
    let first = catalog(&rows);
    let second = catalog(&rows);
    let ids = |catalog: &Catalog| -> Vec<String> {
        catalog
            .albums()
            .iter()
            .map(|album| album.id.clone())
            .chain(catalog.artists().iter().map(|artist| artist.id.clone()))
            .collect()
    };
    assert_eq!(ids(&first), ids(&second));
    let artist = &first.artists()[first.song("l:1").expect("song").artist_ref];
    assert_eq!(artist.id, short_id("ar-", "árvore band"));
    assert!(first.song("d:9").is_some(), "song ids are kept verbatim");
    assert_eq!(
        first.artist_index(&artist.id),
        Some(first.song("l:1").expect("song").artist_ref)
    );
}

#[test]
fn search_folds_case_and_diacritics_and_matches_every_term() {
    let catalog = catalog(&[
        row(
            "l:1",
            "Halo",
            "Beyoncé",
            json!({ "album": "I Am... Sasha Fierce" }),
        ),
        row(
            "l:2",
            "Crazy in Love",
            "Beyonce",
            json!({ "album": "Dangerously" }),
        ),
        row("l:3", "Ｆｕｌｌ Width", "Ｘ", json!({})),
        row("l:4", "Other", "Someone", json!({ "album": "Café" })),
    ]);
    let songs = |query: &str| -> Vec<String> {
        let terms = search_terms(query);
        catalog
            .search_songs(&terms)
            .map(|index| catalog.songs()[index].id.clone())
            .collect()
    };
    assert_eq!(songs("BEYONCE"), ["l:1", "l:2"]);
    assert_eq!(songs("beyoncé halo"), ["l:1"]);
    assert_eq!(songs("full width"), ["l:3"]);
    assert_eq!(songs("cafe"), ["l:4"]);
    assert_eq!(songs("  "), ["l:1", "l:2", "l:3", "l:4"]);
    assert_eq!(songs("\"\""), ["l:1", "l:2", "l:3", "l:4"]);
    assert_eq!(songs("*"), ["l:1", "l:2", "l:3", "l:4"]);
    assert!(songs("nothing matches").is_empty());
    let terms = search_terms("beyonce");
    let mut artists: Vec<&str> = catalog
        .search_artists(&terms)
        .map(|index| catalog.artists()[index].name.as_str())
        .collect();
    artists.sort_unstable();
    assert_eq!(
        artists,
        ["Beyonce", "Beyoncé"],
        "identity keeps diacritics, search folds them"
    );
    let terms = search_terms("sasha");
    assert_eq!(catalog.search_albums(&terms).count(), 1);
}

#[test]
fn covers_genres_years_and_newest() {
    let catalog = catalog(&[
        row(
            "l:1",
            "One",
            "Band",
            json!({ "album": "A", "track": 1, "genre": "Rock", "year": 1999, "addedMs": 5 }),
        ),
        row(
            "l:2",
            "Two",
            "Band",
            json!({ "album": "A", "track": 2, "coverPath": "/c/2.jpg", "genre": "rock", "addedMs": 9 }),
        ),
        row(
            "l:3",
            "Three",
            "Band",
            json!({ "album": "B", "coverPath": "/c/3.jpg", "genre": "Jazz", "addedMs": 7 }),
        ),
        row("l:4", "Four", "Band", json!({ "album": "C", "addedMs": 8 })),
        row(
            "l:5",
            "Five",
            "Band",
            json!({ "album": "C", "coverPath": "/c/5.jpg" }),
        ),
        row(
            "l:6",
            "Six",
            "Solo",
            json!({ "album": "D", "suffix": "wma" }),
        ),
    ]);
    let a = catalog.song("l:1").expect("song").album;
    assert_eq!(
        catalog.albums()[a].cover,
        catalog.song_index("l:2"),
        "a cover file wins over an earlier song that may embed one"
    );
    assert_eq!(
        catalog.song_cover_id(catalog.song_index("l:1").expect("song")),
        Some(catalog.albums()[a].id.as_str())
    );
    let six = catalog.song_index("l:6").expect("song");
    assert_eq!(catalog.song_cover_id(six), None);
    assert_eq!(cover_file(&catalog, "l:1"), Some(Path::new("/c/2.jpg")));
    assert_eq!(cover_file(&catalog, "l:5"), Some(Path::new("/c/5.jpg")));
    assert_eq!(
        cover_file(&catalog, &catalog.albums()[a].id),
        Some(Path::new("/c/2.jpg"))
    );
    let band = catalog.song("l:1").expect("song").artist_ref;
    assert!(cover_file(&catalog, &catalog.artists()[band].id).is_some());
    assert!(catalog.cover_source("l:6").is_none());
    assert!(catalog.cover_source("unknown").is_none());
    assert_eq!(catalog.albums()[a].year, Some(1999));
    let rock = catalog.genre("ROCK").expect("genre");
    assert_eq!(rock.name, "Rock");
    assert_eq!(rock.songs.len(), 2);
    assert_eq!(rock.albums.len(), 1);
    assert_eq!(catalog.genres().len(), 2);
    let newest: Vec<&str> = catalog
        .albums_newest()
        .iter()
        .map(|index| catalog.albums()[*index].name.as_str())
        .collect();
    assert_eq!(newest, ["A", "C", "B", "D"]);
}

#[test]
fn covers_fall_back_to_songs_that_can_embed_one() {
    let catalog = catalog(&[
        row(
            "e:1",
            "One",
            "Band",
            json!({ "album": "E", "track": 1, "suffix": "wma" }),
        ),
        row("e:2", "Two", "Band", json!({ "album": "E", "track": 2 })),
        row(
            "e:3",
            "Three",
            "Band",
            json!({ "album": "E", "track": 3, "path": "/music/e3.m4a", "suffix": "" }),
        ),
        row(
            "e:4",
            "Four",
            "Band",
            json!({ "album": "E", "track": 4, "suffix": "MP3" }),
        ),
        row(
            "e:5",
            "Five",
            "Band",
            json!({ "album": "E", "track": 5, "suffix": "opus" }),
        ),
        row(
            "f:1",
            "Solo",
            "Other",
            json!({ "album": "F", "suffix": "dsf" }),
        ),
    ]);
    let e = catalog.song("e:1").expect("song").album;
    let album = &catalog.albums()[e];
    assert_eq!(album.cover, catalog.song_index("e:2"));
    assert_eq!(catalog.album_cover_id(e), Some(album.id.as_str()));
    let one = catalog.song_index("e:1").expect("song");
    assert_eq!(catalog.song_cover_id(one), Some(album.id.as_str()));
    let band = catalog.songs()[one].artist_ref;
    assert_eq!(
        catalog.artist_cover_id(band),
        Some(catalog.artists()[band].id.as_str())
    );
    let in_album_order = [
        (Path::new("/music/e:2.flac"), "flac"),
        (Path::new("/music/e3.m4a"), "m4a"),
        (Path::new("/music/e:4.flac"), "mp3"),
    ];
    assert_eq!(embedded(&catalog, &album.id), in_album_order, "three tries");
    assert_eq!(
        embedded(&catalog, &catalog.artists()[band].id),
        in_album_order
    );
    assert_eq!(embedded(&catalog, "e:1"), in_album_order);
    assert_eq!(
        embedded(&catalog, "e:5"),
        [
            (Path::new("/music/e:5.flac"), "opus"),
            (Path::new("/music/e:2.flac"), "flac"),
            (Path::new("/music/e3.m4a"), "m4a"),
        ],
        "a song tries its own picture first"
    );
    let solo = catalog.song("f:1").expect("song").album;
    assert_eq!(catalog.album_cover_id(solo), None);
    assert_eq!(
        catalog.song_cover_id(catalog.song_index("f:1").expect("song")),
        None
    );
    assert!(catalog.cover_source("f:1").is_none());
}

#[test]
fn a_cover_source_lists_every_fallback_in_order() {
    let catalog = catalog(&[
        row(
            "g:1",
            "One",
            "Band",
            json!({ "album": "G", "track": 1, "coverPath": "/c/g1.jpg" }),
        ),
        row("g:2", "Two", "Band", json!({ "album": "G", "track": 2 })),
        row(
            "g:3",
            "Three",
            "Band",
            json!({ "album": "G", "track": 3, "coverPath": "/c/g3.jpg" }),
        ),
    ]);
    let album = album_of(&catalog, "g:1").id.clone();
    assert_eq!(
        cover_files(&catalog, "g:3"),
        [Path::new("/c/g3.jpg"), Path::new("/c/g1.jpg")],
        "its own file, then its album's"
    );
    assert_eq!(cover_files(&catalog, "g:1"), [Path::new("/c/g1.jpg")]);
    assert_eq!(cover_files(&catalog, "g:2"), [Path::new("/c/g1.jpg")]);
    assert_eq!(cover_files(&catalog, &album), [Path::new("/c/g1.jpg")]);
    assert_eq!(
        embedded(&catalog, "g:3"),
        [
            (Path::new("/music/g:3.flac"), "flac"),
            (Path::new("/music/g:1.flac"), "flac"),
            (Path::new("/music/g:2.flac"), "flac"),
        ],
        "pictures embedded in the song, then its album's, when no file is left"
    );
    assert_eq!(
        embedded(&catalog, &album),
        [
            (Path::new("/music/g:1.flac"), "flac"),
            (Path::new("/music/g:2.flac"), "flac"),
            (Path::new("/music/g:3.flac"), "flac"),
        ]
    );
}

/// Run with `cargo test --release -p mornye-link -- --ignored --nocapture`.
#[test]
#[ignore = "timing check for release builds"]
fn loads_a_hundred_thousand_songs_quickly() {
    let dir = tempfile::tempdir().expect("temp dir");
    let path = dir.path().join("catalog.ndjson");
    let mut file = std::io::BufWriter::new(std::fs::File::create(&path).expect("create"));
    writeln!(
        file,
        r#"{{"catalogVersion":1,"generatedMs":1,"count":100000}}"#
    )
    .expect("write");
    for index in 0..100_000 {
        let row = json!({
            "id": format!("l:{index}"),
            "title": format!("Song título {index}"),
            "artist": format!("Artist {}", index % 3000),
            "albumArtist": format!("Artist {}", index % 3000),
            "album": format!("Album {}", index % 9000),
            "albumKey": null, "track": index % 12 + 1, "disc": 1, "year": 1990 + index % 30,
            "genre": format!("Genre {}", index % 40), "durationMs": 215_000,
            "path": format!("/music/library/Artist {}/Album {}/{index:05}.flac", index % 3000, index % 9000),
            "size": 31_000_000, "suffix": "flac", "bitRate": 1100, "sampleRate": 44100,
            "bitDepth": 16, "channels": 2, "isrc": "XXABC2600001", "matchKey": "artist|title",
            "coverPath": format!("/covers/{}.jpg", index % 9000), "addedMs": 1_700_000_000_000_i64 + index,
            "trackGain": -6.5, "albumGain": -7.0, "trackPeak": 0.99, "albumPeak": 1.0, "explicit": false,
        });
        writeln!(file, "{row}").expect("write");
    }
    drop(file);
    let started = std::time::Instant::now();
    let catalog = Catalog::load(&path).expect("loads");
    let elapsed = started.elapsed();
    println!("loaded {} songs in {elapsed:?}", catalog.song_count());
    assert_eq!(catalog.song_count(), 100_000);
    assert_eq!(catalog.albums().len(), 9000);
    let started = std::time::Instant::now();
    let terms = search_terms("título 99999");
    assert_eq!(catalog.search_songs(&terms).count(), 1);
    println!("searched in {:?}", started.elapsed());
    if !cfg!(debug_assertions) {
        assert!(
            elapsed < std::time::Duration::from_secs(1),
            "took {elapsed:?}"
        );
    }
}
