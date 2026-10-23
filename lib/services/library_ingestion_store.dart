import 'package:sqflite/sqflite.dart';
import 'package:mornye/services/library_cleanup.dart';
import 'package:mornye/services/library_native_adapter.dart';
import 'package:mornye/services/library_row_mapper.dart';
import 'package:mornye/services/platform_bridge.dart';
import 'package:mornye/services/sqlite_helpers.dart' as sqlite;
import 'package:mornye/utils/logger.dart';

final _log = AppLogger('LibraryDatabase');

/// Scan and incremental ingestion writes. The connection and the lazy
/// History attachment stay owned by LibraryDatabase and are passed in.
class LibraryIngestionStore {
  static const String _scanStageTable = 'library_scan_stage';
  static const String _scanStagePathKeysTable = 'library_scan_path_keys_stage';
  static const String _incrementalStageTable = 'library_incremental_stage';
  static const String _incrementalStagePathKeysTable =
      'library_incremental_path_keys_stage';
  static const String _downloadedLibraryIdsStageTable =
      'library_downloaded_ids_stage';

  final Future<Database> Function() _openDatabase;
  final Future<void> Function(Database db) _attachHistory;

  LibraryIngestionStore({
    required Future<Database> Function() openDatabase,
    required Future<void> Function(Database db) ensureHistoryAttached,
  }) : _openDatabase = openDatabase,
       _attachHistory = ensureHistoryAttached;

  Future<Database> get database => _openDatabase();

  Future<void> _ensureHistoryAttached(Database db) => _attachHistory(db);

  /// The scanner requests at most one small listing batch at a time.
  Future<Map<String, Map<String, dynamic>>> readNetworkScanRows(
    String sourceId,
    List<String> paths,
  ) async {
    if (paths.isEmpty) return {};
    if (paths.length > 64) throw ArgumentError('Too many network scan paths');
    final db = await database;
    // Without statistics SQLite can prefer source_id and revisit every track
    // in the source for each batch. Seek only the requested paths instead.
    final rows = await db.rawQuery(
      'SELECT * FROM library INDEXED BY idx_library_file_path '
      'WHERE source_id = ? '
      'AND file_path IN (${List.filled(paths.length, '?').join(',')})',
      [sourceId, ...paths],
    );
    return {
      for (final row in rows)
        row['file_path'] as String: LibraryRowMapper.decode(row),
    };
  }

  /// Keeps native scan output native through parsing, indexing and the atomic
  /// source swap. The stream implementation remains the desktop/test adapter.
  Future<({int inserted, int skipped})> replaceSourceScanFile(
    String sourceId,
    LibraryScanNDJSONFile scan, {
    required String requestId,
    required bool Function() isCancelled,
  }) async {
    if (isCancelled()) throw StateError('Library scan cancelled');
    if (PlatformBridge.supportsCoreBackend) {
      final db = await database;
      await _ensureHistoryAttached(db);
      final result = await LibraryNativeAdapter(db).importScanFile(
        sourceId,
        scan,
        requestId: requestId,
        isCancelled: isCancelled,
      );
      return (
        inserted: (result['inserted'] as num).toInt(),
        skipped: (result['skipped'] as num).toInt(),
      );
    }
    Stream<Map<String, dynamic>> validatedRows() async* {
      var count = 0;
      await for (final row in scan.rows()) {
        if (isCancelled()) {
          throw StateError('Library scan cancelled during ingestion');
        }
        count++;
        yield row;
      }
      if (count != scan.expectedCount) {
        throw FormatException(
          'Library scan row count mismatch: decoded $count, '
          'expected ${scan.expectedCount}',
        );
      }
    }

    return replaceSourceStream(
      sourceId,
      validatedRows(),
      preserveMissing: scan.errorCount > 0,
      preserveMissingPaths: scan.preserveMissingPaths,
    );
  }

  /// Native folder scanning and delta ingestion share one operation, so delta
  /// track maps never return to Flutter. SAF traversal stays in its OS adapter.
  Future<Map<String, dynamic>> scanIncrementalNative(
    String sourceId,
    String folderPath,
    String snapshotPath, {
    required bool isSaf,
    required String requestId,
    required bool Function() isCancelled,
  }) async {
    final db = await database;
    await _ensureHistoryAttached(db);
    return LibraryNativeAdapter(db).scanIncremental(
      sourceId,
      folderPath,
      snapshotPath,
      isSaf: isSaf,
      requestId: requestId,
      isCancelled: isCancelled,
    );
  }

  /// Removes rows from one source whose normalized path keys already exist in
  /// download History, without materializing either database's paths in Dart.
  Future<int> deleteDownloadedRowsForSource(String sourceId) async {
    final db = await database;
    await _ensureHistoryAttached(db);
    const downloadedMatch = '''
      EXISTS (
        SELECT 1
        FROM library_path_keys lk
        JOIN history_db.history_path_keys hk ON hk.path_key = lk.path_key
        WHERE lk.item_id = library.id
      )
    ''';
    await db.execute('DROP TABLE IF EXISTS $_downloadedLibraryIdsStageTable');
    await db.execute(
      'CREATE TEMP TABLE $_downloadedLibraryIdsStageTable '
      '(id TEXT PRIMARY KEY)',
    );
    try {
      await db.rawInsert(
        'INSERT INTO $_downloadedLibraryIdsStageTable(id) '
        'SELECT id FROM library '
        'WHERE source_id = ? AND $downloadedMatch',
        [sourceId],
      );
      final countRows = await db.rawQuery(
        'SELECT COUNT(*) AS count FROM $_downloadedLibraryIdsStageTable',
      );
      final count = Sqflite.firstIntValue(countRows) ?? 0;
      if (count == 0) return 0;

      await sqlite.transactionWithBusyRetry(db, (txn) async {
        await txn.rawDelete(
          'DELETE FROM library_path_keys WHERE item_id IN '
          '(SELECT id FROM $_downloadedLibraryIdsStageTable)',
        );
        await txn.rawDelete(
          'DELETE FROM library WHERE id IN '
          '(SELECT id FROM $_downloadedLibraryIdsStageTable)',
        );
      });
      return count;
    } finally {
      await db.execute('DROP TABLE IF EXISTS $_downloadedLibraryIdsStageTable');
    }
  }

  /// Upserts incremental scan rows after filtering them through the attached
  /// History path-key index. This keeps the hot incremental path independent
  /// of total History size.
  Future<({int upserted, int skipped})> upsertBatchExcludingHistory(
    List<Map<String, dynamic>> items, {
    required String sourceId,
  }) async {
    if (items.isEmpty) return (upserted: 0, skipped: 0);
    final db = await database;
    await _ensureHistoryAttached(db);
    await db.execute('DROP TABLE IF EXISTS $_incrementalStageTable');
    await db.execute('DROP TABLE IF EXISTS $_incrementalStagePathKeysTable');
    await db.execute(
      'CREATE TEMP TABLE $_incrementalStageTable '
      'AS SELECT * FROM library WHERE 0',
    );
    await db.execute(
      'CREATE UNIQUE INDEX idx_${_incrementalStageTable}_id '
      'ON $_incrementalStageTable(id)',
    );
    await db.execute(
      'CREATE UNIQUE INDEX idx_${_incrementalStageTable}_path '
      'ON $_incrementalStageTable(file_path)',
    );
    await db.execute('''
      CREATE TEMP TABLE $_incrementalStagePathKeysTable (
        item_id TEXT NOT NULL,
        path_key TEXT NOT NULL,
        PRIMARY KEY (item_id, path_key)
      )
    ''');
    await db.execute(
      'CREATE INDEX idx_${_incrementalStagePathKeysTable}_key '
      'ON $_incrementalStagePathKeysTable(path_key)',
    );

    try {
      final batch = db.batch();
      final stagedIds = <String>{};
      for (final json in items) {
        final id = json['id'] as String?;
        if (id == null || id.trim().isEmpty) {
          throw const FormatException('Library scan row has no valid id');
        }
        batch.insert(
          _incrementalStageTable,
          LibraryRowMapper.encode(json, sourceId: sourceId),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
        sqlite.putPathKeysInBatch(
          batch,
          _incrementalStagePathKeysTable,
          id,
          json['filePath'] as String?,
          // The stage starts empty: only a repeated id has keys to replace.
          replaceExisting: !stagedIds.add(id),
        );
      }
      await batch.commit(noResult: true);

      const historyMatch =
          '''
        EXISTS (
          SELECT 1
          FROM $_incrementalStagePathKeysTable sk
          JOIN history_db.history_path_keys hk ON hk.path_key = sk.path_key
          WHERE sk.item_id = s.id
        )
      ''';
      final skippedRows = await db.rawQuery(
        'SELECT COUNT(*) AS count FROM $_incrementalStageTable s '
        'WHERE $historyMatch',
      );
      final skipped = Sqflite.firstIntValue(skippedRows) ?? 0;
      final stagedRows = await db.rawQuery(
        'SELECT COUNT(*) AS count FROM $_incrementalStageTable',
      );
      final staged = Sqflite.firstIntValue(stagedRows) ?? 0;
      final columns = (await db.rawQuery(
        'PRAGMA table_info(library)',
      )).map((row) => row['name'] as String).toList(growable: false);
      final columnList = columns.join(', ');
      final selectedColumns = columns.map((column) => 's.$column').join(', ');

      await sqlite.transactionWithBusyRetry(db, (txn) async {
        await txn.rawDelete('''
          DELETE FROM library_path_keys
          WHERE item_id IN (
            SELECT s.id FROM $_incrementalStageTable s WHERE NOT $historyMatch
          )
        ''');
        await txn.rawInsert('''
          INSERT OR REPLACE INTO library ($columnList)
          SELECT $selectedColumns FROM $_incrementalStageTable s
          WHERE NOT $historyMatch
        ''');
        await txn.rawInsert('''
          INSERT OR IGNORE INTO library_path_keys(item_id, path_key)
          SELECT sk.item_id, sk.path_key
          FROM $_incrementalStagePathKeysTable sk
          JOIN $_incrementalStageTable s ON s.id = sk.item_id
          WHERE NOT $historyMatch
        ''');
      });
      return (upserted: staged - skipped, skipped: skipped);
    } finally {
      await db.execute('DROP TABLE IF EXISTS $_incrementalStagePathKeysTable');
      await db.execute('DROP TABLE IF EXISTS $_incrementalStageTable');
    }
  }

  /// Stages scan rows in bounded, independently committed batches, then swaps
  /// only this source in one short transaction. Download-history exclusion is
  /// an indexed SQLite anti-join, avoiding a full History path set in Dart.
  Future<({int inserted, int skipped})> replaceSourceStream(
    String sourceId,
    Stream<Map<String, dynamic>> items, {
    int batchSize = 300,
    bool preserveMissing = false,
    List<String>? preserveMissingPaths,
  }) async {
    if (batchSize <= 0) {
      throw ArgumentError.value(batchSize, 'batchSize', 'Must be positive');
    }
    final db = await database;
    await _ensureHistoryAttached(db);
    await db.execute('DROP TABLE IF EXISTS $_scanStageTable');
    await db.execute('DROP TABLE IF EXISTS $_scanStagePathKeysTable');
    await db.execute(
      'CREATE TEMP TABLE $_scanStageTable AS SELECT * FROM library WHERE 0',
    );
    await db.execute(
      'CREATE UNIQUE INDEX idx_${_scanStageTable}_id '
      'ON $_scanStageTable(id)',
    );
    await db.execute(
      'CREATE UNIQUE INDEX idx_${_scanStageTable}_path '
      'ON $_scanStageTable(file_path)',
    );
    await db.execute('''
      CREATE TEMP TABLE $_scanStagePathKeysTable (
        item_id TEXT NOT NULL,
        path_key TEXT NOT NULL,
        PRIMARY KEY (item_id, path_key)
      )
    ''');
    await db.execute(
      'CREATE INDEX idx_${_scanStagePathKeysTable}_key '
      'ON $_scanStagePathKeysTable(path_key)',
    );

    var streamed = 0;
    try {
      var batch = db.batch();
      var pending = 0;
      Future<void> flush() async {
        if (pending == 0) return;
        await batch.commit(noResult: true);
        batch = db.batch();
        pending = 0;
      }

      final stagedIds = <String>{};
      await for (final json in items) {
        final id = json['id'] as String?;
        if (id == null || id.trim().isEmpty) {
          throw const FormatException('Library scan row has no valid id');
        }
        batch.insert(
          _scanStageTable,
          LibraryRowMapper.encode(json, sourceId: sourceId),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
        sqlite.putPathKeysInBatch(
          batch,
          _scanStagePathKeysTable,
          id,
          json['filePath'] as String?,
          // The stage starts empty: only a repeated id has keys to replace.
          replaceExisting: !stagedIds.add(id),
        );
        streamed++;
        pending++;
        if (pending >= batchSize) await flush();
      }
      await flush();

      const historyMatch =
          '''
        EXISTS (
          SELECT 1
          FROM $_scanStagePathKeysTable sk
          JOIN history_db.history_path_keys hk ON hk.path_key = sk.path_key
          WHERE sk.item_id = s.id
        )
      ''';
      final skippedRows = await db.rawQuery(
        'SELECT COUNT(*) AS count FROM $_scanStageTable s '
        'WHERE $historyMatch',
      );
      final skipped = Sqflite.firstIntValue(skippedRows) ?? 0;
      final stagedRows = await db.rawQuery(
        'SELECT COUNT(*) AS count FROM $_scanStageTable',
      );
      final staged = Sqflite.firstIntValue(stagedRows) ?? 0;
      final columns = (await db.rawQuery(
        'PRAGMA table_info(library)',
      )).map((row) => row['name'] as String).toList(growable: false);
      final columnList = columns.join(', ');
      final selectedColumns = columns.map((column) => 's.$column').join(', ');

      await sqlite.transactionWithBusyRetry(db, (txn) async {
        await deleteReplacedLibraryScanRows(
          txn,
          sourceId,
          stageTable: _scanStageTable,
          preserveMissing: preserveMissing,
          preserveMissingPaths: preserveMissingPaths,
        );
        await txn.rawDelete('''
          DELETE FROM library_path_keys
          WHERE item_id IN (
            SELECT s.id FROM $_scanStageTable s WHERE NOT $historyMatch
          )
        ''');
        await txn.rawInsert('''
          INSERT OR REPLACE INTO library ($columnList)
          SELECT $selectedColumns FROM $_scanStageTable s
          WHERE NOT $historyMatch
        ''');
        await txn.rawInsert('''
          INSERT OR IGNORE INTO library_path_keys(item_id, path_key)
          SELECT sk.item_id, sk.path_key
          FROM $_scanStagePathKeysTable sk
          JOIN $_scanStageTable s ON s.id = sk.item_id
          WHERE NOT $historyMatch
        ''');
      });
      final inserted = staged - skipped;
      _log.i(
        'Streamed $streamed rows, staged $staged unique rows, and swapped '
        '$inserted into Library source '
        '$sourceId ($skipped downloads excluded)',
      );
      return (inserted: inserted, skipped: skipped);
    } finally {
      await db.execute('DROP TABLE IF EXISTS $_scanStagePathKeysTable');
      await db.execute('DROP TABLE IF EXISTS $_scanStageTable');
    }
  }
}
