import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mornye/app.dart';
import 'package:mornye/constants/app_info.dart';
import 'package:mornye/l10n/app_localizations.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/screens/whats_new_screen.dart';
import 'package:mornye/theme/mornye_theme.dart';

class _Preferences implements SharedPreferences {
  final saved = <String, String>{};

  @override
  String? getString(String key) => saved[key];

  @override
  Future<bool> setString(String key, String value) async {
    saved[key] = value;
    return true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Settings extends SettingsNotifier {
  _Settings(this._initial, _Preferences preferences)
    : super(preferences: () async => preferences);

  final AppSettings _initial;

  @override
  AppSettings build() => _initial;

  @override
  Future<void> ensureLoaded() async {}
}

const _updated = AppSettings(isFirstLaunch: false, hasCompletedTutorial: true);

void main() {
  test('only an update shows the tour, after setup and the tutorial', () {
    expect(
      initialLocationForAppState(
        isFirstLaunch: false,
        hasCompletedTutorial: true,
        hasSeenWhatsNew: false,
      ),
      '/whats-new',
    );
    expect(
      initialLocationForAppState(
        isFirstLaunch: false,
        hasCompletedTutorial: true,
      ),
      '/',
    );
    expect(
      initialLocationForAppState(
        isFirstLaunch: true,
        hasCompletedTutorial: false,
        hasSeenWhatsNew: false,
      ),
      '/setup',
    );
    expect(
      initialLocationForAppState(
        isFirstLaunch: false,
        hasCompletedTutorial: false,
        hasSeenWhatsNew: false,
      ),
      '/tutorial',
    );
    // Settings saved by an older build have no tour mark.
    final older = AppSettings.fromJson(
      Map<String, dynamic>.from(_updated.toJson())..remove('whatsNewSeen'),
    );
    expect(older.whatsNewSeen, isNot(AppInfo.whatsNewRelease));
  });

  test('finishing setup marks the current tour seen', () async {
    final preferences = _Preferences();
    final container = ProviderContainer(
      overrides: [
        settingsProvider.overrideWith(
          () => _Settings(const AppSettings(), preferences),
        ),
      ],
    );
    addTearDown(container.dispose);

    await container.read(settingsProvider.notifier).setFirstLaunchComplete();

    expect(
      container.read(settingsProvider).whatsNewSeen,
      AppInfo.whatsNewRelease,
    );
    final saved = jsonDecode(preferences.saved['app_settings']!) as Map;
    expect(saved['whatsNewSeen'], AppInfo.whatsNewRelease);
  });

  test('pages list only the features this device has', () async {
    final l10n = await AppLocalizations.delegate.load(const Locale('en'));
    List<String> titles({required bool androidPhone, required bool desktop}) =>
        [
          for (final page in whatsNewHighlights(
            l10n,
            androidPhone: androidPhone,
            desktop: desktop,
          ))
            for (final feature in page.features) feature.title,
        ];

    final phone = titles(androidPhone: true, desktop: false);
    expect(phone, contains(l10n.whatsNewPlayerAutoTitle));
    expect(phone, isNot(contains(l10n.whatsNewPlayerExclusiveTitle)));
    final computer = titles(androidPhone: false, desktop: true);
    expect(computer, contains(l10n.whatsNewPlayerExclusiveTitle));
    expect(computer, isNot(contains(l10n.whatsNewPlayerAutoTitle)));
    final iPhone = titles(androidPhone: false, desktop: false);
    expect(iPhone, isNot(contains(l10n.whatsNewPlayerAutoTitle)));
    expect(iPhone, isNot(contains(l10n.whatsNewPlayerExclusiveTitle)));

    // The opening page names every section that follows it.
    final pages = whatsNewHighlights(l10n, androidPhone: true, desktop: false);
    expect(pages.first.title, 'Mornye ${AppInfo.whatsNewRelease} is here');
    expect(
      [for (final feature in pages.first.features) feature.title],
      [for (final page in pages.skip(1)) page.title],
    );
    expect(pages.first.features.every((f) => f.body == null), isTrue);
    expect(
      pages.skip(1).every((page) => page.features.every((f) => f.body != null)),
      isTrue,
    );
  });

  for (final mornye in [false, true]) {
    final style = mornye ? 'Mornye' : 'Material';

    Future<ProviderContainer> openTour(
      WidgetTester tester, {
      double textScale = 1,
    }) async {
      final container = ProviderContainer(
        overrides: [
          settingsProvider.overrideWith(
            () => _Settings(_updated, _Preferences()),
          ),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: mornye ? MornyeTheme.build(Brightness.light) : ThemeData(),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(textScale)),
              child: child!,
            ),
            home: Builder(
              builder: (context) => TextButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const WhatsNewScreen(),
                  ),
                ),
                child: const Text('about'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('about'));
      await tester.pumpAndSettle();
      return container;
    }

    testWidgets('$style tour pages through to Done and closes', (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final container = await openTour(tester);

      expect(find.text('Mornye ${AppInfo.whatsNewRelease} is here'), findsOne);
      expect(find.text('Skip for now'), findsOne);
      for (final title in [
        'Mornye Link',
        'A Home that learns',
        'Player and lyrics',
        'Library and search',
      ]) {
        await tester.tap(find.text('Next'));
        await tester.pumpAndSettle();
        expect(find.text(title), findsWidgets);
      }
      // Back steps to the previous page before it leaves the tour.
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('Player and lyrics'), findsWidgets);
      await tester.tap(find.text('Next'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Next'));
      await tester.pumpAndSettle();
      expect(find.text('Faster everywhere'), findsWidgets);
      expect(find.text('Next'), findsNothing);
      expect(container.read(settingsProvider).whatsNewSeen, isEmpty);

      await tester.tap(find.text('Start listening'));
      await tester.pumpAndSettle();
      expect(find.byType(WhatsNewScreen), findsNothing);
      expect(find.text('about'), findsOne);
      expect(
        container.read(settingsProvider).whatsNewSeen,
        AppInfo.whatsNewRelease,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('$style tour skips at once and fits a small phone', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(320, 568);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final container = await openTour(tester, textScale: 1.6);
      for (var page = 0; page < 5; page++) {
        expect(tester.takeException(), isNull);
        await tester.tap(find.text('Next'));
        await tester.pumpAndSettle();
      }
      expect(tester.takeException(), isNull);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      await tester.tap(find.text('Skip for now'));
      await tester.pumpAndSettle();
      expect(find.byType(WhatsNewScreen), findsNothing);
      expect(
        container.read(settingsProvider).whatsNewSeen,
        AppInfo.whatsNewRelease,
      );
    });
  }
}
