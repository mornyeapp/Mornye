import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/widgets/library_fast_scroller.dart';

void main() {
  Widget host({
    required ScrollController controller,
    int itemCount = 400,
    bool mornye = false,
  }) => MaterialApp(
    theme: mornye ? MornyeTheme.build(Brightness.light) : null,
    home: Scaffold(
      body: LibraryFastScroller(
        labelAt: (fraction) =>
            String.fromCharCode(65 + (fraction * 25).round()),
        child: ListView.builder(
          controller: controller,
          itemExtent: 56,
          itemCount: itemCount,
          itemBuilder: (context, index) => Text('Row $index'),
        ),
      ),
    ),
  );

  Finder thumb() => find.byWidgetPredicate(
    (widget) =>
        widget is GestureDetector && widget.onVerticalDragUpdate != null,
  );

  for (final platform in [
    TargetPlatform.windows,
    TargetPlatform.macOS,
    TargetPlatform.linux,
  ]) {
    for (final mornye in [false, true]) {
      testWidgets('one desktop scrollbar on $platform (mornye: $mornye)', (
        tester,
      ) async {
        final controller = ScrollController();
        addTearDown(controller.dispose);
        final nativeScrollbar = find.byWidgetPredicate(
          (widget) => widget is RawScrollbar,
        );
        await tester.pumpWidget(host(controller: controller, mornye: mornye));
        await tester.pumpAndSettle();
        controller.jumpTo(10);
        await tester.pump();
        expect(thumb(), findsOneWidget);
        expect(nativeScrollbar, findsNothing);

        await tester.pumpWidget(const SizedBox());
        await tester.pumpWidget(
          host(controller: controller, itemCount: 20, mornye: mornye),
        );
        await tester.pumpAndSettle();
        expect(controller.position.maxScrollExtent, lessThan(1000));
        expect(thumb(), findsNothing);
        expect(nativeScrollbar, findsOneWidget);
        expect(controller.position.maxScrollExtent, greaterThan(0));
        controller.jumpTo(100);
        await tester.pump();
        expect(controller.offset, 100);
        expect(tester.takeException(), isNull);
      }, variant: TargetPlatformVariant({platform}));
    }
  }

  testWidgets('dragging the thumb scrolls and names the section', (
    tester,
  ) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(host(controller: controller));
    // The thumb appears once the list scrolls.
    controller.jumpTo(10);
    await tester.pump();
    expect(thumb(), findsOneWidget);

    final gesture = await tester.startGesture(tester.getCenter(thumb()));
    await gesture.moveBy(const Offset(0, 20));
    await tester.pump();
    await gesture.moveBy(const Offset(0, 260));
    await tester.pump();
    expect(controller.offset, greaterThan(1000));
    expect(find.textContaining(RegExp(r'^[A-Z]$')), findsOneWidget);

    await gesture.moveBy(const Offset(0, 2000));
    await tester.pump();
    expect(controller.offset, controller.position.maxScrollExtent);
    await gesture.up();
    await tester.pump(const Duration(seconds: 2));
    expect(find.textContaining(RegExp(r'^[A-Z]$')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('thumb follows the actual scroll position', (tester) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(host(controller: controller));
    final track = tester.getSize(find.byType(LibraryFastScroller)).height;
    for (final fraction in [0.25, 0.5, 0.75, 1.0]) {
      controller.jumpTo(controller.position.maxScrollExtent * fraction);
      await tester.pump();
      expect(
        tester.getTopLeft(thumb()).dy,
        closeTo((track - 52) * fraction, 1),
      );
    }
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('small drags stay precise with ten thousand songs', (
    tester,
  ) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(host(controller: controller, itemCount: 10000));
    controller.jumpTo(1000);
    await tester.pump();
    final gesture = await tester.startGesture(tester.getCenter(thumb()));
    await gesture.moveBy(
      const Offset(0, 20),
      timeStamp: const Duration(milliseconds: 16),
    );
    await tester.pump();
    final before = controller.offset;
    await gesture.moveBy(
      const Offset(0, 2),
      timeStamp: const Duration(milliseconds: 116),
    );
    await tester.pump();
    expect(controller.offset - before, inInclusiveRange(1, 64));
    final beforeNudge = controller.offset;
    await gesture.moveBy(
      const Offset(0, 2),
      timeStamp: const Duration(milliseconds: 117),
    );
    await tester.pump();
    expect(controller.offset - beforeNudge, inInclusiveRange(1, 64));
    // A deliberate quick sweep still reaches the end of the library.
    await gesture.moveBy(
      const Offset(0, 700),
      timeStamp: const Duration(milliseconds: 132),
    );
    await tester.pump();
    expect(controller.offset, controller.position.maxScrollExtent);
    await gesture.up();
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('new pages update the thumb without moving a held list', (
    tester,
  ) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(host(controller: controller, itemCount: 80));
    controller.jumpTo(1000);
    await tester.pump();
    final gesture = await tester.startGesture(tester.getCenter(thumb()));
    await gesture.moveBy(
      const Offset(0, 20),
      timeStamp: const Duration(milliseconds: 16),
    );
    await tester.pump();
    final before = controller.offset;
    await tester.pumpWidget(host(controller: controller, itemCount: 160));
    await tester.pump();
    expect(controller.offset, before);
    final track = tester.getSize(find.byType(LibraryFastScroller)).height;
    expect(
      tester.getTopLeft(thumb()).dy,
      closeTo((track - 52) * before / controller.position.maxScrollExtent, 1),
    );
    await gesture.moveBy(
      const Offset(0, 2),
      timeStamp: const Duration(milliseconds: 116),
    );
    await tester.pump();
    expect(controller.offset - before, inInclusiveRange(1, 64));
    await gesture.up();
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('short lists show no thumb', (tester) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(host(controller: controller, itemCount: 20));
    controller.jumpTo(10);
    await tester.pump();
    expect(thumb(), findsNothing);
  });

  testWidgets('scrolling keeps the thumb visible without per-frame timers', (
    tester,
  ) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(host(controller: controller));
    var hideTimers = 0;
    double opacity() => tester
        .widget<AnimatedOpacity>(
          find.descendant(of: thumb(), matching: find.byType(AnimatedOpacity)),
        )
        .opacity;

    await runZoned(
      () async {
        final gesture = await tester.startGesture(const Offset(200, 450));
        for (var index = 0; index < 100; index++) {
          await gesture.moveBy(const Offset(0, -2));
          await tester.pump(const Duration(milliseconds: 16));
        }
        expect(controller.offset, greaterThan(100));
        expect(opacity(), 1);
        expect(hideTimers, 0);

        await tester.pump(const Duration(seconds: 2));
        expect(opacity(), 1);
        await gesture.up();
        await tester.pump();
        expect(hideTimers, 1);
        expect(opacity(), 1);
        await tester.pump(const Duration(milliseconds: 1400));
        expect(opacity(), 1);
        await tester.pump(const Duration(milliseconds: 100));
        expect(opacity(), 0);
        await tester.pumpAndSettle();
      },
      zoneSpecification: ZoneSpecification(
        createTimer: (self, parent, zone, duration, callback) {
          if (duration == const Duration(milliseconds: 1500)) hideTimers++;
          return parent.createTimer(zone, duration, callback);
        },
      ),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('short lists allocate no thumb hide timers while scrolling', (
    tester,
  ) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(host(controller: controller, itemCount: 20));
    var hideTimers = 0;
    await runZoned(
      () async {
        for (var index = 1; index <= 30; index++) {
          controller.jumpTo(index * 10);
          await tester.pump();
        }
      },
      zoneSpecification: ZoneSpecification(
        createTimer: (self, parent, zone, duration, callback) {
          if (duration == const Duration(milliseconds: 1500)) hideTimers++;
          return parent.createTimer(zone, duration, callback);
        },
      ),
    );
    expect(hideTimers, 0);
    expect(thumb(), findsNothing);
  });

  testWidgets('thumb and date bubble stay clear of the pinned Library header', (
    tester,
  ) async {
    final outer = ScrollController();
    addTearDown(outer.dispose);
    const bottomInset = 100.0;
    const topInset = 24.0;
    const headerExtent = kToolbarHeight + topInset;
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: TextScaler.linear(1.8),
            padding: const EdgeInsets.only(top: topInset),
            viewPadding: const EdgeInsets.only(top: topInset),
          ),
          child: child!,
        ),
        home: Scaffold(
          body: NestedScrollView(
            controller: outer,
            headerSliverBuilder: (context, _) => [
              const SliverAppBar(
                pinned: true,
                expandedHeight: 200,
                title: Text('Library'),
              ),
              const SliverToBoxAdapter(child: SizedBox(height: 100)),
            ],
            body: LibraryFastScroller(
              topPadding: headerExtent,
              bottomPadding: bottomInset,
              labelAt: (_) => 'October 2026',
              child: ListView.builder(
                itemExtent: 56,
                itemCount: 400,
                itemBuilder: (_, index) => Text('Row $index'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final inner = tester
        .state<ScrollableState>(
          find.descendant(
            of: find.byType(LibraryFastScroller),
            matching: find.byType(Scrollable),
          ),
        )
        .position;
    outer.jumpTo(outer.position.maxScrollExtent);
    inner.jumpTo(1);
    await tester.pump();
    expect(tester.getTopLeft(thumb()).dy, greaterThanOrEqualTo(headerExtent));

    final gesture = await tester.startGesture(tester.getCenter(thumb()));
    await gesture.moveBy(const Offset(0, 20));
    await tester.pump(const Duration(seconds: 1));
    final bubble = find.byKey(const ValueKey('library-scroll-bubble'));
    expect(bubble, findsOneWidget);
    expect(
      tester.getTopLeft(bubble).dy,
      greaterThanOrEqualTo(headerExtent + 8),
    );
    inner.jumpTo(inner.maxScrollExtent);
    await tester.pump(const Duration(seconds: 1));
    final body = tester.getRect(find.byType(LibraryFastScroller));
    expect(
      tester.getBottomRight(bubble).dy,
      lessThanOrEqualTo(body.bottom - bottomInset - 8),
    );
    await gesture.up();
    await tester.pump(const Duration(seconds: 2));

    // An expanded header already puts the body below it; no extra gap is needed.
    inner.jumpTo(0);
    outer.jumpTo(0);
    await tester.pump();
    final expandedBody = tester.getRect(find.byType(LibraryFastScroller));
    expect(tester.getTopLeft(thumb()).dy, closeTo(expandedBody.top, 1));
    expect(tester.takeException(), isNull);
  });
}
