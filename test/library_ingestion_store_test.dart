import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/library_ingestion_store.dart';

import 'support/library_native_fixture.dart';
import 'support/sqlite_process_database.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SqliteProcessDatabase database;
  late LibraryIngestionStore store;

  setUp(() async {
    database = await SqliteProcessDatabase.open();
    await createNativeLibraryFixture(database);
    store = LibraryIngestionStore(
      openDatabase: () async => database,
      ensureHistoryAttached: (_) async {},
    );
    await addNativeLibraryTrack(database, nativeLibraryTrack('kept'));
    await addNativeLibraryTrack(database, nativeLibraryTrack('gone'));
    await addNativeLibraryTrack(
      database,
      nativeLibraryTrack('elsewhere'),
      source: 'other',
    );
    await addNativeLibraryDownload(database, '/music/downloaded.flac');
  });
  tearDown(() => database.close());

  Future<List<String>> ids() async => [
    for (final row in await database.rawQuery(
      'SELECT id, source_id, track_name FROM library ORDER BY id',
    ))
      '${row['id']}@${row['source_id']}:${row['track_name']}',
  ];

  Future<List<String>> keyOwners() async => [
    for (final row in await database.rawQuery(
      'SELECT DISTINCT item_id FROM library_path_keys ORDER BY item_id',
    ))
      row['item_id'] as String,
  ];

  Future<List<Object?>> tempTables() async => [
    for (final row in await database.rawQuery(
      "SELECT name FROM sqlite_temp_master WHERE type = 'table'",
    ))
      row['name'],
  ];

  test('incremental upserts skip History files and keep the rest', () async {
    final result = await store.upsertBatchExcludingHistory([
      {...nativeLibraryTrack('kept'), 'trackName': 'Renamed'},
      nativeLibraryTrack('new'),
      nativeLibraryTrack('download', path: '/music/downloaded.flac'),
      {...nativeLibraryTrack('new'), 'trackName': 'Latest'},
    ], sourceId: 'source');

    expect(result, (upserted: 2, skipped: 1));
    expect(await ids(), [
      'elsewhere@other:Track elsewhere',
      'gone@source:Track gone',
      'kept@source:Renamed',
      'new@source:Latest',
    ]);
    expect(await keyOwners(), ['elsewhere', 'gone', 'kept', 'new']);
    expect(await tempTables(), isEmpty);
    await expectLater(
      store.upsertBatchExcludingHistory([
        {...nativeLibraryTrack('blank'), 'id': ' '},
      ], sourceId: 'source'),
      throwsFormatException,
    );
    expect(await tempTables(), isEmpty);
  });

  test('source replacement swaps one source and excludes History', () async {
    final result = await store.replaceSourceStream(
      'source',
      Stream.fromIterable([
        {...nativeLibraryTrack('kept'), 'trackName': 'Renamed'},
        nativeLibraryTrack('new'),
        nativeLibraryTrack('download', path: '/music/downloaded.flac'),
      ]),
      batchSize: 2,
    );

    expect(result, (inserted: 2, skipped: 1));
    expect(await ids(), [
      'elsewhere@other:Track elsewhere',
      'kept@source:Renamed',
      'new@source:Track new',
    ]);
    expect(await keyOwners(), ['elsewhere', 'kept', 'new']);
    expect(await tempTables(), isEmpty);
  });

  test('Windows scan aliases appear once and match downloaded files', () async {
    await addNativeLibraryDownload(database, r'C:\Music\downloaded.flac');
    final result = await store.upsertBatchExcludingHistory([
      nativeLibraryTrack('win-a', path: r'\\?\C:\Music\song.flac'),
      nativeLibraryTrack('win-b', path: r'C:\Music\song.flac'),
      nativeLibraryTrack('win-download', path: r'\\?\C:\Music\downloaded.flac'),
    ], sourceId: 'source');
    expect(result, (upserted: 2, skipped: 1));
    final visible = await database.rawQuery(
      "SELECT id FROM library_visible WHERE id LIKE 'win-%' ORDER BY id",
    );
    expect(visible.map((row) => row['id']), ['win-a']);
    expect(
      await database.query('library', where: 'id = ?', whereArgs: ['win-b']),
      hasLength(1),
    );
  });
}
