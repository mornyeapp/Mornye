import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/download_history.dart';
import 'package:mornye/services/history_database.dart';
import 'package:mornye/services/history_schema.dart';
import 'package:mornye/services/sqlite_helpers.dart' as sqlite;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/sqlite_process_database.dart';

/// The download engine's native writer shares history.db from another
/// process. When it (or a library merge) holds the write lock past one
/// SQLite busy timeout, the Dart history write used to surface
/// "database is locked" as a failed download. These tests prove the history
/// write paths now retry the lock instead.
void main() {
  sqfliteFfiInit();

  late Directory root;
  late Database app;
  late SqliteProcessDatabase native;

  Map<String, dynamic> historyJson(String id) => DownloadHistoryItem(
    id: id,
    trackName: 'Track $id',
    artistName: 'Artist',
    albumName: 'Album',
    filePath: '${root.path}/$id.flac',
    service: 'test',
    downloadedAt: DateTime.utc(2026, 11, 21),
  ).toJson();

  setUp(() async {
    root = await Directory.systemTemp.createTemp('history-busy-retry-');
    final path = '${root.path}/history.db';
    app = await databaseFactoryFfi.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: HistoryDatabase.schemaVersion,
        onConfigure: (db) async {
          // Mirrors openAppDatabase's production pragmas.
          await db.rawQuery('PRAGMA busy_timeout = 5000');
          await db.rawQuery('PRAGMA journal_mode = WAL');
        },
        onCreate: (db, version) async {
          await HistorySchema.create(db, version);
        },
      ),
    );
    native = await SqliteProcessDatabase.open(path: path);
    HistoryDatabase.debugReplaceDatabaseForTest(app);
  });

  tearDown(() async {
    HistoryDatabase.debugReplaceDatabaseForTest(null);
    await native.close();
    await app.close();
    await root.delete(recursive: true);
  });

  test(
    'upsert outlives a native write lock held past one busy timeout',
    () async {
      // A competing process takes the write lock for longer than the 5s
      // busy_timeout, then releases it, like a native library merge finishing.
      await native.execute('BEGIN IMMEDIATE');
      final release = Future<void>.delayed(
        const Duration(seconds: 6),
        () => native.execute('COMMIT'),
      );

      final watch = Stopwatch()..start();
      await HistoryDatabase.instance.upsert(historyJson('id-1'));
      watch.stop();
      await release;

      expect(
        watch.elapsed,
        greaterThan(const Duration(seconds: 5)),
        reason: 'the write must retry past the first busy timeout, not fail',
      );
      expect(await HistoryDatabase.instance.getById('id-1'), isNotNull);
    },
  );

  test('upsertBatch outlives the same contention', () async {
    await native.execute('BEGIN IMMEDIATE');
    final release = Future<void>.delayed(
      const Duration(seconds: 6),
      () => native.execute('COMMIT'),
    );

    await HistoryDatabase.instance.upsertBatch([
      historyJson('id-2'),
      historyJson('id-3'),
    ]);
    await release;

    expect(await HistoryDatabase.instance.getById('id-2'), isNotNull);
    expect(await HistoryDatabase.instance.getById('id-3'), isNotNull);
  });

  test(
    'pre-existing rows and path keys survive a contended batch write',
    () async {
      await HistoryDatabase.instance.upsert(historyJson('keep-1'));

      await native.execute('BEGIN IMMEDIATE');
      final release = Future<void>.delayed(
        const Duration(seconds: 6),
        () => native.execute('COMMIT'),
      );

      await HistoryDatabase.instance.upsertBatch([
        historyJson('id-4'),
        historyJson('id-5'),
      ]);
      await release;

      // Existing history row and its path-key lookup are untouched, and the
      // batch landed completely (no partial batch state).
      expect(await HistoryDatabase.instance.getById('keep-1'), isNotNull);
      expect(
        await HistoryDatabase.instance.findByFilePath(
          '${root.path}/keep-1.flac',
        ),
        isNotNull,
      );
      expect(await HistoryDatabase.instance.getById('id-4'), isNotNull);
      expect(await HistoryDatabase.instance.getById('id-5'), isNotNull);
    },
  );

  test(
    'a custom retry schedule exhausts without ever invoking the body',
    () async {
      await native.execute('BEGIN IMMEDIATE');
      var bodyRuns = 0;
      await expectLater(
        sqlite.transactionWithBusyRetry(
          app,
          (_) async => bodyRuns++,
          retryDelays: const [Duration(milliseconds: 10)],
        ),
        throwsA(isA<DatabaseException>()),
      );
      expect(bodyRuns, 0);
      await native.execute('ROLLBACK');
    },
  );

  test('a body failure mid-transaction leaves no partial writes', () async {
    await app.execute(
      'CREATE TABLE IF NOT EXISTS retry_probe (v TEXT PRIMARY KEY)',
    );
    await app.insert('retry_probe', {'v': 'keep'});

    final failure = StateError('simulated body failure');
    await expectLater(
      sqlite.transactionWithBusyRetry(app, (txn) async {
        await txn.insert('retry_probe', {'v': 'partial'});
        throw failure;
      }),
      throwsA(same(failure)),
    );

    final rows = await app.query('retry_probe');
    expect(rows.map((r) => r['v']), ['keep']);
  });

  test('writes recover immediately after contention is released', () async {
    await native.execute('BEGIN IMMEDIATE');
    final release = Future<void>.delayed(
      const Duration(seconds: 6),
      () => native.execute('COMMIT'),
    );
    await HistoryDatabase.instance.upsert(historyJson('id-6'));
    await release;

    final watch = Stopwatch()..start();
    await HistoryDatabase.instance.upsert(historyJson('id-7'));
    watch.stop();

    expect(await HistoryDatabase.instance.getById('id-7'), isNotNull);
    expect(
      watch.elapsed,
      lessThan(const Duration(seconds: 2)),
      reason: 'an uncontended write after recovery must not keep retrying',
    );
  });
}
