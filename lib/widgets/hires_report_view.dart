import 'package:flutter/foundation.dart' show listEquals;
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
    this.spectrumColor,
  });

  final HiResCheckResult result;
  final HiResReport report;

  /// The color this song has on a chart shared with other songs, so its own
  /// spectrum matches; the theme's primary when null.
  final Color? spectrumColor;

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
                  lines: [
                    (
                      db: report.spectrumDb,
                      stepHz: report.spectrumStepHz,
                      color: spectrumColor ?? cs.primary,
                    ),
                  ],
                  lowpassHz: report.lowpassHz,
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

/// One song's average spectrum on a chart: dB below its peak, [stepHz]
/// apart, drawn in [color].
typedef HiResSpectrumLine = ({List<double> db, double stepHz, Color color});

/// The colors that tell songs apart on a shared chart, in a fixed order and
/// checked for color-blind separation on the app's light and dark surfaces.
abstract final class HiResSongColors {
  static const _light = [
    Color(0xFF2A78D6),
    Color(0xFFEB6834),
    Color(0xFF1BAF7A),
    Color(0xFFEDA100),
    Color(0xFFE87BA4),
    Color(0xFF008300),
    Color(0xFF6250D6),
    Color(0xFFE34948),
  ];
  static const _dark = [
    Color(0xFF3987E5),
    Color(0xFFD95926),
    Color(0xFF199E70),
    Color(0xFFC98500),
    Color(0xFFD55181),
    Color(0xFF0CA30C),
    Color(0xFF9085E9),
    Color(0xFFE66767),
  ];

  /// How many songs get a color of their own.
  static const count = 8;

  /// The color of the song in [slot]. Songs past [count] share the theme's
  /// outline color: more hues than that cannot be told apart.
  static Color of(BuildContext context, int slot) {
    final theme = Theme.of(context);
    if (slot >= count) return theme.colorScheme.outline;
    return on(theme.brightness, slot);
  }

  /// The color in [slot] (below [count]) on a [brightness] surface, for
  /// drawings that do not follow the theme.
  static Color on(Brightness brightness, int slot) =>
      (brightness == Brightness.dark ? _dark : _light)[slot % count];
}

/// The average spectra of several songs on one chart, a line per song.
class HiResSpectrumOverlay extends StatelessWidget {
  const HiResSpectrumOverlay({super.key, required this.lines});

  final List<HiResSpectrumLine> lines;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final l10n = context.l10n;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          l10n.hiResReportSpectrum,
          style: TextStyle(color: cs.onSurfaceVariant, fontSize: 13),
        ),
        const SizedBox(height: 6),
        Semantics(
          label: l10n.hiResBatchSpectrumSemantics(lines.length),
          child: SizedBox(
            height: 132,
            width: double.infinity,
            child: CustomPaint(
              painter: _SpectrumPainter(
                lines: lines,
                grid: cs.outlineVariant,
                label: cs.onSurfaceVariant,
                marker: cs.onSurfaceVariant,
                textScaler: MediaQuery.textScalerOf(context),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Average spectra from 0 Hz to the highest Nyquist among [lines], 0 dB
/// (the peak) at the top and [_floorDb] at the bottom. One line is filled
/// underneath and has its low-pass marked; several are lines only.
class _SpectrumPainter extends CustomPainter {
  _SpectrumPainter({
    required this.lines,
    this.lowpassHz = 0,
    required this.grid,
    required this.label,
    required this.marker,
    required this.textScaler,
  });

  static const _floorDb = -120.0;

  final List<HiResSpectrumLine> lines;
  final double lowpassHz;
  final Color grid;
  final Color label;
  final Color marker;
  final TextScaler textScaler;

  @override
  void paint(Canvas canvas, Size size) {
    var nyquist = 0.0;
    for (final line in lines) {
      final end = line.stepHz * line.db.length;
      if (end > nyquist) nyquist = end;
    }
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
      try {
        text.paint(canvas, Offset(x(hz) - text.width / 2, plot.height + 6));
      } finally {
        text.dispose();
      }
    }

    // Last to first, so the first songs, which have a color of their own,
    // end up on top of the ones that share one.
    for (final line in lines.reversed) {
      final db = line.db;
      if (db.isEmpty) continue;
      final curve = Path()..moveTo(0, y(db.first));
      for (var i = 1; i < db.length; i++) {
        curve.lineTo(x(line.stepHz * (i + 0.5)), y(db[i]));
      }
      if (lines.length == 1) {
        final area = Path.from(curve)
          ..lineTo(x(line.stepHz * db.length), plot.height)
          ..lineTo(0, plot.height)
          ..close();
        canvas.drawPath(
          area,
          Paint()..color = line.color.withValues(alpha: 0.16),
        );
      }
      canvas.drawPath(
        curve,
        Paint()
          ..color = line.color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5
          ..strokeJoin = StrokeJoin.round,
      );
    }
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
      !listEquals(old.lines, lines) ||
      old.lowpassHz != lowpassHz ||
      old.grid != grid ||
      old.label != label ||
      old.marker != marker ||
      old.textScaler != textScaler;
}
