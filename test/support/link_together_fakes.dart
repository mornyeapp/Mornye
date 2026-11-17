import 'dart:async';
import 'dart:math';

import 'package:mornye/services/link/link_protocol.dart';
import 'package:mornye/services/link/together/link_together_deck.dart';
import 'package:mornye/services/link/together/link_together_protocol.dart';

/// A song of a [SimDeck] queue, named by title alone.
TrackRef simSong(String title) => TrackRef(title: title, artist: 'Artist');

/// What a rate change from [from] to [to] moves a [SimDeck]'s song, in
/// milliseconds (negative: it falls behind).
typedef SimRateCost = double Function(double from, double to, Random random);

/// The plain AVPlayer rate change measured on macOS: 25.8 ms lost entering
/// a rate other than 1, 22.5 ms leaving it.
double simPlainRateCost(double from, double to, Random random) =>
    to == 1 ? -22.5 : -25.8;

/// The AVPlayer rate change pinned to the host clock (the Darwin fork's
/// fix): 3.4 ms behind entering 1.02, ahead entering 0.98, none back to 1.
double simPinnedRateCost(double from, double to, Random random) =>
    (to - 1) * -170;

/// An AVPlayer item with the equalizer tap: tens of milliseconds either
/// way per change, measured from -62 to +43.
double simTappedRateCost(double from, double to, Random random) =>
    -65 + random.nextDouble() * 105;

/// A simulated player for Play together tests: its own wall clock
/// ([clockOffsetMs] from the true time), an audio clock that runs
/// [audioPpm] millionths fast, a start delay after play and seek, a load
/// time, and position reports off by up to [jitterMs]. The true position is
/// what a listener hears.
///
/// With [engineReadMs], reports behave like the app's player state: the
/// position is read from the engine that often while playing and
/// extrapolated in between, and play, seek and rate changes restart the
/// extrapolation without a read. A report right after a play then runs
/// ahead of the sound by the start delay until the next read. With
/// [rateCost], every rate change moves the song as the engine does. With
/// [endedReadMs], a song that ran out reads as stopped at its end for that
/// long while the next one already sounds, as the app's player state does
/// until its gapless change is through.
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
    this.engineReadMs = 0,
    this.endedReadMs = 0,
    this.rateCost,
    Random? random,
  }) : _queue = List.of(queue),
       _durations = List.of(durations),
       _random = random ?? Random(1),
       _anchorTrue = trueNowMs(),
       _startTrue = trueNowMs(),
       _shownTrue = trueNowMs(),
       _readTrue = trueNowMs();

  final int Function() trueNowMs;
  final int clockOffsetMs;
  final double audioPpm;
  final int playLatencyMs;
  final int loadMs;
  final int jitterMs;
  final bool nudges;
  final int engineReadMs;
  final int endedReadMs;
  final SimRateCost? rateCost;
  final Random _random;

  /// The song that ran out and until when reports still show it.
  int _endedIndex = -1;
  int _endedUntilTrue = 0;

  /// The reported position: [_shownPos] at true instant [_shownTrue],
  /// extrapolated at [rate]; [_readTrue] is the last engine read.
  double _shownPos = 0;
  int _shownTrue;
  int _readTrue;

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
    // The player state shows the new place at once. A start that sounds
    // later is only seen at an engine read, the first 200 ms on.
    _shownPos = position;
    _shownTrue = _anchorTrue;
    _readTrue = delay > 0 ? _anchorTrue - engineReadMs + 200 : _anchorTrue;
  }

  /// The position a report gives at true instant [at].
  double _reported(int at) {
    if (engineReadMs <= 0) return _position(at);
    if (!playing) return _shownPos;
    if (at - _readTrue >= engineReadMs) {
      final readAt =
          _readTrue + (at - _readTrue) ~/ engineReadMs * engineReadMs;
      _readTrue = readAt;
      // A read before the last change belongs to the stretch before it.
      if (readAt >= _anchorTrue && readAt >= _shownTrue) {
        _shownPos = _position(readAt);
        _shownTrue = readAt;
      }
    }
    // Extrapolated at the rate asked for, on the device's own clock.
    return _shownPos + (at - _shownTrue) * rate;
  }

  /// Reports a change without one, as a player's regular position update.
  void touch() => _changes.add(null);

  /// Playing and past the start delay of its last play or seek.
  bool get sounding => playing && trueNowMs() >= _startTrue;

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
      if (endedReadMs > 0) {
        _endedIndex = index;
        _endedUntilTrue = trueNowMs() + endedReadMs;
        Timer(Duration(milliseconds: endedReadMs), touch);
      }
      if (repeat == LinkRepeatMode.one) {
        // Same song again.
      } else if (index + 1 < _queue.length) {
        index++;
      } else if (repeat == LinkRepeatMode.all) {
        index = 0;
      } else {
        playing = false;
        _anchorPos = _shownPos = _durations[index].toDouble();
        _changes.add(null);
        return;
      }
      _anchor(over);
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
    if (trueNowMs() < _endedUntilTrue) {
      return LinkTogetherReport(
        nowMs: nowMs(),
        track: _queue[_endedIndex],
        index: _endedIndex,
        positionMs: _durations[_endedIndex],
        durationMs: _durations[_endedIndex],
        repeat: repeat,
        rate: rate,
      );
    }
    return LinkTogetherReport(
      nowMs: nowMs(),
      track: has ? _queue[index] : null,
      index: has ? index : -1,
      playing: playing,
      ready: ready && has,
      positionMs: max(0, _reported(trueNowMs()).round() + jitter),
      durationMs: has ? _durations[index] : null,
      repeat: repeat,
      rate: rate,
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
    _anchorPos = _shownPos = _position(trueNowMs());
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

  /// What the rate changes so far moved the song, in all.
  double rateCostMs = 0;

  @override
  void setRate(double factor) {
    _advance();
    final now = trueNowMs();
    final shown = _reported(now);
    final cost = playing && factor != rate
        ? rateCost?.call(rate, factor, _random) ?? 0
        : 0.0;
    rateCostMs += cost;
    _anchorPos = max(0.0, _position(now) + cost);
    _anchorTrue = now;
    if (_startTrue < now) _startTrue = now;
    // The player state goes on from where it showed, at the new rate.
    _shownPos = shown;
    _shownTrue = now;
    rate = factor;
    rates.add(factor);
    rateChangesAt.add(now);
  }

  /// The true instant of each [setRate].
  final rateChangesAt = <int>[];

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
