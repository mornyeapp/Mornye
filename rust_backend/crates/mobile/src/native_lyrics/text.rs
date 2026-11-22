use super::{Line, Voice, Word};
use base64::Engine;
use regex::{Captures, Regex};
use serde_json::Value;
use std::{
    collections::{HashMap, HashSet},
    sync::LazyLock,
};

pub(super) const WS: &str = r"[\t\n\v\f\r \u{00a0}\u{1680}\u{2000}-\u{200a}\u{2028}\u{2029}\u{202f}\u{205f}\u{3000}\u{feff}]";
pub(super) static LINE_TIME: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"\[([0-9]{1,3}):([0-9]{1,2})(?:[.:]([0-9]{1,3}))?\]").unwrap());
pub(super) static WORD_TIME: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"<([0-9]{1,3}):([0-9]{1,2})(?:[.:]([0-9]{1,3}))?>").unwrap());
pub(super) static WHITE_SPACE: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(&format!("{WS}+")).unwrap());
static VOICE_PREFIX: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(&format!(r"(?i)^({WS}*(?:<[0-9]{{1,3}}:[0-9]{{1,2}}(?:[.:][0-9]{{1,3}})?>{WS}*)*)(v[1-9][0-9]*):[ \t]*")).unwrap()
});

pub(super) use crate::native_library::path_keys::{
    dart_trim as trim, dart_whitespace as whitespace,
};
pub(super) fn trim_end(s: &str) -> &str {
    s.trim_end_matches(whitespace)
}
pub(super) fn parse_int(s: &str) -> Option<i64> {
    let s = trim(s);
    let (negative, rest) = if let Some(s) = s.strip_prefix('-') {
        (true, s)
    } else {
        (false, s.strip_prefix('+').unwrap_or(s))
    };
    let unsigned = if rest.starts_with("0x") || rest.starts_with("0X") {
        i64::from_str_radix(&rest[2..], 16).ok()?
    } else {
        rest.parse::<i64>().ok()?
    };
    if negative {
        unsigned.checked_neg()
    } else {
        Some(unsigned)
    }
}
pub(super) fn looks_ttml(s: &str) -> bool {
    let head = s.trim_start_matches(whitespace);
    head.starts_with("<?xml")
        || head.starts_with("<tt")
        || head.contains("<tt ")
        || head.contains("http://www.w3.org/ns/ttml")
}
pub(super) fn duration(c: &Captures<'_>) -> i64 {
    let fraction = c
        .get(3)
        .map(|v| {
            format!("{v:0<3}", v = v.as_str())[..3]
                .parse::<i64>()
                .unwrap_or(0)
        })
        .unwrap_or(0);
    parse_int(&c[1]).unwrap_or(0) * 60_000 + parse_int(&c[2]).unwrap_or(0) * 1000 + fraction
}
pub(super) fn vocal_text(content: &str) -> (String, Option<Voice>) {
    let Some(c) = VOICE_PREFIX.captures(content) else {
        return (content.into(), None);
    };
    let id = c[2].to_ascii_lowercase();
    let voice = Voice {
        index: parse_int(&id[1..]).unwrap_or(1) - 1,
        is_group: id == "v3",
        id,
    };
    (
        format!(
            "{}{}",
            WHITE_SPACE.replace_all(&c[1], ""),
            &content[c.get(0).unwrap().end()..]
        ),
        Some(voice),
    )
}
pub(super) fn parse_words(content: &str) -> Vec<Word> {
    let matches: Vec<_> = WORD_TIME.captures_iter(content).collect();
    let mut words: Vec<Word> = Vec::new();
    for (i, c) in matches.iter().enumerate() {
        let time_ms = duration(c);
        let start = c.get(0).unwrap().end();
        let end = matches
            .get(i + 1)
            .map(|c| c.get(0).unwrap().start())
            .unwrap_or(content.len());
        let text = &content[start..end];
        if trim(text).is_empty() {
            if let Some(previous) = words.last_mut() {
                // A closing timestamp can come before the space between words.
                previous.text.push_str(text);
                if previous.end_ms.is_none() && time_ms >= previous.time_ms {
                    previous.end_ms = Some(time_ms);
                }
            }
        } else {
            words.push(Word {
                time_ms,
                end_ms: None,
                text: text.into(),
            });
        }
    }
    words
}
pub(super) fn decode_supplement(encoded: &str) -> Option<String> {
    // Base64Decoder accepts URL-safe characters and %3D padding, but does
    // not synthesize missing padding or decode other percent escapes.
    let mut normalized = String::new();
    let bytes = encoded.as_bytes();
    let mut index = 0;
    while index < bytes.len() {
        let byte = if bytes[index] == b'%' {
            let value = u8::from_str_radix(
                std::str::from_utf8(bytes.get(index + 1..index + 3)?).ok()?,
                16,
            )
            .ok()?;
            if value != b'=' {
                return None;
            }
            index += 3;
            value
        } else {
            let value = bytes[index];
            index += 1;
            value
        };
        normalized.push(match byte {
            b'-' => '+',
            b'_' => '/',
            _ => char::from(byte),
        });
    }
    let bytes = base64::engine::general_purpose::STANDARD
        .decode(normalized)
        .ok()?;
    Some(trim(&String::from_utf8(bytes).ok()?).into())
}
/// A readable tag value: `\n` is a line break, `\\` a backslash and `\<` a
/// `<`. Mirrors lib/utils/lyric_supplement_tags.dart.
pub(super) fn unescape_supplement(value: &str) -> String {
    let mut out = String::new();
    let mut chars = value.chars().peekable();
    while let Some(c) = chars.next() {
        match (c, chars.peek()) {
            ('\\', Some(&next)) => {
                chars.next();
                push_unescaped(&mut out, next);
            }
            _ => out.push(c),
        }
    }
    out
}
fn push_unescaped(out: &mut String, next: char) {
    match next {
        'n' => out.push('\n'),
        '\\' | '<' => out.push(next),
        _ => {
            out.push('\\');
            out.push(next);
        }
    }
}
/// Readable word timing: each word follows its start, a word ends where the
/// next starts, and a time with no word after it ends the word before it.
pub(super) fn supplement_words(value: &str) -> Vec<Word> {
    let mut leading = String::new();
    let mut segments: Vec<(i64, String)> = Vec::new();
    let mut i = 0;
    while let Some(c) = value[i..].chars().next() {
        let text = match segments.last_mut() {
            Some((_, text)) => text,
            None => &mut leading,
        };
        if c == '\\'
            && let Some(next) = value[i + 1..].chars().next()
        {
            push_unescaped(text, next);
            i += 1 + next.len_utf8();
            continue;
        }
        if c == '<'
            && let Some(time) = WORD_TIME
                .captures_at(value, i)
                .filter(|time| time.get(0).unwrap().start() == i)
        {
            i = time.get(0).unwrap().end();
            segments.push((duration(&time), String::new()));
            continue;
        }
        text.push(c);
        i += c.len_utf8();
    }
    if !leading.is_empty() {
        return vec![];
    }
    let mut words: Vec<Word> = Vec::new();
    for (time, text) in segments {
        if text.is_empty() {
            match words.last_mut() {
                Some(word) if word.end_ms.is_none() => word.end_ms = Some(time),
                _ => return vec![],
            }
            continue;
        }
        if trim(&text).is_empty() {
            return vec![];
        }
        if let Some(previous) = words.last_mut() {
            if previous.time_ms > time {
                return vec![];
            }
            previous.end_ms.get_or_insert(time);
        }
        words.push(Word {
            time_ms: time,
            end_ms: None,
            text,
        });
    }
    for word in &mut words {
        if *word.end_ms.get_or_insert(word.time_ms) < word.time_ms {
            return vec![];
        }
    }
    words
}
pub(super) fn romanization_words(raw: &str) -> Vec<Word> {
    let Ok(Value::Array(values)) = serde_json::from_str::<Value>(raw) else {
        return vec![];
    };
    let mut words: Vec<Word> = Vec::new();
    for value in values {
        let (Some(text), Some(start), Some(end)) = (
            value["text"].as_str(),
            value["startTimeMs"].as_i64(),
            value["endTimeMs"].as_i64(),
        ) else {
            return vec![];
        };
        if trim(text).is_empty()
            || start < 0
            || end < start
            || words.last().is_some_and(|w| w.time_ms > start)
        {
            return vec![];
        }
        words.push(Word {
            time_ms: start,
            end_ms: Some(end),
            text: text.into(),
        });
    }
    words
}
pub(super) struct Supplements<T> {
    entries: Vec<(i64, T)>,
    seen: HashSet<i64>,
}
impl<T> Supplements<T> {
    pub(super) fn new() -> Self {
        Self {
            entries: Vec::new(),
            seen: HashSet::new(),
        }
    }
}
pub(super) fn insert_first<T>(supplements: &mut Supplements<T>, time: i64, value: T) {
    if supplements.seen.insert(time) {
        supplements.entries.push((time, value));
    }
}
pub(super) fn align<T: Clone>(lines: &[Line], supplements: Supplements<T>) -> HashMap<i64, T> {
    let mut matched: HashMap<i64, (i64, T)> = HashMap::new();
    for (time, value) in supplements.entries {
        let lo = lines.partition_point(|line| line.time_ms < time);
        let mut nearest = None;
        let mut distance = 11;
        for index in [lo.checked_sub(1), Some(lo)].into_iter().flatten() {
            let Some(line) = lines.get(index) else {
                continue;
            };
            let delta = line.time_ms.abs_diff(time);
            if delta < distance as u64 {
                nearest = Some(line.time_ms);
                distance = delta as i64;
            }
        }
        if let Some(nearest) = nearest
            && matched.get(&nearest).is_none_or(|(old, _)| distance < *old)
        {
            matched.insert(nearest, (distance, value));
        }
    }
    matched
        .into_iter()
        .map(|(key, (_, value))| (key, value))
        .collect()
}
pub(super) fn shift(time: i64, offset: i64) -> i64 {
    time.saturating_sub(offset).max(0)
}
pub(super) fn shift_words(words: &mut [Word], offset: i64) {
    if offset == 0 {
        return;
    }
    for word in words {
        word.time_ms = shift(word.time_ms, offset);
        word.end_ms = word.end_ms.map(|time| shift(time, offset));
    }
}
