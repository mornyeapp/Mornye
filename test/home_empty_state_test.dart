import 'dart:async';

import 'package:audio_service/audio_service.dart' show MediaItem;
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
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
import 'package:mornye/providers/home_unfinished_provider.dart';
import 'package:mornye/providers/library_browse_provider.dart';
import 'package:mornye/providers/library_mixes_provider.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/providers/recent_access_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/providers/weekly_releases_provider.dart';
import 'package:mornye/screens/home_tab.dart';
import 'package:mornye/services/shell_navigation_service.dart';
import 'package:mornye/services/weekly_releases.dart';
import 'package:mornye/theme/app_theme.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/widgets/app_icon_button.dart';
import 'package:mornye/widgets/error_card.dart';
import 'package:mornye/widgets/preview_button.dart';

import 'support/fixed_settings.dart';

const _title = 'Nothing here yet';

const _album = LibraryBrowseEntry(
  source: 'downloaded',
  key: 'album',
  name: 'Example album',
  artist: 'Artist',
  samplePath: '',
  trackCount: 2,
);

/// Home without extensions, a feed or a song in the player, with [added] as
/// its Recently added shelf and [recommended] as its recommendations. Each
/// other shelf notes its name in [reads] when it loads.
Widget _home({
  required bool mornye,
  List<UnifiedLibraryItem> added = const [],
  List<Track> recommended = const [],
  AppSettings settings = const AppSettings(
    homeFeedProvider: AppSettings.homeFeedProviderOff,
  ),
  List<String>? reads,
  Future<List<LibraryBrowseEntry>> Function()? libraryAlbums,
}) => ProviderScope(
  overrides: [
    homeRecommendationsProvider.overrideWith((ref) async => recommended),
    homeNewReleasesProvider.overrideWith((ref) {
      reads?.add('newReleases');
      return Stream.value(const <WeeklyRelease>[]);
    }),
    settingsProvider.overrideWith(() => FixedSettingsNotifier(settings)),
    extensionProvider.overrideWith(_Extensions.new),
    exploreProvider.overrideWith(_Explore.new),
    downloadHistoryProvider.overrideWith(_History.new),
    recentAccessProvider.overrideWith(_Recent.new),
    libraryMixesProvider.overrideWith((ref) async {
      reads?.add('mixes');
      return const [];
    }),
    homeTopPicksProvider.overrideWith((ref) async {
      reads?.add('topPicks');
      return const <ExploreItem>[];
    }),
    homeRecentlyAddedProvider.overrideWith(
      (ref) async => (items: added, trackCount: added.length),
    ),
    homeRecentlyPlayedProvider.overrideWith((ref) async {
      reads?.add('recentlyPlayed');
      return const [];
    }),
    homeOnRepeatProvider.overrideWith((ref) async {
      reads?.add('onRepeat');
      return const [];
    }),
    homeLibraryAlbumsProvider.overrideWith((ref) {
      reads?.add('libraryAlbums');
      return libraryAlbums?.call() ?? Future.value(const []);
    }),
    homeIncompleteAlbumCountProvider.overrideWith((ref) async {
      reads?.add('unfinished');
      return 0;
    }),
    homeRecognizedMissingProvider.overrideWith((ref) async {
      reads?.add('unfinished');
      return 0;
    }),
    homeQuickSongsProvider.overrideWith((ref) async => const []),
    playerUiEnabledProvider.overrideWithValue(true),
    currentMediaItemProvider.overrideWithBuild(
      (ref, notifier) => Stream<MediaItem?>.value(null),
    ),
    playbackResumeProvider.overrideWith((ref) async => null),
  ],
  child: MaterialApp(
    theme: mornye ? MornyeTheme.build(Brightness.dark) : AppTheme.dark(),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: const HomeTab(mode: HomeTabMode.browse),
  ),
);

Future<void> _open(WidgetTester tester, Widget home) async {
  tester.view.physicalSize = const Size(400, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(home);
  for (var frame = 0; frame < 6; frame++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  testWidgets('the Mornye Home with nothing to show says so', (tester) async {
    await _open(tester, _home(mornye: true));
    expect(tester.takeException(), isNull);

    expect(find.byType(EmptyState), findsOneWidget);
    expect(find.text(_title), findsOneWidget);
    expect(
      find.text('Songs you add to your Library or play show up here.'),
      findsOneWidget,
    );
    expect(find.text('Find music'), findsOneWidget);
  });

  testWidgets('a Mornye Home with a shelf has no empty state', (tester) async {
    await _open(
      tester,
      _home(
        mornye: true,
        added: [
          UnifiedLibraryItem.fromLocalLibrary(
            LocalLibraryItem(
              id: 'song',
              trackName: 'Example song',
              artistName: 'Artist',
              albumName: 'Album',
              filePath: '/music/example.flac',
              scannedAt: DateTime.utc(2026, 10, 1),
            ),
          ),
        ],
      ),
    );
    expect(tester.takeException(), isNull);

    expect(find.text('Recently added'), findsOneWidget);
    expect(find.text(_title), findsNothing);
  });

  testWidgets('the Material Home says so under its Shortcuts and leads to '
      'Search', (tester) async {
    final requested = <ShellTab>[];
    final owner = Object();
    ShellNavigationService.registerTabSelectionHandler(
      owner: owner,
      handler: requested.add,
    );
    addTearDown(
      () => ShellNavigationService.unregisterTabSelectionHandler(owner),
    );
    await _open(tester, _home(mornye: false));
    expect(tester.takeException(), isNull);

    expect(find.text('Shortcuts'), findsOneWidget);
    expect(find.text(_title), findsOneWidget);
    expect(
      tester.getTopLeft(find.text(_title)).dy,
      greaterThan(tester.getTopLeft(find.text('Shortcuts')).dy),
    );
    await tester.ensureVisible(find.text('Find music'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Find music'));
    expect(requested, [ShellTab.search]);
  });

  testWidgets('a Material Home with a shelf has no empty state', (
    tester,
  ) async {
    await _open(
      tester,
      _home(
        mornye: false,
        added: [
          UnifiedLibraryItem.fromLocalLibrary(
            LocalLibraryItem(
              id: 'song',
              trackName: 'Example song',
              artistName: 'Artist',
              albumName: 'Album',
              filePath: '/music/example.flac',
              scannedAt: DateTime.utc(2026, 10, 1),
            ),
          ),
        ],
      ),
    );
    expect(tester.takeException(), isNull);

    expect(find.text('Recently added'), findsOneWidget);
    expect(find.text(_title), findsNothing);
  });

  for (final mornye in [false, true]) {
    testWidgets('Home recommends songs outside the Library '
        '(${mornye ? 'Mornye' : 'Material'})', (tester) async {
      await _open(
        tester,
        _home(
          mornye: mornye,
          recommended: const [
            Track(
              id: 'one',
              name: 'Example song',
              artistName: 'Example artist',
              albumName: 'Album',
              duration: 200,
              previewUrl: 'https://example.test/preview.mp3',
            ),
            Track(
              id: 'two',
              name: 'Another song',
              artistName: 'Someone',
              albumName: 'Album',
              duration: 200,
            ),
          ],
        ),
      );
      expect(tester.takeException(), isNull);

      expect(find.text('Recommended for you'), findsOneWidget);
      expect(find.text(_title), findsNothing);
      expect(find.text('Example song'), findsOneWidget);
      expect(find.text('Example artist'), findsOneWidget);
      // Only a song with a preview offers one.
      expect(find.byType(PreviewButton), findsNWidgets(2));
      expect(
        find.descendant(
          of: find.byType(PreviewButton),
          matching: find.byType(AppIconButton),
        ),
        findsOneWidget,
      );
    });
  }

  final added = [
    UnifiedLibraryItem.fromLocalLibrary(
      LocalLibraryItem(
        id: 'song',
        trackName: 'Example song',
        artistName: 'Artist',
        albumName: 'Album',
        filePath: '/music/example.flac',
        scannedAt: DateTime.utc(2026, 10, 1),
      ),
    ),
  ];
  const off = AppSettings.homeFeedProviderOff;

  for (final mornye in [false, true]) {
    final style = mornye ? 'Mornye' : 'Material';

    testWidgets('sections off by default load nothing ($style)', (
      tester,
    ) async {
      final reads = <String>[];
      await _open(
        tester,
        _home(
          mornye: mornye,
          added: added,
          reads: reads,
          settings: const AppSettings(
            homeFeedProvider: off,
            listeningStatisticsEnabled: false,
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      expect(find.text('Recently added'), findsOneWidget);
      expect(reads, isNot(contains('onRepeat')));
      expect(reads, isNot(contains('unfinished')));
      // Mornye's Top Picks still offer the day's albums.
      expect(reads.contains('libraryAlbums'), mornye);
    });

    testWidgets('sections the person hid load nothing ($style)', (
      tester,
    ) async {
      final reads = <String>[];
      var layout = const HomeLayout();
      for (final section in [
        HomeSection.newReleases,
        HomeSection.mixes,
        HomeSection.topPicks,
        HomeSection.recentlyPlayed,
      ]) {
        layout = layout.withVisible(section, false);
      }
      await _open(
        tester,
        _home(
          mornye: mornye,
          added: added,
          reads: reads,
          settings: AppSettings(homeFeedProvider: off, homeLayout: layout),
        ),
      );
      expect(tester.takeException(), isNull);
      expect(find.text('Recently added'), findsOneWidget);
      expect(reads, isEmpty);
    });

    testWidgets('an empty Library still counts a hidden shelf ($style)', (
      tester,
    ) async {
      final reads = <String>[];
      await _open(
        tester,
        _home(
          mornye: mornye,
          reads: reads,
          libraryAlbums: () async => const [_album],
          // Without Top Picks every album of the day goes to the hidden
          // From your Library.
          settings: AppSettings(
            homeFeedProvider: off,
            listeningStatisticsEnabled: false,
            homeLayout: const HomeLayout().withVisible(
              HomeSection.topPicks,
              false,
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      expect(reads, contains('libraryAlbums'));
      expect(find.text('From your Library'), findsNothing);
      expect(find.text(_title), findsNothing);
      expect(find.text('Edit Home'), findsOneWidget);
    });

    testWidgets('the message waits for a hidden shelf to answer ($style)', (
      tester,
    ) async {
      final albums = Completer<List<LibraryBrowseEntry>>();
      await _open(
        tester,
        _home(
          mornye: mornye,
          libraryAlbums: () => albums.future,
          settings: AppSettings(
            homeFeedProvider: off,
            listeningStatisticsEnabled: false,
            homeLayout: const HomeLayout().withVisible(
              HomeSection.topPicks,
              false,
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      expect(find.text(_title), findsNothing);
      expect(find.text('Edit Home'), findsNothing);

      albums.complete(const []);
      for (var frame = 0; frame < 3; frame++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(tester.takeException(), isNull);
      expect(find.text(_title), findsOneWidget);
      expect(find.text('Edit Home'), findsNothing);
    });
  }
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
