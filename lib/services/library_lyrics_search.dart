import 'dart:async';

import 'package:sqflite/sqflite.dart';
import 'package:mornye/services/library_search.dart';
import 'package:mornye/services/library_shadow_sql.dart';
import 'package:mornye/services/sqlite_helpers.dart' as sqlite;
import 'package:mornye/utils/lyrics_metadata_helper.dart';
import 'package:mornye/utils/path_match_keys.dart';

typedef LibraryLyricsReader = Future<String> Function(String path);

class LibraryLyricsIndexProgress {
  const LibraryLyricsIndexProgress({
    this.checked = 0,
    this.failed = 0,
    this.complete = false,
  });

  final int checked;
  final int failed;
  final bool complete;
}

/// A disposable, persistent search cache. Audio is read only while the Lyrics
/// filter is open; normal Library search never starts an indexing pass.
class LibraryLyricsSearchStore {
  LibraryLyricsSearchStore(
    this.db, {
    required this.readLyrics,
    this.useFts = true,
  });

  static const _table = 'library_lyrics_search_v1';
  static const _fts = 'library_lyrics_search_fts_v1';
  final DatabaseExecutor db;
  final LibraryLyricsReader readLyrics;
  final bool useFts;
  Future<void>? _opening;
  Future<void> _readTail = Future<void>.value();
  bool _hasFts = false;
  int _generation = 0;

  Future<void> open() => _opening ??= _open();

  Future<void> _open() async {
    await db.execute('''CREATE TABLE IF NOT EXISTS $_table (
      source TEXT NOT NULL, id TEXT NOT NULL, file_path TEXT NOT NULL,
      version TEXT NOT NULL, search_text TEXT NOT NULL,
      PRIMARY KEY(source, id)
    )''');
    _hasFts =
        useFts &&
        await sqlite.createTrigramFtsIndex(
          db,
          ftsTable: _fts,
          contentTable: _table,
          triggerPrefix: _fts,
        );
    await db.rawDelete('''DELETE FROM $_table WHERE
      (source = 'downloaded' AND id NOT IN (SELECT id FROM history_db.history))
      OR (source = 'local' AND id NOT IN (SELECT id FROM library))''');
  }

  String _songs(bool includeLocal) =>
      '''
    SELECT 'downloaded' AS source, h.id, h.file_path, h.track_name AS title,
      h.artist_name AS artist, h.cover_url AS cover,
      COALESCE(h.downloaded_at, '') || '|' || COALESCE(h.has_lyrics, 0)
        AS version
    FROM history_db.history h WHERE COALESCE(h.file_path, '') != ''
    ${includeLocal ? '''UNION ALL
    SELECT 'local' AS source, l.id, l.file_path, l.track_name AS title,
      l.artist_name AS artist, l.cover_path AS cover,
      COALESCE(l.file_mod_time, 0) || '|' || l.scanned_at || '|' ||
        COALESCE(l.network_file_version, '') || '|' || l.has_lyrics AS version
    FROM library_visible l WHERE ${libraryNotShadowedSql('l')}
    ''' : ''}
  ''';

  /// One reader lane also bounds overlapping passes when a source changes or
  /// the user leaves and reopens the Lyrics filter during a native read.
  Future<void> _index(
    Map<String, Object?> song,
    bool Function() cancelled,
  ) async {
    final previous = _readTail;
    final done = Completer<void>();
    _readTail = done.future;
    await previous;
    try {
      if (cancelled()) return;
      final current = await db.query(
        _table,
        columns: ['id'],
        where: 'source = ? AND id = ? AND file_path = ? AND version = ?',
        whereArgs: [
          song['source'],
          song['id'],
          song['file_path'],
          song['version'],
        ],
        limit: 1,
      );
      if (current.isNotEmpty) return;
      final generation = _generation;
      final raw = await readLyrics(song['file_path'] as String);
      final text = cleanLyricsForDisplay(raw).toLowerCase();
      if (generation != _generation) return;
      // UPDATE preserves the rowid used by the external-content FTS index.
      final values = {
        'file_path': song['file_path'],
        'version': song['version'],
        'search_text': text,
      };
      final changed = await db.update(
        _table,
        values,
        where: 'source = ? AND id = ?',
        whereArgs: [song['source'], song['id']],
      );
      if (changed == 0 && generation == _generation) {
        await db.insert(_table, {
          'source': song['source'],
          'id': song['id'],
          ...values,
        });
      }
    } finally {
      done.complete();
    }
  }

  Stream<LibraryLyricsIndexProgress> index({
    required bool includeLocal,
    required bool Function() cancelled,
  }) async* {
    await open();
    var checked = 0;
    var failed = 0;
    String? afterSource;
    String? afterId;
    yield const LibraryLyricsIndexProgress();
    while (!cancelled()) {
      final rows = await db.rawQuery(
        '''
        SELECT song.* FROM (${_songs(includeLocal)}) song
        WHERE NOT EXISTS (SELECT 1 FROM $_table c
          WHERE c.source = song.source AND c.id = song.id
            AND c.file_path = song.file_path AND c.version = song.version)
        ${afterSource == null ? '' : 'AND (song.source > ? OR (song.source = ? AND song.id > ?))'}
        ORDER BY song.source, song.id LIMIT 32
      ''',
        [
          if (afterSource != null) ...[afterSource, afterSource, afterId],
        ],
      );
      if (rows.isEmpty) break;
      for (final song in rows) {
        if (cancelled()) return;
        try {
          await _index(song, cancelled);
        } catch (_) {
          // A failed probe is retryable, never cached as "no lyrics".
          failed++;
        }
        if (cancelled()) return;
        checked++;
        if (checked % 8 == 0) {
          yield LibraryLyricsIndexProgress(checked: checked, failed: failed);
        }
      }
      afterSource = rows.last['source'] as String;
      afterId = rows.last['id'] as String;
      yield LibraryLyricsIndexProgress(checked: checked, failed: failed);
    }
    if (!cancelled()) {
      yield LibraryLyricsIndexProgress(
        checked: checked,
        failed: failed,
        complete: true,
      );
    }
  }

  Future<List<LibrarySearchHit>> search({
    required String query,
    required bool includeLocal,
    int limit = 40,
    int offset = 0,
  }) async {
    final search = LibrarySearchQuery(query);
    if (search.terms.isEmpty) return [];
    await open();
    final args = <Object?>[];
    final predicate = search.predicate(
      'c.search_text',
      args,
      rowId: 'c.rowid',
      ftsTable: _hasFts ? _fts : null,
    );
    final order = search.orderBy('LOWER(song.title)', args);
    final rows = await db.rawQuery(
      '''
      SELECT song.source, song.id, song.title, song.artist, song.cover,
        song.file_path AS sample_path, 1 AS track_count
      FROM (${_songs(includeLocal)}) song JOIN $_table c
        ON c.source = song.source AND c.id = song.id
          AND c.file_path = song.file_path AND c.version = song.version
      WHERE $predicate
      ORDER BY $order, LOWER(song.title), song.source, song.id LIMIT ? OFFSET ?
    ''',
      [...args, limit.clamp(1, 100), offset < 0 ? 0 : offset],
    );
    return rows
        .map((row) => LibrarySearchHit.fromRow(LibrarySearchKind.songs, row))
        .toList(growable: false);
  }

  Future<void> invalidate(String path) async {
    _generation++;
    await open();
    await invalidateStored(db, path);
  }

  /// Edits can happen before the search UI has opened in this app session.
  /// Invalidate an existing cache without creating one or reading audio.
  static Future<void> invalidateStored(DatabaseExecutor db, String path) async {
    final exists = await db.rawQuery(
      "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ? LIMIT 1",
      [_table],
    );
    if (exists.isEmpty) return;
    final keys = buildPhysicalPathMatchKeys(path).toList();
    if (keys.isEmpty) return;
    final placeholders = List.filled(keys.length, '?').join(',');
    await db.rawDelete(
      '''DELETE FROM $_table WHERE file_path = ? OR
      (source = 'downloaded' AND id IN (SELECT item_id
        FROM history_db.history_path_keys WHERE path_key IN ($placeholders))) OR
      (source = 'local' AND id IN (SELECT item_id
        FROM library_path_keys WHERE path_key IN ($placeholders)))
    ''',
      [path, ...keys, ...keys],
    );
  }

  Future<void> clear() async {
    _generation++;
    await open();
    await db.delete(_table);
  }
}
