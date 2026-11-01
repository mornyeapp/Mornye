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
}
