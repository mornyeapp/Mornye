part of 'music_player_service.dart';

/// Keeps whole local copies of the network songs around the one playing:
/// the next two in the order the queue plays, then the current one for
/// replays. The copies download once the current song has played a few
/// seconds, so they never compete with its start.
class _MusicPrefetch {
  _MusicPrefetch(this.handler);

  /// How far into a song its neighbours start downloading.
  static const start = Duration(seconds: 3);

  /// How many songs after the current one are kept.
  static const ahead = 2;

  final MusicPlayerHandler handler;
  String? _key;
  int _revision = 0;

  NetworkPlaybackCache? get _cache => handler._dependencies.networkCache();

  void onPosition(Duration position) {
    if (position < start || handler._disposed) return;
    final key =
        '${handler._playRequestGeneration}:${handler._sessionQueueRevision}:'
        '${handler._index}:${handler._repeatMode.name}';
    if (key == _key) return;
    _key = key;
    final cache = _cache;
    if (cache != null) unawaited(_update(cache, ++_revision));
  }

  /// The songs to keep, most needed first. Repeat all wraps to the start of
  /// the queue, except in shuffle mode, where the next pass opens with a
  /// random song.
  List<PlayableMedia> _wanted() {
    final media = handler._media;
    final index = handler._index;
    if (index < 0 || index >= media.length) return const [];
    final current = media[index];
    if (handler._repeatMode == AudioServiceRepeatMode.one) return [current];
    final next = <PlayableMedia>[];
    for (var step = 1; step <= ahead && step < media.length; step++) {
      var i = index + step;
      if (i >= media.length) {
        if (handler._repeatMode != AudioServiceRepeatMode.all ||
            handler._shuffle) {
          break;
        }
        i -= media.length;
      }
      next.add(media[i]);
    }
    return [...next, current];
  }

  Future<void> _update(NetworkPlaybackCache cache, int revision) async {
    final sources = <String>[];
    for (final media in _wanted()) {
      if (!media.source.startsWith('network://')) continue;
      try {
        // A saved offline copy plays in place of the server file.
        if (await handler._dependencies.offlineCopy(media.source) != null) {
          continue;
        }
      } catch (_) {}
      if (revision != _revision) return;
      sources.add(media.source);
    }
    if (revision != _revision || handler._disposed) return;
    cache.want(sources);
  }

  /// Whether the next song [media] has a whole copy within [within], waiting
  /// for a download in progress.
  Future<bool> ready(PlayableMedia media, Duration within) async {
    final cache = _cache;
    if (cache == null || !media.source.startsWith('network://')) return false;
    try {
      return await cache.ready(media.source, within);
    } catch (_) {
      return false;
    }
  }

  /// The whole copy of the network song [media], or null.
  Future<String?> lookup(PlayableMedia media) async {
    final cache = _cache;
    if (cache == null) return null;
    try {
      return await cache.lookup(media.source);
    } catch (_) {
      return null;
    }
  }

  bool owns(String path) => _cache?.owns(path) ?? false;

  Future<void> invalidate(String source) async {
    if (!source.startsWith('network://')) return;
    try {
      await _cache?.invalidate(source);
    } catch (_) {}
  }

  /// Stops downloads once nothing plays.
  void stop() {
    _key = null;
    _revision++;
    _cache?.want(const <String>[]);
  }
}
