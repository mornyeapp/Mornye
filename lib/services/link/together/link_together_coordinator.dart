import 'dart:async';
import 'dart:math' as math;

import 'package:mornye/services/link/link_client_api.dart';
import 'package:mornye/services/link/link_clock_offset.dart';
import 'package:mornye/services/link/link_protocol.dart';
import 'package:mornye/services/link/together/link_together_aligner.dart';
import 'package:mornye/services/link/together/link_together_deck.dart';
import 'package:mornye/services/link/together/link_together_follower.dart';
import 'package:mornye/services/link/together/link_together_protocol.dart';
import 'package:mornye/utils/logger.dart';

final _log = AppLogger('LinkTogether');

int _wallClockMs() => DateTime.now().millisecondsSinceEpoch;

/// The paired computer as the coordinator reaches it. The app sends these
/// over Link; tests fake them.
abstract interface class LinkTogetherPeer {
  /// The computer's player, stamped on its clock (`together/time`).
  Future<LinkTogetherReport> read();

  /// Lines the computer up with [cue], on its clock; false when it lacks
  /// the song.
  Future<bool> rejoin(LinkTogetherCue cue);

  Future<void> nudge(double factor, int durationMs);

  /// A player command for the computer (`POST command`).
  Future<void> command(LinkCommand command);
}

/// [LinkTogetherPeer] over the phone's Link session, for [session].
class LinkClientTogetherPeer implements LinkTogetherPeer {
  LinkClientTogetherPeer(this.client, this.session);

  final LinkClientApi client;
  final String session;

  @override
  Future<LinkTogetherReport> read() async {
    final report = LinkTogetherReport.fromJson(
      await client.get(LinkTogetherOps.time),
    );
    if (report == null) {
      throw const LinkException('invalid', 'Unreadable player report');
    }
    return report;
  }

  @override
  Future<bool> rejoin(LinkTogetherCue cue) async {
    final reply = await client.post(LinkTogetherOps.align, {
      'session': session,
      'rejoin': cue.toJson(),
    });
    return reply is Map && reply['found'] == true;
  }

  @override
  Future<void> nudge(double factor, int durationMs) =>
      client.post(LinkTogetherOps.align, {
        'session': session,
        'nudge': {'factor': factor, 'durationMs': durationMs},
      });

  @override
  Future<void> command(LinkCommand command) =>
      client.post(LinkOps.command, command.toJson());
}

/// Reads the computer [samples] times, [gap] apart, adding each reply to
/// [clock]. Returns the last report, or null when none came back; a
/// computer without Play together answers `not_found`, which is rethrown.
Future<LinkTogetherReport?> linkTogetherMeasureClock(
  LinkTogetherPeer peer,
  LinkClockOffset clock, {
  int samples = 4,
  Duration gap = const Duration(milliseconds: 50),
  int Function()? nowMs,
}) async {
  final now = nowMs ?? _wallClockMs;
  LinkTogetherReport? last;
  for (var i = 0; i < samples; i++) {
    if (i > 0) await Future<void>.delayed(gap);
    try {
      final sent = now();
      final report = await peer.read();
      clock.add(sentMs: sent, receivedMs: now(), remoteMs: report.nowMs);
      last = report;
    } on LinkException catch (error) {
      if (error.code == 'not_found') rethrow;
    } on Object {
      // Another sample may still come back.
    }
  }
  final offset = clock.offsetMs;
  if (offset != null) _log.i('Link: together, clock offset ${offset}ms');
  return offset == null ? null : last;
}

/// Why a session ended by itself.
enum LinkTogetherEnd {
  /// The computer stopped answering or the connection went.
  disconnected,

  /// A song picked on the phone while it followed (as in the car).
  leftOnPhone,

  /// Another song picked on the computer while it followed.
  leftOnDesktop,
}

/// Keeps the phone and the paired computer playing the same song at the
/// same moment. It runs on the phone, which measures the clocks, and makes
/// every timing decision for both: the leader plays as usual and the
/// follower is moved onto its song and position, then kept there. See
/// `docs/internal/desktop/link-2026-11-17/U3.md`.
class LinkTogetherCoordinator {
  LinkTogetherCoordinator({
    required this.phoneLeads,
    required LinkTogetherDeck phone,
    required LinkTogetherPeer desktop,
    required int Function() shiftMs,
    required void Function(LinkTogetherEnd end) onEnded,
    Future<bool> Function(TrackRef track)? onMissing,
    int Function()? nowMs,
    LinkClockOffset? clock,
    LinkTogetherAligner? aligner,
    LinkTogetherFollower? follower,
    this.pollInterval = const Duration(seconds: 1),
    this.maxFailures = 3,
    this.transitionMs = 2500,
    this.maxTransitionWaitMs = 4000,
    this.freshMs = 600,
  }) : _phone = phone,
       _desktop = desktop,
       _shiftMs = shiftMs,
       _onEnded = onEnded,
       _onMissing = onMissing,
       _nowMs = nowMs ?? _wallClockMs,
       clock = clock ?? linkTogetherClock(),
       aligner = aligner ?? LinkTogetherAligner() {
    _follower = follower ?? LinkTogetherFollower(deck: phone, nowMs: _nowMs);
  }

  /// The clock measurement Play together keeps: a dozen recent samples, so
  /// the shortest round trip of the last polls wins.
  static LinkClockOffset linkTogetherClock() =>
      LinkClockOffset(keep: 12, maxRoundTripMs: 1000);

  /// True when the phone owns the queue and the computer follows.
  final bool phoneLeads;
  final LinkTogetherDeck _phone;
  final LinkTogetherPeer _desktop;

  /// The timing adjustment: how much later the phone plays than the
  /// computer, in milliseconds (negative: earlier).
  final int Function() _shiftMs;
  final void Function(LinkTogetherEnd end) _onEnded;

  /// Gives the follower the leader's queue again when it lacks [track];
  /// true once sent.
  final Future<bool> Function(TrackRef track)? _onMissing;
  final int Function() _nowMs;

  /// The computer's clock against the phone's.
  final LinkClockOffset clock;
  final LinkTogetherAligner aligner;

  /// Carries out cues on the phone while it follows.
  late final LinkTogetherFollower _follower;

  final Duration pollInterval;

  /// Reads in a row that may fail before the session counts as gone.
  final int maxFailures;

  /// Near a song's end, how long the two may play different songs.
  final int transitionMs;
  final int maxTransitionWaitMs;

  /// The oldest computer reading a drift sample uses.
  final int freshMs;

  LinkTogetherReport? _report;
  bool _reportFresh = false;
  int? _checkLoggedAtMs;
  LinkTogetherReport? _lastPhone;
  LinkTogetherReport? _lastLeader;
  Timer? _poll;
  StreamSubscription<void>? _changes;
  bool _started = false;
  bool _ended = false;
  bool _evaluating = false;
  bool _again = false;
  bool _scheduled = false;
  bool _rejoining = false;
  bool _reading = false;
  int _failures = 0;
  bool _held = false;
  bool _realign = false;
  TrackRef? _missingFor;
  int? _transitionSince;
  int? _stoppedSince;
  LinkRepeatMode? _repeatSent;

  /// The latest drift sample, follower minus leader, for tests.
  int? lastErrorMs;

  /// Rejoins so far, for tests.
  int rejoins = 0;

  bool get ended => _ended;

  /// Starts keeping the two in step, from the computer's [report] if one
  /// was just read.
  void start([LinkTogetherReport? report]) {
    if (_started || _ended) return;
    _started = true;
    if (report != null) _report ??= report;
    _changes = _phone.changes.listen((_) => _schedule());
    _poll = Timer.periodic(pollInterval, (_) => unawaited(_tick()));
    _schedule();
  }

  /// Ends the session without telling anyone. With [resume], a start the
  /// phone was waiting for happens now, so it keeps playing.
  void stop({bool resume = false}) {
    if (_ended) return;
    _ended = true;
    _poll?.cancel();
    unawaited(_changes?.cancel());
    _follower.cancel(resume: resume);
  }

  void _end(LinkTogetherEnd end) {
    if (_ended) return;
    stop(resume: end == LinkTogetherEnd.disconnected);
    _log.i('Link: together ended (${end.name})');
    _onEnded(end);
  }

  /// The connection went: the phone keeps playing alone.
  void disconnected() => _end(LinkTogetherEnd.disconnected);

  /// A `together.state` push: the computer's player at a change.
  void onDesktopReport(LinkTogetherReport report) {
    if (_ended) return;
    final last = _report;
    if (last != null && report.nowMs < last.nowMs) return;
    _report = report;
    _reportFresh = true;
    _schedule();
  }

  /// A `together.action` push: the computer's own controls, while it
  /// follows, drive the queue's owner. A device picked in the computer's
  /// Devices ends the session whichever device owns the queue.
  Future<void> onDesktopAction(String action) async {
    if (_ended) return;
    _log.i('Link: together, the computer asked for $action');
    if (action == LinkTogetherActions.leftForPhone) {
      _end(LinkTogetherEnd.leftOnPhone);
      return;
    }
    if (!phoneLeads && action != LinkTogetherActions.left) return;
    switch (action) {
      case LinkTogetherActions.pause:
        await _phone.pause();
      case LinkTogetherActions.play:
        await _phone.play();
      case LinkTogetherActions.next:
        await _phone.next();
      case LinkTogetherActions.previous:
        await _phone.previous();
      case LinkTogetherActions.left:
        _end(LinkTogetherEnd.leftOnDesktop);
    }
  }

  /// The timing adjustment changed: line the follower up at once.
  void shiftChanged() {
    _realign = true;
    _schedule();
  }

  Future<void> _tick() async {
    if (_ended || _reading) return;
    await _read();
    _schedule();
  }

  Future<void> _read() async {
    _reading = true;
    try {
      final sent = _nowMs();
      final report = await _desktop.read();
      final received = _nowMs();
      if (_ended) return;
      clock.add(sentMs: sent, receivedMs: received, remoteMs: report.nowMs);
      _failures = 0;
      final last = _report;
      if (last == null || report.nowMs >= last.nowMs) {
        _report = report;
        _reportFresh = true;
      }
    } on Object catch (error) {
      if (_ended) return;
      if (++_failures >= maxFailures) {
        _log.w('Link: together, the computer stopped answering: $error');
        _end(LinkTogetherEnd.disconnected);
      }
    } finally {
      _reading = false;
    }
  }

  void _schedule() {
    if (_ended || !_started || _scheduled) return;
    if (_evaluating) {
      _again = true;
      return;
    }
    _scheduled = true;
    scheduleMicrotask(() async {
      _scheduled = false;
      if (_ended) return;
      _evaluating = true;
      try {
        await _evaluate();
      } on Object catch (error) {
        _log.w('Link: together, a check failed: $error');
      } finally {
        _evaluating = false;
        if (_again) {
          _again = false;
          _schedule();
        }
      }
    });
  }

  bool _jumped(LinkTogetherReport before, LinkTogetherReport after) {
    final expected = before.positionAt(after.nowMs);
    return (after.positionMs - expected).abs() > 1000;
  }

  /// A song change of the phone, while it follows, that the coordinator did
  /// not cause and that is no song ending: the listener picked another song.
  void _watchPhone(LinkTogetherReport phone, int now) {
    final last = _lastPhone;
    _lastPhone = phone;
    if (phoneLeads || last == null || _rejoining || _follower.busy) return;
    if (now - _follower.lastActionMs < 1500) return;
    if (phone.track != null &&
        !linkTogetherSameTrack(last.track, phone.track)) {
      // Where the song before would be by now: one that ran out moved on
      // by itself.
      final remaining = last.remainingAt(phone.nowMs);
      final natural = remaining == null || remaining < transitionMs;
      if (!natural) {
        _end(LinkTogetherEnd.leftOnPhone);
        return;
      }
    }
    if (last.playing &&
        !phone.playing &&
        !_follower.silent &&
        !_ranOut(phone, now)) {
      // A call or another app took the sound: only the phone waits.
      _held = true;
      _log.i('Link: together, the phone paused by itself and waits');
    } else if (!last.playing && phone.playing && _held) {
      _held = false;
    }
  }

  Future<void> _evaluate() async {
    final offset = clock.offsetMs;
    final raw = _report;
    if (_ended || offset == null || raw == null) return;
    final now = _nowMs();
    // The computer's player on the phone's clock.
    final desktop = raw.shifted(offset);
    var phone = _phone.read();
    if (!phoneLeads) phone = phone.copyWith(silent: _follower.silent);
    _watchPhone(phone, now);
    if (_ended) return;
    final leader = phoneLeads ? phone : desktop;
    final follower = phoneLeads ? desktop : phone;
    final last = _lastLeader;
    if (last == null ||
        !linkTogetherSameTrack(last.track, leader.track) ||
        last.playing != leader.playing ||
        _jumped(last, leader)) {
      _held = false;
      aligner.restart(now);
    }
    _lastLeader = leader;
    if (_rejoining || (phoneLeads ? raw.busy : _follower.busy)) return;
    if (follower.repeat != leader.repeat && _repeatSent != leader.repeat) {
      _repeatSent = leader.repeat;
      await _setFollowerRepeat(leader.repeat);
    }
    if (_held) return;
    final track = leader.track;
    if (track == null) {
      if (follower.playing) await _pauseFollower();
      return;
    }
    if (!linkTogetherSameTrack(track, follower.track) || follower.silent) {
      if (follower.silent && linkTogetherSameTrack(_missingFor, track)) return;
      if (_inTransition(leader, follower, now)) return;
      // While the leader loads its song the follower loads it too, paused,
      // so it only has to start once the leader plays.
      await _rejoin(
        leader,
        offset,
        'song',
        playing: leader.playing && leader.ready,
      );
      return;
    }
    _transitionSince = null;
    if (leader.playing != follower.playing) {
      if (leader.playing && !leader.ready) return;
      if (_betweenSongs(leader.playing ? follower : leader, now)) return;
      await _rejoin(leader, offset, leader.playing ? 'play' : 'pause');
      return;
    }
    _stoppedSince = null;
    if (!leader.playing) {
      final target = _followerTarget(leader.positionAt(now));
      if ((follower.positionAt(now) - target).abs() > 1000) {
        await _rejoin(leader, offset, 'position');
      }
      return;
    }
    if (!leader.ready || !follower.ready) return;
    if (_realign) {
      _realign = false;
      await _rejoin(leader, offset, 'timing');
      return;
    }
    // A drift sample at the instant the computer read its player, which the
    // offset places on the phone's clock.
    final at = desktop.nowMs;
    if (!_reportFresh || now - at > freshMs || at > now + 50) return;
    _reportFresh = false;
    final phoneAt = phone.positionAt(at);
    final phoneError = phoneAt - (desktop.positionMs - _shiftMs());
    final error = phoneLeads ? -phoneError : phoneError;
    lastErrorMs = error;
    final canNudge = phoneLeads ? raw.canNudge : _phone.canNudge;
    final who = phoneLeads ? 'computer' : 'phone';
    // The follower's own report, where it should be, and what it was doing.
    final reported = phoneLeads ? desktop.positionMs : phoneAt;
    final rate = (phoneLeads ? raw : phone).rate;
    final nudging = aligner.nudging(now);
    final settling = aligner.settling(now);
    // Every check would push all else out of the log within minutes.
    final loggedAt = _checkLoggedAtMs;
    if (loggedAt == null ||
        now - loggedAt >= (nudging || settling ? 1000 : 5000)) {
      _checkLoggedAtMs = now;
      _log.d(
        'Link: together, check: $who at ${reported}ms, expected '
        '${reported - error}ms, drift ${error}ms, rate '
        '${rate?.toStringAsFixed(2) ?? '?'}, nudge ${nudging ? 'on' : 'off'}'
        '${settling ? ', settling' : ''}',
      );
    }
    final step = aligner.sample(error, now, canNudge: canNudge);
    final landing = aligner.takeLanding();
    if (landing != null) {
      _log.i(
        'Link: together, nudge ended: drift before ${landing.beforeMs}ms, '
        'expected ${landing.expectedMs}ms, measured ${landing.measuredMs}ms '
        '(the rate changes moved it ${landing.costMs}ms, now counted as '
        '${landing.countedCostMs}ms)',
      );
      if (landing.holding) {
        _log.i(
          'Link: together, nudges do not land within ${aligner.inStepMs}ms '
          'here, holding until the drift passes ${aligner.holdFromMs}ms',
        );
      }
    }
    switch (step) {
      case LinkTogetherWait():
        break;
      case LinkTogetherNudge(:final factor, :final durationMs):
        _log.i(switch ((factor == 1, nudging)) {
          (true, _) => 'Link: together, drift ${error}ms, ending the nudge',
          (false, true) =>
            'Link: together, drift ${error}ms, the nudge goes on '
                '${durationMs}ms more',
          (false, false) =>
            'Link: together, drift ${error}ms, nudging the $who to $factor '
                'for ${durationMs}ms (rate changes counted as '
                '${aligner.countedCostMs}ms)',
        });
        if (phoneLeads) {
          await _desktop.nudge(factor, durationMs);
        } else {
          _follower.nudge(factor, durationMs);
        }
      case LinkTogetherRejoin():
        _log.i('Link: together, drift ${error}ms, rejoining');
        await _rejoin(leader, offset, 'drift');
    }
  }

  /// Whether the two are on neighbouring songs at a song boundary, which
  /// each crosses by itself.
  bool _inTransition(
    LinkTogetherReport leader,
    LinkTogetherReport follower,
    int now,
  ) {
    if (follower.track == null || follower.silent) return false;
    final leaderRemaining = leader.remainingAt(now);
    final followerRemaining = follower.remainingAt(now);
    final near =
        (followerRemaining != null &&
            followerRemaining < transitionMs &&
            leader.positionAt(now) < transitionMs) ||
        (leaderRemaining != null &&
            leaderRemaining < transitionMs &&
            follower.positionAt(now) < transitionMs);
    if (!near) {
      _transitionSince = null;
      return false;
    }
    final since = _transitionSince ??= now;
    return now - since < maxTransitionWaitMs;
  }

  /// Whether [stopped], the one that reads as not playing, only ran out of
  /// its song: until the next one starts a player reports neither playing
  /// nor paused, and a cue then would pause the other or land in the middle
  /// of its own song change.
  bool _betweenSongs(LinkTogetherReport stopped, int now) {
    if (!_ranOut(stopped, now)) {
      _stoppedSince = null;
      return false;
    }
    final since = _stoppedSince ??= now;
    return now - since < maxTransitionWaitMs;
  }

  /// Whether [report] shows a song that ran out, not one that was paused.
  bool _ranOut(LinkTogetherReport report, int now) {
    final remaining = report.remainingAt(now);
    return !report.playing &&
        !report.ready &&
        remaining != null &&
        remaining < transitionMs;
  }

  /// The follower's position for the leader at [leaderMs], with the timing
  /// adjustment: the phone plays [_shiftMs] later than the computer.
  int _followerTarget(int leaderMs) =>
      phoneLeads ? leaderMs + _shiftMs() : leaderMs - _shiftMs();

  LinkTogetherCue _cueFor(LinkTogetherReport leader, TrackRef track, bool on) {
    final now = _nowMs();
    return LinkTogetherCue(
      track: track,
      positionMs: math.max(0, _followerTarget(leader.positionAt(now))),
      atMs: now,
      playing: on,
      leadMs: aligner.leadMs,
    );
  }

  /// Sends the follower a cue for the leader's song and position; [playing]
  /// overrides whether it starts.
  Future<void> _rejoin(
    LinkTogetherReport leader,
    int offset,
    String reason, {
    bool? playing,
  }) async {
    final track = leader.track;
    if (track == null) return;
    final plays = playing ?? leader.playing;
    _rejoining = true;
    rejoins++;
    try {
      final cue = _cueFor(leader, track, plays);
      _log.i(
        'Link: together, cue ($reason) for the '
        '${phoneLeads ? 'computer' : 'phone'} at ${cue.positionMs}ms, '
        'lead ${cue.leadMs}ms',
      );
      var found = await _cue(cue, offset);
      if (_ended) return;
      if (!found && !linkTogetherSameTrack(_missingFor, track)) {
        _missingFor = track;
        final missing = _onMissing;
        if (missing != null && await missing(track) && !_ended) {
          _log.i('Link: together, sent the queue again for a missing song');
          found = await _cue(_cueFor(leader, track, plays), offset);
        }
      }
      if (found) _missingFor = null;
      if (plays && found) aligner.rejoined(_nowMs());
    } on Object catch (error) {
      _log.w('Link: together, a cue failed: $error');
    } finally {
      _rejoining = false;
      _reportFresh = false;
    }
  }

  Future<bool> _cue(LinkTogetherCue cue, int offset) =>
      phoneLeads ? _desktop.rejoin(cue.shifted(offset)) : _follower.rejoin(cue);

  Future<void> _pauseFollower() async {
    try {
      if (phoneLeads) {
        await _desktop.command(const LinkCommand(LinkActions.pause));
      } else {
        await _phone.pause();
      }
    } on Object catch (error) {
      _log.w('Link: together, could not pause the follower: $error');
    }
  }

  Future<void> _setFollowerRepeat(LinkRepeatMode mode) async {
    try {
      if (phoneLeads) {
        await _desktop.command(
          LinkCommand(LinkActions.repeat, {'mode': mode.name}),
        );
      } else {
        await _phone.setRepeat(mode);
      }
    } on Object catch (error) {
      _log.w('Link: together, could not set the repeat mode: $error');
    }
  }
}
