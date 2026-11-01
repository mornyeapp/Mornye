import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import 'package:mornye/services/history_database.dart';
import 'package:mornye/services/library_cleanup.dart';
import 'package:mornye/services/platform_bridge.dart';
import 'package:mornye/services/library_schema.dart';
import 'package:mornye/services/sqlite_helpers.dart' as sqlite;
import 'package:mornye/services/sqlite_native_snapshot.dart';
import 'package:mornye/utils/logger.dart';
import 'package:mornye/utils/native_platform_name.dart';

typedef NativeLibraryJobRunner =
    Future<Map<String, dynamic>> Function(
      Map<String, dynamic> request, {
      String? requestId,
    });

final _log = AppLogger('LibraryNativeAdapter');
var _attachmentSequence = 0;

/// Native SQLite only opens detached private files. Publication uses the live
/// database's owning connection, its current History keys and existing indexes.
class LibraryNativeAdapter {
  LibraryNativeAdapter(
    this.database, {
    NativeLibraryJobRunner? nativeJobRunner,
    this.temporaryDirectory,
    String? platform,
  }) : _run = nativeJobRunner ?? PlatformBridge.runNativeDataJob,
       _platform = platform ?? nativePlatformName();

  final Database database;
  final Directory? temporaryDirectory;
  final NativeLibraryJobRunner _run;
  final String _platform;
  final _retainedPaths = <String>{};

  static void _check(bool Function() isCancelled) {
    if (isCancelled()) throw StateError('Library scan cancelled');
  }

  Future<String> _sourcePath(DatabaseExecutor db, String sourceId) async {
    final rows = await db.query(
      'library_sources',
      columns: ['path', 'enabled'],
      where: 'id = ?',
      whereArgs: [sourceId],
      limit: 1,
    );
    if (rows.isEmpty || rows.single['enabled'] != 1) {
      throw StateError('Library source changed or was removed during scan');
    }
    return rows.single['path'] as String;
  }

  Future<void> _checkSource(
    DatabaseExecutor db,
    String sourceId,
    String path,
  ) async {
    if (await _sourcePath(db, sourceId) != path) {
      throw StateError('Library source changed or was removed during scan');
    }
  }

  Future<T> _attached<T>(
    String path,
    Future<T> Function(String alias) action, {
    bool publication = false,
  }) async {
    final alias = 'library_private_${_attachmentSequence++}';
    await database.execute('ATTACH DATABASE ? AS $alias', [path]);
    var completed = false;
    try {
      final result = await action(alias);
      completed = true;
      return result;
    } finally {
      // A successful live commit must never be reported as a cancelled or
      // failed scan merely because temporary-file cleanup failed afterward.
      try {
        await database.execute('DETACH DATABASE $alias');
      } catch (error) {
        _retainedPaths.add(path);
        _log.w('Could not detach private Library database: $error');
        if (!publication || !completed) {
          throw NativeSqliteSnapshotDetachException(path, error);
        }
      }
    }
  }

  Future<Directory> _workingDirectory() async =>
      (temporaryDirectory ?? await getTemporaryDirectory()).createTemp(
        'library-native-',
      );

  Future<void> _cleanup(Directory directory) async {
    if (_retainedPaths.any((path) => p.isWithin(directory.path, path))) return;
    // Also covers DETACH errors from the shared schema-cloning helper.
    try {
      final attached = await database.rawQuery('PRAGMA database_list');
      if (attached.any((row) => p.isWithin(directory.path, '${row['file']}'))) {
        _log.w('Retaining private Library file that is still attached');
        return;
      }
    } catch (error) {
      _log.w('Could not verify private Library detachment: $error');
      return;
    }
    try {
      await directory.delete(recursive: true);
    } catch (error) {
      _log.w('Could not remove private Library staging: $error');
    }
  }

  Map<String, dynamic> _request(
    String sourceId,
    String sourcePath,
    Directory directory,
  ) => {
    'library_path': p.join(directory.path, 'local_library.db'),
    'history_path': p.join(directory.path, 'history.db'),
    'source_id': sourceId,
    'expected_source_path': sourcePath,
    'platform': _platform,
  };

  Future<void> _prepareImport(
    String sourceId,
    String sourcePath,
    Directory directory,
    bool Function() isCancelled,
  ) async {
    await createNativeSqliteSnapshot(
      database,
      p.join(directory.path, 'local_library.db'),
      tables: ['library', 'library_path_keys', 'library_sources'],
      version: LibrarySchema.version,
      copyRows: false,
    );
    _check(isCancelled);
    await _attached(p.join(directory.path, 'local_library.db'), (alias) async {
      await sqlite.transactionWithBusyRetry(database, (txn) async {
        await _checkSource(txn, sourceId, sourcePath);
        _check(isCancelled);
        await txn.execute(
          'INSERT INTO $alias.library_sources SELECT * FROM main.library_sources '
          'WHERE id = ?',
          [sourceId],
        );
      });
    });
    // Retain every candidate during staging. Downloads can change while native
    // work runs; the authoritative anti-join belongs to live publication.
    await _attached(p.join(directory.path, 'history.db'), (alias) async {
      await database.execute(
        'CREATE TABLE $alias.history_path_keys('
        'item_id TEXT NOT NULL, path_key TEXT NOT NULL, '
        'PRIMARY KEY(item_id, path_key))',
      );
      await database.execute(
        'PRAGMA $alias.user_version = ${HistoryDatabase.schemaVersion}',
      );
    });
  }

  Future<Map<String, dynamic>> importScanFile(
    String sourceId,
    LibraryScanNDJSONFile scan, {
    required String requestId,
    required bool Function() isCancelled,
  }) => _import(
    sourceId,
    {
      'operation': 'library_full_import',
      'ndjson_path': scan.file.path,
      'expected_count': scan.expectedCount,
      'error_count': scan.errorCount,
    },
    incremental: false,
    preserveMissing: scan.errorCount > 0,
    preserveMissingPaths: scan.preserveMissingPaths,
    requestId: requestId,
    isCancelled: isCancelled,
  );

  Future<Map<String, dynamic>> scanIncremental(
    String sourceId,
    String folderPath,
    String snapshotPath, {
    required bool isSaf,
    required String requestId,
    required bool Function() isCancelled,
  }) => _import(
    sourceId,
    {
      'operation': 'library_scan_incremental',
      if (isSaf) 'tree_uri': folderPath else 'folder_path': folderPath,
      'snapshot_path': snapshotPath,
      'retain_removed_paths': true,
    },
    incremental: true,
    preserveMissing: true,
    requestId: requestId,
    isCancelled: isCancelled,
  );

  Future<Map<String, dynamic>> _import(
    String sourceId,
    Map<String, dynamic> operation, {
    required bool incremental,
    required bool preserveMissing,
    List<String>? preserveMissingPaths,
    required String requestId,
    required bool Function() isCancelled,
  }) async {
    _check(isCancelled);
    final sourcePath = await _sourcePath(database, sourceId);
    final directory = await _workingDirectory();
    try {
      await _prepareImport(sourceId, sourcePath, directory, isCancelled);
      _check(isCancelled);
      final result = await _run({
        ..._request(sourceId, sourcePath, directory),
        ...operation,
      }, requestId: requestId);
      if (result['committed'] != true) {
        throw StateError('Native Library staging did not complete');
      }
      // Rows the native staging could not encode are skipped, not fatal. Log
      // them and keep their previous entries, as for a platform read error.
      final invalidRows = (result['invalid_rows'] as num?)?.toInt() ?? 0;
      final invalidPaths =
          (result['invalid_row_paths'] as List<dynamic>?)
              ?.whereType<String>()
              .toList() ??
          const <String>[];
      if (invalidRows > 0) {
        _log.e(
          'Skipped $invalidRows invalid scan row(s) for $sourceId: '
          '${result['invalid_row_error']}',
        );
      }
      final protectedPaths =
          preserveMissingPaths ?? (preserveMissing ? null : const <String>[]);
      // Native committed:true only describes the private artifact. Cancellation
      // still prevents publication until the owner's transaction commits.
      _check(isCancelled);
      return await _publish(
        sourceId,
        sourcePath,
        p.join(directory.path, 'local_library.db'),
        result,
        incremental: incremental,
        preserveMissing: preserveMissing || invalidPaths.isNotEmpty,
        preserveMissingPaths: protectedPaths == null
            ? null
            : [...protectedPaths, ...invalidPaths],
        isCancelled: isCancelled,
      );
    } on NativeSqliteSnapshotDetachException catch (error) {
      _retainedPaths.add(error.path);
      rethrow;
    } finally {
      await _cleanup(directory);
    }
  }

  Future<Map<String, dynamic>> _publish(
    String sourceId,
    String sourcePath,
    String privatePath,
    Map<String, dynamic> nativeResult, {
    required bool incremental,
    required bool preserveMissing,
    List<String>? preserveMissingPaths,
    required bool Function() isCancelled,
  }) => _attached(privatePath, (alias) async {
    return sqlite.transactionWithBusyRetry(database, (txn) async {
      _check(isCancelled);
      await _checkSource(txn, sourceId, sourcePath);
      final columns = (await txn.rawQuery(
        'PRAGMA main.table_info(library)',
      )).map((column) => '"${column['name']}"').join(', ');
      final historyMatch =
          'EXISTS(SELECT 1 FROM $alias.library_path_keys sk '
          'JOIN history_db.history_path_keys hk ON hk.path_key = sk.path_key '
          'WHERE sk.item_id = s.id)';
      Future<int> count(String sql, [List<Object?>? args]) async =>
          ((await txn.rawQuery(sql, args)).single.values.single as num).toInt();
      final staged = await count('SELECT COUNT(*) FROM $alias.library');
      final skipped = await count(
        'SELECT COUNT(*) FROM $alias.library s WHERE $historyMatch',
      );
      var excludedExisting = 0;
      var deleted = 0;
      final selectedIds = '${alias}_selected';
      await txn.execute('CREATE TEMP TABLE $selectedIds(id TEXT PRIMARY KEY)');
      Future<int> deleteWhere(String where, List<Object?> args) async {
        // Some predicates read the path-key table being deleted. Freeze the
        // selected IDs first so both deletes apply to the same set.
        await txn.execute('DELETE FROM $selectedIds');
        await txn.execute(
          'INSERT INTO $selectedIds SELECT id FROM main.library WHERE $where',
          args,
        );
        await txn.rawDelete(
          'DELETE FROM main.library_path_keys WHERE item_id IN('
          'SELECT id FROM $selectedIds)',
        );
        return txn.rawDelete(
          'DELETE FROM main.library WHERE id IN(SELECT id FROM $selectedIds)',
        );
      }

      if (incremental) {
        excludedExisting += await deleteWhere(
          'source_id = ? AND EXISTS(SELECT 1 FROM main.library_path_keys lk '
          'JOIN history_db.history_path_keys hk ON hk.path_key = lk.path_key '
          'WHERE lk.item_id = library.id)',
          [sourceId],
        );
        _check(isCancelled);
        deleted = await deleteWhere(
          'source_id = ? AND file_path IN('
          'SELECT path FROM $alias.native_library_removed_paths)',
          [sourceId],
        );
        excludedExisting += await deleteWhere(
          'source_id = ? AND file_path IN(SELECT s.file_path '
          'FROM $alias.library s WHERE $historyMatch)',
          [sourceId],
        );
      } else {
        final predicate = libraryScanReplacementPredicate(
          sourceId,
          stageTable: '$alias.library',
          preserveMissing: preserveMissing,
          preserveMissingPaths: preserveMissingPaths,
        );
        await deleteWhere(predicate.where, predicate.args);
      }
      _check(isCancelled);
      await txn.rawDelete(
        'DELETE FROM main.library_path_keys WHERE item_id IN('
        'SELECT s.id FROM $alias.library s WHERE NOT $historyMatch)',
      );
      await txn.execute(
        'INSERT OR REPLACE INTO main.library($columns) '
        'SELECT $columns FROM $alias.library s WHERE NOT $historyMatch '
        'ORDER BY s.rowid',
      );
      await txn.execute(
        'INSERT OR IGNORE INTO main.library_path_keys '
        'SELECT sk.item_id, sk.path_key FROM $alias.library_path_keys sk '
        'JOIN $alias.library s ON s.id = sk.item_id WHERE NOT $historyMatch',
      );
      await txn.execute('DROP TABLE $selectedIds');
      _check(isCancelled);
      return {
        ...nativeResult,
        'committed': true,
        'durable': true,
        'inserted': staged - skipped,
        'upserted': staged - skipped,
        'skipped': skipped + excludedExisting,
        'deleted_count': deleted,
      };
    }, exclusive: true);
  }, publication: true);

  Future<String> writeFileModTimesSnapshot(
    String sourceId, {
    required String requestId,
    required bool Function() isCancelled,
  }) async {
    _check(isCancelled);
    final sourcePath = await _sourcePath(database, sourceId);
    final directory = await _workingDirectory();
    final output = File('${directory.path}.tsv');
    var published = false;
    try {
      final privatePath = p.join(directory.path, 'local_library.db');
      await _attached(privatePath, (alias) async {
        await sqlite.transactionWithBusyRetry(database, (txn) async {
          await _checkSource(txn, sourceId, sourcePath);
          _check(isCancelled);
          await txn.execute(
            'CREATE TABLE $alias.library AS SELECT id, source_id, file_path, '
            'file_mod_time, audio_metadata_scan_version, sort_added '
            'FROM main.library WHERE source_id = ?',
            [sourceId],
          );
          await txn.execute(
            'CREATE TABLE $alias.library_sources AS SELECT id, path, enabled '
            'FROM main.library_sources WHERE id = ?',
            [sourceId],
          );
          await txn.execute(
            'CREATE TABLE $alias.native_library_timestamp_candidates AS '
            'SELECT file_path FROM $alias.library '
            'WHERE COALESCE(file_mod_time, 0) = 0 '
            'AND audio_metadata_scan_version >= 4',
          );
          await txn.execute(
            'CREATE INDEX $alias.native_library_timestamp_path '
            'ON native_library_timestamp_candidates(file_path)',
          );
          await txn.execute(
            'CREATE INDEX $alias.native_library_snapshot_path '
            'ON library(file_path)',
          );
          await txn.execute(
            'CREATE INDEX $alias.native_library_snapshot_id '
            'ON library(source_id, id)',
          );
          await txn.execute(
            'PRAGMA $alias.user_version = ${LibrarySchema.version}',
          );
        });
      });
      _check(isCancelled);
      final result = await _run({
        ..._request(sourceId, sourcePath, directory),
        'operation': 'library_snapshot',
        'snapshot_path': output.path,
      }, requestId: requestId);
      if (result['committed'] != true || result['path'] != output.path) {
        throw StateError('Native Library snapshot did not complete');
      }
      _check(isCancelled);
      await _attached(privatePath, (alias) async {
        await sqlite.transactionWithBusyRetry(database, (txn) async {
          _check(isCancelled);
          await _checkSource(txn, sourceId, sourcePath);
          final timestamp =
              '(SELECT s.file_mod_time FROM $alias.library s '
              'JOIN $alias.native_library_timestamp_candidates c '
              'ON c.file_path = s.file_path '
              'WHERE s.file_path = library.file_path AND s.file_mod_time > 0)';
          await txn.rawUpdate(
            'UPDATE main.library SET file_mod_time = $timestamp, '
            'sort_added = $timestamp WHERE source_id = ? '
            'AND COALESCE(file_mod_time, 0) = 0 '
            'AND audio_metadata_scan_version >= 4 AND $timestamp IS NOT NULL',
            [sourceId],
          );
          _check(isCancelled);
        }, exclusive: true);
      }, publication: true);
      published = true;
      return output.path;
    } on NativeSqliteSnapshotDetachException catch (error) {
      _retainedPaths.add(error.path);
      rethrow;
    } finally {
      await _cleanup(directory);
      if (!published && await output.exists()) await output.delete();
    }
  }
}
