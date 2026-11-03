part of 'music_player_service.dart';

/// Changes the existing queue's transport, so notification and player controls
/// continue to use the same handler while the TV owns audio output.
class _MusicCast {
  _MusicCast(this.handler, this.output);

  final MusicPlayerHandler handler;
  final CastOutput? output;
  String? _requestedDevice;
  String? _appliedDevice;
  StreamSubscription<Map<Object?, Object?>>? _volumeSubscription;
  int? _volumeIndex;
  bool _closed = false;

  bool get active => _appliedDevice != null;

  void initialize() {
    final output = this.output;
    if (output == null) return;
    output.addListener(_changed);
    _volumeSubscription = output.updates.listen((_) => _showVolume());
    unawaited(output.initialize().then((_) => _changed()));
  }

  void _changed() {
    final output = this.output;
    if (_closed || output == null || handler._disposed) return;
    final device = output.connected
        ? '${output.deviceId}/${output.host}/${output.revision}'
        : null;
    if (device == _requestedDevice) return;
    _requestedDevice = device;
    final connected = device != null;
    final position = handler.playbackState.value.position;
    handler._pendingRestorePosition = position;
    final playing = connected && handler.playbackState.value.playing;
    final generation = ++handler._playRequestGeneration;
    handler._sourceReady = false;
    handler._switchingGeneration = generation;
    unawaited(() async {
      try {
        await handler._player.cancelPreparation();
        await handler._serializeSourceChange(() async {
          if (_closed || generation != handler._playRequestGeneration) return;
          await handler._cancelTransitions();
          if (_closed || generation != handler._playRequestGeneration) return;
          await applyOutput();
          if (_closed || generation != handler._playRequestGeneration) return;
          final index = handler._index;
          if (index < 0 || index >= handler._media.length) return;
          await handler._loadIndex(
            generation,
            handler._media[index],
            recordHistory: false,
            startPosition: position,
            // Losing the TV must never start the phone speaker unexpectedly.
            startPaused: !playing,
          );
        });
      } catch (error, stack) {
        if (generation == handler._playRequestGeneration &&
            !handler._disposed) {
          handler._reportPlaybackError(handler._player, error, stack);
        }
      } finally {
        if (handler._switchingGeneration == generation) {
          handler._switchingGeneration = 0;
        }
      }
    }());
  }

  Future<void> applyOutput() async {
    if (_closed || _appliedDevice == _requestedDevice) return;
    final device = _requestedDevice;
    final previous = handler._player;
    try {
      await previous.stop();
    } catch (error) {
      _log.w('Previous audio output could not stop: $error');
    }
    if (_closed || device != _requestedDevice) return;
    handler._player = device != null
        ? handler._dependencies.createCastDeck(
            output!,
            () => handler.mediaItem.value,
          )
        : handler._dependencies.createDeck('music-player');
    _appliedDevice = device;
    handler._listenToPlayer(handler._player);
    await handler._disposeDeck(previous);
    handler._refreshPlaybackAutomation();
    if (device != null) {
      // iOS keeps the session for the Cast plugin's silent keep-alive, which
      // lets the app keep serving the TV in the background.
      if (!Platform.isIOS) await handler._audioSession?.setActive(false);
      _showVolume();
    } else {
      _volumeIndex = null;
      handler.androidPlaybackInfo.add(LocalAndroidPlaybackInfo());
    }
  }

  void _showVolume() {
    if (_closed || !active) return;
    final index = ((output?.volume ?? 0) * 100).round();
    if (index == _volumeIndex) return;
    _volumeIndex = index;
    handler.androidPlaybackInfo.add(
      RemoteAndroidPlaybackInfo(
        volumeControlType: AndroidVolumeControlType.absolute,
        maxVolume: 100,
        volume: index,
      ),
    );
  }

  Future<void> setVolume(int value) async {
    if (active) {
      await output?.command('volume', {'volume': value.clamp(0, 100) / 100});
    }
  }

  Future<void> adjustVolume(AndroidVolumeDirection direction) =>
      setVolume(((output?.volume ?? 0) * 100).round() + direction.index * 5);

  Future<void> dispose() async {
    _closed = true;
    await _volumeSubscription?.cancel();
    output?.removeListener(_changed);
    if (active) {
      try {
        await output?.command('disconnect');
      } catch (error) {
        _log.w('Could not end Cast session: $error');
      }
    }
  }
}
