// Hand-maintained list of locales offered in the UI.
// A locale is enabled once its Crowdin coverage reaches about 70 percent.
// Edit this list by hand when a locale crosses that threshold in either
// direction.

import 'package:flutter/widgets.dart';

/// List of locales that meet the translation threshold.
/// Only these languages will be available in the app.
const List<Locale> filteredSupportedLocales = <Locale>[
  Locale('en'),
  Locale('ko'),
  Locale('fr'),
  Locale('es', 'ES'),
  Locale('de'),
  Locale('uk'),
  Locale('ru'),
  Locale('tr'),
  Locale('id'),
  Locale('pt', 'PT'),
  Locale('ja'),
];

/// Set of locale codes for quick lookup.
const Set<String> filteredLocaleCodes = <String>{
  'en',
  'ko',
  'fr',
  'es_ES',
  'de',
  'uk',
  'ru',
  'tr',
  'id',
  'pt_PT',
  'ja',
};
