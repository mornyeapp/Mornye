import 'dart:convert';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/providers/extension_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/screens/settings/lyrics_settings_page.dart';
import 'package:mornye/theme/app_theme.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/utils/settings_search_catalog.dart';
import 'package:mornye/widgets/settings_group.dart';

class _Extensions extends ExtensionNotifier {
  @override
  ExtensionState build() => const ExtensionState();
}

void main() {
  test('best timing is on by default, also in settings saved before it', () {
    expect(const AppSettings().lyricsPreferBestTiming, isTrue);
    final legacy = const AppSettings().toJson()
      ..remove('lyricsPreferBestTiming');
    expect(AppSettings.fromJson(legacy).lyricsPreferBestTiming, isTrue);
    expect(
      const AppSettings().lyricsFetchOptions['prefer_best_timing'],
      isTrue,
    );
  });

  test('provider order only survives a round trip to the backend options', () {
    final off = const AppSettings().copyWith(lyricsPreferBestTiming: false);
    final decoded = AppSettings.fromJson(
      jsonDecode(jsonEncode(off.toJson())) as Map<String, dynamic>,
    );
    expect(decoded.lyricsPreferBestTiming, isFalse);
    expect(decoded.lyricsFetchOptions['prefer_best_timing'], isFalse);
  });

  for (final mornye in [false, true]) {
    testWidgets(
      'Best timing first follows provider priority (Mornye: $mornye)',
      (tester) async {
        SharedPreferences.setMockInitialValues({});
        tester.view.physicalSize = const Size(430, 1600);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final container = ProviderContainer(
          overrides: [
            initialSettingsProvider.overrideWithValue(const AppSettings()),
            extensionProvider.overrideWith(_Extensions.new),
          ],
        );
        addTearDown(container.dispose);
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              theme: mornye
                  ? MornyeTheme.build(Brightness.dark)
                  : AppTheme.light(),
              locale: const Locale('en'),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: const LyricsSettingsPage(),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final l10n = AppLocalizations.of(
          tester.element(find.byType(LyricsSettingsPage)),
        );
        final row = find.byWidgetPredicate(
          (widget) =>
              widget is SettingsSwitchItem &&
              widget.title == l10n.lyricsPreferBestTiming,
        );
        await tester.scrollUntilVisible(
          row,
          300,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.pumpAndSettle();
        final priority = find.byWidgetPredicate(
          (widget) =>
              widget is SettingsItem &&
              widget.title == l10n.lyricsProvidersTitle,
        );
        expect(
          tester.getTopLeft(priority).dy,
          lessThan(tester.getTopLeft(row).dy),
        );
        expect(tester.widget<SettingsSwitchItem>(row).value, isTrue);
        expect(find.text(l10n.lyricsPreferBestTimingEnabled), findsOneWidget);

        await tester.tap(find.text(l10n.lyricsPreferBestTiming));
        await tester.pumpAndSettle();
        expect(
          container.read(settingsProvider).lyricsPreferBestTiming,
          isFalse,
        );
        expect(tester.widget<SettingsSwitchItem>(row).value, isFalse);
        expect(find.text(l10n.lyricsPreferBestTimingDisabled), findsOneWidget);
        expect(
          container
              .read(settingsProvider)
              .lyricsFetchOptions['prefer_best_timing'],
          isFalse,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('settings search lists Best timing first', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const Scaffold(),
      ),
    );
    final l10n = AppLocalizations.of(tester.element(find.byType(Scaffold)));
    final titles = [
      for (final entry in SettingsSearchCatalog(l10n).lyrics) entry.title,
    ];
    expect(
      titles.indexOf(l10n.lyricsPreferBestTiming),
      titles.indexOf(l10n.lyricsProvidersTitle) + 1,
    );
  });
}
