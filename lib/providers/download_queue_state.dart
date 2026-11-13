import 'dart:collection';

import 'package:mornye/models/download_item.dart';
import 'package:mornye/utils/chunked_list.dart';

/// Shares the stable key-to-position index across progress snapshots. Values
/// come from the current immutable items, so old lookups keep their old values.
class _IndexedQueueMap extends MapBase<String, DownloadItem> {
  _IndexedQueueMap(this.index, this.items);
  final Map<String, int> index;
  final List<DownloadItem> items;

  @override
  DownloadItem? operator [](Object? key) {
    final position = index[key];
    return position == null ? null : items[position];
  }

  @override
  Iterable<String> get keys => index.keys;

  @override
  int get length => index.length;

  @override
  bool containsKey(Object? key) => index.containsKey(key);

  @override
  void operator []=(String key, DownloadItem value) =>
      throw UnsupportedError('Immutable queue lookup');

  @override
  void clear() => throw UnsupportedError('Immutable queue lookup');

  @override
  DownloadItem? remove(Object? key) =>
      throw UnsupportedError('Immutable queue lookup');
}

/// Positions in one stable index snapshot, with at most 64 deleted positions.
/// Rebase periodically instead of retaining a chain of previous queue states.
class _QueueRemovals {
  _QueueRemovals(this.positions);
  final List<int> positions;

  _QueueRemovals removing(int currentIndex) {
    var original = currentIndex;
    var insertion = 0;
    while (insertion < positions.length && positions[insertion] <= original) {
      original++;
      insertion++;
    }
    return _QueueRemovals([...positions]..insert(insertion, original));
  }

  int? currentIndex(int original) {
    var start = 0;
    var end = positions.length;
    while (start < end) {
      final middle = (start + end) ~/ 2;
      if (positions[middle] < original) {
        start = middle + 1;
      } else {
        end = middle;
      }
    }
    if (start < positions.length && positions[start] == original) return null;
    return original - start;
  }
}

class _RemovedQueueIndex extends MapBase<String, int> {
  _RemovedQueueIndex({
    required this.base,
    required this.removals,
    required this.items,
    required this.length,
    this.firstTrackPositions = const {},
    this.byTrack = false,
  });
  final Map<String, int> base;
  final _QueueRemovals removals;
  final List<DownloadItem> items;
  final Map<String, int> firstTrackPositions;
  final bool byTrack;
  @override
  final int length;

  @override
  int? operator [](Object? key) {
    final original = firstTrackPositions[key] ?? base[key];
    return original == null ? null : removals.currentIndex(original);
  }

  @override
  Iterable<String> get keys sync* {
    // Track order follows its first surviving occurrence, including duplicates
    // whose first request was removed. No sorting or index rebuilding on write.
    final seen = byTrack ? <String>{} : null;
    for (final item in items) {
      final key = byTrack ? item.track.id : item.id;
      if (seen == null || seen.add(key)) yield key;
    }
  }

  @override
  bool containsKey(Object? key) => this[key] != null;
  @override
  void operator []=(String key, int value) =>
      throw UnsupportedError('Immutable queue index');
  @override
  void clear() => throw UnsupportedError('Immutable queue index');
  @override
  int? remove(Object? key) => throw UnsupportedError('Immutable queue index');
}

class _QueueItemIds extends ListBase<String> {
  _QueueItemIds(this.items);
  final List<DownloadItem> items;
  @override
  int get length => items.length;
  @override
  String operator [](int index) => items[index].id;
  @override
  set length(int value) => throw UnsupportedError('Immutable queue IDs');
  @override
  void operator []=(int index, String value) =>
      throw UnsupportedError('Immutable queue IDs');
}

/// One bit per queued position. Sparse status changes copy only the affected
/// word chunks; progress-only updates share the index. This also skips gaps
/// between candidates without rescanning DownloadItem objects during launch.
class _QueuedPositions {
  const _QueuedPositions.empty() : words = const [], firstWord = -1;
  _QueuedPositions._(this.words, this.firstWord);
  final List<int> words;
  final int firstWord;

  factory _QueuedPositions.fromWords(List<int> words) =>
      _QueuedPositions._(ChunkedList<int>.from(words), _findFirst(words, 0));

  static int _findFirst(List<int> words, int start) {
    for (var index = start; index < words.length; index++) {
      if (words[index] != 0) return index;
    }
    return -1;
  }

  Iterable<int> get indices sync* {
    if (firstWord < 0) return;
    for (var index = firstWord; index < words.length; index++) {
      var remaining = words[index];
      while (remaining != 0) {
        final lowestBit = remaining & -remaining;
        yield (index << 5) + lowestBit.bitLength - 1;
        remaining ^= lowestBit;
      }
    }
  }

  _QueuedPositions updated(
    List<DownloadItem> previousItems,
    List<DownloadItem> nextItems,
    Set<int> changedIndices,
  ) {
    Map<int, int>? changes;
    for (final index in changedIndices) {
      final wasQueued = previousItems[index].status == DownloadStatus.queued;
      final isQueued = nextItems[index].status == DownloadStatus.queued;
      if (wasQueued == isQueued) continue;
      changes ??= {};
      final word = index >> 5;
      final bit = 1 << (index & 31);
      final value = changes[word] ?? words[word];
      changes[word] = isQueued ? value | bit : value & ~bit;
    }
    if (changes == null) return this;
    final next = ChunkedList<int>.from(words).updated(changes);
    var first = firstWord;
    for (final entry in changes.entries) {
      if (entry.value != 0 && (first < 0 || entry.key < first)) {
        first = entry.key;
      }
    }
    if (first >= 0 && next[first] == 0) first = _findFirst(next, first + 1);
    return _QueuedPositions._(next, first);
  }

  _QueuedPositions removing(int index, int nextLength) {
    final shifted = List<int>.of(words);
    final first = index >> 5;
    for (var word = first; word < words.length; word++) {
      final lowMask = word == first ? (1 << (index & 31)) - 1 : 0;
      final carry = word + 1 < words.length ? (words[word + 1] & 1) << 31 : 0;
      shifted[word] =
          (words[word] & lowMask) | ((words[word] >> 1) & ~lowMask) | carry;
    }
    if (shifted.length > ((nextLength + 31) >> 5)) shifted.removeLast();
    return _QueuedPositions.fromWords(shifted);
  }
}

/// Immutable queue state shared by the notifier and read-only UI consumers.
///
/// Keeping this model outside the notifier implementation makes queue state
/// transitions testable without importing the download orchestration pipeline.
class DownloadQueueState {
  static const Object _noChange = Object();

  final List<DownloadItem> items;
  final DownloadQueueLookup lookup;
  final DownloadItem? currentDownload;
  final bool isProcessing;
  final bool isPaused;
  final String outputDir;
  final String filenameFormat;
  final String singleFilenameFormat;
  final String audioQuality;
  final bool autoFallback;
  final DownloadQueueReconnectRetry? reconnectRetry;

  const DownloadQueueState({
    this.items = const [],
    this.lookup = const DownloadQueueLookup.empty(),
    this.currentDownload,
    this.isProcessing = false,
    this.isPaused = false,
    this.outputDir = '',
    this.filenameFormat = '{artist} - {title}',
    this.singleFilenameFormat = '{title} - {artist}',
    this.audioQuality = 'LOSSLESS',
    this.autoFallback = true,
    this.reconnectRetry,
  });

  DownloadQueueState copyWith({
    List<DownloadItem>? items,
    DownloadQueueLookup? lookup,
    Object? currentDownload = _noChange,
    bool? isProcessing,
    bool? isPaused,
    String? outputDir,
    String? filenameFormat,
    String? singleFilenameFormat,
    String? audioQuality,
    bool? autoFallback,
    Object? reconnectRetry = _noChange,
  }) {
    final resolvedItems = items == null
        ? this.items
        : ChunkedList<DownloadItem>.from(items);
    return DownloadQueueState(
      items: resolvedItems,
      lookup:
          lookup ??
          (items != null
              ? DownloadQueueLookup.fromItems(resolvedItems)
              : this.lookup),
      currentDownload: identical(currentDownload, _noChange)
          ? this.currentDownload
          : currentDownload as DownloadItem?,
      isProcessing: isProcessing ?? this.isProcessing,
      isPaused: isPaused ?? this.isPaused,
      outputDir: outputDir ?? this.outputDir,
      filenameFormat: filenameFormat ?? this.filenameFormat,
      singleFilenameFormat: singleFilenameFormat ?? this.singleFilenameFormat,
      audioQuality: audioQuality ?? this.audioQuality,
      autoFallback: autoFallback ?? this.autoFallback,
      reconnectRetry: identical(reconnectRetry, _noChange)
          ? this.reconnectRetry
          : reconnectRetry as DownloadQueueReconnectRetry?,
    );
  }

  int get queuedCount => items.isEmpty ? 0 : lookup.queuedCount;
  int get completedCount => items.isEmpty ? 0 : lookup.completedCount;
  int get failedCount => items.isEmpty ? 0 : lookup.failedCount;
  int get activeDownloadsCount =>
      items.isEmpty ? 0 : lookup.activeDownloadsCount;

  /// Ordered candidates from this snapshot. Raw/custom states without a
  /// matching immutable lookup retain the ordinary status-filter behavior.
  Iterable<DownloadItem> get queuedItems => identical(items, lookup._items)
      ? lookup._queuedPositions.indices.map((index) => items[index])
      : items.where((item) => item.status == DownloadStatus.queued);

  /// Replaces items and updates their lookup from this same queue snapshot.
  DownloadQueueState withItemReplacements(Map<int, DownloadItem> replacements) {
    if (replacements.isEmpty) return this;
    final nextItems = ChunkedList<DownloadItem>.from(
      items,
    ).updated(replacements);
    return copyWith(
      items: nextItems,
      lookup: lookup.updatedForIndices(
        previousItems: items,
        nextItems: nextItems,
        changedIndices: replacements.keys,
      ),
    );
  }

  DownloadQueueState withoutItem(String id) {
    final index = lookup.indexByItemId[id];
    if (lookup.indexByItemId.length != items.length ||
        (index != null && items[index].id != id)) {
      // Raw states and duplicate request IDs retain the original remove-all
      // behavior. Normally the notifier always supplies unique indexed items.
      return copyWith(items: items.where((item) => item.id != id).toList());
    }
    if (index == null) return this;
    final nextItems = ChunkedList<DownloadItem>.from(
      List<DownloadItem>.of(items)..removeAt(index),
    );
    return copyWith(
      items: nextItems,
      lookup: lookup.withoutIndex(items, nextItems, index),
    );
  }
}

/// A transient queue effect. Consumers listen for new instances so progress
/// snapshots and mounting a screen cannot replay an earlier retry prompt.
class DownloadQueueReconnectRetry {
  const DownloadQueueReconnectRetry(this.failedCount);

  final int failedCount;
}

/// Precomputed queue indexes and counters.
///
/// Stable identity indexes are shared across progress snapshots. Sparse item
/// changes copy only affected storage chunks rather than two entire maps.
class DownloadQueueLookup {
  final Map<String, DownloadItem> byTrackId;
  final Map<String, DownloadItem> byItemId;
  final Map<String, int> indexByItemId;
  final List<String> itemIds;
  final List<String> notCompletedItemIds;

  /// Waiting, downloading and finalizing rows, in queue order. Progress-only
  /// snapshots share this list so panels can watch membership separately.
  final List<String> activeItemIds;
  final int queuedCount;
  final int completedCount;
  final int failedCount;
  final int activeDownloadsCount;
  final int finalizingCount;
  final List<DownloadItem> _items;
  final int? _firstDownloadingIndex;
  final int? _firstFinalizingIndex;
  final _QueuedPositions _queuedPositions;
  final Map<String, List<int>>? _duplicateTrackPositions;

  DownloadItem? get firstDownloading =>
      _firstDownloadingIndex == null ? null : _items[_firstDownloadingIndex];
  DownloadItem? get firstFinalizing =>
      _firstFinalizingIndex == null ? null : _items[_firstFinalizingIndex];

  const DownloadQueueLookup.empty()
    : byTrackId = const {},
      byItemId = const {},
      indexByItemId = const {},
      itemIds = const [],
      notCompletedItemIds = const [],
      activeItemIds = const [],
      queuedCount = 0,
      completedCount = 0,
      failedCount = 0,
      activeDownloadsCount = 0,
      finalizingCount = 0,
      _items = const [],
      _firstDownloadingIndex = null,
      _firstFinalizingIndex = null,
      _queuedPositions = const _QueuedPositions.empty(),
      _duplicateTrackPositions = null;

  DownloadQueueLookup._({
    required this.byTrackId,
    required this.byItemId,
    required this.indexByItemId,
    required this.itemIds,
    required this.notCompletedItemIds,
    required this.activeItemIds,
    required this.queuedCount,
    required this.completedCount,
    required this.failedCount,
    required this.activeDownloadsCount,
    required this.finalizingCount,
    required List<DownloadItem> items,
    required int? firstDownloadingIndex,
    required int? firstFinalizingIndex,
    required _QueuedPositions queuedPositions,
    Map<String, List<int>>? duplicateTrackPositions,
  }) : _items = items,
       _firstDownloadingIndex = firstDownloadingIndex,
       _firstFinalizingIndex = firstFinalizingIndex,
       _queuedPositions = queuedPositions,
       _duplicateTrackPositions = duplicateTrackPositions;

  static int? _firstAfterRemoval(
    int? first,
    int removedIndex,
    DownloadStatus status,
    int count,
    List<DownloadItem> nextItems,
  ) {
    if (first == null) return null;
    if (first < removedIndex) return first;
    if (first > removedIndex) return first - 1;
    if (count > 1) {
      for (var index = removedIndex; index < nextItems.length; index++) {
        if (nextItems[index].status == status) return index;
      }
    }
    return null;
  }

  // Progress-only snapshots retain the first positions. Search beyond an old
  // first item only when it leaves the status, not on every native sample.
  static int? _firstAfterUpdates(
    int? first,
    DownloadStatus status,
    int count,
    List<DownloadItem> nextItems,
    Set<int> changedIndices,
  ) {
    if (count == 0) return null;
    for (final index in changedIndices) {
      if ((first == null || index < first) &&
          nextItems[index].status == status) {
        first = index;
      }
    }
    if (first == null || nextItems[first].status == status) return first;
    for (var index = first + 1; index < nextItems.length; index++) {
      if (nextItems[index].status == status) return index;
    }
    return null;
  }

  DownloadQueueLookup withoutIndex(
    List<DownloadItem> previousItems,
    List<DownloadItem> nextItems,
    int index,
  ) {
    final previousIndex = indexByItemId;
    final previousRemovals = previousIndex is _RemovedQueueIndex
        ? previousIndex.removals
        : _QueueRemovals(const []);
    if (previousRemovals.positions.length >= 64 ||
        byTrackId is! _IndexedQueueMap ||
        nextItems.isEmpty) {
      return DownloadQueueLookup.fromItems(nextItems);
    }
    final removals = previousRemovals.removing(index);
    final removed = previousItems[index];
    final trackIndex = (byTrackId as _IndexedQueueMap).index;
    final replacements = trackIndex is _RemovedQueueIndex
        ? Map<String, int>.of(trackIndex.firstTrackPositions)
        : <String, int>{};
    final duplicates = _duplicateTrackPositions ?? <String, List<int>>{};
    if (_duplicateTrackPositions == null &&
        byTrackId.length < previousItems.length) {
      for (var i = 0; i < previousItems.length; i++) {
        final key = previousItems[i].track.id;
        final first = trackIndex[key]!;
        if (i != first) duplicates.putIfAbsent(key, () => [first]).add(i);
      }
    }
    var trackCount = byTrackId.length;
    if (trackIndex[removed.track.id] == index) {
      final next = duplicates[removed.track.id]
          ?.where((position) => removals.currentIndex(position) != null)
          .firstOrNull;
      if (next == null) {
        trackCount--;
      } else {
        replacements[removed.track.id] = next;
      }
    }
    final itemIndex = _RemovedQueueIndex(
      base: previousIndex is _RemovedQueueIndex
          ? previousIndex.base
          : previousIndex,
      removals: removals,
      items: nextItems,
      length: nextItems.length,
    );
    return DownloadQueueLookup._(
      byTrackId: _IndexedQueueMap(
        _RemovedQueueIndex(
          base: trackIndex is _RemovedQueueIndex ? trackIndex.base : trackIndex,
          removals: removals,
          items: nextItems,
          length: trackCount,
          firstTrackPositions: replacements,
          byTrack: true,
        ),
        nextItems,
      ),
      byItemId: _IndexedQueueMap(itemIndex, nextItems),
      indexByItemId: itemIndex,
      itemIds: _QueueItemIds(nextItems),
      notCompletedItemIds: removed.status == DownloadStatus.completed
          ? notCompletedItemIds
          : List.unmodifiable(
              notCompletedItemIds.where((id) => id != removed.id),
            ),
      activeItemIds: _countsAsQueued(removed.status)
          ? List.unmodifiable(activeItemIds.where((id) => id != removed.id))
          : activeItemIds,
      queuedCount: queuedCount - (_countsAsQueued(removed.status) ? 1 : 0),
      completedCount:
          completedCount - (removed.status == DownloadStatus.completed ? 1 : 0),
      failedCount:
          failedCount - (removed.status == DownloadStatus.failed ? 1 : 0),
      activeDownloadsCount:
          activeDownloadsCount -
          (removed.status == DownloadStatus.downloading ? 1 : 0),
      finalizingCount:
          finalizingCount -
          (removed.status == DownloadStatus.finalizing ? 1 : 0),
      items: nextItems,
      firstDownloadingIndex: _firstAfterRemoval(
        _firstDownloadingIndex,
        index,
        DownloadStatus.downloading,
        activeDownloadsCount,
        nextItems,
      ),
      firstFinalizingIndex: _firstAfterRemoval(
        _firstFinalizingIndex,
        index,
        DownloadStatus.finalizing,
        finalizingCount,
        nextItems,
      ),
      queuedPositions: _queuedPositions.removing(index, nextItems.length),
      duplicateTrackPositions: duplicates,
    );
  }

  factory DownloadQueueLookup.fromItems(List<DownloadItem> items) {
    final byTrackIndex = <String, int>{};
    final indexByItemId = <String, int>{};
    final itemIds = <String>[];
    final notCompletedItemIds = <String>[];
    final activeItemIds = <String>[];
    var queuedCount = 0;
    var completedCount = 0;
    var failedCount = 0;
    var activeDownloadsCount = 0;
    var finalizingCount = 0;
    int? firstDownloadingIndex;
    int? firstFinalizingIndex;
    final queuedWords = List<int>.filled((items.length + 31) >> 5, 0);
    for (var index = 0; index < items.length; index++) {
      final item = items[index];
      byTrackIndex.putIfAbsent(item.track.id, () => index);
      indexByItemId[item.id] = index;
      itemIds.add(item.id);
      if (item.status != DownloadStatus.completed) {
        notCompletedItemIds.add(item.id);
      }
      if (_countsAsQueued(item.status)) {
        queuedCount++;
        activeItemIds.add(item.id);
      }
      if (item.status == DownloadStatus.queued) {
        queuedWords[index >> 5] |= 1 << (index & 31);
      }
      if (item.status == DownloadStatus.completed) completedCount++;
      if (item.status == DownloadStatus.failed) failedCount++;
      if (item.status == DownloadStatus.downloading) {
        activeDownloadsCount++;
        firstDownloadingIndex ??= index;
      }
      if (item.status == DownloadStatus.finalizing) {
        finalizingCount++;
        firstFinalizingIndex ??= index;
      }
    }
    final snapshot = ChunkedList<DownloadItem>.from(items);
    final itemIndex = Map<String, int>.unmodifiable(indexByItemId);
    return DownloadQueueLookup._(
      byTrackId: _IndexedQueueMap(Map.unmodifiable(byTrackIndex), snapshot),
      byItemId: _IndexedQueueMap(itemIndex, snapshot),
      indexByItemId: itemIndex,
      itemIds: List.unmodifiable(itemIds),
      notCompletedItemIds: List.unmodifiable(notCompletedItemIds),
      activeItemIds: List.unmodifiable(activeItemIds),
      queuedCount: queuedCount,
      completedCount: completedCount,
      failedCount: failedCount,
      activeDownloadsCount: activeDownloadsCount,
      finalizingCount: finalizingCount,
      items: snapshot,
      firstDownloadingIndex: firstDownloadingIndex,
      firstFinalizingIndex: firstFinalizingIndex,
      queuedPositions: _QueuedPositions.fromWords(queuedWords),
    );
  }

  static bool _countsAsQueued(DownloadStatus status) =>
      status == DownloadStatus.queued ||
      status == DownloadStatus.downloading ||
      status == DownloadStatus.finalizing;

  static int _deltaForStatus({
    required DownloadStatus previous,
    required DownloadStatus next,
    required bool Function(DownloadStatus status) predicate,
  }) {
    final had = predicate(previous);
    final has = predicate(next);
    if (had == has) return 0;
    return has ? 1 : -1;
  }

  DownloadQueueLookup updatedForIndices({
    required List<DownloadItem> previousItems,
    required List<DownloadItem> nextItems,
    required Iterable<int> changedIndices,
  }) {
    if (previousItems.length != nextItems.length ||
        itemIds.length != nextItems.length ||
        indexByItemId.length != nextItems.length) {
      return DownloadQueueLookup.fromItems(nextItems);
    }

    final normalizedChanged = <int>{};
    for (final index in changedIndices) {
      if (index < 0 || index >= nextItems.length) {
        return DownloadQueueLookup.fromItems(nextItems);
      }
      normalizedChanged.add(index);
    }
    if (normalizedChanged.isEmpty) return this;

    var nextQueuedCount = queuedCount;
    var nextCompletedCount = completedCount;
    var nextFailedCount = failedCount;
    var nextActiveDownloadsCount = activeDownloadsCount;
    var nextFinalizingCount = finalizingCount;
    var notCompletedMembershipChanged = false;
    var activeMembershipChanged = false;

    for (final index in normalizedChanged) {
      final previous = previousItems[index];
      final next = nextItems[index];
      if (previous.id != next.id || previous.track.id != next.track.id) {
        return DownloadQueueLookup.fromItems(nextItems);
      }

      if ((previous.status == DownloadStatus.completed) !=
          (next.status == DownloadStatus.completed)) {
        notCompletedMembershipChanged = true;
      }
      if (_countsAsQueued(previous.status) != _countsAsQueued(next.status)) {
        activeMembershipChanged = true;
      }

      nextQueuedCount += _deltaForStatus(
        previous: previous.status,
        next: next.status,
        predicate: _countsAsQueued,
      );
      nextCompletedCount += _deltaForStatus(
        previous: previous.status,
        next: next.status,
        predicate: (status) => status == DownloadStatus.completed,
      );
      nextFailedCount += _deltaForStatus(
        previous: previous.status,
        next: next.status,
        predicate: (status) => status == DownloadStatus.failed,
      );
      nextActiveDownloadsCount += _deltaForStatus(
        previous: previous.status,
        next: next.status,
        predicate: (status) => status == DownloadStatus.downloading,
      );
      nextFinalizingCount += _deltaForStatus(
        previous: previous.status,
        next: next.status,
        predicate: (status) => status == DownloadStatus.finalizing,
      );
    }

    if (byTrackId is! _IndexedQueueMap) {
      return DownloadQueueLookup.fromItems(nextItems);
    }
    final snapshot = ChunkedList<DownloadItem>.from(nextItems);
    return DownloadQueueLookup._(
      byTrackId: _IndexedQueueMap(
        (byTrackId as _IndexedQueueMap).index,
        snapshot,
      ),
      byItemId: _IndexedQueueMap(indexByItemId, snapshot),
      indexByItemId: indexByItemId,
      itemIds: itemIds,
      notCompletedItemIds: notCompletedMembershipChanged
          ? List.unmodifiable([
              for (final item in nextItems)
                if (item.status != DownloadStatus.completed) item.id,
            ])
          : notCompletedItemIds,
      activeItemIds: activeMembershipChanged
          ? List.unmodifiable([
              for (final item in nextItems)
                if (_countsAsQueued(item.status)) item.id,
            ])
          : activeItemIds,
      queuedCount: nextQueuedCount,
      completedCount: nextCompletedCount,
      failedCount: nextFailedCount,
      activeDownloadsCount: nextActiveDownloadsCount,
      finalizingCount: nextFinalizingCount,
      items: snapshot,
      firstDownloadingIndex: _firstAfterUpdates(
        _firstDownloadingIndex,
        DownloadStatus.downloading,
        nextActiveDownloadsCount,
        snapshot,
        normalizedChanged,
      ),
      firstFinalizingIndex: _firstAfterUpdates(
        _firstFinalizingIndex,
        DownloadStatus.finalizing,
        nextFinalizingCount,
        snapshot,
        normalizedChanged,
      ),
      queuedPositions: _queuedPositions.updated(
        previousItems,
        snapshot,
        normalizedChanged,
      ),
      duplicateTrackPositions: _duplicateTrackPositions,
    );
  }
}
