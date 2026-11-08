import 'dart:convert';
import 'dart:io';

/// Builds `assets/romanization/pinyin.txt.gz`, the data of offline Hanyu
/// Pinyin for lyrics:
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
/// ```
///
/// Sources:
/// https://www.unicode.org/Public/UCD/latest/ucd/Unihan.zip and
/// https://github.com/mozillazg/phrase-pinyin-data/blob/master/pinyin.txt
Future<void> main(List<String> args) async {
  if (args.length != 2) {
    stderr.writeln(
      'Usage: dart scripts/build_pinyin_data.dart <Unihan dir> <pinyin.txt>',
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

  final byReading = <String, StringBuffer>{};
  final sortedChars = defaults.keys.toList()..sort();
  for (final rune in sortedChars) {
    (byReading[defaults[rune]!] ??= StringBuffer()).writeCharCode(rune);
  }
  final out = StringBuffer('mornye-pinyin 1\n#chars\n');
  final readingKeys = byReading.keys.toList()..sort();
  for (final reading in readingKeys) {
    out.write('$reading\t${byReading[reading]}\n');
  }
  out.write('#phrases\n');
  final phraseKeys = phrases.keys.toList()..sort();
  for (final phrase in phraseKeys) {
    out.write('$phrase\t${phrases[phrase]}\n');
  }
  out.write('#simplified\n');
  final pairs = StringBuffer();
  final traditional = simplified.keys.toList()..sort();
  for (final rune in traditional) {
    pairs
      ..writeCharCode(rune)
      ..writeCharCode(simplified[rune]!);
  }
  out.write('$pairs\n');

  final bytes = utf8.encode(out.toString());
  final gz = GZipCodec(level: 9).encode(bytes);
  final file = File('assets/romanization/pinyin.txt.gz')
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
