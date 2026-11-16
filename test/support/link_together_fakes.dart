import 'dart:async';
import 'dart:math';

import 'package:mornye/services/link/link_protocol.dart';
import 'package:mornye/services/link/together/link_together_deck.dart';
import 'package:mornye/services/link/together/link_together_protocol.dart';

/// A song of a [SimDeck] queue, named by title alone.
TrackRef simSong(String title) => TrackRef(title: title, artist: 'Artist');

/// A simulated player for Play together tests: its own wall clock
/// ([clockOffsetMs] from the true time), an audio clock that runs
/// [audioPpm] millionths fast, a start delay after play and seek, a load
/// time, and position reports off by up to [jitterMs]. The true position is
/// what a listener hears.
class SimDeck implements LinkTogetherDeck {
  SimDeck({
    required this.trueNowMs,
    required List<TrackRef> queue,
    required List<int> durations,
    this.clockOffsetMs = 0,
    this.audioPpm = 0,
    this.playLatencyMs = 0,
    this.loadMs = 100,
    this.jitterMs = 0,
    this.nudges = true,
    Random? random,
  }) : _queue = List.of(queue),
       _durations = List.of(durations),
       _random = random ?? Random(1),
       _anchorTrue = trueNowMs(),
       _startTrue = trueNowMs();

  final int Function() trueNowMs;
  final int clockOffsetMs;
  final double audioPpm;
  final int playLatencyMs;
  final int loadMs;
  final int jitterMs;
  final bool nudges;
  final Random _random;

  List<TrackRef> _queue;
  List<int> _durations;
  int index = 0;
  bool playing = false;
  bool ready = true;
  double rate = 1;
  LinkRepeatMode repeat = LinkRepeatMode.none;
  double _anchorPos = 0;
  int _anchorTrue;
  int _startTrue;
  bool begun = false;
  bool beganAsFollower = false;
  final rates = <double>[];
  final _changes = StreamController<void>.broadcast();

  /// The device's wall clock.
  int nowMs() => trueNowMs() + clockOffsetMs;

  /// Replaces the queue, paused at [index] and [position], as a handoff
  /// loads it.
  void load(
    List<TrackRef> queue,
    List<int> durations, {
    int index = 0,
    int position = 0,
  }) {
    _queue = List.of(queue);
    _durations = List.of(durations);
    this.index = index;
    playing = false;
    _anchor(position.toDouble());
    _changes.add(null);
  }

  /// Plays [index] from [position] at once, as if it had played for a while.
  void playNow({int index = 0, int position = 0}) {
    this.index = index;
    playing = true;
    ready = true;
    _anchor(position.toDouble());
    _changes.add(null);
  }

  void _anchor(double position, {int delay = 0}) {
    _anchorPos = position;
    _anchorTrue = trueNowMs();
    _startTrue = _anchorTrue + delay;
  }

  /// Reports a change without one, as a player's regular position update.
  void touch() => _changes.add(null);

  /// What a listener hears now, in milliseconds into the current song.
  double get truePosition {
    _advance();
    return _position(trueNowMs());
  }

  double _position(int at) {
    if (!playing) return _anchorPos;
    final from = max(_anchorTrue, _startTrue);
    if (at <= from) return _anchorPos;
    return _anchorPos + (at - from) * rate * (1 + audioPpm / 1e6);
  }

  /// Moves on to the next song once one ends, without a gap.
  void _advance() {
    if (!playing) return;
    var position = _position(trueNowMs());
    while (position >= _durations[index]) {
      final over = position - _durations[index];
      if (repeat == LinkRepeatMode.one) {
        // Same song again.
      } else if (index + 1 < _queue.length) {
        index++;
      } else if (repeat == LinkRepeatMode.all) {
        index = 0;
      } else {
        playing = false;
        _anchorPos = _durations[index].toDouble();
        _changes.add(null);
        return;
      }
      _anchorPos = over;
      _anchorTrue = trueNowMs();
      _startTrue = _anchorTrue;
      position = over;
      _changes.add(null);
    }
  }

  @override
  LinkTogetherReport read() {
    _advance();
    final jitter = jitterMs == 0
        ? 0
        : _random.nextInt(jitterMs * 2 + 1) - jitterMs;
    final has = index >= 0 && index < _queue.length;
    return LinkTogetherReport(
      nowMs: nowMs(),
      track: has ? _queue[index] : null,
      index: has ? index : -1,
      playing: playing,
      ready: ready && has,
      positionMs: max(0, _position(trueNowMs()).round() + jitter),
      durationMs: has ? _durations[index] : null,
      repeat: repeat,
    );
  }

  @override
  Stream<void> get changes => _changes.stream;

  @override
  int get length => _queue.length;

  @override
  TrackRef? refAt(int index) =>
      index >= 0 && index < _queue.length ? _queue[index] : null;

  @override
  Future<void> play() async {
    _advance();
    if (playing) return;
    playing = true;
    _anchor(_anchorPos, delay: playLatencyMs);
    _changes.add(null);
  }

  @override
  Future<void> pause() async {
    _advance();
    if (!playing) return;
    _anchorPos = _position(trueNowMs());
    playing = false;
    _changes.add(null);
  }

  /// Seeks so far, which a listener hears as jumps.
  int seeks = 0;

  @override
  Future<void> seek(Duration position) async {
    seeks++;
    _advance();
    _anchor(
      position.inMilliseconds.toDouble(),
      delay: playing ? playLatencyMs : 0,
    );
    _changes.add(null);
  }

  @override
  Future<void> next() async {
    _advance();
    if (index + 1 >= _queue.length) return;
    index++;
    _anchor(0, delay: playing ? playLatencyMs : 0);
    _changes.add(null);
  }

  @override
  Future<void> previous() async {
    _advance();
    if (index == 0) return;
    index--;
    _anchor(0, delay: playing ? playLatencyMs : 0);
    _changes.add(null);
  }

  @override
  Future<void> setRepeat(LinkRepeatMode mode) async => repeat = mode;

  @override
  Future<void> prepare(int index, Duration position) async {
    this.index = index;
    playing = false;
    ready = false;
    _anchor(position.inMilliseconds.toDouble());
    _changes.add(null);
    await Future<void>.delayed(Duration(milliseconds: loadMs));
    ready = true;
    _changes.add(null);
  }

  @override
  bool get canNudge => nudges;

  @override
  void setRate(double factor) {
    _advance();
    final now = trueNowMs();
    _anchorPos = _position(now);
    _anchorTrue = now;
    if (_startTrue < now) _startTrue = now;
    rate = factor;
    rates.add(factor);
  }

  @override
  void begin({required bool follower}) {
    begun = true;
    beganAsFollower = follower;
  }

  @override
  void end() {
    begun = false;
    if (rate != 1) setRate(1);
  }
}
