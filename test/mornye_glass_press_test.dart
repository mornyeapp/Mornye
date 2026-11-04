import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/widgets/mornye_glass_press.dart';

void main() {
  const box = ValueKey('glass');

  Future<void> pumpPress(
    WidgetTester tester, {
    required VoidCallback onTap,
    bool reduceMotion = false,
    bool enabled = true,
  }) => tester.pumpWidget(
    MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(disableAnimations: reduceMotion),
        child: Scaffold(
          body: Center(
            child: MornyeGlassPress(
              radius: 18,
              enabled: enabled,
              child: GestureDetector(
                key: box,
                onTap: onTap,
                child: const SizedBox.square(
                  dimension: 36,
                  child: ColoredBox(color: Colors.grey),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );

  /// Lets the spring reach the pressed state; it starts on the first frame.
  Future<void> hold(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
  }

  /// The control's paint transform, or null while it is at rest.
  Matrix4? deformation(WidgetTester tester) {
    final transforms = find.ancestor(
      of: find.byKey(box),
      matching: find.byWidgetPredicate(
        (widget) => widget is Transform && !widget.transformHitTests,
      ),
    );
    if (transforms.evaluate().isEmpty) return null;
    final matrix = tester.widget<Transform>(transforms).transform;
    return matrix.isIdentity() ? null : matrix;
  }

  testWidgets('swells under a press, keeps its target and rests with no '
      'ticker', (tester) async {
    var taps = 0;
    await pumpPress(tester, onTap: () => taps++);
    final bounds = tester.getRect(find.byKey(box));
    expect(deformation(tester), isNull);

    final press = await tester.startGesture(bounds.center);
    await hold(tester);
    final held = deformation(tester)!.getMaxScaleOnAxis();
    expect(held, closeTo(1 + 3.6 / 36, 0.01));
    // Layout and the hit target stay at rest.
    expect(tester.renderObject<RenderBox>(find.byKey(box)).size.width, 36);

    await press.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    expect(deformation(tester)!.getMaxScaleOnAxis(), lessThan(held));
    await tester.pumpAndSettle();
    expect(taps, 1);
    expect(deformation(tester), isNull);
    expect(tester.binding.transientCallbackCount, 0);
  });

  testWidgets('wobbles past rest on release', (tester) async {
    await pumpPress(tester, onTap: () {});
    final center = tester.getCenter(find.byKey(box));
    final press = await tester.startGesture(center);
    await hold(tester);
    await press.up();
    await tester.pump();

    var lowest = double.infinity;
    for (var frame = 0; frame < 60; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
      final matrix = deformation(tester);
      if (matrix != null) {
        lowest = lowest < matrix.entry(0, 0) ? lowest : matrix.entry(0, 0);
      }
    }
    expect(lowest, lessThan(1));
    await tester.pumpAndSettle();
  });

  testWidgets('leans along a drag and drops it on cancel', (tester) async {
    var taps = 0;
    await pumpPress(tester, onTap: () => taps++);
    final center = tester.getCenter(find.byKey(box));
    final press = await tester.startGesture(center);
    await hold(tester);
    await press.moveBy(const Offset(40, 0));
    await tester.pump();
    final matrix = deformation(tester)!;
    expect(matrix.entry(0, 0), greaterThan(matrix.entry(1, 1)));
    expect(matrix.getTranslation().x, greaterThan(0));

    await press.cancel();
    await tester.pumpAndSettle();
    expect(taps, 0);
    expect(deformation(tester), isNull);
  });

  testWidgets('a mouse over it lifts it a little', (tester) async {
    await pumpPress(tester, onTap: () {});
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(find.byKey(box)));
    await tester.pumpAndSettle();
    expect(
      deformation(tester)!.getMaxScaleOnAxis(),
      closeTo(1 + 0.3 * 3.6 / 36, 0.01),
    );
    await mouse.moveTo(Offset.zero);
    await tester.pumpAndSettle();
    expect(deformation(tester), isNull);
  });

  testWidgets('Reduce Motion keeps the shape still', (tester) async {
    var taps = 0;
    await pumpPress(tester, onTap: () => taps++, reduceMotion: true);
    final press = await tester.startGesture(tester.getCenter(find.byKey(box)));
    await tester.pump();
    expect(deformation(tester), isNull);
    await press.up();
    await tester.pump();
    expect(taps, 1);
    expect(tester.binding.transientCallbackCount, 0);
  });

  testWidgets('a disabled control stays still', (tester) async {
    await pumpPress(tester, onTap: () {}, enabled: false);
    final press = await tester.startGesture(tester.getCenter(find.byKey(box)));
    await tester.pump(const Duration(milliseconds: 200));
    expect(deformation(tester), isNull);
    await press.up();
    await tester.pumpAndSettle();
  });
}
