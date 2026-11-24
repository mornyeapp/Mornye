//! Library scan DTOs composed from the existing tag and quality readers.

use super::{AudioMetadata, CoverArt, file::ObservedReader, read_container_format, read_tags};
use crate::lyrics::lrc::has_usable_content;
use crate::media::{
    adts_quality, mp3_quality, ogg_quality, probe_mp4_quality, probe_quality, riff_quality,
};
use serde_json::{Value, json};
use std::io::{Read, Seek, SeekFrom};
use std::path::Path;

pub fn library_extension(path: &str, hint: &str) -> String {
    let suffix = |path: &str| {
        let name = path.rsplit('/').next().unwrap_or_default();
        name.rfind('.')
            .map(|offset| name[offset + 1..].to_lowercase())
    };
    suffix(path).or_else(|| suffix(hint)).unwrap_or_default()
}

pub fn library_id(path: &str) -> String {
    let hash = path.chars().fold(5381_u32, |hash, value| {
        hash.wrapping_mul(33).wrapping_add(value as u32)
    });
    format!("lib_{hash:x}")
}

fn filename(path: &str) -> String {
    let name = Path::new(path)
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or(path);
    name[..name.rfind('.').unwrap_or(name.len())].into()
}

/// Missing/unsupported audio still produces a filename-derived track in Go.
/// WAV/AIFF use defaults even when their tag/quality readers fail.
pub fn library_metadata(path: &str, hint: &str, scan_time: &str, mod_time: i64) -> Value {
    let mut format = library_extension(path, hint);
    let riff = matches!(format.as_str(), "wav" | "aiff" | "aif" | "aifc");
    if matches!(format.as_str(), "aiff" | "aif" | "aifc") {
        format = "aiff".into();
    }
    let name = filename(if hint.is_empty() { path } else { hint });
    let mut result = json!({
        "id": library_id(path), "filePath":path, "scannedAt":scan_time,
        "trackName":name, "artistName":"Unknown Artist", "albumName":"Unknown Album",
        "hasLyrics":false,
    });
    if !format.is_empty() {
        result["format"] = format.into();
    }
    if mod_time != 0 {
        result["fileModTime"] = mod_time.into();
    }
    if !riff {
        result["metadataFromFilename"] = true.into();
        let numeric = |s: &str| !s.is_empty() && s.bytes().all(|c| c.is_ascii_digit());
        if let Some((first, title)) = name.split_once(" - ") {
            result["trackName"] = title.into();
            if first.len() > 3 || !numeric(first) {
                result["artistName"] = first.into();
            }
        } else if name.len() > 3 && name.as_bytes()[..2].iter().all(u8::is_ascii_digit) {
            result["trackName"] = name[2..].trim_start_matches([' ', '.', '-']).into();
        }
        let parent = Path::new(path).parent().unwrap_or(Path::new("."));
        let album = parent
            .file_name()
            .and_then(|name| name.to_str())
            .unwrap_or_else(|| if parent == Path::new("/") { "/" } else { "." });
        if !matches!(album, "" | "." | "fd" | "self") {
            result["albumName"] = album.into();
        }
    }
    result
}

pub fn read_library_metadata(
    file: &mut (impl Read + Seek),
    path: &str,
    hint: &str,
    scan_time: &str,
    mod_time: i64,
    check: &dyn Fn() -> Result<(), String>,
) -> Result<Value, String> {
    read_observed(file, path, hint, scan_time, mod_time, check, None)
}

/// On a cover-cache miss, scans collect embedded artwork during the tag pass
/// (FLAC, MP3, MP4/M4A, AAC, Ogg and Opus) instead of reading the file again.
pub fn read_library_metadata_with_cover(
    file: &mut (impl Read + Seek),
    path: &str,
    hint: &str,
    scan_time: &str,
    mod_time: i64,
    check: &dyn Fn() -> Result<(), String>,
) -> Result<(Value, Option<CoverArt>), String> {
    let mut cover = None;
    let metadata = read_observed(
        file,
        path,
        hint,
        scan_time,
        mod_time,
        check,
        Some(&mut cover),
    )?;
    Ok((metadata, cover))
}

fn read_observed(
    file: &mut (impl Read + Seek),
    path: &str,
    hint: &str,
    scan_time: &str,
    mod_time: i64,
    check: &dyn Fn() -> Result<(), String>,
    cover: Option<&mut Option<CoverArt>>,
) -> Result<Value, String> {
    check()?;
    let mut reader = ObservedReader {
        file,
        check,
        failure: None,
    };
    let result = read(&mut reader, path, hint, scan_time, mod_time, cover);
    if let Some(error) = reader.failure {
        return Err(error);
    }
    check()?;
    result
}

fn read(
    file: &mut (impl Read + Seek),
    path: &str,
    hint: &str,
    scan_time: &str,
    mod_time: i64,
    mut cover: Option<&mut Option<CoverArt>>,
) -> Result<Value, String> {
    let mut result = library_metadata(path, hint, scan_time, mod_time);
    let extension = library_extension(path, hint);
    let format = read_container_format(file, &extension)?;
    let metadata = read_tags(file, format, &|| Ok(()), cover.as_deref_mut());
    let tagged = metadata.is_ok();
    if !tagged
        && !matches!(format, "m4a" | "mp4" | "aac" | "adts" | "mp3")
        && let Some(cover) = cover
    {
        *cover = None;
    }
    if let Ok(metadata) = metadata {
        apply_tags(&mut result, metadata, format, path, hint)?;
    } else if let Err(error) = metadata {
        result["metadataReadError"] = error.into();
    }
    // Missing ID3 or MP4 tags do not mean the audio stream is unreadable.
    if !tagged
        && !matches!(
            format,
            "mp3" | "m4a" | "mp4" | "aac" | "adts" | "wav" | "aiff" | "aif" | "aifc"
        )
    {
        return Ok(result);
    }
    let size = file
        .seek(SeekFrom::End(0))
        .map_err(|error| error.to_string())?;
    file.seek(SeekFrom::Start(0))
        .map_err(|error| error.to_string())?;
    let quality = match format {
        "flac" => probe_quality(file, &|| Ok(())),
        "m4a" | "mp4" | "aac" => probe_mp4_quality(file, &|| Ok(())),
        "mp3" => mp3_quality(file, size as i64),
        "adts" => adts_quality(file, size as i64),
        "ogg" | "opus" => ogg_quality(file, size as i64, path),
        "wav" | "aiff" | "aif" | "aifc" => riff_quality(file, size as i64, format != "wav"),
        _ => return Ok(result),
    };
    if let Ok(quality) = quality {
        let readable_without_tags = quality.sample_rate > 0
            && match format {
                "mp3" | "adts" => quality.bitrate > 0,
                "m4a" | "mp4" | "aac" => !quality.codec.is_empty(),
                _ => false,
            };
        if !tagged && readable_without_tags {
            // Use the real display name and unknown artist/album, never the
            // staged filename or cache directory used by a SAF fallback.
            apply_tags(&mut result, AudioMetadata::default(), format, path, hint)?;
        }
        for (key, value) in [
            ("bitDepth", quality.bit_depth),
            ("sampleRate", quality.sample_rate),
            ("duration", quality.duration),
        ] {
            if value != 0 {
                result[key] = value.into();
            }
        }
        let bitrate = match format {
            "flac" if quality.total_samples > 0 && quality.sample_rate > 0 => {
                (size as f64 * 8.0
                    / (quality.total_samples as f64 / quality.sample_rate as f64)
                    / 1000.0) as i64
            }
            "mp3" | "adts" | "ogg" | "opus" => quality.bitrate / 1000,
            "m4a" | "mp4" | "aac" => {
                let mapped = match quality.codec.trim().to_lowercase().as_str() {
                    "flac" => "flac",
                    "alac" => "alac",
                    "eac3" | "ec-3" => "eac3",
                    "ac3" | "ac-3" => "ac3",
                    "ac4" | "ac-4" => "ac4",
                    "opus" => "opus",
                    "aac" | "mp4a" => "m4a",
                    _ => "",
                };
                if !mapped.is_empty() {
                    result["format"] = mapped.into();
                }
                quality.bitrate
            }
            _ => 0,
        };
        if bitrate > 0 {
            result["bitrate"] = bitrate.into();
        }
    }
    Ok(result)
}

fn apply_tags(
    result: &mut Value,
    mut tags: AudioMetadata,
    format: &str,
    path: &str,
    hint: &str,
) -> Result<(), String> {
    if format != "flac" && tags.date.is_empty() {
        tags.date = tags.year.clone();
    }
    result
        .as_object_mut()
        .unwrap()
        .remove("metadataFromFilename");
    result.as_object_mut().unwrap().remove("metadataReadError");
    result["trackName"] = if tags.title.is_empty() {
        filename(if hint.is_empty() { path } else { hint }).into()
    } else {
        tags.title.into()
    };
    result["artistName"] = if tags.artist.is_empty() {
        "Unknown Artist".into()
    } else {
        tags.artist.into()
    };
    result["albumName"] = if tags.album.is_empty() {
        "Unknown Album".into()
    } else {
        tags.album.into()
    };
    result["hasLyrics"] = has_usable_content(&tags.lyrics).into();
    // Move owned fields directly instead of serializing the whole struct
    // (including lyrics) per scanned file. Empty strings, zero numbers and
    // `false` stay omitted exactly as before.
    for (target, value) in [
        ("albumArtist", tags.album_artist),
        ("isrc", tags.isrc),
        ("releaseDate", tags.date),
        ("genre", tags.genre),
        ("composer", tags.composer),
        ("label", tags.label),
        ("copyright", tags.copyright),
        ("comment", tags.comment),
        ("albumType", tags.album_type),
        ("upc", tags.upc),
        ("replaygain_track_gain", tags.replay_gain_track_gain),
        ("replaygain_track_peak", tags.replay_gain_track_peak),
        ("replaygain_album_gain", tags.replay_gain_album_gain),
        ("replaygain_album_peak", tags.replay_gain_album_peak),
    ] {
        if !value.is_empty() {
            result[target] = value.into();
        }
    }
    for (target, value) in [
        ("trackNumber", tags.track_number),
        ("totalTracks", tags.total_tracks),
        ("discNumber", tags.disc_number),
        ("totalDiscs", tags.total_discs),
    ] {
        if value != 0 {
            result[target] = value.into();
        }
    }
    if tags.explicit {
        result["explicit"] = true.into();
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The previous serialize-then-filter implementation, kept as the oracle.
    fn serialized_apply_tags(
        result: &mut Value,
        mut tags: AudioMetadata,
        format: &str,
        path: &str,
        hint: &str,
    ) {
        if format != "flac" && tags.date.is_empty() {
            tags.date = tags.year.clone();
        }
        result
            .as_object_mut()
            .unwrap()
            .remove("metadataFromFilename");
        result["trackName"] = if tags.title.is_empty() {
            filename(if hint.is_empty() { path } else { hint }).into()
        } else {
            tags.title.clone().into()
        };
        result["artistName"] = if tags.artist.is_empty() {
            "Unknown Artist".into()
        } else {
            tags.artist.clone().into()
        };
        result["albumName"] = if tags.album.is_empty() {
            "Unknown Album".into()
        } else {
            tags.album.clone().into()
        };
        result["hasLyrics"] = has_usable_content(&tags.lyrics).into();
        let tags = serde_json::to_value(tags).unwrap();
        for (source, target) in [
            ("album_artist", "albumArtist"),
            ("isrc", "isrc"),
            ("track_number", "trackNumber"),
            ("total_tracks", "totalTracks"),
            ("disc_number", "discNumber"),
            ("total_discs", "totalDiscs"),
            ("date", "releaseDate"),
            ("genre", "genre"),
            ("composer", "composer"),
            ("label", "label"),
            ("copyright", "copyright"),
            ("comment", "comment"),
            ("album_type", "albumType"),
            ("explicit", "explicit"),
            ("upc", "upc"),
            ("replay_gain_track_gain", "replaygain_track_gain"),
            ("replay_gain_track_peak", "replaygain_track_peak"),
            ("replay_gain_album_gain", "replaygain_album_gain"),
            ("replay_gain_album_peak", "replaygain_album_peak"),
        ] {
            let value = &tags[source];
            if !matches!(value, Value::Null)
                && value != ""
                && value != &json!(0)
                && value != &json!(false)
            {
                result[target] = value.clone();
            }
        }
    }

    #[test]
    fn direct_tag_mapping_matches_serialized_mapping() {
        let full = AudioMetadata {
            title: "Title".into(),
            artist: "Artist".into(),
            album: "Album".into(),
            album_artist: "Album Artist".into(),
            genre: "Genre".into(),
            year: "2001".into(),
            date: String::new(),
            track_number: 3,
            total_tracks: -1,
            disc_number: 0,
            total_discs: 2,
            isrc: "XX0000000000".into(),
            lyrics: "[00:01.00]line".into(),
            label: "Label".into(),
            copyright: "(c)".into(),
            composer: "Composer".into(),
            comment: "Comment".into(),
            album_type: "album".into(),
            explicit: true,
            upc: "0000".into(),
            replay_gain_track_gain: "-6.5 dB".into(),
            replay_gain_track_peak: "0.98".into(),
            replay_gain_album_gain: "-7 dB".into(),
            replay_gain_album_peak: "0.99".into(),
        };
        let dated = AudioMetadata {
            date: "2001-02-03".into(),
            explicit: false,
            lyrics: " ".into(),
            ..full.clone()
        };
        for tags in [AudioMetadata::default(), full, dated] {
            for format in ["flac", "mp3", "m4a"] {
                for (path, hint) in [("/music/a.flac", ""), ("/proc/self/fd/9", "b.mp3")] {
                    let base = library_metadata(path, hint, "scan", 7);
                    let mut expected = base.clone();
                    serialized_apply_tags(&mut expected, tags.clone(), format, path, hint);
                    let mut actual = base;
                    apply_tags(&mut actual, tags.clone(), format, path, hint).unwrap();
                    assert_eq!(
                        serde_json::to_string(&actual).unwrap(),
                        serde_json::to_string(&expected).unwrap(),
                        "{format} {path} {hint}"
                    );
                }
            }
        }
    }
}
