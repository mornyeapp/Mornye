import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Builds `assets/romanization/pinyin.bin`, the gzipped data of offline Hanyu
/// Pinyin for lyrics. The name must not end in `.gz`: the Android build
/// unpacks such assets and drops the extension, so the app cannot find them.
/// It holds:
///
/// - one reading for each character, the first `kMandarin` value of the
///   Unicode Han Database (Unihan, Unicode License v3), with the overrides
///   below for words sung far more often than the default suggests;
/// - the phrases of mozillazg/phrase-pinyin-data `pinyin.txt` (MIT) whose
///   reading differs from those defaults, so a polyphone reads right in its
///   word, plus the few words of [_extraPhrases];
/// - traditional to simplified pairs from Unihan `kSimplifiedVariant`, so
///   traditional lyrics find the phrases too.
///
/// Usage, from the repository root, with Unihan.zip extracted:
///
/// ```sh
/// dart scripts/build_pinyin_data.dart <Unihan dir> <phrase pinyin.txt>
/// dart scripts/build_pinyin_data.dart --repack
/// ```
///
/// Sources:
/// https://www.unicode.org/Public/UCD/latest/ucd/Unihan.zip and
/// https://github.com/mozillazg/phrase-pinyin-data/blob/master/pinyin.txt
Future<void> main(List<String> args) async {
  const outputPath = 'assets/romanization/pinyin.bin';
  if (args.length == 1 && args[0] == '--repack') {
    final existing = File(outputPath);
    final raw = gzip.decode(existing.readAsBytesSync());
    final text = utf8.decode(raw);
    final parsed = _parseTextV1(text);
    _writeV2(
      outputPath,
      defaults: parsed.defaults,
      phrases: parsed.phrases,
      simplified: parsed.simplified,
    );
    return;
  }
  if (args.length != 2) {
    stderr.writeln(
      'Usage: dart scripts/build_pinyin_data.dart <Unihan dir> <pinyin.txt>\n'
      '   or: dart scripts/build_pinyin_data.dart --repack',
    );
    exitCode = 64;
    return;
  }
  final unihan = args[0];
  final readings = _unihanField('$unihan/Unihan_Readings.txt', 'kMandarin');
  final variants = _unihanField(
    '$unihan/Unihan_Variants.txt',
    'kSimplifiedVariant',
  );

  final defaults = <int, String>{
    for (final MapEntry(:key, :value) in readings.entries)
      key: value.split(' ').first,
  };
  for (final MapEntry(:key, :value) in _overrides.entries) {
    defaults[key.runes.single] = value;
  }

  final simplified = <int, int>{};
  for (final MapEntry(:key, :value) in variants.entries) {
    final target = int.parse(value.split(' ').first.substring(2), radix: 16);
    if (target != key) simplified[key] = target;
  }

  final phrases = <String, String>{};
  for (final raw in File(args[1]).readAsLinesSync()) {
    final line = raw.split('#').first.trim();
    if (line.isEmpty) continue;
    final colon = line.indexOf(':');
    if (colon < 0) continue;
    final phrase = line.substring(0, colon).trim();
    final runes = phrase.runes.toList();
    final syllables = line.substring(colon + 1).trim().split(RegExp(r'\s+'));
    if (runes.length < 2 ||
        runes.length != syllables.length ||
        phrases.containsKey(phrase) ||
        runes.any((rune) => !defaults.containsKey(rune))) {
      continue;
    }
    // Pinyin writes the citation tones of 一 and 不; the phrase list marks
    // their tone changes in some words only.
    for (var i = 0; i < runes.length; i++) {
      if (_citationTone.containsKey(runes[i])) {
        syllables[i] = _citationTone[runes[i]]!;
      }
    }
    var differs = false;
    for (var i = 0; i < runes.length; i++) {
      if (syllables[i] != defaults[runes[i]]) differs = true;
    }
    if (differs) phrases[phrase] = syllables.join(' ');
  }
  phrases.addAll(_extraPhrases);

  _writeV2(
    outputPath,
    defaults: defaults,
    phrases: phrases,
    simplified: simplified,
  );
}

({
  Map<int, String> defaults,
  Map<String, String> phrases,
  Map<int, int> simplified,
})
_parseTextV1(String text) {
  final lines = text.split('\n');
  if (lines.isEmpty || lines.first != 'mornye-pinyin 1') {
    throw const FormatException('Expected mornye-pinyin 1 text payload');
  }
  final defaults = <int, String>{};
  final phrases = <String, String>{};
  final simplified = <int, int>{};
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
        final reading = line.substring(0, tab);
        for (final rune in line.substring(tab + 1).runes) {
          defaults[rune] = reading;
        }
      case '#phrases':
        final tab = line.indexOf('\t');
        phrases[line.substring(0, tab)] = line.substring(tab + 1);
      case '#simplified':
        final runes = line.runes.toList();
        for (var i = 0; i + 1 < runes.length; i += 2) {
          simplified[runes[i]] = runes[i + 1];
        }
    }
  }
  return (defaults: defaults, phrases: phrases, simplified: simplified);
}

void _writeV2(
  String outputPath, {
  required Map<int, String> defaults,
  required Map<String, String> phrases,
  required Map<int, int> simplified,
}) {
  final byReading = <String, List<int>>{};
  final sortedChars = defaults.keys.toList()..sort();
  for (final rune in sortedChars) {
    (byReading[defaults[rune]!] ??= <int>[]).add(rune);
  }
  for (final syllables in phrases.values) {
    for (final syllable in syllables.split(' ')) {
      byReading.putIfAbsent(syllable, () => <int>[]);
    }
  }

  final readingKeys = byReading.keys.toList()..sort();
  final readingIndex = <String, int>{
    for (var i = 0; i < readingKeys.length; i++) readingKeys[i]: i,
  };

  final out = BytesBuilder(copy: false);
  void writeUvar(int value) {
    if (value < 0) throw RangeError.value(value, 'value', 'must be >= 0');
    var v = value;
    while (v >= 0x80) {
      out.addByte((v & 0x7F) | 0x80);
      v >>= 7;
    }
    out.addByte(v);
  }

  void writeSvar(int value) {
    final zigzag = value >= 0 ? (value << 1) : ((-value << 1) - 1);
    writeUvar(zigzag);
  }

  // Binary format v2 ("MPY2"): delta-varint codepoints grouped by reading,
  // front-coded diff-only phrases, and zigzag-encoded simplified pairs.
  out.add(const [0x4D, 0x50, 0x59, 0x32]);
  final readingsBytes = utf8.encode(readingKeys.join('\n'));
  writeUvar(readingKeys.length);
  writeUvar(readingsBytes.length);
  out.add(readingsBytes);

  for (final reading in readingKeys) {
    final chars = byReading[reading]!;
    writeUvar(chars.length);
    var prev = 0;
    for (final rune in chars) {
      writeUvar(rune - prev);
      prev = rune;
    }
  }

  final phraseKeys = phrases.keys.toList()..sort();
  writeUvar(phraseKeys.length);
  var prevRunes = const <int>[];
  for (final phrase in phraseKeys) {
    final runes = phrase.runes.toList(growable: false);
    final syllables = phrases[phrase]!.split(' ');
    if (runes.length != syllables.length || runes.length > 52) {
      throw FormatException('Unsupported phrase: $phrase');
    }
    var shared = 0;
    while (shared < prevRunes.length &&
        shared < runes.length &&
        prevRunes[shared] == runes[shared]) {
      shared++;
    }
    final suffixLen = runes.length - shared;
    if (suffixLen < 0x0F) {
      writeUvar((shared << 4) | suffixLen);
    } else {
      writeUvar((shared << 4) | 0x0F);
      writeUvar(suffixLen);
    }
    for (var i = shared; i < runes.length; i++) {
      writeSvar(runes[i] - 0x4E00);
    }
    var diffMask = 0;
    final diffs = <int>[];
    for (var i = 0; i < runes.length; i++) {
      final ri = readingIndex[syllables[i]]!;
      if (defaults[runes[i]] != syllables[i]) {
        diffMask |= (1 << i);
        diffs.add(ri);
      }
    }
    writeUvar(diffMask);
    for (final ri in diffs) {
      writeUvar(ri);
    }
    prevRunes = runes;
  }

  final traditional = simplified.keys.toList()..sort();
  writeUvar(traditional.length);
  var prevTrad = 0;
  for (final rune in traditional) {
    writeUvar(rune - prevTrad);
    prevTrad = rune;
    writeSvar(simplified[rune]! - rune);
  }

  final bytes = out.takeBytes();
  final gz = GZipCodec(level: 9).encode(bytes);
  final file = File(outputPath)
    ..createSync(recursive: true)
    ..writeAsBytesSync(gz);
  stdout.writeln(
    '${defaults.length} characters, ${phrases.length} phrases, '
    '${simplified.length} traditional pairs; '
    '${bytes.length} bytes, ${gz.length} gzipped to ${file.path}',
  );
}

/// Unihan [field] values by code point.
Map<int, String> _unihanField(String path, String field) {
  final values = <int, String>{};
  for (final line in File(path).readAsLinesSync()) {
    if (line.startsWith('#')) continue;
    final parts = line.split('\t');
    if (parts.length < 3 || parts[1] != field) continue;
    values[int.parse(parts[0].substring(2), radix: 16)] = parts[2];
  }
  return values;
}

const _citationTone = {0x4E00: 'yī', 0x4E0D: 'bù'};

/// Readings that lyrics need far more often than the Unihan default: the
/// particles and the everyday sense of a character. Phrases still give
/// the other readings in their words.
const _overrides = {
  '得': 'de',
  '长': 'cháng',
  '長': 'cháng',
  '啊': 'a',
  '啦': 'la',
  '哦': 'o',
  '喔': 'o',
  '嗯': 'en',
  '弹': 'tán',
  '彈': 'tán',
  '著': 'zhe',
  '誰': 'shéi',
  '么': 'me',
  '麼': 'me',
  '嘛': 'ma',
  '地': 'de',
  '都': 'dōu',
};

/// Common words the phrase list lacks or reads wrong with [_overrides].
const _extraPhrases = {'得到': 'dé dào', '得不到': 'dé bù dào', '不记得': 'bù jì de'};
