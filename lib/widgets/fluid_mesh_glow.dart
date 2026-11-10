import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:mornye/theme/cover_palette.dart';

/// A living, organic fluid mesh glow that smoothly moves, breathes, and morphs
/// in the background of Now Playing behind album artwork, controls, and lyrics.
class FluidMeshGlow extends StatefulWidget {
  const FluidMeshGlow({
    super.key,
    this.artUri,
    this.sourceColor,
    this.dominantColor,
    this.colorScheme,
    this.opacity = 0.35,
    this.isAmoled = false,
  });

  final Uri? artUri;
  final Color? sourceColor;
  final Color? dominantColor;
  final ColorScheme? colorScheme;
  final double opacity;
  final bool isAmoled;

  @override
  State<FluidMeshGlow> createState() => _FluidMeshGlowState();
}

class _FluidMeshGlowState extends State<FluidMeshGlow>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 14),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      if (_controller.isAnimating) _controller.stop();
    } else {
      if (!_controller.isAnimating) _controller.repeat();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.sourceColor != null || widget.dominantColor != null) {
      final base = widget.dominantColor ?? widget.sourceColor!;
      return _buildAnimatedMesh(context, base);
    }

    if (widget.artUri != null) {
      return CoverSourceColorBuilder(
        imageSource: widget.artUri.toString(),
        builder: (context, extractedColor) {
          final fallback =
              widget.colorScheme?.primary ??
              Theme.of(context).colorScheme.primary;
          return _buildAnimatedMesh(context, extractedColor ?? fallback);
        },
      );
    }

    final fallback =
        widget.colorScheme?.primary ?? Theme.of(context).colorScheme.primary;
    return _buildAnimatedMesh(context, fallback);
  }

  Widget _buildAnimatedMesh(BuildContext context, Color baseColor) {
    final disableAnimations = MediaQuery.disableAnimationsOf(context);
    final hsl = HSLColor.fromColor(baseColor);
    final isMonochrome = hsl.saturation < 0.08;

    // Primary dominant glow
    final color1 = hsl
        .withSaturation(
          isMonochrome ? 0.0 : (hsl.saturation * 1.3).clamp(0.3, 0.9),
        )
        .withLightness(0.46)
        .toColor();

    // Secondary hue-shifted fluid glow (+35 deg)
    final color2 = hsl
        .withHue((hsl.hue + (isMonochrome ? 0.0 : 35.0)) % 360.0)
        .withSaturation(
          isMonochrome ? 0.0 : (hsl.saturation * 1.1).clamp(0.3, 0.85),
        )
        .withLightness(0.40)
        .toColor();

    // Tertiary complementary fluid glow (+70 deg)
    final color3 = hsl
        .withHue((hsl.hue + (isMonochrome ? 0.0 : 70.0)) % 360.0)
        .withSaturation(
          isMonochrome ? 0.0 : (hsl.saturation * 1.2).clamp(0.25, 0.8),
        )
        .withLightness(0.38)
        .toColor();

    // Soft deep ambient glow (+180 deg)
    final color4 = hsl
        .withHue((hsl.hue + (isMonochrome ? 0.0 : 180.0)) % 360.0)
        .withSaturation(isMonochrome ? 0.0 : hsl.saturation.clamp(0.2, 0.6))
        .withLightness(0.32)
        .toColor();

    if (disableAnimations) {
      return CustomPaint(
        painter: _FluidMeshPainter(
          progress: 0.0,
          color1: color1,
          color2: color2,
          color3: color3,
          color4: color4,
          opacity: widget.opacity,
          isAmoled: widget.isAmoled,
        ),
        size: Size.infinite,
      );
    }

    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) => CustomPaint(
        painter: _FluidMeshPainter(
          progress: _controller.value,
          color1: color1,
          color2: color2,
          color3: color3,
          color4: color4,
          opacity: widget.opacity,
          isAmoled: widget.isAmoled,
        ),
        size: Size.infinite,
      ),
    );
  }
}

class _FluidMeshPainter extends CustomPainter {
  const _FluidMeshPainter({
    required this.progress,
    required this.color1,
    required this.color2,
    required this.color3,
    required this.color4,
    required this.opacity,
    required this.isAmoled,
  });

  final double progress;
  final Color color1;
  final Color color2;
  final Color color3;
  final Color color4;
  final double opacity;
  final bool isAmoled;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;

    final theta = progress * 2.0 * math.pi;
    final effectiveOpacity = isAmoled ? opacity * 0.75 : opacity;

    // 1. Primary Blob: Gently orbits the upper-middle area (near album art / top)
    final center1 = Offset(
      size.width * (0.50 + 0.16 * math.sin(theta)),
      size.height * (0.30 + 0.10 * math.cos(theta * 1.2)),
    );
    final radius1 = size.width * (0.75 + 0.12 * math.sin(theta * 0.8));
    final paint1 = Paint()
      ..shader = ui.Gradient.radial(
        center1,
        radius1,
        [
          color1.withValues(alpha: effectiveOpacity),
          color1.withValues(alpha: effectiveOpacity * 0.45),
          Colors.transparent,
        ],
        const [0.0, 0.55, 1.0],
      );
    canvas.drawRect(Offset.zero & size, paint1);

    // 2. Secondary Blob: Drifts across the mid-left area
    final center2 = Offset(
      size.width * (0.28 + 0.18 * math.cos(theta * 0.9 + 1.2)),
      size.height * (0.55 + 0.14 * math.sin(theta * 1.1 + 0.6)),
    );
    final radius2 = size.width * (0.70 + 0.10 * math.cos(theta * 0.7));
    final paint2 = Paint()
      ..shader = ui.Gradient.radial(
        center2,
        radius2,
        [
          color2.withValues(alpha: effectiveOpacity * 0.85),
          color2.withValues(alpha: effectiveOpacity * 0.35),
          Colors.transparent,
        ],
        const [0.0, 0.60, 1.0],
      );
    canvas.drawRect(Offset.zero & size, paint2);

    // 3. Tertiary Blob: Drifts across the bottom-right area (behind scrubber & controls)
    final center3 = Offset(
      size.width * (0.72 + 0.15 * math.sin(theta * 1.3 + 2.4)),
      size.height * (0.68 + 0.15 * math.cos(theta * 0.8 + 1.8)),
    );
    final radius3 = size.width * (0.65 + 0.12 * math.sin(theta * 1.4));
    final paint3 = Paint()
      ..shader = ui.Gradient.radial(
        center3,
        radius3,
        [
          color3.withValues(alpha: effectiveOpacity * 0.75),
          color3.withValues(alpha: effectiveOpacity * 0.30),
          Colors.transparent,
        ],
        const [0.0, 0.55, 1.0],
      );
    canvas.drawRect(Offset.zero & size, paint3);

    // 4. Soft Deep Ambient Center: Breaths slowly in the center
    final center4 = Offset(
      size.width * (0.50 + 0.10 * math.cos(theta * 0.6 + 3.0)),
      size.height * (0.45 + 0.08 * math.sin(theta * 0.9 + 2.0)),
    );
    final radius4 = size.width * (0.85 + 0.12 * math.cos(theta));
    final paint4 = Paint()
      ..shader = ui.Gradient.radial(
        center4,
        radius4,
        [color4.withValues(alpha: effectiveOpacity * 0.50), Colors.transparent],
        const [0.0, 1.0],
      );
    canvas.drawRect(Offset.zero & size, paint4);
  }

  @override
  bool shouldRepaint(_FluidMeshPainter oldDelegate) =>
      oldDelegate.progress != progress ||
      oldDelegate.color1 != color1 ||
      oldDelegate.color2 != color2 ||
      oldDelegate.color3 != color3 ||
      oldDelegate.color4 != color4 ||
      oldDelegate.opacity != opacity ||
      oldDelegate.isAmoled != isAmoled;
}
