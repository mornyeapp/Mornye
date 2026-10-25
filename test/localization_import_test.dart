import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/constants/language_choices.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/l10n/supported_locales.dart';

void main() {
  test('selectable languages have generated localizations', () async {
    for (final choice in supportedLanguageChoices) {
      if (choice.$1 == 'system') continue;
      final parts = choice.$1.split('_');
      final locale = Locale(parts.first, parts.length == 2 ? parts.last : null);
      expect(AppLocalizations.delegate.isSupported(locale), isTrue);
      final strings = await AppLocalizations.delegate.load(locale);
      expect(strings.settingsTitle, isNotEmpty);
    }
    expect(
      supportedLanguageChoices.map((choice) => choice.$1),
      containsAll(['vi', 'zh_CN']),
    );
  });

  test(
    'imported conversion labels keep format and quality arguments',
    () async {
      for (final locale in filteredSupportedLocales) {
        final strings = await AppLocalizations.delegate.load(locale);
        final lossless = strings.trackConvertActionLabelLossless(
          'SOURCE_FORMAT',
          'TARGET_FORMAT',
          'QUALITY',
        );
        final lossy = strings.trackConvertActionLabelLossy(
          'SOURCE_FORMAT',
          'TARGET_FORMAT',
          'BITRATE',
        );
        for (final value in ['SOURCE_FORMAT', 'TARGET_FORMAT', 'QUALITY']) {
          expect(lossless, contains(value), reason: locale.toString());
        }
        for (final value in ['SOURCE_FORMAT', 'TARGET_FORMAT', 'BITRATE']) {
          expect(lossy, contains(value), reason: locale.toString());
        }
      }
    },
  );

  test('duplicate warnings keep only the two count arguments', () async {
    for (final locale in filteredSupportedLocales) {
      final strings = await AppLocalizations.delegate.load(locale);
      final message = strings.duplicatesKeepBestAllMessage(19, 7);
      expect(message, contains('19'), reason: locale.toString());
      expect(message, contains('7'), reason: locale.toString());
    }
  });

  for (final (locale, title) in [
    (const Locale('vi'), 'Cài đặt'),
    (const Locale('zh', 'CN'), '设置'),
  ]) {
    testWidgets('new locale $locale loads through the app delegates', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          locale: locale,
          supportedLocales: filteredSupportedLocales,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          home: Builder(
            builder: (context) => Scaffold(
              body: Text(AppLocalizations.of(context).settingsTitle),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text(title), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
