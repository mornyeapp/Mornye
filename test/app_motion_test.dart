import 'package:flutter/physics.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:mornye/theme/app_motion.dart';
import 'package:mornye/theme/app_theme.dart';
import 'package:mornye/theme/mornye_theme.dart';

void main() {
  test('spring curves start at rest and settle within their duration', () {
    for (final spring in [
      M3EMotion.expressiveSpatialFast,
      M3EMotion.expressiveSpatialDefault,
      M3EMotion.expressiveSpatialSlow,
      M3EMotion.effectsFast,
      M3EMotion.effectsDefault,
    ]) {
      final curve = SpringCurve(spring);
      expect(curve.transform(0), 0);
      expect(curve.transform(1), 1);
      expect(curve.transform(0.98), closeTo(1, 0.01));
      expect(curve.duration.inMilliseconds, inInclusiveRange(100, 1200));
    }
  });

  test('spatial springs overshoot while effects springs do not', () {
    double peak(SpringCurve curve) => [
      for (var t = 0.0; t <= 1; t += 0.01) curve.transform(t),
    ].reduce((a, b) => a > b ? a : b);

    expect(
      peak(SpringCurve(M3EMotion.expressiveSpatialDefault)),
      greaterThan(1),
    );
    expect(peak(SpringCurve(M3EMotion.effectsDefault)), lessThanOrEqualTo(1));
  });

  test('a leaving child goes the way the spring moves, fastest first', () {
    for (final spec in [
      MornyeMotion.standard,
      MornyeMotion.effects,
      AppMotionSpec(
        SpringCurve(M3EMotion.effectsDefault).duration,
        SpringCurve(M3EMotion.effectsDefault),
      ),
    ]) {
      // A switcher runs the leaving curve from 1 down to 0: a quarter of the
      // way through the time it reads the curve at 0.75.
      final shown = spec.leaving.transform(0.75);
      expect(shown, closeTo(1 - spec.curve.transform(0.25), 1e-9));
      expect(shown, lessThan(0.6));
      // The entrance curve run backwards would still show nearly all of it.
      expect(spec.curve.transform(0.75), greaterThan(0.9));
      expect(spec.leaving.transform(1), 1);
      expect(spec.leaving.transform(0), 0);
    }
  });

  test('Mornye springs settle without overshoot, except the snappy one', () {
    double peak(AppMotionSpec spec) => [
      for (var t = 0.0; t <= 1; t += 0.005) spec.curve.transform(t),
    ].reduce((a, b) => a > b ? a : b);

    for (final spec in [
      MornyeMotion.fast,
      MornyeMotion.standard,
      MornyeMotion.slow,
      MornyeMotion.effectsFast,
      MornyeMotion.effects,
    ]) {
      expect(spec.curve.transform(0), 0);
      expect(spec.curve.transform(1), 1);
      expect(peak(spec), lessThanOrEqualTo(1));
      expect(spec.duration.inMilliseconds, inInclusiveRange(150, 800));
    }
    expect(peak(MornyeMotion.snappy), inExclusiveRange(1, 1.05));
    // Most of the way early: a spring is not a slow ease.
    expect(MornyeMotion.standard.curve.transform(0.5), greaterThan(0.9));
    expect(
      MornyeMotion.fast.duration,
      lessThan(MornyeMotion.standard.duration),
    );
    expect(
      MornyeMotion.standard.duration,
      lessThan(MornyeMotion.slow.duration),
    );
  });

  const eased = AppMotionSpec(Duration(milliseconds: 250), Curves.easeOutCubic);

  Future<AppMotionSpec> resolve(
    WidgetTester tester, {
    required ThemeData theme,
    bool reduceMotion = false,
    AppMotionSpec fallback = eased,
    AppMotionSpec? mornye,
  }) async {
    late AppMotionSpec spec;
    await tester.pumpWidget(
      MaterialApp(
        theme: theme,
        home: MediaQuery(
          data: MediaQueryData(disableAnimations: reduceMotion),
          child: Builder(
            builder: (context) {
              spec = AppMotion.spatial(context, fallback, mornye: mornye);
              return const SizedBox();
            },
          ),
        ),
      ),
    );
    // MaterialApp animates theme changes between pumps.
    await tester.pumpAndSettle();
    return spec;
  }

  testWidgets('Material uses its springs; reduced motion keeps the fallback', (
    tester,
  ) async {
    final material = await resolve(tester, theme: AppTheme.light());
    expect(material.curve, isA<SpringCurve>());
    expect(material, isNot(same(MornyeMotion.standard)));
    for (final theme in [
      AppTheme.light(),
      MornyeTheme.build(Brightness.light),
    ]) {
      final spec = await resolve(tester, theme: theme, reduceMotion: true);
      expect(spec.curve, Curves.easeOutCubic);
      expect(spec.duration, const Duration(milliseconds: 250));
    }
  });

  group('Animation speed', () {
    tearDown(() => MotionPace.speed = 1);

    test('leaves the designed motion alone at normal speed', () {
      final designed = MornyeMotion.standard;
      expect(MornyeMotion.standard, same(designed));
      expect(
        MotionPace.duration(const Duration(milliseconds: 300)),
        const Duration(milliseconds: 300),
      );
      expect(MornyeMotion.standardSpring, same(MornyeMotion.standardSpring));
    });

    test('shortens and lengthens the presets, keeping their curves', () {
      final designed = MornyeMotion.standard;
      final page = AppMotion.materialPage;
      MotionPace.speed = 2;
      expect(MornyeMotion.standard.duration, designed.duration * 0.5);
      expect(MornyeMotion.standard.curve, same(designed.curve));
      expect(AppMotion.materialPage.duration, page.duration * 0.5);
      MotionPace.speed = 0.5;
      expect(MornyeMotion.standard.duration, designed.duration * 2);
      for (final invalid in [0.0, -1.0, double.nan, double.infinity]) {
        MotionPace.speed = invalid;
        expect(MornyeMotion.standard, same(designed));
      }
    });

    test('a paced spring is the designed spring on a faster clock', () {
      final designed = MornyeMotion.snappySpring;
      MotionPace.speed = 2;
      final paced = MornyeMotion.snappySpring;
      final a = SpringSimulation(designed, 0, 1, 0);
      final b = SpringSimulation(paced, 0, 1, 0);
      for (final t in [0.05, 0.1, 0.2, 0.35, 0.6]) {
        expect(b.x(t / 2), closeTo(a.x(t), 1e-9));
      }
    });

    testWidgets('Material and Mornye sites follow it; reduced motion does '
        'not', (tester) async {
      final themes = [AppTheme.light(), MornyeTheme.build(Brightness.light)];
      for (final theme in themes) {
        final designed = await resolve(tester, theme: theme);
        MotionPace.speed = 2;
        final fast = await resolve(tester, theme: theme);
        expect(fast.duration, designed.duration * 0.5);
        expect(fast.curve, same(designed.curve));
        final reduced = await resolve(tester, theme: theme, reduceMotion: true);
        expect(reduced.duration, const Duration(milliseconds: 250));
        MotionPace.speed = 1;
      }
    });
  });

  testWidgets('Mornye uses its own spring where the site animates', (
    tester,
  ) async {
    final theme = MornyeTheme.build(Brightness.light);
    expect(await resolve(tester, theme: theme), same(MornyeMotion.standard));

    // A site that does not move outside Material stays still.
    const still = AppMotionSpec(Duration.zero, Curves.linear);
    expect(await resolve(tester, theme: theme, fallback: still), same(still));

    // A site may name its own Mornye motion.
    expect(
      await resolve(tester, theme: theme, mornye: MornyeMotion.snappy),
      same(MornyeMotion.snappy),
    );
    expect(
      await resolve(
        tester,
        theme: AppTheme.light(),
        mornye: MornyeMotion.snappy,
      ),
      isNot(same(MornyeMotion.snappy)),
    );
  });
}
