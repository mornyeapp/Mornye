import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart'
    show databaseFactoryFfi, sqfliteFfiInit;
import 'package:mornye/providers/library_search_provider.dart';
import 'package:mornye/services/history_database.dart';
import 'package:mornye/services/library_database.dart';
import 'package:mornye/services/library_row_mapper.dart';
import 'package:mornye/services/sqlite_helpers.dart' as sqlite;

const _formats = ['flac', 'mp3', 'm4a'];

/// [count] scanned songs, scanned out of id order so the date sorts differ
/// from the insertion order.
Future<void> _seed(int count) async {
  final db = await LibraryDatabase.instance.database;
  final batch = db.batch();
  for (var index = 0; index < count; index++) {
    final id = 'song-${index.toString().padLeft(5, '0')}';
    final format = _formats[index % _formats.length];
    final path = '/music/$id.$format';
    final json = LocalLibraryItem(
      id: id,
      trackName: 'Song $index',
      artistName: 'Artist ${index % 7}',
      albumName: 'Album ${index % 11}',
      filePath: path,
      scannedAt: DateTime.utc(2026).add(Duration(minutes: (index * 37) % 997)),
      format: format,
    ).toJson();
    batch.insert('library', LibraryRowMapper.encode(json));
    sqlite.putPathKeysInBatch(batch, 'library_path_keys', id, path);
  }
  await batch.commit(noResult: true);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const paths = MethodChannel('plugins.flutter.io/path_provider');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('library-song-list-');
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

  for (final (sort, format) in [
    ('oldest', null),
    ('a-z', null),
    ('latest', 'flac'),
  ]) {
    test('the song list is every page of the Library list, in its order '
        '($sort, format: $format)', () async {
      await _seed(3100);
      // The Library list itself pages 300 songs at a time.
      final paged = <String>[];
      QueueLibraryDbCursor? cursor;
      for (var offset = 0; ; offset += 300) {
        final page = await LibraryDatabase.instance.getQueueTrackPageResult(
          QueueLibraryDbQuery(
            limit: 300,
            offset: offset,
            searchQuery: '',
            format: format,
            sortMode: sort,
            cursor: cursor,
          ),
        );
        paged.addAll([
          for (final row in page.rows) 'local_${(row['item'] as Map)['id']}',
        ]);
        if (page.rows.length < 300) break;
        cursor = page.nextCursor;
      }

      final container = ProviderContainer();
      addTearDown(container.dispose);
      final songs = await container.read(
        librarySongListProvider((
          filterMode: 'all',
          sortMode: sort,
          source: null,
          quality: null,
          format: format,
          metadata: null,
          includeLocal: true,
        )).future,
      );

      expect(songs.length, format == null ? 3100 : 1034);
      expect(songs.map((song) => song.id).toList(), paged);
      if (format != null) {
        expect(songs.every((song) => song.filePath.endsWith('.flac')), isTrue);
      }
    });
  }
}
