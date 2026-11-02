import 'dart:convert';
import 'dart:io';
import 'package:sqflite/sqflite.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mornye/services/sqlite_helpers.dart' as sqlite;
import 'package:mornye/services/history_maintenance.dart';
import 'package:mornye/services/history_row_mapper.dart';
import 'package:mornye/services/history_schema.dart';
import 'package:mornye/utils/isrc_utils.dart' as isrc;
import 'package:mornye/utils/ios_container_paths.dart';
import 'package:mornye/utils/logger.dart';
import 'package:mornye/utils/path_match_keys.dart';

final _log = AppLogger('HistoryDatabase');
final Future<SharedPreferences> _prefs = SharedPreferences.getInstance();

String? _currentContainerPath;

class HistoryLookupRequest {
  final String spotifyId;
  final String? isrc;
  final String trackName;
  final String artistName;

  const HistoryLookupRequest({
    required this.spotifyId,
    this.isrc,
    required this.trackName,
    required this.artistName,
  });

  String get lookupKey =>
      '${spotifyId.trim()}|${HistoryDatabase.normalizeIsrc(isrc)}|'
      '${HistoryDatabase.matchKeyFor(trackName, artistName)}';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is HistoryLookupRequest &&
          spotifyId == other.spotifyId &&
          isrc == other.isrc &&
          trackName == other.trackName &&
          artistName == other.artistName;

  @override
  int get hashCode => Object.hash(spotifyId, isrc, trackName, artistName);
}

class HistoryBatchLookupRequest {
  final List<HistoryLookupRequest> tracks;

  const HistoryBatchLookupRequest(this.tracks);

  /// An immutable request whose hash is computed only once. Use for lists
  /// retained across widget builds; the const constructor recomputes the hash
  /// on every use.
  factory HistoryBatchLookupRequest.snapshot(
    Iterable<HistoryLookupRequest> tracks,
  ) = _HistoryBatchLookupSnapshot;

  /// The [HistoryLookupRequest.lookupKey] of each track, in order. A
  /// [HistoryBatchLookupRequest.snapshot] computes them once.
  List<String> get lookupKeys => [for (final track in tracks) track.lookupKey];

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! HistoryBatchLookupRequest ||
        other.tracks.length != tracks.length) {
      return false;
    }
    for (var i = 0; i < tracks.length; i++) {
      if (tracks[i] != other.tracks[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hashAll(tracks);
}

class _HistoryBatchLookupSnapshot extends HistoryBatchLookupRequest {
  _HistoryBatchLookupSnapshot(Iterable<HistoryLookupRequest> tracks)
    : super(List.unmodifiable(tracks));

  late final int _hash = Object.hashAll(tracks);

  @override
  late final List<String> lookupKeys = List.unmodifiable(super.lookupKeys);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is HistoryBatchLookupRequest &&
          hashCode == other.hashCode &&
          super == other;

  @override
  int get hashCode => _hash;
}

class HistoryDatabase {
  // The FTS table is a derived, optional index and is initialized lazily after
  // the existing schema migration. The background native writer shares
  // history.db and must accept the same schema contract and
  // user_version without depending on FTS5.
  static const int schemaVersion = 18;
  static const String searchFtsTable = 'history_search_fts';
  static final HistoryDatabase instance = HistoryDatabase._init();
  static final sqlite.SingleFlightInitializer<Database> _database =
      sqlite.SingleFlightInitializer<Database>();
  // null means this database connection has not attempted FTS setup yet.
  // false is a completed capability/setup result and must not be retried.
  bool? _searchFtsAvailable;

  HistoryDatabase._init();

  Future<Database> get database {
    return _database.getOrCreate(() async {
      final db = await sqlite.openAppDatabase(
        'history.db',
        version: schemaVersion,
        onCreate: (db, version) async {
          _searchFtsAvailable = await HistorySchema.create(db, version);
        },
        onUpgrade: HistorySchema.upgrade,
        onOpen: (db) async {
          if (Platform.isWindows) {
            await sqlite.repairWindowsPathKeysOnOpen(
              db,
              'history',
              'history_path_keys',
            );
          }
        },
      );
      // onCreate normally initializes this derived index. Retry once after
      // opening an existing database in case an earlier setup was
      // interrupted; unsupported SQLite builds remain on the LIKE fallback.
      _searchFtsAvailable ??= await HistorySchema.createSearchFts(db);
      return db;
    });
  }

  bool get searchFtsAvailable => _searchFtsAvailable ?? false;

  static String normalizeLookupText(String? value) =>
      sqlite.normalizeLookupText(value);

  static String normalizeIsrc(String? value) => isrc.normalizeIsrc(value);

  /// Returns '' for an empty track name, unlike [LibraryDatabase.matchKeyFor],
  /// which returns '|artist' in that case.
  static String matchKeyFor(String? trackName, String? artistName) {
    final track = normalizeLookupText(trackName);
    if (track.isEmpty) return '';
    return '$track|${normalizeLookupText(artistName)}';
  }

  static List<String> spotifyLookupCandidates(String? rawId) {
    final trimmed = rawId?.trim() ?? '';
    if (trimmed.isEmpty) return const [];
    final candidates = <String>{trimmed};
    final lowered = trimmed.toLowerCase();
    if (lowered.startsWith('spotify:track:')) {
      final compact = trimmed.split(':').last.trim();
      if (compact.isNotEmpty) candidates.add(compact);
    } else if (!trimmed.contains(':')) {
      candidates.add('spotify:track:$trimmed');
    }
    final uri = Uri.tryParse(trimmed);
    final segments = uri?.pathSegments ?? const <String>[];
    final trackIndex = segments.indexOf('track');
    if (trackIndex >= 0 && trackIndex + 1 < segments.length) {
      final pathId = segments[trackIndex + 1].trim();
      if (pathId.isNotEmpty) {
        candidates.add(pathId);
        candidates.add('spotify:track:$pathId');
      }
    }
    return candidates.toList(growable: false);
  }

  void _putPathKeysInBatch(Batch batch, String id, String? filePath) =>
      sqlite.putPathKeysInBatch(batch, 'history_path_keys', id, filePath);

  Future<void> _initContainerPath() async {
    if (!Platform.isIOS || _currentContainerPath != null) return;

    try {
      final docDir = await getApplicationDocumentsDirectory();
      _currentContainerPath = docDir.parent.path;
      _log.d('iOS container path: $_currentContainerPath');
    } catch (e) {
      _log.w('Failed to get iOS container path: $e');
    }
  }

  String _normalizeIosPath(String? filePath) {
    if (filePath == null || filePath.isEmpty) return filePath ?? '';
    if (!Platform.isIOS || _currentContainerPath == null) return filePath;

    return rebaseIosSandboxPath(filePath, '$_currentContainerPath/Documents');
  }

  Future<bool> migrateIosContainerPaths({bool force = false}) async {
    if (!Platform.isIOS) return false;

    await _initContainerPath();
    if (_currentContainerPath == null) return false;

    try {
      final updatedCount = await migrateIosHistoryPaths(
        await database,
        await _prefs,
        containerPath: _currentContainerPath!,
        force: force,
      );
      if (updatedCount == null) {
        _log.d('iOS container path unchanged, skipping migration');
        return false;
      }
      _log.i('iOS path migration complete: $updatedCount paths updated');
      return updatedCount > 0;
    } catch (e, stack) {
      _log.e('iOS path migration failed: $e', e, stack);
      if (force) rethrow;
      return false;
    }
  }

  Future<bool> migrateFromSharedPreferences() async {
    final prefs = await _prefs;
    final migrationKey = 'history_migrated_to_sqlite';

    if (prefs.getBool(migrationKey) == true) {
      _log.d('Already migrated to SQLite');
      return false;
    }

    final jsonStr = prefs.getString('download_history');
    if (jsonStr == null || jsonStr.isEmpty) {
      _log.d('No SharedPreferences history to migrate');
      await prefs.setBool(migrationKey, true);
      return false;
    }

    try {
      final jsonList = List<dynamic>.from(jsonDecode(jsonStr) as List);
      _log.i(
        'Migrating ${jsonList.length} items from SharedPreferences to SQLite',
      );

      final db = await database;
      final batch = db.batch();

      for (final json in jsonList) {
        final map = Map<String, dynamic>.from(json as Map);
        batch.insert(
          'history',
          HistoryRowMapper.jsonToDbRow(map),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
        _putPathKeysInBatch(
          batch,
          map['id'] as String,
          map['filePath'] as String?,
        );
      }

      await batch.commit(noResult: true);

      await prefs.setBool(migrationKey, true);
      _log.i('Migration complete: ${jsonList.length} items');

      return true;
    } catch (e, stack) {
      _log.e('Migration failed: $e', e, stack);
      return false;
    }
  }

  Map<String, dynamic> _dbRowToJson(Map<String, dynamic> row) =>
      HistoryRowMapper.dbRowToJson(
        row,
        _normalizeIosPath(row['file_path'] as String?),
      );

  Future<void> upsert(Map<String, dynamic> json) async {
    final db = await database;
    await db.transaction((txn) async {
      await txn.insert(
        'history',
        HistoryRowMapper.jsonToDbRow(json),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      final batch = txn.batch();
      _putPathKeysInBatch(
        batch,
        json['id'] as String,
        json['filePath'] as String?,
      );
      await batch.commit(noResult: true);
    });
  }

  Future<void> upsertBatch(List<Map<String, dynamic>> items) async {
    if (items.isEmpty) return;
    final db = await database;
    await db.transaction((txn) async {
      final batch = txn.batch();
      for (final json in items) {
        batch.insert(
          'history',
          HistoryRowMapper.jsonToDbRow(json),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
        _putPathKeysInBatch(
          batch,
          json['id'] as String,
          json['filePath'] as String?,
        );
      }
      await batch.commit(noResult: true);
    });
  }

  Future<Set<String>> updateExistingBatch(
    List<Map<String, dynamic>> items,
  ) async {
    if (items.isEmpty) return const {};
    final db = await database;
    return db.transaction(
      (txn) => updateExistingHistoryRows(
        txn,
        items.map(HistoryRowMapper.jsonToDbRow),
      ),
    );
  }

  Future<List<Map<String, dynamic>>> getAll({int? limit, int? offset}) async {
    final db = await database;
    final rows = await db.query(
      'history',
      orderBy: 'sort_added DESC, id DESC',
      limit: limit,
      offset: offset,
    );
    return rows.map(_dbRowToJson).toList();
  }

  Future<List<Map<String, dynamic>>> getAlbumTracks(
    String albumName,
    String artistName,
  ) async {
    final db = await database;
    final albumKey =
        '${normalizeLookupText(albumName)}|${normalizeLookupText(artistName)}';
    final rows = await db.query(
      'history',
      where: 'album_key = ?',
      whereArgs: [albumKey],
      orderBy:
          'COALESCE(disc_number, 0), COALESCE(track_number, 0), track_name',
    );
    return rows.map(_dbRowToJson).toList(growable: false);
  }

  Future<Map<String, dynamic>?> _firstRow(
    Database db,
    String where,
    List<Object?> whereArgs, {
    List<String>? columns,
    bool newestFirst = true,
  }) async {
    final rows = await db.query(
      'history',
      columns: columns,
      where: where,
      whereArgs: whereArgs,
      orderBy: newestFirst ? 'sort_added DESC, id DESC' : null,
      limit: 1,
    );
    return rows.isEmpty ? null : _dbRowToJson(rows.first);
  }

  Future<Map<String, dynamic>?> findByTrackAndArtist(
    String trackName,
    String artistName,
  ) async {
    final key = matchKeyFor(trackName, artistName);
    if (key.isEmpty) return null;
    return _firstRow(await database, 'match_key = ?', [key]);
  }

  Future<Map<String, dynamic>?> getById(String id) async =>
      _firstRow(await database, 'id = ?', [id], newestFirst: false);

  /// Rows for [ids], keyed by id; ids no longer in the history are absent.
  Future<Map<String, Map<String, dynamic>>> getByIds(
    Iterable<String> ids,
  ) async {
    final rows = <String, Map<String, dynamic>>{};
    await sqlite.loadRowsByColumn(
      await database,
      table: 'history',
      column: 'id',
      rawValues: ids,
      destination: rows,
      mapRow: _dbRowToJson,
    );
    return rows;
  }

  Future<Map<String, dynamic>?> findByFilePath(String filePath) async {
    final pathKeys = buildPathMatchKeys(filePath).toList(growable: false);
    if (pathKeys.isEmpty) return null;

    final db = await database;
    final placeholders = List.filled(pathKeys.length, '?').join(',');
    final rows = await db.rawQuery('''
      SELECT h.*
      FROM history h
      JOIN history_path_keys hpk ON hpk.item_id = h.id
      WHERE hpk.path_key IN ($placeholders)
      ORDER BY h.sort_added DESC, h.id DESC
      LIMIT 1
      ''', pathKeys);
    if (rows.isEmpty) return null;
    return _dbRowToJson(rows.first);
  }

  Future<List<String>> getPhysicalFileIds(Iterable<String> filePaths) async =>
      sqlite.findPhysicalFileRowIds(await database, 'history', filePaths);

  /// Origin aliases are deliberately separate from physical path keys:
  /// deleting a server file must never delete its independent offline copy.
  Future<Map<String, dynamic>?> findOfflineCopy(String origin) async =>
      _firstRow(await database, 'origin_file_path = ?', [origin]);

  Future<Map<String, dynamic>?> getBySpotifyId(String spotifyId) async =>
      _firstRow(await database, 'spotify_id = ?', [spotifyId]);

  Future<Map<String, dynamic>?> getByIsrc(String isrc) async =>
      _firstRow(await database, 'isrc = ?', [isrc]);

  Future<Map<String, dynamic>?> findExistingTrack(
    HistoryLookupRequest request, {
    List<String>? columns,
  }) async {
    final db = await database;
    final spotifyCandidates = spotifyLookupCandidates(request.spotifyId);
    if (spotifyCandidates.isNotEmpty) {
      final placeholders = List.filled(spotifyCandidates.length, '?').join(',');
      final normalized = spotifyCandidates
          .map(HistoryRowMapper.normalizeSpotifyId)
          .toList();
      final row = await _firstRow(
        db,
        'spotify_id IN ($placeholders) OR spotify_id_norm IN ($placeholders)',
        [...spotifyCandidates, ...normalized],
        columns: columns,
      );
      if (row != null) return row;
    }

    final isrcNorm = normalizeIsrc(request.isrc);
    if (isrcNorm.isNotEmpty) {
      final row = await _firstRow(db, 'isrc_norm = ?', [
        isrcNorm,
      ], columns: columns);
      if (row != null) return row;
    }

    final matchKey = matchKeyFor(request.trackName, request.artistName);
    if (matchKey.isEmpty) return null;
    return _firstRow(db, 'match_key = ?', [matchKey], columns: columns);
  }

  /// Batch variant used by playlist playback and bulk existence checks. A
  /// compact candidates CTE resolves all identifiers in one indexed lookup per
  /// bounded chunk, returning only the id/path reference those callers need.
  Future<List<Map<String, dynamic>?>> findExistingTracks(
    List<HistoryLookupRequest> requests,
  ) async {
    if (requests.isEmpty) return const [];
    final db = await database;
    final results = List<Map<String, dynamic>?>.filled(requests.length, null);
    const requestChunkSize = 80;

    for (
      var chunkStart = 0;
      chunkStart < requests.length;
      chunkStart += requestChunkSize
    ) {
      final chunkEnd = (chunkStart + requestChunkSize).clamp(
        0,
        requests.length,
      );
      final chunk = requests.sublist(chunkStart, chunkEnd);
      final candidateRows = <String>[];
      final args = <Object?>[];

      void addCandidate(
        int requestIndex,
        int priority,
        String kind,
        String value,
      ) {
        if (value.isEmpty) return;
        candidateRows.add("($requestIndex, $priority, '$kind', ?)");
        args.add(value);
      }

      for (var requestIndex = 0; requestIndex < chunk.length; requestIndex++) {
        final request = chunk[requestIndex];
        var priority = 0;
        final seen = <String>{};
        for (final candidate in spotifyLookupCandidates(request.spotifyId)) {
          final exactKey = 'spotify_id\u0000$candidate';
          if (candidate.isNotEmpty && seen.add(exactKey)) {
            addCandidate(requestIndex, priority++, 'spotify_id', candidate);
          }
          final normalized = HistoryRowMapper.normalizeSpotifyId(candidate);
          final normalizedKey = 'spotify_id_norm\u0000$normalized';
          if (normalized.isNotEmpty && seen.add(normalizedKey)) {
            addCandidate(
              requestIndex,
              priority++,
              'spotify_id_norm',
              normalized,
            );
          }
        }
        addCandidate(
          requestIndex,
          priority++,
          'isrc_norm',
          normalizeIsrc(request.isrc),
        );
        addCandidate(
          requestIndex,
          priority,
          'match_key',
          matchKeyFor(request.trackName, request.artistName),
        );
      }
      if (candidateRows.isEmpty) continue;

      final rows = await db.rawQuery('''
        WITH candidates(request_index, priority, lookup_kind, lookup_value) AS (
          VALUES ${candidateRows.join(', ')}
        ), matches AS (
          SELECT c.request_index, c.priority, h.id, h.file_path,
                 h.sort_added
          FROM candidates c
          JOIN history h ON h.spotify_id = c.lookup_value
          WHERE c.lookup_kind = 'spotify_id'
          UNION ALL
          SELECT c.request_index, c.priority, h.id, h.file_path,
                 h.sort_added
          FROM candidates c
          JOIN history h ON h.spotify_id_norm = c.lookup_value
          WHERE c.lookup_kind = 'spotify_id_norm'
          UNION ALL
          SELECT c.request_index, c.priority, h.id, h.file_path,
                 h.sort_added
          FROM candidates c
          JOIN history h ON h.isrc_norm = c.lookup_value
          WHERE c.lookup_kind = 'isrc_norm'
          UNION ALL
          SELECT c.request_index, c.priority, h.id, h.file_path,
                 h.sort_added
          FROM candidates c
          JOIN history h ON h.match_key = c.lookup_value
          WHERE c.lookup_kind = 'match_key'
        )
        SELECT request_index, id, file_path
        FROM matches
        ORDER BY request_index, priority, sort_added DESC, id DESC
      ''', args);
      for (final row in rows) {
        final localIndex = (row['request_index'] as num).toInt();
        final resultIndex = chunkStart + localIndex;
        results[resultIndex] ??= {
          'id': row['id'],
          'filePath': _normalizeIosPath(row['file_path'] as String?),
        };
      }
    }
    return results;
  }

  Future<void> clearAll() async {
    final db = await database;
    await db.transaction((txn) async {
      await txn.delete('history_path_keys');
      await txn.delete('history');
    });
    // Return freed pages to the OS (no-op unless the file was created with
    // auto_vacuum enabled).
    try {
      await db.execute('PRAGMA incremental_vacuum');
    } catch (_) {}
    _log.i('Cleared all history');
  }

  Future<int> getCount() async {
    final db = await database;
    final result = await db.rawQuery('SELECT COUNT(*) as count FROM history');
    return Sqflite.firstIntValue(result) ?? 0;
  }

  Future<void> close() async {
    final db = await database;
    await db.close();
    _database.reset();
    _searchFtsAvailable = null;
  }

  Future<bool> updateFilePath(
    String id,
    String newFilePath, {
    String? newStorageMode,
    String? newDownloadTreeUri,
    String? newSafFileName,
    String? newSafRelativeDir,
    String? newQuality,
    int? newBitDepth,
    int? newSampleRate,
    int? newBitrate,
    String? newFormat,
    bool clearAudioSpecs = false,
    String? expectedFilePath,
    String? expectedDownloadedAt,
  }) async {
    final db = await database;
    final values = <String, dynamic>{'file_path': newFilePath};
    if (newStorageMode != null) values['storage_mode'] = newStorageMode;
    if (newDownloadTreeUri != null) {
      values['download_tree_uri'] = newDownloadTreeUri;
    }
    if (newSafFileName != null) {
      values['saf_file_name'] = newSafFileName;
    }
    if (newSafRelativeDir != null) {
      values['saf_relative_dir'] = newSafRelativeDir;
    }
    if (newQuality != null) {
      values['quality'] = newQuality;
    }
    if (newFormat != null) {
      values['format'] = newFormat;
    }
    if (newBitrate != null) {
      values['bitrate'] = newBitrate;
    }
    if (clearAudioSpecs) {
      values['bit_depth'] = null;
      values['sample_rate'] = null;
      if (newBitrate == null) {
        values['bitrate'] = null;
      }
    } else {
      if (newBitDepth != null) {
        values['bit_depth'] = newBitDepth;
      }
      if (newSampleRate != null) {
        values['sample_rate'] = newSampleRate;
      }
    }
    return db.transaction((txn) async {
      final changed = await txn.update(
        'history',
        values,
        where:
            'id = ?'
            '${expectedFilePath == null ? '' : ' AND file_path = ?'}'
            '${expectedDownloadedAt == null ? '' : ' AND downloaded_at = ?'}',
        whereArgs: [id, ?expectedFilePath, ?expectedDownloadedAt],
      );
      if (changed == 0) return false;
      final batch = txn.batch();
      _putPathKeysInBatch(batch, id, newFilePath);
      await batch.commit(noResult: true);
      return true;
    });
  }

  Future<List<Map<String, dynamic>>> getEntriesWithPathsPage({
    required int limit,
    int offset = 0,
  }) async {
    final db = await database;
    final rows = await db.query(
      'history',
      columns: [
        'id',
        'file_path',
        'storage_mode',
        'download_tree_uri',
        'saf_relative_dir',
        'saf_file_name',
        'downloaded_at',
      ],
      // A double-quoted "" is an identifier in SQLite; builds without the
      // legacy fallback (DQS), as on Windows, reject it.
      where: "file_path IS NOT NULL AND file_path != ''",
      orderBy: 'sort_added DESC, id DESC',
      limit: limit,
      offset: offset,
    );
    return rows.map((r) => Map<String, dynamic>.from(r)).toList();
  }

  /// A delayed absence check must not delete a replacement downloaded after
  /// the inspected snapshot, even when it reused the same ID and path.
  Future<List<String>> deleteInspectedEntries(
    List<Map<String, dynamic>> entries,
  ) async {
    final db = await database;
    return db.transaction((txn) async {
      final deletedIds = <String>[];
      for (final entry in entries) {
        final id = entry['id'] as String;
        final downloadedAt = entry['downloaded_at'] as String?;
        final count = await txn.delete(
          'history',
          where:
              'id = ? AND file_path = ?'
              '${downloadedAt == null ? '' : ' AND downloaded_at = ?'}',
          whereArgs: [id, entry['file_path'], ?downloadedAt],
        );
        if (count == 0) continue;
        await txn.delete(
          'history_path_keys',
          where: 'item_id = ?',
          whereArgs: [id],
        );
        deletedIds.add(id);
      }
      return deletedIds;
    });
  }

  Future<int> deleteByIds(List<String> ids) async {
    if (ids.isEmpty) return 0;

    final db = await database;
    final totalDeleted = await db.transaction((txn) async {
      var deleted = 0;
      const chunkSize = 500;
      for (var i = 0; i < ids.length; i += chunkSize) {
        final end = (i + chunkSize < ids.length) ? i + chunkSize : ids.length;
        final chunk = ids.sublist(i, end);
        final placeholders = List.filled(chunk.length, '?').join(',');
        await txn.rawDelete(
          'DELETE FROM history_path_keys WHERE item_id IN ($placeholders)',
          chunk,
        );
        deleted += await txn.rawDelete(
          'DELETE FROM history WHERE id IN ($placeholders)',
          chunk,
        );
      }
      return deleted;
    });
    _log.i('Deleted $totalDeleted orphaned entries');
    return totalDeleted;
  }
}
