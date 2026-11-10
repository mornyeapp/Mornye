import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:mornye/services/metadata_cover_resources.dart';
import 'package:mornye/services/metadata_persistence_service.dart';
import 'package:mornye/services/platform_bridge.dart';
import 'package:mornye/utils/artist_utils.dart';

/// Persists lyrics for the current player track safely without disrupting playback.
///
/// If playing via SAF (content://) or local filesystem, writes an external .lrc sidecar
/// to avoid truncating or rewriting the actively open audio file descriptor.
Future<void> persistPlayerLyricsSafely(String source, String lyrics) async {
  if (lyrics.trim().isEmpty) return;

  if (source.startsWith('content://')) {
    try {
      final success = await PlatformBridge.writeSafSidecarLrc(source, lyrics);
      if (success) return;
    } catch (_) {}
  } else if (!source.startsWith('network://')) {
    final uri = Uri.tryParse(source);
    final localPath = uri?.scheme == 'file' ? uri!.toFilePath() : source;
    if (p.posix.isAbsolute(localPath) || p.windows.isAbsolute(localPath)) {
      try {
        final lrcPath = p.setExtension(localPath, '.lrc');
        await File(lrcPath).writeAsString(lyrics);
        return;
      } catch (_) {}
    }
  }

  await persistPlayerLyrics(source, lyrics);
}

/// Writes to the owning source, never to a resolved playback cache or stream.
Future<void> persistPlayerLyrics(String source, String lyrics) async {
  final uri = Uri.tryParse(source);
  final localPath = uri?.scheme == 'file' ? uri!.toFilePath() : source;
  if (!source.startsWith('content://') &&
      !source.startsWith('network://') &&
      !p.posix.isAbsolute(localPath) &&
      !p.windows.isAbsolute(localPath)) {
    throw UnsupportedError('The playing source is not an editable audio file');
  }
  final covers = MetadataCoverResources();
  try {
    final result = await MetadataPersistenceService(covers: covers).save(
      MetadataSaveRequest(
        filePath: localPath,
        metadata: {'lyrics': lyrics},
        artistTagMode: artistTagModeJoined,
        preserveUnspecifiedTags: true,
      ),
    );
    if (result.failure != null) {
      throw result.error ?? StateError('Could not embed the fetched lyrics');
    }
  } finally {
    await covers.dispose();
  }
}
