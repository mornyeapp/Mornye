import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';
import 'package:liquid_glass_easy/liquid_glass_easy.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/utils/adaptive_layout.dart';
import 'package:mornye/widgets/legacy_theme_brightness.dart';

/// A bounded package lens without a captured-screen view or a touch ticker.
class MornyeLiquidBackdrop extends StatelessWidget {
  const MornyeLiquidBackdrop({
    super.key,
    required this.borderRadius,
    required this.clarity,
    required this.blurSigma,
    required this.child,
    this.interaction = false,
    this.progress = 1,
    this.refractionDepth = 0.30,
    this.refractionWidth = 20,
    this.smoothCorners = false,
    this.highlightIntensity = 1,
  });

  final BorderRadius borderRadius;
  final double clarity;
  final double blurSigma;
  final Widget child;
  final bool interaction;
  final double progress;
  final double refractionDepth;
  final double refractionWidth;
  final bool smoothCorners;
  final double highlightIntensity;

  @override
  Widget build(BuildContext context) {
    if (interaction && progress <= 0) return child;
    final effect = interaction ? progress : 1.0;
    final outlines = MornyeTheme.glassOutlinesOf(context);
    final dark = Theme.of(context).brightness == Brightness.dark;
    // Match the old optical lens's edge displacement. Version 5 fixes travel
    // at 70 logical pixels and controls bending through the index alone.
    final edgeBend =
        math.sqrt(1 - 1 / (1.7 * 1.7)) *
        refractionWidth *
        refractionDepth *
        effect *
        5 /
        70;
    final index = 1 / math.sqrt(1 - math.pow(edgeBend.clamp(0, 0.95), 2));
    // The lens places its backdrop sample in window pixels, from the window's
    // size and pixel ratio. Under an interface scale the app's own viewport
    // reports scaled ones, which drew the glass that fraction of the way
    // towards the window's corner, away from its own box.
    final uiScale = AdaptiveUiScale.of(context);
    final lens = LegacyThemeBrightness(
      child: LiquidGlassLens(
        style: LiquidGlassStyle(
          shape: LiquidGlassShape(
            cornerStyle: smoothCorners
                ? LiquidGlassCornerStyle.squircle
                : LiquidGlassCornerStyle.roundedRectangle,
            clipQuality: smoothCorners
                ? LiquidGlassClipQuality.exact
                : LiquidGlassClipQuality.roundedRectangle,
            cornerRadius: borderRadius.topLeft.x,
          ),
          specular: LiquidGlassLight.specular(
            thickness: outlines ? 0.75 * 5.4 : 0,
            angle: 0,
            spread: 0.2,
            intensity: outlines
                ? (dark ? 0.25 : 0.12) * effect * highlightIntensity
                : 0,
            color: dark ? Colors.white : const Color(0x88ffffff),
          ),
          glow: LiquidGlassLight.glow(
            thickness: outlines ? 0.75 * 29.4 : 0,
            intensity: outlines ? 0.05 * highlightIntensity : 0,
          ),
          blur: blurSigma,
          refractionIndex: index,
          refractionWidth: refractionWidth,
          // Version 5 expresses the widest colour split in logical pixels.
          dispersion: 1.32 * clarity * effect,
        ),
        child: uiScale == 1 ? child : _AppViewport(child: child),
      ),
    );
    if (uiScale == 1) return lens;
    return _WindowViewport(scale: uiScale, child: lens);
  }
}

/// Gives the lens the window's size and pixel ratio. Only this and
/// [_AppViewport] follow every viewport change, such as a keyboard inset; the
/// lens rebuilds when the two values it reads change.
class _WindowViewport extends StatelessWidget {
  const _WindowViewport({required this.scale, required this.child});

  final double scale;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final viewport = MediaQuery.of(context);
    return _InheritedAppViewport(
      data: viewport,
      child: MediaQuery(
        data: viewport.copyWith(
          size: viewport.size * scale,
          devicePixelRatio: viewport.devicePixelRatio / scale,
        ),
        child: child,
      ),
    );
  }
}

class _InheritedAppViewport extends InheritedWidget {
  const _InheritedAppViewport({required this.data, required super.child});

  final MediaQueryData data;

  @override
  bool updateShouldNotify(_InheritedAppViewport oldWidget) =>
      data != oldWidget.data;
}

/// Restores the app's scaled viewport for what sits on the glass.
class _AppViewport extends StatelessWidget {
  const _AppViewport({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => MediaQuery(
    data: context
        .dependOnInheritedWidgetOfExactType<_InheritedAppViewport>()!
        .data,
    child: child,
  );
}
