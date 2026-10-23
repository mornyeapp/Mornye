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
    final source = artUri?.scheme == 'file'
        ? artUri!.toFilePath()
        : artUri?.toString();

    return Theme(
      // Missing or unreadable covers use neutral gray, not the app's accent.
      data: theme.copyWith(
        colorScheme: theme.colorScheme.copyWith(
          brightness: Brightness.dark,
          primary: const Color(0xff808080),
        ),
      ),
      child: CoverSourceColorBuilder(
        imageSource: source,
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
          return AnimatedContainer(
            duration: motion,
            curve: Curves.easeInOutCubic,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: artwork == null
                    ? Alignment.topLeft
                    : Alignment.topCenter,
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
              ),
            ),
            child: Stack(
              fit: StackFit.expand,
              children: [
                Positioned(
                  left: 0,
                  right: 0,
                  top: 0,
                  height: artworkAspectRatio != null && artworkAspectRatio! > 0
                      ? (MediaQuery.sizeOf(context).width / artworkAspectRatio!)
                            .clamp(
                              0.0,
                              MediaQuery.sizeOf(context).height * 0.75,
                            )
                      : squareArtwork
                      ? MediaQuery.sizeOf(context).width
                      : MediaQuery.sizeOf(context).height * 0.66,
                  child: ShaderMask(
                    blendMode: BlendMode.dstIn,
                    shaderCallback: (bounds) => LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      stops: [0, fadeStart, 1],
                      colors: const [
                        Colors.white,
                        Colors.white,
                        Colors.transparent,
                      ],
                    ).createShader(bounds),
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
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}
