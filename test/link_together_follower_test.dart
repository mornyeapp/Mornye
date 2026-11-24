// ignore: depend_on_referenced_packages
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/link/together/link_together_follower.dart';
import 'package:mornye/services/link/together/link_together_protocol.dart';

import 'support/link_together_fakes.dart';

void main() {
  final songs = [simSong('One'), simSong('Two'), simSong('Three')];
  const minutes = [240000, 240000, 240000];

  ({SimDeck deck, LinkTogetherFollower follower, int Function() now}) setUp(
    FakeAsync async, {
    int playLatencyMs = 0,
    int loadMs = 100,
    bool nudges = true,
  }) {
    int trueNow() => 1000000 + async.elapsed.inMilliseconds;
    final deck = SimDeck(
      trueNowMs: trueNow,
      queue: songs,
      durations: minutes,
      clockOffsetMs: 777,
      playLatencyMs: playLatencyMs,
      loadMs: loadMs,
      nudges: nudges,
    );
    return (
      deck: deck,
      follower: LinkTogetherFollower(deck: deck, nowMs: deck.nowMs),
      now: deck.nowMs,
    );
  }

  test('starts a song it holds at the agreed instant and position', () {
    fakeAsync((async) {
      final (:deck, :follower, :now) = setUp(async);
      final cue = LinkTogetherCue(
        track: songs[1],
        positionMs: 10000,
        atMs: now(),
        playing: true,
      );
      bool? found;
      follower.rejoin(cue).then((value) => found = value);
      async.elapse(const Duration(milliseconds: 300));
      expect(follower.busy, isTrue);
      expect(deck.playing, isFalse);
      async.elapse(const Duration(seconds: 2));

      expect(found, isTrue);
      expect(follower.busy, isFalse);
      expect(deck.index, 1);
      expect(deck.playing, isTrue);
      expect(deck.truePosition, closeTo(cue.positionAt(now()), 1));
    });
  });

  test('starts early by the lead, so a slow player sounds on time', () {
    fakeAsync((async) {
      final (:deck, :follower, :now) = setUp(async, playLatencyMs: 60);
      final cue = LinkTogetherCue(
        track: songs[0],
        positionMs: 30000,
        atMs: now(),
        playing: true,
        leadMs: 60,
      );
      follower.rejoin(cue);
      async.elapse(const Duration(seconds: 2));

      expect(deck.playing, isTrue);
      expect(deck.truePosition, closeTo(cue.positionAt(now()), 1));
    });
  });

  test('a follower ahead waits for the leader instead of jumping back', () {
    fakeAsync((async) {
      final (:deck, :follower, :now) = setUp(async);
      deck.playNow(position: 20500);
      final cue = LinkTogetherCue(
        track: songs[0],
        positionMs: 20000,
        atMs: now(),
        playing: true,
      );
      follower.rejoin(cue);
      async.elapse(const Duration(milliseconds: 100));
      expect(deck.playing, isFalse);
      async.elapse(const Duration(seconds: 2));

      expect(deck.playing, isTrue);
      expect(deck.seeks, 0);
      expect(deck.truePosition, closeTo(cue.positionAt(now()), 1));
    });
  });

  test('a follower behind seeks ahead of the leader and starts there', () {
    fakeAsync((async) {
      final (:deck, :follower, :now) = setUp(async);
      deck.playNow(position: 15000);
      final cue = LinkTogetherCue(
        track: songs[0],
        positionMs: 20000,
        atMs: now(),
        playing: true,
      );
      follower.rejoin(cue);
      async.elapse(const Duration(seconds: 1));

      expect(deck.playing, isTrue);
      expect(deck.seeks, 1);
      expect(deck.truePosition, closeTo(cue.positionAt(now()), 1));
    });
  });

  test('a song missing from its queue leaves it silent and paused', () {
    fakeAsync((async) {
      final (:deck, :follower, :now) = setUp(async);
      deck.playNow(position: 1000);
      bool? found;
      follower
          .rejoin(
            LinkTogetherCue(
              track: simSong('Elsewhere'),
              positionMs: 0,
              atMs: now(),
              playing: true,
            ),
          )
          .then((value) => found = value);
      async.flushMicrotasks();

      expect(found, isFalse);
      expect(follower.silent, isTrue);
      expect(deck.playing, isFalse);

      // The next song it holds brings it back.
      follower.rejoin(
        LinkTogetherCue(
          track: songs[2],
          positionMs: 0,
          atMs: now(),
          playing: true,
        ),
      );
      async.elapse(const Duration(seconds: 1));
      expect(follower.silent, isFalse);
      expect(deck.index, 2);
      expect(deck.playing, isTrue);
    });
  });

  test('a paused cue loads the song paused at its position', () {
    fakeAsync((async) {
      final (:deck, :follower, :now) = setUp(async);
      deck.playNow(position: 1000);
      follower.rejoin(
        LinkTogetherCue(
          track: songs[1],
          positionMs: 42000,
          atMs: now(),
          playing: false,
        ),
      );
      async.elapse(const Duration(milliseconds: 500));

      expect(deck.index, 1);
      expect(deck.playing, isFalse);
      expect(deck.truePosition, 42000);
    });
  });

  test('a load slower than its margin starts later, still in step', () {
    fakeAsync((async) {
      final (:deck, :follower, :now) = setUp(async, loadMs: 900);
      final cue = LinkTogetherCue(
        track: songs[1],
        positionMs: 5000,
        atMs: now(),
        playing: true,
      );
      follower.rejoin(cue);
      async.elapse(const Duration(seconds: 3));

      expect(deck.playing, isTrue);
      expect(deck.seeks, 1);
      expect(deck.truePosition, closeTo(cue.positionAt(now()), 1));
    });
  });

  test('a newer cue replaces one still waiting', () {
    fakeAsync((async) {
      final (:deck, :follower, :now) = setUp(async);
      follower.rejoin(
        LinkTogetherCue(
          track: songs[0],
          positionMs: 1000,
          atMs: now(),
          playing: true,
        ),
      );
      async.elapse(const Duration(milliseconds: 50));
      final newer = LinkTogetherCue(
        track: songs[2],
        positionMs: 9000,
        atMs: now(),
        playing: true,
      );
      follower.rejoin(newer);
      async.elapse(const Duration(seconds: 2));

      expect(deck.index, 2);
      expect(deck.truePosition, closeTo(newer.positionAt(now()), 1));
    });
  });

  test('nudges the rate for a while, where the player can', () {
    fakeAsync((async) {
      final (:deck, :follower, now: _) = setUp(async);
      deck.playNow();
      follower.nudge(1.02, 1000);
      expect(deck.rate, 1.02);
      async.elapse(const Duration(milliseconds: 1001));
      expect(deck.rate, 1);

      final fixed = setUp(async, nudges: false);
      fixed.follower.nudge(0.98, 1000);
      expect(fixed.deck.rates, isEmpty);
    });
  });

  test('a nudge at the rate in force only moves its end', () {
    fakeAsync((async) {
      final (:deck, :follower, now: _) = setUp(async);
      deck.playNow();
      follower.nudge(1.02, 1000);
      async.elapse(const Duration(milliseconds: 800));
      // Longer, at the same rate: no change on the way, which some engines
      // pay for with lost time.
      follower.nudge(1.02, 1000);
      async.elapse(const Duration(milliseconds: 900));
      expect(deck.rates, [1.02]);
      async.elapse(const Duration(milliseconds: 101));
      expect(deck.rates, [1.02, 1]);

      // From one nudge rate to the other directly, and 1 ends it.
      follower.nudge(1.02, 1000);
      follower.nudge(0.98, 1000);
      follower.nudge(1, 0);
      expect(deck.rates, [1.02, 1, 1.02, 0.98, 1]);
      async.elapse(const Duration(seconds: 2));
      expect(deck.rates, [1.02, 1, 1.02, 0.98, 1]);
    });
  });

  test('a session that ends while it waits starts the player at once', () {
    fakeAsync((async) {
      final (:deck, :follower, :now) = setUp(async);
      follower.rejoin(
        LinkTogetherCue(
          track: songs[0],
          positionMs: 1000,
          atMs: now(),
          playing: true,
        ),
      );
      async.elapse(const Duration(milliseconds: 100));
      expect(deck.playing, isFalse);
      follower.cancel(resume: true);
      async.flushMicrotasks();
      expect(deck.playing, isTrue);
      async.elapse(const Duration(seconds: 1));
      expect(follower.busy, isFalse);
    });
  });
}
