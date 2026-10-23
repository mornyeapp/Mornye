import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:mornye/services/ffmpeg_models.dart';
import 'package:mornye/services/ffmpeg_replaygain.dart';
import 'package:mornye/services/music_player_service.dart';
import 'package:mornye/services/platform_bridge.dart';
import 'package:mornye/utils/file_access.dart';
import 'package:mornye/utils/logger.dart';

/// ReplayGain scanning and tag removal for existing audio files.
///
/// Computes EBU R128 loudness via FFmpeg and writes gain tags using the native
/// metadata editors where supported. Opus uses R128_* rather than legacy tags.
///
/// Handles SAF content:// URIs transparently by working on a temporary copy
/// and writing it back to the original document.
class ReplayGainService {
  ReplayGainService._();

  static final _log = AppLogger('ReplayGain');

  static const _nativeExtensions = <String>{
    '.flac',
    '.m4a',
    '.mp4',
    '.m4b',
    '.ape',
    '.wv',
    '.mpc',
    '.wav',
    '.aiff',
    '.aif',
    '.aifc',
    '.mp3',
    '.opus',
    '.ogg',
  };

  static bool _isNativeWritableFormat(String path) {
    final lower = path.toLowerCase();
    return _nativeExtensions.any(lower.endsWith);
  }

  /// Scans [filePath] for loudness and writes track ReplayGain tags in place.
  ///
  /// Returns `true` when tags were successfully written, `false` otherwise
  /// (scan failed, write failed, or SAF write-back failed).
  static Future<bool> applyToFile(
    String filePath, {
    @visibleForTesting Future<ReplayGainResult?> Function(String)? scan,
    void Function()? onUnsupportedDecoder,
  }) async =>
      await scanAndApplyToFile(
        filePath,
        scan: scan,
        onUnsupportedDecoder: onUnsupportedDecoder,
      ) !=
      null;

  /// Returns the scan for album aggregation only after a verified save.
  static Future<ReplayGainResult?> scanAndApplyToFile(
    String filePath, {
    @visibleForTesting Future<ReplayGainResult?> Function(String)? scan,
    void Function()? onUnsupportedDecoder,
  }) async {
    ReplayGainResult? scanned;
    final written = await _updateFile(filePath, (workingPath) async {
      final rg = scan != null
          ? await scan(workingPath)
          : await FFmpegReplayGain.scan(
              workingPath,
              onUnsupportedDecoder: onUnsupportedDecoder,
            );
      if (rg == null) {
        _log.w('ReplayGain scan returned no result for $workingPath');
        return false;
      }
      scanned = rg;
      return _writeLocalTags(
        workingPath,
        rg.trackGain,
        rg.trackPeak,
        album: false,
      );
    });
    return written ? scanned : null;
  }

  static Future<bool> writeTrackTags(
    String filePath,
    String gain,
    String peak,
  ) => _updateFile(
    filePath,
    (path) => _writeLocalTags(path, gain, peak, album: false),
  );

  static Future<bool> writeAlbumTags(
    String filePath,
    String gain,
    String peak,
  ) => _updateFile(
    filePath,
    (path) => _writeLocalTags(path, gain, peak, album: true),
  );

  /// Removes track/album tags, including Opus R128 and M4A Sound Check tags.
  /// Native editors copy the audio payload unchanged and publish atomically.
  static Future<bool> removeFromFile(String filePath) =>
      _updateFile(filePath, (path) async {
        if (!_isNativeWritableFormat(path)) return false;
        const fields = {
          'replaygain_track_gain': '',
          'replaygain_track_peak': '',
          'replaygain_album_gain': '',
          'replaygain_album_peak': '',
        };
        final result = await PlatformBridge.editFileMetadata(path, fields);
        final method = result['method'];
        if (result['success'] != true ||
            result['error'] != null ||
            method is! String ||
            !(method == 'native' || method.startsWith('native_'))) {
          return false;
        }
        final metadata = await PlatformBridge.readFileMetadata(path);
        return metadata['error'] == null &&
            metadata['audio_codec'] != null &&
            fields.keys.every(
              (key) => (metadata[key]?.toString() ?? '').trim().isEmpty,
            );
      });

  static Future<bool> _writeLocalTags(
    String path,
    String gain,
    String peak, {
    required bool album,
  }) async {
    final scope = album ? 'album' : 'track';
    var written = false;
    if (_isNativeWritableFormat(path)) {
      final result = await PlatformBridge.editFileMetadata(path, {
        'replaygain_${scope}_gain': gain,
        'replaygain_${scope}_peak': peak,
      });
      written =
          result['success'] == true &&
          result['error'] == null &&
          result['method'] is String &&
          (result['method'] == 'native' ||
              (result['method'] as String).startsWith('native_'));
      if (!written) {
        _log.w('Native $scope ReplayGain write did not complete: $result');
      }
    }

    if (!written) {
      // Remuxing all streams rejects attached Opus artwork; mapping only audio
      // would discard it. Keep the original if its native editor cannot handle
      // the file, rather than silently losing artwork or reporting a no-op.
      final lower = path.toLowerCase();
      if (lower.endsWith('.opus') || lower.endsWith('.ogg')) return false;
      written = album
          ? await FFmpegReplayGain.writeAlbumTags(path, gain, peak)
          : await FFmpegReplayGain.writeTrackTags(path, gain, peak);
    }
    if (!written) return false;

    final metadata = await PlatformBridge.readFileMetadata(path);
    final expectedGain = _gainDb(gain);
    final actualGain = _gainDb(metadata['replaygain_${scope}_gain']);
    final expectedPeak = double.tryParse(peak);
    final actualPeak = double.tryParse(
      metadata['replaygain_${scope}_peak']?.toString() ?? '',
    );
    final isOpus = metadata['audio_codec'] == 'opus';
    final verified =
        metadata['error'] == null &&
        expectedGain != null &&
        actualGain != null &&
        (actualGain - expectedGain).abs() <= 0.01 &&
        (isOpus ||
            (expectedPeak != null &&
                actualPeak != null &&
                (actualPeak - expectedPeak).abs() <= 0.000001));
    if (!verified) {
      _log.w('$scope ReplayGain verification failed after writing $path');
      return false;
    }
    return true;
  }

  static double? _gainDb(Object? value) => double.tryParse(
    (value?.toString() ?? '').replaceFirst(RegExp(r'\s*dB\s*$'), '').trim(),
  );

  static Future<bool> _updateFile(
    String filePath,
    Future<bool> Function(String) update,
  ) async {
    if (filePath.isEmpty) return false;

    final isSaf = isContentUri(filePath);
    var workingPath = filePath;
    String? safTempPath;

    try {
      if (isSaf) {
        safTempPath = await PlatformBridge.copyContentUriToTemp(filePath);
        if (safTempPath == null || safTempPath.isEmpty) {
          _log.w('Failed to copy SAF file to temp for ReplayGain update');
          return false;
        }
        workingPath = safTempPath;
      }

      if (!await update(workingPath)) return false;

      if (isSaf) {
        final ok = await PlatformBridge.writeTempToSaf(workingPath, filePath);
        if (!ok) {
          _log.w('Failed to write ReplayGain temp file back to SAF document');
          return false;
        }
      }

      refreshPlaybackNormalization(filePath);
      _log.i('ReplayGain tags updated and verified: $filePath');
      return true;
    } catch (e) {
      _log.e('Failed to update ReplayGain', e);
      return false;
    } finally {
      if (safTempPath != null) {
        try {
          await File(safTempPath).delete();
        } catch (_) {}
      }
    }
  }
}
