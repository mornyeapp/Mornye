import 'package:cupertino_ui/cupertino_ui.dart'
    show CupertinoActivityIndicator, CupertinoSliverRefreshControl;
import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/theme/app_theme.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/widgets/app_refresh_indicator.dart';
import 'package:mornye/widgets/app_sliver_header.dart';

void main() {
  final macOS = TargetPlatformVariant.only(TargetPlatform.macOS);
  late int refreshes;
  late ScrollController scroll;

  Future<void> pumpPage(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    refreshes = 0;
    scroll = ScrollController();
    addTearDown(scroll.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark(),
        // The app's macOS scrolling: lists bounce past their edges.
        scrollBehavior: const MaterialScrollBehavior().copyWith(
          physics: const BouncingScrollPhysics(
            parent: AlwaysScrollableScrollPhysics(),
          ),
        ),
        home: Scaffold(
          body: AppRefreshIndicator(
            onRefresh: () async {
              refreshes++;
              await Future<void>.delayed(const Duration(milliseconds: 300));
            },
            child: CustomScrollView(
              controller: scroll,
              slivers: [
                const AppSliverHeader.tabRoot(title: 'Page'),
                SliverList.builder(
                  itemCount: 40,
                  itemBuilder: (_, i) =>
                      SizedBox(height: 80, child: Text('row $i')),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// A two-finger trackpad pan through [path] (total pan, downward
  /// positive), checking the list after every step.
  Future<void> pan(
    WidgetTester tester,
    List<double> path, {
    void Function()? check,
  }) async {
    final gesture = await tester.createGesture(
      kind: PointerDeviceKind.trackpad,
    );
    await gesture.panZoomStart(const Offset(400, 400));
    for (final y in path) {
      await gesture.panZoomUpdate(const Offset(400, 400), pan: Offset(0, y));
      await tester.pump(const Duration(milliseconds: 16));
      check?.call();
    }
    await gesture.panZoomEnd();
  }

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 120; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
  }

  testWidgets('a pull the indicator ignores leaves no gap', (tester) async {
    await pumpPage(tester);
    await pan(tester, [40, 80, 120, 160, 200]);
    await tester.pump(const Duration(milliseconds: 50));
    expect(refreshes, 1);

    // The indicator ignores a pull while it is busy; the list must not
    // bounce below the pinned header either.
    await pan(tester, [
      40,
      80,
      120,
      160,
    ], check: () => expect(scroll.position.pixels, 0));
    await settle(tester);
    expect(refreshes, 1);
  }, variant: macOS);

  testWidgets('pushing a pull back shrinks it before the list scrolls', (
    tester,
  ) async {
    await pumpPage(tester);
    await pan(tester, [
      40,
      80,
      120,
      160,
      120,
      60,
      20,
    ], check: () => expect(scroll.offset, 0));
    await settle(tester);
    expect(scroll.offset, 0);

    // Past the start of the pull, the list scrolls as usual.
    await pan(tester, [40, 80, 40, 0, -40, -80]);
    await settle(tester);
    expect(scroll.offset, greaterThan(0));
  }, variant: macOS);

  testWidgets('refreshVisible refreshes the page on screen', (tester) async {
    await pumpPage(tester);
    expect(AppRefreshIndicator.refreshVisible(), isTrue);
    await settle(tester);
    expect(refreshes, 1);
  }, variant: macOS);

  group('Mornye', () {
    Future<void> pumpMornye(
      WidgetTester tester, {
      required bool bounces,
      bool mornye = true,
    }) async {
      refreshes = 0;
      await tester.pumpWidget(
        MaterialApp(
          theme: mornye ? MornyeTheme.build(Brightness.light) : null,
          // Phones bounce unless the low-end profile turns overscroll off.
          scrollBehavior: const MaterialScrollBehavior().copyWith(
            physics: bounces
                ? const BouncingScrollPhysics(
                    parent: AlwaysScrollableScrollPhysics(),
                  )
                : const ClampingScrollPhysics(
                    parent: AlwaysScrollableScrollPhysics(),
                  ),
          ),
          home: Scaffold(
            body: AppRefreshIndicator(
              onRefresh: () async {
                refreshes++;
                await Future<void>.delayed(const Duration(milliseconds: 300));
              },
              child: CustomScrollView(
                slivers: [
                  const AppSliverHeader.page(title: 'Page'),
                  AppRefreshIndicator.sliver(),
                  SliverList.builder(
                    itemCount: 40,
                    itemBuilder: (_, i) =>
                        SizedBox(height: 80, child: Text('row $i')),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    Future<void> pull(WidgetTester tester) async {
      final gesture = await tester.startGesture(
        tester.getCenter(find.text('row 2')),
      );
      for (var i = 0; i < 8; i++) {
        await gesture.moveBy(const Offset(0, 40));
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(find.byType(CupertinoActivityIndicator), findsOneWidget);
      expect(find.byType(RefreshProgressIndicator), findsNothing);
      await gesture.up();
    }

    testWidgets('pulls with the iOS refresh control', (tester) async {
      await pumpMornye(tester, bounces: true);
      expect(find.byType(RefreshIndicator), findsNothing);
      await pull(tester);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(refreshes, 1);
      await settle(tester);
      expect(find.byType(CupertinoActivityIndicator), findsNothing);
    });

    testWidgets('keeps the indicator when lists do not bounce', (tester) async {
      await pumpMornye(tester, bounces: false);
      expect(find.byType(RefreshIndicator), findsOneWidget);
      expect(find.byType(CupertinoSliverRefreshControl), findsNothing);
    });

    testWidgets('Material leaves the sliver empty', (tester) async {
      await pumpMornye(tester, bounces: true, mornye: false);
      expect(find.byType(CupertinoSliverRefreshControl), findsNothing);
    });
  });
}
