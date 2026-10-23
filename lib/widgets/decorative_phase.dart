import 'dart:async';

import 'package:flutter/foundation.dart';

/// A looping phase in `[0, 1)` for continuous decorative motion, such as
/// equalizer bars and wavy tracks.
///
/// Every running phase advances from one app-wide clock capped at 30 Hz, so
/// decoration schedules at most 30 frames a second instead of one per
/// display refresh. The clock runs only while a phase is running. Owners
/// stop their phase while paused, under reduced motion, and while a
/// disabled [TickerMode] hides them; a stopped phase holds its value and
/// resumes from it.
class DecorativePhase extends ChangeNotifier
    implements ValueListenable<double> {
  DecorativePhase(this.loop);

  /// Time for one full cycle from 0 back to 0.
  final Duration loop;

  /// Interval between clock ticks: 34 ms keeps the rate at or below 30 Hz.
  static const interval = Duration(milliseconds: 34);

  static final _clock = _DecorativeClock();

  /// Whether the shared clock has a running phase to advance.
  @visibleForTesting
  static bool get debugClockRunning => _clock.running;

  double _value = 0;
  double _startValue = 0;
  int? _startTick;

  @override
  double get value => _value;

  bool get isRunning => _startTick != null;

  void start() {
    if (isRunning) return;
    _startValue = _value;
    _startTick = _clock.ticks;
    _clock.addListener(_tick);
  }

  void stop() {
    if (!isRunning) return;
    _clock.removeListener(_tick);
    _startTick = null;
  }

  void _tick() {
    final elapsed = interval * (_clock.ticks - _startTick!);
    _value = (_startValue + elapsed.inMicroseconds / loop.inMicroseconds) % 1;
    notifyListeners();
  }

  @override
  void dispose() {
    stop();
    super.dispose();
  }
}

class _DecorativeClock extends ChangeNotifier {
  Timer? _timer;
  int _origin = 0;
  int ticks = 0;

  bool get running => _timer != null;

  @override
  void addListener(VoidCallback listener) {
    super.addListener(listener);
    // A late tick reports every interval that passed, so motion keeps its
    // speed when the UI isolate is busy.
    _timer ??= Timer.periodic(DecorativePhase.interval, (timer) {
      ticks = _origin + timer.tick;
      notifyListeners();
      _stopWhenIdle();
    });
  }

  @override
  void removeListener(VoidCallback listener) {
    super.removeListener(listener);
    _stopWhenIdle();
  }

  // Listeners removed during a notification only count once it ends.
  void _stopWhenIdle() {
    if (hasListeners) return;
    _timer?.cancel();
    _timer = null;
    _origin = ticks;
  }
}
