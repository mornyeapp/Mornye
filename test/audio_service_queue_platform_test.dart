import 'dart:async';
import 'dart:collection';

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
  final states = <PlaybackStateMessage>[];
  late AudioHandlerCallbacks callbacks;
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
    states.add(request.state);
    log.add('state ${request.state.processingState.name}');
    return Future<void>.value();
  }

  @override
  void setHandlerCallbacks(AudioHandlerCallbacks callbacks) {
    this.callbacks = callbacks;
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
    states.clear();
    holdQueue = false;
  }
}

class _Handler extends BaseAudioHandler {
  final selections = <int>[];

  @override
  Future<void> skipToQueueItem(int index) async => selections.add(index);
}

class _LazyQueue extends ListBase<MediaItem> {
  int reads = 0;

  @override
  int get length => 20000;

  @override
  set length(int value) => throw UnsupportedError('Read only');

  @override
  MediaItem operator [](int index) {
    RangeError.checkValidIndex(index, this);
    reads++;
    return MediaItem(id: 'song-$index', title: 'Song $index');
  }

  @override
  void operator []=(int index, MediaItem value) =>
      throw UnsupportedError('Read only');
}

class _BrokenQueue extends _LazyQueue {
  @override
  MediaItem operator [](int index) => throw StateError('Queue read failed');
}

const _indexKey = 'com.ryanheise.audio_service.queueIndex';

int _nativeId(List<MediaItemMessage> queue, int position) =>
    queue[position].extras?[_indexKey] as int? ?? position;

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
  late _Handler handler;

  setUpAll(() async {
    AudioServicePlatform.instance = platform;
    handler = await AudioService.init(
      builder: _Handler.new,
      cacheManager: _Cache(),
    );
    AudioService.asyncError.listen(errors.add);
    await pumpEventQueue();
  });

  setUp(() async {
    platform.reset();
    handler.playbackState.add(PlaybackState());
    handler.queue.add([]);
    await pumpEventQueue();
    platform.reset();
    handler.selections.clear();
    errors.clear();
  });

  tearDown(() => debugDefaultTargetPlatformOverride = null);

  test('Android receives at most 500 queue entries on every change', () async {
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
      songs.take(500).map((song) => song.id),
    );
    expect(platform.queues.last, hasLength(500));
    expect(platform.queues.first.first.toMap(), platform.items.single.toMap());
    expect(platform.queues.first.last.extras, {
      'path': '/music/song-499.flac',
      'bitrate': 1411,
    });
  });

  test(
    'a 20,000-song queue keeps absolute IDs and the complete app queue',
    () async {
      final songs = _songs(20000);
      handler.playbackState.add(PlaybackState(queueIndex: 10000));
      handler.queue.add(songs);
      await pumpEventQueue();
      final window = platform.queues.last;
      expect(window, hasLength(500));
      expect(window.first.id, 'song-9900');
      expect(window.last.id, 'song-10399');
      expect(_nativeId(window, 0), 9900);
      expect(_nativeId(window, 100), 10000);
      expect(_nativeId(window, 499), 10399);
      expect(platform.states.last.queueIndex, 10000);
      expect(identical(handler.queue.value, songs), isTrue);
      expect(handler.queue.value, hasLength(20000));
      expect(songs[9900].extras, isNot(contains(_indexKey)));

      await platform.callbacks.skipToQueueItem(
        SkipToQueueItemRequest(index: _nativeId(window, 314)),
      );
      expect(handler.selections, [10214]);
      await handler.skipToQueueItem(17000);
      expect(handler.selections, [10214, 17000]);
    },
  );

  test(
    'index-only changes keep a stable window and recenter near its edges',
    () async {
      handler.queue.add(_songs(20000));
      await pumpEventQueue();
      expect(platform.queues.single.first.id, 'song-0');
      for (final index in [0, 1, 100, 449]) {
        handler.playbackState.add(PlaybackState(queueIndex: index));
      }
      await pumpEventQueue();
      expect(platform.queues, hasLength(1));
      handler.playbackState.add(PlaybackState(queueIndex: 450));
      await pumpEventQueue();
      expect(platform.queues, hasLength(2));
      expect(platform.queues.last.first.id, 'song-350');
      handler.playbackState.add(PlaybackState(queueIndex: 399));
      await pumpEventQueue();
      expect(platform.queues.last.first.id, 'song-299');

      handler.playbackState.add(PlaybackState(queueIndex: 19999));
      await pumpEventQueue();
      expect(platform.queues.last.first.id, 'song-19500');
      expect(platform.queues.last.last.id, 'song-19999');
      final sends = platform.queues.length;
      for (final index in [19998, 19999, -1, 20000, null]) {
        handler.playbackState.add(PlaybackState(queueIndex: index));
      }
      await pumpEventQueue();
      expect(platform.queues, hasLength(sends));
      handler.playbackState.add(PlaybackState(queueIndex: 0));
      await pumpEventQueue();
      expect(platform.queues.last.first.id, 'song-0');
    },
  );

  test(
    'metadata, artwork, reorders and replacements use the latest full queue',
    () async {
      final songs = _songs(20000);
      handler.playbackState.add(PlaybackState(queueIndex: 10000));
      handler.queue.add(songs);
      await pumpEventQueue();
      final changed = [...songs];
      changed[10000] = changed[10000].copyWith(
        title: 'Updated title',
        duration: const Duration(minutes: 8),
        artUri: Uri.parse('content://example.covers/current'),
        extras: {'path': '/music/moved.flac', _indexKey: -700},
      );
      handler.queue.add(changed);
      handler.mediaItem.add(changed[10000]);
      await pumpEventQueue();
      final updated = platform.queues.last[100];
      expect(updated.title, 'Updated title');
      expect(updated.duration, const Duration(minutes: 8));
      expect(updated.artUri, changed[10000].artUri);
      expect(updated.extras, {'path': '/music/moved.flac', _indexKey: 10000});
      expect(platform.items.last.extras?[_indexKey], -700);
      expect(changed[10000].extras?[_indexKey], -700);

      changed[10000] = changed[10000].copyWith(title: 'Same list update');
      handler.queue.add(changed);
      await pumpEventQueue();
      expect(platform.queues.last[100].title, 'Same list update');
      final reversed = changed.reversed.toList();
      handler.queue.add(reversed);
      await pumpEventQueue();
      expect(platform.queues.last[100].id, 'song-9999');
      expect(_nativeId(platform.queues.last, 100), 10000);
      handler.queue.add(reversed.sublist(10));
      await pumpEventQueue();
      expect(platform.queues.last[100].id, 'song-9989');

      handler.queue.add(_songs(3));
      await pumpEventQueue();
      expect(platform.queues.last.map((item) => item.id), [
        'song-0',
        'song-1',
        'song-2',
      ]);
      handler.queue.add([]);
      await pumpEventQueue();
      expect(platform.queues.last, isEmpty);
      expect(handler.queue.value, isEmpty);
    },
  );

  test(
    'pending windows and stale native selections retain absolute indices',
    () async {
      handler.playbackState.add(PlaybackState(queueIndex: 10000));
      platform.holdQueue = true;
      handler.queue.add(_songs(20000));
      await pumpEventQueue();
      final visible = platform.queues.single;
      handler.playbackState.add(PlaybackState(queueIndex: 15000));
      final replacement = _songs(18000);
      replacement[1000] = replacement[1000].copyWith(title: 'Replacement');
      handler.queue.add(replacement);
      handler.playbackState.add(PlaybackState(queueIndex: 1000));
      await pumpEventQueue();
      expect(platform.queues, hasLength(1));
      await platform.callbacks.skipToQueueItem(
        SkipToQueueItemRequest(index: _nativeId(visible, 100)),
      );
      expect(handler.selections, [10000]);
      platform.replyQueue();
      await pumpEventQueue();
      final latest = platform.queues.last;
      expect(platform.queues, hasLength(2));
      expect(latest.first.id, 'song-900');
      expect(latest[100].title, 'Replacement');
      await platform.callbacks.skipToQueueItem(
        SkipToQueueItemRequest(index: _nativeId(latest, 100)),
      );
      expect(handler.selections, [10000, 1000]);
      platform.replyQueue(PlatformException(code: 'queue-failed'));
      await pumpEventQueue();
      expect(errors.single, isA<PlatformException>());
      platform.holdQueue = false;
      handler.queue.add(replacement);
      await pumpEventQueue();
      expect(platform.queues.last.first.id, 'song-900');
      expect(handler.queue.value, hasLength(18000));
    },
  );

  test(
    'small queues keep their full payload and reserved IDs cannot override it',
    () async {
      for (final length in [0, 1, 499, 500, 501]) {
        final songs = _songs(length);
        handler.queue.add(songs);
        await pumpEventQueue();
        expect(platform.queues.last, hasLength(length > 500 ? 500 : length));
        if (length > 0) {
          expect(platform.queues.last.first.extras, songs.first.extras);
        }
      }
      handler.playbackState.add(PlaybackState(queueIndex: 500));
      await pumpEventQueue();
      expect(platform.queues.last.first.id, 'song-1');
      expect(platform.queues.last.last.id, 'song-500');
      expect(_nativeId(platform.queues.last, 499), 500);
      final item = MediaItem(
        id: 'reserved',
        title: 'Reserved',
        extras: {_indexKey: 999},
      );
      handler.queue.add([item]);
      await pumpEventQueue();
      expect(platform.queues.last.single.extras?[_indexKey], 0);
      expect(item.extras?[_indexKey], 999);
    },
  );

  test('the sender only reads 500 items before building messages', () async {
    final songs = _LazyQueue();
    handler.playbackState.add(PlaybackState(queueIndex: 10000));
    handler.queue.add(songs);
    await pumpEventQueue();
    expect(platform.queues.single, hasLength(500));
    expect(songs.reads, 500);
    expect(handler.queue.value, same(songs));
  });

  test(
    'a failed window read reports an error and permits the next send',
    () async {
      handler.playbackState.add(PlaybackState(queueIndex: 10000));
      handler.queue.add(_BrokenQueue());
      await pumpEventQueue();
      expect(platform.queues, isEmpty);
      expect(errors.single, isA<StateError>());
      handler.queue.add(_songs(20000));
      await pumpEventQueue();
      expect(platform.queues.single, hasLength(500));
      expect(platform.queues.single.first.id, 'song-9900');
    },
  );

  test('the 20,000-song channel payload is bounded before encoding', () async {
    const codec = StandardMethodCodec();
    final songs = _songs(20000);
    handler.playbackState.add(PlaybackState(queueIndex: 10000));
    handler.queue.add(songs);
    await pumpEventQueue();
    final actual = codec.encodeMethodCall(
      MethodCall('setQueue', {
        'queue': platform.queues.last.map((item) => item.toMap()).toList(),
      }),
    );
    final fullItem = Map<String, Object?>.from(
      platform.queues.last.first.toMap(),
    );
    fullItem.remove('extras');
    final full = codec.encodeMethodCall(
      MethodCall('setQueue', {
        'queue': [
          for (var i = 0; i < songs.length; i++)
            {
              ...fullItem,
              'id': songs[i].id,
              'title': songs[i].title,
              'duration': songs[i].duration!.inMilliseconds,
              'extras': songs[i].extras,
            },
        ],
      }),
    );
    expect(actual.lengthInBytes, lessThan(full.lengthInBytes ~/ 30));
    // ignore: avoid_print
    print(
      'setQueue codec bytes: ${full.lengthInBytes} -> ${actual.lengthInBytes}',
    );
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
