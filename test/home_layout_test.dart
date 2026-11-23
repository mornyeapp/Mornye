import 'package:audio_service/audio_service.dart' show MediaItem;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mornye/l10n/app_localizations.dart';
import 'package:mornye/models/home_layout.dart';
import 'package:mornye/models/library_database_models.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/models/unified_library_item.dart';
import 'package:mornye/providers/download_history_provider.dart';
import 'package:mornye/providers/explore_provider.dart';
import 'package:mornye/providers/extension_provider.dart';
import 'package:mornye/providers/home_recommendations_provider.dart';
import 'package:mornye/providers/home_top_picks_provider.dart';
import 'package:mornye/providers/library_collections_provider.dart';
import 'package:mornye/providers/library_mixes_provider.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/providers/playback_provider.dart';
import 'package:mornye/providers/recent_access_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/providers/weekly_releases_provider.dart';
import 'package:mornye/screens/home_tab.dart';
import 'package:mornye/screens/settings/home_layout_page.dart';
import 'package:mornye/services/weekly_releases.dart';
import 'package:mornye/theme/app_theme.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/widgets/app_switch.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fixed_settings.dart';

final _song = UnifiedLibraryItem.fromLocalLibrary(
  LocalLibraryItem(
    id: 'song',
    trackName: 'Example song',
    artistName: 'Artist',
    albumName: 'Album',
    filePath: '/music/example.flac',
    scannedAt: DateTime.utc(2026, 10, 1),
  ),
);

List<Override> _overrides(AppSettings settings) => [
  homeRecommendationsProvider.overrideWith((ref) async => const <Track>[]),
  homeNewReleasesProvider.overrideWith(
    (ref) => Stream.value(const <WeeklyRelease>[]),
  ),
  settingsProvider.overrideWith(() => FixedSettingsNotifier(settings)),
  extensionProvider.overrideWith(_Extensions.new),
  exploreProvider.overrideWith(_Explore.new),
  downloadHistoryProvider.overrideWith(_History.new),
  recentAccessProvider.overrideWith(_Recent.new),
  libraryCollectionsProvider.overrideWith(_Collections.new),
  libraryMixesProvider.overrideWith((ref) async => const []),
  homeTopPicksProvider.overrideWith((ref) async => const <ExploreItem>[]),
  homeRecentlyAddedProvider.overrideWith(
    (ref) async => (items: [_song], trackCount: 1),
  ),
  homeRecentlyPlayedProvider.overrideWith((ref) async => const []),
  homeOnRepeatProvider.overrideWith((ref) async => const []),
  homeQuickSongsProvider.overrideWith((ref) async => const []),
  homeLibraryAlbumsProvider.overrideWith((ref) async => const []),
  playerUiEnabledProvider.overrideWithValue(true),
  currentMediaItemProvider.overrideWithBuild(
    (ref, notifier) => Stream<MediaItem?>.value(null),
  ),
  playbackResumeProvider.overrideWith((ref) async => null),
];

Widget _app(
  Widget page, {
  required AppSettings settings,
  bool mornye = false,
  List<Override> overrides = const [],
}) => ProviderScope(
  overrides: [..._overrides(settings), ...overrides],
  child: MaterialApp(
    theme: mornye ? MornyeTheme.build(Brightness.dark) : AppTheme.dark(),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: page,
  ),
);

Future<void> _settle(WidgetTester tester) async {
  for (var frame = 0; frame < 8; frame++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _open(
  WidgetTester tester,
  Widget page, {
  AppSettings settings = const AppSettings(
    homeFeedProvider: AppSettings.homeFeedProviderOff,
  ),
  bool mornye = false,
  List<Override> overrides = const [],
}) async {
  SharedPreferences.setMockInitialValues({});
  tester.view.physicalSize = const Size(400, 1600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    _app(page, settings: settings, mornye: mornye, overrides: overrides),
  );
  await _settle(tester);
}

AppSettings _settingsOf(WidgetTester tester, Type page) =>
    ProviderScope.containerOf(
      tester.element(find.byType(page)),
    ).read(settingsProvider);

double _top(WidgetTester tester, String text) =>
    tester.getTopLeft(find.text(text)).dy;

const _home = HomeTab(mode: HomeTabMode.browse);

void main() {
  group('the layout', () {
    test('ships in the order of the sections', () {
      const layout = HomeLayout();
      expect(layout.isDefault, isTrue);
      expect(layout.sections, HomeSection.values);
      expect(
        {
          for (final section in HomeSection.values)
            if (!layout.shows(section)) section,
        },
        {HomeSection.unfinished, HomeSection.onRepeat},
      );
    });

    test('a section that ships off shows once turned on', () {
      final on = const HomeLayout().withVisible(HomeSection.onRepeat, true);
      expect(on.shows(HomeSection.onRepeat), isTrue);
      expect(on.shows(HomeSection.unfinished), isFalse);
      expect(on.isDefault, isFalse);
      expect(HomeLayout.fromJson(on.toJson()), on);
      expect(
        on.withOrder([HomeSection.onRepeat]).shows(HomeSection.onRepeat),
        isTrue,
      );

      final off = on.withVisible(HomeSection.onRepeat, false);
      expect(off, const HomeLayout());
      // A layout saved before the section shipped off never named it.
      final older = HomeLayout.fromJson({
        'order': <String>[],
        'hidden': <String>[],
      });
      expect(older.shows(HomeSection.onRepeat), isFalse);
    });

    test('a saved order leads and the rest land where they ship', () {
      final layout = const HomeLayout().withOrder([
        HomeSection.onRepeat,
        HomeSection.shortcuts,
      ]);
      final sections = layout.sections;
      expect(sections.toSet(), HomeSection.values.toSet());
      expect(sections.length, HomeSection.values.length);
      expect(
        sections.indexOf(HomeSection.onRepeat),
        lessThan(sections.indexOf(HomeSection.shortcuts)),
      );
      // What ships right after Shortcuts follows them.
      expect(
        sections.indexOf(HomeSection.values[HomeSection.shortcuts.index + 1]),
        sections.indexOf(HomeSection.shortcuts) + 1,
      );
      // What ships before every named section stays at the front.
      expect(sections.first, HomeSection.values.first);
    });

    test('survives a round trip, unknown names and damaged data', () {
      final layout = const HomeLayout()
          .withOrder([HomeSection.recentlyAdded, HomeSection.shortcuts])
          .withVisible(HomeSection.mixes, false);
      expect(HomeLayout.fromJson(layout.toJson()), layout);
      expect(layout.shows(HomeSection.mixes), isFalse);
      expect(
        layout.withVisible(HomeSection.mixes, true).shows(HomeSection.mixes),
        isTrue,
      );

      final odd = HomeLayout.fromJson({
        'order': ['gone', 3, 'shortcuts', 'shortcuts'],
        'hidden': 'mixes',
      });
      expect(odd.sections.length, HomeSection.values.length);
      expect(odd.hidden, isEmpty);
      expect(homeLayoutFromJson('nonsense'), const HomeLayout());
      expect(
        AppSettings.fromJson(
          AppSettings(homeLayout: layout).toJson(),
        ).homeLayout,
        layout,
      );
    });

    test('the two older switches still decide their sections', () {
      const settings = AppSettings(
        homeContinueListening: false,
        homeRecommendations: false,
      );
      expect(settings.homeShows(HomeSection.continueListening), isFalse);
      expect(settings.homeShows(HomeSection.recommended), isFalse);
      expect(settings.homeShows(HomeSection.shortcuts), isTrue);
    });
  });

  group('Home follows the layout', () {
    testWidgets('sections keep the shipped order until moved', (tester) async {
      await _open(tester, _home);
      expect(tester.takeException(), isNull);
      expect(
        _top(tester, 'Shortcuts'),
        lessThan(_top(tester, 'Recently added')),
      );
      expect(
        _top(tester, 'Recently added'),
        lessThan(_top(tester, 'Edit Home')),
      );
    });

    testWidgets('a moved section shows in its new place', (tester) async {
      await _open(
        tester,
        _home,
        settings: AppSettings(
          homeFeedProvider: AppSettings.homeFeedProviderOff,
          homeLayout: const HomeLayout().withOrder([
            HomeSection.recentlyAdded,
            HomeSection.shortcuts,
          ]),
        ),
      );
      expect(tester.takeException(), isNull);
      expect(
        _top(tester, 'Recently added'),
        lessThan(_top(tester, 'Shortcuts')),
      );
    });

    testWidgets('hidden sections are gone, and a Library with songs is not '
        'called empty', (tester) async {
      await _open(
        tester,
        _home,
        settings: AppSettings(
          homeFeedProvider: AppSettings.homeFeedProviderOff,
          homeLayout: const HomeLayout()
              .withVisible(HomeSection.recentlyAdded, false)
              .withVisible(HomeSection.shortcuts, false),
        ),
      );
      expect(tester.takeException(), isNull);
      expect(find.text('Recently added'), findsNothing);
      expect(find.text('Shortcuts'), findsNothing);
      expect(find.text('Nothing here yet'), findsNothing);
      expect(find.text('Edit Home'), findsOneWidget);
    });

    testWidgets('Mornye follows it too', (tester) async {
      await _open(
        tester,
        _home,
        mornye: true,
        settings: AppSettings(
          homeFeedProvider: AppSettings.homeFeedProviderOff,
          homeLayout: const HomeLayout().withVisible(
            HomeSection.recentlyAdded,
            false,
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      expect(find.text('Recently added'), findsNothing);
      expect(find.text('Edit Home'), findsOneWidget);
    });

    testWidgets('the button under the sections opens Edit Home', (
      tester,
    ) async {
      await _open(tester, _home);
      await tester.tap(find.text('Edit Home'));
      await _settle(tester);
      expect(tester.takeException(), isNull);
      expect(find.byType(HomeLayoutPage), findsOneWidget);
    });
  });

  group('Edit Home', () {
    Finder switchOf(String section) => find.descendant(
      of: find.ancestor(
        of: find.text(section),
        matching: find.byType(ReorderableDelayedDragStartListener),
      ),
      matching: find.byType(AppSwitch),
    );

    testWidgets('lists the style\'s sections with what Home shows', (
      tester,
    ) async {
      await _open(
        tester,
        const HomeLayoutPage(),
        settings: const AppSettings(homeRecommendations: false),
      );
      expect(tester.takeException(), isNull);
      expect(find.text('Mixes for you'), findsOneWidget);
      // Mornye's banner shelf is not Material's to arrange.
      expect(find.text('Top Picks for You'), findsNothing);
      expect(tester.widget<AppSwitch>(switchOf('Shortcuts')).value, isTrue);
      expect(
        tester.widget<AppSwitch>(switchOf('Recommended for you')).value,
        isFalse,
      );
    });

    testWidgets('Mornye lists its own sections', (tester) async {
      await _open(tester, const HomeLayoutPage(), mornye: true);
      expect(tester.takeException(), isNull);
      expect(find.text('Top Picks for You'), findsOneWidget);
      expect(find.text('Recently Played'), findsOneWidget);
      expect(find.text('Mixes for you'), findsNothing);
      expect(find.text('Shortcuts'), findsNothing);
    });

    testWidgets('a switch hides a section, the older ones through their own '
        'setting', (tester) async {
      await _open(tester, const HomeLayoutPage());
      await tester.tap(switchOf('Recently added'));
      await tester.tap(switchOf('Continue listening'));
      await _settle(tester);
      final settings = _settingsOf(tester, HomeLayoutPage);
      expect(settings.homeLayout.hidden, {'recentlyAdded'});
      expect(settings.homeContinueListening, isFalse);
    });

    testWidgets('dragging a handle reorders the sections', (tester) async {
      await _open(tester, const HomeLayoutPage());
      final handles = find.byIcon(Icons.drag_handle);
      // Continue listening is Material's first section; drag it under two.
      final gesture = await tester.startGesture(
        tester.getCenter(handles.first),
      );
      await tester.pump(const Duration(milliseconds: 50));
      for (var step = 0; step < 10; step++) {
        await gesture.moveBy(const Offset(0, 15));
        await tester.pump(const Duration(milliseconds: 50));
      }
      await gesture.up();
      await _settle(tester);
      expect(tester.takeException(), isNull);
      final sections = _settingsOf(tester, HomeLayoutPage).homeLayout.sections;
      expect(
        sections.indexOf(HomeSection.shortcuts),
        lessThan(sections.indexOf(HomeSection.continueListening)),
      );
      // Mornye's sections keep their places around the move.
      expect(
        sections.indexOf(HomeSection.topPicks),
        lessThan(sections.indexOf(HomeSection.shortcuts)),
      );
    });

    testWidgets('Reset Home brings the shipped Home back', (tester) async {
      await _open(
        tester,
        const HomeLayoutPage(),
        settings: AppSettings(
          homeContinueListening: false,
          homeLayout: const HomeLayout()
              .withOrder([HomeSection.onRepeat])
              .withVisible(HomeSection.mixes, false),
        ),
      );
      await tester.scrollUntilVisible(find.text('Reset Home'), 200);
      await tester.tap(find.text('Reset Home'));
      await _settle(tester);
      await tester.tap(find.text('Reset'));
      await _settle(tester);
      expect(tester.takeException(), isNull);
      final settings = _settingsOf(tester, HomeLayoutPage);
      expect(settings.homeLayout, const HomeLayout());
      expect(settings.homeContinueListening, isTrue);
    });
  });

  testWidgets('with an external player a Recently added song opens in the '
      'other app', (tester) async {
    final opened = <String>[];
    await _open(
      tester,
      _home,
      settings: const AppSettings(
        homeFeedProvider: AppSettings.homeFeedProviderOff,
        playerMode: 'external',
      ),
      overrides: [
        playbackProvider.overrideWith(
          () => PlaybackController(
            openExternal: (path) async => opened.add(path),
          ),
        ),
      ],
    );
    await tester.tap(find.text('Example song'));
    await _settle(tester);
    expect(opened, ['/music/example.flac']);
    expect(tester.takeException(), isNull);
  });
}

class _Extensions extends ExtensionNotifier {
  @override
  ExtensionState build() => const ExtensionState();
}

class _Explore extends ExploreNotifier {
  @override
  ExploreState build() => const ExploreState();

  @override
  Future<void> fetchHomeFeed({bool forceRefresh = false}) async {}
}

class _History extends DownloadHistoryNotifier {
  @override
  DownloadHistoryState build() => DownloadHistoryState();
}

class _Recent extends RecentAccessNotifier {
  @override
  RecentAccessState build() => const RecentAccessState(isLoaded: true);
}

class _Collections extends LibraryCollectionsNotifier {
  @override
  LibraryCollectionsState build() => LibraryCollectionsState(isLoaded: true);
}
