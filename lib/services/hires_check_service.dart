import 'dart:io';

import 'package:mornye/services/platform_bridge.dart';
import 'package:mornye/services/network_audio_analysis_input.dart';

class HiResOriginalRestoreException implements Exception {
  const HiResOriginalRestoreException(this.backupPath, this.cause);

  final String backupPath;
  final FileSystemException cause;

  @override
  String toString() => 'Original audio retained at $backupPath: $cause';
}

/// Evidence from the Rust Hi-Res checker's sampled analysis.
class HiResCheckResult {
  final bool supported;
  final String verdict;
  final int declaredSampleRate;
  final double cutoffFrequencyHz;
  final double analyzedDurationSeconds;
  final double brickwallHz;
  final int declaredBitDepth;
  final int effectiveBitDepth;
  final bool paddedBitDepth;
  final String reason;

  /// For a fake: 'certain', 'likely' or 'suspect' (may be a genuine master
  /// low-pass filtered in mastering). Empty otherwise.
  final String confidence;

  /// 'sample_hold', 'linear_interpolation', 'imaging', or empty.
  final String upsamplingArtifact;

  /// Eligible to try a replacement. Full-file verification is still required.
  final bool redownloadSafe;

  /// Highest frequency whose level still moves with the music; 0 when not
  /// measured.
  final double musicCutoffHz;

  /// True when the content past [musicCutoffHz] is steady noise (a DSD or
  /// analog tape transfer), so [cutoffFrequencyHz] is where noise ends.
  final bool ultrasonicNoiseOnly;

  const HiResCheckResult({
    required this.supported,
    this.verdict = '',
    this.declaredSampleRate = 0,
    this.cutoffFrequencyHz = 0,
    this.analyzedDurationSeconds = 0,
    this.brickwallHz = 0,
    this.declaredBitDepth = 0,
    this.effectiveBitDepth = 0,
    this.paddedBitDepth = false,
    this.reason = '',
    this.confidence = '',
    this.upsamplingArtifact = '',
    this.redownloadSafe = false,
    this.musicCutoffHz = 0,
    this.ultrasonicNoiseOnly = false,
  });

  factory HiResCheckResult.fromJson(Map<String, dynamic> json) {
    return HiResCheckResult(
      supported: json['supported'] == true,
      verdict: json['verdict'] as String? ?? '',
      declaredSampleRate: (json['declared_sample_rate'] as num?)?.toInt() ?? 0,
      cutoffFrequencyHz: (json['cutoff_frequency_hz'] as num?)?.toDouble() ?? 0,
      analyzedDurationSeconds:
          (json['analyzed_duration_s'] as num?)?.toDouble() ?? 0,
      brickwallHz: (json['brickwall_hz'] as num?)?.toDouble() ?? 0,
      declaredBitDepth: (json['declared_bit_depth'] as num?)?.toInt() ?? 0,
      effectiveBitDepth: (json['effective_bit_depth'] as num?)?.toInt() ?? 0,
      paddedBitDepth: json['padded_bit_depth'] == true,
      reason: json['reason'] as String? ?? '',
      confidence: json['confidence'] as String? ?? '',
      upsamplingArtifact: json['upsampling_artifact'] as String? ?? '',
      redownloadSafe: json['redownload_safe'] == true,
      musicCutoffHz: (json['music_cutoff_hz'] as num?)?.toDouble() ?? 0,
      ultrasonicNoiseOnly: json['ultrasonic_noise_only'] == true,
    );
  }

  bool get isFake => verdict == 'fake_hires';

  bool get isCertain => isFake && confidence == 'certain';
  bool get isSuspect => isFake && confidence == 'suspect';

  /// Older backends called a limited spectrum "suspect". Neither that label
  /// nor the cutoff alone establishes that the file was upsampled.
  bool get hasLimitedBandwidth => verdict == 'band_limited' || isSuspect;
}

class HiResCheckService {
  /// The requested qualities that actually claim Hi-Res. A LOSSLESS request
  /// answered with CD-range audio is not a fake: it is what was asked for.
  static const hiResQualities = {'HI_RES', 'HI_RES_LOSSLESS'};

  /// Requested fallback tier. Its name does not guarantee audio equivalence.
  static const fakeHiResFallbackQuality = 'LOSSLESS';

  static bool isHiResQuality(String quality) =>
      hiResQualities.contains(quality.trim().toUpperCase());

  /// Runs the check; throws on failure. `supported == false` for formats
  /// the Rust checker cannot decode (anything but FLAC and PCM WAV).
  static Future<HiResCheckResult> check(
    String filePath, {
    NetworkAudioAnalysisInput? networkInput,
  }) async {
    if (NetworkAudioAnalysisInput.isNetwork(filePath)) {
      return (networkInput ?? NetworkAudioAnalysisInput()).withFile(
        filePath,
        (path) => check(path),
      );
    }
    final json = await PlatformBridge.checkHiResAuthenticity(filePath);
    final error = json['error'];
    if (error != null) throw StateError(error.toString());
    return HiResCheckResult.fromJson(json);
  }

  /// Every sample, channel and frame must match after removing only zero-bit
  /// padding or exact sample repetition. Missing/old backend support fails closed.
  static Future<bool> replacementPreservesAudio(
    String originalPath,
    String replacementPath,
  ) async {
    final result = await PlatformBridge.checkHiResAuthenticity(
      originalPath,
      options: {'verify_replacement_path': replacementPath},
    );
    return result['error'] == null && result['replacement_equivalent'] == true;
  }

  /// Keeps a unique backup on the same filesystem until [replaceAndFinalize]
  /// has validated, processed, published and persisted the replacement.
  /// False, cancellation or any exception restores the original atomically.
  static Future<bool> withOriginalBackup(
    String originalPath,
    Future<bool> Function(String backupPath) replaceAndFinalize,
  ) async {
    final original = File(originalPath);
    final directory = await original.parent.createTemp('.fake-hires-');
    final backup = File('${directory.path}/${original.uri.pathSegments.last}');
    var moved = false;
    var committed = false;
    try {
      await original.rename(backup.path);
      moved = true;
      committed = await replaceAndFinalize(backup.path);
      return committed;
    } finally {
      if (moved && !committed) {
        // If restoration fails, retain the backup and surface the error.
        try {
          await backup.rename(originalPath);
        } on FileSystemException catch (error) {
          throw HiResOriginalRestoreException(backup.path, error);
        }
      }
      // Cleanup failure must not roll back a successfully published file.
      try {
        await directory.delete(recursive: true);
      } on FileSystemException {
        // A leftover backup is preferable to losing the completed download.
      }
    }
  }
}
