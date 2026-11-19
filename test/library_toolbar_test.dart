import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart' show DateFormat;
import 'package:material_3_expressive/material_3_expressive.dart'
    show M3EButton, M3EButtonGroup, M3EButtonGroupType;
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/download_item.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/download_queue_provider.dart';
import 'package:mornye/models/unified_library_item.dart';
import 'package:mornye/providers/library_browse_provider.dart';
import 'package:mornye/providers/library_collections_provider.dart';
import 'package:mornye/providers/library_directory_provider.dart';
import 'package:mornye/providers/library_genres_provider.dart';
import 'package:mornye/providers/library_search_provider.dart';
import 'package:mornye/providers/local_library_provider.dart';
import 'package:mornye/providers/playback_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/screens/library_mix_screen.dart';
import 'package:mornye/screens/library_tracks_folder_screen.dart';
import 'package:mornye/screens/queue_tab.dart';
import 'package:mornye/services/history_database.dart';
import 'package:mornye/services/library_database.dart';
import 'package:mornye/services/library_directory_index.dart';
import 'package:mornye/services/library_search.dart';
import 'package:mornye/services/playable_media.dart' show PlayableMedia;
import 'package:mornye/theme/app_theme.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:mornye/widgets/app_search_field.dart';
import 'package:mornye/widgets/animated_library_sliver_grid.dart';
import 'package:mornye/widgets/library_directory_view.dart';
import 'package:mornye/widgets/song_row_tap.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';

import 'support/page_back.dart';

class _Settings extends SettingsNotifier {
  _Settings(this.initial);

  final AppSettings? initial;

  // The Rewind banner animates for as long as it is shown; keep it off so
  // the page settles.
  @override
  AppSettings build() =>
      initial ??
      const AppSettings(
        defaultLibraryView: 'all',
        historyViewMode: 'list',
        listeningStatisticsEnabled: false,
      );
}

/// Downloaded songs added on [dates]. With a queue item present and the
/// database page empty, the Library renders this in-memory snapshot.
class _History extends DownloadHistoryNotifier {
  _History(this.dates);

  final List<DateTime> dates;

  @override
  DownloadHistoryState build() => DownloadHistoryState(
    items: [
      for (final (index, date) in dates.indexed)
        DownloadHistoryItem(
          id: 'song-$index',
          trackName: 'Song $index',
          artistName: 'Artist',
          albumName: 'Album $index',
          filePath: '/music/song-$index.flac',
          service: 'example-provider',
          downloadedAt: date,
        ),
    ],
    totalCount: dates.length,
  );
}

class _Local extends LocalLibraryNotifier {
  @override
  LocalLibraryState build() => LocalLibraryState();
}

class _Collections extends LibraryCollectionsNotifier {
  _Collections(this.playlists);

  final List<UserPlaylistCollection> playlists;

  @override
  LibraryCollectionsState build() =>
      LibraryCollectionsState(isLoaded: true, playlists: playlists);
}

class _Queue extends DownloadQueueNotifier {
  @override
  DownloadQueueState build() => DownloadQueueState();
}

class _Playback extends PlaybackController {
  final queues = <List<String>>[];
  final starts = <int>[];

  @override
  Future<void> playMediaQueue(
    Iterable<PlayableMedia> queue, {
    required int startIndex,
    required String externalPath,
  }) async {
    queues.add([for (final media in queue) media.source]);
    starts.add(startIndex);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final queries = <String>[];
  final albumRows = <List<Object?>>[];

  setUp(() {
    queries.clear();
    albumRows.clear();
    SharedPreferences.setMockInitialValues({});
    final previousFactory = databaseFactoryOrNull;
    databaseFactory = databaseFactorySqflitePlugin;
    addTearDown(() => databaseFactory = previousFactory);
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const paths = MethodChannel('plugins.flutter.io/path_provider');
    messenger.setMockMethodCallHandler(paths, (_) async => '/test/documents');
    addTearDown(() => messenger.setMockMethodCallHandler(paths, null));
    // Most tests use an empty database; album order tests supply page rows.
    const sqlite = MethodChannel('com.tekartik.sqflite');
    final versions = <int, int>{};
    messenger.setMockMethodCallHandler(sqlite, (call) async {
      final args = (call.arguments as Map?) ?? {};
      if (call.method == 'openDatabase') {
        final id = versions.length + 1;
        versions[id] = (args['path'] as String).endsWith('history.db')
            ? HistoryDatabase.schemaVersion
            : LibraryDatabase.schemaVersion;
        return {'id': id};
      }
      final sql = args['sql'] as String? ?? '';
      if (call.method == 'execute' && sql.contains('CREATE VIRTUAL TABLE')) {
        throw PlatformException(code: 'sqlite_error', message: 'no fts5');
      }
      if (call.method != 'query') return null;
      queries.add(sql);
      if (sql.toLowerCase().contains('pragma user_version')) {
        return {
          'columns': ['user_version'],
          'rows': [
            [versions[args['id']]],
          ],
        };
      }
      if (sql.trimLeft().startsWith('SELECT *') &&
          sql.contains('sample_file_path') &&
          sql.contains('AS queue_source')) {
        return {
          'columns': [
            'queue_source',
            'album_key',
            'album_name',
            'artist_name',
            'track_count',
            'sort_added',
            'sample_file_path',
            'sort_release',
          ],
          'rows': albumRows,
        };
      }
      return {'columns': <String>[], 'rows': <List<Object?>>[]};
    });
    addTearDown(() => messenger.setMockMethodCallHandler(sqlite, null));
  });
  tearDown(() => debugDesktopPlatformOverride = null);

  Future<void> pumpLibrary(
    WidgetTester tester, {
    bool desktop = false,
    bool mornye = false,
    bool reduceMotion = false,
    List<DateTime>? dates,
    List<UserPlaylistCollection> playlists = const [],
    bool withQueueItem = true,
    String? librarySection,
    List<Override> overrides = const [],
    Size size = const Size(1280, 900),
  }) async {
    final preferences = await SharedPreferences.getInstance();
    debugDesktopPlatformOverride = desktop;
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final queue = DownloadQueueLookup.fromItems([
      if (withQueueItem)
        DownloadItem(
          id: 'completed',
          track: const Track(
            id: 'song',
            name: 'Song',
            artistName: 'Artist',
            albumName: 'Album',
            duration: 1000,
          ),
          service: 'example-provider',
          status: DownloadStatus.completed,
          createdAt: DateTime(2026),
        ),
    ]);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          // These tests play songs with a tap on the row.
          librarySongTapPlaysProvider.overrideWithValue(true),
          settingsProvider.overrideWith(
            () => _Settings(
              hasPersistedAppSettings(preferences)
                  ? loadBootstrapSettings(preferences)
                  : null,
            ),
          ),
          downloadHistoryProvider.overrideWith(
            () => _History(dates ?? [DateTime(2026, 1, 10)]),
          ),
          localLibraryProvider.overrideWith(_Local.new),
          libraryCollectionsProvider.overrideWith(
            () => _Collections(playlists),
          ),
          downloadQueueProvider.overrideWith(_Queue.new),
          downloadQueueLookupProvider.overrideWithValue(queue),
          ...overrides,
        ],
        child: MaterialApp(
          theme: mornye
              ? MornyeTheme.build(Brightness.light)
              : AppTheme.light(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(disableAnimations: reduceMotion),
            child: child!,
          ),
          // Mornye opens Songs as a section page from its Library root.
          home: Scaffold(
            body: QueueTab(
              librarySection: librarySection ?? (mornye ? 'all' : null),
            ),
          ),
        ),
      ),
    );
    // A loading indicator spins while the database page is pending, so the
    // page never settles; pump for a bounded time instead.
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  AppLocalizations l10nOf(WidgetTester tester) =>
      AppLocalizations.of(tester.element(find.byType(QueueTab)));

  Finder toolButton(String? tooltip, {String? label}) => find
      .byWidgetPredicate(
        (widget) =>
            widget is M3EButton &&
            (tooltip == null || widget.tooltip == tooltip) &&
            (label == null ||
                (widget.label is Text &&
                    (widget.label! as Text).data == label)),
      )
      .hitTestable();

  for (final desktop in [false, true]) {
    for (final trackCount in <int?>[null, 0, 143]) {
      testWidgets(
        'Material opens Playlists without downloaded or local songs '
        '(desktop: $desktop, playlist tracks: $trackCount)',
        (tester) async {
          final now = DateTime(2026);
          await pumpLibrary(
            tester,
            desktop: desktop,
            dates: const [],
            withQueueItem: false,
            playlists: [
              if (trackCount != null)
                UserPlaylistCollection(
                  id: 'remote-playlist',
                  name: 'Example saved playlist',
                  createdAt: now,
                  updatedAt: now,
                  tracks: [
                    for (var i = 0; i < trackCount; i++)
                      CollectionTrackEntry(
                        key: 'example:$i',
                        addedAt: now,
                        track: Track(
                          id: 'example:$i',
                          name: 'Remote song $i',
                          artistName: 'Example Artist',
                          albumName: 'Example Album',
                          duration: 180,
                          source: 'example',
                        ),
                      ),
                  ],
                ),
            ],
          );
          final l10n = l10nOf(tester);
          final playlistsTab = find.descendant(
            of: find.byType(TabBar),
            matching: find.text(l10n.searchPlaylists),
          );
          expect(playlistsTab.hitTestable(), findsOneWidget);
          await tester.tap(playlistsTab);
          // Let the spatial spring finish before clicking inside the page.
          for (var i = 0; i < 40; i++) {
            await tester.pump(const Duration(milliseconds: 50));
          }
          expect(find.text(l10n.collectionCreatePlaylist), findsOneWidget);
          if (trackCount != null) {
            expect(find.byType(AppSearchField), findsOneWidget);
            expect(find.text('Example saved playlist'), findsOneWidget);
            expect(find.text(l10n.itemCount(trackCount)), findsOneWidget);
            await tester.tap(find.text('Example saved playlist'));
            for (var i = 0; i < 10; i++) {
              await tester.pump(const Duration(milliseconds: 50));
            }
            expect(
              tester
                  .widget<LibraryTracksFolderScreen>(
                    find.byType(LibraryTracksFolderScreen),
                  )
                  .playlistId,
              'remote-playlist',
            );
            if (trackCount > 0) {
              expect(find.text('Remote song 0'), findsOneWidget);
            }
          }
          expect(tester.takeException(), isNull);
        },
        variant: TargetPlatformVariant({
          desktop ? TargetPlatform.windows : TargetPlatform.android,
        }),
      );
    }

    testWidgets('Material joins sort, filter and view in one connected group '
        '(desktop: $desktop)', (tester) async {
      await pumpLibrary(tester, desktop: desktop);
      final l10n = l10nOf(tester);

      final groups = find.byType(M3EButtonGroup);
      expect(groups, findsOneWidget);
      final group = tester.widget<M3EButtonGroup>(groups);
      expect(group.type, M3EButtonGroupType.connected);
      expect(group.actions, hasLength(4));
      // Shuffle leads the Songs page's tools as one of them.
      expect(group.actions[0].tooltip, l10n.actionShuffle);
      expect(group.actions[0].label, isNull);
      // Sort keeps its label so the current order stays visible.
      expect(
        (group.actions[1].label! as Text).data,
        l10n.libraryFilterSortLatest,
      );
      expect((group.actions[2].label! as Text).data, l10n.libraryFilterTitle);
      expect(group.actions[3].tooltip, l10n.appearanceHistoryViewGrid);
      expect(group.actions[3].label, isNull);
      expect(group.selectedIndex, isNull);

      // A compact visual that keeps the 48dp touch target.
      expect(tester.getSize(groups).height, desktop ? 40 : 44);
      final sort = toolButton(null, label: l10n.libraryFilterSortLatest);
      expect(sort, findsOneWidget);
      final above = tester.getRect(sort).topCenter - const Offset(0, 1);
      expect(
        tester.hitTestOnBinding(above).path.map((entry) => entry.target),
        contains(tester.renderObject(sort)),
      );
    });
  }

  testWidgets('the desktop sort menu opens below its button when it fits', (
    tester,
  ) async {
    await pumpLibrary(tester, desktop: true);
    tester.view.physicalSize = const Size(1280, 1200);
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    final l10n = l10nOf(tester);
    final sort = toolButton(null, label: l10n.libraryFilterSortLatest);
    final sortRect = tester.getRect(sort);

    await tester.tap(sort);
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    final oldest = find.text(l10n.libraryFilterSortOldest);
    expect(oldest, findsOneWidget);
    // The menu shifts left to stay inside the window, so only its top is
    // tied to the button.
    expect(tester.getRect(oldest).top, greaterThanOrEqualTo(sortRect.bottom));
  });

  for (final desktop in [false, true]) {
    for (final mornye in [false, true]) {
      testWidgets('title sort survives a fresh Library and settings scope '
          '(desktop: $desktop, Mornye: $mornye)', (tester) async {
        await pumpLibrary(tester, desktop: desktop, mornye: mornye);
        final l10n = l10nOf(tester);
        await tester.tap(
          find
              .text(
                mornye ? l10n.libraryFilterTitle : l10n.libraryFilterSortLatest,
              )
              .hitTestable(),
        );
        for (var i = 0; i < 10; i++) {
          await tester.pump(const Duration(milliseconds: 50));
        }
        final choice = find.text(l10n.searchSortTitleAZ);
        await tester.ensureVisible(choice);
        await tester.pump(const Duration(milliseconds: 300));
        await tester.tap(choice);
        if (mornye) {
          await tester.ensureVisible(find.text(l10n.libraryFilterApply));
          await tester.pump(const Duration(milliseconds: 300));
          await tester.tap(find.text(l10n.libraryFilterApply));
        }
        for (var i = 0; i < 10; i++) {
          await tester.pump(const Duration(milliseconds: 50));
        }
        final preferences = await SharedPreferences.getInstance();
        expect(loadBootstrapSettings(preferences).historySortMode, 'a-z');
        await tester.pumpWidget(const SizedBox.shrink());
        queries.clear();
        await pumpLibrary(tester, desktop: desktop, mornye: mornye);
        final container = ProviderScope.containerOf(
          tester.element(find.byType(QueueTab)),
        );
        expect(container.read(settingsProvider).historySortMode, 'a-z');
        expect(
          queries.any((sql) => sql.contains('ORDER BY sort_track ASC')),
          isTrue,
        );
        if (!mornye) {
          expect(
            find.text(l10n.searchSortTitleAZ).hitTestable(),
            findsOneWidget,
          );
          expect(find.text(l10n.libraryFilterSortLatest), findsNothing);
        }
        expect(tester.takeException(), isNull);
      });

      testWidgets('size sort applies from the Library menu '
          '(desktop: $desktop, Mornye: $mornye)', (tester) async {
        await pumpLibrary(tester, desktop: desktop, mornye: mornye);
        final l10n = l10nOf(tester);
        // The search field scrolls with the page over its plain background.
        expect(
          find.descendant(
            of: find.byType(AppSearchField),
            matching: find.byType(BackdropFilter),
          ),
          findsNothing,
        );
        await tester.tap(
          find
              .text(
                mornye ? l10n.libraryFilterTitle : l10n.libraryFilterSortLatest,
              )
              .hitTestable(),
        );
        for (var i = 0; i < 10; i++) {
          await tester.pump(const Duration(milliseconds: 50));
        }
        if (mornye) {
          await tester.ensureVisible(
            find.text(l10n.libraryFilterSortSizeLargest),
          );
        }
        expect(find.text(l10n.libraryFilterSortSizeLargest), findsOneWidget);
        expect(find.text(l10n.libraryFilterSortSizeSmallest), findsOneWidget);
        await tester.tap(find.text(l10n.libraryFilterSortSizeLargest));
        if (mornye) {
          await tester.ensureVisible(find.text(l10n.libraryFilterApply));
          await tester.tap(find.text(l10n.libraryFilterApply));
        }
        for (var i = 0; i < 10; i++) {
          await tester.pump(const Duration(milliseconds: 50));
        }
        expect(queries.any((sql) => sql.contains('sort_size DESC')), isTrue);
        expect(find.text(l10n.libraryFilterSortSizeSmallest), findsNothing);
        if (!mornye) {
          await tester.tap(
            find.descendant(
              of: find.byType(TabBar),
              matching: find.text(l10n.searchPlaylists),
            ),
          );
          for (var i = 0; i < 40; i++) {
            await tester.pump(const Duration(milliseconds: 50));
          }
          final preferences = await SharedPreferences.getInstance();
          expect(
            loadBootstrapSettings(preferences).historySortMode,
            'size-desc',
          );
          await tester.tap(
            find
                .descendant(of: find.byType(TabBar), matching: find.byType(Tab))
                .first,
          );
          for (var i = 0; i < 40; i++) {
            await tester.pump(const Duration(milliseconds: 50));
          }
          expect(
            find.text(l10n.libraryFilterSortSizeLargest).hitTestable(),
            findsOneWidget,
          );
        }
        expect(tester.takeException(), isNull);
      });

      testWidgets('album grid preserves year order across local and downloads '
          '(desktop: $desktop, Mornye: $mornye)', (tester) async {
        albumRows.addAll([
          ['local', 'new|artist', 'New', 'Artist', 2, 1, '/new.flac', 2026],
          [
            'downloaded',
            'old|artist',
            'Old',
            'Artist',
            2,
            1,
            '/old.flac',
            2001,
          ],
          [
            'local',
            'unknown|artist',
            'Unknown',
            'Artist',
            2,
            1,
            '/unknown.flac',
            0,
          ],
        ]);
        await pumpLibrary(
          tester,
          desktop: desktop,
          mornye: mornye,
          librarySection: 'albums',
        );
        final container = ProviderScope.containerOf(
          tester.element(find.byType(QueueTab)),
        );
        container
            .read(settingsProvider.notifier)
            .setHistorySortMode('year-desc');
        for (var i = 0; i < 20; i++) {
          await tester.pump(const Duration(milliseconds: 50));
        }
        final grid = find.byType(AnimatedLibrarySliverGrid);
        final delegate =
            tester.widget<AnimatedLibrarySliverGrid>(grid).delegate
                as SliverChildBuilderDelegate;
        expect(delegate.childCount, 3);
        expect(
          [
            for (var i = 0; i < delegate.childCount!; i++)
              delegate.builder(tester.element(grid), i)!.key,
          ],
          [
            const ValueKey('local_new|artist'),
            const ValueKey('Old|Artist'),
            const ValueKey('local_unknown|artist'),
          ],
        );
        expect(tester.takeException(), isNull);
      });

      for (final newest in [false, true]) {
        testWidgets('year sort applies and restores from the Library menu '
            '(desktop: $desktop, Mornye: $mornye, newest: $newest)', (
          tester,
        ) async {
          await pumpLibrary(tester, desktop: desktop, mornye: mornye);
          final l10n = l10nOf(tester);
          final label = newest
              ? l10n.libraryFilterSortYearDesc
              : l10n.libraryFilterSortYearAsc;
          final mode = newest ? 'year-desc' : 'year-asc';
          await tester.tap(
            find
                .text(
                  mornye
                      ? l10n.libraryFilterTitle
                      : l10n.libraryFilterSortLatest,
                )
                .hitTestable(),
          );
          for (var i = 0; i < 10; i++) {
            await tester.pump(const Duration(milliseconds: 50));
          }
          final choice = find.text(label);
          await tester.ensureVisible(choice);
          await tester.pump(const Duration(milliseconds: 300));
          await tester.tap(choice);
          if (mornye) {
            await tester.ensureVisible(find.text(l10n.libraryFilterApply));
            await tester.pump(const Duration(milliseconds: 300));
            await tester.tap(find.text(l10n.libraryFilterApply));
          }
          for (var i = 0; i < 10; i++) {
            await tester.pump(const Duration(milliseconds: 50));
          }
          final preferences = await SharedPreferences.getInstance();
          expect(loadBootstrapSettings(preferences).historySortMode, mode);
          expect(
            queries.any(
              (sql) =>
                  sql.contains('THEN CAST(') &&
                  sql.contains('sort_release ${newest ? 'DESC' : 'ASC'}'),
            ),
            isTrue,
          );
          await tester.pumpWidget(const SizedBox.shrink());
          await pumpLibrary(tester, desktop: desktop, mornye: mornye);
          final container = ProviderScope.containerOf(
            tester.element(find.byType(QueueTab)),
          );
          expect(container.read(settingsProvider).historySortMode, mode);
          expect(tester.takeException(), isNull);
        });
      }
    }
  }

  testWidgets('the view tool switches the Library to the grid', (tester) async {
    await pumpLibrary(tester);
    final l10n = l10nOf(tester);

    await tester.tap(toolButton(l10n.appearanceHistoryViewGrid));
    await tester.pump();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(QueueTab)),
    );
    expect(container.read(settingsProvider).historyViewMode, 'grid');
  });

  testWidgets('reduced motion keeps the separate Material buttons', (
    tester,
  ) async {
    await pumpLibrary(tester, reduceMotion: true);
    final l10n = l10nOf(tester);

    expect(find.byType(M3EButtonGroup), findsNothing);
    expect(find.text(l10n.libraryFilterSortLatest), findsOneWidget);
    expect(find.text(l10n.libraryFilterTitle), findsOneWidget);
  });

  testWidgets('the Folders tab browses the Library by folder', (tester) async {
    await pumpLibrary(tester);
    final l10n = l10nOf(tester);

    await tester.tap(
      find.descendant(
        of: find.byType(TabBar),
        matching: find.text(l10n.libraryFolders),
      ),
    );
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    expect(find.byType(LibraryDirectoryView), findsOneWidget);
    // The mocked database has no songs.
    expect(find.text(l10n.libraryFoldersEmptyTitle), findsOneWidget);
    final container = ProviderScope.containerOf(
      tester.element(find.byType(QueueTab)),
    );
    expect(container.read(settingsProvider).historyFilterMode, 'folders');
  });

  testWidgets('the Genres tab lists genres and opens one; six tabs scroll at '
      'phone width', (tester) async {
    const genre = LibraryBrowseEntry(
      source: '',
      key: 'rock',
      name: 'Rock',
      artist: '',
      samplePath: '',
      trackCount: 2,
    );
    await pumpLibrary(
      tester,
      size: const Size(390, 844),
      overrides: [
        libraryGenresProvider.overrideWith((ref) async => const [genre]),
        libraryGenreSongsProvider.overrideWith(
          (ref, key) async => [
            for (final id in ['a', 'b'])
              UnifiedLibraryItem.fromLocalLibrary(
                LocalLibraryItem(
                  id: id,
                  trackName: 'Rock song $id',
                  artistName: 'Artist',
                  albumName: 'Album',
                  filePath: '/music/$id.flac',
                  scannedAt: DateTime(2026, 11, 16),
                ),
              ),
          ],
        ),
      ],
    );
    final l10n = l10nOf(tester);
    final tabs = find.byType(TabBar);
    expect(tester.widget<TabBar>(tabs).isScrollable, isTrue);
    expect(
      find.descendant(of: tabs, matching: find.byType(Tab)),
      findsNWidgets(6),
    );
    final genresTab = find.descendant(
      of: tabs,
      matching: find.text(l10n.libraryGenres),
    );
    await tester.ensureVisible(genresTab);
    await tester.pump();
    await tester.tap(genresTab);
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    final container = ProviderScope.containerOf(
      tester.element(find.byType(QueueTab)),
    );
    expect(container.read(settingsProvider).historyFilterMode, 'genres');
    expect(find.text('Rock'), findsOneWidget);
    expect(find.text(l10n.tracksCount(2)), findsOneWidget);

    await tester.tap(find.text('Rock'));
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(find.byType(LibraryMixScreen), findsOneWidget);
    expect(find.text('Rock song a'), findsOneWidget);
    expect(find.text('Rock song b'), findsOneWidget);
    await pageBack(tester);
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    // The last tab is still reachable at phone width.
    final foldersTab = find.descendant(
      of: tabs,
      matching: find.text(l10n.libraryFolders),
    );
    await tester.ensureVisible(foldersTab);
    await tester.pump();
    await tester.tap(foldersTab);
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(find.byType(LibraryDirectoryView), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the Genres tab explains an empty Library', (tester) async {
    await pumpLibrary(tester);
    final l10n = l10nOf(tester);

    await tester.tap(
      find.descendant(
        of: find.byType(TabBar),
        matching: find.text(l10n.libraryGenres),
      ),
    );
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    // The mocked database has no songs.
    expect(find.text(l10n.libraryGenresEmpty), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the pager leaves sideways swipes to song rows while they '
      'swipe to queue', (tester) async {
    await pumpLibrary(
      tester,
      overrides: [
        // Songs sit beside the folders on the Folders page.
        libraryDirectoryIndexProvider.overrideWith(
          (ref) async => LibraryDirectoryIndex.build([
            for (final song in ['a', 'b'])
              LibraryDirectoryEntry(
                source: 'downloaded',
                id: song,
                path: '/storage/emulated/0/Music/$song.flac',
              ),
          ]),
        ),
        libraryDirectoryItemsLoaderProvider.overrideWithValue(
          (tracks) async => const [],
        ),
      ],
    );
    final l10n = l10nOf(tester);
    final container = ProviderScope.containerOf(
      tester.element(find.byType(QueueTab)),
    );
    ScrollPhysics? pagerPhysics() => tester
        .widget<PageView>(
          find.descendant(
            of: find.byType(QueueTab),
            matching: find.byType(PageView),
          ),
        )
        .physics;
    Future<void> settle() async {
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
    }

    Future<void> openTab(String label) async {
      final tab = find.descendant(
        of: find.byType(TabBar),
        matching: find.text(label),
      );
      await tester.ensureVisible(tab);
      await tester.pump();
      await tester.tap(tab);
      await settle();
    }

    expect(container.read(settingsProvider).swipeToQueue, isTrue);
    expect(pagerPhysics(), isA<NeverScrollableScrollPhysics>());

    // A grid of songs has no rows to swipe, so the pager swipes.
    container.read(settingsProvider.notifier).setHistoryViewMode('grid');
    await tester.pump();
    expect(pagerPhysics(), isA<ClampingScrollPhysics>());
    container.read(settingsProvider.notifier).setHistoryViewMode('list');
    await tester.pump();
    expect(pagerPhysics(), isA<NeverScrollableScrollPhysics>());

    // So does a page of collections, and a drag from it lands on the songs.
    await openTab(l10n.historyFilterAlbums);
    expect(pagerPhysics(), isA<ClampingScrollPhysics>());
    final pager = find.descendant(
      of: find.byType(QueueTab),
      matching: find.byType(PageView),
    );
    await tester.fling(pager, const Offset(600, 0), 2000);
    await settle();
    expect(tester.widget<PageView>(pager).controller!.page, 0);
    expect(pagerPhysics(), isA<NeverScrollableScrollPhysics>());

    // The tabs still change pages, and Folders lists song rows.
    await openTab(l10n.libraryFolders);
    expect(find.byType(LibraryDirectoryView), findsOneWidget);
    expect(pagerPhysics(), isA<NeverScrollableScrollPhysics>());

    // With the setting off the pager swipes as before.
    container.read(settingsProvider.notifier).setSwipeToQueue(false);
    await tester.pump();
    expect(pagerPhysics(), isA<ClampingScrollPhysics>());
  });

  testWidgets('the Folders page swipes while it lists folders only', (
    tester,
  ) async {
    await pumpLibrary(
      tester,
      overrides: [
        libraryDirectoryIndexProvider.overrideWith(
          (ref) async => LibraryDirectoryIndex.build([
            for (final album in ['One', 'Two'])
              LibraryDirectoryEntry(
                source: 'downloaded',
                id: album,
                path: '/storage/emulated/0/Music/$album/song.flac',
              ),
          ]),
        ),
      ],
    );
    final l10n = l10nOf(tester);
    final tab = find.descendant(
      of: find.byType(TabBar),
      matching: find.text(l10n.libraryFolders),
    );
    await tester.ensureVisible(tab);
    await tester.pump();
    await tester.tap(tab);
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(find.byType(LibraryDirectoryView), findsOneWidget);
    final pager = find.descendant(
      of: find.byType(QueueTab),
      matching: find.byType(PageView),
    );
    expect(
      tester.widget<PageView>(pager).physics,
      isA<ClampingScrollPhysics>(),
    );
    expect(tester.takeException(), isNull);
  });

  for (final mornye in [false, true]) {
    testWidgets('a searched song plays on into the Songs list in its sort '
        'and filters (Mornye: $mornye)', (tester) async {
      UnifiedLibraryItem song(String id) => UnifiedLibraryItem.fromLocalLibrary(
        LocalLibraryItem(
          id: id,
          trackName: 'Track $id',
          artistName: 'Artist',
          albumName: 'Album',
          filePath: '/music/$id.flac',
          scannedAt: DateTime(2026),
        ),
      );
      final lists = <LibrarySongListRequest>[];
      final player = _Playback();
      await pumpLibrary(
        tester,
        mornye: mornye,
        overrides: [
          playbackProvider.overrideWith(() => player),
          librarySearchProvider.overrideWith(
            (ref, request) async => request.kind == LibrarySearchKind.songs
                ? [
                    const LibrarySearchHit(
                      kind: LibrarySearchKind.songs,
                      id: 'b',
                      title: 'Track b',
                      source: 'local',
                    ),
                  ]
                : [],
          ),
          librarySearchTrackProvider.overrideWith(
            (ref, key) async => song(key.id),
          ),
          librarySongListProvider.overrideWith((ref, request) async {
            lists.add(request);
            return [
              for (final id in ['a', 'b', 'c']) song(id),
            ];
          }),
        ],
      );
      final l10n = l10nOf(tester);
      final container = ProviderScope.containerOf(
        tester.element(find.byType(QueueTab)),
      );
      container.read(settingsProvider.notifier).setHistorySortMode('oldest');
      await tester.tap(find.text(l10n.libraryFilterTitle).hitTestable());
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      await tester.tap(find.text(l10n.libraryFilterQualityHiRes));
      await tester.ensureVisible(find.text(l10n.libraryFilterApply));
      await tester.tap(find.text(l10n.libraryFilterApply));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }

      await tester.enterText(
        find.descendant(
          of: find.byType(AppSearchField),
          matching: find.byType(EditableText),
        ),
        'Track',
      );
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(find.text('Track b'), findsOneWidget);
      expect(lists, isEmpty);
      // A tap on the song plays it, as its Play button did.
      await tester.tap(find.text('Track b').hitTestable());
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }

      expect(lists, [
        (
          filterMode: 'all',
          sortMode: 'oldest',
          source: null,
          quality: 'hires',
          format: null,
          metadata: null,
          includeLocal: container.read(settingsProvider).localLibraryEnabled,
        ),
      ]);
      expect(player.queues, [
        ['/music/a.flac', '/music/b.flac', '/music/c.flac'],
      ]);
      expect(player.starts, [1]);
      expect(tester.takeException(), isNull);
    });
  }

  for (final mornye in [false, true]) {
    testWidgets('an unsearched song plays on into the loaded Songs list '
        '(Mornye: $mornye)', (tester) async {
      final lists = <LibrarySongListRequest>[];
      final player = _Playback();
      await pumpLibrary(
        tester,
        mornye: mornye,
        dates: [DateTime(2026, 1, 12), DateTime(2026, 1, 11), DateTime(2026)],
        overrides: [
          playbackProvider.overrideWith(() => player),
          librarySongListProvider.overrideWith((ref, request) async {
            lists.add(request);
            return const [];
          }),
        ],
      );
      // A tap on the song plays it, as its Play button did.
      await tester.tap(find.text('Song 1').hitTestable());
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }

      expect(lists, isEmpty);
      expect(player.queues, [
        ['/music/song-0.flac', '/music/song-1.flac', '/music/song-2.flac'],
      ]);
      expect(player.starts, [1]);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('Mornye keeps its filter button', (tester) async {
    await pumpLibrary(tester, mornye: true);
    final l10n = l10nOf(tester);

    expect(find.byType(M3EButtonGroup), findsNothing);
    expect(find.text(l10n.libraryFilterTitle), findsOneWidget);
  });

  testWidgets('month headers are start-aligned text headers', (tester) async {
    final now = DateTime.now();
    await pumpLibrary(tester, dates: [DateTime(2020, 1, 10), now]);
    final handle = tester.ensureSemantics();
    final colors = Theme.of(tester.element(find.byType(QueueTab))).colorScheme;

    for (final label in [DateFormat.yMMMM('en').format(now), 'January 2020']) {
      final header = find.text(label);
      expect(tester.widget<Text>(header).style?.color, colors.primary);
      final band = find
          .ancestor(of: header, matching: find.byType(ColoredBox))
          .first;
      expect(
        tester.getRect(header).left,
        moreOrLessEquals(tester.getRect(band).left + 20),
      );
      expect(tester.getSemantics(header), isSemantics(isHeader: true));
    }
    handle.dispose();
  });

  testWidgets('a rebuild with unchanged rows reuses the month sections', (
    tester,
  ) async {
    await pumpLibrary(
      tester,
      dates: [
        for (var day = 1; day <= 6; day++) DateTime(2026, 3, day),
        DateTime(2025, 12, 24),
      ],
    );
    final sectionList = find.byWidgetPredicate(
      (widget) => widget.runtimeType.toString() == '_LibrarySectionList',
    );
    // Read the private list's sections without adding a test hook.
    List<Object?> sections() =>
        // ignore: avoid_dynamic_calls
        (tester.widget(sectionList) as dynamic).sections as List<Object?>;
    final widgetBefore = tester.widget(sectionList);
    final before = sections();
    expect(before, hasLength(2));

    // Badge text is display-only: the Library rebuilds with the same rows.
    ProviderScope.containerOf(tester.element(find.byType(QueueTab)))
        .read(settingsProvider.notifier)
        .setLibraryQualityLabelMode(AppSettings.libraryQualityLabelFileFormat);
    await tester.pump();

    expect(tester.widget(sectionList), isNot(same(widgetBefore)));
    expect(sections(), same(before));
  });
}
