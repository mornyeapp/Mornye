import 'package:mornye/services/romanization/cyrillic.dart';
import 'package:mornye/services/romanization/indic.dart';
import 'package:mornye/services/romanization/kana.dart';
import 'package:mornye/services/romanization/korean.dart';
import 'package:mornye/services/romanization/pinyin.dart';

enum _Script { hangul, cyrillic, devanagari, gurmukhi, kana, han }

bool _isHangul(int unit) =>
    (unit >= 0xAC00 && unit <= 0xD7A3) ||
    (unit >= 0x1100 && unit <= 0x11FF) ||
    (unit >= 0x3131 && unit <= 0x318E);

bool _isHan(int rune) =>
    (rune >= 0x3400 && rune <= 0x4DBF) ||
    (rune >= 0x4E00 && rune <= 0x9FFF) ||
    (rune >= 0xF900 && rune <= 0xFAFF) ||
    (rune >= 0x20000 && rune <= 0x2FA1F) ||
    rune == 0x3005 ||
    rune == 0x3007;

int _runeAt(String text, int index) {
  final unit = text.codeUnitAt(index);
  if (unit >= 0xD800 && unit <= 0xDBFF && index + 1 < text.length) {
    final low = text.codeUnitAt(index + 1);
    if (low >= 0xDC00 && low <= 0xDFFF) {
      return 0x10000 + ((unit - 0xD800) << 10) + (low - 0xDC00);
    }
  }
  return unit;
}

_Script? _scriptOf(int rune) {
  if (rune < 0x400) return null;
  if (isCyrillic(rune)) return _Script.cyrillic;
  if (isDevanagari(rune)) return _Script.devanagari;
  if (isGurmukhi(rune)) return _Script.gurmukhi;
  if (_isHangul(rune)) return _Script.hangul;
  if (isKana(rune)) return _Script.kana;
  if (_isHan(rune)) return _Script.han;
  return null;
}

final _nonLatinLetter = RegExp(r'(?!\p{Script=Latin})\p{L}', unicode: true);
final _wordChar = RegExp(r'[\p{L}\p{N}]', unicode: true);

/// Full-width punctuation of Chinese and Japanese, as romanized text
/// writes it.
const _cjkPunctuation = {
  '、': ', ',
  '。': '. ',
  '，': ', ',
  '！': '! ',
  '？': '? ',
  '：': ': ',
  '；': '; ',
  '「': '"',
  '」': '"',
  '『': '"',
  '』': '"',
  '（': '(',
  '）': ')',
  '　': ' ',
  '～': '~',
  '〜': '~',
  '・': ' ',
};

/// Romanizes the lines of one song offline, with what the whole song
/// tells about them: the language of its Cyrillic, and whether its Han
/// characters are Chinese (Japanese kanji and Korean hanja are not
/// romanized).
class TextRomanizer {
  TextRomanizer._(this.cyrillic, this._hanIsChinese, this._hasHan, this.pinyin);

  factory TextRomanizer.forTexts(Iterable<String> texts, {PinyinData? pinyin}) {
    var kana = 0;
    var han = 0;
    var hangul = 0;
    final cyrillic = StringBuffer();
    for (final text in texts) {
      for (final rune in text.runes) {
        switch (_scriptOf(rune)) {
          case _Script.kana:
            kana++;
          case _Script.han:
            han++;
          case _Script.hangul:
            hangul++;
          case _Script.cyrillic:
            cyrillic.writeCharCode(rune);
          default:
            break;
        }
      }
    }
    // Japanese writes kanji among its kana, Korean may write hanja.
    final japanese = kana >= 3 || (kana > 0 && kana * 20 >= han);
    return TextRomanizer._(
      guessCyrillicLanguage(cyrillic.toString()),
      !japanese && hangul <= han,
      han > 0,
      pinyin,
    );
  }

  final CyrillicLanguage cyrillic;
  final bool _hanIsChinese;
  final bool _hasHan;
  final PinyinData? pinyin;

  /// Whether the song is Chinese, so its romanization needs [pinyin].
  bool get needsPinyin => _hanIsChinese && _hasHan;

  /// Whether every letter of [text] outside the Latin alphabet romanizes
  /// here. With [assumePinyin], Chinese counts before [pinyin] is loaded.
  bool canRomanize(String text, {bool assumePinyin = false}) {
    for (var i = 0; i < text.length; i++) {
      final rune = _runeAt(text, i);
      if (rune > 0xFFFF) i++;
      if (rune < 0x80) continue;
      final script = _scriptOf(rune);
      if (script == _Script.han) {
        if (!_hanIsChinese) return false;
        final data = pinyin;
        if (data == null ? !assumePinyin : data.reading(rune) == null) {
          return false;
        }
        continue;
      }
      if (script == null &&
          _nonLatinLetter.hasMatch(String.fromCharCodes([rune]))) {
        return false;
      }
    }
    return true;
  }

  /// [text] romanized, as one part per UTF-16 code unit of [text], so any
  /// slice of [text] (a word timed on its own) maps to its slice of the
  /// result. Null when a letter of [text] does not romanize here.
  List<String>? romanize(String text) {
    if (!canRomanize(text)) return null;
    final out = [for (var i = 0; i < text.length; i++) text[i]];
    final cjk = List.filled(text.length, false);
    var i = 0;
    while (i < text.length) {
      final script = _scriptOf(_runeAt(text, i));
      if (script == null) {
        i++;
        continue;
      }
      var end = i;
      while (end < text.length) {
        final rune = _runeAt(text, end);
        if (_scriptOf(rune) == script) {
          end += rune > 0xFFFF ? 2 : 1;
        } else if (script == _Script.cyrillic &&
            isCyrillicApostrophe(text, end)) {
          end++;
        } else {
          break;
        }
      }
      switch (script) {
        case _Script.hangul:
          romanizeHangul(text, i, end, out);
        case _Script.cyrillic:
          romanizeCyrillic(text, i, end, out, cyrillic);
        case _Script.devanagari:
          romanizeDevanagari(text, i, end, out);
        case _Script.gurmukhi:
          romanizeGurmukhi(text, i, end, out);
        case _Script.kana:
          romanizeKana(text, i, end, out);
          cjk.fillRange(i, end, true);
        case _Script.han:
          _romanizeHan(text, i, end, out);
          cjk.fillRange(i, end, true);
      }
      i = end;
    }
    for (var k = 0; k < text.length; k++) {
      final punctuation = _cjkPunctuation[text[k]];
      if (punctuation != null) out[k] = punctuation;
    }
    // Romanized Chinese and Japanese stand apart from the words around
    // them, which their script did not need to space.
    for (var k = 0; k < text.length; k++) {
      if (!cjk[k]) continue;
      if (k > 0 && !cjk[k - 1] && _wordChar.hasMatch(text[k - 1])) {
        out[k] = ' ${out[k]}';
      }
      if (k + 1 < text.length &&
          !cjk[k + 1] &&
          _wordChar.hasMatch(text[k + 1])) {
        out[k] = '${out[k]} ';
      }
    }
    // One space where the parts bring two.
    for (var k = 0; k < out.length; k++) {
      if (!out[k].endsWith(' ')) continue;
      var next = k + 1;
      while (next < out.length && out[next].isEmpty) {
        next++;
      }
      if (next == out.length || out[next].startsWith(' ')) {
        out[k] = out[k].trimRight();
      }
    }
    return out;
  }

  void _romanizeHan(String text, int start, int end, List<String> out) {
    final at = <int>[];
    final runes = <int>[];
    for (var i = start; i < end; i++) {
      at.add(i);
      final rune = _runeAt(text, i);
      runes.add(rune);
      if (rune > 0xFFFF) out[++i] = '';
    }
    final readings = pinyin!.readings(runes);
    for (var k = 0; k < runes.length; k++) {
      final reading = readings[k]!;
      out[at[k]] = k + 1 < runes.length ? '$reading ' : reading;
    }
  }
}
