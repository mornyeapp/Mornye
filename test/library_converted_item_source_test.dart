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

  setUp(() async {
    root = await Directory.systemTemp.createTemp('library-converted-');
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
    await db.insert(
      'library',
      LibraryRowMapper.encode(
        LocalLibraryItem(
          id: 'song',
          sourceId: 'music',
          trackName: 'Song',
          artistName: 'Band',
          albumName: 'LP',
          filePath: '/music/Song.flac',
          scannedAt: DateTime.utc(2026, 10, 1),
          format: 'flac',
          bitDepth: 24,
          sampleRate: 96000,
        ).toJson(),
      ),
    );
  });

  // A song opened from a list carries no folder, only the default one.
  LocalLibraryItem listed() => LocalLibraryItem(
    id: 'song',
    trackName: 'Song',
    artistName: 'Band',
    albumName: 'LP',
    filePath: '/music/Song.flac',
    scannedAt: DateTime.utc(2026, 10, 1),
    format: 'flac',
    bitDepth: 24,
    sampleRate: 96000,
  );

  for (final keepOriginal in [true, false]) {
    test('a converted file stays in the folder of its original '
        '(keep original: $keepOriginal)', () async {
      final library = LibraryDatabase.instance;
      expect(listed().sourceId, LibraryDatabase.legacySourceId);

      await library.replaceWithConvertedItem(
        item: listed(),
        newFilePath: '/music/Song.m4a',
        targetFormat: 'ALAC',
        bitrate: '',
        sampleRate: 44100,
        keepOriginal: keepOriginal,
      );

      // The library only lists songs of a folder that is present.
      final rows = await library.getPage(limit: 10);
      expect(rows.map((row) => row['filePath']), {
        '/music/Song.m4a',
        if (keepOriginal) '/music/Song.flac',
      });
      final converted = rows.singleWhere(
        (row) => row['filePath'] == '/music/Song.m4a',
      );
      expect(converted['sourceId'], 'music');
      expect(converted['format'], 'alac');
      expect(converted['sampleRate'], 44100);
    });
  }
}
