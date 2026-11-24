import 'package:sqflite/sqflite.dart';
import 'package:mornye/services/sqlite_helpers.dart' as sqlite;
import 'package:mornye/utils/file_access.dart';

bool isLibrarySizeSort(String mode) =>
    mode == 'size-desc' || mode == 'size-asc';

/// A derived index shared by paged Library reads. Native writers keep owning
/// their existing row schemas; triggers invalidate sizes after replacement,
/// conversion or metadata changes, including writes from another connection.
class LibraryFileSizes {
  LibraryFileSizes(this.db, {Future<int?> Function(String)? readSize})
    : _readSize = readSize ?? _fileSize;

  final Database db;
  final Future<int?> Function(String) _readSize;
  final _initialized = <String>{};
  final _pending = <String, Future<void>>{};

  static Future<int?> _fileSize(String path) async {
    // A virtual CUE track has no independent file size.
    if (isCueVirtualPath(path)) return null;
    return (await fileStat(path))?.size;
  }

  Future<void> refresh({
    required bool includeLocal,
    required bool includeHistory,
  }) async {
    if (includeHistory) await _refresh('history_db', 'history');
    if (includeLocal) await _refresh('main', 'library');
  }

  Future<void> _refresh(String schema, String table) =>
      _pending[schema] ??= _fill(schema, table).whenComplete(() {
        _pending.remove(schema);
      });

  Future<void> _initialize(String schema, String table) async {
    if (_initialized.contains(schema)) return;
    await db.execute('''
      CREATE TABLE IF NOT EXISTS $schema.track_file_sizes (
        item_id TEXT PRIMARY KEY,
        file_path TEXT NOT NULL,
        generation INTEGER NOT NULL,
        size_bytes INTEGER,
        checked_at INTEGER NOT NULL DEFAULT 0
      )
    ''');
    await db.execute('''
      CREATE INDEX IF NOT EXISTS $schema.idx_track_file_sizes_pending
      ON track_file_sizes(item_id, checked_at) WHERE size_bytes IS NULL
    ''');
    await db.execute('''
      CREATE INDEX IF NOT EXISTS $schema.idx_track_file_sizes_sort
      ON track_file_sizes(size_bytes, item_id)
    ''');
    for (final event in ['INSERT', 'UPDATE']) {
      await db.execute('''
        CREATE TRIGGER IF NOT EXISTS $schema.track_file_sizes_${event.toLowerCase()}
        AFTER $event ON $table BEGIN
          INSERT OR REPLACE INTO track_file_sizes(item_id, file_path, generation)
          VALUES(NEW.id, NEW.file_path, random());
        END
      ''');
    }
    await db.execute('''
      CREATE TRIGGER IF NOT EXISTS $schema.track_file_sizes_delete
      AFTER DELETE ON $table BEGIN
        DELETE FROM track_file_sizes WHERE item_id = OLD.id;
      END
    ''');
    // Existing installations get placeholders without reading audio or
    // materializing their entire Library in Dart.
    await db.execute('''
      INSERT OR IGNORE INTO $schema.track_file_sizes(item_id, file_path, generation)
      SELECT id, file_path, random() FROM $schema.$table
    ''');
    _initialized.add(schema);
  }

  Future<void> _fill(String schema, String table) async {
    await _initialize(schema, table);
    final now = DateTime.now().millisecondsSinceEpoch;
    final retryBefore = now - const Duration(minutes: 5).inMilliseconds;
    String? after;
    while (true) {
      final rows = await db.rawQuery(
        '''
        SELECT item_id, file_path, generation FROM $schema.track_file_sizes
        WHERE size_bytes IS NULL AND checked_at <= ?
          ${after == null ? '' : 'AND item_id > ?'}
          ${table == 'library' ? '''AND EXISTS (
            SELECT 1 FROM library_visible l WHERE l.id = item_id
          )''' : ''}
        ORDER BY item_id LIMIT 64
      ''',
        [retryBefore, ?after],
      );
      if (rows.isEmpty) break;
      final sizes = <int?>[];
      for (var start = 0; start < rows.length; start += 4) {
        sizes.addAll(
          await Future.wait([
            for (final row in rows.skip(start).take(4))
              Future.sync(
                () => _readSize(row['file_path'] as String),
              ).then<int?>(
                (size) => size != null && size >= 0 ? size : null,
                onError: (Object _) => null,
              ),
          ]),
        );
      }
      await sqlite.transactionWithBusyRetry(db, (txn) async {
        final batch = txn.batch();
        for (var i = 0; i < rows.length; i++) {
          final row = rows[i];
          batch.update(
            '$schema.track_file_sizes',
            {'size_bytes': sizes[i], 'checked_at': now},
            where: 'item_id = ? AND generation = ?',
            whereArgs: [row['item_id'], row['generation']],
          );
        }
        await batch.commit(noResult: true);
      });
      after = rows.last['item_id'] as String;
      if (rows.length < 64) break;
    }
  }
}
