//! Container readers for FLAC and Ogg streams, including Ogg page and packet parsing.

use super::{AudioMetadata, CoverArt, MAX_TAG_BYTES, bytes, comments, exact, id3, seek, utf8};
use base64::Engine;
use std::collections::BTreeMap;
use std::io::{Cursor, Read, Seek, SeekFrom};

pub(super) fn flac(reader: &mut (impl Read + Seek)) -> Result<AudioMetadata, String> {
    flac_inner(reader, None).map_err(|error| format!("failed to parse FLAC file: {error}"))
}

pub(super) fn flac_cover(reader: &mut (impl Read + Seek)) -> Result<CoverArt, String> {
    let mut cover = None;
    flac_with_cover(reader, &mut cover)?;
    cover.ok_or_else(|| "no cover art found in file".into())
}

pub(super) fn flac_with_cover(
    reader: &mut (impl Read + Seek),
    cover: &mut Option<CoverArt>,
) -> Result<AudioMetadata, String> {
    let metadata = flac_inner(reader, Some(cover))
        .map_err(|error| format!("failed to parse FLAC file: {error}"))?;
    if let Some(cover) = cover {
        cover.mime = if cover.data.len() > 8 && &cover.data[1..4] == b"PNG" {
            "image/png"
        } else {
            "image/jpeg"
        }
        .into();
    }
    Ok(metadata)
}

/// Locate the FLAC marker after an optional ID3v2 tag, leaving the reader at
/// the first metadata block. Writers retain the prefix outside this region.
pub(super) fn flac_start(reader: &mut (impl Read + Seek)) -> Result<u64, String> {
    let mut signature = [0; 4];
    exact(reader, &mut signature)?;
    let mut start = 0;
    if &signature[..3] == b"ID3" {
        let mut header = [0; 10];
        header[..4].copy_from_slice(&signature);
        exact(reader, &mut header[4..])?;
        start = id3::v2_tag_length(&header).ok_or("invalid ID3v2 header before fLaC")?;
        seek(reader, SeekFrom::Start(start))?;
        exact(reader, &mut signature)?;
    }
    if &signature != b"fLaC" {
        return Err("fLaC head incorrect".into());
    }
    Ok(start)
}

fn flac_inner(
    reader: &mut (impl Read + Seek),
    mut cover: Option<&mut Option<CoverArt>>,
) -> Result<AudioMetadata, String> {
    let start = flac_start(reader)?;
    let end = seek(reader, SeekFrom::End(0))?;
    seek(reader, SeekFrom::Start(start + 4))?;
    let mut metadata = AudioMetadata::default();
    let mut found = false;
    let mut front_cover = false;
    loop {
        let mut header = [0; 4];
        exact(reader, &mut header)?;
        let length = u32::from_be_bytes([0, header[1], header[2], header[3]]);
        let position = reader
            .stream_position()
            .map_err(|error| error.to_string())?;
        if position + u64::from(length) > end {
            return Err(if position == end {
                "EOF"
            } else {
                "unexpected EOF"
            }
            .into());
        }
        if header[0] & 0x7f == 4 && !found {
            let data = bytes(reader, length as usize)?;
            // FLAC uses the first valid Vorbis block; later blocks do not merge.
            if valid_comments(&data) {
                comments::flac(&mut metadata, &comments::parse(&data, usize::MAX));
                found = true;
            }
        } else if header[0] & 0x7f == 6 && !front_cover && cover.is_some() {
            let data = bytes(reader, length as usize)?;
            if let Some((kind, picture)) = picture_block(&data, false)
                && let Some(cover) = cover.as_deref_mut()
                && (kind == 3 || cover.is_none())
            {
                front_cover = kind == 3;
                *cover = Some(picture);
            }
        } else {
            seek(reader, SeekFrom::Current(i64::from(length)))?;
        }
        if header[0] & 0x80 != 0 {
            let mut sync = [0; 2];
            exact(reader, &mut sync)?;
            if sync[0] != 0xff || sync[1] >> 2 != 0x3e {
                return Err("frames do not begin with sync code".into());
            }
            return Ok(metadata);
        }
    }
}

fn picture_block(data: &[u8], ogg_limits: bool) -> Option<(u32, CoverArt)> {
    let parse = || -> Result<(u32, CoverArt), String> {
        let mut input = Cursor::new(data);
        let kind = u32::from_be_bytes(bytes(&mut input, 4)?.try_into().unwrap());
        let mime_length = u32::from_be_bytes(bytes(&mut input, 4)?.try_into().unwrap()) as usize;
        if mime_length > data.len().saturating_sub(8) || ogg_limits && mime_length > 256 {
            return Err("invalid picture MIME length".into());
        }
        let mime = utf8(&bytes(&mut input, mime_length)?);
        let description = u32::from_be_bytes(bytes(&mut input, 4)?.try_into().unwrap());
        if ogg_limits && description > 10000 {
            return Err("invalid picture description length".into());
        }
        seek(&mut input, SeekFrom::Current(i64::from(description) + 16))?;
        let length = u32::from_be_bytes(bytes(&mut input, 4)?.try_into().unwrap()) as usize;
        if length == 0
            || length > data.len().saturating_sub(input.position() as usize)
            || ogg_limits && length > MAX_TAG_BYTES
        {
            return Err("invalid picture data length".into());
        }
        Ok((
            kind,
            CoverArt {
                data: bytes(&mut input, length)?,
                mime,
            },
        ))
    };
    parse().ok()
}

fn valid_comments(data: &[u8]) -> bool {
    let Some(vendor) = data.get(..4) else {
        return false;
    };
    let Some(mut offset) = (u32::from_le_bytes(vendor.try_into().unwrap()) as usize).checked_add(8)
    else {
        return false;
    };
    let Some(count) = data.get(offset - 4..offset) else {
        return false;
    };
    for _ in 0..u32::from_le_bytes(count.try_into().unwrap()) {
        let Some(length) = data.get(offset..offset.saturating_add(4)) else {
            return false;
        };
        let length = u32::from_le_bytes(length.try_into().unwrap()) as usize;
        offset = offset.saturating_add(4).saturating_add(length);
        // bytes.Reader.Read reports EOF even for a zero-length comment when
        // its length field exhausted the block; Go skips that invalid block.
        if offset > data.len() || length == 0 && offset == data.len() {
            return false;
        }
    }
    true
}

#[derive(Clone)]
pub(crate) struct OggPage {
    pub(crate) header: [u8; 27],
    pub(crate) segments: Vec<u8>,
    pub(crate) data: Vec<u8>,
}

impl OggPage {
    pub(crate) fn read(reader: &mut impl Read) -> Result<Option<Self>, String> {
        let mut header = [0; 27];
        let mut offset = 0;
        while offset < header.len() {
            let count = reader
                .read(&mut header[offset..])
                .map_err(|error| error.to_string())?;
            if count == 0 {
                return if offset == 0 {
                    Ok(None)
                } else {
                    Err("unexpected EOF".into())
                };
            }
            offset += count;
        }
        if &header[..4] != b"OggS" {
            return Err("not an Ogg page".into());
        }
        let segments = bytes(reader, header[26] as usize)?;
        let data = bytes(reader, segments.iter().map(|n| *n as usize).sum())?;
        Ok(Some(Self {
            header,
            segments,
            data,
        }))
    }

    pub(crate) fn len(&self) -> usize {
        27 + self.segments.len() + self.data.len()
    }
}

/// Bound the header read by bytes, allowing page framing around the same
/// comment payload size our tag writer accepts. Artwork grows by one third
/// in Base64, so the old 10 MiB packet limit rejected valid converted songs.
const OGG_COMMENT_BYTES: usize = MAX_TAG_BYTES + 1024 * 1024;

pub(crate) fn ogg_packets(
    reader: &mut impl Read,
    max_packets: usize,
    max_pages: usize,
) -> Result<Vec<Vec<u8>>, String> {
    ogg_packets_until(
        reader,
        max_packets,
        max_pages,
        usize::MAX,
        10 * 1024 * 1024,
        |_| false,
    )
}

/// Packets up to and including the comment header (`OpusTags` or the Vorbis
/// comment packet), which follows the identification header.
fn ogg_comment_packets(reader: &mut impl Read) -> Result<Vec<Vec<u8>>, String> {
    ogg_packets_until(
        reader,
        30,
        usize::MAX,
        OGG_COMMENT_BYTES,
        MAX_TAG_BYTES,
        |packet| packet.starts_with(b"OpusTags") || packet.starts_with(b"\x03vorbis"),
    )
}

fn ogg_packets_until(
    reader: &mut impl Read,
    max_packets: usize,
    max_pages: usize,
    max_bytes: usize,
    max_packet_bytes: usize,
    done: impl Fn(&[u8]) -> bool,
) -> Result<Vec<Vec<u8>>, String> {
    let mut packets = Vec::new();
    let mut current = Vec::new();
    let mut skip_packet = false;
    let mut consumed = 0;
    for _ in 0..max_pages {
        if consumed >= max_bytes {
            break;
        }
        let page = OggPage::read(reader).and_then(|page| page.ok_or_else(|| "EOF".into()));
        let OggPage {
            header,
            segments,
            data,
        } = match page {
            Ok(page) => page,
            Err(error) if packets.is_empty() => return Err(error),
            Err(_) => break,
        };
        consumed += header.len() + segments.len() + data.len();
        if header[5] & 1 == 0 && !current.is_empty() {
            current.clear();
            skip_packet = false;
        }
        let mut offset = 0;
        for length in segments {
            let length = length as usize;
            if !skip_packet && current.len() + length > max_packet_bytes {
                current.clear();
                skip_packet = true;
            }
            if !skip_packet {
                current.extend_from_slice(&data[offset..offset + length]);
            }
            offset += length;
            if length < 255 {
                if !current.is_empty() {
                    let packet = std::mem::take(&mut current);
                    let finished = done(&packet);
                    packets.push(packet);
                    if finished {
                        return Ok(packets);
                    }
                }
                skip_packet = false;
                if packets.len() >= max_packets {
                    break;
                }
            }
        }
        if packets.len() >= max_packets {
            break;
        }
    }
    Ok(packets)
}

pub(crate) fn ogg_stream_is_opus(packets: &[Vec<u8>]) -> Option<bool> {
    packets.iter().find_map(|packet| {
        if packet.starts_with(b"OpusHead") {
            Some(true)
        } else if packet.len() > 7 && packet.starts_with(b"\x01vorbis") {
            Some(false)
        } else {
            None
        }
    })
}

pub(super) fn ogg(reader: &mut impl Read) -> Result<AudioMetadata, String> {
    let packets = ogg_comment_packets(reader)?;
    let stream = ogg_stream_is_opus(&packets);
    let packet = packets.iter().find_map(|packet| {
        if stream != Some(false) && packet.len() > 8 && packet.starts_with(b"OpusTags") {
            Some(&packet[8..])
        } else if stream != Some(true) && packet.len() > 7 && packet.starts_with(b"\x03vorbis") {
            Some(&packet[7..])
        } else {
            None
        }
    });
    // Every Opus and Vorbis stream has this header, so a complete one without
    // a title or artist is an untagged or partly tagged song, not a failed read.
    packet
        .map(|data| comments::ogg(&comments::parse(data, 512 * 1024)))
        .ok_or_else(|| "no Vorbis comments found".into())
}

pub(super) fn ogg_cover(reader: &mut impl Read) -> Result<CoverArt, String> {
    let packets = ogg_comment_packets(reader)?;
    let stream = ogg_stream_is_opus(&packets);
    for packet in &packets {
        let comments = if stream != Some(false) && packet.starts_with(b"OpusTags") {
            &packet[8..]
        } else if stream != Some(true) && packet.starts_with(b"\x03vorbis") {
            &packet[7..]
        } else {
            continue;
        };
        for (key, value) in comments::parse(comments, MAX_TAG_BYTES) {
            if !key.eq_ignore_ascii_case("METADATA_BLOCK_PICTURE") {
                continue;
            }
            let value: Vec<_> = value
                .bytes()
                .filter(|byte| !matches!(byte, b' ' | b'\t' | b'\r' | b'\n'))
                .collect();
            let decoded = base64::engine::general_purpose::STANDARD
                .decode(&value)
                .or_else(|_| base64::engine::general_purpose::STANDARD_NO_PAD.decode(&value));
            if let Ok(decoded) = decoded
                && let Some((_, cover)) = picture_block(&decoded, true)
            {
                return Ok(cover);
            }
        }
    }
    Err("no cover art found".into())
}

pub(super) fn ape(reader: &mut (impl Read + Seek)) -> Result<AudioMetadata, String> {
    let end = seek(reader, SeekFrom::End(0))?;
    if end < 32 {
        return Err("file too small for APE tag".into());
    }
    for offset in [Some(end - 32), end.checked_sub(161).map(|_| end - 160)]
        .into_iter()
        .flatten()
    {
        if let Ok(metadata) = ape_at(reader, offset) {
            return Ok(metadata);
        }
    }
    Err("no APEv2 tag found".into())
}

pub(crate) struct ApeFooter {
    pub(crate) version: u32,
    pub(crate) size: u32,
    pub(crate) count: u32,
    pub(crate) flags: u32,
}

impl ApeFooter {
    pub(crate) fn read(
        reader: &mut (impl Read + Seek),
        offset: u64,
    ) -> Result<Option<Self>, String> {
        seek(reader, SeekFrom::Start(offset))?;
        let data = bytes(reader, 32)?;
        let integer = |index| u32::from_le_bytes(data[index..index + 4].try_into().unwrap());
        if &data[..8] != b"APETAGEX" || integer(20) & (1 << 29) != 0 {
            return Ok(None);
        }
        Ok(Some(Self {
            version: integer(8),
            size: integer(12),
            count: integer(16),
            flags: integer(20),
        }))
    }

    pub(crate) fn items_start(&self, offset: u64) -> Result<u64, String> {
        if !matches!(self.version, 1000 | 2000) || self.size < 32 || self.count > 1000 {
            return Err("invalid APE footer".into());
        }
        offset
            .checked_sub(u64::from(self.size - 32))
            .ok_or_else(|| "invalid APE items offset".into())
    }
}

fn ape_at(reader: &mut (impl Read + Seek), footer: u64) -> Result<AudioMetadata, String> {
    let header = ApeFooter::read(reader, footer)?.ok_or("invalid APE footer")?;
    let start = header.items_start(footer)?;
    seek(reader, SeekFrom::Start(start))?;
    let mut remaining = footer - start;
    let mut metadata = AudioMetadata::default();
    for _ in 0..header.count {
        if remaining < 8 {
            break;
        }
        let header = bytes(reader, 8)?;
        remaining -= 8;
        let length = u64::from(u32::from_le_bytes(header[..4].try_into().unwrap()));
        let mut key = Vec::new();
        let mut terminated = false;
        while remaining > 0 {
            let mut value = [0];
            exact(reader, &mut value)?;
            remaining -= 1;
            if value[0] == 0 {
                terminated = true;
                break;
            }
            // Unknown overlong keys cannot match any supported metadata field.
            if key.len() <= 1024 {
                key.push(value[0]);
            }
        }
        if !terminated || length > remaining {
            break;
        }
        if length <= 32 * 1024 * 1024 && key.len() <= 1024 && comments::ape_key(&utf8(&key)) {
            let value = bytes(reader, length as usize)?;
            comments::apply(&mut metadata, &utf8(&key), &utf8(&value), true);
        } else {
            seek(reader, SeekFrom::Current(length as i64))?;
        }
        remaining -= length;
    }
    Ok(metadata)
}

pub(super) fn riff(reader: &mut (impl Read + Seek), aiff: bool) -> Result<AudioMetadata, String> {
    let (tag, info) = riff_chunks(reader, aiff)?;
    riff_metadata(&tag, &info, aiff)
}

pub(super) fn riff_cover(reader: &mut (impl Read + Seek), aiff: bool) -> Result<CoverArt, String> {
    let (tag, _) = riff_chunks(reader, aiff).map_err(|_| "no embedded cover")?;
    let (data, mime) = super::write::embedded_cover(&tag).ok_or("no embedded cover")?;
    Ok(CoverArt { data, mime })
}

fn riff_chunks(
    reader: &mut (impl Read + Seek),
    aiff: bool,
) -> Result<(Vec<u8>, BTreeMap<String, String>), String> {
    let header = bytes(reader, 12)?;
    if if aiff {
        &header[..4] != b"FORM" || !matches!(&header[8..], b"AIFF" | b"AIFC")
    } else {
        &header[..4] != b"RIFF" || &header[8..] != b"WAVE"
    } {
        return Err(if aiff {
            "not an AIFF file"
        } else {
            "not a WAVE file"
        }
        .into());
    }
    let mut tag = Vec::new();
    let mut info = BTreeMap::<String, String>::new();
    loop {
        let mut header = [0; 8];
        if exact(reader, &mut header).is_err() {
            break;
        }
        let length = if aiff {
            u32::from_be_bytes(header[4..].try_into().unwrap())
        } else {
            u32::from_le_bytes(header[4..].try_into().unwrap())
        };
        let wanted = matches!(&header[..4], b"ID3 " | b"id3 ")
            || if aiff {
                matches!(&header[..4], b"NAME" | b"AUTH" | b"ANNO" | b"(c) ")
            } else {
                &header[..4] == b"LIST"
            };
        if wanted && length > 0 && length <= 16 * 1024 * 1024 {
            if let Ok(data) = bytes(reader, length as usize) {
                if matches!(&header[..4], b"ID3 " | b"id3 ") {
                    tag = data;
                } else if aiff {
                    info.insert(
                        utf8(&header[..4]),
                        utf8(&data).trim().trim_end_matches('\0').into(),
                    );
                } else {
                    riff_info(&data, &mut info);
                }
            }
            seek(reader, SeekFrom::Current(i64::from(length & 1)))?;
        } else {
            seek(
                reader,
                SeekFrom::Current(i64::from(length) + i64::from(length & 1)),
            )?;
        }
    }
    Ok((tag, info))
}

fn riff_metadata(
    tag: &[u8],
    info: &BTreeMap<String, String>,
    aiff: bool,
) -> Result<AudioMetadata, String> {
    if let Ok(metadata) = id3::embedded(tag)
        && has_tags(&metadata)
    {
        return Ok(metadata);
    }
    let get = |key| info.get(key).cloned().unwrap_or_default();
    let metadata = if aiff {
        AudioMetadata {
            title: get("NAME"),
            artist: get("AUTH"),
            comment: get("ANNO"),
            copyright: get("(c) "),
            ..AudioMetadata::default()
        }
    } else {
        let date = get("ICRD");
        AudioMetadata {
            title: get("INAM"),
            artist: get("IART"),
            album: get("IPRD"),
            genre: id3::genre(&get("IGNR")),
            year: if date.len() >= 4 {
                utf8(&date.as_bytes()[..4])
            } else {
                String::new()
            },
            date,
            comment: get("ICMT"),
            copyright: get("ICOP"),
            composer: get("IMUS"),
            track_number: get("ITRK").trim().parse::<isize>().unwrap_or(0) as i64,
            ..AudioMetadata::default()
        }
    };
    if has_tags(&metadata) {
        Ok(metadata)
    } else {
        Err(if aiff {
            "no AIFF tags found"
        } else {
            "no WAV tags found"
        }
        .into())
    }
}

fn has_tags(metadata: &AudioMetadata) -> bool {
    !metadata.title.is_empty() || !metadata.artist.is_empty() || !metadata.album.is_empty()
}

fn riff_info(data: &[u8], info: &mut BTreeMap<String, String>) {
    if !data.starts_with(b"INFO") {
        return;
    }
    let mut offset: usize = 4;
    while let Some(header) = data.get(offset..offset.saturating_add(8)) {
        let length = u32::from_le_bytes(header[4..].try_into().unwrap()) as usize;
        offset += 8;
        if length == 0 {
            break;
        }
        let Some(value) = data.get(offset..offset.saturating_add(length)) else {
            break;
        };
        info.insert(
            utf8(&header[..4]),
            utf8(value).trim_end_matches('\0').trim().into(),
        );
        offset += length;
        offset = offset.saturating_add(length & 1);
    }
}
