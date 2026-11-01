import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/library_schema.dart';
import 'package:mornye/services/sqlite_helpers.dart';
import 'package:mornye/utils/path_match_keys.dart';
import 'package:sqflite/sqflite.dart';

import 'support/sqlite_process_database.dart';

String _id(int index) => index.toString().padLeft(5, '0');
String _path(String id) =>
    'content://com.android.externalstorage.documents/tree/primary%3AMusic/'
    'document/primary%3AMusic%2FAlbum%2F$id.flac';

// Models the reported collection size without allocating a library-sized
// platform message. Real SQLite migration/rollback coverage is below.
class _LargeLibrary implements Database {
  static const count = 43000;
  int readCount = 0;
  int insertCount = 0;
  int maxBatchSize = 0;
  final migrated = <String>{};

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
    if (table == 'library') {
      expect(limit, isNotNull, reason: 'Migration must not read all 43k paths');
      expect(limit, lessThanOrEqualTo(500));
      expect(orderBy, 'id');
      expect(offset, isNull, reason: 'Use indexed pagination, not OFFSET');
      final start = whereArgs == null
          ? 0
          : int.parse(whereArgs.single as String) + 1;
      final end = (start + limit!).clamp(0, count);
      readCount += end - start;
      return [
        for (var i = start; i < end; i++)
          {'id': _id(i), 'file_path': _path(_id(i))},
      ];
    }
    expect(table, 'library_path_keys');
    expect(whereArgs!.length, lessThanOrEqualTo(500));
    // Existing keys already include the original URI, as in pre-v16 data.
    return [
      for (final id in whereArgs)
        {'item_id': id, 'path_key': _path(id as String)},
    ];
  }

  @override
  Batch batch() => _BoundedBatch(this);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _BoundedBatch implements Batch {
  _BoundedBatch(this.database);
  final _LargeLibrary database;
  final ids = <String>{};
  int size = 0;

  @override
  void insert(
    String table,
    Map<String, Object?> values, {
    String? nullColumnHack,
    ConflictAlgorithm? conflictAlgorithm,
  }) {
    expect(conflictAlgorithm, ConflictAlgorithm.ignore);
    ids.add(values['item_id'] as String);
    size++;
    expect(ids.length, lessThanOrEqualTo(500));
  }

  @override
  void delete(String table, {String? where, List<Object?>? whereArgs}) =>
      fail('Correct existing keys must not be rewritten');

  @override
  Future<List<Object?>> commit({
    bool? exclusive,
    bool? noResult,
    bool? continueOnError,
  }) async {
    expect(noResult, isTrue);
    expect(continueOnError, isNot(true));
    expect(database.migrated.intersection(ids), isEmpty);
    database.migrated.addAll(ids);
    database.insertCount += size;
    if (size > database.maxBatchSize) database.maxBatchSize = size;
    return [];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('43k SAF tracks migrate with bounded reads and write batches', () async {
    final db = _LargeLibrary();
    await backfillPathKeys(db, 'library', 'library_path_keys');
    final newKeysPerTrack = buildPathMatchKeys(_path(_id(0))).length - 1;
    expect(db.readCount, _LargeLibrary.count);
    expect(db.migrated.length, _LargeLibrary.count);
    expect(db.insertCount, _LargeLibrary.count * newKeysPerTrack);
    expect(db.maxBatchSize, lessThanOrEqualTo(500 * newKeysPerTrack));
  });

  for (final table in ['library', 'history']) {
    test(
      '$table migration preserves valid aliases and removes stale keys',
      () async {
        final db = await SqliteProcessDatabase.open();
        addTearDown(db.close);
        await db.execute(
          'CREATE TABLE $table(id TEXT PRIMARY KEY, file_path TEXT)',
        );
        await createPathKeyTable(db, '${table}_path_keys');
        // Cross a page boundary, include an empty id, and a row with no path.
        await db.execute('''
          WITH RECURSIVE tracks(n) AS (
            SELECT 0 UNION ALL SELECT n + 1 FROM tracks WHERE n < 502
          )
          INSERT INTO $table SELECT printf('%05d', n), '/music/' || n || '.flac'
          FROM tracks
        ''');
        await db.insert(table, {'id': '', 'file_path': _path('special')});
        await db.insert(table, {'id': 'null-path', 'file_path': null});
        await db.execute('''
          INSERT INTO ${table}_path_keys
          SELECT id, file_path FROM $table WHERE file_path IS NOT NULL
        ''');
        await db.insert('${table}_path_keys', {
          'item_id': 'null-path',
          'path_key': 'stale',
        });
        await db.insert('${table}_path_keys', {
          'item_id': '',
          'path_key': 'stale',
        });
        // An unchanged row must retain its rowid, not be deleted and reinserted.
        final original = await db.rawQuery('''
          SELECT rowid, item_id, path_key FROM ${table}_path_keys
          WHERE path_key != 'stale' ORDER BY item_id
        ''');
        await db.transaction(
          (_) => backfillPathKeys(db, table, '${table}_path_keys'),
        );
        for (final row in await db.query(table)) {
          final keys = await db.query(
            '${table}_path_keys',
            where: 'item_id = ?',
            whereArgs: [row['id']],
          );
          expect(
            keys.map((key) => key['path_key']).toSet(),
            buildPathMatchKeys(row['file_path'] as String?),
          );
        }
        for (final key in original) {
          expect(
            (await db.rawQuery(
              'SELECT rowid FROM ${table}_path_keys WHERE item_id = ? AND path_key = ?',
              [key['item_id'], key['path_key']],
            )).single['rowid'],
            key['rowid'],
          );
        }
        final before = await db.rawQuery('SELECT total_changes()');
        await backfillPathKeys(db, table, '${table}_path_keys');
        expect(await db.rawQuery('SELECT total_changes()'), before);
      },
    );
  }

  test('v14 upgrade rolls back a later-page failure and can retry', () async {
    final db = await SqliteProcessDatabase.open();
    addTearDown(db.close);
    await db.execute('''
      CREATE TABLE library(
        id TEXT PRIMARY KEY, file_path TEXT,
        source_id TEXT NOT NULL DEFAULT 'legacy', isrc TEXT,
        format TEXT, audio_metadata_scan_version INTEGER NOT NULL DEFAULT 0,
        match_key TEXT DEFAULT 'song|artist'
      )
    ''');
    await createPathKeyTable(db, 'library_path_keys');
    await db.execute('''
      WITH RECURSIVE tracks(n) AS (
        SELECT 0 UNION ALL SELECT n + 1 FROM tracks WHERE n < 502
      )
      INSERT INTO library(id, file_path)
      SELECT printf('%05d', n), '/music/' || n || '.flac' FROM tracks
    ''');
    await db.execute('PRAGMA user_version = 14');
    await db.execute('''
      CREATE TRIGGER fail_later_page BEFORE INSERT ON library_path_keys
      WHEN NEW.item_id = '00502'
      BEGIN SELECT RAISE(ABORT, 'simulated storage failure'); END
    ''');
    await expectLater(
      db.transaction((_) async {
        await LibrarySchema.upgrade(db, 14, LibrarySchema.version);
        await db.execute('PRAGMA user_version = ${LibrarySchema.version}');
      }),
      throwsA(isA<StateError>()),
    );
    expect(await db.query('library_path_keys'), isEmpty);
    expect((await db.rawQuery('PRAGMA user_version')).single.values.single, 14);
    expect(
      (await db.rawQuery(
        'PRAGMA table_info(library)',
      )).map((row) => row['name']),
      isNot(contains('has_replaygain')),
    );
    expect(
      (await db.rawQuery('SELECT COUNT(*) FROM library')).single.values.single,
      503,
    );
    await db.execute('DROP TRIGGER fail_later_page');
    await db.transaction((_) async {
      await LibrarySchema.upgrade(db, 14, LibrarySchema.version);
      await db.execute('PRAGMA user_version = ${LibrarySchema.version}');
    });
    expect(
      (await db.rawQuery('PRAGMA user_version')).single.values.single,
      LibrarySchema.version,
    );
    expect(
      (await db.rawQuery(
        'SELECT COUNT(DISTINCT item_id) FROM library_path_keys',
      )).single.values.single,
      503,
    );
    expect((await db.query(LibrarySchema.lookupSummaryTable)).single, {
      'source_id': 'legacy',
      'kind': 'match',
      'value': 'song|artist',
      'ref_count': 503,
    });
  });
}
