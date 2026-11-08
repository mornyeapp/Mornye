import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/lastfm/lastfm_service.dart';
import 'package:mornye/services/listenbrainz/listenbrainz_api.dart';
import 'package:mornye/services/listenbrainz/listenbrainz_service.dart';
import 'package:mornye/services/scrobbling/scrobbler.dart';

import 'support/lastfm_fakes.dart';
import 'support/scrobble_fakes.dart';

void main() {
  final services = <Scrobbler>[];
  void serviceTest(
    String description,
    Future<void> Function(WidgetTester) body,
  ) {
    testWidgets(description, (tester) async {
      try {
        await body(tester);
      } finally {
        for (final service in services.reversed) {
          final closing = service.close();
          await tester.pump();
          await closing;
        }
        services.clear();
      }
    });
  }

  final song = MediaItem(
    id: 'file:///private/music.flac',
    title: 'Song',
    artist: 'Artist',
    album: 'Album',
    duration: const Duration(minutes: 4),
    extras: const {
      'playbackInstance': 1,
      'displayMetadata': {'isrc': 'XX-000-00-00001', 'track_number': '3/12'},
    },
  );
  final playing = PlaybackState(
    playing: true,
    processingState: AudioProcessingState.ready,
  );

  ListenBrainzService create(
    WidgetTester tester,
    FakeListenBrainzServer server,
    MemoryScrobbleStore<ListenBrainzAccount> store,
  ) {
    final start = tester.binding.clock.now();
    final service = ListenBrainzService(
      api: server.api(),
      store: store,
      now: tester.binding.clock.now,
      elapsed: () => tester.binding.clock.now().difference(start),
    );
    services.add(service);
    return service;
  }

  serviceTest('a valid token signs in and is kept with its server', (
    tester,
  ) async {
    final server = FakeListenBrainzServer()..tokenValid = false;
    final store = MemoryScrobbleStore<ListenBrainzAccount>(enabled: false);
    final service = create(tester, server, store);
    await service.connect('  ');
    expect(service.problem, ScrobbleProblem.invalidToken);
    expect(server.urls, isEmpty);
    await service.connect('test-token');
    expect(service.problem, ScrobbleProblem.invalidToken);
    expect(service.connected, isFalse);
    expect(store.session, isNull);

    server.tokenValid = true;
    await service.connect(
      ' test-token ',
      server: 'https://music.example.test/apis/listenbrainz/',
    );
    expect(service.connected, isTrue);
    expect(service.enabled, isTrue);
    expect(service.username, 'listener');
    expect(service.problem, isNull);
    expect(store.session?.token, 'test-token');
    expect(
      store.session?.server,
      'https://music.example.test/apis/listenbrainz',
    );
    expect(
      server.urls.last.toString(),
      'https://music.example.test/apis/listenbrainz/1/validate-token',
    );
    await service.disconnect();
    expect(store.session, isNull);
    expect(service.connected, isFalse);
  });

  serviceTest('a token is never sent over http outside the local network', (
    tester,
  ) async {
    final server = FakeListenBrainzServer();
    final store = MemoryScrobbleStore<ListenBrainzAccount>(enabled: false);
    final service = create(tester, server, store);
    await service.connect('test-token', server: 'http://music.example.test');
    expect(service.problem, ScrobbleProblem.insecureServer);
    expect(service.connected, isFalse);
    expect(server.urls, isEmpty);
    await service.connect('test-token', server: 'http://192.168.1.20:8080');
    expect(service.connected, isTrue);
    expect(server.urls.single.host, '192.168.1.20');
  });

  serviceTest('an older saved http address is signed out before sending', (
    tester,
  ) async {
    final server = FakeListenBrainzServer();
    final store = MemoryScrobbleStore(
      session: const ListenBrainzAccount(
        username: 'listener',
        token: 'test-token',
        server: 'http://music.example.test',
      ),
    )..queue = [lastfmQueued(1)];
    final service = create(tester, server, store);
    await service.initialize();
    final handler = BaseAudioHandler();
    service.bind(handler);
    handler.mediaItem.add(song);
    handler.playbackState.add(playing);
    await tester.pump(const Duration(minutes: 3));
    expect(server.urls, isEmpty);
    expect(service.connected, isFalse);
    expect(service.problem, ScrobbleProblem.insecureServer);
    expect(store.session, isNull);
    // The listen waits for the account to sign in again over HTTPS.
    expect(store.queue, hasLength(1));
  });

  serviceTest('a listen is announced, then submitted with its identifiers', (
    tester,
  ) async {
    final server = FakeListenBrainzServer();
    final store = MemoryScrobbleStore(session: listenBrainzTestAccount);
    final service = create(tester, server, store);
    await service.initialize();
    final handler = BaseAudioHandler();
    service.bind(handler);
    handler.mediaItem.add(song);
    handler.playbackState.add(playing);
    await tester.pump();
    expect(server.nowPlaying, 1);
    await tester.pump(const Duration(seconds: 119));
    expect(server.listens, isEmpty);
    await tester.pump(const Duration(seconds: 1));
    await service.flush();
    final info =
        (server.listens.single['track_metadata'] as Map)['additional_info']
            as Map;
    expect(info['isrc'], 'XX0000000001');
    expect(info['tracknumber'], 3);
    expect(store.queue, isEmpty);
    expect(server.submissions.toString(), isNot(contains('/private/')));
  });

  serviceTest(
    'a revoked token keeps listens, a refused listen leaves, outages retry',
    (tester) async {
      final server = FakeListenBrainzServer()..submitStatus = 401;
      final store = MemoryScrobbleStore(session: listenBrainzTestAccount)
        ..queue = [lastfmQueued(1)];
      final service = create(tester, server, store);
      await service.initialize();
      await service.flush();
      expect(service.problem, ScrobbleProblem.reauthenticate);
      expect(service.connected, isFalse);
      expect(store.session, isNull);
      expect(store.queue, hasLength(1));

      server.submitStatus = 503;
      await service.connect('test-token');
      await service.flush();
      expect(service.problem, ScrobbleProblem.connection);
      expect(store.queue, hasLength(1));
      server.submitStatus = 400;
      await tester.pump(const Duration(seconds: 30));
      await tester.pump();
      expect(service.problem, ScrobbleProblem.rejected);
      expect(store.queue, isEmpty);
    },
  );

  serviceTest(
    'a refused import is resent one listen at a time, keeping the good ones',
    (tester) async {
      final server = FakeListenBrainzServer()
        ..refuses = ((listen) =>
            (listen['track_metadata'] as Map)['track_name'] == 'Bad');
      final store = MemoryScrobbleStore(session: listenBrainzTestAccount)
        ..queue = [
          lastfmQueued(1),
          lastfmQueued(2, title: 'Bad'),
          lastfmQueued(3),
        ];
      final service = create(tester, server, store);
      await service.initialize();
      await service.flush();
      expect(server.requests.map((body) => body['listen_type']), [
        'import',
        'single',
        'single',
        'single',
      ]);
      expect(
        server.listens.map((listen) => listen['listened_at']),
        [
          lastfmQueued(1),
          lastfmQueued(3),
        ].map((entry) => entry.started.millisecondsSinceEpoch ~/ 1000),
      );
      expect(store.queue, isEmpty);
      expect(service.problem, ScrobbleProblem.rejected);
      expect(service.connected, isTrue);
    },
  );

  serviceTest(
    'every enabled service gets the listen and one failing never blocks another',
    (tester) async {
      final start = tester.binding.clock.now();
      Duration elapsed() => tester.binding.clock.now().difference(start);
      final lastfmApi = FakeLastfmApi()
        ..batchError = const SocketException('offline');
      final lastfmStore = MemoryLastfmStore();
      final lastfm = LastfmService(
        api: lastfmApi,
        store: lastfmStore,
        now: tester.binding.clock.now,
        elapsed: elapsed,
      );
      services.add(lastfm);
      final librefmApi = FakeLastfmApi();
      final librefm = LastfmService(
        api: librefmApi,
        store: MemoryLastfmStore()..enabled = false,
        now: tester.binding.clock.now,
        elapsed: elapsed,
      );
      services.add(librefm);
      final server = FakeListenBrainzServer();
      final listenBrainzStore = MemoryScrobbleStore(
        session: listenBrainzTestAccount,
      );
      final listenBrainz = create(tester, server, listenBrainzStore);
      final handler = BaseAudioHandler();
      for (final service in services) {
        await service.initialize();
        service.bind(handler);
      }
      handler.mediaItem.add(song);
      handler.playbackState.add(playing);
      await tester.pump();
      await tester.pump(const Duration(minutes: 2));
      await tester.pump();
      for (final service in services) {
        await service.flush();
      }

      // Last.fm is offline: its listen waits in its own queue.
      expect(lastfmApi.batches, isNotEmpty);
      expect(lastfmStore.queue, hasLength(1));
      expect(lastfm.problem, ScrobbleProblem.connection);
      // Switched off: nothing is sent or queued.
      expect(librefmApi.announcements, isEmpty);
      expect(librefmApi.batches, isEmpty);
      expect(librefm.pendingCount, 0);
      // ListenBrainz is unaffected and receives the listen exactly once.
      expect(server.listens, hasLength(1));
      expect(listenBrainzStore.queue, isEmpty);
      expect(listenBrainz.problem, isNull);

      lastfmApi.batchError = null;
      final attempts = lastfmApi.batches.length;
      await tester.pump(const Duration(seconds: 30));
      await tester.pump();
      expect(lastfmApi.batches, hasLength(attempts + 1));
      expect(lastfmApi.batches.every((batch) => batch.length == 1), isTrue);
      expect(lastfmStore.queue, isEmpty);
      expect(lastfm.problem, isNull);
      expect(server.listens, hasLength(1));
    },
  );
}
