import 'dart:async';
import 'dart:io';

import 'package:mornye/models/track.dart';
import 'package:mornye/services/platform_bridge.dart';
import 'package:mornye/services/playback_metadata.dart';
import 'package:mornye/services/player_lyrics_persistence.dart';
import 'package:mornye/utils/file_access.dart';
import 'package:mornye/utils/logger.dart';
import 'package:mornye/utils/lyrics_metadata_helper.dart';
import 'package:path/path.dart' as p;

final _log = AppLogger('BatchLyricsSync');

class BatchLyricsItem {
  final Track track;
  final String filePath;

  const BatchLyricsItem({required this.track, required this.filePath});
}

class BatchLyricsProgress {
  final int completed;
  final int total;
  final int successful;
  final int failed;
  final bool isCancelled;
  final String? currentTrackName;
  final bool isChecking;
  final int checkingCurrent;
  final int checkingTotal;

  const BatchLyricsProgress({
    required this.completed,
    required this.total,
    required this.successful,
    required this.failed,
    this.isCancelled = false,
    this.currentTrackName,
    this.isChecking = false,
    this.checkingCurrent = 0,
    this.checkingTotal = 0,
  });

  BatchLyricsProgress copyWith({
    int? completed,
    int? total,
    int? successful,
    int? failed,
    bool? isCancelled,
    String? currentTrackName,
    bool? isChecking,
    int? checkingCurrent,
    int? checkingTotal,
  }) {
    return BatchLyricsProgress(
      completed: completed ?? this.completed,
      total: total ?? this.total,
      successful: successful ?? this.successful,
      failed: failed ?? this.failed,
      isCancelled: isCancelled ?? this.isCancelled,
      currentTrackName: currentTrackName ?? this.currentTrackName,
      isChecking: isChecking ?? this.isChecking,
      checkingCurrent: checkingCurrent ?? this.checkingCurrent,
      checkingTotal: checkingTotal ?? this.checkingTotal,
    );
  }
}

typedef LyricsChecker = Future<bool> Function(BatchLyricsItem item);
typedef LyricsFetcher = Future<String> Function(Track track);
typedef LyricsTagSaver = Future<void> Function(String filePath, String lyrics);
typedef LyricsSidecarSaver =
    Future<bool> Function(String filePath, String lyrics);

Future<bool> _defaultCheckHasLyrics(BatchLyricsItem item) async {
  final filePath = item.filePath;
  if (filePath.isEmpty) return false;

  // 1. Check sidecar .lrc file if on filesystem
  if (!isContentUri(filePath)) {
    final uri = Uri.tryParse(filePath);
    final localPath = uri?.scheme == 'file' ? uri!.toFilePath() : filePath;
    final lrcPath = p.setExtension(localPath, '.lrc');
    try {
      final file = File(lrcPath);
      if (await file.exists()) {
        final content = await file.readAsString();
        if (hasUsableLyricsContent(content)) return true;
      }
    } catch (_) {}
  }

  // 2. Check embedded tags
  try {
    final meta = await readPlaybackFileMetadataWithRetry(filePath);
    final lyrics = meta['lyrics']?.toString() ?? '';
    if (hasUsableLyricsContent(lyrics)) return true;
  } catch (_) {}

  return false;
}

Future<String> _defaultFetchLyrics(Track track) async {
  final result = await PlatformBridge.getLyricsLRCWithSource(
    track.id,
    track.name,
    track.artistName,
    durationMs: track.duration * 1000,
  ).timeout(const Duration(seconds: 25));
  return result['lyrics']?.toString() ?? '';
}

Future<void> _defaultSaveTags(String filePath, String lyrics) async {
  await persistPlayerLyrics(filePath, lyrics);
}

Future<bool> _defaultSaveSidecar(String filePath, String lyrics) async {
  if (isContentUri(filePath)) {
    return await PlatformBridge.writeSafSidecarLrc(filePath, lyrics);
  } else {
    final uri = Uri.tryParse(filePath);
    final localPath = uri?.scheme == 'file' ? uri!.toFilePath() : filePath;
    final lrcPath = p.setExtension(localPath, '.lrc');
    await File(lrcPath).writeAsString(lyrics);
    return true;
  }
}

class BatchLyricsSyncService {
  final LyricsChecker _checkHasLyrics;
  final LyricsFetcher _fetchLyrics;
  final LyricsTagSaver _saveTags;
  final LyricsSidecarSaver _saveSidecar;

  BatchLyricsSyncService({
    LyricsChecker? checkHasLyrics,
    LyricsFetcher? fetchLyrics,
    LyricsTagSaver? saveTags,
    LyricsSidecarSaver? saveSidecar,
  }) : _checkHasLyrics = checkHasLyrics ?? _defaultCheckHasLyrics,
       _fetchLyrics = fetchLyrics ?? _defaultFetchLyrics,
       _saveTags = saveTags ?? _defaultSaveTags,
       _saveSidecar = saveSidecar ?? _defaultSaveSidecar;

  Future<BatchLyricsProgress> syncItems(
    List<BatchLyricsItem> items, {
    required void Function(BatchLyricsProgress) onProgress,
    bool Function()? isCancelled,
    bool skipExisting = true,
  }) async {
    final toProcess = <BatchLyricsItem>[];

    // Filter tracks with checking progress
    for (var i = 0; i < items.length; i++) {
      if (isCancelled?.call() == true) {
        final cancelledProgress = const BatchLyricsProgress(
          completed: 0,
          total: 0,
          successful: 0,
          failed: 0,
          isCancelled: true,
          isChecking: false,
        );
        onProgress(cancelledProgress);
        return cancelledProgress;
      }

      final item = items[i];
      if (i % 5 == 0 || i == items.length - 1) {
        onProgress(
          BatchLyricsProgress(
            completed: 0,
            total: 0,
            successful: 0,
            failed: 0,
            isChecking: true,
            checkingCurrent: i + 1,
            checkingTotal: items.length,
            currentTrackName: item.track.name,
          ),
        );
      }

      if (!skipExisting || !await _checkHasLyrics(item)) {
        toProcess.add(item);
      }
    }

    if (toProcess.isEmpty) {
      final zeroProgress = const BatchLyricsProgress(
        completed: 0,
        total: 0,
        successful: 0,
        failed: 0,
      );
      onProgress(zeroProgress);
      return zeroProgress;
    }

    var completed = 0;
    var successful = 0;
    var failed = 0;

    for (final item in toProcess) {
      if (isCancelled?.call() == true) {
        final progress = BatchLyricsProgress(
          completed: completed,
          total: toProcess.length,
          successful: successful,
          failed: failed,
          isCancelled: true,
          currentTrackName: item.track.name,
        );
        onProgress(progress);
        return progress;
      }

      onProgress(
        BatchLyricsProgress(
          completed: completed,
          total: toProcess.length,
          successful: successful,
          failed: failed,
          currentTrackName: item.track.name,
        ),
      );

      var trackSuccess = false;
      try {
        final rawLyrics = await _fetchLyrics(item.track);
        if (hasUsableLyricsContent(rawLyrics)) {
          final filePath = item.filePath;
          if (filePath.isNotEmpty) {
            var tagSaved = false;
            var sidecarSaved = false;

            // 1. Save in tags
            try {
              await _saveTags(filePath, rawLyrics);
              tagSaved = true;
            } catch (e) {
              _log.w('Could not embed tags for ${item.track.name}: $e');
            }

            // 2. Save sidecar .lrc file
            try {
              final ok = await _saveSidecar(filePath, rawLyrics);
              if (ok) sidecarSaved = true;
            } catch (e) {
              _log.w('Could not write sidecar .lrc for ${item.track.name}: $e');
            }

            if (tagSaved || sidecarSaved) {
              trackSuccess = true;
            }
          }
        }
      } catch (e) {
        _log.w('Failed to sync lyrics for ${item.track.name}: $e');
      }

      completed++;
      if (trackSuccess) {
        successful++;
      } else {
        failed++;
      }

      onProgress(
        BatchLyricsProgress(
          completed: completed,
          total: toProcess.length,
          successful: successful,
          failed: failed,
          currentTrackName: item.track.name,
        ),
      );
    }

    final finalProgress = BatchLyricsProgress(
      completed: completed,
      total: toProcess.length,
      successful: successful,
      failed: failed,
    );
    onProgress(finalProgress);
    return finalProgress;
  }
}
