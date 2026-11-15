import 'package:material_ui/material_ui.dart';
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
import 'package:mornye/utils/settings_search_catalog.dart';
import 'package:mornye/widgets/settings_group.dart';

Future<ProviderContainer> _pumpPage(
  WidgetTester tester, {
  required bool mornye,
}) async {
  SharedPreferences.setMockInitialValues({});
  tester.view.physicalSize = const Size(1200, 1600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final container = ProviderContainer(
    overrides: [initialSettingsProvider.overrideWithValue(const AppSettings())],
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

Finder _switch(String title) => find.byWidgetPredicate(
  (widget) => widget is SettingsSwitchItem && widget.title == title,
);

Future<void> _scrollTo(WidgetTester tester, Finder finder) async {
  await tester.scrollUntilVisible(
    finder,
    300,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.pumpAndSettle();
}

void main() {
  for (final mornye in [false, true]) {
    testWidgets('No duplicates in queue is a Playback switch ($mornye)', (
      tester,
    ) async {
      final container = await _pumpPage(tester, mornye: mornye);
      final finder = _switch('No duplicates in queue');
      await _scrollTo(tester, finder);
      expect(tester.widget<SettingsSwitchItem>(finder).value, isFalse);

      await tester.tap(find.text('No duplicates in queue'));
      await tester.pumpAndSettle();
      expect(container.read(settingsProvider).queueNoDuplicates, isTrue);
      expect(tester.widget<SettingsSwitchItem>(finder).value, isTrue);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('settings search lists the queue options', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const Scaffold(),
      ),
    );
    final l10n = AppLocalizations.of(tester.element(find.byType(Scaffold)));
    final titles = {
      for (final entry in SettingsSearchCatalog(l10n).playback) entry.title,
    };
    expect(titles, contains(l10n.queueNoDuplicates));
    expect(titles, contains(l10n.queueLock));
  });

  testWidgets('Lock queue is in Playback settings too', (tester) async {
    final container = await _pumpPage(tester, mornye: false);
    final finder = _switch('Lock queue');
    await _scrollTo(tester, finder);
    await tester.tap(find.text('Lock queue'));
    await tester.pumpAndSettle();
    expect(container.read(settingsProvider).queueLocked, isTrue);
    expect(tester.widget<SettingsSwitchItem>(finder).value, isTrue);
  });
}
