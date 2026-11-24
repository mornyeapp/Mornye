import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Hanyu Pinyin with tone marks, one syllable per character, read from
/// `assets/romanization/pinyin.txt.gz` (see `scripts/build_pinyin_data.dart`):
/// each character's usual reading, and the phrases in which a character
/// reads otherwise, matched longest first.
class PinyinData {
  PinyinData._(
    this._codes,
    this._readingOf,
    this._readings,
    this._phrases,
    this._simplified,
    this._longestPhrase,
  );

  factory PinyinData.decode(List<int> gzipped) =>
      PinyinData.parse(utf8.decode(gzip.decode(gzipped)));

  factory PinyinData.parse(String data) {
    final lines = data.split('\n');
    if (lines.isEmpty || lines.first != 'mornye-pinyin 1') {
      throw const FormatException('Unknown pinyin data');
    }
    final readings = <String>[];
    final byCode = <int, int>{};
    final phrases = <String, String>{};
    final simplified = <int, int>{};
    final longest = <int, int>{};
    var section = '';
    for (final line in lines.skip(1)) {
      if (line.isEmpty) continue;
      if (line.startsWith('#')) {
        section = line;
        continue;
      }
      switch (section) {
        case '#chars':
          final tab = line.indexOf('\t');
          final index = readings.length;
          readings.add(line.substring(0, tab));
          for (final rune in line.substring(tab + 1).runes) {
            byCode[rune] = index;
          }
        case '#phrases':
          final tab = line.indexOf('\t');
          final phrase = line.substring(0, tab);
          phrases[phrase] = line.substring(tab + 1);
          final length = phrase.runes.length;
          final first = phrase.runes.first;
          if (length > (longest[first] ?? 0)) longest[first] = length;
        case '#simplified':
          final runes = line.runes.toList();
          for (var i = 0; i + 1 < runes.length; i += 2) {
            simplified[runes[i]] = runes[i + 1];
          }
      }
    }
    final codes = Int32List.fromList(byCode.keys.toList()..sort());
    final readingOf = Uint16List(codes.length);
    for (var i = 0; i < codes.length; i++) {
      readingOf[i] = byCode[codes[i]]!;
    }
    return PinyinData._(
      codes,
      readingOf,
      List.unmodifiable(readings),
      phrases,
      simplified,
      longest,
    );
  }

  final Int32List _codes;
  final Uint16List _readingOf;
  final List<String> _readings;
  final Map<String, String> _phrases;
  final Map<int, int> _simplified;

  /// The length of the longest phrase starting with each character.
  final Map<int, int> _longestPhrase;

  /// The usual reading of [rune], or null for a character not covered.
  String? reading(int rune) {
    var low = 0;
    var high = _codes.length - 1;
    while (low <= high) {
      final mid = (low + high) >> 1;
      final code = _codes[mid];
      if (code == rune) return _readings[_readingOf[mid]];
      if (code < rune) {
        low = mid + 1;
      } else {
        high = mid - 1;
      }
    }
    final simple = _simplified[rune];
    return simple == null ? null : reading(simple);
  }

  /// The readings of [runes], a run of Han characters, one per character,
  /// with null for characters not covered.
  List<String?> readings(List<int> runes) {
    // The phrases are written in simplified characters.
    final simple = [for (final rune in runes) _simplified[rune] ?? rune];
    final result = List<String?>.filled(runes.length, null);
    var i = 0;
    while (i < runes.length) {
      var matched = 0;
      final longest = _longestPhrase[simple[i]] ?? 0;
      final left = runes.length - i;
      for (
        var length = left < longest ? left : longest;
        length >= 2;
        length--
      ) {
        final phrase = _phrases[String.fromCharCodes(simple, i, i + length)];
        if (phrase == null) continue;
        final syllables = phrase.split(' ');
        for (var k = 0; k < length; k++) {
          result[i + k] = syllables[k];
        }
        matched = length;
        break;
      }
      if (matched == 0) {
        result[i] = reading(runes[i]);
        matched = 1;
      }
      i += matched;
    }
    return result;
  }
}
