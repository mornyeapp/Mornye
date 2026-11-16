import 'dart:math' as math;

/// What the coordinator does about one drift sample.
sealed class LinkTogetherStep {
  const LinkTogetherStep();
}

/// Nothing: in step, settling, or waiting for another sample.
final class LinkTogetherWait extends LinkTogetherStep {
  const LinkTogetherWait();
}

/// Play the follower at [factor] times the normal rate for [durationMs];
/// a factor of 1 stops a nudge under way.
final class LinkTogetherNudge extends LinkTogetherStep {
  const LinkTogetherNudge(this.factor, this.durationMs);

  final double factor;
  final int durationMs;
}

/// Line the follower up again with a new cue.
final class LinkTogetherRejoin extends LinkTogetherStep {
  const LinkTogetherRejoin();
}

/// Decides, from the follower's error against the leader (positive while it
/// runs ahead), how to keep the two in step: leave small errors alone, close
/// moderate ones and steady small ones by playing the follower a little
/// faster or slower, and rejoin for large ones, without rejoining over and
/// over when that does not help. It also learns how late the follower
/// sounds after being told to start, which the next cue starts early by.
class LinkTogetherAligner {
  LinkTogetherAligner({
    this.inStepMs = 20,
    this.nudgeFromMs = 35,
    this.fineFromMs = 12,
    this.fineSamples = 5,
    this.rejoinFromMs = 250,
    this.rejoinWithoutNudgeFromMs = 80,
    this.rate = 0.02,
    this.maxNudgeMs = 10000,
    this.settleMs = 1200,
    this.minRejoinGapMs = 2000,
    this.maxRejoinGapMs = 16000,
    this.maxLeadMs = 400,
  }) : _rejoinGapMs = minRejoinGapMs;

  /// Errors up to this are in step.
  final int inStepMs;

  /// Errors from this, twice in a row, start a nudge.
  final int nudgeFromMs;

  /// The last [fineSamples] errors averaging this or more start a short
  /// nudge: one sample is off by the reports' noise, their average is not.
  final int fineFromMs;
  final int fineSamples;

  /// Errors beyond this rejoin, since a nudge would take too long.
  final int rejoinFromMs;

  /// Where the follower cannot nudge, errors beyond this rejoin (three in a
  /// row, as a rejoin is heard).
  final int rejoinWithoutNudgeFromMs;

  /// How much faster or slower a nudge plays: 2 % closes 20 ms a second.
  final double rate;
  final int maxNudgeMs;

  /// After a rejoin or a change, samples wait this long: players report a
  /// fresh start unevenly.
  final int settleMs;
  final int minRejoinGapMs;
  final int maxRejoinGapMs;
  final int maxLeadMs;

  /// How early the follower is told to start, learned from how late it
  /// sounded after the last rejoins; negative starts it late, where the
  /// leader is the slower one to sound after a play. At most [maxLeadMs]
  /// either way.
  int leadMs = 0;

  int _settleUntilMs = 0;
  int _nudgeUntilMs = 0;
  int _nudgeSign = 0;
  int _overNudge = 0;
  int _overRejoin = 0;
  int? _lastRejoinMs;
  int _rejoinGapMs;
  bool _learn = false;

  /// Errors since the last change, while no nudge ran.
  final _recent = <int>[];

  /// Whether a nudge runs at [nowMs].
  bool nudging(int nowMs) => nowMs < _nudgeUntilMs;

  /// A rejoin ended with the follower started at [startedMs]. The first
  /// sample after settling adjusts [leadMs]. Most rejoins follow the leader
  /// starting, so the lead also covers how much later the follower's player
  /// sounds than the leader's.
  void rejoined(int startedMs) {
    _settleUntilMs = startedMs + settleMs;
    _lastRejoinMs = startedMs;
    _nudgeUntilMs = 0;
    _overNudge = 0;
    _overRejoin = 0;
    _recent.clear();
    _learn = true;
  }

  /// The leader changed song, play state or position: wait for it to settle
  /// and learn nothing from what follows.
  void restart(int nowMs) {
    _settleUntilMs = nowMs + settleMs;
    _nudgeUntilMs = 0;
    _overNudge = 0;
    _overRejoin = 0;
    _recent.clear();
    _learn = false;
  }

  /// Takes the follower's error [errorMs] at [nowMs].
  LinkTogetherStep sample(int errorMs, int nowMs, {required bool canNudge}) {
    if (nowMs < _settleUntilMs) return const LinkTogetherWait();
    final magnitude = errorMs.abs();
    if (_learn) {
      _learn = false;
      // Behind (negative) means it sounded late: start it earlier next time.
      if (magnitude <= rejoinFromMs) {
        leadMs = (leadMs - errorMs * 0.6).round().clamp(-maxLeadMs, maxLeadMs);
      }
    }
    final nudging = this.nudging(nowMs);
    if (!nudging) {
      _recent.add(errorMs);
      if (_recent.length > fineSamples) _recent.removeAt(0);
    }
    final rejoinFrom = canNudge ? rejoinFromMs : rejoinWithoutNudgeFromMs;
    if (magnitude <= inStepMs) {
      _overNudge = 0;
      _overRejoin = 0;
      _rejoinGapMs = minRejoinGapMs;
      if (nudging) {
        _nudgeUntilMs = 0;
        return const LinkTogetherNudge(1, 0);
      }
      return _fine(nowMs, canNudge: canNudge);
    }
    if (nudging) {
      // Past the leader: the nudge overshot.
      if (errorMs.sign != _nudgeSign) {
        _nudgeUntilMs = 0;
        return const LinkTogetherNudge(1, 0);
      }
      if (magnitude <= rejoinFrom) return const LinkTogetherWait();
    }
    if (magnitude > rejoinFrom) {
      _overNudge = 0;
      final needed = magnitude > 1500 ? 1 : (canNudge ? 2 : 3);
      final last = _lastRejoinMs;
      if (++_overRejoin >= needed &&
          (last == null || nowMs - last >= _rejoinGapMs)) {
        _overRejoin = 0;
        _nudgeUntilMs = 0;
        if (last != null) {
          _rejoinGapMs = math.min(_rejoinGapMs * 2, maxRejoinGapMs);
        }
        return const LinkTogetherRejoin();
      }
      return const LinkTogetherWait();
    }
    _overRejoin = 0;
    _rejoinGapMs = minRejoinGapMs;
    if (!canNudge || magnitude < nudgeFromMs) {
      _overNudge = 0;
      return _fine(nowMs, canNudge: canNudge);
    }
    if (++_overNudge < 2) return const LinkTogetherWait();
    _overNudge = 0;
    return _nudge(errorMs, nowMs);
  }

  /// A short nudge for a small error that stays.
  LinkTogetherStep _fine(int nowMs, {required bool canNudge}) {
    if (!canNudge || _recent.length < fineSamples) {
      return const LinkTogetherWait();
    }
    final mean = _recent.reduce((a, b) => a + b) / _recent.length;
    if (mean.abs() < fineFromMs) return const LinkTogetherWait();
    return _nudge(mean.round(), nowMs);
  }

  LinkTogetherNudge _nudge(int errorMs, int nowMs) {
    _recent.clear();
    final duration = math
        .min(errorMs.abs() / rate, maxNudgeMs.toDouble())
        .round();
    _nudgeSign = errorMs.sign;
    _nudgeUntilMs = nowMs + duration;
    // Ahead slows down; behind speeds up.
    return LinkTogetherNudge(errorMs > 0 ? 1 - rate : 1 + rate, duration);
  }
}
