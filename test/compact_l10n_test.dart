import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/app_localizations.dart';
import 'package:mornye/l10n/app_localizations_en.dart';
import 'package:mornye/l10n/supported_locales.dart';

void main() {
  test('generated supportedLocales matches filteredSupportedLocales', () {
    expect(
      AppLocalizations.supportedLocales.toSet(),
      equals(filteredSupportedLocales.toSet()),
    );
    expect(AppLocalizations.supportedLocales, hasLength(13));
  });

  test('all active locales and language fallbacks resolve and inherit en', () {
    final en = lookupAppLocalizations(const Locale('en'));
    for (final locale in [
      ...filteredSupportedLocales,
      const Locale('es'),
      const Locale('pt'),
      const Locale('zh'),
    ]) {
      final l10n = lookupAppLocalizations(locale);
      expect(l10n, isA<AppLocalizationsEn>(), reason: '$locale');
      expect(l10n.settingsTitle, isNotEmpty, reason: '$locale');
      expect(
        l10n.libraryLyricsSearchDescription,
        isNotEmpty,
        reason: '$locale',
      );
      expect(l10n.libraryLyricsIndexing(3), isNotEmpty, reason: '$locale');
    }

    // Spot-check that translated locales still emit their localized strings
    // while untranslated keys inherit cleanly from English.
    final id = lookupAppLocalizations(const Locale('id'));
    expect(id.appearanceInterfaceSize, isNot(en.appearanceInterfaceSize));
    final zh = lookupAppLocalizations(const Locale('zh', 'CN'));
    expect(zh.settingsTitle, isNot(en.settingsTitle));
    final es = lookupAppLocalizations(const Locale('es', 'ES'));
    expect(es.settingsTitle, isNot(en.settingsTitle));
    final pt = lookupAppLocalizations(const Locale('pt', 'PT'));
    expect(pt.settingsTitle, isNot(en.settingsTitle));
  });
}
