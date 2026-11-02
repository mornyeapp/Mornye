import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import 'package:mornye/models/library_database_models.dart';
import 'package:mornye/services/library_row_mapper.dart';
import 'package:mornye/services/sqlite_helpers.dart' as sqlite;
import 'package:mornye/utils/ios_container_paths.dart';
import 'package:mornye/utils/logger.dart';

final _log = AppLogger('LibraryDatabase');

/// Schema lifecycle is independent of collection reads and scan transactions.
abstract final class LibrarySchema {
  static const version = 20;
  static const visibleView = 'library_visible';
  static const searchFtsTable = 'library_search_fts';
  static const lookupSummaryTable = 'library_lookup_summary';
  static const _legacySourceId = LocalLibraryItem.legacySourceId;

  static Future<bool> create(Database db, int version) async {
    _log.i('Creating library database schema v$version');
    await db.execute('''
      CREATE TABLE library (
        id TEXT PRIMARY KEY,
        source_id TEXT NOT NULL DEFAULT '$_legacySourceId',
        track_name TEXT NOT NULL,
        artist_name TEXT NOT NULL,
        album_name TEXT NOT NULL,
        album_artist TEXT,
        file_path TEXT NOT NULL UNIQUE,
        cover_path TEXT,
        scanned_at TEXT NOT NULL,
        file_mod_time INTEGER,
        network_file_version TEXT,
        isrc TEXT,
        track_number INTEGER,
        total_tracks INTEGER,
        disc_number INTEGER,
        total_discs INTEGER,
        duration INTEGER,
        release_date TEXT,
        bit_depth INTEGER,
        sample_rate INTEGER,
        bitrate INTEGER,
        genre TEXT,
        composer TEXT,
        label TEXT,
        copyright TEXT,
        explicit INTEGER NOT NULL DEFAULT 0,
        has_lyrics INTEGER NOT NULL DEFAULT 0,
        has_replaygain INTEGER NOT NULL DEFAULT 0,
        format TEXT,
        audio_metadata_scan_version INTEGER NOT NULL DEFAULT 4,
        track_name_norm TEXT,
        artist_name_norm TEXT,
        album_name_norm TEXT,
        album_artist_norm TEXT,
        match_key TEXT,
        album_key TEXT,
        search_text TEXT,
        sort_genre TEXT,
        sort_release TEXT,
        sort_added INTEGER
      )
    ''');
    for (final index in const {
      'isrc': 'isrc',
      'track_artist': 'track_name, artist_name',
      'album': 'album_name, album_artist',
      'file_path': 'file_path',
    }.entries) {
      await db.execute(
        'CREATE INDEX idx_library_${index.key} ON library(${index.value})',
      );
    }
    await _createNormalizedIndexes(db);
    await _createQueueIndexes(db);
    await sqlite.createPathKeyTable(db, 'library_path_keys');
    await _createSources(db);
    await _createLookupSummary(db);
    final ftsAvailable = await createSearchFts(db);
    _log.i('Library database schema created with indexes');
    return ftsAvailable;
  }

  static Future<void> upgrade(
    Database db,
    int oldVersion,
    int newVersion,
  ) async {
    _log.i('Upgrading library database from v$oldVersion to v$newVersion');
    Future<void> addColumn(String column, String type) =>
        sqlite.addColumnIfMissing(db, 'library', column, type);
    const notNullZero = 'INTEGER NOT NULL DEFAULT 0';
    // Keep historical defaults: older rows require a metadata rescan, while
    // freshly scanned rows are written with their actual scan version.
    for (final addition in const [
      (2, 'cover_path', 'TEXT'),
      (3, 'file_mod_time', 'INTEGER'),
      (4, 'bitrate', 'INTEGER'),
      (5, 'label', 'TEXT'),
      (5, 'copyright', 'TEXT'),
      (6, 'total_tracks', 'INTEGER'),
      (6, 'total_discs', 'INTEGER'),
      (6, 'composer', 'TEXT'),
    ]) {
      if (oldVersion < addition.$1) {
        await db.execute(
          'ALTER TABLE library ADD COLUMN ${addition.$2} ${addition.$3}',
        );
      }
    }
    if (oldVersion < 7) {
      for (final column in const [
        'track_name_norm',
        'artist_name_norm',
        'album_name_norm',
        'album_artist_norm',
        'match_key',
        'album_key',
      ]) {
        await addColumn(column, 'TEXT');
      }
      await _backfillNormalizedColumns(db);
      await _createNormalizedIndexes(db);
    }
    if (oldVersion < 8) {
      await sqlite.createPathKeyTable(db, 'library_path_keys');
    }
    if (oldVersion < 9) {
      await addColumn('audio_metadata_scan_version', notNullZero);
    }
    if (oldVersion < 10) {
      for (final column in const [
        'search_text',
        'sort_genre',
        'sort_release',
        'sort_added',
      ]) {
        await addColumn(column, column == 'sort_added' ? 'INTEGER' : 'TEXT');
      }
      await _backfillQueueColumns(db);
      await _createQueueIndexes(db);
    }
    if (oldVersion < 11) {
      await addColumn('source_id', "TEXT NOT NULL DEFAULT '$_legacySourceId'");
      await _createSources(db);
    }
    for (final addition in const [
      (12, 'explicit'),
      (13, 'has_lyrics'),
      (15, 'has_replaygain'),
    ]) {
      if (oldVersion < addition.$1) {
        await addColumn(addition.$2, notNullZero);
      }
    }
    if (oldVersion < 16) {
      await sqlite.backfillPathKeys(db, 'library', 'library_path_keys');
    }
    if (oldVersion < 17) {
      // Reinstall the triggers and repair counts created by older upserts.
      await _createLookupSummary(db);
    }
    if (oldVersion < 18) {
      await addColumn('network_file_version', 'TEXT');
    }
    if (oldVersion < 19) {
      await _createCueSplits(db);
      await _createVisibleView(db);
    }
    if (oldVersion < 20) {
      // Older Ogg reads stopped after 100 comments and could miss gain tags.
      // Re-read only local Ogg songs on the next scan, keeping lyrics known.
      await db.rawUpdate(
        'UPDATE library SET audio_metadata_scan_version = ? '
        'WHERE audio_metadata_scan_version >= ? '
        "AND file_path NOT LIKE 'network://%' "
        "AND (LOWER(format) IN ('opus', 'ogg', 'vorbis') "
        "OR LOWER(file_path) LIKE '%.opus' "
        "OR LOWER(file_path) LIKE '%.ogg')",
        [libraryLyricsMetadataScanVersion, libraryAudioMetadataScanVersion],
      );
    }
  }

  static Future<bool> createSearchFts(DatabaseExecutor db) =>
      sqlite.createTrigramFtsIndex(
        db,
        ftsTable: searchFtsTable,
        contentTable: 'library',
        triggerPrefix: 'library_search_fts',
      );

  static Future<void> _createSources(DatabaseExecutor db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS library_sources (
        id TEXT PRIMARY KEY,
        path TEXT NOT NULL UNIQUE,
        display_name TEXT NOT NULL,
        bookmark TEXT,
        volume_id TEXT,
        is_removable INTEGER NOT NULL DEFAULT 0,
        enabled INTEGER NOT NULL DEFAULT 1,
        available INTEGER NOT NULL DEFAULT 1,
        last_scanned_at TEXT,
        last_seen_at TEXT,
        last_scan_error TEXT
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_library_source_id ON library(source_id)',
    );
    await db.insert('library_sources', {
      'id': _legacySourceId,
      'path': 'legacy://local-library',
      'display_name': 'Music',
      'enabled': 1,
      'available': 1,
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
    await _createCueSplits(db);
    await _createVisibleView(db);
  }

  static Future<void> _createCueSplits(DatabaseExecutor db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS library_cue_split_sources (
        file_path TEXT NOT NULL PRIMARY KEY,
        cue_path TEXT NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS library_cue_split_outputs (
        cue_path TEXT NOT NULL,
        file_path TEXT NOT NULL,
        PRIMARY KEY(cue_path, file_path)
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_cue_split_sources_cue '
      'ON library_cue_split_sources(cue_path)',
    );
  }

  static Future<void> _createVisibleView(DatabaseExecutor db) async {
    await db.execute('DROP VIEW IF EXISTS $visibleView');
    await db.execute('''
      CREATE VIEW $visibleView AS
      SELECT l.* FROM library l
      JOIN library_sources s ON s.id = l.source_id
      WHERE s.enabled = 1 AND s.available = 1
        AND l.file_path NOT IN (
          SELECT c.file_path FROM library_cue_split_sources c
          JOIN (
            SELECT o.cue_path FROM library_cue_split_outputs o
            LEFT JOIN library t ON t.file_path = o.file_path
            LEFT JOIN library_sources ts ON ts.id = t.source_id
              AND ts.enabled = 1 AND ts.available = 1
            GROUP BY o.cue_path
            HAVING COUNT(*) = COUNT(ts.id)
          ) complete ON complete.cue_path = c.cue_path
        )
    ''');
  }

  static Future<void> _createNormalizedIndexes(DatabaseExecutor db) async {
    for (final column in const {
      'match_key': 'match_key',
      'album_key': 'album_key',
      'track_norm': 'track_name_norm',
      'artist_norm': 'artist_name_norm',
      'album_norm': 'album_name_norm',
      'scanned_at': 'scanned_at',
    }.entries) {
      await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_library_${column.key} ON library(${column.value})',
      );
    }
  }

  static Future<void> _createQueueIndexes(DatabaseExecutor db) async {
    for (final order in const {
      'added': 'sort_added DESC, track_name_norm, id',
      'track': 'track_name_norm, artist_name_norm, id',
      'artist': 'artist_name_norm, track_name_norm, id',
      'album': 'album_name_norm, track_name_norm, id',
      'genre': 'sort_genre, track_name_norm, id',
      'release': 'sort_release, track_name_norm, id',
    }.entries) {
      await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_library_queue_${order.key} ON library(${order.value})',
      );
    }
  }

  static Future<void> _backfillNormalizedColumns(Database db) =>
      sqlite.backfillRows(
        db,
        'library',
        const ['track_name', 'artist_name', 'album_name', 'album_artist'],
        (row) => LibraryRowMapper.normalized(
          trackName: row['track_name'] as String? ?? '',
          artistName: row['artist_name'] as String? ?? '',
          albumName: row['album_name'] as String? ?? '',
          albumArtist: row['album_artist'] as String?,
        ),
      );

  static Future<void> _backfillQueueColumns(Database db) => sqlite.backfillRows(
    db,
    'library',
    const [
      'track_name',
      'artist_name',
      'album_name',
      'album_artist',
      'genre',
      'release_date',
      'file_mod_time',
      'scanned_at',
    ],
    (row) => LibraryRowMapper.queue(
      trackName: row['track_name'] as String?,
      artistName: row['artist_name'] as String?,
      albumName: row['album_name'] as String?,
      albumArtist: row['album_artist'] as String?,
      genre: row['genre'] as String?,
      releaseDate: row['release_date'] as String?,
      fileModTime: (row['file_mod_time'] as num?)?.toInt(),
      scannedAt: row['scanned_at'] as String?,
    ),
  );

  static Future<void> _createLookupSummary(DatabaseExecutor db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS $lookupSummaryTable (
        source_id TEXT NOT NULL, kind TEXT NOT NULL,
        value TEXT NOT NULL, ref_count INTEGER NOT NULL,
        PRIMARY KEY (source_id, kind, value)
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_library_lookup_summary_value ON $lookupSummaryTable(kind, value)',
    );
    for (final (kind, column) in const [
      ('isrc', 'isrc'),
      ('match', 'match_key'),
    ]) {
      for (final operation in const ['insert', 'delete', 'update']) {
        await db.execute(
          'DROP TRIGGER IF EXISTS library_lookup_${operation}_$kind',
        );
      }
      await db.execute('''
        CREATE TRIGGER library_lookup_insert_$kind AFTER INSERT ON library
        WHEN NEW.$column IS NOT NULL AND NEW.$column != ''
        BEGIN
          INSERT INTO $lookupSummaryTable(source_id, kind, value, ref_count)
          SELECT NEW.source_id, '$kind', NEW.$column, 0
          -- An outer INSERT OR REPLACE overrides trigger conflict policies.
          -- Avoid a conflicting insert instead of relying on OR IGNORE.
          WHERE NOT EXISTS (
            SELECT 1 FROM $lookupSummaryTable
            WHERE source_id = NEW.source_id AND kind = '$kind' AND value = NEW.$column
          );
          UPDATE $lookupSummaryTable SET ref_count = ref_count + 1
          WHERE source_id = NEW.source_id AND kind = '$kind' AND value = NEW.$column;
        END
      ''');
      await db.execute('''
        CREATE TRIGGER library_lookup_delete_$kind AFTER DELETE ON library
        WHEN OLD.$column IS NOT NULL AND OLD.$column != ''
        BEGIN
          UPDATE $lookupSummaryTable SET ref_count = ref_count - 1
          WHERE source_id = OLD.source_id AND kind = '$kind' AND value = OLD.$column;
          DELETE FROM $lookupSummaryTable
          WHERE source_id = OLD.source_id AND kind = '$kind' AND value = OLD.$column
            AND ref_count <= 0;
        END
      ''');
      await db.execute('''
        CREATE TRIGGER library_lookup_update_$kind AFTER UPDATE OF source_id, $column ON library
        WHEN OLD.source_id IS NOT NEW.source_id OR OLD.$column IS NOT NEW.$column
        BEGIN
          UPDATE $lookupSummaryTable SET ref_count = ref_count - 1
          WHERE OLD.$column IS NOT NULL AND OLD.$column != ''
            AND source_id = OLD.source_id AND kind = '$kind' AND value = OLD.$column;
          DELETE FROM $lookupSummaryTable
          WHERE source_id = OLD.source_id AND kind = '$kind' AND value = OLD.$column
            AND ref_count <= 0;
          INSERT INTO $lookupSummaryTable(source_id, kind, value, ref_count)
          SELECT NEW.source_id, '$kind', NEW.$column, 0
          WHERE NEW.$column IS NOT NULL AND NEW.$column != '' AND NOT EXISTS (
            SELECT 1 FROM $lookupSummaryTable
            WHERE source_id = NEW.source_id AND kind = '$kind' AND value = NEW.$column
          );
          UPDATE $lookupSummaryTable SET ref_count = ref_count + 1
          WHERE NEW.$column IS NOT NULL AND NEW.$column != ''
            AND source_id = NEW.source_id AND kind = '$kind' AND value = NEW.$column;
        END
      ''');
    }
    await db.delete(lookupSummaryTable);
    for (final (kind, column) in const [
      ('isrc', 'isrc'),
      ('match', 'match_key'),
    ]) {
      await db.rawInsert('''
        INSERT INTO $lookupSummaryTable(source_id, kind, value, ref_count)
        SELECT source_id, '$kind', $column, COUNT(*)
        FROM library WHERE $column IS NOT NULL AND $column != ''
        GROUP BY source_id, $column
      ''');
    }
  }

  static Future<void> onOpen(Database db) async {
    await migrateIosContainerPaths(db);
    if (Platform.isWindows) {
      await sqlite.repairWindowsPathKeysOnOpen(
        db,
        'library',
        'library_path_keys',
      );
    }
  }

  static Future<void> migrateIosContainerPaths(Database db) async {
    if (!Platform.isIOS) return;
    final documents = await getApplicationDocumentsDirectory();
    await db.transaction((txn) async {
      final sources = await txn.query(
        'library_sources',
        columns: ['id', 'path'],
        where: "bookmark IS NULL OR bookmark = ''",
      );
      final localSourceIds = sources.map((source) => source['id']).toSet();
      final rows = await txn.query(
        'library',
        columns: ['id', 'source_id', 'file_path', 'cover_path'],
      );
      final batch = txn.batch();
      for (final row in rows) {
        final updates = <String, Object?>{};
        for (final column in ['file_path', 'cover_path']) {
          // External audio paths remain bookmark-owned. Extracted covers
          // always belong to our sandbox, including bookmarked sources.
          if (column == 'file_path' &&
              !localSourceIds.contains(row['source_id'])) {
            continue;
          }
          final previous = row[column] as String?;
          if (previous == null) continue;
          final current = rebaseIosSandboxPath(previous, documents.path);
          if (current != previous) updates[column] = current;
        }
        if (updates.isEmpty) continue;
        final id = row['id'] as String;
        batch.update('library', updates, where: 'id = ?', whereArgs: [id]);
        if (updates.containsKey('file_path')) {
          sqlite.putPathKeysInBatch(
            batch,
            'library_path_keys',
            id,
            updates['file_path'] as String,
          );
        }
      }
      for (final source in sources) {
        final previous = source['path'] as String;
        final current = rebaseIosSandboxPath(previous, documents.path);
        if (current == previous) continue;
        batch.update(
          'library_sources',
          {'path': current},
          where: 'id = ?',
          whereArgs: [source['id']],
        );
      }
      for (final table in const [
        'library_cue_split_sources',
        'library_cue_split_outputs',
      ]) {
        for (final row in await txn.query(table)) {
          final previousPath = row['file_path'] as String;
          final previousCue = row['cue_path'] as String;
          final path = rebaseIosSandboxPath(previousPath, documents.path);
          final cue = rebaseIosSandboxPath(previousCue, documents.path);
          if (path == previousPath && cue == previousCue) continue;
          batch.update(
            table,
            {'file_path': path, 'cue_path': cue},
            where: 'file_path = ? AND cue_path = ?',
            whereArgs: [previousPath, previousCue],
          );
        }
      }
      await batch.commit(noResult: true);
    });
  }
}
