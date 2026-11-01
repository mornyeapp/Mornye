use mornye_core::tags::{extract_cover, read_audio_tags, rewrite_audio_tags};
use std::collections::BTreeMap;
use std::io::Cursor;

fn chunk(kind: &[u8; 4], body: &[u8]) -> Vec<u8> {
    let mut output = kind.to_vec();
    output.extend((body.len() as u32).to_le_bytes());
    output.extend(body);
    if !body.len().is_multiple_of(2) {
        output.push(0);
    }
    output
}

fn wave(chunks: &[Vec<u8>]) -> Vec<u8> {
    let body = [b"WAVE".as_slice(), chunks.concat().as_slice()].concat();
    chunk(b"RIFF", &body)
}

fn info(entries: &[(&[u8; 4], &str)]) -> Vec<u8> {
    let mut body = b"INFO".to_vec();
    for (kind, text) in entries {
        body.extend(chunk(kind, &[text.as_bytes(), &[0]].concat()));
    }
    chunk(b"LIST", &body)
}

fn chunks(data: &[u8]) -> Vec<(&[u8], &[u8])> {
    let mut result = Vec::new();
    let mut offset = 12;
    while offset + 8 <= data.len() {
        let length = u32::from_le_bytes(data[offset + 4..offset + 8].try_into().unwrap()) as usize;
        result.push((
            &data[offset..offset + 4],
            &data[offset + 8..offset + 8 + length],
        ));
        offset += 8 + length + (length & 1);
    }
    assert_eq!(offset, data.len());
    assert_eq!(
        u32::from_le_bytes(data[4..8].try_into().unwrap()) as usize + 8,
        data.len()
    );
    result
}

fn info_entries(data: &[u8]) -> Vec<([u8; 4], String)> {
    let mut result = Vec::new();
    for (kind, body) in chunks(data) {
        if kind != b"LIST" || !body.starts_with(b"INFO") {
            continue;
        }
        let mut offset = 4;
        while offset + 8 <= body.len() {
            let length =
                u32::from_le_bytes(body[offset + 4..offset + 8].try_into().unwrap()) as usize;
            let text = std::str::from_utf8(&body[offset + 8..offset + 8 + length]).unwrap();
            result.push((
                body[offset..offset + 4].try_into().unwrap(),
                text.trim_end_matches('\0').into(),
            ));
            offset += 8 + length + (length & 1);
        }
        assert_eq!(offset, body.len());
    }
    result
}

fn rewrite(source: &[u8], fields: &BTreeMap<String, String>, cover: Option<&[u8]>) -> Vec<u8> {
    let mut output = Vec::new();
    rewrite_audio_tags(
        &mut Cursor::new(source),
        &mut output,
        "wav",
        fields,
        cover,
        &|| Ok(()),
    )
    .unwrap();
    output
}

fn original() -> Vec<u8> {
    let format = [
        1_u16.to_le_bytes().as_slice(),
        &2_u16.to_le_bytes(),
        &44100_u32.to_le_bytes(),
        &176400_u32.to_le_bytes(),
        &4_u16.to_le_bytes(),
        &16_u16.to_le_bytes(),
    ]
    .concat();
    let audio = chunk(b"data", &[0, 1, 2, 3, 4, 5, 6, 7]);
    let fields = BTreeMap::from([
        ("title".into(), "Old title".into()),
        ("artist".into(), "Old artist".into()),
        ("album".into(), "Old album".into()),
        ("track_number".into(), "4".into()),
        ("track_total".into(), "8".into()),
    ]);
    let tagged = rewrite(&wave(&[chunk(b"fmt ", &format), audio]), &fields, None);
    let mut original_chunks: Vec<_> = chunks(&tagged)
        .into_iter()
        .map(|(kind, body)| chunk(kind.try_into().unwrap(), body))
        .collect();
    original_chunks.push(info(&[
        (b"INAM", "Old title"),
        (b"IART", "Old artist"),
        (b"IPRD", "Old album"),
        (b"ICMT", "Old comment"),
        (b"ITRK", "4/8"),
        (b"ISFT", "Example recorder"),
        (b"IPRT", "4/8"),
        (b"IWRI", "Old composer"),
    ]));
    original_chunks.push(chunk(b"LIST", b"adtluntouched labels"));
    wave(&original_chunks)
}

#[test]
fn wav_edits_update_info_and_id3_without_changing_audio_or_other_lists() {
    let source = original();
    let fields = BTreeMap::from([
        ("title".into(), "New title".into()),
        ("artist".into(), "New artist".into()),
        ("album".into(), "New album".into()),
        ("comment".into(), "New comment".into()),
        ("track_number".into(), "2".into()),
        ("track_total".into(), "10".into()),
        ("lyrics".into(), "[00:01.00] New lyrics".into()),
        ("date".into(), "2026-10-28".into()),
        ("genre".into(), "New genre".into()),
        ("composer".into(), "New composer".into()),
        ("copyright".into(), "New copyright".into()),
    ]);
    let mut png = Cursor::new(Vec::new());
    image::DynamicImage::new_rgb8(2, 2)
        .write_to(&mut png, image::ImageFormat::Png)
        .unwrap();
    let png = png.into_inner();
    let output = rewrite(&source, &fields, Some(&png));
    let metadata = read_audio_tags(&mut Cursor::new(&output), "wav", &|| Ok(())).unwrap();
    assert_eq!(metadata.title, "New title");
    assert_eq!(metadata.artist, "New artist");
    assert_eq!(metadata.lyrics, "[00:01.00] New lyrics");
    assert_eq!((metadata.track_number, metadata.total_tracks), (2, 10));
    assert_eq!(
        extract_cover(&mut Cursor::new(&output), "wav", &|| Ok(()))
            .unwrap()
            .data,
        png
    );
    for (kind, expected) in [
        (b"INAM", "New title"),
        (b"IART", "New artist"),
        (b"IPRD", "New album"),
        (b"ICMT", "New comment"),
        (b"ITRK", "2/10"),
        (b"ISFT", "Example recorder"),
        (b"ICRD", "2026-10-28"),
        (b"IGNR", "New genre"),
        (b"IMUS", "New composer"),
        (b"ICOP", "New copyright"),
    ] {
        assert_eq!(
            info_entries(&output)
                .iter()
                .find(|(id, _)| id == kind)
                .unwrap()
                .1,
            expected
        );
    }
    let untouched = |data: &[u8]| {
        chunks(data)
            .into_iter()
            .filter(|(kind, body)| {
                *kind == b"data"
                    || *kind == b"fmt "
                    || (*kind == b"LIST" && body.starts_with(b"adtl"))
            })
            .map(|(kind, body)| (kind.to_vec(), body.to_vec()))
            .collect::<Vec<_>>()
    };
    assert_eq!(untouched(&output), untouched(&source));
    assert!(
        !info_entries(&output)
            .iter()
            .any(|(id, _)| matches!(id, b"IPRT" | b"IWRI"))
    );
}

#[test]
fn wav_clear_removes_stale_info_and_partial_edits_preserve_other_fields() {
    let source = original();
    let output = rewrite(
        &source,
        &BTreeMap::from([("title".into(), String::new())]),
        None,
    );
    let entries = info_entries(&output);
    assert!(!entries.iter().any(|(id, _)| id == b"INAM"));
    assert!(
        entries
            .iter()
            .any(|(id, text)| id == b"IART" && text == "Old artist")
    );
    assert!(
        entries
            .iter()
            .any(|(id, text)| id == b"ISFT" && text == "Example recorder")
    );
    assert!(
        read_audio_tags(&mut Cursor::new(output), "wav", &|| Ok(()))
            .unwrap()
            .title
            .is_empty()
    );
}

#[test]
fn wav_updates_all_duplicate_info_values_and_repeated_writes_stay_aligned() {
    let source = wave(&[
        info(&[(b"INAM", "Old one"), (b"INAM", "Old two")]),
        chunk(b"data", &[1, 2]),
    ]);
    let fields = BTreeMap::from([("title".into(), "Music 音乐".into())]);
    let once = rewrite(&source, &fields, None);
    let twice = rewrite(&once, &fields, None);
    assert_eq!(info_entries(&twice), vec![(*b"INAM", "Music 音乐".into())]);
    assert_eq!(once, twice);
}

#[test]
fn wav_partial_track_edit_uses_the_existing_number_in_both_tags() {
    let output = rewrite(
        &original(),
        &BTreeMap::from([("track_total".into(), "10".into())]),
        None,
    );
    let metadata = read_audio_tags(&mut Cursor::new(&output), "wav", &|| Ok(())).unwrap();
    assert_eq!((metadata.track_number, metadata.total_tracks), (4, 10));
    assert!(
        info_entries(&output)
            .iter()
            .any(|(id, text)| id == b"ITRK" && text == "4/10")
    );
    assert!(!info_entries(&output).iter().any(|(id, _)| id == b"IPRT"));
}

#[test]
fn wav_edit_preserves_private_id3_frames_and_existing_artwork() {
    let payload = b"example.vendor\0private metadata";
    let mut frame = b"PRIV".to_vec();
    frame.extend((payload.len() as u32).to_be_bytes());
    frame.extend([0, 0]);
    frame.extend(payload);
    let mut tag = b"ID3\x03\0\0".to_vec();
    tag.extend([0, 0, 0, frame.len() as u8]);
    tag.extend(frame);
    let source = wave(&[chunk(b"data", &[1, 2]), chunk(b"id3 ", &tag)]);
    let mut png = Cursor::new(Vec::new());
    image::DynamicImage::new_rgb8(2, 2)
        .write_to(&mut png, image::ImageFormat::Png)
        .unwrap();
    let png = png.into_inner();
    let first = rewrite(
        &source,
        &BTreeMap::from([("title".into(), "First title".into())]),
        Some(&png),
    );
    let output = rewrite(
        &first,
        &BTreeMap::from([("title".into(), "Second title".into())]),
        None,
    );
    assert!(output.windows(payload.len()).any(|part| part == payload));
    assert_eq!(
        extract_cover(&mut Cursor::new(output), "wav", &|| Ok(()))
            .unwrap()
            .data,
        png
    );
}

#[test]
fn wav_edit_rejects_truncated_info_before_writing_output() {
    for body in [
        b"INFOINAM".to_vec(),
        [b"INFOINAM".as_slice(), &u32::MAX.to_le_bytes()].concat(),
    ] {
        let source = wave(&[chunk(b"data", &[1, 2]), chunk(b"LIST", &body)]);
        let mut output = Vec::new();
        let result = rewrite_audio_tags(
            &mut Cursor::new(source),
            &mut output,
            "wav",
            &BTreeMap::from([("title".into(), "New title".into())]),
            None,
            &|| Ok(()),
        );
        assert!(result.unwrap_err().starts_with("invalid RIFF INFO"));
        assert!(output.is_empty());
    }
}

#[test]
fn wav_replaygain_removal_leaves_info_unchanged() {
    let source = original();
    let fields = BTreeMap::from([
        ("replaygain_track_gain".into(), String::new()),
        ("replaygain_track_peak".into(), String::new()),
        ("replaygain_album_gain".into(), String::new()),
        ("replaygain_album_peak".into(), String::new()),
    ]);
    let output = rewrite(&source, &fields, None);
    assert_eq!(info_entries(&source), info_entries(&output));
}
