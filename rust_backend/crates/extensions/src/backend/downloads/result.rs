use super::paths::{album_folder, filename};
use crate::download::native_error_response;
use crate::manifest::ExtensionManifest;
use mornye_core::downloads::DownloadRequest;
use mornye_core::metadata::reenrich::text;
use mornye_providers::resolver::Check;
use serde_json::{Value, json};
use std::path::Path;

pub(super) fn success(
    request: &DownloadRequest,
    result: &Value,
    path: &str,
    exists: bool,
    manifest: &ExtensionManifest,
    check: &Check<'_>,
) -> Result<Value, String> {
    let mut response = json!({"success":true,"message":if exists { "File already exists".into() } else { format!("Downloaded from {}", manifest.name) },
        "file_path":path,"provider_track_id":request.provider_track_id,"already_exists":exists,"service":manifest.name,
        "actual_bit_depth":result["bit_depth"],"actual_sample_rate":result["sample_rate"],
        "audio_codec":text(result, "audio_codec").trim(),"actual_container":text(result, "actual_container").trim(),
        "requires_container_conversion":result["requires_container_conversion"] == true,
        "skip_metadata_enrichment":manifest.skip_metadata_enrichment,
        "explicit":request.explicit || result["explicit"] == true});
    for (key, requested, prefer_request) in [
        ("title", request.track_name.trim(), true),
        // Preserve source credits: an audio provider may list only the lead artist.
        ("artist", request.artist_name.trim(), true),
        ("album", request.album_name.trim(), true),
        ("album_artist", request.album_artist.as_str(), true),
        ("release_date", request.release_date.trim(), true),
        ("cover_url", request.cover_url.trim(), true),
        ("isrc", request.isrc.as_str(), false),
        ("genre", request.genre.as_str(), false),
        ("label", request.label.as_str(), false),
        ("copyright", request.copyright.as_str(), false),
        ("composer", request.composer.as_str(), false),
        ("comment", request.comment.trim(), true),
        ("album_type", request.album_type.as_str(), false),
        ("upc", request.upc.as_str(), false),
    ] {
        let provided = text(result, key);
        response[key] = if (prefer_request && !requested.is_empty()) || provided.is_empty() {
            requested
        } else {
            provided
        }
        .into();
    }
    for (key, value) in [
        ("track_number", request.track_number),
        ("disc_number", request.disc_number),
        ("total_tracks", request.total_tracks),
        ("total_discs", request.total_discs),
    ] {
        response[key] = if value != 0 {
            json!(value)
        } else {
            result.get(key).cloned().unwrap_or(json!(0))
        };
    }
    for key in ["lyrics_lrc", "decryption_key", "decryption"] {
        if let Some(value) = result.get(key) {
            response[key] = value.clone();
        }
    }
    let container = text(result, "actual_container")
        .trim()
        .trim_start_matches('.');
    let container = if [
        "flac", "m4a", "mp4", "mp3", "opus", "ogg", "aac", "wav", "aiff", "aif", "aifc",
    ]
    .iter()
    .any(|extension| container.eq_ignore_ascii_case(extension))
    {
        container
    } else {
        ""
    };
    let extension = [
        text(result, "actual_extension"),
        text(result, "output_extension"),
        container,
    ]
    .into_iter()
    .map(|value| value.trim().to_lowercase())
    .find(|value| !value.is_empty() && !value.contains(['/', '\\']))
    .unwrap_or_else(|| {
        // Providers may only return a renamed file_path, without explicit
        // format fields. The planned path still carries the requested quality.
        [text(result, "file_path"), path]
            .into_iter()
            .filter_map(|path| Path::new(path).extension())
            .map(|extension| extension.to_string_lossy().trim().to_lowercase())
            .find(|extension| !extension.is_empty())
            .unwrap_or_default()
    });
    // A FLAC label on other audio bytes yields to the bytes, since FLAC tags
    // cannot be written into them.
    let extension = if extension.trim_start_matches('.') == "flac" && !container.is_empty() {
        container.to_lowercase()
    } else {
        extension
    };
    if !extension.is_empty() {
        let extension = format!(".{}", extension.trim_start_matches('.'));
        response["actual_extension"] = if extension == ".mp4" {
            ".m4a".into()
        } else {
            extension.into()
        };
    }
    let mut named = request.clone();
    if !text(result, "isrc").trim().is_empty() {
        named.isrc = text(result, "isrc").trim().into();
    }
    response["resolved_file_name"] =
        filename(&named, text(&response, "actual_extension"), check)?.into();
    response["resolved_album_folder"] = album_folder(request, text(&response, "album")).into();
    Ok(response)
}

pub(super) fn compact(mut value: Value) -> Value {
    value.as_object_mut().unwrap().retain(|key, value| {
        matches!(key.as_str(), "success" | "message")
            || !(value.is_null() || value == "" || value == false || value == 0)
    });
    value
}

pub(super) fn failure(service: &str, message: &str, kind: &str, retry: i64) -> Value {
    let mut response = native_error_response(message);
    if !kind.is_empty() {
        response["error_type"] = kind.into();
    }
    response["service"] = service.into();
    response["retry_after_seconds"] = retry.into();
    response
}

pub(super) fn stopped(service: &str, availability: &Value, message: &str) -> Value {
    let reason = if !text(availability, "reason").trim().is_empty() {
        text(availability, "reason").trim()
    } else if !message.is_empty() {
        message
    } else {
        "extension requested no further fallback"
    };
    let kind = native_error_response(reason);
    failure(
        service,
        &format!("Fallback stopped by {service}: {reason}"),
        if kind["error_type"] == "unknown" {
            "extension_error"
        } else {
            text(&kind, "error_type")
        },
        0,
    )
}

pub(super) fn storage_failure(kind: &str, message: &str) -> bool {
    if kind.eq_ignore_ascii_case("permission") {
        return true;
    }
    let message = message.to_lowercase();
    [
        "operation not permitted",
        "permission denied",
        "read-only file system",
        "failed to create file",
        "failed to create directory",
    ]
    .into_iter()
    .any(|part| message.contains(part))
}
