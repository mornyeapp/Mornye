import 'package:audio_service/audio_service.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/music_player_automix_harness.dart';

const _tracks = testTracks;
const _until = waitUntil;

void main() {
  setUpMusicPlayerHarness();

  group('playback failures', () {
    test('runtime error stays on the song and Play retries it', () async {
      await handler.setQueueAndPlay(_tracks);
      await native.error('music-player');
      await _until(
        () =>
            handler.playbackState.value.processingState ==
                AudioProcessingState.error &&
            native.playing.isEmpty,
      );
      expect(handler.playbackState.value.playing, isFalse);
      expect(
        handler.playbackState.value.errorMessage,
        contains('Audio output'),
      );
      expect(handler.mediaItem.value?.id, 'one');

      // Even a late completion from a failed output must not advance the queue.
      await native.event('music-player', 'audio.onComplete');
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(handler.playbackState.value.queueIndex, 0);
      expect(
        handler.playbackState.value.processingState,
        AudioProcessingState.error,
      );

      await handler.play();
      expect(handler.playbackState.value.playing, isTrue);
      expect(handler.playbackState.value.errorMessage, isNull);
      expect(handler.playbackState.value.errorCode, isNull);
      expect(native.resumedSources, ['/one.flac', '/one.flac']);
      await native.event('music-player', 'audio.onComplete');
      await _until(() => handler.playbackState.value.queueIndex == 1);
    });

    test('a media server crash plays the song again by itself', () async {
      const died = 'MEDIA_ERROR_SERVER_DIED, MEDIA_ERROR_UNKNOWN {extra:1}';
      await handler.setQueueAndPlay(_tracks);
      for (var reload = 1; reload <= 2; reload++) {
        await native.error('music-player', details: died);
        await _until(() => native.resumedSources.length == reload + 1);
        expect(handler.playbackState.value.errorMessage, isNull);
        expect(handler.playbackState.value.playing, isTrue);
        expect(handler.mediaItem.value?.id, 'one');
      }

      // A server that keeps dying fails the song as before.
      await native.error('music-player', details: died);
      await _until(
        () =>
            handler.playbackState.value.processingState ==
            AudioProcessingState.error,
      );
      expect(handler.playbackState.value.playing, isFalse);
      expect(native.resumedSources, hasLength(3));
    });

    test('source failure is reported and can be retried', () async {
      native.sourceFailures.add('/one.flac');
      await handler.setQueueAndPlay(_tracks);
      expect(
        handler.playbackState.value.processingState,
        AudioProcessingState.error,
      );
      expect(handler.playbackState.value.playing, isFalse);
      expect(handler.playbackState.value.queueIndex, 0);
      expect(native.resumedSources, isEmpty);

      native.sourceFailures.clear();
      await handler.play();
      expect(handler.playbackState.value.playing, isTrue);
      expect(handler.mediaItem.value?.id, 'one');
      expect(handler.playbackState.value.errorMessage, isNull);
    });

    test('error during resume cannot be overwritten by ready state', () async {
      native.resumeFailures.add('music-player');
      await handler.setQueueAndPlay(_tracks);
      await _until(
        () =>
            handler.playbackState.value.processingState ==
            AudioProcessingState.error,
      );
      expect(handler.playbackState.value.playing, isFalse);
      expect(handler.playbackState.value.queueIndex, 0);
      native.resumeFailures.clear();
      await handler.skipToNext();
      expect(handler.mediaItem.value?.id, 'two');
      expect(handler.playbackState.value.playing, isTrue);
      expect(handler.playbackState.value.errorMessage, isNull);
    });

    test(
      'failed resume from pause reports an error without throwing',
      () async {
        await handler.setQueueAndPlay(_tracks);
        await handler.pause();
        native.resumeFailures.add('music-player');
        await handler.play();
        await _until(
          () =>
              handler.playbackState.value.processingState ==
              AudioProcessingState.error,
        );
        expect(
          handler.playbackState.value.processingState,
          AudioProcessingState.error,
        );
        expect(handler.playbackState.value.playing, isFalse);
        expect(handler.mediaItem.value?.id, 'one');
        native.resumeFailures.clear();
        await handler.play();
        expect(handler.playbackState.value.playing, isTrue);
        expect(handler.playbackState.value.errorMessage, isNull);
      },
    );

    test('resume method failure is reported without escaping Play', () async {
      await handler.setQueueAndPlay(_tracks);
      await handler.pause();
      native.failResumeMethod = true;
      await handler.play();
      expect(
        handler.playbackState.value.processingState,
        AudioProcessingState.error,
      );
      expect(handler.playbackState.value.playing, isFalse);
      native.failResumeMethod = false;
      await handler.play();
      expect(handler.playbackState.value.playing, isTrue);
    });
  });
}
