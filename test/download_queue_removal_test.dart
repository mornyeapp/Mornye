import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/download_item.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/download_queue_state.dart';
import 'package:mornye/utils/chunked_list.dart';

DownloadItem _item(int i, {String? requestId}) => DownloadItem(
  id: requestId ?? 'request-$i',
  track: Track(
    id: 'track-${i % 41}',
    name: 'Track $i',
    artistName: 'Artist',
    albumName: 'Album',
    duration: 180,
  ),
  service: 'example.audio',
  createdAt: DateTime.utc(2026),
  status: DownloadStatus.values[i % DownloadStatus.values.length],
);

void _check(DownloadQueueState state) {
  final expected = DownloadQueueLookup.fromItems(state.items);
  final actual = state.lookup;
  expect(actual.byItemId.keys.toList(), expected.byItemId.keys.toList());
  expect(actual.byTrackId.keys.toList(), expected.byTrackId.keys.toList());
  expect(actual.byItemId, expected.byItemId);
  expect(actual.byTrackId, expected.byTrackId);
  expect(actual.indexByItemId, expected.indexByItemId);
  expect(
    actual.indexByItemId.keys.toList(),
    expected.indexByItemId.keys.toList(),
  );
  expect(actual.itemIds, expected.itemIds);
  expect(actual.notCompletedItemIds, expected.notCompletedItemIds);
  expect(actual.activeItemIds, expected.activeItemIds);
  expect(actual.queuedCount, expected.queuedCount);
  expect(actual.completedCount, expected.completedCount);
  expect(actual.failedCount, expected.failedCount);
  expect(actual.activeDownloadsCount, expected.activeDownloadsCount);
  expect(actual.finalizingCount, expected.finalizingCount);
  expect(
    state.queuedItems,
    state.items.where((item) => item.status == DownloadStatus.queued),
  );
  for (final entry in {
    DownloadStatus.downloading: actual.firstDownloading,
    DownloadStatus.finalizing: actual.firstFinalizing,
  }.entries) {
    expect(
      entry.value,
      same(state.items.where((item) => item.status == entry.key).firstOrNull),
    );
  }
  expect(actual.byItemId['absent'], isNull);
  expect(actual.byTrackId['absent'], isNull);
  expect(actual.indexByItemId['absent'], isNull);
}

void main() {
  for (final order in ['front', 'back', 'middle', 'random']) {
    test('$order removals preserve indexes through updates and rebases', () {
      final random = Random(117);
      var state = const DownloadQueueState(
        isPaused: true,
        outputDir: '/output',
      ).copyWith(items: List.generate(270, _item));
      final original = state;
      for (var tick = 0; state.items.isNotEmpty; tick++) {
        final index = switch (order) {
          'front' => 0,
          'back' => state.items.length - 1,
          'middle' => state.items.length ~/ 2,
          _ => random.nextInt(state.items.length),
        };
        final old = state;
        final before = List<DownloadItem>.of(old.items);
        final id = state.items[index].id;
        state = state.withoutItem(id);
        expect(state.items, before.where((item) => item.id != id));
        expect(old.items, before);
        _check(old);
        _check(state);
        expect(state.isPaused, true);
        expect(state.outputDir, '/output');
        expect(state.withoutItem('absent'), same(state));
        if (state.items.isNotEmpty && tick % 3 == 0) {
          final changed = random.nextInt(state.items.length);
          state = state.withItemReplacements({
            changed: state.items[changed].copyWith(
              status: DownloadStatus.values[random.nextInt(6)],
              progress: tick / 270,
            ),
          });
          _check(state);
        }
      }
      expect(original.items.length, 270);
      _check(original);
    });
  }

  test(
    'removal after append, reordering and track identity change rebases',
    () {
      var state = const DownloadQueueState().copyWith(
        items: List.generate(150, _item),
      );
      for (var i = 0; i < 100; i++) {
        state = state.withoutItem(state.items[i % state.items.length].id);
        if (i % 7 == 0) {
          state = state.copyWith(
            items: [...state.items.reversed, _item(200 + i)],
          );
        }
        if (i % 9 == 0) {
          final next = ChunkedList<DownloadItem>.from(state.items).updated({
            0: state.items.first.copyWith(track: _item(1000 + i).track),
          });
          state = state.copyWith(
            items: next,
            lookup: state.lookup.updatedForIndices(
              previousItems: state.items,
              nextItems: next,
              changedIndices: [0],
            ),
          );
        }
        _check(state);
      }
    },
  );

  test(
    'duplicate request IDs remove all occurrences, including raw states',
    () {
      for (final raw in [true, false]) {
        final items = [
          _item(0, requestId: 'same'),
          _item(1),
          _item(2, requestId: 'same'),
        ];
        final initial = raw
            ? DownloadQueueState(items: items)
            : const DownloadQueueState().copyWith(items: items);
        final next = initial.withoutItem('same');
        expect(next.items, [items[1]]);
        _check(next);
        expect(initial.items, items);
      }
    },
  );

  test(
    'removed indexes and IDs stay immutable and keep old snapshots alive',
    () {
      final old = const DownloadQueueState().copyWith(
        items: List.generate(80, _item),
      );
      final state = old.withoutItem('request-0');
      expect(() => state.lookup.byItemId.clear(), throwsUnsupportedError);
      expect(
        () => state.lookup.byTrackId['new'] = _item(500),
        throwsUnsupportedError,
      );
      expect(
        () => state.lookup.indexByItemId.remove('request-1'),
        throwsUnsupportedError,
      );
      expect(
        () => state.lookup.indexByItemId['request-1'] = 20,
        throwsUnsupportedError,
      );
      expect(() => state.lookup.itemIds[0] = 'bad', throwsUnsupportedError);
      expect(() => state.lookup.itemIds.add('bad'), throwsUnsupportedError);
      expect(() => state.items[0] = _item(500), throwsUnsupportedError);
      _check(old);
      _check(state);
    },
  );
}
