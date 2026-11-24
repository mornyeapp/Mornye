import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:mornye/services/music_playback_deck.dart';
import 'package:mornye/services/playback_deck.dart';
import 'package:mornye/services/playback_equalizer.dart';
import 'package:mornye/services/switching_playback_deck.dart';
import 'package:mornye/utils/logger.dart';

final _log = AppLogger('Media3Deck');

/// A failure the media3 player reported after its source loaded.
class Media3PlaybackException implements Exception {
  const Media3PlaybackException(
    this.message, {
    this.errorCode,
    this.prepared = false,
  });

  final String message;

  /// The platform's error code name, such as `ERROR_CODE_DECODING_FAILED`.
  final String? errorCode;

  /// Whether the source had loaded before it failed.
  final bool prepared;

  @override
  String toString() =>
      'Media3PlaybackException: $message'
      '${errorCode == null ? '' : ' ($errorCode)'}';
}

/// Whether media3 may fetch [source]. ExoPlayer reads streams inside the
/// app, so the app's network security config applies: cleartext `http` only
/// to `localhost` and `127.0.0.1` (`network_security_config.xml`), which the
/// app's own loopback servers use. MediaPlayer fetches in the media server,
/// so audioplayers still plays `http` from other hosts, such as a NAS.
bool media3CanFetch(String source) {
  final uri = Uri.tryParse(source);
  if (uri == null || uri.scheme.toLowerCase() != 'http') return true;
  final host = uri.host.toLowerCase();
  return host == '127.0.0.1' ||
      host == 'localhost' ||
      host.endsWith('.localhost');
}

PlaybackDeckState? _eventState(Object? state) => switch (state) {
  'playing' => PlaybackDeckState.playing,
  'paused' => PlaybackDeckState.paused,
  'stopped' => PlaybackDeckState.stopped,
  'completed' => PlaybackDeckState.completed,
  _ => null,
};

/// Android: one media3 ExoPlayer in the app's own plugin
/// (`com.zarz.mornye/media3_player`), always through the platform mixer with
/// offload off. Gapless queues the next song on this same player.
///
/// The native player is created on first use. Each source owns a token, so
/// a reply or event for an earlier one cannot affect the next song.
class Media3PlaybackDeck implements PlaybackDeck, QueuedPlaybackDeck {
  Media3PlaybackDeck({required this.playerId}) {
    playbackEqualizer.addListener(_equalizerChanged);
    playbackOutputVolume.addListener(_outputVolumeChanged);
    playbackSkipSilence.addListener(_skipSilenceChanged);
    playbackSpatialAudio.addListener(_spatialAudioChanged);
    playbackSpeed.addListener(_parametersChanged);
    playbackPitch.addListener(_parametersChanged);
  }

  static const _channel = MethodChannel('com.zarz.mornye/media3_player');

  /// False once the native player turned out to be missing from this build.
  static bool _missing = false;

  @visibleForTesting
  static bool? debugAvailableOverride;

  @visibleForTesting
  static void debugResetAvailability() => _missing = false;

  /// False when this build has no native media3 player; decks then stay on
  /// audioplayers.
  static bool get isAvailable => debugAvailableOverride ?? !_missing;

  final String playerId;
  final _states = StreamController<PlaybackDeckState>.broadcast();
  final _durations = StreamController<Duration>.broadcast();
  final _positions = StreamController<Duration>.broadcast();
  final _completions = StreamController<void>.broadcast();
  Future<void>? _created;
  StreamSubscription<dynamic>? _events;
  PlaybackDeckState _state = PlaybackDeckState.stopped;
  AsyncError? _failure;
  Duration? _duration;

  /// Whether the current source loaded and has not failed since.
  bool _loaded = false;

  /// Completes when a source still preparing is abandoned.
  Completer<void>? _preparation;
  int _token = 0;
  double _gain = 1;
  ({double volume, double output, void Function() onStarted})? _next;
  Duration? _positionInterval;
  bool Function()? _positionWanted;
  Timer? _positionTimer;
  bool _polling = false;
  bool _disposed = false;
  bool _equalizerSent = false;

  /// The native player starts with silence skipping off; only a change from
  /// that is sent.
  bool _skipSilenceSent = false;

  /// The native player starts with spatialization allowed (auto); only a
  /// change from that is sent.
  bool _spatialAudioSent = true;

  /// The rate [setPlaybackRate] gave, before [playbackSpeed].
  double _rate = 1;

  /// The native player starts at normal speed and pitch; only a change from
  /// that is sent.
  ({double speed, double pitch})? _parametersSent = (speed: 1, pitch: 1);
  Timer? _equalizerTimer;
  Future<void> _equalizerWrite = Future.value();

  @override
  PlaybackDeckState get state => _state;
  @override
  bool get isDirect => false;
  @override
  PlaybackTempoSupport get tempoSupport => PlaybackTempoSupport.full;
  @override
  bool get needsSourceReload => false;
  @override
  Stream<PlaybackDeckState> get onPlayerStateChanged => _states.stream;
  @override
  Stream<Duration> get onDurationChanged => _durations.stream;
  @override
  Stream<Duration> get onPositionChanged => _positions.stream;
  @override
  Stream<void> get onPlayerComplete => _completions.stream;

  @override
  bool get canQueueNextSource => !_disposed && _loaded && _preparation == null;

  Future<void> _ensureCreated() => _created ??= _create();

  Future<void> _create() async {
    try {
      await _channel.invokeMethod<Object?>('create', {'playerId': playerId});
    } catch (error) {
      // Nothing to release; a later call tries again.
      _created = null;
      if (error is MissingPluginException) _missing = true;
      rethrow;
    }
    // dispose releases the native player once this completes.
    if (_disposed) return;
    // The native side registers this stream before create replies.
    _events = EventChannel('com.zarz.mornye/media3_player/events/$playerId')
        .receiveBroadcastStream()
        .listen(
          _onEvent,
          onError: (Object error) => _log.w('Player events: $error'),
        );
    if (playbackEqualizer.value.enabled || _boostWanted > 0) {
      _equalizerWrite = _equalizerWrite.then((_) => _syncEqualizer());
    }
    // Before the first source, so its decoder starts in the mode silence
    // skipping needs.
    if (playbackSkipSilence.value) await _sendSkipSilence();
    // Before the first source, so its output never opens spatialized.
    if (!playbackSpatialAudio.value) await _sendSpatialAudio();
    await _sendParameters();
  }

  ({double speed, double pitch}) get _parameters {
    final speed = _rate * playbackSpeed.value;
    return (speed: speed, pitch: playbackPitch.value.factorAt(speed));
  }

  void _parametersChanged() {
    final created = _created;
    if (_disposed || created == null) return;
    unawaited(
      created.then((_) async {
        if (_disposed) return;
        await _sendParameters();
      }, onError: (Object _) {}),
    );
  }

  /// ExoPlayer applies them at once, keeps them for queued songs, and does
  /// not start a paused player.
  Future<void> _sendParameters() async {
    final parameters = _parameters;
    if (parameters == _parametersSent) return;
    _parametersSent = parameters;
    try {
      await _channel.invokeMethod<void>('setPlaybackParameters', {
        'playerId': playerId,
        'speed': parameters.speed,
        'pitch': parameters.pitch,
      });
    } on PlatformException catch (error) {
      _parametersSent = null;
      _log.w('Speed and pitch unavailable: ${error.code}');
    } on MissingPluginException {
      // An older native player: normal speed and pitch stay.
    }
  }

  void _spatialAudioChanged() {
    final created = _created;
    if (_disposed || created == null) return;
    unawaited(
      created.then((_) async {
        if (_disposed || playbackSpatialAudio.value == _spatialAudioSent) {
          return;
        }
        await _sendSpatialAudio();
      }, onError: (Object _) {}),
    );
  }

  /// Applies live: the native side reopens its output at the current
  /// position with the new spatialization behavior.
  Future<void> _sendSpatialAudio() async {
    final enabled = playbackSpatialAudio.value;
    _spatialAudioSent = enabled;
    try {
      await _channel.invokeMethod<void>('setSpatialAudio', {
        'playerId': playerId,
        'enabled': enabled,
      });
    } on PlatformException catch (error) {
      _log.w('Spatial audio setting unavailable: ${error.code}');
    } on MissingPluginException {
      // An older native player: the platform default (auto) stays.
    }
  }

  void _skipSilenceChanged() {
    final created = _created;
    if (_disposed || created == null) return;
    unawaited(
      created.then((_) async {
        if (_disposed || playbackSkipSilence.value == _skipSilenceSent) return;
        await _sendSkipSilence();
      }, onError: (Object _) {}),
    );
  }

  /// Applies live. The native side decodes to 16-bit while it is on, which
  /// a song already decoding to float adopts from its next decoder start.
  Future<void> _sendSkipSilence() async {
    final enabled = playbackSkipSilence.value;
    _skipSilenceSent = enabled;
    try {
      await _channel.invokeMethod<void>('setSkipSilence', {
        'playerId': playerId,
        'enabled': enabled,
      });
    } on PlatformException catch (error) {
      _log.w('Skip silence unavailable: ${error.code}');
    } on MissingPluginException {
      // An older native player: silence plays as before.
    }
  }

  /// Calls [method] for this player, creating it first. Null once disposed.
  Future<T?> _invoke<T>(
    String method, [
    Map<String, Object?> arguments = const {},
  ]) async {
    if (_disposed) return null;
    await _ensureCreated();
    if (_disposed) return null;
    return _channel.invokeMethod<T>(method, {
      'playerId': playerId,
      ...arguments,
    });
  }

  void _setState(PlaybackDeckState value) {
    if (_state == value || _disposed) return;
    _state = value;
    _syncPositionTimer();
    _states.add(value);
  }

  void _onEvent(dynamic event) {
    if (_disposed || event is! Map) return;
    switch (event['event']) {
      case 'state':
        // A source still preparing replies through setSource.
        final state = _eventState(event['state']);
        if (state != null && _preparation == null) _setState(state);
      case 'duration':
        final milliseconds = event['durationMs'];
        if (milliseconds is num && milliseconds > 0) {
          _duration = Duration(milliseconds: milliseconds.toInt());
          _durations.add(_duration!);
        }
      case 'transition':
        final next = _next;
        _next = null;
        if (next == null) {
          _log.w('A queued song started that is no longer expected');
          return;
        }
        _gain = next.volume;
        _duration = null;
        if (playbackOutputVolume.value != next.output) _outputVolumeChanged();
        if (_boostWanted != _boostAsked) _equalizerChanged();
        next.onStarted();
      case 'trace':
        // The decoder and output the phone used; no path or title.
        _log.i('Engine: ${event['message']}');
      case 'completed':
        _next = null;
        _setState(PlaybackDeckState.completed);
        _completions.add(null);
      case 'error':
        // Preparation failures fail setSource instead.
        if (_preparation != null) return;
        final failure = Media3PlaybackException(
          event['message'] as String? ?? 'Android could not play this audio.',
          errorCode: event['errorCode'] as String?,
          prepared: event['prepared'] == true,
        );
        final stack = StackTrace.current;
        _failure = AsyncError(failure, stack);
        _loaded = false;
        _next = null;
        // The native player is left paused; the error tells the runtime.
        _state = PlaybackDeckState.paused;
        _syncPositionTimer();
        _states.addError(failure, stack);
    }
  }

  @override
  void startPositionUpdates(Duration interval, {bool Function()? wanted}) {
    _positionInterval = interval;
    _positionWanted = wanted;
    _positionTimer?.cancel();
    _positionTimer = null;
    _syncPositionTimer();
  }

  /// Positions are read only while playing, so an idle deck does not wake
  /// the isolate. A timer rather than frames: AutoMix runs with the display
  /// asleep.
  void _syncPositionTimer() {
    final interval = _positionInterval;
    if (_disposed || interval == null || _state != PlaybackDeckState.playing) {
      _positionTimer?.cancel();
      _positionTimer = null;
      return;
    }
    _positionTimer ??= Timer.periodic(interval, (_) async {
      if (_polling || _disposed || !(_positionWanted?.call() ?? true)) return;
      _polling = true;
      final token = _token;
      try {
        final position = await getCurrentPosition();
        if (!_disposed && token == _token && position != null) {
          _positions.add(position);
        }
      } on PlatformException catch (error) {
        _log.w('Position unavailable: ${error.code}');
      } finally {
        _polling = false;
      }
    });
  }

  /// The player is configured once, when it is created: music attributes,
  /// no audio focus (the app owns it) and offload off.
  @override
  Future<void> configureOutput() =>
      _disposed ? Future.value() : _ensureCreated();

  double get _volume => _playerVolume(_gain);

  /// The player's own volume for [gain]: what is left below the raise the
  /// equalizer stage carries.
  double _playerVolume(double gain) =>
      ((gain / math.pow(10, _boostDb / 20)).clamp(0.0, 1.0) *
              playbackOutputVolume.value)
          .clamp(0.0, 1.0);

  /// The raise above full volume [setVolume] asks for, in dB.
  double get _boostWanted => _boostRefused ? 0 : normalizationBoostDb(_gain);

  /// The raise last sent, and the one the equalizer stage carries.
  double _boostAsked = 0;
  double _boostDb = 0;
  bool _boostRefused = false;

  Future<void> _setBoost(double db) async {
    if (db == _boostDb) return;
    _boostDb = db;
    if (!_disposed && _created != null) {
      await _invoke<void>('setVolume', {'volume': _volume});
    }
  }

  @override
  Future<void> setVolume(double volume) async {
    _gain = volume;
    // Until the equalizer takes a new raise the song stays at or below what
    // is asked.
    if (_boostWanted != _boostAsked) _equalizerChanged();
    await _invoke<void>('setVolume', {'volume': _volume});
  }

  void _outputVolumeChanged() {
    if (_disposed || _created == null) return;
    unawaited(
      _invoke<void>('setVolume', {
        'volume': _volume,
      }).catchError((Object error) => _log.w('Output volume: $error')),
    );
  }

  @override
  Future<void> setPlaybackRate(double rate) async {
    if (rate <= 0) return;
    _rate = rate;
    if (_disposed) return;
    await _ensureCreated();
    if (_disposed) return;
    await _sendParameters();
  }

  @override
  Future<void> setNetworkSource(String url, {bool arriving = false}) =>
      _load(url, isLocal: false);

  @override
  Future<void> setFileSource(
    String path, {
    bool preferBitPerfect = false,
    bool directUsb = false,
    bool allowDop = false,
    bool requiresDsd = false,
    bool allowFixedVolume = false,
    bool dapExclusive = false,
    int usbMaxSampleRate = 0,
    bool usbDitherHighPass = false,
  }) async {
    // ExoPlayer has no DSD decoder; the USB output on audioplayers plays it.
    if (requiresDsd) {
      await stop();
      throw UsbDsdUnavailable();
    }
    await _load(path, isLocal: true);
  }

  Future<void> _load(String uri, {required bool isLocal}) async {
    await stop();
    if (_disposed) return;
    final token = ++_token;
    _failure = null;
    _loaded = false;
    _duration = null;
    // A refused raise is tried again once per song.
    _boostRefused = false;
    if (_boostWanted != _boostAsked) _equalizerChanged();
    final abandoned = _preparation = Completer<void>();
    Map<Object?, Object?>? reply;
    try {
      // A newer source, clearSource, stop or dispose fails this call with
      // `superseded`; cancelPreparation also stops waiting for it at once.
      reply = await Future.any([
        _invoke<Map<Object?, Object?>>('setSource', {
          'uri': uri,
          'isLocal': isLocal,
        }),
        abandoned.future.then((_) => null),
      ]);
    } on PlatformException catch (error, stack) {
      if (_disposed || token != _token || error.code == 'superseded') return;
      _failure = AsyncError(error, stack);
      rethrow;
    } finally {
      if (identical(_preparation, abandoned)) _preparation = null;
    }
    if (_disposed || token != _token || abandoned.isCompleted) return;
    _loaded = true;
    final milliseconds = reply?['durationMs'];
    if (milliseconds is num && milliseconds > 0) {
      _duration = Duration(milliseconds: milliseconds.toInt());
      _durations.add(_duration!);
    }
    // The song must not start before the equalizer applies to it.
    await _equalizerWrite;
  }

  @override
  Future<void> cancelPreparation() async {
    final preparation = _preparation;
    if (preparation == null) return;
    _token++;
    _preparation = null;
    preparation.complete();
    try {
      await _invoke<void>('clearSource');
    } on PlatformException catch (error) {
      _log.w('Could not abandon the source: ${error.code}');
    }
  }

  void _throwFailure() {
    final failure = _failure;
    if (failure != null) {
      Error.throwWithStackTrace(failure.error, failure.stackTrace);
    }
  }

  @override
  Future<void> resume() async {
    _throwFailure();
    if (_disposed || !_loaded) return;
    final token = _token;
    await _invoke<void>('play');
    _throwFailure();
    if (token == _token && _loaded) _setState(PlaybackDeckState.playing);
  }

  @override
  Future<void> pause() async {
    if (_disposed || _created == null) return;
    final token = _token;
    await _invoke<void>('pause');
    if (_disposed || token != _token) return;
    if (_state == PlaybackDeckState.playing) {
      _setState(PlaybackDeckState.paused);
    }
    final position = await getCurrentPosition();
    if (!_disposed && token == _token && position != null) {
      _positions.add(position);
    }
  }

  @override
  Future<void> seek(Duration position) async {
    if (_disposed) return;
    await _invoke<void>('seek', {'positionMs': position.inMilliseconds});
    if (!_disposed) _positions.add(position);
  }

  @override
  Future<void> stop() async {
    _token++;
    final queued = _next != null;
    _next = null;
    final preparation = _preparation;
    _preparation = null;
    preparation?.complete();
    if (_disposed || _created == null) return;
    await _invoke<void>('stop');
    // The prepared source stays loaded, and so would a song queued after it.
    if (queued) await _invoke<void>('clearNext');
    _setState(PlaybackDeckState.stopped);
  }

  @override
  Future<bool> queueNextSource(
    String source, {
    required double volume,
    required void Function() onStarted,
  }) async {
    if (!canQueueNextSource) return false;
    final token = _token;
    final output = playbackOutputVolume.value;
    final next = _next = (volume: volume, output: output, onStarted: onStarted);
    var queued = false;
    try {
      queued =
          await _invoke<bool>('queueNext', {
            'uri': source,
            'isLocal': !const {
              'http',
              'https',
            }.contains(Uri.tryParse(source)?.scheme),
            // At the raise playing now; the next one follows the transition.
            'volume': _playerVolume(volume),
          }) ??
          false;
    } on PlatformException catch (error) {
      _log.w('Next song not queued: ${error.code}');
    }
    final current = !_disposed && token == _token && identical(_next, next);
    if (queued && current) return true;
    if (identical(_next, next)) _next = null;
    return false;
  }

  @override
  Future<void> clearNextSource() async {
    _next = null;
    if (_disposed || _created == null) return;
    try {
      await _invoke<void>('clearNext');
    } on PlatformException catch (error) {
      _log.w('Could not clear the next song: ${error.code}');
    }
  }

  /// The plugin's own queue joins songs on one player; it cannot hand its
  /// output to another deck.
  @override
  Future<bool> setNextDeck(PlaybackDeck? next) async => false;

  @override
  Future<Duration?> getCurrentPosition() async {
    if (_disposed) return null;
    if (_created == null) return Duration.zero;
    final milliseconds = await _invoke<num>('getPosition');
    return milliseconds == null
        ? null
        : Duration(milliseconds: milliseconds.toInt());
  }

  @override
  Future<Duration?> getDuration() async {
    if (_disposed || _created == null) return _duration;
    final milliseconds = await _invoke<num>('getDuration');
    return milliseconds == null || milliseconds <= 0
        ? _duration
        : Duration(milliseconds: milliseconds.toInt());
  }

  void _equalizerChanged() {
    _equalizerTimer ??= Timer(const Duration(milliseconds: 32), () {
      _equalizerTimer = null;
      _equalizerWrite = _equalizerWrite.then((_) => _syncEqualizer());
    });
  }

  Future<void> _syncEqualizer() async {
    if (_disposed) return;
    final settings = playbackEqualizer.value;
    final asked = _boostWanted;
    final boosted = boostEqualizer(settings, asked);
    if (!boosted.settings.enabled && !_equalizerSent) {
      _boostAsked = asked;
      reportEqualizerError(playerId, null);
      await _setBoost(0);
      return;
    }
    // Creating the player applies the equalizer.
    if (_created == null) return;
    _boostAsked = asked;
    try {
      // A higher raise lowers the player first and a lower one waits for the
      // equalizer, so the song never plays louder than asked.
      if (boosted.boostDb > _boostDb) await _setBoost(boosted.boostDb);
      await _invoke<void>('setEqualizer', {
        'configuration': {
          ...boosted.settings.toNative(),
          // Kept out of the filters' integer PCM, ahead of the limiter.
          if (boosted.boostDb > 0) 'boostGain': boosted.boostDb,
        },
      }).timeout(const Duration(seconds: 3));
      if (_disposed) return;
      _equalizerSent = true;
      reportEqualizerError(playerId, null);
      await _setBoost(boosted.boostDb);
    } catch (error) {
      if (_disposed) return;
      // Without the effect (before Android 9) the song stays at full volume.
      if (boosted.boostDb > 0 && !settings.enabled) _boostRefused = true;
      await _setBoost(0);
      if (settings.enabled) {
        reportEqualizerError(
          playerId,
          'Equalizer is unavailable on this output: $error',
        );
      }
    }
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    playbackEqualizer.removeListener(_equalizerChanged);
    playbackOutputVolume.removeListener(_outputVolumeChanged);
    playbackSkipSilence.removeListener(_skipSilenceChanged);
    playbackSpatialAudio.removeListener(_spatialAudioChanged);
    playbackSpeed.removeListener(_parametersChanged);
    playbackPitch.removeListener(_parametersChanged);
    _equalizerTimer?.cancel();
    reportEqualizerError(playerId, null);
    _disposed = true;
    _token++;
    _next = null;
    final preparation = _preparation;
    _preparation = null;
    preparation?.complete();
    _positionTimer?.cancel();
    _positionTimer = null;
    _state = PlaybackDeckState.disposed;
    await _events?.cancel();
    final created = _created;
    if (created != null) {
      try {
        await created;
        await _channel.invokeMethod<void>('dispose', {'playerId': playerId});
      } on MissingPluginException {
        // Nothing was created.
      } on PlatformException catch (error) {
        _log.w('Could not release the player: ${error.code}');
      }
    }
    await _states.close();
    await _durations.close();
    await _positions.close();
    await _completions.close();
  }
}

/// Android's music deck: audioplayers, or media3 while
/// [playbackMedia3Engine] is on. Sources for the native USB and AAudio
/// outputs ([DeckSource.needsNativeOutput]) stay on audioplayers, which hosts
/// them, as do streams media3 may not fetch ([media3CanFetch]), and so does
/// everything when this build has no media3 player.
///
/// Each source picks its engine as it loads, so turning the setting on or
/// off applies from the next song; the song playing keeps its engine. It
/// cannot reopen elsewhere safely: a SAF song plays from a descriptor lease
/// that closes once it loaded, and Android may give that descriptor number
/// to another file.
class Media3EngineDeck extends SwitchingPlaybackDeck {
  Media3EngineDeck({
    required PlaybackDeck audioplayers,
    required PlaybackDeck Function() createMedia3,
  }) : super(primary: audioplayers, createAlternate: createMedia3);

  @override
  String get switchName => 'media3 engine';

  @override
  bool get reloadsOnChange => false;

  @override
  bool get routesEachSource => true;

  @override
  bool wantsAlternate(DeckSource? source) =>
      playbackMedia3Engine.value &&
      Media3PlaybackDeck.isAvailable &&
      !(source?.needsNativeOutput ?? false) &&
      (source == null || media3CanFetch(source.location));

  /// Only media3 queues. A song it may not fetch is left to the ordinary
  /// handoff, which opens it on audioplayers.
  @override
  Future<bool> queueNextSource(
    String source, {
    required double volume,
    required void Function() onStarted,
  }) async {
    if (!media3CanFetch(source)) return false;
    return super.queueNextSource(source, volume: volume, onStarted: onStarted);
  }

  @override
  bool alternateUnavailable(Object error) => error is MissingPluginException;
}
