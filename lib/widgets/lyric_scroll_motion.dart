import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';
import 'package:flutter/physics.dart';

/// One shared clock adds a small, staggered spring to upcoming visible rows.
/// Only painting moves: lyric timings and list extents stay fixed.
class LyricScrollMotion extends StatefulWidget {
  const LyricScrollMotion({
    super.key,
    required this.progress,
    required this.distance,
    required this.rowsAfterFocus,
    required this.child,
    this.enabled = true,
    this.motionRevision = 0,
    this.previousProgress = 1,
  });

  final Animation<double> progress;
  final double distance;
  final int rowsAfterFocus;
  final Widget child;
  final bool enabled;

  /// A new shared scroll preserves each row's unfinished visual displacement.
  final int motionRevision;
  final double previousProgress;

  static const duration = Duration(milliseconds: 800);

  /// The list scroll to a new line. It starts from rest with no acceleration
  /// either and settles without overshoot. A plain critically damped spring
  /// accelerates hardest on its first frame, which read as a jerk, above all
  /// when that frame was late; this one arrives just as soon.
  static const scrollDuration = Duration(milliseconds: 550);
  static final Curve scrollCurve = _SoftSpringCurve(20, scrollDuration);

  // Softer than the scroll, so later rows keep trailing it.
  static final _spring = SpringSimulation(
    SpringDescription.withDampingRatio(mass: 1, stiffness: 121, ratio: 0.85),
    0,
    1,
    0,
  );

  @override
  State<LyricScrollMotion> createState() => _LyricScrollMotionState();
}

class _LyricScrollMotionState extends State<LyricScrollMotion> {
  double _initialOffset = 0;

  double _offset(LyricScrollMotion motion, double progress) {
    if (progress >= 1) return 0;
    final t = progress * LyricScrollMotion.duration.inMilliseconds / 1000;
    final scroll = LyricScrollMotion.scrollCurve.transform(
      (t * 1000 / LyricScrollMotion.scrollDuration.inMilliseconds).clamp(
        0.0,
        1.0,
      ),
    );
    final inherited = _initialOffset * (1 - scroll);
    if (motion.rowsAfterFocus <= 0) return inherited;
    final delay = motion.rowsAfterFocus.clamp(1, 6) * 0.035;
    final following = t <= delay ? 0.0 : LyricScrollMotion._spring.x(t - delay);
    return inherited + motion.distance.clamp(-96, 96) * (scroll - following);
  }

  @override
  void didUpdateWidget(covariant LyricScrollMotion oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.motionRevision != widget.motionRevision) {
      _initialOffset = _offset(oldWidget, widget.previousProgress);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled ||
        (_initialOffset == 0 &&
            (widget.rowsAfterFocus <= 0 || widget.distance == 0)) ||
        MediaQuery.disableAnimationsOf(context)) {
      return widget.child;
    }
    return AnimatedBuilder(
      animation: widget.progress,
      child: widget.child,
      builder: (context, child) {
        return Transform.translate(
          offset: Offset(0, _offset(widget, widget.progress.value)),
          transformHitTests: true,
          child: child,
        );
      },
    );
  }
}

/// Two critically damped springs in a row, the second following the first:
/// position, speed and acceleration all start at zero. Sampled over
/// [duration] and scaled to end exactly at 1. [rate] is in 1/s.
class _SoftSpringCurve extends Curve {
  _SoftSpringCurve(this.rate, Duration duration)
    : _seconds = duration.inMicroseconds / Duration.microsecondsPerSecond {
    _end = _position(_seconds);
  }

  final double rate;
  final double _seconds;
  late final double _end;

  double _position(double seconds) {
    final x = rate * seconds;
    return 1 - math.exp(-x) * (1 + x + x * x / 2);
  }

  @override
  double transformInternal(double t) => _position(t * _seconds) / _end;
}
