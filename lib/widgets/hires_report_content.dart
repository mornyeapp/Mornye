import 'dart:math' as math;

import 'package:mornye/l10n/app_localizations.dart';
import 'package:mornye/services/hires_check_service.dart';

/// How much a finding matters, which picks its icon and color.
enum HiResLevel { ok, info, warning, bad }

/// One test of a report: what it found, in sentences, and its measurements
/// as label and value.
class HiResReportSection {
  const HiResReportSection({
    required this.title,
    required this.level,
    required this.texts,
    this.rows = const [],
  });

  final String title;
  final HiResLevel level;
  final List<String> texts;
  final List<(String, String)> rows;
}

/// The words of a whole-file report: the outcome, then one section per
/// test. The card, the list of a several-song check and the shared text all
/// read them from here, so they cannot say different things.
class HiResReportContent {
  const HiResReportContent._({
    required this.level,
    required this.title,
    required this.body,
    required this.sections,
    required this.footer,
  });

  factory HiResReportContent.of(
    AppLocalizations l10n,
    HiResCheckResult result,
    HiResReport report,
  ) {
    final (level, title, body) = _outcome(l10n, result, report);
    return HiResReportContent._(
      level: level,
      title: title,
      body: body,
      sections: [
        _integrity(l10n, result, report),
        _bitDepth(l10n, result, report),
        _frequency(l10n, result, report),
        _lossy(l10n, result, report),
      ],
      footer: result.totalDurationSeconds > 0
          ? l10n.hiResReportWholeFile(_time(result.totalDurationSeconds))
          : null,
    );
  }

  final HiResLevel level;
  final String title;
  final String? body;
  final List<HiResReportSection> sections;

  /// How much audio was read, and what no analysis can promise.
  final String? footer;

  /// The low-pass sits where a lossy encoder would put it, not a master.
  static bool lowpassIsSuspect(HiResReport report) =>
      report.lowpassDropDb >= 25 &&
      (report.lowpassClass == 'low' || report.lowpassClass == 'medium');

  /// The report as plain text, under the [name] of the song it is about.
  String text({String? name}) => [
    if (name != null && name.isNotEmpty) name,
    title,
    ?body,
    for (final section in sections) ...[
      '',
      section.title,
      ...section.texts,
      for (final (label, value) in section.rows) '$label: $value',
    ],
    if (footer != null) ...['', footer!],
  ].join('\n');

  static String _codec(HiResReport report) => switch (report.lossyFamily) {
    'aac' => 'AAC',
    'vorbis' => 'Vorbis',
    'mp3' => 'MP3',
    _ => '',
  };

  static (HiResLevel, String, String?) _outcome(
    AppLocalizations l10n,
    HiResCheckResult result,
    HiResReport report,
  ) {
    return switch (report.grade) {
      'corrupt' => (
        HiResLevel.bad,
        l10n.hiResReportGradeCorrupt,
        l10n.hiResReportGradeCorruptBody,
      ),
      'lossy' => (
        HiResLevel.bad,
        l10n.hiResReportGradeLossy,
        l10n.hiResReportGradeLossyBody(_codec(report)),
      ),
      'upscaled' => (
        result.isCertain ? HiResLevel.bad : HiResLevel.warning,
        result.isCertain
            ? l10n.hiResCheckVerdictFakeCertain
            : l10n.hiResCheckVerdictFake,
        l10n.hiResReportGradeUpscaledBody,
      ),
      'suspect' => (
        HiResLevel.warning,
        l10n.hiResReportGradeSuspect,
        l10n.hiResReportGradeSuspectBody,
      ),
      'limited' => (
        HiResLevel.info,
        l10n.hiResCheckLimitedBandwidth,
        l10n.hiResCheckBandwidthExplanation,
      ),
      'clean' => (
        HiResLevel.ok,
        l10n.hiResReportGradeClean,
        l10n.hiResReportGradeCleanBody,
      ),
      _ => (HiResLevel.info, l10n.hiResCheckVerdictInconclusive, null),
    };
  }

  static HiResReportSection _integrity(
    AppLocalizations l10n,
    HiResCheckResult result,
    HiResReport report,
  ) {
    final rate = math.max(result.declaredSampleRate, 1);
    final decoded = _time(report.decodedFrames / rate);
    final (level, text) = switch (report.integrityStatus) {
      'verified' => (HiResLevel.ok, l10n.hiResReportIntegrityVerified),
      'checksum_mismatch' => (
        HiResLevel.bad,
        l10n.hiResReportIntegrityMismatch,
      ),
      'length_mismatch' => (
        HiResLevel.bad,
        l10n.hiResReportIntegrityLength(
          decoded,
          _time(report.declaredFrames / rate),
        ),
      ),
      'decode_error' => (
        HiResLevel.bad,
        l10n.hiResReportIntegrityDecodeError(decoded),
      ),
      _ => (HiResLevel.info, l10n.hiResReportIntegrityUnverified),
    };
    return HiResReportSection(
      title: l10n.hiResReportIntegrity,
      level: level,
      texts: [text],
      rows: [
        if (report.computedMd5.isNotEmpty)
          (l10n.hiResReportChecksum, report.computedMd5),
      ],
    );
  }

  static HiResReportSection _bitDepth(
    AppLocalizations l10n,
    HiResCheckResult result,
    HiResReport report,
  ) {
    final declared = result.declaredBitDepth;
    final used = result.effectiveBitDepth;
    final resolution = report.resolutionBits;
    final (level, text) = switch (report.bitDepthStatus) {
      'full' => (HiResLevel.ok, l10n.hiResReportBitDepthFull(declared)),
      'padded' => (
        declared > 16 && used <= 16 ? HiResLevel.bad : HiResLevel.info,
        l10n.hiResCheckReasonDepth(declared, used),
      ),
      'coarse' => (
        resolution <= 17 ? HiResLevel.warning : HiResLevel.info,
        l10n.hiResReportBitDepthCoarse(_number(resolution)),
      ),
      'near_16bit' => (
        HiResLevel.warning,
        l10n.hiResReportBitDepthNear16(declared),
      ),
      'float' => (HiResLevel.info, l10n.hiResReportBitDepthFloat),
      _ => (HiResLevel.info, l10n.hiResReportBitDepthUnmeasured),
    };
    return HiResReportSection(
      title: l10n.hiResReportBitDepth,
      level: level,
      texts: [text],
      rows: [
        if (declared > 0)
          (l10n.hiResCheckActiveBits, '${used > 0 ? used : '?'} / $declared'),
        if (declared >= 24 && used == declared && resolution > 0)
          (
            l10n.hiResReportMeasuredResolution,
            l10n.hiResReportBitsValue(_number(resolution)),
          ),
      ],
    );
  }

  static HiResReportSection _frequency(
    AppLocalizations l10n,
    HiResCheckResult result,
    HiResReport report,
  ) {
    final lowpass = _kHz(report.lowpassHz);
    final upsampling = <String>[
      if (result.upsamplingArtifact == 'sample_hold')
        l10n.hiResCheckReasonSampleHold,
      if (result.upsamplingArtifact == 'linear_interpolation')
        l10n.hiResCheckReasonInterpolation,
      if (result.upsamplingArtifact == 'imaging')
        l10n.hiResCheckImagingEvidence,
      if (result.isFake &&
          result.confidence == 'likely' &&
          result.upsamplingArtifact.isEmpty &&
          result.brickwallHz > 0)
        l10n.hiResCheckRateEvidence(_kHz(result.brickwallHz)),
    ];
    final level = upsampling.isNotEmpty
        ? (result.isCertain ? HiResLevel.bad : HiResLevel.warning)
        : lowpassIsSuspect(report)
        ? HiResLevel.warning
        : report.lowpassClass == 'source_rate' || result.hasLimitedBandwidth
        ? HiResLevel.info
        : HiResLevel.ok;
    return HiResReportSection(
      title: l10n.hiResReportFrequency,
      level: level,
      texts: [
        ...upsampling,
        switch (report.lowpassClass) {
          'format' => l10n.hiResReportLowpassFormat(lowpass),
          'source_rate' => l10n.hiResReportLowpassSourceRate(lowpass),
          'high' => l10n.hiResReportLowpassHigh(lowpass),
          'medium' => l10n.hiResReportLowpassMedium(lowpass),
          'low' => l10n.hiResReportLowpassLow(lowpass),
          _ => l10n.hiResReportLowpassNone,
        },
        if (result.ultrasonicNoiseOnly)
          l10n.hiResCheckSteadyEnergy(_kHz(result.musicCutoffHz)),
        if (result.hasLimitedBandwidth && report.grade != 'limited')
          l10n.hiResCheckBandwidthExplanation,
      ],
      rows: [
        (
          l10n.audioAnalysisSampleRate,
          _kHz(result.declaredSampleRate.toDouble()),
        ),
        (l10n.audioAnalysisNyquist, _kHz(result.declaredSampleRate / 2)),
        (l10n.hiResCheckEstimatedCutoff, '~${_kHz(result.cutoffFrequencyHz)}'),
        if (report.lowpassHz > 0)
          (
            l10n.hiResReportLowpass,
            l10n.hiResReportLowpassValue(
              lowpass,
              report.lowpassDropDb.toStringAsFixed(0),
            ),
          ),
      ],
    );
  }

  static HiResReportSection _lossy(
    AppLocalizations l10n,
    HiResCheckResult result,
    HiResReport report,
  ) {
    final (level, text) = switch (report.lossyStatus) {
      'found' => (
        HiResLevel.bad,
        l10n.hiResReportLossyFound(_codec(report), report.lossyFrameSamples),
      ),
      'suspected' when report.lossyFamily.isNotEmpty => (
        HiResLevel.warning,
        l10n.hiResReportLossySuspectedPattern,
      ),
      'suspected' => (
        HiResLevel.warning,
        l10n.hiResReportLossySuspectedLowpass,
      ),
      'not_found' => (HiResLevel.ok, l10n.hiResReportLossyNotFound),
      _ when result.declaredSampleRate > 48000 => (
        HiResLevel.info,
        l10n.hiResReportLossyHighRate,
      ),
      _ => (HiResLevel.info, l10n.hiResReportLossyTooShort),
    };
    return HiResReportSection(
      title: l10n.hiResReportLossy,
      level: level,
      texts: [text],
      rows: [
        if (report.lossyScore > 0)
          (
            l10n.hiResReportPatternStrength,
            l10n.hiResReportPatternStrengthValue(
              _number(report.lossyScore),
              '${report.lossyFoundScore.round()}',
            ),
          ),
      ],
    );
  }

  static String _kHz(double hz) => '${(hz / 1000).toStringAsFixed(1)} kHz';

  /// One decimal, dropped when it is zero.
  static String _number(double value) => value == value.roundToDouble()
      ? value.toStringAsFixed(0)
      : value.toStringAsFixed(1);

  static String _time(double seconds) {
    final whole = seconds.floor();
    return '${whole ~/ 60}:${(whole % 60).toString().padLeft(2, '0')}';
  }
}
