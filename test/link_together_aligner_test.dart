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

    test('a nudge stops once in step or past the leader', () {
      final aligner = LinkTogetherAligner()
        ..sample(100, 0, canNudge: true)
        ..sample(100, 1000, canNudge: true);
      expect(aligner.sample(60, 2000, canNudge: true), isA<LinkTogetherWait>());
      final stop = aligner.sample(15, 3000, canNudge: true);
      expect((stop as LinkTogetherNudge).factor, 1);
      expect(aligner.nudging(3500), isFalse);

      final overshoot = LinkTogetherAligner()
        ..sample(100, 0, canNudge: true)
        ..sample(100, 1000, canNudge: true);
      final flipped = overshoot.sample(-25, 2000, canNudge: true);
      expect((flipped as LinkTogetherNudge).factor, 1);
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

    test('nudges are capped at ten seconds', () {
      final aligner = LinkTogetherAligner()..sample(240, 0, canNudge: true);
      final step = aligner.sample(240, 1000, canNudge: true);
      expect((step as LinkTogetherNudge).durationMs, 10000);
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

    test('learns how late the follower sounds after a rejoin', () {
      // The follower always sounds 60 ms after it is told to start.
      final aligner = LinkTogetherAligner();
      var now = 0;
      for (var i = 0; i < 8; i++) {
        aligner.rejoined(now);
        now += 2000;
        aligner.sample(aligner.leadMs - 60, now, canNudge: true);
        now += 1000;
      }
      expect(aligner.leadMs, inInclusiveRange(58, 62));

      // Ahead after a rejoin: the leader was the slower one to sound, so the
      // follower starts late, by 400 ms at most either way.
      final bounded = LinkTogetherAligner();
      bounded.rejoined(0);
      bounded.sample(200, 2000, canNudge: true);
      expect(bounded.leadMs, -120);
      bounded.leadMs = 390;
      bounded.rejoined(3000);
      bounded.sample(-200, 5000, canNudge: true);
      expect(bounded.leadMs, 400);
      bounded.leadMs = -390;
      bounded.rejoined(6000);
      bounded.sample(200, 8000, canNudge: true);
      expect(bounded.leadMs, -400);
    });
  });
}
