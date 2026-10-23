import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:mornye/services/audio_metadata_mapper.dart';
import 'package:mornye/services/ffmpeg_metadata.dart';
import 'package:mornye/services/ffmpeg_models.dart';
import 'package:mornye/services/ffmpeg_probe.dart';
import 'package:mornye/services/ffmpeg_support.dart';
import 'package:mornye/utils/artist_utils.dart';
import 'package:mornye/utils/audio_conversion_utils.dart';
import 'package:mornye/utils/logger.dart';

final _log = AppLogger('FFmpeg');

class _ResolvedLosslessQuality {
  final int? targetBitDepth;
  final int? targetSampleRate;

  const _ResolvedLosslessQuality({this.targetBitDepth, this.targetSampleRate});
}

/// Encoding and track splitting depend on inspection, tagging and output
/// publication directly, without routing through the compatibility facade.
abstract final class FFmpegConversion {
  static Future<_ResolvedLosslessQuality> _resolveLosslessQuality({
    required String inputPath,
    required LosslessConversionQuality quality,
    int? sourceBitDepth,
  }) async {
    final needsDepth = sourceBitDepth == null && quality.maxBitDepth != null;
    final needsRate = quality.maxSampleRate != null;
    final probe = needsDepth || needsRate
        ? await FFmpegProbe.audioProperties(inputPath)
        : const PrimaryAudioProperties();
    final depth = sourceBitDepth ?? probe.bitDepth;
    final rate = needsRate ? probe.sampleRate : null;
    return _ResolvedLosslessQuality(
      targetBitDepth:
          quality.maxBitDepth != null &&
              (depth == null || depth > quality.maxBitDepth!)
          ? quality.maxBitDepth
          : null,
      targetSampleRate:
          quality.maxSampleRate != null &&
              (rate == null || rate > quality.maxSampleRate!)
          ? quality.maxSampleRate
          : null,
    );
  }

  static String? _sampleFormat(String codec, int? bitDepth) {
    if (bitDepth == null || bitDepth <= 0) return null;
    return switch (codec) {
      'flac' || 'pcm' => bitDepth <= 16 ? 's16' : 's32',
      'alac' => bitDepth <= 16 ? 's16p' : 's32p',
      _ => null,
    };
  }

  static void _appendResampleFilter(
    List<String> arguments, {
    int? targetSampleRate,
    String? outputSampleFormat,
    required LosslessConversionProcessing processing,
  }) {
    final hasRate = targetSampleRate != null && targetSampleRate > 0;
    final hasFormat =
        outputSampleFormat != null && outputSampleFormat.trim().isNotEmpty;
    if (!hasRate && !hasFormat && !processing.hasDither) return;
    final options = <String>[
      ...losslessResamplerFilterOptions(processing),
      if (hasRate) 'osr=$targetSampleRate',
      if (hasFormat) 'osf=${outputSampleFormat.trim()}',
      if (processing.hasDither) 'dither_method=${processing.normalizedDither}',
    ];
    arguments.addAll(['-af', 'aresample=${options.join(':')}']);
  }

  static void _appendLosslessQuality(
    List<String> arguments, {
    required String codec,
    int? targetBitDepth,
    int? targetSampleRate,
    required LosslessConversionProcessing processing,
  }) {
    _appendResampleFilter(
      arguments,
      targetSampleRate: targetSampleRate,
      outputSampleFormat: _sampleFormat(codec, targetBitDepth),
      processing: processing,
    );
    if (targetBitDepth == null || targetBitDepth <= 0) return;
    if (codec == 'flac' || codec == 'alac') {
      final planar = codec == 'alac' ? 'p' : '';
      if (targetBitDepth <= 16) {
        arguments.addAll(['-sample_fmt', 's16$planar']);
      } else if (targetBitDepth <= 24) {
        arguments.addAll([
          '-sample_fmt',
          's32$planar',
          '-bits_per_raw_sample',
          '24',
        ]);
      }
    }
  }

  static Future<String?> convertM4aToFlac(
    String inputPath, {
    String? sourceCodec,
    @visibleForTesting Future<FFmpegResult> Function(List<String>)? execute,
  }) async {
    final plan = await FFmpegOutput.plan(
      inputPath,
      '.flac',
      deleteOriginal: true,
    );
    try {
      final run = execute ?? FFmpegExecution.arguments;
      final codec = sourceCodec ?? await FFmpegProbe.audioCodec(inputPath);
      if (codec?.trim().toLowerCase() == 'flac') {
        final remux = await run([
          '-v',
          'error',
          '-xerror',
          '-i',
          inputPath,
          '-c:a',
          'copy',
          '-f',
          'flac',
          plan.workingPath,
          '-y',
        ]);
        final output = File(plan.workingPath);
        if (remux.success &&
            await output.exists() &&
            await output.length() > 42 &&
            await FFmpegProbe.isNativeFlacFile(plan.workingPath)) {
          final validation = await run([
            '-v',
            'error',
            '-xerror',
            '-err_detect',
            'crccheck+explode',
            '-i',
            plan.workingPath,
            '-map',
            '0:a:0',
            '-f',
            'null',
            '-',
          ]);
          if (validation.success) {
            return await FFmpegOutput.finalize(
              plan: plan,
              inputPath: inputPath,
              deleteOriginal: true,
            );
          }
        }
        _log.w('FLAC remux validation failed; retrying with the encoder');
      }
      final result = await run([
        '-v',
        'error',
        '-xerror',
        '-i',
        inputPath,
        '-c:a',
        'flac',
        '-compression_level',
        '8',
        plan.workingPath,
        '-y',
      ]);
      if (result.success) {
        return await FFmpegOutput.finalize(
          plan: plan,
          inputPath: inputPath,
          deleteOriginal: true,
        );
      }
      _log.e('M4A to FLAC conversion failed: ${result.output}');
    } catch (e) {
      _log.e('M4A to FLAC conversion failed: $e');
    }
    await FFmpegOutput.cleanup(plan.workingPath);
    return null;
  }

  static Future<String> ensureNativeFlacExtension(String inputPath) async {
    if (inputPath.toLowerCase().endsWith('.flac')) return inputPath;
    final plan = await FFmpegOutput.plan(
      inputPath,
      '.flac',
      deleteOriginal: true,
    );
    try {
      await File(inputPath).rename(plan.finalPath);
      FFmpegProbe.invalidate(inputPath);
      FFmpegProbe.invalidate(plan.finalPath);
      return plan.finalPath;
    } catch (_) {
      await FFmpegOutput.cleanup(plan.workingPath);
      rethrow;
    }
  }

  /// Converts audio while preserving requested metadata and cover art. Lossless
  /// quality caps only reduce source quality; known depth avoids an extra probe.
  static Future<String?> convertAudioFormat({
    required String inputPath,
    required String targetFormat,
    required String bitrate,
    required Map<String, String> metadata,
    String? coverPath,
    String artistTagMode = artistTagModeJoined,
    bool deleteOriginal = true,
    int? sourceBitDepth,
    LosslessConversionQuality losslessQuality =
        const LosslessConversionQuality(),
    LosslessConversionProcessing losslessProcessing =
        const LosslessConversionProcessing(),
  }) async {
    final format = targetFormat.toLowerCase();
    if (!const {
      'mp3',
      'opus',
      'aac',
      'alac',
      'flac',
      'wav',
      'aiff',
      'aif',
    }.contains(format)) {
      _log.e('Unsupported target format: $targetFormat');
      return null;
    }
    // Existing credits must not lose names; downloads embed provider credits
    // after auto-conversion applies this preservation policy.
    artistTagMode = artistTagModeForExistingTags(artistTagMode);
    final quality = isLosslessConversionTarget(format)
        ? await _resolveLosslessQuality(
            inputPath: inputPath,
            quality: losslessQuality,
            sourceBitDepth: sourceBitDepth,
          )
        : const _ResolvedLosslessQuality();
    if (format == 'alac' || format == 'flac') {
      return _convertToLossless(
        inputPath: inputPath,
        metadata: metadata,
        codec: format,
        coverPath: coverPath,
        artistTagMode: artistTagMode,
        targetBitDepth: quality.targetBitDepth,
        targetSampleRate: quality.targetSampleRate,
        processing: losslessProcessing,
        deleteOriginal: deleteOriginal,
      );
    }
    if (format == 'wav' || format == 'aiff' || format == 'aif') {
      return _convertToPcm(
        inputPath: inputPath,
        metadata: metadata,
        coverPath: coverPath,
        container: format == 'wav' ? 'wav' : 'aiff',
        sourceBitDepth: sourceBitDepth,
        targetBitDepth: quality.targetBitDepth,
        targetSampleRate: quality.targetSampleRate,
        processing: losslessProcessing,
        deleteOriginal: deleteOriginal,
      );
    }
    final extension = switch (format) {
      'opus' => '.opus',
      'aac' => '.m4a',
      _ => '.mp3',
    };
    final plan = await FFmpegOutput.plan(
      inputPath,
      extension,
      deleteOriginal: deleteOriginal,
    );
    final outputPath = plan.workingPath;
    final arguments = <String>[
      '-v',
      'error',
      '-hide_banner',
      '-i',
      inputPath,
      '-codec:a',
      switch (format) {
        'opus' => 'libopus',
        'aac' => 'aac',
        _ => 'libmp3lame',
      },
      '-b:a',
      bitrate,
      if (format == 'opus') ...['-vbr', 'on', '-compression_level', '10'],
      '-map',
      '0:a',
      if (format == 'aac') ...['-f', 'mp4'],
      if (format == 'mp3') ...['-id3v2_version', '3'],
      outputPath,
      '-y',
    ];
    _log.i(
      'Converting ${inputPath.split(Platform.pathSeparator).last} to $format @ $bitrate',
    );
    final result = await FFmpegExecution.arguments(arguments);
    if (!result.success) {
      _log.e('Audio conversion failed: ${result.output}');
      await FFmpegOutput.cleanup(outputPath);
      return null;
    }
    final hasMetadata = metadata.values.any((v) => v.trim().isNotEmpty);
    final hasCover = coverPath != null && coverPath.trim().isNotEmpty;
    if (hasMetadata || hasCover) {
      final embedded = switch (format) {
        'mp3' => await FFmpegMetadata.embedMetadataToMp3(
          mp3Path: outputPath,
          coverPath: coverPath,
          metadata: metadata,
          artistTagMode: artistTagMode,
        ),
        'aac' => await FFmpegMetadata.embedMetadataToM4a(
          m4aPath: outputPath,
          coverPath: coverPath,
          metadata: metadata,
          artistTagMode: artistTagMode,
          preserveMetadata: true,
        ),
        _ => await FFmpegMetadata.embedMetadataToOpus(
          opusPath: outputPath,
          coverPath: coverPath,
          metadata: metadata,
          artistTagMode: artistTagMode,
        ),
      };
      if (embedded == null) {
        _log.e(
          'Metadata/Cover preservation failed, rolling back converted file',
        );
        await FFmpegOutput.cleanup(outputPath);
        return null;
      }
    }
    return FFmpegOutput.finalize(
      plan: plan,
      inputPath: inputPath,
      deleteOriginal: deleteOriginal,
    );
  }

  static Future<String?> _convertToLossless({
    required String inputPath,
    required Map<String, String> metadata,
    required String codec,
    String? coverPath,
    required String artistTagMode,
    int? targetBitDepth,
    int? targetSampleRate,
    required LosslessConversionProcessing processing,
    required bool deleteOriginal,
  }) async {
    final isAlac = codec == 'alac';
    final plan = await FFmpegOutput.plan(
      inputPath,
      isAlac ? '.m4a' : '.flac',
      deleteOriginal: deleteOriginal,
    );
    final outputPath = plan.workingPath;
    final arguments = <String>['-v', 'error', '-hide_banner', '-i', inputPath];
    final hasCover =
        coverPath != null &&
        coverPath.trim().isNotEmpty &&
        await File(coverPath).exists();
    if (hasCover) arguments.addAll(['-i', coverPath]);
    arguments.addAll(['-map', '0:a']);
    if (hasCover) FFmpegMetadata.appendCoverInputArguments(arguments);
    arguments.addAll(['-c:a', codec]);
    if (!isAlac) arguments.addAll(['-compression_level', '8']);
    _appendLosslessQuality(
      arguments,
      codec: codec,
      targetBitDepth: targetBitDepth,
      targetSampleRate: targetSampleRate,
      processing: processing,
    );
    arguments.addAll(['-map_metadata', isAlac ? '-1' : '0']);
    if (isAlac) {
      AudioMetadataMapper.appendMappedMetadataArguments(
        arguments,
        AudioMetadataMapper.convertToM4aTags(metadata),
      );
    } else {
      AudioMetadataMapper.appendVorbisMetadataArguments(
        arguments,
        metadata,
        artistTagMode: artistTagMode,
      );
    }
    arguments.addAll([outputPath, '-y']);
    final label = isAlac ? 'ALAC' : 'FLAC';
    _log.i(
      'Converting ${inputPath.split(Platform.pathSeparator).last} to $label'
      '${targetBitDepth != null ? ' $targetBitDepth-bit' : ''}'
      '${targetSampleRate != null ? ' @ ${targetSampleRate}Hz' : ''}'
      '${processing.hasDither ? ' dither=${processing.normalizedDither}' : ''}'
      '${processing.normalizedResampler != 'swr' ? ' resampler=${processing.normalizedResampler}' : ''}',
    );
    final result = await FFmpegExecution.arguments(arguments);
    if (!result.success) {
      _log.e('$label conversion failed: ${result.output}');
      await FFmpegOutput.cleanup(outputPath);
      return null;
    }
    if (isAlac) {
      await FFmpegMetadata.writeM4AFreeformTags(outputPath, metadata);
      if (!await FFmpegMetadata.writeM4AReleaseIdentityTags(
        outputPath,
        metadata,
      )) {
        _log.e('ALAC release identity metadata write failed');
        await FFmpegOutput.cleanup(outputPath);
        return null;
      }
    }
    return FFmpegOutput.finalize(
      plan: plan,
      inputPath: inputPath,
      deleteOriginal: deleteOriginal,
    );
  }

  static Future<String?> _convertToPcm({
    required String inputPath,
    required Map<String, String> metadata,
    required String container,
    String? coverPath,
    int? sourceBitDepth,
    int? targetBitDepth,
    int? targetSampleRate,
    required LosslessConversionProcessing processing,
    required bool deleteOriginal,
  }) async {
    final isAiff = container == 'aiff';
    final plan = await FFmpegOutput.plan(
      inputPath,
      isAiff ? '.aiff' : '.wav',
      deleteOriginal: deleteOriginal,
    );
    final outputPath = plan.workingPath;
    var depth = targetBitDepth ?? sourceBitDepth;
    if (depth == null || depth <= 0) {
      depth = (await FFmpegProbe.audioProperties(inputPath)).bitDepth;
    }
    final use24 = depth != null && depth >= 24;
    final codec = isAiff
        ? (use24 ? 'pcm_s24be' : 'pcm_s16be')
        : (use24 ? 'pcm_s24le' : 'pcm_s16le');
    final arguments = <String>[
      '-v',
      'error',
      '-hide_banner',
      '-i',
      inputPath,
      '-map',
      '0:a',
    ];
    _appendResampleFilter(
      arguments,
      targetSampleRate: targetSampleRate,
      outputSampleFormat: _sampleFormat('pcm', targetBitDepth),
      processing: processing,
    );
    arguments.addAll(['-c:a', codec, '-map_metadata', '-1']);
    // Container-native common tags supplement the authoritative native ID3
    // chunks, which also hold totals, lyrics, ReplayGain and artwork.
    AudioMetadataMapper.appendMappedMetadataArguments(
      arguments,
      AudioMetadataMapper.convertToId3Tags(metadata),
    );
    arguments.addAll([outputPath, '-y']);
    _log.i(
      'Converting ${inputPath.split(Platform.pathSeparator).last} to '
      '${container.toUpperCase()} (${use24 ? 24 : 16}-bit'
      '${targetSampleRate != null ? ', ${targetSampleRate}Hz' : ''}'
      '${processing.hasDither ? ', dither=${processing.normalizedDither}' : ''}'
      '${processing.normalizedResampler != 'swr' ? ', resampler=${processing.normalizedResampler}' : ''})',
    );
    final result = await FFmpegExecution.arguments(arguments);
    if (!result.success) {
      _log.e('${container.toUpperCase()} conversion failed: ${result.output}');
      await FFmpegOutput.cleanup(outputPath);
      return null;
    }
    final hasMetadata = metadata.values.any((v) => v.trim().isNotEmpty);
    final hasCover = coverPath != null && coverPath.trim().isNotEmpty;
    if ((hasMetadata || hasCover) &&
        !await FFmpegMetadata.embedChunkTagsNative(
          outputPath,
          metadata,
          coverPath,
        )) {
      _log.e('Native tag embed failed for $container output');
      await FFmpegOutput.cleanup(outputPath);
      return null;
    }
    return FFmpegOutput.finalize(
      plan: plan,
      inputPath: inputPath,
      deleteOriginal: deleteOriginal,
    );
  }

  static Future<List<String>?> splitCueToTracks({
    required String audioPath,
    required String outputDir,
    required List<CueSplitTrackInfo> tracks,
    required Map<String, String> albumMetadata,
    String? coverPath,
    void Function(int current, int total)? onProgress,
  }) async {
    if (tracks.isEmpty) {
      _log.e('No tracks to split');
      return null;
    }
    final outputPaths = <String>[];
    final inputExt = audioPath.toLowerCase().split('.').last;
    final outputExt = const {'flac', 'wav', 'ape', 'wv'}.contains(inputExt)
        ? 'flac'
        : inputExt;
    for (var i = 0; i < tracks.length; i++) {
      final track = tracks[i];
      onProgress?.call(i + 1, tracks.length);
      final title = track.title
          .replaceAll(RegExp(r'[<>:"/\\|?*]'), '_')
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
      final outputName =
          '${track.number.toString().padLeft(2, '0')} - $title.$outputExt';
      final outputPath = '$outputDir${Platform.pathSeparator}$outputName';
      final arguments = <String>[
        '-v',
        'error',
        '-hide_banner',
        '-i',
        audioPath,
        '-ss',
        _formatSeconds(track.startSec),
      ];
      if (track.endSec > 0) {
        arguments.addAll(['-to', _formatSeconds(track.endSec)]);
      }
      arguments.addAll(
        outputExt == 'flac'
            ? ['-c:a', 'flac', '-compression_level', '8']
            : ['-c:a', 'copy'],
      );
      final metadata = <String, String>{
        'TITLE': track.title,
        'ARTIST': track.artist.isNotEmpty
            ? track.artist
            : (albumMetadata['artist'] ?? ''),
        'ALBUM': albumMetadata['album'] ?? '',
        'ALBUMARTIST': albumMetadata['artist'] ?? '',
        'TRACKNUMBER': track.number.toString(),
        'GENRE': albumMetadata['genre'] ?? '',
        'DATE': albumMetadata['date'] ?? '',
        'ISRC': track.isrc,
        'COMPOSER': track.composer,
      }..removeWhere((_, value) => value.isEmpty);
      AudioMetadataMapper.appendMappedMetadataArguments(arguments, metadata);
      arguments.addAll([outputPath, '-y']);
      _log.d('CUE split track ${track.number}');
      final result = await FFmpegExecution.arguments(arguments);
      if (!result.success) {
        _log.e('CUE split failed for track ${track.number}: ${result.output}');
        continue;
      }
      outputPaths.add(outputPath);
      FFmpegProbe.invalidate(outputPath);
      _log.i('CUE split: track ${track.number} -> $outputName');
    }
    if (outputPaths.isEmpty) {
      _log.e('CUE split: no tracks were successfully extracted');
      return null;
    }
    _log.i('CUE split complete: ${outputPaths.length}/${tracks.length} tracks');
    return outputPaths;
  }

  static String _formatSeconds(double seconds) {
    if (seconds < 0) return '0';
    final hours = seconds ~/ 3600;
    final minutes = (seconds % 3600) ~/ 60;
    final secs = seconds - hours * 3600 - minutes * 60;
    return '${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}:${secs.toStringAsFixed(3).padLeft(6, '0')}';
  }
}
