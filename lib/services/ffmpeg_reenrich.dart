import 'dart:io';

import 'package:mornye/services/ffmpeg_metadata.dart';
import 'package:mornye/services/library_database.dart';
import 'package:mornye/services/platform_bridge.dart';
import 'package:mornye/utils/file_access.dart';
import 'package:mornye/utils/lyrics_metadata_helper.dart';

bool _hasValue(String? value) => value != null && value.trim().isNotEmpty;

Future<void> _safeDeleteFile(String path) async {
  await deleteFileQuietly(File(path));
}

Future<void> _cleanupTempFileAndParent(String path) async {
  await _safeDeleteFile(path);
  try {
    final parent = File(path).parent;
    if (await parent.exists()) {
      await parent.delete();
    }
  } catch (_) {}
}

/// Embeds [result]'s metadata/cover into [item] via FFmpeg while preserving
/// existing tags, writes the output back through SAF when the source was staged
/// to a temp file, drops the filesystem .lrc sidecar, and cleans up every temp
/// artifact (including on the SAF-write failure path). Returns true when the
/// FFmpeg step produced an output.
///
/// Shared by the local-album and queue batch re-enrich flows. The track-detail
/// screen keeps its own copy because it drives snackbars and does not preserve
/// existing metadata.
Future<bool> applyFfmpegReEnrichResult({
  required LocalLibraryItem item,
  required Map<String, dynamic> result,
  required String artistTagMode,
}) async {
  final tempPath = result['temp_path'] as String?;
  final safUri = result['saf_uri'] as String?;
  final ffmpegTarget = _hasValue(tempPath) ? tempPath! : item.filePath;
  final downloadedCoverPath = result['cover_path'] as String?;
  String? effectiveCoverPath = downloadedCoverPath;
  String? extractedCoverPath;

  try {
    if (!_hasValue(effectiveCoverPath)) {
      Directory? extractionDirectory;
      try {
        final tempDir = await Directory.systemTemp.createTemp(
          'reenrich_cover_',
        );
        extractionDirectory = tempDir;
        final coverOutput = '${tempDir.path}${Platform.pathSeparator}cover.jpg';
        final extracted = await PlatformBridge.extractCoverToFile(
          ffmpegTarget,
          coverOutput,
        );
        if (extracted['error'] == null) {
          effectiveCoverPath = coverOutput;
          extractedCoverPath = coverOutput;
        }
      } catch (_) {
      } finally {
        if (extractedCoverPath == null && extractionDirectory != null) {
          try {
            await extractionDirectory.delete(recursive: true);
          } catch (_) {}
        }
      }
    }

    final metadata = (result['metadata'] as Map<String, dynamic>?)?.map(
      (k, v) => MapEntry(k, v.toString()),
    );
    final format = item.format?.toLowerCase();
    final lowerPath = item.filePath.toLowerCase();
    final isMp3 = format == 'mp3' || lowerPath.endsWith('.mp3');
    final isM4A =
        format == 'm4a' ||
        format == 'aac' ||
        lowerPath.endsWith('.m4a') ||
        lowerPath.endsWith('.aac');
    final isOpus =
        format == 'opus' ||
        format == 'ogg' ||
        lowerPath.endsWith('.opus') ||
        lowerPath.endsWith('.ogg');

    String? ffmpegResult;
    if (isMp3) {
      ffmpegResult = await FFmpegMetadata.embedMetadataToMp3(
        mp3Path: ffmpegTarget,
        coverPath: effectiveCoverPath,
        metadata: metadata,
        artistTagMode: artistTagMode,
        preserveMetadata: true,
      );
    } else if (isM4A) {
      ffmpegResult = await FFmpegMetadata.embedMetadataToM4a(
        m4aPath: ffmpegTarget,
        coverPath: effectiveCoverPath,
        metadata: metadata,
        artistTagMode: artistTagMode,
        preserveMetadata: true,
      );
    } else if (isOpus) {
      ffmpegResult = await FFmpegMetadata.embedMetadataToOpus(
        opusPath: ffmpegTarget,
        coverPath: effectiveCoverPath,
        metadata: metadata,
        artistTagMode: artistTagMode,
        preserveMetadata: true,
      );
    }

    if (ffmpegResult != null && _hasValue(tempPath) && _hasValue(safUri)) {
      final ok = await PlatformBridge.writeTempToSaf(ffmpegResult, safUri!);
      if (!ok) return false;
      await writeReEnrichSafSidecarLrc(safUri: safUri, reEnrichResult: result);
    }

    if (ffmpegResult != null) {
      await writeReEnrichSidecarLrc(
        audioFilePath: item.filePath,
        reEnrichResult: result,
      );
    }
    return ffmpegResult != null;
  } finally {
    if (_hasValue(downloadedCoverPath)) {
      await _safeDeleteFile(downloadedCoverPath!);
    }
    if (_hasValue(extractedCoverPath)) {
      await _cleanupTempFileAndParent(extractedCoverPath!);
    }
    if (_hasValue(tempPath)) {
      await _safeDeleteFile(tempPath!);
    }
  }
}
