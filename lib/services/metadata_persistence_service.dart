import 'dart:io';

import 'package:mornye/services/ffmpeg_metadata.dart';
import 'package:mornye/services/metadata_cover_resources.dart';
import 'package:mornye/services/platform_bridge.dart';
import 'package:mornye/utils/artist_utils.dart';

enum MetadataSaveFailure {
  backend,
  ffmpeg,
  storage,
  noCover,
  resize,
  unexpected,
}

class MetadataSaveResult {
  final MetadataSaveFailure? failure;
  final Object? error;

  const MetadataSaveResult.saved() : failure = null, error = null;
  const MetadataSaveResult.failed(
    MetadataSaveFailure this.failure, [
    this.error,
  ]);
}

class MetadataSaveRequest {
  final String filePath;
  final Map<String, String> metadata;
  final String artistTagMode;
  final String? selectedCoverPath;
  final String? currentCoverPath;
  final int? coverMaxDimension;

  MetadataSaveRequest({
    required this.filePath,
    required Map<String, String> metadata,
    required this.artistTagMode,
    this.selectedCoverPath,
    this.currentCoverPath,
    this.coverMaxDimension,
  }) : metadata = Map.unmodifiable(metadata);
}

enum MetadataSaveCodec { mp3, m4a, opus }

typedef MetadataEmbed =
    Future<String?> Function(
      MetadataSaveCodec codec,
      String path,
      String? coverPath,
      Map<String, String> metadata,
      String artistTagMode,
    );

/// Writes tags without widget state, and owns resources until every writer ends.
class MetadataPersistenceService {
  final MetadataCoverResources covers;
  final Future<Map<String, dynamic>> Function(String, Map<String, String>) edit;
  final Future<Map<String, dynamic>> Function(String) read;
  final MetadataEmbed embed;
  final Future<bool> Function(String, String) writeBack;

  const MetadataPersistenceService({
    required this.covers,
    this.edit = PlatformBridge.editFileMetadata,
    this.read = PlatformBridge.readFileMetadata,
    this.embed = _embed,
    this.writeBack = PlatformBridge.writeTempToSaf,
  });

  Future<MetadataSaveResult> save(MetadataSaveRequest request) async {
    final releaseLease = covers.retain();
    String? resizedCoverDir;
    String? extractedCoverDir;
    String? stagedPath;
    try {
      var coverPath = request.selectedCoverPath;
      if (request.coverMaxDimension case final dimension?) {
        final source = coverPath ?? request.currentCoverPath;
        if (source == null || source.trim().isEmpty) {
          return const MetadataSaveResult.failed(MetadataSaveFailure.noCover);
        }
        try {
          final resized = await covers.resize(source, dimension);
          resizedCoverDir = resized.tempDir;
          coverPath = resized.path;
        } catch (error) {
          return MetadataSaveResult.failed(MetadataSaveFailure.resize, error);
        }
      }

      final metadata = {
        ...request.metadata,
        'artist_tag_mode': request.artistTagMode,
        'cover_path': coverPath ?? '',
      };
      final result = await edit(request.filePath, metadata);
      stagedPath = result['temp_path'] as String?;
      if (result['error'] case final error?) {
        return MetadataSaveResult.failed(MetadataSaveFailure.backend, error);
      }
      if (result['method'] != 'ffmpeg') {
        return const MetadataSaveResult.saved();
      }

      final target = stagedPath ?? request.filePath;
      final tags = _fallbackTags(metadata);
      try {
        final existing = await read(target);
        for (final key in const [
          'REPLAYGAIN_TRACK_GAIN',
          'REPLAYGAIN_TRACK_PEAK',
          'REPLAYGAIN_ALBUM_GAIN',
          'REPLAYGAIN_ALBUM_PEAK',
        ]) {
          final value = existing[key.toLowerCase()]?.toString() ?? '';
          if (value.isNotEmpty) tags[key] = value;
        }
      } catch (_) {
        // Computed ReplayGain tags are preserved when the reader is available.
      }
      var existingCover = coverPath ?? request.currentCoverPath;
      if (existingCover == null || existingCover.isEmpty) {
        final extracted = await covers.extract(target);
        existingCover = extracted?.path;
        extractedCoverDir = extracted?.tempDir;
      }

      final codec = _codec(request.filePath);
      final output = codec == null
          ? null
          : await embed(
              codec,
              target,
              existingCover,
              tags,
              codec == MetadataSaveCodec.opus
                  ? request.artistTagMode
                  : artistTagModeJoined,
            );
      if (output == null) {
        return const MetadataSaveResult.failed(MetadataSaveFailure.ffmpeg);
      }
      final safUri = result['saf_uri'] as String?;
      if (stagedPath != null &&
          safUri != null &&
          !await writeBack(output, safUri)) {
        return const MetadataSaveResult.failed(MetadataSaveFailure.storage);
      }
      return const MetadataSaveResult.saved();
    } catch (error) {
      return MetadataSaveResult.failed(MetadataSaveFailure.unexpected, error);
    } finally {
      // Android also deletes on writeback; failed FFmpeg never reaches it.
      if (stagedPath != null && stagedPath != request.filePath) {
        try {
          await File(stagedPath).delete();
        } catch (_) {}
      }
      await covers.release(extractedCoverDir);
      await covers.release(resizedCoverDir);
      await releaseLease();
    }
  }

  static MetadataSaveCodec? _codec(String path) {
    final lower = path.toLowerCase();
    if (lower.endsWith('.mp3')) return MetadataSaveCodec.mp3;
    if (lower.endsWith('.m4a') || lower.endsWith('.aac')) {
      return MetadataSaveCodec.m4a;
    }
    if (lower.endsWith('.opus') || lower.endsWith('.ogg')) {
      return MetadataSaveCodec.opus;
    }
    return null;
  }

  static Map<String, String> _fallbackTags(Map<String, String> metadata) {
    String index(String key) {
      final number = metadata['${key}_number'] ?? '';
      final total = metadata['${key}_total'] ?? '';
      if (number.isEmpty || number == '0') return '';
      return total.isEmpty || total == '0' ? number : '$number/$total';
    }

    // Emit empty values too: preserve custom tags while clearing edited fields.
    return {
      for (final entry in const {
        'TITLE': 'title',
        'ARTIST': 'artist',
        'ALBUM': 'album',
        'ALBUMARTIST': 'album_artist',
        'DATE': 'date',
        'GENRE': 'genre',
        'ISRC': 'isrc',
        'LYRICS': 'lyrics',
        'UNSYNCEDLYRICS': 'lyrics',
        'ORGANIZATION': 'label',
        'COPYRIGHT': 'copyright',
        'COMPOSER': 'composer',
        'COMMENT': 'comment',
        'ITUNESADVISORY': 'explicit',
        'RELEASETYPE': 'album_type',
        'BARCODE': 'upc',
        'COMPILATION': 'compilation',
      }.entries)
        entry.key: metadata[entry.value] ?? '',
      'TRACKNUMBER': index('track'),
      'DISCNUMBER': index('disc'),
    };
  }

  static Future<String?> _embed(
    MetadataSaveCodec codec,
    String path,
    String? coverPath,
    Map<String, String> metadata,
    String artistTagMode,
  ) => switch (codec) {
    MetadataSaveCodec.mp3 => FFmpegMetadata.embedMetadataToMp3(
      mp3Path: path,
      coverPath: coverPath,
      metadata: metadata,
      preserveMetadata: true,
    ),
    MetadataSaveCodec.m4a => FFmpegMetadata.embedMetadataToM4a(
      m4aPath: path,
      coverPath: coverPath,
      metadata: metadata,
      preserveMetadata: true,
    ),
    MetadataSaveCodec.opus => FFmpegMetadata.embedMetadataToOpus(
      opusPath: path,
      coverPath: coverPath,
      metadata: metadata,
      artistTagMode: artistTagMode,
      preserveMetadata: true,
    ),
  };
}
