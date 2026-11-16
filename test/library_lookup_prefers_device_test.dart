import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart'
    show databaseFactoryFfi, sqfliteFfiInit;
import 'package:mornye/services/library_database.dart';
import 'package:mornye/services/library_row_mapper.dart';

void main() {
  final messenger =
      TestWidgetsFlutterBinding.ensureInitialized().defaultBinaryMessenger;
  const paths = MethodChannel('plugins.flutter.io/path_provider');
  late Directory root;

  Future<void> add(
    Database db, {
    required String id,
    required String source,
    required String path,
    String? isrc,
  }) => db.insert(
    'library',
    LibraryRowMapper.encode(
      LocalLibraryItem(
        id: id,
        sourceId: source,
        trackName: 'Song',
        artistName: 'Band',
        albumName: 'LP',
        filePath: path,
        scannedAt: DateTime.utc(2026, 11, 1),
        format: 'flac',
        isrc: isrc,
      ).toJson(),
    ),
  );

  setUp(() async {
    root = await Directory.systemTemp.createTemp('library-lookup-');
    sqfliteFfiInit();
    final previousFactory = databaseFactoryOrNull;
    databaseFactory = databaseFactoryFfi;
    messenger.setMockMethodCallHandler(paths, (_) async => root.path);
    addTearDown(() async {
      await LibraryDatabase.instance.close();
      messenger.setMockMethodCallHandler(paths, null);
      databaseFactory = previousFactory;
      await root.delete(recursive: true);
    });
    final db = await LibraryDatabase.instance.database;
    for (final (id, path) in [
      ('host', 'network://conn-1'),
      ('music', '/music'),
    ]) {
      await db.insert('library_sources', {
        'id': id,
        'path': path,
        'display_name': id,
        'available': 1,
        'enabled': 1,
      });
    }
    // The other device's row comes first in the table.
    await add(
      db,
      id: 'a-host',
      source: 'host',
      path: 'network://conn-1/rest/stream/song.flac',
      isrc: 'USAAA2600001',
    );
    await add(
      db,
      id: 'b-device',
      source: 'music',
      path: '/music/Band/Song.flac',
      isrc: 'USAAA2600001',
    );
  });

  test(
    'a song on this device answers before the same song elsewhere',
    () async {
      final found = await LibraryDatabase.instance.findExistingBatch(const [
        LocalLibraryBatchLookupRequest(trackName: 'Song', artistName: 'Band'),
        LocalLibraryBatchLookupRequest(
          isrc: 'USAAA2600001',
          trackName: 'Other',
          artistName: 'Other',
        ),
        LocalLibraryBatchLookupRequest(
          id: 'a-host',
          trackName: 'Song',
          artistName: 'Band',
        ),
      ]);

      expect(found[0]?['filePath'], '/music/Band/Song.flac');
      expect(found[1]?['filePath'], '/music/Band/Song.flac');
      // A row asked for by its id is still that row.
      expect(found[2]?['id'], 'a-host');
    },
  );

  test('a song only another device has is still found', () async {
    final db = await LibraryDatabase.instance.database;
    await db.delete('library', where: 'id = ?', whereArgs: ['b-device']);

    final found = await LibraryDatabase.instance.findExistingBatch(const [
      LocalLibraryBatchLookupRequest(trackName: 'Song', artistName: 'Band'),
    ]);

    expect(found.single?['id'], 'a-host');
  });
}
