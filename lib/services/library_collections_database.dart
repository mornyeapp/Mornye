import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';
import 'package:mornye/models/library_collections.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/services/collection_restore_codec.dart';
import 'package:mornye/services/link/sync/link_collection_sync_schema.dart';
import 'package:mornye/services/platform_bridge.dart';
import 'package:mornye/services/collection_track_batch.dart';
import 'package:mornye/services/sqlite_helpers.dart' as sqlite;
import 'package:mornye/services/sqlite_native_snapshot.dart';
import 'package:mornye/utils/logger.dart';

final _log = AppLogger('LibraryCollectionsDb');

const _dbFileName = 'library_collections.db';

/// v3 adds Mornye Link change tracking (tables and triggers) beside the
/// unchanged collection tables.
const _dbVersion = 3;

/// Native jobs read and write private copies holding only the collection
/// tables, whose schema is still the one they validate as v2.
const _nativeSchemaVersion = 2;

const _tableWishlist = 'wishlist_tracks';
const _tableLoved = 'loved_tracks';
const _tablePlaylists = 'playlists';
const _tablePlaylistTracks = 'playlist_tracks';
const _tableFavoriteArtists = 'favorite_artists';

const _legacyCollectionsStorageKey = 'library_collections_v1';
const _migrationDoneKey = 'library_collections_migrated_to_sqlite_v1';

class LibraryCollectionsSnapshot {
  final List<Map<String, dynamic>> wishlistRows;
  final List<Map<String, dynamic>> lovedRows;
  final List<Map<String, dynamic>> playlistRows;
  final List<Map<String, dynamic>> playlistTrackRows;
  final List<Map<String, dynamic>> favoriteArtistRows;
  final String? nativeRowsPath;
  final String? nativeRowsDirectory;
  final int? nativeRowCount;

  const LibraryCollectionsSnapshot({
    required this.wishlistRows,
    required this.lovedRows,
    required this.playlistRows,
    required this.playlistTrackRows,
    required this.favoriteArtistRows,
    this.nativeRowsPath,
    this.nativeRowsDirectory,
    this.nativeRowCount,
  });
}

class LibraryPlaylistTracksSnapshot {
  const LibraryPlaylistTracksSnapshot({
    this.rows = const [],
    this.nativeRowsPath,
    this.nativeRowsDirectory,
    this.nativeRowCount,
  });
  final List<Map<String, dynamic>> rows;
  final String? nativeRowsPath;
  final String? nativeRowsDirectory;
  final int? nativeRowCount;
}

typedef NativeCollectionsJobRunner =
    Future<Map<String, dynamic>> Function(Map<String, dynamic> request);

class LibraryCollectionsDatabase {
  static int _restoreAttachmentSequence = 0;
  static final LibraryCollectionsDatabase instance =
      LibraryCollectionsDatabase._init();
  static final sqlite.SingleFlightInitializer<Database> _database =
      sqlite.SingleFlightInitializer<Database>();

  final Future<SharedPreferences> _prefs = SharedPreferences.getInstance();
  final Database? _databaseOverride;

  LibraryCollectionsDatabase._init() : _databaseOverride = null;

  /// Uses an already open [database] (tests open it with
  /// [openWithFactory]).
  @visibleForTesting
  LibraryCollectionsDatabase.withDatabase(Database database)
    : _databaseOverride = database;

  /// Keeps saved playlists and likes attached to a scanned track after a move.
  /// Occurrence prefixes and ordering survive; ISRC membership keys stay stable.
  Future<void> relinkLocalTrack(String oldId, String newId) async {
    if (oldId == newId) return;
    final db = await database;
    await sqlite.transactionWithBusyRetry(db, (txn) async {
      for (final table in [_tableWishlist, _tableLoved, _tablePlaylistTracks]) {
        var after = 0;
        while (true) {
          final rows = await txn.query(
            table,
            columns: ['rowid', 'track_key', 'track_json'],
            // Prefilter serialized values, then verify the field in Dart. This
            // also works on system SQLite builds without JSON functions.
            where: 'rowid > ? AND instr(track_json, ?) > 0',
            whereArgs: [after, jsonEncode(oldId)],
            orderBy: 'rowid',
            limit: 200,
          );
          if (rows.isEmpty) break;
          after = rows.last['rowid'] as int;
          for (final row in rows) {
            final track = _decodeTrack(row['track_json']);
            if (track == null || track.source != 'local' || track.id != oldId) {
              continue;
            }
            final previousKey = trackCollectionKey(track);
            final updated = track.copyWith(id: newId);
            final nextKey = trackCollectionKey(updated);
            final key = row['track_key'] as String;
            final renamedKey = key == previousKey
                ? nextKey
                : key.startsWith('occurrence:') && key.endsWith(':$previousKey')
                ? '${key.substring(0, key.length - previousKey.length)}$nextKey'
                : key;
            await txn.update(
              table,
              {
                'track_key': renamedKey,
                'track_json': jsonEncode(updated.toJson()),
              },
              where: 'rowid = ?',
              whereArgs: [row['rowid']],
            );
          }
        }
      }
    });
  }

  /// Opens [path] with the app schema and connection settings through
  /// [factory], for host tests that use FFI.
  @visibleForTesting
  static Future<Database> openWithFactory(
    DatabaseFactory factory,
    String path,
  ) => factory.openDatabase(
    path,
    options: OpenDatabaseOptions(
      version: _dbVersion,
      onConfigure: (db) async {
        await db.execute('PRAGMA foreign_keys = ON');
        await db.execute('PRAGMA recursive_triggers = ON');
      },
      onCreate: _createDb,
      onUpgrade: _upgradeDb,
    ),
  );

  Future<Database> get database {
    final override = _databaseOverride;
    if (override != null) return Future.value(override);
    return _database.getOrCreate(
      () => sqlite.openAppDatabase(
        _dbFileName,
        version: _dbVersion,
        foreignKeys: true,
        onCreate: _createDb,
        onUpgrade: _upgradeDb,
      ),
    );
  }

  static Future<void> _createDb(Database db, int version) async {
    _log.i('Creating collections database schema v$version');
    await _createCollectionTables(db);
    await createLinkCollectionSyncSchema(db);
  }

  /// The collection tables alone, as native jobs expect them (v2).
  static Future<void> _createCollectionTables(Database db) async {
    await db.execute('''
      CREATE TABLE $_tableWishlist (
        track_key TEXT PRIMARY KEY,
        track_json TEXT NOT NULL,
        added_at TEXT NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE $_tableLoved (
        track_key TEXT PRIMARY KEY,
        track_json TEXT NOT NULL,
        added_at TEXT NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE $_tablePlaylists (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        cover_image_path TEXT,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE $_tablePlaylistTracks (
        playlist_id TEXT NOT NULL,
        track_key TEXT NOT NULL,
        track_json TEXT NOT NULL,
        added_at TEXT NOT NULL,
        PRIMARY KEY (playlist_id, track_key),
        FOREIGN KEY (playlist_id) REFERENCES $_tablePlaylists(id) ON DELETE CASCADE
      )
    ''');

    await _createFavoriteArtistsTable(db);

    await db.execute(
      'CREATE INDEX idx_${_tableWishlist}_added_at ON $_tableWishlist(added_at DESC)',
    );
    await db.execute(
      'CREATE INDEX idx_${_tableLoved}_added_at ON $_tableLoved(added_at DESC)',
    );
    await db.execute(
      'CREATE INDEX idx_${_tablePlaylists}_created_at ON $_tablePlaylists(created_at DESC)',
    );
    await db.execute(
      'CREATE INDEX idx_${_tablePlaylistTracks}_playlist_id ON $_tablePlaylistTracks(playlist_id)',
    );
    await db.execute(
      'CREATE INDEX idx_${_tablePlaylistTracks}_added_at ON $_tablePlaylistTracks(added_at DESC)',
    );
  }

  static Future<void> _upgradeDb(
    Database db,
    int oldVersion,
    int newVersion,
  ) async {
    _log.i('Upgrading collections database from v$oldVersion to v$newVersion');
    if (oldVersion < 2) {
      await _createFavoriteArtistsTable(db);
    }
    if (oldVersion < 3) {
      await createLinkCollectionSyncSchema(db);
    }
  }

  static Future<void> _createFavoriteArtistsTable(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS $_tableFavoriteArtists (
        artist_key TEXT PRIMARY KEY,
        artist_json TEXT NOT NULL,
        added_at TEXT NOT NULL
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_${_tableFavoriteArtists}_added_at ON $_tableFavoriteArtists(added_at DESC)',
    );
  }

  Future<bool> migrateFromSharedPreferences() async {
    final prefs = await _prefs;
    if (prefs.getBool(_migrationDoneKey) == true) {
      return false;
    }

    final raw = prefs.getString(_legacyCollectionsStorageKey);
    if (raw == null || raw.isEmpty) {
      await prefs.setBool(_migrationDoneKey, true);
      return false;
    }

    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) {
        await prefs.setBool(_migrationDoneKey, true);
        return false;
      }

      final root = Map<String, dynamic>.from(decoded);
      final wishlistRaw = (root['wishlist'] as List?) ?? const [];
      final lovedRaw = (root['loved'] as List?) ?? const [];
      final playlistsRaw = (root['playlists'] as List?) ?? const [];
      final nowIso = DateTime.now().toIso8601String();

      final db = await database;
      await db.transaction((txn) async {
        for (final entry in wishlistRaw.whereType<Map<Object?, Object?>>()) {
          final map = Map<String, dynamic>.from(entry);
          final trackKey = map['key'] as String?;
          final track = map['track'];
          if (trackKey == null || track is! Map<Object?, Object?>) continue;
          final addedAt = (map['addedAt'] as String?) ?? nowIso;
          await txn.insert(_tableWishlist, {
            'track_key': trackKey,
            'track_json': jsonEncode(track),
            'added_at': addedAt,
          }, conflictAlgorithm: ConflictAlgorithm.replace);
        }

        for (final entry in lovedRaw.whereType<Map<Object?, Object?>>()) {
          final map = Map<String, dynamic>.from(entry);
          final trackKey = map['key'] as String?;
          final track = map['track'];
          if (trackKey == null || track is! Map<Object?, Object?>) continue;
          final addedAt = (map['addedAt'] as String?) ?? nowIso;
          await txn.insert(_tableLoved, {
            'track_key': trackKey,
            'track_json': jsonEncode(track),
            'added_at': addedAt,
          }, conflictAlgorithm: ConflictAlgorithm.replace);
        }

        for (final playlistEntry
            in playlistsRaw.whereType<Map<Object?, Object?>>()) {
          final playlist = Map<String, dynamic>.from(playlistEntry);
          final playlistId = playlist['id'] as String?;
          if (playlistId == null || playlistId.isEmpty) continue;

          final createdAt = (playlist['createdAt'] as String?) ?? nowIso;
          final updatedAt = (playlist['updatedAt'] as String?) ?? createdAt;
          await txn.insert(_tablePlaylists, {
            'id': playlistId,
            'name': (playlist['name'] as String?) ?? '',
            'cover_image_path': playlist['coverImagePath'] as String?,
            'created_at': createdAt,
            'updated_at': updatedAt,
          }, conflictAlgorithm: ConflictAlgorithm.replace);

          final tracksRaw = (playlist['tracks'] as List?) ?? const [];
          for (final trackEntry
              in tracksRaw.whereType<Map<Object?, Object?>>()) {
            final trackMap = Map<String, dynamic>.from(trackEntry);
            final trackKey = trackMap['key'] as String?;
            final track = trackMap['track'];
            if (trackKey == null || track is! Map<Object?, Object?>) continue;
            final addedAt = (trackMap['addedAt'] as String?) ?? nowIso;
            await txn.insert(_tablePlaylistTracks, {
              'playlist_id': playlistId,
              'track_key': trackKey,
              'track_json': jsonEncode(track),
              'added_at': addedAt,
            }, conflictAlgorithm: ConflictAlgorithm.replace);
          }
        }
      });

      await prefs.setBool(_migrationDoneKey, true);
      _log.i('Migrated legacy collections data to SQLite');
      return true;
    } catch (e, stack) {
      _log.e('Failed migrating collections to SQLite: $e', e, stack);
      return false;
    }
  }

  Future<LibraryCollectionsSnapshot> loadSnapshot() async =>
      readDatabaseSnapshot(await database);

  static Future<LibraryCollectionsSnapshot> readDatabaseSnapshot(
    Database db, {
    NativeCollectionsJobRunner? nativeJobRunner,
    Directory? temporaryDirectory,
    bool forceLegacy = false,
  }) async {
    if (!forceLegacy &&
        (nativeJobRunner != null || PlatformBridge.supportsCoreBackend)) {
      final probe = await db.rawQuery('''
        SELECT 1 FROM $_tableWishlist UNION ALL SELECT 1 FROM $_tableLoved
        UNION ALL SELECT 1 FROM $_tablePlaylists
        UNION ALL SELECT 1 FROM $_tablePlaylistTracks
        UNION ALL SELECT 1 FROM $_tableFavoriteArtists LIMIT 64
      ''');
      if (probe.length == 64) {
        return _readNativeRows(
          db,
          nativeJobRunner: nativeJobRunner,
          temporaryDirectory: temporaryDirectory,
        );
      }
    }
    return db.transaction((txn) async {
      final wishlistRows = await _readDateOrderedRows(
        txn,
        _tableWishlist,
        'added_at',
      );
      final lovedRows = await _readDateOrderedRows(
        txn,
        _tableLoved,
        'added_at',
      );
      final playlistRows = await _readDateOrderedRows(
        txn,
        _tablePlaylists,
        'created_at',
        projection:
            '''p.*,
        CASE WHEN p.cover_image_path IS NULL OR p.cover_image_path = '' THEN (
          SELECT pt.track_json
          FROM $_tablePlaylistTracks pt
          WHERE pt.playlist_id = p.id
          ORDER BY pt.added_at ASC, pt.rowid ASC
          LIMIT 1
        ) END AS preview_track_json''',
        alias: 'p',
      );
      final playlistTrackRows = <Map<String, dynamic>>[];
      Object? lastId;
      int? lastRowId;
      while (true) {
        final page = await txn.rawQuery('''
          SELECT rowid AS __collection_rowid, playlist_id, track_key
          FROM $_tablePlaylistTracks
          ${lastRowId == null ? '' : 'WHERE playlist_id>? OR (playlist_id=? AND rowid>?)'}
          ORDER BY playlist_id ASC,rowid ASC LIMIT 256
        ''', lastRowId == null ? const [] : [lastId, lastId, lastRowId]);
        if (page.isEmpty) break;
        lastId = page.last['playlist_id'];
        lastRowId = page.last['__collection_rowid'] as int;
        playlistTrackRows.addAll(page.map(_withoutRowCursor));
        if (page.length < 256) break;
      }
      final favoriteArtistRows = await _readDateOrderedRows(
        txn,
        _tableFavoriteArtists,
        'added_at',
      );
      return LibraryCollectionsSnapshot(
        wishlistRows: wishlistRows,
        lovedRows: lovedRows,
        playlistRows: playlistRows,
        playlistTrackRows: playlistTrackRows,
        favoriteArtistRows: favoriteArtistRows,
      );
    });
  }

  Future<LibraryPlaylistTracksSnapshot> loadPlaylistTracksSnapshot(
    String playlistId,
  ) async => readDatabasePlaylistTracks(await database, playlistId);

  static Future<LibraryPlaylistTracksSnapshot> readDatabasePlaylistTracks(
    Database db,
    String playlistId, {
    NativeCollectionsJobRunner? nativeJobRunner,
    Directory? temporaryDirectory,
    bool forceLegacy = false,
  }) async {
    if (!forceLegacy &&
        (nativeJobRunner != null || PlatformBridge.supportsCoreBackend)) {
      final probe = await db.rawQuery(
        'SELECT 1 FROM $_tablePlaylistTracks WHERE playlist_id=? LIMIT 64',
        [playlistId],
      );
      if (probe.length == 64) {
        final snapshot = await _readNativeRows(
          db,
          playlistId: playlistId,
          nativeJobRunner: nativeJobRunner,
          temporaryDirectory: temporaryDirectory,
        );
        return LibraryPlaylistTracksSnapshot(
          nativeRowsPath: snapshot.nativeRowsPath,
          nativeRowsDirectory: snapshot.nativeRowsDirectory,
          nativeRowCount: snapshot.nativeRowCount,
        );
      }
    }
    final rows = await db.transaction(
      (txn) => _readDateOrderedRows(
        txn,
        _tablePlaylistTracks,
        'added_at',
        ascending: true,
        where: 'playlist_id=?',
        whereArgs: [playlistId],
      ),
    );
    return LibraryPlaylistTracksSnapshot(rows: rows);
  }

  static Map<String, dynamic> _withoutRowCursor(Map<String, Object?> row) =>
      Map<String, dynamic>.from(row)..remove('__collection_rowid');

  static Future<List<Map<String, dynamic>>> _readDateOrderedRows(
    DatabaseExecutor db,
    String table,
    String dateColumn, {
    bool ascending = false,
    String projection = '*',
    String? alias,
    String? where,
    List<Object?> whereArgs = const [],
  }) async {
    final rows = <Map<String, dynamic>>[];
    final qualifier = alias == null ? '' : '$alias.';
    final comparison = ascending ? '>' : '<';
    final direction = ascending ? 'ASC' : 'DESC';
    Object? lastDate;
    int? lastRowId;
    while (true) {
      final predicates = [
        if (where != null) '($where)',
        if (lastRowId != null)
          '($qualifier$dateColumn$comparison? OR ($qualifier$dateColumn=? AND ${qualifier}rowid$comparison?))',
      ];
      final page = await db.rawQuery(
        '''
        SELECT ${qualifier}rowid AS __collection_rowid, $projection
        FROM $table ${alias ?? ''}
        ${predicates.isEmpty ? '' : 'WHERE ${predicates.join(' AND ')}'}
        ORDER BY $qualifier$dateColumn $direction,${qualifier}rowid $direction LIMIT 256
      ''',
        [
          ...whereArgs,
          if (lastRowId != null) ...[lastDate, lastDate, lastRowId],
        ],
      );
      if (page.isEmpty) break;
      lastDate = page.last[dateColumn];
      lastRowId = page.last['__collection_rowid'] as int;
      rows.addAll(page.map(_withoutRowCursor));
      if (page.length < 256) break;
    }
    return rows;
  }

  static Future<LibraryCollectionsSnapshot> _readNativeRows(
    Database db, {
    String? playlistId,
    NativeCollectionsJobRunner? nativeJobRunner,
    Directory? temporaryDirectory,
  }) async {
    final temporary =
        await (temporaryDirectory ?? await getTemporaryDirectory()).createTemp(
          'collection-read-',
        );
    final path = '${temporary.path}/rows.ndjson';
    try {
      final snapshotPath = '${temporary.path}/$_dbFileName';
      await _projectCollectionReadDatabase(
        db,
        snapshotPath,
        playlistId: playlistId,
      );
      final request = <String, dynamic>{
        'operation': 'collections_snapshot',
        'collections_path': snapshotPath,
        'output_path': path,
        'playlist_id': ?playlistId,
      };
      final result = await (nativeJobRunner ?? PlatformBridge.runNativeDataJob)(
        request,
      );
      final counts = result['counts'];
      if (result['published'] != true ||
          result['rows_path'] != path ||
          counts is! Map) {
        throw const FormatException('Invalid native collection snapshot');
      }
      var total = 0;
      for (final count in counts.values) {
        if (count is! int || count < 0) {
          throw const FormatException('Invalid native collection row count');
        }
        total += count;
      }
      return LibraryCollectionsSnapshot(
        wishlistRows: const [],
        lovedRows: const [],
        playlistRows: const [],
        playlistTrackRows: const [],
        favoriteArtistRows: const [],
        nativeRowsPath: path,
        nativeRowsDirectory: temporary.path,
        nativeRowCount: total,
      );
    } on NativeSqliteSnapshotDetachException {
      _log.w(
        'Retaining collection read staging after a failed database detach',
      );
      rethrow;
    } catch (_) {
      await temporary.delete(recursive: true);
      rethrow;
    }
  }

  static final _collectionProjectionQueue = Expando<Future<void>>();
  static var _collectionProjectionSequence = 0;

  /// Both the live database and this projection are owned by the same SQLite
  /// engine during copying. DETACH closes its private file before Rust opens
  /// it; independent SQLite copies must never share a live app database.
  static Future<void> _projectCollectionReadDatabase(
    Database db,
    String outputPath, {
    String? playlistId,
  }) async {
    final previous = _collectionProjectionQueue[db];
    final finished = Completer<void>();
    _collectionProjectionQueue[db] = finished.future;
    if (previous != null) await previous;
    final alias = 'collection_read_${_collectionProjectionSequence++}';
    var attached = false;
    try {
      await db.execute('ATTACH DATABASE ? AS $alias', [outputPath]);
      attached = true;
      await db.transaction((txn) async {
        for (final table in [
          _tableWishlist,
          _tableLoved,
          _tableFavoriteArtists,
          _tablePlaylists,
          _tablePlaylistTracks,
        ]) {
          final where = playlistId == null
              ? ''
              : table == _tablePlaylists
              ? 'WHERE id=?'
              : table == _tablePlaylistTracks
              ? 'WHERE playlist_id=?'
              : 'WHERE 0';
          // CTAS copies every original column and value. Inserting in original
          // rowid order preserves all date-tie and membership ordering without
          // transferring any collection rows through the platform channel.
          await txn.execute(
            'CREATE TABLE $alias.$table AS '
            'SELECT * FROM main.$table $where ORDER BY rowid ASC',
            where.contains('?') ? [playlistId] : const [],
          );
        }
        await txn.execute('PRAGMA $alias.user_version=$_nativeSchemaVersion');
        await txn.execute(
          'CREATE INDEX $alias.collection_read_members '
          'ON $_tablePlaylistTracks(playlist_id)',
        );
        await txn.execute(
          'CREATE INDEX $alias.collection_read_preview '
          'ON $_tablePlaylistTracks(playlist_id,added_at)',
        );
      });
    } finally {
      try {
        if (attached) {
          await detachNativeSqliteSnapshot(db, alias, outputPath);
        }
      } finally {
        finished.complete();
      }
    }
  }

  Future<List<PlaylistPickerSummary>> loadPlaylistPickerSummaries(
    List<String> requestedTrackKeys,
  ) async => readPlaylistPickerSummaries(await database, requestedTrackKeys);

  // Media browsers read bounded lists straight from SQLite: the snapshot's
  // native job needs the backend channel an Activity registers.

  /// Loved songs, the most recently loved first.
  Future<List<Track>> loadLovedTracks({int limit = 500}) async => _decodeTracks(
    await (await database).rawQuery(
      'SELECT track_json FROM $_tableLoved '
      'ORDER BY added_at DESC, rowid DESC LIMIT ?',
      [limit],
    ),
  );

  Future<bool> containsLovedTrack(String trackKey) async =>
      (await (await database).rawQuery(
        'SELECT 1 FROM $_tableLoved WHERE track_key = ? LIMIT 1',
        [trackKey],
      )).isNotEmpty;

  /// Playlists, the newest first, with their song count and the artwork URL
  /// of their first song.
  Future<List<({String id, String name, int trackCount, String? coverUrl})>>
  loadPlaylistSummaries() async {
    final rows = await (await database).rawQuery('''
      SELECT p.id, p.name,
        (SELECT COUNT(*) FROM $_tablePlaylistTracks pt
          WHERE pt.playlist_id = p.id) AS track_count,
        (SELECT pt.track_json FROM $_tablePlaylistTracks pt
          WHERE pt.playlist_id = p.id
          ORDER BY pt.added_at ASC, pt.rowid ASC LIMIT 1) AS first_track_json
      FROM $_tablePlaylists p
      ORDER BY p.created_at DESC, p.rowid DESC
    ''');
    return [
      for (final row in rows)
        (
          id: row['id'] as String,
          name: row['name'] as String? ?? '',
          trackCount: (row['track_count'] as num?)?.toInt() ?? 0,
          coverUrl: _decodeTrack(row['first_track_json'])?.coverUrl,
        ),
    ];
  }

  /// A playlist's songs in playlist order.
  Future<List<Track>> loadPlaylistTracks(
    String playlistId, {
    int limit = 500,
  }) async => _decodeTracks(
    await (await database).rawQuery(
      'SELECT track_json FROM $_tablePlaylistTracks WHERE playlist_id = ? '
      'ORDER BY added_at ASC, rowid ASC LIMIT ?',
      [playlistId, limit],
    ),
  );

  static List<Track> _decodeTracks(List<Map<String, Object?>> rows) => [
    for (final row in rows) ?_decodeTrack(row['track_json']),
  ];

  static Track? _decodeTrack(Object? json) {
    if (json is! String || json.isEmpty) return null;
    try {
      final decoded = jsonDecode(json);
      return decoded is Map
          ? Track.fromJson(Map<String, dynamic>.from(decoded))
          : null;
    } catch (_) {
      return null;
    }
  }

  Future<void> _upsertEntry(
    String table,
    String prefix, {
    required String key,
    required String json,
    required String addedAt,
  }) async {
    final db = await database;
    await db.insert(table, {
      '${prefix}_key': key,
      '${prefix}_json': json,
      'added_at': addedAt,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> _deleteEntry(String table, String prefix, String key) async {
    final db = await database;
    await db.delete(table, where: '${prefix}_key = ?', whereArgs: [key]);
  }

  Future<void> upsertWishlistEntry({
    required String trackKey,
    required String trackJson,
    required String addedAt,
  }) => _upsertEntry(
    _tableWishlist,
    'track',
    key: trackKey,
    json: trackJson,
    addedAt: addedAt,
  );

  Future<void> deleteWishlistEntry(String trackKey) =>
      _deleteEntry(_tableWishlist, 'track', trackKey);

  Future<void> deleteWishlistTracks(List<String> keys) async {
    if (keys.isEmpty) return;
    await deleteDatabaseWishlistTracks(await database, keys);
  }

  static Future<void> deleteDatabaseWishlistTracks(
    Database db,
    List<String> keys,
  ) async {
    if (keys.isEmpty) return;
    await sqlite.transactionWithBusyRetry(
      db,
      (txn) => _deleteTrackKeys(txn, _tableWishlist, keys),
    );
  }

  Future<void> upsertLovedEntry({
    required String trackKey,
    required String trackJson,
    required String addedAt,
  }) => _upsertEntry(
    _tableLoved,
    'track',
    key: trackKey,
    json: trackJson,
    addedAt: addedAt,
  );

  Future<void> deleteLovedEntry(String trackKey) =>
      _deleteEntry(_tableLoved, 'track', trackKey);

  Future<void> upsertLovedTracksBatch(List<Map<String, String>> tracks) async {
    if (tracks.isEmpty) return;
    await writeDatabaseLovedTracks(await database, tracks);
  }

  static Future<void> writeDatabaseLovedTracks(
    Database db,
    List<Map<String, String>> tracks,
  ) async {
    if (tracks.isEmpty) return;
    await sqlite.transactionWithBusyRetry(db, (txn) async {
      for (var start = 0; start < tracks.length; start += 128) {
        final batch = txn.batch();
        for (final row in tracks.skip(start).take(128)) {
          batch.insert(
            _tableLoved,
            row,
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
        }
        await batch.commit(noResult: true);
      }
    });
  }

  Future<void> upsertLovedTracksFile({
    required String addedAt,
    required String rowsPath,
    required int expectedCount,
  }) async => publishLovedBatch(
    database: await database,
    addedAt: addedAt,
    rowsPath: rowsPath,
    expectedCount: expectedCount,
  );

  Future<void> deleteLovedTracks(List<String> keys) async {
    if (keys.isEmpty) return;
    await deleteDatabaseLovedTracks(await database, keys);
  }

  static Future<void> deleteDatabaseLovedTracks(
    Database db,
    List<String> keys,
  ) async {
    if (keys.isEmpty) return;
    await sqlite.transactionWithBusyRetry(
      db,
      (txn) => _deleteTrackKeys(txn, _tableLoved, keys),
    );
  }

  static Future<void> _deleteTrackKeys(
    DatabaseExecutor db,
    String table,
    List<String> keys, {
    String? playlistId,
  }) async {
    for (var start = 0; start < keys.length; start += 128) {
      final end = start + 128 < keys.length ? start + 128 : keys.length;
      final chunk = keys.sublist(start, end);
      await db.delete(
        table,
        where:
            '${playlistId == null ? '' : 'playlist_id = ? AND '}track_key IN (${List.filled(chunk.length, '?').join(',')})',
        whereArgs: [?playlistId, ...chunk],
      );
    }
  }

  Future<void> upsertFavoriteArtistEntry({
    required String artistKey,
    required String artistJson,
    required String addedAt,
  }) => _upsertEntry(
    _tableFavoriteArtists,
    'artist',
    key: artistKey,
    json: artistJson,
    addedAt: addedAt,
  );

  Future<void> deleteFavoriteArtistEntry(String artistKey) =>
      _deleteEntry(_tableFavoriteArtists, 'artist', artistKey);

  Future<void> upsertPlaylist({
    required String id,
    required String name,
    required String createdAt,
    required String updatedAt,
    String? coverImagePath,
  }) async {
    final db = await database;
    await db.insert(_tablePlaylists, {
      'id': id,
      'name': name,
      'cover_image_path': coverImagePath,
      'created_at': createdAt,
      'updated_at': updatedAt,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> renamePlaylist({
    required String playlistId,
    required String name,
    required String updatedAt,
  }) async {
    final db = await database;
    await db.update(
      _tablePlaylists,
      {'name': name, 'updated_at': updatedAt},
      where: 'id = ?',
      whereArgs: [playlistId],
    );
  }

  Future<void> updatePlaylistCover({
    required String playlistId,
    required String updatedAt,
    String? coverImagePath,
  }) async {
    final db = await database;
    await db.update(
      _tablePlaylists,
      {'cover_image_path': coverImagePath, 'updated_at': updatedAt},
      where: 'id = ?',
      whereArgs: [playlistId],
    );
  }

  Future<void> deletePlaylists(List<String> playlistIds) async {
    if (playlistIds.isEmpty) return;
    await deleteDatabasePlaylists(await database, playlistIds);
  }

  /// Delete selected parents together; the owner's foreign-key cascade removes
  /// their track memberships without loading track metadata into Dart.
  static Future<void> deleteDatabasePlaylists(
    Database db,
    List<String> playlistIds,
  ) async {
    if (playlistIds.isEmpty) return;
    await sqlite.transactionWithBusyRetry(db, (txn) async {
      for (var start = 0; start < playlistIds.length; start += 128) {
        final end = start + 128 < playlistIds.length
            ? start + 128
            : playlistIds.length;
        final ids = playlistIds.sublist(start, end);
        await txn.delete(
          _tablePlaylists,
          where: 'id IN (${List.filled(ids.length, '?').join(',')})',
          whereArgs: ids,
        );
      }
    });
  }

  Future<void> upsertPlaylistTrack({
    required String playlistId,
    required String trackKey,
    required String trackJson,
    required String addedAt,
    required String playlistUpdatedAt,
  }) async {
    final db = await database;
    await db.transaction((txn) async {
      await txn.insert(_tablePlaylistTracks, {
        'playlist_id': playlistId,
        'track_key': trackKey,
        'track_json': trackJson,
        'added_at': addedAt,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      await txn.update(
        _tablePlaylists,
        {'updated_at': playlistUpdatedAt},
        where: 'id = ?',
        whereArgs: [playlistId],
      );
    });
  }

  Future<void> upsertPlaylistTracksBatch({
    required String playlistId,
    required String playlistUpdatedAt,
    required List<Map<String, String>> tracks,
  }) async {
    if (tracks.isEmpty) return;
    await writeDatabasePlaylistTracks(
      await database,
      playlistId: playlistId,
      playlistUpdatedAt: playlistUpdatedAt,
      tracks: tracks,
    );
  }

  static Future<void> writeDatabasePlaylistTracks(
    Database db, {
    required String playlistId,
    required String playlistUpdatedAt,
    required List<Map<String, String>> tracks,
  }) async {
    if (tracks.isEmpty) return;
    await sqlite.transactionWithBusyRetry(db, (txn) async {
      var batch = txn.batch();
      var pending = 0;
      for (final track in tracks) {
        batch.insert(_tablePlaylistTracks, {
          'playlist_id': playlistId,
          'track_key': track['track_key'],
          'track_json': track['track_json'],
          'added_at': track['added_at'],
        }, conflictAlgorithm: ConflictAlgorithm.replace);
        if (++pending == 128) {
          await batch.commit(noResult: true);
          batch = txn.batch();
          pending = 0;
        }
      }
      batch.update(
        _tablePlaylists,
        {'updated_at': playlistUpdatedAt},
        where: 'id = ?',
        whereArgs: [playlistId],
      );
      await batch.commit(noResult: true);
    });
  }

  Future<void> upsertPlaylistTracksFile({
    required String playlistId,
    required String playlistUpdatedAt,
    required String rowsPath,
    required int expectedCount,
  }) async => publishPlaylistBatch(
    database: await database,
    playlistId: playlistId,
    updatedAt: playlistUpdatedAt,
    rowsPath: rowsPath,
    expectedCount: expectedCount,
  );

  Future<void> deletePlaylistTracks({
    required String playlistId,
    required List<String> trackKeys,
    required String playlistUpdatedAt,
  }) async {
    if (trackKeys.isEmpty) return;
    await deleteDatabasePlaylistTracks(
      await database,
      playlistId: playlistId,
      trackKeys: trackKeys,
      playlistUpdatedAt: playlistUpdatedAt,
    );
  }

  static Future<void> deleteDatabasePlaylistTracks(
    Database db, {
    required String playlistId,
    required List<String> trackKeys,
    required String playlistUpdatedAt,
  }) async {
    if (trackKeys.isEmpty) return;
    await sqlite.transactionWithBusyRetry(db, (txn) async {
      await _deleteTrackKeys(
        txn,
        _tablePlaylistTracks,
        trackKeys,
        playlistId: playlistId,
      );
      await txn.update(
        _tablePlaylists,
        {'updated_at': playlistUpdatedAt},
        where: 'id = ?',
        whereArgs: [playlistId],
      );
    });
  }

  /// Playlist order is the `added_at` order, which Link sync also carries,
  /// so a reorder rewrites those stamps instead of adding a position column.
  Future<void> reorderPlaylistTracks({
    required String playlistId,
    required Map<String, String> addedAtByKey,
    required String playlistUpdatedAt,
  }) async {
    if (addedAtByKey.isEmpty) return;
    final db = await database;
    await sqlite.transactionWithBusyRetry(db, (txn) async {
      var batch = txn.batch();
      var pending = 0;
      for (final MapEntry(:key, :value) in addedAtByKey.entries) {
        batch.update(
          _tablePlaylistTracks,
          {'added_at': value},
          where: 'playlist_id = ? AND track_key = ?',
          whereArgs: [playlistId, key],
        );
        if (++pending == 128) {
          await batch.commit(noResult: true);
          batch = txn.batch();
          pending = 0;
        }
      }
      batch.update(
        _tablePlaylists,
        {'updated_at': playlistUpdatedAt},
        where: 'id = ?',
        whereArgs: [playlistId],
      );
      await batch.commit(noResult: true);
    });
  }

  /// Updates only ordering stamps, retaining membership and track metadata.
  /// The existing collection triggers publish the change to Link atomically.
  Future<void> reorderSavedTracks({
    required LibraryTracksFolderMode mode,
    required Map<String, String> addedAtByKey,
  }) async {
    final table = switch (mode) {
      LibraryTracksFolderMode.loved => _tableLoved,
      LibraryTracksFolderMode.wishlist => _tableWishlist,
      LibraryTracksFolderMode.playlist => throw ArgumentError.value(mode),
    };
    if (addedAtByKey.isEmpty) return;
    await sqlite.transactionWithBusyRetry(await database, (txn) async {
      var batch = txn.batch();
      var pending = 0;
      for (final MapEntry(:key, :value) in addedAtByKey.entries) {
        batch.update(
          table,
          {'added_at': value},
          where: 'track_key = ?',
          whereArgs: [key],
        );
        if (++pending == 128) {
          await batch.commit(noResult: true);
          batch = txn.batch();
          pending = 0;
        }
      }
      if (pending > 0) await batch.commit(noResult: true);
    });
  }

  /// Wipes every collection table and rewrites them from a restored backup.
  ///
  /// [collectionsJson] must use the same shape as
  /// `LibraryCollectionsState.toJson()` (wishlist/loved/playlists/favoriteArtists).
  /// Track entries carry a nested `track` map (stored as `track_json`); favorite
  /// artist entries are stored whole as `artist_json`.
  Future<void> replaceAllFromBackup(
    Map<String, dynamic> collectionsJson,
  ) async {
    final nowIso = DateTime.now().toIso8601String();
    await replaceDatabaseFromBackup(
      await database,
      collectionsJson,
      nowIso: nowIso,
    );
  }

  /// Shares the production restore route with isolated database integration
  /// fixtures. The caller initializes the app-owned schema before native IO.
  static Future<void> replaceDatabaseFromBackup(
    Database db,
    Map<String, dynamic> collectionsJson, {
    String? nowIso,
  }) async {
    final restoreTime = nowIso ?? DateTime.now().toIso8601String();
    if (PlatformBridge.supportsCoreBackend) {
      final temporary = await Directory(
        (await getTemporaryDirectory()).path,
      ).createTemp('collection-restore-');
      var detached = true;
      try {
        final path = '${temporary.path}/commands.ndjson';
        final count = await writeCollectionRestoreCommands(
          path,
          collectionsJson,
          restoreTime,
        );
        // The native backend bundles its own SQLite. Give it a private file
        // after sqflite closes that file; only the database owner publishes
        // into the live database, preserving its WAL and connection caches.
        final stagedPath = '${temporary.path}/$_dbFileName';
        sqlite.ensureAppDatabaseFactory();
        // Staging holds only the collection tables: the live database's
        // triggers record the published rows.
        final stagedDatabase = await openDatabase(
          stagedPath,
          version: _nativeSchemaVersion,
          onConfigure: (staged) => staged.execute('PRAGMA foreign_keys=ON'),
          onCreate: (staged, _) => _createCollectionTables(staged),
        );
        detached = false;
        await stagedDatabase.close();
        detached = true;
        final result = await PlatformBridge.runNativeDataJob({
          'operation': 'backup_collections_import',
          'collections_path': stagedPath,
          'ndjson_path': path,
          'expected_count': count,
        });
        if (result['committed'] != true) {
          throw const FormatException('Incomplete collection restore');
        }
        final alias = 'collection_restore_${_restoreAttachmentSequence++}';
        await db.execute('ATTACH DATABASE ? AS $alias', [stagedPath]);
        var committed = false;
        try {
          await db.transaction((txn) async {
            for (final table in [
              _tablePlaylistTracks,
              _tablePlaylists,
              _tableWishlist,
              _tableLoved,
              _tableFavoriteArtists,
            ]) {
              await txn.delete(table);
            }
            for (final (table, columns) in [
              (_tableWishlist, 'track_key,track_json,added_at'),
              (_tableLoved, 'track_key,track_json,added_at'),
              (_tableFavoriteArtists, 'artist_key,artist_json,added_at'),
              (
                _tablePlaylists,
                'id,name,cover_image_path,created_at,updated_at',
              ),
              (
                _tablePlaylistTracks,
                'playlist_id,track_key,track_json,added_at',
              ),
            ]) {
              await txn.execute(
                'INSERT INTO main.$table($columns) '
                'SELECT $columns FROM $alias.$table ORDER BY rowid',
              );
            }
          });
          committed = true;
        } finally {
          try {
            await detachNativeSqliteSnapshot(db, alias, stagedPath);
          } on NativeSqliteSnapshotDetachException {
            detached = false;
            if (!committed) rethrow;
            _log.w(
              'Collections restored; retaining staging after a failed database detach',
            );
          }
        }
      } on NativeSqliteSnapshotDetachException {
        detached = false;
        _log.w(
          'Retaining collection restore staging after a failed database detach',
        );
        rethrow;
      } finally {
        if (detached) {
          try {
            await temporary.delete(recursive: true);
          } on FileSystemException catch (error) {
            _log.w('Could not remove collection restore staging: $error');
          }
        }
      }
      _log.i('Restored collections from backup');
      return;
    }

    final commands = await prepareCollectionRestoreCommands(
      collectionsJson,
      restoreTime,
    );
    await db.transaction((txn) async {
      await txn.delete(_tablePlaylistTracks);
      await txn.delete(_tablePlaylists);
      await txn.delete(_tableWishlist);
      await txn.delete(_tableLoved);
      await txn.delete(_tableFavoriteArtists);

      var batch = txn.batch();
      var pending = 0;
      for (final command in commands) {
        final table = switch (command['kind']) {
          'wishlist' => _tableWishlist,
          'loved' => _tableLoved,
          'artist' => _tableFavoriteArtists,
          'playlist' => _tablePlaylists,
          'playlist_track' => _tablePlaylistTracks,
          _ => throw const FormatException('Unknown collection command'),
        };
        batch.insert(
          table,
          command['values'] as Map<String, dynamic>,
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
        if (++pending == 500) {
          await batch.commit(noResult: true);
          batch = txn.batch();
          pending = 0;
        }
      }
      if (pending > 0) await batch.commit(noResult: true);
    });

    _log.i('Restored collections from backup');
  }
}

/// Reads picker rows with bounded selection queries, preserving playlist order.
Future<List<PlaylistPickerSummary>> readPlaylistPickerSummaries(
  DatabaseExecutor db,
  List<String> requestedTrackKeys,
) async {
  final uniqueTrackKeys = requestedTrackKeys
      .where((key) => key.trim().isNotEmpty)
      .toSet()
      .toList(growable: false);

  final playlistRows = await db.rawQuery('''
      SELECT
        p.id,
        p.name,
        p.cover_image_path,
        COUNT(pt.track_key) AS track_count,
        CASE WHEN p.cover_image_path IS NULL OR p.cover_image_path = '' THEN (
          SELECT preview.track_json
          FROM $_tablePlaylistTracks preview
          WHERE preview.playlist_id = p.id
          ORDER BY preview.added_at ASC, preview.rowid ASC
          LIMIT 1
        ) END AS preview_track_json
      FROM $_tablePlaylists p
      LEFT JOIN $_tablePlaylistTracks pt ON pt.playlist_id = p.id
      GROUP BY p.id
      ORDER BY p.created_at DESC, p.rowid DESC
    ''');

  final matchedCountsByPlaylistId = <String, int>{};
  const chunkSize = 500;
  for (var offset = 0; offset < uniqueTrackKeys.length; offset += chunkSize) {
    final chunk = uniqueTrackKeys.sublist(
      offset,
      (offset + chunkSize).clamp(0, uniqueTrackKeys.length),
    );
    final placeholders = List.filled(chunk.length, '?').join(', ');
    final matchedRows = await db.rawQuery('''
          SELECT playlist_id, COUNT(*) AS matched_count
          FROM $_tablePlaylistTracks
          WHERE track_key IN ($placeholders)
          GROUP BY playlist_id
        ''', chunk);
    for (final row in matchedRows) {
      final playlistId = row['playlist_id']?.toString();
      if (playlistId == null || playlistId.isEmpty) continue;
      matchedCountsByPlaylistId[playlistId] =
          (matchedCountsByPlaylistId[playlistId] ?? 0) +
          ((row['matched_count'] as num?)?.toInt() ?? 0);
    }
  }

  return playlistRows
      .map((row) {
        final id = row['id']?.toString() ?? '';
        String? previewCover;
        final previewJson = row['preview_track_json'] as String?;
        if (previewJson != null && previewJson.isNotEmpty) {
          try {
            final decoded = jsonDecode(previewJson);
            if (decoded is Map) {
              final cover = decoded['coverUrl']?.toString();
              if (cover != null && cover.isNotEmpty) previewCover = cover;
            }
          } catch (_) {}
        }
        return PlaylistPickerSummary(
          id: id,
          name: row['name']?.toString() ?? '',
          coverImagePath: row['cover_image_path'] as String?,
          previewCover: previewCover,
          trackCount: (row['track_count'] as num?)?.toInt() ?? 0,
          containsAllRequestedTracks:
              uniqueTrackKeys.isNotEmpty &&
              matchedCountsByPlaylistId[id] == uniqueTrackKeys.length,
        );
      })
      .toList(growable: false);
}
