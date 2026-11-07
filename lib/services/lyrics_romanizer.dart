// On-device pronunciation (romaji / romanized Hangul) for lyric lines that
// arrive without one.
//
// Ported from PixelPlayerOSS (GPL-3.0) `MultiLangRomanizer`,
// app/src/main/java/com/lostf1sh/pixelplayeross/utils/LyricsUtils.kt.
// Japanese is read by Kuromoji on Android (see LyricsRomanizerPlugin.kt);
// Korean is converted in Dart from the same jamo tables.
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:mornye/services/lyrics_romanizer_hangul.dart';
import 'package:mornye/utils/lyrics_parser.dart';

class LyricsRomanizer {
  LyricsRomanizer._();

  static const _channel = MethodChannel('com.zarz.mornye/lyrics_romanizer');

  static bool _isKana(int code) =>
      (code >= 0x3040 && code <= 0x309F) || (code >= 0x30A0 && code <= 0x30FF);
  static bool _isHan(int code) => code >= 0x4E00 && code <= 0x9FFF;
  static bool _isHangul(int code) => code >= 0xAC00 && code <= 0xD7A3;

  /// Kana always marks Japanese. Han-only text counts when the lyrics as a
  /// whole contain kana ([entireLyricsHasKana]), so kanji-only lines get
  /// Japanese readings instead of being skipped.
  static bool isJapanese(String text, {bool entireLyricsHasKana = false}) {
    final codes = text.codeUnits;
    if (codes.any(_isKana)) return true;
    return entireLyricsHasKana && codes.any(_isHan);
  }

  static bool isKorean(String text) => text.codeUnits.any(_isHangul);

  /// Romanizes Hangul syllable by syllable. A final consonant is resolved
  /// against the next syllable's initial, which handles most liaison and
  /// assimilation (for example 안녕 -> annyeong).
  static String romanizeKorean(String text) {
    final out = StringBuffer();
    String? prevFinal;

    String finalSound(String jong, [String? next]) =>
        (next == null ? null : hangulJongseong[jong + next]) ??
        hangulJongseong[jong] ??
        jong;

    for (final rune in text.runes) {
      if (rune >= 0xAC00 && rune <= 0xD7A3) {
        final index = rune - 0xAC00;
        final cho = String.fromCharCode(0x1100 + index ~/ (21 * 28));
        final jung = String.fromCharCode(0x1161 + (index % (21 * 28)) ~/ 28);
        final jongIndex = index % 28;
        final jong = jongIndex == 0
            ? null
            : String.fromCharCode(0x11A7 + jongIndex);

        if (prevFinal != null) out.write(finalSound(prevFinal, cho));
        out
          ..write(hangulChoseong[cho] ?? cho)
          ..write(hangulJungseong[jung] ?? jung);
        prevFinal = jong;
      } else {
        if (prevFinal != null) {
          out.write(finalSound(prevFinal));
          prevFinal = null;
        }
        out.writeCharCode(rune);
      }
    }
    if (prevFinal != null) out.write(finalSound(prevFinal));
    return out.toString();
  }

  /// Reads Japanese lines through Kuromoji on Android. Returns one entry per
  /// input line, null where a reading is unavailable. Other platforms have no
  /// Japanese reader yet, so they return all nulls.
  static Future<List<String?>> romanizeJapaneseLines(List<String> lines) async {
    if (lines.isEmpty) return const [];
    final none = List<String?>.filled(lines.length, null);
    if (kIsWeb || !Platform.isAndroid) return none;
    try {
      final result = await _channel.invokeListMethod<String?>(
        'romanizeJapanese',
        {'lines': lines},
      );
      if (result == null || result.length != lines.length) return none;
      return result;
    } on PlatformException {
      return none;
    } on MissingPluginException {
      return none;
    }
  }

  static String? _tidy(String? value) {
    final text = value?.trim();
    if (text == null || text.isEmpty) return null;
    return text[0].toUpperCase() + text.substring(1);
  }

  /// Lyrics without timing have no [ParsedLyrics.lines], only text, so each
  /// text line gets its own entry in [ParsedLyrics.plainPronunciations].
  static Future<ParsedLyrics> _fillPlain(ParsedLyrics lyrics) async {
    if (lyrics.plainPronunciations.isNotEmpty ||
        lyrics.plainText.trim().isEmpty) {
      return lyrics;
    }
    final rows = lyrics.plainText.split(RegExp(r'\r\n|\r|\n'));
    final hasKana = lyrics.plainText.codeUnits.any(_isKana);

    final readings = List<String?>.filled(rows.length, null);
    final japanese = <int>[];
    for (var i = 0; i < rows.length; i++) {
      final text = rows[i].trim();
      if (text.isEmpty) continue;
      if (isJapanese(text, entireLyricsHasKana: hasKana)) {
        japanese.add(i);
      } else if (isKorean(text)) {
        readings[i] = _tidy(romanizeKorean(text));
      }
    }
    if (japanese.isNotEmpty) {
      final values = await romanizeJapaneseLines([
        for (final i in japanese) rows[i].trim(),
      ]);
      for (var n = 0; n < japanese.length; n++) {
        readings[japanese[n]] = _tidy(values[n]);
      }
    }
    if (readings.every((value) => value == null)) return lyrics;

    return ParsedLyrics(
      synced: lyrics.synced,
      wordSynced: lyrics.wordSynced,
      lines: lyrics.lines,
      plainText: lyrics.plainText,
      writers: lyrics.writers,
      provider: lyrics.provider,
      plainPronunciations: readings,
    );
  }

  /// Fills [ParsedLyrics.lines] that have no pronunciation yet and are
  /// Japanese or Korean. Lines that already carry a romanization from the
  /// lyrics provider are left alone.
  static Future<ParsedLyrics> fillMissing(ParsedLyrics lyrics) async {
    if (lyrics.lines.isEmpty) return _fillPlain(lyrics);
    final hasKana = lyrics.lines.any(
      (line) => line.text.codeUnits.any(_isKana),
    );

    final japanese = <int>[];
    final korean = <int>[];
    for (var i = 0; i < lyrics.lines.length; i++) {
      final line = lyrics.lines[i];
      if (line.romanization?.trim().isNotEmpty == true) continue;
      if (isJapanese(line.text, entireLyricsHasKana: hasKana)) {
        japanese.add(i);
      } else if (isKorean(line.text)) {
        korean.add(i);
      }
    }
    if (japanese.isEmpty && korean.isEmpty) return lyrics;

    final readings = <int, String>{};
    for (final i in korean) {
      final value = _tidy(romanizeKorean(lyrics.lines[i].text));
      if (value != null) readings[i] = value;
    }
    if (japanese.isNotEmpty) {
      final values = await romanizeJapaneseLines([
        for (final i in japanese) lyrics.lines[i].text,
      ]);
      for (var n = 0; n < japanese.length; n++) {
        final value = _tidy(values[n]);
        if (value != null) readings[japanese[n]] = value;
      }
    }
    if (readings.isEmpty) return lyrics;

    return ParsedLyrics(
      synced: lyrics.synced,
      wordSynced: lyrics.wordSynced,
      lines: [
        for (var i = 0; i < lyrics.lines.length; i++)
          readings.containsKey(i)
              ? lyrics.lines[i].withTranslation(
                  lyrics.lines[i].translation,
                  romanization: readings[i],
                )
              : lyrics.lines[i],
      ],
      plainText: lyrics.plainText,
      writers: lyrics.writers,
      provider: lyrics.provider,
    );
  }
}
