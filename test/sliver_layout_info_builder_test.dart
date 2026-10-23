import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/widgets/album_detail_header.dart';
import 'package:mornye/widgets/mornye_artist_header.dart';
import 'package:mornye/widgets/sliver_layout_info_builder.dart';

/// A short header, then [sliver], in a scroll view taller than the content
/// above it so dragging changes the sliver's scroll offset every frame.
Widget _scrollView(Widget sliver, {ScrollController? controller}) =>
    MaterialApp(
      home: Scaffold(
        body: CustomScrollView(
          controller: controller,
          slivers: [
            const SliverToBoxAdapter(child: SizedBox(height: 100)),
            sliver,
            const SliverToBoxAdapter(child: SizedBox(height: 2000)),
          ],
        ),
      ),
    );

Future<void> _dragFrames(WidgetTester tester, int frames) async {
  final gesture = await tester.startGesture(const Offset(200, 500));
  for (var i = 0; i < frames; i++) {
    await gesture.moveBy(const Offset(0, -8));
    await tester.pump();
  }
  await gesture.up();
  await tester.pumpAndSettle();
}

/// Twelve tiles: all of them stay inside the cache extent while dragging.
Widget _grid(void Function() onItem) => SliverGrid.builder(
  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
    crossAxisCount: 3,
    mainAxisExtent: 40,
  ),
  itemCount: 12,
  itemBuilder: (context, index) {
    onItem();
    return Text('$index');
  },
);

void main() {
  testWidgets('SliverLayoutBuilder rebuilds its grid on every scroll frame', (
    tester,
  ) async {
    var builds = 0;
    var items = 0;
    await tester.pumpWidget(
      _scrollView(
        SliverLayoutBuilder(
          builder: (context, constraints) {
            builds++;
            return _grid(() => items++);
          },
        ),
      ),
    );
    expect(builds, 1);
    expect(items, 12);
    await _dragFrames(tester, 10);
    // The SDK baseline this widget avoids.
    expect(builds, greaterThanOrEqualTo(10));
    expect(items, greaterThanOrEqualTo(12 * 10));
  });

  testWidgets('a width-derived grid builds once while scrolling', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final widths = <double>[];
    var items = 0;
    await tester.pumpWidget(
      _scrollView(
        SliverLayoutInfoBuilder(
          select: (constraints) => constraints.crossAxisExtent,
          builder: (context, width) {
            widths.add(width);
            return _grid(() => items++);
          },
        ),
      ),
    );
    expect(widths, [400]);
    expect(items, 12);
    await _dragFrames(tester, 10);
    expect(widths, [400]);
    expect(items, 12);
    expect(find.text('11'), findsOneWidget);

    tester.view.physicalSize = const Size(600, 800);
    await tester.pump();
    expect(widths, [400, 600]);
  });

  testWidgets('a collapsed flag rebuilds only when the threshold is crossed', (
    tester,
  ) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    final values = <bool>[];
    await tester.pumpWidget(
      _scrollView(
        SliverLayoutInfoBuilder(
          select: (constraints) => constraints.scrollOffset >= 50,
          builder: (context, collapsed) {
            values.add(collapsed);
            return SliverToBoxAdapter(
              child: SizedBox(height: 200, child: Text('collapsed $collapsed')),
            );
          },
        ),
        controller: controller,
      ),
    );
    for (final offset in [20.0, 100.0, 149.0, 150.0, 151.0, 180.0, 120.0]) {
      controller.jumpTo(offset);
      await tester.pump();
    }
    // The sliver starts at 100, so its own offset reaches 50 at 150.
    expect(values, [false, true, false]);
    expect(find.text('collapsed false'), findsOneWidget);
  });

  testWidgets('inherited dependencies still rebuild the builder', (
    tester,
  ) async {
    final scaler = ValueNotifier(TextScaler.noScaling);
    addTearDown(scaler.dispose);
    final scales = <double>[];
    await tester.pumpWidget(
      ValueListenableBuilder<TextScaler>(
        valueListenable: scaler,
        builder: (context, value, child) => MediaQuery(
          data: MediaQueryData(textScaler: value),
          child: child!,
        ),
        child: _scrollView(
          SliverLayoutInfoBuilder(
            select: (constraints) => constraints.crossAxisExtent,
            builder: (context, width) {
              scales.add(MediaQuery.textScalerOf(context).scale(10));
              return const SliverToBoxAdapter(child: SizedBox(height: 10));
            },
          ),
        ),
      ),
    );
    scaler.value = const TextScaler.linear(2);
    await tester.pump();
    expect(scales, [10, 20]);
  });

  testWidgets(
    'immersive album toolbar and back button persist while scrolling',
    (tester) async {
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final controller = ScrollController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            theme: MornyeTheme.build(Brightness.dark),
            home: Scaffold(
              body: CustomScrollView(
                controller: controller,
                slivers: [
                  const AlbumDetailHeader(
                    title: 'Album title',
                    expandedHeight: 400,
                    showTitleInAppBar: false,
                    immersive: true,
                    background: ColoredBox(color: Colors.orange),
                  ),
                  const SliverToBoxAdapter(child: SizedBox(height: 2000)),
                ],
              ),
            ),
          ),
        ),
      );
      final appBar = find.byType(SliverAppBar, skipOffstage: false);
      final back = find.byType(HeaderCircleButton, skipOffstage: false);
      final firstBar = tester.widget(appBar);
      final firstBack = tester.widget(back);
      // The toolbar collapses at 400 - 20 - kToolbarHeight = 324.
      for (final offset in [40.0, 120.0, 250.0, 323.0]) {
        controller.jumpTo(offset);
        await tester.pump();
        expect(tester.widget(appBar), same(firstBar));
        expect(tester.widget(back), same(firstBack));
      }
      controller.jumpTo(324);
      await tester.pump();
      final collapsedBar = tester.widget<SliverAppBar>(appBar);
      expect(collapsedBar, isNot(same(firstBar)));
      expect(collapsedBar.backgroundColor, isNot(Colors.transparent));
      expect(tester.widget(back), same(firstBack));
      for (final offset in [400.0, 700.0]) {
        controller.jumpTo(offset);
        await tester.pump();
        expect(tester.widget(appBar), same(collapsedBar));
      }
    },
  );

  testWidgets('artist header is not rebuilt by scrolling or title flips', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final controller = ScrollController();
    addTearDown(controller.dispose);
    final showTitle = ValueNotifier(false);
    addTearDown(showTitle.dispose);
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: MornyeTheme.build(Brightness.dark),
          home: Scaffold(
            body: CustomScrollView(
              controller: controller,
              slivers: [
                MornyeArtistHeader(
                  name: 'Artist',
                  artwork: const ColoredBox(color: Colors.orange),
                  actions: const [],
                  showTitle: false,
                  showTitleListenable: showTitle,
                ),
                const SliverToBoxAdapter(child: SizedBox(height: 2000)),
              ],
            ),
          ),
        ),
      ),
    );
    final appBar = find.byType(SliverAppBar, skipOffstage: false);
    final firstBar = tester.widget(appBar);
    final title = find.ancestor(
      of: find.descendant(
        of: find.byType(NavigationToolbar, skipOffstage: false),
        matching: find.text('Artist', skipOffstage: false),
      ),
      matching: find.byType(AnimatedOpacity, skipOffstage: false),
    );
    for (final offset in [60.0, 200.0, 500.0]) {
      controller.jumpTo(offset);
      await tester.pump();
      expect(tester.widget(appBar), same(firstBar));
    }
    expect(tester.widget<AnimatedOpacity>(title).opacity, 0);
    showTitle.value = true;
    await tester.pump();
    expect(tester.widget(appBar), same(firstBar));
    expect(tester.widget<AnimatedOpacity>(title).opacity, 1);
  });
}
