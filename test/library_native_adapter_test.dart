import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart';
import 'package:mornye/services/history_database.dart';
import 'package:mornye/services/library_native_adapter.dart';
import 'package:mornye/services/library_row_mapper.dart';
import 'package:mornye/services/library_schema.dart';
import 'package:mornye/services/platform_bridge.dart';
import 'package:mornye/services/sqlite_native_snapshot.dart';

import 'support/library_native_fixture.dart';
import 'support/sqlite_process_database.dart';

class _NativeHarness {
  _NativeHarness(this.live);
  final Database live;
  List<Map<String, dynamic>> incremental = [];
  List<String> removed = [];
  // Scan rows the native staging reports as invalid instead of staging.
  List<String> invalidPaths = [];
  Future<void> Function()? afterStage;
  final stagedPaths = <String>[];

  Future<Map<String, dynamic>> run(
    Map<String, dynamic> request, {
    String? requestId,
  }) async {
    final path = request['library_path'] as String;
    expect(path, isNot(live.path));
    expect(
      (await live.rawQuery('PRAGMA database_list')).map((r) => r['file']),
      isNot(contains(path)),
    );
    stagedPaths.add(path);
    final private = await SqliteProcessDatabase.open(path: path);
    expect(
      (await private.rawQuery('PRAGMA user_version')).single['user_version'],
      LibrarySchema.version,
    );
    final snapshot = request['operation'] == 'library_snapshot';
    var count = 0;
    var invalid = <Map<String, dynamic>>[];
    try {
      if (snapshot) {
        final indexes = await private.rawQuery('PRAGMA index_list(library)');
        expect(
          indexes.any((row) => row['name'] == 'native_library_snapshot_id'),
          isTrue,
        );
        final rows = await private.query('library', orderBy: 'id');
        final lines = <String>[];
        for (final row in rows) {
          var timestamp =
              (row['audio_metadata_scan_version'] as num).toInt() < 4
              ? -1
              : (row['file_mod_time'] as num?)?.toInt() ?? 0;
          if (timestamp == 0) {
            timestamp = 999;
            await private.update(
              'library',
              {'file_mod_time': timestamp, 'sort_added': timestamp},
              where: 'id = ?',
              whereArgs: [row['id']],
            );
          }
          lines.add('$timestamp\t${row['file_path']}');
        }
        await File(
          request['snapshot_path'] as String,
        ).writeAsString('${lines.join('\n')}\n');
        count = rows.length;
      } else {
        expect(await private.query('library'), isEmpty);
        final history = await SqliteProcessDatabase.open(
          path: request['history_path'] as String,
        );
        try {
          expect(
            (await history.rawQuery(
              'PRAGMA user_version',
            )).single['user_version'],
            HistoryDatabase.schemaVersion,
          );
          expect(await history.query('history_path_keys'), isEmpty);
        } finally {
          await history.close();
        }
        final full = request['operation'] == 'library_full_import';
        final rows = full
            ? (await File(request['ndjson_path'] as String).readAsLines())
                  .where((line) => line.isNotEmpty)
                  .map(
                    (line) =>
                        Map<String, dynamic>.from(jsonDecode(line) as Map),
                  )
                  .toList()
            : incremental;
        invalid = rows
            .where((row) => invalidPaths.contains(row['filePath']))
            .toList();
        for (final row in rows) {
          if (invalid.contains(row)) continue;
          await addNativeLibraryTrack(private, row);
        }
        count = rows.length - invalid.length;
        if (!full) {
          expect(request['retain_removed_paths'], isTrue);
          await private.execute(
            'CREATE TABLE native_library_removed_paths(ordinal INTEGER PRIMARY KEY,path TEXT NOT NULL)',
          );
          for (var i = 0; i < removed.length; i++) {
            await private.execute(
              'INSERT INTO native_library_removed_paths VALUES(?,?)',
              [i, removed[i]],
            );
          }
        }
      }
    } finally {
      await private.close();
    }
    await afterStage?.call();
    return {
      'committed': true,
      'inserted': count,
      'skipped': 0,
      'scanned_count': count + invalid.length,
      'invalid_rows': invalid.length,
      'invalid_row_paths': invalid.map((row) => row['filePath']).toList(),
      if (invalid.isNotEmpty)
        'invalid_row_error':
            '${invalid.first['filePath']}: '
            'Library scan row requires string trackName',
      'totalFiles': count + 3,
      'skippedCount': 3,
      if (snapshot) 'path': request['snapshot_path'],
    };
  }
}

class _SqlProbe implements Database, Transaction {
  _SqlProbe(this.inner, this.path, this.onSql);
  final DatabaseExecutor inner;
  @override
  final String path;
  final void Function(String) onSql;
  @override
  Future<void> execute(String sql, [List<Object?>? args]) async {
    if (sql.startsWith('DETACH')) onSql(sql);
    await inner.execute(sql, args);
    if (!sql.startsWith('DETACH')) onSql(sql);
  }

  @override
  Future<List<Map<String, Object?>>> rawQuery(
    String sql, [
    List<Object?>? args,
  ]) => inner.rawQuery(sql, args);
  @override
  Future<int> rawDelete(String sql, [List<Object?>? args]) async {
    final result = await inner.rawDelete(sql, args);
    onSql(sql);
    return result;
  }

  @override
  Future<int> rawUpdate(String sql, [List<Object?>? args]) async {
    final result = await inner.rawUpdate(sql, args);
    onSql(sql);
    return result;
  }

  @override
  Future<List<Map<String, Object?>>> query(
    String table, {
    bool? distinct,
    List<String>? columns,
    String? where,
    List<Object?>? whereArgs,
    String? groupBy,
    String? having,
    String? orderBy,
    int? limit,
    int? offset,
  }) => inner.query(
    table,
    distinct: distinct,
    columns: columns,
    where: where,
    whereArgs: whereArgs,
    groupBy: groupBy,
    having: having,
    orderBy: orderBy,
    limit: limit,
    offset: offset,
  );
  @override
  Future<T> transaction<T>(
    Future<T> Function(Transaction) action, {
    bool? exclusive,
  }) => (inner as Database).transaction(
    (txn) => action(_SqlProbe(txn, path, onSql)),
    exclusive: exclusive,
  );
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late Directory root;
  late SqliteProcessDatabase live;
  late _NativeHarness native;
  late LibraryNativeAdapter adapter;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('library-private-adapter-');
    live = await SqliteProcessDatabase.open(path: '${root.path}/live.db');
    await createNativeLibraryFixture(live);
    native = _NativeHarness(live);
    adapter = LibraryNativeAdapter(
      live,
      temporaryDirectory: root,
      nativeJobRunner: native.run,
      platform: 'ios',
    );
    await addNativeLibraryTrack(live, nativeLibraryTrack('old'));
    await addNativeLibraryTrack(
      live,
      nativeLibraryTrack('other', path: '/other/other.flac'),
      source: 'other',
    );
  });
  tearDown(() async {
    await live.close();
    await root.delete(recursive: true);
  });
  Future<LibraryScanNDJSONFile> scan(
    List<Map<String, dynamic>> rows, {
    int errors = 0,
    List<String>? preserveMissingPaths,
  }) async {
    final file = File('${root.path}/scan.ndjson');
    await file.writeAsString(rows.map(jsonEncode).join('\n'));
    return LibraryScanNDJSONFile(
      file: file,
      expectedCount: rows.length,
      errorCount: errors,
      preserveMissingPaths: preserveMissingPaths,
    );
  }

  Future<void> cleaned() async {
    for (final path in native.stagedPaths) {
      expect(await Directory(File(path).parent.path).exists(), isFalse);
    }
    expect(
      (await live.rawQuery(
        'PRAGMA database_list',
      )).map((r) => r['name']).where((name) => name != 'temp'),
      ['main', 'history_db'],
    );
    expect(await live.rawQuery('PRAGMA integrity_check'), [
      {'integrity_check': 'ok'},
    ]);
  }

  test(
    'full private staging publishes exact rows and filters current History through live triggers',
    () async {
      final rows = [nativeLibraryTrack('new'), nativeLibraryTrack('download')];
      native.afterStage = () =>
          addNativeLibraryDownload(live, '/music/download.flac');
      final result = await adapter.importScanFile(
        'source',
        await scan(rows),
        requestId: 'full',
        isCancelled: () => false,
      );
      expect(result, containsPair('durable', true));
      expect(result['inserted'], 1);
      expect(result['skipped'], 1);
      expect(
        await live.query(
          'library',
          where: 'source_id = ?',
          whereArgs: ['source'],
        ),
        [LibraryRowMapper.encode(rows.first, sourceId: 'source')],
      );
      expect(
        (await live.query(
          'library_path_keys',
        )).map((r) => r['item_id']).toSet(),
        {'new', 'other'},
      );
      final lookup = await live.rawQuery(
        "SELECT ref_count FROM library_lookup_summary WHERE source_id='source' AND kind='match'",
      );
      expect(lookup, [
        {'ref_count': 1},
      ]);
      await cleaned();
    },
  );

  test(
    'partial and empty scans preserve missing rows only for partial scans',
    () async {
      await adapter.importScanFile(
        'source',
        await scan([nativeLibraryTrack('new')], errors: 1),
        requestId: 'partial',
        isCancelled: () => false,
      );
      expect((await live.query('library', orderBy: 'id')).map((r) => r['id']), [
        'new',
        'old',
        'other',
      ]);
      await adapter.importScanFile(
        'source',
        await scan([], errors: 1),
        requestId: 'empty-partial',
        isCancelled: () => false,
      );
      expect((await live.query('library', orderBy: 'id')).map((r) => r['id']), [
        'new',
        'old',
        'other',
      ]);
      final result = await adapter.importScanFile(
        'source',
        await scan([]),
        requestId: 'empty',
        isCancelled: () => false,
      );
      expect(result['inserted'], 0);
      expect((await live.query('library')).map((r) => r['id']), ['other']);
      await cleaned();
    },
  );

  test('partial NAS publication retains only unreadable scopes', () async {
    const prefix = 'network://nas/music/';
    await addNativeLibraryTrack(
      live,
      nativeLibraryTrack('unreadable', path: '${prefix}unreadable.flac'),
    );
    await addNativeLibraryTrack(
      live,
      nativeLibraryTrack('offline', path: '${prefix}offline%25_/keep.flac'),
    );
    await addNativeLibraryTrack(
      live,
      nativeLibraryTrack('deleted', path: '${prefix}test/deleted.flac'),
    );
    final refreshed = nativeLibraryTrack(
      'refreshed',
      path: '${prefix}offline%25_/keep.flac',
    );
    await adapter.importScanFile(
      'source',
      await scan(
        [refreshed],
        errors: 2,
        preserveMissingPaths: [
          '${prefix}offline%25_/',
          '${prefix}unreadable.flac',
        ],
      ),
      requestId: 'partial-nas',
      isCancelled: () => false,
    );
    expect(
      (await live.query('library')).map((row) => row['id']),
      unorderedEquals(['refreshed', 'unreadable', 'other']),
    );
    expect(
      (await live.query(
        'library_path_keys',
      )).map((row) => row['item_id']).toSet(),
      {'refreshed', 'unreadable', 'other'},
    );
    await cleaned();
  });

  test(
    'invalid native rows are skipped and keep their previous entries',
    () async {
      await addNativeLibraryTrack(live, nativeLibraryTrack('broken'));
      await addNativeLibraryTrack(live, nativeLibraryTrack('gone'));
      native.invalidPaths = ['/music/broken.flac'];
      final result = await adapter.importScanFile(
        'source',
        await scan([
          nativeLibraryTrack('new'),
          nativeLibraryTrack('broken-2', path: '/music/broken.flac'),
        ]),
        requestId: 'invalid-rows',
        isCancelled: () => false,
      );
      expect(result['invalid_rows'], 1);
      // The skipped file keeps its previous entry; files absent from an
      // otherwise clean scan are still removed.
      expect(
        (await live.query('library')).map((row) => row['id']),
        unorderedEquals(['new', 'broken', 'other']),
      );
      await cleaned();
    },
  );

  test(
    'incremental removes current downloads and exact source-scoped deleted paths',
    () async {
      await addNativeLibraryTrack(live, nativeLibraryTrack('unchanged'));
      await addNativeLibraryTrack(live, nativeLibraryTrack('unreadable'));
      native.incremental = [
        nativeLibraryTrack('new'),
        nativeLibraryTrack('download'),
      ];
      native.removed = [
        '/music/old.flac',
        '/music/old.flac',
        '/other/other.flac',
      ];
      native.afterStage = () async {
        await addNativeLibraryDownload(live, '/music/unchanged.flac');
        await addNativeLibraryDownload(live, '/music/download.flac');
      };
      final result = await adapter.scanIncremental(
        'source',
        '/music',
        '${root.path}/snapshot.tsv',
        isSaf: false,
        requestId: 'incremental',
        isCancelled: () => false,
      );
      expect(result['inserted'], 1);
      expect(result['skipped'], 2);
      expect(result['deleted_count'], 1);
      expect(result['skippedCount'], 3);
      expect(result['scanned_count'], 2);
      expect(result['totalFiles'], 5);
      expect((await live.query('library', orderBy: 'id')).map((r) => r['id']), [
        'new',
        'other',
        'unreadable',
      ]);
      expect(
        (await live.query(
          'library_path_keys',
        )).map((r) => r['item_id']).toSet(),
        {'new', 'other', 'unreadable'},
      );
      await cleaned();
    },
  );

  test(
    'source edit and cancellation after private commit never publish',
    () async {
      final before = await nativeLibraryDigest(live);
      var cancelled = false;
      native.afterStage = () async {
        cancelled = true;
      };
      await expectLater(
        adapter.importScanFile(
          'source',
          await scan([nativeLibraryTrack('new')]),
          requestId: 'cancel',
          isCancelled: () => cancelled,
        ),
        throwsStateError,
      );
      expect(await nativeLibraryDigest(live), before);
      native.afterStage = () => live
          .update(
            'library_sources',
            {'path': '/changed'},
            where: 'id=?',
            whereArgs: ['source'],
          )
          .then((_) {});
      await expectLater(
        adapter.importScanFile(
          'source',
          await scan([nativeLibraryTrack('new')]),
          requestId: 'source-edit',
          isCancelled: () => false,
        ),
        throwsStateError,
      );
      expect(await nativeLibraryDigest(live), before);
      await cleaned();
    },
  );

  test(
    'late owner SQL failure rolls back rows, path keys and derived lookups',
    () async {
      final before = await nativeLibraryDigest(live);
      await live.execute(
        "CREATE TRIGGER reject_new BEFORE INSERT ON library WHEN new.id='new' BEGIN SELECT RAISE(ABORT,'fixture late failure'); END",
      );
      await expectLater(
        adapter.importScanFile(
          'source',
          await scan([nativeLibraryTrack('new')]),
          requestId: 'rollback',
          isCancelled: () => false,
        ),
        throwsStateError,
      );
      expect(await nativeLibraryDigest(live), before);
      expect(
        await live.rawQuery(
          "SELECT name FROM sqlite_temp_master WHERE name LIKE 'library_private_%_selected'",
        ),
        isEmpty,
      );
      await cleaned();
    },
  );

  test(
    'cancellation during owner publication rolls back accepted rows and keys',
    () async {
      var cancelled = false;
      final before = await nativeLibraryDigest(live);
      final probed = _SqlProbe(live, live.path, (sql) {
        if (sql.startsWith('INSERT OR REPLACE INTO main.library(')) {
          cancelled = true;
        }
      });
      final candidate = LibraryNativeAdapter(
        probed,
        temporaryDirectory: root,
        nativeJobRunner: native.run,
      );
      await expectLater(
        candidate.importScanFile(
          'source',
          await scan([nativeLibraryTrack('new')]),
          requestId: 'cancel-publication',
          isCancelled: () => cancelled,
        ),
        throwsStateError,
      );
      expect(await nativeLibraryDigest(live), before);
      await cleaned();
    },
  );

  test(
    'failed preparation DETACH retains file and never invokes native',
    () async {
      final probed = _SqlProbe(live, live.path, (sql) {
        if (sql.startsWith('DETACH')) {
          throw StateError('fixture detach failure');
        }
      });
      final candidate = LibraryNativeAdapter(
        probed,
        temporaryDirectory: root,
        nativeJobRunner: native.run,
      );
      await expectLater(
        candidate.importScanFile(
          'source',
          await scan([nativeLibraryTrack('new')]),
          requestId: 'detach-prepare',
          isCancelled: () => false,
        ),
        throwsA(isA<NativeSqliteSnapshotDetachException>()),
      );
      expect(native.stagedPaths, isEmpty);
      final attached = await live.rawQuery('PRAGMA database_list');
      final stage = attached.singleWhere(
        (row) => (row['name'] as String).startsWith('native_snapshot_'),
      );
      expect(await File(stage['file'] as String).exists(), isTrue);
      await live.execute('DETACH DATABASE "${stage['name']}"');
    },
  );

  test(
    'cancellation after durable commit still returns the committed result',
    () async {
      var publishing = false;
      var cancelled = false;
      final probed = _SqlProbe(live, live.path, (sql) {
        if (sql.startsWith('INSERT OR REPLACE INTO main.library(')) {
          publishing = true;
        }
        if (publishing && sql.startsWith('DETACH')) {
          cancelled = true;
        }
      });
      final candidate = LibraryNativeAdapter(
        probed,
        temporaryDirectory: root,
        nativeJobRunner: native.run,
      );
      final result = await candidate.importScanFile(
        'source',
        await scan([nativeLibraryTrack('new')]),
        requestId: 'cancel-after-commit',
        isCancelled: () => cancelled,
      );
      expect(cancelled, isTrue);
      expect(result['durable'], isTrue);
      expect(
        (await live.query('library', orderBy: 'id')).map((row) => row['id']),
        ['new', 'other'],
      );
      await cleaned();
    },
  );

  test(
    'failed DETACH after durable publication retains stage and reports success',
    () async {
      var published = false;
      final probed = _SqlProbe(live, live.path, (sql) {
        if (sql.startsWith('INSERT OR REPLACE INTO main.library(')) {
          published = true;
        }
        if (published && sql.startsWith('DETACH')) {
          throw StateError('fixture postcommit detach failure');
        }
      });
      final candidate = LibraryNativeAdapter(
        probed,
        temporaryDirectory: root,
        nativeJobRunner: native.run,
      );
      final result = await candidate.importScanFile(
        'source',
        await scan([nativeLibraryTrack('new')]),
        requestId: 'detach-publish',
        isCancelled: () => false,
      );
      expect(result['durable'], isTrue);
      expect((await live.query('library', orderBy: 'id')).map((r) => r['id']), [
        'new',
        'other',
      ]);
      expect(await File(native.stagedPaths.single).exists(), isTrue);
      final stage = (await live.rawQuery('PRAGMA database_list')).singleWhere(
        (row) => (row['name'] as String).startsWith('library_private_'),
      );
      await live.execute('DETACH DATABASE "${stage['name']}"');
    },
  );

  test(
    'timestamp snapshot retains sentinels and only backfills still missing eligible live rows',
    () async {
      for (final id in ['zero', 'changed', 'legacy']) {
        await addNativeLibraryTrack(
          live,
          nativeLibraryTrack(id, timestamp: 0, version: id == 'legacy' ? 3 : 4),
        );
      }
      native.afterStage = () async {
        await live.update(
          'library',
          {'file_mod_time': 777, 'sort_added': 777},
          where: 'id=?',
          whereArgs: ['changed'],
        );
        await live.update(
          'library',
          {'file_mod_time': 0},
          where: 'id=?',
          whereArgs: ['old'],
        );
      };
      final path = await adapter.writeFileModTimesSnapshot(
        'source',
        requestId: 'snapshot',
        isCancelled: () => false,
      );
      expect(await File(path).readAsLines(), [
        '999\t/music/changed.flac',
        '-1\t/music/legacy.flac',
        '1770000000000\t/music/old.flac',
        '999\t/music/zero.flac',
      ]);
      final rows = await live.query(
        'library',
        columns: ['id', 'file_mod_time'],
        orderBy: 'id',
      );
      expect(rows, [
        {'id': 'changed', 'file_mod_time': 777},
        {'id': 'legacy', 'file_mod_time': 0},
        {'id': 'old', 'file_mod_time': 0},
        {'id': 'other', 'file_mod_time': 1770000000000},
        {'id': 'zero', 'file_mod_time': 999},
      ]);
      await cleaned();
    },
  );

  test(
    'timestamp preparation DETACH failure retains projection and never invokes native',
    () async {
      final probed = _SqlProbe(live, live.path, (sql) {
        if (sql.startsWith('DETACH')) {
          throw StateError('fixture timestamp preparation detach failure');
        }
      });
      final candidate = LibraryNativeAdapter(
        probed,
        temporaryDirectory: root,
        nativeJobRunner: native.run,
      );
      await expectLater(
        candidate.writeFileModTimesSnapshot(
          'source',
          requestId: 'timestamp-detach-prepare',
          isCancelled: () => false,
        ),
        throwsA(isA<NativeSqliteSnapshotDetachException>()),
      );
      expect(native.stagedPaths, isEmpty);
      final stage = (await live.rawQuery('PRAGMA database_list')).singleWhere(
        (row) => (row['name'] as String).startsWith('library_private_'),
      );
      expect(await File(stage['file'] as String).exists(), isTrue);
      await live.execute('DETACH DATABASE "${stage['name']}"');
    },
  );

  test(
    'timestamp publication DETACH failure retains projection and returns durable snapshot',
    () async {
      await addNativeLibraryTrack(
        live,
        nativeLibraryTrack('zero', timestamp: 0),
      );
      var published = false;
      final probed = _SqlProbe(live, live.path, (sql) {
        if (sql.startsWith('UPDATE main.library SET file_mod_time')) {
          published = true;
        }
        if (published && sql.startsWith('DETACH')) {
          throw StateError('fixture timestamp postcommit detach failure');
        }
      });
      final candidate = LibraryNativeAdapter(
        probed,
        temporaryDirectory: root,
        nativeJobRunner: native.run,
      );
      final output = await candidate.writeFileModTimesSnapshot(
        'source',
        requestId: 'timestamp-detach-publish',
        isCancelled: () => false,
      );
      expect(await File(output).exists(), isTrue);
      expect(
        (await live.query(
          'library',
          where: 'id=?',
          whereArgs: ['zero'],
        )).single['file_mod_time'],
        999,
      );
      expect(await File(native.stagedPaths.single).exists(), isTrue);
      final stage = (await live.rawQuery('PRAGMA database_list')).singleWhere(
        (row) => (row['name'] as String).startsWith('library_private_'),
      );
      await live.execute('DETACH DATABASE "${stage['name']}"');
    },
  );
}
