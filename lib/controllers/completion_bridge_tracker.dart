import 'package:flutter/foundation.dart';
import 'package:mornye/models/download_history.dart';
import 'package:mornye/models/download_item.dart';
import 'package:mornye/providers/download_queue_state.dart';

/// Just-completed queue items that the Library keeps showing until their
/// History row lands in the paged Library query.
///
/// The owning State registers the `ref.listen` callbacks in `build` and calls
/// into this tracker; `shouldRetainCompletionBridge` in
/// queue_library_refresh_policy.dart decides when a bridged item expires.
class CompletionBridgeTracker {
  /// Bridged queue items by queue item id.
  final Map<String, DownloadItem> items = {};

  final Map<String, DateTime> addedAt = {};

  /// Bridged items whose cover precache has already been scheduled.
  final Set<String> precacheStarted = {};

  /// Finds the History row for a bridged [item] by file path, id, track id
  /// and then ISRC.
  static DownloadHistoryItem? historyItemFor(
    DownloadItem item,
    List<DownloadHistoryItem> historyItems,
  ) {
    final filePath = item.filePath?.trim();
    if (filePath != null && filePath.isNotEmpty) {
      for (final historyItem in historyItems) {
        if (historyItem.filePath == filePath) return historyItem;
      }
    }

    for (final historyItem in historyItems) {
      if (historyItem.id == item.id) return historyItem;
    }

    final trackId = item.track.id.trim();
    if (trackId.isNotEmpty) {
      for (final historyItem in historyItems) {
        if (historyItem.spotifyId == trackId) return historyItem;
      }
    }

    final isrc = item.track.isrc?.trim();
    if (isrc != null && isrc.isNotEmpty) {
      for (final historyItem in historyItems) {
        if (historyItem.isrc == isrc) return historyItem;
      }
    }

    return null;
  }

  /// Handles a queue lookup change: drops bridged items that left the queue
  /// (rebuilding through [setState]) and bridges items that just completed,
  /// refreshing their file checks through [refreshPath] first.
  void onQueueLookupChanged(
    DownloadQueueLookup? previous,
    DownloadQueueLookup next, {
    required void Function(VoidCallback fn) setState,
    required void Function(String? path) refreshPath,
  }) {
    if (previous == null) return;
    if (items.keys.any((id) => !next.byItemId.containsKey(id))) {
      setState(() {
        items.removeWhere((id, _) => !next.byItemId.containsKey(id));
        addedAt.removeWhere((id, _) => !next.byItemId.containsKey(id));
        precacheStarted.removeWhere((id) => !next.byItemId.containsKey(id));
      });
    }
    if (identical(previous.notCompletedItemIds, next.notCompletedItemIds)) {
      return;
    }
    final fastCompletedIds = next.justCompletedFrom(previous);
    if (fastCompletedIds != null) {
      for (final id in fastCompletedIds) {
        final nextItem = next.byItemId[id];
        if (nextItem == null) continue;
        refreshPath(nextItem.filePath);
        items[id] = nextItem;
        addedAt[id] = DateTime.now();
      }
      return;
    }
    for (final id in previous.notCompletedItemIds) {
      final prevItem = previous.byItemId[id];
      final nextItem = next.byItemId[id];
      if (prevItem == null) continue;
      final wasActive =
          prevItem.status == DownloadStatus.downloading ||
          prevItem.status == DownloadStatus.finalizing ||
          prevItem.status == DownloadStatus.queued;
      final nowCompleted =
          nextItem != null && nextItem.status == DownloadStatus.completed;
      if (wasActive && nowCompleted) {
        refreshPath(nextItem.filePath);
        items[id] = nextItem;
        addedAt[id] = DateTime.now();
      }
    }
  }

  /// Refreshes the file checks of every bridged item and of its History row
  /// after History reloads its index.
  void refreshPaths(
    List<DownloadHistoryItem> historyItems, {
    required void Function(String? path) refreshPath,
  }) {
    for (final bridgeItem in items.values) {
      refreshPath(bridgeItem.filePath);
      final historyPath = historyItemFor(bridgeItem, historyItems)?.filePath;
      refreshPath(historyPath);
    }
  }
}
