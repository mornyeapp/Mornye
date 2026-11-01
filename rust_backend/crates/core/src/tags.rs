//! Audio tags used by metadata, lyrics and duplicate detection. Readers are
//! supplied by the native owner so descriptor paths need no temporary copy.

mod comments;
mod containers;
mod file;
mod id3;
mod library;
mod mp4;
mod separators;
mod write;
use crate::text::utf8;
pub(crate) use containers::{ogg_packets, ogg_stream_is_opus};
pub use file::{file_metadata_extension, read_file_metadata};
pub(crate) use id3::v2_tag_length;
pub use library::{
    library_extension, library_id, library_metadata, read_library_metadata,
    read_library_metadata_with_cover,
};
pub use separators::format_metadata_tag_value;
use serde::Serialize;
use std::io::{self, BufReader, Read, Seek, SeekFrom};
pub use write::{
    embed_flac_metadata, rewrite_ac4_config, rewrite_ac4_metadata, rewrite_audio_tags,
    rewrite_flac_tags_if_changed, rewrite_m4a_freeform,
};

// Readers must accept the tag blocks our native writers can produce.
const MAX_TAG_BYTES: usize = 64 * 1024 * 1024;

#[derive(Clone, Debug)]
pub struct CoverArt {
    pub data: Vec<u8>,
    pub mime: String,
}

/// The container behind an extension that names more than one: Opus is also
/// carried in MP4 under a .opus name, and .aac names both MP4 and raw ADTS
/// streams, the latter often behind an ID3v2 tag. ADTS reports "adts".
fn read_container_format<'a>(
    reader: &mut (impl Read + Seek),
    format: &'a str,
) -> Result<&'a str, String> {
    if !matches!(format, "opus" | "aac") {
        return Ok(format);
    }
    let mut header = [0; 10];
    let length = read_prefix(reader, 0, &mut header)?;
    let container = if length >= 8 && &header[4..8] == b"ftyp" {
        if format == "opus" { "m4a" } else { format }
    } else if format == "aac" {
        let mut sync = [0; 2];
        let synced = match id3::v2_tag_length(&header[..length]) {
            Some(tag) => read_prefix(reader, tag, &mut sync)? == sync.len(),
            None => {
                sync.copy_from_slice(&header[..2]);
                length >= sync.len()
            }
        };
        if synced && crate::media::is_adts_frame(&sync) {
            "adts"
        } else {
            format
        }
    } else {
        format
    };
    reader
        .seek(SeekFrom::Start(0))
        .map_err(|error| error.to_string())?;
    Ok(container)
}

/// The container a file's bytes begin with, for names that cannot be trusted:
/// "flac" (also behind an ID3v2 tag, as the FLAC tag writer accepts), "m4a",
/// "mp3", or "" for anything else.
pub fn sniff_container(reader: &mut (impl Read + Seek)) -> Result<&'static str, String> {
    let mut header = [0; 10];
    let length = read_prefix(reader, 0, &mut header)?;
    let mut start = [0; 4];
    let found = match id3::v2_tag_length(&header[..length]) {
        Some(tag) => read_prefix(reader, tag, &mut start)?,
        None => {
            let found = length.min(start.len());
            start[..found].copy_from_slice(&header[..found]);
            found
        }
    };
    let container = if found == 4 && &start == b"fLaC" {
        "flac"
    } else if length >= 8 && &header[4..8] == b"ftyp" {
        "m4a"
    } else if found >= 2 && start[0] == 0xff && start[1] & 0xe6 == 0xe2 {
        // MPEG audio Layer III. ADTS shares the sync word with layer 0.
        "mp3"
    } else {
        ""
    };
    reader
        .seek(SeekFrom::Start(0))
        .map_err(|error| error.to_string())?;
    Ok(container)
}

/// Fills as much of `data` as the file has from `offset`, without treating a
/// short file as an error.
fn read_prefix(
    reader: &mut (impl Read + Seek),
    offset: u64,
    data: &mut [u8],
) -> Result<usize, String> {
    reader
        .seek(SeekFrom::Start(offset))
        .map_err(|error| error.to_string())?;
    let mut length = 0;
    while length < data.len() {
        match reader.read(&mut data[length..]) {
            Ok(0) => break,
            Ok(count) => length += count,
            Err(error) if error.kind() == io::ErrorKind::Interrupted => {}
            Err(error) => return Err(error.to_string()),
        }
    }
    Ok(length)
}

/// Extract the embedded bytes without decoding the image or reading audio into
/// memory. Path hints and output publication belong to the owner.
pub fn extract_cover(
    reader: &mut (impl Read + Seek),
    format: &str,
    check: &dyn Fn() -> Result<(), String>,
) -> Result<CoverArt, String> {
    check()?;
    reader
        .seek(SeekFrom::Start(0))
        .map_err(|error| error.to_string())?;
    let mut observed = file::ObservedReader {
        file: reader,
        check,
        failure: None,
    };
    let format = read_container_format(&mut observed, format)?;
    let mut reader = BufReader::new(&mut observed);
    let result = match format {
        "flac" => containers::flac_cover(&mut reader),
        "m4a" | "aac" => mp4::cover(&mut reader),
        "mp3" | "adts" => id3::cover(&mut reader),
        "ogg" | "opus" => containers::ogg_cover(&mut reader),
        "wav" => containers::riff_cover(&mut reader, false),
        "aiff" | "aif" | "aifc" => containers::riff_cover(&mut reader, true),
        _ => Err("unsupported audio format for cover extraction".into()),
    };
    if let Some(error) = observed.failure {
        return Err(error);
    }
    check()?;
    result
}

#[derive(Clone, Debug, Default, PartialEq, Serialize)]
pub struct AudioMetadata {
    pub title: String,
    pub artist: String,
    pub album: String,
    pub album_artist: String,
    pub genre: String,
    pub year: String,
    pub date: String,
    pub track_number: i64,
    pub total_tracks: i64,
    pub disc_number: i64,
    pub total_discs: i64,
    pub isrc: String,
    pub lyrics: String,
    pub label: String,
    pub copyright: String,
    pub composer: String,
    pub comment: String,
    pub album_type: String,
    pub explicit: bool,
    pub upc: String,
    pub replay_gain_track_gain: String,
    pub replay_gain_track_peak: String,
    pub replay_gain_album_gain: String,
    pub replay_gain_album_peak: String,
}

struct CheckedReader<'a, R> {
    reader: R,
    check: &'a dyn Fn() -> Result<(), String>,
}

impl<R: Read> Read for CheckedReader<'_, R> {
    fn read(&mut self, buffer: &mut [u8]) -> io::Result<usize> {
        (self.check)().map_err(io::Error::other)?;
        self.reader.read(buffer)
    }
}

impl<R: Seek> Seek for CheckedReader<'_, R> {
    fn seek(&mut self, position: SeekFrom) -> io::Result<u64> {
        (self.check)().map_err(io::Error::other)?;
        self.reader.seek(position)
    }
}

struct TagReader<'a, R> {
    reader: BufReader<CheckedReader<'a, R>>,
    position: u64,
}

impl<R: Read> Read for TagReader<'_, R> {
    fn read(&mut self, bytes: &mut [u8]) -> io::Result<usize> {
        (self.reader.get_ref().check)().map_err(io::Error::other)?;
        let count = self.reader.read(bytes)?;
        self.position += count as u64;
        Ok(count)
    }
}

impl<R: Read + Seek> Seek for TagReader<'_, R> {
    fn seek(&mut self, offset: SeekFrom) -> io::Result<u64> {
        (self.reader.get_ref().check)().map_err(io::Error::other)?;
        let target = match offset {
            SeekFrom::Start(position) => position,
            SeekFrom::Current(delta) => self
                .position
                .checked_add_signed(delta)
                .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "invalid tag seek"))?,
            SeekFrom::End(_) => {
                self.position = self.reader.seek(offset)?;
                return Ok(self.position);
            }
        };
        if let Ok(delta) = i64::try_from(i128::from(target) - i128::from(self.position)) {
            self.reader.seek_relative(delta)?;
        } else {
            self.reader.seek(SeekFrom::Start(target))?;
        }
        self.position = target;
        Ok(target)
    }

    fn stream_position(&mut self) -> io::Result<u64> {
        (self.reader.get_ref().check)().map_err(io::Error::other)?;
        Ok(self.position)
    }
}

pub fn read_audio_tags(
    reader: &mut (impl Read + Seek),
    format: &str,
    check: &dyn Fn() -> Result<(), String>,
) -> Result<AudioMetadata, String> {
    read_tags(reader, format, check, None)
}

fn read_tags(
    reader: &mut (impl Read + Seek),
    format: &str,
    check: &dyn Fn() -> Result<(), String>,
    cover: Option<&mut Option<CoverArt>>,
) -> Result<AudioMetadata, String> {
    check()?;
    reader
        .seek(SeekFrom::Start(0))
        .map_err(|error| error.to_string())?;
    let mut reader = TagReader {
        reader: BufReader::new(CheckedReader { reader, check }),
        position: 0,
    };
    let format = read_container_format(&mut reader, format)?;
    let result = match format {
        "flac" => match cover {
            Some(cover) => containers::flac_with_cover(&mut reader, cover),
            None => containers::flac(&mut reader),
        },
        "m4a" | "mp4" | "aac" => mp4::read(&mut reader),
        "mp3" => id3::read(&mut reader),
        // ADTS has no tag format of its own; taggers use ID3 or APEv2.
        "adts" => id3::read(&mut reader).or_else(|_| containers::ape(&mut reader)),
        "ogg" | "opus" => containers::ogg(&mut reader),
        "ape" | "wv" | "mpc" => containers::ape(&mut reader),
        "wav" => containers::riff(&mut reader, false),
        "aiff" | "aif" | "aifc" => containers::riff(&mut reader, true),
        _ => Err("unsupported audio tag format".into()),
    };
    check()?;
    result
}

fn exact(reader: &mut impl Read, bytes: &mut [u8]) -> Result<(), String> {
    let mut offset = 0;
    while offset < bytes.len() {
        match reader
            .read(&mut bytes[offset..])
            .map_err(|error| error.to_string())?
        {
            0 => return Err(if offset == 0 { "EOF" } else { "unexpected EOF" }.into()),
            count => offset += count,
        }
    }
    Ok(())
}

fn bytes(reader: &mut impl Read, length: usize) -> Result<Vec<u8>, String> {
    let mut bytes = vec![0; length];
    exact(reader, &mut bytes)?;
    Ok(bytes)
}

fn seek(reader: &mut impl Seek, position: SeekFrom) -> Result<u64, String> {
    reader.seek(position).map_err(|error| error.to_string())
}

fn number(value: &str) -> i64 {
    match value.trim().parse::<isize>() {
        Ok(value) => value as i64,
        Err(error) => match error.kind() {
            std::num::IntErrorKind::PosOverflow => isize::MAX as i64,
            std::num::IntErrorKind::NegOverflow => isize::MIN as i64,
            _ => 0,
        },
    }
}

fn pair(value: &str) -> (i64, i64) {
    let value = value.trim();
    match value.find('/').filter(|index| *index > 0) {
        Some(index) => (number(&value[..index]), number(&value[index + 1..])),
        None => (number(value), 0),
    }
}

fn truthy(value: &str) -> bool {
    matches!(
        value.trim().to_ascii_lowercase().as_str(),
        "1" | "true" | "yes" | "explicit"
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::BTreeMap;
    use std::io::Cursor;

    #[test]
    fn sniff_container_reads_the_bytes_instead_of_the_name() {
        let tag = b"ID3\x04\0\0\0\0\0\x02\0\0";
        for (bytes, expected) in [
            (b"fLaC\x80\0\0\x22".to_vec(), "flac"),
            ([tag.as_slice(), b"fLaC"].concat(), "flac"),
            (b"\0\0\0\x18ftypM4A ".to_vec(), "m4a"),
            (b"\xff\xfb\x90\x00".to_vec(), "mp3"),
            ([tag.as_slice(), b"\xff\xf3\x90\x00"].concat(), "mp3"),
            // ADTS AAC and text bodies are neither FLAC nor MP3.
            (b"\xff\xf1\x50\x80".to_vec(), ""),
            (b"<!DOCTYPE html>".to_vec(), ""),
            (b"fL".to_vec(), ""),
            (Vec::new(), ""),
        ] {
            let mut reader = Cursor::new(&bytes);
            assert_eq!(sniff_container(&mut reader).unwrap(), expected, "{bytes:?}");
            assert_eq!(reader.position(), 0);
        }
    }

    #[test]
    fn library_scan_preserves_replaygain_values_written_to_flac() {
        let mut source = b"fLaC\x80\0\0\x22".to_vec();
        source.resize(42, 0);
        source.extend_from_slice(&[0xff, 0xf8, 0, 0]);
        let fields = BTreeMap::from([
            ("replaygain_track_gain".into(), "-6.20 dB".into()),
            ("replaygain_track_peak".into(), "0.000000".into()),
            ("replaygain_album_gain".into(), "0.00 dB".into()),
            ("replaygain_album_peak".into(), "1.234567".into()),
        ]);
        let mut output = Vec::new();
        rewrite_audio_tags(
            &mut Cursor::new(&source),
            &mut output,
            "flac",
            &fields,
            None,
            &|| Ok(()),
        )
        .unwrap();
        let mut reader = Cursor::new(&output);
        let scan = read_library_metadata(&mut reader, "track.flac", "", "", 0, &|| Ok(())).unwrap();
        let full = read_file_metadata(&mut reader, "track.flac", "", &|| Ok(())).unwrap();
        let empty = read_library_metadata(
            &mut Cursor::new(source),
            "track.flac",
            "",
            "",
            0,
            &|| Ok(()),
        )
        .unwrap();
        for (key, value) in fields {
            assert_eq!(scan[&key], value);
            assert_eq!(scan[&key], full[&key]);
            assert!(empty.get(&key).is_none());
        }
    }

    fn atom(kind: &[u8; 4], body: &[u8]) -> Vec<u8> {
        [
            ((body.len() + 8) as u32).to_be_bytes().as_slice(),
            kind,
            body,
        ]
        .concat()
    }

    #[test]
    fn opus_in_mp4_reads_tags_cover_and_library_quality() {
        let mut ilst = Vec::new();
        let cover = b"\xff\xd8\xff\xd9";
        for (kind, value) in [
            (b"\xa9nam", b"Track Title".as_slice()),
            (b"\xa9ART", b"Artist Name".as_slice()),
            (b"covr", cover.as_slice()),
        ] {
            ilst.extend(atom(kind, &atom(b"data", &[&[0; 8], value].concat())));
        }
        let metadata = atom(
            b"udta",
            &atom(
                b"meta",
                &[&[0; 4], atom(b"ilst", &ilst).as_slice()].concat(),
            ),
        );
        let mut entry = [0; 28];
        entry[24..26].copy_from_slice(&48_000_u16.to_be_bytes());
        let moov = [metadata, atom(b"Opus", &entry)].concat();
        let data = [atom(b"ftyp", b"isom\0\0\0\0"), atom(b"moov", &moov)].concat();
        for suffix in ["opus", "m4a"] {
            let mut reader = Cursor::new(&data);
            reader.set_position(data.len() as u64);
            let path = format!("Track Title - Artist Name.{suffix}");
            let scan = read_library_metadata(&mut reader, &path, "", "", 0, &|| Ok(())).unwrap();
            assert_eq!(scan["trackName"], "Track Title");
            assert_eq!(scan["artistName"], "Artist Name");
            assert_eq!(scan["format"], "opus");
            assert_eq!(scan["sampleRate"], 48_000);
            assert!(scan.get("metadataFromFilename").is_none());
            assert_eq!(
                read_audio_tags(&mut reader, suffix, &|| Ok(()))
                    .unwrap()
                    .title,
                "Track Title"
            );
            let metadata = read_file_metadata(&mut reader, &path, "", &|| Ok(())).unwrap();
            assert_eq!(metadata["title"], "Track Title");
            assert_eq!(metadata["audio_codec"], "opus");
            assert_eq!(
                extract_cover(&mut reader, suffix, &|| Ok(())).unwrap().data,
                cover
            );
            assert_eq!(reader.into_inner(), &data);
        }
        let mut reader = Cursor::new(&data);
        assert!(read_file_metadata(&mut reader, "misnamed.flac", "", &|| Ok(())).is_err());
        assert_eq!(
            read_audio_tags(&mut reader, "opus", &|| Err("cancelled".into())).unwrap_err(),
            "cancelled"
        );
        assert_eq!(
            extract_cover(&mut reader, "opus", &|| Err("cancelled".into())).unwrap_err(),
            "cancelled"
        );
    }
}
