import 'dart:async';
import 'dart:math' as math;

import 'package:mornye/services/link/link_protocol.dart';
import 'package:mornye/services/link/together/link_together_deck.dart';
import 'package:mornye/services/link/together/link_together_protocol.dart';
import 'package:mornye/utils/logger.dart';

final _log = AppLogger('LinkTogether');

int _wallClockMs() => DateTime.now().millisecondsSinceEpoch;

/// Carries out the coordinator's steps on the device that follows: lines
/// its player up with a [LinkTogetherCue] and nudges its rate. It decides
/// nothing about timing itself; it runs on the phone and on the computer.
class LinkTogetherFollower {
  LinkTogetherFollower({
    required LinkTogetherDeck deck,
    int Function()? nowMs,
    this.seekMarginMs = 250,
    this.loadMarginMs = 600,
    this.maxWaitMs = 3000,
    this.lateMs = 40,
    this.pausedToleranceMs = 50,
  }) : _deck = deck,
       _nowMs = nowMs ?? _wallClockMs;

  final LinkTogetherDeck _deck;
  final int Function() _nowMs;

  /// How far ahead a start is set after a seek, and after loading a song:
  /// the player must be ready, paused at the right place, by then.
  final int seekMarginMs;
  final int loadMarginMs;

  /// The longest a follower that runs ahead waits, paused, for the leader to
  /// reach it; further ahead it seeks back instead.
  final int maxWaitMs;

  /// How late a start may be before the position is set again.
  final int lateMs;

  /// A paused player this close to the cue keeps its position.
  final int pausedToleranceMs;

  int _operation = 0;
  int _busy = 0;
  bool _silent = false;
  bool _startPending = false;
  int _lastActionMs = 0;
  Timer? _nudgeTimer;
  double _nudgeFactor = 1;

  /// A cue is being carried out.
  bool get busy => _busy > 0;

  /// The last cue named a song this device's queue does not hold.
  bool get silent => _silent;

  /// When the last cue finished; player changes shortly after it are its
  /// own, not the listener's.
  int get lastActionMs => _lastActionMs;

  /// The queue entry for [track], looked for from the current entry
  /// outwards, the next ones first.
  int? find(TrackRef track) {
    final length = _deck.length;
    if (length == 0) return null;
    final current = _deck.read().index;
    final start = current < 0 || current >= length ? 0 : current;
    bool matches(int index) => linkTogetherSameTrack(_deck.refAt(index), track);
    if (matches(start)) return start;
    for (var step = 1; step < length; step++) {
      final ahead = start + step;
      final behind = start - step;
      if (ahead < length && matches(ahead)) return ahead;
      if (behind >= 0 && matches(behind)) return behind;
      if (ahead >= length && behind < 0) break;
    }
    return null;
  }

  /// Lines the player up with [cue]; true once it plays (or waits) there,
  /// false when its queue lacks the song, which leaves it [silent].
  Future<bool> rejoin(LinkTogetherCue cue) async {
    final operation = ++_operation;
    _stopNudge();
    _busy++;
    try {
      final at = find(cue.track);
      if (at == null) {
        _silent = true;
        _startPending = false;
        if (_deck.read().playing) await _deck.pause();
        _log.i('Link: together, this device lacks the song, staying silent');
        return false;
      }
      _silent = false;
      final report = _deck.read();
      if (!cue.playing) {
        _startPending = false;
        if (report.index != at) {
          await _deck.prepare(at, Duration(milliseconds: cue.positionMs));
          return true;
        }
        if (report.playing) await _deck.pause();
        if (operation != _operation) return true;
        if ((_deck.read().positionMs - cue.positionMs).abs() >
            pausedToleranceMs) {
          await _deck.seek(Duration(milliseconds: cue.positionMs));
        }
        return true;
      }
      _startPending = true;
      if (report.index != at || !report.ready) {
        final start = math.max(
          _nowMs() + loadMarginMs + cue.leadMs,
          cue.atMs + cue.leadMs,
        );
        await _deck.prepare(at, Duration(milliseconds: cue.positionAt(start)));
        if (operation != _operation) return true;
        await _startAt(operation, cue, start);
        return true;
      }
      if (report.playing) {
        final now = _nowMs();
        final ahead = report.positionAt(now) - cue.positionAt(now);
        if (ahead > 0 && ahead <= maxWaitMs) {
          // Ahead: stop and go on once the leader reaches this point, so
          // nothing is skipped or heard twice.
          await _deck.pause();
          if (operation != _operation) return true;
          final stopped = _deck.read().positionMs;
          final start = cue.atMs + (stopped - cue.positionMs);
          if (start - cue.leadMs > _nowMs() + 5) {
            await _startAt(operation, cue, start);
            return true;
          }
        }
      }
      final start = _nowMs() + seekMarginMs + cue.leadMs;
      if (_deck.read().playing) await _deck.pause();
      if (operation != _operation) return true;
      await _deck.seek(Duration(milliseconds: cue.positionAt(start)));
      if (operation != _operation) return true;
      await _startAt(operation, cue, start);
      return true;
    } finally {
      _busy--;
      _lastActionMs = _nowMs();
    }
  }

  /// Plays at [start] minus the cue's lead. A start that comes too late, as
  /// after a slow load, moves the position on and waits again, twice at most.
  Future<void> _startAt(int operation, LinkTogetherCue cue, int start) async {
    for (var attempt = 0; ; attempt++) {
      final playAt = start - cue.leadMs;
      final wait = playAt - _nowMs();
      if (wait > 0) await Future<void>.delayed(Duration(milliseconds: wait));
      if (operation != _operation) return;
      final late = _nowMs() - playAt;
      if (late <= lateMs || attempt >= 2) {
        _startPending = false;
        await _deck.play();
        _log.i('Link: together, started ${late}ms after the agreed instant');
        return;
      }
      start = _nowMs() + seekMarginMs + cue.leadMs;
      await _deck.seek(Duration(milliseconds: cue.positionAt(start)));
      if (operation != _operation) return;
    }
  }

  /// Plays at [factor] times the normal rate for [durationMs], then normal
  /// again; 1 stops a nudge under way. A nudge already at [factor] only
  /// moves its end: some engines lose a little of the song on every rate
  /// change.
  void nudge(double factor, int durationMs) {
    if (factor == 1 || durationMs <= 0 || !_deck.canNudge) {
      _stopNudge();
      return;
    }
    _nudgeTimer?.cancel();
    if (_nudgeTimer == null || _nudgeFactor != factor) _deck.setRate(factor);
    _nudgeFactor = factor;
    _nudgeTimer = Timer(Duration(milliseconds: durationMs), _stopNudge);
  }

  void _stopNudge() {
    final nudging = _nudgeTimer != null;
    _nudgeTimer?.cancel();
    _nudgeTimer = null;
    _nudgeFactor = 1;
    if (nudging) _deck.setRate(1);
  }

  /// Drops what is under way. With [resume], a start it was waiting for
  /// happens now, so a device left alone keeps playing.
  void cancel({bool resume = false}) {
    _operation++;
    _stopNudge();
    _deck.setRate(1);
    _silent = false;
    if (resume && _startPending) unawaited(_deck.play());
    _startPending = false;
  }
}
