import 'package:material_ui/material_ui.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/services/hires_check_service.dart';
import 'package:mornye/theme/mornye_icons.dart';
import 'package:mornye/widgets/hires_report_content.dart';

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
    final content = HiResReportContent.of(l10n, result, report);
    final body = content.body;
    final footer = content.footer;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _Heading(level: content.level, title: content.title, large: true),
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
              '${(result.cutoffFrequencyHz / 1000).toStringAsFixed(1)} kHz',
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
                  marker: HiResReportContent.lowpassIsSuspect(report)
                      ? cs.error
                      : cs.onSurfaceVariant,
                  textScaler: MediaQuery.textScalerOf(context),
                ),
              ),
            ),
          ),
        ],
        for (final section in content.sections) ..._section(context, section),
        if (footer != null) ...[const SizedBox(height: 16), _Body(footer)],
      ],
    );
  }

  List<Widget> _section(BuildContext context, HiResReportSection section) {
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
}

/// The icon and color a finding of [level] is shown with.
class HiResLevelIcon extends StatelessWidget {
  const HiResLevelIcon(this.level, {super.key, this.size = 20});

  final HiResLevel level;
  final double size;

  static Color colorOf(ColorScheme cs, HiResLevel level) => switch (level) {
    HiResLevel.ok => cs.primary,
    HiResLevel.info => cs.onSurfaceVariant,
    HiResLevel.warning || HiResLevel.bad => cs.error,
  };

  static IconData iconOf(HiResLevel level) => switch (level) {
    HiResLevel.ok => Icons.check_circle_outline,
    HiResLevel.info => Icons.info_outline,
    HiResLevel.warning => Icons.warning_amber_rounded,
    HiResLevel.bad => Icons.error_outline,
  };

  @override
  Widget build(BuildContext context) {
    return Icon(
      context.adaptiveIcon(iconOf(level)),
      color: colorOf(Theme.of(context).colorScheme, level),
      size: size,
    );
  }
}

class _Heading extends StatelessWidget {
  const _Heading({
    required this.level,
    required this.title,
    this.large = false,
  });

  final HiResLevel level;
  final String title;

  /// The outcome of the whole report rather than of one section.
  final bool large;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Row(
      children: [
        HiResLevelIcon(level, size: large ? 22 : 20),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            title,
            style: TextStyle(
              color: large && level != HiResLevel.ok && level != HiResLevel.info
                  ? HiResLevelIcon.colorOf(cs, level)
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
