part of 'music_player_service.dart';

/// Gapless playback: loads the next song on a second deck shortly before the
/// current one ends and starts it the moment the current one completes,
/// chained natively where the engine can (see [PlaybackDeck.setNextDeck]).
/// AutoMix replaces it while on. Repeat one, USB output and exclusive output
/// keep the ordinary transition, which loads the next song after the end.
class _MusicGapless {
  _MusicGapless(this.handler);

  /// How long before the end the next song loads.
  static const lead = Duration(seconds: 30);

  final MusicPlayerHandler handler;
  final _pins = <String>{};
  PlaybackDeck? _prepared;
  PlayableMedia? _next;
  String? _nextPath;
  Duration? _nextDuration;
  double _nextVolume = 1;
  bool _nextIsCopy = false;
  int _nextIndex = -1;
  int _queueRevision = -1;
  int _playGeneration = -1;
  int _generation = 0;
  String? _attempt;
  bool _preparing = false;

  Set<String> get pinnedPaths => _pins;

  bool get _enabled {
    final settings = handler._settings;
    return settings.gaplessPlayback &&
        !settings.autoMix &&
        !settings.usbBitPerfect &&
        // A second deck cannot open a device held in exclusive mode.
        !playbackExclusiveOutput.value &&
        !handler._player.isDirect &&
        !handler._disposed &&
        handler._sourceReady &&
        handler._repeatMode != AudioServiceRepeatMode.one;
  }

  bool _current(int generation) =>
      generation == _generation &&
      _enabled &&
      _playGeneration == handler._playRequestGeneration &&
      _queueRevision == handler._sessionQueueRevision;

  void onPosition(Duration position) {
    if (_preparing) return;
    if (_prepared != null) {
      if (!_current(_generation)) unawaited(cancel());
      return;
    }
    if (!_enabled) return;
    final duration = handler.mediaItem.value?.duration;
    if (duration == null ||
        duration <= Duration.zero ||
        duration - position > lead) {
      return;
    }
    final key =
        '${handler._playRequestGeneration}:${handler._sessionQueueRevision}';
    if (_attempt == key) return;
    _attempt = key;
    unawaited(_prepare());
  }

  Future<void> _prepare() async {
    _preparing = true;
    final generation = ++_generation;
    _playGeneration = handler._playRequestGeneration;
    _queueRevision = handler._sessionQueueRevision;
    final index = handler._index;
    final nextIndex = index + 1 < handler._media.length
        ? index + 1
        : handler._repeatMode == AudioServiceRepeatMode.all
        ? handler._repeatPassStart()
        : -1;
    PlaybackDeck? deck;
    ContentUriPlaybackLease? lease;
    try {
      if (index < 0 || nextIndex < 0 || nextIndex == index) return;
      final next = handler._media[nextIndex];
      // DSD needs the USB output, which the ordinary transition opens.
      if (MusicPlayerHandler._requiresDsd(next)) return;
      if (handler._dependencies.isAndroid && next.isContentUri) {
        try {
          lease = await PlatformBridge.openContentUriPlaybackLease(next.source);
        } catch (error) {
          _log.w('Gapless SAF lease unavailable: $error');
        }
        if (!_current(generation)) return;
      }
      final path = lease?.path ?? await handler._resolveSource(next);
      if (path == null || !_current(generation)) return;
      final isCopy = next.isContentUri && lease == null;
      if (isCopy) _pins.add(path);
      final volume = await handler._normalizationVolumeFor(
        path,
        cacheKey: next.isContentUri ? next.source : null,
        displayName: lease?.displayName,
      );
      if (!_current(generation)) return;
      deck = handler._dependencies.createDeck(
        'music-gapless-$generation-${DateTime.now().microsecondsSinceEpoch}',
      );
      handler._listenToPlayer(deck);
      await deck.configureOutput();
      await deck.setVolume(volume);
      if (!_current(generation)) return;
      if (const {'http', 'https'}.contains(Uri.tryParse(path)?.scheme)) {
        await deck.setNetworkSource(
          path,
          arriving: handler._runtime.streamsArrivingFile(path),
        );
      } else {
        await deck.setFileSource(path);
      }
      if (!_current(generation)) return;
      final duration = await deck.getDuration();
      if (!_current(generation)) return;
      final chained = await handler._player.setNextDeck(deck);
      if (!_current(generation)) {
        if (chained) await handler._player.setNextDeck(null);
        return;
      }
      _prepared = deck;
      deck = null;
      _next = next;
      _nextIndex = nextIndex;
      _nextPath = path;
      _nextDuration = duration != null && duration > Duration.zero
          ? duration
          : next.duration;
      _nextVolume = volume;
      _nextIsCopy = isCopy;
      _log.d('Gapless prepared (${chained ? 'native' : 'on completion'})');
    } catch (error) {
      _log.w('Gapless preparation skipped: $error');
    } finally {
      if (lease != null) {
        await PlatformBridge.closeContentUriPlaybackLease(lease.token);
      }
      if (deck != null) await handler._disposeDeck(deck);
      if (generation == _generation) {
        _preparing = false;
        if (_prepared == null) _pins.clear();
      }
      await handler._cleanupPendingResolvedPaths();
    }
  }

  /// Makes the prepared song current as the current one completes. False
  /// leaves the ordinary transition to the caller.
  Future<bool> handoff() async {
    final incoming = _prepared;
    final next = _next;
    if (incoming == null || next == null) return false;
    if (!_current(_generation) ||
        _nextIndex >= handler._media.length ||
        !identical(handler._media[_nextIndex], next)) {
      await cancel();
      return false;
    }
    final generation = _generation;
    final playGeneration = handler._playRequestGeneration;
    try {
      // A natively chained deck already plays; this confirms its state.
      await incoming.resume();
    } catch (error) {
      _log.w('Gapless start failed: $error');
      if (generation == _generation) await cancel();
      return playGeneration != handler._playRequestGeneration;
    }
    // Another request (Next, a new queue) took over meanwhile.
    if (generation != _generation) {
      return playGeneration != handler._playRequestGeneration;
    }
    final outgoing = handler._player;
    final path = _nextPath;
    _prepared = null;
    _next = null;
    _pins.clear();
    handler._player = incoming;
    // An index at or before the current one wraps to a new repeat-all pass.
    final index = _nextIndex > handler._index
        ? _nextIndex
        : handler._beginRepeatPass(_nextIndex);
    handler._index = index;
    final current = ++handler._playRequestGeneration;
    handler._serverDiedReloads = 0;
    handler._playbackAutomation.cancelPendingActions();
    handler._recordPlayHistory(index);
    handler._normalizationVolume = _nextVolume;
    handler._activeResolvedPath = _nextIsCopy ? path : null;
    handler._pendingRestorePosition = null;
    handler._runtime.personalization.begin(_learningTrack(next));
    handler.mediaItem.add(
      handler
          ._toMediaItem(next, resolvedSource: _nextIsCopy ? path : null)
          .copyWith(duration: _nextDuration),
    );
    handler._covers
      ..fetchFor(next)
      ..fetchAhead();
    handler._lastBroadcastPosition = Duration.zero;
    handler._lastPositionBroadcastAt = null;
    handler._broadcastPosition(Duration.zero, force: true);
    handler._broadcastState(playerState: PlaybackDeckState.playing);
    handler._lastPeriodicPersistAt = DateTime.now();
    unawaited(handler._persistSession(position: Duration.zero));
    if (!next.isNetwork) {
      unawaited(handler._recoverEmbeddedArtwork(next, current));
    }
    if (next.source.startsWith('network://')) {
      unawaited(handler._loadNetworkMetadata(next, current));
    }
    unawaited(handler._ensureDurationKnown(next, current));
    unawaited(handler._autoplay.fill());
    _log.d('Gapless transition');
    await handler._disposeDeck(outgoing);
    await handler._cleanupPendingResolvedPaths();
    return true;
  }

  Future<void> cancel() async {
    _generation++;
    _preparing = false;
    _attempt = null;
    final prepared = _prepared;
    _prepared = null;
    _next = null;
    _nextPath = null;
    _pins.clear();
    if (prepared == null) return;
    try {
      await handler._player.setNextDeck(null);
    } catch (error) {
      _log.w('Gapless unlink failed: $error');
    }
    await handler._disposeDeck(prepared);
    await handler._cleanupPendingResolvedPaths();
  }

  Future<void> dispose() => cancel();
}
