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

/// What reading the whole file found, section by section. The status words
/// are the Rust checker's; see its `Report`.
class HiResReport {
  /// 'corrupt', 'lossy', 'upscaled', 'suspect', 'limited', 'clean' or
  /// 'inconclusive'.
  final String grade;

  /// 'verified', 'unverified', 'checksum_mismatch', 'length_mismatch' or
  /// 'decode_error'.
  final String integrityStatus;
  final String storedMd5;
  final String computedMd5;
  final int declaredFrames;
  final int decodedFrames;

  /// 'full', 'padded', 'coarse', 'near_16bit', 'float' or 'unmeasured'.
  final String bitDepthStatus;

  /// Resolution the spacing of the quiet samples shows; 0 when not measured.
  final double resolutionBits;

  /// Where the spectrum steps down and stays down; 0 when it does not.
  final double lowpassHz;
  final double lowpassDropDb;

  /// 'none', 'format', 'source_rate', 'high', 'medium' or 'low'.
  final String lowpassClass;

  /// 'found', 'suspected', 'not_found' or 'not_checked'.
  final String lossyStatus;

  /// 'aac', 'vorbis', 'mp3', or empty when no frame pattern showed.
  final String lossyFamily;
  final int lossyFrameSamples;
  final double lossyScore;
  final double lossyRatio;

  /// The score from which a pattern of the kind measured counts as found.
  final double lossyFoundScore;

  /// That score for AAC and Vorbis (the Rust checker's `GRID_SCORE`), which
  /// a report without its own figure is read with.
  static const double _longTransformFoundScore = 12;

  /// The average spectrum in dB below its peak, [spectrumStepHz] apart.
  final double spectrumStepHz;
  final List<double> spectrumDb;

  const HiResReport({
    this.grade = '',
    this.integrityStatus = '',
    this.storedMd5 = '',
    this.computedMd5 = '',
    this.declaredFrames = 0,
    this.decodedFrames = 0,
    this.bitDepthStatus = '',
    this.resolutionBits = 0,
    this.lowpassHz = 0,
    this.lowpassDropDb = 0,
    this.lowpassClass = 'none',
    this.lossyStatus = '',
    this.lossyFamily = '',
    this.lossyFrameSamples = 0,
    this.lossyScore = 0,
    this.lossyRatio = 0,
    this.lossyFoundScore = _longTransformFoundScore,
    this.spectrumStepHz = 0,
    this.spectrumDb = const [],
  });

  factory HiResReport.fromJson(Map<String, dynamic> json) {
    Map<String, dynamic> section(String key) =>
        (json[key] as Map?)?.cast<String, dynamic>() ?? const {};
    final integrity = section('integrity');
    final bitDepth = section('bit_depth');
    final bandwidth = section('bandwidth');
    final lossy = section('lossy');
    final spectrum = section('spectrum');
    return HiResReport(
      grade: json['grade'] as String? ?? '',
      integrityStatus: integrity['status'] as String? ?? '',
      storedMd5: integrity['stored_md5'] as String? ?? '',
      computedMd5: integrity['computed_md5'] as String? ?? '',
      declaredFrames: (integrity['declared_frames'] as num?)?.toInt() ?? 0,
      decodedFrames: (integrity['decoded_frames'] as num?)?.toInt() ?? 0,
      bitDepthStatus: bitDepth['status'] as String? ?? '',
      resolutionBits: (bitDepth['resolution_bits'] as num?)?.toDouble() ?? 0,
      lowpassHz: (bandwidth['lowpass_hz'] as num?)?.toDouble() ?? 0,
      lowpassDropDb: (bandwidth['lowpass_drop_db'] as num?)?.toDouble() ?? 0,
      lowpassClass: bandwidth['lowpass_class'] as String? ?? 'none',
      lossyStatus: lossy['status'] as String? ?? '',
      lossyFamily: lossy['family'] as String? ?? '',
      lossyFrameSamples: (lossy['frame_samples'] as num?)?.toInt() ?? 0,
      lossyScore: (lossy['score'] as num?)?.toDouble() ?? 0,
      lossyRatio: (lossy['ratio'] as num?)?.toDouble() ?? 0,
      lossyFoundScore: switch ((lossy['found_score'] as num?)?.toDouble()) {
        final score? when score > 0 => score,
        _ => _longTransformFoundScore,
      },
      spectrumStepHz: (spectrum['step_hz'] as num?)?.toDouble() ?? 0,
      spectrumDb: [
        for (final value in spectrum['db'] as List? ?? const [])
          (value as num).toDouble(),
      ],
    );
  }
}

/// Evidence from the Rust Hi-Res checker: of a sample from the middle of
/// the file, or with a [report] of all of it.
class HiResCheckResult {
  final bool supported;
  final String verdict;
  final int declaredSampleRate;
  final double cutoffFrequencyHz;
  final double analyzedDurationSeconds;
  final double totalDurationSeconds;

  /// Only a full inspection has one.
  final HiResReport? report;
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
    this.totalDurationSeconds = 0,
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
    this.report,
  });

  factory HiResCheckResult.fromJson(Map<String, dynamic> json) {
    final report = json['report'];
    return HiResCheckResult(
      supported: json['supported'] == true,
      report: report is Map
          ? HiResReport.fromJson(report.cast<String, dynamic>())
          : null,
      verdict: json['verdict'] as String? ?? '',
      declaredSampleRate: (json['declared_sample_rate'] as num?)?.toInt() ?? 0,
      cutoffFrequencyHz: (json['cutoff_frequency_hz'] as num?)?.toDouble() ?? 0,
      analyzedDurationSeconds:
          (json['analyzed_duration_s'] as num?)?.toDouble() ?? 0,
      totalDurationSeconds: (json['total_duration_s'] as num?)?.toDouble() ?? 0,
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
  /// With [detailed] the whole file is read, which takes several seconds,
  /// and the result carries a [HiResCheckResult.report].
  static Future<HiResCheckResult> check(
    String filePath, {
    NetworkAudioAnalysisInput? networkInput,
    bool detailed = false,
  }) async {
    if (NetworkAudioAnalysisInput.isNetwork(filePath)) {
      return (networkInput ?? NetworkAudioAnalysisInput()).withFile(
        filePath,
        (path) => check(path, detailed: detailed),
      );
    }
    final json = await PlatformBridge.checkHiResAuthenticity(
      filePath,
      options: detailed ? const {'detailed': true} : null,
    );
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
