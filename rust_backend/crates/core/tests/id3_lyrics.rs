use mornye_core::tags::read_audio_tags;
use std::io::Cursor;

fn syncsafe(size: usize) -> [u8; 4] {
    [
        (size >> 21 & 127) as u8,
        (size >> 14 & 127) as u8,
        (size >> 7 & 127) as u8,
        (size & 127) as u8,
    ]
}

fn frame(id: &str, data: Vec<u8>) -> Vec<u8> {
    let mut frame = id.as_bytes().to_vec();
    frame.extend(syncsafe(data.len()));
    frame.extend([0, 0]);
    frame.extend(data);
    frame
}

fn user_text(description: &str, value: &str) -> Vec<u8> {
    let mut data = vec![3];
    data.extend(description.as_bytes());
    data.push(0);
    data.extend(value.as_bytes());
    frame("TXXX", data)
}

fn uslt(value: &str) -> Vec<u8> {
    let mut data = vec![3];
    data.extend(b"eng");
    data.push(0);
    data.extend(value.as_bytes());
    frame("USLT", data)
}

fn tag(frames: Vec<Vec<u8>>) -> Vec<u8> {
    let body: Vec<u8> = frames.concat();
    let mut tag = b"ID3\x04\0\0".to_vec();
    tag.extend(syncsafe(body.len()));
    tag.extend(body);
    tag
}

fn lyrics(source: &[u8]) -> String {
    read_audio_tags(&mut Cursor::new(source.to_vec()), "mp3", &|| Ok(()))
        .unwrap()
        .lyrics
}

#[test]
fn uslt_wins_over_earlier_user_text_lyrics() {
    let source = tag(vec![
        user_text("UNSYNCEDLYRICS", "old plain"),
        uslt("[00:01.00]new synced"),
    ]);
    assert_eq!(lyrics(&source), "[00:01.00]new synced");
}

#[test]
fn uslt_wins_over_later_user_text_lyrics() {
    let source = tag(vec![
        uslt("[00:01.00]new synced"),
        user_text("UNSYNCEDLYRICS", "old plain"),
    ]);
    assert_eq!(lyrics(&source), "[00:01.00]new synced");
}

#[test]
fn user_text_lyrics_used_when_no_uslt_present() {
    let source = tag(vec![user_text("UNSYNCEDLYRICS", "old plain")]);
    assert_eq!(lyrics(&source), "old plain");
}
