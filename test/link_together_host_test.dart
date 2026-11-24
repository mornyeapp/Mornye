// ignore: depend_on_referenced_packages
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/link/link_host_router.dart';
import 'package:mornye/services/link/link_protocol.dart';
import 'package:mornye/services/link/together/link_together_host.dart';
import 'package:mornye/services/link/together/link_together_protocol.dart';

import 'support/link_together_fakes.dart';

void main() {
  final songs = [simSong('One'), simSong('Two'), simSong('Three')];
  const lengths = [240000, 240000, 240000];

  ({
    SimDeck deck,
    LinkTogetherHost host,
    LinkHostRouter router,
    List<({Map<String, dynamic> message, String deviceId})> sent,
    List<String> started,
  })
  setUp(FakeAsync async) {
    final deck = SimDeck(
      trueNowMs: () => 2000000 + async.elapsed.inMilliseconds,
      queue: songs,
      durations: lengths,
      clockOffsetMs: 4321,
    );
    final sent = <({Map<String, dynamic> message, String deviceId})>[];
    final started = <String>[];
    final host = LinkTogetherHost(
      deck: deck,
      nowMs: deck.nowMs,
      send: (message, deviceId) async {
        sent.add((message: message, deviceId: deviceId));
        return 1;
      },
      onStarted: started.add,
    );
    final router = LinkHostRouter();
    host.register(router);
    return (
      deck: deck,
      host: host,
      router: router,
      sent: sent,
      started: started,
    );
  }

  Future<Object?> call(
    LinkHostRouter router,
    String op,
    Map<String, dynamic> args, {
    String deviceId = 'phone-1',
  }) => router.dispatch(
    LinkRequest(requestId: 'r', op: op, deviceId: deviceId, args: args),
  );

  Object? run(FakeAsync async, Future<Object?> future) {
    Object? result;
    Object? error;
    future.then((value) => result = value, onError: (Object e) => error = e);
    async.elapse(const Duration(seconds: 2));
    if (error != null) throw error!;
    return result;
  }

  test('time answers the player on the computer clock', () {
    fakeAsync((async) {
      final (:deck, :host, :router, sent: _, started: _) = setUp(async);
      deck.playNow(index: 1, position: 5000);
      final report = LinkTogetherReport.fromJson(
        run(async, call(router, LinkTogetherOps.time, const {})),
      )!;
      expect(report.nowMs, deck.nowMs() - 2000);
      expect(report.track, songs[1]);
      expect(report.playing, isTrue);
      expect(report.canNudge, isTrue);
      expect(report.session, isNull);
      expect(host.active, isFalse);
    });
  });

  test('start takes a session and a role, and begins the player', () {
    fakeAsync((async) {
      final (:deck, :host, :router, sent: _, :started) = setUp(async);
      expect(
        () => run(
          async,
          call(router, LinkTogetherOps.start, const {'role': 'follower'}),
        ),
        throwsA(isA<LinkException>()),
      );
      expect(
        () => run(
          async,
          call(router, LinkTogetherOps.start, const {
            'session': 's1',
            'role': 'boss',
          }),
        ),
        throwsA(isA<LinkException>()),
      );

      final report = LinkTogetherReport.fromJson(
        run(
          async,
          call(router, LinkTogetherOps.start, const {
            'session': 's1',
            'role': 'follower',
          }),
        ),
      )!;
      expect(report.session, 's1');
      expect(host.active, isTrue);
      expect(host.deviceId, 'phone-1');
      expect(deck.begun, isTrue);
      expect(deck.beganAsFollower, isTrue);
      expect(started, ['phone-1']);
    });
  });

  test('another session or phone is refused', () {
    fakeAsync((async) {
      final (deck: _, host: _, :router, sent: _, started: _) = setUp(async);
      run(
        async,
        call(router, LinkTogetherOps.start, const {
          'session': 's1',
          'role': 'follower',
        }),
      );
      Matcher refused = throwsA(
        isA<LinkException>().having((e) => e.code, 'code', 'invalid'),
      );
      expect(
        () => run(
          async,
          call(router, LinkTogetherOps.stop, const {'session': 's2'}),
        ),
        refused,
      );
      expect(
        () => run(
          async,
          call(router, LinkTogetherOps.align, const {
            'session': 's1',
            'nudge': {'factor': 1.02, 'durationMs': 500},
          }, deviceId: 'phone-2'),
        ),
        refused,
      );
    });
  });

  test('a cue lines the player up and answers whether it has the song', () {
    fakeAsync((async) {
      final (:deck, host: _, :router, sent: _, started: _) = setUp(async);
      run(
        async,
        call(router, LinkTogetherOps.start, const {
          'session': 's1',
          'role': 'follower',
        }),
      );
      final cue = LinkTogetherCue(
        track: songs[2],
        positionMs: 7000,
        atMs: deck.nowMs(),
        playing: true,
      );
      final reply = run(
        async,
        call(router, LinkTogetherOps.align, {
          'session': 's1',
          'rejoin': cue.toJson(),
        }),
      );
      expect(reply, {'found': true});
      expect(deck.index, 2);
      expect(deck.truePosition, closeTo(cue.positionAt(deck.nowMs()), 1));

      final missing = run(
        async,
        call(router, LinkTogetherOps.align, {
          'session': 's1',
          'rejoin': LinkTogetherCue(
            track: simSong('Elsewhere'),
            positionMs: 0,
            atMs: deck.nowMs(),
            playing: true,
          ).toJson(),
        }),
      );
      expect(missing, {'found': false});
      expect(deck.playing, isFalse);
      final report = LinkTogetherReport.fromJson(
        run(async, call(router, LinkTogetherOps.time, const {})),
      )!;
      expect(report.silent, isTrue);
    });
  });

  test('a report carries the rate in force, which its position runs at', () {
    fakeAsync((async) {
      final (:deck, host: _, :router, sent: _, started: _) = setUp(async);
      deck.playNow(position: 5000);
      run(
        async,
        call(router, LinkTogetherOps.start, const {
          'session': 's1',
          'role': 'follower',
        }),
      );
      run(
        async,
        call(router, LinkTogetherOps.align, const {
          'session': 's1',
          'nudge': {'factor': 1.02, 'durationMs': 5000},
        }),
      );
      final report = LinkTogetherReport.fromJson(
        run(async, call(router, LinkTogetherOps.time, const {})),
      )!;
      expect(report.rate, 1.02);
      expect(report.positionAt(report.nowMs + 1000) - report.positionMs, 1020);

      // A computer that does not say runs at 1, and a rate no nudge sets is
      // not one.
      final json = report.toJson()..remove('rate');
      final unsaid = LinkTogetherReport.fromJson(json)!;
      expect(unsaid.rate, isNull);
      expect(unsaid.positionAt(unsaid.nowMs + 1000) - unsaid.positionMs, 1000);
      expect(LinkTogetherReport.fromJson({...json, 'rate': 0})!.rate, isNull);
      expect(LinkTogetherReport.fromJson({...json, 'rate': '2'})!.rate, isNull);
    });
  });

  test('stop pauses only when asked, and restores the player', () {
    fakeAsync((async) {
      final (:deck, :host, :router, sent: _, started: _) = setUp(async);
      deck.playNow();
      Map<String, dynamic> begin(String session) => {
        'session': session,
        'role': 'leader',
      };
      run(async, call(router, LinkTogetherOps.start, begin('s1')));
      run(async, call(router, LinkTogetherOps.stop, const {'session': 's1'}));
      expect(host.active, isFalse);
      expect(deck.begun, isFalse);
      expect(deck.playing, isTrue);

      run(async, call(router, LinkTogetherOps.start, begin('s2')));
      run(
        async,
        call(router, LinkTogetherOps.stop, const {
          'session': 's2',
          'pause': true,
        }),
      );
      expect(deck.playing, isFalse);
    });
  });

  test('a phone that leaves ends it and a start it waited for happens', () {
    fakeAsync((async) {
      final (:deck, :host, :router, sent: _, started: _) = setUp(async);
      run(
        async,
        call(router, LinkTogetherOps.start, const {
          'session': 's1',
          'role': 'follower',
        }),
      );
      // A cue that starts the player 250 ms from now.
      call(router, LinkTogetherOps.align, {
        'session': 's1',
        'rejoin': LinkTogetherCue(
          track: songs[0],
          positionMs: 1000,
          atMs: deck.nowMs(),
          playing: true,
        ).toJson(),
      });
      async.elapse(const Duration(milliseconds: 100));
      expect(deck.playing, isFalse);

      host.keepConnected(const {'phone-2'});
      async.flushMicrotasks();
      expect(host.active, isFalse);
      expect(deck.playing, isTrue);
      expect(deck.begun, isFalse);
    });
  });

  test('tells the phone about changes at once, once each', () {
    fakeAsync((async) {
      final (:deck, host: _, :router, :sent, started: _) = setUp(async);
      run(
        async,
        call(router, LinkTogetherOps.start, const {
          'session': 's1',
          'role': 'leader',
        }),
      );
      sent.clear();
      deck.playNow(index: 1, position: 3000);
      async.flushMicrotasks();
      final states = [
        for (final entry in sent)
          if (entry.message['type'] == LinkTogetherMessages.state) entry,
      ];
      expect(states, hasLength(1));
      expect(states.single.deviceId, 'phone-1');
      expect(states.single.message['session'], 's1');
      final report = LinkTogetherReport.fromJson(
        states.single.message['report'],
      )!;
      expect(report.track, songs[1]);
      expect(report.playing, isTrue);

      // Playing on as expected says nothing new.
      async.elapse(const Duration(seconds: 1));
      sent.clear();
      deck.touch();
      async.flushMicrotasks();
      expect(sent, isEmpty);

      deck.setRepeat(LinkRepeatMode.all);
      deck.touch();
      async.flushMicrotasks();
      expect(sent, hasLength(1));
    });
  });

  test("this computer's own controls become actions while it follows", () {
    fakeAsync((async) {
      final (:deck, :host, :router, :sent, started: _) = setUp(async);
      deck.playNow(position: 60000);
      run(
        async,
        call(router, LinkTogetherOps.start, const {
          'session': 's1',
          'role': 'follower',
        }),
      );
      List<String> actions() => [
        for (final entry in sent)
          if (entry.message['type'] == LinkTogetherMessages.action)
            entry.message['action'] as String,
      ];

      deck.pause();
      async.flushMicrotasks();
      deck.play();
      async.flushMicrotasks();
      deck.next();
      async.flushMicrotasks();
      deck.previous();
      async.flushMicrotasks();
      expect(actions(), [
        LinkTogetherActions.pause,
        LinkTogetherActions.play,
        LinkTogetherActions.next,
        LinkTogetherActions.previous,
      ]);

      // A cue's own changes are not the listener's.
      sent.clear();
      run(
        async,
        call(router, LinkTogetherOps.align, {
          'session': 's1',
          'rejoin': LinkTogetherCue(
            track: songs[2],
            positionMs: 0,
            atMs: deck.nowMs(),
            playing: true,
          ).toJson(),
        }),
      );
      expect(actions(), isEmpty);

      // Another queue picked here ends it.
      async.elapse(const Duration(seconds: 2));
      deck.load([simSong('Elsewhere')], const [100000]);
      async.flushMicrotasks();
      expect(actions(), [LinkTogetherActions.left]);
      expect(host.active, isFalse);
    });
  });

  test('a device picked in Devices ends it, whoever owns the queue', () {
    for (final role in ['follower', 'leader']) {
      fakeAsync((async) {
        final deck = SimDeck(
          trueNowMs: () => 2000000 + async.elapsed.inMilliseconds,
          queue: songs,
          durations: lengths,
        );
        final sent = <Map<String, dynamic>>[];
        var delivered = 1;
        final phones = <String?>[];
        late final LinkTogetherHost host;
        host = LinkTogetherHost(
          deck: deck,
          nowMs: deck.nowMs,
          send: (message, _) async {
            sent.add(message);
            return delivered;
          },
          onChanged: () => phones.add(host.deviceId),
        );
        final router = LinkHostRouter();
        host.register(router);
        Map<String, dynamic> start(String session) => {
          'session': session,
          'role': role,
        };
        List<String> actions() => [
          for (final message in sent)
            if (message['type'] == LinkTogetherMessages.action)
              message['action'] as String,
        ];

        // Nothing to end.
        expect(run(async, host.leave(keepHere: true)), isFalse);

        deck.playNow(position: 60000);
        run(async, call(router, LinkTogetherOps.start, start('s1')));
        expect(phones, ['phone-1']);

        // This computer: the phone is told and this computer plays on.
        expect(run(async, host.leave(keepHere: true)), isTrue, reason: role);
        expect(actions(), [LinkTogetherActions.left]);
        expect(host.active, isFalse);
        expect(deck.playing, isTrue);
        expect(phones, ['phone-1', null]);

        // The phone: it ends the session itself, which pauses this computer.
        sent.clear();
        run(async, call(router, LinkTogetherOps.start, start('s2')));
        expect(run(async, host.leave(keepHere: false)), isTrue, reason: role);
        expect(actions(), [LinkTogetherActions.leftForPhone]);
        expect(host.active, isTrue);
        run(
          async,
          call(router, LinkTogetherOps.stop, const {
            'session': 's2',
            'pause': true,
          }),
        );
        expect(host.active, isFalse);
        expect(deck.playing, isFalse);
        expect(phones, ['phone-1', null, 'phone-1', null]);

        // A phone that cannot be told keeps the session.
        run(async, call(router, LinkTogetherOps.start, start('s3')));
        delivered = 0;
        expect(run(async, host.leave(keepHere: true)), isFalse);
        expect(host.active, isTrue);
      });
    }
  });
}
