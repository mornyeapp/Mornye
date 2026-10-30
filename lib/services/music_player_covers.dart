part of 'music_player_service.dart';

/// Network covers shown from the cover store: a stored cover shows from a
/// song's first item, the same file on every play; one not stored yet shows
/// on the current song and its queue entries once fetched. A network song
/// shows the cover from its tags once read (see [CoverStore.songCover]),
/// else its network cover ([PlayableMedia.coverReference]). The covers of
/// the next songs are fetched ahead, so a skip or a gapless start shows its
/// cover at once.
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
    unawaited(_store.file(ref).then((_) => _show(ref)));
  }

  /// [fetch] for the network cover of [media], unless it shows the cover
  /// from its tags.
  void fetchFor(PlayableMedia media) {
    if (_store.songCover(media.source) == null) fetch(media.coverReference);
  }

  /// [fetch] for the covers of the songs after the current one that have
  /// no stored cover yet.
  void fetchAhead() {
    final media = handler._media;
    final index = handler._index;
    for (var i = index + 1; i < media.length && i <= index + ahead; i++) {
      final ref = media[i].coverReference;
      if (ref != null && _store.songCover(media[i].source, ref) == null) {
        fetch(ref);
      }
    }
  }

  /// The server changed the cover [ref]: the current song checks it again
  /// now, others when they next ask the store.
  void invalidate(String? ref) {
    _store.invalidate(ref);
    final index = handler._index;
    if (ref == null || index < 0 || index >= handler._media.length) return;
    final current = handler._media[index];
    if (current.coverReference == ref) fetchFor(current);
  }

  /// Shows the file the stored cover [ref] moved to.
  void changed(String ref) => _show(ref);

  /// Keeps the cover read with the tags of the network song [media] to the
  /// temporary file [cover] when it is the song's own ([_ownsTagCover]):
  /// once stored, it is the song's cover on every play. A read without one
  /// keeps it, since a failed cover request reads the same. Answers the
  /// cover the song shows now: its stored cover, else [cover] on this play
  /// only. Null keeps what its items show.
  Future<Uri?> readTagCover(PlayableMedia media, String? cover) async {
    final read = cover == null || cover.isEmpty ? null : Uri.file(cover);
    if (read != null && _ownsTagCover(media)) {
      final reference = CoverStore.songCoverReference(media.source);
      // One the store could not keep shows on this play only.
      if (await _store.adopt(reference, cover!) == null) return read;
    }
    final stored = _store.songCover(media.source, media.coverReference);
    return stored == null ? read : Uri.file(stored.path);
  }

  /// Whether the cover read with the tags of [media] is its own. A Subsonic
  /// server answers the cover the song's network reference names, which
  /// the store keeps fresh under that reference.
  static bool _ownsTagCover(PlayableMedia media) {
    if (media.coverReference == null) return true;
    final uri = Uri.tryParse(media.source);
    return uri == null ||
        subsonicSongIdFromPath(uri.pathSegments.join('/')) == null;
  }

  /// The reference of the stored cover [item] of the song [source] shows,
  /// for listening statistics to keep: its tag cover's, else its network
  /// cover's, else the artwork when it outlasts this run.
  String? reference(MediaItem item) {
    final source = item.extras?['source']?.toString();
    final shown = source == null ? null : _store.songCover(source);
    if (shown != null && item.artUri == Uri.file(shown.path)) {
      return shown.reference;
    }
    return item.extras?['artworkRef']?.toString() ??
        durableCoverReference(item.artUri?.toString());
  }

  /// Shows the stored cover of the songs whose tag cover or network cover
  /// is [ref] on the current song and their queue entries.
  void _show(String ref) {
    if (handler._disposed) return;
    MediaItem? covered(MediaItem item, String source, String? reference) {
      if (ref != reference && ref != CoverStore.songCoverReference(source)) {
        return null;
      }
      final cover = _store.songCover(source, reference);
      if (cover == null) return null;
      final artUri = Uri.file(cover.path);
      return item.artUri == artUri ? null : item.copyWith(artUri: artUri);
    }

    final current = handler.mediaItem.value;
    final source = current?.extras?['source']?.toString();
    if (current != null && source != null) {
      final updated = covered(
        current,
        source,
        current.extras?['artworkRef']?.toString(),
      );
      if (updated != null) handler.mediaItem.add(updated);
    }
    var changed = false;
    for (var i = 0; i < handler._media.length; i++) {
      final media = handler._media[i];
      final entry = handler._queueItems[i];
      final updated = covered(entry, media.source, media.coverReference);
      if (updated == null) continue;
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
