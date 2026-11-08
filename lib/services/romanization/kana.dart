/// Hepburn romanization of hiragana and katakana, letter by letter: long
/// vowels are written as they are spelled (`ou`, `ee`, and the vowel again
/// for ー), ん before a vowel takes an apostrophe and を is `o`. Telling the
/// particles は and へ from the syllables needs the words, so they read
/// `ha` and `he`. Kanji need a dictionary and are not romanized here.
library;

/// Hiragana from U+3041 to U+3096; katakana are 0x60 above.
final _kana =
    ('a a i i u u e e o o ka ga ki gi ku gu ke ge ko go sa za shi ji su zu '
            'se ze so zo ta da chi ji - tsu zu te de to do na ni nu ne no '
            'ha ba pa hi bi pi fu bu pu he be pe ho bo po ma mi mu me mo '
            'ya ya yu yu yo yo ra ri ru re ro wa wa i e o n vu ka ke')
        .split(' ');

const _smallTsu = 0x3063;
const _smallY = {0x3083: 'a', 0x3085: 'u', 0x3087: 'o'};
const _smallVowels = {
  0x3041: 'a',
  0x3043: 'i',
  0x3045: 'u',
  0x3047: 'e',
  0x3049: 'o',
  0x308E: 'wa',
};

/// Whether a small vowel after [previous] makes one syllable with it.
bool _joinsSmallVowel(String previous, String small) {
  if (previous.isEmpty || previous.endsWith(small)) return false;
  if (previous == 'i') return small == 'e';
  if (previous.endsWith('u')) return true;
  return switch (previous) {
    'te' || 'de' => small == 'i' || small == 'u',
    'to' || 'do' => small == 'u',
    'shi' || 'chi' || 'ji' => small == 'e',
    _ => false,
  };
}

bool isKana(int unit) =>
    (unit >= 0x3041 && unit <= 0x3096) ||
    (unit >= 0x309D && unit <= 0x309E) ||
    (unit >= 0x30A1 && unit <= 0x30FA) ||
    (unit >= 0x30FC && unit <= 0x30FE);

/// [unit] as hiragana, when it is a katakana letter with one.
int _hiragana(int unit) =>
    unit >= 0x30A1 && unit <= 0x30F6 ? unit - 0x60 : unit;

const _vowelLetters = 'aeiou';

/// Writes the romanization of the kana in [text] from [start] to [end]
/// into [out], one entry per UTF-16 code unit.
void romanizeKana(String text, int start, int end, List<String> out) {
  for (var i = start; i < end; i++) {
    final unit = text.codeUnitAt(i);
    final kana = _hiragana(unit);
    final previous = i > start ? out[i - 1] : '';
    // ゃ, ゅ and ょ join the i-row syllable before them: kya, sha, ja.
    final y = _smallY[kana];
    if (y != null && previous.endsWith('i') && previous.length > 1) {
      final stem = previous.substring(0, previous.length - 1);
      final hushed = stem == 'sh' || stem == 'ch' || stem == 'j';
      out[i - 1] = stem;
      out[i] = hushed ? y : 'y$y';
      continue;
    }
    // Small vowels make new syllables (fa, ti, che, wo), or lengthen the
    // vowel before them (nee).
    final small = _smallVowels[kana];
    if (small != null && _joinsSmallVowel(previous, small)) {
      out[i - 1] = previous.length == 1
          ? (previous == 'u' ? 'w' : 'y')
          : previous.substring(0, previous.length - 1);
      out[i] = small;
      continue;
    }
    switch (unit) {
      case 0x30F7:
        out[i] = 'va';
      case 0x30F8:
        out[i] = 'vi';
      case 0x30F9:
        out[i] = 've';
      case 0x30FA:
        out[i] = 'vo';
      case 0x30FC:
        // The long vowel mark repeats the vowel before it.
        final vowel = previous.isEmpty ? '' : previous[previous.length - 1];
        out[i] = _vowelLetters.contains(vowel) ? vowel : '';
      case 0x309D || 0x30FD:
        out[i] = previous;
      case 0x309E || 0x30FE:
        out[i] = _voiced(previous);
      default:
        if (kana >= 0x3041 && kana <= 0x3096) {
          final value = _kana[kana - 0x3041];
          out[i] = value == '-' ? '' : value;
        }
    }
  }
  // Small っ doubles the consonant after it (tch for ch); ん takes an
  // apostrophe before a vowel or y.
  for (var i = start; i < end; i++) {
    final kana = _hiragana(text.codeUnitAt(i));
    final next = i + 1 < end ? out[i + 1] : '';
    if (kana == _smallTsu) {
      out[i] = next.startsWith('ch')
          ? 't'
          : next.isNotEmpty && !_vowelLetters.contains(next[0])
          ? next[0]
          : '';
    } else if (kana == 0x3093 &&
        next.isNotEmpty &&
        (_vowelLetters.contains(next[0]) || next[0] == 'y')) {
      out[i] = "n'";
    }
  }
}

String _voiced(String syllable) {
  for (final (plain, voiced) in const [
    ('sh', 'j'),
    ('ch', 'j'),
    ('ts', 'z'),
    ('k', 'g'),
    ('s', 'z'),
    ('t', 'd'),
    ('h', 'b'),
    ('f', 'b'),
  ]) {
    if (syllable.startsWith(plain)) {
      return voiced + syllable.substring(plain.length);
    }
  }
  return syllable;
}
