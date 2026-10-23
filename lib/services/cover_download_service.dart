import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/services/platform_bridge.dart';
import 'package:mornye/utils/string_utils.dart';

class SavedCoverResult {
  final String fileName;

  const SavedCoverResult({required this.fileName});
}

class CoverDownloadService {
  const CoverDownloadService._();

  static Future<SavedCoverResult> saveRemoteCover({
    required String coverUrl,
    required String baseName,
    required AppSettings settings,
  }) async {
    final normalizedUrl = normalizeRemoteHttpUrl(coverUrl);
    if (normalizedUrl == null) {
      throw const FormatException('No remote cover art source available');
    }

    final safeBaseName = await PlatformBridge.sanitizeFilename(baseName.trim());
    final resolvedBaseName = safeBaseName.trim().isEmpty
        ? 'cover'
        : safeBaseName.trim();
    final tempDir = await Directory.systemTemp.createTemp('save_cover_');
    var tempPath = p.join(tempDir.path, 'cover.image');
    IosSecurityScopedAccess? iosBookmarkAccess;

    try {
      final download = await PlatformBridge.downloadCoverToFile(
        normalizedUrl,
        PlatformBridge.supportsCoreBackend ? '' : tempPath,
      );
      final error = download['error']?.toString().trim() ?? '';
      if (error.isNotEmpty) throw StateError(error);
      tempPath = download['file_path'] as String? ?? tempPath;

      final tempFile = File(tempPath);
      if (!await tempFile.exists() || await tempFile.length() <= 0) {
        throw const FileSystemException('Downloaded cover is empty');
      }

      final format = await detectCoverFileFormat(tempFile);
      final requestedFileName = '${resolvedBaseName}_cover.${format.extension}';

      if (Platform.isAndroid && settings.storageMode == 'saf') {
        final treeUri = settings.downloadTreeUri.trim();
        if (treeUri.isEmpty) {
          throw const FileSystemException('No storage access');
        }
        final result = await PlatformBridge.createUniqueSafFileFromPath(
          treeUri: treeUri,
          relativeDir: '',
          fileName: requestedFileName,
          mimeType: format.mimeType,
          srcPath: tempPath,
        );
        final uri = result['uri']?.toString().trim() ?? '';
        final fileName = result['file_name']?.toString().trim() ?? '';
        final writeError = result['error']?.toString().trim() ?? '';
        if (writeError.isNotEmpty) throw StateError(writeError);
        if (uri.isEmpty || fileName.isEmpty) {
          throw const FileSystemException('Failed to write cover to storage');
        }
        return SavedCoverResult(fileName: fileName);
      }

      var outputDirectory = settings.downloadDirectory.trim();
      if (Platform.isIOS && settings.downloadDirectoryBookmark.isNotEmpty) {
        iosBookmarkAccess = await PlatformBridge.startAccessingIosBookmark(
          settings.downloadDirectoryBookmark,
        );
        final resolved = iosBookmarkAccess?.path;
        if (resolved == null || resolved.trim().isEmpty) {
          throw const FileSystemException('No storage access');
        }
        outputDirectory = resolved.trim();
      }
      if (outputDirectory.isEmpty) {
        final documents = await getApplicationDocumentsDirectory();
        outputDirectory = p.join(documents.path, 'Mornye');
      }

      final directory = Directory(outputDirectory);
      await directory.create(recursive: true);
      final outputPath = await uniqueFilePath(
        directory.path,
        requestedFileName,
      );
      await tempFile.copy(outputPath);
      return SavedCoverResult(fileName: p.basename(outputPath));
    } finally {
      if (iosBookmarkAccess != null) {
        await PlatformBridge.stopAccessingIosBookmark(iosBookmarkAccess);
      }
      try {
        final tempFile = File(tempPath);
        if (await tempFile.exists()) await tempFile.delete();
        if (await tempDir.exists()) await tempDir.delete(recursive: true);
      } catch (_) {}
    }
  }

  static Future<({String extension, String mimeType})> detectCoverFileFormat(
    File file,
  ) async {
    final reader = await file.open();
    try {
      final bytes = await reader.read(12);
      if (bytes.length >= 8 &&
          bytes[0] == 0x89 &&
          bytes[1] == 0x50 &&
          bytes[2] == 0x4e &&
          bytes[3] == 0x47) {
        return (extension: 'png', mimeType: 'image/png');
      }
      if (bytes.length >= 12 &&
          bytes[0] == 0x52 &&
          bytes[1] == 0x49 &&
          bytes[2] == 0x46 &&
          bytes[3] == 0x46 &&
          bytes[8] == 0x57 &&
          bytes[9] == 0x45 &&
          bytes[10] == 0x42 &&
          bytes[11] == 0x50) {
        return (extension: 'webp', mimeType: 'image/webp');
      }
      return (extension: 'jpg', mimeType: 'image/jpeg');
    } finally {
      await reader.close();
    }
  }

  static Future<String> uniqueFilePath(
    String directory,
    String fileName,
  ) async {
    var candidate = p.join(directory, fileName);
    if (!await File(candidate).exists()) return candidate;

    final extension = p.extension(fileName);
    final stem = p.basenameWithoutExtension(fileName);
    var counter = 2;
    while (await File(candidate).exists()) {
      candidate = p.join(directory, '$stem ($counter)$extension');
      counter++;
    }
    return candidate;
  }
}
