import 'dart:io';
import 'dart:isolate';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';
import 'package:mornye/models/library_database_models.dart';
import 'package:mornye/services/app_state_database.dart';
import 'package:mornye/services/cache_maintenance_service.dart';
import 'package:mornye/services/history_database.dart';
import 'package:mornye/services/library_collections_database.dart';
import 'package:mornye/services/library_cover_snapshot.dart';
import 'package:mornye/services/listening_statistics.dart';
import 'package:mornye/services/native_cache_maintenance.dart';
import 'package:mornye/services/platform_bridge.dart';
import 'package:mornye/services/sqlite_helpers.dart' as sqlite;
import 'package:mornye/utils/file_access.dart';
import 'package:mornye/utils/logger.dart';

/// Removes rows superseded by a staged scan inside the caller's transaction.
/// On partial scans, an unreadable file is not evidence that it was deleted.
({String where, List<Object?> args}) libraryScanReplacementPredicate(
  String sourceId, {
  required String stageTable,
  required bool preserveMissing,
  List<String>? preserveMissingPaths,
}) {
  final args = <Object?>[sourceId];
  if (!preserveMissing) return (where: 'source_id = ?', args: args);
  final replaced =
      'id IN (SELECT id FROM $stageTable) '
      'OR file_path IN (SELECT file_path FROM $stageTable)';
  if (preserveMissingPaths == null || preserveMissingPaths.length > 128) {
    return (where: 'source_id = ? AND ($replaced)', args: args);
  }
  if (preserveMissingPaths.isEmpty) {
    return (where: 'source_id = ?', args: args);
  }
  final protected = <String>[];
  for (final path in preserveMissingPaths) {
    if (path.endsWith('/')) {
      // Literal prefixes preserve percent signs and underscores in NAS names.
      protected.add('substr(file_path, 1, length(?)) = ?');
      args.addAll([path, path]);
    } else {
      protected.add('file_path = ?');
      args.add(path);
    }
  }
  return (
    where:
        'source_id = ? AND ($replaced OR '
        'NOT (${protected.join(' OR ')}))',
    args: args,
  );
}

Future<void> deleteReplacedLibraryScanRows(
  DatabaseExecutor db,
  String sourceId, {
  required String stageTable,
  required bool preserveMissing,
  List<String>? preserveMissingPaths,
}) async {
  final predicate = libraryScanReplacementPredicate(
    sourceId,
    stageTable: stageTable,
    preserveMissing: preserveMissing,
    preserveMissingPaths: preserveMissingPaths,
  );
  await db.rawDelete(
    'DELETE FROM library_path_keys WHERE item_id IN '
    '(SELECT id FROM library WHERE ${predicate.where})',
    predicate.args,
  );
  await db.rawDelete(
    'DELETE FROM library WHERE ${predicate.where}',
    predicate.args,
  );
}

/// Deletes a selection atomically without exceeding SQLite's parameter budget.
Future<void> deleteLibraryItemsByIds(Database db, Iterable<String> ids) async {
  final uniqueIds = ids.toSet().toList();
  if (uniqueIds.isEmpty) return;
  await db.transaction((txn) async {
    const chunkSize = 500;
    for (var start = 0; start < uniqueIds.length; start += chunkSize) {
      final chunk = uniqueIds.sublist(
        start,
        (start + chunkSize).clamp(0, uniqueIds.length),
      );
      final placeholders = List.filled(chunk.length, '?').join(',');
      await txn.delete(
        'library_path_keys',
        where: 'item_id IN ($placeholders)',
        whereArgs: chunk,
      );
      await txn.delete(
        'library',
        where: 'id IN ($placeholders)',
        whereArgs: chunk,
      );
    }
  });
}

/// Every store besides the `library` table that keeps Library cover paths
/// copied from rows, the player or Link save offline.
Future<List<LibraryCoverReferenceColumn>>
appLibraryCoverReferenceColumns() async {
  final collections = await LibraryCollectionsDatabase.instance.database;
  final appState = await AppStateDatabase.instance.database;
  final history = await HistoryDatabase.instance.database;
  final statistics = await ListeningStatisticsStore.instance.database;
  return [
    for (final table in const [
      'wishlist_tracks',
      'loved_tracks',
      'playlist_tracks',
    ])
      (database: collections, table: table, column: 'track_json'),
    (database: collections, table: 'playlists', column: 'cover_image_path'),
    (database: collections, table: 'favorite_artists', column: 'artist_json'),
    (database: appState, table: 'playback_session', column: 'media_json'),
    (database: appState, table: 'playback_resume', column: 'media_json'),
    (database: appState, table: 'playback_resume', column: 'preview_json'),
    (database: appState, table: 'recent_access_items', column: 'item_json'),
    (database: appState, table: 'download_queue_items', column: 'item_json'),
    (database: history, table: 'history', column: 'cover_url'),
    (database: statistics, table: 'listening', column: 'artwork'),
  ];
}

/// Deletes files in [directory] that neither the Library nor
/// [referenceColumns] (see [appLibraryCoverReferenceColumns]) name.
Future<int> pruneUnreferencedLibraryCovers(
  Directory directory,
  Set<String> referencedPaths, {
  required Iterable<LibraryCoverReferenceColumn> referenceColumns,
  Database? libraryDatabase,
  String? requestId,
  Duration minimumAge = Duration.zero,
  NativeCacheJobRunner? nativeJobRunner,
  bool Function()? canPrune,
  Directory? temporaryDirectory,
}) async {
  if (minimumAge.isNegative) {
    throw ArgumentError.value(minimumAge, 'minimumAge');
  }
  if (canPrune != null && !canPrune()) return 0;
  final stored = await readStoredLibraryCoverPaths(directory, referenceColumns);
  if (canPrune != null && !canPrune()) return 0;
  if (libraryDatabase != null) {
    if (nativeJobRunner == null && !PlatformBridge.supportsCoreBackend) {
      return libraryDatabase.transaction((txn) async {
        final paths = await readLibraryCoverReferences(txn);
        if (canPrune != null && !canPrune()) return 0;
        return _pruneUnreferencedLibraryCovers(
          directory,
          {...paths, ...stored},
          requestId: requestId,
          minimumAge: minimumAge,
        );
      }, exclusive: true);
    }
    return withLibraryCoverSnapshot(
      libraryDatabase,
      (privatePath) => _pruneUnreferencedLibraryCovers(
        directory,
        const {},
        privateSnapshotPath: privatePath,
        requestId: requestId,
        minimumAge: minimumAge,
        nativeJobRunner: nativeJobRunner,
      ),
      canPrune: canPrune,
      temporaryDirectory: temporaryDirectory,
      storedReferences: stored,
    );
  }
  return _pruneUnreferencedLibraryCovers(
    directory,
    {...referencedPaths, ...stored},
    requestId: requestId,
    minimumAge: minimumAge,
    nativeJobRunner: nativeJobRunner,
  );
}

Future<int> _pruneUnreferencedLibraryCovers(
  Directory directory,
  Set<String> referencedPaths, {
  String? privateSnapshotPath,
  String? requestId,
  required Duration minimumAge,
  NativeCacheJobRunner? nativeJobRunner,
}) async {
  final result = await runNativeCacheMaintenance(
    {
      'operation': 'cache_prune_library',
      'directory': directory.absolute.path,
      'library_path': ?privateSnapshotPath,
      if (privateSnapshotPath == null)
        'referenced_paths': referencedPaths.toList(growable: false),
      'minimum_age_us': minimumAge.inMicroseconds,
    },
    requestId: requestId,
    nativeJobRunner: nativeJobRunner,
  );
  if (result != null) {
    final deleted = cacheMaintenanceDeletedCount(result);
    final errors = result['errors'];
    if (errors is List) {
      for (final error in errors.whereType<String>()) {
        AppLogger('LocalLibrary').w(error);
      }
      final count = result['error_count'];
      if (count is int && count > errors.length) {
        AppLogger('LocalLibrary').w(
          'Failed deleting ${count - errors.length} additional stale library cover cache files',
        );
      }
    }
    return deleted;
  }
  if (privateSnapshotPath != null) {
    throw StateError(
      'The desktop cache adapter requires explicit cover references',
    );
  }
  final path = directory.path;
  final outcome = await _pruneCoversOnWorker(path, referencedPaths, minimumAge);
  for (final error in outcome.errors) {
    AppLogger('LocalLibrary').w(error);
  }
  return outcome.deleted;
}

Future<({int deleted, List<String> errors})> _pruneCoversOnWorker(
  String path,
  Set<String> references,
  Duration minimumAge,
) => Isolate.run(() => _pruneCoversInWorker(path, references, minimumAge));

Future<({int deleted, List<String> errors})> _pruneCoversInWorker(
  String path,
  Set<String> referencedPaths,
  Duration minimumAge,
) async {
  final directory = Directory(path);
  final cutoff = DateTime.now().subtract(minimumAge);
  final references = {
    ...referencedPaths,
    for (final path in referencedPaths) ?_subsonicCoverPointer(path),
  };
  // Native scans may return canonical paths while Dart lists a directory alias.
  final retainedPaths = {...references};
  for (final path in references) {
    try {
      retainedPaths.add(await File(path).resolveSymbolicLinks());
    } on FileSystemException {
      // Missing cache files can remain referenced until the next full scan.
    }
  }
  var deleted = 0;
  final errors = <String>[];
  await for (final entity in directory.list(
    recursive: true,
    followLinks: false,
  )) {
    if (entity is! File || retainedPaths.contains(entity.path)) continue;
    try {
      if (retainedPaths.contains(await entity.resolveSymbolicLinks())) continue;
      final before = await entity.stat();
      if (before.type != FileSystemEntityType.file ||
          before.modified.isAfter(cutoff)) {
        continue;
      }
      await entity.delete();
      deleted++;
    } catch (error) {
      final message =
          'Failed deleting stale library cover cache ${entity.path}: $error';
      errors.add(message);
    }
  }
  return (deleted: deleted, errors: errors);
}

/// Deletes every file in [directory] (Settings, Storage) and marks the local
/// Library rows whose covers lived there for one rescan, so the next scan of
/// any kind extracts them again under the same names. Network songs need no
/// mark: their scan already reads a song again when its cover file is gone.
/// Returns the number of marked rows.
Future<int> clearLibraryCoverFiles(
  Directory directory,
  Database libraryDatabase,
) async {
  await CacheMaintenanceService.clearDirectoryContents(directory.path);
  // Rows keep the scan's spelling of the folder (canonical /data/data on
  // older Android, backslashes on Windows), so match the folder by name:
  // after the clear, every file in a library_covers folder is gone.
  // Below the audio version, the incremental snapshot reports the file as
  // changed; the lyrics version keeps lyrics filters as they were meanwhile.
  return sqlite.transactionWithBusyRetry(
    libraryDatabase,
    (txn) => txn.rawUpdate(
      'UPDATE library SET audio_metadata_scan_version = ? '
      'WHERE audio_metadata_scan_version > ? '
      r"AND cover_path GLOB '*[/\]library_covers[/\]*' "
      "AND file_path NOT LIKE 'network://%'",
      [libraryLyricsMetadataScanVersion, libraryLyricsMetadataScanVersion],
    ),
    exclusive: true,
  );
}

final _subsonicCover = RegExp(r'^subsonic_([0-9a-fA-F]{64})(?:_.*)?\.image$');

/// A Subsonic cover (`subsonic_<hash>.image`, or `subsonic_<hash>_<id>.image`
/// after a refresh) is found again through `subsonic_<hash>.image.current`.
String? _subsonicCoverPointer(String path) {
  final hash = _subsonicCover.firstMatch(p.basename(path))?.group(1);
  return hash == null
      ? null
      : p.join(p.dirname(path), 'subsonic_$hash.image.current');
}

/// Pages by stable ID (not OFFSET, since rows are removed during traversal).
/// A high-water mark bounds the run if a concurrent scan adds new rows.
Future<int> cleanupMissingLibraryRows(
  Database db, {
  String? sourceId,
  Future<bool> Function()? canDelete,
  Future<Map<String, bool?>> Function(List<String>) checkPaths =
      fileExistenceByPath,
}) async {
  const pageSize = 256;
  final sourceWhere = sourceId == null ? null : 'source_id = ?';
  final sourceArgs = sourceId == null ? null : <Object?>[sourceId];
  final last = await db.query(
    'library',
    columns: ['id'],
    where: sourceWhere,
    whereArgs: sourceArgs,
    orderBy: 'id DESC',
    limit: 1,
  );
  if (last.isEmpty) return 0;
  final upperId = last.single['id'] as String;
  String? cursor;
  var removed = 0;
  while (true) {
    final rows = await db.query(
      'library',
      columns: ['id', 'file_path'],
      where: [
        ?sourceWhere,
        'id <= ?',
        if (cursor != null) 'id > ?',
      ].join(' AND '),
      whereArgs: [?sourceId, upperId, ?cursor],
      orderBy: 'id ASC',
      limit: pageSize,
    );
    if (rows.isEmpty) break;
    cursor = rows.last['id'] as String;
    final paths = rows.map((row) => row['file_path'] as String).toList();
    Map<String, bool?> checks;
    try {
      checks = await checkPaths(paths);
    } catch (_) {
      continue; // No deletion on a failed batch.
    }
    final missing = rows
        .where((row) => checks[row['file_path']] == false)
        .toList();
    if (missing.isEmpty) continue;
    if (canDelete != null) {
      try {
        if (!await canDelete()) break;
      } catch (_) {
        break;
      }
    }
    // Compare the original path as well: a scan may repair it while I/O runs.
    final conditions = List.filled(
      missing.length,
      '(id = ? AND file_path = ?)',
    ).join(' OR ');
    final where =
        '($conditions)${sourceWhere == null ? '' : ' AND $sourceWhere'}';
    final args = <Object?>[
      for (final row in missing) ...[row['id'], row['file_path']],
      ?sourceId,
    ];
    removed += await db.transaction((txn) async {
      await txn.rawDelete(
        'DELETE FROM library_path_keys WHERE item_id IN '
        '(SELECT id FROM library WHERE $where)',
        args,
      );
      return txn.rawDelete('DELETE FROM library WHERE $where', args);
    });
  }
  return removed;
}
