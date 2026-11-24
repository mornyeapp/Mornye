/// Hindi (Devanagari) and Punjabi (Gurmukhi) in the plain spelling lyrics
/// are usually romanized with: no diacritics, doubled letters for long
/// vowels inside a word (`aa`, `ee`, `oo`) and single ones at its end
/// (`mera`, `kudi`), `ch` and `chh`, `sh`, and nasal vowels as `n`.
///
/// The vowel each consonant carries is dropped where Hindi and Punjabi
/// drop it in speech: at the end of a word, and between two consonants
/// that have vowels around them (कमल kamal, समझना samajhna).
library;

class _Script {
  const _Script({
    required this.base,
    required this.consonants,
    required this.nukta,
    required this.vowels,
    required this.signs,
    required this.virama,
    required this.nasals,
    required this.visarga,
    this.gemination,
    this.extra = const {},
  });

  /// The first code point of the block.
  final int base;
  final Map<int, String> consonants;

  /// What a nukta makes of a consonant.
  final Map<int, String> nukta;

  /// Independent vowels; an empty value is a bare vowel carrier.
  final Map<int, String> vowels;

  final Map<int, String> signs;
  final int virama;
  final Set<int> nasals;
  final int visarga;

  /// Punjabi's addak, which doubles the next consonant.
  final int? gemination;

  /// Other characters with a fixed value, such as digits and symbols.
  final Map<int, String> extra;

  int get nuktaSign => base + 0x3C;
}

Map<int, String> _table(int base, String spec) {
  final values = <int, String>{};
  for (final entry in spec.split(' ')) {
    final [offset, value] = entry.split('=');
    values[base + int.parse(offset, radix: 16)] = value == '-' ? '' : value;
  }
  return values;
}

Map<int, String> _digits(int zero) => {
  for (var i = 0; i < 10; i++) zero + i: '$i',
};

final _devanagari = _Script(
  base: 0x900,
  consonants: _table(
    0x900,
    '15=k 16=kh 17=g 18=gh 19=ng 1A=ch 1B=chh 1C=j 1D=jh 1E=ny 1F=t 20=th '
    '21=d 22=dh 23=n 24=t 25=th 26=d 27=dh 28=n 29=n 2A=p 2B=ph 2C=b '
    '2D=bh 2E=m 2F=y 30=r 31=r 32=l 33=l 34=l 35=v 36=sh 37=sh 38=s 39=h '
    '58=q 59=kh 5A=gh 5B=z 5C=d 5D=dh 5E=f 5F=y',
  ),
  nukta: _table(0x900, '15=q 16=kh 17=gh 1C=z 21=d 22=dh 2B=f 2F=y'),
  vowels: _table(
    0x900,
    '04=e 05=a 06=aa 07=i 08=ee 09=u 0A=oo 0B=ri 0C=li 0D=e 0E=e 0F=e '
    '10=ai 11=o 12=o 13=o 14=au 60=ri 61=li 72=a',
  ),
  signs: _table(
    0x900,
    '3E=aa 3F=i 40=ee 41=u 42=oo 43=ri 44=ri 45=e 46=e 47=e 48=ai 49=o '
    '4A=o 4B=o 4C=au 62=li 63=li',
  ),
  virama: 0x94D,
  nasals: {0x901, 0x902},
  visarga: 0x903,
  extra: {..._digits(0x966), 0x93D: '', 0x950: 'om', 0x964: '.', 0x965: '.'},
);

final _gurmukhi = _Script(
  base: 0xA00,
  consonants: _table(
    0xA00,
    '15=k 16=kh 17=g 18=gh 19=ng 1A=ch 1B=chh 1C=j 1D=jh 1E=ny 1F=t 20=th '
    '21=d 22=dh 23=n 24=t 25=th 26=d 27=dh 28=n 2A=p 2B=ph 2C=b 2D=bh '
    '2E=m 2F=y 30=r 32=l 33=l 35=v 36=sh 38=s 39=h 59=kh 5A=gh 5B=z 5C=d '
    '5E=f',
  ),
  nukta: _table(0xA00, '16=kh 17=gh 1C=z 2B=f 32=l 38=sh'),
  vowels: _table(
    0xA00,
    '05=a 06=aa 07=i 08=ee 09=u 0A=oo 0F=e 10=ai 13=o 14=au 72=- 73=-',
  ),
  signs: _table(0xA00, '3E=aa 3F=i 40=ee 41=u 42=oo 47=e 48=ai 4B=o 4C=au'),
  virama: 0xA4D,
  nasals: {0xA01, 0xA02, 0xA70},
  visarga: 0xA03,
  gemination: 0xA71,
  extra: {..._digits(0xA66), 0xA74: 'ik onkar', 0xA75: 'y'},
);

bool isDevanagari(int unit) =>
    (unit >= 0x900 && unit <= 0x97F) || (unit >= 0xA8E0 && unit <= 0xA8FF);

bool isGurmukhi(int unit) => unit >= 0xA00 && unit <= 0xA7F;

/// One syllable: its consonants, its vowel and the marks after it.
class _Unit {
  /// Code unit index of each consonant of [onset].
  final onsetAt = <int>[];
  final onset = <String>[];

  /// Index of the vowel sign or independent vowel, or of the consonant
  /// carrying the inherent vowel.
  int vowelAt = -1;
  String? vowel;
  bool halant = false;
  bool nasal = false;
  bool geminated = false;
  bool inherent = false;
  bool keepInherent = true;
}

/// Writes the romanization of the Devanagari in [text] from [start] to
/// [end] into [out], one entry per UTF-16 code unit.
void romanizeDevanagari(String text, int start, int end, List<String> out) =>
    _romanize(_devanagari, text, start, end, out);

/// Writes the romanization of the Gurmukhi in [text] from [start] to [end]
/// into [out], one entry per UTF-16 code unit.
void romanizeGurmukhi(String text, int start, int end, List<String> out) =>
    _romanize(_gurmukhi, text, start, end, out);

const _labials = {'p', 'ph', 'b', 'bh', 'm', 'f'};

void _romanize(
  _Script script,
  String text,
  int start,
  int end,
  List<String> out,
) {
  final units = <_Unit>[];
  final nasals = <int>[];
  final geminations = <int>[];
  _Unit? current;
  for (var i = start; i < end; i++) {
    final c = text.codeUnitAt(i);
    out[i] = '';
    final consonant = script.consonants[c];
    if (consonant != null) {
      if (current == null || !current.halant) {
        current = _Unit()..inherent = true;
        units.add(current);
      }
      current
        ..halant = false
        ..onset.add(consonant)
        ..onsetAt.add(i)
        ..vowelAt = i;
      continue;
    }
    if (c == script.nuktaSign) {
      if (current != null && current.onset.isNotEmpty) {
        final base = text.codeUnitAt(current.onsetAt.last);
        final value = script.nukta[base];
        if (value != null) current.onset.last = value;
      }
      continue;
    }
    final sign = script.signs[c];
    if (sign != null && current != null) {
      current
        ..vowel = sign
        ..vowelAt = i
        ..inherent = false
        ..halant = false;
      continue;
    }
    final vowel = script.vowels[c];
    if (vowel != null) {
      current = _Unit()
        ..vowel = vowel
        ..vowelAt = i;
      units.add(current);
      continue;
    }
    if (c == script.virama) {
      current
        ?..halant = true
        ..inherent = false;
      continue;
    }
    if (script.nasals.contains(c)) {
      current?.nasal = true;
      // Its sound depends on the consonant after it.
      nasals.add(i);
      continue;
    }
    if (c == script.visarga) {
      out[i] = 'h';
      continue;
    }
    if (c == script.gemination) {
      current?.geminated = true;
      geminations.add(i);
      continue;
    }
    final fixed = script.extra[c];
    if (fixed != null) out[i] = fixed;
    current = null;
  }

  _dropInherentVowels(units);

  // The first letters of the consonant after index [at].
  String? nextConsonant(int at) {
    for (final unit in units) {
      for (var k = 0; k < unit.onsetAt.length; k++) {
        if (unit.onsetAt[k] > at) return unit.onset[k];
      }
      if (unit.vowelAt > at && unit.onset.isEmpty) return null;
    }
    return null;
  }

  for (var u = 0; u < units.length; u++) {
    final unit = units[u];
    for (var k = 0; k < unit.onset.length; k++) {
      out[unit.onsetAt[k]] = unit.onset[k];
    }
    var vowel = unit.inherent ? (unit.keepInherent ? 'a' : '') : unit.vowel;
    if (vowel == null || unit.vowelAt < 0) continue;
    // Long vowels end a word short, as lyrics spell mera and kudi.
    if (u == units.length - 1 && units.length > 1) {
      vowel = switch (vowel) {
        'aa' => 'a',
        'ee' => 'i',
        'oo' => 'u',
        _ => vowel,
      };
    }
    final at = unit.vowelAt;
    out[at] = unit.inherent ? '${out[at]}$vowel' : vowel;
  }

  for (final at in nasals) {
    out[at] = _labials.contains(nextConsonant(at)) ? 'm' : 'n';
  }
  for (final at in geminations) {
    final next = nextConsonant(at);
    out[at] = next == null || next.isEmpty ? '' : next[0];
  }
}

/// Clears [_Unit.keepInherent] where speech drops the inherent vowel:
/// at the end of a word after a single consonant, and in a consonant
/// between two vowels, scanning from the end of the word. A vowel stays
/// where dropping it would join three consonants (ज़िंदगी zindagi).
void _dropInherentVowels(List<_Unit> units) {
  if (units.length < 2) return;
  final last = units.last;
  final beforeLast = units[units.length - 2];
  if (last.inherent &&
      last.onset.length == 1 &&
      !last.nasal &&
      // Sanskrit words such as priya keep it after i.
      !(last.onset.single == 'y' &&
          (beforeLast.vowel == 'i' || beforeLast.vowel == 'ee'))) {
    last.keepInherent = false;
  }
  bool voiced(_Unit unit) =>
      !unit.halant && (!unit.inherent || unit.keepInherent);
  for (var k = units.length - 2; k >= 1; k--) {
    final unit = units[k];
    final next = units[k + 1];
    if (unit.inherent &&
        unit.onset.length == 1 &&
        !unit.nasal &&
        !unit.geminated &&
        voiced(units[k - 1]) &&
        !units[k - 1].nasal &&
        !units[k - 1].geminated &&
        next.onset.length == 1 &&
        voiced(next)) {
      unit.keepInherent = false;
    }
  }
}
