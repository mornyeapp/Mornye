use super::*;
use crate::RuntimeLimits;

const ID: &str = "example.motion";
const SOURCE: &str = r#"
function searchTracks() {
    return {tracks: [{id: "track-1", name: "Song", artists: "Artist",
        album_name: "Album", album_id: "album-1",
        images: "https://example.invalid/still.jpg"}]};
}
function getTrack(id) {
    return {id, name: "Song", artists: "Artist", album_name: "Album", album_id: "album-1"};
}
function getAlbum(id) {
    if (id === "unavailable") throw new Error("optional artwork unavailable");
    return {id, name: "Album", artists: "Artist", tracks: [],
        cover_url: "https://example.invalid/still.jpg",
        header_video: "https://example.invalid/motion.m3u8"};
}
registerExtension({searchTracks, getTrack, getAlbum});
"#;

fn fixture() -> (tempfile::TempDir, Backend) {
    let root = tempfile::tempdir().unwrap();
    let source = root.path().join("sources").join(ID);
    std::fs::create_dir_all(&source).unwrap();
    std::fs::write(
        source.join("manifest.json"),
        json!({"name":ID,"displayName":"Example Motion","version":"1",
            "description":"Generic motion metadata fixture","type":["metadata_provider"]})
        .to_string(),
    )
    .unwrap();
    std::fs::write(source.join("index.js"), SOURCE).unwrap();
    let backend = Backend::new(
        &root.path().join("sources"),
        &root.path().join("data"),
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
        "1",
        RuntimeLimits::default(),
    )
    .unwrap();
    backend.load_all().unwrap();
    backend.set_enabled(ID, true).unwrap();
    (root, backend)
}

fn request() -> Request {
    Request::parse(
        r#"{"track_name":"Song","artist_name":"Artist","album_name":"Album",
        "update_fields":["cover"]}"#,
    )
    .unwrap()
}

#[test]
fn cover_preview_resolves_album_motion_without_replacing_the_still_image() {
    let (_root, backend) = fixture();
    let mut request = request();
    request.file_path = "unused-preview.flac".into();
    request.search_online = true;
    request.preview_only = true;
    let raw = backend
        .reenrich_file(&serde_json::to_string(&request).unwrap(), &|| Ok(()))
        .unwrap();
    let response: Value = serde_json::from_str(&raw).unwrap();
    assert_eq!(response["method"], "preview");
    assert_eq!(
        response["enriched_metadata"]["cover_url"],
        "https://example.invalid/still.jpg"
    );
    assert_eq!(
        response["enriched_metadata"]["header_video"],
        "https://example.invalid/motion.m3u8"
    );
}

#[test]
fn missing_album_id_uses_provider_track_details() {
    let (_root, backend) = fixture();
    let video = backend.reenrich_motion_artwork(
        &request(),
        &json!({"id":"track-1","provider_id":ID}),
        &|| Ok(()),
    );
    assert_eq!(
        video.as_deref(),
        Some("https://example.invalid/motion.m3u8")
    );
}

#[test]
fn optional_failures_and_different_releases_do_not_supply_video() {
    let (_root, backend) = fixture();
    let track = json!({"id":"track-1","album_id":"unavailable","provider_id":ID});
    assert!(
        backend
            .reenrich_motion_artwork(&request(), &track, &|| Ok(()))
            .is_none()
    );
    let mut request = request();
    request.album_name = "Another Release".into();
    let track = json!({"id":"track-1","album_id":"album-1","provider_id":ID});
    assert!(
        backend
            .reenrich_motion_artwork(&request, &track, &|| Ok(()))
            .is_none()
    );
}
