part of 'music_player_service.dart';

/// Bounds automatic skips across missing files and unsupported formats.
/// A successful start or a new transport request begins a new attempt.
class _MusicFailures {
  _MusicFailures(this.handler);

  final MusicPlayerHandler handler;
  int _failures = 0;
  int _skipGeneration = -1;
  int _queueLimit = 0;

  void started() => _failures = 0;

  /// After source recovery and opening failed, only confirmed absence of
  /// the local song permits skipping. An unavailable server, lost access or
  /// missing temporary SAF copy does not mean the song itself is gone.
  Future<bool> skipMissing(
    PlayableMedia media,
    String? resolved,
    int generation, {
    required bool startPaused,
  }) async {
    if (!handler._isCurrentPlayRequest(generation, media)) return true;
    if (media.isNetwork ||
        media.originSource != null ||
        _MusicFormats._isUrl(resolved ?? '')) {
      return false;
    }
    final path = media.isContentUri || handler._formats.owns(resolved)
        ? media.source
        : resolved ?? media.source;
    if (path.isEmpty) return false;
    final access = await checkFileAccess(path);
    if (!handler._isCurrentPlayRequest(generation, media)) return true;
    if (access is! FileAccessMissing) return false;
    final skip = canSkip(generation, startPaused: startPaused);
    _log.w('Local audio file is missing: ${media.title}; skip=$skip');
    if (!skip) return false;
    playNext();
    return true;
  }

  bool canSkip(int generation, {required bool startPaused, int? limit}) {
    if (_failures == 0 || generation != _skipGeneration) {
      _failures = 0;
      // Autoplay additions cannot keep a failing pass running forever.
      _queueLimit = handler._media.length;
    }
    _failures++;
    final count = handler._media.length;
    final repeatAll = handler._repeatMode == AudioServiceRepeatMode.all;
    return !startPaused &&
        !handler._userPaused &&
        handler._repeatMode != AudioServiceRepeatMode.one &&
        (handler._index + 1 < count || (repeatAll && count > 1)) &&
        _failures < min(_queueLimit, limit ?? _queueLimit);
  }

  void playNext() {
    final next = handler._index + 1 < handler._media.length
        ? handler._index + 1
        : handler._beginRepeatPass(handler._repeatPassStart());
    // Finish the failed source change before opening the next song.
    final playing = handler._playIndex(next);
    _skipGeneration = handler._playRequestGeneration;
    unawaited(
      playing.catchError((Object error) {
        _log.w('Could not play the next song: $error');
      }),
    );
  }
}
