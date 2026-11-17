import 'package:flutter/physics.dart';
import 'package:flutter/widgets.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:mornye/theme/material_expressive.dart';
import 'package:mornye/theme/mornye_theme.dart';

/// A duration and curve pair for implicit animations.
@immutable
class AppMotionSpec {
  const AppMotionSpec(this.duration, this.curve);

  final Duration duration;
  final Curve curve;

  /// [curve] for the child a switcher takes away (`switchOutCurve`, or a
  /// `reverseCurve`). Flutter runs that curve backwards, which would hold a
  /// leaving child in place for most of a spring and drop it at the end;
  /// flipped, the child leaves the way the spec moves, fastest first.
  Curve get leaving => curve.flipped;
}

/// A [Curve] that follows an [M3ESpring] released from rest at 0 toward 1.
///
/// [duration] is the spring's settling time, so implicit animations driven by
/// this curve end exactly when the physical motion does.
class SpringCurve extends Curve {
  SpringCurve(M3ESpring spring) : this.of(spring.toDescription());

  /// The curve of [spring] itself, for a spring that is not an M3E token.
  SpringCurve.of(SpringDescription spring)
    : this._(SpringSimulation(spring, 0, 1, 0));

  SpringCurve._(this._simulation) : duration = _settleTime(_simulation);

  final SpringSimulation _simulation;
  final Duration duration;

  static Duration _settleTime(SpringSimulation simulation) {
    const step = 1 / 1000;
    var settledSince = 0.0;
    for (var t = 0.0; t < 2; t += step) {
      final settled =
          (simulation.x(t) - 1).abs() < 0.002 && simulation.dx(t).abs() < 0.02;
      if (!settled) {
        settledSince = t + step;
      } else if (t - settledSince >= 0.05) {
        break;
      }
    }
    return Duration(microseconds: (settledSince * 1e6).round());
  }

  @override
  double transformInternal(double t) =>
      _simulation.x(t * duration.inMicroseconds / 1e6);
}

/// Apple-style springs for the Mornye theme.
///
/// A spring is named the way SwiftUI's `spring(duration:bounce:)` names it:
/// by the time its motion reads as done and by its bounce. The system's
/// default spring (`smooth`) has no bounce, and so do these, except
/// [snappy]. A spring moves most of the way early and settles in a long,
/// quiet tail, so its [AppMotionSpec.duration] is longer than its name.
abstract final class MornyeMotion {
  static SpringDescription _spring(int milliseconds, [double bounce = 0]) =>
      SpringDescription.withDurationAndBounce(
        duration: Duration(milliseconds: milliseconds),
        bounce: bounce,
      );

  /// Small controls: a press, a check, a chip, a hover.
  static final SpringDescription fastSpring = _spring(250);

  /// Content that moves or resizes: rows, panels, a selection.
  static final SpringDescription standardSpring = _spring(350);

  /// Full-screen surfaces, at the pace of the system's default spring.
  static final SpringDescription slowSpring = _spring(500);

  /// A control with a physical feel that lands with a slight bounce, as the
  /// system's `snappy` spring: a selection pill, a switch thumb. Not for a
  /// surface whose size resizes other content.
  static final SpringDescription snappySpring = _spring(350, 0.15);

  /// Opacity and color of small controls.
  static final SpringDescription effectsFastSpring = _spring(150);

  /// Opacity and color of content.
  static final SpringDescription effectsSpring = _spring(250);

  static AppMotionSpec _spec(SpringDescription spring) {
    final curve = SpringCurve.of(spring);
    return AppMotionSpec(curve.duration, curve);
  }

  static final AppMotionSpec fast = _spec(fastSpring);
  static final AppMotionSpec standard = _spec(standardSpring);
  static final AppMotionSpec slow = _spec(slowSpring);
  static final AppMotionSpec snappy = _spec(snappySpring);
  static final AppMotionSpec effectsFast = _spec(effectsFastSpring);
  static final AppMotionSpec effects = _spec(effectsSpring);
}

/// The app's motion presets, by theme.
///
/// Material follows Material 3 Expressive: spatial springs (position, size,
/// scale) overshoot slightly; effects springs (opacity, color) settle
/// without overshoot. Mornye follows the Apple guidelines with the
/// [MornyeMotion] spring of the same role, which does not overshoot.
///
/// Reduced motion keeps each call site's `fallback`, and so does Mornye
/// where the fallback has no length: such a site does not animate outside
/// Material. A site that needs its own Mornye motion passes `mornye`.
abstract final class AppMotion {
  static final _spatialFast = SpringCurve(M3EMotion.expressiveSpatialFast);
  static final _spatialDefault = SpringCurve(
    M3EMotion.expressiveSpatialDefault,
  );
  static final _spatialSlow = SpringCurve(M3EMotion.expressiveSpatialSlow);
  static final _effectsFast = SpringCurve(M3EMotion.effectsFast);
  static final _effectsDefault = SpringCurve(M3EMotion.effectsDefault);

  static AppMotionSpec _spec(SpringCurve curve) =>
      AppMotionSpec(curve.duration, curve);

  /// Material's standard spatial spring, for a surface as large as a page:
  /// its overshoot is a thousandth of the travel, where the expressive
  /// springs would push a page past its own bounds.
  static final AppMotionSpec materialPage = _spec(
    SpringCurve(M3EMotion.spatialDefault),
  );

  static const _still = AppMotionSpec(Duration.zero, Curves.linear);

  /// A move that must stop at its end: a section that opens above other
  /// content, a card that unfolds, a scroll most of a page long. Material's
  /// standard spatial spring and Mornye's standard spring, neither of which
  /// passes its target; nothing with reduced motion.
  static AppMotionSpec surface(BuildContext context) {
    if (MediaQuery.disableAnimationsOf(context)) return _still;
    return context.isMornye ? MornyeMotion.standard : materialPage;
  }

  static AppMotionSpec _resolve(
    BuildContext context,
    AppMotionSpec fallback,
    SpringCurve material,
    AppMotionSpec apple,
    AppMotionSpec? mornye,
  ) {
    if (MediaQuery.disableAnimationsOf(context)) return fallback;
    if (!context.isMornye) return _spec(material);
    if (mornye != null) return mornye;
    return fallback.duration == Duration.zero ? fallback : apple;
  }

  /// Fast spatial spring for small components: chips, checks, buttons.
  static AppMotionSpec spatialFast(
    BuildContext context,
    AppMotionSpec fallback, {
    AppMotionSpec? mornye,
  }) => _resolve(context, fallback, _spatialFast, MornyeMotion.fast, mornye);

  /// Default spatial spring for list items, panels and content changes.
  static AppMotionSpec spatial(
    BuildContext context,
    AppMotionSpec fallback, {
    AppMotionSpec? mornye,
  }) => _resolve(
    context,
    fallback,
    _spatialDefault,
    MornyeMotion.standard,
    mornye,
  );

  /// Slow spatial spring for full-screen surfaces such as the player.
  static AppMotionSpec spatialSlow(
    BuildContext context,
    AppMotionSpec fallback, {
    AppMotionSpec? mornye,
  }) => _resolve(context, fallback, _spatialSlow, MornyeMotion.slow, mornye);

  /// Fast effects spring for opacity and color.
  static AppMotionSpec effectsFast(
    BuildContext context,
    AppMotionSpec fallback, {
    AppMotionSpec? mornye,
  }) => _resolve(
    context,
    fallback,
    _effectsFast,
    MornyeMotion.effectsFast,
    mornye,
  );

  /// Default effects spring for opacity and color.
  static AppMotionSpec effects(
    BuildContext context,
    AppMotionSpec fallback, {
    AppMotionSpec? mornye,
  }) => _resolve(
    context,
    fallback,
    _effectsDefault,
    MornyeMotion.effects,
    mornye,
  );

  /// Entrance for sheets and menus. The slow spatial spring is critically
  /// damped, so a surface never overshoots its own size and reveals what is
  /// behind it. Null keeps the platform transition.
  static AnimationStyle? surfaceEntrance(BuildContext context) =>
      materialExpressiveEnabled(context)
      ? AnimationStyle(
          duration: _spatialSlow.duration,
          curve: _spatialSlow,
          reverseDuration: const Duration(milliseconds: 200),
        )
      : null;
}
