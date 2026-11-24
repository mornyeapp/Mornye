import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mornye/utils/adaptive_layout.dart';
import 'package:mornye/widgets/scaled_drag_proxy.dart';

Widget _app(double scale, {ReorderItemProxyDecorator? proxy}) => MaterialApp(
  builder: (context, child) =>
      AdaptiveUiScaler(userScale: scale, child: child!),
  home: Scaffold(
    body: CustomScrollView(
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.all(16),
          sliver: SliverReorderableList(
            itemCount: 5,
            onReorderItem: (_, _) {},
            proxyDecorator: proxy,
            itemBuilder: (context, index) => SizedBox(
              key: ValueKey(index),
              height: 60,
              child: Row(
                children: [
                  Expanded(child: Text('Row $index')),
                  ReorderableDragStartListener(
                    index: index,
                    child: ColoredBox(
                      key: ValueKey('handle-$index'),
                      color: Colors.transparent,
                      child: const SizedBox.square(dimension: 44),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    ),
  ),
);

void main() {
  void phone(WidgetTester tester) {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  for (final scale in [0.8, 1.0, 1.3]) {
    testWidgets('a dragged row stays under the finger at $scale', (
      tester,
    ) async {
      phone(tester);
      await tester.pumpWidget(_app(scale, proxy: ScaledDragProxy.plain));
      final row = find.byKey(const ValueKey(2));
      final before = tester.getRect(row);

      final drag = await tester.startGesture(
        tester.getCenter(find.byKey(const ValueKey('handle-2'))),
      );
      await tester.pump();
      await drag.moveBy(const Offset(0, 20));
      await drag.moveBy(const Offset(3, 20));
      await tester.pump();
      // The row follows the finger down and keeps its place across.
      final held = tester.getRect(row);
      expect(held.left, closeTo(before.left, 0.5));
      expect(held.top, closeTo(before.top + 40, 0.5));
      expect(held.width, closeTo(before.width, 0.5));
      expect(held.height, closeTo(before.height, 0.5));

      // It returns to its row without sliding sideways on the way.
      await drag.up();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      final dropping = tester.getRect(row);
      expect(dropping.left, closeTo(before.left, 0.5));
      expect(dropping.top, inInclusiveRange(before.top, before.top + 40));
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(row).dy, closeTo(before.top, 0.5));
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('without the proxy a scaled page draws the row elsewhere', (
    tester,
  ) async {
    phone(tester);
    await tester.pumpWidget(_app(0.8));
    final row = find.byKey(const ValueKey(2));
    final before = tester.getRect(row);
    final drag = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey('handle-2'))),
    );
    await tester.pump();
    await drag.moveBy(const Offset(0, 40));
    await tester.pump();
    // Flutter's own placement, which this widget exists to correct.
    expect(tester.getRect(row).left, lessThan(before.left - 20));
    await drag.up();
    await tester.pumpAndSettle();
  });
}
