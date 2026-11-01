use super::*;

/// Songs `synced`, `plain` and `none`, each a fake FLAC with the given
/// `.lrc` sidecar (none for `none`).
fn songs(synced: &str, plain: &str) -> Fixture {
    let (synced, plain) = (synced.to_owned(), plain.to_owned());
    Fixture::new(move |dir| {
        let song = |id: &str, title: &str, lrc: Option<&str>| {
            let path = write_file(dir, &format!("{id}.flac"), &[0, 1, 2, 3]);
            if let Some(lrc) = lrc {
                write_file(dir, &format!("{id}.lrc"), lrc.as_bytes());
            }
            json!({
                "id": id, "title": title, "artist": "Singer", "path": path,
                "suffix": "flac", "durationMs": 200_000, "size": 4,
            })
        };
        vec![
            song("synced", "Timed", Some(&synced)),
            song("plain", "Untimed", Some(&plain)),
            song("none", "Silent", None),
        ]
    })
}

const SYNCED: &str = "[ar:Singer]\n\
    [00:03.00]Third line\n\
    [00:01.00]v1:<00:01.00>Hello <00:01.50>world<00:02.00>\n\
    [bg:<00:01.20>(echo)]\n\
    [00:02.00][00:04.00]Twice\n";

#[tokio::test]
async fn synced_lyrics_are_lines_by_start_with_the_stored_text() {
    let fixture = songs(SYNCED, "First\nSecond");
    let list = fixture
        .ok("getLyricsBySongId", &[("id", "synced")], "lyricsList")
        .await;
    let entries = list["structuredLyrics"].as_array().expect("entries");
    assert_eq!(entries.len(), 1, "{list}");
    let entry = &entries[0];
    assert_eq!(entry["synced"], true);
    assert_eq!(entry["lang"], "xxx");
    assert_eq!(entry["offset"], 0);
    assert_eq!(entry["displayArtist"], "Singer");
    assert_eq!(entry["displayTitle"], "Timed");
    assert_eq!(
        entry["line"],
        json!([
            { "start": 1000, "value": "Hello world" },
            { "start": 2000, "value": "Twice" },
            { "start": 3000, "value": "Third line" },
        ])
    );
    assert_eq!(entry["mornyeRaw"], SYNCED.trim());
}

#[tokio::test]
async fn plain_lyrics_are_lines_without_start() {
    let fixture = songs(SYNCED, "[ar:Singer]\nFirst\n\n Second \n");
    let list = fixture
        .ok("getLyricsBySongId", &[("id", "plain")], "lyricsList")
        .await;
    let entry = &list["structuredLyrics"][0];
    assert_eq!(entry["synced"], false);
    assert_eq!(
        entry["line"],
        json!([{ "value": "First" }, { "value": "Second" }])
    );
}

#[tokio::test]
async fn a_song_without_lyrics_has_none_and_an_unknown_one_is_not_found() {
    let fixture = songs(SYNCED, "[ar:Singer]\n[00:01.00]");
    for id in ["none", "plain"] {
        assert_eq!(
            fixture
                .ok("getLyricsBySongId", &[("id", id)], "lyricsList")
                .await,
            json!({ "structuredLyrics": [] }),
            "{id}"
        );
    }
    assert_eq!(
        fixture
            .error_code("getLyricsBySongId", &[("id", "missing")])
            .await,
        u64::from(code::NOT_FOUND)
    );
    assert_eq!(
        fixture.error_code("getLyricsBySongId", &[]).await,
        u64::from(code::MISSING_PARAMETER)
    );
}

#[tokio::test]
async fn xml_lines_carry_their_text_as_content() {
    let fixture = songs(SYNCED, "First");
    let reply = fixture
        .raw("getLyricsBySongId", &[("id", "synced")], HeaderMap::new())
        .await;
    let text = reply.text();
    let document = roxmltree::Document::parse(&text).expect("well-formed XML");
    let entry = document
        .descendants()
        .find(|node| node.has_tag_name("structuredLyrics"))
        .expect("structuredLyrics");
    assert_eq!(entry.attribute("synced"), Some("true"));
    assert_eq!(entry.attribute("mornyeRaw"), Some(SYNCED.trim()));
    let first = entry
        .children()
        .find(|node| node.has_tag_name("line"))
        .expect("line");
    assert_eq!(first.attribute("start"), Some("1000"));
    assert_eq!(first.text(), Some("Hello world"));
}
