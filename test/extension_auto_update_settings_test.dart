import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/models/theme_settings.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/screens/settings/app_settings_page.dart';
import 'package:mornye/theme/app_theme.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/utils/settings_search_catalog.dart';
import 'package:mornye/widgets/settings_group.dart';

const _title = 'Update extensions automatically';

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
        home: const AppSettingsPage(),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return container;
}

Finder get _switchFinder => find.byWidgetPredicate(
  (widget) => widget is SettingsSwitchItem && widget.title == _title,
);

void main() {
  test('the setting defaults to on and round-trips through JSON', () {
    expect(const AppSettings().autoUpdateExtensions, isTrue);
    expect(AppSettings.fromJson(const {}).autoUpdateExtensions, isTrue);
    final off = const AppSettings().copyWith(autoUpdateExtensions: false);
    expect(off.toJson()['autoUpdateExtensions'], isFalse);
    expect(AppSettings.fromJson(off.toJson()).autoUpdateExtensions, isFalse);
  });

  for (final mornye in [false, true]) {
    testWidgets('App settings offer the switch below the repo one ($mornye)', (
      tester,
    ) async {
      final container = await _pumpPage(tester, mornye: mornye);
      expect(_switchFinder, findsOneWidget);
      final item = tester.widget<SettingsSwitchItem>(_switchFinder);
      expect(item.value, isTrue);
      expect(
        item.subtitle,
        'Installs updates for enabled extensions in the background when no '
        'download is running.',
      );
      expect(
        tester.getTopLeft(find.text(_title)).dy,
        greaterThan(tester.getTopLeft(find.text('Extension Repo')).dy),
      );

      await tester.tap(find.text(_title));
      await tester.pumpAndSettle();
      expect(container.read(settingsProvider).autoUpdateExtensions, isFalse);
      expect(tester.widget<SettingsSwitchItem>(_switchFinder).value, isFalse);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('settings search lists it with the App options', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const Scaffold(),
      ),
    );
    final l10n = AppLocalizations.of(tester.element(find.byType(Scaffold)));
    final entry = SettingsSearchCatalog(
      l10n,
    ).app.where((entry) => entry.title == _title).single;
    expect(entry.matches(SettingsSearchQuery('auto update')), isTrue);
    expect(entry.matches(SettingsSearchQuery('extensions background')), isTrue);
  });
}
