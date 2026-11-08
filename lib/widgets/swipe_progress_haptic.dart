import 'dart:async';

import 'package:flutter/services.dart';
import 'package:mornye/services/music_haptics.dart';

/// A swipe's haptics that build up toward its commit point.
///
/// As the swipe nears the point where letting go would commit, soft ticks
/// grow stronger at each of [steps]; crossing the point gives one strong,
/// sharp pulse and nothing follows past it. Ticks closer together than
/// [minInterval] are dropped, so a fast swipe never buzzes. Each step, and
/// the commit pulse, arms again once the swipe falls back [hysteresis]
/// below it, so hovering on a boundary stays quiet.
///
/// Pulses go through the native haptics channel as touch feedback
/// ([nativeTouchHapticPulse]), which renders intensity and sharpness and on
/// Android follows the touch feedback setting. Where it is missing or fails,
/// [HapticFeedback] takes over: a selection click per tick and a medium
/// impact at the commit point. Haptics stay on under reduced motion: they
/// replace motion rather than add to it.
class SwipeProgressHaptic {
  SwipeProgressHaptic({
    HapticPulse? pulse,
    Duration Function()? clock,
    this.steps = const [0.3, 0.55, 0.8],
    this.minInterval = const Duration(milliseconds: 70),
    this.hysteresis = 0.1,
  }) : _pulse = pulse ?? nativeTouchHapticPulse,
       _clock = clock ?? _stopwatchClock();

  /// Progress points (0 to 1 of the commit distance) that tick on the way.
  final List<double> steps;

  /// The shortest gap between two ticks.
  final Duration minInterval;

  /// How far below a step or the commit point the swipe must fall before
  /// it ticks there again.
  final double hysteresis;

  final HapticPulse _pulse;
  final Duration Function() _clock;

  static const commitIntensity = 1.0;
  static const commitSharpness = 0.9;

  /// A soft tick's strength at progress [step], rising toward the commit.
  static double tickIntensity(double step) => 0.2 + 0.3 * step;

  /// Ticks stay dull, so the commit pulse reads as different.
  static double tickSharpness(double step) => 0.2 + 0.2 * step;

  late final _passed = List.filled(steps.length, false);
  bool _committed = false;
  Duration? _lastTick;
  bool _nativeFailed = false;

  static Duration Function() _stopwatchClock() {
    final stopwatch = Stopwatch()..start();
    return () => stopwatch.elapsed;
  }

  /// Reports the swipe's travel as a share of its commit distance; 1 or more
  /// means letting go would commit.
  void update(double progress) {
    final value = progress.abs();
    if (_committed && value < 1 - hysteresis) _committed = false;
    for (var i = 0; i < steps.length; i++) {
      if (_passed[i] && value < steps[i] - hysteresis) _passed[i] = false;
    }
    if (value >= 1) {
      // Steps skipped by a fast swipe stay passed without a tick.
      _passed.fillRange(0, _passed.length, true);
      if (_committed) return;
      _committed = true;
      _lastTick = _clock();
      _emit(commitIntensity, commitSharpness, commit: true);
      return;
    }
    // One tick per update, for the furthest step newly reached.
    int? reached;
    for (var i = 0; i < steps.length; i++) {
      if (!_passed[i] && value >= steps[i]) {
        _passed[i] = true;
        reached = i;
      }
    }
    if (reached == null) return;
    final now = _clock();
    final last = _lastTick;
    if (last != null && now - last < minInterval) return;
    _lastTick = now;
    final step = steps[reached];
    _emit(tickIntensity(step), tickSharpness(step), commit: false);
  }

  /// Ends the swipe: the next one starts with every step armed.
  void reset() {
    _passed.fillRange(0, _passed.length, false);
    _committed = false;
    _lastTick = null;
  }

  void _emit(double intensity, double sharpness, {required bool commit}) {
    if (_nativeFailed) {
      _fallback(commit);
      return;
    }
    unawaited(
      _pulse(intensity, sharpness).catchError((Object _) {
        // Missing channel (another platform) or a native error: the
        // system haptics carry the rest of this row's swipes.
        _nativeFailed = true;
        _fallback(commit);
      }),
    );
  }

  static void _fallback(bool commit) {
    unawaited(
      commit ? HapticFeedback.mediumImpact() : HapticFeedback.selectionClick(),
    );
  }
}
