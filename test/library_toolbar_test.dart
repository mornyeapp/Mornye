import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart' show DateFormat;
import 'package:material_3_expressive/material_3_expressive.dart'
    show M3EButton, M3EButtonGroup, M3EButtonGroupType;
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/download_item.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/download_queue_provider.dart';
import 'package:mornye/providers/library_collections_provider.dart';
import 'package:mornye/providers/local_library_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/screens/library_tracks_folder_screen.dart';
import 'package:mornye/screens/queue_tab.dart';
import 'package:mornye/services/history_database.dart';
import 'package:mornye/services/library_database.dart';
import 'package:mornye/theme/app_theme.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:mornye/widgets/app_search_field.dart';
import 'package:mornye/widgets/library_directory_view.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';

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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final queries = <String>[];

  setUp(() {
    queries.clear();
    SharedPreferences.setMockInitialValues({});
    final previousFactory = databaseFactoryOrNull;
    databaseFactory = databaseFactorySqflitePlugin;
    addTearDown(() => databaseFactory = previousFactory);
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const paths = MethodChannel('plugins.flutter.io/path_provider');
    messenger.setMockMethodCallHandler(paths, (_) async => '/test/documents');
    addTearDown(() => messenger.setMockMethodCallHandler(paths, null));
    // An empty database: every page query returns no rows.
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
  }) async {
    final preferences = await SharedPreferences.getInstance();
    debugDesktopPlatformOverride = desktop;
    tester.view.physicalSize = const Size(1280, 900);
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
          home: Scaffold(body: QueueTab(librarySection: mornye ? 'all' : null)),
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
      expect(group.actions, hasLength(3));
      // Sort keeps its label so the current order stays visible.
      expect(
        (group.actions[0].label! as Text).data,
        l10n.libraryFilterSortLatest,
      );
      expect((group.actions[1].label! as Text).data, l10n.libraryFilterTitle);
      expect(group.actions[2].tooltip, l10n.appearanceHistoryViewGrid);
      expect(group.actions[2].label, isNull);
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

  testWidgets('the desktop sort menu opens below the sort button', (
    tester,
  ) async {
    await pumpLibrary(tester, desktop: true);
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
