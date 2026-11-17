import 'package:audio_service/audio_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/link/link_protocol.dart';
import 'package:mornye/services/link/together/link_together_deck.dart';
import 'package:mornye/services/link/together/link_together_protocol.dart';

void main() {
  const first = MediaItem(
    id: 'one',
    title: 'One',
    duration: Duration(seconds: 200),
  );
  const second = MediaItem(
    id: 'two',
    title: 'Two',
    duration: Duration(seconds: 180),
  );

  LinkTogetherReport report(PlaybackState state, {MediaItem? current}) =>
      LinkRuntimeTogetherDeck.reportOf(
        state: state,
        queue: const [first, second],
        current: current ?? first,
        nowMs: 1000,
        refFor: (item) => TrackRef(title: item.title, artist: 'Artist'),
      );

  group('The Play together report of the app player', () {
    test('a paused song reports where it stands', () {
      final paused = report(
        PlaybackState(
          processingState: AudioProcessingState.ready,
          updatePosition: const Duration(seconds: 42),
          queueIndex: 0,
        ),
      );

      expect(paused.playing, isFalse);
      expect(paused.ready, isTrue);
      expect(paused.positionMs, 42000);
      expect(paused.durationMs, 200000);
      expect(paused.index, 0);
    });

    // A real run (2026-11-17): the state of a song that ran out carried a
    // position well before its end, and the phone took the next song for
    // one picked by hand.
    test('a song that ran out reports its end, whatever was read last', () {
      final ended = report(
        PlaybackState(
          processingState: AudioProcessingState.completed,
          updatePosition: const Duration(seconds: 190),
          queueIndex: 0,
        ),
      );

      expect(ended.playing, isFalse);
      expect(ended.ready, isFalse);
      expect(ended.positionMs, 200000);
      expect(ended.remainingAt(1000), 0);
    });

    test('a song that ran out without a known length keeps its position', () {
      final ended = report(
        PlaybackState(
          processingState: AudioProcessingState.completed,
          updatePosition: const Duration(seconds: 190),
          queueIndex: 0,
        ),
        current: const MediaItem(id: 'one', title: 'One'),
      );

      expect(ended.positionMs, 190000);
      expect(ended.durationMs, isNull);
    });

    test('the entry follows the current song when the index is behind', () {
      final moved = report(
        PlaybackState(
          processingState: AudioProcessingState.ready,
          playing: true,
          queueIndex: 0,
        ),
        current: second,
      );

      expect(moved.index, 1);
      expect(moved.track?.title, 'Two');
      expect(moved.durationMs, 180000);
    });
  });
}
