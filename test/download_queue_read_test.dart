import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';
import 'package:mornye/services/app_state_database.dart';

import 'support/sqlite_process_database.dart';

class _Reads {
  int transactions = 0;
  final sizes = <int>[];
  final batchSizes = <int>[];
  final valueSizes = <int>[];
  final statements = <String>[];
  String? legacyVersion;
}

class _RecordingBatch implements Batch {
  _RecordingBatch(this.batch, this.reads);
  final Batch batch;
  final _Reads reads;
  int size = 0;

  @override
  void insert(
    String table,
    Map<String, Object?> values, {
    String? nullColumnHack,
    ConflictAlgorithm? conflictAlgorithm,
  }) {
    size++;
    batch.insert(
      table,
      values,
      nullColumnHack: nullColumnHack,
      conflictAlgorithm: conflictAlgorithm,
    );
  }

  @override
  void delete(String table, {String? where, List<Object?>? whereArgs}) {
    size++;
    batch.delete(table, where: where, whereArgs: whereArgs);
  }

  @override
  Future<List<Object?>> commit({
    bool? exclusive,
    bool? noResult,
    bool? continueOnError,
  }) {
    reads.batchSizes.add(size);
    return batch.commit(
      exclusive: exclusive,
      noResult: noResult,
      continueOnError: continueOnError,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _RecordingTransaction implements Transaction {
  _RecordingTransaction(this.transaction, this.reads);
  final Transaction transaction;
  final _Reads reads;

  @override
  Batch batch() => _RecordingBatch(transaction.batch(), reads);

  @override
  Future<List<Map<String, Object?>>> rawQuery(
    String sql, [
    List<Object?>? arguments,
  ]) async {
    final rows = await transaction.rawQuery(sql, arguments);
    if (sql.contains('sqlite_master')) {
      if (reads.legacyVersion != null && rows.isNotEmpty) {
        return [
          {'version': reads.legacyVersion},
        ];
      }
    } else {
      reads.sizes.add(rows.length);
      reads.statements.add(sql);
    }
    return rows;
  }

  @override
  Future<int> rawInsert(String sql, [List<Object?>? arguments]) {
    reads.valueSizes.add((arguments?.length ?? 0) ~/ 5);
    return transaction.rawInsert(sql, arguments);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _RecordingDatabase implements Database {
  _RecordingDatabase(this.database, this.reads);
  @override
  final Database database;
  final _Reads reads;

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
  }) async {
    final rows = await database.query(
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
    reads.sizes.add(rows.length);
    return rows;
  }

  @override
  Future<T> transaction<T>(
    Future<T> Function(Transaction txn) action, {
    bool? exclusive,
  }) {
    reads.transactions++;
    return database.transaction(
      (txn) => action(_RecordingTransaction(txn, reads)),
      exclusive: exclusive,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<SqliteProcessDatabase> fixture(int count) async {
    final database = await SqliteProcessDatabase.open();
    addTearDown(database.close);
    await database.execute('''
      CREATE TABLE download_queue_items (
        id TEXT PRIMARY KEY,
        item_json TEXT NOT NULL,
        status TEXT NOT NULL,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      )
    ''');
    await database.execute(
      'CREATE INDEX idx_download_queue_items_created ON download_queue_items(created_at ASC)',
    );
    await database.execute(
      'CREATE INDEX idx_download_queue_items_status ON download_queue_items(status)',
    );
    await database.transaction((txn) async {
      for (var index = 0; index < count; index++) {
        await txn.insert('download_queue_items', {
          'id': 'queue:${count - index}',
          'item_json': '{"fixture":$index}',
          'status': 'queued',
          // Identical timestamps exercise rowid tie-breaking across pages.
          'created_at': index % 3 == 0 ? '' : '2026-10-07T00:00:00.000Z',
          'updated_at': '2026-10-07',
        });
      }
    });
    return database;
  }

  test(
    'small queues keep a single bounded query without a transaction',
    () async {
      final database = await fixture(256);
      for (final size in [0, 1, 16, 63, 256]) {
        await database.execute(
          'UPDATE download_queue_items SET status = CASE WHEN rowid <= ? THEN ? ELSE ? END',
          [size, 'queued', 'completed'],
        );
        final reads = _Reads();
        final rows = await AppStateDatabase.instance
            .getPendingDownloadQueueRows(
              databaseOverride: _RecordingDatabase(database, reads),
            );
        expect(rows, hasLength(size));
        expect(reads.sizes, [size]);
        expect(reads.transactions, 0);
        expect(rows.every((row) => !row.containsKey('__queue_order')), isTrue);
      }
    },
  );

  test(
    'large pages preserve SQLite order, ties, statuses, and exact row data',
    () async {
      final database = await fixture(2100);
      await database.execute('''
      UPDATE download_queue_items SET status =
        CASE rowid % 6
          WHEN 0 THEN 'completed'
          WHEN 1 THEN 'failed'
          WHEN 2 THEN 'queued'
          WHEN 3 THEN 'skipped'
          WHEN 4 THEN 'downloading'
          ELSE 'finalizing'
        END
    ''');
      final expected = await database.query(
        'download_queue_items',
        where: 'status IN (?, ?, ?, ?, ?)',
        whereArgs: ['queued', 'downloading', 'finalizing', 'skipped', 'failed'],
        orderBy: 'created_at ASC, rowid ASC',
      );
      final reads = _Reads();
      final actual = await AppStateDatabase.instance
          .getPendingDownloadQueueRows(
            databaseOverride: _RecordingDatabase(database, reads),
          );
      expect(actual, expected);
      expect(actual, hasLength(1750));
      expect(reads.transactions, 1);
      expect(reads.sizes.first, 257);
      expect(reads.sizes.skip(1).every((size) => size <= 256), isTrue);
      expect(reads.sizes.skip(1).reduce((a, b) => a + b), actual.length);
      expect(actual.map((row) => row['id']).toSet().length, actual.length);
    },
  );

  test(
    'bulk changes bound batches but keep delete/upsert order and one transaction',
    () async {
      final database = await fixture(700);
      final existing = await database.query(
        'download_queue_items',
        orderBy: 'rowid ASC',
      );
      final deleted = existing
          .take(550)
          .map((row) => row['id'] as String)
          .toList();
      final upserts = <Map<String, dynamic>>[
        for (var index = 0; index < 700; index++)
          {
            'id': 'new:$index',
            'item_json': '{"value":$index}',
            'status': 'queued',
            'created_at': '2026-10-07',
            'updated_at': '2026-10-07',
          },
      ];
      final reads = _Reads();
      await AppStateDatabase.instance.applyPendingDownloadQueueChanges(
        upserts: upserts,
        deletedIds: deleted,
        databaseOverride: _RecordingDatabase(database, reads),
      );
      expect(reads.transactions, 1);
      expect(reads.batchSizes, [256, 256, 38]);
      expect(reads.valueSizes, [192, 192, 192, 124]);
      final actual = await database.query(
        'download_queue_items',
        orderBy: 'rowid ASC',
      );
      expect(actual, [...existing.skip(550), ...upserts]);
    },
  );

  test(
    'older SQLite and databases without the created index retain row parity',
    () async {
      for (final withoutIndex in [false, true]) {
        final database = await fixture(700);
        if (withoutIndex) {
          await database.execute('DROP INDEX idx_download_queue_items_created');
        }
        final expected = await database.query(
          'download_queue_items',
          orderBy: 'created_at ASC, rowid ASC',
        );
        final reads = _Reads()..legacyVersion = '3.9.2';
        final actual = await AppStateDatabase.instance
            .getPendingDownloadQueueRows(
              databaseOverride: _RecordingDatabase(database, reads),
            );
        expect(actual, expected);
        expect(reads.sizes, [257, 256, 256, 188]);
        expect(reads.statements.last.contains('(created_at, rowid) >'), false);
        expect(reads.statements.last.contains('INDEXED BY'), !withoutIndex);
        expect(
          reads.statements.last.contains('AND created_at >= ?'),
          !withoutIndex,
        );
      }
    },
  );

  test(
    'small writes retain one ordinary batch without VALUES statements',
    () async {
      final database = await fixture(63);
      final rows = await database.query('download_queue_items');
      final reads = _Reads();
      await AppStateDatabase.instance.applyPendingDownloadQueueChanges(
        upserts: rows,
        deletedIds: const [],
        databaseOverride: _RecordingDatabase(database, reads),
      );
      expect(reads.transactions, 1);
      expect(reads.batchSizes, [63]);
      expect(reads.valueSizes, isEmpty);
      expect(await database.query('download_queue_items'), rows);
    },
  );

  test(
    'VALUES chunks match replacement order and mixed raw maps exactly',
    () async {
      final actualDatabase = await fixture(3);
      final oracleDatabase = await fixture(3);
      for (final database in [actualDatabase, oracleDatabase]) {
        await database.execute(
          'ALTER TABLE download_queue_items ADD COLUMN fixture_extra TEXT DEFAULT NULL',
        );
      }
      final upserts = <Map<String, dynamic>>[
        for (var index = 0; index < 700; index++)
          {
            // Duplicates within and across 192-row statement boundaries must
            // match the former sequential INSERT OR REPLACE rowid behavior.
            'updated_at': '2026-10-07',
            'created_at': '2026-10-07',
            'status': 'queued',
            'item_json': '{"value":$index}',
            'id': index % 192 < 2 ? 'duplicate' : 'new:$index',
            if (index == 383) 'fixture_extra': 'raw metadata 日本語',
          },
      ];
      const deletions = ['queue:2', 'duplicate'];
      await oracleDatabase.transaction((txn) async {
        for (final id in deletions) {
          await txn.delete(
            'download_queue_items',
            where: 'id = ?',
            whereArgs: [id],
          );
        }
        for (final row in upserts) {
          await txn.insert(
            'download_queue_items',
            row,
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
        }
      });
      final reads = _Reads();
      await AppStateDatabase.instance.applyPendingDownloadQueueChanges(
        upserts: upserts,
        deletedIds: deletions,
        databaseOverride: _RecordingDatabase(actualDatabase, reads),
      );
      expect(
        await actualDatabase.query(
          'download_queue_items',
          orderBy: 'rowid ASC',
        ),
        await oracleDatabase.query(
          'download_queue_items',
          orderBy: 'rowid ASC',
        ),
      );
      expect(reads.transactions, 1);
      expect(reads.batchSizes, [2, 1]);
      expect(reads.valueSizes, [192, 191, 192, 124]);
    },
  );

  test(
    'invalid raw maps roll back earlier canonical VALUES statements',
    () async {
      final database = await fixture(3);
      final before = await database.query('download_queue_items');
      final upserts = <Map<String, dynamic>>[
        for (var index = 0; index < 500; index++)
          {
            'id': 'new:$index',
            'item_json': '{}',
            'status': 'queued',
            'created_at': '2026-10-07',
            'updated_at': '2026-10-07',
            if (index == 499) 'unknown_column': 'cannot persist',
          },
      ];
      await expectLater(
        AppStateDatabase.instance.applyPendingDownloadQueueChanges(
          upserts: upserts,
          deletedIds: ['queue:1'],
          databaseOverride: database,
        ),
        throwsStateError,
      );
      expect(await database.query('download_queue_items'), before);
    },
  );

  test(
    'a late failed chunk rolls back preceding deletions and inserted chunks',
    () async {
      final database = await fixture(600);
      final before = await database.query(
        'download_queue_items',
        orderBy: 'rowid ASC',
      );
      await database.execute('''
      CREATE TRIGGER reject_queue BEFORE INSERT ON download_queue_items
      WHEN NEW.id = 'reject' BEGIN SELECT RAISE(ABORT, 'fixture rejection'); END
    ''');
      final upserts = <Map<String, dynamic>>[
        for (var index = 0; index < 600; index++)
          {
            'id': index == 599 ? 'reject' : 'new:$index',
            'item_json': '{}',
            'status': 'queued',
            'created_at': '2026-10-07',
            'updated_at': '2026-10-07',
          },
      ];
      await expectLater(
        AppStateDatabase.instance.applyPendingDownloadQueueChanges(
          upserts: upserts,
          deletedIds: before.map((row) => row['id'] as String).toList(),
          databaseOverride: database,
        ),
        throwsStateError,
      );
      expect(
        await database.query('download_queue_items', orderBy: 'rowid ASC'),
        before,
      );
      await database.execute('DROP TRIGGER reject_queue');
      await AppStateDatabase.instance.applyPendingDownloadQueueChanges(
        upserts: upserts,
        deletedIds: before.map((row) => row['id'] as String).toList(),
        databaseOverride: database,
      );
      expect(
        await database.query('download_queue_items', orderBy: 'rowid ASC'),
        upserts,
      );
    },
  );
}
