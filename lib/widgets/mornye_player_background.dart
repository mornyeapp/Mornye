import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:mornye/theme/cover_palette.dart';

/// Opaque cover-derived surface, with full-bleed artwork on the player page
/// and a muted two-tone gradient behind lyrics and the queue.
class MornyePlayerBackground extends StatelessWidget {
  const MornyePlayerBackground({
    super.key,
    required this.artUri,
    this.artwork,
    this.squareArtwork = true,
    this.artworkAspectRatio,
    this.fadeStart = 0.42,
    this.ambientGlow = false,
  });

  final Uri? artUri;
  final Widget? artwork;
  final bool squareArtwork;
  final double? artworkAspectRatio;

  /// Fraction of the artwork's height that stays sharp before fading out.
  final double fadeStart;

  /// Whether to render an ambient radial glow derived from cover palette.
  final bool ambientGlow;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Theme(
      // Missing or unreadable covers use neutral gray, not the app's accent.
      data: theme.copyWith(
        colorScheme: theme.colorScheme.copyWith(
          brightness: Brightness.dark,
          primary: const Color(0xff808080),
        ),
      ),
      child: CoverSourceColorBuilder(
        imageSource: artUri?.toString(),
        builder: (context, sourceColor) {
          final dominant = HSLColor.fromColor(
            sourceColor ?? const Color(0xff808080),
          );
          final muted = dominant.withSaturation(
            dominant.saturation.clamp(0.0, 0.34),
          );
          // Carry the cover's muted colour through the controls instead of
          // fading bright artwork into a nearly black, flat surface.
          final backdrop = dominant.withSaturation(
            dominant.saturation.clamp(0.0, 0.2),
          );
          final motion = MediaQuery.disableAnimationsOf(context)
              ? Duration.zero
              : const Duration(milliseconds: 380);
          final background = LinearGradient(
            begin: artwork == null ? Alignment.topLeft : Alignment.topCenter,
            end: artwork == null
                ? Alignment.bottomRight
                : Alignment.bottomCenter,
            stops: artwork == null ? null : const [0, 0.5, 1],
            colors: artwork == null
                ? [
                    muted
                        .withLightness(0.28 + dominant.lightness * 0.24)
                        .toColor(),
                    muted
                        .withLightness(0.14 + dominant.lightness * 0.20)
                        .toColor(),
                  ]
                : [
                    backdrop.withLightness(0.62).toColor(),
                    backdrop.withLightness(0.54).toColor(),
                    backdrop.withLightness(0.34).toColor(),
                  ],
          );
          final size = MediaQuery.sizeOf(context);
          final artworkHeight =
              artworkAspectRatio != null && artworkAspectRatio! > 0
              ? (size.width / artworkAspectRatio!).clamp(
                  0.0,
                  size.height * 0.75,
                )
              : squareArtwork
              ? size.width
              : size.height * 0.66;
          return TweenAnimationBuilder<LinearGradient>(
            tween: _GradientTween(end: background),
            duration: motion,
            curve: Curves.easeInOutCubic,
            builder: (context, gradient, artworkLayer) => DecoratedBox(
              decoration: BoxDecoration(gradient: gradient),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  if (ambientGlow)
                    Positioned.fill(
                      child: KeyedSubtree(
                        key: const ValueKey('mornye-ambient-glow'),
                        child: IgnorePointer(
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              gradient: RadialGradient(
                                center: const Alignment(0.0, -0.28),
                                radius: 0.95,
                                colors: [
                                  dominant
                                      .withSaturation(
                                        (dominant.saturation * 1.3).clamp(
                                          0.2,
                                          0.75,
                                        ),
                                      )
                                      .withLightness(0.42)
                                      .toColor()
                                      .withValues(alpha: 0.38),
                                  muted
                                      .withLightness(0.32)
                                      .toColor()
                                      .withValues(alpha: 0.16),
                                  Colors.transparent,
                                ],
                                stops: const [0.0, 0.55, 1.0],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  artworkLayer!,
                  // An outgoing cover fades out while the gradient leaves
                  // the full-bleed layout.
                  if (artwork != null || gradient.begin != background.begin)
                    CustomPaint(
                      painter: _ArtworkFade(
                        gradient,
                        artworkHeight * fadeStart,
                        artworkHeight,
                      ),
                    ),
                ],
              ),
            ),
            child: Positioned(
              left: 0,
              right: 0,
              top: 0,
              height: artworkHeight,
              child: HeroMode(
                // The compact header owns the route hero while the
                // full cover is fading out behind the lyrics.
                enabled: artwork != null,
                child: AnimatedSwitcher(
                  duration: motion,
                  switchInCurve: Curves.easeInOutCubic,
                  switchOutCurve: Curves.easeInOutCubic,
                  layoutBuilder: (current, previous) => Stack(
                    fit: StackFit.expand,
                    children: [
                      for (final child in previous)
                        HeroMode(enabled: false, child: child),
                      ?current,
                    ],
                  ),
                  child: artwork == null
                      ? null
                      : KeyedSubtree(
                          key: const ValueKey('full-player-artwork'),
                          child: artwork!,
                        ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _GradientTween extends Tween<LinearGradient> {
  _GradientTween({super.end});

  @override
  LinearGradient lerp(double t) => LinearGradient.lerp(begin, end, t)!;
}

/// Fades the artwork into [background] by painting the background over it
/// with the inverse of the fade as alpha. This composites the same pixels as
/// masking the artwork, without an offscreen pass on every raster frame.
class _ArtworkFade extends CustomPainter {
  const _ArtworkFade(this.background, this.top, this.bottom);

  final LinearGradient background;
  final double top;
  final double bottom;

  @override
  void paint(Canvas canvas, Size size) {
    if (bottom <= top) return;
    // Extend slightly past the artwork bottom to ensure the edge is 100% buried
    final bleedBottom = math.max(bottom + 12.0, size.height);
    final rect = Rect.fromLTRB(0, top, size.width, bleedBottom);
    final paint = Paint()..isAntiAlias = false;
    if (background.begin == Alignment.topCenter &&
        background.end == Alignment.bottomCenter) {
      // Non-linear stops that reach full opacity before the bottom edge
      final baseStops = const [0.0, 0.25, 0.50, 0.70, 0.85, 0.92, 1.0];
      final stops = {
        ...baseStops,
        for (final stop in background.stops ?? const <double>[])
          if (stop * size.height > top && stop * size.height < bottom)
            ((stop * size.height - top) / (bottom - top)).clamp(0.0, 1.0),
      }.toList()..sort();
      canvas.drawRect(
        rect,
        paint
          ..shader = ui.Gradient.linear(rect.topCenter, rect.bottomCenter, [
            for (final stop in stops)
              _backgroundAt(
                (top + stop * (bottom - top)) / size.height,
              ).withValues(
                // Reaches full opacity before stop = 0.92, hiding the bottom edge
                alpha: Curves.easeInQuad.transform((stop / 0.92).clamp(0.0, 1.0)),
              ),
          ], stops),
      );
      return;
    }
    // The page transition tilts the gradient, so no single vertical overlay
    // matches it; mask a copy of the background for those frames instead.
    canvas.saveLayer(rect, Paint());
    canvas.drawRect(
      rect,
      paint..shader = background.createShader(Offset.zero & size),
    );
    canvas.drawRect(
      rect,
      paint
        ..blendMode = BlendMode.dstIn
        ..shader = ui.Gradient.linear(
          rect.topCenter,
          Offset(rect.topCenter.dx, bottom),
          const [
            Colors.transparent,
            Color(0x33ffffff),
            Color(0xaaffffff),
            Colors.white,
            Colors.white,
          ],
          const [0.0, 0.35, 0.65, 0.90, 1.0],
        ),
    );
    canvas.restore();
  }

  Color _backgroundAt(double t) {
    final colors = background.colors;
    final stops =
        background.stops ??
        [for (var i = 0; i < colors.length; i++) i / (colors.length - 1)];
    var index = 1;
    while (index < stops.length - 1 && t > stops[index]) {
      index++;
    }
    final span = stops[index] - stops[index - 1];
    return Color.lerp(
      colors[index - 1],
      colors[index],
      span <= 0 ? 1 : ((t - stops[index - 1]) / span).clamp(0.0, 1.0),
    )!;
  }

  @override
  bool? hitTest(Offset position) => false;

  @override
  bool shouldRepaint(_ArtworkFade oldDelegate) =>
      background != oldDelegate.background ||
      top != oldDelegate.top ||
      bottom != oldDelegate.bottom;
}
