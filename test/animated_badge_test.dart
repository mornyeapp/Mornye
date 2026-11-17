import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/theme/app_motion.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/widgets/animation_utils.dart';

void main() {
  Future<void> pumpBadge(
    WidgetTester tester, {
    required int count,
    bool mornye = false,
    bool reducedMotion = false,
  }) => tester.pumpWidget(
    MaterialApp(
      theme: mornye ? MornyeTheme.build(Brightness.light) : ThemeData(),
      home: MediaQuery(
        data: MediaQueryData(disableAnimations: reducedMotion),
        child: Center(
          child: AnimatedBadge(count: count, child: Text('$count')),
        ),
      ),
    ),
  );

  double scale(WidgetTester tester) => tester
      .widget<ScaleTransition>(
        find.descendant(
          of: find.byType(AnimatedBadge),
          matching: find.byType(ScaleTransition),
        ),
      )
      .scale
      .value;

  testWidgets('reduced motion shows a new count without a bump', (
    tester,
  ) async {
    for (final mornye in [false, true]) {
      await pumpBadge(tester, count: 1, mornye: mornye, reducedMotion: true);
      await pumpBadge(tester, count: 2, mornye: mornye, reducedMotion: true);
      for (var frame = 0; frame < 30; frame++) {
        expect(scale(tester), 1);
        await tester.pump(const Duration(milliseconds: 16));
      }
      await tester.pumpWidget(const SizedBox());
    }
  });

  /// Pumps frames until the bump settles and returns the lowest and highest
  /// scales seen.
  Future<(double, double)> track(WidgetTester tester) async {
    var low = scale(tester);
    var high = low;
    for (var frame = 0; frame < 60; frame++) {
      await tester.pump(const Duration(milliseconds: 8));
      low = math.min(low, scale(tester));
      high = math.max(high, scale(tester));
    }
    await tester.pumpAndSettle();
    return (low, high);
  }

  testWidgets('the bump keeps its height at every Animation speed', (
    tester,
  ) async {
    addTearDown(() => MotionPace.speed = 1);
    for (final speed in [0.5, 2.0, 1.0]) {
      MotionPace.speed = speed;
      for (final mornye in [true, false]) {
        await pumpBadge(tester, count: 1, mornye: mornye);
        await pumpBadge(tester, count: 2, mornye: mornye);
        final (_, high) = await track(tester);
        expect(
          high,
          closeTo(1 + AnimatedBadge.bumpHeight, 0.01),
          reason: 'speed $speed, mornye $mornye',
        );
        await tester.pumpWidget(const SizedBox());
      }
    }
  });

  testWidgets('Material pushes from 1 on its fast spatial spring', (
    tester,
  ) async {
    await pumpBadge(tester, count: 1);
    expect(scale(tester), 1);
    await pumpBadge(tester, count: 2);
    // The bump starts from the scale on screen, not from its peak.
    expect(scale(tester), 1);
    final (low, high) = await track(tester);
    expect(high, closeTo(1 + AnimatedBadge.bumpHeight, 0.01));
    // The expressive spring dips slightly below rest on the way back.
    expect(low, lessThan(1));
    expect(scale(tester), 1);

    // A lower count does not bump.
    await pumpBadge(tester, count: 1);
    expect(scale(tester), 1);
  });

  testWidgets('Mornye pushes on its fast spring without a bounce', (
    tester,
  ) async {
    await pumpBadge(tester, count: 1, mornye: true);
    await pumpBadge(tester, count: 2, mornye: true);
    expect(scale(tester), 1);
    final (low, high) = await track(tester);
    expect(high, closeTo(1 + AnimatedBadge.bumpHeight, 0.01));
    expect(low, greaterThanOrEqualTo(1 - 1e-6));
    expect(scale(tester), 1);
  });

  testWidgets('a count that grows mid-bump goes on from the scale on screen', (
    tester,
  ) async {
    for (final mornye in [false, true]) {
      await pumpBadge(tester, count: 1, mornye: mornye);
      await pumpBadge(tester, count: 2, mornye: mornye);
      await tester.pump(const Duration(milliseconds: 16));
      await tester.pump(const Duration(milliseconds: 16));
      final before = scale(tester);
      expect(before, greaterThan(1.05));

      await pumpBadge(tester, count: 3, mornye: mornye);
      expect(scale(tester), before);
      var previous = before;
      for (var frame = 0; frame < 3; frame++) {
        await tester.pump(const Duration(milliseconds: 8));
        // No restart from 1: each frame moves on from the last one.
        expect(scale(tester), greaterThan(1.05));
        expect((scale(tester) - previous).abs(), lessThan(0.1));
        previous = scale(tester);
      }
      await tester.pumpAndSettle();
      expect(scale(tester), 1);
      await tester.pumpWidget(const SizedBox());
    }
  });
}
