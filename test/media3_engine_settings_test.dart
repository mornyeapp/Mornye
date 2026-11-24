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
import 'package:mornye/utils/android_tv.dart';
import 'package:mornye/utils/settings_search_catalog.dart';
import 'package:mornye/widgets/beta_badge.dart';
import 'package:mornye/widgets/settings_group.dart';

const _title = 'New playback engine';

Future<ProviderContainer> _pumpPage(
  WidgetTester tester, {
  required bool mornye,
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

Finder get _switchFinder => find.byWidgetPredicate(
  (widget) => widget is SettingsSwitchItem && widget.title == _title,
);

void main() {
  tearDown(() => debugAndroidAudioSettingsOverride = null);

  test('the setting defaults to off and round-trips through JSON', () {
    expect(const AppSettings().media3Engine, isFalse);
    expect(AppSettings.fromJson(const {}).media3Engine, isFalse);
    final on = const AppSettings().copyWith(media3Engine: true);
    expect(on.toJson()['media3Engine'], isTrue);
    expect(AppSettings.fromJson(on.toJson()).media3Engine, isTrue);
    // A saved choice survives the default.
    expect(
      AppSettings.fromJson(const {'media3Engine': true}).media3Engine,
      isTrue,
    );
  });

  for (final mornye in [false, true]) {
    testWidgets('Android offers the engine as a beta switch ($mornye)', (
      tester,
    ) async {
      debugAndroidAudioSettingsOverride = true;
      final container = await _pumpPage(tester, mornye: mornye);
      await tester.scrollUntilVisible(
        _switchFinder,
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      final item = tester.widget<SettingsSwitchItem>(_switchFinder);
      expect(item.value, isFalse);
      expect(item.titleTrailing, isA<BetaBadge>());
      expect(
        item.subtitle,
        startsWith("Plays through the app's own engine instead of the phone's"),
      );

      await tester.tap(find.text(_title));
      await tester.pumpAndSettle();
      expect(container.read(settingsProvider).media3Engine, isTrue);
      expect(tester.widget<SettingsSwitchItem>(_switchFinder).value, isTrue);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('other platforms do not show it', (tester) async {
    debugAndroidAudioSettingsOverride = false;
    await _pumpPage(tester, mornye: false);
    for (var i = 0; i < 10; i++) {
      await tester.drag(find.byType(Scrollable).first, const Offset(0, -600));
      await tester.pumpAndSettle();
      expect(_switchFinder, findsNothing);
    }
  });

  testWidgets('settings search lists it with the Android audio options', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const Scaffold(),
      ),
    );
    final l10n = AppLocalizations.of(tester.element(find.byType(Scaffold)));
    bool listed({required bool androidAudio}) => SettingsSearchCatalog(
      l10n,
      androidAudio: androidAudio,
    ).playback.any((entry) => entry.title == l10n.newPlaybackEngine);
    expect(listed(androidAudio: true), isTrue);
    expect(listed(androidAudio: false), isFalse);
    bool skipListed({required bool androidAudio}) => SettingsSearchCatalog(
      l10n,
      androidAudio: androidAudio,
    ).playback.any((entry) => entry.title == l10n.skipSilence);
    expect(skipListed(androidAudio: true), isTrue);
    expect(skipListed(androidAudio: false), isFalse);
  });

  test('skip silence defaults to off and round-trips through JSON', () {
    expect(const AppSettings().skipSilence, isFalse);
    expect(AppSettings.fromJson(const {}).skipSilence, isFalse);
    final on = const AppSettings().copyWith(skipSilence: true);
    expect(on.toJson()['skipSilence'], isTrue);
    expect(AppSettings.fromJson(on.toJson()).skipSilence, isTrue);
  });

  Finder skipSwitch() => find.byWidgetPredicate(
    (widget) => widget is SettingsSwitchItem && widget.title == 'Skip silence',
  );

  for (final mornye in [false, true]) {
    testWidgets('skip silence sits under the engine and needs it ($mornye)', (
      tester,
    ) async {
      debugAndroidAudioSettingsOverride = true;
      final container = await _pumpPage(
        tester,
        mornye: mornye,
        settings: const AppSettings(media3Engine: true),
      );
      await tester.scrollUntilVisible(
        skipSwitch(),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      var item = tester.widget<SettingsSwitchItem>(skipSwitch());
      expect(item.value, isFalse);
      expect(item.enabled, isTrue);
      expect(item.subtitle, startsWith('Jumps over silent parts of songs.'));

      await tester.tap(find.text('Skip silence'));
      await tester.pumpAndSettle();
      expect(container.read(settingsProvider).skipSilence, isTrue);

      await tester.tap(find.text(_title));
      await tester.pumpAndSettle();
      item = tester.widget<SettingsSwitchItem>(skipSwitch());
      expect(item.enabled, isFalse);
      expect(item.subtitle, contains('Turn on the new playback engine'));
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('skip silence says AutoMix suspends it', (tester) async {
    debugAndroidAudioSettingsOverride = true;
    await _pumpPage(
      tester,
      mornye: false,
      settings: const AppSettings(
        media3Engine: true,
        autoMix: true,
        skipSilence: true,
      ),
    );
    await tester.scrollUntilVisible(
      skipSwitch(),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    final item = tester.widget<SettingsSwitchItem>(skipSwitch());
    expect(item.subtitle, endsWith('Off while AutoMix is on.'));
  });

  testWidgets('Android TV does not show skip silence', (tester) async {
    debugAndroidAudioSettingsOverride = true;
    debugAndroidTvOverride = true;
    addTearDown(() => debugAndroidTvOverride = null);
    await _pumpPage(tester, mornye: false);
    await tester.scrollUntilVisible(
      _switchFinder,
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    expect(skipSwitch(), findsNothing);
  });
}
