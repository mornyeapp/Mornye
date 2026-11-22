import 'package:flutter/foundation.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/widgets/glass_window_space.dart';

/// One bounded surface of the glass package at its premium quality. Callers
/// decide whether the device and the user's settings allow it.
class MornyeLiquidBackdrop extends StatelessWidget {
  const MornyeLiquidBackdrop({
    super.key,
    required this.borderRadius,
    required this.tint,
    required this.blurSigma,
    required this.child,
    this.interaction = false,
    this.progress = 1,
    this.refractionDepth = 0.30,
    this.smoothCorners = false,
    this.highlightIntensity = 1,
  });

  /// The package's material for resting glass, calibrated against iOS 27.
  static LiquidGlassSettings material(Brightness brightness) =>
      brightness == Brightness.dark
      ? LiquidGlassSettings.ios27Dark
      : LiquidGlassSettings.ios27Light;

  /// The package keeps Windows and Linux off its refracting shaders, which
  /// their graphics layers compile slowly or not at all.
  static GlassQuality get quality => switch (defaultTargetPlatform) {
    TargetPlatform.windows || TargetPlatform.linux => GlassQuality.standard,
    _ => GlassQuality.premium,
  };

  final BorderRadius borderRadius;

  /// The glass's own color, laid over the backdrop exactly as given.
  final Color tint;
  final double blurSigma;
  final Widget child;

  /// A lens held over other glass, such as a selection under a finger. It
  /// comes in with [progress] and is absent at zero.
  final bool interaction;
  final double progress;
  final double refractionDepth;
  final bool smoothCorners;
  final double highlightIntensity;

  @override
  Widget build(BuildContext context) {
    if (interaction && progress <= 0) return child;
    final effect = interaction ? progress.clamp(0.0, 1.0) : 1.0;
    final base = interaction
        ? LiquidGlassSettings.ios27Indicator
        : material(Theme.of(context).brightness);
    final rim = MornyeTheme.glassOutlinesOf(context) ? highlightIntensity : 0.0;
    return GlassWindowSpace(
      builder: (context, scale) {
        final radius = borderRadius.topLeft.x * scale;
        // The caller has already weighed contrast against the user's settings.
        return GlassAccessibilityScope(
          reduceTransparency: false,
          child: AdaptiveGlass(
            quality: quality,
            shape: smoothCorners
                ? LiquidRoundedSuperellipse(borderRadius: radius)
                : LiquidRoundedRectangle(borderRadius: radius),
            settings: base.copyWith(
              visibility: effect,
              glassColor: tint,
              // The adaptive body keeps the backdrop's brightness under a
              // tint, which would undo the dimming that keeps labels readable.
              bodyMode: GlassBodyMode.clear,
              blur: blurSigma * scale,
              frost: base.frost * scale,
              thickness: base.thickness * scale * refractionDepth / 0.30,
              rimLight: base.rimLight * rim,
              rimShade: base.rimShade * rim,
              // The caller draws one shadow for every glass level.
              shadow: const [],
            ),
            child: GlassWindowSpace.content(child: child),
          ),
        );
      },
    );
  }
}
