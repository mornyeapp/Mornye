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
  static const _parametricSteps = 120;
  static final double _logSpan = math.log(_maxHz / _minHz);
  static final List<double> _parametricGridHz = List<double>.unmodifiable([
    for (var i = 0; i <= _parametricSteps; i++)
      _minHz * math.pow(_maxHz / _minHz, i / _parametricSteps).toDouble(),
  ]);

  static _EqualizerCurveGeometry? _cachedGeometry;

  _EqualizerCurveGeometry _geometryFor(Rect plot) {
    final cached = _cachedGeometry;
    if (cached != null &&
        cached.plot == plot &&
        _sameCurve(cached.settings, settings)) {
      return cached;
    }
    double x(double hz) =>
        plot.left + math.log(hz / _minHz) / _logSpan * plot.width;
    double y(double gain) =>
        plot.center.dy - gain.clamp(-_range, _range) / _range * plot.height / 2;

    final points = <Offset>[];
    final dots = <Offset>[];
    double dotRadius = 4;
    if (settings.parametric) {
      // The filters' own response, which has no bands to pass through.
      final activeFilters = [
        for (final filter in settings.filters)
          if (filter.enabled) filter,
      ];
      final sampleHz = <double>[
        ..._parametricGridHz,
        for (final filter in activeFilters) filter.frequency,
      ];
      final responses = settings.sampleParametricResponse(sampleHz);
      for (var i = 0; i <= _parametricSteps; i++) {
        points.add(
          Offset(
            plot.left + plot.width * i / _parametricSteps,
            y(responses[i]),
          ),
        );
      }
      for (var i = 0; i < activeFilters.length; i++) {
        dots.add(
          Offset(
            x(activeFilters[i].frequency),
            y(responses[_parametricSteps + 1 + i]),
          ),
        );
      }
    } else {
      final effective = settings.effectiveGains;
      final freqs = settings.frequencies;
      points.add(Offset(plot.left, y(effective.first)));
      for (var i = 0; i < effective.length; i++) {
        final point = Offset(x(freqs[i]), y(effective[i]));
        if (point.dx > points.last.dx + 0.5 && point.dx < plot.right - 0.5) {
          points.add(point);
        }
      }
      points.add(Offset(plot.right, y(effective.last)));
      dotRadius = effective.length > 15 ? 2.5 : 4;
      for (var i = 0; i < effective.length; i++) {
        final hz = freqs[i];
        if (hz < _minHz || hz > _maxHz) continue;
        dots.add(Offset(x(hz), y(effective[i])));
      }
    }
    final line = _monotoneSpline(points);
    final area = Path.from(line)
      ..lineTo(plot.right, plot.center.dy)
      ..lineTo(plot.left, plot.center.dy)
      ..close();
    final built = _EqualizerCurveGeometry(
      settings: settings,
      plot: plot,
      line: line,
      area: area,
      dots: dots,
      dotRadius: dotRadius,
    );
    _cachedGeometry = built;
    return built;
  }

  static bool _sameCurve(EqualizerSettings a, EqualizerSettings b) {
    if (identical(a, b)) return true;
    if (a.parametric != b.parametric) return false;
    if (a.parametric) {
      if (identical(a.filters, b.filters)) return true;
      if (a.filters.length != b.filters.length) return false;
      for (var i = 0; i < a.filters.length; i++) {
        if (a.filters[i] != b.filters[i]) return false;
      }
      return true;
    }
    if (a.bass != b.bass || a.treble != b.treble) return false;
    if (identical(a.gains, b.gains)) return true;
    if (a.gains.length != b.gains.length) return false;
    for (var i = 0; i < a.gains.length; i++) {
      if (a.gains[i] != b.gains[i]) return false;
    }
    return true;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final (gutter, bottomInset) = _equalizerPlotInsets(labelStyle, textScaler);
    final bottom = size.height - bottomInset;
    final plot = Rect.fromLTRB(gutter, 4, size.width, bottom);
    final geometry = _geometryFor(plot);
    canvas.save();
    canvas.clipRect(plot);
    canvas.drawPath(
      geometry.area,
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
      geometry.line,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..strokeJoin = StrokeJoin.round
        ..strokeCap = StrokeCap.round,
    );
    final dot = Paint()..color = color;
    for (final center in geometry.dots) {
      canvas.drawCircle(center, geometry.dotRadius, dot);
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
      !_sameCurve(oldDelegate.settings, settings) ||
      oldDelegate.color != color ||
      oldDelegate.labelStyle != labelStyle ||
      oldDelegate.textScaler != textScaler;
}

class _EqualizerCurveGeometry {
  const _EqualizerCurveGeometry({
    required this.settings,
    required this.plot,
    required this.line,
    required this.area,
    required this.dots,
    required this.dotRadius,
  });

  final EqualizerSettings settings;
  final Rect plot;
  final Path line;
  final Path area;
  final List<Offset> dots;
  final double dotRadius;
}
