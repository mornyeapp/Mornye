import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import 'package:mornye/utils/logger.dart';
import 'package:mornye/utils/audio_format_utils.dart';
import 'package:mornye/utils/file_access.dart';
import 'package:mornye/services/history_database.dart';
import 'package:mornye/services/library_queue_store.dart';
import 'package:mornye/services/library_file_sizes.dart';
import 'package:mornye/services/library_cleanup.dart';
import 'package:mornye/services/library_search.dart';
import 'package:mornye/services/library_database_models.dart';
import 'package:mornye/services/library_duplicates.dart';
import 'package:mornye/services/network_storage_service.dart';
import 'package:mornye/services/library_ingestion_store.dart';
import 'package:mornye/services/library_native_adapter.dart';
import 'package:mornye/services/library_row_mapper.dart';
import 'package:mornye/services/library_schema.dart';
import 'package:mornye/services/platform_bridge.dart';
import 'package:mornye/services/sqlite_helpers.dart' as sqlite;

export 'library_database_models.dart';

export 'library_queue_store.dart'
    show confirmedMissingLyricsSqlPredicate, missingReplayGainSqlPredicate;

final _log = AppLogger('LibraryDatabase');

class LibraryDatabase {
  static final LibraryDatabase instance = LibraryDatabase._init();
  // The FTS table is a derived, optional index and is initialized lazily after
  // the existing schema migration, so it does not require a user_version bump.
  static const int schemaVersion = LibrarySchema.version;
  static const String legacySourceId = LocalLibraryItem.legacySourceId;
  static const String visibleLibraryView = LibrarySchema.visibleView;
  static const String lookupSummaryTable = LibrarySchema.lookupSummaryTable;
  // v4 records ReplayGain availability; older rows rescan once.
  static const int audioMetadataScanVersion = libraryAudioMetadataScanVersion;

  /// First scan version whose rows record lyrics availability (v3).
  static const int lyricsMetadataScanVersion = libraryLyricsMetadataScanVersion;
  static final sqlite.SingleFlightInitializer<Database> _database =
      sqlite.SingleFlightInitializer<Database>();
  bool _historyAttached = false;
  LibraryFileSizes? _fileSizes;
  late final LibraryIngestionStore _ingestion = LibraryIngestionStore(
    openDatabase: () => database,
    ensureHistoryAttached: _ensureHistoryAttached,
  );
  // null means this database connection has not attempted FTS setup yet.
  // false is a completed capability/setup result and must not be retried.
  bool? _searchFtsAvailable;

  LibraryDatabase._init();

  Future<Database> get database {
    return _database.getOrCreate(() async {
      final db = await sqlite.openAppDatabase(
        'local_library.db',
        version: schemaVersion,
        onCreate: (db, version) async {
          _searchFtsAvailable = await LibrarySchema.create(db, version);
        },
        onUpgrade: LibrarySchema.upgrade,
        onOpen: LibrarySchema.migrateIosContainerPaths,
      );
      // Library upserts use INSERT OR REPLACE. Recursive triggers ensure the
      // implicit delete also decrements materialized lookup ref-counts.
      await db.execute('PRAGMA recursive_triggers = ON');
      // onCreate normally initializes this derived index. Retry once after
      // opening an existing database in case an earlier setup was
      // interrupted; unsupported SQLite builds remain on the LIKE fallback.
      _searchFtsAvailable ??= await LibrarySchema.createSearchFts(db);
      return db;
    });
  }

  bool get searchFtsAvailable => _searchFtsAvailable ?? false;

  Future<Map<String, Map<String, dynamic>>> readNetworkScanRows(
    String sourceId,
    List<String> paths,
  ) => _ingestion.readNetworkScanRows(sourceId, paths);

  /// Keeps native scan output native through parsing, indexing and the atomic
  /// source swap. The stream implementation remains the desktop/test adapter.
  Future<({int inserted, int skipped})> replaceSourceScanFile(
    String sourceId,
    LibraryScanNDJSONFile scan, {
    required String requestId,
    required bool Function() isCancelled,
  }) => _ingestion.replaceSourceScanFile(
    sourceId,
    scan,
    requestId: requestId,
    isCancelled: isCancelled,
  );

  /// Exports timestamps directly from the DB on the worker. Android's adapter
  /// backfills zero SAF timestamps in bounded ContentResolver batches first.
  Future<String> writeNativeFileModTimesSnapshot(
    String sourceId, {
    required String requestId,
    required bool Function() isCancelled,
  }) async {
    return LibraryNativeAdapter(await database).writeFileModTimesSnapshot(
      sourceId,
      requestId: requestId,
      isCancelled: isCancelled,
    );
  }

  /// Native folder scanning and delta ingestion share one operation, so delta
  /// track maps never return to Flutter. SAF traversal stays in its OS adapter.
  Future<Map<String, dynamic>> scanIncrementalNative(
    String sourceId,
    String folderPath,
    String snapshotPath, {
    required bool isSaf,
    required String requestId,
    required bool Function() isCancelled,
  }) => _ingestion.scanIncrementalNative(
    sourceId,
    folderPath,
    snapshotPath,
    isSaf: isSaf,
    requestId: requestId,
    isCancelled: isCancelled,
  );

  Future<List<LibrarySearchHit>> searchLibrary({
    required String query,
    required LibrarySearchKind kind,
    required bool includeLocal,
    int limit = 40,
    int offset = 0,
  }) async {
    final db = await database;
    await _ensureHistoryAttached(db);
    return LibrarySearchStore(
      db,
      historyFts: HistoryDatabase.instance.searchFtsAvailable,
      localFts: searchFtsAvailable,
    ).search(
      query: query,
      kind: kind,
      includeLocal: includeLocal,
      limit: limit,
      offset: offset,
    );
  }

  Future<void> _ensureHistoryAttached(Database db) async {
    if (_historyAttached) return;
    await HistoryDatabase.instance.database;
    final dbPath = await sqlite.appDatabaseDirectory();
    final historyPath = join(dbPath.path, 'history.db');
    try {
      await db.execute('ATTACH DATABASE ? AS history_db', [historyPath]);
    } catch (e) {
      final message = e.toString().toLowerCase();
      if (!message.contains('already in use') &&
          !message.contains('already exists')) {
        rethrow;
      }
    }
    _historyAttached = true;
  }

  void _putPathKeysInBatch(Batch batch, String id, String? filePath) =>
      sqlite.putPathKeysInBatch(batch, 'library_path_keys', id, filePath);

  static String normalizeLookupText(String? value) =>
      sqlite.normalizeLookupText(value);

  static String matchKeyFor(String trackName, String artistName) {
    return '${normalizeLookupText(trackName)}|${normalizeLookupText(artistName)}';
  }

  static String albumKeyFor(
    String albumName,
    String? albumArtist,
    String artistName,
  ) {
    return '${normalizeLookupText(albumName)}|${normalizeLookupText(albumArtist ?? artistName)}';
  }

  /// Removes rows from one source whose normalized path keys already exist in
  /// download History, without materializing either database's paths in Dart.
  Future<int> deleteDownloadedRowsForSource(String sourceId) =>
      _ingestion.deleteDownloadedRowsForSource(sourceId);

  /// Upserts incremental scan rows after filtering them through the attached
  /// History path-key index. This keeps the hot incremental path independent
  /// of total History size.
  Future<({int upserted, int skipped})> upsertBatchExcludingHistory(
    List<Map<String, dynamic>> items, {
    required String sourceId,
  }) => _ingestion.upsertBatchExcludingHistory(items, sourceId: sourceId);

  Future<List<LocalLibrarySource>> getSources() async {
    final db = await database;
    final rows = await db.rawQuery('''
      SELECT s.*, COUNT(l.id) AS track_count
      FROM library_sources s
      LEFT JOIN library l ON l.source_id = s.id
      GROUP BY s.id
      HAVING s.path != 'legacy://local-library' OR COUNT(l.id) > 0
      ORDER BY s.is_removable, LOWER(s.display_name), LOWER(s.path)
    ''');
    return rows.map(_sourceFromRow).toList(growable: false);
  }

  Future<LocalLibrarySource?> getSourceByPath(String path) async {
    final db = await database;
    final rows = await db.rawQuery(
      '''
      SELECT s.*, COUNT(l.id) AS track_count
      FROM library_sources s
      LEFT JOIN library l ON l.source_id = s.id
      WHERE s.path = ?
      GROUP BY s.id
      LIMIT 1
      ''',
      [path],
    );
    return rows.isEmpty ? null : _sourceFromRow(rows.first);
  }

  LocalLibrarySource _sourceFromRow(Map<String, Object?> row) {
    DateTime? parseDate(Object? value) =>
        value is String ? DateTime.tryParse(value) : null;
    return LocalLibrarySource(
      id: row['id'] as String,
      path: row['path'] as String,
      displayName: row['display_name'] as String,
      bookmark: row['bookmark'] as String?,
      volumeId: row['volume_id'] as String?,
      isRemovable: (row['is_removable'] as num?)?.toInt() == 1,
      enabled: (row['enabled'] as num?)?.toInt() != 0,
      available: (row['available'] as num?)?.toInt() != 0,
      trackCount: (row['track_count'] as num?)?.toInt() ?? 0,
      lastScannedAt: parseDate(row['last_scanned_at']),
      lastSeenAt: parseDate(row['last_seen_at']),
      lastScanError: row['last_scan_error'] as String?,
    );
  }

  Future<void> upsertSource(LocalLibrarySource source) async {
    final db = await database;
    final values = <String, Object?>{
      'path': source.path,
      'display_name': source.displayName,
      'bookmark': source.bookmark,
      'volume_id': source.volumeId,
      'is_removable': source.isRemovable ? 1 : 0,
      'enabled': source.enabled ? 1 : 0,
      'available': source.available ? 1 : 0,
      'last_scanned_at': source.lastScannedAt?.toIso8601String(),
      'last_seen_at': source.lastSeenAt?.toIso8601String(),
      'last_scan_error': source.lastScanError,
    };
    final updated = await db.update(
      'library_sources',
      values,
      where: 'id = ?',
      whereArgs: [source.id],
    );
    if (updated == 0) {
      await db.insert('library_sources', {'id': source.id, ...values});
    }
  }

  Future<void> updateSourceState(
    String sourceId, {
    bool? enabled,
    bool? available,
    DateTime? lastScannedAt,
    DateTime? lastSeenAt,
    String? lastScanError,
    bool clearLastScanError = false,
  }) async {
    final values = <String, Object?>{};
    if (enabled != null) values['enabled'] = enabled ? 1 : 0;
    if (available != null) values['available'] = available ? 1 : 0;
    if (lastScannedAt != null) {
      values['last_scanned_at'] = lastScannedAt.toIso8601String();
    }
    if (lastSeenAt != null) {
      values['last_seen_at'] = lastSeenAt.toIso8601String();
    }
    if (lastScanError != null || clearLastScanError) {
      values['last_scan_error'] = clearLastScanError ? null : lastScanError;
    }
    if (values.isEmpty) return;
    final db = await database;
    await db.update(
      'library_sources',
      values,
      where: 'id = ?',
      whereArgs: [sourceId],
    );
  }

  Future<void> migrateLegacySource({
    required String path,
    required String displayName,
    String? bookmark,
    String? volumeId,
    bool isRemovable = false,
    bool available = true,
    DateTime? lastScannedAt,
  }) async {
    if (path.trim().isEmpty) return;
    final db = await database;
    await persistLegacyLibrarySource(
      db,
      LocalLibrarySource(
        id: legacySourceId,
        path: path,
        displayName: displayName,
        bookmark: bookmark,
        volumeId: volumeId,
        isRemovable: isRemovable,
        available: available,
        lastScannedAt: lastScannedAt,
        lastSeenAt: available ? DateTime.now() : null,
      ),
    );
  }

  Future<void> removeSource(String sourceId) async {
    final db = await database;
    await sqlite.transactionWithBusyRetry(db, (txn) async {
      await txn.rawDelete(
        'DELETE FROM library_path_keys WHERE item_id IN '
        '(SELECT id FROM library WHERE source_id = ?)',
        [sourceId],
      );
      await txn.delete(
        'library',
        where: 'source_id = ?',
        whereArgs: [sourceId],
      );
      if (sourceId == legacySourceId) {
        await txn.update(
          'library_sources',
          {
            'path': 'legacy://local-library',
            'display_name': 'Music',
            'bookmark': null,
            'volume_id': null,
            'is_removable': 0,
            'enabled': 1,
            'available': 1,
            'last_scanned_at': null,
            'last_seen_at': null,
            'last_scan_error': null,
          },
          where: 'id = ?',
          whereArgs: [sourceId],
        );
      } else {
        await txn.delete(
          'library_sources',
          where: 'id = ?',
          whereArgs: [sourceId],
        );
      }
    });
  }

  Future<List<Map<String, dynamic>>> getAll() async {
    final db = await database;
    final rows = await db.query(
      visibleLibraryView,
      orderBy: 'album_artist, album_name, disc_number, track_number',
    );
    return rows.map(LibraryRowMapper.decode).toList();
  }

  String _orderByForSort(LocalLibrarySortMode sortMode) {
    return switch (sortMode) {
      LocalLibrarySortMode.title =>
        'track_name_norm, artist_name_norm, album_name_norm, disc_number, track_number',
      LocalLibrarySortMode.artist =>
        'artist_name_norm, album_name_norm, disc_number, track_number, track_name_norm',
      LocalLibrarySortMode.latest =>
        'scanned_at DESC, album_artist_norm, album_name_norm, disc_number, track_number',
      LocalLibrarySortMode.quality =>
        'COALESCE(bit_depth, 0) DESC, COALESCE(sample_rate, 0) DESC, COALESCE(bitrate, 0) DESC, album_artist_norm, album_name_norm, disc_number, track_number',
      LocalLibrarySortMode.album =>
        'album_artist_norm, album_name_norm, COALESCE(disc_number, 0), COALESCE(track_number, 0), track_name_norm',
    };
  }

  Future<List<Map<String, dynamic>>> getQueueTrackPage(
    QueueLibraryDbQuery request,
  ) async {
    return (await getQueueTrackPageResult(request)).rows;
  }

  Future<LibraryQueueStore> _queueStore([QueueLibraryDbQuery? request]) async {
    final db = await database;
    await _ensureHistoryAttached(db);
    if (request != null && isLibrarySizeSort(request.sortMode)) {
      await (_fileSizes ??= LibraryFileSizes(db)).refresh(
        includeLocal: request.includeLocal && request.source != 'downloaded',
        includeHistory: request.source != 'local',
      );
    }
    return LibraryQueueStore(
      db,
      historyFts: HistoryDatabase.instance.searchFtsAvailable,
      localFts: searchFtsAvailable,
    );
  }

  Future<QueueLibraryDbPage> getQueueTrackPageResult(
    QueueLibraryDbQuery request,
  ) async => (await _queueStore(request)).trackPage(request);

  Future<QueueLibraryCounts> getQueueCounts(
    QueueLibraryDbQuery request,
  ) async => (await _queueStore()).counts(request);

  @visibleForTesting
  Future<List<Map<String, dynamic>>> getQueueAlbumPage(
    QueueLibraryDbQuery request,
  ) async {
    return (await getQueueAlbumPageResult(request)).rows;
  }

  Future<QueueLibraryDbPage> getQueueAlbumPageResult(
    QueueLibraryDbQuery request,
  ) async => (await _queueStore(request)).albumPage(request);

  /// Album artists across downloaded and scanned music, excluding duplicate paths.
  Future<List<Map<String, dynamic>>> getQueueArtistPage(
    QueueLibraryDbQuery request,
  ) async => (await _queueStore()).artistPage(request);

  Future<List<Map<String, dynamic>>> getQueueLocalAlbumTracks(
    String albumName,
    String artistName,
  ) async {
    final db = await database;
    final rows = await db.query(
      visibleLibraryView,
      where:
          "LOWER(album_name) = ? AND LOWER(COALESCE(NULLIF(album_artist, ''), artist_name)) = ?",
      whereArgs: [albumName.toLowerCase(), artistName.toLowerCase()],
      orderBy:
          'COALESCE(disc_number, 0), COALESCE(track_number, 0), track_name',
    );
    return rows.map(LibraryRowMapper.decode).toList(growable: false);
  }

  Future<List<Map<String, dynamic>>> getQueueLocalAlbumTracksByKey(
    String albumKey,
  ) async {
    final db = await database;
    final rows = await db.query(
      visibleLibraryView,
      where: 'album_key = ?',
      whereArgs: [albumKey],
      orderBy:
          'COALESCE(disc_number, 0), COALESCE(track_number, 0), track_name',
    );
    return rows.map(LibraryRowMapper.decode).toList(growable: false);
  }

  Future<Map<String, dynamic>?> getById(String id) async {
    final db = await database;
    final rows = await db.query(
      visibleLibraryView,
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return LibraryRowMapper.decode(rows.first);
  }

  Future<Map<String, dynamic>?> getByIsrc(String isrc) async {
    final db = await database;
    final rows = await db.query(
      visibleLibraryView,
      where: 'isrc = ?',
      whereArgs: [isrc],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return LibraryRowMapper.decode(rows.first);
  }

  Future<List<Map<String, dynamic>>> findByTrackAndArtist(
    String trackName,
    String artistName,
  ) async {
    final db = await database;
    final rows = await db.query(
      visibleLibraryView,
      where: 'match_key = ?',
      whereArgs: [matchKeyFor(trackName, artistName)],
    );
    return rows.map(LibraryRowMapper.decode).toList();
  }

  Future<Map<String, dynamic>?> findFirstByTrackAndArtist(
    String trackName,
    String artistName,
  ) async {
    final db = await database;
    final rows = await db.query(
      visibleLibraryView,
      where: 'match_key = ?',
      whereArgs: [matchKeyFor(trackName, artistName)],
      orderBy: _orderByForSort(LocalLibrarySortMode.album),
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return LibraryRowMapper.decode(rows.first);
  }

  Future<Map<String, dynamic>?> findExisting({
    String? isrc,
    String? trackName,
    String? artistName,
  }) async {
    if (isrc != null && isrc.isNotEmpty) {
      final byIsrc = await getByIsrc(isrc);
      if (byIsrc != null) return byIsrc;
    }

    if (trackName != null && artistName != null) {
      final matches = await findByTrackAndArtist(trackName, artistName);
      if (matches.isNotEmpty) return matches.first;
    }

    return null;
  }

  /// Resolves a track list with a bounded number of indexed queries instead
  /// of issuing up to three SQLite calls for every track.
  Future<List<Map<String, dynamic>?>> findExistingBatch(
    List<LocalLibraryBatchLookupRequest> requests,
  ) async {
    if (requests.isEmpty) return const [];
    final db = await database;
    final byId = <String, Map<String, dynamic>>{};
    final byIsrc = <String, Map<String, dynamic>>{};
    final byMatchKey = <String, Map<String, dynamic>>{};

    Future<void> loadColumn(
      String column,
      Iterable<String> rawValues,
      Map<String, Map<String, dynamic>> destination,
    ) {
      return sqlite.loadRowsByColumn(
        db,
        table: visibleLibraryView,
        column: column,
        rawValues: rawValues,
        destination: destination,
        mapRow: LibraryRowMapper.decode,
      );
    }

    await Future.wait([
      loadColumn('id', requests.map((request) => request.id ?? ''), byId),
      loadColumn('isrc', requests.map((request) => request.isrc ?? ''), byIsrc),
      loadColumn(
        'match_key',
        requests.map(
          (request) => matchKeyFor(request.trackName, request.artistName),
        ),
        byMatchKey,
      ),
    ]);

    return requests
        .map((request) {
          final id = request.id?.trim() ?? '';
          if (id.isNotEmpty && byId[id] != null) return byId[id];
          final isrc = request.isrc?.trim() ?? '';
          if (isrc.isNotEmpty && byIsrc[isrc] != null) return byIsrc[isrc];
          return byMatchKey[matchKeyFor(request.trackName, request.artistName)];
        })
        .toList(growable: false);
  }

  Future<LocalLibraryLookupIndex> getLookupIndex() async {
    final db = await database;
    final rows = await db.rawQuery('''
      SELECT summary.kind, summary.value
      FROM $lookupSummaryTable summary
      JOIN library_sources source ON source.id = summary.source_id
      WHERE source.enabled = 1 AND source.available = 1
      GROUP BY summary.kind, summary.value
    ''');
    final isrcs = <String>{};
    final matchKeys = <String>{};
    for (final row in rows) {
      final value = row['value'] as String?;
      if (value == null || value.isEmpty) continue;
      if (row['kind'] == 'isrc') {
        isrcs.add(value);
      } else if (row['kind'] == 'match') {
        matchKeys.add(value);
      }
    }
    return LocalLibraryLookupIndex(
      isrcs: Set<String>.unmodifiable(isrcs),
      matchKeys: Set<String>.unmodifiable(matchKeys),
    );
  }

  /// Physical copies sharing one ISRC, excluding inactive NAS sources and
  /// alternate index/URI references to the same file. Best quality comes first.
  Future<List<IsrcDuplicateGroup>> findIsrcDuplicateGroups() async {
    final db = await database;
    await _ensureHistoryAttached(db);
    return readIsrcDuplicateGroups(
      db,
      loadNetworkConnections: NetworkStorageService.instance.connections,
    );
  }

  Future<List<String>> getPhysicalFileIds(Iterable<String> filePaths) async =>
      sqlite.findPhysicalFileRowIds(await database, 'library', filePaths);

  Future<void> deleteByPath(String filePath) async {
    final db = await database;
    final rows = await db.query(
      'library',
      columns: ['id'],
      where: 'file_path = ?',
      whereArgs: [filePath],
    );
    final ids = rows.map((row) => row['id'] as String).toList(growable: false);
    await sqlite.transactionWithBusyRetry(db, (txn) async {
      for (final id in ids) {
        await txn.delete(
          'library_path_keys',
          where: 'item_id = ?',
          whereArgs: [id],
        );
      }
      await txn.delete(
        'library',
        where: 'file_path = ?',
        whereArgs: [filePath],
      );
    });
  }

  Future<void> replaceWithConvertedItem({
    required LocalLibraryItem item,
    required String newFilePath,
    required String targetFormat,
    required String bitrate,
    int? bitDepth,
    int? sampleRate,
    bool keepOriginal = false,
  }) async {
    final db = await database;
    final stat = await fileStat(newFilePath);
    final now = DateTime.now();
    final normalizedFormat = _normalizeConvertedFormat(targetFormat);
    final convertedBitrate =
        _convertedBitrate(targetFormat: targetFormat, bitrate: bitrate) ??
        estimateAverageBitrateKbps(
          fileSizeBytes: stat?.size,
          durationSeconds: item.duration,
        );
    final updated = item.toJson()
      ..['id'] = _generateLibraryId(newFilePath)
      ..['filePath'] = newFilePath
      ..['scannedAt'] = now.toIso8601String()
      ..['fileModTime'] = stat?.modified?.millisecondsSinceEpoch
      ..['format'] = normalizedFormat
      ..['bitrate'] = convertedBitrate
      // Conversion may rewrite gain tags; rescan the resulting file.
      ..['hasReplayGain'] = false
      ..['audioMetadataScanVersion'] = 0;

    if (normalizedFormat == 'mp3' ||
        normalizedFormat == 'opus' ||
        normalizedFormat == 'aac') {
      updated['bitDepth'] = null;
      updated['sampleRate'] = null;
    } else {
      updated['bitDepth'] = bitDepth ?? item.bitDepth;
      updated['sampleRate'] = sampleRate ?? item.sampleRate;
    }

    await sqlite.transactionWithBusyRetry(db, (txn) async {
      if (!keepOriginal) {
        await txn.delete(
          'library_path_keys',
          where: 'item_id = ?',
          whereArgs: [item.id],
        );
        await txn.delete(
          'library',
          where: 'id = ? OR file_path = ?',
          whereArgs: [item.id, item.filePath],
        );
      }
      await txn.insert(
        'library',
        LibraryRowMapper.encode(updated),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      final batch = txn.batch();
      _putPathKeysInBatch(
        batch,
        updated['id'] as String,
        updated['filePath'] as String?,
      );
      await batch.commit(noResult: true);
    });
  }

  Future<void> updateAudioMetadata(
    String id, {
    int? duration,
    int? bitDepth,
    int? sampleRate,
    int? bitrate,
    bool? explicit,
    bool? hasLyrics,
    bool? hasReplayGain,
    String? format,
  }) async {
    final values = <String, dynamic>{};
    if (duration != null && duration > 0) {
      values['duration'] = duration;
    }
    if (bitDepth != null && bitDepth > 0) {
      values['bit_depth'] = bitDepth;
    }
    if (sampleRate != null && sampleRate > 0) {
      values['sample_rate'] = sampleRate;
    }
    if (bitrate != null && bitrate > 0) {
      values['bitrate'] = bitrate;
    }
    if (explicit != null) {
      values['explicit'] = explicit ? 1 : 0;
    }
    if (hasLyrics != null) {
      values['has_lyrics'] = hasLyrics ? 1 : 0;
    }
    if (hasReplayGain != null) {
      values['has_replaygain'] = hasReplayGain ? 1 : 0;
    }
    final normalizedFormat = normalizeAudioFormatValue(format);
    if (normalizedFormat != null) {
      values['format'] = normalizedFormat;
    }
    if (values.isEmpty) return;

    final db = await database;
    if (hasReplayGain == null && hasLyrics == null) {
      await db.update('library', values, where: 'id = ?', whereArgs: [id]);
      return;
    }
    // A quality-only update must not confirm absent tags. ReplayGain-only
    // writes can advance lyrics-aware rows, while older rows still rescan.
    final replayGainOnly = hasReplayGain != null && hasLyrics == null;
    final scanVersion = hasReplayGain != null
        ? audioMetadataScanVersion
        : lyricsMetadataScanVersion;
    final versionSql = replayGainOnly
        ? 'CASE WHEN COALESCE(audio_metadata_scan_version, 0) >= ? '
              'THEN MAX(COALESCE(audio_metadata_scan_version, 0), ?) '
              'ELSE COALESCE(audio_metadata_scan_version, 0) END'
        : 'MAX(COALESCE(audio_metadata_scan_version, 0), ?)';
    final columns = values.keys.toList(growable: false);
    await db.rawUpdate(
      'UPDATE library SET ${columns.map((column) => '$column = ?').join(', ')}, '
      'audio_metadata_scan_version = $versionSql WHERE id = ?',
      [
        ...columns.map((column) => values[column]),
        if (replayGainOnly) lyricsMetadataScanVersion,
        scanVersion,
        id,
      ],
    );
  }

  Future<void> deleteByIds(Iterable<String> ids) async {
    if (ids.isEmpty) return;
    await deleteLibraryItemsByIds(await database, ids);
  }

  Future<int> cleanupMissingFiles({
    String? sourceId,
    Future<bool> Function()? canDelete,
  }) async {
    final db = await database;
    final removed = await cleanupMissingLibraryRows(
      db,
      sourceId: sourceId,
      canDelete: canDelete,
    );

    if (removed > 0) {
      _log.i('Cleaned up $removed missing files from library');
    }
    return removed;
  }

  Future<void> clearAll() async {
    final db = await database;
    await sqlite.transactionWithBusyRetry(db, (txn) async {
      await txn.delete('library_path_keys');
      await txn.delete('library');
      await txn.update('library_sources', {
        'last_scanned_at': null,
        'last_scan_error': null,
      });
    });
    _log.i('Cleared all library data');
  }

  Future<int> getCount() async {
    final db = await database;
    final result = await db.rawQuery(
      'SELECT COUNT(*) as count FROM $visibleLibraryView',
    );
    return Sqflite.firstIntValue(result) ?? 0;
  }

  Future<int> getSourceCount(String sourceId) async {
    final db = await database;
    final result = await db.rawQuery(
      'SELECT COUNT(*) as count FROM library WHERE source_id = ?',
      [sourceId],
    );
    return Sqflite.firstIntValue(result) ?? 0;
  }

  Future<void> close() async {
    final db = await database;
    await db.close();
    _database.reset();
    _historyAttached = false;
    _fileSizes = null;
    _searchFtsAvailable = null;
  }

  Future<Map<String, int>> getFileModTimes({String? sourceId}) async {
    final db = await database;
    final rows = await db.rawQuery(
      'SELECT file_path, COALESCE(file_mod_time, 0) AS file_mod_time, '
      'audio_metadata_scan_version FROM library '
      '${sourceId == null ? '' : 'WHERE source_id = ?'}',
      sourceId == null ? const [] : [sourceId],
    );
    final result = <String, int>{};
    for (final row in rows) {
      final path = row['file_path'] as String;
      final modTime = (row['file_mod_time'] as num?)?.toInt() ?? 0;
      final scanVersion =
          (row['audio_metadata_scan_version'] as num?)?.toInt() ?? 0;
      // A sentinel timestamp keeps the path in deletion/dedup checks while
      // making the incremental scanner treat a legacy row as changed once.
      result[path] = libraryIncrementalSnapshotModTime(
        storedModTime: modTime,
        storedScanVersion: scanVersion,
      );
    }
    return result;
  }

  Future<void> updateFileModTimes(Map<String, int> fileModTimes) async {
    if (fileModTimes.isEmpty) return;
    final db = await database;
    final batch = db.batch();
    for (final entry in fileModTimes.entries) {
      batch.update(
        'library',
        {'file_mod_time': entry.value, 'sort_added': entry.value},
        where: 'file_path = ?',
        whereArgs: [entry.key],
      );
    }
    await batch.commit(noResult: true);
  }

  Future<int> deleteByPaths(List<String> filePaths) async {
    if (filePaths.isEmpty) return 0;
    final db = await database;
    var totalDeleted = 0;
    const chunkSize = 500;
    // One commit for the whole removal; a rescan that dropped a folder can
    // otherwise pay several WAL commits per chunk.
    await sqlite.transactionWithBusyRetry(db, (txn) async {
      for (var i = 0; i < filePaths.length; i += chunkSize) {
        final end = (i + chunkSize < filePaths.length)
            ? i + chunkSize
            : filePaths.length;
        final chunk = filePaths.sublist(i, end);
        final placeholders = List.filled(chunk.length, '?').join(',');
        await txn.rawDelete(
          'DELETE FROM library_path_keys WHERE item_id IN '
          '(SELECT id FROM library WHERE file_path IN ($placeholders))',
          chunk,
        );
        totalDeleted += await txn.rawDelete(
          'DELETE FROM library WHERE file_path IN ($placeholders)',
          chunk,
        );
      }
    });
    if (totalDeleted > 0) {
      _log.i('Deleted $totalDeleted items from library');
    }
    return totalDeleted;
  }

  String _normalizeConvertedFormat(String targetFormat) {
    return normalizeAudioFormatValue(targetFormat) ?? 'mp3';
  }

  int? _convertedBitrate({
    required String targetFormat,
    required String bitrate,
  }) {
    switch (targetFormat.trim().toLowerCase()) {
      case 'mp3':
      case 'opus':
      case 'aac':
        final match = RegExp(r'(\d+)').firstMatch(bitrate);
        return match != null ? int.tryParse(match.group(1)!) : null;
      default:
        return null;
    }
  }

  String _generateLibraryId(String filePath) {
    return 'lib_${_hashString(filePath).toRadixString(16)}';
  }

  int _hashString(String input) {
    var hash = 5381;
    for (final codeUnit in input.codeUnits) {
      hash = (((hash << 5) + hash) + codeUnit) & 0xffffffff;
    }
    return hash;
  }
}

/// Migrates the pre-multiple-folder setting even when its placeholder row is
/// absent. Do not REPLACE an existing source or change the IDs of its tracks.
Future<void> persistLegacyLibrarySource(
  Database db,
  LocalLibrarySource source,
) async {
  final values = <String, Object?>{
    'path': source.path,
    'display_name': source.displayName,
    'bookmark': source.bookmark,
    'volume_id': source.volumeId,
    'is_removable': source.isRemovable ? 1 : 0,
    'available': source.available ? 1 : 0,
    'last_scanned_at': source.lastScannedAt?.toIso8601String(),
    'last_seen_at': source.lastSeenAt?.toIso8601String(),
  };
  await sqlite.transactionWithBusyRetry(db, (txn) async {
    final updated = await txn.update(
      'library_sources',
      values,
      where: 'id = ?',
      whereArgs: [source.id],
    );
    if (updated == 0) {
      await txn.insert('library_sources', {
        'id': source.id,
        'enabled': source.enabled ? 1 : 0,
        ...values,
      });
    }
  });
}
