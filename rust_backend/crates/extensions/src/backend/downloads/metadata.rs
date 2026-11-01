//! Download metadata selection and application: host track data, identity matching, and preferred track ids.

use super::matching::{duration_matches, exact_identity, matches_track, strong_identity};
use crate::manifest::ExtensionManifest;
use mornye_core::downloads::DownloadRequest;
use mornye_core::lyrics::matching::{normalize_loose_artist, normalize_title};
use mornye_core::metadata::reenrich::text;
use mornye_core::resolver::titles_match;
use serde_json::Value;
use std::collections::BTreeMap;

pub(super) fn host_track(request: &DownloadRequest) -> Value {
    let mut track = serde_json::to_value(request).expect("download request serialization");
    let object = track.as_object_mut().unwrap();
    object.retain(|key, _| {
        matches!(
            key.as_str(),
            "album_name"
                | "album_artist"
                | "cover_url"
                | "release_date"
                | "track_number"
                | "total_tracks"
                | "disc_number"
                | "total_discs"
                | "duration_ms"
                | "isrc"
                | "genre"
                | "label"
                | "copyright"
                | "composer"
                | "comment"
                | "explicit"
                | "album_type"
                | "upc"
        )
    });
    object.insert("id".into(), request.provider_track_id.clone().into());
    object.insert("name".into(), request.track_name.clone().into());
    object.insert("artists".into(), request.artist_name.clone().into());
    object.insert("provider_id".into(), request.source.clone().into());
    track
}

pub(super) fn download_metadata_fields(
    request: &DownloadRequest,
    response: &Value,
) -> BTreeMap<String, String> {
    let mut fields = BTreeMap::new();
    if let Some(separators) = &request.metadata_separators {
        for key in ["artist", "album_artist", "composer", "genre"] {
            if let Some(value) = separators.get(key) {
                fields.insert(format!("{key}_separator"), value.clone());
            }
        }
    }
    for (tag, field, fallback) in [
        ("TITLE", "title", &request.track_name),
        ("ARTIST", "artist", &request.artist_name),
        ("ALBUM", "album", &request.album_name),
        ("ALBUMARTIST", "album_artist", &request.album_artist),
        ("DATE", "release_date", &request.release_date),
        ("ISRC", "isrc", &request.isrc),
        ("GENRE", "genre", &request.genre),
        ("ORGANIZATION", "label", &request.label),
        ("COPYRIGHT", "copyright", &request.copyright),
        ("COMPOSER", "composer", &request.composer),
        ("COMMENT", "comment", &request.comment),
        ("BARCODE", "upc", &request.upc),
    ] {
        let value = [text(response, field), fallback.as_str()]
            .into_iter()
            .map(str::trim)
            .find(|value| !value.is_empty())
            .unwrap_or_default();
        if !value.is_empty() {
            fields.insert(tag.into(), value.into());
        }
    }
    let positive = |field: &str, fallback: i64| {
        response[field]
            .as_i64()
            .filter(|value| *value > 0)
            .unwrap_or(fallback.max(0))
    };
    for (tag, number, total) in [
        (
            "TRACKNUMBER",
            positive("track_number", request.track_number),
            positive("total_tracks", request.total_tracks),
        ),
        (
            "DISCNUMBER",
            positive("disc_number", request.disc_number),
            positive("total_discs", request.total_discs),
        ),
    ] {
        if number > 0 {
            fields.insert(
                tag.into(),
                if total > 0 {
                    format!("{number}/{total}")
                } else {
                    number.to_string()
                },
            );
        }
    }
    if request.embed_lyrics && !text(response, "lyrics_lrc").is_empty() {
        for tag in ["LYRICS", "UNSYNCEDLYRICS"] {
            fields.insert(tag.into(), text(response, "lyrics_lrc").into());
        }
    }
    if response["explicit"] == true || request.explicit {
        fields.insert("ITUNESADVISORY".into(), "1".into());
    }
    let album_type = [text(response, "album_type"), &request.album_type]
        .into_iter()
        .map(str::trim)
        .find(|value| !value.is_empty())
        .unwrap_or_default();
    if !album_type.is_empty() {
        fields.insert(
            "RELEASETYPE".into(),
            mornye_core::matching::lowercase(album_type),
        );
        if album_type.eq_ignore_ascii_case("compilation") {
            fields.insert("COMPILATION".into(), "1".into());
        }
    }
    fields
}

pub(super) fn apply_metadata(request: &mut DownloadRequest, track: &Value, source: bool) {
    let mut value = serde_json::to_value(&*request).expect("download request serialization");
    for (target, key) in [
        ("track_name", "name"),
        ("artist_name", "artists"),
        ("album_name", "album_name"),
        ("album_artist", "album_artist"),
        ("spotify_id", "id"),
        ("isrc", "isrc"),
        ("cover_url", "cover_url"),
        ("release_date", "release_date"),
        ("genre", "genre"),
        ("label", "label"),
        ("copyright", "copyright"),
        ("composer", "composer"),
        ("comment", "comment"),
        ("album_type", "album_type"),
        ("upc", "upc"),
        ("tidal_id", "tidal_id"),
        ("qobuz_id", "qobuz_id"),
        ("deezer_id", "deezer_id"),
    ] {
        if !source
            && matches!(
                target,
                "track_name"
                    | "artist_name"
                    | "spotify_id"
                    | "comment"
                    | "tidal_id"
                    | "qobuz_id"
                    | "deezer_id"
            )
        {
            continue;
        }
        if (text(&value, target).is_empty()
            || (source
                && matches!(
                    target,
                    "isrc" | "cover_url" | "tidal_id" | "qobuz_id" | "deezer_id"
                )))
            && !text(track, key).is_empty()
        {
            value[target] = track[key].clone();
        }
    }
    for key in [
        "duration_ms",
        "track_number",
        "total_tracks",
        "disc_number",
        "total_discs",
    ] {
        if !source && key == "duration_ms" {
            continue;
        }
        if value[key] == 0 && track[key].as_i64().is_some_and(|number| number > 0) {
            value[key] = track[key].clone();
        }
    }
    if track["explicit"] == true {
        value["explicit"] = true.into();
    }
    *request = serde_json::from_value(value).expect("typed download metadata");
}

pub(super) fn preferred_track_id(
    request: &DownloadRequest,
    manifest: &ExtensionManifest,
    explicit: &str,
) -> String {
    if !explicit.trim().is_empty() {
        return explicit.trim().into();
    }
    let replaces = manifest
        .capabilities
        .get("replacesBuiltInProviders")
        .and_then(Value::as_array);
    for (provider, native) in [
        ("tidal", &request.tidal_id),
        ("qobuz", &request.qobuz_id),
        ("deezer", &request.deezer_id),
        ("spotify", &request.spotify_id),
    ] {
        if replaces.is_some_and(|values| {
            values.iter().any(|value| {
                value
                    .as_str()
                    .is_some_and(|id| id.trim().eq_ignore_ascii_case(provider))
            })
        }) {
            if provider != "spotify" && !native.trim().is_empty() {
                return native.trim().into();
            }
            let id = request.spotify_id.trim();
            if !id.is_empty() {
                let prefix = format!("{provider}:");
                return if id.to_lowercase().starts_with(&prefix) {
                    id[prefix.len()..].into()
                } else {
                    id.into()
                };
            }
        }
    }
    [
        &request.spotify_id,
        &request.tidal_id,
        &request.qobuz_id,
        &request.deezer_id,
    ]
    .into_iter()
    .map(|value| value.trim())
    .find(|value| !value.is_empty())
    .unwrap_or_default()
    .into()
}

pub(super) fn select_download_metadata<'a>(
    request: &DownloadRequest,
    tracks: &'a [Value],
) -> Option<&'a Value> {
    let mut best = None;
    let mut best_score = i32::MIN;
    for track in tracks {
        let isrc = text(track, "isrc").trim();
        let expected = request.isrc.trim();
        let exact = !expected.is_empty() && !isrc.is_empty() && expected.eq_ignore_ascii_case(isrc);
        if !expected.is_empty() && !isrc.is_empty() && !exact {
            continue;
        }
        let mut candidate = track.clone();
        for (target, source) in [
            ("title", "name"),
            ("artist", "artists"),
            ("album", "album_name"),
        ] {
            candidate[target] = text(track, source).into();
        }
        if !matches_track(request, &candidate, false)
            || (!exact && !strong_identity(request, &candidate))
        {
            continue;
        }
        let score = 2000
            + i32::from(exact) * 10000
            + i32::from(exact_identity(
                &request.track_name,
                text(track, "name"),
                normalize_title,
            )) * 400
            + i32::from(exact_identity(
                &request.artist_name,
                text(track, "artists"),
                normalize_loose_artist,
            )) * 320
            + i32::from(
                !request.album_name.is_empty()
                    && !text(track, "album_name").is_empty()
                    && titles_match(&request.album_name, text(track, "album_name")),
            ) * 120
            + i32::from(duration_matches(request, track)) * 80
            + i32::from(!text(track, "isrc").is_empty()) * 40
            + i32::from(!text(track, "album_name").is_empty()) * 30
            + i32::from(!text(track, "release_date").is_empty()) * 30
            + i32::from(
                track["track_number"]
                    .as_i64()
                    .is_some_and(|number| number > 0),
            ) * 10;
        if score > best_score {
            best_score = score;
            best = Some(track);
        }
    }
    best
}
