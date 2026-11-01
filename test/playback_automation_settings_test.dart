import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/models/theme_settings.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/screens/settings/playback_settings_page.dart';
import 'package:mornye/utils/settings_search_catalog.dart';
import 'package:mornye/theme/app_theme.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/widgets/settings_group.dart';

void main() {
  for (final mornye in [false, true]) {
    testWidgets('automatic controls persist in both themes ($mornye)', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final container = ProviderContainer(
        overrides: [
          initialSettingsProvider.overrideWithValue(
            const AppSettings(pauseOnMute: false),
          ),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: mornye
                ? MornyeTheme.build(Brightness.dark, accent: MornyeAccent.blue)
                : AppTheme.light(),
            locale: const Locale('en'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: const PlaybackSettingsPage(),
          ),
        ),
      );
      final muted = find.text('Pause when muted');
      final connected = find.text('Play when headphones connect');
      await tester.scrollUntilVisible(
        muted,
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.tap(muted);
      await tester.pumpAndSettle();
      await tester.ensureVisible(connected);
      await tester.pumpAndSettle();
      await tester.tap(connected);
      await tester.pumpAndSettle();
      expect(container.read(settingsProvider).pauseOnMute, isTrue);
      expect(
        container.read(settingsProvider).playOnHeadphonesConnected,
        isTrue,
      );
      final prefs = await SharedPreferences.getInstance();
      final saved = AppSettings.fromJson(
        jsonDecode(prefs.getString('app_settings')!) as Map<String, dynamic>,
      );
      expect(saved.pauseOnMute, isTrue);
      expect(saved.playOnHeadphonesConnected, isTrue);

      container.read(settingsProvider.notifier).setPlayerMode('external');
      await tester.pump();
      final automationControls = tester.widgetList<SettingsSwitchItem>(
        find.byWidgetPredicate(
          (widget) =>
              widget is SettingsSwitchItem &&
              const [
                'Pause when muted',
                'Play when headphones connect',
              ].contains(widget.title),
        ),
      );
      expect(automationControls, hasLength(2));
      expect(automationControls.every((widget) => !widget.enabled), isTrue);
      expect(tester.takeException(), isNull);

      final l10n = AppLocalizations.of(tester.element(connected));
      final catalog = SettingsSearchCatalog(l10n);
      expect(
        catalog.playback.any(
          (entry) => entry.matches(SettingsSearchQuery('mute')),
        ),
        isTrue,
      );
      expect(
        catalog.playback.any(
          (entry) => entry.matches(SettingsSearchQuery('earphone')),
        ),
        isTrue,
      );
    });

    testWidgets('Gapless playback yields to AutoMix ($mornye)', (tester) async {
      SharedPreferences.setMockInitialValues({});
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final container = ProviderContainer(
        overrides: [
          initialSettingsProvider.overrideWithValue(const AppSettings()),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: mornye
                ? MornyeTheme.build(Brightness.dark, accent: MornyeAccent.blue)
                : AppTheme.light(),
            locale: const Locale('en'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: const PlaybackSettingsPage(),
          ),
        ),
      );
      final gapless = find.text('Gapless playback');
      await tester.scrollUntilVisible(
        gapless,
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      SettingsSwitchItem item() => tester.widget<SettingsSwitchItem>(
        find.byWidgetPredicate(
          (widget) =>
              widget is SettingsSwitchItem &&
              widget.title == 'Gapless playback',
        ),
      );
      expect(item().value, isTrue);
      await tester.tap(gapless);
      await tester.pumpAndSettle();
      expect(container.read(settingsProvider).gaplessPlayback, isFalse);

      container.read(settingsProvider.notifier).setGaplessPlayback(true);
      container.read(settingsProvider.notifier).setAutoMix(true);
      await tester.pumpAndSettle();
      expect(item().enabled, isFalse);
      expect(item().value, isFalse);
      expect(tester.takeException(), isNull);

      final catalog = SettingsSearchCatalog(
        AppLocalizations.of(tester.element(gapless)),
      );
      expect(
        catalog.playback.any(
          (entry) => entry.matches(SettingsSearchQuery('gapless')),
        ),
        isTrue,
      );
    });

    testWidgets('Compact player is a Material option ($mornye)', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final container = ProviderContainer(
        overrides: [
          initialSettingsProvider.overrideWithValue(const AppSettings()),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: mornye
                ? MornyeTheme.build(Brightness.dark, accent: MornyeAccent.blue)
                : AppTheme.light(),
            locale: const Locale('en'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: const PlaybackSettingsPage(),
          ),
        ),
      );
      final compact = find.text('Compact player');
      await tester.scrollUntilVisible(
        compact,
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      final item = tester.widget<SettingsSwitchItem>(
        find.byWidgetPredicate(
          (widget) =>
              widget is SettingsSwitchItem && widget.title == 'Compact player',
        ),
      );
      expect(item.value, isFalse);
      expect(item.enabled, !mornye);
      if (!mornye) {
        await tester.tap(compact);
        await tester.pumpAndSettle();
        expect(container.read(settingsProvider).compactPlayer, isTrue);
        expect(
          AppSettings.fromJson(
            container.read(settingsProvider).toJson(),
          ).compactPlayer,
          isTrue,
        );
      }
      expect(tester.takeException(), isNull);
    });
  }
}
