import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/widgets/smoothed_progress.dart';

Widget _testApp({
  required double progress,
  bool animate = true,
  Duration duration = const Duration(milliseconds: 900),
  Curve curve = Curves.linear,
}) {
  return MaterialApp(
    home: SmoothedProgressScope(
      value: progress,
      animate: animate,
      duration: duration,
      curve: curve,
      child: SmoothedProgressBuilder(
        builder: (context, value, child) => Text(
          value.toStringAsFixed(3),
          key: const ValueKey('smoothed-progress-value'),
        ),
      ),
    ),
  );
}

double _displayedProgress(WidgetTester tester) {
  final text = tester.widget<Text>(
    find.byKey(const ValueKey('smoothed-progress-value')),
  );
  return double.parse(text.data!);
}

void main() {
  testWidgets('shows the first authoritative value immediately', (
    tester,
  ) async {
    await tester.pumpWidget(_testApp(progress: 0.42));

    expect(_displayedProgress(tester), 0.42);
  });

  testWidgets('interpolates monotonic progress updates locally', (
    tester,
  ) async {
    await tester.pumpWidget(_testApp(progress: 0.2));
    await tester.pumpWidget(_testApp(progress: 0.8));
    await tester.pump(const Duration(milliseconds: 450));

    final halfway = _displayedProgress(tester);
    expect(halfway, greaterThan(0.2));
    expect(halfway, lessThan(0.8));

    await tester.pump(const Duration(milliseconds: 450));
    expect(_displayedProgress(tester), 0.8);
  });

  testWidgets('snaps resets and completion to the backend value', (
    tester,
  ) async {
    await tester.pumpWidget(_testApp(progress: 0.4));
    await tester.pumpWidget(_testApp(progress: 0.9));
    await tester.pump(const Duration(milliseconds: 300));

    await tester.pumpWidget(_testApp(progress: 0.7));
    expect(_displayedProgress(tester), 0.7);

    await tester.pumpWidget(_testApp(progress: 0.1));
    expect(_displayedProgress(tester), 0.1);

    await tester.pumpWidget(_testApp(progress: 1));
    expect(_displayedProgress(tester), 1);
  });

  testWidgets('snaps updates when animation is disabled', (tester) async {
    await tester.pumpWidget(_testApp(progress: 0.2));
    await tester.pumpWidget(_testApp(progress: 0.8, animate: false));

    expect(_displayedProgress(tester), 0.8);
  });

  testWidgets('rapid curved updates continue from the displayed progress', (
    tester,
  ) async {
    await tester.pumpWidget(_testApp(progress: 0.1));
    var previous = _displayedProgress(tester);
    for (var index = 1; index <= 80; index++) {
      final target = 0.1 + index * 0.01;
      await tester.pumpWidget(
        _testApp(progress: target, curve: Curves.easeOutCubic),
      );
      expect(_displayedProgress(tester), previous);
      await tester.pump(const Duration(milliseconds: 16));
      final current = _displayedProgress(tester);
      expect(current, inInclusiveRange(previous, target));
      previous = current;
    }
    await tester.pump(const Duration(milliseconds: 900));
    expect(_displayedProgress(tester), 0.9);
    expect(tester.binding.transientCallbackCount, 0);

    await tester.pumpWidget(_testApp(progress: 0.95));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
    expect(tester.binding.transientCallbackCount, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('uses the selected curve when restarting an interpolation', (
    tester,
  ) async {
    await tester.pumpWidget(_testApp(progress: 0.2));
    await tester.pumpWidget(_testApp(progress: 0.6));
    await tester.pump(const Duration(milliseconds: 450));
    expect(_displayedProgress(tester), 0.4);

    await tester.pumpWidget(_testApp(progress: 0.9, curve: Curves.decelerate));
    expect(_displayedProgress(tester), 0.4);
    await tester.pump(const Duration(milliseconds: 450));
    expect(_displayedProgress(tester), 0.775);
    await tester.pump(const Duration(milliseconds: 450));
    expect(_displayedProgress(tester), 0.9);
  });
}
