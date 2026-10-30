//! Web cover copies (`webCoverPath`, contract section 5) rank after every
//! cover file and embedded picture.

use super::covers::{flac_pair, json_cover};
use super::*;

/// The body `getCoverArt` serves for each of `ids`.
async fn served(fixture: &Fixture, ids: &[&str]) -> Vec<Vec<u8>> {
    let mut bodies = Vec::new();
    for id in ids {
        let reply = json_cover(fixture, id).await;
        assert_eq!(reply.status, 200, "{id}");
        bodies.push(reply.body.to_vec());
    }
    bodies
}

#[tokio::test]
async fn a_mixed_album_serves_its_embedded_picture_before_a_web_copy() {
    let picture = png(40, 20);
    let copy = png(16, 16);
    let fixture = Fixture::new(|dir| {
        let (with, without) = flac_pair(&picture);
        let bare = write_file(dir, "1.flac", &without);
        let embedded = write_file(dir, "2.flac", &with);
        let web = write_file(dir, "web.png", &copy);
        vec![
            json!({ "id": "s1", "title": "One", "artist": "A", "album": "X", "track": 1,
                    "path": bare, "webCoverPath": web }),
            json!({ "id": "s2", "title": "Two", "artist": "A", "album": "X", "track": 2,
                    "path": embedded }),
        ]
    });
    let album = fixture.album_id("s1");
    let artist = fixture.artist_id("A");
    assert_eq!(
        served(&fixture, &[&album, "s1", "s2", &artist]).await,
        vec![picture.clone(); 4],
        "the album's own picture, as without the copy"
    );
}

#[tokio::test]
async fn a_web_copy_serves_only_when_nothing_else_exists() {
    let first = png(16, 16);
    let second = png(24, 12);
    let fixture = Fixture::new(|dir| {
        let (_, without) = flac_pair(&png(8, 8));
        let bare = write_file(dir, "bare.flac", &without);
        let one = write_file(dir, "one.png", &first);
        let two = write_file(dir, "two.png", &second);
        vec![
            json!({ "id": "s1", "title": "One", "artist": "A", "album": "X", "track": 1,
                    "path": bare, "webCoverPath": one }),
            json!({ "id": "s2", "title": "Two", "artist": "A", "album": "X", "track": 2,
                    "path": bare, "webCoverPath": two }),
            json!({ "id": "s3", "title": "Three", "artist": "A", "album": "X", "track": 3,
                    "path": bare, "webCoverPath": dir.join("pruned.png").to_string_lossy() }),
            json!({ "id": "s4", "title": "Four", "artist": "B", "album": "Y", "path": bare }),
        ]
    });
    let album = fixture.album_id("s1");
    let song = fixture.ok("getSong", &[("id", "s2")], "song").await;
    assert_eq!(song["coverArt"], album.as_str());
    // A song its own copy, then the album's; the album its first song's.
    assert_eq!(
        served(&fixture, &[&album, "s1", "s2", "s3"]).await,
        vec![first.clone(), first.clone(), second, first]
    );
    // A song with neither a picture nor a copy still has no cover.
    assert_eq!(json_cover(&fixture, "s4").await.status, 404);
}

#[tokio::test]
async fn a_local_cover_file_after_a_web_only_song_keeps_the_album_cover() {
    let cover = png(30, 30);
    let copy = png(16, 16);
    let fixture = Fixture::new(|dir| {
        let (_, without) = flac_pair(&png(8, 8));
        let bare = write_file(dir, "bare.flac", &without);
        let file = write_file(dir, "cover.png", &cover);
        let web = write_file(dir, "web.png", &copy);
        vec![
            json!({ "id": "s1", "title": "One", "artist": "A", "album": "X", "track": 1,
                    "path": bare, "webCoverPath": web }),
            json!({ "id": "s2", "title": "Two", "artist": "A", "album": "X", "track": 2,
                    "path": bare, "coverPath": file }),
        ]
    });
    let album = fixture.album_id("s1");
    assert_eq!(
        served(&fixture, &[&album, "s1", "s2"]).await,
        vec![cover.clone(); 3],
        "the cover file, as without the copy"
    );
}
