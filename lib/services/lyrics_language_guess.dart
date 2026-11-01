/// Which language a song's lyrics are in, from their script and their most
/// common words, so automatic translation skips songs already in the
/// target language. It answers only when the text settles it; anything
/// unclear (a mixed song, a script several languages share) stays with
/// the model.
library;

enum _Script {
  latin,
  greek,
  cyrillic,
  hebrew,
  arabic,
  devanagari,
  bengali,
  gurmukhi,
  gujarati,
  tamil,
  telugu,
  kannada,
  malayalam,
  thai,
  hangul,
  kana,
  han,
}

_Script? _scriptOf(int rune) {
  if ((rune >= 0x41 && rune <= 0x5A) ||
      (rune >= 0x61 && rune <= 0x7A) ||
      (rune >= 0xC0 && rune <= 0x24F && rune != 0xD7 && rune != 0xF7) ||
      (rune >= 0x1E00 && rune <= 0x1EFF)) {
    return _Script.latin;
  }
  if ((rune >= 0x370 && rune <= 0x3FF) || (rune >= 0x1F00 && rune <= 0x1FFF)) {
    return _Script.greek;
  }
  if (rune >= 0x400 && rune <= 0x52F) return _Script.cyrillic;
  if (rune >= 0x5D0 && rune <= 0x5F4) return _Script.hebrew;
  if ((rune >= 0x620 && rune <= 0x6FF) ||
      (rune >= 0x750 && rune <= 0x77F) ||
      (rune >= 0xFB50 && rune <= 0xFDFF) ||
      (rune >= 0xFE70 && rune <= 0xFEFF)) {
    return _Script.arabic;
  }
  if (rune >= 0x900 && rune <= 0x97F) return _Script.devanagari;
  if (rune >= 0x980 && rune <= 0x9FF) return _Script.bengali;
  if (rune >= 0xA00 && rune <= 0xA7F) return _Script.gurmukhi;
  if (rune >= 0xA80 && rune <= 0xAFF) return _Script.gujarati;
  if (rune >= 0xB80 && rune <= 0xBFF) return _Script.tamil;
  if (rune >= 0xC00 && rune <= 0xC7F) return _Script.telugu;
  if (rune >= 0xC80 && rune <= 0xCFF) return _Script.kannada;
  if (rune >= 0xD00 && rune <= 0xD7F) return _Script.malayalam;
  if (rune >= 0xE00 && rune <= 0xE7F) return _Script.thai;
  if ((rune >= 0x1100 && rune <= 0x11FF) ||
      (rune >= 0x3130 && rune <= 0x318F) ||
      (rune >= 0xAC00 && rune <= 0xD7AF)) {
    return _Script.hangul;
  }
  if ((rune >= 0x3040 && rune <= 0x30FF) ||
      (rune >= 0x31F0 && rune <= 0x31FF) ||
      (rune >= 0xFF66 && rune <= 0xFF9F)) {
    return _Script.kana;
  }
  if ((rune >= 0x3400 && rune <= 0x4DBF) ||
      (rune >= 0x4E00 && rune <= 0x9FFF) ||
      (rune >= 0xF900 && rune <= 0xFAFF)) {
    return _Script.han;
  }
  return null;
}

/// The languages a script names on its own, among the translation targets.
const _scriptLanguages = {
  _Script.greek: 'el',
  _Script.hebrew: 'he',
  _Script.bengali: 'bn',
  _Script.gurmukhi: 'pa',
  _Script.gujarati: 'gu',
  _Script.tamil: 'ta',
  _Script.telugu: 'te',
  _Script.kannada: 'kn',
  _Script.malayalam: 'ml',
  _Script.thai: 'th',
  _Script.hangul: 'ko',
  _Script.kana: 'ja',
};

/// Frequent words of Latin-script languages that no other listed language
/// uses as often ("me", "de", "la" and the like are left out).
final _commonWords = {
  for (final MapEntry(:key, :value) in const {
    'en':
        "the you i and to my your it that of we all this with but just for "
        "be are can will know what when now never like got i'm don't can't "
        "it's you're",
    'id':
        'yang dan aku kau kamu engkau ini itu tak tidak akan dengan ku untuk '
        'ada dalam hanya saja bila jika tapi karena pun lagi sudah bisa ke '
        'dari kita kami mereka apa selalu semua hati cinta ingin jangan '
        'masih belum',
    'es':
        'el los las yo y pero muy más sin cuando donde tengo estoy ya hay '
        'soy qué eres quiero corazón cómo puedo mí tú nos',
    'pt':
        'não eu você meu minha é os na com mais pra seu quero também '
        'coração ela ele estou nós tem vou sou agora onde ao isso tudo então',
    'fr':
        "je les et est pas dans pour avec mon moi toi vous nous une des au "
        "ce c'est j'ai suis tout sur elle sans comme oui être rien jamais "
        "toujours encore cœur amour",
    'de':
        'ich und nicht ist das der ein eine mit mich mir dich dir wir sie '
        'auf zu wie noch nur aber auch sein kein immer bin bist hab habe '
        'wenn dann mein dein herz liebe nie',
    'it':
        'il di che per sono ti ma gli della del nel una io sei è più anche '
        'questo quello cosa perché amore cuore niente mai ancora voglio',
    'nl':
        'ik het een niet dat van mijn jij wij ze voor maar ook nog naar wat '
        'zijn mij jou hou nooit altijd weet',
  }.entries)
    key: value.split(' ').toSet(),
};

final _word = RegExp(r"[\p{L}']+", unicode: true);

/// The language of [texts] (one song's lines): a base language code
/// (`en`, `ja`), or `zh-Hans` and `zh-Hant` for Chinese. Null when the
/// text is short, mixes scripts or does not settle it.
String? guessLyricsLanguage(List<String> texts) {
  final text = texts.join('\n');
  final counts = <_Script, int>{};
  var letters = 0;
  for (final rune in text.runes) {
    final script = _scriptOf(rune);
    if (script == null) continue;
    counts[script] = (counts[script] ?? 0) + 1;
    letters++;
  }
  if (letters < 40) return null;
  // Japanese writes kanji among its kana.
  final kana = counts[_Script.kana] ?? 0;
  final han = counts[_Script.han] ?? 0;
  if (kana > 0 && kana * 10 >= kana + han) {
    counts[_Script.kana] = kana + han;
    counts.remove(_Script.han);
  }
  final (script, count) = counts.entries.fold<(_Script?, int)>((
    null,
    0,
  ), (best, entry) => entry.value > best.$2 ? (entry.key, entry.value) : best);
  if (script == null || count < letters * 0.85) return null;
  return switch (script) {
    _Script.latin => _latinLanguage(text),
    _Script.cyrillic => _cyrillicLanguage(text.toLowerCase()),
    _Script.arabic => _arabicLanguage(text),
    _Script.han => _chineseScript(text),
    // Hindi and Marathi share it.
    _Script.devanagari => null,
    _ => _scriptLanguages[script],
  };
}

/// Whether [texts] are already in the translation target [code]. False
/// when unsure, so an unclear song is still translated.
bool lyricsAlreadyIn(List<String> texts, String code) {
  final guess = guessLyricsLanguage(texts);
  if (guess == null) return false;
  if (guess.startsWith('zh')) return guess.toLowerCase() == code.toLowerCase();
  return guess == code.split('-').first.toLowerCase();
}

String? _latinLanguage(String text) {
  final words = _word
      .allMatches(text.toLowerCase().replaceAll('’', "'"))
      .map((match) => match[0]!.replaceAll(RegExp(r"^'+|'+$"), ''))
      .where((word) => word.isNotEmpty)
      .toList();
  if (words.length < 20) return null;
  String? best;
  var bestHits = 0;
  var secondHits = 0;
  for (final MapEntry(key: language, value: common) in _commonWords.entries) {
    final hits = words.where(common.contains).length;
    if (hits > bestHits) {
      secondHits = bestHits;
      bestHits = hits;
      best = language;
    } else if (hits > secondHits) {
      secondHits = hits;
    }
  }
  if (bestHits < 8 || bestHits < words.length * 0.12) return null;
  return bestHits >= secondHits * 3 ? best : null;
}

int _countOf(String text, String letters) =>
    text.runes.where(letters.runes.toSet().contains).length;

String? _cyrillicLanguage(String text) {
  if (_countOf(text, 'ђјљњћџ') >= 3) return 'sr';
  if (_countOf(text, 'әғқңөұүһ') >= 3) return 'kk';
  final ukrainian = _countOf(text, 'іїєґ');
  final russian = _countOf(text, 'ыэё');
  if (ukrainian >= 5 && russian * 10 <= ukrainian) return 'uk';
  if (russian >= 5 && ukrainian * 10 <= russian) return 'ru';
  if (ukrainian == 0 && russian == 0 && _countOf(text, 'ъ') >= 5) return 'bg';
  return null;
}

String? _arabicLanguage(String text) {
  if (_countOf(text, 'ٹڈڑںے') >= 3) return 'ur';
  // Persian writes yeh as U+06CC, Arabic as U+064A.
  final persian = _countOf(text, 'ی');
  final arabic = _countOf(text, 'ي');
  if (persian >= 5 && arabic * 10 <= persian) return 'fa';
  if (arabic >= 5 && persian * 10 <= arabic) {
    return _countOf(text, 'پچژگ') >= 3 ? null : 'ar';
  }
  return null;
}

/// Characters that differ between simplified and traditional Chinese,
/// paired by position.
const _simplified = '们这说为来时个爱会过还没让么开后头见门问间听东车长发从对风无语';
const _traditional = '們這說為來時個愛會過還沒讓麼開後頭見門問間聽東車長發從對風無語';

String? _chineseScript(String text) {
  final simplified = _countOf(text, _simplified);
  final traditional = _countOf(text, _traditional);
  if (simplified >= 5 && traditional * 4 <= simplified) return 'zh-Hans';
  if (traditional >= 5 && simplified * 4 <= traditional) return 'zh-Hant';
  return null;
}
