import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:mornye/services/ffmpeg_metadata.dart';
import 'package:mornye/services/ffmpeg_probe.dart';
import 'package:mornye/utils/file_access.dart';

const _playlistCoverMaxDimension = 1024;
const _playlistCoverMaxStoredBytes = 2 * 1024 * 1024;

/// File storage for user playlist covers under the app support
/// `playlist_covers` directory. Covers are stored as `<playlistId>.jpg`,
/// normalized to at most [_playlistCoverMaxDimension] pixels and
/// [_playlistCoverMaxStoredBytes] bytes.
class PlaylistCoverStore {
  const PlaylistCoverStore({
    Future<Directory> Function() supportDirectory =
        getApplicationSupportDirectory,
  }) : _supportDirectory = supportDirectory;

  final Future<Directory> Function() _supportDirectory;

  /// Resolves the covers directory on every call and creates it when missing.
  Future<Directory> coversDirectory() async {
    final appDir = await _supportDirectory();
    final dir = Directory(p.join(appDir.path, 'playlist_covers'));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  /// Writes a normalized JPEG for [playlistId] from [sourceFilePath] and
  /// returns its path. Errors propagate; the temporary file is always removed.
  Future<String> normalize(String playlistId, String sourceFilePath) async {
    final coversDir = await coversDirectory();
    final destPath = p.join(coversDir.path, '$playlistId.jpg');
    final tempPath = p.join(
      coversDir.path,
      '.$playlistId.${DateTime.now().microsecondsSinceEpoch}.jpg',
    );
    try {
      final dimensions = await FFmpegProbe.imageDimensions(sourceFilePath);
      final longestEdge = dimensions == null
          ? _playlistCoverMaxDimension
          : (dimensions.width > dimensions.height
                ? dimensions.width
                : dimensions.height);
      var targetDimension = longestEdge
          .clamp(64, _playlistCoverMaxDimension)
          .toInt();
      while (true) {
        final resized = await FFmpegMetadata.resizeCoverArt(
          inputPath: sourceFilePath,
          outputPath: tempPath,
          maxDimension: targetDimension,
        );
        if (!resized) {
          throw StateError('Unable to normalize playlist cover');
        }
        if (await File(tempPath).length() <= _playlistCoverMaxStoredBytes) {
          break;
        }
        if (targetDimension <= 64) {
          throw StateError('Normalized playlist cover exceeds the size limit');
        }
        targetDimension = (targetDimension * 3 ~/ 4)
            .clamp(64, targetDimension)
            .toInt();
      }
      final destination = File(destPath);
      if (await destination.exists()) await destination.delete();
      await File(tempPath).rename(destPath);
      return destPath;
    } finally {
      await deleteFileQuietly(File(tempPath));
    }
  }

  Future<bool> needsNormalization(String path) async {
    final file = File(path);
    if (!await file.exists()) return false;
    if (p.extension(path).toLowerCase() != '.jpg' ||
        await file.length() > _playlistCoverMaxStoredBytes) {
      return true;
    }
    final dimensions = await FFmpegProbe.imageDimensions(path);
    return dimensions == null ||
        dimensions.width > _playlistCoverMaxDimension ||
        dimensions.height > _playlistCoverMaxDimension;
  }

  /// Deletes the cover at [path] when it exists. Errors propagate.
  Future<void> delete(String path) async {
    final file = File(path);
    if (await file.exists()) {
      await file.delete();
    }
  }

  /// Deletes the cover at [path] when it exists and swallows any error.
  Future<void> deleteQuietly(String path) => deleteFileQuietly(File(path));

  /// Whether [path] exists and is not empty. Errors propagate.
  Future<bool> hasContent(String path) async {
    final file = File(path);
    return await file.exists() && await file.length() != 0;
  }

  /// Restores a backup cover for [id] into [coversDir] from either an
  /// extracted file at [restoredPath] or legacy base64 [data], then
  /// normalizes it. Returns null when any step fails.
  Future<String?> restoreFromBackup({
    required Directory coversDir,
    required String id,
    required String ext,
    String? restoredPath,
    String? data,
  }) async {
    try {
      final sourcePath = p.join(
        coversDir.path,
        '.$id.restore${ext.startsWith('.') ? ext : '.$ext'}',
      );
      final source = File(sourcePath);
      if (restoredPath != null && restoredPath.isNotEmpty) {
        await File(restoredPath).copy(source.path);
      } else {
        await source.writeAsBytes(base64Decode(data!), flush: true);
      }
      try {
        return await normalize(id, sourcePath);
      } finally {
        await deleteFileQuietly(source);
      }
    } catch (_) {
      return null;
    }
  }
}
