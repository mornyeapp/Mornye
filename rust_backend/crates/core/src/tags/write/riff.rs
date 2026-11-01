use super::{Fields, Section, bytes, id3, metadata_fields, seek};
use crate::tags::{file::ObservedReader, read_audio_tags};
use std::collections::BTreeMap;
use std::io::{Cursor, Read, Seek, SeekFrom};

pub(super) fn edit(
    source: &mut (impl Read + Seek),
    aiff: bool,
    fields: &Fields,
    cover: Option<&[u8]>,
    check: &dyn Fn() -> Result<(), String>,
) -> Result<Vec<Section>, String> {
    let mut observed = ObservedReader {
        file: source,
        check,
        failure: None,
    };
    let metadata = read_audio_tags(&mut observed, if aiff { "aiff" } else { "wav" }, &|| Ok(()))
        .unwrap_or_default();
    if let Some(error) = observed.failure {
        return Err(error);
    }
    let source = observed.file;
    let length = seek(source, SeekFrom::End(0))?;
    seek(source, SeekFrom::Start(0))?;
    let header = bytes(source, 12)?;
    if &header[..4] != if aiff { b"FORM" } else { b"RIFF" } {
        return Err("unexpected container magic".into());
    }
    let mut sections = Vec::new();
    let mut start = 12_u64;
    let mut body_size = 4_u64;
    let mut embedded_cover = None;
    let mut existing_wav_tag = None;
    let replace_cover = cover.is_some();
    let tag_fields = metadata_fields(&metadata, fields);
    let info_fields = info_fields(fields, &tag_fields);
    let remove_gain_only = fields.len() == 4 && super::clears_replay_gain(fields);
    for _ in 0..65536 {
        check()?;
        if start + 8 > length {
            break;
        }
        seek(source, SeekFrom::Start(start))?;
        let header = bytes(source, 8)?;
        let size = if aiff {
            u32::from_be_bytes(header[4..].try_into().unwrap())
        } else {
            u32::from_le_bytes(header[4..].try_into().unwrap())
        };
        let end = start + 8 + u64::from(size) + u64::from(size & 1);
        if header[..4].eq_ignore_ascii_case(b"id3 ") {
            if remove_gain_only {
                // Edit the existing ID3 frames so unknown tags and all artwork
                // survive removal, instead of rebuilding from parsed metadata.
                if size as usize > super::MAX_TAG_BYTES || end > length {
                    return Err("invalid RIFF ID3 chunk size".into());
                }
                let (tag, _) = id3::header(
                    &mut Cursor::new(bytes(source, size as usize)?),
                    fields,
                    None,
                    check,
                )?;
                let tag_size = tag.len() as u32;
                let mut chunk = header[..4].to_vec();
                chunk.extend(if aiff {
                    tag_size.to_be_bytes()
                } else {
                    tag_size.to_le_bytes()
                });
                chunk.extend(tag);
                if tag_size & 1 == 1 {
                    chunk.push(0);
                }
                body_size += chunk.len() as u64;
                sections.push(Section {
                    start,
                    end,
                    data: chunk,
                });
                start = end;
                continue;
            }
            if size > 0
                && size <= 16 * 1024 * 1024
                && end <= length
                && matches!(&header[..4], b"ID3 " | b"id3 ")
            {
                let tag = bytes(source, size as usize)?;
                if cover.is_none() {
                    embedded_cover = id3::cover(&tag);
                }
                if !aiff {
                    existing_wav_tag = Some(tag);
                }
            }
            sections.push(Section {
                start,
                end: end.min(length),
                data: Vec::new(),
            });
        } else {
            if end > length {
                return Err("unexpected EOF while copying audio".into());
            }
            if !aiff && !info_fields.is_empty() && &header[..4] == b"LIST" && size >= 4 {
                let kind = bytes(source, 4)?;
                if kind == b"INFO" {
                    if size as usize > super::MAX_TAG_BYTES {
                        return Err("RIFF INFO chunk exceeds 64 MiB".into());
                    }
                    let mut data = kind;
                    data.extend(bytes(source, size as usize - 4)?);
                    let data = edit_info(&data, &info_fields, check)?;
                    body_size += data.len() as u64;
                    sections.push(Section { start, end, data });
                    start = end;
                    continue;
                }
            }
            body_size += end - start;
        }
        start = end;
    }
    if start + 8 <= length {
        return Err("RIFF chunk count exceeds 65536".into());
    }
    if remove_gain_only {
        let size = u32::try_from(body_size).map_err(|_| "RIFF container exceeds 32-bit size")?;
        sections.push(Section {
            start: 4,
            end: 8,
            data: if aiff {
                size.to_be_bytes()
            } else {
                size.to_le_bytes()
            }
            .to_vec(),
        });
        return Ok(sections);
    }
    let cover_path = fields.get("cover_path").map(|p| p.trim()).unwrap_or("");
    if !cover_path.is_empty() && cover.is_none() {
        return Err("read cover art: file not found".into());
    }
    if cover.is_some_and(|cover| cover.is_empty()) {
        return Err("cover art is empty".into());
    }
    let cover = if let Some(cover) = cover {
        let mime = if cover.len() >= 8 && cover.starts_with(b"\x89PNG") {
            "image/png"
        } else if cover.len() >= 12 && &cover[..4] == b"RIFF" && &cover[8..12] == b"WEBP" {
            "image/webp"
        } else if cover.starts_with(b"GIF87a") || cover.starts_with(b"GIF89a") {
            "image/gif"
        } else {
            match std::path::Path::new(cover_path)
                .extension()
                .and_then(|e| e.to_str())
                .unwrap_or("")
                .to_ascii_lowercase()
                .as_str()
            {
                "png" => "image/png",
                "webp" => "image/webp",
                "gif" => "image/gif",
                _ => "image/jpeg",
            }
        };
        Some((cover, mime))
    } else {
        embedded_cover
            .as_ref()
            .map(|(data, mime)| (data.as_slice(), mime.as_str()))
    };
    let tag = if let Some(tag) = existing_wav_tag {
        id3::embedded_header(
            &mut Cursor::new(tag),
            &tag_fields,
            if replace_cover { cover } else { None },
            check,
        )
        .or_else(|_| id3::fresh(&tag_fields, cover, check))?
    } else {
        id3::fresh(&tag_fields, cover, check)?
    };
    let tag_size = tag.len() as u32;
    let mut chunk = if aiff {
        b"ID3 ".to_vec()
    } else {
        b"id3 ".to_vec()
    };
    chunk.extend(if aiff {
        tag_size.to_be_bytes()
    } else {
        tag_size.to_le_bytes()
    });
    chunk.extend(tag);
    if tag_size & 1 == 1 {
        chunk.push(0)
    }
    body_size += chunk.len() as u64;
    let size = u32::try_from(body_size).map_err(|_| "RIFF container exceeds 32-bit size")?;
    sections.push(Section {
        start: 4,
        end: 8,
        data: if aiff {
            size.to_be_bytes()
        } else {
            size.to_le_bytes()
        }
        .to_vec(),
    });
    // Go drops an incomplete trailing chunk header, then appends the new ID3.
    sections.push(Section {
        start: start.min(length),
        end: length,
        data: chunk,
    });
    Ok(sections)
}

fn info_fields(edited: &Fields, current: &Fields) -> BTreeMap<[u8; 4], String> {
    let mut result = BTreeMap::new();
    for (field, kind) in [
        ("title", *b"INAM"),
        ("artist", *b"IART"),
        ("album", *b"IPRD"),
        ("date", *b"ICRD"),
        ("genre", *b"IGNR"),
        ("comment", *b"ICMT"),
        ("copyright", *b"ICOP"),
        ("composer", *b"IMUS"),
    ] {
        if edited.contains_key(field) {
            result.insert(kind, current[field].clone());
        }
    }
    if edited.contains_key("track_number") || edited.contains_key("track_total") {
        result.insert(
            *b"ITRK",
            super::edit_index((0, 0), current, "track_number", "track_total"),
        );
    }
    result
}

/// Keep legacy readers in sync with ID3 while retaining unedited INFO chunks.
fn edit_info(
    data: &[u8],
    fields: &BTreeMap<[u8; 4], String>,
    check: &dyn Fn() -> Result<(), String>,
) -> Result<Vec<u8>, String> {
    let mut body = b"INFO".to_vec();
    let mut offset = 4;
    while offset < data.len() {
        check()?;
        let header = data
            .get(offset..offset + 8)
            .ok_or("invalid RIFF INFO header")?;
        let kind: [u8; 4] = header[..4].try_into().unwrap();
        let size = u32::from_le_bytes(header[4..].try_into().unwrap()) as usize;
        let end = offset
            .checked_add(8)
            .and_then(|offset| offset.checked_add(size))
            .and_then(|offset| offset.checked_add(size & 1))
            .ok_or("invalid RIFF INFO chunk size")?;
        let entry = data
            .get(offset..end)
            .ok_or("invalid RIFF INFO chunk size")?;
        let key = match &kind {
            b"IPRT" => *b"ITRK",
            b"IWRI" => *b"IMUS",
            _ => kind,
        };
        if !fields.contains_key(&key) {
            body.extend(entry);
        }
        offset = end;
    }
    for (kind, value) in fields {
        check()?;
        if value.trim().is_empty() {
            continue;
        }
        let size = value.len() + 1;
        if body.len() + 8 + size + (size & 1) > super::MAX_TAG_BYTES {
            return Err("RIFF INFO chunk exceeds 64 MiB".into());
        }
        body.extend(kind);
        body.extend((size as u32).to_le_bytes());
        body.extend(value.as_bytes());
        body.push(0);
        if size & 1 == 1 {
            body.push(0);
        }
    }
    let mut chunk = b"LIST".to_vec();
    chunk.extend((body.len() as u32).to_le_bytes());
    chunk.extend(body);
    Ok(chunk)
}
