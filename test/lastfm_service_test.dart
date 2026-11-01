import 'dart:async';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/lastfm/lastfm_api.dart';
import 'package:mornye/services/lastfm/lastfm_service.dart';

import 'support/lastfm_fakes.dart';

void main() {
  final services = <LastfmService>[];
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
    extras: const {'playbackInstance': 1},
  );
  PlaybackState playing({bool play = true}) =>
      PlaybackState(playing: play, processingState: AudioProcessingState.ready);

  LastfmService create(
    WidgetTester tester,
    FakeLastfmApi api,
    MemoryLastfmStore store, {
    Future<bool> Function(Uri)? openBrowser,
  }) {
    final start = tester.binding.clock.now();
    final service = LastfmService(
      api: api,
      store: store,
      now: tester.binding.clock.now,
      elapsed: () => tester.binding.clock.now().difference(start),
      openBrowser: openBrowser ?? (_) async => true,
    );
    services.add(service);
    return service;
  }

  serviceTest('local playback persists a qualified listen before submission', (
    tester,
  ) async {
    final api = FakeLastfmApi(), store = MemoryLastfmStore();
    final persistedSizes = <int>[];
    api.onBatch = () => persistedSizes.add(store.queue.length);
    final service = create(tester, api, store);
    await service.initialize();
    final handler = BaseAudioHandler();
    service.bind(handler);
    handler.mediaItem.add(song);
    handler.playbackState.add(playing());
    await tester.pump();
    expect(api.announcements.single['track'], 'Song');
    expect(api.announcements.single.toString(), isNot(contains('/private/')));
    await tester.pump(const Duration(seconds: 120));
    await service.flush();
    expect(api.batches, hasLength(1));
    expect(persistedSizes, [1]);
    expect(api.batches.single.single.keys, isNot(contains('id')));
    expect(store.queue, isEmpty);
    expect(service.pendingCount, 0);
    await tester.pump(const Duration(minutes: 4));
    expect(api.batches, hasLength(1));
  });

  serviceTest('offline queue survives restart and keeps original timestamps', (
    tester,
  ) async {
    final store = MemoryLastfmStore();
    final offline = FakeLastfmApi()
      ..batchError = const SocketException('offline');
    final first = create(tester, offline, store);
    await first.initialize();
    final handler = BaseAudioHandler();
    first.bind(handler);
    handler.mediaItem.add(song);
    handler.playbackState.add(playing());
    await tester.pump();
    await tester.pump(const Duration(seconds: 120));
    await first.flush();
    expect(store.queue, hasLength(1));
    final timestamp = store.queue.single.parameters['timestamp'];
    await first.close();
    final online = FakeLastfmApi();
    final second = create(tester, online, store);
    await second.initialize();
    await second.flush();
    expect(online.batches.single.single['timestamp'], timestamp);
    expect(store.queue, isEmpty);
  });

  serviceTest(
    'cached batches stay ordered, are limited to 50 and do not overlap',
    (tester) async {
      final store = MemoryLastfmStore()
        ..queue = [for (var i = 0; i < 101; i++) lastfmQueued(i)];
      final gate = Completer<void>();
      final api = FakeLastfmApi()..batchGate = gate;
      final service = create(tester, api, store);
      await service.initialize();
      final flush = service.flush();
      final concurrent = service.flush();
      await tester.pump();
      expect(api.batches, hasLength(1));
      gate.complete();
      await Future.wait([flush, concurrent]);
      expect(api.batches.map((batch) => batch.length), [50, 50, 1]);
      expect(
        api.batches.first.first['timestamp'],
        lastfmQueued(0).parameters['timestamp'],
      );
      expect(store.queue, isEmpty);
    },
  );

  serviceTest(
    'scrobbling opt-out makes no requests and excludes elapsed time',
    (tester) async {
      final store = MemoryLastfmStore()..enabled = false;
      final api = FakeLastfmApi();
      final service = create(tester, api, store);
      await service.initialize();
      final handler = BaseAudioHandler();
      service.bind(handler);
      handler.mediaItem.add(song);
      handler.playbackState.add(playing());
      await tester.pump(const Duration(minutes: 10));
      expect(api.announcements, isEmpty);
      expect(api.batches, isEmpty);
      await service.setEnabled(true);
      await tester.pump(const Duration(seconds: 119));
      expect(api.batches, isEmpty);
      await tester.pump(const Duration(seconds: 1));
      await service.flush();
      expect(api.batches, hasLength(1));
    },
  );

  serviceTest(
    'Now Playing can be switched off independently and failures are not retried',
    (tester) async {
      final store = MemoryLastfmStore()..nowPlaying = false;
      final api = FakeLastfmApi()
        ..announceError = const SocketException('offline');
      final service = create(tester, api, store);
      await service.initialize();
      final handler = BaseAudioHandler();
      service.bind(handler);
      handler.mediaItem.add(song);
      handler.playbackState.add(playing());
      await tester.pump();
      expect(api.announcements, isEmpty);
      await service.setNowPlaying(true);
      expect(api.announcements, hasLength(1));
      await tester.pump(const Duration(minutes: 2));
      await service.flush();
      expect(api.announcements, hasLength(1));
      expect(api.batches, hasLength(1));
    },
  );

  serviceTest('browser approval is required and session is stored separately', (
    tester,
  ) async {
    final store = MemoryLastfmStore()..session = null;
    final api = FakeLastfmApi()..sessionError = const LastfmException(14);
    Uri? browser;
    final service = create(
      tester,
      api,
      store,
      openBrowser: (url) async {
        browser = url;
        return true;
      },
    );
    await service.beginConnection();
    expect(browser?.host, 'www.last.fm');
    expect(service.awaitingAuthorization, isTrue);
    await service.finishConnection();
    expect(service.connected, isFalse);
    expect(service.problem, LastfmProblem.pending);
    api.sessionError = null;
    await service.finishConnection();
    expect(service.connected, isTrue);
    expect(store.session?.key, lastfmTestSession.key);
    expect(service.enabled, isTrue);
    expect(service.busy, isFalse);
    expect(service.awaitingAuthorization, isFalse);
  });

  serviceTest(
    'expired approval can be restarted and browser failure can recover',
    (tester) async {
      final store = MemoryLastfmStore()..session = null;
      final api = FakeLastfmApi();
      var opened = false;
      final service = create(
        tester,
        api,
        store,
        openBrowser: (_) async => opened,
      );
      await service.beginConnection();
      expect(service.problem, LastfmProblem.connection);
      expect(service.awaitingAuthorization, isFalse);
      opened = true;
      await service.beginConnection();
      await tester.pump(const Duration(hours: 1));
      await service.finishConnection();
      expect(service.problem, LastfmProblem.expired);
      expect(service.connected, isFalse);
      await service.beginConnection();
      await service.finishConnection();
      expect(service.connected, isTrue);
    },
  );

  serviceTest('cancelled login cannot publish a late session', (tester) async {
    final store = MemoryLastfmStore()..session = null;
    final result = Completer<LastfmSession>();
    final api = FakeLastfmApi()..sessionResult = result;
    final service = create(tester, api, store);
    await service.beginConnection();
    final finish = service.finishConnection();
    service.cancelConnection();
    result.complete(lastfmTestSession);
    await finish;
    expect(service.connected, isFalse);
    expect(store.session, isNull);
  });

  serviceTest(
    'network failure during approval can be retried without a new token',
    (tester) async {
      final api = FakeLastfmApi()
        ..sessionError = const SocketException('offline');
      final service = create(tester, api, MemoryLastfmStore()..session = null);
      await service.beginConnection();
      await service.finishConnection();
      expect(service.problem, LastfmProblem.connection);
      expect(service.awaitingAuthorization, isTrue);
      api.sessionError = null;
      await service.finishConnection();
      expect(service.connected, isTrue);
      expect(api.tokenRequests, 1);
    },
  );

  serviceTest('disconnect wins over a pending secure-storage write', (
    tester,
  ) async {
    final gate = Completer<void>();
    final store = MemoryLastfmStore()..session = null;
    final service = create(tester, FakeLastfmApi(), store);
    await service.beginConnection();
    store.sessionGate = gate;
    final finish = service.finishConnection();
    await tester.pump();
    final disconnect = service.disconnect();
    await tester.pump();
    gate.complete();
    await Future.wait([finish, disconnect]);
    expect(store.session, isNull);
    expect(service.connected, isFalse);
    expect(service.enabled, isFalse);
  });

  serviceTest('only the connected account receives cached scrobbles', (
    tester,
  ) async {
    final store = MemoryLastfmStore()
      ..queue = [lastfmQueued(1), lastfmQueued(2, username: 'other')];
    final api = FakeLastfmApi();
    final service = create(tester, api, store);
    await service.initialize();
    await service.flush();
    expect(api.batches.single, hasLength(1));
    expect(api.accounts.single, 'listener');
    expect(store.queue.single.username, 'other');
    await service.disconnect();
    expect(store.queue, isEmpty);
    expect(store.session, isNull);
  });

  serviceTest(
    'session revocation retains pending plays and stops automatic submission',
    (tester) async {
      final store = MemoryLastfmStore()..queue = [lastfmQueued(1)];
      final api = FakeLastfmApi()..batchError = const LastfmException(9);
      final service = create(tester, api, store);
      await service.initialize();
      await service.flush();
      expect(service.problem, LastfmProblem.reauthenticate);
      expect(service.connected, isFalse);
      expect(store.queue, hasLength(1));
      expect(store.session, isNull);
      await tester.pump(const Duration(minutes: 5));
      expect(api.batches, hasLength(1));
      api.batchError = null;
      await service.beginConnection();
      await service.finishConnection();
      await service.flush();
      expect(store.queue, isEmpty);
    },
  );

  serviceTest(
    'permanent errors are not retried, temporary errors remain queued',
    (tester) async {
      for (final code in [6, 11, 16, 29]) {
        final store = MemoryLastfmStore()..queue = [lastfmQueued(code)];
        final api = FakeLastfmApi()..batchError = LastfmException(code);
        final service = create(tester, api, store);
        await service.initialize();
        await service.flush();
        expect(store.queue.length, code == 6 ? 0 : 1);
        await tester.pump(const Duration(seconds: 30));
        expect(api.batches.length, code == 6 ? 1 : 2);
        await service.close();
      }
    },
  );

  serviceTest(
    'failed storage prevents submission and recovers without losing the queue',
    (tester) async {
      final store = MemoryLastfmStore()..failRead = true;
      final api = FakeLastfmApi();
      final service = create(tester, api, store);
      await service.initialize();
      expect(service.problem, LastfmProblem.storage);
      expect(store.writes, 0);
      store.failRead = false;
      await service.retry();
      final handler = BaseAudioHandler();
      service.bind(handler);
      handler.mediaItem.add(song);
      handler.playbackState.add(playing());
      await tester.pump();
      store.failWrite = true;
      await tester.pump(const Duration(seconds: 120));
      expect(api.batches, isEmpty);
      expect(service.pendingCount, 1);
      store.failWrite = false;
      await service.retry();
      expect(api.batches, hasLength(1));
      expect(store.queue, isEmpty);
    },
  );

  serviceTest(
    'unbind stops counting and configured credentials are required to connect',
    (tester) async {
      final api = FakeLastfmApi();
      final service = create(tester, api, MemoryLastfmStore());
      await service.initialize();
      final handler = BaseAudioHandler();
      service.bind(handler);
      handler.mediaItem.add(song);
      handler.playbackState.add(playing());
      await tester.pump(const Duration(seconds: 20));
      service.bind(null);
      await tester.pump(const Duration(minutes: 10));
      expect(api.batches, isEmpty);
      final unavailableApi = FakeLastfmApi(configured: false);
      final unavailable = create(
        tester,
        unavailableApi,
        MemoryLastfmStore()..session = null,
      );
      await unavailable.beginConnection();
      expect(unavailable.problem, LastfmProblem.unavailable);
      expect(unavailableApi.tokenRequests, 0);
    },
  );
}
