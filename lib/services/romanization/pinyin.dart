import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Hanyu Pinyin with tone marks, one syllable per character, read from
/// `assets/romanization/pinyin.bin` (see `scripts/build_pinyin_data.dart`):
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

  static const _binaryMagic = <int>[0x4D, 0x50, 0x59, 0x32]; // "MPY2"

  factory PinyinData.decode(List<int> gzipped) {
    final raw = gzip.decode(gzipped);
    if (raw.length >= 4 &&
        raw[0] == _binaryMagic[0] &&
        raw[1] == _binaryMagic[1] &&
        raw[2] == _binaryMagic[2] &&
        raw[3] == _binaryMagic[3]) {
      return PinyinData._decodeV2(
        raw is Uint8List ? raw : Uint8List.fromList(raw),
      );
    }
    return PinyinData.parse(utf8.decode(raw));
  }

  factory PinyinData._decodeV2(Uint8List bytes) {
    var offset = 4;
    int readUvar() {
      var result = 0;
      var shift = 0;
      while (true) {
        if (offset >= bytes.length) {
          throw const FormatException('Truncated pinyin data');
        }
        final b = bytes[offset++];
        result |= (b & 0x7F) << shift;
        if ((b & 0x80) == 0) return result;
        shift += 7;
      }
    }

    int readSvar() {
      final u = readUvar();
      return (u & 1) == 0 ? (u >> 1) : -((u >> 1) + 1);
    }

    final readingCount = readUvar();
    final readingsByteLen = readUvar();
    if (offset + readingsByteLen > bytes.length) {
      throw const FormatException('Truncated pinyin readings table');
    }
    final readingsText = utf8.decode(
      bytes.sublist(offset, offset + readingsByteLen),
    );
    offset += readingsByteLen;
    final readings = readingCount == 0
        ? const <String>[]
        : readingsText.split('\n');
    if (readings.length != readingCount) {
      throw const FormatException('Corrupt pinyin readings table');
    }

    final byCode = <int, int>{};
    for (var r = 0; r < readingCount; r++) {
      final count = readUvar();
      var cp = 0;
      for (var i = 0; i < count; i++) {
        cp += readUvar();
        byCode[cp] = r;
      }
    }

    final phraseCount = readUvar();
    final phrases = <String, String>{};
    final longest = <int, int>{};
    var prevRunes = const <int>[];
    for (var p = 0; p < phraseCount; p++) {
      final header = readUvar();
      final shared = header >> 4;
      var suffixLen = header & 0x0F;
      if (suffixLen == 0x0F) suffixLen = readUvar();
      final runes = List<int>.filled(shared + suffixLen, 0);
      for (var i = 0; i < shared; i++) {
        runes[i] = prevRunes[i];
      }
      for (var i = 0; i < suffixLen; i++) {
        runes[shared + i] = 0x4E00 + readSvar();
      }
      prevRunes = runes;

      final diffMask = readUvar();
      final syllables = List<String>.filled(runes.length, '');
      for (var i = 0; i < runes.length; i++) {
        final ri = ((diffMask & (1 << i)) != 0)
            ? readUvar()
            : (byCode[runes[i]] ?? -1);
        if (ri < 0 || ri >= readings.length) {
          throw const FormatException('Invalid pinyin reading index');
        }
        syllables[i] = readings[ri];
      }
      final phrase = String.fromCharCodes(runes);
      phrases[phrase] = syllables.join(' ');
      final first = runes.first;
      if (runes.length > (longest[first] ?? 0)) {
        longest[first] = runes.length;
      }
    }

    final simplifiedCount = readUvar();
    final simplified = <int, int>{};
    var trad = 0;
    for (var i = 0; i < simplifiedCount; i++) {
      trad += readUvar();
      final simp = trad + readSvar();
      simplified[trad] = simp;
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
