import 'dart:io';

import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:mornye/utils/logger.dart';
import 'package:mornye/utils/path_match_keys.dart';
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart' show databaseFactoryFfi;

final _log = AppLogger('AppSqlite');

var _ffiDatabaseFactoryInstalled = false;

/// Routes sqflite through FFI and the bundled SQLite on Windows and Linux,
/// which have no sqflite platform plugin. Mobile and macOS keep the plugin.
/// Every app database open goes through [openAppDatabase] first, so later
/// direct `openDatabase` calls also see this factory.
void ensureAppDatabaseFactory() {
  if (_ffiDatabaseFactoryInstalled || !isDesktopPlatform || Platform.isMacOS) {
    return;
  }
  databaseFactory = databaseFactoryFfi;
  _ffiDatabaseFactoryInstalled = true;
}

/// Directory that holds the app databases. Mobile keeps the documents
/// directory; desktop uses application support so the files stay out of the
/// user's Documents folder.
Future<Directory> appDatabaseDirectory() async {
  if (!isDesktopPlatform) return getApplicationDocumentsDirectory();
  final directory = await getApplicationSupportDirectory();
  await directory.create(recursive: true);
  return directory;
}

Future<bool>? _trigramFts5Capability;
const _trigramFts5ProbeTable = 'mornye_trigram_fts5_probe';

/// Caches an asynchronously-created value while also coalescing concurrent
/// callers onto the same in-flight initialization.
class SingleFlightInitializer<T extends Object> {
  T? _value;
  Future<T>? _initializing;

  Future<T> getOrCreate(Future<T> Function() create) {
    final value = _value;
    if (value != null) return Future<T>.value(value);

    final initializing = _initializing;
    if (initializing != null) return initializing;

    late final Future<T> future;
    future = Future<T>.sync(create)
        .then((value) {
          _value = value;
          return value;
        })
        .whenComplete(() {
          if (identical(_initializing, future)) {
            _initializing = null;
          }
        });
    _initializing = future;
    return future;
  }

  void reset() {
    _value = null;
  }
}

/// Opens a database file in [appDatabaseDirectory] with the shared
/// WAL + synchronous=NORMAL configuration.
Future<Database> openAppDatabase(
  String fileName, {
  required int version,
  required Future<void> Function(Database db, int version) onCreate,
  required Future<void> Function(Database db, int oldVersion, int newVersion)
  onUpgrade,
  Future<void> Function(Database db)? onOpen,
  bool foreignKeys = false,
  bool incrementalAutoVacuum = true,
}) async {
  ensureAppDatabaseFactory();
  final dbPath = await appDatabaseDirectory();
  final path = join(dbPath.path, fileName);

  _log.i('Initializing database at: $path');

  return openDatabase(
    path,
    version: version,
    onConfigure: (db) async {
      // Set this before any other PRAGMA so transient writer contention waits
      // instead of immediately surfacing SQLITE_BUSY during startup.
      await db.rawQuery('PRAGMA busy_timeout = 5000');
      if (foreignKeys) {
        await db.execute('PRAGMA foreign_keys = ON');
      }
      // History/library use INSERT OR REPLACE extensively. SQLite only fires
      // delete triggers for REPLACE when recursive_triggers is enabled; the
      // FTS external-content delete trigger needs that event to remove the old
      // rowid instead of accumulating unreachable index entries.
      await db.execute('PRAGMA recursive_triggers = ON');
      if (incrementalAutoVacuum) {
        final tables = await db.rawQuery('''
          SELECT 1
          FROM sqlite_master
          WHERE type = 'table'
            AND name NOT LIKE 'sqlite_%'
            AND name != 'android_metadata'
          LIMIT 1
        ''');
        // Changing from NONE must happen outside a transaction and before the
        // first application table is created. Android may already have added
        // its internal android_metadata table at this point.
        if (tables.isEmpty) {
          await db.execute('PRAGMA auto_vacuum = INCREMENTAL');
        }
      }
      await db.rawQuery('PRAGMA journal_mode = WAL');
      await db.execute('PRAGMA synchronous = NORMAL');
    },
    onCreate: onCreate,
    onUpgrade: onUpgrade,
    onOpen: onOpen,
  );
}

String normalizeLookupText(String? value) {
  return (value ?? '').trim().toLowerCase();
}

/// Retry only lock contention while acquiring BEGIN, before the callback runs.
/// History download writers can also lock transactions on an attached Library
/// connection. Never replay a body or COMMIT failure: it may have side effects
/// or an already durable result. Persistent locks still surface after 3 attempts.
Future<T> transactionWithBusyRetry<T>(
  Database db,
  Future<T> Function(Transaction txn) action, {
  bool? exclusive,
}) async {
  for (var attempt = 0; ; attempt++) {
    var entered = false;
    try {
      return await db.transaction((txn) {
        entered = true;
        return action(txn);
      }, exclusive: exclusive);
    } on DatabaseException catch (error) {
      final code = error.getResultCode();
      final message = error.toString().toLowerCase();
      final busy = code != null
          ? (code & 0xff) == 5 || (code & 0xff) == 6
          : message.contains('database is locked') ||
                message.contains('database table is locked');
      if (entered || !busy || attempt >= 2) rethrow;
      _log.w('Database busy before transaction; retry ${attempt + 1}/2');
      await Future<void>.delayed(Duration(milliseconds: 100 << attempt));
    }
  }
}

/// Returns a literal phrase suitable for the trigram FTS5 MATCH operator.
///
/// The trigram tokenizer cannot answer one- or two-character searches, so
/// callers should use their compatibility fallback when this returns null.
/// Quoting and escaping the value keeps user-entered FTS operators literal.
String? ftsPhraseSearchQuery(String value) {
  if (value.runes.length < 3 || value.contains('\u0000')) return null;
  return '"${value.replaceAll('"', '""')}"';
}

/// Whether [error] means the current SQLite runtime cannot provide the
/// FTS5/trigram combination used by the search indexes.
bool isTrigramFts5UnavailableError(Object error) {
  final message = error.toString().toLowerCase();
  return message.contains('no such module: fts5') ||
      message.contains('no such tokenizer: trigram') ||
      message.contains('unknown tokenizer: trigram');
}

/// Probes FTS5 + trigram once for the current process.
///
/// Android's sqflite implementation uses the platform SQLite runtime, so
/// compile-time modules can vary by device. A real temporary virtual table is
/// more reliable than PRAGMA compile_options because it also verifies that the
/// trigram tokenizer is registered. All app databases use the same sqflite
/// runtime, so subsequent history/library initialization can reuse the result.
Future<bool> _supportsTrigramFts5(DatabaseExecutor db) {
  return _trigramFts5Capability ??= _probeTrigramFts5(db);
}

Future<bool> _probeTrigramFts5(DatabaseExecutor db) async {
  try {
    await db.execute('''
      CREATE VIRTUAL TABLE temp.$_trigramFts5ProbeTable USING fts5(
        search_text,
        tokenize='trigram'
      )
    ''');
    return true;
  } catch (error) {
    if (isTrigramFts5UnavailableError(error)) {
      _log.i(
        'Trigram FTS5 is unavailable in this SQLite runtime; '
        'search will use the LIKE fallback',
      );
    } else {
      _log.w(
        'Could not probe trigram FTS5; search will use the LIKE fallback: '
        '$error',
      );
    }
    return false;
  } finally {
    try {
      await db.execute('DROP TABLE IF EXISTS temp.$_trigramFts5ProbeTable');
    } catch (error) {
      _log.d('Could not remove the temporary FTS5 probe table: $error');
    }
  }
}

/// Creates an external-content FTS5 index that preserves substring search
/// semantics through SQLite's trigram tokenizer.
///
/// FTS5 is an optional SQLite extension on some platform/database builds, so
/// callers must retain their existing query fallback when this returns false.
/// The index is external-content: the source table remains authoritative and
/// these triggers keep the index synchronized for every insert/update/delete,
/// including writes that happen outside the Dart repository methods.
Future<bool> createTrigramFtsIndex(
  DatabaseExecutor db, {
  required String ftsTable,
  required String contentTable,
  required String triggerPrefix,
}) async {
  if (!await _supportsTrigramFts5(db)) return false;

  try {
    final existingIndex = await db.rawQuery(
      "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ? LIMIT 1",
      [ftsTable],
    );
    final existingTriggers = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type = 'trigger' AND name IN (?, ?, ?)",
      ['${triggerPrefix}_ai', '${triggerPrefix}_ad', '${triggerPrefix}_au'],
    );
    final needsRebuild = existingIndex.isEmpty || existingTriggers.length != 3;
    await db.execute('''
      CREATE VIRTUAL TABLE IF NOT EXISTS $ftsTable USING fts5(
        search_text,
        content='$contentTable',
        content_rowid='rowid',
        tokenize='trigram'
      )
    ''');
    await db.execute('''
      CREATE TRIGGER IF NOT EXISTS ${triggerPrefix}_ai
      AFTER INSERT ON $contentTable
      BEGIN
        INSERT INTO $ftsTable(rowid, search_text)
        VALUES (new.rowid, COALESCE(new.search_text, ''));
      END
    ''');
    await db.execute('''
      CREATE TRIGGER IF NOT EXISTS ${triggerPrefix}_ad
      AFTER DELETE ON $contentTable
      BEGIN
        INSERT INTO $ftsTable($ftsTable, rowid, search_text)
        VALUES ('delete', old.rowid, COALESCE(old.search_text, ''));
      END
    ''');
    await db.execute('''
      CREATE TRIGGER IF NOT EXISTS ${triggerPrefix}_au
      AFTER UPDATE OF search_text ON $contentTable
      BEGIN
        INSERT INTO $ftsTable($ftsTable, rowid, search_text)
        VALUES ('delete', old.rowid, COALESCE(old.search_text, ''));
        INSERT INTO $ftsTable(rowid, search_text)
        VALUES (new.rowid, COALESCE(new.search_text, ''));
      END
    ''');

    // Rebuild a new or partially-created index. Avoid doing this on every app
    // start: the external-content table is already kept current by triggers.
    if (needsRebuild) {
      await db.rawInsert("INSERT INTO $ftsTable($ftsTable) VALUES (?)", [
        'rebuild',
      ]);
    }
    return true;
  } catch (error) {
    _log.w(
      'FTS5 index unavailable for $contentTable; using LIKE fallback: $error',
    );
    // Do not leave a half-created index/triggers behind. This makes a later
    // retry deterministic and never compromises the authoritative table.
    try {
      await db.execute('DROP TRIGGER IF EXISTS ${triggerPrefix}_ai');
      await db.execute('DROP TRIGGER IF EXISTS ${triggerPrefix}_ad');
      await db.execute('DROP TRIGGER IF EXISTS ${triggerPrefix}_au');
      await db.execute('DROP TABLE IF EXISTS $ftsTable');
    } catch (cleanupError) {
      _log.w('Failed to clean up partial FTS5 index $ftsTable: $cleanupError');
    }
    return false;
  }
}

Future<void> addColumnIfMissing(
  Database db,
  String table,
  String column,
  String type,
) async {
  final columns = await db.rawQuery('PRAGMA table_info($table)');
  final exists = columns.any(
    (row) => (row['name']?.toString().toLowerCase() ?? '') == column,
  );
  if (!exists) {
    await db.execute('ALTER TABLE $table ADD COLUMN $column $type');
  }
}

/// Rewrites every row of [table] by id with [values] computed from its
/// [columns], in one batch.
Future<void> backfillRows(
  Database db,
  String table,
  List<String> columns,
  Map<String, Object?> Function(Map<String, Object?> row) values,
) async {
  final rows = await db.query(table, columns: ['id', ...columns]);
  final batch = db.batch();
  for (final row in rows) {
    batch.update(table, values(row), where: 'id = ?', whereArgs: [row['id']]);
  }
  await batch.commit(noResult: true);
}

/// Loads rows whose [column] matches any of [rawValues] (chunked IN clauses)
/// into [destination], keeping the first row seen per value.
Future<void> loadRowsByColumn(
  DatabaseExecutor db, {
  required String table,
  required String column,
  required Iterable<String> rawValues,
  required Map<String, Map<String, dynamic>> destination,
  required Map<String, dynamic> Function(Map<String, Object?> row) mapRow,
  String? orderBy,
}) async {
  final values = rawValues.where((value) => value.isNotEmpty).toSet().toList();
  const chunkSize = 450;
  for (var start = 0; start < values.length; start += chunkSize) {
    final end = (start + chunkSize).clamp(0, values.length);
    final chunk = values.sublist(start, end);
    final placeholders = List.filled(chunk.length, '?').join(',');
    final rows = await db.rawQuery(
      'SELECT * FROM $table WHERE $column IN ($placeholders)'
      '${orderBy == null ? '' : ' ORDER BY $orderBy'}',
      chunk,
    );
    for (final row in rows) {
      final key = row[column] as String?;
      if (key != null && key.isNotEmpty) {
        destination.putIfAbsent(key, () => mapRow(row));
      }
    }
  }
}

Future<void> createPathKeyTable(DatabaseExecutor db, String table) async {
  await db.execute('''
    CREATE TABLE IF NOT EXISTS $table (
      item_id TEXT NOT NULL,
      path_key TEXT NOT NULL,
      PRIMARY KEY (item_id, path_key)
    )
  ''');
  await db.execute(
    'CREATE INDEX IF NOT EXISTS idx_${table}_key ON $table(path_key)',
  );
}

/// Finds every index entry for these physical files, including SAF aliases.
/// Keep extensions: deleting a FLAC must not remove a surviving Opus variant.
Future<List<String>> findPhysicalFileRowIds(
  DatabaseExecutor db,
  String table,
  Iterable<String> filePaths,
) async {
  final keys = {
    for (final path in filePaths) ...buildPhysicalPathMatchKeys(path),
  };
  final values = keys.toList();
  final ids = <String>{};
  const chunkSize = 450;
  for (var start = 0; start < values.length; start += chunkSize) {
    final chunk = values.sublist(
      start,
      (start + chunkSize).clamp(0, values.length),
    );
    final placeholders = List.filled(chunk.length, '?').join(',');
    final rows = await db.rawQuery('''
      SELECT DISTINCT item.id, item.file_path
      FROM $table item
      JOIN ${table}_path_keys keys ON keys.item_id = item.id
      WHERE keys.path_key IN ($placeholders)
    ''', chunk);
    for (final row in rows) {
      if (buildPhysicalPathMatchKeys(
        row['file_path'] as String?,
      ).any(keys.contains)) {
        ids.add(row['id'] as String);
      }
    }
  }
  return ids.toList();
}

Future<void> backfillPathKeys(
  Database db,
  String sourceTable,
  String keyTable,
) async {
  // One SAF path can expand into dozens of aliases. A library-wide batch
  // duplicates all of them in Dart and the platform channel during upgrades.
  // Keep reads/writes bounded and leave correct keys untouched to avoid
  // rewriting the entire index (and its WAL) just to add a new alias.
  const pageSize = 250;
  String? lastId;
  while (true) {
    final rows = await db.query(
      sourceTable,
      columns: ['id', 'file_path'],
      where: lastId == null ? null : 'id > ?',
      whereArgs: lastId == null ? null : [lastId],
      orderBy: 'id',
      limit: pageSize,
    );
    if (rows.isEmpty) break;
    final missingKeys = {
      for (final row in rows)
        row['id'] as String: buildPathMatchKeys(
          row['file_path'] as String?,
        ).toSet(),
    };
    final ids = missingKeys.keys.toList(growable: false);
    final existingKeys = await db.query(
      keyTable,
      columns: ['item_id', 'path_key'],
      where: 'item_id IN (${List.filled(ids.length, '?').join(',')})',
      whereArgs: ids,
    );
    Batch? batch;
    for (final key in existingKeys) {
      final id = key['item_id'] as String;
      final pathKey = key['path_key'] as String;
      if (!missingKeys[id]!.remove(pathKey)) {
        (batch ??= db.batch()).delete(
          keyTable,
          where: 'item_id = ? AND path_key = ?',
          whereArgs: [id, pathKey],
        );
      }
    }
    for (final entry in missingKeys.entries) {
      for (final key in entry.value) {
        (batch ??= db.batch()).insert(keyTable, {
          'item_id': entry.key,
          'path_key': key,
        }, conflictAlgorithm: ConflictAlgorithm.ignore);
      }
    }
    // onUpgrade owns the transaction; page commits must not open an
    // independent transaction or publish a partially migrated database.
    await batch?.commit(noResult: true);
    lastId = rows.last['id'] as String;
  }
}

/// [replaceExisting] may be false when the caller knows [table] holds no keys
/// for [id] yet, such as the first row for an id in a fresh staging table.
void putPathKeysInBatch(
  Batch batch,
  String table,
  String id,
  String? filePath, {
  bool replaceExisting = true,
}) {
  if (replaceExisting) {
    batch.delete(table, where: 'item_id = ?', whereArgs: [id]);
  }
  for (final key in buildPathMatchKeys(filePath)) {
    batch.insert(table, {
      'item_id': id,
      'path_key': key,
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
  }
}
