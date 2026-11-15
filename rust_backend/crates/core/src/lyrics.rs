//! Lyrics contracts shared by built-in providers, extension hosts and exports.

pub mod config;
pub mod errors;
pub mod file;
pub(crate) mod json;
pub mod lrc;
pub mod lrclib;
pub mod matching;
pub mod models;
pub mod payloads;

use crate::json::lenient_deserialize;
use serde::{Deserialize, Serialize};

/// HTTP providers use Go's streaming JSON decoder: decode the first value,
/// replacing invalid UTF-8 and unpaired UTF-16 escapes before typed decoding.
pub fn decode_response<T: serde::de::DeserializeOwned>(
    bytes: &[u8],
) -> Result<T, serde_json::Error> {
    let text = crate::text::utf8(bytes);
    let normalized = crate::text::json_surrogates(&text);
    // Go scans a complete JSON value before decoding typed fields. Otherwise a
    // wrong root type could hide truncated JSON and change provider cooldowns.
    let raw = <&serde_json::value::RawValue>::deserialize(
        &mut serde_json::Deserializer::from_str(&normalized),
    )?;
    serde_json::from_str(raw.get())
}

/// Complete-document counterpart to the streaming HTTP decoder.
pub fn decode_document<T: serde::de::DeserializeOwned>(
    bytes: &[u8],
) -> Result<T, serde_json::Error> {
    let text = crate::text::utf8(bytes);
    let normalized = crate::text::json_surrogates(&text);
    let raw: &serde_json::value::RawValue = serde_json::from_str(&normalized)?;
    serde_json::from_str(raw.get())
}

pub fn text_from_bytes(bytes: &[u8]) -> String {
    crate::text::utf8(bytes)
}

#[derive(Clone, Debug, Default, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct LyricsWord {
    pub text: String,
    pub start_time_ms: i64,
    pub end_time_ms: i64,
}

lenient_deserialize!(LyricsWord {
    "text" => text,
    "starttimems" => start_time_ms,
    "endtimems" => end_time_ms,
});

#[derive(Clone, Debug, Default, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct LyricsLine {
    pub start_time_ms: i64,
    pub words: String,
    pub end_time_ms: i64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub romanization: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub romanization_words: Option<Vec<LyricsWord>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub translation: Option<String>,
}

lenient_deserialize!(LyricsLine {
    "starttimems" => start_time_ms,
    "words" => words,
    "endtimems" => end_time_ms,
    "romanization" => romanization,
    "romanizationwords" => romanization_words,
    "translation" => translation,
});

#[derive(Clone, Debug, Default, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct LyricsResponse {
    // Go distinguishes an uninitialized slice (null) from an explicit [].
    pub lines: Option<Vec<LyricsLine>>,
    pub sync_type: String,
    pub instrumental: bool,
    pub plain_lyrics: String,
    pub provider: String,
    pub source: String,
}

lenient_deserialize!(LyricsResponse {
    "lines" => lines,
    "synctype" => sync_type,
    "instrumental" => instrumental,
    "plainlyrics" => plain_lyrics,
    "provider" => provider,
    "source" => source,
});

impl LyricsResponse {
    pub fn lines(&self) -> &[LyricsLine] {
        self.lines.as_deref().unwrap_or_default()
    }

    pub fn has_usable_text(&self) -> bool {
        self.instrumental
            || !self.plain_lyrics.trim().is_empty()
            || self
                .lines()
                .iter()
                .any(|line| !line.words.trim().is_empty())
    }

    pub fn is_synced(&self) -> bool {
        self.sync_type == "LINE_SYNCED" && lrc::has_usable_timing(self.lines())
    }

    /// Synced lyrics that also time each word, as TTML and enhanced LRC
    /// sources give them.
    pub fn is_word_synced(&self) -> bool {
        self.is_synced() && lrc::has_word_timing(self.lines())
    }

    pub fn normalize_timing(&mut self) {
        if self.sync_type == "LINE_SYNCED" && !self.is_synced() {
            self.sync_type = "UNSYNCED".into();
            if !self.lines().is_empty() {
                self.plain_lyrics = lrc::untimed_text(self.lines());
            }
        }
    }

    pub fn from_text(text: &str, provider: &str, source: &str) -> Self {
        let mut result = Self {
            provider: provider.into(),
            source: source.into(),
            ..Self::default()
        };
        if let Some(lines) = lrc::parse_synced(text) {
            result.plain_lyrics = lrc::plain_from_timed_lines(&lines);
            result.lines = Some(lines);
            result.sync_type = "LINE_SYNCED".into();
        } else if let Some(lines) = lrc::plain_text_lines(text) {
            result.lines = Some(lines);
            result.sync_type = "UNSYNCED".into();
            result.plain_lyrics = text.into();
        }
        result.normalize_timing();
        result
    }
}
