import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/providers/download_history_provider.dart';
import 'package:mornye/providers/library_browse_provider.dart';
import 'package:mornye/providers/library_collections_provider.dart';
import 'package:mornye/providers/local_library_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/screens/mornye_library_screen.dart';
import 'package:mornye/services/library_collections_database.dart';
import 'package:mornye/services/library_database.dart';
import 'package:mornye/services/library_search.dart';
import 'package:mornye/services/platform_bridge.dart';
import 'package:mornye/theme/mornye_theme.dart';

import '../test/support/library_native_fixture.dart';
import '../test/support/library_paging_fixture.dart';
import 'performance_probe.dart';

const _browse = (
  artists: false,
  artist: null,
  search: '',
  sort: 'a-z',
  limit: 40,
  completeness: null,
);

class _Settings extends SettingsNotifier {
  @override
  AppSettings build() => const AppSettings(localLibraryEnabled: true);

  @override
  Future<void> ensureLoaded() async {}
}

class _History extends DownloadHistoryNotifier {
  @override
  DownloadHistoryState build() => DownloadHistoryState();
}

class _Timeline {
  final clock = Stopwatch()..start();
  final events = <Map<String, Object?>>[];
  String scenario = 'setup';

  Future<T> span<T>(String name, Future<T> Function() action) async {
    final start = clock.elapsedMicroseconds;
    final label = scenario;
    try {
      return await action();
    } finally {
      events.add({
        'scenario': label,
        'stage': name,
        'start_us': start,
        'elapsed_us': clock.elapsedMicroseconds - start,
      });
    }
  }
}

class _Library extends LibraryDatabase {
  _Library(super.database, this.timeline, {required bool fts})
    : super.withDatabase(historyAttached: true, searchFtsAvailable: fts);

  final _Timeline timeline;

  @override
  Future<List<LocalLibrarySource>> getSources() =>
      timeline.span('source_rows_and_counts', super.getSources);

  @override
  Future<int> getCount() => timeline.span('visible_count', super.getCount);

  @override
  Future<LocalLibraryLookupIndex> getLookupIndex() =>
      timeline.span('lookup_rows_decode_and_sets', super.getLookupIndex);
}

class _Collections extends LibraryCollectionsDatabase {
  _Collections(super.database, this.timeline) : super.withDatabase();

  final _Timeline timeline;
  final snapshots = <Map<String, Object?>>[];

  @override
  Future<LibraryCollectionsSnapshot> loadSnapshot() async {
    final snapshot = await timeline.span(
      'collections_sqlite_snapshot_and_native_export',
      super.loadSnapshot,
    );
    snapshots.add({
      'kind': 'collections',
      'native_rows': snapshot.nativeRowCount,
      'native_file': snapshot.nativeRowsPath != null,
    });
    return snapshot;
  }

  @override
  Future<LibraryPlaylistTracksSnapshot> loadPlaylistTracksSnapshot(
    String playlistId,
  ) async {
    final snapshot = await timeline.span(
      'playlist_sqlite_snapshot_and_native_export',
      () => super.loadPlaylistTracksSnapshot(playlistId),
    );
    snapshots.add({
      'kind': 'playlist',
      'native_rows': snapshot.nativeRowCount,
      'native_file': snapshot.nativeRowsPath != null,
    });
    return snapshot;
  }

  @override
  Future<void> upsertPlaylist({
    required String id,
    required String name,
    String? coverImagePath,
    required String createdAt,
    required String updatedAt,
  }) => timeline.span(
    'playlist_insert_transaction',
    () => super.upsertPlaylist(
      id: id,
      name: name,
      coverImagePath: coverImagePath,
      createdAt: createdAt,
      updatedAt: updatedAt,
    ),
  );

  @override
  Future<void> reorderPlaylistTracks({
    required String playlistId,
    required Map<String, String> addedAtByKey,
    required String playlistUpdatedAt,
  }) => timeline.span(
    'playlist_order_transaction_and_link_triggers',
    () => super.reorderPlaylistTracks(
      playlistId: playlistId,
      addedAtByKey: addedAtByKey,
      playlistUpdatedAt: playlistUpdatedAt,
    ),
  );
}

Future<void> _createCover(String path, {int variation = 0}) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawColor(Color(0xff305060 + variation * 0x00020103), BlendMode.src);
  canvas.drawCircle(
    Offset(120 + variation % 9 * 5, 140 + variation % 11 * 5),
    125,
    Paint()..color = const Color(0xffc47f56),
  );
  final picture = recorder.endRecording();
  final image = await picture.toImage(384, 384);
  try {
    final bytes = (await image.toByteData(format: ui.ImageByteFormat.png))!;
    await File(path).writeAsBytes(bytes.buffer.asUint8List());
  } finally {
    image.dispose();
    picture.dispose();
  }
}

void main() {
  final binding = PerformanceTestBinding.ensureInitialized();
  testWidgets('private SQLite Library and collection production pipelines', (
    tester,
  ) async {
    final probe = PerformanceProbe(binding, tester, suite: 'library_pipeline');
    final timeline = _Timeline();
    final root = await Directory.systemTemp.createTemp('library-pipeline-');
    final temporary = await getTemporaryDirectory();
    await temporary.create(recursive: true);
    final cover = '${root.path}/cover.png';
    await _createCover(cover);
    final localFolder = await Directory('${root.path}/music').create();
    final scanFolder = await Directory('${root.path}/scanned').create();
    final extensions = await Directory('${root.path}/extensions').create();
    final data = await Directory('${root.path}/data').create();
    final output = await Directory('${root.path}/output').create();
    SharedPreferences.setMockInitialValues({
      'library_collections_migrated_to_sqlite_v1': true,
    });
    await PlatformBridge.initExtensionSystem(
      extensions.path,
      data.path,
      masterKey: base64Encode(List<int>.filled(32, 1)),
      lyricsProviders: const [],
      lyricsFetchOptions: const {},
      allowedDirectories: [output.path],
    );
    final database = await openDatabase(
      '${root.path}/library.db',
      singleInstance: false,
      onConfigure: (db) async {
        await db.rawQuery('PRAGMA journal_mode=WAL');
        await db.execute('PRAGMA synchronous=NORMAL');
        await db.execute('PRAGMA recursive_triggers=ON');
      },
    );
    await createLibraryPagingFixture(
      database,
      albumsPerSource: 2000,
      cover: cover,
    );
    await database.update(
      'library_sources',
      {'path': localFolder.path},
      where: 'id = ?',
      whereArgs: ['legacy'],
    );
    await database.execute(
      "UPDATE library SET match_key=track_name_norm || '|' || artist_name_norm "
      "WHERE track_name_norm IS NOT NULL",
    );
    final fts = (await database.rawQuery(
      "SELECT 1 FROM sqlite_master WHERE name='library_search_fts'",
    )).isNotEmpty;
    final library = _Library(database, timeline, fts: fts);
    final collectionDatabase = await LibraryCollectionsDatabase.openWithFactory(
      databaseFactory,
      '${root.path}/collections.db',
    );
    await collectionDatabase.rawQuery('PRAGMA journal_mode=WAL');
    await collectionDatabase.execute('PRAGMA synchronous=NORMAL');
    final collections = _Collections(collectionDatabase, timeline);
    const playlistSize = 12000;
    const stamp = '2026-10-01T00:00:00.000Z';
    await collectionDatabase.transaction((txn) async {
      await txn.insert('playlists', {
        'id': 'fixture',
        'name': 'Fixture playlist',
        'created_at': stamp,
        'updated_at': stamp,
      });
      final batch = txn.batch();
      for (var index = 0; index < playlistSize; index++) {
        batch.insert('playlist_tracks', {
          'playlist_id': 'fixture',
          'track_key': 'example:$index',
          'track_json': jsonEncode({
            'id': '$index',
            'name': 'Song $index',
            'artistName': 'Artist ${index % 97}',
            'albumName': 'Album ${index ~/ 12}',
            'duration': 180,
            'source': 'example',
          }),
          'added_at': stamp,
        });
      }
      await batch.commit(noResult: true);
    });
    ProviderContainer? container;
    addTearDown(() async {
      container?.dispose();
      await collectionDatabase.close();
      await database.close();
      await PlatformBridge.cleanupExtensions();
      await root.delete(recursive: true);
    });
    var returnedRows = 0;
    var browseReads = 0;
    var providerPublications = 0;
    final markers = <Map<String, Object?>>[];
    final artworkCache = <Map<String, Object?>>[];

    Future<void> painted() async {
      binding.scheduleFrame();
      await binding.endOfFrame;
    }

    Future<void> until(bool Function() condition) async {
      final watch = Stopwatch()..start();
      while (!condition()) {
        if (watch.elapsed > const Duration(seconds: 60)) {
          fail('Pipeline did not finish: ${timeline.scenario}');
        }
        await probe.wait(const Duration(milliseconds: 1));
      }
    }

    Future<void> scenario(
      String name,
      Future<void> Function() action, {
      bool allowIdle = false,
    }) => probe.measure(
      name,
      () async {
        timeline.scenario = name;
        await timeline.span(name, action);
      },
      warmup: () async {},
      repetitions: 1,
      allowIdle: allowIdle,
    );

    await scenario('first_library_mount_to_summary_and_album_paint', () async {
      container = ProviderContainer(
        overrides: [
          settingsProvider.overrideWith(_Settings.new),
          downloadHistoryProvider.overrideWith(_History.new),
          localLibraryProvider.overrideWith(
            () => LocalLibraryNotifier(database: library),
          ),
          libraryCollectionsProvider.overrideWith(
            () => LibraryCollectionsNotifier(database: collections),
          ),
          libraryBrowsePageLoaderProvider.overrideWithValue((request) async {
            final page = await timeline.span(
              'album_page_sql_and_mapping',
              () async {
                final result = await library.getQueueAlbumPageResult(
                  libraryBrowseQuery(request),
                );
                return LibraryBrowsePage.fromRows(
                  result.rows,
                  artists: false,
                  nextCursor: result.nextCursor,
                );
              },
            );
            browseReads++;
            returnedRows += page.entries.length;
            return page;
          }),
        ],
      );
      container!.listen(localLibraryProvider, (_, next) {
        providerPublications++;
        if (!next.isLoading && next.loadedIndexVersion > 0) {
          markers.add({
            'stage': 'local_summary_published',
            'at_us': timeline.clock.elapsedMicroseconds,
            'count': next.totalCount,
          });
        }
      });
      binding.attachRootWidget(
        binding.wrapWithDefaultView(
          UncontrolledProviderScope(
            container: container!,
            child: MaterialApp(
              theme: MornyeTheme.build(Brightness.dark),
              locale: const Locale('en'),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: Scaffold(
                body: MornyeLibraryScreen(
                  page: MornyeLibraryPage.albums,
                  onOpenSection: (_) {},
                ),
              ),
            ),
          ),
        ),
      );
      await painted();
      await until(() {
        final local = container!.read(localLibraryProvider);
        final browse = container!.read(libraryBrowseProvider(_browse));
        return !local.isLoading &&
            local.loadedIndexVersion > 0 &&
            browse.hasValue &&
            !browse.isLoading;
      });
      await painted();
      expect(container!.read(localLibraryProvider).loadFailed, isFalse);
      expect(container!.read(localLibraryProvider).totalCount, 4200);
      expect(find.text('Album 0000'), findsWidgets);
    });

    await scenario('scroll_retaining_1000_album_rows', () async {
      final notifier = container!.read(libraryBrowseProvider(_browse).notifier);
      while (container!
              .read(libraryBrowseProvider(_browse))
              .requireValue
              .entries
              .length <
          1000) {
        await notifier.loadMore();
        await painted();
      }
      final scroll = tester
          .widget<CustomScrollView>(find.byType(CustomScrollView))
          .controller!;
      await probe.scroll(scroll, distance: 3000);
    });

    for (final kind in [
      LibrarySearchKind.songs,
      LibrarySearchKind.albums,
      LibrarySearchKind.artists,
    ]) {
      await scenario('search_${kind.name}_sql_to_hits', () async {
        final hits = await library.searchLibrary(
          query: 'Artist 0199',
          kind: kind,
          includeLocal: true,
        );
        expect(hits, isNotEmpty);
        expect(hits.length, lessThanOrEqualTo(40));
      }, allowIdle: true);
    }

    final scanFile = File('${root.path}/scan.ndjson');
    await scanFile.writeAsString(
      [
        for (var index = 0; index < 1200; index++)
          jsonEncode(nativeLibraryTrack('scan-$index')),
      ].join('\n'),
    );
    await database.insert('library_sources', {
      'id': 'source',
      'path': scanFolder.path,
      'display_name': 'Scan fixture',
    });
    final readsBeforeScan = browseReads;
    final rowsBeforeScan = returnedRows;
    await scenario(
      'scan_ndjson_native_commit_to_retained_browse_paint',
      () async {
        final result = await timeline.span(
          'native_scan_stage_and_sqlite_publish',
          () => library.replaceSourceScanFile(
            'source',
            LibraryScanNDJSONFile(file: scanFile, expectedCount: 1200),
            requestId: 'library-pipeline-scan',
            isCancelled: () => false,
          ),
        );
        expect(result.inserted, 1200);
        final previous = container!
            .read(localLibraryProvider)
            .loadedIndexVersion;
        await container!
            .read(localLibraryProvider.notifier)
            .reloadFromStorage();
        await until(() {
          final local = container!.read(localLibraryProvider);
          final browse = container!.read(libraryBrowseProvider(_browse));
          return local.loadedIndexVersion > previous &&
              browse.hasValue &&
              !browse.isLoading &&
              browse.requireValue.entries.length >= 1000;
        });
        await painted();
        expect(container!.read(localLibraryProvider).totalCount, 5400);
      },
    );
    final scanRefreshReads = browseReads - readsBeforeScan;
    final scanRefreshRows = returnedRows - rowsBeforeScan;

    const coverCount = 64;
    final covers = <String>[];
    for (var index = 0; index < coverCount; index++) {
      final path = '${root.path}/cover-$index.png';
      await _createCover(path, variation: index + 1);
      covers.add(path);
    }
    final coverCase = [
      'CASE CAST(SUBSTR(album_name, 7) AS INTEGER) % $coverCount',
      for (var index = 0; index < coverCount; index++) 'WHEN $index THEN ?',
      'END',
    ].join(' ');
    await database.rawUpdate(
      'UPDATE library SET cover_path=$coverCase',
      covers,
    );
    await database.rawUpdate(
      'UPDATE history_db.history SET cover_url=$coverCase',
      covers,
    );
    await scenario('varied_64_covers_refresh_and_scroll', () async {
      final cache = PaintingBinding.instance.imageCache;
      artworkCache.add({
        'stage': 'before_varied_covers',
        'entries': cache.currentSize,
        'bytes': cache.currentSizeBytes,
        'pending': cache.pendingImageCount,
      });
      await container!.read(localLibraryProvider.notifier).reloadFromStorage();
      await until(() {
        final browse = container!.read(libraryBrowseProvider(_browse));
        return browse.hasValue && !browse.isLoading;
      });
      await painted();
      final scroll = tester
          .widget<CustomScrollView>(find.byType(CustomScrollView))
          .controller!;
      scroll.jumpTo(0);
      await painted();
      await probe.scroll(
        scroll,
        distance: 20000,
        duration: const Duration(milliseconds: 1500),
      );
      artworkCache.add({
        'stage': 'after_varied_covers',
        'entries': cache.currentSize,
        'bytes': cache.currentSizeBytes,
        'pending': cache.pendingImageCount,
      });
    });

    await scenario('collection_snapshot_to_provider_publication', () async {
      container!.listen(libraryCollectionsProvider, (_, _) {
        providerPublications++;
      });
      await until(() => container!.read(libraryCollectionsProvider).isLoaded);
      final playlist = container!
          .read(libraryCollectionsProvider)
          .playlistById('fixture')!;
      expect(playlist.trackCount, playlistSize);
      expect(playlist.tracksLoaded, isFalse);
    }, allowIdle: true);
    final collectionNotifier = container!.read(
      libraryCollectionsProvider.notifier,
    );
    await scenario('playlist_create_commit_to_provider_publication', () async {
      final id = await collectionNotifier.createPlaylist('Created fixture');
      expect(
        container!.read(libraryCollectionsProvider).playlistById(id),
        isNotNull,
      );
      expect(
        await collectionDatabase.query(
          'playlists',
          where: 'id=?',
          whereArgs: [id],
        ),
        hasLength(1),
      );
    }, allowIdle: true);
    await scenario(
      'playlist_open_native_snapshot_worker_to_publication',
      () async {
        await collectionNotifier.ensurePlaylistLoaded('fixture');
        expect(
          container!
              .read(libraryCollectionsProvider)
              .playlistById('fixture')!
              .tracks,
          hasLength(playlistSize),
        );
      },
      allowIdle: true,
    );
    final original = container!
        .read(libraryCollectionsProvider)
        .playlistById('fixture')!
        .tracks
        .map((entry) => entry.key)
        .toList();
    await scenario('playlist_reorder_prepare_commit_to_publication', () async {
      expect(
        await collectionNotifier.reorderPlaylistTracks(
          'fixture',
          original.reversed.toList(),
        ),
        isTrue,
      );
      expect(
        container!
            .read(libraryCollectionsProvider)
            .playlistById('fixture')!
            .tracks
            .first
            .key,
        original.last,
      );
    }, allowIdle: true);
    await scenario('playlist_reopen_after_reorder', () async {
      await collectionNotifier.reloadFromDatabase();
      await collectionNotifier.ensurePlaylistLoaded('fixture');
      expect(
        container!
            .read(libraryCollectionsProvider)
            .playlistById('fixture')!
            .tracks
            .map((entry) => entry.key),
        original.reversed,
      );
    }, allowIdle: true);

    await probe.finish(
      metadata: {
        'fixture': {
          'albums_per_source': 2000,
          'initial_visible_local_tracks': 4200,
          'scan_rows': 1200,
          'playlist_tracks': playlistSize,
          'local_fts': fts,
          'artwork':
              'One shared 384px local cover for metadata scenarios, followed '
              'by 64 distinct generated 384px PNGs in a separate scroll pass',
        },
        'scope':
            'Real sqflite, production schema/adapters/notifiers and native '
            'collection and ingestion workers. Library browse uses the production '
            'screen. Settings and History state are fixed fixture configuration.',
        'limitations':
            'Backend initialization, schema/fixture creation and app '
            'shell startup are excluded. Scan starts with synthetic NDJSON, '
            'excluding filesystem traversal and metadata extraction; summary '
            'refresh uses reloadFromStorage, excluding scan completion '
            'preferences, notifications and cover pruning. Search ends '
            'at mapped hits; collection endpoints are provider publication, '
            'excluding their screens. One diagnostic sample per scenario.',
        'browse_reads': browseReads,
        'browse_returned_rows': returnedRows,
        'scan_refresh_reads': scanRefreshReads,
        'scan_refresh_returned_rows': scanRefreshRows,
        'provider_publications': providerPublications,
        'native_snapshots': collections.snapshots,
        'artwork_cache': artworkCache,
        'markers': markers,
        'timeline': timeline.events,
      },
    );
  }, timeout: const Timeout(Duration(minutes: 5)));
}
