part of 'music_player_service.dart';

/// Bounds automatic skips across missing files and unsupported formats.
/// A successful start or a new transport request begins a new attempt.
class _MusicFailures {
  _MusicFailures(this.handler);

  final MusicPlayerHandler handler;
  int _failures = 0;
  int _skipGeneration = -1;
  int _queueLimit = 0;
  int? _checkingGeneration;
  PlayableMedia? _startedMedia;
  String? _startedPath;

  bool get checking => _checkingGeneration == handler._playRequestGeneration;

  void started(PlayableMedia media, String? path) {
    _failures = 0;
    _startedMedia = media;
    _startedPath = path;
  }

  Future<void> onRuntimeError(
    PlaybackDeck player,
    Object error,
    StackTrace stack,
  ) async {
    if (handler._disposed ||
        !identical(player, handler._player) ||
        handler._playbackError != null ||
        checking) {
      return;
    }
    final index = handler._index;
    if (index < 0 ||
        index >= handler._media.length ||
        '$error'.contains('MEDIA_ERROR_SERVER_DIED')) {
      handler._reportPlaybackError(player, error, stack);
      return;
    }
    final generation = handler._playRequestGeneration;
    final media = handler._media[index];
    final resolved =
        _startedMedia?.id == media.id && _startedMedia?.source == media.source
        ? _startedPath
        : null;
    handler._sourceReady = false;
    _checkingGeneration = generation;
    try {
      if (await skipMissing(
        media,
        resolved,
        generation,
        startPaused: handler._userPaused || handler._interruptionActive,
      )) {
        return;
      }
      if (handler._isCurrentPlayRequest(generation, media)) {
        handler._reportPlaybackError(player, error, stack);
      }
    } finally {
      if (_checkingGeneration == generation) _checkingGeneration = null;
    }
  }

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
    // A null local resolution can mean recovery from a paired device failed.
    // It is not evidence that the remotely recoverable song should be removed.
    if (media.isNetwork ||
        media.originSource != null ||
        (resolved == null && !media.isContentUri) ||
        _MusicFormats._isUrl(resolved ?? '')) {
      return false;
    }
    final path = media.isContentUri || handler._formats.owns(resolved)
        ? media.source
        : resolved ?? media.source;
    if (path.isEmpty) return false;
    final access = await handler._dependencies.fileAccess(path);
    if (!handler._isCurrentPlayRequest(generation, media)) return true;
    if (access is! FileAccessMissing) return false;
    _recordFailure(generation);
    final removed = handler._pruneQueuedSource(media.source);
    if (removed == null) return false;
    handler._autoplay.dismiss(media);
    _log.w('Removing missing local audio from the queue: ${media.title}');
    final count = handler._media.length;
    final next = removed.nextIndex;
    // Source changes are serialized. Do not await a new one from _loadIndex.
    final Future<void> reaction;
    if (count == 0 ||
        (next >= count && handler._repeatMode != AudioServiceRepeatMode.all)) {
      reaction = handler.stop();
    } else {
      reaction = handler._playIndex(
        next < count
            ? next
            : handler._beginRepeatPass(handler._repeatPassStart()),
        startPaused: startPaused,
      );
    }
    _skipGeneration = handler._playRequestGeneration;
    unawaited(
      reaction.catchError((Object error) {
        _log.w('Could not update playback after a missing file: $error');
      }),
    );
    return true;
  }

  void _recordFailure(int generation) {
    if (_failures == 0 || generation != _skipGeneration) {
      _failures = 0;
      // Autoplay additions cannot keep a failing pass running forever.
      _queueLimit = handler._media.length;
    }
    _failures++;
  }

  bool canSkip(int generation, {required bool startPaused, int? limit}) {
    _recordFailure(generation);
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
