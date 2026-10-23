import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';

class _Cache implements BaseCacheManager {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'playback synchronization awaits the native acknowledgement and errors',
    () async {
      const client = MethodChannel(
        'com.ryanheise.audio_service.client.methods',
      );
      const native = MethodChannel(
        'com.ryanheise.audio_service.handler.methods',
      );
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      Completer<void>? nativeReply;
      var received = 0;
      messenger.setMockMethodCallHandler(client, (_) async => null);
      messenger.setMockMethodCallHandler(native, (call) async {
        if (call.method == 'setState') {
          received++;
          await nativeReply?.future;
        }
        return null;
      });
      addTearDown(() {
        messenger.setMockMethodCallHandler(client, null);
        messenger.setMockMethodCallHandler(native, null);
      });
      final errors = <Object>[];
      final subscription = AudioService.asyncError.listen(errors.add);
      addTearDown(subscription.cancel);
      final handler = await AudioService.init(
        builder: BaseAudioHandler.new,
        cacheManager: _Cache(),
      );
      addTearDown(() async {
        await handler.playbackState.close();
        await handler.queue.close();
        await handler.mediaItem.close();
        await handler.androidPlaybackInfo.close();
      });
      await AudioService.synchronizePlaybackState();
      expect(received, 1);

      nativeReply = Completer<void>();
      handler.playbackState.add(
        PlaybackState(
          playing: true,
          processingState: AudioProcessingState.ready,
        ),
      );
      var playingAcknowledged = false;
      final playing = AudioService.synchronizePlaybackState().then(
        (_) => playingAcknowledged = true,
      );
      await Future<void>.delayed(Duration.zero);
      expect(received, 2);
      expect(playingAcknowledged, isFalse);

      handler.playbackState.add(
        PlaybackState(processingState: AudioProcessingState.ready),
      );
      var pausedAcknowledged = false;
      final paused = AudioService.synchronizePlaybackState().then(
        (_) => pausedAcknowledged = true,
      );
      nativeReply.complete();
      nativeReply = Completer<void>();
      await playing;
      await Future<void>.delayed(Duration.zero);
      expect(received, 3);
      expect(pausedAcknowledged, isFalse);
      nativeReply.complete();
      await paused;
      await AudioService.synchronizePlaybackState();
      expect(received, 3);

      nativeReply = Completer<void>();
      handler.playbackState.add(
        PlaybackState(
          playing: true,
          processingState: AudioProcessingState.ready,
        ),
      );
      final failed = AudioService.synchronizePlaybackState();
      final failure = expectLater(failed, throwsA(isA<PlatformException>()));
      await Future<void>.delayed(Duration.zero);
      nativeReply.completeError(PlatformException(code: 'foreground-denied'));
      await failure;
      await Future<void>.delayed(Duration.zero);
      expect(errors, hasLength(1));

      nativeReply = null;
      handler.playbackState.add(
        PlaybackState(processingState: AudioProcessingState.ready),
      );
      await AudioService.synchronizePlaybackState();
      expect(received, 5);
    },
  );
}
