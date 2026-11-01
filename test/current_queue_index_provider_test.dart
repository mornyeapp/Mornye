import 'package:audio_service/audio_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/providers/music_player_provider.dart';

Future<int> _index(List<String> ids, String? current, int? reported) async {
  final queue = [for (final id in ids) MediaItem(id: id, title: id)];
  final container = ProviderContainer(
    overrides: [
      playQueueProvider.overrideWith((ref) => Stream.value(queue)),
      currentMediaItemProvider.overrideWithBuild(
        (ref, notifier) => Stream.value(
          current == null ? null : MediaItem(id: current, title: current),
        ),
      ),
      playbackStateProvider.overrideWith(
        (ref) => Stream.value(PlaybackState(queueIndex: reported)),
      ),
    ],
  );
  addTearDown(container.dispose);
  final subscription = container.listen(currentQueueIndexProvider, (_, _) {});
  await container.read(playQueueProvider.future);
  await container.read(currentMediaItemProvider.future);
  await container.read(playbackStateProvider.future);
  return subscription.read();
}

void main() {
  test('reported index wins only while it names the current item', () async {
    // A repeated track keeps the reported copy.
    expect(await _index(['a', 'b', 'a'], 'a', 2), 2);
    // Shuffle or a stale report falls back to the first match.
    expect(await _index(['a', 'b', 'c'], 'c', 0), 2);
    expect(await _index(['a', 'b', 'c'], 'b', 7), 1);
    expect(await _index(['a', 'b', 'c'], 'b', -1), 1);
    expect(await _index(['a', 'b', 'c'], 'b', null), 1);
    expect(await _index(['a', 'b'], 'x', 1), -1);
    expect(await _index([], 'a', 0), -1);
    expect(await _index(['a'], null, 0), -1);
  });
}
