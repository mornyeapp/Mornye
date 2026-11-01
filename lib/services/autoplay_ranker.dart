import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart'
    show ValueListenable, ValueNotifier, compute, visibleForTesting;
import 'package:mornye/services/autoplay_personalization.dart';
import 'package:mornye/services/sqlite_helpers.dart' as sqlite;
import 'package:mornye/utils/logger.dart';
import 'package:sqflite/sqflite.dart';

final _log = AppLogger('AutoplayRanker');

/// The most outcomes the ranker keeps; the oldest go first.
const autoplayRankerLogLimit = 2000;

/// Outcomes needed before learned weights may replace the starting ones.
const autoplayRankerMinimum = 40;

/// New outcomes that start learning again.
const _retrainAfter = 10;

/// Picks the ranker waits on for the listener's verdict.
const _rememberedLimit = 200;

// Score points to the log-odds of keeping a song: five more points make a
// song about e times likelier to be kept.
const _scale = 0.2;

// Each weight starts at 1, the hand-set ranking, and leaves it only as far
// as the outcomes show (a prior standard deviation of 0.5), within bounds.
const _weightPrecision = 4.0;
const _interceptPrecision = 0.25;
const _minWeight = 0.0, _maxWeight = 3.0;

// An outcome counts half as much every two months.
const _halfLife = Duration(days: 60);

/// How the listener took one autoplay pick: the parts of its score when it
/// was picked (see `AutoplayPick`), and the reward and weight learning gave
/// the feedback. Song identity is not kept.
class AutoplayRankOutcome {
  const AutoplayRankOutcome({
    required this.at,
    required this.parts,
    required this.reward,
    this.weight = 1,
  });

  final DateTime at;
  final Map<String, double> parts;
  final double reward, weight;

  /// Played on rather than skipped.
  bool get kept => reward >= 0.5;
}

/// How well rankings order the latest outcomes: the share of kept and
/// skipped pairs where the kept song scores higher (the AUC), for the
/// starting weights and for weights learned from the outcomes before them.
class AutoplayRankEvaluation {
  const AutoplayRankEvaluation({
    required this.outcomes,
    this.tested = 0,
    this.starting,
    this.learned,
  });

  /// Outcomes observed in all.
  final int outcomes;

  /// The latest outcomes held out to compare the rankings on.
  final int tested;

  /// Null while the held-out outcomes lack a kept or a skipped song.
  final double? starting, learned;

  /// Whether the learned weights rank at least as well as the starting
  /// ones, so autoplay uses them.
  bool get learnedWins {
    final starting = this.starting, learned = this.learned;
    return starting != null && learned != null && learned >= starting;
  }
}

/// What training found: the weights autoplay should use (empty for the
/// starting ones) and the evaluation that chose them.
typedef AutoplayRankTraining = ({
  Map<String, double> weights,
  AutoplayRankEvaluation evaluation,
});

/// Evaluates on the latest quarter of [outcomes] (at least 10) with weights
/// learned from the rest, and learns from all of them when that ranks at
/// least as well as the starting weights.
AutoplayRankTraining trainAutoplayRanker(List<AutoplayRankOutcome> outcomes) {
  final sorted = List.of(outcomes)..sort((a, b) => a.at.compareTo(b.at));
  if (sorted.length < autoplayRankerMinimum) {
    return (
      weights: const {},
      evaluation: AutoplayRankEvaluation(outcomes: sorted.length),
    );
  }
  final tested = max(10, sorted.length ~/ 4);
  final earlier = sorted.sublist(0, sorted.length - tested);
  final latest = sorted.sublist(sorted.length - tested);
  final evaluation = AutoplayRankEvaluation(
    outcomes: sorted.length,
    tested: tested,
    starting: autoplayRankAuc(latest, const {}),
    learned: autoplayRankAuc(latest, fitAutoplayRankWeights(earlier)),
  );
  return (
    weights: evaluation.learnedWins
        ? fitAutoplayRankWeights(sorted)
        : const <String, double>{},
    evaluation: evaluation,
  );
}

/// Logistic regression of keeping a song on its score parts, each part's
/// weight a multiplier with a Gaussian prior at 1, fitted by Newton's
/// method. Parts no outcome has keep their starting weight.
Map<String, double> fitAutoplayRankWeights(List<AutoplayRankOutcome> outcomes) {
  final names = {for (final outcome in outcomes) ...outcome.parts.keys}.toList()
    ..sort();
  if (names.isEmpty) return const {};
  final size = names.length + 1;
  // The intercept, then one multiplier per part.
  final prior = [0.0, for (var i = 1; i < size; i++) 1.0];
  final precision = [
    _interceptPrecision,
    for (var i = 1; i < size; i++) _weightPrecision,
  ];
  final latest = outcomes
      .map((outcome) => outcome.at)
      .reduce((a, b) => a.isAfter(b) ? a : b);
  final rows = [
    for (final outcome in outcomes)
      (
        z: [1.0, for (final name in names) _scale * (outcome.parts[name] ?? 0)],
        y: outcome.reward.clamp(0.0, 1.0),
        w:
            min(outcome.weight, 4.0) *
            pow(0.5, latest.difference(outcome.at).inHours / _halfLife.inHours),
      ),
  ];
  final theta = List.of(prior);
  for (var iteration = 0; iteration < 25; iteration++) {
    final gradient = [
      for (var i = 0; i < size; i++) precision[i] * (theta[i] - prior[i]),
    ];
    final hessian = [
      for (var i = 0; i < size; i++)
        [for (var j = 0; j < size; j++) i == j ? precision[i] : 0.0],
    ];
    for (final row in rows) {
      var logit = 0.0;
      for (var i = 0; i < size; i++) {
        logit += theta[i] * row.z[i];
      }
      final p = 1 / (1 + exp(-logit.clamp(-30.0, 30.0)));
      final curvature = row.w * p * (1 - p);
      for (var i = 0; i < size; i++) {
        gradient[i] += row.w * (p - row.y) * row.z[i];
        for (var j = 0; j < size; j++) {
          hessian[i][j] += curvature * row.z[i] * row.z[j];
        }
      }
    }
    final step = _solve(hessian, gradient);
    var largest = 0.0;
    for (var i = 0; i < size; i++) {
      theta[i] -= step[i];
      largest = max(largest, step[i].abs());
    }
    if (largest < 1e-6) break;
  }
  return {
    for (var i = 1; i < size; i++)
      names[i - 1]: theta[i].clamp(_minWeight, _maxWeight),
  };
}

/// Solves `matrix * x = vector` by Gaussian elimination with partial
/// pivoting; the matrix is a small positive definite Hessian.
List<double> _solve(List<List<double>> matrix, List<double> vector) {
  final n = vector.length;
  final a = [for (final row in matrix) List.of(row)];
  final b = List.of(vector);
  for (var column = 0; column < n; column++) {
    var pivot = column;
    for (var row = column + 1; row < n; row++) {
      if (a[row][column].abs() > a[pivot][column].abs()) pivot = row;
    }
    final row = a[column], value = b[column];
    a[column] = a[pivot];
    a[pivot] = row;
    b[column] = b[pivot];
    b[pivot] = value;
    for (var row = column + 1; row < n; row++) {
      final factor = a[row][column] / a[column][column];
      for (var k = column; k < n; k++) {
        a[row][k] -= factor * a[column][k];
      }
      b[row] -= factor * b[column];
    }
  }
  final x = List.filled(n, 0.0);
  for (var row = n - 1; row >= 0; row--) {
    var sum = b[row];
    for (var k = row + 1; k < n; k++) {
      sum -= a[row][k] * x[k];
    }
    x[row] = sum / a[row][row];
  }
  return x;
}

/// The share of kept and skipped pairs in [outcomes] that [weights] (1 for
/// absent parts) score in the right order, ties counting half; null without
/// both a kept and a skipped song.
double? autoplayRankAuc(
  List<AutoplayRankOutcome> outcomes,
  Map<String, double> weights,
) {
  final scored = [
    for (final outcome in outcomes)
      (
        score: outcome.parts.entries.fold(
          0.0,
          (sum, part) => sum + (weights[part.key] ?? 1) * part.value,
        ),
        kept: outcome.kept,
      ),
  ]..sort((a, b) => a.score.compareTo(b.score));
  final kept = scored.where((entry) => entry.kept).length;
  final skipped = scored.length - kept;
  if (kept == 0 || skipped == 0) return null;
  // Mann-Whitney: the kept songs' ranks, ties sharing their average rank.
  var rankSum = 0.0;
  for (var start = 0; start < scored.length;) {
    var end = start;
    while (end + 1 < scored.length &&
        scored[end + 1].score == scored[start].score) {
      end++;
    }
    final rank = (start + end) / 2 + 1;
    for (var i = start; i <= end; i++) {
      if (scored[i].kept) rankSum += rank;
    }
    start = end + 1;
  }
  return (rankSum - kept * (kept + 1) / 2) / (kept * skipped);
}

/// Learns how much each part of an autoplay score counts for this listener
/// from how they take the picks, on this device only. Learned weights
/// replace the hand-set ones only while they rank the latest outcomes at
/// least as well.
class AutoplayRanker {
  AutoplayRanker({
    Future<Database> Function()? open,
    Future<AutoplayRankTraining> Function(List<AutoplayRankOutcome>)? train,
  }) : _open = open ?? _openShared,
       _trainer = train ?? _trainOnWorker;

  final Future<Database> Function() _open;
  final Future<AutoplayRankTraining> Function(List<AutoplayRankOutcome>)
  _trainer;
  // Source to the parts of its score, oldest pick first.
  final _remembered = <String, Map<String, double>>{};
  final _pending = <AutoplayRankOutcome>[];
  final _evaluation = ValueNotifier<AutoplayRankEvaluation?>(null);
  Map<String, double> _weights = const {};
  Future<void>? _loading, _training, _queued;
  Future<void> _writing = Future<void>.value();
  Timer? _saveTimer;
  int _sinceTraining = 0, _generation = 0;
  bool _disposed = false;

  static final _shared = sqlite.SingleFlightInitializer<Database>();
  static const _schema = 1;

  static Future<Database> _openShared() => _shared.getOrCreate(
    () => sqlite.openAppDatabase(
      'autoplay_ranker.db',
      version: _schema,
      onCreate: _create,
      onUpgrade: (_, _, _) async {},
    ),
  );

  static Future<void> _create(Database db, int version) => db.execute('''
    CREATE TABLE outcomes (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      at INTEGER NOT NULL,
      reward REAL NOT NULL,
      weight REAL NOT NULL,
      parts TEXT NOT NULL
    )
  ''');

  /// Opens [path] with the ranker schema through [factory], for host tests
  /// that use FFI.
  @visibleForTesting
  static Future<Database> openWithFactory(
    DatabaseFactory factory,
    String path,
  ) => factory.openDatabase(
    path,
    options: OpenDatabaseOptions(version: _schema, onCreate: _create),
  );

  static Future<AutoplayRankTraining> _trainOnWorker(
    List<AutoplayRankOutcome> outcomes,
  ) => compute(trainAutoplayRanker, outcomes, debugLabel: 'autoplay-ranker');

  /// Multipliers of the score parts by name; empty for the starting ones.
  Map<String, double> get weights {
    unawaited(_ensureLoaded());
    return _weights;
  }

  /// The latest evaluation, null until the outcomes are read.
  ValueListenable<AutoplayRankEvaluation?> get evaluation {
    unawaited(_ensureLoaded());
    return _evaluation;
  }

  /// Keeps the parts of a pick's score until the listener's verdict.
  void remember(String source, Map<String, double> parts) {
    if (_disposed) return;
    _remembered.remove(source);
    _remembered[source] = parts;
    if (_remembered.length > _rememberedLimit) {
      _remembered.remove(_remembered.keys.first);
    }
  }

  /// Turns the first feedback on a remembered pick into an outcome.
  void record(AutoplayFeedback feedback) {
    final parts = _remembered.remove(feedback.track.source);
    if (parts == null || _disposed) return;
    _pending.add(
      AutoplayRankOutcome(
        at: feedback.at,
        parts: parts,
        reward: feedback.reward,
        weight: feedback.weight,
      ),
    );
    _saveTimer ??= Timer(const Duration(seconds: 10), () => unawaited(flush()));
    if (++_sinceTraining >= _retrainAfter) unawaited(train());
  }

  Future<void> flush() {
    _saveTimer?.cancel();
    _saveTimer = null;
    if (_pending.isEmpty) return _writing;
    final outcomes = List.of(_pending);
    _pending.clear();
    final generation = _generation;
    return _writing = _writing.then((_) async {
      if (generation != _generation) return;
      try {
        final batch = (await _open()).batch();
        for (final outcome in outcomes) {
          batch.insert('outcomes', {
            'at': outcome.at.millisecondsSinceEpoch,
            'reward': outcome.reward,
            'weight': outcome.weight,
            'parts': jsonEncode(outcome.parts),
          });
        }
        batch.rawDelete(
          'DELETE FROM outcomes WHERE id <= (SELECT MAX(id) FROM outcomes) - ?',
          [autoplayRankerLogLimit],
        );
        await batch.commit(noResult: true);
      } catch (error) {
        if (generation == _generation && !_disposed) {
          _pending.insertAll(0, outcomes);
        }
        _log.w('Could not save autoplay outcomes: $error');
      }
    });
  }

  /// The stored outcomes, oldest first.
  Future<List<AutoplayRankOutcome>> readOutcomes() async {
    await flush();
    final rows = await (await _open()).query('outcomes', orderBy: 'id');
    return [
      for (final row in rows)
        if (_parts(row['parts']) case final parts?)
          AutoplayRankOutcome(
            at: DateTime.fromMillisecondsSinceEpoch(row['at'] as int),
            parts: parts,
            reward: (row['reward'] as num).toDouble(),
            weight: (row['weight'] as num).toDouble(),
          ),
    ];
  }

  static Map<String, double>? _parts(Object? raw) {
    try {
      final decoded = raw is String ? jsonDecode(raw) : null;
      if (decoded is! Map) return null;
      return {
        for (final MapEntry(:key, :value) in decoded.entries)
          if (key is String && value is num && value.isFinite)
            key: value.toDouble(),
      };
    } on FormatException {
      return null;
    }
  }

  Future<void> _ensureLoaded() =>
      _loading ?? (_disposed ? Future<void>.value() : train());

  /// Learns from every stored outcome on a worker isolate. A run already
  /// learning read the outcomes before any later ones, so one more follows.
  /// The first run also loads what earlier launches learned.
  Future<void> train() {
    final running = _training;
    if (running == null) {
      final training = _training = _train().whenComplete(
        () => _training = null,
      );
      _loading ??= training;
      return training;
    }
    if (_sinceTraining == 0) return running;
    return _queued ??= running.then((_) {
      _queued = null;
      return train();
    });
  }

  Future<void> _train() async {
    final generation = _generation;
    _sinceTraining = 0;
    try {
      final outcomes = await readOutcomes();
      if (generation != _generation || _disposed) return;
      final training = await _trainer(outcomes);
      if (generation != _generation || _disposed) return;
      _weights = training.weights;
      _evaluation.value = training.evaluation;
      final evaluation = training.evaluation;
      _log.d(
        'Ranked ${evaluation.tested} of ${evaluation.outcomes} outcomes: '
        'starting ${evaluation.starting}, learned ${evaluation.learned}; '
        'weights $_weights',
      );
    } catch (error) {
      _loading = null;
      _log.w('Could not learn autoplay weights: $error');
    }
  }

  /// Forgets every outcome and the weights learned from them.
  Future<void> reset() async {
    _generation++;
    _remembered.clear();
    _pending.clear();
    _saveTimer?.cancel();
    _saveTimer = null;
    _weights = const {};
    _sinceTraining = 0;
    _evaluation.value = const AutoplayRankEvaluation(outcomes: 0);
    await (_writing = _writing.then((_) async {
      try {
        await (await _open()).delete('outcomes');
      } catch (error) {
        _log.w('Could not clear autoplay outcomes: $error');
      }
    }));
  }

  Future<void> dispose() async {
    _disposed = true;
    await flush();
  }
}
