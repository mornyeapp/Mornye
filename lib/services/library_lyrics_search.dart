import 'dart:async';

import 'package:sqflite/sqflite.dart';
import 'package:mornye/models/library_database_models.dart';
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
    this.revision = 0,
  });

  final int checked;
  final int failed;
  final bool complete;

  /// Changes when searches should run again: at most once per refresh
  /// interval while indexing, and at the end of a pass that saved lyrics.
  final int revision;
}

/// A disposable, persistent search cache. Audio is read only while the Lyrics
/// filter is open; normal Library search never starts an indexing pass.
class LibraryLyricsSearchStore {
  LibraryLyricsSearchStore(
    this.db, {
    required this.readLyrics,
    this.useFts = true,
    this.refreshInterval = const Duration(seconds: 1),
  });

  static const _table = 'library_lyrics_search_v1';
  static const _fts = 'library_lyrics_search_fts_v1';

  /// The version of a row an edit invalidated. Real versions contain `|`.
  static const _edited = '';
  final DatabaseExecutor db;
  final LibraryLyricsReader readLyrics;
  final bool useFts;
  final Duration refreshInterval;
  Future<void>? _opening;
  Future<void> _readTail = Future<void>.value();
  bool _hasFts = false;
  int _generation = 0;
  int _revision = 0;

  /// Set by [clear] until a pass completes: Refresh reads every file again,
  /// including files whose scan found no lyrics, in case the flag is wrong.
  bool _readAll = false;
  int _clears = 0;

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

  /// `no_lyrics` marks files whose tags a scan read without embedded lyrics,
  /// the only lyrics [readLyrics] returns.
  static const _downloadedSongs = '''
    SELECT 'downloaded' AS source, h.id, h.file_path, h.track_name AS title,
      h.artist_name AS artist, h.cover_url AS cover,
      COALESCE(h.downloaded_at, '') || '|' || COALESCE(h.has_lyrics, 0)
        AS version,
      h.has_lyrics = 0 AND h.lyrics_metadata_scan_version >= 1 AS no_lyrics
    FROM history_db.history h WHERE COALESCE(h.file_path, '') != ''
  ''';

  static final _localSongs =
      '''
    SELECT 'local' AS source, l.id, l.file_path, l.track_name AS title,
      l.artist_name AS artist, l.cover_path AS cover,
      COALESCE(l.file_mod_time, 0) || '|' || l.scanned_at || '|' ||
        COALESCE(l.network_file_version, '') || '|' || l.has_lyrics AS version,
      l.has_lyrics = 0 AND
        l.audio_metadata_scan_version >= $libraryLyricsMetadataScanVersion
        AS no_lyrics
    FROM library_visible l WHERE ${libraryNotShadowedSql('l')}
  ''';

  /// One reader lane also bounds overlapping passes when a source changes or
  /// the user leaves and reopens the Lyrics filter during a native read.
  Future<
    ({
      Object? source,
      Object? id,
      Object? filePath,
      Object? version,
      String text,
      bool exists,
      int generation,
    })?
  >
  _prepareIndexEntry(
    Map<String, Object?> song,
    Map<String, Object?>? stored,
    bool Function() cancelled, {
    required bool readAll,
  }) async {
    final previous = _readTail;
    final done = Completer<void>();
    _readTail = done.future;
    await previous;
    try {
      if (cancelled()) return null;
      if (stored?['file_path'] == song['file_path'] &&
          stored?['version'] == song['version']) {
        return null;
      }
      final generation = _generation;
      // An edit can add lyrics before a scan updates the flag.
      final raw =
          !readAll && song['no_lyrics'] == 1 && stored?['version'] != _edited
          ? ''
          : await readLyrics(song['file_path'] as String);
      final text = cleanLyricsForDisplay(raw).toLowerCase();
      if (generation != _generation) return null;
      return (
        source: song['source'],
        id: song['id'],
        filePath: song['file_path'],
        version: song['version'],
        text: text,
        exists: stored != null,
        generation: generation,
      );
    } finally {
      done.complete();
    }
  }

  /// Writes [entries] in one transaction and returns how many could not be
  /// written; like a failed read, they are tried again on the next pass.
  Future<int> _commitPreparedEntries(
    List<
      ({
        Object? source,
        Object? id,
        Object? filePath,
        Object? version,
        String text,
        bool exists,
        int generation,
      })
    >
    entries,
  ) async {
    if (entries.isEmpty) return 0;
    Future<void> apply(DatabaseExecutor executor) async {
      final batch = executor.batch();
      var touched = false;
      for (final entry in entries) {
        if (entry.generation != _generation) continue;
        final values = {
          'file_path': entry.filePath,
          'version': entry.version,
          'search_text': entry.text,
        };
        if (entry.exists) {
          // UPDATE preserves the rowid used by the external-content FTS index.
          batch.update(
            _table,
            values,
            where: 'source = ? AND id = ?',
            whereArgs: [entry.source, entry.id],
          );
          touched = true;
        } else {
          batch.insert(_table, {
            'source': entry.source,
            'id': entry.id,
            ...values,
          }, conflictAlgorithm: ConflictAlgorithm.replace);
          if (entry.text.isNotEmpty) touched = true;
        }
      }
      await batch.commit(noResult: true);
      if (touched) _revision++;
    }

    final executor = db;
    try {
      if (executor is Database) {
        await executor.transaction(apply);
      } else {
        await apply(executor);
      }
      return 0;
    } catch (_) {
      return entries.length;
    }
  }

  Stream<LibraryLyricsIndexProgress> index({
    required bool includeLocal,
    required bool Function() cancelled,
  }) async* {
    await open();
    final clears = _clears;
    var checked = 0;
    var failed = 0;
    var revision = _revision;
    final sinceRefresh = Stopwatch()..start();
    LibraryLyricsIndexProgress progress() {
      if (revision != _revision && sinceRefresh.elapsed >= refreshInterval) {
        revision = _revision;
        sinceRefresh.reset();
      }
      return LibraryLyricsIndexProgress(
        checked: checked,
        failed: failed,
        revision: revision,
      );
    }

    yield LibraryLyricsIndexProgress(revision: revision);
    // Each source pages by its own primary key, so a batch seeks past the
    // previous one instead of sorting every remaining song again.
    for (final songs in [_downloadedSongs, if (includeLocal) _localSongs]) {
      String? afterId;
      while (!cancelled()) {
        final rows = await db.rawQuery(
          '''
          SELECT song.* FROM ($songs) song
          WHERE NOT EXISTS (SELECT 1 FROM $_table c
            WHERE c.source = song.source AND c.id = song.id
              AND c.file_path = song.file_path AND c.version = song.version)
          ${afterId == null ? '' : 'AND song.id > ?'}
          ORDER BY song.id LIMIT 32
        ''',
          [?afterId],
        );
        if (rows.isEmpty) break;
        final source = rows.first['source'];
        final ids = [for (final row in rows) row['id']];
        final placeholders = List.filled(ids.length, '?').join(',');
        final existingRows = await db.query(
          _table,
          columns: ['id', 'file_path', 'version'],
          where: 'source = ? AND id IN ($placeholders)',
          whereArgs: [source, ...ids],
        );
        final existingById = {
          for (final row in existingRows) row['id'] as String: row,
        };
        final prepared =
            <
              ({
                Object? source,
                Object? id,
                Object? filePath,
                Object? version,
                String text,
                bool exists,
                int generation,
              })
            >[];
        for (final song in rows) {
          if (cancelled()) {
            await _commitPreparedEntries(prepared);
            return;
          }
          try {
            final entry = await _prepareIndexEntry(
              song,
              existingById[song['id'] as String],
              cancelled,
              readAll: _readAll,
            );
            if (entry != null) prepared.add(entry);
          } catch (_) {
            // A failed probe is retryable, never cached as "no lyrics".
            failed++;
          }
          if (cancelled()) {
            await _commitPreparedEntries(prepared);
            return;
          }
          checked++;
          if (checked % 8 == 0) {
            failed += await _commitPreparedEntries(prepared);
            prepared.clear();
            yield progress();
          }
        }
        failed += await _commitPreparedEntries(prepared);
        afterId = rows.last['id'] as String;
        yield progress();
      }
    }
    if (!cancelled()) {
      if (clears == _clears) _readAll = false;
      yield LibraryLyricsIndexProgress(
        checked: checked,
        failed: failed,
        complete: true,
        revision: _revision,
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
    final localUnion = includeLocal
        ? '''
      UNION ALL
      SELECT 'local' AS source, l.id, l.track_name AS title,
        l.artist_name AS artist, l.cover_path AS cover, l.file_path
      FROM matched m
      JOIN library_visible l ON m.source = 'local' AND l.id = m.id
        AND l.file_path = m.file_path
        AND (COALESCE(l.file_mod_time, 0) || '|' || l.scanned_at || '|' ||
          COALESCE(l.network_file_version, '') || '|' || l.has_lyrics) = m.version
      WHERE ${libraryNotShadowedSql('l')}
      '''
        : '';
    final rows = await db.rawQuery(
      '''
      WITH matched AS (
        SELECT c.source, c.id, c.file_path, c.version
        FROM $_table c
        WHERE $predicate
      )
      SELECT song.source, song.id, song.title, song.artist, song.cover,
        song.file_path AS sample_path, 1 AS track_count
      FROM (
        SELECT 'downloaded' AS source, h.id, h.track_name AS title,
          h.artist_name AS artist, h.cover_url AS cover, h.file_path
        FROM matched m
        JOIN history_db.history h ON m.source = 'downloaded' AND h.id = m.id
          AND h.file_path = m.file_path
          AND (COALESCE(h.downloaded_at, '') || '|' || COALESCE(h.has_lyrics, 0)) = m.version
        WHERE COALESCE(h.file_path, '') != ''
        $localUnion
      ) song
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
    _revision++;
    await open();
    await invalidateStored(db, path);
  }

  /// Edits can happen before the search UI has opened in this app session.
  /// Invalidate an existing cache without creating one or reading audio.
  /// The row stays as an edit mark, so the next pass reads the file even if
  /// its scan still says it has no lyrics.
  static Future<void> invalidateStored(DatabaseExecutor db, String path) async {
    final exists = await db.rawQuery(
      "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ? LIMIT 1",
      [_table],
    );
    if (exists.isEmpty) return;
    final keys = buildPhysicalPathMatchKeys(path).toList();
    if (keys.isEmpty) return;
    final placeholders = List.filled(keys.length, '?').join(',');
    await db.rawUpdate(
      '''UPDATE $_table SET version = ?, search_text = ''
      WHERE version != ? AND (file_path = ? OR
      (source = 'downloaded' AND id IN (SELECT item_id
        FROM history_db.history_path_keys WHERE path_key IN ($placeholders))) OR
      (source = 'local' AND id IN (SELECT item_id
        FROM library_path_keys WHERE path_key IN ($placeholders))))
    ''',
      [_edited, _edited, path, ...keys, ...keys],
    );
  }

  Future<void> clear() async {
    _generation++;
    _revision++;
    _clears++;
    _readAll = true;
    await open();
    await db.delete(_table);
  }
}
