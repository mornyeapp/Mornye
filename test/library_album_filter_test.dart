import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart'
    show databaseFactoryFfi, sqfliteFfiInit;
import 'package:mornye/services/history_database.dart';
import 'package:mornye/services/library_database.dart';
import 'package:mornye/services/library_queue_store.dart';
import 'package:mornye/services/library_row_mapper.dart';
import 'package:mornye/services/sqlite_helpers.dart' as sqlite;

const _artists = ['Aurora Lane', 'Night Shift', 'Paper Moons'];
const _formats = ['flac', 'm4a', 'mp3'];

Future<void> _addScanned(
  Database db,
  String id,
  String path, {
  required String album,
  required String artist,
  required int number,
  required String source,
  required int day,
}) async {
  final json = LocalLibraryItem(
    id: id,
    sourceId: source,
    trackName: number.isEven ? 'Night Song $number' : 'Day Song $number',
    artistName: artist,
    albumName: album,
    albumArtist: artist,
    filePath: path,
    coverPath: number == 2 ? '/Users/me/Covers/$day.jpg' : null,
    scannedAt: DateTime.utc(2026, 9, day, number),
    fileModTime: day * 100 + number,
    isrc: number == 3 ? 'BAD' : 'USAAA26${'$day$number'.padLeft(5, '0')}',
    trackNumber: number,
    totalTracks: day % 3 == 0 ? null : 4,
    discNumber: 1,
    totalDiscs: 1,
    bitDepth: switch ((day + number) % 3) {
      0 => 24,
      1 => 16,
      _ => null,
    },
    genre: day.isEven || number == 1 ? 'Pop' : null,
    label: day % 3 == 1 ? null : 'Label',
    releaseDate: '${2000 + day}',
    format: _formats[(day + number) % 3],
  ).toJson();
  await db.insert('library', LibraryRowMapper.encode(json));
  final batch = db.batch();
  sqlite.putPathKeysInBatch(batch, 'library_path_keys', id, path);
  await batch.commit(noResult: true);
}

Map<String, dynamic> _download(
  String id,
  String path, {
  required String album,
  required String artist,
  required int number,
  required int day,
}) => {
  'id': id,
  'trackName': number.isEven ? 'Night Track $number' : 'Track $number',
  'artistName': artist,
  'albumName': album,
  'albumArtist': day % 4 == 0 ? null : artist,
  'coverUrl': 'https://covers.example/$day.jpg',
  'filePath': path,
  'service': 'example-provider',
  'downloadedAt': DateTime.utc(2026, 8, day, number).toIso8601String(),
  'isrc': number == 2 ? 'DL$day' : 'USBBB26${'$day$number'.padLeft(5, '0')}',
  'trackNumber': number,
  'totalTracks': 3,
  'discNumber': 1,
  'totalDiscs': 1,
  'quality': switch (number) {
    1 => '24-bit/96kHz',
    2 => '16-bit/44.1kHz',
    _ => '320 kbps',
  },
  'bitDepth': switch (number) {
    1 => 24,
    2 => 16,
    _ => null,
  },
  'genre': day.isOdd || number == 1 ? 'Rock' : null,
  'label': day.isEven ? 'Label' : null,
  'releaseDate': '${2010 + day}',
  'format': _formats[(day + number + 1) % 3],
};

/// Albums of one to four songs by three album artists in every source
/// state; some scanned songs are also downloads, which hides them.
Future<void> _seed() async {
  final library = await LibraryDatabase.instance.database;
  for (final (id, available, enabled) in [
    ('music', 1, 1),
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
  const sources = ['legacy', 'music', 'music', 'offline', 'disabled'];
  final downloads = <Map<String, dynamic>>[];
  for (var day = 1; day <= 18; day++) {
    final artist = _artists[day % 3];
    final album = 'Album $day';
    for (var number = 1; number <= day % 4 + 1; number++) {
      final path =
          '/Users/me/Music/A$day/$number.${_formats[(day + number) % 3]}';
      await _addScanned(
        library,
        'l-$day-$number',
        path,
        album: album,
        artist: artist,
        number: number,
        source: sources[(day + number) % sources.length],
        day: day,
      );
      if (day % 5 == 0 && number == 1) {
        downloads.add(
          _download(
            'h-shadow-$day',
            path,
            album: album,
            artist: artist,
            number: number,
            day: day,
          ),
        );
      }
    }
  }
  for (var day = 1; day <= 12; day++) {
    for (var number = 1; number <= day % 3 + 1; number++) {
      downloads.add(
        _download(
          'h-$day-$number',
          '/Users/me/Downloads/D$day/$number.${_formats[(day + number + 1) % 3]}',
          album: 'Download $day',
          artist: _artists[(day + 1) % 3],
          number: number,
          day: day,
        ),
      );
    }
  }
  await HistoryDatabase.instance.upsertBatch(downloads);
}

final _filters = <String, QueueLibraryDbQuery Function(String, bool)>{
  'unfiltered': (sort, singles) =>
      QueueLibraryDbQuery(sortMode: sort, includeSingleTrackAlbums: singles),
  for (final artist in [..._artists, ' NIGHT Shift '])
    'artist $artist': (sort, singles) => QueueLibraryDbQuery(
      sortMode: sort,
      includeSingleTrackAlbums: singles,
      albumArtist: artist,
    ),
  'search night': (sort, singles) => QueueLibraryDbQuery(
    sortMode: sort,
    includeSingleTrackAlbums: singles,
    searchQuery: 'night',
  ),
  'search moons': (sort, singles) => QueueLibraryDbQuery(
    sortMode: sort,
    includeSingleTrackAlbums: singles,
    searchQuery: 'paper moons',
  ),
  for (final quality in ['hires', 'cd', 'lossy'])
    'quality $quality': (sort, singles) => QueueLibraryDbQuery(
      sortMode: sort,
      includeSingleTrackAlbums: singles,
      quality: quality,
    ),
  for (final format in ['flac', 'm4a'])
    'format $format': (sort, singles) => QueueLibraryDbQuery(
      sortMode: sort,
      includeSingleTrackAlbums: singles,
      format: format,
    ),
  for (final metadata in [
    'missing-genre',
    'complete',
    'incorrect-isrc-format',
    'incomplete-album',
    'unknown-album-completeness',
  ])
    'metadata $metadata': (sort, singles) => QueueLibraryDbQuery(
      sortMode: sort,
      includeSingleTrackAlbums: singles,
      metadata: metadata,
    ),
  'artist and search': (sort, singles) => QueueLibraryDbQuery(
    sortMode: sort,
    includeSingleTrackAlbums: singles,
    albumArtist: 'Night Shift',
    searchQuery: 'song',
  ),
  'artist and completeness': (sort, singles) => QueueLibraryDbQuery(
    sortMode: sort,
    includeSingleTrackAlbums: singles,
    albumArtist: 'Aurora Lane',
    metadata: 'incomplete-album',
  ),
};

QueueLibraryDbQuery _scoped(
  QueueLibraryDbQuery request, {
  String? source,
  bool includeLocal = true,
  int limit = 4,
  int offset = 0,
  QueueLibraryDbCursor? cursor,
}) => QueueLibraryDbQuery(
  includeSingleTrackAlbums: request.includeSingleTrackAlbums,
  albumArtist: request.albumArtist,
  searchQuery: request.searchQuery,
  quality: request.quality,
  format: request.format,
  metadata: request.metadata,
  sortMode: request.sortMode,
  source: source,
  includeLocal: includeLocal,
  limit: limit,
  offset: offset,
  cursor: cursor,
);

/// Every album page of [request]: cursor pages of four, then one offset
/// page.
Future<List<Object?>> _pages(
  LibraryQueueStore store,
  QueueLibraryDbQuery request,
) async {
  final pages = <Object?>[];
  QueueLibraryDbCursor? cursor;
  for (var page = 0; page < 20; page++) {
    final result = await store.albumPage(
      _scoped(
        request,
        source: request.source,
        includeLocal: request.includeLocal,
        cursor: cursor,
      ),
    );
    pages.add(result.rows);
    cursor = result.nextCursor;
    if (result.rows.length < 4 || cursor == null) break;
  }
  pages.add(
    (await store.albumPage(
      _scoped(
        request,
        source: request.source,
        includeLocal: request.includeLocal,
        offset: 4,
      ),
    )).rows,
  );
  return pages;
}

/// SHA-256 of every album page per filter, captured from the album page SQL
/// of 0331d5ec, which aggregated every album for a filtered page.
const _expectedDigests = <String, String>{
  'unfiltered':
      '5d3ad153fdab48e2a0154acb7d72345552e46328c1350d7f8a93ffdee913b5e4',
  'artist Aurora Lane':
      'e73120420037546d2e851f564ca0078696ecdcaccbf67552d9564822e52e53bc',
  'artist Night Shift':
      '8e6b924208a3f56ff212ec2cc7a3a80c50a8a5b76fbe73e46a7b155c23f0b4e6',
  'artist Paper Moons':
      '8da8a9c0d1a980b07d2aac0f396081357765a27a3740a8bfb801465c9083b310',
  'artist  NIGHT Shift ':
      '8e6b924208a3f56ff212ec2cc7a3a80c50a8a5b76fbe73e46a7b155c23f0b4e6',
  'search night':
      'ba16ecf5dbdb4193d7079eb2e08ccff1f5b825bc1bbcc3e5f3f06991b39ba724',
  'search moons':
      '8da8a9c0d1a980b07d2aac0f396081357765a27a3740a8bfb801465c9083b310',
  'quality hires':
      '775b6f7f3fa283575b8d2bd8225472405407a2f2663eadd47a7a0c4bec76a182',
  'quality cd':
      '506f7a2e0e91b7affba6f0ac2ca1455fa7199c2f6eb7f06a98c32193967a4ec6',
  'quality lossy':
      '8287855418a2632208b471d263b49ccd3690a5bd1d2076b4c27f982b8a1b32ef',
  'format flac':
      '156e674f4a93cf5204c8b495e30433c45d806d59fbfb7f585e8e998636721b6c',
  'format m4a':
      'd5f7fe651bc878e027edc2fb3d59bf93a76e5267d0a6278cb6d08410e8b55ce1',
  'metadata missing-genre':
      'c3e9bc564e69b869bda8ca107b65f62e430609713179d44715995cca12febb9c',
  'metadata complete':
      '1376ca7f6d4e4cf950634feadf805b56c872848e9206153806bfb2618bb0eb25',
  'metadata incorrect-isrc-format':
      'd4520fb9562b3a6b1bfd307bdabf3273266a04baa475d7aed586ca3cbf35c8c7',
  'metadata incomplete-album':
      'a4c24e8349b7aa6363c11465423d0a6694243c102f40fd22fde8b99bd3259bff',
  'metadata unknown-album-completeness':
      'b2065ca9d3d727e9aca8fd1348db214bc115a5a9c1141cea79f70a8fa15b9b7e',
  'artist and search':
      '6dddb60797543b4d5b79f0a39dcbb49bcf95c1eb152c9e5f0ff80de776fefded',
  'artist and completeness':
      'fdb1eddecb5b55aaedaa735be82fa617b33ec36bc2d8c879739a73b4bf278de6',
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const paths = MethodChannel('plugins.flutter.io/path_provider');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('library-album-filter-');
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
  });

  test(
    'filtered album pages keep their rows, counts, sort keys and order',
    () async {
      await _seed();
      final db = await LibraryDatabase.instance.database;
      // Creates the size tables the size sort joins and attaches History.
      await LibraryDatabase.instance.getQueueAlbumPageResult(
        const QueueLibraryDbQuery(sortMode: 'size-desc'),
      );
      final snapshot = sqlite.LibraryShadowSnapshot();
      final actual = <String, String>{};
      for (final MapEntry(key: name, value: build) in _filters.entries) {
        final results = <Object?>[];
        for (final fts in [false, true]) {
          LibraryQueueStore store({bool shadow = false}) => LibraryQueueStore(
            db,
            historyFts: fts && HistoryDatabase.instance.searchFtsAvailable,
            localFts: fts && LibraryDatabase.instance.searchFtsAvailable,
            shadowSnapshot: shadow,
          );
          for (final sort in [
            'latest',
            'album-asc',
            'artist-desc',
            'release-newest',
            'size-desc',
          ]) {
            for (final singles in [false, true]) {
              for (final (source, includeLocal) in [
                (null, true),
                ('downloaded', true),
                ('local', true),
                (null, false),
              ]) {
                final request = _scoped(
                  build(sort, singles),
                  source: source,
                  includeLocal: includeLocal,
                );
                final rowCheck = await _pages(store(), request);
                final viaSnapshot = await snapshot.read(
                  db,
                  (shadow) => _pages(store(shadow: shadow), request),
                );
                expect(
                  viaSnapshot,
                  rowCheck,
                  reason: '$name $sort $singles $source $includeLocal',
                );
                results.add(rowCheck);
              }
            }
          }
        }
        actual[name] = sha256
            .convert(utf8.encode(jsonEncode(results)))
            .toString();
      }
      final mismatches = [
        for (final MapEntry(:key, :value) in actual.entries)
          if (_expectedDigests[key] != value) "  '$key': '$value',",
      ];
      expect(
        mismatches,
        isEmpty,
        reason: 'Changed album pages:\n${mismatches.join('\n')}',
      );
      expect(_expectedDigests.keys, unorderedEquals(actual.keys));
    },
  );
}
