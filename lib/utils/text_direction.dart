import 'package:flutter/painting.dart' show TextDirection;

/// The direction of [text]'s first strong character, the rule the Unicode
/// bidirectional algorithm uses for a paragraph: right to left for a
/// Hebrew, Arabic or other right-to-left letter, left to right for any
/// other letter. Digits, punctuation, symbols, spaces, marks and a byte
/// order mark decide nothing, so text of only those returns null and the
/// caller chooses.
TextDirection? strongTextDirection(String text) {
  for (final rune in text.runes) {
    if (rune < 0x80) {
      // Latin letters, the usual first character, decide at once.
      if ((rune | 0x20) >= 0x61 && (rune | 0x20) <= 0x7A) {
        return TextDirection.ltr;
      }
      continue;
    }
    if (_within(_weak, rune)) continue;
    return _within(_rightToLeft, rune) ? TextDirection.rtl : TextDirection.ltr;
  }
  return null;
}

/// [strongTextDirection] of each of [lines]. A line without a strong
/// character, such as an instrumental break or "...", takes the direction
/// of the line before it, else of the first one after it with one, so it
/// sits beside its neighbours. All null when no line has a strong
/// character.
List<TextDirection?> lyricLineDirections(Iterable<String> lines) {
  final directions = [for (final line in lines) strongTextDirection(line)];
  TextDirection? previous;
  for (var index = 0; index < directions.length; index++) {
    previous = directions[index] ??= previous;
  }
  TextDirection? next;
  for (var index = directions.length - 1; index >= 0; index--) {
    next = directions[index] ??= next;
  }
  return directions;
}

/// Whether [rune] falls in one of the sorted, inclusive [ranges].
bool _within(List<int> ranges, int rune) {
  var low = 0;
  var high = ranges.length ~/ 2 - 1;
  while (low <= high) {
    final middle = (low + high) >> 1;
    if (rune < ranges[middle * 2]) {
      high = middle - 1;
    } else if (rune > ranges[middle * 2 + 1]) {
      low = middle + 1;
    } else {
      return true;
    }
  }
  return false;
}

/// Characters past ASCII that are not strong: combining marks, digits and
/// number signs, punctuation, symbols, spaces and format characters,
/// including those inside the right-to-left blocks below.
const _weak = [
  0x0080, 0x00BF, // Latin-1 controls, punctuation and signs
  0x00D7, 0x00D7, // multiplication sign
  0x00F7, 0x00F7, // division sign
  0x02B9, 0x02BA, // modifier primes
  0x02C2, 0x02CF, // modifier symbols
  0x02D2, 0x02DF,
  0x02E5, 0x02ED,
  0x02EF, 0x02FF,
  0x0300, 0x036F, // combining diacritics
  0x0374, 0x0375, // Greek numeral signs
  0x037E, 0x037E, // Greek question mark
  0x0384, 0x0385, // Greek tonos
  0x0387, 0x0387, // Greek ano teleia
  0x0483, 0x0489, // Cyrillic combining marks
  0x0591, 0x05BD, // Hebrew points and accents
  0x05BF, 0x05BF,
  0x05C1, 0x05C2,
  0x05C4, 0x05C5,
  0x05C7, 0x05C7,
  0x0600, 0x0607, // Arabic number signs
  0x0609, 0x060A, // Arabic per mille and per ten thousand
  0x060C, 0x060C, // Arabic comma
  0x060E, 0x061A, // Arabic poetic signs and marks
  0x064B, 0x065F, // Arabic vowel marks
  0x0660, 0x066C, // Arabic-Indic digits and separators
  0x0670, 0x0670, // Arabic superscript alef
  0x06D6, 0x06E4, // Quranic marks
  0x06E7, 0x06ED,
  0x06F0, 0x06F9, // extended Arabic-Indic digits
  0x0711, 0x0711, // Syriac superscript alaph
  0x0730, 0x074A, // Syriac marks
  0x07A6, 0x07B0, // Thaana vowels
  0x07EB, 0x07F3, // NKo tone marks
  0x07F6, 0x07F9, // NKo symbols
  0x07FD, 0x07FD,
  0x0816, 0x0819, // Samaritan marks
  0x081B, 0x0823,
  0x0825, 0x0827,
  0x0829, 0x082D,
  0x0859, 0x085B, // Mandaic marks
  0x0890, 0x0891, // Arabic pound and piastre marks
  0x0897, 0x089F, // Arabic marks
  0x08CA, 0x08FF,
  0x2000, 0x200D, // spaces, zero-width space and joiners
  0x2010, 0x2BFF, // punctuation, symbols, arrows and shapes
  0x2E00, 0x2FFF, // supplemental punctuation, CJK radicals
  0x3000, 0x3004, // CJK space and punctuation
  0x3008, 0x3020,
  0x302A, 0x3030,
  0x3036, 0x3037,
  0x303D, 0x303F,
  0x3099, 0x309C, // kana voicing marks
  0x30A0, 0x30A0,
  0x30FB, 0x30FB, // katakana middle dot
  0xFB1E, 0xFB1E, // Hebrew point judeo-spanish varika
  0xFB29, 0xFB29, // Hebrew alternative plus sign
  0xFD3E, 0xFD3F, // ornate parentheses
  0xFDCF, 0xFDCF,
  0xFDFD, 0xFDFF,
  0xFE00, 0xFE6F, // variation selectors, small and vertical forms
  0xFEFF, 0xFEFF, // byte order mark
  0xFF00, 0xFF20, // fullwidth punctuation and digits
  0xFF3B, 0xFF40,
  0xFF5B, 0xFF65,
  0xFFE0, 0xFFFF,
  0x10E60, 0x10E7E, // Rumi numerals
  0x1E8D0, 0x1E8D6, // Mende Kikakui marks
  0x1E944, 0x1E94A, // Adlam marks
  0x1EEF0, 0x1EEF1,
  0x1F000, 0x1FBFF, // emoji, game and legacy symbols
  0xE0000, 0xE0FFF, // tags and variation selectors
];

/// The right-to-left blocks: Hebrew through Arabic Extended-A, their
/// presentation forms, and the historic and African right-to-left scripts.
/// The right-to-left mark counts too.
const _rightToLeft = [
  0x0590, 0x08FF, // Hebrew, Arabic, Syriac, Thaana, NKo and their kin
  0x200F, 0x200F, // right-to-left mark
  0xFB1D, 0xFDFF, // Hebrew and Arabic presentation forms
  0xFE70, 0xFEFC, // Arabic presentation forms B
  0x10800, 0x10FFF, // historic right-to-left scripts
  0x1E800, 0x1EFFF, // Mende Kikakui, Adlam and Arabic mathematical letters
];
