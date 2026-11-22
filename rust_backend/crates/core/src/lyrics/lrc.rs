//! LRC lyrics parsing and helpers: timestamps, synced and plain text, and usability checks.

use super::{LyricsLine, LyricsResponse, LyricsWord};
use crate::matching::lowercase;
use regex::Regex;
use std::sync::LazyLock;

static TIMED_LINE: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"\[([0-9]{2}):([0-9]{2})\.([0-9]{2,3})\](.*)").unwrap());
static METADATA: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"(?i)^\[[a-z][a-z0-9_-]*:.*\]$").unwrap());
static BACKGROUND: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"(?i)^\[bg:(.*)\]$").unwrap());
static LEADING_TIME: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"^\[[0-9]{1,3}:[0-9]{1,2}(?:[.:][0-9]{1,3})?\]").unwrap());
static INLINE_TIME: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"<[0-9]{1,3}:[0-9]{1,2}(?:[.:][0-9]{1,3})?>").unwrap());
static VOICE_PREFIX: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"(?i)^v[1-9][0-9]*:").unwrap());
static INSTRUMENTAL: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"(?i)^\[instrumental:true\]$").unwrap());
static WRITER_CREDIT: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"(?i)^Written\s+by\s*:.+$").unwrap());

pub fn is_instrumental_marker(raw: &str) -> bool {
    INSTRUMENTAL.is_match(raw.trim())
}

/// Headers, empty timestamps and empty vocal markers are not embedded lyrics.
pub fn has_usable_content(raw: &str) -> bool {
    if is_instrumental_marker(raw) {
        return true;
    }
    for line in raw.split('\n') {
        let mut cleaned = line.trim();
        if cleaned.is_empty() {
            continue;
        }
        if let Some(background) = BACKGROUND.captures(cleaned) {
            cleaned = background.get(1).unwrap().as_str().trim();
        } else if METADATA.is_match(cleaned) {
            continue;
        }
        while let Some(timestamp) = LEADING_TIME.find(cleaned) {
            cleaned = cleaned[timestamp.end()..].trim();
        }
        let without_inline = INLINE_TIME.replace_all(cleaned, "");
        cleaned = without_inline.trim();
        if let Some(voice) = VOICE_PREFIX.find(cleaned) {
            cleaned = cleaned[voice.end()..].trim();
        }
        if !cleaned.is_empty() {
            return true;
        }
    }
    false
}

pub fn parse_synced(raw: &str) -> Option<Vec<LyricsLine>> {
    let mut lines: Vec<LyricsLine> = Vec::new();
    for line in raw.split('\n').map(str::trim) {
        if line.is_empty() {
            continue;
        }
        if line.starts_with("[bg:")
            && let Some(previous) = lines.last_mut()
        {
            previous.words.push('\n');
            previous.words.push_str(line);
            continue;
        }
        if let Some(captures) = TIMED_LINE.captures(line) {
            let words = captures[4].trim();
            if words.is_empty() {
                continue;
            }
            let minutes = captures[1].parse::<i64>().unwrap();
            let seconds = captures[2].parse::<i64>().unwrap();
            let mut fraction = captures[3].parse::<i64>().unwrap();
            if captures[3].len() == 2 {
                fraction *= 10;
            }
            lines.push(LyricsLine {
                start_time_ms: minutes * 60_000 + seconds * 1000 + fraction,
                words: words.into(),
                end_time_ms: 0,
                ..LyricsLine::default()
            });
        }
    }
    for index in 1..lines.len() {
        lines[index - 1].end_time_ms = lines[index].start_time_ms;
    }
    if let Some(last) = lines.last_mut() {
        last.end_time_ms = last.start_time_ms + 5000;
    }
    (!lines.is_empty()).then_some(lines)
}

pub fn plain_text_lines(raw: &str) -> Option<Vec<LyricsLine>> {
    let lines: Vec<_> = raw
        .split('\n')
        .map(str::trim)
        .filter(|line| !line.is_empty())
        .map(|line| LyricsLine {
            words: line.into(),
            ..LyricsLine::default()
        })
        .collect();
    (!lines.is_empty()).then_some(lines)
}

pub fn plain_from_timed_lines(lines: &[LyricsLine]) -> String {
    lines
        .iter()
        .map(|line| line.words.trim())
        .filter(|words| !words.is_empty())
        .collect::<Vec<_>>()
        .join("\n")
}

pub fn has_usable_timing(lines: &[LyricsLine]) -> bool {
    // Ignore synthesized end times: parse_synced adds five seconds to the
    // final row even when every source timestamp is zero.
    lines.iter().enumerate().any(|(index, line)| {
        has_usable_content(&line.words)
            && !(index + 1 == lines.len() && WRITER_CREDIT.is_match(line.words.trim()))
            && (line.start_time_ms > 0
                || INLINE_TIME.find_iter(&line.words).any(|time| {
                    time.as_str()
                        .bytes()
                        .any(|byte| matches!(byte, b'1'..=b'9'))
                }))
    })
}

/// Whether any line times its words: an inline timestamp that starts some
/// text, as enhanced LRC writes it. A lone closing timestamp only ends the
/// line.
pub fn has_word_timing(lines: &[LyricsLine]) -> bool {
    lines.iter().any(|line| {
        let words = &line.words;
        let mut times = INLINE_TIME.find_iter(words).peekable();
        while let Some(time) = times.next() {
            let end = times.peek().map_or(words.len(), |next| next.start());
            if !words[time.end()..end].trim().is_empty() {
                return true;
            }
        }
        false
    })
}

pub(super) fn untimed_text(lines: &[LyricsLine]) -> String {
    INLINE_TIME
        .replace_all(&plain_from_timed_lines(lines), "")
        .into_owned()
}

pub fn timestamp_inline(ms: i64) -> String {
    let ms = ms.max(0);
    let seconds = ms / 1000;
    let fraction = if ms % 10 == 0 {
        format!("{:02}", ms % 1000 / 10)
    } else {
        format!("{:03}", ms % 1000)
    };
    format!("{:02}:{:02}.{fraction}", seconds / 60, seconds % 60)
}

pub fn timestamp(ms: i64) -> String {
    format!("[{}]", timestamp_inline(ms))
}

pub fn source_uses_proxy(source: &str) -> bool {
    let source = lowercase(source.trim());
    !source.is_empty()
        && ![
            "lrclib",
            "zarz-lrc",
            "mornye lyrics",
            // Retain credits embedded before the provider was renamed.
            "spotiflac-mobile lyrics",
            "kugou direct",
            "qq music direct",
            "genius direct",
            "lrc.red",
            "betterlyrics",
            "extension:",
            "heuristic",
        ]
        .iter()
        .any(|prefix| source.starts_with(prefix))
}

pub fn extract_source(raw: &str) -> String {
    for line in raw.split('\n').map(str::trim) {
        if !lowercase(line).starts_with("[by:") {
            continue;
        }
        let Some((_, source)) = line.split_once("(source: ") else {
            return String::new();
        };
        let source = source.trim();
        let source = source.strip_suffix(']').unwrap_or(source);
        return source.strip_suffix(')').unwrap_or(source).trim().into();
    }
    String::new()
}

/// A readable tag value, as lib/utils/lyric_supplement_tags.dart writes it:
/// `\n` for a line break, `\\` for a backslash and, in word timing, `\<`.
fn escape_supplement(text: &str, words: bool) -> String {
    let mut out = String::new();
    for c in text.replace("\r\n", "\n").replace('\r', "\n").chars() {
        match c {
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '<' if words => out.push_str("\\<"),
            _ => out.push(c),
        }
    }
    out
}

/// Word timing as enhanced LRC: each word after its start, a time with no
/// word after it where a word ends before the next starts. None when a word
/// has no valid time range.
fn supplement_words(words: &[LyricsWord]) -> Option<String> {
    let mut out = String::new();
    let mut last: Option<(i64, i64)> = None;
    for word in words {
        let (start, end) = (word.start_time_ms, word.end_time_ms);
        if word.text.trim().is_empty()
            || start < 0
            || end < start
            || last.is_some_and(|(last_start, _)| last_start > start)
        {
            return None;
        }
        if let Some((_, last_end)) = last
            && last_end != start
        {
            out.push_str(&format!("<{}>", timestamp_inline(last_end)));
        }
        out.push_str(&format!("<{}>", timestamp_inline(start)));
        out.push_str(&escape_supplement(&word.text, true));
        last = Some((start, end));
    }
    let (_, end) = last?;
    out.push_str(&format!("<{}>", timestamp_inline(end)));
    Some(out)
}

pub fn with_metadata(lyrics: &LyricsResponse, track: &str, artist: &str) -> String {
    if lyrics.lines().is_empty() {
        return String::new();
    }
    let source = if lyrics.source.trim().is_empty() {
        lyrics.provider.trim()
    } else {
        lyrics.source.trim()
    };
    let credit = if source_uses_proxy(source) {
        "Mornye via Paxsenix API"
    } else {
        "Mornye"
    };
    let mut output = format!("[ti:{track}]\n[ar:{artist}]\n[by:{credit}");
    if !source.is_empty() {
        output.push_str(&format!(" (source: {source})"));
    }
    output.push_str("]\n\n");
    let synced = lyrics.is_synced();
    if synced {
        for line in lyrics.lines() {
            if let Some(words) = line
                .romanization_words
                .as_deref()
                .and_then(supplement_words)
            {
                output.push_str(&format!(
                    "[x-romanized-words:{}:{words}]\n",
                    line.start_time_ms
                ));
            }
            for (tag, text) in [
                ("x-romanized", &line.romanization),
                ("x-translated", &line.translation),
            ] {
                if let Some(text) = text.as_deref().filter(|text| !text.trim().is_empty()) {
                    output.push_str(&format!(
                        "[{tag}:{}:{}]\n",
                        line.start_time_ms,
                        escape_supplement(text.trim(), false)
                    ));
                }
            }
        }
    }
    for line in lyrics.lines() {
        if line.words.is_empty() {
            continue;
        }
        if synced {
            output.push_str(&timestamp(line.start_time_ms));
        }
        if synced {
            output.push_str(&line.words);
        } else {
            output.push_str(&INLINE_TIME.replace_all(&line.words, ""));
        }
        output.push('\n');
    }
    output
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn first_party_lyrics_do_not_credit_paxsenix() {
        for source in [
            "Zarz-LRC",
            "Zarz-LRC (cached)",
            "Mornye Lyrics",
            "Mornye Lyrics (cached)",
            "SpotiFLAC-Mobile Lyrics",
            "SpotiFLAC-Mobile Lyrics (cached)",
        ] {
            let lyrics = LyricsResponse::from_text("[00:01.00]Example", source, source);
            let saved = with_metadata(&lyrics, "Track", "Artist");
            assert!(saved.contains("[by:Mornye (source: "));
            assert!(!saved.contains("Paxsenix"));
            assert_eq!(extract_source(&saved), source);
        }
        let lyrics = LyricsResponse::from_text("[00:01.00]Example", "Spotify", "Spotify");
        assert!(with_metadata(&lyrics, "Track", "Artist").contains("via Paxsenix API"));
    }

    #[test]
    fn zero_placeholders_are_plain_lyrics_without_losing_source_or_text() {
        let raw = "[ti:Example]\n[by:Example app (source: extension:example)]\n\n[00:00.00]First line\n[00:00.00]Second line\n[01:00.00]";
        let lyrics = LyricsResponse::from_text(raw, "Example", "extension:example");
        assert_eq!(lyrics.sync_type, "UNSYNCED");
        assert_eq!(lyrics.plain_lyrics, "First line\nSecond line");
        assert_eq!(lyrics.lines().last().unwrap().end_time_ms, 5000);
        let saved = with_metadata(&lyrics, "Example", "Example artist");
        assert!(!saved.contains("[00:"));
        assert!(saved.ends_with("First line\nSecond line\n"));
        assert_eq!(extract_source(&saved), "extension:example");
    }

    #[test]
    fn writer_validates_provider_flags_and_ignores_synthetic_end_times() {
        let mut lyrics = LyricsResponse::from_text(
            "[00:00.00]<00:00.00>First <00:00.00>line<00:00.00>",
            "Example",
            "extension:example",
        );
        assert_eq!(lyrics.plain_lyrics, "First line");
        lyrics.sync_type = "LINE_SYNCED".into();
        assert!(!lyrics.is_synced());
        let saved = with_metadata(&lyrics, "Example", "Example artist");
        assert!(saved.ends_with("First line\n"));
        assert!(!saved.contains("00:00"));
        lyrics.normalize_timing();
        assert_eq!(lyrics.sync_type, "UNSYNCED");
    }

    #[test]
    fn genuine_zero_start_retains_line_and_word_timing() {
        for raw in [
            "[00:00.00]First line\n[00:02.00]Second line",
            "[00:00.00]<00:00.00>First <00:01.00>line<00:02.00>",
        ] {
            let lyrics = LyricsResponse::from_text(raw, "Example", "extension:example");
            assert!(lyrics.is_synced());
            let saved = with_metadata(&lyrics, "Example", "Example artist");
            assert!(saved.contains("[00:00.00]"));
            if raw.contains('<') {
                assert!(saved.contains("<00:01.00>"));
            }
        }
    }

    #[test]
    fn word_timing_needs_a_timestamp_that_starts_text() {
        let word = LyricsResponse::from_text(
            "[00:01.00]v1:<00:01.00>First <00:01.50>line<00:02.00>",
            "Example",
            "Example",
        );
        assert!(word.is_word_synced());
        // A closing timestamp after the text only ends the line.
        let line =
            LyricsResponse::from_text("[00:01.00]First line<00:02.00>", "Example", "Example");
        assert!(line.is_synced());
        assert!(!line.is_word_synced());
        // Word timestamps without line timestamps are plain lyrics.
        let plain =
            LyricsResponse::from_text("<00:01.00>First <00:01.50>line", "Example", "Example");
        assert!(!plain.is_synced());
        assert!(!plain.is_word_synced());
    }

    #[test]
    fn timed_writer_credit_is_not_lyric_timing() {
        let lyrics = LyricsResponse::from_text(
            "[00:00.00]First line\n[00:03.00]Written by: Example Writer",
            "Example",
            "extension:example",
        );
        assert_eq!(lyrics.sync_type, "UNSYNCED");
        assert!(!with_metadata(&lyrics, "Example", "Example artist").contains("[00:"));
    }

    #[test]
    fn invalid_sync_flag_preserves_a_plain_text_fallback() {
        let mut lyrics = LyricsResponse {
            sync_type: "LINE_SYNCED".into(),
            plain_lyrics: "First line\nSecond line".into(),
            ..LyricsResponse::default()
        };
        lyrics.normalize_timing();
        assert_eq!(lyrics.sync_type, "UNSYNCED");
        assert_eq!(lyrics.plain_lyrics, "First line\nSecond line");
    }

    #[test]
    fn optional_timings_cannot_promote_plain_lyrics_to_synced() {
        let mut lyrics = LyricsResponse::from_text("[00:00.00]First line", "Example", "Example");
        let line = &mut lyrics.lines.as_mut().unwrap()[0];
        line.romanization = Some("Reading".into());
        line.romanization_words = Some(vec![super::super::LyricsWord {
            start_time_ms: 1000,
            end_time_ms: 2000,
            text: "Reading".into(),
        }]);
        lyrics.sync_type = "LINE_SYNCED".into();
        assert!(!lyrics.is_synced());
        assert!(!with_metadata(&lyrics, "Example", "Example artist").contains("x-romaji"));
        lyrics.lines.as_mut().unwrap()[0].start_time_ms = 1000;
        lyrics.sync_type = "UNSYNCED".into();
        assert!(!lyrics.is_synced());
    }

    #[test]
    fn usability_matches_the_app_and_native_finalizer() {
        let cases = include_str!(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../../android/app/src/test/resources/lyrics_usability_cases.tsv"
        ));
        for line in cases
            .lines()
            .filter(|line| !line.is_empty() && !line.starts_with('#'))
        {
            let fields: Vec<_> = line.splitn(3, '\t').collect();
            let raw = fields[2]
                .replace("\\n", "\n")
                .replace("\\r", "\r")
                .replace("\\t", "\t");
            assert_eq!(
                has_usable_content(&raw),
                fields[1] == "true",
                "{}",
                fields[0]
            );
        }
    }

    #[test]
    fn writing_timestamps_never_discards_milliseconds() {
        for time in [0, 1000, 1009, 12345, 59999, 60000, 3599999] {
            let raw = format!("{}Original", timestamp(time));
            assert_eq!(parse_synced(&raw).unwrap()[0].start_time_ms, time);
        }
        assert_eq!(timestamp_inline(1000), "00:01.00");
        assert_eq!(timestamp_inline(1009), "00:01.009");
    }

    #[test]
    fn optional_text_is_safe_metadata_not_lyric_content() {
        let raw = "[x-romaji:1000:YQ==]\n[x-translation:1000:Yg==]";
        assert!(!has_usable_content(raw));
        let raw = "[x-romanized:1000:a ]b]\n[x-translated:1000:<00:01.00>c]";
        assert!(!has_usable_content(raw));
        let mut lyrics =
            LyricsResponse::from_text("[00:01.009]Original", "Apple Music", "Apple Music");
        lyrics.lines.as_mut().unwrap()[0].translation = Some("Text ]\nnext \\ line 日本語".into());
        let lrc = with_metadata(&lyrics, "Track", "Artist");
        assert!(lrc.contains("[x-translated:1009:Text ]\\nnext \\\\ line 日本語]"));
        assert!(lrc.contains("[00:01.009]Original"));
        assert!(has_usable_content(&lrc));
    }

    #[test]
    fn word_timing_is_written_as_enhanced_lrc() {
        let word = |text: &str, start_time_ms, end_time_ms| LyricsWord {
            text: text.into(),
            start_time_ms,
            end_time_ms,
        };
        let words = [
            word("Ro ", 1000, 1200),
            word("<ma>", 1200, 1500),
            word("ji", 1609, 2000),
        ];
        assert_eq!(
            supplement_words(&words).as_deref(),
            Some("<00:01.00>Ro <00:01.20>\\<ma><00:01.50><00:01.609>ji<00:02.00>")
        );
        assert_eq!(supplement_words(&[word("a", 2000, 1000)]), None);
        assert_eq!(supplement_words(&[word(" ", 0, 1000)]), None);
        assert_eq!(supplement_words(&[]), None);
    }
}
