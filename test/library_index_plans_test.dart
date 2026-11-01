import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart';
// The logger ships in sqflite_common, which sqflite and sqflite_common_ffi
// re-export without it.
// ignore: depend_on_referenced_packages
import 'package:sqflite_common/sqflite_logger.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart'
    show databaseFactoryFfi, sqfliteFfiInit;
import 'package:mornye/services/history_database.dart';
import 'package:mornye/services/history_schema.dart';
import 'package:mornye/services/library_database.dart';
import 'package:mornye/services/library_queue_store.dart';
import 'package:mornye/services/library_row_mapper.dart';
import 'package:mornye/services/library_search.dart';
import 'package:mornye/services/sqlite_helpers.dart' as sqlite;

/// The indexes v21 and v16 dropped, as v20 and v15 created them.
const _droppedLibraryIndexes = {
  'idx_library_track_artist': 'library(track_name, artist_name)',
  'idx_library_album': 'library(album_name, album_artist)',
  'idx_library_track_norm': 'library(track_name_norm)',
  'idx_library_artist_norm': 'library(artist_name_norm)',
  'idx_library_album_norm': 'library(album_name_norm)',
  'idx_library_scanned_at': 'library(scanned_at)',
};
const _droppedHistoryIndexes = {
  'idx_downloaded_at': 'history(downloaded_at DESC)',
  'idx_album': 'history(album_name, album_artist)',
  'idx_history_track_artist': 'history(track_name, artist_name)',
};

/// NativeHistoryStore.kt statements on its own connection.
const _nativeHistoryStatements = [
  'SELECT id FROM history WHERE (spotify_id = ? OR spotify_id_norm = ?) '
      'AND id <> ?',
  'SELECT id FROM history WHERE (isrc = ? OR isrc_norm = ?) AND id <> ?',
  'SELECT id FROM history WHERE match_key = ? AND id <> ?',
  'DELETE FROM history_path_keys WHERE item_id IN (?, ?)',
  'DELETE FROM history WHERE id IN (?, ?)',
  'DELETE FROM history_path_keys WHERE item_id = ?',
  'SELECT id, spotify_id, isrc, track_name, artist_name, album_name, '
      'album_artist, genre, release_date, downloaded_at FROM history '
      'WHERE spotify_id_norm IS NULL OR isrc_norm IS NULL '
      'OR match_key IS NULL OR album_key IS NULL OR search_text IS NULL '
      'OR sort_track IS NULL OR sort_release IS NULL OR sort_added IS NULL',
  'SELECT id, file_path FROM history',
  'UPDATE history SET sort_track = ? WHERE id = ?',
];

Map<String, dynamic> _scanned(String id, int album, int number) =>
    LocalLibraryItem(
      id: id,
      sourceId: album.isEven ? 'music' : LocalLibraryItem.legacySourceId,
      trackName: 'Song $number',
      artistName: 'Artist ${album % 3}',
      albumName: 'Album $album',
      albumArtist: 'Artist ${album % 3}',
      filePath: '/Users/me/Music/A$album/$number.flac',
      coverPath: '/Users/me/Covers/$album.jpg',
      scannedAt: DateTime.utc(2026, 9, album + 1, number),
      fileModTime: album * 100 + number,
      isrc: 'USAAA26${'$album$number'.padLeft(5, '0')}',
      trackNumber: number,
      totalTracks: 3,
      discNumber: 1,
      totalDiscs: 1,
      bitDepth: number.isEven ? 24 : 16,
      genre: 'Pop',
      releaseDate: '${2000 + album}',
    ).toJson();

Map<String, dynamic> _download(String id, int album, int number) => {
  'id': id,
  'trackName': 'Song $number',
  'artistName': 'Artist ${album % 3}',
  'albumName': 'Album $album',
  'albumArtist': 'Artist ${album % 3}',
  'filePath': album.isEven
      ? '/Users/me/Music/A$album/$number.flac'
      : '/Users/me/Downloads/D$album/$number.flac',
  'service': 'example-provider',
  'downloadedAt': DateTime.utc(2026, 8, album + 1, number).toIso8601String(),
  'isrc': 'USBBB26${'$album$number'.padLeft(5, '0')}',
  'spotifyId': 'track$album$number',
  'trackNumber': number,
  'totalTracks': 3,
  'discNumber': 1,
  'totalDiscs': 1,
  'quality': '24-bit',
  'bitDepth': 24,
  'genre': 'Rock',
  'releaseDate': '${2010 + album}',
};

Future<void> _seed() async {
  final library = await LibraryDatabase.instance.database;
  await library.insert('library_sources', {
    'id': 'music',
    'path': '/Users/me/Music',
    'display_name': 'Music',
  });
  for (var album = 0; album < 6; album++) {
    for (var number = 1; number <= 3; number++) {
      final json = _scanned('l-$album-$number', album, number);
      await library.insert('library', LibraryRowMapper.encode(json));
      final batch = library.batch();
      sqlite.putPathKeysInBatch(
        batch,
        'library_path_keys',
        json['id'] as String,
        json['filePath'] as String,
      );
      await batch.commit(noResult: true);
    }
  }
  await HistoryDatabase.instance.upsertBatch([
    for (var album = 0; album < 4; album++)
      for (var number = 1; number <= 2; number++)
        _download('h-$album-$number', album, number),
  ]);
}

/// Exercises Library and History APIs, including queue and search builders
/// across their sorts and filters.
Future<void> _exercise() async {
  final library = LibraryDatabase.instance;
  final history = HistoryDatabase.instance;
  for (final sort in [
    'latest',
    'oldest',
    'a-z',
    'z-a',
    'artist-asc',
    'artist-desc',
    'album-asc',
    'album-desc',
    'release-oldest',
    'release-newest',
    'genre-asc',
    'genre-desc',
    'size-asc',
    'size-desc',
  ]) {
    for (final request in [
      QueueLibraryDbQuery(sortMode: sort, limit: 5),
      QueueLibraryDbQuery(sortMode: sort, limit: 5, offset: 5),
      QueueLibraryDbQuery(sortMode: sort, source: 'local', limit: 5),
      QueueLibraryDbQuery(sortMode: sort, includeLocal: false, limit: 5),
      QueueLibraryDbQuery(sortMode: sort, albumArtist: 'Artist 1'),
      QueueLibraryDbQuery(sortMode: sort, searchQuery: 'song'),
      QueueLibraryDbQuery(sortMode: sort, filterMode: 'singles'),
      QueueLibraryDbQuery(sortMode: sort, quality: 'hires', format: 'flac'),
      QueueLibraryDbQuery(sortMode: sort, metadata: 'missing-genre'),
      QueueLibraryDbQuery(sortMode: sort, metadata: 'incomplete-album'),
      QueueLibraryDbQuery(
        sortMode: sort,
        includeSingleTrackAlbums: true,
        albumArtist: 'Artist 2',
        searchQuery: 'album',
      ),
    ]) {
      final tracks = await library.getQueueTrackPageResult(request);
      final albums = await library.getQueueAlbumPageResult(request);
      await library.getQueueCounts(request);
      await library.getQueueArtistPage(request);
      for (final (page, read) in [
        (tracks, library.getQueueTrackPageResult),
        (albums, library.getQueueAlbumPageResult),
      ]) {
        final cursor = page.nextCursor;
        if (cursor == null) continue;
        await read(
          QueueLibraryDbQuery(
            sortMode: request.sortMode,
            source: request.source,
            includeLocal: request.includeLocal,
            albumArtist: request.albumArtist,
            searchQuery: request.searchQuery,
            filterMode: request.filterMode,
            quality: request.quality,
            format: request.format,
            metadata: request.metadata,
            includeSingleTrackAlbums: request.includeSingleTrackAlbums,
            limit: request.limit,
            cursor: cursor,
          ),
        );
      }
    }
  }
  for (final kind in LibrarySearchKind.values) {
    for (final query in ['song', 'artist 1', 'al']) {
      await library.searchLibrary(query: query, kind: kind, includeLocal: true);
    }
  }
  await library.getDirectoryEntries(includeLocal: true);
  await library.getSongFiles();
  for (final source in ['downloaded', 'local']) {
    await library.getMixSongPage(source: source, afterId: 'h-1-1', limit: 5);
  }
  await library.getSources();
  await library.getSourceByPath('/Users/me/Music');
  await library.getQueueLocalAlbumTracks('Album 1', 'Artist 1');
  await library.getQueueLocalAlbumTracksByKey('album 1|artist 1');
  await library.getFilePathRows();
  await library.getByIds(['l-1-1', 'l-2-2']);
  await library.getById('l-1-1');
  await library.getByIsrc('USAAA2600011');
  await library.findByTrackAndArtist('Song 1', 'Artist 1');
  await library.findFirstByTrackAndArtist('Song 1', 'Artist 1');
  await library.findExisting(
    isrc: 'none',
    trackName: 'Song 2',
    artistName: 'Artist 2',
  );
  await library.findExistingBatch(const [
    LocalLibraryBatchLookupRequest(
      id: 'l-1-1',
      isrc: 'USAAA2600011',
      trackName: 'Song 1',
      artistName: 'Artist 1',
    ),
    LocalLibraryBatchLookupRequest(trackName: 'Song 3', artistName: 'X'),
  ]);
  await library.getLookupIndex();
  await library.findIsrcDuplicateGroups();
  await library.getPhysicalFileIds(['/Users/me/Music/A1/1.flac']);
  await library.getCount();
  await library.getSourceCount('music');
  await library.getFileModTimes();
  await library.getFileModTimes(sourceId: 'music');
  await library.readNetworkScanRows('music', [
    '/Users/me/Music/A2/1.flac',
    '/Users/me/Music/A2/2.flac',
  ]);
  await library.updateAudioMetadata('l-3-1', duration: 200, hasLyrics: true);
  await library.updateFileModTimes({'/Users/me/Music/A3/1.flac': 1});
  await library.upsertBatchExcludingHistory([
    _scanned('l-9-1', 9, 1),
  ], sourceId: LocalLibraryItem.legacySourceId);
  await library.deleteByPath('/Users/me/Music/A5/3.flac');
  await library.deleteByPaths(['/Users/me/Music/A5/2.flac']);
  await library.deleteByIds(['l-5-1']);
  await library.updateSourceState('music', available: false);
  await library.updateSourceState('music', available: true);

  await history.getAll(limit: 3, offset: 1);
  await history.getAlbumTracks('Album 1', 'Artist 1');
  await history.findByTrackAndArtist('Song 1', 'Artist 1');
  await history.getById('h-1-1');
  await history.getByIds(['h-1-1', 'h-2-1']);
  await history.findByFilePath('/Users/me/Downloads/D1/1.flac');
  await history.getPhysicalFileIds(['/Users/me/Downloads/D1/1.flac']);
  await history.getBySpotifyId('track11');
  await history.getByIsrc('USBBB2600011');
  await history.findExistingTrack(
    const HistoryLookupRequest(
      spotifyId: 'track21',
      isrc: 'USBBB2600021',
      trackName: 'Song 1',
      artistName: 'Artist 2',
    ),
  );
  await history.findExistingTracks(const [
    HistoryLookupRequest(
      spotifyId: 'none',
      trackName: 'Song 2',
      artistName: 'Artist 1',
    ),
  ]);
  await history.getCount();
  await history.getEntriesWithPathsPage(limit: 3, offset: 1);
  await history.updateFilePath(
    'h-1-2',
    '/Users/me/Downloads/D1/moved.flac',
    expectedFilePath: '/Users/me/Downloads/D1/2.flac',
  );
  await history.upsert(_download('h-9-1', 9, 1));
  await history.updateExistingBatch([_download('h-9-1', 9, 1)]);
  await history.deleteInspectedEntries([
    {
      'id': 'h-9-1',
      'file_path': '/Users/me/Downloads/D9/1.flac',
      'downloaded_at': DateTime.utc(2026, 8, 10, 1).toIso8601String(),
    },
  ]);
  await history.deleteByIds(['h-3-2']);
  await library.removeSource('music');
}

/// The plan of each statement, by the connection it ran on.
Future<Map<String, String>> _plans(
  Map<Database, Map<String, List<Object?>>> statements,
) async {
  final plans = <String, String>{};
  for (final MapEntry(key: db, value: sqls) in statements.entries) {
    for (final MapEntry(key: sql, value: args) in sqls.entries) {
      final rows = await db.rawQuery('EXPLAIN QUERY PLAN $sql', args);
      plans['${db.path}\n$sql'] = rows
          .map((row) => row['detail'] as String)
          .join('\n');
    }
  }
  return plans;
}

bool _isPlanned(String sql) {
  final head = sql.trimLeft().toUpperCase();
  return [
    'SELECT',
    'WITH',
    'UPDATE',
    'DELETE',
    'INSERT',
    'REPLACE',
  ].any(head.startsWith);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const paths = MethodChannel('plugins.flutter.io/path_provider');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory root;
  final statements = <Database, Map<String, List<Object?>>>{};
  var recording = false;

  void record(Database db, String sql, Object? args) {
    if (recording && _isPlanned(sql)) {
      statements
          .putIfAbsent(db, () => {})
          .putIfAbsent(sql, () => [...?(args as List?)]);
    }
  }

  setUp(() async {
    root = await Directory.systemTemp.createTemp('library-index-plans-');
    sqfliteFfiInit();
    final previousFactory = databaseFactoryOrNull;
    // ignore: experimental_member_use
    databaseFactory = SqfliteDatabaseFactoryLogger(
      databaseFactoryFfi,
      options: SqfliteLoggerOptions(
        type: SqfliteDatabaseFactoryLoggerType.all,
        log: (event) {
          if (event is SqfliteLoggerSqlEvent) {
            record(event.client.database, event.sql, event.arguments);
          } else if (event is SqfliteLoggerBatchEvent) {
            for (final operation in event.operations) {
              record(event.client.database, operation.sql, operation.arguments);
            }
          }
        },
      ),
    );
    messenger.setMockMethodCallHandler(paths, (_) async => root.path);
    addTearDown(() async {
      recording = false;
      statements.clear();
      await LibraryDatabase.instance.close();
      await HistoryDatabase.instance.close();
      messenger.setMockMethodCallHandler(paths, null);
      databaseFactory = previousFactory;
      await root.delete(recursive: true);
    });
  });

  test('remaining indexes preserve seeks and avoid additional sorts', () async {
    await _seed();
    recording = true;
    await _exercise();
    recording = false;
    final library = await LibraryDatabase.instance.database;
    final history = await HistoryDatabase.instance.database;
    statements.putIfAbsent(history, () => {}).addAll({
      for (final sql in _nativeHistoryStatements)
        sql: List.filled('?'.allMatches(sql).length, null),
    });
    // Statements on dropped TEMP tables and detached private files cannot be
    // planned afterwards; they write staging copies, not the live tables.
    final transient = <String>{};
    for (final MapEntry(key: db, value: sqls) in statements.entries) {
      for (final MapEntry<String, List<Object?>>(key: sql, value: args)
          in sqls.entries.toList()) {
        if (transient.any((table) => sql.contains(table))) {
          sqls.remove(sql);
          continue;
        }
        try {
          await db.rawQuery('EXPLAIN QUERY PLAN $sql', args);
        } on DatabaseException catch (error) {
          final table = RegExp(
            r'no such table: ([\w.]+)',
          ).firstMatch('$error')?.group(1);
          expect(table, isNotNull, reason: '$error');
          transient.add(table!);
          sqls.remove(sql);
        }
      }
    }
    expect(
      transient,
      everyElement(
        matches(r'_stage$|_staging$|^native_|^cover_snapshot_|\.library$'),
      ),
    );
    expect(
      statements[library]!.length + statements[history]!.length,
      greaterThan(250),
    );

    final current = await _plans(statements);
    for (final (db, indexes) in [
      (library, _droppedLibraryIndexes),
      (history, _droppedHistoryIndexes),
    ]) {
      for (final MapEntry(:key, :value) in indexes.entries) {
        await db.execute('CREATE INDEX $key ON $value');
      }
    }
    final withDropped = await _plans(statements);
    final dropped = [
      ..._droppedLibraryIndexes.keys,
      ..._droppedHistoryIndexes.keys,
    ];
    for (final MapEntry(:key, :value) in withDropped.entries) {
      String seek(String detail) => detail.replaceFirst(
        RegExp(r'USING (?:COVERING )?INDEX \w+'),
        'USING INDEX',
      );
      final currentSeeks = current[key]!.split('\n').map(seek).toSet();
      for (final detail
          in value
              .split('\n')
              .where(
                (detail) =>
                    detail.startsWith('SEARCH ') &&
                    dropped.any((index) => detail.contains('INDEX $index ')),
              )) {
        expect(currentSeeks, contains(seek(detail)), reason: '$key\n$detail');
      }
      int sorts(String plan) => 'USE TEMP B-TREE'.allMatches(plan).length;
      expect(
        sorts(current[key]!),
        lessThanOrEqualTo(sorts(value)),
        reason: key,
      );
    }
  });

  test(
    'an album artist page seeks its albums instead of scanning the Library',
    () async {
      await _seed();
      final library = await LibraryDatabase.instance.database;
      // Attaches History and creates the shadow snapshot table.
      await LibraryDatabase.instance.getQueueCounts(
        const QueueLibraryDbQuery(),
      );
      for (final snapshot in [false, true]) {
        for (final request in const [
          QueueLibraryDbQuery(albumArtist: 'Artist 1'),
          QueueLibraryDbQuery(
            albumArtist: 'Artist 1',
            includeSingleTrackAlbums: true,
            sortMode: 'album-asc',
          ),
        ]) {
          final recorder = _RecordingDatabase();
          await LibraryQueueStore(
            recorder,
            historyFts: HistoryDatabase.instance.searchFtsAvailable,
            localFts: LibraryDatabase.instance.searchFtsAvailable,
            shadowSnapshot: snapshot,
          ).albumPage(request);
          final (sql, args) = recorder.queries.single;
          final plan = (await library.rawQuery(
            'EXPLAIN QUERY PLAN $sql',
            args,
          )).map((row) => row['detail'] as String).toList();
          expect(
            plan.where(
              (detail) => RegExp(
                r'^SCAN (l|h|candidate|library|history|history_db\.history)\b',
              ).hasMatch(detail),
            ),
            isEmpty,
            reason: plan.join('\n'),
          );
          expect(
            plan,
            containsAll([
              contains('USING INDEX idx_library_album_artist_norm'),
              contains('USING INDEX idx_history_sort_album_artist'),
            ]),
            reason: plan.join('\n'),
          );
        }
      }
    },
  );

  test('the dropped History indexes match the native writer', () {
    final native = File(
      'android/app/src/main/kotlin/com/zarz/mornye/NativeHistoryStore.kt',
    ).readAsStringSync();
    final list = RegExp(
      r'unusedHistoryIndexes = listOf\(([^)]*)\)',
    ).firstMatch(native);
    expect(list, isNotNull);
    expect(
      RegExp(r'"(\w+)"').allMatches(list!.group(1)!).map((m) => m.group(1)),
      HistorySchema.unusedIndexes,
    );
    expect(HistorySchema.unusedIndexes, _droppedHistoryIndexes.keys);
  });
}

class _RecordingDatabase implements Database {
  final queries = <(String, List<Object?>)>[];

  @override
  Future<List<Map<String, Object?>>> rawQuery(
    String query, [
    List<Object?>? arguments,
  ]) async {
    queries.add((query, [...?arguments]));
    return const [];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
