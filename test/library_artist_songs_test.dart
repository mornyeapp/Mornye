import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart'
    show databaseFactoryFfi, sqfliteFfiInit;
import 'package:mornye/providers/library_artist_songs_provider.dart';
import 'package:mornye/providers/library_song_reads.dart';
import 'package:mornye/services/history_database.dart';
import 'package:mornye/services/library_database.dart';
import 'package:mornye/services/library_row_mapper.dart';
import 'package:mornye/services/sqlite_helpers.dart' as sqlite;

Map<String, dynamic> _download(
  String id,
  String artist, {
  String? albumArtist,
}) => {
  'id': id,
  'trackName': 'Song $id',
  'artistName': artist,
  'albumArtist': albumArtist,
  'albumName': 'Album $id',
  'filePath': '/downloads/$id.flac',
  'service': 'example-provider',
  'downloadedAt': DateTime.utc(2026, 11, 1).toIso8601String(),
};

Future<void> _addScanned(
  Database db,
  String id,
  String artist, {
  String? albumArtist,
  String source = 'legacy',
}) async {
  final filePath = '/music/$id.flac';
  await db.insert(
    'library',
    LibraryRowMapper.encode(
      LocalLibraryItem(
        id: id,
        sourceId: source,
        trackName: 'Song $id',
        artistName: artist,
        albumArtist: albumArtist,
        albumName: 'Album $id',
        filePath: filePath,
        scannedAt: DateTime.utc(2026, 11, 1),
      ).toJson(),
    ),
  );
  final batch = db.batch();
  sqlite.putPathKeysInBatch(batch, 'library_path_keys', id, filePath);
  await batch.commit(noResult: true);
}

/// Songs of one artist's own albums, songs that credit the artist beside
/// others, a name that only contains the artist's name, another artist, and
/// a scanned song in a disabled folder.
Future<void> _seed() async {
  final library = await LibraryDatabase.instance.database;
  await library.insert('library_sources', {
    'id': 'disabled',
    'path': '/Volumes/disabled',
    'display_name': 'disabled',
    'available': 1,
    'enabled': 0,
  });
  await HistoryDatabase.instance.upsertBatch([
    _download('d1', 'Ana'),
    _download('d2', 'Ana feat. Ben', albumArtist: 'Ana'),
    _download('d3', 'Cleo & Ana', albumArtist: 'Various Artists'),
    _download('d4', 'Anabel'),
    _download('d5', 'Ben'),
  ]);
  await _addScanned(library, 'l1', 'ANA');
  await _addScanned(library, 'l2', 'Dan', albumArtist: 'Ana');
  await _addScanned(library, 'l3', 'Ana', source: 'disabled');
}

/// The songs the artist's Songs view shows, found as its provider finds
/// them.
Future<Set<String>> _songIds(String artist, {bool includeLocal = true}) async {
  final key = sqlite.normalizeLookupText(artist);
  final songs = await readLibrarySongs(
    includeLocal: includeLocal,
    creditedArtist: artist,
  );
  return {
    for (final song in songs)
      if (libraryItemCreditsArtist(song, key)) song.id,
  };
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const paths = MethodChannel('plugins.flutter.io/path_provider');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('library-artist-songs-');
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

  test('an artist has the songs of their albums and the songs that credit '
      'them, from downloads and scanned folders', () async {
    expect(await _songIds('Ana'), {
      'dl_d1',
      'dl_d2',
      'dl_d3',
      'local_l1',
      'local_l2',
    });
    expect(await _songIds('ana '), await _songIds('Ana'));
    expect(await _songIds('Ben'), {'dl_d2', 'dl_d5'});
    expect(await _songIds('Nobody'), isEmpty);
  });

  test(
    'a name that only contains the artist\'s name is not their song',
    () async {
      final found = await readLibrarySongs(
        includeLocal: true,
        creditedArtist: 'Ana',
      );
      // The database matches the artist tag as text.
      expect([for (final song in found) song.id], contains('dl_d4'));
      expect(await _songIds('Ana'), isNot(contains('dl_d4')));
    },
  );

  test('scanned songs stay out while the scanned Library is off', () async {
    expect(await _songIds('Ana', includeLocal: false), {
      'dl_d1',
      'dl_d2',
      'dl_d3',
    });
  });
}
