import 'dart:io';

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

    test('a missing current track is skipped automatically', () async {
      final directory = await Directory.systemTemp.createTemp(
        'missing-current-track-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final missing = PlayableMedia(
        id: 'missing',
        source: '${directory.path}/removed.flac',
        title: 'Missing',
        artist: 'Artist',
      );

      await handler.setQueueAndPlay([missing, _tracks[1]]);
      await native.error(
        'music-player',
        message: 'Cannot open file: Audio file is unavailable',
      );

      await _until(
        () =>
            handler.mediaItem.value?.id == 'two' &&
            handler.playbackState.value.playing,
      );
      expect(handler.queue.value.map((item) => item.id), ['two']);
      expect(handler.playbackState.value.errorMessage, isNull);
      expect(native.resumedSources, contains('/two.flac'));
    });

    test(
      'a missing track later in the queue is skipped to the next song',
      () async {
      final directory = await Directory.systemTemp.createTemp(
        'missing-queued-track-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final missing = PlayableMedia(
        id: 'missing',
        source: '${directory.path}/removed.flac',
        title: 'Missing',
        artist: 'Artist',
      );
      await handler.setQueueAndPlay([_tracks[0], missing, _tracks[2]]);
      await native.complete('music-player');
      await _until(
        () =>
            handler.mediaItem.value?.id == 'missing' &&
            handler.playbackState.value.playing,
      );

      await native.error(
        'music-player',
        message: 'Cannot open file: Audio file is unavailable',
      );
      await _until(
        () =>
            handler.mediaItem.value?.id == 'three' &&
            handler.playbackState.value.playing,
      );

      expect(handler.queue.value.map((item) => item.id), ['one', 'three']);
      expect(handler.playbackState.value.queueIndex, 1);
      expect(handler.playbackState.value.errorMessage, isNull);
    });

    test('a missing only track stops and clears the player cleanly', () async {
      final directory = await Directory.systemTemp.createTemp(
        'missing-only-track-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final missing = PlayableMedia(
        id: 'missing',
        source: '${directory.path}/removed.flac',
        title: 'Missing',
        artist: 'Artist',
      );

      await handler.setQueueAndPlay([missing]);
      await native.error(
        'music-player',
        message: 'Cannot open file: Audio file is unavailable',
      );
      await _until(() => handler.mediaItem.value == null);

      expect(handler.queue.value, isEmpty);
      expect(handler.playbackState.value.playing, isFalse);
      expect(native.playing, isEmpty);
    });

    test('a permission error is not treated as a missing track', () async {
      final directory = await Directory.systemTemp.createTemp(
        'inaccessible-track-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final file = await File('${directory.path}/song.flac').writeAsString(
        'audio',
      );
      final track = PlayableMedia(
        id: 'protected',
        source: file.path,
        title: 'Protected',
        artist: 'Artist',
      );

      await handler.setQueueAndPlay([track, _tracks[1]]);
      await native.error(
        'music-player',
        message: 'Cannot open file: Permission denied',
      );
      await _until(
        () =>
            handler.playbackState.value.processingState ==
            AudioProcessingState.error,
      );

      expect(handler.mediaItem.value?.id, 'protected');
      expect(handler.queue.value.map((item) => item.id), [
        'protected',
        'two',
      ]);
      expect(handler.playbackState.value.playing, isFalse);
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
