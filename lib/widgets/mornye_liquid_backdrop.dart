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
    required this.child,
    this.tint,
    this.blurSigma,
    this.density = 1,
    this.interaction = false,
    this.progress = 1,
    this.refractionDepth = 0.30,
    this.refractiveIndex,
    this.pinch = 0,
    this.smoothCorners = false,
    this.highlightIntensity = 1,
  });

  /// The package's material for resting glass, calibrated against iOS 27.
  static LiquidGlassSettings material(Brightness brightness) =>
      brightness == Brightness.dark ? _dark : LiquidGlassSettings.ios27Light;

  // iOS turns the labels on dark glass dark over a bright backdrop. Mornye's
  // stay white, so its dark glass pulls a bright backdrop down further.
  static final _dark = LiquidGlassSettings.ios27Dark.copyWith(bodyShade: 0.55);

  /// The package keeps Windows and Linux off its refracting shaders, which
  /// their graphics layers compile slowly or not at all.
  static GlassQuality get quality => switch (defaultTargetPlatform) {
    TargetPlatform.windows || TargetPlatform.linux => GlassQuality.standard,
    _ => GlassQuality.premium,
  };

  final BorderRadius borderRadius;

  /// Mornye's own color for the glass, laid over the backdrop exactly as
  /// given. Null keeps the material's color and body.
  final Color? tint;

  /// Null keeps the material's blur.
  final double? blurSigma;

  /// How much of the material's frost stays: 1 is the material as calibrated,
  /// less is clearer glass. Its color stays, which keeps labels readable.
  final double density;
  final Widget child;

  /// A lens held over other glass, such as a selection under a finger. It
  /// comes in with [progress] and is absent at zero.
  final bool interaction;
  final double progress;
  final double refractionDepth;

  /// Null keeps the material's refractive index.
  final double? refractiveIndex;

  /// How far a held lens draws its backdrop in from its ends, from 0 to 1.
  final double pinch;
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
    final tint = this.tint;
    return GlassWindowSpace(
      builder: (context, scale) {
        final radius = borderRadius.topLeft.x * scale;
        final settings = base.copyWith(
          visibility: effect,
          glassColor: tint,
          // The adaptive body keeps the backdrop's brightness under a
          // tint, which would undo the dimming that keeps labels readable.
          bodyMode: tint == null ? base.bodyMode : GlassBodyMode.clear,
          blur: (blurSigma ?? base.blur) * scale,
          frost: base.frost * density * scale,
          thickness: base.thickness * scale * refractionDepth / 0.30,
          refractiveIndex: refractiveIndex,
          rimLight: base.rimLight * rim,
          rimShade: base.rimShade * rim,
          // The caller draws one shadow for every glass level.
          shadow: const [],
        );
        // The caller has already weighed contrast against the user's settings.
        return GlassAccessibilityScope(
          reduceTransparency: false,
          child: AdaptiveGlass(
            quality: quality,
            shape: smoothCorners
                ? LiquidRoundedSuperellipse(borderRadius: radius)
                : LiquidRoundedRectangle(borderRadius: radius),
            // The package's own switch pinches its lens the same way.
            settings: pinch > 0 ? settings.copyWithPinch(pinch) : settings,
            child: GlassWindowSpace.content(child: child),
          ),
        );
      },
    );
  }
}
