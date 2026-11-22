import 'dart:convert';

import 'package:mornye/utils/lyrics_draft.dart' show formatLyricsTime;
import 'package:mornye/utils/lyrics_parser.dart' show LyricWord;

/// The translation and pronunciation tags an LRC line carries, written as
/// readable text in ID tag form, so other players skip them:
///
/// ```
/// [00:12.34]僕らは
/// [x-romanized:12340:bokura wa]
/// [x-translated-words:12340:<00:12.34>We <00:12.60>are<00:13.00>]
/// [x-translated:12340:We are]
/// ```
///
/// - The key is the line's time in milliseconds, or its index from 0 in
///   lyrics without timing.
/// - A value runs to the row's last `]`. `\n` is a line break and `\\` a
///   backslash; in word timing `\<` is a `<`.
/// - Word timing is enhanced LRC in absolute time: each word follows its
///   start, a word ends where the next starts, and a time with no word after
///   it ends the word before it.
///
/// Earlier versions wrote `x-romaji`, `x-romaji-words`, `x-translation` and
/// `x-translation-words` with base64 values, word timing as base64 JSON;
/// they are still read.
///
/// Kinds are named `romaji`, `romaji-words`, `translation` and
/// `translation-words` in code, whichever way the file spells them.
const _tagNames = {
  'romaji': 'romanized',
  'romaji-words': 'romanized-words',
  'translation': 'translated',
  'translation-words': 'translated-words',
};
const _kindsByTag = {
  'romanized': 'romaji',
  'romanized-words': 'romaji-words',
  'translated': 'translation',
  'translated-words': 'translation-words',
};

final _row = RegExp(
  r'^\[x-(romanized-words|romanized|translated-words|translated|romaji-words|romaji|translation-words|translation):(\d+):(.*)\]$',
  caseSensitive: false,
);
final _wordTime = RegExp(r'<(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?>');

/// A translation or pronunciation tag read from a row.
typedef LyricSupplementTag = ({
  String kind,
  int? key,

  /// The text of a `romaji` or `translation` tag, trimmed; null when it
  /// cannot be read.
  String? text,

  /// The timing of a `-words` tag; empty when it cannot be read.
  List<LyricWord> words,
});

/// The tag [row] holds, or null when it is no translation or pronunciation
/// tag.
LyricSupplementTag? readLyricSupplementTag(String row) {
  final match = _row.firstMatch(row);
  if (match == null) return null;
  final written = match.group(1)!.toLowerCase();
  final legacy = !_kindsByTag.containsKey(written);
  final kind = _kindsByTag[written] ?? written;
  final key = int.tryParse(match.group(2)!);
  final value = match.group(3)!;
  if (kind.endsWith('-words')) {
    return (
      kind: kind,
      key: key,
      text: null,
      words: legacy ? _legacyWords(value) : decodeLyricWordsTag(value),
    );
  }
  String? text;
  if (legacy) {
    try {
      text = utf8.decode(base64.decode(value)).trim();
    } on FormatException {
      // Optional damaged metadata must not hide the lyrics.
    }
  } else {
    text = _unescape(value).trim();
  }
  return (kind: kind, key: key, text: text, words: const []);
}

/// The row that writes [payload], a value from [encodeLyricTextTag] or
/// [encodeLyricWordsTag], as a [kind] tag under [key].
String lyricSupplementRow(String kind, int key, String payload) =>
    '[x-${_tagNames[kind] ?? kind}:$key:$payload]';

/// [text] as a tag value.
String encodeLyricTextTag(String text) => _escape(text, words: false);

/// [words] as a `-words` tag value. Empty when a word cannot be given a
/// valid time range.
String encodeLyricWordsTag(List<LyricWord> words) {
  final out = StringBuffer();
  int? lastStart;
  int? lastEnd;
  for (var i = 0; i < words.length; i++) {
    final word = words[i];
    final start = word.time.inMilliseconds;
    final end =
        word.end?.inMilliseconds ??
        (i + 1 < words.length ? words[i + 1].time.inMilliseconds : start);
    if (word.text.trim().isEmpty ||
        start < 0 ||
        end < start ||
        (lastStart != null && lastStart > start)) {
      return '';
    }
    if (lastEnd != null && lastEnd != start) out.write(_time(lastEnd));
    out
      ..write(_time(start))
      ..write(_escape(word.text, words: true));
    lastStart = start;
    lastEnd = end;
  }
  if (lastEnd != null) out.write(_time(lastEnd));
  return out.toString();
}

/// The words a `-words` tag value times, or empty when it is damaged.
List<LyricWord> decodeLyricWordsTag(String value) {
  final segments = <(int, StringBuffer)>[];
  final leading = StringBuffer();
  var i = 0;
  while (i < value.length) {
    final text = segments.isEmpty ? leading : segments.last.$2;
    final char = value[i];
    if (char == r'\' && i + 1 < value.length) {
      text.write(_unescaped(value[i + 1]));
      i += 2;
      continue;
    }
    final time = char == '<' ? _wordTime.matchAsPrefix(value, i) : null;
    if (time != null) {
      segments.add((_milliseconds(time), StringBuffer()));
      i = time.end;
      continue;
    }
    text.write(char);
    i++;
  }
  if (leading.isNotEmpty) return const [];
  final words = <(int, int?, String)>[];
  for (final (time, buffer) in segments) {
    final text = buffer.toString();
    if (text.isEmpty) {
      // A time with no word after it ends the word before it.
      if (words.isEmpty || words.last.$2 != null) return const [];
      words.last = (words.last.$1, time, words.last.$3);
      continue;
    }
    if (text.trim().isEmpty) return const [];
    if (words.isNotEmpty) {
      final (start, end, previous) = words.last;
      if (start > time) return const [];
      words.last = (start, end ?? time, previous);
    }
    words.add((time, null, text));
  }
  final timed = <LyricWord>[];
  for (final (start, end, text) in words) {
    if (end != null && end < start) return const [];
    timed.add(
      LyricWord(
        time: Duration(milliseconds: start),
        end: Duration(milliseconds: end ?? start),
        text: text,
      ),
    );
  }
  return timed;
}

/// Base64 JSON word timing, as earlier versions wrote it.
List<LyricWord> _legacyWords(String value) {
  try {
    final decoded = jsonDecode(utf8.decode(base64.decode(value)).trim());
    if (decoded is! List) return const [];
    final words = <LyricWord>[];
    for (final item in decoded) {
      if (item case {
        'text': final String text,
        'startTimeMs': final int start,
        'endTimeMs': final int end,
      }) {
        if (text.trim().isEmpty ||
            start < 0 ||
            end < start ||
            (words.isNotEmpty && words.last.time.inMilliseconds > start)) {
          return const [];
        }
        words.add(
          LyricWord(
            time: Duration(milliseconds: start),
            end: Duration(milliseconds: end),
            text: text,
          ),
        );
      } else {
        return const [];
      }
    }
    return words;
  } on FormatException {
    return const [];
  }
}

String _time(int ms) => '<${formatLyricsTime(Duration(milliseconds: ms))}>';

int _milliseconds(Match time) {
  final fraction = time.group(3) ?? '0';
  final ms = switch (fraction.length) {
    1 => int.parse(fraction) * 100,
    2 => int.parse(fraction) * 10,
    _ => int.parse(fraction),
  };
  return (int.parse(time.group(1)!) * 60 + int.parse(time.group(2)!)) * 1000 +
      ms;
}

String _escape(String text, {required bool words}) {
  final out = StringBuffer();
  final lines = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  for (final char in lines.split('')) {
    out.write(switch (char) {
      r'\' => r'\\',
      '\n' => r'\n',
      '<' when words => r'\<',
      _ => char,
    });
  }
  return out.toString();
}

String _unescape(String value) {
  final out = StringBuffer();
  var i = 0;
  while (i < value.length) {
    if (value[i] == r'\' && i + 1 < value.length) {
      out.write(_unescaped(value[i + 1]));
      i += 2;
    } else {
      out.write(value[i]);
      i++;
    }
  }
  return out.toString();
}

String _unescaped(String char) => switch (char) {
  'n' => '\n',
  r'\' || '<' => char,
  _ => '\\$char',
};
