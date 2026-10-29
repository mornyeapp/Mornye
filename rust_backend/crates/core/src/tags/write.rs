//! Streaming metadata rewrites. The native owner supplies a separate staged
//! output and publishes it only after this operation succeeds and is synced.

mod ape;
mod artists;
mod id3;
mod mp4;
mod ogg;
mod riff;

pub(super) use id3::cover as embedded_cover;

use super::{CheckedReader, MAX_TAG_BYTES, bytes, exact, pair, seek};
use crate::matching::uppercase;
use artists::{
    artist_mode_fields, primary_artist, primary_artist_mode, split_artists, tag_separator,
};
use regex::Regex;
use std::collections::BTreeMap;
use std::io::{BufReader, Cursor, Read, Seek, SeekFrom, Write};
use std::sync::LazyLock;

type Fields = BTreeMap<String, String>;

fn clears_replay_gain(fields: &Fields) -> bool {
    [
        "replaygain_track_gain",
        "replaygain_track_peak",
        "replaygain_album_gain",
        "replaygain_album_peak",
    ]
    .iter()
    .all(|key| {
        fields
            .get(*key)
            .is_some_and(|value| value.trim().is_empty())
    })
}

struct Section {
    start: u64,
    end: u64,
    data: Vec<u8>,
}

pub fn rewrite_audio_tags(
    source: &mut (impl Read + Seek),
    output: &mut impl Write,
    format: &str,
    fields: &Fields,
    cover: Option<&[u8]>,
    check: &dyn Fn() -> Result<(), String>,
) -> Result<(), String> {
    check()?;
    validate_fields(fields)?;
    let fields = &*artist_mode_fields(fields);
    let mut source = BufReader::new(CheckedReader {
        reader: source,
        check,
    });
    seek(&mut source, SeekFrom::Start(0))?;
    if matches!(format, "wav" | "aiff" | "aif" | "aifc") {
        let sections = riff::edit(&mut source, format != "wav", fields, cover, check)?;
        return write_sections(&mut source, output, sections, check);
    }
    let cover = cover.filter(|data| !data.is_empty());
    if matches!(format, "ogg" | "opus") {
        return ogg::rewrite(&mut source, output, fields, cover, check);
    }
    if matches!(format, "ape" | "wv" | "mpc") {
        let section = ape::edit(&mut source, fields, cover, check)?;
        return write_sections(&mut source, output, vec![section], check);
    }
    if matches!(format, "m4a" | "mp4" | "m4b") {
        let sections = mp4::edit(&mut source, fields, cover, check)?;
        return write_sections(&mut source, output, sections, check);
    }
    let section = match format {
        "flac" => flac_header(&mut source, fields, cover, None, check)?,
        "mp3" => {
            let (data, end) = id3::header(&mut source, fields, cover, check)?;
            Section {
                start: 0,
                end,
                data,
            }
        }
        _ => return Err(format!("unsupported tag writer: {format}")),
    };
    write_sections(&mut source, output, vec![section], check)
}

/// Edit FLAC tags, leaving output untouched when the complete metadata header
/// is already identical. The native owner can then discard its staging file.
pub fn rewrite_flac_tags_if_changed(
    source: &mut (impl Read + Seek),
    output: &mut impl Write,
    fields: &Fields,
    cover: Option<&[u8]>,
    check: &dyn Fn() -> Result<(), String>,
) -> Result<bool, String> {
    check()?;
    validate_fields(fields)?;
    let fields = &*artist_mode_fields(fields);
    // Read only metadata and the frame sync needed for validation. A buffered
    // reader here would also pull audio into memory on the no-op path.
    let mut source = CheckedReader {
        reader: source,
        check,
    };
    seek(&mut source, SeekFrom::Start(0))?;
    let section = flac_header(
        &mut source,
        fields,
        cover.filter(|bytes| !bytes.is_empty()),
        None,
        check,
    )?;
    if section.data.len() as u64 == section.end - section.start {
        seek(&mut source, SeekFrom::Start(section.start))?;
        let mut buffer = [0; 65536];
        let mut unchanged = true;
        for expected in section.data.chunks(buffer.len()) {
            exact(&mut source, &mut buffer[..expected.len()])?;
            if buffer[..expected.len()] != *expected {
                unchanged = false;
                break;
            }
        }
        check()?;
        if unchanged {
            return Ok(false);
        }
    }
    write_sections(&mut source, output, vec![section], check)?;
    Ok(true)
}

/// Embed canonical Vorbis keys without clearing empty values or removing
/// legacy aliases. This is the enrichment contract, distinct from the editor.
pub fn embed_flac_metadata(
    source: &mut (impl Read + Seek),
    output: &mut impl Write,
    fields: &Fields,
    artist_tag_mode: &str,
    cover: Option<&[u8]>,
    check: &dyn Fn() -> Result<(), String>,
) -> Result<(), String> {
    check()?;
    validate_fields(fields)?;
    let mut source = BufReader::new(CheckedReader {
        reader: source,
        check,
    });
    seek(&mut source, SeekFrom::Start(0))?;
    let section = flac_header(
        &mut source,
        fields,
        cover.filter(|data| !data.is_empty()),
        Some(artist_tag_mode),
        check,
    )?;
    write_sections(&mut source, output, vec![section], check)
}

fn validate_fields(fields: &Fields) -> Result<(), String> {
    if fields
        .iter()
        .try_fold(0usize, |total, (key, value)| {
            total.checked_add(key.len())?.checked_add(value.len())
        })
        .is_none_or(|length| length > MAX_TAG_BYTES)
    {
        return Err("tag edit fields exceed 64 MiB".into());
    }
    Ok(())
}

/// Rewrite only existing M4A freeform tags. False means a no-op and no output
/// was written, so the native owner can discard its staging file immediately.
pub fn rewrite_m4a_freeform(
    source: &mut (impl Read + Seek),
    output: &mut impl Write,
    fields: &Fields,
    replay_gain_only: bool,
    check: &dyn Fn() -> Result<(), String>,
) -> Result<bool, String> {
    check()?;
    validate_fields(fields)?;
    let mut source = BufReader::new(CheckedReader {
        reader: source,
        check,
    });
    let sections = mp4::edit_freeform(&mut source, fields, replay_gain_only, check)?;
    write_optional_sections(&mut source, output, sections, check)
}

/// Normalize an AC-4 container and lazily open its original configuration source.
pub fn rewrite_ac4_config<R: Read + Seek>(
    source: &mut (impl Read + Seek),
    output: &mut impl Write,
    reference: impl FnOnce() -> Result<R, String>,
    check: &dyn Fn() -> Result<(), String>,
) -> Result<bool, String> {
    check()?;
    let mut source = BufReader::new(CheckedReader {
        reader: source,
        check,
    });
    let sections = mp4::ac4::config(&mut source, reference, check)?;
    write_optional_sections(&mut source, output, sections, check)
}

/// Replace AC-4 metadata; false means no output, and the cover is read only for AC-4.
pub fn rewrite_ac4_metadata(
    source: &mut (impl Read + Seek),
    output: &mut impl Write,
    metadata_json: &str,
    cover: impl FnOnce() -> Result<Option<Vec<u8>>, String>,
    check: &dyn Fn() -> Result<(), String>,
) -> Result<bool, String> {
    check()?;
    let mut source = BufReader::new(CheckedReader {
        reader: source,
        check,
    });
    let sections = mp4::ac4::metadata(&mut source, metadata_json, cover, check)?;
    write_optional_sections(&mut source, output, sections, check)
}

fn write_optional_sections(
    source: &mut (impl Read + Seek),
    output: &mut impl Write,
    sections: Vec<Section>,
    check: &dyn Fn() -> Result<(), String>,
) -> Result<bool, String> {
    if sections.is_empty() {
        check()?;
        return Ok(false);
    }
    write_sections(source, output, sections, check)?;
    Ok(true)
}

fn write_sections(
    source: &mut (impl Read + Seek),
    output: &mut impl Write,
    mut sections: Vec<Section>,
    check: &dyn Fn() -> Result<(), String>,
) -> Result<(), String> {
    sections.sort_by_key(|section| section.start);
    let mut position = 0;
    for section in &sections {
        if section.start < position || section.end < section.start {
            return Err("overlapping or invalid file sections".into());
        }
        position = section.end;
    }
    seek(source, SeekFrom::Start(0))?;
    position = 0;
    for section in sections {
        copy(source, output, Some(section.start - position), check)?;
        for chunk in section.data.chunks(65536) {
            check()?;
            output.write_all(chunk).map_err(|error| error.to_string())?;
        }
        seek(source, SeekFrom::Start(section.end))?;
        position = section.end;
    }
    copy(source, output, None, check)
}

fn copy(
    source: &mut impl Read,
    output: &mut impl Write,
    mut remaining: Option<u64>,
    check: &dyn Fn() -> Result<(), String>,
) -> Result<(), String> {
    let mut buffer = [0; 65536];
    loop {
        check()?;
        let limit = remaining.map_or(buffer.len(), |n| n.min(buffer.len() as u64) as usize);
        if limit == 0 {
            break;
        }
        let count = source
            .read(&mut buffer[..limit])
            .map_err(|error| error.to_string())?;
        if count == 0 {
            if remaining.is_some() {
                return Err("unexpected EOF while copying audio".into());
            }
            break;
        }
        output
            .write_all(&buffer[..count])
            .map_err(|error| error.to_string())?;
        remaining = remaining.map(|n| n - count as u64);
    }
    check()
}

fn flac_header(
    source: &mut (impl Read + Seek),
    fields: &Fields,
    cover: Option<&[u8]>,
    embed_mode: Option<&str>,
    check: &dyn Fn() -> Result<(), String>,
) -> Result<Section, String> {
    let start = super::containers::flac_start(source)?;
    let mut blocks = Vec::new();
    let mut total = 0;
    loop {
        check()?;
        if blocks.len() >= 65536 {
            return Err("FLAC metadata block count exceeds 65536".into());
        }
        let h = bytes(source, 4)?;
        let length = u32::from_be_bytes([0, h[1], h[2], h[3]]) as usize;
        total += length + 4;
        if total > MAX_TAG_BYTES {
            return Err("FLAC metadata exceeds 64 MiB".into());
        }
        let kind = h[0] & 0x7f;
        let data = if kind == 6 && cover.is_some() {
            // Replacement artwork discards every old picture. Still read its
            // complete payload to retain truncation checks without retaining it.
            discard_bytes(source, length, check)?;
            Vec::new()
        } else {
            bytes(source, length)?
        };
        blocks.push((kind, data));
        if h[0] & 0x80 != 0 {
            break;
        }
    }
    let audio_start = seek(source, SeekFrom::Current(0))?;
    let sync = bytes(source, 2)?;
    if sync[0] != 0xff || sync[1] >> 2 != 0x3e {
        return Err("frames do not begin with sync code".into());
    }
    let index = blocks.iter().position(|(kind, _)| *kind == 4);
    let (vendor, mut comments) = if let Some(index) = index {
        parse_comments(&blocks[index].1)?
    } else {
        (b"Mornye".to_vec(), Vec::new())
    };
    if let Some(mode) = embed_mode {
        for (key, value) in fields.iter().filter(|(_, value)| !value.is_empty()) {
            if key.ends_with("_separator") {
                continue;
            }
            let separator = tag_separator(fields, key);
            if matches!(key.as_str(), "ARTIST" | "ALBUMARTIST") {
                let values =
                    if mode.trim().eq_ignore_ascii_case("split_vorbis") && separator.is_empty() {
                        split_artists(value)
                    } else if primary_artist_mode(mode) {
                        vec![primary_artist(value)]
                    } else {
                        vec![super::format_metadata_tag_value(value, separator)]
                    };
                if !values.is_empty() {
                    set_comment(&mut comments, key, "");
                    for value in values.iter().filter(|value| !value.trim().is_empty()) {
                        comments.push(format!("{key}={value}").into_bytes());
                    }
                }
            } else {
                set_comment(
                    &mut comments,
                    key,
                    &super::format_metadata_tag_value(value, separator),
                );
            }
        }
    } else {
        edit_comments(&mut comments, fields);
    }
    let mut data = Vec::new();
    put_string(&mut data, &vendor);
    data.extend((comments.len() as u32).to_le_bytes());
    for comment in comments {
        put_string(&mut data, &comment);
    }
    if let Some(index) = index {
        blocks[index].1 = data;
    } else {
        blocks.push((4, data));
    }
    if let Some(cover) = cover {
        blocks.retain(|(kind, _)| *kind != 6);
        if let Some(picture) = picture(cover, check)? {
            blocks.push((6, picture));
        }
    }
    let mut head = b"fLaC".to_vec();
    let count = blocks.len();
    for (index, (kind, data)) in blocks.into_iter().enumerate() {
        if head.len() + data.len() + 4 > MAX_TAG_BYTES {
            return Err("FLAC metadata exceeds 64 MiB".into());
        }
        if data.len() > 0xff_ffff {
            return Err("FLAC metadata block exceeds 24-bit size".into());
        }
        head.push(kind | if index + 1 == count { 0x80 } else { 0 });
        head.extend(&(data.len() as u32).to_be_bytes()[1..]);
        head.extend(data);
    }
    Ok(Section {
        start,
        end: audio_start,
        data: head,
    })
}

fn discard_bytes(
    source: &mut impl Read,
    length: usize,
    check: &dyn Fn() -> Result<(), String>,
) -> Result<(), String> {
    let mut buffer = [0; 65536];
    let mut offset = 0;
    while offset < length {
        check()?;
        let count = source
            .read(&mut buffer[..(length - offset).min(65536)])
            .map_err(|error| error.to_string())?;
        if count == 0 {
            return Err(if offset == 0 { "EOF" } else { "unexpected EOF" }.into());
        }
        offset += count;
    }
    Ok(())
}

fn parse_comments(data: &[u8]) -> Result<(Vec<u8>, Vec<Vec<u8>>), String> {
    fn string(reader: &mut Cursor<&[u8]>) -> Result<Vec<u8>, String> {
        let mut length = [0; 4];
        exact(reader, &mut length)?;
        let length = u32::from_le_bytes(length) as usize;
        if length
            > reader
                .get_ref()
                .len()
                .saturating_sub(reader.position() as usize)
        {
            return Err("truncated Vorbis comment".into());
        }
        bytes(reader, length)
    }
    let mut reader = Cursor::new(data);
    let vendor = string(&mut reader)?;
    let mut count = [0; 4];
    exact(&mut reader, &mut count)?;
    let mut comments = Vec::new();
    for _ in 0..u32::from_le_bytes(count) {
        comments.push(string(&mut reader)?);
    }
    Ok((vendor, comments))
}

fn put_string(output: &mut Vec<u8>, data: &[u8]) {
    output.extend((data.len() as u32).to_le_bytes());
    output.extend(data);
}

fn comment_key(value: &[u8]) -> String {
    value
        .iter()
        .position(|value| *value == b'=')
        .filter(|index| *index > 0)
        .map(|index| uppercase(&String::from_utf8_lossy(&value[..index])))
        .unwrap_or_default()
}

fn set_comment(comments: &mut Vec<Vec<u8>>, key: &str, value: &str) {
    comments.retain(|comment| comment_key(comment) != key);
    if !value.is_empty() {
        comments.push(format!("{key}={value}").into_bytes());
    }
}

fn get_comment(comments: &[Vec<u8>], key: &str) -> String {
    comments
        .iter()
        .find(|comment| comment_key(comment) == key)
        .map(|comment| String::from_utf8_lossy(&comment[key.len() + 1..]).into_owned())
        .unwrap_or_default()
}

fn edit_comments(comments: &mut Vec<Vec<u8>>, fields: &Fields) {
    for (field, key) in [
        ("title", "TITLE"),
        ("album", "ALBUM"),
        ("date", "DATE"),
        ("isrc", "ISRC"),
        ("genre", "GENRE"),
        ("label", "ORGANIZATION"),
        ("copyright", "COPYRIGHT"),
        ("composer", "COMPOSER"),
        ("comment", "COMMENT"),
        ("explicit", "ITUNESADVISORY"),
        ("album_type", "RELEASETYPE"),
        ("upc", "BARCODE"),
        ("barcode", "BARCODE"),
        ("compilation", "COMPILATION"),
        ("replaygain_track_gain", "REPLAYGAIN_TRACK_GAIN"),
        ("replaygain_track_peak", "REPLAYGAIN_TRACK_PEAK"),
        ("replaygain_album_gain", "REPLAYGAIN_ALBUM_GAIN"),
        ("replaygain_album_peak", "REPLAYGAIN_ALBUM_PEAK"),
    ] {
        if let Some(value) = fields.get(field) {
            set_comment(comments, key, value);
        }
    }
    for (field, aliases) in [
        ("label", &["LABEL", "PUBLISHER"][..]),
        ("date", &["YEAR"][..]),
    ] {
        if fields.contains_key(field) {
            for key in aliases {
                set_comment(comments, key, "");
            }
        }
    }
    for (field, key) in [("artist", "ARTIST"), ("album_artist", "ALBUMARTIST")] {
        if let Some(value) = fields.get(field) {
            set_comment(comments, key, "");
            let values = if fields
                .get("artist_tag_mode")
                .is_some_and(|mode| mode.trim().eq_ignore_ascii_case("split_vorbis"))
                && tag_separator(fields, field).is_empty()
            {
                split_artists(value)
            } else {
                vec![value.clone()]
            };
            for value in values {
                if !value.trim().is_empty() {
                    comments.push(format!("{key}={value}").into_bytes());
                }
            }
            if field == "album_artist" {
                for alias in ["ALBUM ARTIST", "ALBUM_ARTIST"] {
                    set_comment(comments, alias, "");
                }
            }
        }
    }
    for (field, total, key, alias) in [
        ("track_number", "track_total", "TRACKNUMBER", "TRACK"),
        ("disc_number", "disc_total", "DISCNUMBER", "DISC"),
    ] {
        if fields.contains_key(field) || fields.contains_key(total) {
            let mut current = pair(&get_comment(comments, key));
            if current == (0, 0) {
                current = pair(&get_comment(comments, alias));
            }
            set_comment(comments, key, &edit_index(current, fields, field, total));
            set_comment(comments, alias, "");
        }
    }
    if let Some(value) = fields.get("lyrics") {
        set_comment(comments, "SYNCEDLYRICS", "");
        set_comment(comments, "LYRICS", value);
        set_comment(comments, "UNSYNCEDLYRICS", value);
    }
}

fn edit_index(
    (mut number, mut total): (i64, i64),
    fields: &Fields,
    key: &str,
    total_key: &str,
) -> String {
    if let Some(value) = fields.get(key) {
        number = value.trim().parse::<i64>().unwrap_or(0);
    }
    if let Some(value) = fields.get(total_key) {
        total = value.trim().parse::<i64>().unwrap_or(0);
    }
    if number <= 0 {
        String::new()
    } else if total > 0 {
        format!("{number}/{total}")
    } else {
        number.to_string()
    }
}

fn metadata_fields(metadata: &super::AudioMetadata, fields: &Fields) -> Fields {
    let mut result = Fields::new();
    for (field, current) in [
        ("title", &metadata.title),
        ("artist", &metadata.artist),
        ("album", &metadata.album),
        ("album_artist", &metadata.album_artist),
        ("date", &metadata.date),
        ("genre", &metadata.genre),
        ("composer", &metadata.composer),
        ("label", &metadata.label),
        ("copyright", &metadata.copyright),
        ("isrc", &metadata.isrc),
        ("lyrics", &metadata.lyrics),
        ("comment", &metadata.comment),
        ("album_type", &metadata.album_type),
        ("upc", &metadata.upc),
        ("replaygain_track_gain", &metadata.replay_gain_track_gain),
        ("replaygain_track_peak", &metadata.replay_gain_track_peak),
        ("replaygain_album_gain", &metadata.replay_gain_album_gain),
        ("replaygain_album_peak", &metadata.replay_gain_album_peak),
    ] {
        result.insert(field.into(), fields.get(field).unwrap_or(current).clone());
    }
    static INTEGER: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"^[+-]?[0-9]+").unwrap());
    for (field, current) in [
        ("track_number", metadata.track_number),
        ("track_total", metadata.total_tracks),
        ("disc_number", metadata.disc_number),
        ("disc_total", metadata.total_discs),
    ] {
        let value = fields.get(field).map_or(current, |value| {
            INTEGER
                .find(value.trim())
                .and_then(|n| n.as_str().parse::<isize>().ok())
                .unwrap_or(0) as i64
        });
        result.insert(field.into(), value.to_string());
    }
    let explicit = fields
        .get("explicit")
        .map_or(metadata.explicit, |value| super::truthy(value));
    result.insert("explicit".into(), if explicit { "1" } else { "" }.into());
    let compilation = result["album_type"]
        .trim()
        .eq_ignore_ascii_case("compilation");
    result.insert(
        "compilation".into(),
        if compilation { "1" } else { "" }.into(),
    );
    result
}

fn cover_mime(data: &[u8]) -> &'static str {
    if data.starts_with(b"\x89PNG\r\n\x1a\n") {
        "image/png"
    } else if data.starts_with(b"\xff\xd8\xff") {
        "image/jpeg"
    } else if data.starts_with(b"GIF87a") || data.starts_with(b"GIF89a") {
        "image/gif"
    } else if data.len() >= 12 && &data[..4] == b"RIFF" && &data[8..12] == b"WEBP" {
        "image/webp"
    } else {
        "image/jpeg"
    }
}

fn picture(
    original: &[u8],
    check: &dyn Fn() -> Result<(), String>,
) -> Result<Option<Vec<u8>>, String> {
    let mut resized = None;
    if original.len() > 16_000_000 {
        let Ok(image) = image::ImageReader::new(Cursor::new(original))
            .with_guessed_format()
            .map_err(|e| e.to_string())?
            .decode()
        else {
            return Ok(None);
        };
        for quality in [90, 80, 70, 60] {
            check()?;
            let mut encoded = Vec::new();
            if image::codecs::jpeg::JpegEncoder::new_with_quality(&mut encoded, quality)
                .encode_image(&image.to_rgb8())
                .is_ok()
                && encoded.len() <= 16_000_000
            {
                resized = Some(encoded);
                break;
            }
        }
        if resized.is_none() {
            for dimension in [1500, 1200, 1000, 800] {
                check()?;
                let scaled = image
                    .resize(dimension, dimension, image::imageops::FilterType::Nearest)
                    .to_rgb8();
                let mut encoded = Vec::new();
                if image::codecs::jpeg::JpegEncoder::new_with_quality(&mut encoded, 85)
                    .encode_image(&scaled)
                    .is_ok()
                    && encoded.len() <= 16_000_000
                {
                    resized = Some(encoded);
                    break;
                }
            }
        }
        if resized.is_none() {
            return Ok(None);
        }
    }
    check()?;
    let data = resized.as_deref().unwrap_or(original);
    let mime = cover_mime(data);
    let dimensions = image::ImageReader::new(Cursor::new(data))
        .with_guessed_format()
        .map_err(|e| e.to_string())?
        .into_dimensions()
        .ok();
    let (width, height, depth) = dimensions.map_or((0, 0, 0), |(w, h)| {
        (
            w,
            h,
            match mime {
                "image/png" => 32,
                "image/jpeg" => 24,
                _ => 0,
            },
        )
    });
    let mut result = 3_u32.to_be_bytes().to_vec();
    for value in [mime.as_bytes(), b"Front Cover"] {
        result.extend((value.len() as u32).to_be_bytes());
        result.extend(value);
    }
    for value in [width, height, depth, 0, data.len() as u32] {
        result.extend(value.to_be_bytes());
    }
    result.extend(data);
    Ok(Some(result))
}

#[cfg(test)]
mod tests;
