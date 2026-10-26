import 'dart:async';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:mornye/utils/logger.dart';
import 'package:mornye/services/playback_deck.dart';
import 'package:mornye/services/playback_equalizer.dart';

final _log = AppLogger('AudioOutput');

/// [url] marked for the Darwin audioplayers fork as a file still arriving.
/// The fork then prepares it without indexing its timing first, which would
/// read to the end of a file still being written and time out (see
/// third_party/audioplayers_darwin/MORNYE_PATCHES.md).
@visibleForTesting
String darwinArrivingUrl(String url) => '$url#mornye-arriving';

/// Only verified native playback reports active. File metadata alone never does.
final usbAudioStatus = ValueNotifier<UsbAudioStatus>(const UsbAudioStatus());

class UsbOutputUnavailable extends StateError {
  UsbOutputUnavailable(super.message);
}

class UsbDsdUnavailable extends UsbOutputUnavailable {
  UsbDsdUnavailable() : super('DSD requires a compatible direct USB output');
}

/// Null outside direct USB; an unavailable control must not change phone volume.
final usbHardwareVolume = ValueNotifier<UsbVolumeState?>(null);

class UsbVolumeState {
  UsbVolumeState(Map<dynamic, dynamic> data)
    : available = data['available'] == true,
      minDb = (data['minDb'] as num?)?.toDouble() ?? -90,
      maxDb = (data['maxDb'] as num?)?.toDouble() ?? 0,
      currentDb = (data['currentDb'] as num?)?.toDouble() ?? 0,
      token = (data['token'] as num?)?.toInt() ?? 0;
  final bool available;
  final double minDb, maxDb, currentDb;
  final int token;
  double get fraction => available && maxDb > minDb
      ? ((currentDb - minDb) / (maxDb - minDb)).clamp(0, 1)
      : 0;
}

Future<void> setUsbHardwareVolume(double fraction) async {
  final state = usbHardwareVolume.value;
  if (state == null || !state.available) return;
  final result = await AudioplayersPlaybackDeck._channel
      .invokeMapMethod<String, dynamic>('volume', {
        'token': state.token,
        'db': state.minDb + fraction.clamp(0, 1) * (state.maxDb - state.minDb),
      });
  if (result != null && usbHardwareVolume.value?.token == state.token) {
    usbHardwareVolume.value = UsbVolumeState(result);
  }
}

class UsbAudioStatus {
  const UsbAudioStatus({
    this.reason = 'idle',
    this.device,
    this.sampleRate,
    this.bitDepth,
    this.transport = 'pcm',
    this.driver = 'android',
  });

  final String reason;
  final String? device;
  final int? sampleRate;
  final int? bitDepth;
  final String transport;
  final String driver;
}

final AudioContext _musicAudioContext = AudioContext(
  android: const AudioContextAndroid(
    audioFocus: AndroidAudioFocus.none,
    contentType: AndroidContentType.music,
    usageType: AndroidUsageType.media,
    stayAwake: true,
  ),
);

PlaybackDeckState _deckState(PlayerState state) => switch (state) {
  PlayerState.stopped => PlaybackDeckState.stopped,
  PlayerState.playing => PlaybackDeckState.playing,
  PlayerState.paused => PlaybackDeckState.paused,
  PlayerState.completed => PlaybackDeckState.completed,
  PlayerState.disposed => PlaybackDeckState.disposed,
};

/// The audioplayers deck (Android, iOS, macOS), with Android's native USB
/// path. Each prepare owns a token so delayed native events cannot affect a
/// new song.
class AudioplayersPlaybackDeck implements PlaybackDeck {
  AudioplayersPlaybackDeck({
    required String playerId,
    bool? nativeAvailable,
    bool? equalizerAvailable,
  }) : _ordinary = AudioPlayer(playerId: playerId),
       // The Darwin fork's tap is shared source, so macOS has it as well.
       // isDesktopPlatform keeps host-run tests on the mobile default.
       _equalizerAvailable =
           equalizerAvailable ??
           (Platform.isAndroid ||
               Platform.isIOS ||
               (isDesktopPlatform && Platform.isMacOS)),
       _platformChainsPlayers =
           Platform.isAndroid ||
           Platform.isIOS ||
           (isDesktopPlatform && Platform.isMacOS),
       _nativeAvailable = nativeAvailable ?? Platform.isAndroid {
    playbackEqualizer.addListener(_equalizerChanged);
    playbackOutputVolume.addListener(_outputVolumeChanged);
    _subscriptions.addAll([
      _ordinary.onPlayerStateChanged.listen((value) {
        if (!_direct) _states.add(_deckState(value));
      }),
      _ordinary.eventStream.listen(
        (event) {
          if (_direct || _disposed) return;
          switch (event.eventType) {
            case AudioEventType.duration:
              _durations.add(event.duration!);
            case AudioEventType.complete:
              _completions.add(null);
            default:
              break;
          }
        },
        onError: (Object error, StackTrace stackTrace) {
          if (_direct || _disposed) return;
          _ordinaryError = AsyncError(error, stackTrace);
          _states.addError(error, stackTrace);
        },
      ),
    ]);
  }

  /// Forces [setNextDeck] support, for tests on any host.
  @visibleForTesting
  static bool? debugChainsPlayers;

  static const _channel = MethodChannel('com.zarz.mornye/usb_pcm');
  static const _events = EventChannel('com.zarz.mornye/usb_pcm/events');
  static Stream<dynamic>? _nativeEvents;
  static int _nextToken = 0;
  final AudioPlayer _ordinary;
  final bool _equalizerAvailable;
  final bool _platformChainsPlayers;
  bool get _chainsPlayers => debugChainsPlayers ?? _platformChainsPlayers;
  bool _equalizerDisposed = false;
  static const _effects = MethodChannel('xyz.luan/audioplayers');
  bool _equalizerSent = false;
  Timer? _equalizerTimer;
  Future<void> _equalizerWrite = Future.value();

  void _equalizerChanged() {
    _equalizerTimer ??= Timer(const Duration(milliseconds: 32), () {
      _equalizerTimer = null;
      _equalizerWrite = _equalizerWrite.then((_) => _syncEqualizer());
    });
  }

  Future<void> _syncEqualizer() async {
    if (_disposed || _equalizerDisposed) return;
    final settings = playbackEqualizer.value;
    if (!_equalizerAvailable) {
      // Windows and Linux get the equalizer with their own deck. Until then
      // the editor must not claim it is active.
      if (isDesktopPlatform) {
        reportEqualizerError(
          _ordinary.playerId,
          settings.enabled ? 'Equalizer is not available on this system' : null,
        );
      }
      return;
    }
    if (!settings.enabled && !_equalizerSent) {
      reportEqualizerError(_ordinary.playerId, null);
      return;
    }
    try {
      // Public API waits for native player creation without changing playback.
      if (!_equalizerSent) await _ordinary.getDuration();
      if (_disposed || _equalizerDisposed) return;
      await _effects
          .invokeMethod<void>('setEqualizer', {
            'playerId': _ordinary.playerId,
            'configuration': settings
                .copyWith(enabled: settings.enabled && !_direct)
                .toNative(),
          })
          .timeout(const Duration(seconds: 3));
      if (_disposed || _equalizerDisposed) return;
      _equalizerSent = true;
      reportEqualizerError(_ordinary.playerId, null);
    } catch (error) {
      if (!_disposed && !_equalizerDisposed && settings.enabled) {
        reportEqualizerError(
          _ordinary.playerId,
          'Equalizer is unavailable on this output: $error',
        );
      }
    }
  }

  final bool _nativeAvailable;
  final _states = StreamController<PlaybackDeckState>.broadcast();
  final _durations = StreamController<Duration>.broadcast();
  final _positions = StreamController<Duration>.broadcast();
  final _completions = StreamController<void>.broadcast();
  final _subscriptions = <StreamSubscription<dynamic>>[];
  AsyncError? _ordinaryError;
  StreamSubscription<dynamic>? _nativeSubscription;
  StreamSubscription<Duration>? _positionSubscription;
  Timer? _timer;
  bool _polling = false;
  bool _direct = false;
  bool _preparing = false;
  Completer<void>? _ordinaryPreparation;
  bool _disposed = false;
  int _token = 0;
  Duration? _duration;
  DeviceFileSource? _source;
  bool _routeLost = false;
  bool _nativeStarted = false;
  bool _volumeBlocked = false;
  double _gain = 1;
  PlaybackDeckState _directState = PlaybackDeckState.stopped;
  UsbAudioStatus _preparedStatus = const UsbAudioStatus();

  @override
  bool get isDirect => _direct;
  @override
  bool get needsSourceReload => _direct && _routeLost;
  @override
  Future<void> cancelPreparation() async {
    if (_preparing) await stop();
    final preparation = _ordinaryPreparation;
    if (preparation == null) return;
    _ordinaryPreparation = null;
    preparation.complete();
    await _ordinary.release();
  }

  @override
  PlaybackDeckState get state =>
      _direct ? _directState : _deckState(_ordinary.state);
  @override
  Stream<PlaybackDeckState> get onPlayerStateChanged => _states.stream;
  @override
  Stream<Duration> get onDurationChanged => _durations.stream;
  @override
  Stream<Duration> get onPositionChanged => _positions.stream;
  @override
  Stream<void> get onPlayerComplete => _completions.stream;

  @override
  void startPositionUpdates(Duration interval) {
    _ordinary.positionUpdater = TimerPositionUpdater(
      interval: interval,
      getPosition: getCurrentPosition,
    );
    unawaited(_positionSubscription?.cancel());
    _positionSubscription = _ordinary.onPositionChanged.listen((value) {
      if (!_direct) _positions.add(value);
    });
  }

  @override
  Future<void> configureOutput() async {
    await _ordinary.setReleaseMode(ReleaseMode.stop);
    // audioplayers has no audio context outside Android and iOS.
    if (Platform.isAndroid || Platform.isIOS) {
      await _ordinary.setAudioContext(_musicAudioContext);
    }
  }

  @override
  Future<void> setVolume(double volume) async {
    if (_direct) return;
    _gain = volume;
    await _ordinary.setVolume(volume * playbackOutputVolume.value);
  }

  void _outputVolumeChanged() {
    if (_direct || _disposed) return;
    unawaited(
      _ordinary
          .setVolume(_gain * playbackOutputVolume.value)
          .catchError((Object error) => _log.w('Output volume: $error')),
    );
  }

  @override
  Future<void> setPlaybackRate(double rate) async {
    if (!_direct) await _ordinary.setPlaybackRate(rate);
  }

  @override
  Future<void> setNetworkSource(String url, {bool arriving = false}) async {
    await stop();
    _source = null;
    _routeLost = false;
    _nativeStarted = false;
    await _setOrdinarySource(
      UrlSource(
        arriving && (Platform.isMacOS || Platform.isIOS)
            ? darwinArrivingUrl(url)
            : url,
      ),
    );
  }

  @override
  Future<void> setFileSource(
    String path, {
    bool preferBitPerfect = false,
    bool directUsb = false,
    bool allowDop = false,
    bool requiresDsd = false,
    bool allowFixedVolume = false,
    bool dapExclusive = false,
  }) async {
    await stop();
    final source = DeviceFileSource(path);
    _source = source;
    _routeLost = false;
    _nativeStarted = false;
    if (preferBitPerfect && _nativeAvailable) {
      _token = ++_nextToken;
      final preparingToken = _token;
      _preparing = true;
      _nativeSubscription ??=
          (_nativeEvents ??= _events.receiveBroadcastStream()).listen(
            _onNativeEvent,
            onError: (Object error) {
              if (_direct && !_disposed) {
                _routeLost = true;
                unawaited(pause().catchError((Object _) {}));
                usbAudioStatus.value = const UsbAudioStatus(
                  reason: 'route_changed',
                );
              }
            },
          );
      try {
        final response = await _channel
            .invokeMapMethod<String, dynamic>('prepare', {
              'path': source.path,
              'token': _token,
              'direct': directUsb,
              'allowDop': allowDop,
              'allowFixedVolume': allowFixedVolume,
              'dapExclusive': dapExclusive,
              'requiresDsd': requiresDsd,
            });
        if (_disposed || preparingToken != _token) return;
        if (response?['ready'] == true) {
          _volumeBlocked = response?['volumeBlocked'] == true;
          final volume = response?['volume'];
          usbHardwareVolume.value = volume is Map
              ? UsbVolumeState(volume)
              : null;
          _direct = true;
          _directState = PlaybackDeckState.stopped;
          _duration = Duration(
            milliseconds: (response?['duration'] as num?)?.toInt() ?? 0,
          );
          _preparedStatus = UsbAudioStatus(
            reason: 'active',
            device: response?['device'] as String?,
            sampleRate: (response?['sampleRate'] as num?)?.toInt(),
            bitDepth: (response?['bitDepth'] as num?)?.toInt(),
            transport: response?['transport'] as String? ?? 'pcm',
            driver: response?['driver'] as String? ?? 'android',
          );
          usbAudioStatus.value = UsbAudioStatus(
            reason: _volumeBlocked ? 'volume_unavailable' : 'ready',
          );
          _durations.add(_duration!);
          return;
        }
        usbAudioStatus.value = UsbAudioStatus(
          reason: response?['reason'] as String? ?? 'unsupported',
        );
        final detail = response?['detail'] as String?;
        if (detail != null && detail.isNotEmpty) {
          _log.w('Native output ${usbAudioStatus.value.reason}: $detail');
        }
        if (response?['fatal'] == true) {
          throw UsbDsdUnavailable();
        }
      } on PlatformException {
        if (_disposed || preparingToken != _token) return;
        usbAudioStatus.value = const UsbAudioStatus(reason: 'unsupported');
      } on MissingPluginException {
        if (_disposed || preparingToken != _token) return;
        usbAudioStatus.value = const UsbAudioStatus(reason: 'unsupported');
      } finally {
        if (preparingToken == _token) _preparing = false;
      }
    }
    if (requiresDsd) {
      usbAudioStatus.value = const UsbAudioStatus(reason: 'dsd_unsupported');
      throw UsbDsdUnavailable();
    }
    await _setOrdinarySource(source);
  }

  Future<void> _setOrdinarySource(Source source) async {
    // stop mode retains the native source. Android can reuse the same
    // /proc/self/fd number for a different SAF file, so URL equality must not
    // reuse the previous MediaPlayer or its pending preparation callbacks.
    await _ordinary.release();
    _ordinaryError = null;
    final abandoned = _ordinaryPreparation = Completer<void>();
    try {
      // A network source waits for its server, up to the plugin's prepare
      // timeout; a newer song abandons it instead of queueing behind it.
      await Future.any([_ordinary.setSource(source), abandoned.future]);
    } finally {
      if (identical(_ordinaryPreparation, abandoned)) {
        _ordinaryPreparation = null;
      }
    }
    if (abandoned.isCompleted) return;
    await _syncEqualizer();
  }

  void _onNativeEvent(dynamic event) {
    if (_disposed || !_direct || event is! Map || event['token'] != _token) {
      return;
    }
    switch (event['event']) {
      case 'active':
        usbAudioStatus.value = _preparedStatus;
      case 'paused':
        _routeLost = true;
        _timer?.cancel();
        _setState(PlaybackDeckState.paused);
        usbAudioStatus.value = const UsbAudioStatus(reason: 'route_changed');
      case 'complete':
        _timer?.cancel();
        _setState(PlaybackDeckState.completed);
        _completions.add(null);
    }
  }

  void _setState(PlaybackDeckState value) {
    _directState = value;
    if (!_disposed) _states.add(value);
  }

  void _pauseLostRoute(UsbAudioStatus status) {
    _routeLost = true;
    _setState(PlaybackDeckState.paused);
    usbAudioStatus.value = status;
  }

  @override
  Future<void> resume() async {
    if (!_direct) {
      void checkError() {
        final failure = _ordinaryError;
        if (failure != null) {
          Error.throwWithStackTrace(failure.error, failure.stackTrace);
        }
      }

      checkError();
      await _ordinary.resume();
      checkError();
      return;
    }
    if (_volumeBlocked) {
      usbAudioStatus.value = const UsbAudioStatus(reason: 'volume_unavailable');
      throw UsbOutputUnavailable(
        'DAC hardware volume unavailable; check audio output settings',
      );
    }
    final token = _token;
    // Before first playback the SAF lease is still open. After playback starts,
    // reconnect through the handler to obtain a fresh lease for the same song.
    try {
      if (_routeLost) throw PlatformException(code: 'route_changed');
      await _channel.invokeMethod<void>('resume');
    } on PlatformException {
      if (token != _token || !_direct || _disposed) return;
      if (_preparedStatus.driver == 'usb_direct') {
        _pauseLostRoute(const UsbAudioStatus(reason: 'route_changed'));
        throw UsbOutputUnavailable(
          'Direct USB output changed; reconnect before playing',
        );
      }
      if (_nativeStarted) {
        _pauseLostRoute(const UsbAudioStatus(reason: 'route_changed'));
        rethrow;
      }
      if (_preparedStatus.transport != 'pcm') {
        _pauseLostRoute(const UsbAudioStatus(reason: 'dsd_unsupported'));
        throw UsbDsdUnavailable();
      }
      final source = _source;
      final position = await getCurrentPosition() ?? Duration.zero;
      await stop();
      usbAudioStatus.value = const UsbAudioStatus(reason: 'unsupported');
      if (source == null || _disposed) return;
      _gain = 1;
      await _ordinary.setVolume(playbackOutputVolume.value);
      await _setOrdinarySource(source);
      if (position > Duration.zero) await _ordinary.seek(position);
      return _ordinary.resume();
    }
    if (_disposed || token != _token || !_direct) return;
    _nativeStarted = true;
    _setState(PlaybackDeckState.playing);
    usbAudioStatus.value = _preparedStatus;
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(milliseconds: 200), (_) async {
      if (_polling || _disposed) return;
      _polling = true;
      final token = _token;
      try {
        final position = await getCurrentPosition();
        if (!_disposed && _direct && token == _token && position != null) {
          _positions.add(position);
        }
      } on PlatformException {
        // Route failures arrive through the native event stream.
      } finally {
        _polling = false;
      }
    });
  }

  @override
  Future<void> pause() async {
    if (!_direct) return _ordinary.pause();
    final token = _token;
    _timer?.cancel();
    await _channel.invokeMethod<void>('pause');
    if (token == _token && _direct) _setState(PlaybackDeckState.paused);
  }

  @override
  Future<void> seek(Duration position) async {
    if (!_direct) return _ordinary.seek(position);
    final token = _token;
    await _channel.invokeMethod<void>('seek', {
      'position': position.inMilliseconds,
    });
    if (!_disposed && token == _token && _direct) _positions.add(position);
  }

  @override
  Future<bool> setNextDeck(PlaybackDeck? next) async {
    // The forks chain their own players: Android with
    // MediaPlayer.setNextMediaPlayer, Darwin from the end notification.
    if (_direct || !_chainsPlayers) return false;
    final player = next is AudioplayersPlaybackDeck && !next._direct
        ? next._ordinary
        : null;
    if (next != null && player == null) return false;
    try {
      await _effects.invokeMethod<void>('setNextPlayer', {
        'playerId': _ordinary.playerId,
        'nextPlayerId': ?player?.playerId,
      });
      return player != null;
    } on PlatformException catch (error) {
      _log.w('Next player link unavailable: $error');
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  @override
  Future<Duration?> getCurrentPosition() async {
    if (!_direct) return _ordinary.getCurrentPosition();
    final milliseconds = await _channel.invokeMethod<int>('position');
    return milliseconds == null ? null : Duration(milliseconds: milliseconds);
  }

  @override
  Future<Duration?> getDuration() =>
      _direct ? Future.value(_duration) : _ordinary.getDuration();

  @override
  Future<void> stop() async {
    _timer?.cancel();
    if (_direct || _preparing) {
      _token = ++_nextToken;
      _preparing = false;
      await _channel.invokeMethod<void>('stop');
      _setState(PlaybackDeckState.stopped);
      _direct = false;
      _volumeBlocked = false;
      usbHardwareVolume.value = null;
      usbAudioStatus.value = const UsbAudioStatus();
    }
    await _ordinary.stop();
  }

  @override
  Future<void> dispose() async {
    _equalizerDisposed = true;
    playbackEqualizer.removeListener(_equalizerChanged);
    playbackOutputVolume.removeListener(_outputVolumeChanged);
    _equalizerTimer?.cancel();
    reportEqualizerError(_ordinary.playerId, null);
    await stop();
    _disposed = true;
    await _nativeSubscription?.cancel();
    await _positionSubscription?.cancel();
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    await _ordinary.dispose();
    await _states.close();
    await _durations.close();
    await _positions.close();
    await _completions.close();
  }
}
