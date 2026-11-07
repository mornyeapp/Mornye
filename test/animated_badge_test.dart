import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
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

  testWidgets('Material settles from 1.15 on a spring', (tester) async {
    await pumpBadge(tester, count: 1);
    expect(scale(tester), 1);
    await pumpBadge(tester, count: 2);
    expect(scale(tester), closeTo(1.15, 0.001));
    await tester.pump(const Duration(milliseconds: 60));
    expect(scale(tester), lessThan(1.15));
    await tester.pumpAndSettle();
    expect(scale(tester), 1);

    // A lower count does not bump.
    await pumpBadge(tester, count: 1);
    expect(scale(tester), 1);
  });

  testWidgets('Mornye keeps its eased bump', (tester) async {
    await pumpBadge(tester, count: 1, mornye: true);
    await pumpBadge(tester, count: 2, mornye: true);
    expect(scale(tester), 1);
    await tester.pump(const Duration(milliseconds: 120));
    expect(scale(tester), closeTo(1.3, 0.01));
    await tester.pumpAndSettle();
    expect(scale(tester), 1);
  });
}
