import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/widgets/desktop/desktop_wheel_smoother.dart';

class _FakeWheel {
  bool reduced = false;
  bool shift = false;
  bool Function(PointerScrollEvent event)? passThrough;
  Duration clock = Duration.zero;
  final frames = <VoidCallback>[];
  final sent = <PointerScrollEvent>[];

  late final smoother = DesktopWheelSmoother(
    dispatch: (event) => sent.add(event as PointerScrollEvent),
    scheduleFrame: frames.add,
    now: () => clock,
    reducedMotion: () => reduced,
    shiftPressed: () => shift,
    hitsPassThrough: (event) => passThrough?.call(event) ?? false,
  );

  bool notch(
    double dy, {
    double dx = 0,
    PointerDeviceKind kind = PointerDeviceKind.mouse,
    Offset position = const Offset(100, 100),
  }) => smoother.handlePointerEvent(
    PointerScrollEvent(
      kind: kind,
      position: position,
      scrollDelta: Offset(dx, dy),
    ),
  );

  /// Advances the fake clock by [ms] and runs the frame callbacks due.
  void frame([int ms = 16]) {
    clock += Duration(milliseconds: ms);
    final due = List.of(frames);
    frames.clear();
    for (final callback in due) {
      callback();
    }
  }

  void runFrames(int count) {
    for (var i = 0; i < count; i++) {
      frame();
    }
  }

  List<double> get pieces => [for (final e in sent) e.scrollDelta.dy];
  double get total => pieces.fold(0, (sum, piece) => sum + piece);
}

void main() {
  group('DesktopWheelSmoother', () {
    test('eases one notch in monotonic pieces that sum to it', () {
      final wheel = _FakeWheel();
      expect(wheel.notch(60), isTrue);
      expect(wheel.sent, isEmpty);

      wheel.runFrames(13); // 208 ms
      final pieces = wheel.pieces;
      expect(pieces.length, greaterThan(5));
      expect(pieces.every((piece) => piece > 0), isTrue);
      // Each piece is smaller than the last, apart from the final snap of
      // under a pixel.
      for (var i = 1; i < pieces.length - 1; i++) {
        expect(pieces[i], lessThanOrEqualTo(pieces[i - 1]));
      }
      expect(pieces.last, lessThan(1));
      expect(wheel.total, 60);
      expect(wheel.frames, isEmpty);
      expect(
        wheel.sent.every((e) => e.position == const Offset(100, 100)),
        isTrue,
      );
    });

    test('most of a notch lands within 150 ms', () {
      final wheel = _FakeWheel()..notch(60);
      wheel.runFrames(9); // 144 ms
      expect(wheel.total, greaterThan(55));
      expect(wheel.total, lessThan(60));
    });

    test('notches in the same direction add up', () {
      final wheel = _FakeWheel()..notch(60);
      wheel.runFrames(2);
      wheel.notch(60);
      wheel.runFrames(20);
      expect(wheel.total, 120);
    });

    test('a reversal drops what was left', () {
      final wheel = _FakeWheel()..notch(60);
      wheel.runFrames(2);
      final moved = wheel.total;
      expect(moved, inExclusiveRange(0, 60));
      wheel.notch(-60);
      wheel.runFrames(20);
      expect(wheel.total, closeTo(moved - 60, 1e-9));
      expect(wheel.pieces.skip(2).every((piece) => piece < 0), isTrue);
    });

    test('a click stops the rest of the notch', () {
      final wheel = _FakeWheel()..notch(60);
      wheel.runFrames(1);
      final moved = wheel.total;
      wheel.smoother.handlePointerEvent(
        const PointerDownEvent(position: Offset(100, 100)),
      );
      wheel.runFrames(10);
      expect(wheel.total, moved);
    });

    test('Shift pressed mid-ease drops the rest of the notch', () {
      final wheel = _FakeWheel()..notch(60);
      wheel.runFrames(1);
      final moved = wheel.total;
      wheel.shift = true;
      wheel.runFrames(10);
      expect(wheel.total, moved);
      expect(wheel.frames, isEmpty);
    });

    test('a notch elsewhere first finishes the old one', () {
      final wheel = _FakeWheel()..notch(60);
      wheel.runFrames(1);
      wheel.notch(60, position: const Offset(400, 100));
      final old = wheel.sent.where((e) => e.position == const Offset(100, 100));
      expect(old.fold<double>(0, (sum, e) => sum + e.scrollDelta.dy), 60);
      wheel.runFrames(20);
      expect(wheel.total, 120);
    });

    test('passes through what it does not smooth', () {
      final wheel = _FakeWheel();
      expect(wheel.notch(4), isFalse, reason: 'small delta');
      expect(wheel.notch(0, dx: 60), isFalse, reason: 'sideways delta');
      expect(
        wheel.notch(60, kind: PointerDeviceKind.trackpad),
        isFalse,
        reason: 'touchpad',
      );
      expect(
        wheel.smoother.handlePointerEvent(
          const PointerPanZoomUpdateEvent(pan: Offset(0, 60)),
        ),
        isFalse,
        reason: 'pan-zoom',
      );
      wheel.shift = true;
      expect(wheel.notch(60), isFalse, reason: 'Shift held');
      wheel
        ..shift = false
        ..reduced = true;
      expect(wheel.notch(60), isFalse, reason: 'reduced motion');
      wheel
        ..reduced = false
        ..passThrough = (_) => true;
      expect(wheel.notch(60), isFalse, reason: 'volume control');
      wheel.runFrames(10);
      expect(wheel.sent, isEmpty);
    });
  });

  group('DesktopWheelSmoother in a list', () {
    late ScrollController controller;

    Future<void> pumpList(WidgetTester tester) async {
      controller = ScrollController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Center(
            child: SizedBox(
              width: 200,
              height: 400,
              child: ListView.builder(
                controller: controller,
                itemExtent: 50,
                itemCount: 40,
                itemBuilder: (_, index) => Text('Row $index'),
              ),
            ),
          ),
        ),
      );
    }

    Future<double> directNotch(WidgetTester tester, double start) async {
      controller.jumpTo(start);
      await tester.pump();
      tester.binding.handlePointerEvent(
        PointerScrollEvent(
          kind: PointerDeviceKind.mouse,
          position: tester.getCenter(find.byType(ListView)),
          scrollDelta: const Offset(0, 60),
        ),
      );
      await tester.pump();
      return controller.offset;
    }

    Future<double> smoothNotch(WidgetTester tester, double start) async {
      controller.jumpTo(start);
      await tester.pump();
      var clock = Duration.zero;
      final frames = <VoidCallback>[];
      final smoother = DesktopWheelSmoother(
        dispatch: tester.binding.handlePointerEvent,
        scheduleFrame: frames.add,
        now: () => clock,
        reducedMotion: () => false,
        shiftPressed: () => false,
        hitsPassThrough: (_) => false,
      );
      final taken = smoother.handlePointerEvent(
        PointerScrollEvent(
          kind: PointerDeviceKind.mouse,
          position: tester.getCenter(find.byType(ListView)),
          scrollDelta: const Offset(0, 60),
        ),
      );
      expect(taken, isTrue);
      final offsets = <double>[];
      while (frames.isNotEmpty) {
        clock += const Duration(milliseconds: 16);
        final due = List.of(frames);
        frames.clear();
        for (final callback in due) {
          callback();
        }
        await tester.pump(const Duration(milliseconds: 16));
        offsets.add(controller.offset);
      }
      expect(offsets.length, greaterThan(5));
      for (var i = 1; i < offsets.length; i++) {
        expect(offsets[i], greaterThanOrEqualTo(offsets[i - 1]));
      }
      return controller.offset;
    }

    testWidgets('ends where one direct notch would', (tester) async {
      await pumpList(tester);
      expect(await smoothNotch(tester, 0), await directNotch(tester, 0));
      expect(await smoothNotch(tester, 120), 180);
      expect(
        await smoothNotch(tester, 13.37),
        closeTo(await directNotch(tester, 13.37), 1e-9),
      );
      // Near the end the list clamps the same way.
      final end = controller.position.maxScrollExtent;
      expect(await smoothNotch(tester, end - 20), end);
      expect(await directNotch(tester, end - 20), end);
    });

    testWidgets('wheels over a pass-through control are found', (tester) async {
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 100,
                height: 100,
                child: DesktopWheelPassThrough(
                  child: Listener(
                    behavior: HitTestBehavior.opaque,
                    onPointerSignal: (_) {},
                  ),
                ),
              ),
              const SizedBox(width: 100, height: 100),
            ],
          ),
        ),
      );
      PointerScrollEvent at(Offset position) => PointerScrollEvent(
        position: position,
        scrollDelta: const Offset(0, 60),
      );
      expect(
        hitsDesktopWheelPassThrough(tester.binding, at(const Offset(50, 50))),
        isTrue,
      );
      expect(
        hitsDesktopWheelPassThrough(tester.binding, at(const Offset(150, 50))),
        isFalse,
      );
    });

    testWidgets('the binding wiring honours reduced motion', (tester) async {
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(disableAnimations: true);
      addTearDown(
        tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );
      final sent = <PointerEvent>[];
      final smoother = DesktopWheelSmoother.forBinding(
        tester.binding,
        dispatch: sent.add,
      );
      final event = PointerScrollEvent(
        kind: PointerDeviceKind.mouse,
        position: const Offset(10, 10),
        scrollDelta: const Offset(0, 60),
      );
      expect(smoother.handlePointerEvent(event), isFalse);
      tester.platformDispatcher.clearAccessibilityFeaturesTestValue();
      expect(smoother.handlePointerEvent(event), isTrue);
      // Stop the run so no frame callback outlives the test.
      smoother.handlePointerEvent(const PointerDownEvent());
      await tester.pump();
      expect(sent, isEmpty);
    });
  });
}
