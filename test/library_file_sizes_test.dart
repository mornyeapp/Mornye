import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/library_database_models.dart';
import 'package:mornye/services/library_file_sizes.dart';
import 'package:mornye/services/library_queue_store.dart';

import 'support/library_paging_fixture.dart';
import 'support/sqlite_process_database.dart';

List<String> _identities(QueueLibraryDbPage page) => [
  for (final row in page.rows) '${row['source']}:${(row['item'] as Map)['id']}',
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SqliteProcessDatabase db;
  late LibraryQueueStore store;
  late LibraryFileSizes index;
  late Map<String, int?> sizes;
  late List<String> probes;

  setUp(() async {
    db = await SqliteProcessDatabase.open();
    store = await createLibraryPagingFixture(db, albumsPerSource: 3);
    // The album paging fixture omits History fields only used by song rows.
    for (final column in [
      'storage_mode TEXT',
      'download_tree_uri TEXT',
      'saf_relative_dir TEXT',
      'saf_file_name TEXT',
      'saf_repaired INTEGER',
      'spotify_id TEXT',
      'quality TEXT',
      'replaygain_metadata_scan_version INTEGER',
    ]) {
      await db.execute('ALTER TABLE history_db.history ADD COLUMN $column');
    }
    sizes = {
      for (var album = 0; album < 3; album++)
        for (var number = 1; number <= 2; number++) ...{
          '/fixture/download-$album-$number.flac': (album + 1) * 100 + number,
          '/fixture/local-$album-$number.flac': (album + 1) * 200 + number,
        },
    };
    sizes['/fixture/local-2-2.flac'] = null;
    probes = [];
    index = LibraryFileSizes(
      db,
      readSize: (path) async {
        probes.add(path);
        return sizes[path];
      },
    );
  });
  tearDown(() => db.close());

  Future<void> refresh() =>
      index.refresh(includeLocal: true, includeHistory: true);

  for (final sort in ['size-desc', 'size-asc']) {
    test(
      '$sort globally orders both sources and preserves cursor/offset pages',
      () async {
        await refresh();
        final full = await store.trackPage(
          QueueLibraryDbQuery(limit: 100, sortMode: sort),
        );
        expect(full.rows, hasLength(12));
        final values = [
          for (final row in full.rows) (row['item'] as Map)['fileSize'] as int?,
        ];
        expect(values.last, isNull);
        final known = values.whereType<int>().toList();
        final expected = [...known]..sort();
        expect(
          known,
          sort == 'size-asc' ? expected : expected.reversed.toList(),
        );
        final pages = <String>[];
        QueueLibraryDbCursor? cursor;
        do {
          final page = await store.trackPage(
            QueueLibraryDbQuery(limit: 2, cursor: cursor, sortMode: sort),
          );
          if (page.rows.isEmpty) break;
          expect(page.nextCursor, isNotNull);
          pages.addAll(_identities(page));
          cursor = page.nextCursor;
        } while (pages.length < 20);
        expect(pages, _identities(full));
        final offset = await store.trackPage(
          QueueLibraryDbQuery(limit: 3, offset: 3, sortMode: sort),
        );
        expect(_identities(offset), _identities(full).sublist(3, 6));
      },
    );

    test(
      '$sort orders albums by total bytes with incomplete sizes last',
      () async {
        await refresh();
        final full = await store.albumPage(
          QueueLibraryDbQuery(limit: 100, sortMode: sort),
        );
        expect(full.rows, hasLength(6));
        expect(full.rows.last['sort_size_unknown'], 1);
        final totals = [
          for (final row in full.rows.take(5)) row['sort_size'] as int,
        ];
        expect(
          totals,
          sort == 'size-desc'
              ? [803, 603, 403, 403, 203]
              : [203, 403, 403, 603, 803],
        );
        final pages = <String>[];
        QueueLibraryDbCursor? cursor;
        for (var i = 0; i < 4; i++) {
          final page = await store.albumPage(
            QueueLibraryDbQuery(limit: 2, cursor: cursor, sortMode: sort),
          );
          if (page.rows.isEmpty) break;
          pages.addAll([
            for (final row in page.rows)
              '${row['queue_source']}:${row['album_key']}',
          ]);
          cursor = page.nextCursor;
        }
        expect(pages, [
          for (final row in full.rows)
            '${row['queue_source']}:${row['album_key']}',
        ]);
      },
    );
  }

  test(
    'old rows are indexed once and persisted sizes survive a new reader',
    () async {
      await refresh();
      expect(probes, isNot(contains('/fixture/hidden.flac')));
      final count = probes.length;
      await refresh();
      await LibraryFileSizes(
        db,
        readSize: (_) async => fail('cached files must not be probed'),
      ).refresh(includeLocal: true, includeHistory: true);
      expect(probes.length, count);
    },
  );

  test(
    'conversion and scan writes invalidate even a file kept at the same path',
    () async {
      await refresh();
      const path = '/fixture/download-0-1.flac';
      sizes[path] = 45;
      await db.update(
        'history_db.history',
        {'quality': 'converted'},
        where: 'id = ?',
        whereArgs: ['download-0-1'],
      );
      const local = '/fixture/local-0-1.flac';
      sizes[local] = 20;
      await db.update(
        'library',
        {'file_mod_time': 500},
        where: 'id = ?',
        whereArgs: ['local-0-1'],
      );
      probes.clear();
      await refresh();
      expect(probes, unorderedEquals([path, local]));
      final page = await store.trackPage(
        const QueueLibraryDbQuery(limit: 2, sortMode: 'size-asc'),
      );
      expect(
        [for (final row in page.rows) (row['item'] as Map)['fileSize']],
        [20, 45],
      );
    },
  );

  test(
    'a delayed size cannot overwrite a replacement at the same path',
    () async {
      await refresh();
      const id = 'download-0-1';
      await db.update(
        'history_db.history',
        {'quality': 'first'},
        where: 'id = ?',
        whereArgs: [id],
      );
      final started = Completer<void>();
      final result = Completer<int?>();
      final delayed = LibraryFileSizes(
        db,
        readSize: (_) {
          started.complete();
          return result.future;
        },
      );
      final work = delayed.refresh(includeLocal: false, includeHistory: true);
      await started.future;
      await db.update(
        'history_db.history',
        {'quality': 'replacement'},
        where: 'id = ?',
        whereArgs: [id],
      );
      result.complete(999);
      await work;
      final row = (await db.query(
        'history_db.track_file_sizes',
        where: 'item_id = ?',
        whereArgs: [id],
      )).single;
      expect(row['size_bytes'], isNull);
      expect(row['checked_at'], 0);
      sizes['/fixture/download-0-1.flac'] = 50;
      await refresh();
      expect(
        (await db.query(
          'history_db.track_file_sizes',
          where: 'item_id = ?',
          whereArgs: [id],
        )).single['size_bytes'],
        50,
      );
    },
  );

  test('deleted tracks do not leave size records behind', () async {
    await refresh();
    await db.delete(
      'history_db.history',
      where: 'id = ?',
      whereArgs: ['download-0-1'],
    );
    expect(
      await db.query(
        'history_db.track_file_sizes',
        where: 'item_id = ?',
        whereArgs: ['download-0-1'],
      ),
      isEmpty,
    );
  });

  test('overlapping requests share the same metadata probes', () async {
    await Future.wait([refresh(), refresh()]);
    expect(probes, hasLength(13));
  });

  test('unavailable sizes are cached briefly and can be retried', () async {
    var unavailable = true;
    const path = '/fixture/download-0-1.flac';
    final reader = LibraryFileSizes(
      db,
      readSize: (file) async {
        if (file == path && unavailable) throw StateError('unavailable');
        return sizes[file];
      },
    );
    await reader.refresh(includeLocal: false, includeHistory: true);
    final before = (await db.query(
      'history_db.track_file_sizes',
      where: 'item_id = ?',
      whereArgs: ['download-0-1'],
    )).single;
    expect(before['size_bytes'], isNull);
    expect(before['checked_at'], greaterThan(0));
    unavailable = false;
    await reader.refresh(includeLocal: false, includeHistory: true);
    expect(
      (await db.query(
        'history_db.track_file_sizes',
        where: 'item_id = ?',
        whereArgs: ['download-0-1'],
      )).single['size_bytes'],
      isNull,
    );
    await db.update('history_db.track_file_sizes', {'checked_at': 0});
    await reader.refresh(includeLocal: false, includeHistory: true);
    expect(
      (await db.query(
        'history_db.track_file_sizes',
        where: 'item_id = ?',
        whereArgs: ['download-0-1'],
      )).single['size_bytes'],
      sizes[path],
    );
  });

  test('SAF sizes come from document metadata without copying audio', () async {
    const channel = MethodChannel('com.zarz.mornye/backend');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'safStat');
      return {'exists': true, 'size': 275};
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await db.update(
      'history_db.history',
      {'file_path': 'content://example/audio'},
      where: 'id = ?',
      whereArgs: ['download-0-1'],
    );
    await LibraryFileSizes(
      db,
    ).refresh(includeLocal: false, includeHistory: true);
    expect(
      (await db.query(
        'history_db.track_file_sizes',
        where: 'item_id = ?',
        whereArgs: ['download-0-1'],
      )).single['size_bytes'],
      275,
    );
  });

  test(
    'the production reader measures bytes on disk without parsing audio',
    () async {
      final root = await Directory.systemTemp.createTemp('library-size-');
      addTearDown(() => root.delete(recursive: true));
      final file = await File(
        '${root.path}/example.flac',
      ).writeAsBytes(List.filled(37, 0));
      await db.update(
        'history_db.history',
        {'file_path': file.path},
        where: 'id = ?',
        whereArgs: ['download-0-1'],
      );
      await LibraryFileSizes(
        db,
      ).refresh(includeLocal: false, includeHistory: true);
      final row = (await db.query(
        'history_db.track_file_sizes',
        where: 'item_id = ?',
        whereArgs: ['download-0-1'],
      )).single;
      expect(row['size_bytes'], 37);
    },
  );
}
