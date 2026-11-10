import 'package:audio_service/audio_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/controllers/player_metadata_controller.dart';
import 'package:mornye/services/queue_lyrics_prefetcher.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('QueueLyricsPrefetcher', () {
    test(
      'prefetch caches upcoming track metadata and accelerates load',
      () async {
        var readCalls = 0;
        final controller = PlayerMetadataController(
          readMetadata: (path) async {
            readCalls++;
            return {'lyrics': '[00:01.00]Prefetched lyrics', 'format': 'FLAC'};
          },
        );

        final nextItem = const MediaItem(
          id: 'track_2',
          title: 'Song 2',
          artist: 'Artist 2',
          extras: {'source': '/music/song2.flac'},
        );

        // Pre-fetching loads in background without mutating current controller state
        await controller.prefetch(nextItem);
        expect(readCalls, 1);
        expect(controller.item, isNull);

        // Subsequent load of nextItem uses cached probe without re-reading
        await controller.load(nextItem);
        expect(readCalls, 1);
        expect(controller.lyrics.isEmpty, isFalse);
        expect(controller.lyrics.lines.single.text, 'Prefetched lyrics');
      },
    );

    test(
      'QueueLyricsPrefetcher resolves next item from queue and prefetches it',
      () async {
        final prefetchedItems = <MediaItem>[];
        final prefetcher = QueueLyricsPrefetcher(
          onPrefetch: (item) async {
            prefetchedItems.add(item);
          },
        );

        final queue = [
          const MediaItem(
            id: '1',
            title: 'Song 1',
            extras: {'source': '/1.flac'},
          ),
          const MediaItem(
            id: '2',
            title: 'Song 2',
            extras: {'source': '/2.flac'},
          ),
          const MediaItem(
            id: '3',
            title: 'Song 3',
            extras: {'source': '/3.flac'},
          ),
        ];

        // At index 0, should prefetch index 1 (Song 2)
        prefetcher.updateQueue(queue: queue, currentIndex: 0);
        expect(prefetchedItems.map((i) => i.id).toList(), ['2']);

        // Advance to index 1, should prefetch index 2 (Song 3)
        prefetcher.updateQueue(queue: queue, currentIndex: 1);
        expect(prefetchedItems.map((i) => i.id).toList(), ['2', '3']);

        // At end of queue, does nothing
        prefetcher.updateQueue(queue: queue, currentIndex: 2);
        expect(prefetchedItems.length, 2);
      },
    );
  });
}
