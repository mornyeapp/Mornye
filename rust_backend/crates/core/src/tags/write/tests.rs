use super::*;
use std::cell::Cell;
use std::io;
use std::rc::Rc;

struct CountingReader {
    data: Cursor<Vec<u8>>,
    bytes_read: Rc<Cell<usize>>,
}

impl Read for CountingReader {
    fn read(&mut self, buffer: &mut [u8]) -> io::Result<usize> {
        let count = self.data.read(buffer)?;
        self.bytes_read.set(self.bytes_read.get() + count);
        Ok(count)
    }
}

impl Seek for CountingReader {
    fn seek(&mut self, offset: SeekFrom) -> io::Result<u64> {
        self.data.seek(offset)
    }
}

/// Shared with the Dart and Kotlin primary-artist tests; keep in sync.
#[test]
fn split_artist_credits_recognize_variants_without_splitting_band_words() {
    assert_eq!(
        split_artists("One Featured Two; Three"),
        vec!["One", "Two", "Three"]
    );
    assert_eq!(split_artists("One feature Two"), vec!["One", "Two"]);
    assert_eq!(
        split_artists("Florence and the Machine"),
        vec!["Florence and the Machine"]
    );
    assert_eq!(
        split_artists("Artist Without Fear"),
        vec!["Artist Without Fear"]
    );
}

#[test]
fn primary_artist_uses_the_shared_separator_set() {
    for (input, expected) in [
        ("Calle 24, Chino Pacas", "Calle 24"),
        ("Calle 24 & Chino Pacas", "Calle 24"),
        ("Artist A; Artist B", "Artist A"),
        ("Artist A feat. Artist B", "Artist A"),
        ("Artist A Feat Artist B", "Artist A"),
        ("Artist A ft. Artist B", "Artist A"),
        ("Artist A featuring Artist B", "Artist A"),
        ("Artist A featured Artist B", "Artist A"),
        ("Artist A feature Artist B", "Artist A"),
        ("Artist A with Artist B", "Artist A"),
        ("Artist A x Artist B", "Artist A"),
        ("Artist A X Artist B", "Artist A"),
        (" , Artist A, Artist B", "Artist A"),
        ("Malcolm X", "Malcolm X"),
        ("Artist Without Fear", "Artist Without Fear"),
        ("Maxx", "Maxx"),
        ("AC/DC", "AC/DC"),
        ("  Various Artists  ", "Various Artists"),
        ("", ""),
    ] {
        assert_eq!(primary_artist(input), expected, "{input:?}");
    }
}

fn editable_flac() -> (Vec<u8>, usize, Fields) {
    let mut comments = Vec::new();
    put_string(&mut comments, b"Mornye");
    comments.extend(2_u32.to_le_bytes());
    put_string(&mut comments, b"CUSTOM=preserve");
    put_string(&mut comments, b"TITLE=Example");
    let blocks = [
        (0, vec![0; 34]),
        (1, vec![0; 16]),
        (4, comments),
        (6, picture(b"original cover", &|| Ok(())).unwrap().unwrap()),
    ];
    let mut input = b"fLaC".to_vec();
    for (index, (kind, data)) in blocks.iter().enumerate() {
        input.push(kind | if index + 1 == blocks.len() { 0x80 } else { 0 });
        input.extend(&(data.len() as u32).to_be_bytes()[1..]);
        input.extend(data);
    }
    let audio_start = input.len();
    input.extend([0xff, 0xf8]);
    input.resize(audio_start + 1024 * 1024, 0x55);
    let fields = Fields::from([("title".into(), "Example".into())]);
    (input, audio_start, fields)
}

#[test]
fn unchanged_flac_tags_do_not_copy_audio_or_write_output() {
    for cover in [None, Some(b"original cover".as_slice())] {
        let (input, audio_start, fields) = editable_flac();
        let bytes_read = Rc::new(Cell::new(0));
        let mut source = CountingReader {
            data: Cursor::new(input),
            bytes_read: bytes_read.clone(),
        };
        let mut output = Vec::new();
        assert!(
            !rewrite_flac_tags_if_changed(&mut source, &mut output, &fields, cover, &|| Ok(()),)
                .unwrap()
        );
        assert!(output.is_empty());
        // One header parse, two frame-sync bytes, one exact comparison.
        assert_eq!(bytes_read.get(), audio_start * 2 + 2);
    }
}

#[test]
fn changed_flac_tags_match_full_rewrite_and_preserve_audio() {
    let (input, audio_start, _) = editable_flac();
    for (title, cover) in [
        ("Changed", None), // Equal-length header with different bytes.
        ("A longer title", None),
        ("Example", Some(b"different artwork".as_slice())),
    ] {
        let fields = Fields::from([("title".into(), title.into())]);
        let mut expected = Vec::new();
        rewrite_audio_tags(
            &mut Cursor::new(&input),
            &mut expected,
            "flac",
            &fields,
            cover,
            &|| Ok(()),
        )
        .unwrap();
        let mut output = Vec::new();
        assert!(
            rewrite_flac_tags_if_changed(
                &mut Cursor::new(&input),
                &mut output,
                &fields,
                cover,
                &|| Ok(()),
            )
            .unwrap()
        );
        assert_eq!(output, expected);
        assert!(output.ends_with(&input[audio_start..]));
    }
}

fn flac_with_comments(items: &[&str]) -> Vec<u8> {
    let mut comments = Vec::new();
    put_string(&mut comments, b"Mornye");
    comments.extend((items.len() as u32).to_le_bytes());
    for item in items {
        put_string(&mut comments, item.as_bytes());
    }
    let mut input = b"fLaC".to_vec();
    for (index, (kind, data)) in [(0, vec![0; 34]), (4, comments)].iter().enumerate() {
        input.push(kind | if index == 1 { 0x80 } else { 0 });
        input.extend(&(data.len() as u32).to_be_bytes()[1..]);
        input.extend(data);
    }
    input.extend([0xff, 0xf8, 0, 0]);
    input
}

/// The Vorbis comments of a FLAC file, sorted.
fn flac_comment_list(data: &[u8]) -> Vec<String> {
    let mut offset = 4;
    loop {
        let header = &data[offset..offset + 4];
        let length = u32::from_be_bytes([0, header[1], header[2], header[3]]) as usize;
        let body = &data[offset + 4..offset + 4 + length];
        if header[0] & 0x7f == 4 {
            let mut comments: Vec<_> = parse_comments(body)
                .unwrap()
                .1
                .iter()
                .map(|comment| String::from_utf8_lossy(comment).into_owned())
                .collect();
            comments.sort();
            return comments;
        }
        assert_eq!(header[0] & 0x80, 0, "no comment block");
        offset += 4 + length;
    }
}

fn read_flac(data: &[u8]) -> crate::tags::AudioMetadata {
    crate::tags::read_audio_tags(&mut Cursor::new(data), "flac", &|| Ok(())).unwrap()
}

#[test]
fn flac_downloads_write_totals_in_their_own_comments() {
    let input = flac_with_comments(&["TITLE=Example", "TRACKTOTAL=99"]);
    let fields = Fields::from([
        ("TRACKNUMBER".into(), "6/12".into()),
        ("DISCNUMBER".into(), "1/2".into()),
    ]);
    let mut output = Vec::new();
    embed_flac_metadata(
        &mut Cursor::new(&input),
        &mut output,
        &fields,
        "",
        None,
        &|| Ok(()),
    )
    .unwrap();
    assert_eq!(
        flac_comment_list(&output),
        [
            "DISCNUMBER=1",
            "DISCTOTAL=2",
            "TITLE=Example",
            "TOTALDISCS=2",
            "TOTALTRACKS=12",
            "TRACKNUMBER=6",
            "TRACKTOTAL=12",
        ]
    );
    let metadata = read_flac(&output);
    assert_eq!((metadata.track_number, metadata.total_tracks), (6, 12));
    assert_eq!((metadata.disc_number, metadata.total_discs), (1, 2));

    // Without a total from the fields, the file's own total stays.
    let fields = Fields::from([("TRACKNUMBER".into(), "3".into())]);
    let mut output = Vec::new();
    embed_flac_metadata(
        &mut Cursor::new(&input),
        &mut output,
        &fields,
        "",
        None,
        &|| Ok(()),
    )
    .unwrap();
    assert_eq!(
        flac_comment_list(&output),
        ["TITLE=Example", "TRACKNUMBER=3", "TRACKTOTAL=99"]
    );
}

#[test]
fn flac_tag_edits_split_combined_numbers_and_keep_totals() {
    let edit = |input: &[u8], fields: &[(&str, &str)]| {
        let fields = fields
            .iter()
            .map(|(key, value)| (key.to_string(), value.to_string()))
            .collect::<Fields>();
        let mut output = Vec::new();
        rewrite_audio_tags(
            &mut Cursor::new(input),
            &mut output,
            "flac",
            &fields,
            None,
            &|| Ok(()),
        )
        .unwrap();
        output
    };

    // An older `6/12` file becomes separate fields on any number edit.
    let old = flac_with_comments(&["TRACKNUMBER=6/12", "DISCNUMBER=1/2"]);
    let output = edit(&old, &[("track_number", "7")]);
    assert_eq!(
        flac_comment_list(&output),
        [
            "DISCNUMBER=1/2",
            "TOTALTRACKS=12",
            "TRACKNUMBER=7",
            "TRACKTOTAL=12"
        ]
    );
    assert_eq!(read_flac(&output).total_discs, 2);

    // A total written by another tag editor is read and kept.
    let separate = flac_with_comments(&["TRACKNUMBER=2", "TOTALTRACKS=9"]);
    let metadata = read_flac(&separate);
    assert_eq!((metadata.track_number, metadata.total_tracks), (2, 9));
    let output = edit(&separate, &[("track_number", "4")]);
    assert_eq!(
        flac_comment_list(&output),
        ["TOTALTRACKS=9", "TRACKNUMBER=4", "TRACKTOTAL=9"]
    );

    let output = edit(&separate, &[("track_total", "")]);
    assert_eq!(flac_comment_list(&output), ["TRACKNUMBER=2"]);

    let output = edit(&separate, &[("disc_number", "3"), ("track_number", "")]);
    assert_eq!(flac_comment_list(&output), ["DISCNUMBER=3"]);
}

fn flac_id3_prefix(version: u8, footer: bool, padding: usize) -> Vec<u8> {
    let mut header = b"ID3".to_vec();
    header.extend([version, 0, if footer { 0x10 } else { 0 }]);
    header.extend([21, 14, 7, 0].map(|shift| (padding >> shift) as u8 & 0x7f));
    let mut prefix = header.clone();
    prefix.resize(10 + padding, 0);
    if footer {
        header[..3].copy_from_slice(b"3DI");
        prefix.extend(header);
    }
    prefix
}

#[test]
fn id3_prefixed_flac_writers_preserve_prefix_audio_and_unedited_metadata() {
    let (flac, audio_start, _) = editable_flac();
    for (version, footer) in [(2, false), (3, false), (4, false), (4, true)] {
        let prefix = flac_id3_prefix(version, footer, 131);
        let input = [&prefix[..], &flac].concat();
        for writer in ["edit", "rewrite", "embed"] {
            for cover in [None, Some(b"replacement cover".as_slice())] {
                let fields = Fields::from([
                    ("title".into(), "Changed title".into()),
                    ("lyrics".into(), "[00:00.00]Example lyrics".into()),
                    ("replaygain_track_gain".into(), "-3.00 dB".into()),
                ]);
                let write = |input: &[u8]| {
                    let mut source = Cursor::new(input);
                    let mut output = Vec::new();
                    match writer {
                        "edit" => {
                            assert!(
                                rewrite_flac_tags_if_changed(
                                    &mut source,
                                    &mut output,
                                    &fields,
                                    cover,
                                    &|| Ok(()),
                                )
                                .unwrap()
                            );
                        }
                        "rewrite" => rewrite_audio_tags(
                            &mut source,
                            &mut output,
                            "flac",
                            &fields,
                            cover,
                            &|| Ok(()),
                        )
                        .unwrap(),
                        _ => {
                            let canonical = fields
                                .iter()
                                .map(|(key, value)| (key.to_uppercase(), value.clone()))
                                .collect();
                            embed_flac_metadata(
                                &mut source,
                                &mut output,
                                &canonical,
                                "",
                                cover,
                                &|| Ok(()),
                            )
                            .unwrap();
                        }
                    }
                    output
                };
                let output = write(&input);
                assert_eq!(output, [&prefix[..], &write(&flac)].concat());
                assert!(output.ends_with(&flac[audio_start..]));
                assert!(output.windows(15).any(|bytes| bytes == b"CUSTOM=preserve"));
                let tags =
                    crate::tags::read_audio_tags(&mut Cursor::new(&output), "flac", &|| Ok(()))
                        .unwrap();
                assert_eq!(tags.title, "Changed title");
                assert_eq!(tags.lyrics, "[00:00.00]Example lyrics");
                assert_eq!(tags.replay_gain_track_gain, "-3.00 dB");
                let picture =
                    crate::tags::extract_cover(&mut Cursor::new(&output), "flac", &|| Ok(()))
                        .unwrap();
                assert_eq!(picture.data, cover.unwrap_or(b"original cover"));
            }
        }
    }
}

#[test]
fn unchanged_id3_prefixed_flac_skips_large_prefix_and_audio() {
    let (flac, audio_start, fields) = editable_flac();
    let prefix = flac_id3_prefix(4, true, 2 * 1024 * 1024);
    let bytes_read = Rc::new(Cell::new(0));
    let mut source = CountingReader {
        data: Cursor::new([prefix, flac].concat()),
        bytes_read: bytes_read.clone(),
    };
    let mut output = Vec::new();
    assert!(
        !rewrite_flac_tags_if_changed(&mut source, &mut output, &fields, None, &|| Ok(()),)
            .unwrap()
    );
    assert!(output.is_empty());
    // Only the ID3 header is read; its body and footer are skipped.
    assert_eq!(bytes_read.get(), 10 + audio_start * 2 + 2);
}

#[test]
fn invalid_id3_prefixed_flac_never_writes_output() {
    let (flac, audio_start, fields) = editable_flac();
    let prefix = flac_id3_prefix(4, true, 131);
    let valid = [&prefix[..], &flac].concat();
    let mut bad_size = valid.clone();
    bad_size[6] = 0x80;
    let mut wrong_container = valid.clone();
    wrong_container[prefix.len()..prefix.len() + 4].copy_from_slice(b"OggS");
    let mut bad_sync = valid.clone();
    bad_sync[prefix.len() + audio_start] = 0;
    for invalid in [
        bad_size,
        wrong_container,
        bad_sync,
        valid[..6].to_vec(),
        valid[..prefix.len() - 1].to_vec(),
        valid[..prefix.len() + 3].to_vec(),
        valid[..prefix.len() + audio_start + 1].to_vec(),
    ] {
        let mut output = Vec::new();
        assert!(
            rewrite_flac_tags_if_changed(
                &mut Cursor::new(invalid),
                &mut output,
                &fields,
                None,
                &|| Ok(()),
            )
            .is_err()
        );
        assert!(output.is_empty());
    }
}

#[test]
fn id3_prefixed_flac_observes_cancellation_after_reading_prefix_header() {
    let (flac, _, fields) = editable_flac();
    let prefix = flac_id3_prefix(3, false, 131);
    let bytes_read = Rc::new(Cell::new(0));
    let mut source = CountingReader {
        data: Cursor::new([prefix, flac].concat()),
        bytes_read: bytes_read.clone(),
    };
    let mut output = Vec::new();
    assert_eq!(
        rewrite_flac_tags_if_changed(&mut source, &mut output, &fields, None, &|| {
            if bytes_read.get() >= 10 {
                Err("cancelled".into())
            } else {
                Ok(())
            }
        },)
        .unwrap_err(),
        "cancelled"
    );
    assert_eq!(bytes_read.get(), 10);
    assert!(output.is_empty());
}

#[test]
fn unchanged_flac_still_validates_frames_and_observes_cancellation() {
    let (input, audio_start, fields) = editable_flac();
    let bytes_read = Rc::new(Cell::new(0));
    let mut source = CountingReader {
        data: Cursor::new(input.clone()),
        bytes_read: bytes_read.clone(),
    };
    let mut output = Vec::new();
    let error = rewrite_flac_tags_if_changed(&mut source, &mut output, &fields, None, &|| {
        if bytes_read.get() >= audio_start + 2 {
            Err("cancelled".into())
        } else {
            Ok(())
        }
    })
    .unwrap_err();
    assert_eq!(error, "cancelled");
    assert!(output.is_empty());

    let mut invalid = input;
    invalid[audio_start] = 0;
    assert!(
        rewrite_flac_tags_if_changed(
            &mut Cursor::new(invalid),
            &mut output,
            &fields,
            None,
            &|| Ok(()),
        )
        .unwrap_err()
        .contains("sync code")
    );
    assert!(output.is_empty());
}

fn flac_with_pictures(lengths: &[usize]) -> (Vec<u8>, usize) {
    let mut comments = Vec::new();
    put_string(&mut comments, b"Example vendor");
    comments.extend(1_u32.to_le_bytes());
    put_string(&mut comments, b"CUSTOM=preserve");
    let mut blocks = vec![
        (0, vec![0; 34]),
        (2, b"unknown block".to_vec()),
        (4, comments),
    ];
    blocks.extend(lengths.iter().map(|length| (6, vec![0x55; *length])));
    let mut input = b"fLaC".to_vec();
    for (index, (kind, data)) in blocks.iter().enumerate() {
        input.push(kind | if index + 1 == blocks.len() { 0x80 } else { 0 });
        input.extend(&(data.len() as u32).to_be_bytes()[1..]);
        input.extend(data);
    }
    let audio_start = input.len();
    input.extend([0xff, 0xf8, 0x12, 0x34, 0x56]);
    (input, audio_start)
}

#[test]
fn replacement_flac_artwork_preserves_other_blocks_and_audio() {
    let (input, audio_start) = flac_with_pictures(&[131_073, 262_145]);
    let (without_pictures, _) = flac_with_pictures(&[]);
    let cover = Some(b"replacement artwork".as_slice());
    for embed in [false, true] {
        let fields = Fields::from([(
            if embed { "TITLE" } else { "title" }.into(),
            "Changed title".into(),
        )]);
        let rewrite = |data: &[u8], cover| {
            let mut output = Vec::new();
            if embed {
                embed_flac_metadata(
                    &mut Cursor::new(data),
                    &mut output,
                    &fields,
                    "",
                    cover,
                    &|| Ok(()),
                )
                .unwrap();
            } else {
                rewrite_audio_tags(
                    &mut Cursor::new(data),
                    &mut output,
                    "flac",
                    &fields,
                    cover,
                    &|| Ok(()),
                )
                .unwrap();
            }
            output
        };
        let output = rewrite(&input, cover);
        assert_eq!(output, rewrite(&without_pictures, cover));
        assert!(output.ends_with(&input[audio_start..]));
        let retained = rewrite(&input, None);
        assert!(
            retained
                .windows(131_073)
                .any(|bytes| bytes == [0x55; 131_073])
        );
        assert!(retained.ends_with(&input[audio_start..]));
    }
}

#[test]
fn discarded_flac_picture_preserves_eof_and_cancellation() {
    let (input, audio_start) = flac_with_pictures(&[131_073]);
    let picture_start = audio_start - 131_073;
    let fields = Fields::new();
    for available in [0, 1, 65536, 65537, 131_072] {
        let truncated = &input[..picture_start + available];
        let mut expected = Vec::new();
        let error = rewrite_audio_tags(
            &mut Cursor::new(truncated),
            &mut expected,
            "flac",
            &fields,
            None,
            &|| Ok(()),
        )
        .unwrap_err();
        let mut output = Vec::new();
        assert_eq!(
            rewrite_audio_tags(
                &mut Cursor::new(truncated),
                &mut output,
                "flac",
                &fields,
                Some(b"replacement artwork"),
                &|| Ok(()),
            )
            .unwrap_err(),
            error
        );
        assert!(output.is_empty());
    }
    let bytes_read = Rc::new(Cell::new(0));
    let mut source = CountingReader {
        data: Cursor::new(input),
        bytes_read: bytes_read.clone(),
    };
    let mut output = Vec::new();
    assert_eq!(
        rewrite_flac_tags_if_changed(
            &mut source,
            &mut output,
            &fields,
            Some(b"replacement artwork"),
            &|| {
                if bytes_read.get() >= picture_start + 65536 {
                    Err("cancelled".into())
                } else {
                    Ok(())
                }
            },
        )
        .unwrap_err(),
        "cancelled"
    );
    assert!(bytes_read.get() < audio_start);
    assert!(output.is_empty());
}

#[test]
fn discarded_flac_pictures_still_count_toward_metadata_limit() {
    let (input, _) = flac_with_pictures(&vec![0; 65534]);
    let mut output = Vec::new();
    assert_eq!(
        rewrite_audio_tags(
            &mut Cursor::new(input),
            &mut output,
            "flac",
            &Fields::new(),
            Some(b"replacement artwork"),
            &|| Ok(()),
        )
        .unwrap_err(),
        "FLAC metadata block count exceeds 65536"
    );
    assert!(output.is_empty());
}

#[test]
fn oversized_flac_cover_reencodes_or_omits_invalid_image() {
    let image = image::DynamicImage::ImageRgba8(image::RgbaImage::from_pixel(
        3,
        2,
        image::Rgba([30, 60, 90, 255]),
    ));
    let mut encoded = Cursor::new(Vec::new());
    image
        .write_to(&mut encoded, image::ImageFormat::Png)
        .unwrap();
    let mut cover = encoded.into_inner();
    // Valid PNG with trailing data forces the same size fallback as a
    // large artwork file without an expensive image-generation fixture.
    cover.resize(16_000_001, 0);
    let block = picture(&cover, &|| Ok(())).unwrap().unwrap();
    let mut reader = Cursor::new(block);
    let mut number = || {
        let mut value = [0; 4];
        reader.read_exact(&mut value).unwrap();
        u32::from_be_bytes(value)
    };
    assert_eq!(number(), 3);
    assert_eq!(number(), 10);
    assert_eq!(bytes(&mut reader, 10).unwrap(), b"image/jpeg");
    assert_eq!(bytes(&mut reader, 4).unwrap(), 11_u32.to_be_bytes());
    assert_eq!(bytes(&mut reader, 11).unwrap(), b"Front Cover");
    assert_eq!(bytes(&mut reader, 4).unwrap(), 3_u32.to_be_bytes());
    assert_eq!(bytes(&mut reader, 4).unwrap(), 2_u32.to_be_bytes());
    assert_eq!(bytes(&mut reader, 4).unwrap(), 24_u32.to_be_bytes());
    assert_eq!(bytes(&mut reader, 4).unwrap(), [0; 4]);
    let length = u32::from_be_bytes(bytes(&mut reader, 4).unwrap().try_into().unwrap());
    assert!(length < 16_000_000);
    let jpeg = bytes(&mut reader, length as usize).unwrap();
    assert_eq!(
        image::ImageReader::new(Cursor::new(jpeg))
            .with_guessed_format()
            .unwrap()
            .into_dimensions()
            .unwrap(),
        (3, 2)
    );
    cover.fill(0);
    assert!(picture(&cover, &|| Ok(())).unwrap().is_none());
    assert_eq!(
        picture(b"small cover", &|| Err("cancelled".into())).unwrap_err(),
        "cancelled"
    );
}
