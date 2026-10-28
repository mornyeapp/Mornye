use mornye_core::metadata::reenrich::Request;
use serde_json::json;

#[test]
fn cover_motion_survives_preview_and_apply_without_becoming_an_audio_tag() {
    let mut request =
        Request::parse(r#"{"album_name":"Album","update_fields":["cover"]}"#).unwrap();
    request.apply(&json!({
        "album_name":"Album", "cover_url":"https://example.invalid/cover.jpg",
        "header_video":"https://example.invalid/motion.m3u8"
    }));
    let metadata = request.result_metadata();
    assert_eq!(
        metadata["header_video"],
        "https://example.invalid/motion.m3u8"
    );
    let reapplied = Request::parse(&metadata.to_string()).unwrap();
    assert_eq!(reapplied.header_video, request.header_video);
    assert!(
        reapplied
            .write_metadata("")
            .keys()
            .all(|key| !key.contains("VIDEO"))
    );
}

#[test]
fn another_release_and_unselected_cover_cannot_supply_motion() {
    for input in [
        r#"{"album_name":"Original Album","update_fields":["cover"]}"#,
        r#"{"album_name":"Other Album","update_fields":["isrc"]}"#,
    ] {
        let mut request = Request::parse(input).unwrap();
        request.apply(&json!({
            "album_name":"Other Album", "header_video":"https://example.invalid/other.m3u8"
        }));
        assert!(request.result_metadata().get("header_video").is_none());
    }
}
