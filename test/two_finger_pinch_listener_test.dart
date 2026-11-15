import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/widgets/two_finger_pinch_listener.dart';

void main() {
  Widget buildHarness({
    required ScrollController controller,
    required VoidCallback onStart,
    required ValueChanged<double> onUpdate,
    required VoidCallback onEnd,
  }) {
    return MaterialApp(
      home: Scaffold(
        body: TwoFingerPinchListener(
          onStart: onStart,
          onUpdate: onUpdate,
          onEnd: onEnd,
          child: ListView.builder(
            controller: controller,
            itemExtent: 80,
            itemCount: 30,
            itemBuilder: (context, index) => Text('Track $index'),
          ),
        ),
      ),
    );
  }

  testWidgets('does not compete with one-finger vertical scrolling', (
    tester,
  ) async {
    final controller = ScrollController();
    var pinchStarts = 0;
    final scales = <double>[];

    await tester.pumpWidget(
      buildHarness(
        controller: controller,
        onStart: () => pinchStarts++,
        onUpdate: scales.add,
        onEnd: () {},
      ),
    );

    await tester.drag(find.text('Track 2'), const Offset(0, -240));
    await tester.pumpAndSettle();

    expect(controller.offset, greaterThan(0));
    expect(pinchStarts, 0);
    expect(scales, isEmpty);
    controller.dispose();
  });

  testWidgets('reports scale only after two touch pointers are down', (
    tester,
  ) async {
    final controller = ScrollController();
    var pinchStarts = 0;
    var pinchEnds = 0;
    final scales = <double>[];

    await tester.pumpWidget(
      buildHarness(
        controller: controller,
        onStart: () => pinchStarts++,
        onUpdate: scales.add,
        onEnd: () => pinchEnds++,
      ),
    );

    final first = await tester.startGesture(const Offset(150, 300), pointer: 1);
    expect(pinchStarts, 0);

    final second = await tester.startGesture(
      const Offset(250, 300),
      pointer: 2,
    );
    expect(pinchStarts, 1);

    await first.moveTo(const Offset(125, 300));
    await second.moveTo(const Offset(275, 300));
    await tester.pump();

    expect(scales, isNotEmpty);
    expect(scales.last, greaterThan(1));

    await first.up();
    await second.up();
    expect(pinchEnds, 1);
    controller.dispose();
  });
}
