import 'package:mornye/models/track.dart';
import 'package:mornye/services/history_database.dart';
import 'package:mornye/services/download_file_recovery.dart';
import 'package:mornye/services/library_database.dart';
import 'package:mornye/services/platform_bridge.dart';
import 'package:mornye/utils/file_access.dart';

/// The file each of [tracks] plays from, or null when it has none: a scanned
/// Library file first when [includeLocal] (Local Library is on), then a
/// download. [missingHistoryIds] names downloads whose file is gone, which
/// callers may remove from History.
Future<({List<String?> paths, Set<String> missingHistoryIds})>
resolveTrackFiles(
  List<Track> tracks, {
  required LibraryDatabase library,
  required HistoryDatabase history,
  required bool includeLocal,
  Future<String?> Function(String source, String? historyId)? recoverDownload,
}) async {
  if (tracks.isEmpty) {
    return (paths: const <String?>[], missingHistoryIds: const <String>{});
  }
  final localFuture = includeLocal
      ? library.findExistingBatch([
          for (final track in tracks)
            LocalLibraryBatchLookupRequest(
              id: (track.source ?? '').toLowerCase() == 'local'
                  ? track.id
                  : null,
              isrc: track.isrc,
              trackName: track.name,
              artistName: track.artistName,
            ),
        ])
      : Future.value(List<Map<String, dynamic>?>.filled(tracks.length, null));
  final historyFuture = history.findExistingTracks([
    for (final track in tracks)
      HistoryLookupRequest(
        spotifyId: track.id,
        isrc: track.isrc,
        trackName: track.name,
        artistName: track.artistName,
      ),
  ]);
  final localMatches = await localFuture;
  final historyMatches = await historyFuture;

  final results = List<String?>.filled(tracks.length, null);
  final existsChecks = <String, Future<bool>>{};
  final unknownSafPaths = <String>{};
  final safPaths = <String>{
    for (final row in [...localMatches, ...historyMatches])
      if (isContentUri(stripCueTrackSuffix(row?['filePath']?.toString() ?? '')))
        stripCueTrackSuffix(row!['filePath'].toString()),
  }.toList(growable: false);
  for (var start = 0; start < safPaths.length; start += 64) {
    final batch = safPaths.sublist(
      start,
      (start + 64).clamp(0, safPaths.length),
    );
    try {
      final checks = await PlatformBridge.safExistsBatch(batch);
      for (final path in batch) {
        final exists = checks[path];
        if (exists != null) {
          existsChecks[path] = Future.value(exists);
        } else {
          unknownSafPaths.add(path);
        }
      }
    } catch (_) {
      // Older bindings may lack the batch API; retain per-file fallback.
      unknownSafPaths.addAll(batch);
    }
  }
  final invalidHistoryIds = <String>{};
  final recovery = DownloadFileRecovery(history: history);
  var next = 0;
  final workerCount = tracks.length < 8 ? tracks.length : 8;

  Future<bool> pathExists(String path) {
    final realPath = stripCueTrackSuffix(path);
    return existsChecks.putIfAbsent(realPath, () => fileExists(path));
  }

  Future<void> worker() async {
    while (true) {
      final index = next++;
      if (index >= tracks.length) return;
      final localPath = localMatches[index]?['filePath']?.toString() ?? '';
      if (localPath.isNotEmpty && await pathExists(localPath)) {
        results[index] = localPath;
        continue;
      }

      final historyMatch = historyMatches[index];
      final historyPath = historyMatch?['filePath']?.toString() ?? '';
      if (historyPath.isNotEmpty && await pathExists(historyPath)) {
        results[index] = historyPath;
        continue;
      }
      final historyId = historyMatch?['id']?.toString() ?? '';
      if (historyPath.isNotEmpty) {
        try {
          final moved = recoverDownload != null
              ? await recoverDownload(historyPath, historyId)
              : await recovery.recover(
                  historyPath,
                  historyId: historyId,
                  knownMissing: true,
                );
          if (moved != null) {
            results[index] = moved;
            continue;
          }
        } catch (_) {
          // Failed access or a concurrent edit cannot establish an orphan.
          continue;
        }
      }
      if (historyId.isNotEmpty &&
          !unknownSafPaths.contains(stripCueTrackSuffix(historyPath))) {
        invalidHistoryIds.add(historyId);
      }
    }
  }

  await Future.wait(List.generate(workerCount, (_) => worker()));
  return (paths: results, missingHistoryIds: invalidHistoryIds);
}
