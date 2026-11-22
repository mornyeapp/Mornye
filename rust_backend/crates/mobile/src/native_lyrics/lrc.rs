use super::text::{
    LINE_TIME, Supplements, WORD_TIME, align, decode_supplement, duration, insert_first, parse_int,
    parse_words, romanization_words, shift, shift_words, supplement_words, trim, trim_end,
    unescape_supplement, vocal_text,
};
use super::{Line, Parsed, Word, has_usable_timing};
use regex::Regex;
use std::sync::LazyLock;

static BACKGROUND: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"(?i)^\[bg:(.*)\]$").unwrap());
static ID_TAG: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"(?i)^\[(ti|ar|al|by|offset|length|re|ve|tool|au|la|encoder|instrumental|x-[a-z0-9_-]+):.*\]$").unwrap()
});
static SUPPLEMENT: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"(?i)^\[x-(romanized-words|romanized|translated-words|translated|romaji-words|romaji|translation-words|translation):([0-9]+):(.*)\]$")
        .unwrap()
});
static NEW_LINE: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"\r\n|\r|\n").unwrap());

pub(super) fn parse_lrc(
    text: &str,
    check: &dyn Fn() -> Result<(), String>,
) -> Result<Parsed, String> {
    let mut parsed: Vec<Line> = Vec::new();
    let mut plain = Vec::new();
    let (mut romaji, mut romaji_words, mut translation, mut translation_words) = (
        Supplements::new(),
        Supplements::new(),
        Supplements::new(),
        Supplements::new(),
    );
    let (mut saw_timestamp, mut saw_words, mut offset) = (false, false, 0);
    for raw in NEW_LINE.split(text) {
        check()?;
        let mut line = trim_end(raw);
        if trim(line).is_empty() {
            continue;
        }
        let background = BACKGROUND.captures(trim(line));
        if let Some(ref c) = background {
            line = trim(c.get(1).unwrap().as_str());
        }
        if let Some(c) = SUPPLEMENT.captures(trim(line)) {
            // Earlier versions wrote base64 under the old names.
            let written = c[1].to_ascii_lowercase();
            let (kind, readable) = match written.as_str() {
                "romanized" => ("romaji", true),
                "romanized-words" => ("romaji-words", true),
                "translated" => ("translation", true),
                "translated-words" => ("translation-words", true),
                legacy => (legacy, false),
            };
            if let Some(time) = parse_int(&c[2]) {
                if kind.ends_with("-words") {
                    let words = if readable {
                        supplement_words(&c[3])
                    } else {
                        decode_supplement(&c[3])
                            .filter(|value| !value.is_empty())
                            .map(|value| romanization_words(&value))
                            .unwrap_or_default()
                    };
                    if !words.is_empty() {
                        let target = if kind == "romaji-words" {
                            &mut romaji_words
                        } else {
                            &mut translation_words
                        };
                        insert_first(target, time, words);
                    }
                } else {
                    let value = if readable {
                        Some(trim(&unescape_supplement(&c[3])).to_string())
                    } else {
                        decode_supplement(&c[3])
                    };
                    if let Some(value) = value.filter(|value| !value.is_empty()) {
                        let target = if kind == "romaji" {
                            &mut romaji
                        } else {
                            &mut translation
                        };
                        insert_first(target, time, value);
                    }
                }
            }
            continue;
        }
        if let Some(c) = ID_TAG.captures(trim(line)) {
            if c[1].eq_ignore_ascii_case("offset") {
                offset =
                    parse_int(&line[line.find(':').unwrap() + 1..].replace(']', "")).unwrap_or(0);
            }
            continue;
        }
        let times: Vec<_> = LINE_TIME.captures_iter(line).collect();
        if times.is_empty() {
            let (content, voice) = vocal_text(trim(line));
            let clean = trim(&WORD_TIME.replace_all(&content, "")).to_string();
            plain.push(clean.clone());
            if background.is_some() && !parsed.is_empty() && !clean.is_empty() {
                let words = parse_words(&content);
                let previous = parsed.last().unwrap();
                let time = words.first().map(|w| w.time_ms).unwrap_or(previous.time_ms);
                let end = words.last().and_then(|w| w.end_ms).or(previous.end_ms);
                let voice = voice.or_else(|| previous.voice.clone());
                saw_words |= !words.is_empty();
                parsed.push(Line::new(
                    time,
                    end,
                    clean,
                    words,
                    voice,
                    true,
                    previous.vocal_group,
                ));
            }
            continue;
        }
        saw_timestamp = true;
        let (content, voice) =
            vocal_text(trim(&line[times.last().unwrap().get(0).unwrap().end()..]));
        let words = parse_words(&content);
        saw_words |= !words.is_empty();
        let clean = trim(&WORD_TIME.replace_all(&content, "")).to_string();
        plain.push(clean.clone());
        for time in times {
            let background = background.is_some();
            let previous = parsed.last();
            let line_voice = voice.clone().or_else(|| {
                if background {
                    previous.and_then(|line| line.voice.clone())
                } else {
                    None
                }
            });
            let group = if background {
                previous.and_then(|line| line.vocal_group)
            } else {
                Some(parsed.len() as i64)
            };
            parsed.push(Line::new(
                duration(&time),
                words.last().and_then(|w| w.end_ms),
                clean.clone(),
                words.clone(),
                line_voice,
                background,
                group,
            ));
        }
    }
    let plain_text = plain
        .into_iter()
        .filter(|line| !line.is_empty())
        .collect::<Vec<_>>()
        .join("\n");
    if !saw_timestamp {
        return Ok(Parsed {
            plain_text,
            ..Parsed::default()
        });
    }
    // All-zero provider placeholders are plain lyrics. Validate before offsets
    // so a negative offset cannot turn them into apparently useful timing.
    let synced = has_usable_timing(&parsed);
    parsed.sort_by_key(|line| line.time_ms);
    if synced {
        pair_translations(&mut parsed);
    }
    let romaji = align(&parsed, romaji);
    let romaji_words = align(&parsed, romaji_words);
    let translation = align(&parsed, translation);
    let translation_words = align(&parsed, translation_words);
    // Keep readable text when optional timings are incomplete or belong to a
    // different revision of the text they time.
    let spelled = |text: &Option<String>, words: Option<&Vec<Word>>| {
        words
            .filter(|words| {
                text.as_deref()
                    == Some(
                        words
                            .iter()
                            .map(|w| w.text.as_str())
                            .collect::<String>()
                            .as_str(),
                    )
            })
            .cloned()
            .unwrap_or_default()
    };
    if offset != 0 || !romaji.is_empty() || !translation.is_empty() {
        for line in &mut parsed {
            check()?;
            line.romanization = romaji.get(&line.time_ms).cloned();
            line.romanization_words = spelled(&line.romanization, romaji_words.get(&line.time_ms));
            line.translation = translation
                .get(&line.time_ms)
                .cloned()
                .or_else(|| line.translation.take());
            line.translation_words =
                spelled(&line.translation, translation_words.get(&line.time_ms));
            line.time_ms = shift(line.time_ms, offset);
            line.end_ms = line.end_ms.map(|time| shift(time, offset));
            shift_words(&mut line.words, offset);
            shift_words(&mut line.romanization_words, offset);
            shift_words(&mut line.translation_words, offset);
        }
    }
    Ok(Parsed {
        synced,
        word_synced: synced && saw_words,
        lines: parsed,
        plain_text,
        ..Parsed::default()
    })
}

/// Bilingual LRC files time each translation like the line it translates:
/// the original, then its translation, under one timestamp. Lines are read
/// so only when most moments of the song are such a pair, so occasional
/// simultaneous singers stay separate lines. Mirrors the Dart parser.
fn pair_translations(lines: &mut Vec<Line>) {
    let sung = |line: &Line| !line.is_background && !line.text.is_empty();
    // Each run of lines sharing a timestamp, as its length and whether it is
    // an original followed by its translation.
    let mut runs = Vec::new();
    let (mut moments, mut pairs) = (0, 0);
    let mut start = 0;
    while start < lines.len() {
        let rest = &lines[start..];
        let len = rest
            .iter()
            .take_while(|line| line.time_ms == rest[0].time_ms)
            .count();
        let run = &rest[..len];
        let pair = len == 2
            && sung(&run[0])
            && sung(&run[1])
            && run[1]
                .voice
                .as_ref()
                .is_none_or(|voice| run[0].voice.as_ref() == Some(voice));
        moments += usize::from(run.iter().any(sung));
        pairs += usize::from(pair);
        runs.push((len, pair));
        start += len;
    }
    if pairs < 2 || pairs * 2 <= moments {
        return;
    }
    let mut source = std::mem::take(lines).into_iter();
    for (len, pair) in runs {
        if !pair {
            lines.extend(source.by_ref().take(len));
            continue;
        }
        let (mut line, translation) = (source.next().unwrap(), source.next().unwrap());
        // A repeated line is the same words twice, not a translation.
        if translation.text != line.text {
            line.translation = Some(translation.text);
        }
        lines.push(line);
    }
}
