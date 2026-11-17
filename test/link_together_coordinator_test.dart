import 'dart:async';
import 'dart:math';

// ignore: depend_on_referenced_packages
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/link/link_host_router.dart';
import 'package:mornye/services/link/link_protocol.dart';
import 'package:mornye/services/link/together/link_together_coordinator.dart';
import 'package:mornye/services/link/together/link_together_host.dart';
import 'package:mornye/services/link/together/link_together_protocol.dart';

import 'support/link_fakes.dart';
import 'support/link_together_fakes.dart';

/// The phone's Link session over a simulated network: every request and
/// push takes 2 to 25 ms each way, picked at random, so the two directions
/// differ. Requests reach a real [LinkTogetherHost] behind a router.
class _Wire extends FakeLinkClient {
  _Wire(this.router, this.random);

  final LinkHostRouter router;
  final Random random;

  /// The network is gone: requests fail after their first hop.
  bool down = false;

  Duration hop() => Duration(milliseconds: 2 + random.nextInt(24));

  Future<Object?> _request(String op, Map<String, dynamic> args) async {
    await Future<void>.delayed(hop());
    if (down) throw const LinkException('unavailable', 'Gone');
    final reply = await router.dispatch(
      LinkRequest(requestId: 'r', op: op, deviceId: 'phone-1', args: args),
    );
    await Future<void>.delayed(hop());
    if (down) throw const LinkException('unavailable', 'Gone');
    return reply;
  }

  @override
  Future<Object?> get(String op, [Map<String, String> query = const {}]) {
    gets.add(op);
    return _request(op, {...query, '_method': 'GET'});
  }

  @override
  Future<Object?> post(String op, Map<String, dynamic> body) {
    posts.add((op: op, body: body));
    return _request(op, body);
  }
}

const _session = 'session-1';

/// A phone and a computer with clocks 3.456 s apart, the computer's audio
/// 150 ppm fast, start delays of 60 ms (phone) and 20 ms (computer), and
/// position reports off by up to 5 ms.
///
/// [engineReadMs], [desktopLatencyMs] and the rate costs model what a real
/// run measured (see [_measured]); [seed] varies the noise.
class _Sim {
  _Sim(
    this.async, {
    required this.phoneLeads,
    List<TrackRef>? songs,
    List<int>? durations,
    List<TrackRef>? followerSongs,
    List<int>? followerDurations,
    double desktopPpm = 150,
    bool followerNudges = true,
    int desktopLatencyMs = 20,
    int phoneLatencyMs = 60,
    int engineReadMs = 0,
    int endedReadMs = 0,
    SimRateCost? desktopRateCost,
    SimRateCost? phoneRateCost,
    int seed = 0,
  }) {
    final queue = songs ?? [simSong('One'), simSong('Two'), simSong('Three')];
    final lengths = durations ?? [900000, 900000, 900000];
    phone = SimDeck(
      trueNowMs: trueNow,
      queue: queue,
      durations: lengths,
      playLatencyMs: phoneLatencyMs,
      loadMs: 150,
      jitterMs: 5,
      nudges: followerNudges || phoneLeads,
      engineReadMs: engineReadMs,
      endedReadMs: endedReadMs,
      rateCost: phoneRateCost,
      random: Random(2 + seed * 10),
    );
    desktop = SimDeck(
      trueNowMs: trueNow,
      queue: queue,
      durations: lengths,
      clockOffsetMs: 3456,
      audioPpm: desktopPpm,
      playLatencyMs: desktopLatencyMs,
      loadMs: 80,
      jitterMs: 5,
      nudges: followerNudges || !phoneLeads,
      engineReadMs: engineReadMs,
      endedReadMs: endedReadMs,
      rateCost: desktopRateCost,
      random: Random(3 + seed * 10),
    );
    _followerSongs = followerSongs ?? queue;
    _followerDurations = followerDurations ?? lengths;
    final router = LinkHostRouter();
    wire = _Wire(router, Random(4 + seed * 10));
    host = LinkTogetherHost(
      deck: desktop,
      nowMs: desktop.nowMs,
      send: (message, deviceId) async {
        await Future<void>.delayed(wire.hop());
        wire.push(message);
        return 1;
      },
    )..register(router);
  }

  final FakeAsync async;
  final bool phoneLeads;
  late final SimDeck phone;
  late final SimDeck desktop;
  late final _Wire wire;
  late final LinkTogetherHost host;
  late final LinkTogetherCoordinator coordinator;
  late final List<TrackRef> _followerSongs;
  late final List<int> _followerDurations;
  int shiftMs = 0;
  final ended = <LinkTogetherEnd>[];
  final missing = <TrackRef>[];
  final errors = <({int atMs, double errorMs})>[];
  Timer? _trace;

  static const _epochMs = 5000000;

  int trueNow() => _epochMs + async.elapsed.inMilliseconds;

  SimDeck get leader => phoneLeads ? phone : desktop;
  SimDeck get follower => phoneLeads ? desktop : phone;

  /// Starts as the phone's controller does, once the leader plays.
  void start() {
    unawaited(_start());
    async.elapse(const Duration(seconds: 1));
    _trace = Timer.periodic(const Duration(milliseconds: 100), (_) {
      final error = trueErrorMs();
      if (error != null) {
        errors.add((atMs: async.elapsed.inMilliseconds, errorMs: error));
      }
    });
  }

  Future<void> _start() async {
    final peer = LinkClientTogetherPeer(wire, _session);
    final clock = LinkTogetherCoordinator.linkTogetherClock();
    await linkTogetherMeasureClock(peer, clock, nowMs: phone.nowMs);
    // The handoff loads the leader's queue on the follower, paused.
    follower.load(
      _followerSongs,
      _followerDurations,
      index: _followerSongs.indexOf(leader.refAt(leader.index)!),
      position: leader.truePosition.round(),
    );
    final reply = LinkTogetherReport.fromJson(
      await wire.post(LinkTogetherOps.start, {
        'session': _session,
        'role':
            (phoneLeads ? LinkTogetherRole.follower : LinkTogetherRole.leader)
                .name,
      }),
    );
    phone.begin(follower: !phoneLeads);
    coordinator = LinkTogetherCoordinator(
      phoneLeads: phoneLeads,
      phone: phone,
      desktop: peer,
      clock: clock,
      nowMs: phone.nowMs,
      shiftMs: () => shiftMs,
      onEnded: ended.add,
      onMissing: (track) async {
        missing.add(track);
        return false;
      },
    )..start(reply);
    wire.messages.listen((message) {
      if (message['session'] != _session) return;
      switch (message['type']) {
        case LinkTogetherMessages.state:
          coordinator.onDesktopReport(
            LinkTogetherReport.fromJson(message['report'])!,
          );
        case LinkTogetherMessages.action:
          unawaited(coordinator.onDesktopAction(message['action'] as String));
      }
    });
  }

  /// How far the phone is from where it should be against the computer,
  /// as heard: positive while it runs ahead. Null unless both sound the
  /// same song.
  double? trueErrorMs() {
    final phoneAt = phone.truePosition;
    final desktopAt = desktop.truePosition;
    if (!phone.sounding ||
        !desktop.sounding ||
        phone.refAt(phone.index) != desktop.refAt(desktop.index)) {
      return null;
    }
    return phoneAt - (desktopAt - shiftMs);
  }

  /// The largest error heard from [fromMs] into the run until [toMs].
  double worstFrom(int fromMs, [int? toMs]) => errors
      .where(
        (sample) =>
            sample.atMs >= fromMs && (toMs == null || sample.atMs < toMs),
      )
      .fold(0, (worst, sample) => max(worst, sample.errorMs.abs()));

  /// The mean error heard from [fromMs] into the run on.
  double meanFrom(int fromMs) {
    final heard = [
      for (final sample in errors)
        if (sample.atMs >= fromMs) sample.errorMs.abs(),
    ];
    return heard.fold<double>(0, (sum, error) => sum + error) / heard.length;
  }

  /// The share of the time from [fromMs] into the run on that the error
  /// heard stays within 20 ms.
  double inStepShare(int fromMs) {
    final heard = [
      for (final sample in errors)
        if (sample.atMs >= fromMs) sample.errorMs.abs(),
    ];
    return heard.where((error) => error <= 20).length / heard.length;
  }

  /// The follower's rate changes from [fromMs] into the run on.
  int rateChangesFrom(int fromMs) =>
      follower.rateChangesAt.where((at) => at - _epochMs >= fromMs).length;

  void finish() {
    _trace?.cancel();
    coordinator.stop();
    host.dispose();
  }
}

/// A computer as a real run measured it (2026-11-17, an Android emulator
/// leading the macOS app, both release builds): its report runs ahead of
/// its sound for a moment after each start (the sound follows play by
/// about 230 ms), the app's player state reads the engine about every half
/// second, and every rate change costs what [cost] says.
_Sim _measured(
  FakeAsync async,
  SimRateCost cost, {
  bool phoneLeads = true,
  int seed = 0,
}) => _Sim(
  async,
  phoneLeads: phoneLeads,
  desktopLatencyMs: 230,
  engineReadMs: 500,
  desktopRateCost: phoneLeads ? cost : null,
  phoneRateCost: phoneLeads ? null : cost,
  seed: seed,
);

void main() {
  group('Play together in a simulated room', () {
    test('a computer that follows starts in step and stays there', () {
      fakeAsync((async) {
        final sim = _Sim(async, phoneLeads: true);
        sim.phone.playNow(position: 30000);
        sim.start();
        async.elapse(const Duration(seconds: 5));
        final rejoinsAfterStart = sim.coordinator.rejoins;
        async.elapse(const Duration(minutes: 10));

        expect(sim.desktop.playing, isTrue);
        expect(sim.desktop.beganAsFollower, isTrue);
        // 150 ppm adds 90 ms over ten minutes. Short nudges keep it within
        // 30 ms from 3 s after the start (19.6 ms measured), about 4 ms on
        // average, without another rejoin.
        expect(sim.worstFrom(3000), lessThanOrEqualTo(30));
        expect(sim.meanFrom(3000), lessThanOrEqualTo(10));
        expect(sim.coordinator.rejoins, rejoinsAfterStart);
        expect(sim.desktop.rates, contains(0.98));
        sim.finish();
      });
    });

    test('a phone that follows starts in step and stays there', () {
      fakeAsync((async) {
        final sim = _Sim(async, phoneLeads: false);
        sim.desktop.playNow(position: 30000);
        sim.start();
        async.elapse(const Duration(seconds: 6));
        final rejoinsAfterStart = sim.coordinator.rejoins;
        async.elapse(const Duration(minutes: 10));

        expect(sim.phone.playing, isTrue);
        expect(sim.phone.beganAsFollower, isTrue);
        // The phone sounds 60 ms after its first cue; a nudge closes that
        // within 5 s, and it stays within 30 ms after.
        expect(sim.worstFrom(0), lessThanOrEqualTo(80));
        expect(sim.worstFrom(6000), lessThanOrEqualTo(30));
        expect(sim.meanFrom(6000), lessThanOrEqualTo(10));
        expect(sim.coordinator.rejoins, rejoinsAfterStart);
        sim.finish();
      });
    });

    test('pause, play and a skip on the leader carry over', () {
      fakeAsync((async) {
        final sim = _Sim(async, phoneLeads: true);
        sim.phone.playNow(position: 30000);
        sim.start();
        async.elapse(const Duration(seconds: 5));

        sim.phone.pause();
        async.elapse(const Duration(seconds: 1));
        expect(sim.desktop.playing, isFalse);
        expect(sim.desktop.truePosition, closeTo(sim.phone.truePosition, 30));

        final resumed = async.elapsed.inMilliseconds;
        sim.phone.play();
        async.elapse(const Duration(seconds: 1));
        expect(sim.desktop.playing, isTrue);
        async.elapse(const Duration(seconds: 11));
        // The phone sounds 60 ms after its play and the computer 20 ms:
        // the first resume is off by about their difference, and a nudge
        // closes it.
        expect(sim.worstFrom(resumed), lessThanOrEqualTo(80));
        expect(sim.worstFrom(resumed + 7000), lessThanOrEqualTo(30));

        final skipped = async.elapsed.inMilliseconds;
        sim.phone.next();
        async.elapse(const Duration(seconds: 12));
        expect(sim.desktop.index, 1);
        expect(sim.worstFrom(skipped), lessThanOrEqualTo(80));
        expect(sim.worstFrom(skipped + 7000), lessThanOrEqualTo(30));
        sim.finish();
      });
    });

    test('both cross song ends by themselves, gapless, without a rejoin', () {
      fakeAsync((async) {
        final sim = _Sim(
          async,
          phoneLeads: true,
          songs: [
            for (final title in ['A', 'B', 'C', 'D']) simSong(title),
          ],
          durations: const [20000, 20000, 20000, 20000],
        );
        sim.phone.playNow(position: 5000);
        sim.start();
        async.elapse(const Duration(seconds: 3));
        final rejoinsAfterStart = sim.coordinator.rejoins;
        // Song ends at 15, 35 and 55 s.
        async.elapse(const Duration(seconds: 60));

        expect(sim.phone.index, 3);
        expect(sim.desktop.index, 3);
        expect(sim.coordinator.rejoins, rejoinsAfterStart);
        expect(sim.worstFrom(3000), lessThanOrEqualTo(30));
        sim.finish();
      });
    });

    // A real run (2026-11-17): the phone's player read as stopped for a
    // moment at each song end, which paused the computer for three seconds.
    for (final phoneLeads in [true, false]) {
      test('a song end that reads as stopped pauses nobody, the '
          '${phoneLeads ? 'phone' : 'computer'} leading', () {
        fakeAsync((async) {
          final sim = _Sim(
            async,
            phoneLeads: phoneLeads,
            songs: [
              for (final title in ['A', 'B', 'C', 'D']) simSong(title),
            ],
            durations: const [20000, 20000, 20000, 20000],
            endedReadMs: 60,
          );
          sim.leader.playNow(position: 5000);
          sim.start();
          // A phone that follows needs up to 6 s to get in step.
          async.elapse(const Duration(seconds: 6));
          final rejoinsAfterStart = sim.coordinator.rejoins;
          // Song ends at 15, 35 and 55 s.
          async.elapse(const Duration(seconds: 57));

          expect(sim.phone.index, 3);
          expect(sim.desktop.index, 3);
          expect(sim.coordinator.rejoins, rejoinsAfterStart);
          expect(sim.ended, isEmpty);
          expect(sim.worstFrom(6000), lessThanOrEqualTo(30));
          sim.finish();
        });
      });
    }

    test('a leader paused in the last moments of a song still pauses the '
        'follower', () {
      fakeAsync((async) {
        final sim = _Sim(
          async,
          phoneLeads: true,
          durations: const [20000, 20000, 20000],
        );
        sim.phone.playNow(position: 5000);
        sim.start();
        async.elapse(const Duration(milliseconds: 13500));
        unawaited(sim.phone.pause());
        async.elapse(const Duration(seconds: 2));

        expect(sim.desktop.playing, isFalse);
        expect(sim.desktop.index, 0);
        sim.finish();
      });
    });

    test('a song the follower lacks keeps it silent until the next one', () {
      fakeAsync((async) {
        final songs = [simSong('A'), simSong('B'), simSong('C')];
        final sim = _Sim(
          async,
          phoneLeads: true,
          songs: songs,
          durations: const [20000, 20000, 20000],
          followerSongs: [songs[0], songs[2]],
          followerDurations: const [20000, 20000],
        );
        sim.phone.playNow(position: 10000);
        sim.start();
        // Into song B, which only the phone has.
        async.elapse(const Duration(seconds: 15));
        expect(sim.phone.index, 1);
        expect(sim.desktop.playing, isFalse);
        expect(sim.missing, [songs[1]]);

        // Song C, from 30 s, brings the computer back in step.
        async.elapse(const Duration(seconds: 17));
        expect(sim.phone.index, 2);
        expect(sim.desktop.playing, isTrue);
        expect(sim.desktop.refAt(sim.desktop.index), songs[2]);
        expect(sim.trueErrorMs()!.abs(), lessThanOrEqualTo(30));
        expect(sim.missing, [songs[1]]);
        sim.finish();
      });
    });

    test('the timing adjustment plays the phone earlier or later', () {
      fakeAsync((async) {
        final sim = _Sim(async, phoneLeads: true);
        sim.phone.playNow(position: 30000);
        sim.start();
        async.elapse(const Duration(seconds: 5));

        // The phone plays 200 ms ahead of the computer, as for Bluetooth.
        sim.shiftMs = -200;
        sim.coordinator.shiftChanged();
        async.elapse(const Duration(seconds: 2));
        final shifted = async.elapsed.inMilliseconds;
        async.elapse(const Duration(seconds: 20));
        expect(
          sim.phone.truePosition - sim.desktop.truePosition,
          closeTo(200, 30),
        );
        expect(sim.worstFrom(shifted), lessThanOrEqualTo(30));
        sim.finish();
      });
    });

    test('a lost connection ends it quietly and both go on playing', () {
      fakeAsync((async) {
        final sim = _Sim(async, phoneLeads: false);
        sim.desktop.playNow(position: 30000);
        sim.start();
        async.elapse(const Duration(seconds: 5));

        sim.wire.down = true;
        async.elapse(const Duration(seconds: 4));
        sim.host.keepConnected(const {});

        expect(sim.ended, [LinkTogetherEnd.disconnected]);
        expect(sim.coordinator.ended, isTrue);
        expect(sim.phone.playing, isTrue);
        expect(sim.desktop.playing, isTrue);
        expect(sim.host.active, isFalse);
        sim.finish();
      });
    });

    test("the computer's own controls drive the phone that leads", () {
      fakeAsync((async) {
        final sim = _Sim(async, phoneLeads: true);
        sim.phone.playNow(position: 30000);
        sim.start();
        async.elapse(const Duration(seconds: 5));

        sim.desktop.pause();
        async.elapse(const Duration(milliseconds: 500));
        expect(sim.phone.playing, isFalse);
        // Changes this soon after a cue count as the cue's own.
        async.elapse(const Duration(seconds: 2));

        sim.desktop.play();
        async.elapse(const Duration(seconds: 3));
        expect(sim.phone.playing, isTrue);

        sim.desktop.next();
        async.elapse(const Duration(seconds: 3));
        expect(sim.phone.index, 1);
        expect(sim.desktop.index, 1);
        expect(sim.ended, isEmpty);

        // Another song picked there: it plays on alone.
        sim.desktop.load([simSong('Elsewhere')], const [100000]);
        sim.desktop.play();
        async.elapse(const Duration(seconds: 1));
        expect(sim.ended, [LinkTogetherEnd.leftOnDesktop]);
        expect(sim.host.active, isFalse);
        sim.finish();
      });
    });

    test("a device picked in the computer's Devices ends it, whoever owns "
        'the queue', () {
      for (final phoneLeads in [true, false]) {
        for (final keepHere in [true, false]) {
          fakeAsync((async) {
            final sim = _Sim(async, phoneLeads: phoneLeads);
            sim.leader.playNow(position: 30000);
            sim.start();
            async.elapse(const Duration(seconds: 6));
            expect(sim.ended, isEmpty);

            unawaited(sim.host.leave(keepHere: keepHere));
            async.elapse(const Duration(seconds: 1));
            final reason = 'phoneLeads $phoneLeads, keepHere $keepHere';
            expect(sim.ended, [
              keepHere
                  ? LinkTogetherEnd.leftOnDesktop
                  : LinkTogetherEnd.leftOnPhone,
            ], reason: reason);
            // The phone's controller pauses whichever device was not picked;
            // the computer ended its own side only when it plays on.
            expect(sim.host.active, !keepHere, reason: reason);
            expect(sim.desktop.playing, isTrue, reason: reason);
            expect(sim.phone.playing, isTrue, reason: reason);
            sim.finish();
          });
        }
      }
    });

    test('a song picked on the phone while it follows ends it', () {
      fakeAsync((async) {
        final sim = _Sim(async, phoneLeads: false);
        sim.desktop.playNow(position: 30000);
        sim.start();
        async.elapse(const Duration(seconds: 6));
        expect(sim.ended, isEmpty);

        sim.phone.load([simSong('Car pick')], const [200000]);
        sim.phone.play();
        async.elapse(const Duration(seconds: 2));
        expect(sim.ended, [LinkTogetherEnd.leftOnPhone]);
        expect(sim.phone.playing, isTrue);
        sim.finish();
      });
    });

    test('a follower that cannot change its rate rejoins only past 80 ms', () {
      fakeAsync((async) {
        final sim = _Sim(
          async,
          phoneLeads: true,
          desktopPpm: 400,
          followerNudges: false,
        );
        sim.phone.playNow(position: 30000);
        sim.start();
        async.elapse(const Duration(seconds: 5));
        final rejoinsAfterStart = sim.coordinator.rejoins;
        async.elapse(const Duration(minutes: 10));

        expect(sim.desktop.rates, isEmpty);
        // 400 ppm is 240 ms in ten minutes: a few rejoins, never far off.
        expect(sim.coordinator.rejoins, greaterThan(rejoinsAfterStart));
        expect(
          sim.coordinator.rejoins - rejoinsAfterStart,
          lessThanOrEqualTo(4),
        );
        expect(sim.worstFrom(3000), lessThanOrEqualTo(100));
        sim.finish();
      });
    });
  });

  group('Play together against measured players', () {
    /// Five minutes of [cost] on the follower from a start at 18 s, once
    /// for each of five noise seeds.
    void run(
      SimRateCost cost,
      void Function(_Sim sim) check, {
      bool phoneLeads = true,
    }) {
      for (var seed = 0; seed < 5; seed++) {
        fakeAsync((async) {
          final sim = _measured(
            async,
            cost,
            phoneLeads: phoneLeads,
            seed: seed,
          );
          sim.leader.playNow(position: 18000);
          sim.start();
          async.elapse(const Duration(minutes: 5));
          check(sim);
          sim.finish();
        });
      }
    }

    // The computer as the real run met it: about 24 ms lost on every rate
    // change, which the aligner used to answer with a nudge every 4 s for
    // as long as the session lasted.
    test('a computer that loses time on each rate change gets in step and '
        'stops changing its rate', () {
      run(simPlainRateCost, (sim) {
        expect(sim.coordinator.rejoins, 1);
        expect(sim.inStepShare(45000), greaterThanOrEqualTo(0.9));
        expect(sim.meanFrom(45000), lessThanOrEqualTo(12));
        // The old aligner changed the rate about 120 times here.
        expect(sim.rateChangesFrom(60000), lessThanOrEqualTo(10));
      });
    });

    test('a phone that loses time on each rate change gets in step and '
        'stops changing its rate', () {
      run(phoneLeads: false, simPlainRateCost, (sim) {
        expect(sim.coordinator.rejoins, 1);
        expect(sim.inStepShare(45000), greaterThanOrEqualTo(0.9));
        expect(sim.meanFrom(45000), lessThanOrEqualTo(12));
        expect(sim.rateChangesFrom(60000), lessThanOrEqualTo(10));
      });
    });

    test('a computer whose rate changes keep its clock stays within 20 ms', () {
      run(simPinnedRateCost, (sim) {
        expect(sim.coordinator.rejoins, 1);
        expect(sim.worstFrom(45000), lessThanOrEqualTo(20));
        expect(sim.meanFrom(45000), lessThanOrEqualTo(6));
        // 150 ppm adds 36 ms in the four minutes; short nudges take it out.
        expect(sim.rateChangesFrom(60000), lessThanOrEqualTo(12));
      });
    });

    test('a computer whose rate changes move it unevenly settles and stops '
        'nudging', () {
      run(simTappedRateCost, (sim) {
        expect(sim.coordinator.rejoins, 1);
        // Holding leaves up to 80 ms alone; a nudge only past that.
        expect(sim.worstFrom(60000), lessThanOrEqualTo(100));
        expect(sim.rateChangesFrom(60000), lessThanOrEqualTo(6));
      });
    });

    test('a computer that sounds late after a cue is cued early enough from '
        'the second cue on', () {
      fakeAsync((async) {
        final sim = _measured(async, simPinnedRateCost);
        sim.phone.playNow(position: 18000);
        sim.start();
        async.elapse(const Duration(seconds: 40));

        // The computer sounds 230 ms after its play: the first cue learns
        // that, so a seek on the phone lines it up at once.
        for (final position in [90000, 30000]) {
          sim.phone.seek(Duration(milliseconds: position));
          final cued = async.elapsed.inMilliseconds;
          async.elapse(const Duration(seconds: 20));
          // The phone's seek shows as drift and the cue sounds about 2.5 s
          // later; from then until a nudge could have done the work.
          expect(
            sim.worstFrom(cued + 3000, cued + 8000),
            lessThanOrEqualTo(25),
          );
        }
        sim.finish();
      });
    });
  });
}
