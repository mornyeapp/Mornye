use super::*;
use crate::RuntimeLimits;
use base64::Engine;

#[test]
fn provider_format_fields_and_returned_path_override_the_planned_extension() {
    let request = DownloadRequest {
        track_name: "Track".into(),
        filename_format: "{title}".into(),
        output_ext: ".flac".into(),
        ..Default::default()
    };
    let manifest = ExtensionManifest::default();
    for (result, expected) in [
        (json!({"file_path":"staged/Track.m4a"}), ".m4a"),
        (json!({"file_path":"staged/Track.MP3"}), ".mp3"),
        (json!({"file_path":"staged/Track.opus"}), ".opus"),
        (json!({"file_path":"staged/Track.mp4"}), ".m4a"),
        (json!({"file_path":"staged/Track.flac"}), ".flac"),
        (
            json!({"file_path":"staged/Track.mp3","actual_container":"audio/mpeg"}),
            ".mp3",
        ),
        (
            json!({"file_path":"staged/Track.m4a","actual_extension":"audio/mp4"}),
            ".m4a",
        ),
        (
            json!({"file_path":"staged/Track.flac","actual_container":"m4a"}),
            ".m4a",
        ),
        (
            json!({"file_path":"staged/Track.flac","output_extension":" MP4 "}),
            ".m4a",
        ),
        (
            json!({"file_path":"staged/Track.m4a","actual_extension":".mp3","output_extension":".flac"}),
            ".mp3",
        ),
        // A FLAC label yields to the container its bytes were probed as.
        (
            json!({"file_path":"staged/Track.flac","actual_extension":".flac","actual_container":"m4a"}),
            ".m4a",
        ),
        (
            json!({"file_path":"staged/Track.flac","output_extension":"flac","actual_container":"mp3"}),
            ".mp3",
        ),
        (json!({}), ".flac"),
    ] {
        let response = success(
            &request,
            &result,
            "planned/Track.flac",
            false,
            &manifest,
            &|| Ok(()),
        )
        .unwrap();
        assert_eq!(response["actual_extension"], expected);
        assert_eq!(response["resolved_file_name"], format!("Track{expected}"));
    }
}

#[test]
fn downloads_publish_the_actual_container_for_regular_and_explicit_working_paths() {
    // Header-only payloads verify byte-preserving publication; real decodable
    // audio and Flutter metadata finalization are exercised on devices.
    for (returned_extension, payload, expected) in [
        ("m4a", b"\0\0\0\x18ftypM4A fixture".as_slice(), ".m4a"),
        ("mp4", b"\0\0\0\x18ftypM4A fixture".as_slice(), ".m4a"),
        ("mp3", b"ID3example audio".as_slice(), ".mp3"),
        ("opus", b"OggSexample audio".as_slice(), ".opus"),
        // A legacy provider may leave the requested suffix on MP4 bytes.
        ("flac", b"\0\0\0\x18ftypM4A fixture".as_slice(), ".m4a"),
        // Or on MP3 bytes, which FLAC tags could not be written into.
        (
            "flac",
            b"ID3\x04\0\0\0\0\0\0\xff\xfb\x90\0fixture".as_slice(),
            ".mp3",
        ),
    ] {
        for explicit_path in [false, true] {
            let directory = tempfile::tempdir().unwrap();
            let encoded = base64::engine::general_purpose::STANDARD.encode(payload);
            let (backend, output) = container_fixture(
                directory.path(),
                &format!(
                    "const path=outputPath.replace(/\\.[^.]+$/,'.{returned_extension}');
                    file.writeBytes(path,{encoded});
                    return {{success:true,file_path:path}};",
                    encoded = json!(encoded),
                ),
            );
            let mut request = container_request(&output, returned_extension == "flac");
            if explicit_path {
                request["output_path"] = output.join("working.flac").to_string_lossy().into();
            }
            let raw = backend
                .download_by_strategy(&request.to_string(), &|| Ok(()))
                .unwrap();
            let response: Value = serde_json::from_str(&raw).unwrap();
            assert_eq!(response["success"], true, "{response}");
            assert_eq!(response["actual_extension"], expected, "{response}");
            assert_eq!(response["resolved_file_name"], format!("Track{expected}"));
            let stem = if explicit_path { "working" } else { "Track" };
            let published = output.join(format!("{stem}{expected}"));
            assert_eq!(response["file_path"], published.to_string_lossy().as_ref());
            assert_eq!(std::fs::read(&published).unwrap(), payload);
            assert!(!output.join(format!("{stem}.flac")).exists());
            // Resolving the corrected suffix must never replace a sibling.
            let second: Value = serde_json::from_str(
                &backend
                    .download_by_strategy(&request.to_string(), &|| Ok(()))
                    .unwrap(),
            )
            .unwrap();
            assert_eq!(second["success"], false, "{second}");
            assert_eq!(std::fs::read(&published).unwrap(), payload);
            backend.shutdown();
        }
    }
}

#[test]
fn a_flac_label_on_unrecognized_bytes_fails_without_publishing() {
    let directory = tempfile::tempdir().unwrap();
    let encoded = base64::engine::general_purpose::STANDARD.encode(b"<!DOCTYPE html>");
    let (backend, output) = container_fixture(
        directory.path(),
        &format!(
            "file.writeBytes(outputPath,{encoded});
            return {{success:true,file_path:outputPath,actual_extension:'.flac'}};",
            encoded = json!(encoded),
        ),
    );
    let raw = backend
        .download_by_strategy(&container_request(&output, true).to_string(), &|| Ok(()))
        .unwrap();
    let response: Value = serde_json::from_str(&raw).unwrap();
    assert_eq!(response["success"], false, "{response}");
    assert!(
        text(&response, "error").contains("is not FLAC audio"),
        "{response}"
    );
    assert_eq!(std::fs::read_dir(&output).unwrap().count(), 0);
    backend.shutdown();
}

/// A download provider running `body` as its download function, with an
/// allowed output directory.
fn container_fixture(directory: &Path, body: &str) -> (Backend, std::path::PathBuf) {
    let source = directory.join("sources/example.audio");
    std::fs::create_dir_all(&source).unwrap();
    std::fs::write(
        source.join("manifest.json"),
        json!({"name":"example.audio","version":"1",
            "description":"Generic native-container fixture","type":["download_provider"],
            "permissions":{"file":true},"skipMetadataEnrichment":true})
        .to_string(),
    )
    .unwrap();
    std::fs::write(
        source.join("index.js"),
        format!(
            "registerExtension({{checkAvailability(){{return {{available:true,track_id:'track'}};}},
            download(trackId,quality,outputPath){{{body}}}}});"
        ),
    )
    .unwrap();
    let backend = Backend::new(
        &directory.join("sources"),
        &directory.join("data"),
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
        "1",
        RuntimeLimits::default(),
    )
    .unwrap();
    backend.load_all().unwrap();
    backend.set_enabled("example.audio", true).unwrap();
    backend.download_manifest("example.audio").unwrap();
    let output = directory.join("output");
    std::fs::create_dir_all(&output).unwrap();
    backend
        .environment()
        .set_allowed_download_directories(std::slice::from_ref(&output))
        .unwrap();
    (backend, output)
}

fn container_request(output: &Path, embed_metadata: bool) -> Value {
    json!({"service":"example.audio","provider_track_id":"track",
        "use_extensions":true,"use_fallback":false,"output_dir":output,
        "track_name":"Track","artist_name":"Artist","album_name":"Album",
        "filename_format":"{title}","output_ext":".flac","quality":"LOSSLESS",
        "embed_metadata":embed_metadata,"embed_lyrics":false})
}
