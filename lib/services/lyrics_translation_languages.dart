import 'dart:ui';

/// A translation target: a BCP-47 tag, its own name for display and its
/// English name for the prompt.
class LyricsTranslationLanguage {
  const LyricsTranslationLanguage(this.code, this.nativeName, this.englishName);

  final String code;
  final String nativeName;
  final String englishName;
}

/// Major languages, sorted by English name. Names are endonyms, so they are
/// not localized.
const lyricsTranslationLanguages = <LyricsTranslationLanguage>[
  LyricsTranslationLanguage('af', 'Afrikaans', 'Afrikaans'),
  LyricsTranslationLanguage('ar', 'العربية', 'Arabic'),
  LyricsTranslationLanguage('bn', 'বাংলা', 'Bengali'),
  LyricsTranslationLanguage('bg', 'Български', 'Bulgarian'),
  LyricsTranslationLanguage('ca', 'Català', 'Catalan'),
  LyricsTranslationLanguage('zh-Hans', '简体中文', 'Chinese (Simplified)'),
  LyricsTranslationLanguage('zh-Hant', '繁體中文', 'Chinese (Traditional)'),
  LyricsTranslationLanguage('hr', 'Hrvatski', 'Croatian'),
  LyricsTranslationLanguage('cs', 'Čeština', 'Czech'),
  LyricsTranslationLanguage('da', 'Dansk', 'Danish'),
  LyricsTranslationLanguage('nl', 'Nederlands', 'Dutch'),
  LyricsTranslationLanguage('en', 'English', 'English'),
  LyricsTranslationLanguage('et', 'Eesti', 'Estonian'),
  LyricsTranslationLanguage('fil', 'Filipino', 'Filipino'),
  LyricsTranslationLanguage('fi', 'Suomi', 'Finnish'),
  LyricsTranslationLanguage('fr', 'Français', 'French'),
  LyricsTranslationLanguage('de', 'Deutsch', 'German'),
  LyricsTranslationLanguage('el', 'Ελληνικά', 'Greek'),
  LyricsTranslationLanguage('gu', 'ગુજરાતી', 'Gujarati'),
  LyricsTranslationLanguage('he', 'עברית', 'Hebrew'),
  LyricsTranslationLanguage('hi', 'हिन्दी', 'Hindi'),
  LyricsTranslationLanguage('hu', 'Magyar', 'Hungarian'),
  LyricsTranslationLanguage('id', 'Bahasa Indonesia', 'Indonesian'),
  LyricsTranslationLanguage('it', 'Italiano', 'Italian'),
  LyricsTranslationLanguage('ja', '日本語', 'Japanese'),
  LyricsTranslationLanguage('jv', 'Basa Jawa', 'Javanese'),
  LyricsTranslationLanguage('kn', 'ಕನ್ನಡ', 'Kannada'),
  LyricsTranslationLanguage('kk', 'Қазақ тілі', 'Kazakh'),
  LyricsTranslationLanguage('ko', '한국어', 'Korean'),
  LyricsTranslationLanguage('lv', 'Latviešu', 'Latvian'),
  LyricsTranslationLanguage('lt', 'Lietuvių', 'Lithuanian'),
  LyricsTranslationLanguage('ms', 'Bahasa Melayu', 'Malay'),
  LyricsTranslationLanguage('ml', 'മലയാളം', 'Malayalam'),
  LyricsTranslationLanguage('mr', 'मराठी', 'Marathi'),
  LyricsTranslationLanguage('nb', 'Norsk bokmål', 'Norwegian Bokmål'),
  LyricsTranslationLanguage('fa', 'فارسی', 'Persian'),
  LyricsTranslationLanguage('pl', 'Polski', 'Polish'),
  LyricsTranslationLanguage(
    'pt-BR',
    'Português (Brasil)',
    'Portuguese (Brazil)',
  ),
  LyricsTranslationLanguage(
    'pt-PT',
    'Português (Portugal)',
    'Portuguese (Portugal)',
  ),
  LyricsTranslationLanguage('pa', 'ਪੰਜਾਬੀ', 'Punjabi'),
  LyricsTranslationLanguage('ro', 'Română', 'Romanian'),
  LyricsTranslationLanguage('ru', 'Русский', 'Russian'),
  LyricsTranslationLanguage('sr', 'Српски', 'Serbian'),
  LyricsTranslationLanguage('sk', 'Slovenčina', 'Slovak'),
  LyricsTranslationLanguage('sl', 'Slovenščina', 'Slovenian'),
  LyricsTranslationLanguage('es', 'Español', 'Spanish'),
  LyricsTranslationLanguage(
    'es-419',
    'Español (Latinoamérica)',
    'Spanish (Latin America)',
  ),
  LyricsTranslationLanguage('sw', 'Kiswahili', 'Swahili'),
  LyricsTranslationLanguage('sv', 'Svenska', 'Swedish'),
  LyricsTranslationLanguage('ta', 'தமிழ்', 'Tamil'),
  LyricsTranslationLanguage('te', 'తెలుగు', 'Telugu'),
  LyricsTranslationLanguage('th', 'ไทย', 'Thai'),
  LyricsTranslationLanguage('tr', 'Türkçe', 'Turkish'),
  LyricsTranslationLanguage('uk', 'Українська', 'Ukrainian'),
  LyricsTranslationLanguage('ur', 'اردو', 'Urdu'),
  LyricsTranslationLanguage('uz', 'Oʻzbekcha', 'Uzbek'),
  LyricsTranslationLanguage('vi', 'Tiếng Việt', 'Vietnamese'),
];

LyricsTranslationLanguage? lyricsTranslationLanguageFor(String code) {
  for (final language in lyricsTranslationLanguages) {
    if (language.code.toLowerCase() == code.toLowerCase()) return language;
  }
  return null;
}

/// The closest listed language to [locale]: an exact tag, then the
/// script or region variants Chinese and Portuguese need, then the bare
/// language. Falls back to English.
LyricsTranslationLanguage lyricsTranslationLanguageForLocale(Locale locale) {
  final language = locale.languageCode.toLowerCase();
  final region = locale.countryCode?.toUpperCase();
  final script = locale.scriptCode;
  if (language == 'zh') {
    final traditional =
        script == 'Hant' || const {'TW', 'HK', 'MO'}.contains(region);
    return lyricsTranslationLanguageFor(traditional ? 'zh-Hant' : 'zh-Hans')!;
  }
  if (language == 'pt') {
    return lyricsTranslationLanguageFor(region == 'BR' ? 'pt-BR' : 'pt-PT')!;
  }
  if (language == 'no' || language == 'nn') {
    return lyricsTranslationLanguageFor('nb')!;
  }
  if (language == 'tl') return lyricsTranslationLanguageFor('fil')!;
  if (language == 'in') return lyricsTranslationLanguageFor('id')!;
  if (language == 'iw') return lyricsTranslationLanguageFor('he')!;
  return lyricsTranslationLanguageFor(language) ??
      lyricsTranslationLanguageFor('en')!;
}

/// Parses the app's `locale` setting (`system`, `en`, `pt_PT`, `zh_CN`).
Locale? localeFromAppSetting(String value) {
  if (value.isEmpty || value == 'system') return null;
  final parts = value.split(RegExp('[-_]'));
  return Locale(parts.first, parts.length > 1 ? parts[1] : null);
}
