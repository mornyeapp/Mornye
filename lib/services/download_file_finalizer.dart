import 'dart:io';

import 'package:mornye/models/download_result.dart';
import 'package:mornye/services/download_saf_file_replacer.dart';
import 'package:mornye/services/ffmpeg_models.dart';
import 'package:mornye/utils/audio_conversion_utils.dart';
import 'package:mornye/utils/audio_format_utils.dart';
import 'package:mornye/utils/file_access.dart';

typedef DecryptDownloadFile =
    Future<String?> Function({
      required String inputPath,
      required DownloadDecryptionDescriptor descriptor,
      required bool deleteOriginal,
      Future<void> Function(String)? prepareOutput,
    });

typedef ConvertDownloadAudio =
    Future<String?> Function({
      required String inputPath,
      required String targetFormat,
      required String bitrate,
      required bool deleteOriginal,
    });

enum DownloadDecryptionFailure { safAccess, decrypt, safWrite }

class DownloadDecryptionOutcome {
  const DownloadDecryptionOutcome(this.path, {this.fileName, this.failure});
  final String? path;
  final String? fileName;
  final DownloadDecryptionFailure? failure;
}

class DownloadConversionOutcome {
  const DownloadConversionOutcome({
    required this.filePath,
    required this.fileName,
    required this.quality,
    this.converted = false,
  });
  final String filePath;
  final String? fileName;
  final String quality;
  final bool converted;
}

/// Owns audio transforms and their optional-failure policy. Queue state,
/// settings, track enrichment and platform storage stay at the call boundary.
class DownloadFileFinalizer {
  const DownloadFileFinalizer({
    required this.decryptFile,
    required this.probeCodec,
    required this.repairAc4,
    required this.convertAudio,
    required this.replaceSafFile,
    required this.warn,
    required this.info,
  });

  final DecryptDownloadFile decryptFile;
  final Future<String?> Function(String) probeCodec;
  final Future<void> Function(String path, String encryptedPath) repairAc4;
  final ConvertDownloadAudio convertAudio;
  final ReplaceSafDownloadFile replaceSafFile;
  final void Function(String) warn;
  final void Function(String) info;

  Future<String> _normalizeIsoBmffPath(
    String path,
    DownloadResult result,
  ) async {
    if (!_isMp4Container(path)) return path;
    final codec = await probeCodec(path);
    final extension = isoBmffAudioExtensionForCodec(
      codec ?? result.reportedFormat,
    );
    if (path.toLowerCase().endsWith(extension)) return path;
    final targetPath = path.replaceFirst(
      RegExp(r'\.(?:m4a|mp4)$', caseSensitive: false),
      extension,
    );
    if (targetPath == path) return path;
    try {
      if (await File(targetPath).exists()) {
        warn(
          'Cannot normalize ISO-BMFF audio extension; target already exists: $targetPath',
        );
        return path;
      }
      return (await File(path).rename(targetPath)).path;
    } catch (e) {
      warn('Failed to normalize ISO-BMFF audio extension for $path: $e');
      return path;
    }
  }

  Future<void> _repair(String path, String encryptedPath) async {
    if (!_isMp4Container(path)) return;
    try {
      await repairAc4(path, encryptedPath);
    } catch (e) {
      warn('AC-4 container repair skipped: $e');
    }
  }

  Future<DownloadDecryptionOutcome> decrypt({
    required DownloadResult result,
    required String filePath,
    required bool useSaf,
    String? treeUri,
    required String relativeDir,
    required String baseName,
    required String extensionFallback,
    required bool repairContainer,
    void Function(String strategy)? onStart,
  }) async {
    if (result.alreadyExists) return DownloadDecryptionOutcome(filePath);
    final descriptor = result.decryption;
    if (descriptor == null) {
      return DownloadDecryptionOutcome(filePath);
    }
    onStart?.call(descriptor.normalizedStrategy);
    if (useSaf && isContentUri(filePath)) {
      if (treeUri == null || treeUri.isEmpty) {
        return const DownloadDecryptionOutcome(
          null,
          failure: DownloadDecryptionFailure.safAccess,
        );
      }
      DownloadDecryptionFailure? failure;
      var started = false;
      String? fileName;
      final uri = await replaceSafFile(
        uri: filePath,
        treeUri: treeUri,
        relativeDir: relativeDir,
        op: (tempPath, addCleanup) async {
          started = true;
          final decrypted = await decryptFile(
            inputPath: tempPath,
            descriptor: descriptor,
            deleteOriginal: false,
          );
          if (decrypted == null) {
            failure = DownloadDecryptionFailure.decrypt;
            return null;
          }
          addCleanup(decrypted);
          final normalized = await _normalizeIsoBmffPath(decrypted, result);
          if (normalized != decrypted) addCleanup(normalized);
          if (repairContainer) await _repair(normalized, tempPath);
          final dotIndex = normalized.lastIndexOf('.');
          final extension = dotIndex >= 0
              ? normalized.substring(dotIndex).toLowerCase()
              : extensionFallback;
          const allowed = {'.flac', '.m4a', '.mp4', '.mp3', '.opus'};
          fileName =
              '$baseName${allowed.contains(extension) ? extension : extensionFallback}';
          return (normalized, fileName!);
        },
      );
      return DownloadDecryptionOutcome(
        uri,
        fileName: uri == null ? null : fileName,
        failure: uri == null
            ? failure ??
                  (started
                      ? DownloadDecryptionFailure.safWrite
                      : DownloadDecryptionFailure.safAccess)
            : null,
      );
    }
    final decrypted = await decryptFile(
      inputPath: filePath,
      descriptor: descriptor,
      deleteOriginal: true,
      // Repair before the encrypted source is removed by atomic promotion.
      prepareOutput: repairContainer ? (path) => _repair(path, filePath) : null,
    );
    return DownloadDecryptionOutcome(
      decrypted == null ? null : await _normalizeIsoBmffPath(decrypted, result),
      failure: decrypted == null ? DownloadDecryptionFailure.decrypt : null,
    );
  }

  Future<DownloadConversionOutcome> autoConvert({
    required DownloadResult result,
    required String filePath,
    required String? fileName,
    required String quality,
    required bool enabled,
    required String targetFormat,
    required String targetBitrate,
    required bool useSaf,
    String? treeUri,
    String relativeDir = '',
    Future<void> Function(String path, String format)? embedMetadata,
    void Function()? onStart,
  }) async {
    final original = DownloadConversionOutcome(
      filePath: filePath,
      fileName: fileName,
      quality: quality,
    );
    if (!enabled) return original;
    targetFormat = normalizeAutoConvertFormat(targetFormat);
    targetBitrate = normalizeAutoConvertBitrate(targetBitrate);
    final bitrateKbps = autoConvertBitrateKbps(targetBitrate);
    if (autoConversionAlreadySatisfied(
      filePath: filePath,
      fileName: fileName,
      targetFormat: targetFormat,
      targetBitrate: targetBitrate,
      quality: quality,
      bitrateKbps: result.bitrateKbps,
    )) {
      return original;
    }
    final baseName = fileName?.trim().isNotEmpty == true
        ? fileName!.trim()
        : downloadSourceFileName(filePath);
    final convertedName = convertedOutputFileName(
      originalFileName: baseName,
      targetFormat: targetFormat,
    );
    Future<void> embed(String path) async {
      try {
        await embedMetadata?.call(
          path,
          metadataFormatForLossyFormat(targetFormat),
        );
      } catch (e) {
        warn('Automatic conversion metadata embed failed: $e');
        result['auto_conversion_metadata_warning'] = e.toString();
      }
    }

    try {
      onStart?.call();
      String? convertedPath;
      String? publishedName = convertedName;
      if (useSaf && isContentUri(filePath)) {
        if (treeUri == null || treeUri.isEmpty) {
          throw StateError('Missing SAF tree for automatic conversion');
        }
        convertedPath = await replaceSafFile(
          uri: filePath,
          treeUri: treeUri,
          relativeDir: relativeDir,
          avoidOverwrite: convertedName.toLowerCase() != baseName.toLowerCase(),
          onPublishedFileName: (value) => publishedName = value,
          op: (tempPath, addCleanup) async {
            final output = await convertAudio(
              inputPath: tempPath,
              targetFormat: targetFormat,
              bitrate: targetBitrate,
              deleteOriginal: false,
            );
            if (output == null) return null;
            addCleanup(output);
            await embed(output);
            return (output, convertedName);
          },
        );
      } else {
        convertedPath = await convertAudio(
          inputPath: filePath,
          targetFormat: targetFormat,
          bitrate: targetBitrate,
          deleteOriginal: true,
        );
        if (convertedPath != null) {
          // Deferred SAF outputs keep their logical name while in cache.
          if (!useSaf) {
            publishedName = File(convertedPath).uri.pathSegments.last;
          }
          await embed(convertedPath);
        }
      }
      if (convertedPath == null || convertedPath.isEmpty) {
        throw StateError('FFmpeg returned no automatic conversion output');
      }
      result.markConvertedAudio(
        path: convertedPath,
        name: publishedName,
        format: targetFormat,
        bitrateKbps: bitrateKbps,
      );
      info(
        'Automatic conversion completed: ${autoConvertFormatLabel(targetFormat)} @ $targetBitrate',
      );
      return DownloadConversionOutcome(
        filePath: convertedPath,
        fileName: publishedName,
        quality:
            '${displayFormatForLossyFormat(targetFormat)} ${bitrateKbps}kbps',
        converted: true,
      );
    } catch (e) {
      // FFmpeg removes the source only after atomic output promotion.
      result['auto_conversion_warning'] = e.toString();
      warn('Automatic conversion failed; keeping downloaded source: $e');
      return original;
    }
  }
}

/// The file name of a downloaded file. A SAF document URI has no file name segment: its
/// last segment is the percent-encoded document id (`primary:Music/Album/Song.flac`), of
/// which the name is the part after the last `/` and `:`.
String downloadSourceFileName(String filePath) {
  if (!isContentUri(filePath)) return File(filePath).uri.pathSegments.last;
  final segments = Uri.tryParse(filePath)?.pathSegments ?? const <String>[];
  var name = segments.isEmpty ? filePath : segments.last;
  for (final separator in const ['/', ':']) {
    final index = name.lastIndexOf(separator);
    if (index >= 0 && index + 1 < name.length) name = name.substring(index + 1);
  }
  return name;
}

bool _isMp4Container(String path) {
  final lower = path.toLowerCase();
  return lower.endsWith('.m4a') || lower.endsWith('.mp4');
}
