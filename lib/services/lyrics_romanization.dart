/// Offline romanization of lyrics, worked out on the device: Korean,
/// Cyrillic, Hindi, Punjabi, Chinese and Japanese kana. Lines in other
/// scripts, and Japanese lines with kanji, are left to the AI translation
/// when it is set up to romanize.
///
/// It is shown, never saved: the player works it out again for each song,
/// so the song's files and their saved translations stay as they were.
library;

import 'dart:async';
import 'dart:isolate';
import 'dart:ui' show Locale;

import 'package:flutter/foundation.dart' show setEquals;
import 'package:flutter/services.dart';
import 'package:mornye/services/lyrics_translation.dart';
import 'package:mornye/services/romanization/pinyin.dart';
import 'package:mornye/services/romanization/text_romanizer.dart';
import 'package:mornye/utils/logger.dart';
import 'package:mornye/utils/lyrics_parser.dart';

final _log = AppLogger('LyricsRomanization');

const pinyinDataAsset = 'assets/romanization/pinyin.txt.gz';

/// Loads the Chinese reading data once, off the UI thread, the first time
/// Chinese lyrics need it.
class PinyinDataLoader {
  PinyinDataLoader({Future<List<int>> Function()? read})
    : _read = read ?? _readAsset;

  final Future<List<int>> Function() _read;
  Future<PinyinData?>? _loading;
  PinyinData? _data;

  /// The data, once loaded.
  PinyinData? get data => _data;

  Future<PinyinData?> load() => _loading ??= _load();

  Future<PinyinData?> _load() async {
    try {
      final bytes = await _read();
      return _data = await Isolate.run(() => PinyinData.decode(bytes));
    } catch (error) {
      _log.w('Could not load the pinyin data: $error');
      return null;
    }
  }

  static Future<List<int>> _readAsset() async {
    final data = await rootBundle.load(pinyinDataAsset);
    return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  }
}

final _romanizers = Expando<(PinyinData?, TextRomanizer)>();

TextRomanizer _romanizerFor(
  ParsedLyrics lyrics,
  PinyinData? pinyin,
  Set<LyricsScript> readerScripts,
) {
  final memo = _romanizers[lyrics];
  if (memo != null &&
      identical(memo.$1, pinyin) &&
      setEquals(memo.$2.readerScripts, readerScripts)) {
    return memo.$2;
  }
  final romanizer = TextRomanizer.forTexts(
    lyricsWithPlainLines(lyrics).lines.map((line) => line.text),
    pinyin: pinyin,
    readerScripts: readerScripts,
  );
  _romanizers[lyrics] = (pinyin, romanizer);
  return romanizer;
}

/// The scripts a user whose app reads in [locale] reads as they are written,
/// so their lines are never romanized.
Set<LyricsScript> lyricsReaderScripts(Locale locale) =>
    scriptsReadIn(locale.languageCode, scriptCode: locale.scriptCode);

/// Whether [lyrics] are Chinese, so romanizing them needs [PinyinData].
bool lyricsNeedPinyin(
  ParsedLyrics lyrics, {
  Set<LyricsScript> readerScripts = const {},
}) => _romanizerFor(lyrics, null, readerScripts).needsPinyin;

/// The lines of [lyrics] written outside the Latin alphabet that have no
/// romanization yet and that offline romanization cannot give one: the
/// lines to ask the AI translation to romanize. Lines in [readerScripts]
/// are left out.
Iterable<LyricLine> linesNeedingAiRomanization(
  ParsedLyrics lyrics, {
  Set<LyricsScript> readerScripts = const {},
}) {
  final romanizer = _romanizerFor(lyrics, null, readerScripts);
  return lyricsWithPlainLines(lyrics).lines.where((line) {
    if (line.romanization?.trim().isNotEmpty == true) return false;
    final text = translatableLyricText(line.text);
    return lyricNeedsRomanization(text) &&
        !romanizer.readsAsWritten(text) &&
        !romanizer.canRomanize(text, assumePinyin: true);
  });
}

/// [shown], [original] as a translation shows it, without the
/// romanization the translation gave lines in [readerScripts]: the AI
/// romanizes every line it is sent. Romanization [original] has of its own
/// stays.
ParsedLyrics lyricsWithoutReaderRomanization(
  ParsedLyrics original,
  ParsedLyrics shown,
  Set<LyricsScript> readerScripts,
) {
  if (readerScripts.isEmpty || identical(original, shown)) return shown;
  final saved = lyricsWithPlainLines(original).lines;
  if (saved.length != shown.lines.length) return shown;
  var changed = false;
  final lines = <LyricLine>[];
  for (var i = 0; i < saved.length; i++) {
    final line = shown.lines[i];
    final own = saved[i];
    if (line.romanization == own.romanization ||
        !writtenIn(line.text, readerScripts)) {
      lines.add(line);
      continue;
    }
    changed = true;
    lines.add(
      LyricLine(
        time: line.time,
        end: line.end,
        text: line.text,
        words: line.words,
        romanization: own.romanization,
        romanizationWords: own.romanizationWords,
        translation: line.translation,
        translationWords: line.translationWords,
        voice: line.voice,
        isBackground: line.isBackground,
        vocalGroup: line.vocalGroup,
      ),
    );
  }
  if (!changed) return shown;
  return ParsedLyrics(
    synced: shown.synced,
    wordSynced: shown.wordSynced,
    lines: lines,
    plainText: shown.plainText,
    writers: shown.writers,
    provider: shown.provider,
  );
}

/// [lyrics] with an offline romanization on each line written outside the
/// Latin alphabet that has none, timed word by word on word-timed lines.
/// Chinese lines wait for [pinyin]; lines in [readerScripts] get none.
ParsedLyrics lyricsWithOfflineRomanization(
  ParsedLyrics lyrics, {
  PinyinData? pinyin,
  Set<LyricsScript> readerScripts = const {},
}) {
  final base = lyricsWithPlainLines(lyrics);
  final romanizer = _romanizerFor(lyrics, pinyin, readerScripts);
  var changed = false;
  final lines = <LyricLine>[];
  for (final line in base.lines) {
    final romanized =
        line.romanization?.trim().isNotEmpty == true ||
            !lyricNeedsRomanization(line.text)
        ? null
        : _romanizeLine(line, romanizer);
    if (romanized != null) changed = true;
    lines.add(romanized ?? line);
  }
  if (!changed) return lyrics;
  return ParsedLyrics(
    synced: base.synced,
    wordSynced: base.wordSynced,
    lines: lines,
    plainText: base.plainText,
    writers: base.writers,
    provider: base.provider,
  );
}

LyricLine? _romanizeLine(LyricLine line, TextRomanizer romanizer) {
  if (!line.hasWordTiming) {
    final parts = romanizer.romanize(line.text);
    final romanization = parts?.join().trim() ?? '';
    if (romanization.isEmpty) return null;
    return line.withTranslation(line.translation, romanization: romanization);
  }
  // The words together, so sounds that run across them (Korean liaison,
  // Chinese phrases) read right; each word then takes its own part.
  final parts = romanizer.romanize(line.words.map((word) => word.text).join());
  if (parts == null) return null;
  final texts = <String>[];
  var offset = 0;
  for (final word in line.words) {
    texts.add(parts.sublist(offset, offset + word.text.length).join());
    offset += word.text.length;
  }
  texts
    ..first = texts.first.trimLeft()
    ..last = texts.last.trimRight();
  final words = <LyricWord>[];
  for (var i = 0; i < line.words.length; i++) {
    final text = texts[i];
    if (text.trim().isEmpty) {
      // A word that romanizes to nothing, or to a space, joins the one
      // before it, as the lyrics parsers join a lone space.
      final previous = words.lastOrNull;
      if (previous != null && text.isNotEmpty) {
        words.last = LyricWord(
          time: previous.time,
          end: line.words[i].end ?? previous.end,
          text: '${previous.text}$text',
        );
      }
      continue;
    }
    final word = line.words[i];
    words.add(LyricWord(time: word.time, end: word.end, text: text));
  }
  final romanization = words.map((word) => word.text).join();
  if (romanization.trim().isEmpty) return null;
  return line.withTranslation(
    line.translation,
    romanization: romanization,
    romanizationWords: words,
  );
}

/// [lyrics] with each line's romanization as the line itself and the
/// original under it, where the line has one. A word-timed line whose
/// romanization is not timed keeps its original, so its words still
/// light up as they are sung.
ParsedLyrics lyricsWithRomanizedMainLines(ParsedLyrics lyrics) {
  var changed = false;
  final lines = <LyricLine>[];
  for (final line in lyrics.lines) {
    final romanization = line.romanization?.trim() ?? '';
    if (romanization.isEmpty ||
        (line.hasWordTiming && line.romanizationWords.isEmpty)) {
      lines.add(line);
      continue;
    }
    changed = true;
    lines.add(
      LyricLine(
        time: line.time,
        end: line.end,
        text: line.romanizationWords.isEmpty
            ? romanization
            : line.romanizationWords.map((word) => word.text).join(),
        words: line.romanizationWords,
        romanization: line.text,
        romanizationWords: line.romanizationWords.isEmpty
            ? const []
            : line.words,
        translation: line.translation,
        translationWords: line.translationWords,
        voice: line.voice,
        isBackground: line.isBackground,
        vocalGroup: line.vocalGroup,
      ),
    );
  }
  if (!changed) return lyrics;
  return ParsedLyrics(
    synced: lyrics.synced,
    wordSynced: lyrics.wordSynced,
    lines: lines,
    plainText: lyrics.synced
        ? lyrics.plainText
        : _plainTextOf(lyrics.plainText, lines),
    writers: lyrics.writers,
    provider: lyrics.provider,
  );
}

/// [plainText] with each of its rows replaced by the [lines] made of them,
/// keeping the blank rows between verses.
String _plainTextOf(String plainText, List<LyricLine> lines) {
  var next = 0;
  return [
    for (final row in plainText.split('\n'))
      if (row.trim().isEmpty || next >= lines.length)
        row
      else
        lines[next++].text,
  ].join('\n');
}
