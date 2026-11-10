import 'dart:math' as math;
import 'package:flutter/material.dart';

/// Liquid Glass animated audio spectrum visualizer.
///
/// Paints a reactive 24-band frequency wave with specular gloss, dynamic
/// bounce and harmonic energy curves tailored for modern studio audio playback.
class RealtimeAudioVisualizer extends StatefulWidget {
  const RealtimeAudioVisualizer({
    super.key,
    required this.isPlaying,
    this.accentColor,
    this.barCount = 28,
    this.height = 42.0,
  });

  final bool isPlaying;
  final Color? accentColor;
  final int barCount;
  final double height;

  @override
  State<RealtimeAudioVisualizer> createState() =>
      _RealtimeAudioVisualizerState();
}

class _RealtimeAudioVisualizerState extends State<RealtimeAudioVisualizer>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2400),
    );
    if (widget.isPlaying) {
      _controller.repeat();
    }
  }

  @override
  void didUpdateWidget(covariant RealtimeAudioVisualizer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isPlaying != oldWidget.isPlaying) {
      if (widget.isPlaying) {
        if (!_controller.isAnimating) _controller.repeat();
      } else {
        _controller.stop();
      }
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = widget.accentColor ?? Colors.white.withValues(alpha: 0.85);

    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) => CustomPaint(
        size: Size(double.infinity, widget.height),
        painter: _VisualizerPainter(
          progress: _controller.value,
          isPlaying: widget.isPlaying,
          barCount: widget.barCount,
          accentColor: color,
        ),
      ),
    );
  }
}

class _VisualizerPainter extends CustomPainter {
  const _VisualizerPainter({
    required this.progress,
    required this.isPlaying,
    required this.barCount,
    required this.accentColor,
  });

  final double progress;
  final bool isPlaying;
  final int barCount;
  final Color accentColor;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;

    final barWidth = (size.width / barCount) * 0.58;
    final gap = (size.width - (barWidth * barCount)) / (barCount - 1);
    final maxHeight = size.height * 0.90;
    final minHeight = size.height * 0.12;

    for (int i = 0; i < barCount; i++) {
      final x = i * (barWidth + gap);
      final normalizedIndex = i / (barCount - 1);

      // Acoustic envelope curve (bell curve peaking at lower mids ~300-800Hz)
      final envelope = math.sin(normalizedIndex * math.pi);

      double heightFactor;
      if (isPlaying) {
        // Multi-frequency harmonic synthesis
        final wave1 = math.sin((progress * 2 * math.pi * 3.5) + (i * 0.42));
        final wave2 = math.cos((progress * 2 * math.pi * 2.1) + (i * 0.78));
        final wave3 = math.sin((progress * 2 * math.pi * 5.2) + (i * 0.25));

        final energy = (wave1 * 0.45 + wave2 * 0.35 + wave3 * 0.20 + 1.0) / 2.0;
        heightFactor = (0.2 + energy * 0.8 * envelope).clamp(0.12, 1.0);
      } else {
        heightFactor = 0.14 * envelope + 0.06;
      }

      final barH = math.max(minHeight, maxHeight * heightFactor);
      final y = size.height - barH;

      final rect = RRect.fromRectAndRadius(
        Rect.fromLTWH(x, y, barWidth, barH),
        Radius.circular(barWidth / 2),
      );

      // Liquid glass gradient for each bar
      final paint = Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            accentColor.withValues(alpha: isPlaying ? 0.92 : 0.35),
            accentColor.withValues(alpha: isPlaying ? 0.40 : 0.15),
          ],
        ).createShader(rect.outerRect);

      canvas.drawRRect(rect, paint);

      // Specular highlight dot at the top of the bar
      if (isPlaying && barH > 10) {
        final highlightPaint = Paint()
          ..color = Colors.white.withValues(alpha: 0.65)
          ..style = PaintingStyle.fill;
        canvas.drawCircle(
          Offset(x + barWidth / 2, y + barWidth / 2),
          barWidth * 0.38,
          highlightPaint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant _VisualizerPainter oldDelegate) =>
      oldDelegate.progress != progress ||
      oldDelegate.isPlaying != isPlaying ||
      oldDelegate.accentColor != accentColor;
}
