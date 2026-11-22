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
    SteadyPageRoute<void>(
      builder: (_) => Scaffold(body: Center(child: Text(label))),
    ),
  );
}

PageTransitionsBuilder _builderFor(ThemeData theme, TargetPlatform platform) {
  final builder = theme.pageTransitionsTheme.builders[platform];
  expect(builder, isA<ReducedMotionPageTransitionsBuilder>());
  return (builder! as ReducedMotionPageTransitionsBuilder).builder;
}

/// Frames that come on time: a longer step reads as a late frame.
Future<void> _frames(WidgetTester tester, int count) async {
  for (var i = 0; i < count; i++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

/// Whether a transform above [label] moves it as a picture.
bool _pictureAbove(WidgetTester tester, String label) => tester
    .widgetList<Transform>(
      find.ancestor(of: find.text(label), matching: find.byType(Transform)),
    )
    .any((transform) => transform.filterQuality != null);

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

  testWidgets('a Material Android push that starts late does not leap in', (
    tester,
  ) async {
    await _pumpApp(tester, material.copyWith(platform: TargetPlatform.android));
    final width = tester.getSize(find.byType(Scaffold)).width;
    _push('page');
    await tester.pump();
    // The page's first frame took a third of the transition.
    await tester.pump(const Duration(milliseconds: 120));
    final first = tester.getTopLeft(find.byType(Scaffold).last).dx;
    // Shown one frame in, with the page below it one frame out.
    expect(first, greaterThan(width / 3 * 0.95));
    expect(_opacityAbove(tester, 'page'), inExclusiveRange(0, 0.6));
    expect(
      tester.getTopLeft(find.byType(Scaffold).first).dx,
      inExclusiveRange(-width * 0.25 * 0.05, 0),
    );
    // Then it moves every frame, and plays whole: it is still arriving when
    // the transition's own time is over.
    var last = first;
    for (var frame = 0; frame < 15; frame++) {
      await _frames(tester, 1);
      final left = tester.getTopLeft(find.byType(Scaffold).last).dx;
      expect(left, lessThan(last));
      last = left;
    }
    expect(last, greaterThan(0));
    await _frames(tester, 8);
    expect(tester.getTopLeft(find.byType(Scaffold).last).dx, 0);
    expect(tester.binding.hasScheduledFrame, isFalse);
  });

  testWidgets('Material Android pushes a solid page and pops it as a card', (
    tester,
  ) async {
    await _pumpApp(tester, material.copyWith(platform: TargetPlatform.android));
    final width = tester.getSize(find.byType(Scaffold)).width;
    _push('page');
    await tester.pump();
    // Faint while it moves fastest: its opacity follows its way in.
    await _frames(tester, 2);
    expect(_opacityAbove(tester, 'page'), inExclusiveRange(0, 0.25));
    await _frames(tester, 1);

    expect(find.byType(SnapshotWidget), findsNothing);
    expect(_opacityAbove(tester, 'page'), inExclusiveRange(0.25, 1));
    final arriving = tester.getTopLeft(find.byType(Scaffold).last).dx;
    expect(arriving, inExclusiveRange(0, width / 3));
    // The page it covers moves the other way.
    expect(tester.getTopLeft(find.byType(Scaffold).first).dx, lessThan(0));

    // Solid long before it lands: no two pages read through each other.
    await _frames(tester, 5);
    expect(_opacityAbove(tester, 'page'), 1);
    expect(tester.getTopLeft(find.byType(Scaffold).last).dx, greaterThan(0));

    await tester.pumpAndSettle();
    expect(tester.getTopLeft(find.byType(Scaffold).last).dx, 0);
    expect(_pictureAbove(tester, 'page'), isFalse);

    _navigatorKey.currentState!.pop();
    await tester.pump();
    await _frames(tester, 8);
    // The card has drawn in but hardly moved, and stays solid.
    final card = tester.getRect(find.byType(Scaffold).last);
    expect(card.width, lessThan(width));
    expect(card.center.dx, lessThan(width * 0.6));
    expect(_opacityAbove(tester, 'page'), 1);
    // It is scaled as a picture of the live page, not text at a new size.
    expect(_pictureAbove(tester, 'page'), isTrue);
    expect(find.byType(SnapshotWidget), findsNothing);
    // A third of the way in time, the page below is most of the way back.
    expect(
      tester.getTopLeft(find.byType(Scaffold).first).dx,
      inInclusiveRange(-width * 0.25 * 0.3, 0),
    );

    await tester.pumpAndSettle();
    expect(find.text('page'), findsNothing);
    expect(tester.getTopLeft(find.byType(Scaffold)).dx, 0);
  });

  testWidgets('a picture scale draws its child as itself at rest', (
    tester,
  ) async {
    FilterQuality? quality() =>
        tester.widget<Transform>(find.byType(Transform)).filterQuality;

    await tester.pumpWidget(
      const PictureScaleTransition(
        scale: AlwaysStoppedAnimation(0.92),
        child: SizedBox(),
      ),
    );
    expect(quality(), FilterQuality.low);
    await tester.pumpWidget(
      const PictureScaleTransition(
        scale: AlwaysStoppedAnimation(1),
        child: SizedBox(),
      ),
    );
    expect(quality(), isNull);
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
      await _frames(tester, 13);
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

  group('Material Android back swipe', () {
    const codec = StandardMethodCodec();
    Future<void> swipe(
      WidgetTester tester,
      String method, [
      double? progress,
    ]) => tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      SystemChannels.backGesture.name,
      codec.encodeMethodCall(
        MethodCall(
          method,
          progress == null
              ? null
              : <String, Object?>{
                  'touchOffset': <double>[5, 300],
                  'progress': progress,
                  'swipeEdge': 0,
                },
        ),
      ),
      (_) {},
    );

    void observe(Iterable<NavigatorState?> Function() navigators) {
      final observer = PageBackSwipe(navigators);
      WidgetsBinding.instance.addObserver(observer);
      addTearDown(() => WidgetsBinding.instance.removeObserver(observer));
    }

    final android = material.copyWith(platform: TargetPlatform.android);

    testWidgets('the page follows the finger as a card', (tester) async {
      await _pumpApp(tester, android);
      observe(() => [_navigatorKey.currentState]);
      final width = tester.getSize(find.byType(Scaffold)).width;
      _push('page');
      await tester.pumpAndSettle();

      await swipe(tester, 'startBackGesture', 0);
      await swipe(tester, 'updateBackGestureProgress', 0.5);
      await tester.pump();
      final half = tester.getRect(find.byType(Scaffold).last);
      await swipe(tester, 'updateBackGestureProgress', 1);
      await tester.pump();
      final full = tester.getRect(find.byType(Scaffold).last);
      // Drawn in evenly under the finger, solid, over the page below.
      expect(
        width - half.width,
        moreOrLessEquals((width - full.width) / 2, epsilon: 1),
      );
      expect(full.width, inExclusiveRange(width * 0.88, width * 0.93));
      expect(_opacityAbove(tester, 'page'), 1);
      expect(find.text('home'), findsOneWidget);

      // Let go without going back: the page returns the way it came.
      await swipe(tester, 'cancelBackGesture');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
      final returning = tester.getRect(find.byType(Scaffold).last);
      expect(returning.width, inExclusiveRange(full.width, width));
      expect(_opacityAbove(tester, 'page'), 1);
      await tester.pumpAndSettle();
      expect(tester.getRect(find.byType(Scaffold).last).width, width);
      expect(find.text('page'), findsOneWidget);

      // Let go to go back: the card leaves from where the finger left it.
      await swipe(tester, 'startBackGesture', 0);
      await swipe(tester, 'updateBackGestureProgress', 1);
      await tester.pump();
      await swipe(tester, 'commitBackGesture');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
      final leaving = tester.getRect(find.byType(Scaffold).last);
      expect(leaving.width, lessThan(full.width));
      expect(leaving.width, greaterThan(full.width - 20));
      expect(leaving.left, greaterThan(full.left));
      await tester.pumpAndSettle();
      expect(find.text('page'), findsNothing);
      expect(tester.getRect(find.byType(Scaffold)).width, width);
    });

    testWidgets('a cover flies back to its row on a swipe as on a press', (
      tester,
    ) async {
      const row = Key('row-cover');
      const header = Key('header-cover');
      Widget cover(BuildContext context, Key key, double size) => Hero(
        tag: 'cover',
        transitionOnUserGestures: heroFollowsBackSwipe(context),
        child: SizedBox.square(
          key: key,
          dimension: size,
          child: const ColoredBox(color: Colors.red),
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: _navigatorKey,
          theme: android,
          home: Scaffold(
            body: Builder(
              builder: (context) => Align(
                alignment: Alignment.topLeft,
                child: cover(context, row, 40),
              ),
            ),
          ),
        ),
      );
      observe(() => [_navigatorKey.currentState]);
      final rowRect = tester.getRect(find.byKey(row));
      Future<void> open() async {
        _navigatorKey.currentState!.push(
          SteadyPageRoute<void>(
            builder: (context) =>
                Scaffold(body: Center(child: cover(context, header, 200))),
          ),
        );
        await tester.pumpAndSettle();
      }

      await open();
      final headerRect = tester.getRect(find.byKey(header));

      // Under the finger the cover has left the page and is on its way.
      await swipe(tester, 'startBackGesture', 0);
      await swipe(tester, 'updateBackGestureProgress', 1);
      await tester.pump();
      await tester.pump();
      expect(find.byKey(header), findsNothing);
      final flying = tester.getRect(find.byKey(row));
      expect(flying.width, inExclusiveRange(rowRect.width, headerRect.width));
      expect(flying.center.dx, lessThan(headerRect.center.dx));

      // Let go without going back: the cover returns to the page.
      await swipe(tester, 'cancelBackGesture');
      await tester.pumpAndSettle();
      expect(tester.getRect(find.byKey(header)), headerRect);

      // Let go to go back: it lands on its row.
      await swipe(tester, 'startBackGesture', 0);
      await swipe(tester, 'updateBackGestureProgress', 1);
      await tester.pump();
      await swipe(tester, 'commitBackGesture');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
      expect(find.byKey(header), findsNothing);
      await tester.pumpAndSettle();
      expect(tester.getRect(find.byKey(row)), rowRect);

      // A press flies it the same way.
      await open();
      _navigatorKey.currentState!.pop();
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byKey(header), findsNothing);
      expect(
        tester.getRect(find.byKey(row)).width,
        inExclusiveRange(rowRect.width, headerRect.width),
      );
      await tester.pumpAndSettle();
      expect(tester.getRect(find.byKey(row)), rowRect);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a dialog above the page closes first', (tester) async {
      await _pumpApp(tester, android);
      observe(() => [_navigatorKey.currentState]);
      final width = tester.getSize(find.byType(Scaffold)).width;
      _push('page');
      await tester.pumpAndSettle();
      showDialog<void>(
        context: _navigatorKey.currentContext!,
        builder: (_) => const AlertDialog(content: Text('dialog')),
      );
      await tester.pumpAndSettle();

      await swipe(tester, 'startBackGesture', 0);
      await swipe(tester, 'updateBackGestureProgress', 1);
      await tester.pump();
      expect(tester.getRect(find.byType(Scaffold).last).width, width);
      await swipe(tester, 'commitBackGesture');
      await tester.pumpAndSettle();
      expect(find.text('dialog'), findsNothing);
      expect(find.text('page'), findsOneWidget);
    });

    testWidgets('the swipe reaches the navigator a back press would', (
      tester,
    ) async {
      final tab = GlobalKey<NavigatorState>();
      Route<void> page(String label) =>
          MaterialPageRoute<void>(builder: (_) => Scaffold(body: Text(label)));
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: _navigatorKey,
          theme: android,
          home: Navigator(key: tab, onGenerateRoute: (_) => page('tab')),
        ),
      );
      observe(() => [_navigatorKey.currentState, tab.currentState]);
      Future<void> swipeBack() async {
        await swipe(tester, 'startBackGesture', 0);
        await swipe(tester, 'updateBackGestureProgress', 1);
        await tester.pump();
        await swipe(tester, 'commitBackGesture');
        await tester.pumpAndSettle();
      }

      // A root page above a page of the tab: only the root page goes.
      tab.currentState!.push(page('tab page'));
      await tester.pumpAndSettle();
      _navigatorKey.currentState!.push(page('root page'));
      await tester.pumpAndSettle();
      await swipeBack();
      expect(find.text('root page'), findsNothing);
      expect(find.text('tab page'), findsOneWidget);

      // Nothing above the tab at the root: its page goes.
      await swipeBack();
      expect(find.text('tab page'), findsNothing);
      expect(find.text('tab'), findsOneWidget);
    });
  });

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
