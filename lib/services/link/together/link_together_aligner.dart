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
/// a factor of 1 stops a nudge under way. A nudge at the rate already in
/// force only moves its end.
final class LinkTogetherNudge extends LinkTogetherStep {
  const LinkTogetherNudge(this.factor, this.durationMs);

  final double factor;
  final int durationMs;
}

/// Line the follower up again with a new cue.
final class LinkTogetherRejoin extends LinkTogetherStep {
  const LinkTogetherRejoin();
}

/// How one nudge turned out, read at the first settled check after it.
class LinkTogetherLanding {
  const LinkTogetherLanding({
    required this.beforeMs,
    required this.expectedMs,
    required this.measuredMs,
    required this.costMs,
    required this.countedCostMs,
    required this.holding,
  });

  /// The drift the nudge was planned for.
  final int beforeMs;

  /// Where the plan expected the drift to end, the counted cost included.
  final int expectedMs;

  /// The drift measured once the follower settled.
  final int measuredMs;

  /// What the two rate changes moved the follower this time: the measured
  /// drift minus what the rate alone explains.
  final int costMs;

  /// The cost the next nudge is planned with.
  final int countedCostMs;

  /// This landing made the aligner hold (see [LinkTogetherAligner.holding]).
  final bool holding;
}

/// A nudge under way, or ended and waiting for its landing to be read.
class _Nudge {
  _Nudge({
    required this.beforeMs,
    required this.sign,
    required this.factor,
    required this.startMs,
    required this.untilMs,
    required this.costMs,
    required this.knewCost,
  });

  final int beforeMs;

  /// 1 while the follower plays faster (its error grows), -1 slower.
  final int sign;
  final double factor;
  final int startMs;
  int untilMs;

  /// The rate change cost the plan counts (updated once entering the rate
  /// was measured), and whether an earlier nudge measured one.
  int costMs;
  final bool knewCost;

  /// What entering the rate moved the follower, once a settled check
  /// during the nudge showed it.
  int? enterMs;
  bool replanned = false;
}

/// Decides, from the follower's error against the leader (positive while it
/// runs ahead), how to keep the two in step: leave small errors alone, close
/// moderate ones and steady small ones by playing the follower a little
/// faster or slower, and rejoin for large ones, without rejoining over and
/// over when that does not help. It also learns how late the follower
/// sounds after being told to start, which the next cue starts early by.
///
/// Some engines move the song a little each time their rate changes: a
/// plain AVPlayer change held its clock for 21 to 26 ms. The aligner
/// measures that cost on every nudge and plans the next one with it, so a
/// nudge ends in step instead of short of it. Where nudges still keep
/// missing (the cost varies too much), it holds: no more nudges until the
/// error passes [holdFromMs], so the rate is not toggled for nothing.
class LinkTogetherAligner {
  LinkTogetherAligner({
    this.inStepMs = 20,
    this.nudgeFromMs = 35,
    this.fineFromMs = 12,
    this.fineSamples = 5,
    this.rejoinFromMs = 250,
    this.rejoinWithoutNudgeFromMs = 80,
    this.holdFromMs = 80,
    this.rate = 0.02,
    this.minNudgeMs = 200,
    this.maxNudgeMs = 15000,
    this.settleMs = 1200,
    this.rateSettleMs = 1000,
    this.minRejoinGapMs = 2000,
    this.maxRejoinGapMs = 16000,
    this.maxLeadMs = 600,
    this.leadAgreeMs = 25,
    this.maxMisses = 2,
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

  /// While holding, errors from this, twice in a row, start a nudge.
  final int holdFromMs;

  /// How much faster or slower a nudge plays: 2 % closes 20 ms a second.
  final double rate;
  final int minNudgeMs;
  final int maxNudgeMs;

  /// After a rejoin or a change, samples wait this long: players report a
  /// fresh start unevenly.
  final int settleMs;

  /// After a rate change, samples wait this long: the follower's report
  /// shows what the change did only once its player has read the engine.
  final int rateSettleMs;
  final int minRejoinGapMs;
  final int maxRejoinGapMs;
  final int maxLeadMs;

  /// Two settled samples after a rejoin this close together are trusted as
  /// the follower's start offset.
  final int leadAgreeMs;

  /// Nudges of the last four planned with a measured cost that may end
  /// outside [inStepMs] before the aligner holds; once it held, one does.
  final int maxMisses;

  /// How early the follower is told to start, learned from how late it
  /// sounded after the last rejoins; negative starts it late, where the
  /// leader is the slower one to sound after a play. At most [maxLeadMs]
  /// either way.
  int leadMs = 0;

  int _settleUntilMs = 0;
  _Nudge? _nudge;
  int _overNudge = 0;
  int _overRejoin = 0;
  int? _lastRejoinMs;
  int _rejoinGapMs;
  bool _holding = false;
  bool _held = false;
  int _landed = 0;

  /// 1 for each of the last nudges planned with a measured cost that ended
  /// out of step, 0 for one in step.
  final _missed = <int>[];
  LinkTogetherLanding? _landing;

  /// Errors since the last change, settled and while no nudge ran.
  final _recent = <int>[];

  /// After a rejoin that plays: the lead it used and its settled samples.
  bool _learning = false;
  int _leadUsed = 0;
  final _learnSamples = <int>[];

  /// The leads the last rejoins needed, and what the rate changes of the
  /// last nudges cost, in all and on entering the rate.
  final _leads = <int>[];
  final _costs = <int>[];
  final _enterCosts = <int>[];

  /// Whether a nudge runs at [nowMs].
  bool nudging(int nowMs) => (_nudge?.untilMs ?? 0) > nowMs;

  /// Whether a sample at [nowMs] would be ignored as unsettled.
  bool settling(int nowMs) {
    if (nowMs < _settleUntilMs) return true;
    final nudge = _nudge;
    if (nudge == null) return false;
    return nowMs - nudge.startMs < rateSettleMs ||
        (nowMs >= nudge.untilMs && nowMs - nudge.untilMs < rateSettleMs);
  }

  /// Nudges keep missing here: the aligner only acts on errors from
  /// [holdFromMs]. Two nudges in a row that end in step lift it, until the
  /// next miss.
  bool get holding => _holding;

  /// The rate change cost the next nudge is planned with: the median of
  /// the last measurements, 0 until one was made.
  int get countedCostMs => _median(_costs) ?? 0;

  /// How the last nudge turned out, once; null when none was read since.
  LinkTogetherLanding? takeLanding() {
    final landing = _landing;
    _landing = null;
    return landing;
  }

  static int? _median(List<int> values) {
    if (values.isEmpty) return null;
    final sorted = [...values]..sort();
    final middle = sorted.length ~/ 2;
    return sorted.length.isOdd
        ? sorted[middle]
        : ((sorted[middle - 1] + sorted[middle]) / 2).round();
  }

  static void _keep(List<int> values, int value, [int count = 3]) {
    values.add(value);
    if (values.length > count) values.removeAt(0);
  }

  /// A rejoin ended with the follower started at [startedMs]. The first
  /// settled samples after it set [leadMs]. Most rejoins follow the leader
  /// starting, so the lead also covers how much later the follower's player
  /// sounds than the leader's.
  void rejoined(int startedMs) {
    _settleUntilMs = startedMs + settleMs;
    _lastRejoinMs = startedMs;
    _nudge = null;
    _overNudge = 0;
    _overRejoin = 0;
    _recent.clear();
    _learning = true;
    _leadUsed = leadMs;
    _learnSamples.clear();
  }

  /// The leader changed song, play state or position: wait for it to settle
  /// and learn nothing from what follows.
  void restart(int nowMs) {
    _settleUntilMs = nowMs + settleMs;
    _nudge = null;
    _overNudge = 0;
    _overRejoin = 0;
    _recent.clear();
    _learning = false;
  }

  /// Takes the follower's error [errorMs] at [nowMs].
  LinkTogetherStep sample(int errorMs, int nowMs, {required bool canNudge}) {
    if (nowMs < _settleUntilMs) return const LinkTogetherWait();
    final nudge = _nudge;
    if (nudge != null) {
      if (nowMs - nudge.startMs < rateSettleMs) return const LinkTogetherWait();
      if (nowMs < nudge.untilMs) {
        return _during(nudge, errorMs, nowMs, canNudge);
      }
      if (nowMs - nudge.untilMs < rateSettleMs) return const LinkTogetherWait();
      _nudge = null;
      _land(nudge, errorMs);
    }
    if (_learning) _learn(errorMs);
    return _decide(errorMs, nowMs, canNudge: canNudge);
  }

  /// Learns the lead from the settled samples after a rejoin, once one
  /// confirms the last.
  void _learn(int errorMs) {
    // Far off is a different problem (a wrong song or place), not a start.
    if (errorMs.abs() > maxLeadMs + 200) {
      _learning = false;
      return;
    }
    _learnSamples.add(errorMs);
    final count = _learnSamples.length;
    int? settled;
    if (count >= 2 &&
        (_learnSamples[count - 1] - _learnSamples[count - 2]).abs() <=
            leadAgreeMs) {
      settled = ((_learnSamples[count - 1] + _learnSamples[count - 2]) / 2)
          .round();
    } else if (count >= 4) {
      settled = _median(_learnSamples.sublist(count - 3));
    }
    if (settled != null) _settleLead(settled);
  }

  /// The follower settled [settledMs] off after the last rejoin.
  void _settleLead(int settledMs) {
    _learning = false;
    // Behind (negative) means it sounded late: start it earlier next time,
    // by all of it, averaged with the last rejoins' needs.
    _keep(_leads, _leadUsed - settledMs);
    final mean = _leads.reduce((a, b) => a + b) / _leads.length;
    leadMs = mean.round().clamp(-maxLeadMs, maxLeadMs);
  }

  LinkTogetherStep _decide(int errorMs, int nowMs, {required bool canNudge}) {
    final magnitude = errorMs.abs();
    _keep(_recent, errorMs, fineSamples);
    final rejoinFrom = canNudge ? rejoinFromMs : rejoinWithoutNudgeFromMs;
    if (magnitude <= inStepMs) {
      _overNudge = 0;
      _overRejoin = 0;
      _rejoinGapMs = minRejoinGapMs;
      return _fine(nowMs, canNudge: canNudge);
    }
    if (magnitude > rejoinFrom) {
      return _towardsRejoin(magnitude, nowMs, canNudge);
    }
    _overRejoin = 0;
    _rejoinGapMs = minRejoinGapMs;
    final from = _holding ? holdFromMs : nudgeFromMs;
    if (!canNudge || magnitude < from) {
      _overNudge = 0;
      return _fine(nowMs, canNudge: canNudge);
    }
    if (++_overNudge < 2) return const LinkTogetherWait();
    _overNudge = 0;
    return _start(errorMs, nowMs);
  }

  LinkTogetherStep _towardsRejoin(int magnitude, int nowMs, bool canNudge) {
    _overNudge = 0;
    final needed = magnitude > 1500 ? 1 : (canNudge ? 2 : 3);
    final last = _lastRejoinMs;
    if (++_overRejoin >= needed &&
        (last == null || nowMs - last >= _rejoinGapMs)) {
      _overRejoin = 0;
      _nudge = null;
      if (last != null) {
        _rejoinGapMs = math.min(_rejoinGapMs * 2, maxRejoinGapMs);
      }
      return const LinkTogetherRejoin();
    }
    return const LinkTogetherWait();
  }

  /// A short nudge for a small error that stays. Where the rate changes
  /// move the song more than [inStepMs], only an error that stays out of
  /// step is worth them.
  LinkTogetherStep _fine(int nowMs, {required bool canNudge}) {
    if (!canNudge || _holding || _recent.length < fineSamples) {
      return const LinkTogetherWait();
    }
    final mean = _recent.reduce((a, b) => a + b) / _recent.length;
    final costly = countedCostMs.abs() > inStepMs;
    if (costly ? mean.abs() <= inStepMs : mean.abs() < fineFromMs) {
      return const LinkTogetherWait();
    }
    return _start(mean.round(), nowMs);
  }

  /// A nudge that should end with the follower in step: the rate must move
  /// it by the error and by what the two rate changes cost.
  LinkTogetherNudge _start(int errorMs, int nowMs) {
    _recent.clear();
    // The samples after a nudge show the nudge, not the start: learn from
    // what came before it.
    if (_learning) {
      final settled = _median(_learnSamples);
      if (settled == null) {
        _learning = false;
      } else {
        _settleLead(settled);
      }
    }
    final cost = countedCostMs;
    final need = -errorMs - cost;
    final sign = need >= 0 ? 1 : -1;
    final duration = (need.abs() / rate).round().clamp(minNudgeMs, maxNudgeMs);
    final factor = 1 + sign * rate;
    _nudge = _Nudge(
      beforeMs: errorMs,
      sign: sign,
      factor: factor,
      startMs: nowMs,
      untilMs: nowMs + duration,
      costMs: cost,
      knewCost: _costs.isNotEmpty,
    );
    return LinkTogetherNudge(factor, duration);
  }

  /// A settled sample while [nudge] runs. The first one shows what entering
  /// the rate cost; when the nudge would then end out of step, its end
  /// moves once (same rate, so no extra rate change).
  LinkTogetherStep _during(
    _Nudge nudge,
    int errorMs,
    int nowMs,
    bool canNudge,
  ) {
    final rejoinFrom = canNudge ? rejoinFromMs : rejoinWithoutNudgeFromMs;
    if (errorMs.abs() > rejoinFrom) {
      return _towardsRejoin(errorMs.abs(), nowMs, canNudge);
    }
    _overRejoin = 0;
    final byRate = nudge.beforeMs + nudge.sign * rate * (nowMs - nudge.startMs);
    final enter = nudge.enterMs ??= (errorMs - byRate).round();
    if (nudge.replanned) return const LinkTogetherWait();
    // What leaving the rate will cost: what the last nudges cost less what
    // entering cost them, or before one landed, what entering cost now
    // (AVPlayer loses about as much each way).
    final leave = _costs.isEmpty
        ? enter
        : countedCostMs - (_median(_enterCosts) ?? enter);
    nudge.costMs = enter + leave;
    final remaining = nudge.untilMs - nowMs;
    final landing = errorMs + nudge.sign * rate * remaining + leave;
    if (landing.abs() <= inStepMs) return const LinkTogetherWait();
    nudge.replanned = true;
    final needed = (-(errorMs + leave) / (nudge.sign * rate)).round();
    if (needed <= 0) {
      nudge.untilMs = nowMs;
      return const LinkTogetherNudge(1, 0);
    }
    final duration = math.min(needed, maxNudgeMs);
    nudge.untilMs = nowMs + duration;
    return LinkTogetherNudge(nudge.factor, duration);
  }

  /// Reads how [nudge] ended from the first settled sample after it, and
  /// counts what its rate changes cost.
  void _land(_Nudge nudge, int errorMs) {
    final byRate =
        nudge.beforeMs + nudge.sign * rate * (nudge.untilMs - nudge.startMs);
    final cost = (errorMs - byRate).round();
    _keep(_costs, cost);
    final enter = nudge.enterMs;
    if (enter != null) _keep(_enterCosts, enter);
    final missed = errorMs.abs() > inStepMs;
    if (missed) {
      _landed = 0;
    } else if (_holding && ++_landed >= 2) {
      _holding = false;
      _landed = 0;
    }
    var held = false;
    // A first nudge, planned without a measured cost, may miss by it.
    if (nudge.knewCost) {
      _keep(_missed, missed ? 1 : 0, 4);
      final misses = _missed.reduce((a, b) => a + b);
      if (missed && !_holding && misses >= (_held ? 1 : maxMisses)) {
        _holding = _held = true;
        held = true;
      }
    }
    _landing = LinkTogetherLanding(
      beforeMs: nudge.beforeMs,
      expectedMs: (byRate + nudge.costMs).round(),
      measuredMs: errorMs,
      costMs: cost,
      countedCostMs: countedCostMs,
      holding: held,
    );
  }
}
