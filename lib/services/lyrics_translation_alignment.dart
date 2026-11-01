import 'package:mornye/utils/lyrics_parser.dart';

/// A translated phrase tied to a zero-based unit of the original text.
/// No absolute timestamps are cached or sent to another device.
class LyricsTranslationChunk {
  const LyricsTranslationChunk(this.text, this.source);

  final String text;
  final int source;

  Map<String, Object> toJson() => {'text': text, 'source': source};
}

final _spaces = RegExp(r'\s+');
final _sourceUnits = RegExp(
  r'[\p{Script=Han}\p{Script=Hiragana}\p{Script=Katakana}]|'
  r'[^\s\p{Script=Han}\p{Script=Hiragana}\p{Script=Katakana}]+',
  unicode: true,
);

/// Stable across repeats, syllable segmentation and timing offsets.
List<String> lyricsTranslationUnits(String text) {
  final units = _sourceUnits
      .allMatches(text)
      .take(513)
      .map((match) => match[0]!)
      .toList();
  return units.length <= 512 ? List.unmodifiable(units) : const [];
}

/// Invalid alignment never discards an otherwise usable translated line.
List<LyricsTranslationChunk>? readLyricsTranslationChunks(
  Object? value,
  String text, {
  int sourceCount = 512,
}) {
  if (value == null) return const [];
  if (value is! List || value.length > 256) return null;
  final chunks = <LyricsTranslationChunk>[];
  var previous = 0;
  var length = 0;
  for (final entry in value) {
    final Object? part;
    final Object? source;
    if (entry is List && entry.length == 2) {
      source = entry[0];
      part = entry[1];
    } else if (entry is Map) {
      part = entry['text'];
      source = entry['source'];
    } else {
      return null;
    }
    if (part is! String ||
        part.isEmpty ||
        source is! int ||
        source < previous ||
        source >= sourceCount) {
      return null;
    }
    length += part.length;
    if (length > 4000) return null;
    chunks.add(LyricsTranslationChunk(part, source));
    previous = source;
  }
  if (chunks.isNotEmpty && chunks.map((chunk) => chunk.text).join() != text) {
    return null;
  }
  return List.unmodifiable(chunks);
}

List<List<LyricsTranslationChunk>>? readLyricsTranslationAlignments(
  Object? value,
  List<String?> texts,
) {
  if (value == null) return const [];
  if (value is! List || value.length != texts.length || value.length > 2000) {
    return null;
  }
  final result = <List<LyricsTranslationChunk>>[];
  for (var i = 0; i < value.length; i++) {
    final chunks = readLyricsTranslationChunks(value[i], texts[i] ?? '');
    if (chunks == null) return null;
    result.add(chunks);
  }
  return List.unmodifiable(result);
}

/// Projects stable text units onto this occurrence's sung syllables/words.
/// A mismatched file or unavailable end time falls back to line sync.
List<LyricWord> timedLyricsTranslation(
  LyricLine line,
  List<String> units,
  List<LyricsTranslationChunk> chunks, {
  Duration? nextLine,
}) {
  if (line.words.isEmpty || units.isEmpty || chunks.isEmpty) return const [];
  final sourceText = units.join();
  final parts = <({int start, int end, Duration time, Duration until})>[];
  final joined = StringBuffer();
  var previousTime = Duration.zero;
  for (var i = 0; i < line.words.length; i++) {
    final word = line.words[i];
    final text = word.text.replaceAll(_spaces, '');
    if (text.isEmpty) continue;
    final end =
        word.end ??
        (i + 1 < line.words.length ? line.words[i + 1].time : null) ??
        line.end ??
        nextLine;
    if (end == null || end < word.time || word.time < previousTime) {
      return const [];
    }
    parts.add((
      start: joined.length,
      end: joined.length + text.length,
      time: word.time,
      until: end,
    ));
    joined.write(text);
    previousTime = word.time;
  }
  if (joined.toString() != sourceText || parts.isEmpty) return const [];
  final starts = <Duration>[];
  final ends = <Duration>[];
  var offset = 0;
  var partIndex = 0;
  for (final unit in units) {
    while (partIndex < parts.length - 1 && parts[partIndex].end <= offset) {
      partIndex++;
    }
    final part = parts[partIndex];
    final fraction = (offset - part.start) / (part.end - part.start);
    starts.add(
      part.time +
          Duration(
            microseconds: ((part.until - part.time).inMicroseconds * fraction)
                .round(),
          ),
    );
    offset += unit.length;
    var endPartIndex = partIndex;
    while (endPartIndex < parts.length - 1 &&
        parts[endPartIndex].end < offset) {
      endPartIndex++;
    }
    final endPart = parts[endPartIndex];
    final endFraction =
        (offset - endPart.start) / (endPart.end - endPart.start);
    ends.add(
      endPart.time +
          Duration(
            microseconds:
                ((endPart.until - endPart.time).inMicroseconds * endFraction)
                    .round(),
          ),
    );
  }
  final result = <LyricWord>[];
  var index = 0;
  while (index < chunks.length) {
    final source = chunks[index].source;
    if (source < 0 || source >= starts.length) return const [];
    var endIndex = index + 1;
    while (endIndex < chunks.length && chunks[endIndex].source == source) {
      endIndex++;
    }
    final nextSource = endIndex < chunks.length
        ? chunks[endIndex].source
        : null;
    if (nextSource != null &&
        (nextSource <= source || nextSource >= starts.length)) {
      return const [];
    }
    final start = starts[source];
    var end = nextSource == null ? ends.last : ends[nextSource - 1];
    if (nextSource != null && end > starts[nextSource]) {
      end = starts[nextSource];
    }
    if (end <= start) return const [];
    final count = endIndex - index;
    final span = (end - start).inMicroseconds;
    for (var i = index; i < endIndex; i++) {
      result.add(
        LyricWord(
          text: chunks[i].text,
          time:
              start +
              Duration(microseconds: (span * (i - index) / count).round()),
          end:
              start +
              Duration(microseconds: (span * (i - index + 1) / count).round()),
        ),
      );
    }
    index = endIndex;
  }
  return List.unmodifiable(result);
}
