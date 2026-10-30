part of 'music_player_service.dart';

/// Network covers ([PlayableMedia.networkArtworkSource]) shown from the
/// cover store: a stored cover shows from a song's first item, the same file
/// on every play; one not stored yet shows on the current song and its queue
/// entries once fetched. The covers of the next songs are fetched ahead, so
/// a skip or a gapless start shows its cover at once.
class _MusicCovers {
  _MusicCovers(this.handler);

  /// How many songs after the current one have their covers fetched ahead.
  static const ahead = 3;

  final MusicPlayerHandler handler;

  CoverStore get _store => handler._dependencies.coverStore;

  /// Shows the network cover [ref] once the store has it, fetching it when
  /// it is not stored yet and checking a stored one.
  void fetch(String? ref) {
    if (ref == null) return;
    unawaited(_store.file(ref).then((path) => _show(ref, path)));
  }

  /// [fetch] for the covers of the songs after the current one that are
  /// not stored yet.
  void fetchAhead() {
    final media = handler._media;
    final index = handler._index;
    for (var i = index + 1; i < media.length && i <= index + ahead; i++) {
      final ref = media[i].networkArtworkSource;
      if (ref != null && _store.indexedFile(ref) == null) fetch(ref);
    }
  }

  /// [fetch] for a cover its server just changed.
  void refresh(String? ref) {
    if (ref == null) return;
    unawaited(_store.refresh(ref).then((path) => _show(ref, path)));
  }

  /// Shows the file the stored cover [ref] moved to.
  void changed(String ref) => _show(ref, _store.indexedFile(ref));

  /// The stored copy of the cover in the tags of the network song [source],
  /// read to the temporary file [cover], so the session keeps a path that
  /// lasts. Null when the song's network cover [reference] is stored, which
  /// it shows instead, or when the copy failed.
  Future<String?> adoptTagCover(
    String source,
    String? reference,
    String? cover,
  ) async {
    if (cover == null || cover.isEmpty) return null;
    if (_store.indexedFile(reference) != null) return null;
    return _store.adopt(CoverStore.songCoverReference(source), cover);
  }

  /// Shows [path], the stored file of the network cover [ref], on the current
  /// song and on the queue entries with that cover.
  void _show(String ref, String? path) {
    if (path == null || handler._disposed) return;
    final artUri = Uri.file(path);
    final current = handler.mediaItem.value;
    if (current != null &&
        current.extras?['artworkRef'] == ref &&
        current.artUri != artUri) {
      handler.mediaItem.add(current.copyWith(artUri: artUri));
    }
    var changed = false;
    for (var i = 0; i < handler._media.length; i++) {
      final entry = handler._queueItems[i];
      if (handler._media[i].networkArtworkSource != ref ||
          entry.artUri == artUri) {
        continue;
      }
      final updated = entry.copyWith(artUri: artUri);
      handler._queueItems[i] = updated;
      // Keep the saved shuffle order paired with the updated entry.
      final original = handler._originalQueueOrder;
      final at = original?.indexWhere((item) => identical(item, entry)) ?? -1;
      if (at >= 0) original![at] = updated;
      changed = true;
    }
    if (changed) {
      handler.queue.add(List<MediaItem>.unmodifiable(handler._queueItems));
    }
  }
}
