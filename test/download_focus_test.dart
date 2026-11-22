import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/home_shortcut.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/models/theme_settings.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/screens/settings/lyrics_settings_page.dart';
import 'package:mornye/screens/settings/playback_settings_page.dart';
import 'package:mornye/theme/app_theme.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/utils/settings_search_catalog.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _external = AppSettings(playerMode: 'external');

Future<void> _pump(
  WidgetTester tester,
  Widget page, {
  required AppSettings settings,
  bool mornye = false,
}) async {
  SharedPreferences.setMockInitialValues({});
  tester.view.physicalSize = const Size(400, 2400);
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
        localizationsDelegates: appLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: page,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<AppLocalizations> _l10n(WidgetTester tester) async {
  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: appLocalizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: const Scaffold(),
    ),
  );
  return AppLocalizations.of(tester.element(find.byType(Scaffold)));
}

void main() {
  group('Home shortcuts while another app plays', () {
    test('player tools are not offered', () {
      expect(
        HomeShortcut.available(player: false),
        isNot(containsAll(HomeShortcut.playerOnly)),
      );
      expect(HomeShortcut.available(player: true), HomeShortcut.values);
    });

    test('the defaults give way to the next usable shortcuts', () {
      final shown = HomeShortcut.resolve(
        const AppSettings().homeShortcuts,
        player: false,
      );
      expect(shown, hasLength(HomeShortcut.slotCount));
      expect(shown.toSet().intersection(HomeShortcut.playerOnly), isEmpty);
      expect(shown.first, HomeShortcut.networkStorage);
    });

    test('a saved choice keeps its usable shortcuts in order', () {
      expect(
        HomeShortcut.resolve([
          'loved',
          'equalizer',
          'link',
          'shuffle',
        ], player: false).take(2),
        [HomeShortcut.loved, HomeShortcut.link],
      );
    });
  });

  group('Settings search while another app plays', () {
    testWidgets('lists the player choice and no player settings', (
      tester,
    ) async {
      final l10n = await _l10n(tester);
      final catalog = SettingsSearchCatalog(l10n, builtInPlayer: false);
      final all = SettingsSearchCatalog(l10n);
      Set<String> titles(List<SettingsSearchEntry> entries) => {
        for (final entry in entries) entry.title,
      };

      expect(titles(catalog.playback), {
        l10n.libraryExternalPlayer,
        l10n.libraryBuiltInPreviewPlayer,
      });
      expect(all.playback.length, greaterThan(catalog.playback.length));

      final lyrics = titles(catalog.lyrics);
      expect(lyrics, isNot(contains(l10n.lyricsKeepScreenOn)));
      expect(lyrics, isNot(contains(l10n.lyricsPlayerPreview)));
      expect(lyrics, isNot(contains(l10n.lyricsRomanize)));
      expect(lyrics, contains(l10n.optionsEmbedLyrics));
      expect(lyrics, contains(l10n.lyricsAiTranslation));

      expect(
        titles(catalog.appearance),
        isNot(contains(l10n.homeContinueListening)),
      );
      expect(titles(all.appearance), contains(l10n.homeContinueListening));
      expect(titles(catalog.appearance), contains(l10n.homeRecommendedForYou));
    });
  });

  group('Playback settings', () {
    for (final mornye in [false, true]) {
      testWidgets('another app leaves only the player choice '
          '(Mornye=$mornye)', (tester) async {
        await _pump(
          tester,
          const PlaybackSettingsPage(),
          settings: _external,
          mornye: mornye,
        );
        final l10n = AppLocalizations.of(
          tester.element(find.byType(PlaybackSettingsPage)),
        );

        expect(find.text(l10n.libraryExternalPlayer), findsOneWidget);
        expect(find.text(l10n.libraryBuiltInPreviewPlayer), findsOneWidget);
        expect(find.text(l10n.playbackExternalHidden), findsOneWidget);
        expect(find.text(l10n.equalizerTitle), findsNothing);
        expect(find.text(l10n.gaplessPlayback), findsNothing);
        expect(find.text(l10n.listeningStats), findsNothing);
      });
    }

    testWidgets('the built-in player keeps its settings and shows no note', (
      tester,
    ) async {
      await _pump(
        tester,
        const PlaybackSettingsPage(),
        settings: const AppSettings(),
      );
      final l10n = AppLocalizations.of(
        tester.element(find.byType(PlaybackSettingsPage)),
      );

      expect(find.text(l10n.playbackExternalHidden), findsNothing);
      expect(find.text(l10n.equalizerTitle), findsOneWidget);
    });

    testWidgets('choosing the built-in player brings the settings back', (
      tester,
    ) async {
      await _pump(tester, const PlaybackSettingsPage(), settings: _external);
      final l10n = AppLocalizations.of(
        tester.element(find.byType(PlaybackSettingsPage)),
      );

      await tester.tap(find.text(l10n.libraryBuiltInPreviewPlayer));
      await tester.pumpAndSettle();

      expect(find.text(l10n.playbackExternalHidden), findsNothing);
      expect(find.text(l10n.equalizerTitle), findsOneWidget);
    });
  });

  group('Lyrics settings', () {
    testWidgets('another app keeps what is saved with a download', (
      tester,
    ) async {
      await _pump(tester, const LyricsSettingsPage(), settings: _external);
      final l10n = AppLocalizations.of(
        tester.element(find.byType(LyricsSettingsPage)),
      );

      expect(find.text(l10n.lyricsKeepScreenOn), findsNothing);
      expect(find.text(l10n.lyricsPlayerPreview), findsNothing);
      expect(find.text(l10n.lyricsRomanize), findsNothing);
      expect(find.text(l10n.lyricsAiTranslation), findsOneWidget);
      expect(find.text(l10n.optionsEmbedLyrics), findsOneWidget);
    });

    testWidgets('the built-in player keeps its lyrics view settings', (
      tester,
    ) async {
      await _pump(
        tester,
        const LyricsSettingsPage(),
        settings: const AppSettings(),
      );
      final l10n = AppLocalizations.of(
        tester.element(find.byType(LyricsSettingsPage)),
      );

      expect(find.text(l10n.lyricsKeepScreenOn), findsOneWidget);
      expect(find.text(l10n.lyricsPlayerPreview), findsOneWidget);
    });
  });
}
