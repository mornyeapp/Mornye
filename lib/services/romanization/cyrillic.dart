/// Cyrillic romanization, with one standard per language:
///
/// - Russian: BGN/PCGN, without the marks for the soft and hard signs;
/// - Ukrainian: the national system of 2010 (KMU resolution 55);
/// - Belarusian: BGN/PCGN, without the soft sign mark;
/// - Bulgarian: the Streamlined System of 2009;
/// - Serbian: the Serbian Latin alphabet;
/// - Macedonian: the digraph system of official documents since 2008;
/// - Kyrgyz: BGN/PCGN.
///
/// Letters a language does not use take the Russian value, or a common
/// one for the letters of other languages.
library;

enum CyrillicLanguage {
  russian,
  ukrainian,
  belarusian,
  bulgarian,
  serbian,
  macedonian,
  kyrgyz,
}

int _count(String text, String letters) {
  final set = letters.codeUnits.toSet();
  var count = 0;
  for (final unit in text.codeUnits) {
    if (set.contains(unit)) count++;
  }
  return count;
}

/// The language of the Cyrillic in [text], one song's lyrics, from the
/// letters only some languages use. Russian when nothing tells.
CyrillicLanguage guessCyrillicLanguage(String text) {
  final lower = text.toLowerCase();
  final serbian = _count(lower, 'ђћ');
  final macedonian = _count(lower, 'ѓќѕ');
  if (macedonian > serbian) return CyrillicLanguage.macedonian;
  if (serbian > 0 || _count(lower, 'јљњџ') > 0) return CyrillicLanguage.serbian;
  if (_count(lower, 'ў') > 0) return CyrillicLanguage.belarusian;
  final ukrainian = _count(lower, 'їєґ');
  final i = _count(lower, 'і');
  final russian = _count(lower, 'ыэё');
  if (ukrainian > 0 || (i > 0 && russian == 0)) {
    return CyrillicLanguage.ukrainian;
  }
  if (i > 0) return CyrillicLanguage.belarusian;
  if (_count(lower, 'әғқұһ') == 0 && _count(lower, 'ңөү') > 0) {
    return CyrillicLanguage.kyrgyz;
  }
  // Bulgarian writes ъ inside words and has no ы, э or ё.
  if (russian == 0 && RegExp('ъ[а-я]').allMatches(lower).length >= 2) {
    return CyrillicLanguage.bulgarian;
  }
  return CyrillicLanguage.russian;
}

const _russian = {
  // Russian letters.
  'а': 'a', 'б': 'b', 'в': 'v', 'г': 'g', 'д': 'd', 'е': 'e', 'ё': 'yo',
  'ж': 'zh', 'з': 'z', 'и': 'i', 'й': 'y', 'к': 'k', 'л': 'l', 'м': 'm',
  'н': 'n', 'о': 'o', 'п': 'p', 'р': 'r', 'с': 's', 'т': 't', 'у': 'u',
  'ф': 'f', 'х': 'kh', 'ц': 'ts', 'ч': 'ch', 'ш': 'sh', 'щ': 'shch',
  'ъ': '', 'ы': 'y', 'ь': '', 'э': 'e', 'ю': 'yu', 'я': 'ya',
  // Letters of other languages.
  'і': 'i', 'ї': 'yi', 'є': 'ye', 'ґ': 'g', 'ў': 'w', 'ђ': 'đ', 'ј': 'j',
  'љ': 'lj', 'њ': 'nj', 'ћ': 'ć', 'џ': 'dž', 'ѓ': 'gj', 'ѕ': 'dz',
  'ќ': 'kj', 'ң': 'ng', 'ө': 'ö', 'ү': 'ü', 'ә': 'ä', 'ғ': 'gh', 'қ': 'q',
  'ұ': 'u', 'һ': 'h',
};

const _ukrainian = {'г': 'h', 'и': 'y', 'х': 'kh'};

const _belarusian = {'г': 'h', 'ў': 'w', 'х': 'kh'};

const _bulgarian = {'х': 'h', 'щ': 'sht', 'ъ': 'a', 'ь': 'y'};

const _serbian = {
  // Where Serbian Latin differs from the Russian values.
  'ж': 'ž', 'х': 'h', 'ц': 'c', 'ч': 'č', 'ш': 'š', 'ђ': 'đ', 'ћ': 'ć',
  'џ': 'dž', 'ј': 'j', 'љ': 'lj', 'њ': 'nj',
};

const _macedonian = {'х': 'h', 'ц': 'c', 'џ': 'dj', 'ѓ': 'gj', 'ќ': 'kj'};

const _kyrgyz = {'ж': 'j'};

const _overrides = {
  CyrillicLanguage.russian: <String, String>{},
  CyrillicLanguage.ukrainian: _ukrainian,
  CyrillicLanguage.belarusian: _belarusian,
  CyrillicLanguage.bulgarian: _bulgarian,
  CyrillicLanguage.serbian: _serbian,
  CyrillicLanguage.macedonian: _macedonian,
  CyrillicLanguage.kyrgyz: _kyrgyz,
};

const _vowels = 'аеёиоуыэюяіїєәөүұ';
const _apostrophes = "'’ʼ";

bool isCyrillic(int unit) => unit >= 0x400 && unit <= 0x52F;

/// Whether [unit] is an apostrophe inside a Cyrillic word, as Ukrainian
/// and Belarusian write before a iotated vowel.
bool isCyrillicApostrophe(String text, int index) =>
    _apostrophes.contains(text[index]) &&
    index > 0 &&
    index + 1 < text.length &&
    isCyrillic(text.codeUnitAt(index - 1)) &&
    isCyrillic(text.codeUnitAt(index + 1));

/// Writes the romanization of the Cyrillic word in [text] from [start] to
/// [end] (apostrophes inside it included) into [out], one entry per
/// UTF-16 code unit.
void romanizeCyrillic(
  String text,
  int start,
  int end,
  List<String> out,
  CyrillicLanguage language,
) {
  final overrides = _overrides[language]!;
  for (var i = start; i < end; i++) {
    final char = text[i];
    final lower = char.toLowerCase();
    if (_apostrophes.contains(char)) {
      out[i] = '';
      continue;
    }
    final previous = i > start ? text[i - 1].toLowerCase() : null;
    final next = i + 1 < end ? text[i + 1].toLowerCase() : null;
    final value =
        _letter(lower, language, previous, next) ??
        overrides[lower] ??
        _russian[lower];
    if (value == null) continue;
    out[i] = _cased(char, lower, value, text, i, start, end);
  }
}

/// The letters whose value depends on their place in the word.
String? _letter(
  String letter,
  CyrillicLanguage language,
  String? previous,
  String? next,
) {
  final initial = previous == null;
  final afterVowel = previous != null && _vowels.contains(previous);
  final afterSign = previous == 'ъ' || previous == 'ь';
  final afterApostrophe = previous != null && _apostrophes.contains(previous);
  switch (language) {
    case CyrillicLanguage.russian || CyrillicLanguage.kyrgyz:
      if (letter == 'е') {
        return initial || afterVowel || afterSign || previous == 'й'
            ? 'ye'
            : 'e';
      }
      if (letter == 'ё' && const ['ж', 'ч', 'ш', 'щ'].contains(previous)) {
        return 'o';
      }
    case CyrillicLanguage.ukrainian:
      // Initial forms only at the start of a word.
      const forms = {
        'є': ('ye', 'ie'),
        'ї': ('yi', 'i'),
        'й': ('y', 'i'),
        'ю': ('yu', 'iu'),
        'я': ('ya', 'ia'),
      };
      final form = forms[letter];
      if (form != null) return initial ? form.$1 : form.$2;
      if (letter == 'г' && previous == 'з') return 'gh';
    case CyrillicLanguage.belarusian:
      const forms = {
        'е': ('ye', 'ie'),
        'ё': ('yo', 'io'),
        'ю': ('yu', 'iu'),
        'я': ('ya', 'ia'),
      };
      final form = forms[letter];
      if (form != null) {
        return initial ||
                afterVowel ||
                afterSign ||
                afterApostrophe ||
                previous == 'й' ||
                previous == 'ў'
            ? form.$1
            : form.$2;
      }
    case CyrillicLanguage.bulgarian:
      if (letter == 'я' && previous == 'и' && next == null) return 'a';
    case CyrillicLanguage.serbian || CyrillicLanguage.macedonian:
      break;
  }
  return null;
}

/// [value] in the case of [char]: capitalized for a capital, all capitals
/// when the word around it is written in capitals.
String _cased(
  String char,
  String lower,
  String value,
  String text,
  int index,
  int start,
  int end,
) {
  if (char == lower || value.isEmpty) return value;
  bool upper(int at) =>
      at >= start && at < end && text[at] != text[at].toLowerCase();
  if (upper(index - 1) || upper(index + 1)) return value.toUpperCase();
  return value[0].toUpperCase() + value.substring(1);
}
