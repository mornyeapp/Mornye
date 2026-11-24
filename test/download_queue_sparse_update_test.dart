import 'dart:collection';
import 'dart:math';
import 'package:mornye/models/download_item.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/download_queue_state.dart';
import 'package:mornye/utils/chunked_list.dart';
import 'package:flutter_test/flutter_test.dart';

class _CountingList<T> extends ListBase<T> {
  _CountingList(this.source);
  final List<T> source;
  int reads = 0;
  @override
  int get length => source.length;
  @override
  set length(int value) => throw UnsupportedError('read only');
  @override
  T operator [](int index) {
    reads++;
    return source[index];
  }

  @override
  void operator []=(int index, T value) => throw UnsupportedError('read only');
}

DownloadItem _item(int index) => DownloadItem(
  id: 'item-$index',
  track: Track(
    id: 'track-${index ~/ 2}',
    name: 'Song',
    artistName: 'Artist',
    albumName: 'Album',
    duration: 1000,
  ),
  service: 'extension.test',
  createdAt: DateTime.utc(2026),
  status: DownloadStatus.downloading,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'active panel membership survives progress and follows status changes',
    () {
      var state = const DownloadQueueState().copyWith(
        items: [
          _item(0),
          _item(1).copyWith(status: DownloadStatus.queued),
          _item(2).copyWith(status: DownloadStatus.finalizing),
          _item(3).copyWith(status: DownloadStatus.failed),
          _item(4).copyWith(status: DownloadStatus.skipped),
          _item(5).copyWith(status: DownloadStatus.completed),
        ],
      );
      final initialIds = state.lookup.activeItemIds;
      expect(initialIds, ['item-0', 'item-1', 'item-2']);
      state = state.withItemReplacements({
        0: state.items[0].copyWith(progress: 0.6),
        1: state.items[1].copyWith(status: DownloadStatus.downloading),
        2: state.items[2].copyWith(status: DownloadStatus.downloading),
      });
      expect(state.lookup.activeItemIds, same(initialIds));
      // Keep the active count unchanged while exchanging two members.
      state = state.withItemReplacements({
        0: state.items[0].copyWith(status: DownloadStatus.failed),
        3: state.items[3].copyWith(status: DownloadStatus.queued),
      });
      expect(state.lookup.activeItemIds, ['item-1', 'item-2', 'item-3']);
      expect(initialIds, ['item-0', 'item-1', 'item-2']);
      final beforeRemoval = state.lookup.activeItemIds;
      state = state.withoutItem('item-4');
      expect(state.lookup.activeItemIds, same(beforeRemoval));
      state = state.withoutItem('item-1');
      expect(state.lookup.activeItemIds, ['item-2', 'item-3']);
      expect(() => state.lookup.activeItemIds.clear(), throwsUnsupportedError);
    },
  );

  test(
    'queued positions span word/chunk boundaries and preserve iterables',
    () {
      final queued = {
        0,
        1,
        30,
        31,
        32,
        33,
        63,
        64,
        65,
        1023,
        1024,
        2047,
        2048,
        2099,
      };
      var state = const DownloadQueueState().copyWith(
        items: [
          for (var i = 0; i < 2100; i++)
            _item(i).copyWith(
              status: queued.contains(i)
                  ? DownloadStatus.queued
                  : DownloadStatus.completed,
            ),
        ],
      );
      final old = state;
      final captured = state.queuedItems;
      final original = state.items
          .where((item) => item.status == DownloadStatus.queued)
          .toList();
      for (final removed in [31, 32, 0, 2048, 2047, 33, 1024, 2099, 500, 64]) {
        state = state.withoutItem('item-$removed');
        expect(
          state.queuedItems,
          state.items.where((item) => item.status == DownloadStatus.queued),
        );
        expect(captured, original);
        expect(old.queuedItems, original);
      }
      final previous = state.items;
      final next = ChunkedList<DownloadItem>.from(previous).updated({
        for (var i = 0; i < previous.length; i++)
          i: previous[i].copyWith(status: DownloadStatus.completed),
      });
      state = state.copyWith(
        items: next,
        lookup: state.lookup.updatedForIndices(
          previousItems: previous,
          nextItems: next,
          changedIndices: List.generate(previous.length * 2, (i) => i ~/ 2),
        ),
      );
      expect(state.queuedItems, isEmpty);
      final restored = ChunkedList<DownloadItem>.from(next).updated({
        for (final i in [31, 32, 63, 64, 2047, 2048])
          i: next[i].copyWith(status: DownloadStatus.queued),
      });
      state = state.copyWith(
        items: restored,
        lookup: state.lookup.updatedForIndices(
          previousItems: next,
          nextItems: restored,
          changedIndices: [2048, 31, 64, 32, 2047, 63],
        ),
      );
      expect(state.queuedItems, [
        for (final i in [31, 32, 63, 64, 2047, 2048]) restored[i],
      ]);
      expect(captured, original);
    },
  );

  test('raw and mismatched queue states keep ordinary status filtering', () {
    final items = [_item(0), _item(1).copyWith(status: DownloadStatus.queued)];
    final raw = DownloadQueueState(items: items);
    expect(raw.queuedItems, [items[1]]);
    final unrelated = DownloadQueueLookup.fromItems([_item(3), _item(4)]);
    final mismatched = DownloadQueueState(items: items, lookup: unrelated);
    expect(mismatched.queuedItems, [items[1]]);
    items[0] = items[0].copyWith(status: DownloadStatus.queued);
    expect(raw.queuedItems, items);
    expect(mismatched.queuedItems, items);
  });

  test(
    'sparse updates preserve snapshots and do not revisit the source list',
    () {
      final source = _CountingList(List.generate(10000, (i) => i));
      final initial = ChunkedList<int>.from(source);
      source.reads = 0;
      var current = initial;
      final expected = List<int>.of(initial);
      final random = Random(42);
      for (var iteration = 0; iteration < 1000; iteration++) {
        final index = random.nextInt(initial.length);
        final previous = current;
        final oldValue = previous[index];
        current = current.updated({index: -iteration - 1});
        expected[index] = -iteration - 1;
        expect(previous[index], oldValue);
      }
      expect(current, expected);
      expect(initial, List.generate(10000, (i) => i));
      expect(source.reads, 0);
      expect(() => current[0] = 1, throwsUnsupportedError);
      expect(() => current.updated({10000: 1}), throwsRangeError);
    },
  );

  test('item replacements preserve queue metadata and immutable snapshots', () {
    final items = List.generate(130, _item);
    const retry = DownloadQueueReconnectRetry(2);
    final initial = const DownloadQueueState(
      isProcessing: true,
      isPaused: true,
      outputDir: '/selected',
      filenameFormat: '{title}',
      singleFilenameFormat: '{artist}',
      audioQuality: 'HIGH',
      autoFallback: false,
      reconnectRetry: retry,
    ).copyWith(items: items, currentDownload: items[1]);
    expect(initial.withItemReplacements({}), same(initial));
    final replacements = {
      63: initial.items[63].copyWith(progress: 0.5),
      64: initial.items[64].copyWith(status: DownloadStatus.failed),
    };
    final next = initial.withItemReplacements(replacements);
    replacements.clear();
    expect(next.items[63].progress, 0.5);
    expect(next.items[64].status, DownloadStatus.failed);
    for (var i = 0; i < items.length; i++) {
      if (i != 63 && i != 64) expect(next.items[i], same(initial.items[i]));
    }
    expect(next.lookup.indexByItemId, same(initial.lookup.indexByItemId));
    expect(next.lookup.itemIds, same(initial.lookup.itemIds));
    expect(
      next.lookup.notCompletedItemIds,
      same(initial.lookup.notCompletedItemIds),
    );
    expect(next.currentDownload, same(initial.currentDownload));
    expect(next.isProcessing, initial.isProcessing);
    expect(next.isPaused, initial.isPaused);
    expect(next.outputDir, initial.outputDir);
    expect(next.filenameFormat, initial.filenameFormat);
    expect(next.singleFilenameFormat, initial.singleFilenameFormat);
    expect(next.audioQuality, initial.audioQuality);
    expect(next.autoFallback, initial.autoFallback);
    expect(next.reconnectRetry, same(retry));
    expect(() => next.items[0] = _item(200), throwsUnsupportedError);
    expect(
      () => initial.withItemReplacements({0: next.items[63], 130: _item(130)}),
      throwsRangeError,
    );
    expect(initial.items, items);
    expect(initial.lookup.byItemId['item-63'], same(items[63]));
    expect(initial.lookup.byItemId['item-64'], same(items[64]));
    expect(initial.items[63].progress, 0);
    expect(initial.items[64].status, DownloadStatus.downloading);
  });

  test(
    'queue indexes match a full rebuild through sparse status transitions',
    () {
      var state = const DownloadQueueState().copyWith(
        items: List.generate(130, _item),
      );
      final original = state;
      final random = Random(17);
      for (var tick = 0; tick < 150; tick++) {
        final index = random.nextInt(state.items.length);
        final old = state;
        state = state.withItemReplacements({
          index: state.items[index].copyWith(
            progress: tick / 150,
            status: DownloadStatus.values[tick % DownloadStatus.values.length],
          ),
        });
        final rebuilt = DownloadQueueLookup.fromItems(state.items);
        expect(state.lookup.byItemId, rebuilt.byItemId);
        expect(state.lookup.byTrackId, rebuilt.byTrackId);
        expect(state.lookup.indexByItemId, rebuilt.indexByItemId);
        expect(state.lookup.itemIds, rebuilt.itemIds);
        expect(state.lookup.queuedCount, rebuilt.queuedCount);
        expect(state.lookup.completedCount, rebuilt.completedCount);
        expect(state.lookup.failedCount, rebuilt.failedCount);
        expect(state.lookup.activeDownloadsCount, rebuilt.activeDownloadsCount);
        expect(state.lookup.finalizingCount, rebuilt.finalizingCount);
        expect(state.lookup.firstDownloading, same(rebuilt.firstDownloading));
        expect(state.lookup.firstFinalizing, same(rebuilt.firstFinalizing));
        expect(
          state.queuedItems,
          state.items.where((item) => item.status == DownloadStatus.queued),
        );
        expect(state.lookup.notCompletedItemIds, rebuilt.notCompletedItemIds);
        expect(state.lookup.activeItemIds, rebuilt.activeItemIds);
        expect(
          old.lookup.byItemId[old.items[index].id],
          same(old.items[index]),
        );
      }
      expect(original.items.every((item) => item.progress == 0), isTrue);
      expect(
        original.lookup.byItemId.values.every((item) => item.progress == 0),
        isTrue,
      );
      expect(() => state.lookup.byItemId.clear(), throwsUnsupportedError);
    },
  );

  test(
    'notification candidates follow batch transitions and keep old values',
    () {
      void check(DownloadQueueState state) {
        expect(
          state.queuedItems,
          state.items.where((item) => item.status == DownloadStatus.queued),
        );
        expect(
          state.lookup.firstDownloading,
          same(
            state.items
                .where((item) => item.status == DownloadStatus.downloading)
                .firstOrNull,
          ),
        );
        expect(
          state.lookup.firstFinalizing,
          same(
            state.items
                .where((item) => item.status == DownloadStatus.finalizing)
                .firstOrNull,
          ),
        );
      }

      var state = const DownloadQueueState().copyWith(
        items: List.generate(200, _item),
      );
      void update(Map<int, DownloadItem> changes) {
        final old = state;
        state = old.withItemReplacements(changes);
        check(state);
        check(old);
      }

      final random = Random(506);
      for (var tick = 0; tick < 300; tick++) {
        update({
          for (var i = 0; i < 7; i++)
            random.nextInt(200): state.items[random.nextInt(200)],
        });
        // Above exercises identity/reordering fallback. Keep IDs stable here to
        // exercise the incremental path with multiple simultaneous transitions.
        final changes = <int, DownloadItem>{};
        for (var i = 0; i < 7; i++) {
          final index = random.nextInt(200);
          changes[index] = state.items[index].copyWith(
            status: DownloadStatus
                .values[random.nextInt(DownloadStatus.values.length)],
            progress: tick / 300,
            track: state.items[index].track.copyWith(name: 'Updated $tick'),
          );
        }
        // Restore unique request IDs after the intentionally malformed batch.
        state = state.copyWith(
          items: [
            for (var i = 0; i < state.items.length; i++)
              state.items[i].copyWith(id: 'item-$i'),
          ],
        );
        update({
          for (final entry in changes.entries)
            entry.key: entry.value.copyWith(id: 'item-${entry.key}'),
        });
      }
      update({
        for (var i = 0; i < state.items.length; i++)
          i: state.items[i].copyWith(status: DownloadStatus.completed),
      });
      expect(state.lookup.firstDownloading, isNull);
      expect(state.lookup.firstFinalizing, isNull);
      update({
        190: state.items[190].copyWith(status: DownloadStatus.downloading),
        195: state.items[195].copyWith(status: DownloadStatus.finalizing),
      });
      update({
        195: state.items[195].copyWith(status: DownloadStatus.downloading),
        190: state.items[190].copyWith(status: DownloadStatus.finalizing),
        1: state.items[1].copyWith(status: DownloadStatus.downloading),
        0: state.items[0].copyWith(status: DownloadStatus.finalizing),
      });
      expect(state.lookup.firstDownloading, same(state.items[1]));
      expect(state.lookup.firstFinalizing, same(state.items[0]));
      update({
        0: state.items[0].copyWith(status: DownloadStatus.completed),
        1: state.items[1].copyWith(status: DownloadStatus.completed),
      });
      expect(state.lookup.firstDownloading, same(state.items[195]));
      expect(state.lookup.firstFinalizing, same(state.items[190]));
      check(const DownloadQueueState());
    },
  );
}
