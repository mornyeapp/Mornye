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
