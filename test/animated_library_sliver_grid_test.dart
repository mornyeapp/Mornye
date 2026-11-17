import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/widgets/animated_library_sliver_grid.dart';

void main() {
  testWidgets(
    'pinch extent updates only the grid and does not trail gestures',
    (tester) async {
      final extent = ValueNotifier(120.0);
      addTearDown(extent.dispose);
      var screenBuilds = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              screenBuilds++;
              return CustomScrollView(
                slivers: [
                  AnimatedLibrarySliverGrid(
                    maxCrossAxisExtent: 120,
                    extentListenable: extent,
                    mainAxisSpacing: 8,
                    crossAxisSpacing: 8,
                    childAspectRatio: 1,
                    delegate: SliverChildBuilderDelegate(
                      (context, index) => Text('Track $index'),
                      childCount: 200,
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      );
      final initialBuilds = screenBuilds;
      for (final size in [140.0, 160.0, 190.0]) {
        extent.value = size;
        await tester.pump();
        final grid = tester.widget<SliverGrid>(find.byType(SliverGrid));
        expect(
          (grid.gridDelegate as SliverGridDelegateWithMaxCrossAxisExtent)
              .maxCrossAxisExtent,
          size,
        );
        expect(screenBuilds, initialBuilds);
        expect(tester.binding.transientCallbackCount, 0);
      }
    },
  );

  for (final mornye in [false, true]) {
    testWidgets(
      'a changed extent springs without overshoot and an interrupted one '
      'goes on from the extent on screen (${mornye ? 'Mornye' : 'Material'})',
      (tester) async {
        Widget grid(double extent) => MaterialApp(
          theme: mornye ? MornyeTheme.build(Brightness.light) : ThemeData(),
          home: CustomScrollView(
            slivers: [
              AnimatedLibrarySliverGrid(
                maxCrossAxisExtent: extent,
                mainAxisSpacing: 8,
                crossAxisSpacing: 8,
                childAspectRatio: 1,
                delegate: SliverChildBuilderDelegate(
                  (context, index) => Text('Track $index'),
                  childCount: 20,
                ),
              ),
            ],
          ),
        );
        double current() =>
            (tester.widget<SliverGrid>(find.byType(SliverGrid)).gridDelegate
                    as SliverGridDelegateWithMaxCrossAxisExtent)
                .maxCrossAxisExtent;

        await tester.pumpWidget(grid(120));
        // Let the app's theme animation reach the chosen theme.
        await tester.pump(const Duration(seconds: 1));
        await tester.pumpWidget(grid(200));
        var highest = current();
        for (var frame = 0; frame < 4; frame++) {
          await tester.pump(const Duration(milliseconds: 16));
          highest = highest > current() ? highest : current();
        }
        final midway = current();
        expect(midway, inExclusiveRange(120, 200));

        // Back the other way: the first frame starts where the grid is.
        await tester.pumpWidget(grid(120));
        expect(current(), closeTo(midway, 0.01));
        var lowest = current();
        for (var frame = 0; frame < 60; frame++) {
          await tester.pump(const Duration(milliseconds: 16));
          lowest = lowest < current() ? lowest : current();
        }
        expect(highest, lessThan(200.01));
        // An overshoot below 120 would flip the column count twice.
        expect(lowest, greaterThan(120 - 0.2));
        await tester.pumpAndSettle();
        expect(current(), 120);
      },
    );
  }

  testWidgets('reduced motion applies a changed extent immediately', (
    tester,
  ) async {
    Widget grid(double extent) => MaterialApp(
      home: MediaQuery(
        data: const MediaQueryData(disableAnimations: true),
        child: CustomScrollView(
          slivers: [
            AnimatedLibrarySliverGrid(
              maxCrossAxisExtent: extent,
              mainAxisSpacing: 8,
              crossAxisSpacing: 8,
              childAspectRatio: 1,
              delegate: SliverChildBuilderDelegate(
                (context, index) => Text('Track $index'),
                childCount: 20,
              ),
            ),
          ],
        ),
      ),
    );
    await tester.pumpWidget(grid(120));
    await tester.pumpWidget(grid(200));
    final widget = tester.widget<SliverGrid>(find.byType(SliverGrid));
    expect(
      (widget.gridDelegate as SliverGridDelegateWithMaxCrossAxisExtent)
          .maxCrossAxisExtent,
      200,
    );
    expect(tester.binding.transientCallbackCount, 0);
  });
}
