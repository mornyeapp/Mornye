/// Revised Romanization of Korean (2000), as the words are pronounced:
/// liaison, nasalization, lateralization, aspiration and palatalization
/// between the syllables of one word. Tensing, which the system does not
/// write, and the insertion of ㄴ, which needs the word's meaning, are left
/// out.
library;

// Consonants, numbered as the initials of a syllable.
const _g = 0, _kk = 1, _n = 2, _d = 3, _r = 5, _m = 6, _b = 7;
const _s = 9, _ss = 10, _ieung = 11, _j = 12, _ch = 14, _k = 15, _t = 16;
const _p = 17, _h = 18;

final _initials = 'g,kk,n,d,tt,r,m,b,pp,s,ss,,j,jj,ch,k,t,p,h'.split(',');

final _vowels = 'a,ae,ya,yae,eo,e,yeo,ye,o,wa,wae,oe,yo,u,wo,we,wi,yu,eu,ui,i'
    .split(',');

const _vowelI = 20;

/// The consonants of each final, as initials; ㅇ stands for "ng".
const _finals = <List<int>>[
  [],
  [_g],
  [_kk],
  [_g, _s],
  [_n],
  [_n, _j],
  [_n, _h],
  [_d],
  [_r],
  [_r, _g],
  [_r, _m],
  [_r, _b],
  [_r, _s],
  [_r, _t],
  [_r, _p],
  [_r, _h],
  [_m],
  [_b],
  [_b, _s],
  [_s],
  [_ss],
  [_ieung],
  [_j],
  [_ch],
  [_k],
  [_t],
  [_p],
  [_h],
];

/// The sound a final keeps before a consonant or at the end of a word.
String _sound(List<int> finals) {
  if (finals.isEmpty) return '';
  if (finals.length == 2) {
    final (first, second) = (finals[0], finals[1]);
    if (first == _r) {
      return switch (second) {
        _g => 'k',
        _m => 'm',
        _p => 'p',
        _ => 'l',
      };
    }
    if (first == _b) return 'p';
    if (first == _g) return 'k';
    return 'n';
  }
  return switch (finals.single) {
    _g || _kk || _k => 'k',
    _n => 'n',
    _r => 'l',
    _m => 'm',
    _b || _p => 'p',
    _ieung => 'ng',
    _ => 't',
  };
}

const _nasal = {'k': 'ng', 't': 'n', 'p': 'm'};

const _aspirated = {_g: _k, _kk: _k, _d: _t, _s: _t, _j: _ch, _b: _p};

class _Syllable {
  _Syllable(this.initial, this.vowel, List<int> finals) : finals = [...finals];

  int initial;
  final int vowel;
  final List<int> finals;
  String sound = '';
}

bool _isSyllable(int unit) => unit >= 0xAC00 && unit <= 0xD7A3;

/// Writes the romanization of the Hangul in [text] from [start] to [end]
/// into [out], one entry per UTF-16 code unit: each syllable gets its own
/// part, so the parts of a word timed syllable by syllable still read as
/// the word is pronounced.
void romanizeHangul(String text, int start, int end, List<String> out) {
  var i = start;
  while (i < end) {
    final unit = text.codeUnitAt(i);
    if (!_isSyllable(unit)) {
      out[i] = _jamo(unit) ?? out[i];
      i++;
      continue;
    }
    var wordEnd = i;
    while (wordEnd < end && _isSyllable(text.codeUnitAt(wordEnd))) {
      wordEnd++;
    }
    final word = [
      for (var k = i; k < wordEnd; k++)
        _Syllable(
          (text.codeUnitAt(k) - 0xAC00) ~/ 588,
          (text.codeUnitAt(k) - 0xAC00) % 588 ~/ 28,
          _finals[(text.codeUnitAt(k) - 0xAC00) % 28],
        ),
    ];
    for (var k = 0; k + 1 < word.length; k++) {
      _join(word[k], word[k + 1]);
    }
    word.last.sound = _sound(word.last.finals);
    for (var k = 0; k < word.length; k++) {
      final syllable = word[k];
      final initial =
          syllable.initial == _r && k > 0 && word[k - 1].sound == 'l'
          ? 'l'
          : _initials[syllable.initial];
      out[i + k] = '$initial${_vowels[syllable.vowel]}${syllable.sound}';
    }
    i = wordEnd;
  }
}

/// Applies the sound changes between [a]'s final and [b]'s initial, and
/// settles the sound of [a]'s final.
void _join(_Syllable a, _Syllable b) {
  final finals = a.finals;
  if (finals.isEmpty) return;
  if (b.initial == _ieung) {
    if (finals.length == 1 && finals.first == _ieung) {
      a.sound = 'ng';
      return;
    }
    if (finals.last == _h) finals.removeLast();
    if (finals.isNotEmpty) {
      var moved = finals.removeLast();
      if (b.vowel == _vowelI) {
        if (moved == _d) moved = _j;
        if (moved == _t) moved = _ch;
      }
      b.initial = moved;
    }
    a.sound = _sound(finals);
    return;
  }
  if (b.initial == _h) {
    final aspirated = _aspirated[finals.last];
    if (aspirated != null) {
      finals.removeLast();
      // ㄷ and ㅌ before 이 soften to ㅊ, as in 닫히다.
      b.initial = aspirated == _t && b.vowel == _vowelI ? _ch : aspirated;
    } else if (finals.last == _h) {
      finals.removeLast();
    }
    a.sound = _sound(finals);
    return;
  }
  if (finals.last == _h) {
    finals.removeLast();
    switch (b.initial) {
      case _g:
        b.initial = _k;
      case _d:
        b.initial = _t;
      case _j:
        b.initial = _ch;
      case _s:
        b.initial = _ss;
      case _n:
        if (finals.isEmpty) finals.add(_n);
      default:
        if (finals.isEmpty) finals.add(_d);
    }
  }
  var sound = _sound(finals);
  switch (b.initial) {
    case _r:
      if (_nasal.containsKey(sound)) {
        sound = _nasal[sound]!;
        b.initial = _n;
      } else if (sound == 'm' || sound == 'ng') {
        b.initial = _n;
      } else if (sound == 'n') {
        sound = 'l';
      }
    case _n:
      sound = _nasal[sound] ?? sound;
      if (sound == 'l') b.initial = _r;
    case _m:
      sound = _nasal[sound] ?? sound;
  }
  a.sound = sound;
}

final _compatibilityConsonants =
    'g,kk,gs,n,nj,nh,d,tt,r,lg,lm,lb,ls,lt,lp,lh,m,b,pp,bs,s,ss,,j,jj,ch,k,t,'
            'p,h'
        .split(',');

/// A lone jamo, as in ㅋㅋ or ㅠㅠ.
String? _jamo(int unit) {
  if (unit >= 0x3131 && unit <= 0x314E) {
    return _compatibilityConsonants[unit - 0x3131];
  }
  if (unit >= 0x314F && unit <= 0x3163) return _vowels[unit - 0x314F];
  if (unit >= 0x1100 && unit <= 0x1112) return _initials[unit - 0x1100];
  if (unit >= 0x1161 && unit <= 0x1175) return _vowels[unit - 0x1161];
  if (unit >= 0x11A8 && unit <= 0x11C2) {
    return _sound(_finals[unit - 0x11A7]);
  }
  return null;
}
