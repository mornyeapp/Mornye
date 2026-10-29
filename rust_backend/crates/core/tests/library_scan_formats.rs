//! Real-world file shapes that Library scans used to drop as unreadable.

use mornye_core::tags::{
    extract_cover, read_file_metadata, read_library_metadata, rewrite_audio_tags,
};
use serde_json::Value;
use std::io::{self, Cursor, Read, Seek, SeekFrom};

fn id3v23(frames: &[(&[u8; 4], &str)]) -> Vec<u8> {
    let mut body = Vec::new();
    for (id, text) in frames {
        body.extend(*id);
        body.extend(((text.len() + 1) as u32).to_be_bytes());
        // Frame flags, then ISO-8859-1 text.
        body.extend([0, 0, 0]);
        body.extend(text.as_bytes());
    }
    let size = body.len() as u32;
    let mut tag = b"ID3\x03\0\0".to_vec();
    tag.extend([21, 14, 7, 0].map(|shift| (size >> shift) as u8 & 0x7f));
    tag.extend(body);
    tag
}

/// AAC-LC, 44.1 kHz stereo, about 128 kbit/s: 431 frames are 10 seconds.
fn adts(frames: usize) -> Vec<u8> {
    let length = 371_usize;
    let mut frame = vec![0; length];
    frame[..7].copy_from_slice(&[
        0xff,
        0xf1,
        0x50,
        0x80 | (length >> 11) as u8,
        (length >> 3) as u8,
        ((length & 7) << 5) as u8 | 0x1f,
        0xfc,
    ]);
    frame.repeat(frames)
}

fn vorbis_comments(comments: &[String]) -> Vec<u8> {
    let mut data = 6_u32.to_le_bytes().to_vec();
    data.extend(b"vendor");
    data.extend((comments.len() as u32).to_le_bytes());
    for comment in comments {
        data.extend((comment.len() as u32).to_le_bytes());
        data.extend(comment.as_bytes());
    }
    data
}

fn flac(comments: &[String]) -> Vec<u8> {
    let mut data = b"fLaC\0\0\0\x22".to_vec();
    let mut info = [0; 34];
    let packed = (44_100_u64 << 44) | (1_u64 << 41) | (15_u64 << 36) | 441_000;
    info[10..18].copy_from_slice(&packed.to_be_bytes());
    data.extend(info);
    let block = vorbis_comments(comments);
    data.push(0x84);
    data.extend(&(block.len() as u32).to_be_bytes()[1..]);
    data.extend(block);
    data.extend([0xff, 0xf8]);
    data
}

fn ogg_page(flags: u8, granule: u64, sequence: u32, lacing: &[u8], data: &[u8]) -> Vec<u8> {
    let mut page = b"OggS\0".to_vec();
    page.push(flags);
    page.extend(granule.to_le_bytes());
    page.extend(1_u32.to_le_bytes());
    page.extend(sequence.to_le_bytes());
    // The readers do not check the CRC.
    page.extend([0; 4]);
    page.push(lacing.len() as u8);
    page.extend(lacing);
    page.extend(data);
    page
}

/// A 10-second Opus stream whose comment header is laced across pages of
/// `segments_per_page` segments, as taggers such as mutagen write it.
fn opus(comments: Option<&[String]>, segments_per_page: usize) -> Vec<u8> {
    let mut head = b"OpusHead\x01\x02".to_vec();
    head.extend(312_u16.to_le_bytes());
    head.extend(48_000_u32.to_le_bytes());
    head.extend([0, 0, 0]);
    let mut stream = ogg_page(0x02, 0, 0, &[head.len() as u8], &head);
    let mut sequence = 1;
    if let Some(comments) = comments {
        let packet = [b"OpusTags".as_slice(), &vorbis_comments(comments)].concat();
        let mut lacing = vec![255; packet.len() / 255];
        lacing.push((packet.len() % 255) as u8);
        let mut offset = 0;
        for (index, chunk) in lacing.chunks(segments_per_page).enumerate() {
            let length: usize = chunk.iter().map(|value| *value as usize).sum();
            let flags = if index == 0 { 0 } else { 0x01 };
            stream.extend(ogg_page(
                flags,
                0,
                sequence,
                chunk,
                &packet[offset..offset + length],
            ));
            offset += length;
            sequence += 1;
        }
    }
    stream.extend(ogg_page(0x04, 480_312, sequence, &[3], &[0xfc, 0, 0]));
    stream
}

fn picture_comment(size: usize) -> String {
    use base64::Engine;
    let mut block = 3_u32.to_be_bytes().to_vec();
    block.extend(10_u32.to_be_bytes());
    block.extend(b"image/jpeg");
    block.extend(0_u32.to_be_bytes());
    block.extend([0; 16]);
    block.extend((size as u32).to_be_bytes());
    let mut image = vec![0x42; size];
    image[..2].copy_from_slice(&[0xff, 0xd8]);
    block.extend(image);
    format!(
        "METADATA_BLOCK_PICTURE={}",
        base64::engine::general_purpose::STANDARD.encode(block)
    )
}

fn scan(data: &[u8], hint: &str) -> Value {
    read_library_metadata(
        &mut Cursor::new(data.to_vec()),
        "/proc/self/fd/42",
        hint,
        "scan",
        0,
        &|| Ok(()),
    )
    .unwrap()
}

fn assert_readable(metadata: &Value) {
    assert!(metadata.get("metadataFromFilename").is_none(), "{metadata}");
    assert!(metadata.get("metadataReadError").is_none(), "{metadata}");
}

#[test]
fn untagged_adts_aac_is_read_from_its_frames() {
    let metadata = scan(&adts(431), "Artist - Title.aac");
    assert_readable(&metadata);
    assert_eq!(metadata["trackName"], "Artist - Title");
    assert_eq!(metadata["artistName"], "Unknown Artist");
    assert_eq!(metadata["format"], "aac");
    assert_eq!(metadata["sampleRate"], 44_100);
    assert_eq!(metadata["duration"], 10);
    assert_eq!(metadata["bitrate"], 127);
}

#[test]
fn adts_aac_behind_an_id3_tag_keeps_its_tags() {
    let data = [
        id3v23(&[(b"TIT2", "Song"), (b"TPE1", "Singer"), (b"TALB", "Record")]),
        adts(431),
    ]
    .concat();
    let metadata = scan(&data, "track.aac");
    assert_readable(&metadata);
    assert_eq!(metadata["trackName"], "Song");
    assert_eq!(metadata["artistName"], "Singer");
    assert_eq!(metadata["albumName"], "Record");
    assert_eq!(metadata["sampleRate"], 44_100);
    assert_eq!(metadata["duration"], 10);

    let details = read_file_metadata(&mut Cursor::new(data), "track.aac", "", &|| Ok(())).unwrap();
    assert_eq!(details["title"], "Song");
    assert_eq!(details["format"], "aac");
    assert_eq!(details["audio_codec"], "aac");
    assert_eq!(details["sample_rate"], 44_100);
    assert_eq!(details["bitrate"], 127);
}

#[test]
fn flac_behind_an_id3_tag_keeps_its_vorbis_comments() {
    let data = [
        id3v23(&[(b"TIT2", "Ignored")]),
        flac(&["TITLE=Song".into(), "ARTIST=Singer".into()]),
    ]
    .concat();
    let metadata = scan(&data, "track.flac");
    assert_readable(&metadata);
    assert_eq!(metadata["trackName"], "Song");
    assert_eq!(metadata["artistName"], "Singer");
    assert_eq!(metadata["sampleRate"], 44_100);
    assert_eq!(metadata["bitDepth"], 16);
    assert_eq!(metadata["duration"], 10);
}

#[test]
fn opus_comments_after_a_large_cover_on_small_pages_are_read() {
    let comments = [
        picture_comment(400 * 1024),
        "TITLE=Song".into(),
        "ARTIST=Singer".into(),
    ];
    // About 135 pages of 4 KiB, well past the old 80-page window.
    let data = opus(Some(&comments), 16);
    let metadata = scan(&data, "track.opus");
    assert_readable(&metadata);
    assert_eq!(metadata["trackName"], "Song");
    assert_eq!(metadata["artistName"], "Singer");
    assert_eq!(metadata["sampleRate"], 48_000);
    assert_eq!(metadata["duration"], 10);
    let cover = extract_cover(&mut Cursor::new(data), "opus", &|| Ok(())).unwrap();
    assert_eq!(cover.data.len(), 400 * 1024);
}

#[test]
fn opus_with_high_resolution_artwork_remains_readable() {
    // Base64 expands an 8 MiB picture past the old 10 MiB packet limit;
    // a 13 MiB picture also exceeds the old 16 MiB header read window.
    for size in [8 * 1024 * 1024, 13 * 1024 * 1024] {
        let data = opus(
            Some(&[
                picture_comment(size),
                "TITLE=Converted song".into(),
                "ARTIST=Example artist".into(),
            ]),
            255,
        );
        let metadata = scan(&data, "Converted.opus");
        assert_readable(&metadata);
        assert_eq!(metadata["trackName"], "Converted song");
        assert_eq!(metadata["artistName"], "Example artist");
        assert_eq!(metadata["duration"], 10);
        let cover = extract_cover(&mut Cursor::new(&data), "opus", &|| Ok(())).unwrap();
        assert_eq!(cover.data.len(), size);

        // Automatic download conversion uses the native tag writer. Its
        // completed output must be readable by the scanner too.
        let mut rewritten = Vec::new();
        rewrite_audio_tags(
            &mut Cursor::new(&data),
            &mut rewritten,
            "opus",
            &[("title".into(), "Retagged song".into())].into(),
            Some(&cover.data),
            &|| Ok(()),
        )
        .unwrap();
        let metadata = scan(&rewritten, "Retagged.opus");
        assert_readable(&metadata);
        assert_eq!(metadata["trackName"], "Retagged song");
        assert_eq!(metadata["artistName"], "Example artist");
        assert_eq!(metadata["duration"], 10);
        let details = read_file_metadata(
            &mut Cursor::new(&rewritten),
            "/proc/self/fd/42",
            "Retagged.opus",
            &|| Ok(()),
        )
        .unwrap();
        assert_eq!(details["title"], "Retagged song");
        assert_eq!(details["audio_codec"], "opus");
    }
}

#[test]
fn manual_opus_cover_replacement_remains_readable() {
    let source = opus(
        Some(&["TITLE=Original song".into(), "ARTIST=Example artist".into()]),
        255,
    );
    assert_readable(&scan(&source, "Manual.opus"));
    let mut cover = vec![0x42; 8 * 1024 * 1024];
    cover[..2].copy_from_slice(&[0xff, 0xd8]);
    let mut edited = Vec::new();
    rewrite_audio_tags(
        &mut Cursor::new(&source),
        &mut edited,
        "ogg",
        &[("title".into(), "Manually edited song".into())].into(),
        Some(&cover),
        &|| Ok(()),
    )
    .unwrap();
    let metadata = scan(&edited, "Manual.opus");
    assert_readable(&metadata);
    assert_eq!(metadata["trackName"], "Manually edited song");
    assert_eq!(metadata["artistName"], "Example artist");
    let metadata = read_file_metadata(
        &mut Cursor::new(&edited),
        "/proc/self/fd/42",
        "Manual.opus",
        &|| Ok(()),
    )
    .unwrap();
    assert_eq!(metadata["title"], "Manually edited song");
    let artwork = extract_cover(&mut Cursor::new(&edited), "opus", &|| Ok(())).unwrap();
    assert_eq!(artwork.data, cover);
}

#[test]
fn opus_without_title_or_artist_keeps_its_other_tags() {
    let metadata = scan(&opus(Some(&["ALBUM=Record".into()]), 255), "Song.opus");
    assert_readable(&metadata);
    assert_eq!(metadata["trackName"], "Song");
    assert_eq!(metadata["artistName"], "Unknown Artist");
    assert_eq!(metadata["albumName"], "Record");

    let untagged = scan(&opus(Some(&[]), 255), "Untagged.opus");
    assert_readable(&untagged);
    assert_eq!(untagged["trackName"], "Untagged");
    assert_eq!(untagged["duration"], 10);
}

#[test]
fn unreadable_streams_are_still_rejected() {
    // An Opus stream cut off before its mandatory comment header.
    let truncated = scan(&opus(None, 255), "Song.opus");
    assert_eq!(truncated["metadataFromFilename"], true);
    for hint in ["Song.aac", "Song.flac"] {
        let data = [id3v23(&[(b"TIT2", "Song")]), vec![0; 512]].concat();
        let metadata = scan(&data, hint);
        assert_eq!(metadata["metadataFromFilename"], true, "{hint}");
    }
}

/// Interrupts every other call and returns at most three bytes, like a slow
/// provider descriptor under load.
struct Choppy {
    data: Cursor<Vec<u8>>,
    interrupt: bool,
}

impl Read for Choppy {
    fn read(&mut self, buffer: &mut [u8]) -> io::Result<usize> {
        self.interrupt = !self.interrupt;
        if self.interrupt {
            return Err(io::ErrorKind::Interrupted.into());
        }
        let length = buffer.len().min(3);
        self.data.read(&mut buffer[..length])
    }
}

impl Seek for Choppy {
    fn seek(&mut self, position: SeekFrom) -> io::Result<u64> {
        self.data.seek(position)
    }
}

#[test]
fn interrupted_and_short_reads_give_the_same_result() {
    let cover = picture_comment(64 * 1024);
    for (data, hint) in [
        (adts(431), "track.aac"),
        (
            [id3v23(&[(b"TIT2", "Song")]), adts(431)].concat(),
            "track.aac",
        ),
        (
            [
                id3v23(&[(b"TIT2", "Ignored")]),
                flac(&["TITLE=Song".into()]),
            ]
            .concat(),
            "track.flac",
        ),
        (
            opus(Some(&[cover.clone(), "TITLE=Song".into()]), 16),
            "track.opus",
        ),
    ] {
        let expected = scan(&data, hint);
        let actual = read_library_metadata(
            &mut Choppy {
                data: Cursor::new(data),
                interrupt: false,
            },
            "/proc/self/fd/42",
            hint,
            "scan",
            0,
            &|| Ok(()),
        )
        .unwrap();
        assert_eq!(actual, expected, "{hint}");
    }
}
