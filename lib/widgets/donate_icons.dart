import 'package:material_ui/material_ui.dart';

class KofiIcon extends StatelessWidget {
  final double size;
  final Color color;

  const KofiIcon({super.key, this.size = 22, this.color = Colors.white});

  @override
  Widget build(BuildContext context) {
    return CustomPaint(size: Size(size, size), painter: _KofiPainter(color));
  }
}

class _KofiPainter extends CustomPainter {
  final Color color;
  _KofiPainter(this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width;
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;

    final cup = RRect.fromRectAndRadius(
      Rect.fromLTWH(s * 0.08, s * 0.28, s * 0.62, s * 0.52),
      Radius.circular(s * 0.12),
    );
    canvas.drawRRect(cup, paint);

    final handlePaint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = s * 0.08
      ..strokeCap = StrokeCap.round;

    final handlePath = Path()
      ..moveTo(s * 0.70, s * 0.40)
      ..quadraticBezierTo(s * 0.92, s * 0.40, s * 0.92, s * 0.54)
      ..quadraticBezierTo(s * 0.92, s * 0.68, s * 0.70, s * 0.68);
    canvas.drawPath(handlePath, handlePaint);

    final heartPaint = Paint()
      ..color = const Color(0xFFFF5E5B)
      ..style = PaintingStyle.fill;

    final hx = s * 0.39;
    final hy = s * 0.46;
    final hs = s * 0.12;

    final heart = Path()
      ..moveTo(hx, hy + hs * 0.3)
      ..cubicTo(
        hx - hs,
        hy - hs * 0.3,
        hx - hs * 0.5,
        hy - hs,
        hx,
        hy - hs * 0.4,
      )
      ..cubicTo(
        hx + hs * 0.5,
        hy - hs,
        hx + hs,
        hy - hs * 0.3,
        hx,
        hy + hs * 0.3,
      )
      ..close();
    canvas.drawPath(heart, heartPaint);

    final steamPaint = Paint()
      ..color = color.withValues(alpha: 0.6)
      ..style = PaintingStyle.stroke
      ..strokeWidth = s * 0.04
      ..strokeCap = StrokeCap.round;

    for (var i = 0; i < 2; i++) {
      final sx = s * (0.30 + i * 0.18);
      final steam = Path()
        ..moveTo(sx, s * 0.24)
        ..quadraticBezierTo(sx - s * 0.04, s * 0.18, sx, s * 0.12);
      canvas.drawPath(steam, steamPaint);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class GitHubIcon extends StatelessWidget {
  final double size;
  final Color color;

  const GitHubIcon({super.key, this.size = 22, this.color = Colors.white});

  @override
  Widget build(BuildContext context) {
    return CustomPaint(size: Size(size, size), painter: _GitHubPainter(color));
  }
}

class _GitHubPainter extends CustomPainter {
  final Color color;
  _GitHubPainter(this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width;
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;

    final scale = s / 24.0;

    final path = Path();
    path.moveTo(12 * scale, 0.5 * scale);
    path.cubicTo(
      5.37 * scale,
      0.5 * scale,
      0 * scale,
      5.87 * scale,
      0 * scale,
      12.5 * scale,
    );
    path.cubicTo(
      0 * scale,
      17.78 * scale,
      3.44 * scale,
      22.27 * scale,
      8.21 * scale,
      23.85 * scale,
    );
    path.cubicTo(
      8.81 * scale,
      23.96 * scale,
      9.02 * scale,
      23.59 * scale,
      9.02 * scale,
      23.27 * scale,
    );
    path.cubicTo(
      9.02 * scale,
      22.98 * scale,
      9.01 * scale,
      22.01 * scale,
      9.01 * scale,
      21.01 * scale,
    );
    path.cubicTo(
      5.67 * scale,
      21.71 * scale,
      4.97 * scale,
      19.56 * scale,
      4.97 * scale,
      19.56 * scale,
    );
    path.cubicTo(
      4.42 * scale,
      18.22 * scale,
      3.63 * scale,
      17.85 * scale,
      3.63 * scale,
      17.85 * scale,
    );
    path.cubicTo(
      2.55 * scale,
      17.12 * scale,
      3.71 * scale,
      17.13 * scale,
      3.71 * scale,
      17.13 * scale,
    );
    path.cubicTo(
      4.90 * scale,
      17.22 * scale,
      5.53 * scale,
      18.36 * scale,
      5.53 * scale,
      18.36 * scale,
    );
    path.cubicTo(
      6.58 * scale,
      20.05 * scale,
      8.36 * scale,
      19.53 * scale,
      9.05 * scale,
      19.22 * scale,
    );
    path.cubicTo(
      9.16 * scale,
      18.45 * scale,
      9.47 * scale,
      17.93 * scale,
      9.81 * scale,
      17.63 * scale,
    );
    path.cubicTo(
      7.15 * scale,
      17.33 * scale,
      4.34 * scale,
      16.33 * scale,
      4.34 * scale,
      11.93 * scale,
    );
    path.cubicTo(
      4.34 * scale,
      10.68 * scale,
      4.81 * scale,
      9.66 * scale,
      5.55 * scale,
      8.86 * scale,
    );
    path.cubicTo(
      5.43 * scale,
      8.56 * scale,
      5.02 * scale,
      7.40 * scale,
      5.67 * scale,
      5.82 * scale,
    );
    path.cubicTo(
      5.67 * scale,
      5.82 * scale,
      6.66 * scale,
      5.50 * scale,
      8.98 * scale,
      6.99 * scale,
    );
    path.cubicTo(
      9.94 * scale,
      6.72 * scale,
      10.98 * scale,
      6.59 * scale,
      12.0 * scale,
      6.58 * scale,
    );
    path.cubicTo(
      13.02 * scale,
      6.59 * scale,
      14.06 * scale,
      6.72 * scale,
      15.02 * scale,
      6.99 * scale,
    );
    path.cubicTo(
      17.34 * scale,
      5.50 * scale,
      18.33 * scale,
      5.82 * scale,
      18.33 * scale,
      5.82 * scale,
    );
    path.cubicTo(
      18.98 * scale,
      7.40 * scale,
      18.57 * scale,
      8.56 * scale,
      18.45 * scale,
      8.86 * scale,
    );
    path.cubicTo(
      19.19 * scale,
      9.66 * scale,
      19.66 * scale,
      10.68 * scale,
      19.66 * scale,
      11.93 * scale,
    );
    path.cubicTo(
      19.66 * scale,
      16.34 * scale,
      16.84 * scale,
      17.32 * scale,
      14.17 * scale,
      17.62 * scale,
    );
    path.cubicTo(
      14.59 * scale,
      17.99 * scale,
      14.97 * scale,
      18.70 * scale,
      14.97 * scale,
      19.80 * scale,
    );
    path.cubicTo(
      14.97 * scale,
      21.40 * scale,
      14.95 * scale,
      22.67 * scale,
      14.95 * scale,
      23.27 * scale,
    );
    path.cubicTo(
      14.95 * scale,
      23.60 * scale,
      15.16 * scale,
      23.97 * scale,
      15.77 * scale,
      23.85 * scale,
    );
    path.cubicTo(
      20.55 * scale,
      22.26 * scale,
      24.0 * scale,
      17.78 * scale,
      24.0 * scale,
      12.5 * scale,
    );
    path.cubicTo(
      24.0 * scale,
      5.87 * scale,
      18.63 * scale,
      0.5 * scale,
      12.0 * scale,
      0.5 * scale,
    );
    path.close();

    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
