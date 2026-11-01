import 'package:sqflite/sqflite.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mornye/models/download_history.dart';
import 'package:mornye/services/sqlite_helpers.dart' as sqlite;
import 'package:mornye/utils/ios_container_paths.dart';

/// Restored history can contain an older container even after this install's
/// startup migration ran. Update stored paths and their match keys together.
/// The version marker also repairs restores performed before this fix.
Future<int?> migrateIosHistoryPaths(
  Database db,
  SharedPreferences prefs, {
  required String containerPath,
  bool force = false,
}) async {
  const version = 1;
  const versionKey = 'ios_history_path_migration_version';
  if (!force &&
      prefs.getString('ios_last_container_path') == containerPath &&
      prefs.getInt(versionKey) == version) {
    return null;
  }

  final updated = await sqlite.transactionWithBusyRetry(db, (txn) async {
    var count = 0;
    String? afterId;
    while (true) {
      final rows = await txn.query(
        'history',
        columns: ['id', 'file_path'],
        where: afterId == null ? null : 'id > ?',
        whereArgs: afterId == null ? null : [afterId],
        orderBy: 'id',
        limit: 256,
      );
      if (rows.isEmpty) break;
      final batch = txn.batch();
      for (final row in rows) {
        final previous = row['file_path'] as String?;
        if (previous == null) continue;
        final current = rebaseIosSandboxPath(
          previous,
          '$containerPath/Documents',
        );
        if (current == previous) continue;
        final id = row['id'] as String;
        batch.update(
          'history',
          {'file_path': current},
          where: 'id = ?',
          whereArgs: [id],
        );
        sqlite.putPathKeysInBatch(batch, 'history_path_keys', id, current);
        count++;
      }
      await batch.commit(noResult: true);
      afterId = rows.last['id'] as String;
      if (rows.length < 256) break;
    }
    return count;
  });
  await prefs.setString('ios_last_container_path', containerPath);
  await prefs.setInt(versionKey, version);
  return updated;
}

/// A delayed probe owns only fields it changed on the file it inspected.
/// Newer user edits and results for a replacement file remain authoritative.
class HistoryMaintenanceUpdate {
  const HistoryMaintenanceUpdate({
    required this.original,
    required this.updated,
  });

  final DownloadHistoryItem original;
  final DownloadHistoryItem updated;

  DownloadHistoryItem? mergeInto(DownloadHistoryItem current) {
    if (current.id != original.id ||
        current.filePath != original.filePath ||
        !current.downloadedAt.isAtSameMomentAs(original.downloadedAt)) {
      return null;
    }
    final before = original.toJson();
    final next = current.toJson();
    final keepLyrics =
        current.lyricsMetadataScanVersion != original.lyricsMetadataScanVersion;
    final keepReplayGain =
        current.replayGainMetadataScanVersion !=
        original.replayGainMetadataScanVersion;
    for (final field in updated.toJson().entries) {
      if (field.value == before[field.key] ||
          next[field.key] != before[field.key]) {
        continue;
      }
      if (keepLyrics &&
          (field.key == 'hasLyrics' ||
              field.key == 'lyricsMetadataScanVersion')) {
        continue;
      }
      if (keepReplayGain &&
          (field.key == 'hasReplayGain' ||
              field.key == 'replayGainMetadataScanVersion')) {
        continue;
      }
      next[field.key] = field.value;
    }
    return DownloadHistoryItem.fromJson(next);
  }
}

/// Called inside a transaction. Delayed metadata/SAF probes must never insert
/// rows deleted by orphan cleanup while the probe was running.
Future<Set<String>> updateExistingHistoryRows(
  DatabaseExecutor db,
  Iterable<Map<String, dynamic>> rows,
) async {
  final updatedIds = <String>{};
  final batch = db.batch();
  for (final row in rows) {
    final id = row['id'] as String;
    final changed = await db.update(
      'history',
      row,
      where: 'id = ?',
      whereArgs: [id],
    );
    if (changed == 0) continue;
    updatedIds.add(id);
    sqlite.putPathKeysInBatch(
      batch,
      'history_path_keys',
      id,
      row['file_path'] as String?,
    );
  }
  if (updatedIds.isNotEmpty) await batch.commit(noResult: true);
  return updatedIds;
}
