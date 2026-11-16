import 'package:audio_service/audio_service.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/music_player_automix_harness.dart';

int get _loads =>
    native.calls.where((call) => call.$2 == 'setSourceUrl').length;

void main() {
  setUpMusicPlayerHarness();

  // Mornye Link Play together loads the song paused at the leader's place,
  // then starts it at an agreed instant.
  test(
    'a song loaded paused starts where it was put, without loading again',
    () async {
      await handler.setQueueAndPlay(
        testTracks,
        initialIndex: 1,
        initialPosition: const Duration(seconds: 18),
        startPaused: true,
      );
      await waitUntil(() => native.sources['music-player'] == '/two.flac');
      expect(native.playing, isEmpty);
      // Paused and ready, as the follower checks before seeking.
      final paused = handler.playbackState.value;
      expect(paused.processingState, AudioProcessingState.ready);
      expect(paused.playing, isFalse);
      expect(paused.position, const Duration(seconds: 18));

      final loads = _loads;
      await handler.play();
      await waitUntil(() => native.playing.contains('music-player'));
      expect(_loads, loads);
      expect(handler.playbackState.value.playing, isTrue);
      expect(
        handler.playbackState.value.position.inMilliseconds,
        inInclusiveRange(18000, 18500),
      );
    },
  );

  test('a seek after a paused load moves where play starts', () async {
    await handler.setQueueAndPlay(testTracks);
    await waitUntil(() => native.playing.contains('music-player'));
    await handler.prepareQueueItem(
      1,
      position: const Duration(milliseconds: 18222),
    );
    await waitUntil(() => native.sources['music-player'] == '/two.flac');
    expect(native.playing, isEmpty);

    await handler.seek(const Duration(milliseconds: 21231));
    final loads = _loads;
    await handler.play();
    await waitUntil(() => native.playing.contains('music-player'));
    expect(_loads, loads);
    expect(native.positions['music-player'], 21231);
    expect(
      handler.playbackState.value.position.inMilliseconds,
      inInclusiveRange(21231, 21731),
    );
  });
}
