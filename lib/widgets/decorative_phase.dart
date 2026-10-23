import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

/// A looping phase in `[0, 1)` for continuous decorative motion, such as
/// equalizer bars and wavy tracks.
///
/// Every running phase advances from one app-wide clock capped at 30 Hz, so
/// decoration schedules at most 30 frames a second instead of one per
/// display refresh. The clock runs only while a phase is running and the app
/// draws frames, so a hidden or paused app holds every phase like a ticker
/// would. Owners stop their phase while paused, under reduced motion, and
/// while a disabled [TickerMode] hides them; a stopped phase holds its value
/// and resumes from it.
class DecorativePhase extends ChangeNotifier
    implements ValueListenable<double> {
  DecorativePhase(this.loop);

  /// Time for one full cycle from 0 back to 0.
  final Duration loop;

  /// Interval between clock ticks: 34 ms keeps the rate at or below 30 Hz.
  static const interval = Duration(milliseconds: 34);

  static var _clock = _DecorativeClock();

  /// Whether the shared clock has a running phase to advance.
  @visibleForTesting
  static bool get debugClockRunning => _clock.running;

  /// Replaces the shared clock, so a phase a test left running cannot keep
  /// a timer from a finished test zone.
  @visibleForTesting
  static void debugResetClock() {
    _clock.dispose();
    _clock = _DecorativeClock();
  }

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

class _DecorativeClock extends ChangeNotifier with WidgetsBindingObserver {
  Timer? _timer;
  bool _observing = false;
  int _origin = 0;
  int ticks = 0;

  bool get running => _timer != null;

  @override
  void addListener(VoidCallback listener) {
    super.addListener(listener);
    _sync();
  }

  @override
  void removeListener(VoidCallback listener) {
    super.removeListener(listener);
    _sync();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) => _sync();

  // Listeners removed during a notification only count once it ends, so a
  // tick syncs again afterwards.
  void _sync() {
    final observe = hasListeners;
    if (observe != _observing) {
      _observing = observe;
      observe
          ? WidgetsBinding.instance.addObserver(this)
          : WidgetsBinding.instance.removeObserver(this);
    }
    final run = observe && SchedulerBinding.instance.framesEnabled;
    if (run == running) return;
    if (run) {
      // A late tick reports every interval that passed, so motion keeps its
      // speed when the UI isolate is busy.
      _timer = Timer.periodic(DecorativePhase.interval, (timer) {
        ticks = _origin + timer.tick;
        notifyListeners();
        _sync();
      });
    } else {
      _timer!.cancel();
      _timer = null;
      _origin = ticks;
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    if (_observing) WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}
