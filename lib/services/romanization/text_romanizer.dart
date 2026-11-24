import 'package:mornye/services/romanization/cyrillic.dart';
import 'package:mornye/services/romanization/indic.dart';
import 'package:mornye/services/romanization/kana.dart';
import 'package:mornye/services/romanization/korean.dart';
import 'package:mornye/services/romanization/pinyin.dart';

/// The scripts offline romanization reads.
enum LyricsScript { hangul, cyrillic, devanagari, gurmukhi, kana, han }

/// Languages written in Cyrillic, among those an app or system language
/// can be.
const _cyrillicLanguages = {
  // Slavic languages.
  'ru', 'uk', 'be', 'bg', 'sr', 'mk',
  // Turkic, Iranian, Mongolic, Caucasian and Uralic ones.
  'ky', 'kk', 'tg', 'mn', 'tt', 'ba', 'cv', 'sah', 'os', 'ce', 'ab', 'av',
  'kv', 'udm',
};

const _devanagariLanguages = {'hi', 'mr', 'ne', 'sa', 'kok', 'mai', 'bho'};

/// The scripts a reader of the language of [languageCode] (in
/// [scriptCode], when the locale names one) reads without romanization.
Set<LyricsScript> scriptsReadIn(String languageCode, {String? scriptCode}) {
  final language = languageCode.toLowerCase();
  final script = scriptCode?.toLowerCase();
  // A language can be written in another script than its usual one, as
  // Serbian in Latin or Punjabi in Arabic.
  bool writes(String usual) => script == null || script == usual;
  if (_cyrillicLanguages.contains(language) && writes('cyrl')) {
    return const {LyricsScript.cyrillic};
  }
  return switch (language) {
    'zh' => const {LyricsScript.han},
    'ja' => const {LyricsScript.kana, LyricsScript.han},
    'ko' => const {LyricsScript.hangul},
    'pa' when writes('guru') => const {LyricsScript.gurmukhi},
    _ when _devanagariLanguages.contains(language) && writes('deva') => const {
      LyricsScript.devanagari,
    },
    _ => const {},
  };
}

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

LyricsScript? _scriptOf(int rune) {
  if (rune < 0x400) return null;
  if (isCyrillic(rune)) return LyricsScript.cyrillic;
  if (isDevanagari(rune)) return LyricsScript.devanagari;
  if (isGurmukhi(rune)) return LyricsScript.gurmukhi;
  if (_isHangul(rune)) return LyricsScript.hangul;
  if (isKana(rune)) return LyricsScript.kana;
  if (_isHan(rune)) return LyricsScript.han;
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

/// Whether [text] has a letter of one of [scripts].
bool writtenIn(String text, Set<LyricsScript> scripts) {
  if (scripts.isEmpty) return false;
  for (final rune in text.runes) {
    if (scripts.contains(_scriptOf(rune))) return true;
  }
  return false;
}

/// Romanizes the lines of one song offline, with what the whole song
/// tells about them: the language of its Cyrillic, and whether its Han
/// characters are Chinese (Japanese kanji and Korean hanja are not
/// romanized). Lines in a script of [readerScripts], which the user reads
/// as they are, stay unromanized.
class TextRomanizer {
  TextRomanizer._(
    this.cyrillic,
    this._hanIsChinese,
    this._hasHan,
    this.pinyin,
    this.readerScripts,
  );

  factory TextRomanizer.forTexts(
    Iterable<String> texts, {
    PinyinData? pinyin,
    Set<LyricsScript> readerScripts = const {},
  }) {
    var kana = 0;
    var han = 0;
    var hangul = 0;
    final cyrillic = StringBuffer();
    for (final text in texts) {
      for (final rune in text.runes) {
        switch (_scriptOf(rune)) {
          case LyricsScript.kana:
            kana++;
          case LyricsScript.han:
            han++;
          case LyricsScript.hangul:
            hangul++;
          case LyricsScript.cyrillic:
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
      readerScripts,
    );
  }

  final CyrillicLanguage cyrillic;
  final bool _hanIsChinese;
  final bool _hasHan;
  final PinyinData? pinyin;
  final Set<LyricsScript> readerScripts;

  /// Whether the song is Chinese, so its romanization needs [pinyin].
  bool get needsPinyin =>
      _hanIsChinese && _hasHan && !readerScripts.contains(LyricsScript.han);

  /// Whether [text] is written in a script of [readerScripts], so it reads
  /// as it is.
  bool readsAsWritten(String text) => writtenIn(text, readerScripts);

  /// Whether every letter of [text] outside the Latin alphabet romanizes
  /// here. With [assumePinyin], Chinese counts before [pinyin] is loaded.
  bool canRomanize(String text, {bool assumePinyin = false}) {
    for (var i = 0; i < text.length; i++) {
      final rune = _runeAt(text, i);
      if (rune > 0xFFFF) i++;
      if (rune < 0x80) continue;
      final script = _scriptOf(rune);
      if (script == LyricsScript.han) {
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
  /// result. Null when a letter of [text] does not romanize here, or when
  /// [text] [readsAsWritten].
  List<String>? romanize(String text) {
    if (readsAsWritten(text) || !canRomanize(text)) return null;
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
        } else if (script == LyricsScript.cyrillic &&
            isCyrillicApostrophe(text, end)) {
          end++;
        } else {
          break;
        }
      }
      switch (script) {
        case LyricsScript.hangul:
          romanizeHangul(text, i, end, out);
        case LyricsScript.cyrillic:
          romanizeCyrillic(text, i, end, out, cyrillic);
        case LyricsScript.devanagari:
          romanizeDevanagari(text, i, end, out);
        case LyricsScript.gurmukhi:
          romanizeGurmukhi(text, i, end, out);
        case LyricsScript.kana:
          romanizeKana(text, i, end, out);
          cjk.fillRange(i, end, true);
        case LyricsScript.han:
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
