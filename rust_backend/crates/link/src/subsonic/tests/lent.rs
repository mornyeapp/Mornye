//! Songs only the app can open: the server borrows each file through
//! `server/files/open` and returns it through `server/files/close` once the
//! response is done with it, however the response ends. The test's open file
//! stands in for the descriptor the app holds.
#![cfg(unix)]

use super::covers::{flac, flac_pair};
use super::*;
use crate::source::{CLOSE_OP, Leases, OPEN_OP};
use std::os::fd::AsRawFd;
use std::time::Duration;

const URI: &str =
    "content://com.example.documents/tree/a%3AMusic/document/a%3AMusic%2FBand%2FSong.flac";

/// A catalog whose one song `s` at `uri` the app lends from `bytes`.
fn lent_at(uri: &str, bytes: &[u8]) -> (Fixture, std::fs::File) {
    let mut held = None;
    let fixture = Fixture::new(|dir| {
        let path = write_file(dir, "lent.flac", bytes);
        held = Some(std::fs::File::open(path).expect("open"));
        vec![json!({
            "id": "s", "title": "Song", "artist": "Band", "album": "Album",
            "path": uri, "suffix": "flac",
        })]
    });
    let held = held.expect("held file");
    fixture.host.reply(
        OPEN_OP,
        Ok(json!({ "path": format!("/dev/fd/{}", held.as_raw_fd()) })),
    );
    (fixture, held)
}

fn lent(bytes: &[u8]) -> (Fixture, std::fs::File) {
    lent_at(URI, bytes)
}

fn audio(len: usize) -> Vec<u8> {
    (0..len).map(|index| (index % 251) as u8).collect()
}

/// The ops forwarded so far, each asserted to come from the server itself.
fn ops(fixture: &Fixture) -> Vec<String> {
    fixture
        .host
        .requests()
        .into_iter()
        .map(|(op, device, _)| {
            assert_eq!(device, "", "{op} is the server's own request");
            op
        })
        .collect()
}

/// Asserts each open was followed by the close of the same lease.
fn returned(fixture: &Fixture, borrows: usize) {
    let requests = fixture.host.requests();
    assert_eq!(requests.len(), borrows * 2, "{requests:?}");
    for pair in requests.chunks(2) {
        assert_eq!(pair[0].0, OPEN_OP);
        assert_eq!(pair[0].2["uri"], URI);
        assert_eq!(pair[1].0, CLOSE_OP);
        let lease = pair[0].2["lease"].as_str().expect("lease");
        assert!(!lease.is_empty());
        assert_eq!(pair[1].2["lease"], lease);
    }
}

#[tokio::test]
async fn a_lent_song_streams_whole_and_returns_its_lease() {
    let bytes = audio(200_000);
    let (fixture, _held) = lent(&bytes);
    let reply = fixture
        .raw("stream", &[("id", "s")], HeaderMap::new())
        .await;
    assert_eq!(reply.status, 200);
    assert_eq!(reply.header("content-type"), Some("audio/flac"));
    assert_eq!(reply.header("content-length"), Some("200000"));
    assert_eq!(reply.header("accept-ranges"), Some("bytes"));
    assert_eq!(reply.body.as_ref(), bytes.as_slice());
    returned(&fixture, 1);
}

#[tokio::test]
async fn ranges_seek_in_a_lent_song_and_each_response_borrows_its_own() {
    let bytes = audio(200_000);
    let (fixture, _held) = lent(&bytes);
    for (range, start, end) in [
        ("bytes=150000-150099", 150_000, 150_099),
        ("bytes=10-19", 10, 19),
    ] {
        let reply = fixture
            .raw("stream", &[("id", "s")], headers(&[("range", range)]))
            .await;
        assert_eq!(reply.status, 206, "{range}");
        assert_eq!(
            reply.header("content-range").map(str::to_owned),
            Some(format!("bytes {start}-{end}/200000"))
        );
        assert_eq!(reply.body.as_ref(), &bytes[start..=end]);
    }
    let whole = fixture
        .raw("stream", &[("id", "s")], HeaderMap::new())
        .await;
    assert_eq!(whole.body.as_ref(), bytes.as_slice(), "starts at the top");
    returned(&fixture, 3);
}

#[tokio::test]
async fn a_response_dropped_midway_returns_its_lease() {
    let (fixture, _held) = lent(&audio(1 << 20));
    let response = fixture
        .response("stream", &[("id", "s")], HeaderMap::new())
        .await;
    assert_eq!(response.status(), 200);
    let mut body = response.into_body();
    let frame = body.frame().await.expect("a frame").expect("data");
    assert!(frame.data_ref().is_some_and(|data| !data.is_empty()));
    assert_eq!(ops(&fixture), [OPEN_OP], "held while the client reads");
    drop(body);
    returned(&fixture, 1);
}

#[tokio::test]
async fn an_unsatisfiable_range_returns_its_lease() {
    let (fixture, _held) = lent(&audio(100));
    let reply = fixture
        .raw(
            "stream",
            &[("id", "s")],
            headers(&[("range", "bytes=500-")]),
        )
        .await;
    assert_eq!(reply.status, 416);
    returned(&fixture, 1);
}

#[tokio::test]
async fn a_file_the_app_cannot_lend_answers_404_and_is_still_closed() {
    let (fixture, _held) = lent(&audio(100));
    fixture
        .host
        .reply(OPEN_OP, Err(HostError::new("not_found", "Gone")));
    assert_eq!(
        fixture
            .raw("stream", &[("id", "s")], HeaderMap::new())
            .await
            .status,
        404
    );
    // A lent path that is not a regular file.
    let folder = fixture
        .shared
        .config
        .temp_dir
        .to_string_lossy()
        .into_owned();
    fixture.host.reply(OPEN_OP, Ok(json!({ "path": folder })));
    assert_eq!(
        fixture
            .raw("download", &[("id", "s")], HeaderMap::new())
            .await
            .status,
        404
    );
    fixture.host.reply(OPEN_OP, Ok(json!({})));
    assert_eq!(
        fixture
            .raw("stream", &[("id", "s")], HeaderMap::new())
            .await
            .status,
        404
    );
    returned(&fixture, 3);
}

#[tokio::test]
async fn an_open_abandoned_while_waiting_for_the_app_is_closed() {
    let (fixture, _held) = lent(&audio(100));
    fixture.host.hold(OPEN_OP);
    let waited = tokio::time::timeout(
        Duration::from_millis(50),
        fixture.response("stream", &[("id", "s")], HeaderMap::new()),
    )
    .await;
    assert!(waited.is_err(), "the app never answered");
    returned(&fixture, 1);
}

#[tokio::test]
async fn lent_files_are_bounded_and_a_returned_one_frees_its_place() {
    let bytes = audio(1 << 20);
    let (mut fixture, _held) = lent(&bytes);
    fixture.shared.leases = Leases::new(1, Duration::from_millis(50));
    let first = fixture
        .response("stream", &[("id", "s")], HeaderMap::new())
        .await;
    assert_eq!(first.status(), 200);
    let busy = fixture
        .raw("stream", &[("id", "s")], HeaderMap::new())
        .await;
    assert_eq!(busy.status, 503);
    assert_eq!(
        ops(&fixture),
        [OPEN_OP],
        "a busy request never asks the app"
    );
    drop(first);
    let next = fixture
        .raw("stream", &[("id", "s")], HeaderMap::new())
        .await;
    assert_eq!(next.status, 200);
    assert_eq!(next.body.as_ref(), bytes.as_slice());
    returned(&fixture, 2);
}

#[tokio::test]
async fn a_lent_song_downloads_under_its_document_name() {
    let bytes = audio(1000);
    let (fixture, _held) = lent(&bytes);
    let song = fixture.ok("getSong", &[("id", "s")], "song").await;
    assert_eq!(song["path"], "Band/Album/Song.flac");
    assert!(ops(&fixture).is_empty(), "browsing opens nothing");
    let reply = fixture
        .raw("download", &[("id", "s")], HeaderMap::new())
        .await;
    assert_eq!(reply.status, 200);
    assert_eq!(
        reply.header("content-disposition"),
        Some("attachment; filename*=UTF-8''Song.flac")
    );
    assert_eq!(reply.body.as_ref(), bytes.as_slice());
    returned(&fixture, 1);
}

#[tokio::test]
async fn a_picture_embedded_in_a_lent_song_is_its_cover() {
    let image = png(12, 6);
    let (with, _) = flac_pair(&image);
    let uri = "content://com.example.documents/document/a%3ACovered.flac";
    let (fixture, _held) = lent_at(uri, &with);
    for _ in 0..2 {
        let reply = fixture
            .raw("getCoverArt", &[("id", "s")], HeaderMap::new())
            .await;
        assert_eq!(reply.status, 200);
        assert_eq!(reply.header("content-type"), Some("image/png"));
        assert_eq!(reply.body.as_ref(), image.as_slice());
    }
    // The second is served from the cache, but its version comes from the
    // lent file, which is borrowed again and returned.
    let requests = fixture.host.requests();
    let ops: Vec<&str> = requests.iter().map(|(op, _, _)| op.as_str()).collect();
    assert_eq!(ops, [OPEN_OP, CLOSE_OP, OPEN_OP, CLOSE_OP]);
    assert_eq!(requests[0].2["uri"], uri);
}

/// A FLAC VORBIS_COMMENT block with `entries`.
fn vorbis_comment(entries: &[&str]) -> Vec<u8> {
    let length = |len: usize| u32::try_from(len).expect("length").to_le_bytes();
    let mut block = length(4).to_vec();
    block.extend_from_slice(b"test");
    block.extend_from_slice(&length(entries.len()));
    for entry in entries {
        block.extend_from_slice(&length(entry.len()));
        block.extend_from_slice(entry.as_bytes());
    }
    block
}

#[tokio::test]
async fn lyrics_embedded_in_a_lent_song_are_read() {
    let song = flac(
        4,
        &vorbis_comment(&["LYRICS=[00:01.00]Hello\n[00:02.00]World"]),
    );
    let (fixture, _held) = lent(&song);
    let list = fixture
        .ok("getLyricsBySongId", &[("id", "s")], "lyricsList")
        .await;
    assert_eq!(
        list["structuredLyrics"][0]["line"],
        json!([
            { "start": 1000, "value": "Hello" },
            { "start": 2000, "value": "World" },
        ]),
        "{list}"
    );
    returned(&fixture, 1);
}

#[tokio::test]
async fn a_plain_path_never_asks_the_app() {
    let fixture = library();
    for method in ["stream", "download", "getCoverArt", "getLyricsBySongId"] {
        fixture
            .raw(method, &[("id", "l:2")], HeaderMap::new())
            .await;
    }
    assert!(fixture.host.requests().is_empty());
}
