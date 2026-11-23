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
import 'package:mornye/services/playable_media.dart';
import 'package:mornye/services/weekly_releases.dart';
import 'package:mornye/theme/app_theme.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fixed_settings.dart';

UnifiedLibraryItem _song(String name, {String? album, String? artist}) =>
    UnifiedLibraryItem.fromLocalLibrary(
      LocalLibraryItem(
        id: name,
        trackName: name,
        artistName: artist ?? 'Artist of $name',
        albumName: album ?? 'Album of $name',
        filePath: '/music/$name.flac',
        scannedAt: DateTime.utc(2026, 10, 1),
      ),
    );

final _nine = [for (var index = 1; index <= 9; index++) _song('Quick $index')];

const _grid = ValueKey('home-quick-play-grid');
const _home = HomeTab(mode: HomeTabMode.browse);
const _noFeed = AppSettings(homeFeedProvider: AppSettings.homeFeedProviderOff);

class _PlaybackRecorder extends PlaybackController {
  final paths = <String>[];
  final queues = <List<String>>[];
  final starts = <int>[];

  @override
  Future<void> playMediaQueue(
    Iterable<PlayableMedia> queue, {
    required int startIndex,
    required String externalPath,
  }) async {
    paths.add(externalPath);
    queues.add([for (final media in queue) media.source]);
    starts.add(startIndex);
  }
}

List<Override> _overrides(
  AppSettings settings, {
  required bool player,
  required bool saved,
}) => [
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
    (ref) async => (items: [_song('Newest')], trackCount: 10),
  ),
  homeRecentlyPlayedProvider.overrideWith((ref) async => const []),
  homeOnRepeatProvider.overrideWith((ref) async => const []),
  homeLibraryAlbumsProvider.overrideWith((ref) async => const []),
  playerUiEnabledProvider.overrideWithValue(player),
  currentMediaItemProvider.overrideWithBuild(
    (ref, notifier) => Stream<MediaItem?>.value(null),
  ),
  playbackResumeProvider.overrideWith(
    (ref) async => saved
        ? (
            media: const PlayableMedia(
              id: 'network://nas/Album/song.flac',
              source: 'network://nas/Album/song.flac',
              title: 'Saved song',
              artist: 'Artist',
            ),
            position: const Duration(seconds: 23),
          )
        : null,
  ),
];

Future<void> _settle(WidgetTester tester) async {
  for (var frame = 0; frame < 8; frame++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// Opens [page] in a [width] wide window with [songs] as the Quick play
/// picks. [reads] counts how often Home asked for them.
Future<void> _open(
  WidgetTester tester,
  Widget page, {
  List<UnifiedLibraryItem>? songs,
  AppSettings settings = _noFeed,
  bool mornye = false,
  bool player = true,
  bool saved = true,
  bool desktop = false,
  double width = 400,
  List<int>? reads,
  List<Override> overrides = const [],
}) async {
  SharedPreferences.setMockInitialValues({});
  tester.view.physicalSize = Size(width, 2000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  if (desktop) {
    debugDesktopPlatformOverride = true;
    addTearDown(() => debugDesktopPlatformOverride = null);
  }
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        ..._overrides(settings, player: player, saved: saved),
        homeQuickSongsProvider.overrideWith((ref) async {
          reads?.add(1);
          return songs ?? _nine;
        }),
        ...overrides,
      ],
      child: MaterialApp(
        theme: mornye ? MornyeTheme.build(Brightness.dark) : AppTheme.dark(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: page,
      ),
    ),
  );
  await _settle(tester);
}

double _top(WidgetTester tester, String text) =>
    tester.getTopLeft(find.text(text)).dy;

/// The box of the grid's song `Quick [index]`.
Rect _box(WidgetTester tester, int index) =>
    tester.getRect(find.byKey(ValueKey('home-quick-play-local_Quick $index')));

void main() {
  group('the day\'s stretches', () {
    test('a small Library is read whole', () {
      expect(homeQuickSongStretches(0, '2026-11-23'), [(offset: 0, limit: 90)]);
      expect(homeQuickSongStretches(90, '2026-11-23'), [
        (offset: 0, limit: 90),
      ]);
    });

    test('a large one gives three stretches that move with the day', () {
      final today = homeQuickSongStretches(5000, '2026-11-23');
      expect(today, hasLength(3));
      for (final (:offset, :limit) in today) {
        expect(limit, 30);
        expect(offset, inInclusiveRange(0, 5000 - 30));
      }
      expect(homeQuickSongStretches(5000, '2026-11-23'), today);
      expect(homeQuickSongStretches(5000, '2026-11-24'), isNot(today));
    });
  });

  group('the picks', () {
    List<String> names(List<UnifiedLibraryItem> songs) => [
      for (final song in songs) song.trackName,
    ];

    final pool = [for (var index = 1; index <= 40; index++) _song('P$index')];

    test('played songs lead in their order, the pool fills to nine', () {
      final played = [_song('A'), _song('B'), _song('C')];
      final picks = homeQuickSongPicks(
        played: played,
        pool: pool,
        day: '2026-11-23',
      );
      expect(picks, hasLength(9));
      expect(names(picks).take(3), ['A', 'B', 'C']);
      expect(names(picks).toSet(), hasLength(9));
    });

    test('nine played songs need no pool, more are cut', () {
      final played = [
        for (var index = 1; index <= 12; index++) _song('$index'),
      ];
      expect(names(homeQuickSongPicks(played: played, pool: pool, day: 'd')), [
        for (var index = 1; index <= 9; index++) '$index',
      ]);
    });

    test('a song is never shown twice', () {
      final picks = homeQuickSongPicks(
        played: [pool[3], pool[3], pool[7]],
        pool: pool.take(9).toList(),
        day: '2026-11-23',
      );
      expect(names(picks).take(2), ['P4', 'P8']);
      expect(names(picks).toSet(), hasLength(picks.length));
      expect(picks, hasLength(9));
    });

    test('the day sets the order, not how the Library was read', () {
      List<String> on(String day, List<UnifiedLibraryItem> pool) =>
          names(homeQuickSongPicks(played: const [], pool: pool, day: day));
      expect(on('2026-11-23', pool), on('2026-11-23', pool.reversed.toList()));
      expect(on('2026-11-23', pool), isNot(on('2026-11-24', pool)));
    });

    test('other albums come before a second song of one', () {
      final picks = homeQuickSongPicks(
        played: const [],
        pool: [
          for (var index = 1; index <= 20; index++)
            _song('Same $index', album: 'One album', artist: 'One artist'),
          for (var index = 1; index <= 8; index++) _song('Other $index'),
        ],
        day: '2026-11-23',
      );
      expect(picks, hasLength(9));
      expect(
        names(picks).where((name) => name.startsWith('Other')),
        hasLength(8),
      );
    });

    test('a small Library gives what it has', () {
      final picks = homeQuickSongPicks(
        played: const [],
        pool: [_song('Only'), _song('Two')],
        day: '2026-11-23',
      );
      expect(names(picks).toSet(), {'Only', 'Two'});
    });
  });

  group('Home', () {
    testWidgets('shows nine covers in three rows under Shortcuts', (
      tester,
    ) async {
      await _open(tester, _home);
      expect(tester.takeException(), isNull);
      expect(
        _top(tester, 'Continue listening'),
        lessThan(_top(tester, 'Shortcuts')),
      );
      expect(_top(tester, 'Shortcuts'), lessThan(_top(tester, 'Quick play')));
      expect(find.byKey(_grid), findsOneWidget);

      Rect box(int index) => _box(tester, index);
      for (final row in [1, 4, 7]) {
        expect(box(row).top, box(row + 1).top);
        expect(box(row).top, box(row + 2).top);
        expect(box(row).left, box(1).left);
        expect(box(row + 1).left, box(2).left);
        expect(box(row + 2).left, box(3).left);
      }
      // Square boxes four apart, across and down, from the page margin.
      expect(box(1).width, box(1).height);
      expect(box(2).left - box(1).right, 4);
      expect(box(3).left - box(2).right, 4);
      expect(box(4).top - box(1).bottom, 4);
      expect(box(7).top - box(4).bottom, 4);
      expect(box(1).left, 16);
      expect(box(3).right, moreOrLessEquals(384, epsilon: 1));
      // Each title sits inside its box; the grid names the songs only.
      for (var index = 1; index <= 9; index++) {
        final title = tester.getRect(find.text('Quick $index'));
        expect(box(index).contains(title.topLeft), isTrue);
        expect(
          box(index).contains(title.bottomRight - const Offset(1, 1)),
          isTrue,
        );
      }
      expect(find.text('Artist of Quick 1'), findsNothing);
    });

    testWidgets('a tap plays that song with the others after it', (
      tester,
    ) async {
      final player = _PlaybackRecorder();
      await _open(
        tester,
        _home,
        overrides: [playbackProvider.overrideWith(() => player)],
      );
      await tester.tap(
        find.byKey(const ValueKey('home-quick-play-local_Quick 5')),
      );
      await _settle(tester);
      expect(tester.takeException(), isNull);
      expect(player.starts, [4]);
      expect(player.paths, ['/music/Quick 5.flac']);
      expect(player.queues.single, [
        for (var index = 1; index <= 9; index++) '/music/Quick $index.flac',
      ]);
    });

    testWidgets('fewer songs leave the last row short', (tester) async {
      await _open(tester, _home, songs: _nine.take(4).toList());
      expect(tester.takeException(), isNull);
      expect(find.text('Quick 4'), findsOneWidget);
      expect(find.text('Quick 5'), findsNothing);
      expect(
        tester.getTopLeft(find.text('Quick 4')).dx,
        tester.getTopLeft(find.text('Quick 1')).dx,
      );
    });

    testWidgets('no songs, no section', (tester) async {
      await _open(tester, _home, songs: const []);
      expect(tester.takeException(), isNull);
      expect(find.text('Quick play'), findsNothing);
      expect(find.text('Shortcuts'), findsOneWidget);
    });

    testWidgets('a hidden section is not read either', (tester) async {
      final reads = <int>[];
      await _open(
        tester,
        _home,
        reads: reads,
        settings: AppSettings(
          homeFeedProvider: AppSettings.homeFeedProviderOff,
          homeLayout: const HomeLayout().withVisible(
            HomeSection.quickPlay,
            false,
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      expect(find.text('Quick play'), findsNothing);
      expect(reads, isEmpty);
    });

    testWidgets('another app as the player leaves it out', (tester) async {
      final reads = <int>[];
      await _open(tester, _home, player: false, reads: reads);
      expect(tester.takeException(), isNull);
      expect(find.text('Quick play'), findsNothing);
      expect(reads, isEmpty);
    });

    testWidgets('Mornye shows the grid too', (tester) async {
      await _open(tester, _home, mornye: true);
      expect(tester.takeException(), isNull);
      expect(find.text('Quick play'), findsOneWidget);
      expect(find.byKey(_grid), findsOneWidget);
      // Boxes start under the section title, as Mornye's shelves do.
      expect(
        _box(tester, 1).left,
        tester.getTopLeft(find.text('Quick play')).dx,
      );
      expect(_box(tester, 1).top, _box(tester, 2).top);
      expect(_box(tester, 2).left - _box(tester, 1).right, 4);
    });

    testWidgets('a wide page lays the songs out as a shelf', (tester) async {
      await _open(tester, _home, width: 900);
      expect(tester.takeException(), isNull);
      expect(find.text('Quick play'), findsOneWidget);
      expect(find.byKey(_grid), findsNothing);
      expect(
        tester.getTopLeft(find.text('Quick 1')).dy,
        tester.getTopLeft(find.text('Quick 4')).dy,
      );
      expect(find.text('Artist of Quick 1'), findsOneWidget);
    });

    testWidgets('the desktop top stays above it', (tester) async {
      await _open(tester, _home, desktop: true, width: 1280);
      expect(tester.takeException(), isNull);
      expect(
        _top(tester, 'Continue listening'),
        lessThan(_top(tester, 'Quick play')),
      );
      expect(_top(tester, 'Shortcuts'), lessThan(_top(tester, 'Quick play')));
    });

    testWidgets('on the desktop Shortcuts moved first take the top with '
        'them', (tester) async {
      await _open(
        tester,
        _home,
        desktop: true,
        width: 1280,
        settings: AppSettings(
          homeFeedProvider: AppSettings.homeFeedProviderOff,
          homeLayout: const HomeLayout().withOrder([
            HomeSection.quickPlay,
            HomeSection.shortcuts,
            HomeSection.continueListening,
          ]),
        ),
      );
      expect(tester.takeException(), isNull);
      expect(_top(tester, 'Quick play'), lessThan(_top(tester, 'Shortcuts')));
      expect(
        _top(tester, 'Shortcuts'),
        moreOrLessEquals(_top(tester, 'Continue listening')),
      );
    });
  });

  group('Edit Home', () {
    testWidgets('lists Quick play after Shortcuts', (tester) async {
      await _open(tester, const HomeLayoutPage());
      expect(tester.takeException(), isNull);
      expect(
        find.text(
          'Songs you play most and the day\'s picks from your Library, one '
          'tap from playing',
        ),
        findsOneWidget,
      );
      expect(
        _top(tester, 'Continue listening'),
        lessThan(_top(tester, 'Shortcuts')),
      );
      expect(_top(tester, 'Shortcuts'), lessThan(_top(tester, 'Quick play')));
    });

    testWidgets('leaves it out while another app is the player', (
      tester,
    ) async {
      await _open(tester, const HomeLayoutPage(), player: false);
      expect(tester.takeException(), isNull);
      expect(find.text('Quick play'), findsNothing);
      expect(find.text('Shortcuts'), findsOneWidget);
    });
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
