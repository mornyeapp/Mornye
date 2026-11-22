import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/theme/app_scroll_physics.dart';

void main() {
  const physics = AndroidGlideScrollPhysics();

  ScrollMetrics list({double at = 2000, double length = 100000}) =>
      FixedScrollMetrics(
        minScrollExtent: 0,
        maxScrollExtent: length,
        pixels: at,
        viewportDimension: 800,
        axisDirection: AxisDirection.down,
        devicePixelRatio: 3,
      );

  /// Where a simulation comes to rest, and the furthest it went on the way.
  ({double rest, double furthest}) run(Simulation simulation) {
    var time = 0.0;
    var furthest = simulation.x(0);
    while (!simulation.isDone(time)) {
      time += 1 / 120;
      final x = simulation.x(time);
      if (x > furthest) furthest = x;
      expect(time, lessThan(30), reason: 'the simulation never ends');
    }
    return (rest: simulation.x(time), furthest: furthest);
  }

  test('a flick travels as far as it does in an Android list', () {
    for (final velocity in [1500.0, 3000.0, 6000.0, 8000.0, -6000.0]) {
      final metrics = list(at: 50000);
      final android = ClampingScrollSimulation(
        position: metrics.pixels,
        velocity: velocity,
      );
      final glide = physics.createBallisticSimulation(metrics, velocity)!;
      expect(
        run(glide).rest,
        moreOrLessEquals(android.x(double.maxFinite), epsilon: 0.5),
      );
      // And at the same pace on the way.
      for (final time in [0.05, 0.2, 0.6, 1.5]) {
        expect(glide.x(time), moreOrLessEquals(android.x(time), epsilon: 0.01));
        expect(
          glide.dx(time),
          moreOrLessEquals(android.dx(time), epsilon: 0.01),
        );
      }
    }
  });

  test('a fast flick goes further than the bounce carries it', () {
    final metrics = list();
    final bounce = const BouncingScrollPhysics().createBallisticSimulation(
      metrics,
      8000,
    )!;
    final glide = physics.createBallisticSimulation(metrics, 8000)!;
    expect(
      run(glide).rest - 2000,
      greaterThan((run(bounce).rest - 2000) * 1.5),
    );
  });

  test('a flick that reaches the end bounces there', () {
    final metrics = list(at: 9000, length: 10000);
    final glide = physics.createBallisticSimulation(metrics, 6000)!;
    final result = run(glide);
    expect(result.furthest, greaterThan(10010));
    expect(result.rest, moreOrLessEquals(10000, epsilon: 1));
    // The speed does not jump where the spring takes over.
    var last = glide.dx(0);
    for (var time = 0.001; time < 1; time += 0.001) {
      final speed = glide.dx(time);
      expect((speed - last).abs(), lessThan(0.1 * last.abs() + 60));
      last = speed;
    }

    final back = physics.createBallisticSimulation(list(at: 600), -6000)!;
    expect(run(back).rest, moreOrLessEquals(0, epsilon: 1));
  });

  test('a list pulled past its end comes back as the bounce does', () {
    final past = list(at: 10080, length: 10000);
    final simulation = physics.createBallisticSimulation(past, 0)!;
    expect(simulation, isA<BouncingScrollSimulation>());
    expect(run(simulation).rest, moreOrLessEquals(10000, epsilon: 1));
  });

  test('a list at rest stays where it is', () {
    expect(physics.createBallisticSimulation(list(), 0), isNull);
  });

  test('one flick does not add its speed to the next', () {
    expect(physics.carriedMomentum(8000), 0);
    expect(const BouncingScrollPhysics().carriedMomentum(8000), greaterThan(0));
  });

  test('stays itself under a parent, and is still a bounce', () {
    final applied = physics.applyTo(const AlwaysScrollableScrollPhysics());
    expect(applied, isA<AndroidGlideScrollPhysics>());
    expect(applied, isA<BouncingScrollPhysics>());
    expect(applied.parent, isA<AlwaysScrollableScrollPhysics>());
  });
}
