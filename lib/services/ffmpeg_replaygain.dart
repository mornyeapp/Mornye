import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:mornye/services/ffmpeg_models.dart';
import 'package:mornye/services/ffmpeg_support.dart';
import 'package:mornye/utils/logger.dart';

final _log = AppLogger('FFmpeg');

/// EBU R128 measurement and non-Ogg ReplayGain stream-copy tagging.
abstract final class FFmpegReplayGain {
  static Future<ReplayGainResult?> scan(
    String filePath, {
    void Function()? onUnsupportedDecoder,
  }) async {
    _log.d(
      'Scanning ReplayGain for: ${filePath.split(Platform.pathSeparator).last}',
    );
    // Suppress per-frame measurements and retain the final ebur128 summary.
    final result = await FFmpegExecution.arguments([
      '-hide_banner',
      '-nostats',
      '-loglevel',
      'info',
      '-i',
      filePath,
      '-map',
      '0:a:0',
      '-vn',
      '-sn',
      '-dn',
      '-af',
      'ebur128=peak=true:framelog=quiet',
      '-f',
      'null',
      '-',
    ]);
    return parseScan(result, onUnsupportedDecoder: onUnsupportedDecoder);
  }

  @visibleForTesting
  static ReplayGainResult? parseScan(
    FFmpegResult result, {
    void Function()? onUnsupportedDecoder,
  }) {
    final output = result.output;
    if (!result.success) {
      final decoderMissing = RegExp(
        r'decoder.*not found|no decoder found|unknown decoder',
        caseSensitive: false,
      );
      final diagnostic = output
          .split('\n')
          .where(
            (line) =>
                decoderMissing.hasMatch(line) ||
                RegExp(
                  r'error|invalid|failed',
                  caseSensitive: false,
                ).hasMatch(line),
          )
          .take(3)
          .join(' ')
          .trim();
      _log.w(
        'ReplayGain scan failed (exit ${result.returnCode}): ${diagnostic.isEmpty ? "no decoder diagnostics" : diagnostic.substring(0, math.min(diagnostic.length, 500))}',
      );
      if (decoderMissing.hasMatch(output)) onUnsupportedDecoder?.call();
      // A failed decoder can print a partial/default summary, not a measurement
      // of the complete track.
      return null;
    }

    final integratedMatch = RegExp(
      r'I:\s+(-?\d+\.?\d*)\s+LUFS',
    ).allMatches(output);
    if (integratedMatch.isEmpty) {
      _log.w('ReplayGain scan: could not parse integrated loudness');
      return null;
    }
    // The final match is the summary, rather than a per-segment measurement.
    final integratedLufs = double.tryParse(integratedMatch.last.group(1) ?? '');
    if (integratedLufs == null) {
      _log.w('ReplayGain scan: invalid integrated loudness value');
      return null;
    }

    // Use the maximum true peak across channels, converting dBFS to a ratio.
    double? truePeakDbfs;
    for (final match in RegExp(
      r'Peak:\s+(-?\d+\.?\d*)\s+dBFS',
    ).allMatches(output)) {
      final value = double.tryParse(match.group(1) ?? '');
      if (value != null && (truePeakDbfs == null || value > truePeakDbfs)) {
        truePeakDbfs = value;
      }
    }
    final gainDb = -18.0 - integratedLufs;
    final peakLinear = truePeakDbfs == null
        ? 1.0
        : math.pow(10, truePeakDbfs / 20.0).toDouble();
    final trackGain =
        '${gainDb >= 0 ? "+" : ""}${gainDb.toStringAsFixed(2)} dB';
    final trackPeak = peakLinear.toStringAsFixed(6);
    _log.i(
      'ReplayGain scan result: gain=$trackGain, peak=$trackPeak (integrated=${integratedLufs.toStringAsFixed(1)} LUFS)',
    );
    return ReplayGainResult(
      trackGain: trackGain,
      trackPeak: trackPeak,
      integratedLufs: integratedLufs,
      truePeakLinear: peakLinear,
    );
  }

  static Future<bool> writeAlbumTags(
    String filePath,
    String gain,
    String peak, {
    bool returnTempPath = false,
    void Function(String tempPath)? onTempReady,
  }) => _writeTags(
    filePath,
    'Album',
    gain,
    peak,
    returnTempPath: returnTempPath,
    onTempReady: onTempReady,
  );

  static Future<bool> writeTrackTags(
    String filePath,
    String gain,
    String peak,
  ) => _writeTags(filePath, 'Track', gain, peak);

  static Future<bool> _writeTags(
    String filePath,
    String scope,
    String gain,
    String peak, {
    bool returnTempPath = false,
    void Function(String tempPath)? onTempReady,
  }) async {
    final ext = filePath.contains('.')
        ? '.${filePath.split('.').last}'
        : '.tmp';
    if (ext.toLowerCase() == '.opus' || ext.toLowerCase() == '.ogg') {
      _log.e('Ogg/Opus ReplayGain requires the native tag writer');
      return false;
    }
    final tempOutput = await FFmpegOutput.tempPath(ext);
    final tag = scope.toUpperCase();
    _log.d('Writing ${scope.toLowerCase()} ReplayGain tags via FFmpeg');
    final result = await FFmpegExecution.arguments([
      '-v',
      'error',
      '-hide_banner',
      '-i',
      filePath,
      '-map',
      '0',
      '-c',
      'copy',
      '-map_metadata',
      '0',
      '-metadata',
      'REPLAYGAIN_${tag}_GAIN=$gain',
      '-metadata',
      'REPLAYGAIN_${tag}_PEAK=$peak',
      tempOutput,
      '-y',
    ]);
    if (!result.success) {
      _log.e(
        '$scope ReplayGain write failed (code ${result.returnCode}): ${result.output}',
      );
    } else if (returnTempPath) {
      try {
        if (await File(tempOutput).exists()) {
          onTempReady?.call(tempOutput);
          return true;
        }
      } catch (e) {
        _log.w(
          'Failed to replace file with ${scope.toLowerCase()} ReplayGain: $e',
        );
      }
    } else if (await FFmpegOutput.promote(
      tempOutput,
      filePath,
      onError: (e) => _log.w(
        'Failed to replace file with ${scope.toLowerCase()} ReplayGain: $e',
      ),
    )) {
      _log.d('$scope ReplayGain tags written successfully');
      return true;
    }
    await FFmpegOutput.cleanup(tempOutput);
    return false;
  }
}
