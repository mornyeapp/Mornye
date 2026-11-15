import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/music_player_runtime.dart';

import 'support/music_player_automix_harness.dart';

void main() {
  setUpMusicPlayerHarness();

  List<String> ids() => [for (final item in handler.queue.value) item.id];

  test('a queued song plays next as a copy, the entry stays', () async {
    await handler.setQueueAndPlay(testTracks);
    final last = handler.queue.value[2];

    expect(await handler.playQueuedItemNext(last), isTrue);

    expect(ids(), ['one', 'three', 'two', 'three']);
    final queue = handler.queue.value;
    expect(queue[3], same(last));
    expect(queue[1], isNot(same(last)));
    expect(queue[1].extras?['source'], last.extras?['source']);
    expect(handler.mediaItem.value?.id, 'one');

    // Removing the copy leaves the entry it came from.
    handler.removeQueuedItem(queue[1]);
    expect(ids(), ['one', 'two', 'three']);
  });

  test(
    'the current song or a song gone from the queue copies nothing',
    () async {
      await handler.setQueueAndPlay(testTracks);
      final current = handler.queue.value.first;
      final gone = handler.queue.value[1];
      handler.removeQueuedItem(gone);

      expect(await handler.playQueuedItemNext(current), isFalse);
      expect(await handler.playQueuedItemNext(gone), isFalse);
      expect(ids(), ['one', 'three']);
    },
  );

  test('with no duplicates on, the song moves up instead', () async {
    musicPlayerRuntime.configure(
      musicPlayerRuntime.settings.copyWith(queueNoDuplicates: true),
    );
    await handler.setQueueAndPlay(testTracks);

    expect(await handler.playQueuedItemNext(handler.queue.value[2]), isTrue);

    expect(ids(), ['one', 'three', 'two']);
  });

  test('a copy of an Autoplay song is the listener\'s own pick', () async {
    setAutoplayEnabled(true);
    await handler.setQueueAndPlay([testTracks.first]);
    await waitUntil(() => handler.queue.value.length == 3);
    final suggestion = handler.queue.value[2];
    expect(suggestion.extras?['autoplay'], isTrue);

    expect(await handler.playQueuedItemNext(suggestion), isTrue);
    final copy = handler.queue.value[1];
    expect(copy.id, suggestion.id);
    expect(copy.extras?['autoplay'], isNull);

    // Turning Autoplay off drops its suggestions, never the copy.
    setAutoplayEnabled(false);
    expect(ids(), ['one', suggestion.id]);
    expect(handler.queue.value[1], same(copy));
  });
}
