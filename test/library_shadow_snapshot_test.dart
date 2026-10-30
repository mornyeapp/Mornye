import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart'
    show databaseFactoryFfi, sqfliteFfiInit;
import 'package:mornye/services/album_completeness.dart';
import 'package:mornye/services/history_database.dart';
import 'package:mornye/services/library_database.dart';
import 'package:mornye/services/library_queue_store.dart';
import 'package:mornye/services/library_row_mapper.dart';
import 'package:mornye/services/library_search.dart';
import 'package:mornye/services/sqlite_helpers.dart' as sqlite;

const _sources = ['legacy', 'music', 'offline', 'disabled'];

Map<String, dynamic> _scanned(
  String id,
  String path, {
  required int album,
  required int number,
  String source = 'legacy',
}) => LocalLibraryItem(
  id: id,
  sourceId: source,
  trackName: 'Song $number',
  artistName: 'Artist ${album % 4}',
  albumName: 'Album $album',
  albumArtist: 'Artist ${album % 4}',
  filePath: path,
  scannedAt: DateTime.utc(2026, 10, album + 1, number),
  fileModTime: album * 100 + number,
  isrc: number == 2 ? '' : 'ISRC$album$number',
  trackNumber: number,
  totalTracks: album % 3 == 0 ? null : album % 4 + 2,
  discNumber: 1,
  totalDiscs: 1,
  bitDepth: number.isEven ? 24 : 16,
  genre: album.isEven ? 'Pop' : null,
  releaseDate: '${2010 + album}',
).toJson();

Map<String, dynamic> _download(
  String id,
  String path, {
  required int album,
  required int number,
}) => {
  'id': id,
  'trackName': 'Song $number',
  'artistName': 'Artist ${album % 4}',
  'albumName': 'Album $album',
  'albumArtist': 'Artist ${album % 4}',
  'filePath': path,
  'service': 'example-provider',
  'downloadedAt': DateTime.utc(
    2026,
    9,
    album % 28 + 1,
    number,
  ).toIso8601String(),
  'isrc': 'DL$album$number',
  'trackNumber': number,
  'totalTracks': album % 4 + 2,
  'discNumber': 1,
  'totalDiscs': 1,
  'quality': number.isEven ? '24-bit' : '16-bit',
  'bitDepth': number.isEven ? 24 : 16,
  'genre': 'Pop',
  'releaseDate': '2020',
};

/// The SAF document of `/storage/emulated/0/Music/A[album]/[number].flac`.
String _saf(int album, int number) =>
    'content://com.android.externalstorage.documents/tree/primary%3AMusic/'
    'document/primary%3AMusic%2FA$album%2F$number.flac';

/// A connection of its own: by default sqflite reuses the open one.
Future<Database> _connection(String path) => databaseFactoryFfi.openDatabase(
  path,
  options: OpenDatabaseOptions(singleInstance: false),
);

Future<void> _addScanned(Database db, Map<String, dynamic> json) async {
  await db.insert('library', LibraryRowMapper.encode(json));
  final batch = db.batch();
  sqlite.putPathKeysInBatch(
    batch,
    'library_path_keys',
    json['id'] as String,
    json['filePath'] as String,
  );
  await batch.commit(noResult: true);
}

/// Scanned rows in every source state; downloads of some of the same files
/// as SAF documents or with another extension; one download matching two
/// scanned copies; a History path key without its row; [extraDownloads]
/// others.
Future<void> _seed({int extraDownloads = 0}) async {
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
  final downloads = <Map<String, dynamic>>[];
  for (var album = 0; album < 10; album++) {
    for (var number = 1; number <= album % 4 + 2; number++) {
      final android = album.isEven;
      await _addScanned(
        library,
        _scanned(
          'l-$album-$number',
          android
              ? '/storage/emulated/0/Music/A$album/$number.flac'
              : '/Users/me/Music/A$album/$number.m4a',
          album: album,
          number: number,
          source: _sources[(album + number) % 4],
        ),
      );
      if (album % 3 != 1 && number <= 2) {
        downloads.add(
          _download(
            'h-$album-$number',
            android
                ? _saf(album, number)
                : '/Users/me/Music/A$album/$number.opus',
            album: album,
            number: number,
          ),
        );
      }
    }
  }
  for (final (id, extension) in [('l-dup-1', 'flac'), ('l-dup-2', 'm4a')]) {
    await _addScanned(
      library,
      _scanned(id, '/Users/me/Music/Dup/1.$extension', album: 10, number: 1),
    );
  }
  downloads.add(
    _download('h-dup', '/Users/me/Music/Dup/1.opus', album: 10, number: 1),
  );
  for (var index = 0; index < extraDownloads; index++) {
    downloads.add(
      _download(
        'h-only-$index',
        '/Users/me/Downloads/$index.flac',
        album: 20 + index % 5,
        number: index % 3 + 1,
      ),
    );
  }
  await HistoryDatabase.instance.upsertBatch(downloads);
  await (await HistoryDatabase.instance.database).insert('history_path_keys', {
    'item_id': 'ghost',
    'path_key': '/Users/me/Music/A3/3.m4a',
  });
}

LibraryQueueStore _store(Database db, {bool snapshot = false}) =>
    LibraryQueueStore(
      db,
      historyFts: HistoryDatabase.instance.searchFtsAvailable,
      localFts: LibraryDatabase.instance.searchFtsAvailable,
      shadowSnapshot: snapshot,
    );

List<Object?> _counts(QueueLibraryCounts counts) => [
  counts.allTrackCount,
  counts.albumCount,
  counts.singleTrackCount,
];

List<Object?> _hits(List<LibrarySearchHit> hits) => [
  for (final hit in hits)
    [
      hit.source,
      hit.id,
      hit.title,
      hit.artist,
      hit.cover,
      hit.samplePath,
      hit.trackCount,
    ],
];

final _requests = <String, QueueLibraryDbQuery>{
  for (final source in [null, 'local', 'downloaded'])
    for (final sort in ['latest', 'a-z', 'album-asc', 'size-desc'])
      for (final MapEntry(key: name, value: build)
          in <String, QueueLibraryDbQuery Function(String?, String)>{
            'all': (source, sort) =>
                QueueLibraryDbQuery(source: source, sortMode: sort),
            'singles': (source, sort) => QueueLibraryDbQuery(
              source: source,
              sortMode: sort,
              filterMode: 'singles',
            ),
            'search': (source, sort) => QueueLibraryDbQuery(
              source: source,
              sortMode: sort,
              searchQuery: 'song 2',
            ),
            'album-artist': (source, sort) => QueueLibraryDbQuery(
              source: source,
              sortMode: sort,
              albumArtist: 'Artist 1',
            ),
            'hires': (source, sort) => QueueLibraryDbQuery(
              source: source,
              sortMode: sort,
              quality: 'hires',
            ),
            'flac': (source, sort) => QueueLibraryDbQuery(
              source: source,
              sortMode: sort,
              format: 'flac',
            ),
            'missing-genre': (source, sort) => QueueLibraryDbQuery(
              source: source,
              sortMode: sort,
              metadata: 'missing-genre',
            ),
            'incomplete': (source, sort) => QueueLibraryDbQuery(
              source: source,
              sortMode: sort,
              metadata: incompleteAlbumFilter,
            ),
            'unknown': (source, sort) => QueueLibraryDbQuery(
              source: source,
              sortMode: sort,
              metadata: unknownAlbumCompletenessFilter,
            ),
            'single-albums': (source, sort) => QueueLibraryDbQuery(
              source: source,
              sortMode: sort,
              includeSingleTrackAlbums: true,
            ),
          }.entries)
        '$name ${source ?? 'all'} $sort': build(source, sort),
};

/// Every family of reads that leaves out shadowed rows.
Future<Map<String, Object?>> _reads(
  Database db, {
  required bool snapshot,
}) async {
  final store = _store(db, snapshot: snapshot);
  final search = LibrarySearchStore(
    db,
    historyFts: HistoryDatabase.instance.searchFtsAvailable,
    localFts: LibraryDatabase.instance.searchFtsAvailable,
    shadowSnapshot: snapshot,
  );
  final reads = <String, Object?>{};
  for (final MapEntry(key: name, value: query) in _requests.entries) {
    final request = QueueLibraryDbQuery(
      source: query.source,
      sortMode: query.sortMode,
      filterMode: query.filterMode,
      searchQuery: query.searchQuery,
      albumArtist: query.albumArtist,
      quality: query.quality,
      format: query.format,
      metadata: query.metadata,
      includeSingleTrackAlbums: query.includeSingleTrackAlbums,
      limit: 1000,
    );
    reads['tracks $name'] = (await store.trackPage(request)).rows;
    reads['albums $name'] = (await store.albumPage(request)).rows;
    reads['counts $name'] = _counts(await store.counts(request));
    reads['artists $name'] = await store.artistPage(request);
  }
  reads['folders'] = await store.directoryEntries(includeLocal: true);
  reads['files'] = await store.songFiles();
  reads['mixes'] = await store.mixSongs(
    includeLocal: true,
    limit: 1000,
    offset: 0,
  );
  for (final kind in [
    LibrarySearchKind.songs,
    LibrarySearchKind.albums,
    LibrarySearchKind.artists,
  ]) {
    for (final text in ['song', 'album 1', 'artist 2', 'so']) {
      reads['search ${kind.name} $text'] = _hits(
        await search.search(
          query: text,
          kind: kind,
          includeLocal: true,
          limit: 1000,
        ),
      );
    }
  }
  return reads;
}

Future<List<Map<String, Object?>>> _shadowPairs(Database db) => db.rawQuery(
  'SELECT item_id, history_id FROM ${sqlite.libraryShadowTable} '
  'ORDER BY item_id, history_id',
);

Future<List<Map<String, Object?>>> _currentPairs(Database db) => db.rawQuery('''
  SELECT DISTINCT lpk.item_id, hpk.item_id AS history_id
  FROM library_path_keys lpk
  JOIN history_db.history_path_keys hpk ON hpk.path_key = lpk.path_key
  ORDER BY 1, 2
''');

/// Reads through [LibraryDatabase], which uses its snapshot, against the
/// same reads through the row check on the same connection.
Future<void> _expectCurrent(String step) async {
  final library = LibraryDatabase.instance;
  final rowCheck = _store(await library.database);
  for (final request in const [
    QueueLibraryDbQuery(limit: 1000),
    QueueLibraryDbQuery(source: 'local', limit: 1000),
    QueueLibraryDbQuery(metadata: incompleteAlbumFilter, limit: 1000),
    QueueLibraryDbQuery(metadata: unknownAlbumCompletenessFilter, limit: 1000),
  ]) {
    expect(
      _counts(await library.getQueueCounts(request)),
      _counts(await rowCheck.counts(request)),
      reason: '$step counts',
    );
    expect(
      (await library.getQueueTrackPageResult(request)).rows,
      (await rowCheck.trackPage(request)).rows,
      reason: '$step tracks',
    );
    expect(
      (await library.getQueueAlbumPageResult(request)).rows,
      (await rowCheck.albumPage(request)).rows,
      reason: '$step albums',
    );
    expect(
      await library.getQueueArtistPage(request),
      await rowCheck.artistPage(request),
      reason: '$step artists',
    );
  }
  expect(
    await library.getDirectoryEntries(includeLocal: true),
    await rowCheck.directoryEntries(includeLocal: true),
    reason: '$step folders',
  );
  expect(
    await library.getSongFiles(),
    await rowCheck.songFiles(),
    reason: '$step files',
  );
  expect(
    await library.getMixSongPage(includeLocal: true, limit: 1000, offset: 0),
    await rowCheck.mixSongs(includeLocal: true, limit: 1000, offset: 0),
    reason: '$step mixes',
  );
  expect(
    _hits(
      await library.searchLibrary(
        query: 'song',
        kind: LibrarySearchKind.songs,
        includeLocal: true,
        limit: 1000,
      ),
    ),
    _hits(
      await LibrarySearchStore(
        await library.database,
        historyFts: HistoryDatabase.instance.searchFtsAvailable,
        localFts: library.searchFtsAvailable,
      ).search(
        query: 'song',
        kind: LibrarySearchKind.songs,
        includeLocal: true,
        limit: 1000,
      ),
    ),
    reason: '$step search',
  );
  // The reads above used a snapshot, not the row-check fallback.
  final db = await library.database;
  expect(await _shadowPairs(db), await _currentPairs(db), reason: step);
}

Future<int> _scannedSongs() async =>
    (await LibraryDatabase.instance.getQueueCounts(
      const QueueLibraryDbQuery(source: 'local'),
    )).allTrackCount;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const paths = MethodChannel('plugins.flutter.io/path_provider');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('library-shadow-');
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

  for (final extraDownloads in [0, 60]) {
    test(
      'the snapshot selects the rows the row check selects '
      '(${extraDownloads == 0 ? 'fewer' : 'more'} downloads than songs)',
      () async {
        await _seed(extraDownloads: extraDownloads);
        final db = await LibraryDatabase.instance.database;
        // Size sorts read the size index this call creates.
        await LibraryDatabase.instance.getQueueTrackPageResult(
          const QueueLibraryDbQuery(sortMode: 'size-desc'),
        );
        final sizes = (await db.rawQuery(
          'SELECT (SELECT COUNT(*) FROM library) AS library, '
          '(SELECT COUNT(*) FROM history_db.history) AS history',
        )).single;
        // Each case builds the pairs from a different side.
        expect(
          (sizes['history'] as int) * 2 < (sizes['library'] as int),
          extraDownloads == 0,
        );
        final pairs = await _shadowPairs(db);
        expect(pairs, await _currentPairs(db));
        expect(
          pairs.map((pair) => pair['item_id']).toSet(),
          containsAll(['l-0-1', 'l-3-3', 'l-5-2', 'l-dup-1', 'l-dup-2']),
        );

        final rowCheck = await _reads(db, snapshot: false);
        final snapshot = await _reads(db, snapshot: true);
        expect(snapshot.keys, rowCheck.keys);
        for (final name in rowCheck.keys) {
          expect(snapshot[name], rowCheck[name], reason: name);
        }
        // The fixture exercises each completeness verdict.
        final albums = (rowCheck['albums all all latest'] as List)
            .cast<Map<String, Object?>>();
        expect(rowCheck['albums incomplete all latest'], isNotEmpty);
        expect(rowCheck['albums unknown all latest'], isNotEmpty);
        expect(albums, isNotEmpty);
      },
    );
  }

  test('every writer refreshes the snapshot before the next read', () async {
    await _seed();
    final library = LibraryDatabase.instance;
    await _expectCurrent('seed');
    final base = await _scannedSongs();

    // A download of a scanned file, through the History connection.
    await HistoryDatabase.instance.upsert(
      _download('h-new', _saf(4, 1), album: 4, number: 1),
    );
    expect(await _scannedSongs(), base - 1);
    await _expectCurrent('history download');
    await HistoryDatabase.instance.deleteByIds(['h-new']);
    expect(await _scannedSongs(), base);
    await _expectCurrent('history delete');

    // Another connection, as Android's native store or a Rust restore.
    final native = await _connection(p.join(root.path, 'history.db'));
    addTearDown(native.close);
    await native.insert('history', {
      'id': 'native',
      'track_name': 'Song 1',
      'artist_name': 'Artist 0',
      'album_name': 'Album 4',
      'file_path': 'file:///storage/emulated/0/Music/A4/1.flac',
      'service': 'example-provider',
      'downloaded_at': '2026-10-30T00:00:00Z',
    });
    final batch = native.batch();
    sqlite.putPathKeysInBatch(
      batch,
      'history_path_keys',
      'native',
      'file:///storage/emulated/0/Music/A4/1.flac',
    );
    await batch.commit(noResult: true);
    expect(await _scannedSongs(), base - 1);
    await _expectCurrent('native history write');
    await native.delete('history_path_keys', where: "item_id = 'native'");
    expect(await _scannedSongs(), base);
    await _expectCurrent('native history delete');

    // Raw writes on the Library connection itself, to either schema.
    final db = await library.database;
    await db.delete(
      'history_db.history_path_keys',
      where: 'item_id = ?',
      whereArgs: ['h-0-1'],
    );
    expect(await _scannedSongs(), base + 1);
    await _expectCurrent('raw history key delete');
    await _addScanned(
      db,
      _scanned(
        'l-copy',
        '/storage/emulated/legacy/Music/A2/1.m4a',
        album: 2,
        number: 1,
      ),
    );
    await _addScanned(
      db,
      _scanned('l-fresh', '/Users/me/Music/Fresh/1.flac', album: 11, number: 1),
    );
    expect(await _scannedSongs(), base + 2);
    await _expectCurrent('raw library insert');
    await db.update(
      'library',
      {'album_name': 'Renamed'},
      where: 'id = ?',
      whereArgs: ['l-0-1'],
    );
    await _expectCurrent('raw library update');

    // Library repository writes: deletes, sources and scans.
    await library.deleteByIds(['l-fresh']);
    expect(await _scannedSongs(), base + 1);
    await _expectCurrent('delete');
    await library.updateSourceState('music', enabled: false);
    await _expectCurrent('source disabled');
    await library.updateSourceState('music', enabled: true);
    await _expectCurrent('source enabled');
    await library.removeSource('offline');
    await _expectCurrent('source removed');
    await library.upsertBatchExcludingHistory([
      _scanned(
        'l-scan',
        '/Users/me/Music/Scan/1.flac',
        album: 12,
        number: 1,
        source: 'music',
      ),
    ], sourceId: 'music');
    await _expectCurrent('incremental scan');
    await library.deleteByPaths(['/Users/me/Music/Scan/1.flac']);
    await _expectCurrent('scan removal');

    // A writer on another Library connection.
    final other = await _connection(p.join(root.path, 'local_library.db'));
    addTearDown(other.close);
    await _addScanned(
      other,
      _scanned('l-other', '/sdcard/Music/A6/1.opus', album: 6, number: 1),
    );
    await _expectCurrent('other library connection');

    // A new connection starts without the TEMP table.
    await library.close();
    await _expectCurrent('reopened');
    await HistoryDatabase.instance.clearAll();
    await _expectCurrent('history cleared');
    await library.clearAll();
    expect(await _scannedSongs(), 0);
    await _expectCurrent('library cleared');
  });

  test('reads and other snapshots leave the snapshot current', () async {
    await _seed();
    final library = LibraryDatabase.instance;
    await library.getQueueCounts(const QueueLibraryDbQuery());
    final db = await library.database;
    final snapshot = sqlite.LibraryShadowSnapshot();
    expect(await snapshot.refresh(db), isNotNull);
    expect(snapshot.rebuilds, 1);
    expect(
      await Future.wait([for (var i = 0; i < 6; i++) snapshot.refresh(db)]),
      everyElement(isNotNull),
    );
    expect(snapshot.rebuilds, 1);

    // Reads, and the Library's own rebuild of the same TEMP table, write no
    // rows in either database.
    await HistoryDatabase.instance.upsert(
      _download('h-new', _saf(4, 1), album: 4, number: 1),
    );
    await library.getQueueCounts(const QueueLibraryDbQuery());
    await library.searchLibrary(
      query: 'song',
      kind: LibrarySearchKind.albums,
      includeLocal: true,
    );
    await library.getLookupIndex();
    expect(await snapshot.refresh(db), isNotNull);
    expect(snapshot.rebuilds, 2);
    expect(await snapshot.refresh(db), isNotNull);
    expect(snapshot.rebuilds, 2);

    await db.update(
      'library',
      {'genre': 'Jazz'},
      where: 'id = ?',
      whereArgs: ['l-0-1'],
    );
    expect(
      await Future.wait([for (var i = 0; i < 6; i++) snapshot.refresh(db)]),
      everyElement(isNotNull),
    );
    expect(snapshot.rebuilds, 3);
  });

  test('a write during a rebuild reaches the next refresh', () async {
    await _seed();
    final library = LibraryDatabase.instance;
    await library.getQueueCounts(const QueueLibraryDbQuery());
    final db = await library.database;
    final snapshot = sqlite.LibraryShadowSnapshot();
    final building = snapshot.refresh(db);
    await HistoryDatabase.instance.upsert(
      _download('h-new', _saf(4, 1), album: 4, number: 1),
    );
    expect(await building, isNotNull);
    expect(await snapshot.refresh(db), isNotNull);
    expect(
      (await _shadowPairs(db)).map((pair) => pair['item_id']),
      contains('l-4-1'),
    );
  });

  test('a write before the query finishes reads the row check', () async {
    await _seed();
    final library = LibraryDatabase.instance;
    await library.getQueueCounts(const QueueLibraryDbQuery());
    final db = await library.database;
    const scanned = QueueLibraryDbQuery(source: 'local');
    final writers = <String, Future<void> Function()>{
      'none': () async {},
      'History connection': () => HistoryDatabase.instance.upsert(
        _download('h-new', _saf(4, 1), album: 4, number: 1),
      ),
      'Library connection': () => db.delete(
        'history_db.history_path_keys',
        where: 'item_id = ?',
        whereArgs: ['h-0-1'],
      ),
    };
    for (final MapEntry(key: writer, value: write) in writers.entries) {
      final snapshot = sqlite.LibraryShadowSnapshot();
      final modes = <bool>[];
      final counts = await snapshot.read(db, (snap) async {
        modes.add(snap);
        // The write lands after the snapshot and before the query.
        if (modes.length == 1) await write();
        return _counts(await _store(db, snapshot: snap).counts(scanned));
      });
      expect(modes, writer == 'none' ? [true] : [true, false], reason: writer);
      expect(counts, _counts(await _store(db).counts(scanned)), reason: writer);
    }
  });

  test('without a stamp the reads keep the row check', () async {
    final memory = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    addTearDown(memory.close);
    final snapshot = sqlite.LibraryShadowSnapshot();
    // history_db is not attached, so its data_version cannot be read.
    expect(await snapshot.refresh(memory), isNull);
    expect(await snapshot.refresh(_NoBatchResults()), isNull);
    expect(await snapshot.read(memory, (snap) async => snap), isFalse);
    expect(snapshot.rebuilds, 0);
  });
}

/// A platform whose batch calls return no results, as a mocked channel does.
class _NoBatchResults implements Database {
  @override
  Batch batch() => _EmptyBatch();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _EmptyBatch implements Batch {
  @override
  void rawQuery(String sql, [List<Object?>? arguments]) {}

  @override
  Future<List<Object?>> apply({bool? noResult, bool? continueOnError}) async =>
      const [];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
