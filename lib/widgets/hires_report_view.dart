import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/services/hires_check_service.dart';
import 'package:mornye/theme/mornye_icons.dart';

/// How much a finding matters, which picks its icon and color.
enum _Level { ok, info, warning, bad }

/// A frame pattern counts as found from this score; the Rust checker's
/// `GRID_SCORE`.
const _patternFoundScore = 12;

/// The report of a whole-file inspection: the outcome, the spectrum it was
/// read from, and one section per test. Sections share the card they sit in.
class HiResReportView extends StatelessWidget {
  const HiResReportView({
    super.key,
    required this.result,
    required this.report,
  });

  final HiResCheckResult result;
  final HiResReport report;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final l10n = context.l10n;
    final (level, title, body) = _outcome(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _Heading(level: level, title: title, large: true),
        if (body != null) ...[const SizedBox(height: 8), _Body(body)],
        if (report.spectrumDb.length > 1) ...[
          const SizedBox(height: 16),
          Text(
            l10n.hiResReportSpectrum,
            style: TextStyle(color: cs.onSurfaceVariant, fontSize: 13),
          ),
          const SizedBox(height: 6),
          Semantics(
            label: l10n.hiResReportSpectrumSemantics(
              _kHz(result.cutoffFrequencyHz),
            ),
            child: SizedBox(
              height: 132,
              width: double.infinity,
              child: CustomPaint(
                painter: _SpectrumPainter(
                  db: report.spectrumDb,
                  stepHz: report.spectrumStepHz,
                  lowpassHz: report.lowpassHz,
                  line: cs.primary,
                  grid: cs.outlineVariant,
                  label: cs.onSurfaceVariant,
                  marker: _lowpassIsSuspect ? cs.error : cs.onSurfaceVariant,
                  textScaler: MediaQuery.textScalerOf(context),
                ),
              ),
            ),
          ),
        ],
        ..._section(context, _integrity(context)),
        ..._section(context, _bitDepth(context)),
        ..._section(context, _frequency(context)),
        ..._section(context, _lossy(context)),
        if (result.totalDurationSeconds > 0) ...[
          const SizedBox(height: 16),
          _Body(l10n.hiResReportWholeFile(_time(result.totalDurationSeconds))),
        ],
      ],
    );
  }

  bool get _lowpassIsSuspect =>
      report.lowpassDropDb >= 25 &&
      (report.lowpassClass == 'low' || report.lowpassClass == 'medium');

  String get _codec => switch (report.lossyFamily) {
    'aac' => 'AAC',
    'vorbis' => 'Vorbis',
    'mp3' => 'MP3',
    _ => '',
  };

  (_Level, String, String?) _outcome(BuildContext context) {
    final l10n = context.l10n;
    return switch (report.grade) {
      'corrupt' => (
        _Level.bad,
        l10n.hiResReportGradeCorrupt,
        l10n.hiResReportGradeCorruptBody,
      ),
      'lossy' => (
        _Level.bad,
        l10n.hiResReportGradeLossy,
        l10n.hiResReportGradeLossyBody(_codec),
      ),
      'upscaled' => (
        result.isCertain ? _Level.bad : _Level.warning,
        result.isCertain
            ? l10n.hiResCheckVerdictFakeCertain
            : l10n.hiResCheckVerdictFake,
        l10n.hiResReportGradeUpscaledBody,
      ),
      'suspect' => (
        _Level.warning,
        l10n.hiResReportGradeSuspect,
        l10n.hiResReportGradeSuspectBody,
      ),
      'limited' => (
        _Level.info,
        l10n.hiResCheckLimitedBandwidth,
        l10n.hiResCheckBandwidthExplanation,
      ),
      'clean' => (
        _Level.ok,
        l10n.hiResReportGradeClean,
        l10n.hiResReportGradeCleanBody,
      ),
      _ => (_Level.info, l10n.hiResCheckVerdictInconclusive, null),
    };
  }

  _SectionData _integrity(BuildContext context) {
    final l10n = context.l10n;
    final rate = math.max(result.declaredSampleRate, 1);
    final decoded = _time(report.decodedFrames / rate);
    final (level, text) = switch (report.integrityStatus) {
      'verified' => (_Level.ok, l10n.hiResReportIntegrityVerified),
      'checksum_mismatch' => (_Level.bad, l10n.hiResReportIntegrityMismatch),
      'length_mismatch' => (
        _Level.bad,
        l10n.hiResReportIntegrityLength(
          decoded,
          _time(report.declaredFrames / rate),
        ),
      ),
      'decode_error' => (
        _Level.bad,
        l10n.hiResReportIntegrityDecodeError(decoded),
      ),
      _ => (_Level.info, l10n.hiResReportIntegrityUnverified),
    };
    return _SectionData(
      title: l10n.hiResReportIntegrity,
      level: level,
      texts: [text],
      rows: [
        if (report.computedMd5.isNotEmpty)
          (l10n.hiResReportChecksum, report.computedMd5),
      ],
    );
  }

  _SectionData _bitDepth(BuildContext context) {
    final l10n = context.l10n;
    final declared = result.declaredBitDepth;
    final used = result.effectiveBitDepth;
    final resolution = report.resolutionBits;
    final (level, text) = switch (report.bitDepthStatus) {
      'full' => (_Level.ok, l10n.hiResReportBitDepthFull(declared)),
      'padded' => (
        declared > 16 && used <= 16 ? _Level.bad : _Level.info,
        l10n.hiResCheckReasonDepth(declared, used),
      ),
      'coarse' => (
        resolution <= 17 ? _Level.warning : _Level.info,
        l10n.hiResReportBitDepthCoarse(_number(resolution)),
      ),
      'near_16bit' => (
        _Level.warning,
        l10n.hiResReportBitDepthNear16(declared),
      ),
      'float' => (_Level.info, l10n.hiResReportBitDepthFloat),
      _ => (_Level.info, l10n.hiResReportBitDepthUnmeasured),
    };
    return _SectionData(
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

  _SectionData _frequency(BuildContext context) {
    final l10n = context.l10n;
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
        ? (result.isCertain ? _Level.bad : _Level.warning)
        : _lowpassIsSuspect
        ? _Level.warning
        : report.lowpassClass == 'source_rate' || result.hasLimitedBandwidth
        ? _Level.info
        : _Level.ok;
    return _SectionData(
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

  _SectionData _lossy(BuildContext context) {
    final l10n = context.l10n;
    final (level, text) = switch (report.lossyStatus) {
      'found' => (
        _Level.bad,
        l10n.hiResReportLossyFound(_codec, report.lossyFrameSamples),
      ),
      'suspected' when report.lossyFamily.isNotEmpty => (
        _Level.warning,
        l10n.hiResReportLossySuspectedPattern,
      ),
      'suspected' => (_Level.warning, l10n.hiResReportLossySuspectedLowpass),
      'not_found' => (_Level.ok, l10n.hiResReportLossyNotFound),
      _ when result.declaredSampleRate > 48000 => (
        _Level.info,
        l10n.hiResReportLossyHighRate,
      ),
      _ => (_Level.info, l10n.hiResReportLossyTooShort),
    };
    return _SectionData(
      title: l10n.hiResReportLossy,
      level: level,
      texts: [text],
      rows: [
        if (report.lossyScore > 0)
          (
            l10n.hiResReportPatternStrength,
            l10n.hiResReportPatternStrengthValue(
              _number(report.lossyScore),
              '$_patternFoundScore',
            ),
          ),
      ],
    );
  }

  List<Widget> _section(BuildContext context, _SectionData section) {
    final cs = Theme.of(context).colorScheme;
    return [
      const SizedBox(height: 16),
      const Divider(height: 1),
      const SizedBox(height: 14),
      _Heading(level: section.level, title: section.title),
      for (final text in section.texts) ...[
        const SizedBox(height: 8),
        _Body(text),
      ],
      if (section.rows.isNotEmpty) const SizedBox(height: 4),
      for (final (label, value) in section.rows)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  label,
                  style: TextStyle(color: cs.onSurfaceVariant, fontSize: 15),
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Text(
                  value,
                  textAlign: TextAlign.end,
                  style: TextStyle(
                    color: cs.onSurface,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ),
            ],
          ),
        ),
    ];
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

class _SectionData {
  const _SectionData({
    required this.title,
    required this.level,
    required this.texts,
    this.rows = const [],
  });

  final String title;
  final _Level level;
  final List<String> texts;
  final List<(String, String)> rows;
}

class _Heading extends StatelessWidget {
  const _Heading({
    required this.level,
    required this.title,
    this.large = false,
  });

  final _Level level;
  final String title;

  /// The outcome of the whole report rather than of one section.
  final bool large;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final (icon, color) = switch (level) {
      _Level.ok => (Icons.check_circle_outline, cs.primary),
      _Level.info => (Icons.info_outline, cs.onSurfaceVariant),
      _Level.warning => (Icons.warning_amber_rounded, cs.error),
      _Level.bad => (Icons.error_outline, cs.error),
    };
    return Row(
      children: [
        Icon(context.adaptiveIcon(icon), color: color, size: large ? 22 : 20),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            title,
            style: TextStyle(
              color: large && level != _Level.ok && level != _Level.info
                  ? color
                  : cs.onSurface,
              fontWeight: FontWeight.w600,
              fontSize: large ? 17 : 16,
            ),
          ),
        ),
      ],
    );
  }
}

class _Body extends StatelessWidget {
  const _Body(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: TextStyle(
        color: Theme.of(context).colorScheme.onSurfaceVariant,
        fontSize: 15,
        height: 1.35,
      ),
    );
  }
}

/// The average spectrum from 0 Hz to Nyquist, 0 dB (the peak) at the top
/// and [_floorDb] at the bottom, with the low-pass marked.
class _SpectrumPainter extends CustomPainter {
  _SpectrumPainter({
    required this.db,
    required this.stepHz,
    required this.lowpassHz,
    required this.line,
    required this.grid,
    required this.label,
    required this.marker,
    required this.textScaler,
  });

  static const _floorDb = -120.0;

  final List<double> db;
  final double stepHz;
  final double lowpassHz;
  final Color line;
  final Color grid;
  final Color label;
  final Color marker;
  final TextScaler textScaler;

  @override
  void paint(Canvas canvas, Size size) {
    final nyquist = stepHz * db.length;
    if (nyquist <= 0) return;
    final labels = textScaler.scale(11);
    final plot = Size(size.width, size.height - labels - 6);
    double x(double hz) => hz / nyquist * plot.width;
    double y(double level) =>
        (level.clamp(_floorDb, 0) / _floorDb) * plot.height;

    final gridPaint = Paint()
      ..color = grid.withValues(alpha: 0.6)
      ..strokeWidth = 1;
    for (final level in const [-40.0, -80.0]) {
      canvas.drawLine(
        Offset(0, y(level)),
        Offset(plot.width, y(level)),
        gridPaint,
      );
    }
    final tick = nyquist <= 25000
        ? 5000.0
        : nyquist <= 50000
        ? 10000.0
        : 20000.0;
    for (var hz = tick; hz < nyquist - tick / 4; hz += tick) {
      canvas.drawLine(Offset(x(hz), 0), Offset(x(hz), plot.height), gridPaint);
      final text = TextPainter(
        text: TextSpan(
          text: '${(hz / 1000).round()}k',
          style: TextStyle(color: label, fontSize: 11),
        ),
        textDirection: TextDirection.ltr,
        textScaler: textScaler,
      )..layout();
      text.paint(canvas, Offset(x(hz) - text.width / 2, plot.height + 6));
    }

    final curve = Path()..moveTo(0, y(db.first));
    for (var i = 1; i < db.length; i++) {
      curve.lineTo(x(stepHz * (i + 0.5)), y(db[i]));
    }
    final area = Path.from(curve)
      ..lineTo(plot.width, plot.height)
      ..lineTo(0, plot.height)
      ..close();
    canvas.drawPath(area, Paint()..color = line.withValues(alpha: 0.16));
    canvas.drawPath(
      curve,
      Paint()
        ..color = line
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..strokeJoin = StrokeJoin.round,
    );
    canvas.drawLine(
      Offset(0, plot.height),
      Offset(plot.width, plot.height),
      gridPaint,
    );

    if (lowpassHz > 0 && lowpassHz < nyquist) {
      final at = x(lowpassHz);
      final markerPaint = Paint()
        ..color = marker
        ..strokeWidth = 1.5;
      canvas.drawLine(Offset(at, 6), Offset(at, plot.height), markerPaint);
      canvas.drawPath(
        Path()
          ..moveTo(at - 5, 0)
          ..lineTo(at + 5, 0)
          ..lineTo(at, 7)
          ..close(),
        markerPaint,
      );
    }
  }

  @override
  bool shouldRepaint(_SpectrumPainter old) =>
      old.db != db ||
      old.stepHz != stepHz ||
      old.lowpassHz != lowpassHz ||
      old.line != line ||
      old.grid != grid ||
      old.label != label ||
      old.marker != marker ||
      old.textScaler != textScaler;
}
