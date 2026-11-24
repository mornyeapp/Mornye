//! The player's existing LRC/TTML contract, parsed on the bounded data worker.
//! Milliseconds cross the bridge; playback timeline lookup stays in Flutter.
mod credits;
mod lrc;
#[cfg(test)]
mod tests;
mod text;
mod ttml;

use credits::{WRITER_CREDIT, with_credits};
use lrc::parse_lrc;
use serde::Serialize;
use serde_json::Value;
use text::{looks_ttml, trim};
use ttml::parse_ttml;

#[derive(Clone, Debug, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
struct Word {
    time_ms: i64,
    end_ms: Option<i64>,
    text: String,
}
#[derive(Clone, Debug, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
struct Voice {
    id: String,
    index: i64,
    is_group: bool,
}
#[derive(Clone, Debug, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
struct Line {
    time_ms: i64,
    end_ms: Option<i64>,
    text: String,
    words: Vec<Word>,
    romanization: Option<String>,
    romanization_words: Vec<Word>,
    translation: Option<String>,
    // Saved AI translation timing is rare; leave it out of the bridge
    // payload when a line has none.
    #[serde(skip_serializing_if = "Vec::is_empty")]
    translation_words: Vec<Word>,
    voice: Option<Voice>,
    is_background: bool,
    vocal_group: Option<i64>,
}
#[derive(Default, Debug, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
struct Parsed {
    synced: bool,
    word_synced: bool,
    lines: Vec<Line>,
    plain_text: String,
    writers: Option<String>,
    provider: Option<String>,
}

fn has_usable_timing(lines: &[Line]) -> bool {
    lines.iter().enumerate().any(|(index, line)| {
        !trim(&line.text).is_empty()
            && !(index + 1 == lines.len() && WRITER_CREDIT.is_match(trim(&line.text)))
            && (line.time_ms > 0
                || line.end_ms.is_some_and(|time| time > 0)
                || line.words.iter().any(|word| {
                    !trim(&word.text).is_empty()
                        && (word.time_ms > 0 || word.end_ms.is_some_and(|time| time > 0))
                }))
    })
}
impl Line {
    fn new(
        time_ms: i64,
        end_ms: Option<i64>,
        text: String,
        words: Vec<Word>,
        voice: Option<Voice>,
        background: bool,
        group: Option<i64>,
    ) -> Self {
        Self {
            time_ms,
            end_ms,
            text,
            words,
            voice,
            is_background: background,
            vocal_group: group,
            romanization: None,
            romanization_words: vec![],
            translation: None,
            translation_words: vec![],
        }
    }
}

pub(crate) fn execute(
    request: &Value,
    bytes: Option<&[u8]>,
    check: &dyn Fn() -> Result<(), String>,
) -> Result<Value, String> {
    check()?;
    let raw = match bytes.filter(|b| !b.is_empty()) {
        Some(data) => std::str::from_utf8(data).map_err(|e| e.to_string())?,
        None => request["raw"].as_str().unwrap_or_default(),
    };
    let text = trim(raw);
    let mut parsed = if text.is_empty() {
        Parsed::default()
    } else {
        match if looks_ttml(text) {
            parse_ttml(text, check)?
        } else {
            None
        } {
            Some(parsed) if !parsed.lines.is_empty() => parsed,
            _ => parse_lrc(text, check)?,
        }
    };
    if !text.is_empty() {
        with_credits(text, &mut parsed)?;
    }
    check()?;
    serde_json::to_value(parsed).map_err(|e| e.to_string())
}
