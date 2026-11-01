import 'package:sqflite/sqflite.dart';
import 'package:mornye/models/library_database_models.dart';
import 'package:mornye/services/library_schema.dart';
import 'package:mornye/services/network_storage_service.dart';
import 'package:mornye/utils/path_match_keys.dart';

/// Review physical copies, not index rows. History remains intact when a NAS
/// source is disabled, but must not suggest deleting its replacement SAF copy.
Future<List<IsrcDuplicateGroup>> readIsrcDuplicateGroups(
  DatabaseExecutor db, {
  Map<String, NetworkConnection> networkConnections = const {},
  Future<List<NetworkConnection>> Function()? loadNetworkConnections,
}) async {
  final rows = await db.rawQuery('''
    WITH active_history AS (
      SELECT h.* FROM history_db.history h
      WHERE NOT (
        h.file_path LIKE 'network://%'
        AND EXISTS (
          SELECT 1 FROM library_sources s
          WHERE (s.enabled = 0 OR s.available = 0)
            AND substr(h.file_path, 1, length(s.path)) = s.path
        )
        AND NOT EXISTS (
          SELECT 1 FROM library_sources s
          WHERE s.enabled = 1 AND s.available = 1
            AND substr(h.file_path, 1, length(s.path)) = s.path
        )
      )
    ), merged AS (
      SELECT h.id, 'downloaded' AS source, h.track_name, h.artist_name,
             h.file_path, UPPER(TRIM(h.isrc)) AS isrc_key,
             h.bit_depth, h.sample_rate, h.bitrate, h.format
      FROM active_history h
      WHERE h.isrc IS NOT NULL AND TRIM(h.isrc) != ''
      UNION ALL
      SELECT l.id, 'local' AS source, l.track_name, l.artist_name,
             l.file_path, UPPER(TRIM(l.isrc)) AS isrc_key,
             l.bit_depth, l.sample_rate, l.bitrate, l.format
      FROM ${LibrarySchema.visibleView} l
      WHERE l.isrc IS NOT NULL AND TRIM(l.isrc) != ''
    )
    SELECT * FROM merged
    WHERE isrc_key IN (
      SELECT isrc_key FROM merged GROUP BY isrc_key HAVING COUNT(*) > 1
    )
    ORDER BY isrc_key, bit_depth DESC, sample_rate DESC, bitrate DESC, source, id
  ''');

  final connections =
      loadNetworkConnections != null &&
          rows.any(
            (row) =>
                (row['file_path'] as String? ?? '').startsWith('network://'),
          )
      ? {
          for (final connection in await loadNetworkConnections())
            connection.id: connection,
        }
      : networkConnections;

  final groups = <String, List<IsrcDuplicateEntry>>{};
  final pathsByIsrc = <String, Set<String>>{};
  for (final row in rows) {
    final isrc = row['isrc_key'] as String? ?? '';
    final path = row['file_path'] as String? ?? '';
    if (isrc.isEmpty || path.isEmpty) continue;
    final remoteKey = NetworkStorageService.physicalFileKey(path, connections);
    final keys = {...buildPhysicalPathMatchKeys(path), ?remoteKey};
    final seen = pathsByIsrc.putIfAbsent(isrc, () => {});
    final alreadySeen = keys.any(seen.contains);
    seen.addAll(keys);
    if (alreadySeen) continue;
    groups
        .putIfAbsent(isrc, () => [])
        .add(
          IsrcDuplicateEntry(
            id: row['id'] as String,
            source: row['source'] as String,
            trackName: row['track_name'] as String? ?? '',
            artistName: row['artist_name'] as String? ?? '',
            filePath: path,
            bitDepth: (row['bit_depth'] as num?)?.toInt(),
            sampleRate: (row['sample_rate'] as num?)?.toInt(),
            bitrate: (row['bitrate'] as num?)?.toInt(),
            format: row['format'] as String?,
          ),
        );
  }
  return [
    for (final entry in groups.entries)
      if (entry.value.length > 1)
        IsrcDuplicateGroup(isrc: entry.key, entries: entry.value),
  ];
}
