import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/link/together/link_together_aligner.dart';

void main() {
  group('LinkTogetherAligner', () {
    test('leaves small errors alone', () {
      final aligner = LinkTogetherAligner();
      for (var i = 0; i < 10; i++) {
        expect(
          aligner.sample(i.isEven ? 30 : -30, i * 1000, canNudge: true),
          isA<LinkTogetherWait>(),
        );
      }
    });

    test('nudges after two samples in a row, against the error', () {
      final aligner = LinkTogetherAligner();
      expect(aligner.sample(50, 0, canNudge: true), isA<LinkTogetherWait>());
      final ahead = aligner.sample(50, 1000, canNudge: true);
      expect(ahead, isA<LinkTogetherNudge>());
      ahead as LinkTogetherNudge;
      // 2 % slower closes 50 ms in 2.5 s.
      expect(ahead.factor, closeTo(0.98, 1e-9));
      expect(ahead.durationMs, 2500);
      expect(aligner.nudging(2000), isTrue);

      final behind = LinkTogetherAligner()..sample(-60, 0, canNudge: true);
      final step = behind.sample(-60, 1000, canNudge: true);
      expect((step as LinkTogetherNudge).factor, closeTo(1.02, 1e-9));
      expect(step.durationMs, 3000);
    });

    test('one sample over the line does not nudge', () {
      final aligner = LinkTogetherAligner();
      expect(aligner.sample(50, 0, canNudge: true), isA<LinkTogetherWait>());
      expect(aligner.sample(10, 1000, canNudge: true), isA<LinkTogetherWait>());
      expect(aligner.sample(50, 2000, canNudge: true), isA<LinkTogetherWait>());
    });

    test('a nudge on course runs its planned length', () {
      final aligner = LinkTogetherAligner()
        ..sample(100, 0, canNudge: true)
        ..sample(100, 1000, canNudge: true);
      // Just after the rate change the report does not show it yet.
      expect(aligner.settling(1500), isTrue);
      expect(aligner.sample(0, 1500, canNudge: true), isA<LinkTogetherWait>());
      // In step at 15 ms, but the plan ends at 0: no stop half way.
      expect(aligner.sample(80, 2000, canNudge: true), isA<LinkTogetherWait>());
      expect(aligner.sample(15, 5250, canNudge: true), isA<LinkTogetherWait>());
      expect(aligner.nudging(5900), isTrue);
      expect(aligner.nudging(6000), isFalse);
    });

    test('a nudge that would end out of step is replanned once', () {
      // Entering the rate cost 30 ms: 2 % for 5 s would end 60 ms behind
      // (leaving costs about as much), so the nudge ends 1 s after the check.
      final aligner = LinkTogetherAligner()
        ..sample(100, 0, canNudge: true)
        ..sample(100, 1000, canNudge: true);
      final shorter = aligner.sample(50, 2000, canNudge: true);
      expect((shorter as LinkTogetherNudge).factor, closeTo(0.98, 1e-9));
      expect(shorter.durationMs, 1000);
      expect(aligner.sample(0, 2500, canNudge: true), isA<LinkTogetherWait>());
      expect(aligner.sample(0, 3500, canNudge: true), isA<LinkTogetherWait>());
      expect(aligner.takeLanding(), isNull);
      expect(
        aligner.sample(-10, 4000, canNudge: true),
        isA<LinkTogetherWait>(),
      );
      final landing = aligner.takeLanding()!;
      expect(landing.beforeMs, 100);
      expect(landing.expectedMs, 0);
      expect(landing.measuredMs, -10);
      expect(landing.costMs, -70);
      expect(landing.countedCostMs, -70);
      expect(landing.holding, isFalse);
      expect(aligner.takeLanding(), isNull);

      // Already past the leader: the nudge ends at once.
      final overshoot = LinkTogetherAligner()
        ..sample(100, 0, canNudge: true)
        ..sample(100, 1000, canNudge: true);
      final stop = overshoot.sample(-30, 2000, canNudge: true);
      expect((stop as LinkTogetherNudge).factor, 1);
      expect(overshoot.nudging(2000), isFalse);
    });

    test('counts what rate changes cost and plans the next nudge with it', () {
      // The real run: each nudge pair lost about 48 ms, so a 2.45 s nudge
      // for -49 ms ended at -48 ms again, every 4 s.
      final aligner = _withCost(-48);
      expect(aligner.countedCostMs, -48);
      final step = aligner.sample(-49, 8000, canNudge: true);
      expect((step as LinkTogetherNudge).factor, closeTo(1.02, 1e-9));
      expect(step.durationMs, 4850);
      // Entering cost 26 ms, which the plan expected: no replanning.
      expect(
        aligner.sample(-55, 9000, canNudge: true),
        isA<LinkTogetherWait>(),
      );
      expect(
        aligner.sample(-1, 13850, canNudge: true),
        isA<LinkTogetherWait>(),
      );
      final landing = aligner.takeLanding()!;
      expect(landing.expectedMs, 0);
      expect(landing.measuredMs, -1);
      expect(landing.costMs, -49);
      expect(aligner.holding, isFalse);
    });

    test('where rate changes cost more than 20 ms, a short nudge waits for '
        'an error that stays out of step', () {
      final aligner = _withCost(-45);
      var now = 8000;
      for (var i = 0; i < 6; i++) {
        expect(
          aligner.sample(17, now += 1000, canNudge: true),
          isA<LinkTogetherWait>(),
        );
      }
      LinkTogetherStep step = const LinkTogetherWait();
      for (var i = 0; i < 5 && step is LinkTogetherWait; i++) {
        step = aligner.sample(25, now += 1000, canNudge: true);
      }
      // Ahead, yet faster: slowing down would lose the changes' 45 ms too.
      expect((step as LinkTogetherNudge).factor, closeTo(1.02, 1e-9));
    });

    test('holds when planned nudges keep missing, until 80 ms', () {
      final aligner = _withCost(-48);
      // Planned for -48 ms, the changes moved it +10 ms: a miss.
      aligner.sample(-49, 8000, canNudge: true);
      aligner.sample(58, 13850, canNudge: true);
      expect(aligner.takeLanding()!.holding, isFalse);
      final second = aligner.sample(58, 14850, canNudge: true);
      expect((second as LinkTogetherNudge).factor, closeTo(0.98, 1e-9));
      expect(second.durationMs, 1950);
      // Then -60 ms: a second miss.
      aligner.sample(-41, 17800, canNudge: true);
      expect(aligner.takeLanding()!.holding, isTrue);
      expect(aligner.holding, isTrue);
      var now = 17800;
      for (final error in [-41, -60, -79, -79, -50, -79, -20, -79]) {
        expect(
          aligner.sample(error, now += 1000, canNudge: true),
          isA<LinkTogetherWait>(),
        );
      }
      aligner.sample(-90, now += 1000, canNudge: true);
      expect(
        aligner.sample(-90, now += 1000, canNudge: true),
        isA<LinkTogetherNudge>(),
      );
    });

    test('a small error that stays is closed by a short nudge', () {
      final aligner = LinkTogetherAligner();
      for (var i = 0; i < 4; i++) {
        expect(
          aligner.sample([15, 19, 13, 17][i], i * 1000, canNudge: true),
          isA<LinkTogetherWait>(),
        );
      }
      final step = aligner.sample(21, 4000, canNudge: true);
      // Five samples averaging 17 ms: 850 ms at 2 % slower.
      expect((step as LinkTogetherNudge).factor, closeTo(0.98, 1e-9));
      expect(step.durationMs, 850);

      // Noise around zero averages out.
      final calm = LinkTogetherAligner();
      for (var i = 0; i < 10; i++) {
        expect(
          calm.sample(i.isEven ? 15 : -12, i * 1000, canNudge: true),
          isA<LinkTogetherWait>(),
        );
      }
    });

    test('nudges are capped at fifteen seconds', () {
      final aligner = _withCost(-100);
      final step = aligner.sample(-245, 8000, canNudge: true);
      expect((step as LinkTogetherNudge).durationMs, 15000);
    });

    test('rejoins beyond 250 ms on two samples, beyond 1.5 s at once', () {
      final aligner = LinkTogetherAligner();
      expect(aligner.sample(400, 0, canNudge: true), isA<LinkTogetherWait>());
      expect(
        aligner.sample(400, 1000, canNudge: true),
        isA<LinkTogetherRejoin>(),
      );
      expect(
        LinkTogetherAligner().sample(-2000, 0, canNudge: true),
        isA<LinkTogetherRejoin>(),
      );
    });

    test('without rate changes, rejoins beyond 80 ms on three samples', () {
      final aligner = LinkTogetherAligner();
      expect(aligner.sample(90, 0, canNudge: false), isA<LinkTogetherWait>());
      expect(
        aligner.sample(90, 1000, canNudge: false),
        isA<LinkTogetherWait>(),
      );
      expect(
        aligner.sample(90, 2000, canNudge: false),
        isA<LinkTogetherRejoin>(),
      );
      // Under 80 ms it never nudges or rejoins.
      final calm = LinkTogetherAligner();
      for (var i = 0; i < 10; i++) {
        expect(
          calm.sample(70, i * 1000, canNudge: false),
          isA<LinkTogetherWait>(),
        );
      }
    });

    test(
      'waits for a rejoin to settle, then backs off when it keeps failing',
      () {
        final aligner = LinkTogetherAligner();
        aligner.rejoined(0);
        // Settling: nothing counts.
        expect(
          aligner.sample(5000, 500, canNudge: true),
          isA<LinkTogetherWait>(),
        );
        expect(
          aligner.sample(5000, 2000, canNudge: true),
          isA<LinkTogetherRejoin>(),
        );
        aligner.rejoined(2000);
        // The next one waits 4 s after the last.
        expect(
          aligner.sample(5000, 3500, canNudge: true),
          isA<LinkTogetherWait>(),
        );
        expect(
          aligner.sample(5000, 5000, canNudge: true),
          isA<LinkTogetherWait>(),
        );
        expect(
          aligner.sample(5000, 6000, canNudge: true),
          isA<LinkTogetherRejoin>(),
        );
        aligner.rejoined(6000);
        expect(
          aligner.sample(5000, 13000, canNudge: true),
          isA<LinkTogetherWait>(),
        );
        expect(
          aligner.sample(5000, 14000, canNudge: true),
          isA<LinkTogetherRejoin>(),
        );
        aligner.rejoined(14000);
        // In step again: the gap is back to 2 s.
        aligner.sample(0, 16000, canNudge: true);
        expect(
          aligner.sample(5000, 17000, canNudge: true),
          isA<LinkTogetherRejoin>(),
        );
      },
    );

    test('a change of the leader restarts the settling time', () {
      final aligner = LinkTogetherAligner()..restart(10000);
      expect(
        aligner.sample(5000, 10500, canNudge: true),
        isA<LinkTogetherWait>(),
      );
      expect(
        aligner.sample(5000, 11300, canNudge: true),
        isA<LinkTogetherRejoin>(),
      );
    });

    test('learns how late the follower sounds after a rejoin, in one step', () {
      // The real run: lead 0 settled 221 ms behind, and the next cue's lead
      // of 133 ms still settled 107 ms behind.
      final aligner = LinkTogetherAligner()..rejoined(0);
      expect(aligner.settling(1000), isTrue);
      // Two settled samples that agree are trusted, the first alone is not.
      expect(
        aligner.sample(-230, 1500, canNudge: true),
        isA<LinkTogetherWait>(),
      );
      expect(aligner.leadMs, 0);
      aligner.sample(-226, 2500, canNudge: true);
      expect(aligner.leadMs, 228);

      // The next cue starts that early and settles in step; the lead stays.
      aligner.rejoined(5000);
      aligner
        ..sample(-2, 6500, canNudge: true)
        ..sample(3, 7500, canNudge: true);
      expect(aligner.leadMs, inInclusiveRange(227, 228));

      // Samples that do not agree yet are waited for.
      final unsure = LinkTogetherAligner()..rejoined(0);
      for (final (i, error) in [-30, 0, -28].indexed) {
        unsure.sample(error, 1500 + i * 1000, canNudge: true);
        expect(unsure.leadMs, 0);
      }
      unsure.sample(-26, 4500, canNudge: true);
      expect(unsure.leadMs, 27);

      // A nudge that starts first ends the learning with what came before.
      final nudged = LinkTogetherAligner()..rejoined(0);
      nudged.sample(-100, 1500, canNudge: true);
      final step = nudged.sample(-200, 2500, canNudge: true);
      expect(step, isA<LinkTogetherNudge>());
      expect(nudged.leadMs, 150);
    });

    test('a lead stays within 600 ms, either way', () {
      LinkTogetherAligner learn(int lead, int settled) {
        final aligner = LinkTogetherAligner()
          ..leadMs = lead
          ..rejoined(0)
          ..sample(settled, 1500, canNudge: true)
          ..sample(settled, 2500, canNudge: true);
        return aligner;
      }

      // Ahead after a rejoin: the leader was the slower one to sound, so the
      // follower starts late.
      expect(learn(0, 200).leadMs, -200);
      expect(learn(590, -200).leadMs, 600);
      expect(learn(-590, 200).leadMs, -600);
      // Far off is another problem (a wrong song or place), not a start.
      expect(learn(0, 900).leadMs, 0);
    });
  });
}

/// An aligner whose one nudge so far, planned without a cost, ended
/// [costMs] away from where the rate alone took it, read at 7 s.
LinkTogetherAligner _withCost(int costMs) {
  final aligner = LinkTogetherAligner()
    ..sample(100, 0, canNudge: true)
    ..sample(100, 1000, canNudge: true)
    ..sample(costMs, 7000, canNudge: true);
  aligner.takeLanding();
  return aligner;
}
