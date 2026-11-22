import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/theme/app_motion.dart';
import 'package:mornye/theme/app_theme.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/theme/page_transitions.dart';

final _navigatorKey = GlobalKey<NavigatorState>();

Future<void> _pumpApp(
  WidgetTester tester,
  ThemeData theme, {
  bool reducedMotion = false,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      navigatorKey: _navigatorKey,
      theme: theme,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(disableAnimations: reducedMotion),
        child: child!,
      ),
      home: const Scaffold(body: Text('home')),
    ),
  );
}

void _push(String label) {
  _navigatorKey.currentState!.push(
    MaterialPageRoute<void>(
      builder: (_) => Scaffold(body: Center(child: Text(label))),
    ),
  );
}

PageTransitionsBuilder _builderFor(ThemeData theme, TargetPlatform platform) {
  final builder = theme.pageTransitionsTheme.builders[platform];
  expect(builder, isA<ReducedMotionPageTransitionsBuilder>());
  return (builder! as ReducedMotionPageTransitionsBuilder).builder;
}

double _opacityAbove(WidgetTester tester, String label) => tester
    .widgetList<FadeTransition>(
      find.ancestor(
        of: find.text(label),
        matching: find.byType(FadeTransition),
      ),
    )
    .fold(1.0, (opacity, fade) => opacity * fade.opacity.value);

void main() {
  final material = AppTheme.light();
  final mornye = MornyeTheme.build(Brightness.light);

  test('page pushes and pops follow the Animation speed', () {
    addTearDown(() => MotionPace.speed = 1);
    for (final theme in [material, mornye]) {
      for (final platform in TargetPlatform.values) {
        final builder = theme.pageTransitionsTheme.builders[platform];
        if (builder == null) continue;
        MotionPace.speed = 1;
        final push = builder.transitionDuration;
        final pop = builder.reverseTransitionDuration;
        expect(push, _builderFor(theme, platform).transitionDuration);
        MotionPace.speed = 2;
        expect(builder.transitionDuration, push * 0.5);
        expect(builder.reverseTransitionDuration, pop * 0.5);
      }
    }
  });

  test('every platform has a builder in both styles', () {
    for (final platform in [
      TargetPlatform.android,
      TargetPlatform.iOS,
      TargetPlatform.macOS,
      TargetPlatform.windows,
      TargetPlatform.linux,
    ]) {
      final materialBuilder = _builderFor(material, platform);
      final mornyeBuilder = _builderFor(mornye, platform);
      expect(materialBuilder, isNot(isA<ZoomPageTransitionsBuilder>()));
      expect(
        materialBuilder,
        isNot(isA<PredictiveBackPageTransitionsBuilder>()),
      );
      expect(mornyeBuilder, isNot(isA<PredictiveBackPageTransitionsBuilder>()));
      final desktop =
          platform == TargetPlatform.macOS ||
          platform == TargetPlatform.windows ||
          platform == TargetPlatform.linux;
      if (desktop) {
        expect(materialBuilder, isA<DesktopPageTransitionsBuilder>());
        expect(mornyeBuilder, isA<DesktopCupertinoPageTransitionsBuilder>());
      } else {
        expect(mornyeBuilder, isA<CupertinoPageTransitionsBuilder>());
      }
    }
    expect(
      _builderFor(material, TargetPlatform.android),
      isA<MaterialPhonePageTransitionsBuilder>(),
    );
  });

  testWidgets('Material Android pushes a solid page and pops it as a card', (
    tester,
  ) async {
    await _pumpApp(tester, material.copyWith(platform: TargetPlatform.android));
    final width = tester.getSize(find.byType(Scaffold)).width;
    _push('page');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.byType(SnapshotWidget), findsNothing);
    expect(_opacityAbove(tester, 'page'), inExclusiveRange(0, 1));
    final arriving = tester.getTopLeft(find.byType(Scaffold).last).dx;
    expect(arriving, inExclusiveRange(0, width / 3));
    // The page it covers moves the other way.
    expect(tester.getTopLeft(find.byType(Scaffold).first).dx, lessThan(0));

    // Solid long before it lands: no two pages read through each other.
    await tester.pump(const Duration(milliseconds: 70));
    expect(_opacityAbove(tester, 'page'), 1);
    expect(tester.getTopLeft(find.byType(Scaffold).last).dx, greaterThan(0));

    await tester.pumpAndSettle();
    expect(tester.getTopLeft(find.byType(Scaffold).last).dx, 0);

    _navigatorKey.currentState!.pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));
    // The card has drawn in but hardly moved, and stays solid.
    final card = tester.getRect(find.byType(Scaffold).last);
    expect(card.width, lessThan(width));
    expect(card.center.dx, lessThan(width * 0.6));
    expect(_opacityAbove(tester, 'page'), 1);
    // A third of the way in time, the page below is most of the way back.
    expect(
      tester.getTopLeft(find.byType(Scaffold).first).dx,
      inInclusiveRange(-width * 0.25 * 0.3, 0),
    );

    await tester.pumpAndSettle();
    expect(find.text('page'), findsNothing);
    expect(tester.getTopLeft(find.byType(Scaffold)).dx, 0);
  });

  for (final platform in [TargetPlatform.windows, TargetPlatform.linux]) {
    testWidgets('Material ${platform.name} push fades and slides without a '
        'snapshot and exits shorter', (tester) async {
      await _pumpApp(tester, material.copyWith(platform: platform));
      _push('page');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(find.byType(SnapshotWidget), findsNothing);
      final opacity = _opacityAbove(tester, 'page');
      expect(opacity, greaterThan(0));
      expect(opacity, lessThan(1));
      final shift = tester.getTopLeft(find.byType(Scaffold).last).dx;
      expect(shift, greaterThan(0));
      expect(shift, lessThanOrEqualTo(32));

      await tester.pumpAndSettle();
      expect(_opacityAbove(tester, 'page'), 1);
      expect(tester.getTopLeft(find.byType(Scaffold).last).dx, 0);

      _navigatorKey.currentState!.pop();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 210));
      expect(find.text('page'), findsNothing);
      expect(find.text('home'), findsOneWidget);
    });

    testWidgets('Mornye ${platform.name} push uses the Cupertino transition '
        'and ignores a mouse drag from the edge', (tester) async {
      await _pumpApp(tester, mornye.copyWith(platform: platform));
      _push('page');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(
        find.ancestor(
          of: find.text('page'),
          matching: find.byType(CupertinoPageTransition),
        ),
        findsOneWidget,
      );
      await tester.pumpAndSettle();

      final gesture = await tester.startGesture(
        const Offset(5, 300),
        kind: PointerDeviceKind.mouse,
      );
      await gesture.moveBy(const Offset(200, 0));
      await gesture.moveBy(const Offset(200, 0));
      await gesture.up();
      await tester.pumpAndSettle();
      expect(find.text('page'), findsOneWidget);
    });
  }

  testWidgets('Mornye Android push uses the Cupertino transition', (
    tester,
  ) async {
    await _pumpApp(tester, mornye.copyWith(platform: TargetPlatform.android));
    _push('page');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(
      find.ancestor(
        of: find.text('page'),
        matching: find.byType(CupertinoPageTransition),
      ),
      findsOneWidget,
    );
    await tester.pumpAndSettle();
  });

  for (final style in ['Material', 'Mornye']) {
    testWidgets('$style Android back closes a sheet before the page', (
      tester,
    ) async {
      final theme = style == 'Material' ? material : mornye;
      await _pumpApp(tester, theme.copyWith(platform: TargetPlatform.android));
      _push('page');
      await tester.pumpAndSettle();
      showModalBottomSheet<void>(
        context: _navigatorKey.currentContext!,
        builder: (_) => const SizedBox(height: 200, child: Text('sheet')),
      );
      await tester.pumpAndSettle();

      // A predictive back gesture from the system, then its commit.
      const codec = StandardMethodCodec();
      Future<void> send(String method, [Object? arguments]) =>
          tester.binding.defaultBinaryMessenger.handlePlatformMessage(
            SystemChannels.backGesture.name,
            codec.encodeMethodCall(MethodCall(method, arguments)),
            (_) {},
          );
      await send('startBackGesture', <String, Object?>{
        'touchOffset': <double>[5, 300],
        'progress': 0.0,
        'swipeEdge': 0,
      });
      await send('commitBackGesture');
      await tester.pumpAndSettle();

      expect(find.text('sheet'), findsNothing);
      expect(find.text('page'), findsOneWidget);
    });
  }

  group('reduced motion', () {
    for (final (style, theme, platform) in [
      ('Material', material, TargetPlatform.windows),
      ('Material', material, TargetPlatform.android),
      ('Mornye', mornye, TargetPlatform.macOS),
      ('Mornye', mornye, TargetPlatform.iOS),
    ]) {
      testWidgets('$style ${platform.name} pushes and pops at once', (
        tester,
      ) async {
        await _pumpApp(
          tester,
          theme.copyWith(platform: platform),
          reducedMotion: true,
        );
        _push('page');
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 16));
        expect(tester.getTopLeft(find.byType(Scaffold).last), Offset.zero);
        expect(_opacityAbove(tester, 'page'), 1);
        await tester.pumpAndSettle();

        _navigatorKey.currentState!.pop();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 16));
        expect(find.text('page'), findsNothing);
        expect(find.text('home'), findsOneWidget);
        await tester.pumpAndSettle();
      });
    }

    testWidgets('Mornye iOS back swipe still follows the finger', (
      tester,
    ) async {
      await _pumpApp(
        tester,
        mornye.copyWith(platform: TargetPlatform.iOS),
        reducedMotion: true,
      );
      _push('page');
      await tester.pumpAndSettle();

      final gesture = await tester.startGesture(const Offset(5, 300));
      await gesture.moveBy(const Offset(20, 0));
      await gesture.moveBy(const Offset(180, 0));
      await tester.pump();
      expect(
        tester.getTopLeft(find.byType(Scaffold).last).dx,
        greaterThan(100),
      );
      await gesture.moveBy(const Offset(300, 0));
      await gesture.up();
      await tester.pumpAndSettle();
      expect(find.text('page'), findsNothing);
    });
  });
}
