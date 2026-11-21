import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/automix_options.dart';
import 'package:mornye/services/automix_analysis.dart';
import 'package:mornye/services/automix_analyzer.dart';

class WindowAnalyzer extends AutoMixAnalyzer {
  final calls = <double>[];
  final windows = <double, AutoMixBeatGrid?>{};
  Completer<AutoMixBeatGrid?>? pending;
  double pendingOffset = 6;

  @override
  Future<AutoMixBeatGrid?> analyze(String path, {double offset = 0}) async {
    calls.add(offset);
    if (offset == pendingOffset && pending != null) return pending!.future;
    return windows[offset];
  }
}

AutoMixBeatGrid grid(
  double confidence, {
  double bpm = 120,
  double phase = 0.17,
}) => AutoMixBeatGrid(
  bpm: bpm,
  phase: phase,
  confidence: confidence,
  firstSound: 0.1,
);

void main() {
  test(
    'nearby evidence recovers the grid without skipping the original intro',
    () async {
      final analyzer = WindowAnalyzer()
        ..windows.addAll({0: grid(0.35), 6: grid(0.9)});
      final result = await analyzer.analyzeTransition('track');
      expect(result!.reliable, isTrue);
      expect(result.beatAtOrAfter(result.firstSound), closeTo(0.17, 0.00001));
      expect(result.firstSound, 0.1);
      expect(analyzer.calls, [0, 6]);
      analyzer.dispose();
    },
  );

  test(
    'outro recovery looks backward and retains the requested timeline',
    () async {
      final analyzer = WindowAnalyzer()
        ..windows.addAll({156: grid(0.4), 150: grid(0.9)});
      final result = await analyzer.analyzeTransition('track', offset: 156);
      expect(result!.reliable, isTrue);
      expect(result.beatAtOrAfter(0), closeTo(0.17, 0.00001));
      expect(analyzer.calls, [156, 150]);
      analyzer.dispose();
    },
  );

  test('the matching level sets how sure the nearby window must be', () async {
    for (final (matching, recovers) in [
      (AutoMixMatching.standard, false),
      (AutoMixMatching.more, true),
      (AutoMixMatching.most, true),
    ]) {
      final original = grid(0.35);
      final analyzer = WindowAnalyzer()
        ..windows.addAll({0: original, 6: grid(0.45), 12: grid(0.45)});
      final result = await analyzer.analyzeTransition(
        'track',
        matching: matching,
      );
      expect(result!.reliableFor(matching), recovers, reason: matching.name);
      expect(result.confirmed, recovers);
      // Alone, neither window is sure enough.
      expect(result.reliable, isFalse);
      if (!recovers) expect(result, same(original));
      analyzer.dispose();
    }
  });

  test(
    'different tempo or phase cannot lend confidence to the transition',
    () async {
      for (final candidate in [
        grid(0.9, bpm: 124),
        grid(0.9, phase: 0.32),
        grid(0.9, bpm: 120.5),
      ]) {
        final original = grid(0.35);
        final analyzer = WindowAnalyzer()
          ..windows.addAll({0: original, 6: candidate, 12: candidate});
        expect(await analyzer.analyzeTransition('track'), same(original));
        expect(analyzer.calls, [0, 6, 12]);
        analyzer.dispose();
      }
    },
  );

  test(
    'reliable, missing and unstructured windows do not trigger extra decoding',
    () async {
      for (final initial in [grid(0.9), grid(0.1), null]) {
        final analyzer = WindowAnalyzer()..windows[0] = initial;
        expect(await analyzer.analyzeTransition('track'), same(initial));
        expect(analyzer.calls, [0]);
        analyzer.dispose();
      }
    },
  );

  test('short outros do not decode the same nearby window twice', () async {
    final original = grid(0.35);
    final analyzer = WindowAnalyzer()
      ..windows.addAll({4: original, 0: original});
    expect(
      await analyzer.analyzeTransition('track', offset: 4),
      same(original),
    );
    expect(analyzer.calls, [4, 0]);
    analyzer.dispose();
  });

  test('cancelling the first pass cannot publish its completed grid', () async {
    final analyzer = WindowAnalyzer()
      ..pendingOffset = 0
      ..pending = Completer<AutoMixBeatGrid?>();
    final result = analyzer.analyzeTransition('track');
    analyzer.cancel();
    analyzer.pending!.complete(grid(0.9));
    expect(await result, isNull);
    expect(analyzer.calls, [0]);
    analyzer.dispose();
  });

  test('cancelling a nearby pass cannot publish its completed grid', () async {
    final analyzer = WindowAnalyzer()
      ..windows[0] = grid(0.35)
      ..pending = Completer<AutoMixBeatGrid?>();
    final result = analyzer.analyzeTransition('track');
    await Future<void>.delayed(Duration.zero);
    expect(analyzer.calls, [0, 6]);
    analyzer.cancel();
    analyzer.pending!.complete(grid(0.9));
    expect(await result, isNull);
    analyzer.dispose();
  });
}
