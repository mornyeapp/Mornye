import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/widgets/swipe_progress_haptic.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late List<(double, double)> pulses;
  late Duration now;

  SwipeProgressHaptic haptic({bool fails = false}) => SwipeProgressHaptic(
    pulse: (intensity, sharpness) async {
      pulses.add((intensity, sharpness));
      if (fails) throw MissingPluginException();
    },
    clock: () => now,
  );

  /// Reports [progress] values 100 ms apart unless [gap] says otherwise.
  void sweep(
    SwipeProgressHaptic target,
    Iterable<double> progress, {
    Duration gap = const Duration(milliseconds: 100),
  }) {
    for (final value in progress) {
      now += gap;
      target.update(value);
    }
  }

  Iterable<double> range(double from, double to, [double step = 0.05]) sync* {
    final count = ((to - from) / step).abs().round();
    final sign = to >= from ? 1 : -1;
    for (var i = 0; i <= count; i++) {
      yield from + sign * step * i;
    }
  }

  const commit = (
    SwipeProgressHaptic.commitIntensity,
    SwipeProgressHaptic.commitSharpness,
  );

  setUp(() {
    pulses = [];
    now = Duration.zero;
  });

  test('ticks grow toward the commit point, then one strong pulse', () {
    final target = haptic();
    sweep(target, range(0, 1.6));

    expect(pulses, hasLength(4));
    final ticks = pulses.take(3).toList();
    for (var i = 1; i < ticks.length; i++) {
      expect(ticks[i].$1, greaterThan(ticks[i - 1].$1));
    }
    for (final tick in ticks) {
      expect(tick.$1, lessThan(commit.$1));
      expect(tick.$2, lessThan(commit.$2));
    }
    expect(pulses.last, commit);
  });

  test('the intensity follows the step reached', () {
    final target = haptic();
    sweep(target, [0.31, 0.56, 0.81]);
    expect(pulses.map((pulse) => pulse.$1), [
      SwipeProgressHaptic.tickIntensity(0.3),
      SwipeProgressHaptic.tickIntensity(0.55),
      SwipeProgressHaptic.tickIntensity(0.8),
    ]);
  });

  test('a fast swipe drops ticks inside the minimum gap', () {
    final target = haptic();
    sweep(target, [0.31, 0.56, 0.81], gap: const Duration(milliseconds: 20));
    expect(pulses, [
      (
        SwipeProgressHaptic.tickIntensity(0.3),
        SwipeProgressHaptic.tickSharpness(0.3),
      ),
    ]);
    // The commit pulse is never dropped.
    sweep(target, [1.0], gap: const Duration(milliseconds: 5));
    expect(pulses.last, commit);
  });

  test('one update past several steps ticks once for the furthest', () {
    final target = haptic();
    sweep(target, [0.9]);
    expect(pulses, [
      (
        SwipeProgressHaptic.tickIntensity(0.8),
        SwipeProgressHaptic.tickSharpness(0.8),
      ),
    ]);
  });

  test('a jump straight past the commit point gives only the pulse', () {
    final target = haptic();
    sweep(target, [1.4]);
    expect(pulses, [commit]);
  });

  test('nothing more past the commit point, in either direction', () {
    final target = haptic();
    sweep(target, [1.0, 1.3, 1.8, 1.2, 0.95, 1.1]);
    expect(pulses, [commit]);
  });

  test('falling back below re-arms the commit pulse and the steps', () {
    final target = haptic();
    sweep(target, [1.0]);
    // Below the commit point by more than the hysteresis.
    sweep(target, [0.85, 1.0]);
    expect(pulses, [commit, commit]);

    pulses.clear();
    sweep(target, range(1.0, 0));
    expect(pulses, isEmpty);
    sweep(target, range(0, 1.0));
    expect(pulses, hasLength(4));
    expect(pulses.last, commit);
  });

  test('hovering on a step boundary ticks once', () {
    final target = haptic();
    sweep(target, [0.3, 0.28, 0.31, 0.25, 0.3]);
    expect(pulses, hasLength(1));
  });

  test('a negative swipe ramps the same way', () {
    final target = haptic();
    sweep(target, range(0, -1.2));
    expect(pulses, hasLength(4));
    expect(pulses.last, commit);
  });

  test('reset arms every step for the next swipe', () {
    final target = haptic();
    sweep(target, range(0, 1.2));
    target.reset();
    pulses.clear();
    sweep(target, range(0, 1.2));
    expect(pulses, hasLength(4));
  });

  group('fallback', () {
    late List<Object?> system;

    setUp(() {
      system = [];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
            if (call.method == 'HapticFeedback.vibrate') {
              system.add(call.arguments);
            }
            return null;
          });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
    });

    test('system haptics take over when the channel fails', () async {
      final target = haptic(fails: true);
      sweep(target, [0.31]);
      await pumpEventQueue();
      expect(system, ['HapticFeedbackType.selectionClick']);

      sweep(target, [0.56, 1.0]);
      await pumpEventQueue();
      expect(system, [
        'HapticFeedbackType.selectionClick',
        'HapticFeedbackType.selectionClick',
        'HapticFeedbackType.mediumImpact',
      ]);
      // After the first failure the channel is not tried again.
      expect(pulses, hasLength(1));
    });
  });
}
