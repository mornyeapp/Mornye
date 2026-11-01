import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:audio_service_platform_interface/audio_service_platform_interface.dart';
import 'package:audio_service_platform_interface/no_op_audio_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_test/flutter_test.dart';

class _Cache implements BaseCacheManager {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _RecordingPlatform extends NoOpAudioService {
  final log = <String>[];
  final queues = <List<MediaItemMessage>>[];
  final items = <MediaItemMessage>[];
  final _queueReplies = <Completer<void>>[];
  bool holdQueue = false;

  @override
  Future<void> setQueue(SetQueueRequest request) {
    queues.add(request.queue);
    log.add('queue ${request.queue.map((item) => item.id).join(',')}');
    if (!holdQueue) return Future<void>.value();
    final reply = Completer<void>();
    _queueReplies.add(reply);
    return reply.future;
  }

  @override
  Future<void> setMediaItem(SetMediaItemRequest request) {
    items.add(request.mediaItem);
    log.add('item ${request.mediaItem.id}');
    return Future<void>.value();
  }

  @override
  Future<void> setState(SetStateRequest request) {
    log.add('state ${request.state.processingState.name}');
    return Future<void>.value();
  }

  void replyQueue([Object? error]) {
    final reply = _queueReplies.removeAt(0);
    if (error == null) {
      reply.complete();
    } else {
      reply.completeError(error);
    }
  }

  void reset() {
    expect(_queueReplies, isEmpty);
    log.clear();
    queues.clear();
    items.clear();
    holdQueue = false;
  }
}

List<MediaItem> _songs(int count) => [
  for (var index = 0; index < count; index++)
    MediaItem(
      id: 'song-$index',
      title: 'Song $index',
      artist: 'Artist',
      album: 'Album',
      duration: Duration(seconds: 180 + index),
      extras: {'path': '/music/song-$index.flac', 'bitrate': 1411},
    ),
];

List<MediaItem> _queue(String id) => [MediaItem(id: id, title: 'Song $id')];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final platform = _RecordingPlatform();
  final errors = <Object>[];
  late BaseAudioHandler handler;

  setUpAll(() async {
    AudioServicePlatform.instance = platform;
    handler = await AudioService.init(
      builder: BaseAudioHandler.new,
      cacheManager: _Cache(),
    );
    AudioService.asyncError.listen(errors.add);
    await pumpEventQueue();
  });

  setUp(() {
    platform.reset();
    errors.clear();
  });

  tearDown(() => debugDefaultTargetPlatformOverride = null);

  test('Android receives the whole queue on every change', () async {
    final songs = _songs(1000);
    handler.queue.add(songs);
    await pumpEventQueue();
    handler.queue.add(songs.sublist(1));
    await pumpEventQueue();
    handler.mediaItem.add(songs.first);
    await pumpEventQueue();

    expect(platform.queues, hasLength(2));
    expect(
      platform.queues.first.map((item) => item.id),
      songs.map((song) => song.id),
    );
    expect(platform.queues.last, hasLength(999));
    expect(platform.queues.first.first.toMap(), platform.items.single.toMap());
    expect(platform.queues.first.last.extras, {
      'path': '/music/song-999.flac',
      'bitrate': 1411,
    });
  });

  for (final target in [
    TargetPlatform.iOS,
    TargetPlatform.macOS,
    TargetPlatform.windows,
    TargetPlatform.linux,
    TargetPlatform.fuchsia,
  ]) {
    test('${target.name} receives no queue', () async {
      debugDefaultTargetPlatformOverride = target;
      handler.queue.add(_songs(1000));
      handler.mediaItem.add(_queue('current').single);
      handler.queue.add(_songs(10));
      await pumpEventQueue();

      expect(platform.queues, isEmpty);
      expect(platform.log, ['item current']);
    });
  }

  test('a burst during a send sends only the newest queue next', () async {
    platform.holdQueue = true;
    handler.queue.add(_queue('q1'));
    await pumpEventQueue();
    for (final id in ['q2', 'q3', 'q4']) {
      handler.queue.add(_queue(id));
    }
    await pumpEventQueue();
    expect(platform.log, ['queue q1']);

    platform.replyQueue();
    await pumpEventQueue();
    expect(platform.log, ['queue q1', 'queue q4']);

    handler.queue.add(_queue('q5'));
    handler.queue.add(_queue('q6'));
    await pumpEventQueue();
    platform.replyQueue(PlatformException(code: 'failed'));
    await pumpEventQueue();
    expect(platform.log, ['queue q1', 'queue q4', 'queue q6']);
    expect(errors.single, isA<PlatformException>());

    platform.replyQueue();
    await pumpEventQueue();
    expect(platform.log, hasLength(3));

    handler.queue.add(_queue('q7'));
    await pumpEventQueue();
    expect(platform.log.last, 'queue q7');
    platform.replyQueue();
    await pumpEventQueue();
  });

  test('the newest queue keeps its place among item and state calls', () async {
    platform.holdQueue = true;
    handler.queue.add(_queue('q1'));
    await pumpEventQueue();
    handler.queue.add(_queue('q2'));
    handler.mediaItem.add(_queue('m2').single);
    handler.queue.add(_queue('q3'));
    handler.playbackState.add(
      PlaybackState(processingState: AudioProcessingState.buffering),
    );
    await pumpEventQueue();
    platform.replyQueue();
    await pumpEventQueue();
    platform.replyQueue();
    await pumpEventQueue();
    platform.holdQueue = false;
    handler.queue.add(_queue('q4'));
    handler.mediaItem.add(_queue('m4').single);
    await pumpEventQueue();

    expect(platform.log, [
      'queue q1',
      'item m2',
      'state buffering',
      'queue q3',
      'queue q4',
      'item m4',
    ]);
  });
}
