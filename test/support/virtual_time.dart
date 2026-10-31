import 'dart:async';

/// Real time plus any idle time skipped by [VirtualTime.run].
///
/// Outside [run], timers created in [zone] are ordinary timers. Inside, they
/// are queued and fired in due order, skipping ahead whenever nothing else is
/// runnable, so a wait for a fade or for nothing to happen costs no real time.
/// Microtasks always stay real: no future or stream is tied to a zone that
/// stops running, even when shared runtime state outlives a test.
class VirtualTime {
  VirtualTime() {
    zone = _parent.fork(
      specification: ZoneSpecification(
        createTimer: (self, parent, zone, duration, callback) {
          onTimer?.call(duration);
          return _virtual
              ? _add(duration, null, (_) => callback())
              : parent.createTimer(zone, duration, callback);
        },
        createPeriodicTimer: (self, parent, zone, period, callback) => _virtual
            ? _add(period, period, callback)
            : parent.createPeriodicTimer(zone, period, callback),
      ),
    );
  }

  final _parent = Zone.current;
  late final Zone zone;

  /// Called as each one-shot timer is created in [zone], virtual or not.
  void Function(Duration duration)? onTimer;
  final _real = Stopwatch()..start();
  final _timers = <_VirtualTimer>[];
  var _skipped = Duration.zero;
  var _virtual = false;
  var _sequence = 0;

  Duration get now => _real.elapsed + _skipped;

  Stopwatch stopwatch() => _VirtualStopwatch(() => now);

  Timer _add(
    Duration duration,
    Duration? period,
    void Function(Timer) callback,
  ) {
    final timer = _VirtualTimer(
      this,
      now + (duration.isNegative ? Duration.zero : duration),
      period,
      _sequence++,
      callback,
    );
    _timers.add(timer);
    return timer;
  }

  /// Runs [body] in [zone] with virtual timers until it completes.
  Future<T> run<T>(Future<T> Function() body) async {
    _virtual = true;
    try {
      final result = zone.run(body);
      var done = false;
      unawaited(
        result
            .then<void>((_) {}, onError: (Object _) {})
            .whenComplete(() => done = true),
      );
      while (!done) {
        // One real event-loop turn drains microtasks and platform replies.
        await Future<void>.delayed(Duration.zero);
        if (done || _timers.isEmpty) continue;
        final next = _timers.reduce(
          (a, b) => b.due < a.due || (b.due == a.due && b.sequence < a.sequence)
              ? b
              : a,
        );
        if (next.due > now) _skipped += next.due - now;
        if (_skipped > const Duration(minutes: 10)) {
          throw StateError('Virtual time ran for more than ten minutes');
        }
        next._fire();
      }
      return await result;
    } finally {
      _virtual = false;
      // Whatever is still scheduled continues on real time, as it would have.
      for (final timer in _timers.toList()) {
        timer._realize();
      }
      _timers.clear();
    }
  }
}

class _VirtualTimer implements Timer {
  _VirtualTimer(this._time, this.due, this._period, this.sequence, this._run);

  final VirtualTime _time;
  final Duration? _period;
  final int sequence;
  final void Function(Timer) _run;
  Duration due;
  Timer? _real;
  var _active = true;
  var _tick = 0;

  @override
  bool get isActive => _active;

  @override
  int get tick => _tick;

  @override
  void cancel() {
    _active = false;
    _real?.cancel();
    _time._timers.remove(this);
  }

  void _fire() {
    final period = _period;
    _tick++;
    if (period == null) {
      _active = false;
      _time._timers.remove(this);
    } else {
      due += period;
    }
    _run(this);
  }

  void _realize() {
    final remaining = due - _time.now;
    _real = _time._parent.createTimer(
      remaining.isNegative ? Duration.zero : remaining,
      () {
        final period = _period;
        if (!_active) return;
        _fire();
        if (period != null && _active) {
          _real = _time._parent.createPeriodicTimer(period, (_) {
            if (!_active) return;
            _tick++;
            _run(this);
          });
        }
      },
    );
  }
}

/// A [Stopwatch] on [VirtualTime.now].
class _VirtualStopwatch implements Stopwatch {
  _VirtualStopwatch(this._now);

  final Duration Function() _now;
  Duration? _startedAt;
  Duration _stopped = Duration.zero;

  @override
  int get frequency => Duration.microsecondsPerSecond;

  @override
  bool get isRunning => _startedAt != null;

  @override
  void start() => _startedAt ??= _now();

  @override
  void stop() {
    _stopped = elapsed;
    _startedAt = null;
  }

  @override
  void reset() {
    _stopped = Duration.zero;
    if (_startedAt != null) _startedAt = _now();
  }

  @override
  Duration get elapsed {
    final startedAt = _startedAt;
    return startedAt == null ? _stopped : _stopped + _now() - startedAt;
  }

  @override
  int get elapsedTicks => elapsed.inMicroseconds;

  @override
  int get elapsedMicroseconds => elapsed.inMicroseconds;

  @override
  int get elapsedMilliseconds => elapsed.inMilliseconds;
}
