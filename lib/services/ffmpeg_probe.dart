import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:mornye/services/ffmpeg_support.dart';
import 'package:mornye/utils/logger.dart';

final _log = AppLogger('FFmpeg');

class PrimaryAudioProperties {
  final String? codec;
  final int? bitDepth;
  final int? sampleRate;

  const PrimaryAudioProperties({this.codec, this.bitDepth, this.sampleRate});
}

class _AudioProbeCacheEntry {
  final String identity;
  final Future<PrimaryAudioProperties> result;

  const _AudioProbeCacheEntry({required this.identity, required this.result});
}

/// Media inspection owns its cache independently of conversion and tagging.
abstract final class FFmpegProbe {
  static final Map<String, _AudioProbeCacheEntry> _cache = {};

  static void invalidate(String path) => _cache.remove(path);

  @visibleForTesting
  static ({int width, int height})? imageDimensionsFromProperties(
    Map<dynamic, dynamic> properties,
  ) {
    final width = int.tryParse(properties['width']?.toString() ?? '');
    final height = int.tryParse(properties['height']?.toString() ?? '');
    if (width == null || height == null || width <= 0 || height <= 0) {
      return null;
    }
    return (width: width, height: height);
  }

  static Future<({int width, int height})?> imageDimensions(String path) async {
    try {
      final info = await FFmpegExecution.mediaInformation(path);
      if (info == null) return null;
      for (final stream in info.getStreams()) {
        final dimensions = imageDimensionsFromProperties(
          stream.getAllProperties() ?? const <String, dynamic>{},
        );
        if (dimensions != null) return dimensions;
      }
    } catch (e) {
      _log.w('Cover dimension probe failed for $path: $e');
    }
    return null;
  }

  static Future<String?> audioCodec(String path) async =>
      (await audioProperties(path)).codec;

  static Future<String?> _identity(String path) async {
    try {
      final stat = await File(path).stat();
      if (stat.type != FileSystemEntityType.file) return null;
      return '${stat.modified.millisecondsSinceEpoch}:${stat.size}';
    } catch (_) {
      return null;
    }
  }

  static Future<PrimaryAudioProperties> audioProperties(String path) async {
    final identity = await _identity(path);
    if (identity != null) {
      final cached = _cache[path];
      if (cached != null && cached.identity == identity) return cached.result;
    }
    final result = _readAudioProperties(path);
    if (identity != null) {
      while (_cache.length >= 64 && _cache.isNotEmpty) {
        _cache.remove(_cache.keys.first);
      }
      _cache[path] = _AudioProbeCacheEntry(identity: identity, result: result);
    }
    return result;
  }

  static Future<PrimaryAudioProperties> _readAudioProperties(
    String path,
  ) async {
    try {
      final info = await FFmpegExecution.mediaInformation(path);
      if (info == null) return const PrimaryAudioProperties();
      for (final stream in info.getStreams()) {
        final props = stream.getAllProperties() ?? const <String, dynamic>{};
        if (props['codec_type']?.toString() != 'audio') continue;
        final codec = props['codec_name']?.toString().trim().toLowerCase();
        final bitDepth =
            int.tryParse(props['bits_per_raw_sample']?.toString() ?? '') ??
            int.tryParse(props['bits_per_sample']?.toString() ?? '');
        final sampleRate = int.tryParse(props['sample_rate']?.toString() ?? '');
        return PrimaryAudioProperties(
          codec: codec == null || codec.isEmpty ? null : codec,
          bitDepth: bitDepth != null && bitDepth > 0 ? bitDepth : null,
          sampleRate: sampleRate != null && sampleRate > 0 ? sampleRate : null,
        );
      }
    } catch (e) {
      _log.w('Audio property probe failed for $path: $e');
    }
    return const PrimaryAudioProperties();
  }

  static Future<bool> isNativeFlacFile(String path) async {
    try {
      final file = await File(path).open();
      try {
        final header = await file.read(4);
        return header.length == 4 &&
            header[0] == 0x66 &&
            header[1] == 0x4c &&
            header[2] == 0x61 &&
            header[3] == 0x43;
      } finally {
        await file.close();
      }
    } catch (e) {
      _log.w('Native FLAC magic probe failed for $path: $e');
      return false;
    }
  }
}
