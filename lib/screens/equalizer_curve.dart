part of 'equalizer_screen.dart';

double _snap(double value, double step) => (value / step).round() * step;

/// Signed gain with a true minus sign, e.g. `+3.5`, `0.0`, `−2.0`.
String _signed(double value) {
  final text = value.abs().toStringAsFixed(1);
  if (text == '0.0') return text;
  return value > 0 ? '+$text' : '−$text';
}

String _frequency(double hz) => hz >= 1000
    ? '${(hz / 1000).toStringAsFixed(hz >= 10000 ? 0 : 1)}k'
    : hz.toStringAsFixed(0);

/// Cached `(gutter, bottomInset)` of the equalizer plot for a given label style.
(TextStyle, TextScaler, double, double)? _equalizerInsetsCache;

(double gutter, double bottomInset) _equalizerPlotInsets(
  TextStyle labelStyle,
  TextScaler textScaler,
) {
  final clamped = textScaler.clamp(maxScaleFactor: 1.3);
  final cached = _equalizerInsetsCache;
  if (cached != null && cached.$1 == labelStyle && cached.$2 == clamped) {
    return (cached.$3, cached.$4);
  }
  final freq = TextPainter(
    text: TextSpan(text: _frequency(100.0), style: labelStyle),
    textDirection: TextDirection.ltr,
    textScaler: clamped,
  )..layout();
  final gain = TextPainter(
    text: TextSpan(text: '+12', style: labelStyle),
    textDirection: TextDirection.ltr,
    textScaler: clamped,
  )..layout();
  final gutter = gain.width + 8;
  final bottomInset = freq.height + 6;
  freq.dispose();
  gain.dispose();
  _equalizerInsetsCache = (labelStyle, clamped, gutter, bottomInset);
  return (gutter, bottomInset);
}

class _EqualizerGridPainter extends CustomPainter {
  _EqualizerGridPainter({
    required this.grid,
    required this.label,
    required this.labelStyle,
    required this.textScaler,
  });

  final Color grid, label;
  final TextStyle labelStyle;
  final TextScaler textScaler;

  static const _range = 18.0;
  static const _minHz = 20.0, _maxHz = 20000.0;

  TextPainter _text(String text) => TextPainter(
    text: TextSpan(
      text: text,
      style: labelStyle.copyWith(color: label),
    ),
    textDirection: TextDirection.ltr,
    textScaler: textScaler.clamp(maxScaleFactor: 1.3),
  )..layout();

  @override
  void paint(Canvas canvas, Size size) {
    final freqLabels = [
      for (final hz in const [100.0, 1000.0, 10000.0])
        (hz, _text(_frequency(hz))),
    ];
    final gainLabels = [
      for (final entry in const [(12.0, '+12'), (0.0, '0'), (-12.0, '−12')])
        (entry.$1, _text(entry.$2)),
    ];
    try {
      final bottom = size.height - freqLabels.first.$2.height - 6;
      final gutter = gainLabels.first.$2.width + 8;
      final plot = Rect.fromLTRB(gutter, 4, size.width, bottom);
      double x(double hz) =>
          plot.left +
          math.log(hz / _minHz) / math.log(_maxHz / _minHz) * plot.width;
      double y(double gain) =>
          plot.center.dy -
          gain.clamp(-_range, _range) / _range * plot.height / 2;

      final guide = Paint()
        ..color = grid.withValues(alpha: 0.5)
        ..strokeWidth = 1;
      for (final gain in const [12.0, -12.0]) {
        canvas.drawLine(
          Offset(plot.left, y(gain)),
          Offset(plot.right, y(gain)),
          guide,
        );
      }
      for (final (hz, _) in freqLabels) {
        canvas.drawLine(
          Offset(x(hz), plot.top),
          Offset(x(hz), plot.bottom),
          guide,
        );
      }
      // Dashed 0 dB baseline as a single path.
      final baselinePath = Path();
      for (var dx = plot.left; dx < plot.right; dx += 8) {
        baselinePath
          ..moveTo(dx, plot.center.dy)
          ..lineTo(math.min(dx + 4, plot.right), plot.center.dy);
      }
      canvas.drawPath(
        baselinePath,
        Paint()
          ..color = grid
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5,
      );
      for (final (gain, painter) in gainLabels) {
        painter.paint(
          canvas,
          Offset(gutter - 8 - painter.width, y(gain) - painter.height / 2),
        );
      }
      for (final (hz, painter) in freqLabels) {
        painter.paint(canvas, Offset(x(hz) - painter.width / 2, bottom + 6));
      }
    } finally {
      for (final (_, painter) in freqLabels) {
        painter.dispose();
      }
      for (final (_, painter) in gainLabels) {
        painter.dispose();
      }
    }
  }

  @override
  bool shouldRepaint(_EqualizerGridPainter oldDelegate) =>
      oldDelegate.grid != grid ||
      oldDelegate.label != label ||
      oldDelegate.labelStyle != labelStyle ||
      oldDelegate.textScaler != textScaler;
}

class _EqualizerCurve extends CustomPainter {
  _EqualizerCurve({
    required this.settings,
    required this.color,
    required this.labelStyle,
    required this.textScaler,
  });

  final EqualizerSettings settings;
  final Color color;
  final TextStyle labelStyle;
  final TextScaler textScaler;

  static const _range = 18.0;
  static const _minHz = 20.0, _maxHz = 20000.0;

  @override
  void paint(Canvas canvas, Size size) {
    final (gutter, bottomInset) = _equalizerPlotInsets(labelStyle, textScaler);
    final bottom = size.height - bottomInset;
    final plot = Rect.fromLTRB(gutter, 4, size.width, bottom);
    double x(double hz) =>
        plot.left +
        math.log(hz / _minHz) / math.log(_maxHz / _minHz) * plot.width;
    double y(double gain) =>
        plot.center.dy - gain.clamp(-_range, _range) / _range * plot.height / 2;

    final curve = settings.copyWith(gains: settings.effectiveGains);
    final points = <Offset>[Offset(plot.left, y(curve.gains.first))];
    for (var i = 0; i < curve.gains.length; i++) {
      final point = Offset(x(settings.frequencies[i]), y(curve.gains[i]));
      if (point.dx > points.last.dx + 0.5 && point.dx < plot.right - 0.5) {
        points.add(point);
      }
    }
    points.add(Offset(plot.right, y(curve.gains.last)));
    final line = _monotoneSpline(points);
    final area = Path.from(line)
      ..lineTo(plot.right, plot.center.dy)
      ..lineTo(plot.left, plot.center.dy)
      ..close();
    canvas.save();
    canvas.clipRect(plot);
    canvas.drawPath(
      area,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            color.withValues(alpha: 0.42),
            color.withValues(alpha: 0.12),
            color.withValues(alpha: 0.42),
          ],
        ).createShader(plot),
    );
    canvas.restore();
    canvas.drawPath(
      line,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..strokeJoin = StrokeJoin.round
        ..strokeCap = StrokeCap.round,
    );
    final dot = Paint()..color = color;
    final effective = curve.gains;
    for (var i = 0; i < effective.length; i++) {
      final hz = settings.frequencies[i];
      if (hz < _minHz || hz > _maxHz) continue;
      canvas.drawCircle(
        Offset(x(hz), y(effective[i])),
        effective.length > 15 ? 2.5 : 4,
        dot,
      );
    }
  }

  /// Smooth curve through [points] that never overshoots between bands
  /// (Fritsch–Carlson monotone cubic interpolation).
  static Path _monotoneSpline(List<Offset> points) {
    final n = points.length;
    final path = Path()..moveTo(points.first.dx, points.first.dy);
    if (n < 3) {
      for (final point in points.skip(1)) {
        path.lineTo(point.dx, point.dy);
      }
      return path;
    }
    final slopes = [
      for (var i = 0; i < n - 1; i++)
        (points[i + 1].dy - points[i].dy) / (points[i + 1].dx - points[i].dx),
    ];
    final tangents = [
      slopes.first,
      for (var i = 1; i < n - 1; i++)
        slopes[i - 1] * slopes[i] <= 0 ? 0.0 : (slopes[i - 1] + slopes[i]) / 2,
      slopes.last,
    ];
    for (var i = 0; i < n - 1; i++) {
      if (slopes[i] == 0) {
        tangents[i] = tangents[i + 1] = 0;
        continue;
      }
      final a = tangents[i] / slopes[i], b = tangents[i + 1] / slopes[i];
      final s = a * a + b * b;
      if (s > 9) {
        final t = 3 / math.sqrt(s);
        tangents[i] = t * a * slopes[i];
        tangents[i + 1] = t * b * slopes[i];
      }
    }
    for (var i = 0; i < n - 1; i++) {
      final p0 = points[i], p1 = points[i + 1];
      final h = (p1.dx - p0.dx) / 3;
      path.cubicTo(
        p0.dx + h,
        p0.dy + tangents[i] * h,
        p1.dx - h,
        p1.dy - tangents[i + 1] * h,
        p1.dx,
        p1.dy,
      );
    }
    return path;
  }

  @override
  bool shouldRepaint(_EqualizerCurve oldDelegate) =>
      oldDelegate.settings != settings ||
      oldDelegate.color != color ||
      oldDelegate.labelStyle != labelStyle ||
      oldDelegate.textScaler != textScaler;
}
