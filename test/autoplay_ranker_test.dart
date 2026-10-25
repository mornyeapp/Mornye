import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/autoplay_personalization.dart';
import 'package:mornye/services/autoplay_ranker.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

final _start = DateTime(2026, 10, 1, 8);

/// A listener who keeps songs by their score parts weighed by [weights] (1
/// for the parts not named), as sharply as the ranker assumes: five more
/// points make a song about e times likelier to be kept.
List<AutoplayRankOutcome> _listener(
  Map<String, double> weights, {
  int count = 600,
  int seed = 3,
}) {
  final random = Random(seed);
  return [
    for (var i = 0; i < count; i++)
      () {
        final parts = {
          'genre': 6 * random.nextDouble(),
          'signal:sound': 5 * random.nextDouble(),
          'fatigue': -6 * random.nextDouble(),
        };
        var utility = 0.0;
        for (final MapEntry(:key, :value) in parts.entries) {
          utility += (weights[key] ?? 1) * value;
        }
        // Centered so about half of the songs are kept.
        final centre =
            3 * (weights['genre'] ?? 1) +
            2.5 * (weights['signal:sound'] ?? 1) -
            3 * (weights['fatigue'] ?? 1);
        final kept =
            random.nextDouble() < 1 / (1 + exp(-0.2 * (utility - centre)));
        return AutoplayRankOutcome(
          at: _start.add(Duration(minutes: 4 * i)),
          parts: parts,
          reward: kept ? 1 : 0,
        );
      }(),
  ];
}

AutoplayRankOutcome _outcome(double score, {required bool kept}) =>
    AutoplayRankOutcome(at: _start, parts: {'x': score}, reward: kept ? 1 : 0);

AutoplayFeedback _feedback(
  String source, {
  AutoplayFeedbackKind kind = AutoplayFeedbackKind.listened,
  double reward = 1,
  double weight = 1,
}) => AutoplayFeedback(
  kind: kind,
  track: AutoplayLearningTrack(source: source, title: source, artist: 'A'),
  previous: null,
  at: _start,
  reward: reward,
  weight: weight,
);

Future<Database> _database() async {
  sqfliteFfiInit();
  final directory = await Directory.systemTemp.createTemp('autoplay-ranker-');
  addTearDown(() => directory.delete(recursive: true));
  final db = await AutoplayRanker.openWithFactory(
    databaseFactoryFfi,
    '${directory.path}/ranker.db',
  );
  addTearDown(db.close);
  return db;
}

void main() {
  test('AUC counts kept songs scored above skipped ones, ties half', () {
    expect(
      autoplayRankAuc([
        _outcome(3, kept: true),
        _outcome(2, kept: true),
        _outcome(1, kept: false),
      ], const {}),
      1,
    );
    expect(
      autoplayRankAuc([
        _outcome(1, kept: true),
        _outcome(2, kept: true),
        _outcome(0, kept: false),
        _outcome(3, kept: false),
      ], const {}),
      0.5,
    );
    // A zero weight ties every song.
    expect(
      autoplayRankAuc(
        [_outcome(3, kept: true), _outcome(1, kept: false)],
        const {'x': 0},
      ),
      0.5,
    );
    expect(autoplayRankAuc([_outcome(1, kept: true)], const {}), isNull);
  });

  test('learning finds what the listener cares about', () {
    final weights = fitAutoplayRankWeights(
      _listener(const {'genre': 0, 'signal:sound': 3}),
    );
    expect(weights['signal:sound'], greaterThan(2));
    expect(weights['genre'], lessThan(0.5));
    expect(weights['fatigue'], inInclusiveRange(0.6, 1.6));
    // Weights stay within bounds.
    expect(weights.values, everyElement(inInclusiveRange(0, 3)));
  });

  test('a listener the starting weights fit keeps them about the same', () {
    final weights = fitAutoplayRankWeights(_listener(const {}));
    expect(weights.values, everyElement(inInclusiveRange(0.6, 1.4)));
  });

  test('few outcomes leave the starting weights in place', () {
    final weights = fitAutoplayRankWeights(
      _listener(const {'genre': 0, 'signal:sound': 3}, count: 6),
    );
    expect(weights.values, everyElement(inInclusiveRange(0.6, 1.6)));
  });

  test('learned weights are used only once they rank better', () {
    final few = trainAutoplayRanker(_listener(const {}, count: 39));
    expect(few.weights, isEmpty);
    expect(few.evaluation.outcomes, 39);
    expect(few.evaluation.tested, 0);

    final learned = trainAutoplayRanker(
      _listener(const {'genre': 0, 'signal:sound': 3}, count: 400),
    );
    final evaluation = learned.evaluation;
    expect(evaluation.tested, 100);
    expect(evaluation.learned! - evaluation.starting!, greaterThan(0.05));
    expect(evaluation.learnedWins, isTrue);
    expect(learned.weights['signal:sound'], greaterThan(2));

    // When learning ranks the latest songs worse, the starting weights stay.
    final outcomes = [
      ..._listener(const {'genre': 0, 'signal:sound': 3}, count: 300),
      for (final outcome in _listener(const {'genre': 3}, count: 100, seed: 9))
        AutoplayRankOutcome(
          at: outcome.at.add(const Duration(days: 1)),
          parts: outcome.parts,
          reward: outcome.reward,
        ),
    ];
    final changed = trainAutoplayRanker(outcomes);
    expect(changed.evaluation.learnedWins, isFalse);
    expect(changed.weights, isEmpty);
  });

  test('the first verdict on a remembered pick becomes an outcome', () async {
    final db = await _database();
    final trainings = <int>[];
    final ranker = AutoplayRanker(
      open: () async => db,
      train: (outcomes) async {
        trainings.add(outcomes.length);
        return (
          weights: {'genre': 0.5},
          evaluation: AutoplayRankEvaluation(outcomes: outcomes.length),
        );
      },
    );
    addTearDown(ranker.dispose);
    ranker.remember('/a.flac', {'genre': 4, 'fatigue': -2});
    ranker.record(_feedback('/a.flac', reward: 0, weight: 1.5));
    // Later feedback on it, and on songs autoplay did not pick, says nothing.
    ranker.record(_feedback('/a.flac', kind: AutoplayFeedbackKind.loved));
    ranker.record(_feedback('/manual.flac'));
    final outcomes = await ranker.readOutcomes();
    expect(outcomes, hasLength(1));
    expect(outcomes.single.parts, {'genre': 4, 'fatigue': -2});
    expect(outcomes.single.reward, 0);
    expect(outcomes.single.weight, 1.5);

    for (var i = 0; i < 10; i++) {
      ranker.remember('/$i.flac', {'genre': i.toDouble()});
      ranker.record(_feedback('/$i.flac'));
    }
    await ranker.train();
    expect(trainings.last, 11);
    expect(ranker.weights, {'genre': 0.5});
    expect(ranker.evaluation.value?.outcomes, 11);

    // Another launch reads what was saved.
    final reopened = AutoplayRanker(
      open: () async => db,
      train: (outcomes) async => trainAutoplayRanker(outcomes),
    );
    addTearDown(reopened.dispose);
    expect(await reopened.readOutcomes(), hasLength(11));

    await ranker.reset();
    expect(ranker.weights, isEmpty);
    expect(ranker.evaluation.value?.outcomes, 0);
    expect(await ranker.readOutcomes(), isEmpty);
  });
}
