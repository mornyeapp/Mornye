import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';
import 'package:mornye/theme/app_motion.dart';
import 'package:mornye/theme/cover_palette.dart';

/// The player's background for a cover whose average is [sourceColor]: the
/// same two muted tones on every page, so the controls keep their surface
/// when lyrics or the queue open. With [fullBleed] they run straight down,
/// behind the artwork and the controls; otherwise across the page.
LinearGradient mornyePlayerGradient(
  Color? sourceColor, {
  required bool fullBleed,
}) {
  final dominant = HSLColor.fromColor(sourceColor ?? const Color(0xff808080));
  // Bright and mid covers keep their tones. Darker ones go darker with the
  // cover, so a black cover ends near black rather than on a gray surface.
  final depth = ui.lerpDouble(
    0.1,
    1,
    (dominant.lightness / 0.35).clamp(0.0, 1.0),
  )!;
  final muted = dominant.withSaturation(dominant.saturation.clamp(0.0, 0.34));
  return LinearGradient(
    // Straight down under the artwork, whose fade into it is then a single
    // vertical overlay (see [_ArtworkFade]).
    begin: fullBleed ? Alignment.topCenter : Alignment.topLeft,
    end: fullBleed ? Alignment.bottomCenter : Alignment.bottomRight,
    colors: [
      muted.withLightness((0.28 + dominant.lightness * 0.24) * depth).toColor(),
      muted.withLightness((0.14 + dominant.lightness * 0.20) * depth).toColor(),
    ],
  );
}

/// Height of the full-bleed artwork on a screen of [size].
double mornyeArtworkHeight(
  Size size, {
  required bool squareArtwork,
  required double? aspectRatio,
}) => aspectRatio != null && aspectRatio > 0
    ? (size.width / aspectRatio).clamp(0.0, size.height * 0.75)
    : squareArtwork
    ? size.width
    : size.height * 0.66;

/// Opaque cover-derived surface, with full-bleed artwork on the player page
/// and a muted two-tone gradient behind lyrics and the queue.
class MornyePlayerBackground extends StatelessWidget {
  const MornyePlayerBackground({
    super.key,
    required this.artUri,
    this.artwork,
    this.squareArtwork = true,
    this.artworkAspectRatio,
    this.fadeStart = 0.58,
  });

  final Uri? artUri;
  final Widget? artwork;
  final bool squareArtwork;
  final double? artworkAspectRatio;

  /// Fraction of the artwork's height that stays sharp before fading out.
  final double fadeStart;

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
          final motion = mornyePlayerPanelMotion(context);
          final background = mornyePlayerGradient(
            sourceColor,
            fullBleed: artwork != null,
          );
          final artworkHeight = mornyeArtworkHeight(
            MediaQuery.sizeOf(context),
            squareArtwork: squareArtwork,
            aspectRatio: artworkAspectRatio,
          );
          return TweenAnimationBuilder<LinearGradient>(
            tween: _GradientTween(end: background),
            duration: motion.duration,
            curve: motion.curve,
            builder: (context, gradient, artworkLayer) => DecoratedBox(
              decoration: BoxDecoration(gradient: gradient),
              child: Stack(
                fit: StackFit.expand,
                children: [
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
                  duration: motion.duration,
                  switchInCurve: motion.curve,
                  switchOutCurve: motion.leaving,
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

/// The Mornye player's change between the full cover and a panel (lyrics or
/// the queue), and between two covers: the cover, the gradient, the shade
/// and the moving artwork's glow all change together, as content, on the
/// standard spring without bounce. Reduced motion changes them at once.
AppMotionSpec mornyePlayerPanelMotion(BuildContext context) =>
    MediaQuery.disableAnimationsOf(context)
    ? const AppMotionSpec(Duration.zero, Curves.linear)
    : MornyeMotion.standard;

/// How dark [MornyeControlsDim] is at full strength.
const mornyeControlsDimAlpha = 0.4;

/// Keeps the player's white labels readable from the artwork's fade down: a
/// soft dark layer over [MornyePlayerBackground] with the same artwork
/// geometry. Moving artwork has all of it; a still cover has as much as the
/// contrast sample asks for, none while white already reads on it. It stays
/// outside that sample, so it does not change what is read.
class MornyeControlsDim extends StatelessWidget {
  const MornyeControlsDim({
    super.key,
    required this.strength,
    this.squareArtwork = true,
    this.artworkAspectRatio,
    this.fadeStart = 0.58,
  });

  /// From 0 (no layer) to 1 (all of it).
  final double strength;
  final bool squareArtwork;
  final double? artworkAspectRatio;
  final double fadeStart;

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final artworkHeight = mornyeArtworkHeight(
      size,
      squareArtwork: squareArtwork,
      aspectRatio: artworkAspectRatio,
    );
    final start = (artworkHeight * fadeStart / size.height).clamp(0.0, 1.0);
    final end = ((start + artworkHeight / size.height) / 2).clamp(start, 1.0);
    final motion = mornyePlayerPanelMotion(context);
    return IgnorePointer(
      child: TweenAnimationBuilder<double>(
        tween: Tween(end: strength.clamp(0.0, 1.0)),
        duration: motion.duration,
        curve: motion.curve,
        builder: (context, value, _) {
          final alpha = value.clamp(0.0, 1.0);
          if (alpha <= 0) return const SizedBox.shrink();
          return DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                stops: [start, end],
                colors: [
                  Colors.black.withValues(alpha: 0),
                  // 4.5:1 for white over a white frame mid-fade.
                  Colors.black.withValues(
                    alpha: mornyeControlsDimAlpha * alpha,
                  ),
                ],
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
    final rect = Rect.fromLTRB(0, top, size.width, bottom);
    final paint = Paint()..isAntiAlias = false;
    if (background.begin == Alignment.topCenter &&
        background.end == Alignment.bottomCenter) {
      // Stops where either the colour or the alpha changes slope keep both
      // linear between them.
      final stops = {
        0.0,
        1.0,
        for (final stop in background.stops ?? const <double>[])
          if (stop * size.height > top && stop * size.height < bottom)
            (stop * size.height - top) / (bottom - top),
      }.toList()..sort();
      canvas.drawRect(
        rect,
        paint
          ..shader = ui.Gradient.linear(rect.topCenter, rect.bottomCenter, [
            for (final stop in stops)
              _backgroundAt(
                (top + stop * (bottom - top)) / size.height,
              ).withValues(alpha: stop),
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
        ..shader = ui.Gradient.linear(rect.topCenter, rect.bottomCenter, const [
          Colors.transparent,
          Colors.white,
        ]),
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
