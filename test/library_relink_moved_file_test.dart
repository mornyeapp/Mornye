import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart'
    show databaseFactoryFfi, sqfliteFfiInit;
import 'package:mornye/services/library_database.dart';
import 'package:mornye/services/library_row_mapper.dart';

Map<String, dynamic> _scanned(String id, String path, String title) =>
    LocalLibraryItem(
      id: id,
      sourceId: 'music',
      trackName: title,
      artistName: 'Band',
      albumName: 'LP',
      filePath: path,
      scannedAt: DateTime.utc(2026, 10, 1),
      fileModTime: 1234,
      trackNumber: 1,
    ).toJson();

Future<void> _add(Map<String, dynamic> json) async {
  final db = await LibraryDatabase.instance.database;
  await db.insert('library', LibraryRowMapper.encode(json));
}

void main() {
  final messenger =
      TestWidgetsFlutterBinding.ensureInitialized().defaultBinaryMessenger;
  const paths = MethodChannel('plugins.flutter.io/path_provider');
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('library-relink-');
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
    await db.insert('library_sources', {
      'id': 'music',
      'path': '/music',
      'display_name': 'music',
      'available': 1,
      'enabled': 1,
    });
  });

  test('a moved file keeps its row under the new path', () async {
    final library = LibraryDatabase.instance;
    await _add(_scanned('old', '/music/incoming/a.mp3', 'A'));
    await _add(_scanned('other', '/music/b.mp3', 'B'));

    final before = await library.getPage(limit: 10);
    expect(before.map((row) => row['filePath']), {
      '/music/incoming/a.mp3',
      '/music/b.mp3',
    });

    expect(
      await library.relinkMovedFile(
        '/music/incoming/a.mp3',
        '/music/Band/LP/01 - A.mp3',
      ),
      isTrue,
    );

    final rows = await library.getPage(limit: 10);
    final moved = rows.singleWhere((row) => row['trackName'] == 'A');
    expect(moved['filePath'], '/music/Band/LP/01 - A.mp3');
    expect(moved['id'], isNot('old'));
    expect(moved['fileModTime'], 1234);
    expect(await library.getById('old'), isNull);
    expect((await library.getById(moved['id'] as String))?['trackName'], 'A');
    expect(await library.getCount(), 2);

    final db = await library.database;
    final keys = await db.query(
      'library_path_keys',
      where: 'item_id = ?',
      whereArgs: ['old'],
    );
    expect(keys, isEmpty);
  });

  test('a stale row at the destination is replaced, not duplicated', () async {
    final library = LibraryDatabase.instance;
    await _add(_scanned('moving', '/music/x.mp3', 'X'));
    await _add(_scanned('stale', '/music/Band/x.mp3', 'Old copy'));

    expect(
      await library.relinkMovedFile('/music/x.mp3', '/music/Band/x.mp3'),
      isTrue,
    );

    final rows = await library.getPage(limit: 10);
    expect(rows, hasLength(1));
    expect(rows.single['trackName'], 'X');
    expect(rows.single['filePath'], '/music/Band/x.mp3');
  });

  test('an unknown path is reported, not invented', () async {
    expect(
      await LibraryDatabase.instance.relinkMovedFile('/nope.mp3', '/a.mp3'),
      isFalse,
    );
  });
}
