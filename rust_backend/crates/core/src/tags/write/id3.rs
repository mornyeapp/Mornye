//! ID3v2 tag writing: parses the existing header and builds or rewrites the tag frames.

use super::{Fields, MAX_TAG_BYTES, bytes, cover_mime, edit_index, pair, seek};
use crate::matching::uppercase;
use crate::tags::id3::{decode, user_text};
use std::collections::BTreeSet;
use std::io::{Cursor, Read, Seek, SeekFrom};

struct Frame {
    id: Vec<u8>,
    data: Vec<u8>,
}

pub(super) fn header(
    source: &mut (impl Read + Seek),
    fields: &Fields,
    cover: Option<&[u8]>,
    check: &dyn Fn() -> Result<(), String>,
) -> Result<(Vec<u8>, u64), String> {
    edit_header(source, fields, cover, None, 512, check)
}

pub(super) fn fresh(
    fields: &Fields,
    cover: Option<(&[u8], &str)>,
    check: &dyn Fn() -> Result<(), String>,
) -> Result<Vec<u8>, String> {
    embedded_header(&mut Cursor::new(Vec::<u8>::new()), fields, cover, check)
}

pub(super) fn embedded_header(
    source: &mut (impl Read + Seek),
    fields: &Fields,
    cover: Option<(&[u8], &str)>,
    check: &dyn Fn() -> Result<(), String>,
) -> Result<Vec<u8>, String> {
    edit_header(
        source,
        fields,
        cover.map(|p| p.0),
        cover.map(|p| p.1),
        0,
        check,
    )
    .map(|result| result.0)
}

fn edit_header(
    source: &mut (impl Read + Seek),
    fields: &Fields,
    cover: Option<&[u8]>,
    mime_override: Option<&str>,
    padding: usize,
    check: &dyn Fn() -> Result<(), String>,
) -> Result<(Vec<u8>, u64), String> {
    let (frames, audio_start) = read_frames(source, check)?;
    let mut drop = BTreeSet::<Vec<u8>>::new();
    let mut added = Vec::new();
    for (field, id, aliases) in [
        ("title", "TIT2", &[][..]),
        ("artist", "TPE1", &[][..]),
        ("album", "TALB", &[][..]),
        ("album_artist", "TPE2", &[][..]),
        ("date", "TDRC", &["TYER", "TDAT", "TIME"][..]),
        ("genre", "TCON", &[][..]),
        ("label", "TPUB", &[][..]),
        ("copyright", "TCOP", &[][..]),
        ("composer", "TCOM", &[][..]),
        ("isrc", "TSRC", &[][..]),
        ("compilation", "TCMP", &[][..]),
    ] {
        if let Some(value) = fields.get(field) {
            drop.insert(id.as_bytes().to_vec());
            for alias in aliases {
                drop.insert(alias.as_bytes().to_vec());
            }
            if !value.trim().is_empty() {
                added.push(frame(id, text(value)));
            }
        }
    }
    for (field, id) in [("comment", "COMM"), ("lyrics", "USLT")] {
        if let Some(value) = fields.get(field) {
            drop.insert(id.as_bytes().to_vec());
            if !value.trim().is_empty() {
                let mut data = b"\x03eng\0".to_vec();
                data.extend(value.as_bytes());
                added.push(frame(id, data));
            }
        }
    }
    for (field, total, id) in [
        ("track_number", "track_total", "TRCK"),
        ("disc_number", "disc_total", "TPOS"),
    ] {
        if fields.contains_key(field) || fields.contains_key(total) {
            let current = frames
                .iter()
                .find(|frame| frame.id == id.as_bytes())
                .map(|frame| {
                    let value = frame
                        .data
                        .split_first()
                        .map(|(encoding, data)| decode(*encoding, data))
                        .unwrap_or_default();
                    pair(value.split('\0').next().unwrap_or_default())
                })
                .unwrap_or_default();
            drop.insert(id.as_bytes().to_vec());
            let value = edit_index(current, fields, field, total);
            if !value.is_empty() {
                added.push(frame(id, text(&value)));
            }
        }
    }
    let mut drop_descriptions = BTreeSet::new();
    for (field, description) in [
        ("replaygain_track_gain", "REPLAYGAIN_TRACK_GAIN"),
        ("replaygain_track_peak", "REPLAYGAIN_TRACK_PEAK"),
        ("replaygain_album_gain", "REPLAYGAIN_ALBUM_GAIN"),
        ("replaygain_album_peak", "REPLAYGAIN_ALBUM_PEAK"),
        ("explicit", "ITUNESADVISORY"),
        ("album_type", "RELEASETYPE"),
        ("upc", "BARCODE"),
    ] {
        if let Some(value) = fields.get(field) {
            drop_descriptions.insert(description.to_owned());
            if !value.trim().is_empty() {
                let mut data = text(description);
                data.push(0);
                data.extend(value.as_bytes());
                added.push(frame("TXXX", data));
            }
        }
    }
    if let Some(cover) = cover {
        drop.insert(b"APIC".to_vec());
        let mime = if let Some(mime) = mime_override {
            mime
        } else if cover_mime(cover) != "image/jpeg" || cover.starts_with(b"\xff\xd8\xff") {
            cover_mime(cover)
        } else if cover.starts_with(b"BM") {
            "image/bmp"
        } else if cover.starts_with(b"%PDF-") {
            "application/pdf"
        } else if cover
            .iter()
            .take(512)
            .all(|b| !matches!(b, 0..=8 | 11 | 14..=26 | 28..=31))
        {
            "text/plain; charset=utf-8"
        } else {
            "application/octet-stream"
        };
        let mut data = text(mime);
        data.extend([0, 3, 0]);
        data.extend(cover);
        added.push(frame("APIC", data));
    }
    let kept = frames.into_iter().filter(|frame| {
        !drop.contains(&frame.id)
            && !(frame.id == b"TXXX"
                && drop_descriptions.contains(&uppercase(user_text(&frame.data).0.trim())))
    });
    let mut body = Vec::new();
    for frame in kept.chain(added) {
        check()?;
        if body.len() + frame.data.len() + 10 + padding > MAX_TAG_BYTES {
            return Err("ID3 metadata exceeds 64 MiB".into());
        }
        body.extend(frame.id);
        body.extend(syncsafe(frame.data.len()));
        body.extend([0, 0]);
        body.extend(frame.data);
    }
    body.resize(body.len() + padding, 0);
    let mut result = b"ID3\x04\0\0".to_vec();
    result.extend(syncsafe(body.len()));
    result.extend(body);
    Ok((result, audio_start))
}

pub(in crate::tags) fn cover(tag: &[u8]) -> Option<(Vec<u8>, String)> {
    let (frames, _) = read_frames(&mut Cursor::new(tag), &|| Ok(())).ok()?;
    let data = &frames.iter().find(|frame| frame.id == b"APIC")?.data;
    // read_frames also normalizes ID3v2.2 PIC frames to APIC.
    let picture = super::super::id3::picture_frame(data, 4)?;
    Some((picture.data, picture.mime))
}

fn frame(id: &str, data: Vec<u8>) -> Frame {
    Frame {
        id: id.as_bytes().to_vec(),
        data,
    }
}
fn text(value: &str) -> Vec<u8> {
    let mut data = vec![3];
    data.extend(value.as_bytes());
    data
}

fn syncsafe(size: usize) -> [u8; 4] {
    [
        (size >> 21 & 127) as u8,
        (size >> 14 & 127) as u8,
        (size >> 7 & 127) as u8,
        (size & 127) as u8,
    ]
}

fn size(data: &[u8], syncsafe: bool) -> usize {
    if syncsafe {
        crate::tags::id3::syncsafe(data) as usize
    } else {
        u32::from_be_bytes(data.try_into().unwrap()) as usize
    }
}

fn read_frames(
    source: &mut (impl Read + Seek),
    check: &dyn Fn() -> Result<(), String>,
) -> Result<(Vec<Frame>, u64), String> {
    let mut header = [0; 10];
    let mut received = 0;
    while received < header.len() {
        let n = source
            .read(&mut header[received..])
            .map_err(|e| e.to_string())?;
        if n == 0 {
            break;
        }
        received += n;
    }
    if received < 10 || &header[..3] != b"ID3" {
        return Ok((Vec::new(), 0));
    }
    let version = header[3];
    let flags = header[5];
    let length = size(&header[6..], true);
    if length == 0 {
        return Err("invalid ID3v2 tag size".into());
    }
    if length > MAX_TAG_BYTES {
        return Err("ID3 metadata exceeds 64 MiB".into());
    }
    let end = seek(source, SeekFrom::End(0))?;
    if 10 + length as u64 > end {
        return Err("truncated ID3v2 tag".into());
    }
    seek(source, SeekFrom::Start(10))?;
    let mut data = bytes(source, length)?;
    let audio_start = 10 + length as u64 + if flags & 0x10 != 0 { 10 } else { 0 };
    if flags & 0x10 != 0 && data.len() >= 10 && &data[data.len() - 10..data.len() - 7] == b"3DI" {
        data.truncate(data.len() - 10);
    }
    let mut offset = 0;
    if flags & 0x40 != 0 && data.len() >= 4 && matches!(version, 3 | 4) {
        let length = size(&data[..4], version == 4);
        if length > 0 {
            let skip = if length + 4 <= data.len() {
                length + 4
            } else if length <= data.len() {
                length
            } else {
                0
            };
            if skip < data.len() {
                offset = skip;
            }
        }
    }
    let mut frames = Vec::new();
    let header_length = if version == 2 { 6 } else { 10 };
    while offset + header_length < data.len() {
        check()?;
        if frames.len() >= 65536 {
            return Err("ID3 frame count exceeds 65536".into());
        }
        let id_length = if version == 2 { 3 } else { 4 };
        let id = &data[offset..offset + id_length];
        if id[0] == 0 {
            break;
        }
        let length = if version == 2 {
            ((data[offset + 3] as usize) << 16)
                | ((data[offset + 4] as usize) << 8)
                | data[offset + 5] as usize
        } else {
            size(&data[offset + 4..offset + 8], version == 4)
        };
        if length == 0 || length > data.len() - offset - header_length {
            break;
        }
        let frame_flags = if version == 2 { 0 } else { data[offset + 9] };
        let mut payload = &data[offset + header_length..offset + header_length + length];
        offset += header_length + length;
        if version == 3 {
            if frame_flags & 0xc0 != 0 {
                continue;
            }
            if frame_flags & 0x20 != 0 {
                payload = &payload[1..];
            }
        } else if version != 2 {
            if frame_flags & 0x0c != 0 {
                continue;
            }
            if frame_flags & 0x40 != 0 {
                payload = &payload[1..];
            }
            if frame_flags & 1 != 0 {
                if payload.len() < 4 {
                    continue;
                }
                payload = &payload[4..];
            }
        }
        let mut payload =
            if flags & 0x80 != 0 || (version != 2 && version != 3 && frame_flags & 2 != 0) {
                let mut result = Vec::new();
                let mut offset = 0;
                while offset < payload.len() {
                    result.push(payload[offset]);
                    offset += if payload[offset] == 0xff && payload.get(offset + 1) == Some(&0) {
                        2
                    } else {
                        1
                    };
                }
                result
            } else {
                payload.to_vec()
            };
        let id = if version == 2 {
            match id {
                b"TT2" => b"TIT2".as_slice(),
                b"TP1" => b"TPE1",
                b"TP2" => b"TPE2",
                b"TAL" => b"TALB",
                b"TYE" => b"TDRC",
                b"TCO" => b"TCON",
                b"TRK" => b"TRCK",
                b"TPA" => b"TPOS",
                b"TCM" => b"TCOM",
                b"TPB" => b"TPUB",
                b"TCR" => b"TCOP",
                b"TXX" => b"TXXX",
                b"ULT" => b"USLT",
                b"COM" => b"COMM",
                b"PIC" => {
                    if payload.len() < 5 {
                        continue;
                    }
                    let mime = if payload[1..4].eq_ignore_ascii_case(b"PNG") {
                        "image/png"
                    } else {
                        "image/jpeg"
                    };
                    let mut converted = vec![payload[0]];
                    converted.extend(mime.as_bytes());
                    converted.push(0);
                    converted.extend(&payload[4..]);
                    payload = converted;
                    b"APIC"
                }
                _ => continue,
            }
        } else {
            id
        };
        frames.push(Frame {
            id: id.to_vec(),
            data: payload,
        });
    }
    Ok((frames, audio_start))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn previous_syncsafe_size(data: &[u8]) -> usize {
        ((data[0] as usize) << 21)
            | ((data[1] as usize) << 14)
            | ((data[2] as usize) << 7)
            | data[3] as usize
    }

    #[test]
    fn syncsafe_size_matches_previous_decoder_across_bit_boundaries() {
        assert_eq!(size(&[0, 0, 0, 0], true), 0);
        assert_eq!(size(&[0, 0, 0, 0x7f], true), 0x7f);
        assert_eq!(size(&[0, 0, 1, 0], true), 0x80);
        assert_eq!(size(&[0x7f, 0x7f, 0x7f, 0x7f], true), 0x0fff_ffff);
        assert_eq!(size(&[0, 0, 0, 0x80], true), 0x80);
        assert_eq!(size(&[0xff, 0xff, 0xff, 0xff], true), 0x1fff_ffff);
        assert_eq!(size(&[0, 0, 1, 0, 9], true), 0x80);
        let values = [0x00, 0x01, 0x7f, 0x80, 0xff];
        for a in values {
            for b in values {
                for c in values {
                    for d in values {
                        let data = [a, b, c, d];
                        assert_eq!(size(&data, true), previous_syncsafe_size(&data), "{data:?}");
                    }
                }
            }
        }
    }
}
