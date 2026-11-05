import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/screens/now_playing_screen.dart';
import 'package:mornye/theme/mornye_theme.dart';

const _sheet = Key('player-sheet');

class _TestPlayerRoute extends NowPlayingRoute {
  _TestPlayerRoute({super.miniPlayerGeometry}) : super(child: const SizedBox());

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
}
