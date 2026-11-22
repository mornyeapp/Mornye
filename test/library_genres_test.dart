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
import 'package:mornye/utils/genre_tags.dart';

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

/// The songs of a genre, found as the Genres page finds them: through the
/// tags that list it.
Future<Set<String>> _songIds(String genre, {bool includeLocal = true}) async {
  final tags = libraryGenreTagsFromRows(
    await LibraryDatabase.instance.getGenreSpellings(
      includeLocal: includeLocal,
    ),
  );
  final page = await LibraryDatabase.instance.getQueueTrackPageResult(
    QueueLibraryDbQuery(
      genreTags: tags[genre] ?? const [],
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
    // "Rock; Pop" counts under both of its genres.
    expect(_genres(rows), [
      ('jazz', 'Jazz', 2),
      ('pop', 'Pop', 2),
      ('rock', 'Rock', 5),
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
      [('jazz', 'Jazz', 1), ('pop', 'Pop', 2), ('rock', 'Rock', 4)],
    );
  });

  test('songs named by title and artist give their genre tag', () async {
    String key(String id) => LibraryDatabase.matchKeyFor('Song $id', 'Artist');
    Future<Map<String, String>> tags({required bool includeLocal}) async => {
      for (final row in await LibraryDatabase.instance.getGenresOfSongs([
        for (final id in ['d1', 'd5', 'd7', 'l2', 'l4', 'unknown']) key(id),
      ], includeLocal: includeLocal))
        row['match_key']! as String: row['genre_name']! as String,
    };

    // Untagged songs, a song in a disabled folder and a song the Library
    // does not have give nothing.
    expect(await tags(includeLocal: true), {
      key('d1'): 'Rock',
      key('d7'): 'Rock; Pop',
      key('l2'): 'Jazz',
    });
    expect(await tags(includeLocal: false), {
      key('d1'): 'Rock',
      key('d7'): 'Rock; Pop',
    });

    // More songs than one query takes.
    final many = await LibraryDatabase.instance.getGenresOfSongs([
      for (var i = 0; i < 900; i++) LibraryDatabase.matchKeyFor('x$i', 'y'),
      key('l2'),
    ], includeLocal: true);
    expect([for (final row in many) row['genre_name']], ['Jazz']);
  });

  test('songs named by title and artist give their file details', () async {
    String key(String id) => LibraryDatabase.matchKeyFor('Song $id', 'Artist');
    Future<Set<Object?>> keys({required bool includeLocal}) async => {
      for (final row in await LibraryDatabase.instance.getDetailsOfSongs([
        for (final id in ['d1', 'd5', 'l2', 'unknown']) key(id),
      ], includeLocal: includeLocal))
        row['match_key'],
    };

    // Untagged songs are listed too; scanned ones only with local songs.
    expect(await keys(includeLocal: true), {key('d1'), key('d5'), key('l2')});
    expect(await keys(includeLocal: false), {key('d1'), key('d5')});
    final row = (await LibraryDatabase.instance.getDetailsOfSongs([
      key('l2'),
    ], includeLocal: true)).single;
    expect(
      row.keys,
      containsAll(['release_date', 'format', 'bit_depth', 'sample_rate']),
    );
  });

  test('a genre lists and counts exactly the songs of that genre', () async {
    expect(await _songIds('rock'), {'d1', 'd2', 'd3', 'd7', 'l1'});
    expect(await _songIds('pop'), {'d4', 'd7'});
    expect(await _songIds('jazz'), {'d8', 'l2'});
    expect(await _songIds('rock; pop'), isEmpty);
    expect(await _songIds('rock', includeLocal: false), {
      'd1',
      'd2',
      'd3',
      'd7',
    });
    expect(await _songIds('folk'), isEmpty);

    final counts = await LibraryDatabase.instance.getQueueCounts(
      const QueueLibraryDbQuery(genreTags: ['rock', 'rock; pop']),
    );
    expect(counts.allTrackCount, 5);
  });

  test('a tag lists genres with semicolons, commas, NUL and the user\'s '
      'separator, and keeps slashes and ampersands', () {
    expect(splitGenreTag(' Rock; Pop ,  Jazz\u0000Blues '), [
      'Rock',
      'Pop',
      'Jazz',
      'Blues',
    ]);
    expect(splitGenreTag('Hip-Hop/Rap; R&B'), ['Hip-Hop/Rap', 'R&B']);
    expect(splitGenreTag('Rock; rock;; ROCK'), ['Rock']);
    expect(splitGenreTag('Rock / Pop', separator: ' / '), ['Rock', 'Pop']);
    expect(splitGenreTag('Rock / Pop'), ['Rock / Pop']);
    expect(splitGenreTag(null), isEmpty);
    expect(splitGenreTag(' ; '), isEmpty);
  });

  test('a genre takes its most common spelling across tags', () {
    final genres = libraryGenresFromRows([
      {'genre_key': 'rock', 'genre_name': 'rock', 'track_count': 2},
      {'genre_key': 'rock; pop', 'genre_name': 'Rock; Pop', 'track_count': 3},
      {'genre_key': 'pop / soul', 'genre_name': 'Pop / Soul', 'track_count': 1},
    ], separator: ' / ');
    expect(
      [for (final genre in genres) (genre.key, genre.name, genre.trackCount)],
      [('pop', 'Pop', 4), ('rock', 'Rock', 5), ('soul', 'Soul', 1)],
    );
    expect(
      libraryGenreTagsFromRows([
        {'genre_key': 'rock', 'genre_name': 'rock'},
        {'genre_key': 'rock; pop', 'genre_name': 'Rock; Pop'},
      ]),
      {
        'rock': ['rock', 'rock; pop'],
        'pop': ['rock; pop'],
      },
    );
  });
}
