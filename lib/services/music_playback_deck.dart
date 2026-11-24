import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

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
    this.codec,
    this.lossy = false,
    this.sourceBitDepth,
    this.channels,
    this.outputSampleRate,
  });

  /// A native reply that did not start the output. Keeps the specific
  /// reason and the source or DAC format the label names.
  factory UsbAudioStatus.failure(Map<String, dynamic>? reply) => UsbAudioStatus(
    reason: reply?['reason'] as String? ?? 'unsupported',
    sampleRate: (reply?['sampleRate'] as num?)?.toInt(),
    bitDepth: (reply?['bitDepth'] as num?)?.toInt(),
    codec: reply?['codec'] as String?,
    lossy: reply?['lossy'] == true,
    sourceBitDepth: (reply?['sourceBitDepth'] as num?)?.toInt(),
    channels: (reply?['channels'] as num?)?.toInt(),
  );

  final String reason;
  final String? device;
  final int? sampleRate;

  /// The depth sent to the DAC; for a refused format, the depth asked for.
  final int? bitDepth;
  final String transport;
  final String driver;

  /// The source codec, such as FLAC, ALAC or AAC, when native reports it.
  final String? codec;

  /// A lossy source decoded by the phone: the transport may be direct, but
  /// the chain is not bit-perfect to a lossless original.
  final bool lossy;
  final int? sourceBitDepth;
  final int? channels;

  /// The rate sent to the DAC when it refused the song's own [sampleRate]
  /// and the song is converted: the chain is not bit-perfect. Null otherwise.
  final int? outputSampleRate;
}

final AudioContext _musicAudioContext = AudioContext(
  android: const AudioContextAndroid(
    audioFocus: AndroidAudioFocus.none,
    contentType: AndroidContentType.music,
    usageType: AndroidUsageType.media,
    stayAwake: true,
  ),
);

/// audioplayers' [TimerPositionUpdater], except that a tick [wanted] answers
/// false for asks the platform nothing. The updates the plugin requests
/// itself, after a load, seek, pause or stop, always read the position.
class _PositionTicker extends PositionUpdater {
  _PositionTicker({
    required super.getPosition,
    required this.interval,
    this.wanted,
  });

  final Duration interval;
  final bool Function()? wanted;
  final _positions = StreamController<Duration>.broadcast();
  Timer? _timer;
  bool _polling = false;
  bool _disposed = false;

  @override
  Stream<Duration> get positionStream => _positions.stream;

  @override
  Future<void> update() async {
    final position = await getPosition();
    // A retired updater has already closed its stream when a slow reply
    // arrives. Check immediately before publishing it.
    if (!_disposed && position != null) _positions.add(position);
  }

  @override
  void start() {
    _timer?.cancel();
    _timer = Timer.periodic(interval, (_) async {
      if (_polling || !(wanted?.call() ?? true)) return;
      _polling = true;
      try {
        await update();
      } finally {
        _polling = false;
      }
    });
  }

  @override
  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  @override
  Future<void> dispose() async {
    _disposed = true;
    await super.dispose();
    await _positions.close();
  }
}

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
    bool? spatialAudioAvailable,
    bool? pitchAvailable,
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
       // Both forks carry `setSpatialAudio`.
       _spatialAudioAvailable =
           spatialAudioAvailable ??
           (Platform.isAndroid ||
               Platform.isIOS ||
               (isDesktopPlatform && Platform.isMacOS)),
       // Both forks carry `setPitch`; the Windows and Linux plugins (the
       // fallback without libmpv) change only the speed.
       _pitchAvailable =
           pitchAvailable ??
           (Platform.isAndroid ||
               Platform.isIOS ||
               (isDesktopPlatform && Platform.isMacOS)),
       _nativeAvailable = nativeAvailable ?? Platform.isAndroid {
    playbackEqualizer.addListener(_equalizerChanged);
    playbackOutputVolume.addListener(_outputVolumeChanged);
    playbackSpatialAudio.addListener(_spatialAudioChanged);
    playbackSpeed.addListener(_speedChanged);
    playbackPitch.addListener(_pitchChanged);
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

  /// Lets the next Direct USB song ask for USB access again after the user
  /// declined it this session.
  static Future<void> forgetUsbPermissionDenial() async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod<void>('forgetPermissionDenial');
    } on PlatformException catch (_) {
      // No USB plugin; nothing was remembered.
    } on MissingPluginException catch (_) {}
  }

  /// Hands a Direct USB DAC back at the level it connected with and lets go
  /// of it. Only while nothing plays (playback ended, or sat paused): Direct
  /// USB lowers that level, and no song may run on at the higher one.
  static Future<void> endUsbSession() async {
    try {
      await _channel.invokeMethod<void>('endSession');
    } on PlatformException catch (_) {
      // The level stays where playback left it.
    } on MissingPluginException catch (_) {}
  }

  /// Whether the phone rings or a call is under way, in any app. False when
  /// the platform cannot say.
  static Future<bool> callActive() async {
    try {
      return await _channel.invokeMethod<bool>('callActive') ?? false;
    } on PlatformException catch (_) {
      return false;
    } on MissingPluginException catch (_) {
      return false;
    }
  }

  /// Whether the output a bit-perfect song would open is connected. True
  /// when the platform cannot say.
  static Future<bool> bitPerfectOutputPresent({
    required bool directUsb,
    required bool dapExclusive,
  }) async {
    try {
      return await _channel.invokeMethod<bool>('outputPresent', {
            'direct': directUsb,
            'dapExclusive': dapExclusive,
          }) ??
          true;
    } on PlatformException catch (_) {
      return true;
    } on MissingPluginException catch (_) {
      return true;
    }
  }

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
    final own = settings.copyWith(
      enabled:
          settings.enabled &&
          !_direct &&
          // Android's own equalizer is a bank of fixed bands:
          // the filters need the media3 deck's DSP.
          !(settings.parametric &&
              defaultTargetPlatform == TargetPlatform.android),
    );
    final asked = _boostWanted;
    _boostAsked = asked;
    final boosted = boostEqualizer(own, asked);
    if (!boosted.settings.enabled && !_equalizerSent) {
      reportEqualizerError(_ordinary.playerId, null);
      await _setBoost(0);
      return;
    }
    try {
      // Public API waits for native player creation without changing playback.
      if (!_equalizerSent) await _ordinary.getDuration();
      if (_disposed || _equalizerDisposed) return;
      // A higher raise lowers the player first and a lower one waits for the
      // equalizer, so the song never plays louder than asked.
      if (boosted.boostDb > _boostDb) await _setBoost(boosted.boostDb);
      await _effects
          .invokeMethod<void>('setEqualizer', {
            'playerId': _ordinary.playerId,
            'configuration': boosted.settings.toNative(),
          })
          .timeout(const Duration(seconds: 3));
      if (_disposed || _equalizerDisposed) return;
      _equalizerSent = true;
      reportEqualizerError(_ordinary.playerId, null);
      await _setBoost(boosted.boostDb);
    } catch (error) {
      if (_disposed || _equalizerDisposed) return;
      // Without the effect (before Android 9) the song stays at full volume.
      if (boosted.boostDb > 0 && !own.enabled) _boostRefused = true;
      await _setBoost(0);
      if (settings.enabled) {
        reportEqualizerError(
          _ordinary.playerId,
          'Equalizer is unavailable on this output: $error',
        );
      }
    }
  }

  /// The raise above full volume [setVolume] asks for, in dB, that the
  /// equalizer stage may carry.
  double get _boostWanted => _equalizerAvailable && !_direct && !_boostRefused
      ? normalizationBoostDb(_gain)
      : 0;

  /// The raise last sent, and the one the equalizer stage carries.
  double _boostAsked = 0;
  double _boostDb = 0;
  bool _boostRefused = false;

  Future<void> _setBoost(double db) async {
    if (db == _boostDb) return;
    _boostDb = db;
    if (!_direct && !_disposed) await _ordinary.setVolume(_playerVolume);
  }

  /// The player's own volume: what [setVolume] asks for below the raise.
  double get _playerVolume =>
      (_gain / math.pow(10, _boostDb / 20)).clamp(0.0, 1.0) *
      playbackOutputVolume.value;

  final bool _spatialAudioAvailable;

  /// Both forks start a player with spatialization allowed; only a change
  /// from that is sent.
  bool _spatialAudioSent = true;
  Future<void> _spatialAudioWrite = Future.value();

  void _spatialAudioChanged() {
    _spatialAudioWrite = _spatialAudioWrite.then((_) => _syncSpatialAudio());
  }

  /// Android's MediaPlayer takes it from the next source; the Darwin fork
  /// also sets it on the current item.
  Future<void> _syncSpatialAudio() async {
    if (!_spatialAudioAvailable || _disposed) return;
    final enabled = playbackSpatialAudio.value;
    if (enabled == _spatialAudioSent) return;
    _spatialAudioSent = enabled;
    try {
      // Public API waits for native player creation without changing playback.
      await _ordinary.getDuration();
      if (_disposed) return;
      await _effects
          .invokeMethod<void>('setSpatialAudio', {
            'playerId': _ordinary.playerId,
            'enabled': enabled,
          })
          .timeout(const Duration(seconds: 3));
    } catch (error) {
      _log.w('Spatial audio setting unavailable: $error');
    }
  }

  final bool _pitchAvailable;

  /// Both forks start a player without a shift, its pitch kept while the
  /// speed changes; only a change from that is sent. Null when unknown
  /// after a failed send.
  PlaybackPitch? _pitchSent = PlaybackPitch.none;
  Future<void> _pitchWrite = Future.value();

  /// True while the fork refused [playbackPitch] for the current source.
  bool _pitchFailed = false;

  void _pitchChanged() {
    _pitchWrite = _pitchWrite.then((_) => _syncPitch());
  }

  /// The fork keeps the values for this player and applies them to the
  /// current source and every later one, also when the rate changes.
  Future<void> _syncPitch() async {
    if (!_pitchAvailable || _disposed) return;
    final pitch = playbackPitch.value;
    if (pitch == _pitchSent) return;
    _pitchSent = pitch;
    try {
      // Public API waits for native player creation without changing playback.
      await _ordinary.getDuration();
      if (_disposed) return;
      await _effects
          .invokeMethod<void>('setPitch', {
            'playerId': _ordinary.playerId,
            'semitones': pitch.semitones,
            'followsRate': pitch.followsRate,
          })
          .timeout(const Duration(seconds: 3));
      _setPitchFailed(false);
    } catch (error) {
      _log.w('Pitch unavailable for this source: $error');
      // Sent again with the next change or source.
      _pitchSent = null;
      if (!_disposed) _setPitchFailed(true);
    }
  }

  void _setPitchFailed(bool failed) {
    if (failed == _pitchFailed) return;
    _pitchFailed = failed;
    if (!_direct) notifyPlaybackTempoSupportChanged();
  }

  /// The rate [setPlaybackRate] gave, before [playbackSpeed].
  double _rate = 1;

  /// The rate the ordinary player was given last.
  double _rateSent = 1;

  double get _effectiveRate => _rate * playbackSpeed.value;

  Future<void> _syncRate() async {
    if (_direct || _disposed) return;
    final rate = _effectiveRate;
    _rateSent = rate;
    // The forks apply it once playing; a paused player stays paused.
    await _ordinary.setPlaybackRate(rate);
  }

  void _speedChanged() {
    if (_direct || _disposed) return;
    unawaited(
      _syncRate().catchError((Object error) => _log.w('Speed: $error')),
    );
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
  Duration _positionInterval = const Duration(milliseconds: 200);
  bool Function()? _positionWanted;
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

  /// How long a Direct USB song that is not playing keeps the DAC. Holding
  /// it leaves every other app without sound through that DAC.
  @visibleForTesting
  static Duration usbIdleRelease = const Duration(seconds: 5);
  Timer? _idleTimer;
  int _idleEpoch = 0;

  /// Where the song stood when the idle DAC was let go; play reloads there.
  Duration? _releasedAt;

  @override
  bool get isDirect => _direct;
  @override
  PlaybackTempoSupport get tempoSupport => _direct
      ? PlaybackTempoSupport.none
      : !_pitchAvailable || _pitchFailed
      ? PlaybackTempoSupport.speedOnly
      : PlaybackTempoSupport.full;
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
  void startPositionUpdates(Duration interval, {bool Function()? wanted}) {
    _positionInterval = interval;
    _positionWanted = wanted;
    _ordinary.positionUpdater = _PositionTicker(
      interval: interval,
      wanted: wanted,
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
    // Until the equalizer takes a new raise the song stays at or below what
    // is asked.
    if (_boostWanted != _boostAsked) _equalizerChanged();
    await _ordinary.setVolume(_playerVolume);
  }

  void _outputVolumeChanged() {
    if (_direct || _disposed) return;
    unawaited(
      _ordinary
          .setVolume(_playerVolume)
          .catchError((Object error) => _log.w('Output volume: $error')),
    );
  }

  /// Direct (USB) output plays at the source's own rate.
  @override
  Future<void> setPlaybackRate(double rate) async {
    _rate = rate;
    await _syncRate();
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
    int usbMaxSampleRate = 0,
    bool usbDitherHighPass = false,
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
      usbAudioStatus.value = const UsbAudioStatus(reason: 'preparing');
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
              'maxSampleRate': usbMaxSampleRate,
              'ditherHighPass': usbDitherHighPass,
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
            codec: response?['codec'] as String?,
            lossy: response?['lossy'] == true,
            sourceBitDepth: (response?['sourceBitDepth'] as num?)?.toInt(),
            outputSampleRate: response?['resampled'] == true
                ? (response?['carrierRate'] as num?)?.toInt()
                : null,
          );
          final codec = _preparedStatus.codec;
          final outputRate = _preparedStatus.outputSampleRate;
          _log.i(
            'Native output prepared: ${_preparedStatus.driver}, '
            '${_preparedStatus.sampleRate} Hz, ${_preparedStatus.bitDepth}-bit'
            '${codec == null ? '' : ', $codec'}'
            '${_preparedStatus.lossy ? ' (lossy source)' : ''}'
            '${outputRate == null ? '' : ', resampled to $outputRate Hz'}',
          );
          // A DAC level that falls from one song to the next shows here:
          // what the DAC read when opened against what the app set last.
          if (response?['volumeTrace'] case final Map<Object?, Object?> trace
              when volume is Map) {
            _log.i(
              'DAC volume: connected at ${trace['connectedDb']} dB, '
              'remembered ${trace['rememberedDb']} dB, '
              'released ${trace['sinceReleaseMs']} ms ago, '
              'playing at ${volume['currentDb']} dB '
              '(${volume['minDb']} to ${volume['maxDb']} dB)',
            );
          }
          usbAudioStatus.value = _volumeBlocked
              ? const UsbAudioStatus(reason: 'volume_unavailable')
              : const UsbAudioStatus(reason: 'ready');
          _durations.add(_duration!);
          // A song prepared and never started holds the DAC as well.
          _armIdleRelease();
          return;
        }
        usbAudioStatus.value = UsbAudioStatus.failure(response);
        // Every refusal is logged, also the ones without a detail (no DAC,
        // permission declined): the song then plays through Android's mixer.
        final detail = response?['detail'] as String?;
        _log.w(
          'Native output ${usbAudioStatus.value.reason}'
          '${detail == null || detail.isEmpty ? '' : ': $detail'}',
        );
        if (response?['fatal'] == true) {
          throw UsbDsdUnavailable();
        }
      } on PlatformException catch (error) {
        if (_disposed || preparingToken != _token) return;
        _log.w('Native output unsupported: ${error.message ?? error.code}');
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
    // Android's MediaPlayer reads its audio attributes as the source loads.
    _spatialAudioChanged();
    await _spatialAudioWrite;
    // A speed change while the direct output played did not reach it.
    if (_rateSent != _effectiveRate) await _syncRate();
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
    // A refused raise is tried again once per song.
    _boostRefused = false;
    await _syncEqualizer();
    // Sent again for each source with a shift: the fork answers whether
    // this one takes it (Darwin cannot shift protected audio or HLS).
    if (_pitchFailed || playbackPitch.value != PlaybackPitch.none) {
      _pitchSent = null;
    }
    _pitchChanged();
    await _pitchWrite;
  }

  /// Reconcile the display with the current native session without reopening it.
  Future<void> refreshNativeStatus() async {
    if (!_direct || _disposed || _preparing) return;
    final token = _token;
    try {
      final status = await _channel.invokeMapMethod<String, dynamic>('status');
      if (_disposed ||
          !_direct ||
          token != _token ||
          status?['token'] != token) {
        return;
      }
      final reason = status?['reason'];
      if (reason == 'active') {
        if (usbAudioStatus.value.reason != 'active') {
          _log.i(
            'Native output status reconciled: ${_preparedStatus.driver} active',
          );
        }
        usbAudioStatus.value = _preparedStatus;
      } else if (reason == 'ready' || reason == 'volume_unavailable') {
        if (usbAudioStatus.value.reason != reason) {
          usbAudioStatus.value = UsbAudioStatus(reason: reason as String);
        }
      } else if (reason == 'route_changed' || reason == 'idle') {
        if (!_routeLost) {
          _log.w('Native output paused: status read back as $reason');
          _pauseLostRoute(const UsbAudioStatus(reason: 'route_changed'));
        }
      }
    } on MissingPluginException {
      // An older native build has no read-only status query.
    } on PlatformException catch (error) {
      _log.w('Cannot refresh native output status: ${error.code}');
    }
  }

  void _onNativeEvent(dynamic event) {
    if (_disposed || !_direct || event is! Map || event['token'] != _token) {
      return;
    }
    switch (event['event']) {
      case 'active':
        usbAudioStatus.value = _preparedStatus;
      case 'paused':
        // Why the output stopped on its own, for a tester's exported log.
        _log.w(
          'Native output paused: ${event['reason']}'
          '${event['detail'] is String ? ': ${event['detail']}' : ''}',
        );
        _routeLost = true;
        _timer?.cancel();
        _setState(PlaybackDeckState.paused);
        // A source that stopped decoding is not a lost USB route. Constant
        // values keep a repeated report from notifying listeners again.
        usbAudioStatus.value = event['reason'] == 'decode_failed'
            ? const UsbAudioStatus(reason: 'decode_failed')
            : const UsbAudioStatus(reason: 'route_changed');
      case 'complete':
        _timer?.cancel();
        _setState(PlaybackDeckState.completed);
        _armIdleRelease();
        _completions.add(null);
    }
  }

  void _setState(PlaybackDeckState value) {
    _directState = value;
    if (!_disposed) _states.add(value);
  }

  void _cancelIdleRelease() {
    _idleEpoch++;
    _idleTimer?.cancel();
    _idleTimer = null;
  }

  void _armIdleRelease() {
    _idleTimer?.cancel();
    if (!_direct || _routeLost || _preparedStatus.driver != 'usb_direct') {
      return;
    }
    _idleTimer = Timer(usbIdleRelease, () => unawaited(_releaseIdle()));
  }

  /// Lets go of a Direct USB DAC that is not playing, at the level it
  /// connected with, so other apps play through it. Play reloads the song.
  Future<void> _releaseIdle() async {
    if (_disposed ||
        !_direct ||
        _routeLost ||
        _directState == PlaybackDeckState.playing) {
      return;
    }
    final token = _token;
    final epoch = _idleEpoch;
    final ended = _directState == PlaybackDeckState.completed;
    try {
      final position = ended ? Duration.zero : await getCurrentPosition();
      if (_disposed ||
          token != _token ||
          epoch != _idleEpoch ||
          !_direct ||
          _routeLost ||
          _directState == PlaybackDeckState.playing) {
        return;
      }
      // Set first: a play that arrives now reloads instead of resuming.
      _routeLost = true;
      _releasedAt = position ?? Duration.zero;
      await _channel.invokeMethod<void>('endSession');
      if (_disposed || token != _token || !_direct) return;
      usbHardwareVolume.value = null;
      usbAudioStatus.value = const UsbAudioStatus(reason: 'ready');
      _log.i('Native output released while idle: usb_direct');
    } on PlatformException catch (error) {
      _log.w('Idle USB output not released: ${error.message ?? error.code}');
    } on MissingPluginException {
      // An older native build keeps the DAC until the song stops.
    }
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
    _cancelIdleRelease();
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
    if (!_nativeStarted) {
      _log.i('Native output active: ${_preparedStatus.driver}');
    }
    _nativeStarted = true;
    _setState(PlaybackDeckState.playing);
    usbAudioStatus.value = _preparedStatus;
    _timer?.cancel();
    _timer = Timer.periodic(_positionInterval, (_) async {
      if (_polling || _disposed || !(_positionWanted?.call() ?? true)) return;
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
    if (token == _token && _direct) {
      _setState(PlaybackDeckState.paused);
      _armIdleRelease();
    }
  }

  @override
  Future<void> seek(Duration position) async {
    if (!_direct) return _ordinary.seek(position);
    if (_releasedAt != null) {
      // The DAC was let go while idle: play reloads the song from here.
      _releasedAt = position;
      _positions.add(position);
      return;
    }
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
    if (_releasedAt case final released?) return released;
    final milliseconds = await _channel.invokeMethod<int>('position');
    return milliseconds == null ? null : Duration(milliseconds: milliseconds);
  }

  @override
  Future<Duration?> getDuration() =>
      _direct ? Future.value(_duration) : _ordinary.getDuration();

  @override
  Future<void> stop() async {
    _timer?.cancel();
    _cancelIdleRelease();
    _releasedAt = null;
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
    playbackSpatialAudio.removeListener(_spatialAudioChanged);
    playbackSpeed.removeListener(_speedChanged);
    playbackPitch.removeListener(_pitchChanged);
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
