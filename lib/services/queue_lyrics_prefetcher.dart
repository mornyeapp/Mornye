import 'dart:async';
import 'package:audio_service/audio_service.dart';

/// Pre-fetches metadata and lyrics for upcoming tracks in the active playback queue.
class QueueLyricsPrefetcher {
  QueueLyricsPrefetcher({required this.onPrefetch});

  final Future<void> Function(MediaItem item) onPrefetch;
  String? _lastPrefetchedId;

  /// Inspects the current queue state and triggers pre-fetching for the upcoming track.
  void updateQueue({
    required List<MediaItem> queue,
    required int currentIndex,
  }) {
    if (currentIndex < 0 || currentIndex + 1 >= queue.length) {
      return;
    }
    final nextItem = queue[currentIndex + 1];
    if (nextItem.id == _lastPrefetchedId) {
      return;
    }
    _lastPrefetchedId = nextItem.id;
    unawaited(onPrefetch(nextItem));
  }

  void reset() {
    _lastPrefetchedId = null;
  }
}
