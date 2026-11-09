import 'dart:async';
import 'dart:io';

import 'package:mornye/models/track.dart';
import 'package:mornye/services/platform_bridge.dart';
import 'package:mornye/services/playback_metadata.dart';
import 'package:mornye/services/player_lyrics_persistence.dart';
import 'package:mornye/utils/file_access.dart';
import 'package:mornye/utils/logger.dart';
import 'package:mornye/utils/lyrics_metadata_helper.dart';

final _log = AppLogger('BatchLyricsSync');

class BatchLyricsProgress {
  final int completed;
  final int total;
  final int successful;
  final int failed;
  final bool isCancelled;
  final String? currentTrackName;

  const BatchLyricsProgress({
    required this.completed,
    required this.total,
    required this.successful,
    required this.failed,
    this.isCancelled = false,
    this.currentTrackName,
  });

  BatchLyricsProgress copyWith({
    int? completed,
    int? total,
    int? successful,
    int? failed,
    bool? isCancelled,
    String? currentTrackName,
  }) {
    return BatchLyricsProgress(
      completed: completed ?? this.completed,
      total: total ?? this.total,
      successful: successful ?? this.successful,
      failed: failed ?? this.failed,
      isCancelled: isCancelled ?? this.isCancelled,
      currentTrackName: currentTrackName ?? this.currentTrackName,
    );
  }
}

typedef LyricsChecker = Future<bool> Function(Track track);
typedef LyricsFetcher = Future<String> Function(Track track);
typedef LyricsTagSaver = Future<void> Function(String source, String lyrics);
typedef LyricsSidecarSaver =
    Future<void> Function(String source, String lyrics);

Future<bool> _defaultCheckHasLyrics(Track track) async {
  final source = track.source;
  if (source == null || source.isEmpty) return false;

  // 1. Check sidecar .lrc file if on filesystem
  if (!isContentUri(source)) {
    final uri = Uri.tryParse(source);
    final localPath = uri?.scheme == 'file' ? uri!.toFilePath() : source;
    final slash = localPath.lastIndexOf(Platform.pathSeparator);
    final dot = localPath.lastIndexOf('.');
    final lrcPath = (dot > slash)
        ? '${localPath.substring(0, dot)}.lrc'
        : '$localPath.lrc';
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
    final meta = await readPlaybackFileMetadataWithRetry(source);
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

Future<void> _defaultSaveTags(String source, String lyrics) async {
  await persistPlayerLyrics(source, lyrics);
}

Future<void> _defaultSaveSidecar(String source, String lyrics) async {
  if (isContentUri(source)) {
    await PlatformBridge.writeSafSidecarLrc(source, lyrics);
  } else {
    final uri = Uri.tryParse(source);
    final localPath = uri?.scheme == 'file' ? uri!.toFilePath() : source;
    final slash = localPath.lastIndexOf(Platform.pathSeparator);
    final dot = localPath.lastIndexOf('.');
    final lrcPath = (dot > slash)
        ? '${localPath.substring(0, dot)}.lrc'
        : '$localPath.lrc';
    await File(lrcPath).writeAsString(lyrics);
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

  Future<BatchLyricsProgress> syncTracks(
    List<Track> tracks, {
    required void Function(BatchLyricsProgress) onProgress,
    bool Function()? isCancelled,
    bool skipExisting = true,
  }) async {
    final toProcess = <Track>[];

    // Filter tracks
    for (final track in tracks) {
      if (isCancelled?.call() == true) {
        final cancelledProgress = BatchLyricsProgress(
          completed: 0,
          total: 0,
          successful: 0,
          failed: 0,
          isCancelled: true,
        );
        onProgress(cancelledProgress);
        return cancelledProgress;
      }
      if (!skipExisting || !await _checkHasLyrics(track)) {
        toProcess.add(track);
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

    for (final track in toProcess) {
      if (isCancelled?.call() == true) {
        final progress = BatchLyricsProgress(
          completed: completed,
          total: toProcess.length,
          successful: successful,
          failed: failed,
          isCancelled: true,
          currentTrackName: track.name,
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
          currentTrackName: track.name,
        ),
      );

      var trackSuccess = false;
      try {
        final rawLyrics = await _fetchLyrics(track);
        if (hasUsableLyricsContent(rawLyrics)) {
          final source = track.source;
          if (source != null && source.isNotEmpty) {
            // 1. Save in tags
            try {
              await _saveTags(source, rawLyrics);
            } catch (e) {
              _log.w('Could not embed tags for ${track.name}: $e');
            }

            // 2. Save sidecar .lrc file
            try {
              await _saveSidecar(source, rawLyrics);
            } catch (e) {
              _log.w('Could not write sidecar .lrc for ${track.name}: $e');
            }

            trackSuccess = true;
          }
        }
      } catch (e) {
        _log.w('Failed to sync lyrics for ${track.name}: $e');
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
          currentTrackName: track.name,
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
