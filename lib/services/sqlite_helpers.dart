import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';
import 'package:mornye/services/library_shadow_sql.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:mornye/utils/logger.dart';
import 'package:mornye/utils/path_match_keys.dart';
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart' show databaseFactoryFfi;

export 'package:mornye/services/library_shadow_sql.dart';

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

/// Adds the plain-path keys that rows stored with a Windows verbatim path
/// (`\\?\C:\…`, `\\?\UNC\server\…`) lacked before those keys existed.
/// Without them a scanned file and the download of the same file look like
/// two files. Rows that already have their plain key cost one indexed probe.
/// Returns the number of rows repaired.
Future<int> repairWindowsVerbatimPathKeys(
  Database db,
  String sourceTable,
  String keyTable,
) async {
  const path = 's.file_path';
  const isUnc =
      "upper(substr($path, 5, 3)) = 'UNC' "
      'AND substr($path, 8, 1) = substr($path, 1, 1)';
  final rows = await db.rawQuery(
    'SELECT s.id, s.file_path FROM $sourceTable s '
    r"WHERE substr(s.file_path, 1, 4) IN ('\\?\', '//?/') "
    "AND (substr($path, 6, 1) = ':' OR ($isUnc)) "
    'AND NOT EXISTS ('
    '  SELECT 1 FROM $keyTable k WHERE k.item_id = s.id AND k.path_key = '
    '    CASE WHEN $isUnc '
    '      THEN substr($path, 1, 2) || substr($path, 9) '
    '      ELSE substr($path, 5) END'
    ')',
  );
  if (rows.isEmpty) return 0;
  const pageSize = 250;
  await db.transaction((txn) async {
    for (var start = 0; start < rows.length; start += pageSize) {
      final batch = txn.batch();
      for (final row in rows.skip(start).take(pageSize)) {
        putPathKeysInBatch(
          batch,
          keyTable,
          row['id'] as String,
          row['file_path'] as String?,
          replaceExisting: false,
        );
      }
      await batch.commit(noResult: true);
    }
  });
  return rows.length;
}

/// [repairWindowsVerbatimPathKeys] for a database being opened. A failed
/// repair is logged and leaves the database usable.
Future<void> repairWindowsPathKeysOnOpen(
  Database db,
  String sourceTable,
  String keyTable,
) async {
  try {
    final repaired = await repairWindowsVerbatimPathKeys(
      db,
      sourceTable,
      keyTable,
    );
    if (repaired > 0) {
      _log.i('Added plain Windows path keys to $repaired $sourceTable rows');
    }
  } catch (error) {
    _log.w('Could not repair Windows path keys in $sourceTable: $error');
  }
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

/// Reads, in one call, values that change after any write [db] can see in
/// [schemas]: each schema's `PRAGMA data_version` moves when another
/// connection commits, and `total_changes()` counts every row this
/// connection writes, raw writes outside its repository included. Equal
/// stamps from one connection mean nothing was written in between. Null when
/// the platform returns no stamp.
Future<String?> readWriteStamp(Database db, List<String> schemas) async {
  final batch = db.batch();
  for (final schema in schemas) {
    batch.rawQuery('PRAGMA $schema.data_version');
  }
  batch.rawQuery('SELECT total_changes()');
  try {
    return _writeStamp(await batch.apply(), [
      for (var index = 0; index <= schemas.length; index++) index,
    ]);
  } catch (error) {
    _log.w('Could not read the database write stamp: $error');
    return null;
  }
}

String? _writeStamp(List<Object?> results, List<int> indexes) {
  final values = <int>[];
  for (final index in indexes) {
    final rows = index < results.length ? results[index] : null;
    final value = rows is List && rows.isNotEmpty && rows.first is Map
        ? (rows.first as Map).values.firstOrNull
        : null;
    if (value is! int) return null;
    values.add(value);
  }
  return values.join(':');
}

/// Keeps [libraryShadowTable] on one Library connection with history_db
/// attached, rebuilt only after a write that could change it. The stamp sees
/// every writer: a commit by another connection (HistoryDatabase, Android's
/// native history store, a Rust restore) moves the `PRAGMA data_version` of
/// its schema, and this connection's own writes, raw ones included, move
/// `total_changes()`. A rebuild is one batch call, so nothing else on the
/// connection runs inside it, and reads that counter after its statements.
class LibraryShadowSnapshot {
  static const _schemas = ['main', 'history_db'];

  Database? _db;
  String? _stamp;
  Future<String?>? _building;
  // A failed build is tried again only once the data has changed.
  ({Database db, String stamp})? _failed;
  Database? _buildWarned;
  Database? _queryWarned;
  int _rebuilds = 0;

  /// Builds started, failed ones included.
  @visibleForTesting
  int get rebuilds => _rebuilds;

  /// The stamp of a current [libraryShadowTable], or null to keep the
  /// per-row check, as when the platform returns no stamp. With [rebuild]
  /// false a stale table is not built and also gives null.
  Future<String?> refresh(Database db, {bool rebuild = true}) async {
    // A rebuild in flight may have read the files before the caller's write.
    final building = _building;
    if (building != null) {
      if (!rebuild) return null;
      await building;
    }
    final stamp = await readWriteStamp(db, _schemas);
    if (stamp == null) return null;
    if (identical(db, _db) && stamp == _stamp) return stamp;
    final failed = _failed;
    if (!rebuild ||
        (failed != null && identical(failed.db, db) && failed.stamp == stamp)) {
      return null;
    }
    return _building ??= _rebuild(
      db,
      stamp,
    ).whenComplete(() => _building = null);
  }

  /// Runs [query] on [libraryShadowTable] when the table stays current
  /// until [query] has finished. Otherwise, as after a write between the
  /// two, its rows and the table could be from different states, so
  /// [query] runs again with the per-row check. [rebuild] false suits reads
  /// the row check keeps cheap, such as a page that stops after a few rows:
  /// they use the table only when it is already current, never waiting for
  /// a build.
  Future<T> read<T>(
    Database db,
    Future<T> Function(bool snapshot) query, {
    bool rebuild = true,
  }) async {
    final stamp = await refresh(db, rebuild: rebuild);
    if (stamp == null) return query(false);
    try {
      final result = await query(true);
      if (await readWriteStamp(db, _schemas) == stamp) return result;
    } on DatabaseException catch (error) {
      // A failed rebuild can leave no table; the row check needs none.
      if (!identical(_queryWarned, db)) {
        _queryWarned = db;
        _log.w(
          'Download shadow snapshot query failed; using the row check: $error',
        );
      }
    }
    return query(false);
  }

  String? _buildFailed(Database db, String stamp, Object error) {
    _failed = (db: db, stamp: stamp);
    if (!identical(_buildWarned, db)) {
      _buildWarned = db;
      _log.w(
        'Download shadow snapshot unavailable; using the row check: $error',
      );
    }
    return null;
  }

  Future<String?> _rebuild(Database db, String stamp) async {
    _db = null;
    _stamp = null;
    _rebuilds++;
    try {
      final sizes = (await db.rawQuery(
        'SELECT (SELECT COUNT(*) FROM library) AS library_rows, '
        '(SELECT COUNT(*) FROM history_db.history) AS history_rows',
      )).first;
      final libraryRows = (sizes['library_rows'] as num?)?.toInt() ?? 0;
      final historyRows = (sizes['history_rows'] as num?)?.toInt() ?? 0;
      // The pairs go to a staging table first, so a failed build leaves the
      // previous snapshot in place for queries already issued.
      final results =
          await (db.batch()
                ..rawQuery('PRAGMA main.data_version')
                ..rawQuery('PRAGMA history_db.data_version')
                ..execute('DROP TABLE IF EXISTS temp.library_shadowed_next')
                ..execute(
                  'CREATE TEMP TABLE library_shadowed_next AS '
                  '${_shadowPairsSql(fromHistory: historyRows * 2 < libraryRows)}',
                )
                ..execute('DROP TABLE IF EXISTS $libraryShadowTable')
                ..execute(
                  'CREATE TEMP TABLE library_shadowed AS '
                  'SELECT * FROM temp.library_shadowed_next',
                )
                ..execute('DROP TABLE temp.library_shadowed_next')
                ..execute(
                  'CREATE INDEX temp.library_shadowed_item '
                  'ON library_shadowed(item_id)',
                )
                ..execute(
                  'CREATE INDEX temp.library_shadowed_history '
                  'ON library_shadowed(history_id)',
                )
                ..rawQuery('SELECT total_changes()'))
              .apply();
      final built = _writeStamp(results, const [0, 1, 9]);
      if (built == null) {
        return _buildFailed(db, stamp, 'no write stamp after the build');
      }
      _db = db;
      _stamp = built;
      _failed = null;
      return built;
    } catch (error) {
      return _buildFailed(db, stamp, error);
    }
  }

  /// Distinct pairs, from the side that costs less: a key read from History
  /// costs about twice one read from the Library, as it first collects the
  /// matching Library ids.
  static String _shadowPairsSql({required bool fromHistory}) => fromHistory
      ? '''
    SELECT DISTINCT lpk.item_id AS item_id, hpk.item_id AS history_id
    FROM library_path_keys lpk
    JOIN history_db.history_path_keys hpk ON hpk.path_key = lpk.path_key
    WHERE lpk.item_id IN (
      SELECT item_id FROM library_path_keys
      WHERE path_key IN (SELECT path_key FROM history_db.history_path_keys)
    )'''
      : '''
    SELECT DISTINCT lpk.item_id AS item_id, hpk.item_id AS history_id
    FROM library_path_keys lpk
    CROSS JOIN history_db.history_path_keys hpk
      ON hpk.path_key = lpk.path_key''';
}
