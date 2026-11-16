import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart'
    show databaseFactoryFfi, sqfliteFfiInit;
import 'package:mornye/providers/library_genres_provider.dart';
import 'package:mornye/services/history_database.dart';
import 'package:mornye/services/library_database.dart';
import 'package:mornye/services/library_queue_store.dart';
import 'package:mornye/services/library_row_mapper.dart';
import 'package:mornye/services/sqlite_helpers.dart' as sqlite;

Map<String, dynamic> _download(String id, String? genre, {String? path}) => {
  'id': id,
  'trackName': 'Song $id',
  'artistName': 'Artist',
  'albumName': 'Album $id',
  'filePath': path ?? '/downloads/$id.flac',
  'service': 'example-provider',
  'downloadedAt': DateTime.utc(2026, 11, 1).toIso8601String(),
  'coverUrl': id == 'd2' ? 'https://example.com/rock.jpg' : null,
  'genre': genre,
};

Future<void> _addScanned(
  Database db,
  String id,
  String? genre, {
  String source = 'legacy',
  String? path,
}) async {
  final filePath = path ?? '/music/$id.flac';
  await db.insert(
    'library',
    LibraryRowMapper.encode(
      LocalLibraryItem(
        id: id,
        sourceId: source,
        trackName: 'Song $id',
        artistName: 'Artist',
        albumName: 'Album $id',
        filePath: filePath,
        scannedAt: DateTime.utc(2026, 11, 1),
        genre: genre,
      ).toJson(),
    ),
  );
  final batch = db.batch();
  sqlite.putPathKeysInBatch(batch, 'library_path_keys', id, filePath);
  await batch.commit(noResult: true);
}

/// Downloads and scanned songs whose genres differ in case and spacing,
/// songs without a genre, a multi-value tag, scanned songs in an offline
/// and a disabled folder, and a scanned file a download shadows.
Future<void> _seed() async {
  final library = await LibraryDatabase.instance.database;
  for (final (id, available, enabled) in [
    ('offline', 0, 1),
    ('disabled', 1, 0),
  ]) {
    await library.insert('library_sources', {
      'id': id,
      'path': '/Volumes/$id',
      'display_name': id,
      'available': available,
      'enabled': enabled,
    });
  }
  await HistoryDatabase.instance.upsertBatch([
    _download('d1', 'Rock'),
    _download('d2', 'Rock'),
    _download('d3', ' rock '),
    _download('d4', 'Pop'),
    _download('d5', ''),
    _download('d6', null),
    _download('d7', 'Rock; Pop'),
    _download('d8', 'Jazz', path: '/music/shared.flac'),
  ]);
  await _addScanned(library, 'l1', 'ROCK');
  await _addScanned(library, 'l2', 'Jazz');
  await _addScanned(library, 'l3', 'Jazz', source: 'offline');
  await _addScanned(library, 'l4', 'Folk', source: 'disabled');
  await _addScanned(library, 'l5', 'Pop', path: '/music/shared.flac');
  await _addScanned(library, 'l6', '   ');
}

List<(String, String, int)> _genres(Iterable<Map<String, Object?>> rows) => [
  for (final genre in libraryGenresFromRows(rows))
    (genre.key, genre.name, genre.trackCount),
];

Future<Set<String>> _songIds(String genre, {bool includeLocal = true}) async {
  final page = await LibraryDatabase.instance.getQueueTrackPageResult(
    QueueLibraryDbQuery(
      genre: genre,
      sortMode: 'a-z',
      includeLocal: includeLocal,
      limit: 100,
    ),
  );
  return {for (final row in page.rows) (row['item'] as Map)['id'] as String};
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const paths = MethodChannel('plugins.flutter.io/path_provider');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('library-genres-');
    sqfliteFfiInit();
    final previousFactory = databaseFactoryOrNull;
    databaseFactory = databaseFactoryFfi;
    messenger.setMockMethodCallHandler(paths, (_) async => root.path);
    addTearDown(() async {
      await LibraryDatabase.instance.close();
      await HistoryDatabase.instance.close();
      messenger.setMockMethodCallHandler(paths, null);
      databaseFactory = previousFactory;
      await root.delete(recursive: true);
    });
    await _seed();
  });

  test('genres group both sources case-insensitively under the most common '
      'spelling, leaving out untagged, hidden and shadowed songs', () async {
    final rows = await LibraryDatabase.instance.getGenreSpellings(
      includeLocal: true,
    );
    expect(_genres(rows), [
      ('jazz', 'Jazz', 2),
      ('pop', 'Pop', 1),
      ('rock', 'Rock', 4),
      // No splitting rule: a multi-value tag is a genre of its own.
      ('rock; pop', 'Rock; Pop', 1),
    ]);
    final rock = libraryGenresFromRows(rows)[2];
    expect(rock.cover, 'https://example.com/rock.jpg');

    // The row check selects what the snapshot selects.
    final rowCheck = await LibraryQueueStore(
      await LibraryDatabase.instance.database,
      historyFts: false,
      localFts: false,
    ).genreSpellings(includeLocal: true);
    expect(_genres(rowCheck), _genres(rows));

    expect(
      _genres(
        await LibraryDatabase.instance.getGenreSpellings(includeLocal: false),
      ),
      [
        ('jazz', 'Jazz', 1),
        ('pop', 'Pop', 1),
        ('rock', 'Rock', 3),
        ('rock; pop', 'Rock; Pop', 1),
      ],
    );
  });

  test('a genre lists and counts exactly the songs of that genre', () async {
    expect(await _songIds('Rock'), {'d1', 'd2', 'd3', 'l1'});
    expect(await _songIds(' ROCK'), {'d1', 'd2', 'd3', 'l1'});
    expect(await _songIds('pop'), {'d4'});
    expect(await _songIds('jazz'), {'d8', 'l2'});
    expect(await _songIds('rock; pop'), {'d7'});
    expect(await _songIds('Rock', includeLocal: false), {'d1', 'd2', 'd3'});
    expect(await _songIds('folk'), isEmpty);

    final counts = await LibraryDatabase.instance.getQueueCounts(
      const QueueLibraryDbQuery(genre: 'rock'),
    );
    expect(counts.allTrackCount, 4);
  });
}
