use cap_std::fs::OpenOptions;
use mornye_core::downloads::DownloadRequest;
use mornye_core::lyrics::matching::normalize_loose_artist;
use mornye_core::matching::lowercase;
use mornye_core::metadata::reenrich::{self, text};
use mornye_core::resolver::{artists_match, titles_match, track_identity_title};
use mornye_providers::resolver::Check;
use serde_json::{Value, json};
use std::io::{Seek, SeekFrom};

pub(super) fn probe_result(
    files: &crate::files::ExtensionFiles,
    result: &mut Value,
    album_pending: bool,
    check: &Check<'_>,
) -> Result<&'static str, String> {
    let path = text(result, "file_path").to_owned();
    let file = files
        .resolve_legacy(&path)?
        .open(OpenOptions::new().read(true));
    let mut container = "";
    if let Ok(mut file) = file {
        // Provider labels may disagree with the bytes, which decide the
        // published suffix. Quality is probed only for FLAC/MP4. Missing
        // album folders may use tags from any supported container,
        // including undecoded audio.
        container = mornye_core::tags::sniff_container(&mut file).unwrap_or_default();
        let quality = matches!(container, "flac" | "m4a");
        if !container.is_empty() {
            result["actual_container"] = container.into();
        }
        let album = album_pending && text(result, "album").trim().is_empty();
        if (quality || album)
            && file.seek(SeekFrom::Start(0)).is_ok()
            && let Ok(metadata) = mornye_core::tags::read_file_metadata(&mut file, &path, "", check)
        {
            if quality {
                for key in ["bit_depth", "sample_rate", "audio_codec"] {
                    result[key] = metadata[key].clone();
                }
            }
            if album {
                result["album"] = text(&metadata, "album").trim().into();
            }
        }
    }
    check()?;
    Ok(container)
}

pub(super) fn matches_track(request: &DownloadRequest, result: &Value, skip_names: bool) -> bool {
    let exact = !request.isrc.is_empty()
        && !text(result, "isrc").is_empty()
        && request
            .isrc
            .trim()
            .eq_ignore_ascii_case(text(result, "isrc").trim());
    let identity = reenrich::Request {
        track_name: request.track_name.clone(),
        artist_name: request.artist_name.clone(),
        isrc: request.isrc.clone(),
        duration_ms: request.duration_ms,
        ..Default::default()
    };
    let mut candidate = result.clone();
    candidate["name"] = result.get("title").cloned().unwrap_or(json!(""));
    candidate["artists"] = result.get("artist").cloned().unwrap_or(json!(""));
    // Skipping names does not permit truncated previews or a duration mismatch.
    if skip_names && request.duration_ms / 1000 <= 0 {
        return true;
    }
    if skip_names
        && (result["duration_ms"].as_i64().unwrap_or_default() / 1000 <= 0
            || (request.duration_ms / 1000)
                .abs_diff(result["duration_ms"].as_i64().unwrap_or_default() / 1000)
                <= 10)
    {
        return true;
    }
    if !identity.verified(&candidate) {
        return false;
    }
    if !exact
        && !skip_names
        && !request.album_name.is_empty()
        && !text(result, "album").is_empty()
        && !titles_match(&request.album_name, text(result, "album"))
    {
        if !request.isrc.is_empty() && !text(result, "isrc").is_empty() {
            return false;
        }
        return strong_identity(request, result);
    }
    true
}

pub(super) fn exact_identity(expected: &str, found: &str, normalize: fn(&str) -> String) -> bool {
    let (left, right) = (normalize(expected), normalize(found));
    if !left.is_empty() && !right.is_empty() {
        left == right
    } else {
        lowercase(expected.trim()) == lowercase(found.trim())
    }
}

pub(super) fn duration_matches(request: &DownloadRequest, track: &Value) -> bool {
    let expected = request.duration_ms / 1000;
    let actual = track["duration_ms"].as_i64().unwrap_or_default() / 1000;
    expected > 0 && actual > 0 && expected.abs_diff(actual) <= 10
}

pub(super) fn strong_identity(request: &DownloadRequest, track: &Value) -> bool {
    let title = text(track, "title");
    let artist = text(track, "artist");
    !request.track_name.is_empty()
        && !title.is_empty()
        && !request.artist_name.is_empty()
        && !artist.is_empty()
        && exact_identity(&request.track_name, title, track_identity_title)
        && (exact_identity(&request.artist_name, artist, normalize_loose_artist)
            || (artists_match(&request.artist_name, artist) && duration_matches(request, track)))
}
