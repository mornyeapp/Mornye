import 'dart:convert';

import 'package:sqflite/sqflite.dart';
import 'package:mornye/services/sqlite_long_text.dart';

/// A dismissed player's last session, separate from the active player state.
class PlaybackResumeStore {
  const PlaybackResumeStore(this.database);

  final Database database;
  static const _table = 'playback_resume';

  static Future<void> createSchema(DatabaseExecutor db) => db.execute('''
    CREATE TABLE IF NOT EXISTS $_table (
      id INTEGER PRIMARY KEY CHECK (id = 1),
      media_json TEXT NOT NULL,
      current_index INTEGER NOT NULL,
      position_ms INTEGER NOT NULL,
      shuffle INTEGER NOT NULL,
      repeat_mode TEXT NOT NULL,
      preview_json TEXT NOT NULL
    )
  ''');

  Future<void> archive(Map<String, dynamic> media) async {
    final preview = jsonEncode(media);
    await database.transaction((txn) async {
      // Copy the queue inside SQLite instead of serializing it again in Dart.
      await txn.rawInsert(
        '''
        INSERT OR REPLACE INTO $_table
          (id, media_json, current_index, position_ms, shuffle, repeat_mode,
           preview_json)
        SELECT id, media_json, current_index, position_ms, shuffle, repeat_mode, ?
        FROM playback_session WHERE id = 1
      ''',
        [preview],
      );
      await txn.delete('playback_session');
    });
  }

  Future<Map<String, dynamic>?> preview() async {
    final rows = await database.query(
      _table,
      columns: ['preview_json', 'position_ms'],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final media = jsonDecode(rows.first['preview_json'] as String);
    if (media is! Map) return null;
    return {
      'media': Map<String, dynamic>.from(media),
      'positionMs': rows.first['position_ms'],
    };
  }

  Future<Map<String, dynamic>?> session() async {
    final stored = await readJsonTextRow(
      database,
      table: _table,
      jsonColumn: 'media_json',
      columns: const ['current_index', 'position_ms', 'shuffle', 'repeat_mode'],
    );
    if (stored == null) return null;
    final row = stored.row;
    return {
      'version': 2,
      'media': stored.json(),
      'index': row['current_index'],
      'positionMs': row['position_ms'],
      'shuffle': row['shuffle'] == 1,
      'repeat': row['repeat_mode'],
    };
  }

  Future<void> clear() => database.delete(_table);

  /// Relinks active and dismissed queues atomically without changing their order
  /// or playback position. JSON stays inside SQLite, including large queues.
  Future<void> relocateSource(String previous, String replacement) async {
    await database.transaction((txn) async {
      for (final table in ['playback_session', _table]) {
        await txn.rawUpdate(
          '''
          UPDATE $table SET media_json = (
            SELECT json_group_array(json(item)) FROM (
              SELECT CASE WHEN json_extract(value, '\$.source') = ?
                THEN json_set(value, '\$.source', ?) ELSE value END AS item
              FROM json_each($table.media_json) ORDER BY CAST(key AS INTEGER)
            )
          ) WHERE EXISTS (
            SELECT 1 FROM json_each($table.media_json)
            WHERE json_extract(value, '\$.source') = ?
          )
        ''',
          [previous, replacement, previous],
        );
      }
      await txn.rawUpdate(
        '''
        UPDATE $_table SET preview_json = json_set(preview_json, '\$.source', ?)
        WHERE json_extract(preview_json, '\$.source') = ?
      ''',
        [replacement, previous],
      );
    });
  }
}
