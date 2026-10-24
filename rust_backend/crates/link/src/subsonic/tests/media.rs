use super::*;
use crate::subsonic::media::{ByteRange, Codec, Transcode, ffmpeg_args, parse_range, plan};
use std::time::{Duration, Instant};

fn catalog_with(extra: Value) -> Catalog {
    let mut row = json!({
        "id": "s", "title": "T", "artist": "A", "path": "/m/s.flac", "suffix": "flac",
    });
    if let (Some(object), Value::Object(extra)) = (row.as_object_mut(), extra) {
        object.extend(extra);
    }
    Catalog::read(format!("{{\"catalogVersion\":1}}\n{row}").as_bytes()).expect("catalog")
}

fn decide(
    catalog: &Catalog,
    format: Option<&str>,
    cap: Option<u32>,
    offset: Option<f64>,
) -> Option<(Codec, u32, Option<f64>)> {
    plan(catalog.song("s").expect("song"), format, cap, offset)
        .map(|plan| (plan.codec, plan.kbps, plan.offset_secs))
}

fn which_ffmpeg() -> Option<PathBuf> {
    let output = std::process::Command::new("which")
        .arg("ffmpeg")
        .output()
        .ok()?;
    let path = String::from_utf8(output.stdout).ok()?;
    let path = path.trim();
    (output.status.success() && !path.is_empty()).then(|| PathBuf::from(path))
}

/// A sine WAV of `seconds` at `rate` Hz.
fn sine_wav(ffmpeg: &Path, path: &Path, seconds: u32, rate: u32) {
    let status = std::process::Command::new(ffmpeg)
        .args(["-nostdin", "-loglevel", "error", "-f", "lavfi", "-i"])
        .arg(format!(
            "sine=frequency=440:duration={seconds}:sample_rate={rate}"
        ))
        .arg("-y")
        .arg(path)
        .status()
        .expect("ffmpeg runs");
    assert!(status.success());
}

#[test]
fn ranges_cover_single_suffix_and_open_forms() {
    assert_eq!(parse_range("bytes=1-2", 4), ByteRange::Partial(1, 2));
    assert_eq!(parse_range("BYTES=0-0", 4), ByteRange::Partial(0, 0));
    assert_eq!(parse_range("bytes=2-", 4), ByteRange::Partial(2, 3));
    assert_eq!(parse_range("bytes=-1", 4), ByteRange::Partial(3, 3));
    assert_eq!(parse_range("bytes=-10", 4), ByteRange::Partial(0, 3));
    assert_eq!(parse_range("bytes=0-100", 4), ByteRange::Partial(0, 3));
    assert_eq!(parse_range("bytes=4-", 4), ByteRange::Unsatisfiable);
    assert_eq!(parse_range("bytes=-0", 4), ByteRange::Unsatisfiable);
    assert_eq!(parse_range("bytes=0-0", 0), ByteRange::Unsatisfiable);
    assert_eq!(parse_range("bytes=0-1,2-3", 4), ByteRange::Full);
    assert_eq!(parse_range("bytes=2-1", 4), ByteRange::Full);
    assert_eq!(parse_range("items=0-1", 4), ByteRange::Full);
    assert_eq!(parse_range("bytes=x-1", 4), ByteRange::Full);
    assert_eq!(parse_range("bytes", 4), ByteRange::Full);
}

#[test]
fn transcode_plans_follow_format_and_bit_rate_caps() {
    let flac = catalog_with(json!({ "bitRate": 1000 }));
    assert_eq!(decide(&flac, None, None, None), None);
    assert_eq!(decide(&flac, Some("raw"), Some(128), None), None);
    assert_eq!(decide(&flac, Some(""), None, None), None);
    assert_eq!(decide(&flac, Some("flac"), None, None), None);
    assert_eq!(
        decide(&flac, Some("mp3"), None, None),
        Some((Codec::Mp3, 320, None))
    );
    assert_eq!(
        decide(&flac, None, Some(128), None),
        Some((Codec::Mp3, 128, None))
    );
    assert_eq!(decide(&flac, None, Some(2000), None), None);
    assert_eq!(decide(&flac, None, Some(0), None), None);
    assert_eq!(
        decide(&flac, Some("opus"), Some(96), None),
        Some((Codec::Opus, 96, None))
    );
    assert_eq!(
        decide(&flac, Some("ogg"), None, None),
        Some((Codec::Opus, 160, None))
    );
    assert_eq!(
        decide(&flac, Some("aac"), Some(16), None),
        Some((Codec::Aac, 32, None))
    );
    assert_eq!(
        decide(&flac, Some("mp3"), None, Some(12.5)),
        Some((Codec::Mp3, 320, Some(12.5)))
    );
    assert_eq!(
        decide(&flac, Some("mp3"), None, Some(-1.0)),
        Some((Codec::Mp3, 320, None))
    );
    let mp3 = catalog_with(json!({ "suffix": "mp3", "bitRate": 256 }));
    assert_eq!(decide(&mp3, Some("mp3"), None, None), None, "already MP3");
    assert_eq!(decide(&mp3, Some("mp3"), Some(320), None), None);
    assert_eq!(
        decide(&mp3, Some("mp3"), Some(128), None),
        Some((Codec::Mp3, 128, None))
    );
    assert_eq!(
        decide(&mp3, None, Some(128), None),
        Some((Codec::Mp3, 128, None))
    );
    let unknown_lossless = catalog_with(json!({}));
    assert_eq!(
        decide(&unknown_lossless, None, Some(320), None),
        Some((Codec::Mp3, 320, None))
    );
    let unknown_lossy = catalog_with(json!({ "suffix": "ogg" }));
    assert_eq!(decide(&unknown_lossy, None, Some(128), None), None);
    let estimated =
        catalog_with(json!({ "suffix": "m4a", "size": 8_000_000, "durationMs": 200_000 }));
    assert_eq!(
        decide(&estimated, None, Some(256), None),
        Some((Codec::Mp3, 256, None))
    );
    assert_eq!(decide(&estimated, None, Some(320), None), None);
}

#[test]
fn ffmpeg_arguments_write_the_target_to_stdout() {
    let strings = |args: Vec<std::ffi::OsString>| -> Vec<String> {
        args.into_iter()
            .map(|arg| arg.to_string_lossy().into_owned())
            .collect()
    };
    let opus = Transcode {
        codec: Codec::Opus,
        kbps: 96,
        offset_secs: Some(12.5),
    };
    assert_eq!(
        strings(ffmpeg_args(Path::new("/m/a b.flac"), &opus)),
        [
            "-nostdin",
            "-hide_banner",
            "-loglevel",
            "error",
            "-ss",
            "12.500",
            "-i",
            "/m/a b.flac",
            "-map",
            "0:a:0",
            "-vn",
            "-sn",
            "-dn",
            "-map_metadata",
            "-1",
            "-ac",
            "2",
            "-c:a",
            "libopus",
            "-b:a",
            "96k",
            "-f",
            "ogg",
            "pipe:1",
        ]
    );
    let mp3 = strings(ffmpeg_args(
        Path::new("/m/x.wav"),
        &Transcode {
            codec: Codec::Mp3,
            kbps: 320,
            offset_secs: None,
        },
    ));
    assert!(!mp3.contains(&"-ss".to_owned()));
    assert!(mp3.ends_with(&[
        "-c:a".to_owned(),
        "libmp3lame".to_owned(),
        "-b:a".to_owned(),
        "320k".to_owned(),
        "-f".to_owned(),
        "mp3".to_owned(),
        "pipe:1".to_owned(),
    ]));
    let aac = strings(ffmpeg_args(
        Path::new("/m/x.wav"),
        &Transcode {
            codec: Codec::Aac,
            kbps: 256,
            offset_secs: None,
        },
    ));
    assert!(aac.contains(&"adts".to_owned()));
    assert!(aac.contains(&"aac".to_owned()));
}

#[tokio::test]
async fn stream_serves_the_file_with_single_ranges() {
    let fixture = library();
    let full = fixture
        .raw("stream", &[("id", "l:1")], HeaderMap::new())
        .await;
    assert_eq!(full.status, 200);
    assert_eq!(full.header("content-type"), Some("audio/flac"));
    assert_eq!(full.header("content-length"), Some("4"));
    assert_eq!(full.header("accept-ranges"), Some("bytes"));
    assert_eq!(full.body.as_ref(), [0, 1, 2, 3]);
    let part = fixture
        .raw(
            "stream",
            &[("id", "l:1"), ("format", "raw")],
            headers(&[("range", "bytes=1-2")]),
        )
        .await;
    assert_eq!(part.status, 206);
    assert_eq!(part.header("content-range"), Some("bytes 1-2/4"));
    assert_eq!(part.header("content-length"), Some("2"));
    assert_eq!(part.body.as_ref(), [1, 2]);
    let unsatisfiable = fixture
        .raw(
            "stream",
            &[("id", "l:1")],
            headers(&[("range", "bytes=9-")]),
        )
        .await;
    assert_eq!(unsatisfiable.status, 416);
    assert_eq!(unsatisfiable.header("content-range"), Some("bytes */4"));
    assert!(unsatisfiable.body.is_empty());
    let multi = fixture
        .raw(
            "stream",
            &[("id", "l:1")],
            headers(&[("range", "bytes=0-0,2-3")]),
        )
        .await;
    assert_eq!(multi.status, 200);
    assert_eq!(multi.body.len(), 4);
}

#[tokio::test]
async fn download_serves_the_original_with_its_file_name() {
    let fixture = library();
    let full = fixture
        .raw("download", &[("id", "l:1")], HeaderMap::new())
        .await;
    assert_eq!(full.status, 200);
    assert_eq!(
        full.header("content-disposition"),
        Some("attachment; filename*=UTF-8''audio.flac")
    );
    assert_eq!(full.body.as_ref(), [0, 1, 2, 3]);
    let tail = fixture
        .raw(
            "download",
            &[("id", "l:1")],
            headers(&[("range", "bytes=-1")]),
        )
        .await;
    assert_eq!(tail.status, 206);
    assert_eq!(tail.body.as_ref(), [3]);
}

#[tokio::test]
async fn missing_songs_and_files_answer_404_with_error_70() {
    let fixture = Fixture::new(|dir| {
        vec![json!({
            "id": "gone", "title": "Gone", "artist": "A",
            "path": dir.join("missing.flac").to_string_lossy(),
        })]
    });
    for method in ["stream", "download"] {
        for id in ["gone", "unknown"] {
            let reply = fixture
                .raw(method, &[("f", "json"), ("id", id)], HeaderMap::new())
                .await;
            assert_eq!(reply.status, 404, "{method} {id}");
            assert_eq!(reply.subsonic()["error"]["code"], 70);
        }
    }
    let no_id = fixture
        .raw("stream", &[("f", "json")], HeaderMap::new())
        .await;
    assert_eq!(no_id.status, 200);
    assert_eq!(no_id.subsonic()["error"]["code"], 10);
}

#[tokio::test]
async fn transcode_requests_fall_back_to_the_file_without_ffmpeg() {
    for ffmpeg in [None, Some(PathBuf::from("/nonexistent/ffmpeg"))] {
        let fixture = Fixture::with_ffmpeg(ffmpeg, |dir| {
            let audio = write_file(dir, "a.flac", &[9, 8, 7]);
            vec![json!({ "id": "s", "title": "T", "artist": "A", "path": audio, "bitRate": 900 })]
        });
        let reply = fixture
            .raw(
                "stream",
                &[("id", "s"), ("format", "mp3")],
                HeaderMap::new(),
            )
            .await;
        assert_eq!(reply.status, 200);
        assert_eq!(reply.header("content-type"), Some("audio/flac"));
        assert_eq!(reply.body.as_ref(), [9, 8, 7]);
    }
}

#[tokio::test]
async fn transcodes_with_ffmpeg_when_available() {
    let Some(ffmpeg) = which_ffmpeg() else {
        eprintln!("skipping: ffmpeg not found");
        return;
    };
    let fixture = Fixture::with_ffmpeg(Some(ffmpeg.clone()), |dir| {
        let wav = dir.join("tone.wav");
        sine_wav(&ffmpeg, &wav, 2, 44_100);
        vec![json!({
            "id": "tone", "title": "Tone", "artist": "A", "path": wav.to_string_lossy(),
            "durationMs": 2000,
        })]
    });
    let reply = fixture
        .raw(
            "stream",
            &[("id", "tone"), ("format", "mp3"), ("maxBitRate", "128")],
            headers(&[("range", "bytes=0-10")]),
        )
        .await;
    assert_eq!(reply.status, 200, "transcodes ignore Range");
    assert_eq!(reply.header("content-type"), Some("audio/mpeg"));
    assert_eq!(reply.header("content-length"), None);
    assert_eq!(reply.header("accept-ranges"), Some("none"));
    assert!(
        reply.body.starts_with(b"ID3") || reply.body.first() == Some(&0xFF),
        "an MP3 stream"
    );
    let offset = fixture
        .raw(
            "stream",
            &[
                ("id", "tone"),
                ("format", "mp3"),
                ("maxBitRate", "128"),
                ("timeOffset", "1"),
            ],
            HeaderMap::new(),
        )
        .await;
    assert!(
        offset.body.len() < reply.body.len(),
        "{} >= {}",
        offset.body.len(),
        reply.body.len()
    );
    let raw = fixture
        .raw(
            "stream",
            &[("id", "tone"), ("format", "raw")],
            HeaderMap::new(),
        )
        .await;
    assert_eq!(raw.header("content-type"), Some("audio/wav"));
}

#[tokio::test]
async fn dropping_a_transcode_body_stops_ffmpeg() {
    let Some(ffmpeg) = which_ffmpeg() else {
        eprintln!("skipping: ffmpeg not found");
        return;
    };
    let running = |pattern: &str| -> Option<bool> {
        std::process::Command::new("pgrep")
            .args(["-f", pattern])
            .output()
            .ok()
            .map(|output| output.status.success())
    };
    if running("^$").is_none() {
        eprintln!("skipping: pgrep not found");
        return;
    }
    let mut marker = String::new();
    let fixture = Fixture::with_ffmpeg(Some(ffmpeg.clone()), |dir| {
        // Long enough that ffmpeg blocks on the unread pipe.
        let wav = dir.join("long-tone-for-drop-test.wav");
        sine_wav(&ffmpeg, &wav, 300, 8000);
        marker = wav.to_string_lossy().into_owned();
        vec![json!({ "id": "long", "title": "Long", "artist": "A", "path": marker })]
    });
    let response = fixture
        .response(
            "stream",
            &[("id", "long"), ("format", "opus")],
            HeaderMap::new(),
        )
        .await;
    assert_eq!(response.status(), 200);
    let mut body = response.into_body();
    let frame = body.frame().await.expect("a frame").expect("data");
    assert!(frame.is_data());
    assert_eq!(running(&marker), Some(true), "ffmpeg runs while streaming");
    drop(body);
    let deadline = Instant::now() + Duration::from_secs(5);
    while running(&marker) == Some(true) {
        assert!(
            Instant::now() < deadline,
            "ffmpeg still running after the body was dropped"
        );
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
}
