import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:mornye/theme/cover_palette.dart';
import 'package:mornye/widgets/material_player_backdrop.dart';

/// The player's background for a cover whose average is [sourceColor]. With
/// [fullBleed] it runs behind the artwork and the controls, otherwise behind
/// lyrics and the queue.
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
  if (fullBleed) {
    // Carry the cover's muted colour through the controls instead of fading
    // bright artwork into a nearly black, flat surface.
    final backdrop = dominant.withSaturation(
      dominant.saturation.clamp(0.0, 0.2),
    );
    return LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      stops: const [0, 0.5, 1],
      colors: [
        backdrop.withLightness(0.62 * depth).toColor(),
        backdrop.withLightness(0.54 * depth).toColor(),
        backdrop.withLightness(0.34 * depth).toColor(),
      ],
    );
  }
  final muted = dominant.withSaturation(dominant.saturation.clamp(0.0, 0.34));
  return LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [
      muted.withLightness((0.28 + dominant.lightness * 0.24) * depth).toColor(),
      muted.withLightness((0.14 + dominant.lightness * 0.20) * depth).toColor(),
    ],
  );
}

/// Height of the full-bleed artwork on a screen of [size].
double _artworkHeight(
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
    this.coverBlur = true,
  });

  final Uri? artUri;
  final Widget? artwork;
  final bool squareArtwork;
  final double? artworkAspectRatio;

  /// Fraction of the artwork's height that stays sharp before fading out.
  final double fadeStart;

  /// Whether the full-bleed cover fades into a blur of itself. Without it,
  /// as where blur effects are off, it fades into the flat gradient.
  final bool coverBlur;

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
          final motion = MediaQuery.disableAnimationsOf(context)
              ? Duration.zero
              : const Duration(milliseconds: 380);
          final background = mornyePlayerGradient(
            sourceColor,
            fullBleed: artwork != null,
          );
          final artworkHeight = _artworkHeight(
            MediaQuery.sizeOf(context),
            squareArtwork: squareArtwork,
            aspectRatio: artworkAspectRatio,
          );
          return TweenAnimationBuilder<LinearGradient>(
            tween: _GradientTween(end: background),
            duration: motion,
            curve: Curves.easeInOutCubic,
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
                  // The cover carries on under the controls as a blur, so
                  // its colours stay around the buttons instead of ending
                  // in one flat tone. The gradient shows until it is ready
                  // and for a song without a cover.
                  AnimatedSwitcher(
                    duration: motion,
                    switchInCurve: Curves.easeInOutCubic,
                    switchOutCurve: Curves.easeInOutCubic,
                    layoutBuilder: (current, previous) => Stack(
                      fit: StackFit.expand,
                      children: [...previous, ?current],
                    ),
                    child: artwork == null || !coverBlur
                        ? const SizedBox.shrink()
                        : _CoverBlur(
                            key: const ValueKey('full-player-blur'),
                            artUri: artUri,
                            top: artworkHeight * fadeStart,
                            bottom: artworkHeight,
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

/// Keeps the player's white labels readable from the artwork's fade down: a
/// soft dark layer over [MornyePlayerBackground] with the same artwork
/// geometry. Moving artwork always has it; a still cover has it when the
/// contrast sample finds a label background too light for white. It stays
/// outside that sample, so turning it on does not change what is read.
class MornyeControlsDim extends StatelessWidget {
  const MornyeControlsDim({
    super.key,
    required this.visible,
    this.squareArtwork = true,
    this.artworkAspectRatio,
    this.fadeStart = 0.58,
  });

  final bool visible;
  final bool squareArtwork;
  final double? artworkAspectRatio;
  final double fadeStart;

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final artworkHeight = _artworkHeight(
      size,
      squareArtwork: squareArtwork,
      aspectRatio: artworkAspectRatio,
    );
    final start = (artworkHeight * fadeStart / size.height).clamp(0.0, 1.0);
    final end = ((start + artworkHeight / size.height) / 2).clamp(start, 1.0);
    return IgnorePointer(
      child: AnimatedOpacity(
        opacity: visible ? 1 : 0,
        duration: MediaQuery.disableAnimationsOf(context)
            ? Duration.zero
            : const Duration(milliseconds: 380),
        curve: Curves.easeInOutCubic,
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              stops: [start, end],
              colors: [
                Colors.black.withValues(alpha: 0),
                // 4.5:1 for white over a white frame mid-fade.
                Colors.black.withValues(alpha: 0.4),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The blurred cover from the artwork's fade down, under a shade that keeps
/// a vivid cover from competing with the controls.
class _CoverBlur extends StatelessWidget {
  const _CoverBlur({
    super.key,
    required this.artUri,
    required this.top,
    required this.bottom,
  });

  final Uri? artUri;
  final double top;
  final double bottom;

  @override
  Widget build(BuildContext context) {
    final height = MediaQuery.sizeOf(context).height;
    return IgnorePointer(
      child: Stack(
        fit: StackFit.expand,
        children: [
          PlayerCoverBlur(
            artUri: artUri?.toString(),
            colorScheme: Theme.of(context).colorScheme,
            // Opaque by the middle of the artwork's own fade, before the
            // flat gradient under it shows as a dull band between the two.
            reveal: (top: top, bottom: (top + bottom) / 2),
          ),
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                stops: [
                  (top / height).clamp(0.0, 1.0),
                  (bottom / height).clamp(0.0, 1.0),
                  1,
                ],
                colors: const [
                  Color(0x00000000),
                  Color(0x2e000000),
                  Color(0x52000000),
                ],
              ),
            ),
          ),
        ],
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
