import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
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
