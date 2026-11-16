import 'dart:io';

import 'package:audio_service/audio_service.dart';
// ignore: depend_on_referenced_packages
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/lastfm/lastfm_service.dart';

import 'support/lastfm_fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final start = DateTime.utc(2026, 11, 1, 12);
  final song = MediaItem(
    id: 'file:///music/song.flac',
    title: 'Song',
    artist: 'Artist',
    duration: const Duration(minutes: 4),
    extras: const {'playbackInstance': 1},
  );
  PlaybackState playing({bool play = true, double speed = 1}) => PlaybackState(
    playing: play,
    speed: speed,
    processingState: AudioProcessingState.ready,
  );

  LastfmService create(
    FakeAsync async,
    FakeLastfmApi api,
    MemoryLastfmStore store,
  ) {
    final service = LastfmService(
      api: api,
      store: store,
      now: () => start.add(async.elapsed),
      elapsed: () => async.elapsed,
    );
    service.initialize();
    async.flushMicrotasks();
    return service;
  }

  void close(FakeAsync async, LastfmService service) {
    service.close();
    async.flushMicrotasks();
  }

  test('a connected service with nothing queued keeps no timer', () {
    fakeAsync((async) {
      final api = FakeLastfmApi(), store = MemoryLastfmStore();
      final service = create(async, api, store);
      expect(service.connected && service.enabled, isTrue);
      expect(async.pendingTimers, isEmpty);
      async.elapse(const Duration(minutes: 5));
      expect(async.pendingTimers, isEmpty);
      close(async, service);
    });
  });

  test('a playing song wakes the service once, when it counts', () {
    fakeAsync((async) {
      final api = FakeLastfmApi(), store = MemoryLastfmStore();
      final service = create(async, api, store);
      final handler = BaseAudioHandler();
      service.bind(handler);
      handler.mediaItem.add(song);
      handler.playbackState.add(playing());
      async.flushMicrotasks();
      expect(async.periodicTimerCount, 0);
      expect(async.pendingTimers.single.duration, const Duration(minutes: 2));
      async.elapse(const Duration(seconds: 119));
      expect(api.batches, isEmpty);
      async.elapse(const Duration(seconds: 1));
      expect(api.batches, hasLength(1));
      expect(store.queue, isEmpty);
      expect(async.pendingTimers, isEmpty);
      close(async, service);
    });
  });

  test('the wake-up follows pause and playback speed', () {
    fakeAsync((async) {
      final api = FakeLastfmApi(), store = MemoryLastfmStore();
      final service = create(async, api, store);
      final handler = BaseAudioHandler();
      service.bind(handler);
      handler.mediaItem.add(song);
      handler.playbackState.add(playing());
      async.elapse(const Duration(seconds: 100));
      handler.playbackState.add(playing(play: false));
      async.flushMicrotasks();
      expect(async.pendingTimers, isEmpty);
      async.elapse(const Duration(minutes: 10));
      handler.playbackState.add(playing(speed: 2));
      async.flushMicrotasks();
      // 20 s of the song remain, heard in 10 s at double speed.
      expect(async.pendingTimers.single.duration, const Duration(seconds: 10));
      async.elapse(const Duration(seconds: 9));
      expect(api.batches, isEmpty);
      async.elapse(const Duration(seconds: 1));
      expect(api.batches, hasLength(1));
      close(async, service);
    });
  });

  test('queued listens are retried every 30 s until the queue empties', () {
    fakeAsync((async) {
      final store = MemoryLastfmStore()..queue = [lastfmQueued(1)];
      final api = FakeLastfmApi()..batchError = const SocketException('');
      final service = create(async, api, store);
      expect(api.batches, hasLength(1));
      expect(async.periodicTimerCount, 1);
      async.elapse(const Duration(seconds: 30));
      expect(api.batches, hasLength(2));
      api.batchError = null;
      async.elapse(const Duration(seconds: 30));
      expect(api.batches, hasLength(3));
      expect(store.queue, isEmpty);
      expect(async.pendingTimers, isEmpty);
      close(async, service);
    });
  });
}
