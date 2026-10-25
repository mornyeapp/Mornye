//! OpenSubsonic `getLyricsBySongId` (songLyrics version 1): the lyrics a
//! song's file embeds, else its `.lrc` sidecar, as line-level structured
//! lyrics. `mornyeRaw` carries the stored text as well; a Mornye phone
//! parses it as it parses a local file's, keeping word timing, voices and
//! backing vocals that the line-level shape drops.

use super::{Failure, Payload, payload, required};
use crate::catalog::Catalog;
use crate::types::SubsonicRequest;
use mornye_core::lyrics::{file, lrc};
use regex::Regex;
use serde_json::{Value, json};
use std::fs::File;
use std::sync::LazyLock;

/// One or more leading `[mm:ss.xx]` stamps (a line sung more than once).
static LEADING_TIMES: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"^(?:\[[0-9]{1,3}:[0-9]{1,2}(?:[.:][0-9]{1,3})?\])+").unwrap());
/// A word timing inside a line, `<mm:ss.xx>`.
static WORD_TIME: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"<[0-9]{1,3}:[0-9]{1,2}(?:[.:][0-9]{1,3})?>").unwrap());
static VOICE_PREFIX: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"(?i)^v[1-9][0-9]*:").unwrap());
/// A header such as `[ar:Artist]` or `[instrumental:true]`.
static HEADER: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"(?i)^\[[a-z][a-z0-9_-]*:.*\]$").unwrap());

/// A song without lyrics answers an empty `structuredLyrics`; an unknown id
/// answers error 70.
pub(super) async fn by_song_id(
    catalog: &Catalog,
    request: &SubsonicRequest,
) -> Result<Payload, Failure> {
    let id = required(request, "id")?;
    let song = catalog.song(id).ok_or_else(|| Failure::not_found("Song"))?;
    let path = song.path.to_string_lossy().into_owned();
    let raw = tokio::task::spawn_blocking(move || {
        file::extract(
            &path,
            &|path| File::open(path).map_err(|error| error.to_string()),
            &|| Ok(()),
        )
    })
    .await
    .ok()
    .and_then(Result::ok)
    .unwrap_or_default();
    let entries = if lrc::has_usable_content(&raw) {
        vec![structured(&song.artist, &song.title, raw)]
    } else {
        Vec::new()
    };
    Ok(payload(
        "lyricsList",
        json!({ "structuredLyrics": entries }),
    ))
}

fn structured(artist: &str, title: &str, raw: String) -> Value {
    let (synced, line): (bool, Vec<Value>) = match lrc::parse_synced(&raw) {
        Some(lines) => {
            let mut lines: Vec<(i64, String)> = lines
                .iter()
                .map(|line| (line.start_time_ms, display_text(&line.words)))
                .filter(|(_, text)| !text.is_empty())
                .collect();
            lines.sort_by_key(|(start, _)| *start);
            let lines = lines
                .into_iter()
                .map(|(start, value)| json!({ "start": start, "value": value }))
                .collect();
            (true, lines)
        }
        None => {
            let lines = raw
                .lines()
                .map(str::trim)
                .filter(|line| !line.is_empty() && !HEADER.is_match(line))
                .map(|value| json!({ "value": value }))
                .collect();
            (false, lines)
        }
    };
    json!({
        "displayArtist": artist,
        "displayTitle": title,
        "lang": "xxx",
        "offset": 0,
        "synced": synced,
        "line": line,
        "mornyeRaw": raw,
    })
}

/// A synced line as sung by its lead: without word timings, a voice prefix
/// (`v1:`) or the backing vocals parsed onto it (`\n[bg:...]`).
fn display_text(words: &str) -> String {
    let lead = words.split('\n').next().unwrap_or_default();
    let lead = LEADING_TIMES.replace(lead.trim(), "");
    let lead = WORD_TIME.replace_all(&lead, "");
    VOICE_PREFIX.replace(lead.trim(), "").trim().to_owned()
}
