import 'package:flutter/physics.dart';
import 'package:flutter/scheduler.dart' show Ticker, TickerCallback;
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

  /// This spec at the pace of [MotionPace].
  AppMotionSpec get paced => MotionPace.timeScale == 1
      ? this
      : AppMotionSpec(MotionPace.duration(duration), curve);
}

/// How fast the app's own motion plays (Settings > Appearance > Animation
/// speed). The presets of [AppMotion] and [MornyeMotion], page pushes, the
/// player's opening and the tab switch follow it. Motion that keeps time
/// with a song (lyrics, the seek bar), a finger's own movement and the
/// framework's built-in component motion do not.
abstract final class MotionPace {
  static double _timeScale = 1;

  /// The factor a designed duration is multiplied by: above 1 is slower.
  static double get timeScale => _timeScale;

  /// Sets the pace from a speed factor, where 2 is twice as fast.
  static set speed(double speed) {
    _timeScale = speed.isFinite && speed > 0 ? 1 / speed : 1;
  }

  static Duration duration(Duration designed) =>
      _timeScale == 1 ? designed : designed * _timeScale;

  /// [designed] with the same shape, played at the pace.
  static SpringDescription spring(SpringDescription designed) => _timeScale == 1
      ? designed
      : SpringDescription(
          mass: designed.mass,
          stiffness: designed.stiffness / (_timeScale * _timeScale),
          damping: designed.damping / _timeScale,
        );
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

/// The time at which [curve], which must only rise, reaches [value].
double curveTimeFor(Curve curve, double value) {
  if (value <= 0) return 0;
  if (value >= 1) return 1;
  var low = 0.0;
  var high = 1.0;
  for (var i = 0; i < 24; i++) {
    final middle = (low + high) / 2;
    if (curve.transform(middle) < value) {
      low = middle;
    } else {
      high = middle;
    }
  }
  return (low + high) / 2;
}

/// Ticks that leave out the time a transition's first frames took.
///
/// A new page's first frames are its heaviest, and a ticker counts the time
/// they took: the next frame would show the transition already well under
/// way. Here a late frame among a run's first counts as one frame, so the
/// transition starts late and plays whole.
class SteadyStartTicks implements TickerProvider {
  const SteadyStartTicks(this.vsync);

  final TickerProvider vsync;

  /// A frame is late when it brings more than this many frames at once.
  static const double _late = 2.5;

  /// Only this many frames of a run can be late. Frames that stay slow
  /// after them are the device's pace, and waiting for each would drag.
  static const int _first = 3;

  static Duration get _frame {
    final views = WidgetsBinding.instance.platformDispatcher.views;
    final rate = views.isEmpty ? 0.0 : views.first.display.refreshRate;
    return Duration(microseconds: (1e6 / (rate > 0 ? rate : 60)).round());
  }

  @override
  Ticker createTicker(TickerCallback onTick) {
    var last = Duration.zero;
    var leftOut = Duration.zero;
    var frames = 0;
    return vsync.createTicker((elapsed) {
      // A run that starts again counts from zero.
      if (elapsed < last) {
        last = Duration.zero;
        leftOut = Duration.zero;
        frames = 0;
      }
      final frame = _frame;
      final step = elapsed - last;
      last = elapsed;
      if (step > Duration.zero) frames++;
      if (frames <= _first && step > frame * _late) leftOut += step - frame;
      onTick(elapsed - leftOut);
    });
  }
}

/// A route whose transition waits out its own slow first frames, on
/// [SteadyStartTicks].
mixin SteadyStartRoute<T> on TransitionRoute<T> {
  @override
  AnimationController createAnimationController() => AnimationController(
    duration: transitionDuration,
    reverseDuration: reverseTransitionDuration,
    debugLabel: debugLabel,
    vsync: SteadyStartTicks(navigator!),
  );
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

  static final SpringDescription _fastSpring = _spring(250);
  static final SpringDescription _standardSpring = _spring(350);
  static final SpringDescription _slowSpring = _spring(500);
  static final SpringDescription _snappySpring = _spring(350, 0.15);
  static final SpringDescription _glassPressSpring = _spring(300, 0.25);
  static final SpringDescription _glassMorphSpring = _spring(480, 0.22);
  static final SpringDescription _effectsFastSpring = _spring(150);
  static final SpringDescription _effectsSpring = _spring(250);

  /// Small controls: a press, a check, a chip, a hover.
  static SpringDescription get fastSpring => MotionPace.spring(_fastSpring);

  /// Content that moves or resizes: rows, panels, a selection.
  static SpringDescription get standardSpring =>
      MotionPace.spring(_standardSpring);

  /// Full-screen surfaces, at the pace of the system's default spring.
  static SpringDescription get slowSpring => MotionPace.spring(_slowSpring);

  /// A control with a physical feel that lands with a slight bounce, as the
  /// system's `snappy` spring: a selection pill, a switch thumb. Not for a
  /// surface whose size resizes other content.
  static SpringDescription get snappySpring => MotionPace.spring(_snappySpring);

  /// Tactile Liquid Glass press and release: responsive swell with crisp
  /// elastic rebound, sitting between Apple's `snappy` and `bouncy` presets.
  static SpringDescription get glassPressSpring =>
      MotionPace.spring(_glassPressSpring);

  /// Liquid Glass surface morph: folding bars and pouring menus that expand
  /// smoothly and settle with a subtle ~2% glass overshoot.
  static SpringDescription get glassMorphSpring =>
      MotionPace.spring(_glassMorphSpring);

  /// Opacity and color of small controls.
  static SpringDescription get effectsFastSpring =>
      MotionPace.spring(_effectsFastSpring);

  /// Opacity and color of content.
  static SpringDescription get effectsSpring =>
      MotionPace.spring(_effectsSpring);

  static AppMotionSpec _spec(SpringDescription spring) {
    final curve = SpringCurve.of(spring);
    return AppMotionSpec(curve.duration, curve);
  }

  static final AppMotionSpec _fast = _spec(_fastSpring);
  static final Curve _fastLeaving = _fast.leaving;
  static final AppMotionSpec _standard = _spec(_standardSpring);
  static final AppMotionSpec _slow = _spec(_slowSpring);
  static final AppMotionSpec _snappy = _spec(_snappySpring);
  static final AppMotionSpec _glassPress = _spec(_glassPressSpring);
  static final AppMotionSpec _glassMorph = _spec(_glassMorphSpring);
  static final AppMotionSpec _effectsFast = _spec(_effectsFastSpring);
  static final AppMotionSpec _effects = _spec(_effectsSpring);

  static AppMotionSpec get fast => _fast.paced;
  static Curve get fastLeaving => _fastLeaving;
  static AppMotionSpec get standard => _standard.paced;
  static AppMotionSpec get slow => _slow.paced;
  static AppMotionSpec get snappy => _snappy.paced;
  static AppMotionSpec get glassPress => _glassPress.paced;
  static AppMotionSpec get glassMorph => _glassMorph.paced;
  static AppMotionSpec get effectsFast => _effectsFast.paced;
  static AppMotionSpec get effects => _effects.paced;
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
  static final Curve _spatialSlowLeaving = _spatialSlow.flipped;
  static final _effectsFast = SpringCurve(M3EMotion.effectsFast);
  static final _effectsDefault = SpringCurve(M3EMotion.effectsDefault);

  static AppMotionSpec _spec(SpringCurve curve) =>
      AppMotionSpec(MotionPace.duration(curve.duration), curve);

  static final _spatialStandard = SpringCurve(M3EMotion.spatialDefault);
  static final AppMotionSpec _materialPage = AppMotionSpec(
    _spatialStandard.duration,
    _spatialStandard,
  );

  /// Material's standard spatial spring, for a surface as large as a page:
  /// its overshoot is a thousandth of the travel, where the expressive
  /// springs would push a page past its own bounds.
  static AppMotionSpec get materialPage => _materialPage.paced;

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

  /// Entrance and exit for sheets and popup menus. Both styles use their
  /// critically damped full-screen spring on entrance so surfaces never
  /// overshoot their bounds, and dismiss fastest-first on their leaving curve.
  /// Reduced motion removes the transition.
  static AnimationStyle? surfaceEntrance(BuildContext context) {
    if (MediaQuery.disableAnimationsOf(context)) {
      return AnimationStyle.noAnimation;
    }
    if (context.isMornye) {
      final enter = MornyeMotion.slow;
      final exit = MornyeMotion.fast;
      return AnimationStyle(
        duration: enter.duration,
        curve: enter.curve,
        reverseDuration: exit.duration,
        reverseCurve: MornyeMotion.fastLeaving,
      );
    }
    if (materialExpressiveEnabled(context)) {
      return AnimationStyle(
        duration: MotionPace.duration(_spatialSlow.duration),
        curve: _spatialSlow,
        reverseDuration: MotionPace.duration(const Duration(milliseconds: 200)),
        reverseCurve: _spatialSlowLeaving,
      );
    }
    return null;
  }
}
