import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/models/theme_settings.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/screens/settings/playback_settings_page.dart';
import 'package:mornye/theme/app_theme.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/utils/android_tv.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:mornye/utils/settings_search_catalog.dart';
import 'package:mornye/widgets/settings_group.dart';

const _title = 'Resume when headphones reconnect';

Future<ProviderContainer> _pumpPage(
  WidgetTester tester, {
  bool mornye = false,
  AppSettings settings = const AppSettings(),
}) async {
  SharedPreferences.setMockInitialValues({});
  tester.view.physicalSize = const Size(1200, 1600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final container = ProviderContainer(
    overrides: [initialSettingsProvider.overrideWithValue(settings)],
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
  await tester.pumpAndSettle();
  return container;
}

Finder _switch() => find.byWidgetPredicate(
  (widget) => widget is SettingsSwitchItem && widget.title == _title,
);

Future<void> _scrollToHeadphones(WidgetTester tester) async {
  await tester.scrollUntilVisible(
    find.text('Play when headphones connect'),
    300,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.pumpAndSettle();
}

Future<Set<String>> _searchTitles(WidgetTester tester) async {
  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: const Scaffold(),
    ),
  );
  final l10n = AppLocalizations.of(tester.element(find.byType(Scaffold)));
  return {
    for (final entry in SettingsSearchCatalog(l10n).playback) entry.title,
  };
}

void main() {
  tearDown(() {
    debugAndroidTvOverride = null;
    debugDesktopPlatformOverride = null;
  });

  for (final mornye in [false, true]) {
    testWidgets('a phone shows the switch, off by default ($mornye)', (
      tester,
    ) async {
      final container = await _pumpPage(tester, mornye: mornye);
      await _scrollToHeadphones(tester);
      await tester.scrollUntilVisible(
        _switch(),
        100,
        scrollable: find.byType(Scrollable).first,
      );
      expect(tester.widget<SettingsSwitchItem>(_switch()).value, isFalse);
      await tester.tap(find.text(_title));
      await tester.pumpAndSettle();
      expect(container.read(settingsProvider).resumeOnOutputReconnect, isTrue);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('Play when headphones connect already covers it', (tester) async {
    await _pumpPage(
      tester,
      settings: const AppSettings(playOnHeadphonesConnected: true),
    );
    await _scrollToHeadphones(tester);
    await tester.scrollUntilVisible(
      _switch(),
      100,
      scrollable: find.byType(Scrollable).first,
    );
    final item = tester.widget<SettingsSwitchItem>(_switch());
    expect(item.enabled, isFalse);
    expect(item.subtitle, contains('already resumes on every connection'));
  });

  testWidgets('Android TV and desktop hide it', (tester) async {
    debugAndroidTvOverride = true;
    await _pumpPage(tester);
    await _scrollToHeadphones(tester);
    expect(_switch(), findsNothing);
    expect(await _searchTitles(tester), isNot(contains(_title)));

    debugAndroidTvOverride = null;
    debugDesktopPlatformOverride = true;
    expect(await _searchTitles(tester), isNot(contains(_title)));
  });

  testWidgets('settings search finds it on a phone', (tester) async {
    expect(await _searchTitles(tester), contains(_title));
  });
}
