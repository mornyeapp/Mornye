import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/screens/now_playing_screen.dart';
import 'package:mornye/theme/app_motion.dart';
import 'package:mornye/theme/app_theme.dart';
import 'package:mornye/theme/mornye_theme.dart';

const _sheet = Key('player-sheet');

class _TestPlayerRoute extends NowPlayingRoute {
  _TestPlayerRoute({super.miniPlayerGeometry, super.morph})
    : super(child: const SizedBox());

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) => const ColoredBox(key: _sheet, color: Colors.black);
}

void main() {
  testWidgets('closing the player keeps the search keyboard dismissed', (
    tester,
  ) async {
    final navigator = GlobalKey<NavigatorState>();
    final focus = FocusNode();
    final text = TextEditingController();
    addTearDown(focus.dispose);
    addTearDown(text.dispose);
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        home: Scaffold(
          body: TextField(focusNode: focus, controller: text),
        ),
      ),
    );
    await tester.enterText(find.byType(TextField), 'Unfinished search');
    expect(focus.hasFocus, isTrue);
    expect(tester.testTextInput.isVisible, isTrue);

    navigator.currentState!.push(_TestPlayerRoute());
    await tester.pumpAndSettle();
    expect(tester.testTextInput.isVisible, isFalse);
    navigator.currentState!.pop();
    await tester.pumpAndSettle();

    expect(text.text, 'Unfinished search');
    expect(focus.hasFocus, isFalse);
    expect(tester.testTextInput.isVisible, isFalse);
    await tester.tap(find.byType(TextField));
    await tester.pump();
    expect(focus.hasFocus, isTrue);
    expect(tester.testTextInput.isVisible, isTrue);
  });

  testWidgets('closing the player restores focus to a non-editing control', (
    tester,
  ) async {
    final navigator = GlobalKey<NavigatorState>();
    final focus = FocusNode();
    addTearDown(focus.dispose);
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        home: Scaffold(
          body: TextButton(
            focusNode: focus,
            onPressed: () {},
            child: const Text('Play'),
          ),
        ),
      ),
    );
    focus.requestFocus();
    await tester.pump();
    expect(focus.hasFocus, isTrue);
    navigator.currentState!.push(_TestPlayerRoute());
    await tester.pumpAndSettle();
    navigator.currentState!.pop();
    await tester.pumpAndSettle();
    expect(focus.hasFocus, isTrue);
  });

  testWidgets('rotation on close discards stale mini-player bounds', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(852, 393);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        theme: MornyeTheme.build(Brightness.dark),
        home: const SizedBox(),
      ),
    );
    navigator.currentState!.push(
      _TestPlayerRoute(
        miniPlayerGeometry: () => (
          surface: const Rect.fromLTWH(80, 310, 700, 52),
          artwork: const Rect.fromLTWH(88, 314, 44, 44),
        ),
      ),
    );
    await tester.pumpAndSettle();
    navigator.currentState!.pop();
    await tester.pump();
    expect(
      find.byKey(const ValueKey('player-minimize-surface')),
      findsOneWidget,
    );
    tester.view.physicalSize = const Size(393, 852);
    await tester.pump(const Duration(milliseconds: 16));
    expect(find.byKey(const ValueKey('player-minimize-surface')), findsNothing);
    await tester.pumpAndSettle();
    expect(find.byKey(_sheet), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('settled player keeps the page below offstage until dragged', (
    tester,
  ) async {
    const below = Key('below-player');
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        home: const SizedBox.expand(key: below),
      ),
    );
    final route = _TestPlayerRoute();
    navigator.currentState!.push(route);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    // Translucent while it slides in.
    expect(find.byKey(below), findsOneWidget);
    await tester.pumpAndSettle();
    expect(find.byKey(below), findsNothing);
    expect(find.byKey(below, skipOffstage: false), findsOneWidget);

    route.startDrag();
    route.updateDrag(
      DragUpdateDetails(
        globalPosition: const Offset(0, 120),
        delta: const Offset(0, 120),
        primaryDelta: 120,
      ),
      600,
    );
    await tester.pump();
    expect(find.byKey(below), findsOneWidget);
    route.cancelDrag();
    await tester.pumpAndSettle();
    expect(find.byKey(below), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('rotation while covered discards stale mini-player bounds', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(393, 852);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        theme: MornyeTheme.build(Brightness.dark),
        home: const SizedBox(),
      ),
    );
    navigator.currentState!.push(
      _TestPlayerRoute(
        miniPlayerGeometry: () => (
          surface: const Rect.fromLTWH(20, 700, 353, 52),
          artwork: const Rect.fromLTWH(28, 704, 44, 44),
        ),
      ),
    );
    await tester.pumpAndSettle();
    // The page below is not laid out while hidden, so its mini player still
    // reports portrait bounds after the window turns landscape.
    tester.view.physicalSize = const Size(852, 393);
    await tester.pump();
    navigator.currentState!.pop();
    await tester.pump();
    expect(find.byKey(const ValueKey('player-minimize-surface')), findsNothing);
    await tester.pumpAndSettle();
    expect(find.byKey(_sheet), findsNothing);
    expect(tester.takeException(), isNull);
  });

  for (final brightness in Brightness.values) {
    testWidgets(
      'player fills safe areas and reveals the page only when dragged in $brightness',
      (tester) async {
        tester.view.physicalSize = const Size(393, 852);
        tester.view.devicePixelRatio = 1;
        tester.view.padding = FakeViewPadding(top: 59, bottom: 34);
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPadding);
        final navigator = GlobalKey<NavigatorState>();
        final capture = GlobalKey();
        const background = Color(0xffff00ff);
        final theme = MornyeTheme.build(brightness);
        final playerBackground = theme.colorScheme.surface;
        await tester.pumpWidget(
          RepaintBoundary(
            key: capture,
            child: ProviderScope(
              overrides: [
                currentMediaItemProvider.overrideWithBuild(
                  (ref, notifier) => Stream.value(null),
                ),
              ],
              child: MaterialApp(
                navigatorKey: navigator,
                theme: theme,
                localizationsDelegates: AppLocalizations.localizationsDelegates,
                supportedLocales: AppLocalizations.supportedLocales,
                home: ColoredBox(
                  color: background,
                  child: const SizedBox.expand(),
                ),
              ),
            ),
          ),
        );
        final route = NowPlayingRoute(child: const NowPlayingScreen());
        navigator.currentState!.push(route);
        await tester.pumpAndSettle();

        Future<void> expectColorAt(int x, int y, Color expected) async {
          final pixel = await tester.runAsync(() async {
            final boundary = tester.renderObject<RenderRepaintBoundary>(
              find.byKey(capture),
            );
            final image = await boundary.toImage();
            final bytes = (await image.toByteData(
              format: ui.ImageByteFormat.rawRgba,
            ))!;
            final offset = (y * image.width + x) * 4;
            final color = Color.fromARGB(
              bytes.getUint8(offset + 3),
              bytes.getUint8(offset),
              bytes.getUint8(offset + 1),
              bytes.getUint8(offset + 2),
            );
            image.dispose();
            return color;
          });
          expect(pixel, expected);
        }

        await expectColorAt(196, 30, playerBackground);
        await expectColorAt(1, 1, playerBackground);
        await expectColorAt(196, 840, playerBackground);
        expect(tester.getTopLeft(find.byType(AppBar).last).dy, 0);
        expect(
          tester.getTopLeft(find.byIcon(Icons.keyboard_arrow_down)).dy,
          greaterThanOrEqualTo(59),
        );
        route.startDrag();
        route.updateDrag(
          DragUpdateDetails(
            globalPosition: const Offset(0, 213),
            delta: const Offset(0, 213),
            primaryDelta: 213,
          ),
          852,
        );
        await tester.pump();
        await expectColorAt(196, 100, background);
        await expectColorAt(196, 243, playerBackground);
        route.cancelDrag();
        await tester.pumpAndSettle();
        await expectColorAt(196, 30, playerBackground);
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final reducedMotion in [false, true]) {
    testWidgets('Mornye player opens and closes at once only under reduced '
        'motion ($reducedMotion)', (tester) async {
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      if (reducedMotion) {
        tester.platformDispatcher.accessibilityFeaturesTestValue =
            const FakeAccessibilityFeatures(disableAnimations: true);
        addTearDown(
          tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
        );
      }
      final navigator = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigator,
          theme: MornyeTheme.build(Brightness.dark),
          home: const SizedBox(),
        ),
      );
      navigator.currentState!.push(_TestPlayerRoute());
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
      final top = tester.getTopLeft(find.byKey(_sheet)).dy;
      if (reducedMotion) {
        expect(top, 0);
      } else {
        expect(top, greaterThan(0));
      }
      await tester.pumpAndSettle();

      navigator.currentState!.pop();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
      expect(find.byKey(_sheet), reducedMotion ? findsNothing : findsOneWidget);
      await tester.pumpAndSettle();
      expect(find.byKey(_sheet), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('the Mornye page moves with round corners and rests square', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        theme: MornyeTheme.build(Brightness.dark),
        home: const SizedBox(),
      ),
    );
    const corners = ValueKey('player-slide-corners');
    const minimize = ValueKey('player-minimize-surface');
    ClipRRect clip(Key key) => tester.widget<ClipRRect>(find.byKey(key));
    navigator.currentState!.push(
      _TestPlayerRoute(
        miniPlayerGeometry: () => (
          surface: const Rect.fromLTWH(16, 700, 368, 56),
          artwork: const Rect.fromLTWH(24, 706, 44, 44),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    expect(tester.getTopLeft(find.byKey(_sheet)).dy, greaterThan(32));
    expect(
      clip(corners).borderRadius,
      const BorderRadius.vertical(top: Radius.circular(32)),
    );
    expect(clip(corners).clipBehavior, Clip.antiAlias);
    await tester.pumpAndSettle();
    expect(clip(corners).clipBehavior, Clip.none);

    navigator.currentState!.pop();
    await tester.pump();
    // Frames that come on time: one long step would read as a late frame.
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(tester.getTopLeft(find.byKey(minimize)).dy, greaterThan(32));
    expect(clip(minimize).borderRadius, BorderRadius.circular(32));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('a Material page slides up with square corners', (tester) async {
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(navigatorKey: navigator, home: const SizedBox()),
    );
    navigator.currentState!.push(_TestPlayerRoute());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    expect(tester.getTopLeft(find.byKey(_sheet)).dy, greaterThan(0));
    expect(find.byKey(const ValueKey('player-slide-corners')), findsNothing);
    await tester.pumpAndSettle();
  });

  group('Material morph', () {
    const mini = Rect.fromLTWH(0, 700, 400, 72);
    const morph = AppMotionSpec(Duration(milliseconds: 500), Curves.linear);
    const surface = ValueKey('player-expand-surface');
    const minimize = ValueKey('player-minimize-surface');

    Future<GlobalKey<NavigatorState>> pumpApp(WidgetTester tester) async {
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final navigator = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigator,
          theme: AppTheme.light(),
          home: const SizedBox(),
        ),
      );
      return navigator;
    }

    _TestPlayerRoute route({AppMotionSpec spec = morph}) => _TestPlayerRoute(
      miniPlayerGeometry: () =>
          (surface: mini, artwork: const Rect.fromLTWH(12, 714, 44, 44)),
      morph: spec,
    );

    // Frames that come on time: a longer step reads as a late frame.
    Future<void> frames(WidgetTester tester, int count) async {
      for (var i = 0; i < count; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
    }

    Future<void> backGesture(
      WidgetTester tester,
      String method, [
      double? progress,
    ]) => tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      'flutter/backgesture',
      const StandardMethodCodec().encodeMethodCall(
        MethodCall(
          method,
          progress == null
              ? null
              : {
                  'touchOffset': [5.0, 400.0],
                  'progress': progress,
                  'swipeEdge': 0,
                },
        ),
      ),
      (_) {},
    );

    testWidgets('a surface narrower than the screen grows as a picture', (
      tester,
    ) async {
      final navigator = await pumpApp(tester);
      navigator.currentState!.push(
        _TestPlayerRoute(
          miniPlayerGeometry: () => (
            surface: const Rect.fromLTWH(40, 700, 320, 72),
            artwork: const Rect.fromLTWH(52, 714, 44, 44),
          ),
          morph: morph,
        ),
      );
      await tester.pump();
      await tester.pump();
      await frames(tester, 6);
      // The page is scaled to the surface's width: not as text at a new
      // size on every frame.
      final scaled = tester.widget<Transform>(
        find
            .descendant(
              of: find.byKey(surface),
              matching: find.byType(Transform),
            )
            .first,
      );
      expect(scaled.filterQuality, FilterQuality.low);
      await tester.pumpAndSettle();
      expect(find.byKey(surface), findsNothing);
    });

    testWidgets('the player grows out of the mini player and shrinks back', (
      tester,
    ) async {
      final navigator = await pumpApp(tester);
      final player = route();
      navigator.currentState!.push(player);
      // The first frame lays the route out offstage to measure Heroes.
      await tester.pump();
      await tester.pump();
      expect(tester.getRect(find.byKey(surface)), mini);
      // The player's own content comes in behind the growing surface.
      final content = player.contentOpacity(
        CurveTween(curve: const Interval(0.4, 1)),
      );
      expect(content.value, 0);
      await frames(tester, 9);
      final growing = tester.getRect(find.byKey(surface));
      expect(growing.top, inExclusiveRange(0, mini.top));
      expect(growing.bottom, inInclusiveRange(mini.bottom, 800));
      expect(growing.height, greaterThan(mini.height));
      // The content shows by how far open the surface is.
      expect(content.value, inExclusiveRange(0, 0.2));
      await tester.pumpAndSettle();
      expect(content.value, 1);
      expect(find.byKey(surface), findsNothing);
      expect(
        tester.getRect(find.byKey(_sheet)),
        const Rect.fromLTWH(0, 0, 400, 800),
      );

      navigator.currentState!.pop();
      await tester.pump();
      // The shrink only moves toward the mini player, never past it, at
      // the pace of the entrance: still well short of the bar after a
      // tenth of a second, and done in under half a second.
      var previousTop = 0.0;
      var previousContent = 1.0;
      var elapsed = Duration.zero;
      while (find.byKey(minimize).evaluate().isNotEmpty) {
        final top = tester.getRect(find.byKey(minimize)).top;
        expect(top, greaterThanOrEqualTo(previousTop));
        expect(top, lessThanOrEqualTo(mini.top + 0.01));
        if (elapsed == const Duration(milliseconds: 96)) {
          expect(top, lessThan(mini.top * 0.65));
        }
        // The content leaves with the surface and never comes back.
        expect(content.value, lessThanOrEqualTo(previousContent));
        previousContent = content.value;
        // The surface is solid until a fifth of the way from the bar, so
        // the page below is never read through a whole screen of it.
        final opacity = tester
            .widget<Opacity>(
              find
                  .descendant(
                    of: find.byKey(minimize),
                    matching: find.byType(Opacity),
                  )
                  .first,
            )
            .opacity;
        if (top < mini.top * 0.8 - 0.01) expect(opacity, 1);
        previousTop = top;
        await tester.pump(const Duration(milliseconds: 16));
        elapsed += const Duration(milliseconds: 16);
      }
      expect(previousTop, greaterThan(mini.top - 20));
      expect(previousContent, 0);
      expect(elapsed, greaterThan(const Duration(milliseconds: 380)));
      expect(elapsed, lessThan(const Duration(milliseconds: 560)));
      expect(find.byKey(_sheet), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('an opening that starts late does not leap open', (
      tester,
    ) async {
      final navigator = await pumpApp(tester);
      final player = route();
      navigator.currentState!.push(player);
      await tester.pump();
      await tester.pump();
      // The player's first frame took a fifth of the opening.
      await tester.pump(const Duration(milliseconds: 100));
      final first = tester.getRect(find.byKey(surface)).top;
      expect(first, greaterThan(mini.top * 0.95));
      // Then it grows every frame, and plays whole: it is still growing
      // when the opening's own time is over.
      var last = first;
      for (var elapsed = 116; elapsed < 500; elapsed += 16) {
        await frames(tester, 1);
        final top = tester.getRect(find.byKey(surface)).top;
        expect(top, lessThan(last));
        last = top;
      }
      expect(last, greaterThan(0));
      await frames(tester, 8);
      expect(find.byKey(surface), findsNothing);
      expect(
        tester.getRect(find.byKey(_sheet)),
        const Rect.fromLTWH(0, 0, 400, 800),
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('the growing surface is solid within its first frames', (
      tester,
    ) async {
      final navigator = await pumpApp(tester);
      navigator.currentState!.push(route());
      await tester.pump();
      await tester.pump();
      double opacity() => tester
          .widget<Opacity>(
            find.descendant(
              of: find.byKey(surface),
              matching: find.byType(Opacity),
            ),
          )
          .opacity;
      // Under a fifth of the way open the mini player still hands over.
      await frames(tester, 3);
      expect(opacity(), inExclusiveRange(0, 1));
      await frames(tester, 4);
      expect(opacity(), 1);
      // Solid while most of the way is still ahead of it.
      expect(
        tester.getRect(find.byKey(surface)).top,
        greaterThan(mini.top * 0.7),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });

    test('the cover flight keeps step with the surface', () {
      const begin = Rect.fromLTWH(12, 714, 44, 44);
      const end = Rect.fromLTWH(0, 0, 400, 400);
      const curve = Curves.easeOutBack;
      final opening = PlayerCoverRectTween(
        begin: begin,
        end: end,
        curve: curve,
      );
      final closing = PlayerCoverRectTween(begin: end, end: begin);
      for (final time in [0.0, 0.1, 0.35, 0.6, 0.9, 1.0]) {
        // A Hero hands its tween the route's time on its own ease, which
        // Flutter evaluates to a thousandth: a few pixels of a screen.
        final eased = Curves.fastOutSlowIn.transform(time);
        final opened = opening.lerp(eased)!;
        final surface = Rect.lerp(begin, end, curve.transform(time))!;
        expect(opened.top, moreOrLessEquals(surface.top, epsilon: 4));
        expect(opened.width, moreOrLessEquals(surface.width, epsilon: 4));
        final closed = closing.lerp(eased)!;
        expect(
          closed.top,
          moreOrLessEquals(Rect.lerp(end, begin, time)!.top, epsilon: 4),
        );
      }
    });

    testWidgets('reduced motion opens and closes at once', (tester) async {
      final navigator = await pumpApp(tester);
      navigator.currentState!.push(
        route(spec: const AppMotionSpec(Duration.zero, Curves.linear)),
      );
      await tester.pump();
      await tester.pump();
      expect(find.byKey(surface), findsNothing);
      expect(
        tester.getRect(find.byKey(_sheet)),
        const Rect.fromLTWH(0, 0, 400, 800),
      );
      navigator.currentState!.pop();
      await tester.pump();
      await tester.pump();
      expect(find.byKey(_sheet), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('predictive back previews the shrink, cancels and commits', (
      tester,
    ) async {
      final navigator = await pumpApp(tester);
      navigator.currentState!.push(route());
      await tester.pumpAndSettle();

      await backGesture(tester, 'startBackGesture', 0);
      await backGesture(tester, 'updateBackGestureProgress', 0.5);
      await tester.pump();
      final half = tester.getRect(find.byKey(minimize));
      await backGesture(tester, 'updateBackGestureProgress', 1);
      await tester.pump();
      final full = tester.getRect(find.byKey(minimize));
      expect(half.top, greaterThan(0));
      expect(full.top, greaterThan(half.top));
      expect(full.top, lessThan(mini.top / 2));

      await backGesture(tester, 'cancelBackGesture');
      await tester.pumpAndSettle();
      expect(find.byKey(minimize), findsNothing);
      expect(
        tester.getRect(find.byKey(_sheet)),
        const Rect.fromLTWH(0, 0, 400, 800),
      );

      await backGesture(tester, 'startBackGesture', 0);
      await backGesture(tester, 'updateBackGestureProgress', 0.6);
      await tester.pump();
      final released = tester.getRect(find.byKey(minimize));
      await backGesture(tester, 'commitBackGesture');
      await tester.pump();
      expect(
        tester.getRect(find.byKey(minimize)).top,
        closeTo(released.top, 1),
      );
      await tester.pump(const Duration(milliseconds: 60));
      expect(
        tester.getRect(find.byKey(minimize)).top,
        greaterThan(released.top),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(_sheet), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('predictive back leaves a route above the player alone', (
      tester,
    ) async {
      final navigator = await pumpApp(tester);
      navigator.currentState!.push(route());
      await tester.pumpAndSettle();
      navigator.currentState!.push(
        MaterialPageRoute<void>(builder: (_) => const Text('Sheet')),
      );
      await tester.pumpAndSettle();
      await backGesture(tester, 'startBackGesture', 0);
      await backGesture(tester, 'updateBackGestureProgress', 0.5);
      await tester.pump();
      expect(find.byKey(minimize), findsNothing);
      await backGesture(tester, 'commitBackGesture');
      await tester.pumpAndSettle();
      // The system back closes the route on top, not the player.
      expect(find.text('Sheet'), findsNothing);
      expect(find.byKey(_sheet), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  for (final dismiss in [false, true]) {
    testWidgets('Player drag settles without a position jump (pop: $dismiss)', (
      tester,
    ) async {
      final navigator = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        MaterialApp(navigatorKey: navigator, home: const SizedBox()),
      );
      final route = _TestPlayerRoute();
      navigator.currentState!.push(route);
      await tester.pumpAndSettle();
      final height = tester.getSize(find.byKey(_sheet)).height;

      route.startDrag();
      route.updateDrag(
        DragUpdateDetails(
          globalPosition: Offset(0, height * 0.4),
          primaryDelta: height * 0.4,
          delta: Offset(0, height * 0.4),
        ),
        height,
      );
      await tester.pump();
      final releasedTop = tester.getTopLeft(find.byKey(_sheet)).dy;
      if (dismiss) {
        route.endDrag(DragEndDetails(primaryVelocity: 0), height);
      } else {
        route.cancelDrag();
      }
      await tester.pump();
      expect(
        tester.getTopLeft(find.byKey(_sheet)).dy,
        closeTo(releasedTop, 0.1),
      );

      var previousTop = releasedTop;
      for (var frame = 0; frame < 5; frame++) {
        await tester.pump(const Duration(milliseconds: 16));
        final top = tester.getTopLeft(find.byKey(_sheet)).dy;
        expect(top, dismiss ? greaterThan(previousTop) : lessThan(previousTop));
        previousTop = top;
      }
      await tester.pumpAndSettle();
      if (dismiss) {
        expect(find.byKey(_sheet), findsNothing);
      } else {
        expect(tester.getTopLeft(find.byKey(_sheet)).dy, 0);
      }
      expect(tester.takeException(), isNull);
    });
  }

  group('a released drag keeps the finger\'s velocity', () {
    const mini = Rect.fromLTWH(20, 700, 360, 64);

    /// How far [surface] moved in the first frame after a drag of [drag]
    /// (a fraction of the page) is let go at [velocity] pixels a second.
    Future<double> firstFrameTravel(
      WidgetTester tester, {
      required ThemeData theme,
      required double drag,
      required double velocity,
      required Key surface,
      bool geometry = false,
    }) async {
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final navigator = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigator,
          theme: theme,
          home: const SizedBox(),
        ),
      );
      final route = _TestPlayerRoute(
        miniPlayerGeometry: geometry
            ? () =>
                  (surface: mini, artwork: const Rect.fromLTWH(28, 710, 44, 44))
            : null,
      );
      navigator.currentState!.push(route);
      await tester.pumpAndSettle();
      route.startDrag();
      route.updateDrag(
        DragUpdateDetails(
          globalPosition: Offset(0, 800 * drag),
          primaryDelta: 800 * drag,
          delta: Offset(0, 800 * drag),
        ),
        800,
      );
      await tester.pump();
      route.endDrag(
        DragEndDetails(
          velocity: Velocity(pixelsPerSecond: Offset(0, velocity)),
          primaryVelocity: velocity,
        ),
        800,
      );
      await tester.pump();
      final released = tester.getTopLeft(find.byKey(surface)).dy;
      await tester.pump(const Duration(milliseconds: 16));
      final travel = tester.getTopLeft(find.byKey(surface)).dy - released;
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      return travel;
    }

    testWidgets('a Material page flung down closes faster than one let go', (
      tester,
    ) async {
      final still = await firstFrameTravel(
        tester,
        theme: AppTheme.light(),
        drag: 0.4,
        velocity: 0,
        surface: _sheet,
      );
      final flung = await firstFrameTravel(
        tester,
        theme: AppTheme.light(),
        drag: 0.4,
        velocity: 1500,
        surface: _sheet,
      );
      expect(still, greaterThan(0));
      // At 1500 px/s the finger covers 24 px in a 16 ms frame.
      expect(flung - still, greaterThan(12));
    });

    testWidgets('a page flung up settles open faster than one let go', (
      tester,
    ) async {
      for (final theme in [
        AppTheme.light(),
        MornyeTheme.build(Brightness.dark),
      ]) {
        final still = await firstFrameTravel(
          tester,
          theme: theme,
          drag: 0.2,
          velocity: 0,
          surface: _sheet,
        );
        final flung = await firstFrameTravel(
          tester,
          theme: theme,
          drag: 0.2,
          velocity: -1500,
          surface: _sheet,
        );
        expect(still, lessThan(0));
        expect(still - flung, greaterThan(12));
      }
    });

    testWidgets('the Mornye shrink starts from the finger\'s velocity', (
      tester,
    ) async {
      const minimize = ValueKey('player-minimize-surface');
      final still = await firstFrameTravel(
        tester,
        theme: MornyeTheme.build(Brightness.dark),
        drag: 0.4,
        velocity: 0,
        surface: minimize,
        geometry: true,
      );
      final flung = await firstFrameTravel(
        tester,
        theme: MornyeTheme.build(Brightness.dark),
        drag: 0.4,
        velocity: 1500,
        surface: minimize,
        geometry: true,
      );
      expect(still, greaterThan(0));
      expect(flung - still, greaterThan(8));
    });

    testWidgets('reduced motion settles a let-go drag at once', (tester) async {
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(disableAnimations: true);
      addTearDown(
        tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );
      final navigator = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        MaterialApp(navigatorKey: navigator, home: const SizedBox()),
      );
      final route = _TestPlayerRoute();
      navigator.currentState!.push(route);
      await tester.pumpAndSettle();
      route.startDrag();
      route.updateDrag(
        DragUpdateDetails(
          globalPosition: const Offset(0, 120),
          primaryDelta: 120,
          delta: const Offset(0, 120),
        ),
        600,
      );
      await tester.pump();
      route.endDrag(
        DragEndDetails(
          velocity: const Velocity(pixelsPerSecond: Offset(0, -900)),
          primaryVelocity: -900,
        ),
        600,
      );
      await tester.pump();
      expect(tester.getTopLeft(find.byKey(_sheet)).dy, 0);
      expect(tester.takeException(), isNull);
    });
  });

  // Issue 918: back closed the player while a finger was still on it. The
  // finger's release then drove the popped route back on screen, and the
  // next drag down popped the page below, leaving nothing.
  for (final late in ['cancel', 'drag', 'release']) {
    testWidgets('a touch that ends after the player closed changes nothing '
        '($late)', (tester) async {
      final navigator = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        MaterialApp(navigatorKey: navigator, home: const Text('Home')),
      );
      final route = _TestPlayerRoute();
      navigator.currentState!.push(route);
      await tester.pumpAndSettle();
      const height = 600.0;
      final down = DragUpdateDetails(
        globalPosition: const Offset(0, 300),
        primaryDelta: 300,
        delta: const Offset(0, 300),
      );
      if (late == 'release') {
        route.startDrag();
        route.updateDrag(down, height);
      }

      navigator.currentState!.pop();
      await tester.pump();
      switch (late) {
        case 'cancel':
          route.cancelDrag();
        case 'drag':
          route.startDrag();
          route.updateDrag(down, height);
          route.endDrag(DragEndDetails(primaryVelocity: 0), height);
        default:
          route.endDrag(DragEndDetails(primaryVelocity: 0), height);
      }
      await tester.pumpAndSettle();

      expect(find.byKey(_sheet), findsNothing);
      expect(find.text('Home'), findsOneWidget);
      expect(navigator.currentState!.canPop(), isFalse);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('a drag let go under another route does not pop that route', (
    tester,
  ) async {
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(navigatorKey: navigator, home: const Text('Home')),
    );
    final route = _TestPlayerRoute();
    navigator.currentState!.push(route);
    await tester.pumpAndSettle();
    route.startDrag();
    navigator.currentState!.push(
      MaterialPageRoute<void>(builder: (_) => const Text('Above')),
    );
    await tester.pumpAndSettle();
    route.endDrag(
      DragEndDetails(
        velocity: const Velocity(pixelsPerSecond: Offset(0, 2000)),
        primaryVelocity: 2000,
      ),
      600,
    );
    await tester.pumpAndSettle();
    expect(find.text('Above'), findsOneWidget);
    expect(route.isActive, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a moving player says so, and its landing cover too', (
    tester,
  ) async {
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        theme: MornyeTheme.build(Brightness.dark),
        home: const Text('Home'),
      ),
    );
    final route = _TestPlayerRoute(
      miniPlayerGeometry: () => (
        surface: const Rect.fromLTWH(16, 480, 300, 56),
        artwork: const Rect.fromLTWH(24, 488, 40, 40),
      ),
    );
    expect(NowPlayingRoute.moving.value, isFalse);
    navigator.currentState!.push(route);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(NowPlayingRoute.moving.value, isTrue);
    expect(NowPlayingRoute.coverLanding.value, isFalse);
    await tester.pumpAndSettle();
    expect(NowPlayingRoute.moving.value, isFalse);

    // A held drag keeps the page under the player a picture.
    route.startDrag();
    route.updateDrag(
      DragUpdateDetails(
        globalPosition: const Offset(0, 120),
        delta: const Offset(0, 120),
        primaryDelta: 120,
      ),
      600,
    );
    await tester.pump();
    expect(NowPlayingRoute.moving.value, isTrue);
    expect(NowPlayingRoute.coverLanding.value, isFalse);
    route.cancelDrag();
    await tester.pumpAndSettle();
    expect(NowPlayingRoute.moving.value, isFalse);

    route.readArtwork = () => (
      bounds: const Rect.fromLTWH(40, 80, 300, 300),
      child: const ColoredBox(color: Colors.red),
      fullBleed: false,
    );
    navigator.currentState!.pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(
      find.byKey(const ValueKey('player-minimize-artwork')),
      findsOneWidget,
    );
    expect(NowPlayingRoute.moving.value, isTrue);
    expect(NowPlayingRoute.coverLanding.value, isTrue);
    await tester.pumpAndSettle();
    expect(find.byKey(_sheet), findsNothing);
    expect(NowPlayingRoute.moving.value, isFalse);
    expect(NowPlayingRoute.coverLanding.value, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a player closed without a cover of its own leaves the mini '
      'player\'s alone', (tester) async {
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        theme: MornyeTheme.build(Brightness.dark),
        home: const Text('Home'),
      ),
    );
    final route = _TestPlayerRoute(
      miniPlayerGeometry: () => (
        surface: const Rect.fromLTWH(16, 480, 300, 56),
        artwork: const Rect.fromLTWH(24, 488, 40, 40),
      ),
    );
    navigator.currentState!.push(route);
    await tester.pumpAndSettle();
    navigator.currentState!.pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.byKey(const ValueKey('player-minimize-artwork')), findsNothing);
    expect(NowPlayingRoute.coverLanding.value, isFalse);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
