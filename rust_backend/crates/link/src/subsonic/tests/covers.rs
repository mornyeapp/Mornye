use super::*;
use crate::subsonic::covers::{CACHE_DIR, trim_cache};

fn cached_files(fixture: &Fixture) -> Vec<PathBuf> {
    std::fs::read_dir(fixture.shared.config.temp_dir.join(CACHE_DIR))
        .map(|entries| {
            entries
                .filter_map(Result::ok)
                .map(|entry| entry.path())
                .collect()
        })
        .unwrap_or_default()
}

#[tokio::test]
async fn cover_art_serves_the_original_for_album_song_and_artist_ids() {
    let fixture = library();
    let original = png(64, 32);
    for id in [
        fixture.album_id("l:1"),
        "l:1".to_owned(),
        "l:2".to_owned(),
        fixture.artist_id("The Band"),
    ] {
        let reply = fixture
            .raw("getCoverArt", &[("id", &id)], HeaderMap::new())
            .await;
        assert_eq!(reply.status, 200, "{id}");
        assert_eq!(reply.header("content-type"), Some("image/png"));
        assert_eq!(reply.body.as_ref(), original.as_slice());
        assert!(reply.header("etag").is_some());
    }
    assert!(cached_files(&fixture).is_empty(), "no size, no cache");
}

#[tokio::test]
async fn cover_art_resizes_to_jpeg_keeping_the_aspect_ratio_and_caches() {
    let fixture = library();
    let id = fixture.album_id("l:1");
    let reply = fixture
        .raw(
            "getCoverArt",
            &[("id", &id), ("size", "16")],
            HeaderMap::new(),
        )
        .await;
    assert_eq!(reply.status, 200);
    assert_eq!(reply.header("content-type"), Some("image/jpeg"));
    assert!(reply.body.starts_with(&[0xFF, 0xD8, 0xFF]));
    let image = image::load_from_memory(&reply.body).expect("decodes");
    assert_eq!((image.width(), image.height()), (16, 8));
    let cached = cached_files(&fixture);
    assert_eq!(cached.len(), 1);
    assert_eq!(
        std::fs::read(&cached[0]).expect("cache file"),
        reply.body.as_ref()
    );
    let modified = std::fs::metadata(&cached[0])
        .and_then(|meta| meta.modified())
        .expect("mtime");
    let again = fixture
        .raw(
            "getCoverArt",
            &[("id", &id), ("size", "16")],
            HeaderMap::new(),
        )
        .await;
    assert_eq!(again.body, reply.body);
    assert_eq!(cached_files(&fixture), cached);
    assert_eq!(
        std::fs::metadata(&cached[0])
            .and_then(|meta| meta.modified())
            .expect("mtime"),
        modified,
        "served from the cache"
    );
    let larger = fixture
        .raw(
            "getCoverArt",
            &[("id", &id), ("size", "500")],
            HeaderMap::new(),
        )
        .await;
    assert_eq!(
        larger.header("content-type"),
        Some("image/png"),
        "never upscaled"
    );
    assert_eq!(cached_files(&fixture).len(), 1);
}

#[tokio::test]
async fn cover_art_answers_304_for_a_matching_etag() {
    let fixture = library();
    let id = fixture.album_id("l:1");
    let first = fixture
        .raw("getCoverArt", &[("id", &id)], HeaderMap::new())
        .await;
    let etag = first.header("etag").expect("etag").to_owned();
    let cached = fixture
        .raw(
            "getCoverArt",
            &[("id", &id)],
            headers(&[("if-none-match", &etag)]),
        )
        .await;
    assert_eq!(cached.status, 304);
    assert!(cached.body.is_empty());
    let resized = fixture
        .raw(
            "getCoverArt",
            &[("id", &id), ("size", "16")],
            headers(&[("if-none-match", &etag)]),
        )
        .await;
    assert_eq!(resized.status, 200, "a different size has a different tag");
}

#[tokio::test]
async fn cover_art_without_an_image_is_error_70_with_http_404() {
    let fixture = library();
    for id in ["l:40", "l:10", "unknown", &fixture.album_id("l:10")] {
        let reply = fixture
            .raw(
                "getCoverArt",
                &[("f", "json"), ("id", id)],
                HeaderMap::new(),
            )
            .await;
        assert_eq!(reply.status, 404, "{id}");
        assert_eq!(reply.subsonic()["error"]["code"], 70);
    }
    let xml = fixture
        .raw("getCoverArt", &[("id", "unknown")], HeaderMap::new())
        .await;
    assert_eq!(xml.status, 404);
    assert!(xml.text().contains("code=\"70\""));
    let gone = Fixture::new(|dir| {
        vec![json!({
            "id": "s", "title": "T", "artist": "A", "path": "/m/s.flac",
            "coverPath": dir.join("deleted.jpg").to_string_lossy(),
        })]
    });
    let reply = gone
        .raw(
            "getCoverArt",
            &[("f", "json"), ("id", "s")],
            HeaderMap::new(),
        )
        .await;
    assert_eq!(reply.status, 404);
}

#[tokio::test]
async fn undecodable_covers_are_served_as_they_are() {
    let fixture = Fixture::new(|dir| {
        let cover = write_file(dir, "cover.jpg", b"\xFF\xD8\xFFnot really a jpeg");
        vec![
            json!({ "id": "s", "title": "T", "artist": "A", "path": "/m/s.flac", "coverPath": cover }),
        ]
    });
    let reply = fixture
        .raw(
            "getCoverArt",
            &[("id", "s"), ("size", "32")],
            HeaderMap::new(),
        )
        .await;
    assert_eq!(reply.status, 200);
    assert_eq!(reply.header("content-type"), Some("image/jpeg"));
    assert_eq!(reply.body.as_ref(), b"\xFF\xD8\xFFnot really a jpeg");
}

/// A minimal FLAC file: STREAMINFO, then `block` as the last metadata block
/// of type `kind`, then a frame sync code.
fn flac(kind: u8, block: &[u8]) -> Vec<u8> {
    let mut bytes = b"fLaC".to_vec();
    bytes.extend_from_slice(&[0, 0, 0, 34]);
    bytes.extend_from_slice(&[0; 34]);
    let length = u32::try_from(block.len())
        .expect("block length")
        .to_be_bytes();
    bytes.push(0x80 | kind);
    bytes.extend_from_slice(&length[1..]);
    bytes.extend_from_slice(block);
    bytes.extend_from_slice(&[0xFF, 0xF8, 0, 0]);
    bytes
}

/// A FLAC PICTURE block holding `image` as the front cover.
fn picture_block(image: &[u8]) -> Vec<u8> {
    let mime = b"image/png";
    let mut block = Vec::new();
    block.extend_from_slice(&3u32.to_be_bytes());
    block.extend_from_slice(&u32::try_from(mime.len()).expect("mime").to_be_bytes());
    block.extend_from_slice(mime);
    block.extend_from_slice(&0u32.to_be_bytes());
    block.extend_from_slice(&[0; 16]);
    block.extend_from_slice(&u32::try_from(image.len()).expect("image").to_be_bytes());
    block.extend_from_slice(image);
    block
}

/// A FLAC with `image` embedded, and one of the same length without a
/// picture (a PADDING block instead).
fn flac_pair(image: &[u8]) -> (Vec<u8>, Vec<u8>) {
    let picture = picture_block(image);
    (flac(6, &picture), flac(1, &vec![0; picture.len()]))
}

#[tokio::test]
async fn cover_art_serves_a_picture_embedded_in_the_audio_file() {
    let original = png(40, 20);
    let fixture = Fixture::new(|dir| {
        let (with, without) = flac_pair(&original);
        let bare = write_file(dir, "1.flac", &without);
        let embedded = write_file(dir, "2.flac", &with);
        vec![
            json!({ "id": "s1", "title": "One", "artist": "A", "album": "X", "track": 1, "path": bare }),
            json!({ "id": "s2", "title": "Two", "artist": "A", "album": "X", "track": 2, "path": embedded }),
        ]
    });
    let album = fixture.album_id("s1");
    let artist = fixture.artist_id("A");
    let song = fixture.ok("getSong", &[("id", "s1")], "song").await;
    assert_eq!(song["coverArt"], album.as_str());
    for id in [album.as_str(), "s1", "s2", artist.as_str()] {
        let reply = fixture
            .raw("getCoverArt", &[("id", id)], HeaderMap::new())
            .await;
        assert_eq!(reply.status, 200, "{id}");
        assert_eq!(reply.header("content-type"), Some("image/png"));
        assert_eq!(reply.body.as_ref(), original.as_slice(), "{id}");
    }
    let cached = cached_files(&fixture);
    assert_eq!(cached.len(), 1, "{cached:?}");
    assert_eq!(cached[0].extension().and_then(|e| e.to_str()), Some("png"));
    let resized = fixture
        .raw(
            "getCoverArt",
            &[("id", &album), ("size", "10")],
            HeaderMap::new(),
        )
        .await;
    assert_eq!(resized.status, 200);
    assert_eq!(resized.header("content-type"), Some("image/jpeg"));
    let image = image::load_from_memory(&resized.body).expect("decodes");
    assert_eq!((image.width(), image.height()), (10, 5));
    assert_eq!(cached_files(&fixture).len(), 2);
}

#[tokio::test]
async fn cover_art_without_any_picture_is_404_and_remembered() {
    let original = png(8, 8);
    let (with, without) = flac_pair(&original);
    let fixture = Fixture::new(|dir| {
        let bare = write_file(dir, "bare.flac", &without);
        vec![json!({ "id": "s", "title": "T", "artist": "A", "album": "X", "path": bare })]
    });
    let path = fixture.catalog().song("s").expect("song").path.clone();
    let missing = json_cover(&fixture, "s").await;
    assert_eq!(missing.status, 404);
    assert_eq!(missing.subsonic()["error"]["code"], 70);

    // Same path, size and mtime: not read again.
    let modified = std::fs::metadata(&path)
        .and_then(|meta| meta.modified())
        .expect("mtime");
    std::fs::write(&path, &with).expect("rewrite");
    let set_mtime = |time: std::time::SystemTime| {
        std::fs::File::options()
            .write(true)
            .open(&path)
            .and_then(|file| file.set_modified(time))
            .expect("set mtime");
    };
    set_mtime(modified);
    assert_eq!(json_cover(&fixture, "s").await.status, 404, "remembered");

    // A changed file is read again.
    set_mtime(modified + std::time::Duration::from_secs(5));
    let found = json_cover(&fixture, "s").await;
    assert_eq!(found.status, 200);
    assert_eq!(found.body.as_ref(), original.as_slice());
    assert_eq!(cached_files(&fixture).len(), 1);
}

async fn json_cover(fixture: &Fixture, id: &str) -> Reply {
    fixture
        .raw(
            "getCoverArt",
            &[("f", "json"), ("id", id)],
            HeaderMap::new(),
        )
        .await
}

#[test]
fn trim_cache_removes_the_oldest_covers() {
    let dir = tempfile::tempdir().expect("temp dir");
    let base = std::time::SystemTime::now() - std::time::Duration::from_secs(100);
    for index in 0..5u64 {
        let path = dir.path().join(format!("{index}.jpg"));
        std::fs::write(&path, [0]).expect("write");
        let file = std::fs::File::options()
            .write(true)
            .open(&path)
            .expect("open");
        file.set_modified(base + std::time::Duration::from_secs(index))
            .expect("set mtime");
    }
    std::fs::write(dir.path().join("note.txt"), [0]).expect("write");
    trim_cache(dir.path(), 2);
    let mut left: Vec<String> = std::fs::read_dir(dir.path())
        .expect("list")
        .filter_map(Result::ok)
        .map(|entry| entry.file_name().to_string_lossy().into_owned())
        .collect();
    left.sort();
    assert_eq!(left, ["3.jpg", "4.jpg", "note.txt"]);
}
