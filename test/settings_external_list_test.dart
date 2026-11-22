import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/models/theme_settings.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/screens/settings/playback_settings_page.dart';
import 'package:mornye/screens/settings/settings_tab.dart';
import 'package:mornye/services/app_remote_config_service.dart';
import 'package:mornye/theme/app_theme.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _external = AppSettings(playerMode: 'external');
const _playerRow = ValueKey('settings-player-choice');

Future<ProviderContainer> _pump(
  WidgetTester tester, {
  required AppSettings settings,
  bool mornye = false,
  bool linkInUse = false,
  bool asPage = false,
  Size size = const Size(400, 2400),
}) async {
  SharedPreferences.setMockInitialValues({});
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final container = ProviderContainer(
    overrides: [
      initialSettingsProvider.overrideWithValue(settings),
      settingsLinkInUseProvider.overrideWithValue(linkInUse),
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
        localizationsDelegates: appLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: SettingsTab(
            asPage: asPage,
            remoteConfigService: AppRemoteConfigService(
              client: MockClient((_) async => http.Response('{}', 200)),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return container;
}

AppLocalizations _l10n(WidgetTester tester) =>
    AppLocalizations.of(tester.element(find.byType(SettingsTab)));

double _top(WidgetTester tester, String title) =>
    tester.getTopLeft(find.text(title)).dy;

void main() {
  tearDown(() => debugDesktopPlatformOverride = null);

  for (final mornye in [false, true]) {
    final style = mornye ? 'Mornye' : 'Material';

    testWidgets('$style: another app puts the download pages first and the '
        'player choice in the list', (tester) async {
      await _pump(tester, settings: _external, mornye: mornye);
      final l10n = _l10n(tester);

      expect(
        _top(tester, l10n.settingsDownload),
        lessThan(_top(tester, l10n.settingsLocalLibrary)),
      );
      expect(
        _top(tester, l10n.settingsLyrics),
        lessThan(_top(tester, l10n.settingsLocalLibrary)),
      );
      expect(
        _top(tester, l10n.settingsLocalLibrary),
        lessThan(_top(tester, l10n.settingsAppearance)),
      );
      expect(find.byKey(_playerRow), findsOneWidget);
      expect(find.text(l10n.libraryExternalPlayer), findsOneWidget);
      expect(find.text(l10n.libraryPlayback), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('$style: the built-in player keeps the usual list', (
      tester,
    ) async {
      await _pump(tester, settings: const AppSettings(), mornye: mornye);
      final l10n = _l10n(tester);

      expect(
        _top(tester, l10n.settingsAppearance),
        lessThan(_top(tester, l10n.settingsDownload)),
      );
      expect(find.byKey(_playerRow), findsNothing);
      expect(find.text(l10n.libraryPlayback), findsOneWidget);
    });

    testWidgets('$style: the player row brings the built-in player back', (
      tester,
    ) async {
      final container = await _pump(
        tester,
        settings: _external,
        mornye: mornye,
      );
      final l10n = _l10n(tester);

      await tester.tap(find.byKey(_playerRow));
      await tester.pumpAndSettle();
      // The choice opens over the list, not as a page.
      expect(find.byType(PlaybackSettingsPage), findsNothing);
      await tester.tap(find.text(l10n.libraryBuiltInPreviewPlayer));
      await tester.pumpAndSettle();

      expect(container.read(settingsProvider).playerMode, 'internal');
      expect(find.byKey(_playerRow), findsNothing);
      expect(find.text(l10n.libraryPlayback), findsOneWidget);
      expect(
        _top(tester, l10n.settingsAppearance),
        lessThan(_top(tester, l10n.settingsDownload)),
      );
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('a search result for the player opens the choice too', (
    tester,
  ) async {
    await _pump(tester, settings: _external);
    final l10n = _l10n(tester);

    await tester.enterText(
      find.byType(TextField),
      l10n.libraryBuiltInPreviewPlayer,
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(
        ValueKey(
          'settings-search:${l10n.libraryPlayback}:'
          '${l10n.libraryBuiltInPreviewPlayer}',
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(PlaybackSettingsPage), findsNothing);
    expect(find.text(l10n.libraryExternalPlayerSubtitle), findsOneWidget);
  });

  testWidgets('another app lists Link only once it is set up', (tester) async {
    debugDesktopPlatformOverride = true;
    await _pump(tester, settings: _external, asPage: true);
    final title = _l10n(tester).linkDesktopSettingsTitle;
    expect(find.text(title), findsNothing);

    await _pump(tester, settings: _external, asPage: true, linkInUse: true);
    expect(find.text(title), findsOneWidget);

    await _pump(tester, settings: const AppSettings(), asPage: true);
    expect(find.text(title), findsOneWidget);
  });

  testWidgets('the open category stays open when the list changes order', (
    tester,
  ) async {
    debugDesktopPlatformOverride = true;
    final semantics = tester.ensureSemantics();
    await _pump(tester, settings: _external, size: const Size(1400, 2400));
    final l10n = _l10n(tester);
    final playback = find.byKey(
      ValueKey('settings-category:${l10n.libraryPlayback}'),
    );

    await tester.tap(playback);
    await tester.pumpAndSettle();
    await tester.tap(find.text(l10n.libraryBuiltInPreviewPlayer));
    await tester.pumpAndSettle();

    expect(
      tester.getSemantics(
        find.descendant(of: playback, matching: find.byType(InkWell)),
      ),
      isSemantics(isSelected: true, hasTapAction: true),
    );
    expect(find.byType(PlaybackSettingsPage), findsOneWidget);
    semantics.dispose();
  });
}
