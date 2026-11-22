import 'package:flutter/gestures.dart' show kMinFlingVelocity;
import 'package:flutter/widgets.dart';

/// The bounce at both ends of a list, with Android's own glide between them.
///
/// The bounce's glide is the iPhone's: it carries a slow flick further than
/// Android does and a fast one only about half as far, so a long list felt
/// heavy beside the platform's own lists. Here a flick travels as far and as
/// long as it does there, and still bounces where the list ends.
class AndroidGlideScrollPhysics extends BouncingScrollPhysics {
  const AndroidGlideScrollPhysics({super.parent});

  @override
  AndroidGlideScrollPhysics applyTo(ScrollPhysics? ancestor) =>
      AndroidGlideScrollPhysics(parent: buildParent(ancestor));

  // The platform's lists fling from a slower flick than the bounce asks
  // for, and do not add one flick's speed to the next.
  @override
  double get minFlingVelocity => kMinFlingVelocity;

  @override
  double carriedMomentum(double existingVelocity) => 0;

  @override
  Simulation? createBallisticSimulation(
    ScrollMetrics position,
    double velocity,
  ) {
    final tolerance = toleranceFor(position);
    // Past an end, or at rest: the bounce's own way back.
    if (position.outOfRange || velocity.abs() < tolerance.velocity) {
      return super.createBallisticSimulation(position, velocity);
    }
    return _GlideThenBounce(
      position: position.pixels,
      velocity: velocity,
      leadingExtent: position.minScrollExtent,
      trailingExtent: position.maxScrollExtent,
      spring: spring,
      tolerance: tolerance,
    );
  }
}

/// Android's glide until it reaches an end of the list, then the bounce's
/// spring from there at the speed the glide still had.
class _GlideThenBounce extends Simulation {
  _GlideThenBounce({
    required double position,
    required double velocity,
    required double leadingExtent,
    required double trailingExtent,
    required SpringDescription spring,
    super.tolerance,
  }) : _glide = ClampingScrollSimulation(
         position: position,
         velocity: velocity,
         tolerance: tolerance,
       ) {
    final rest = _glide.x(double.maxFinite);
    final double end;
    if (rest > trailingExtent) {
      end = trailingExtent;
    } else if (rest < leadingExtent) {
      end = leadingExtent;
    } else {
      return;
    }
    // The glide only moves one way: halve toward the time it crosses the end.
    var before = 0.0;
    var after = 0.1;
    while (!_glide.isDone(after)) {
      after *= 2;
    }
    final forward = velocity > 0;
    for (var i = 0; i < 32; i++) {
      final middle = (before + after) / 2;
      if ((_glide.x(middle) < end) == forward) {
        before = middle;
      } else {
        after = middle;
      }
    }
    _bounceAt = after;
    _bounce = ScrollSpringSimulation(
      spring,
      end,
      end,
      _glide.dx(after),
      tolerance: tolerance,
    );
  }

  final ClampingScrollSimulation _glide;
  ScrollSpringSimulation? _bounce;
  double _bounceAt = double.infinity;

  @override
  double x(double time) =>
      time < _bounceAt ? _glide.x(time) : _bounce!.x(time - _bounceAt);

  @override
  double dx(double time) =>
      time < _bounceAt ? _glide.dx(time) : _bounce!.dx(time - _bounceAt);

  @override
  bool isDone(double time) => _bounce == null
      ? _glide.isDone(time)
      : time >= _bounceAt && _bounce!.isDone(time - _bounceAt);
}
