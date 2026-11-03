import 'dart:async';
import 'dart:math' as math;

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';
import 'package:mornye/models/equalizer_settings.dart';
import 'package:mornye/services/media_kit_audio_filters.dart';
import 'package:mornye/services/music_playback_deck.dart'
    show UsbDsdUnavailable;
import 'package:mornye/services/playback_deck.dart';
import 'package:mornye/services/playback_equalizer.dart';
import 'package:mornye/services/windows_audio_device_service.dart';
import 'package:mornye/utils/logger.dart';

final _log = AppLogger('MediaKitDeck');

/// An error-level line from libmpv's log.
typedef MpvLogError = ({String prefix, String text});

/// The libmpv operations [MediaKitPlaybackDeck] uses. [MediaKitEngine] is the
/// media_kit implementation; host tests substitute a fake.
abstract interface class MpvEngine {
  Stream<bool> get completed;
  Stream<Duration> get duration;
  Stream<int> get sampleRate;
  Stream<MpvLogError> get errors;
  Duration get position;

  /// Loads [source] paused.
  Future<void> open(String source);
  Future<void> play();
  Future<void> pause();
  Future<void> seek(Duration position);
  Future<void> stop();

  /// mpv's `volume` property, 0 to 100 on a cubic curve.
  Future<void> setVolume(double volume);
  Future<void> setSpeed(double speed);

  /// Returns the mpv error code: negative on failure.
  Future<int> setProperty(String name, String value);
  Future<String> getProperty(String name);

  /// Runs an mpv input command, such as `ao-reload`.
  Future<void> command(List<String> args);
  Future<void> dispose();
}

/// One libmpv instance through media_kit.
class MediaKitEngine implements MpvEngine {
  MediaKitEngine()
    : _player = NativePlayer(
        configuration: const PlayerConfiguration(title: 'Mornye'),
      ) {
    _configured = Future.wait([
      // Names the PulseAudio and PipeWire stream. The app applies ReplayGain
      // itself, so mpv's stays at its default (off).
      setProperty('audio-client-name', 'Mornye'),
      // media_kit caches streams on disk, which fails where the cache folder
      // is not writable and reports a load error. Memory is enough for audio.
      setProperty('cache-on-disk', 'no'),
      // Mornye reads sidecar lyrics itself. A failed mpv subtitle autoload
      // must not turn an otherwise playable song into a source error.
      setProperty('sub-auto', 'no'),
      // Each deck has one source. mpv's playlist gapless mode reports EOF
      // before its output drains, so handing off then cuts the queued tail.
      setProperty('gapless-audio', 'no'),
      // Room for an equalizer preamp of +12 dB applied through the volume
      // when the libmpv build has no volume filter.
      setProperty('volume-max', '200'),
    ]);
  }

  final NativePlayer _player;
  late final Future<void> _configured;

  @override
  Stream<bool> get completed => _player.stream.completed;
  @override
  Stream<Duration> get duration => _player.stream.duration;
  @override
  Stream<int> get sampleRate => _player.stream.audioParams
      .map((params) => params.sampleRate)
      .where((rate) => rate != null && rate > 0)
      .cast<int>();
  @override
  Stream<MpvLogError> get errors => _player.stream.log
      .where((log) => log.level == 'error')
      .map((log) => (prefix: log.prefix, text: log.text));
  @override
  Duration get position => _player.state.position;

  @override
  Future<void> open(String source) async {
    await _configured;
    await _player.open(Media(source), play: false);
  }

  @override
  Future<void> play() => _player.play();
  @override
  Future<void> pause() => _player.pause();
  @override
  Future<void> seek(Duration position) => _player.seek(position);
  @override
  Future<void> stop() => _player.stop();
  @override
  Future<void> setVolume(double volume) => _player.setVolume(volume);
  @override
  Future<void> setSpeed(double speed) => _player.setRate(speed);

  @override
  Future<int> setProperty(String name, String value) async {
    await _player.waitForPlayerInitialization;
    if (_player.disposed) return -1;
    final nativeName = name.toNativeUtf8();
    final nativeValue = value.toNativeUtf8();
    try {
      return _player.mpv.mpv_set_property_string(
        _player.ctx,
        nativeName.cast(),
        nativeValue.cast(),
      );
    } finally {
      calloc.free(nativeName);
      calloc.free(nativeValue);
    }
  }

  @override
  Future<String> getProperty(String name) => _player.getProperty(name);

  @override
  Future<void> command(List<String> args) async {
    await _player.waitForPlayerInitialization;
    if (_player.disposed) return;
    await _player.command(args);
  }

  @override
  Future<void> dispose() => _player.dispose();
}

/// A source libmpv could not open.
class MediaKitSourceException implements Exception {
  const MediaKitSourceException(this.message);
  final String message;

  @override
  String toString() => 'MediaKitSourceException: $message';
}

/// The Windows and Linux deck: one libmpv player through media_kit, with the
/// equalizer as an mpv audio filter chain.
///
/// Gapless playback across tracks needs mpv's own playlist
/// (`gapless-audio`), but the runtime gives each deck one source at a time
/// and prepares the next song on a separate deck for AutoMix. Tracks are
/// therefore joined like on the audioplayers deck.
class MediaKitPlaybackDeck implements PlaybackDeck {
  MediaKitPlaybackDeck({required this.playerId, MpvEngine? engine})
    : _engine = engine ?? debugEngineFactory?.call() ?? MediaKitEngine() {
    playbackEqualizer.addListener(_equalizerChanged);
    playbackOutputVolume.addListener(_outputVolumeChanged);
    playbackExclusiveOutput.addListener(_exclusiveChanged);
    playbackExclusiveDevice.addListener(_exclusiveChanged);
    _subscriptions.addAll([
      _engine.completed.listen((done) {
        if (!done || _disposed || _state != PlaybackDeckState.playing) return;
        _setState(PlaybackDeckState.completed);
        _completions.add(null);
      }),
      _engine.duration.listen((value) {
        if (_disposed || value <= Duration.zero) return;
        _duration = value;
        _durations.add(value);
        _finishLoad(null);
        if (defaultTargetPlatform == TargetPlatform.windows) {
          unawaited(_updateAudioStatus());
        }
      }),
      _engine.sampleRate.listen((rate) {
        if (_disposed || rate == _sampleRate) return;
        _sampleRate = rate;
        // Band frequencies are limited to 45% of the rate.
        _equalizerChanged();
      }),
      _engine.errors.listen(_onError),
    ]);
    _equalizerChanged();
  }

  final String playerId;
  final MpvEngine _engine;

  static bool? _available;

  /// Overrides [isAvailable] in tests.
  @visibleForTesting
  static bool? debugAvailableOverride;

  /// Supplies the engine of decks created without one, in tests.
  @visibleForTesting
  static MpvEngine Function()? debugEngineFactory;

  /// True once libmpv is loaded. A missing library (for example no libmpv
  /// package on Linux) leaves the app on the audioplayers deck.
  static bool get isAvailable {
    final override = debugAvailableOverride;
    if (override != null) return override;
    return _available ??= () {
      try {
        MediaKit.ensureInitialized();
        return true;
      } catch (error) {
        _log.e('libmpv is unavailable, playing through audioplayers: $error');
        return false;
      }
    }();
  }

  static const _loadTimeout = Duration(seconds: 20);

  final _states = StreamController<PlaybackDeckState>.broadcast();
  final _durations = StreamController<Duration>.broadcast();
  final _positions = StreamController<Duration>.broadcast();
  final _completions = StreamController<void>.broadcast();
  final _subscriptions = <StreamSubscription<dynamic>>[];
  PlaybackDeckState _state = PlaybackDeckState.stopped;
  AsyncError? _failure;
  Completer<String?>? _pendingLoad;
  Duration? _duration;
  Duration? _positionInterval;
  bool Function()? _positionWanted;
  Timer? _positionTimer;
  int _token = 0;
  bool _disposed = false;
  double _gain = 1;

  /// The source last opened, for reopening it when exclusive output fails.
  String? _source;

  /// The output property as last set; null before the first set.
  ({String name, String value})? _output;

  /// The audio-device property last applied to the engine on Windows; null before the first set.
  String? _appliedAudioDevice;

  /// The audio-device property last applied, for tests.
  @visibleForTesting
  String? get debugAppliedAudioDevice => _appliedAudioDevice;

  /// Whether [_output] is the exclusive one.
  bool _exclusive = false;
  int? _sampleRate;

  /// The `af` value libmpv accepted last, null when unknown.
  String? _appliedSpec;
  double _chainGainDb = 0;

  /// Optional filters this process's libmpv lacks, found by probing once.
  static final _missingFilters = <String>{};
  static Future<void>? _probe;

  @visibleForTesting
  static void debugResetMissingFilters() {
    _missingFilters.clear();
    _probe = null;
  }

  Timer? _equalizerTimer;
  Future<void> _equalizerWrite = Future.value();

  /// Reads an mpv property of this deck's player, for integration tests.
  @visibleForTesting
  Future<String> debugProperty(String name) => _engine.getProperty(name);

  @override
  PlaybackDeckState get state => _state;
  @override
  bool get isDirect => false;
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

  void _setState(PlaybackDeckState value) {
    _state = value;
    _syncPositionTimer();
    if (!_disposed) _states.add(value);
  }

  // "Option af: lavfi-x doesn't exist." and "Error parsing option af".
  static bool _isRejectedFilterValue(MpvLogError error) =>
      error.text.toLowerCase().contains('option af');

  static bool _isFilterError(MpvLogError error) =>
      _isRejectedFilterValue(error) ||
      error.prefix.contains('lavfi') ||
      error.prefix.startsWith('af') ||
      error.prefix.contains('Parsed_') ||
      error.text.toLowerCase().contains('filter');

  // Errors that stop the current source. Decoder errors are often a single
  // damaged frame and playback continues.
  static bool _isSourceError(MpvLogError error) =>
      !(error.prefix == 'cplayer' &&
          error.text.trimLeft().startsWith('Can not open external file ')) &&
      (const {'file', 'stream', 'ao', 'cplayer'}.contains(error.prefix) ||
          error.prefix.startsWith('demux') ||
          error.prefix.startsWith('stream'));

  // "Could not open/initialize audio device -> no sound.": every audio
  // driver failed, so mpv dropped the audio of the current source.
  static bool _isOutputFailure(MpvLogError error) =>
      error.prefix == 'cplayer' &&
      error.text.toLowerCase().contains('audio device');

  void _onError(MpvLogError error) {
    if (_disposed) return;
    if (_exclusive) {
      // A driver that refuses exclusive access is reported before mpv tries
      // the next one; only the final failure stops the source.
      if (error.prefix == 'ao' || error.prefix.startsWith('ao/')) {
        _log.w('mpv ${error.prefix}: ${error.text}');
        return;
      }
      if (_isOutputFailure(error)) {
        _log.w('Exclusive output unavailable: ${error.text}');
        unawaited(
          _fallBackToShared().catchError(
            (Object error) => _log.w('Shared output fallback: $error'),
          ),
        );
        return;
      }
    }
    if (_isFilterError(error)) {
      // A rejected `af` value is handled through the property's result,
      // including the filter probes of _probeFilters.
      if (_isRejectedFilterValue(error)) return;
      _log.w('mpv ${error.prefix}: ${error.text}');
      // mpv disabled the filter; the next change sets the chain again.
      _appliedSpec = null;
      if (playbackEqualizer.value.enabled) {
        reportEqualizerError(
          playerId,
          'Equalizer is unavailable on this output: ${error.text}',
        );
      }
      return;
    }
    // FFmpeg can reject an ID3 text field while the audio still opens.
    // Apply the same source-error policy during preparation and playback.
    if (!_isSourceError(error)) {
      _log.w('mpv ${error.prefix}: ${error.text}');
      return;
    }
    if (_pendingLoad != null) {
      _finishLoad('${error.prefix}: ${error.text}');
      return;
    }
    if (_state == PlaybackDeckState.stopped) {
      _log.w('mpv ${error.prefix}: ${error.text}');
      return;
    }
    final failure = MediaKitSourceException(error.text);
    _failure = AsyncError(failure, StackTrace.current);
    _states.addError(failure, _failure!.stackTrace);
  }

  void _finishLoad(String? error) {
    final pending = _pendingLoad;
    if (pending != null && !pending.isCompleted) pending.complete(error);
  }

  @override
  void startPositionUpdates(Duration interval, {bool Function()? wanted}) {
    _positionInterval = interval;
    _positionWanted = wanted;
    _positionTimer?.cancel();
    _positionTimer = null;
    _syncPositionTimer();
  }

  /// Positions are published only while playing, so the timer runs only
  /// then: an idle deck does not wake the isolate.
  void _syncPositionTimer() {
    final interval = _positionInterval;
    if (_disposed || interval == null || _state != PlaybackDeckState.playing) {
      _positionTimer?.cancel();
      _positionTimer = null;
      return;
    }
    // A timer rather than frames: AutoMix runs with the display asleep.
    _positionTimer ??= Timer.periodic(interval, (_) {
      if (!_disposed &&
          _state == PlaybackDeckState.playing &&
          (_positionWanted?.call() ?? true)) {
        _positions.add(_engine.position);
      }
    });
  }

  @override
  Future<void> configureOutput() => _applyExclusive();

  void _exclusiveChanged() {
    if (_disposed) return;
    unawaited(
      _applyExclusive(
        reload: true,
      ).catchError((Object error) => _log.w('Exclusive output: $error')),
    );
  }

  /// The mpv property that selects the output: `audio-exclusive` for
  /// WASAPI, or on Linux `audio-device`, an ALSA `hw:` device that bypasses
  /// the sound server.
  static ({String name, String value}) _outputFor({required bool exclusive}) {
    if (defaultTargetPlatform == TargetPlatform.linux) {
      final device = playbackExclusiveDevice.value;
      return (
        name: 'audio-device',
        value: exclusive && device.isNotEmpty ? device : 'auto',
      );
    }
    return (name: 'audio-exclusive', value: exclusive ? 'yes' : 'no');
  }

  bool _isFallbackDevice = false;

  int? _parseBitDepth(String? format) {
    if (format == null || format.isEmpty) return null;
    final f = format.toLowerCase();
    if (f.contains('16')) return 16;
    if (f.contains('24')) return 24;
    if (f.contains('32') || f.contains('float')) return 32;
    if (f.contains('64') || f.contains('double')) return 64;
    return null;
  }

  Future<void> _updateAudioStatus() async {
    if (_disposed || defaultTargetPlatform != TargetPlatform.windows) return;
    try {
      final srcSampleRateStr = await _engine.getProperty('audio-params/samplerate');
      final srcFormatStr = await _engine.getProperty('audio-params/format');
      final srcChannelsStr = await _engine.getProperty('audio-params/channels');
      final srcSampleRate = int.tryParse(srcSampleRateStr);
      final srcBitDepth = _parseBitDepth(srcFormatStr);

      String outSampleRateStr = await _engine.getProperty('audio-out-params/samplerate');
      String outFormatStr = await _engine.getProperty('audio-out-params/format');
      String outChannelsStr = await _engine.getProperty('audio-out-params/channels');
      String outChannelCountStr = await _engine.getProperty('audio-out-params/channel-count');

      if (outSampleRateStr.isEmpty) outSampleRateStr = srcSampleRateStr;
      if (outFormatStr.isEmpty) outFormatStr = srcFormatStr;
      if (outChannelsStr.isEmpty) outChannelsStr = srcChannelsStr;

      final outSampleRate = int.tryParse(outSampleRateStr);
      final outBitDepth = _parseBitDepth(outFormatStr);
      final outChannelCount = int.tryParse(outChannelCountStr);

      String actualMode = 'shared';
      String reason = _isFallbackDevice ? 'fallback' : 'active';
      if (playbackExclusiveOutput.value) {
        try {
          final exclusiveStatus = await _engine.getProperty('audio-exclusive');
          if (exclusiveStatus == 'yes') {
            actualMode = 'exclusive_event';
            reason = _isFallbackDevice ? 'fallback' : 'active';
          } else {
            actualMode = 'shared';
            reason = 'fallback';
          }
        } catch (_) {
          actualMode = 'shared';
          reason = 'fallback';
        }
      } else {
        actualMode = 'shared';
      }

      final isVolume100 = playbackOutputVolume.value >= 0.999;
      final isNormBypassed = _gain >= 0.999;
      final isEqDisabled = !playbackEqualizer.value.enabled;
      final isRateMatching = srcSampleRate != null &&
          outSampleRate != null &&
          srcSampleRate == outSampleRate;
      final isExclusive = actualMode.startsWith('exclusive');

      final isBitPerfect = isExclusive &&
          isVolume100 &&
          isNormBypassed &&
          isEqDisabled &&
          isRateMatching;

      String bitPerfectReason;
      if (isBitPerfect) {
        bitPerfectReason =
            'Bit-perfect direct output: WASAPI Exclusive active, unattenuated 100% volume, DSP/EQ bypassed, source rate matched ($srcSampleRate Hz).';
      } else {
        final degradations = <String>[];
        if (!isExclusive) {
          degradations.add('WASAPI Shared mixer active (system audio engine may resample or limit bit depth)');
        }
        if (!isRateMatching && srcSampleRate != null && outSampleRate != null) {
          degradations.add('Sample rate conversion: ${srcSampleRate}Hz -> ${outSampleRate}Hz');
        }
        if (!isVolume100) {
          degradations.add('Digital volume attenuation: ${(playbackOutputVolume.value * 100).round()}%');
        }
        if (!isNormBypassed) {
          degradations.add('Gain normalization active');
        }
        if (!isEqDisabled) {
          degradations.add('Equalizer DSP processing active');
        }
        bitPerfectReason = degradations.isEmpty
            ? 'Not verified'
            : degradations.join(' • ');
      }

      final selectedSetting = playbackExclusiveDevice.value;
      final selectedEp = WindowsAudioDeviceService.instance.findEndpoint(selectedSetting);
      final selectedName = selectedSetting.isEmpty || selectedSetting == 'auto'
          ? 'System Default'
          : (selectedEp?.name ?? selectedSetting);

      String activeName;
      if (_isFallbackDevice) {
        final defaultEp = WindowsAudioDeviceService.instance.activeDefaultEndpoint;
        final baseName = defaultEp?.name ?? 'System Default';
        activeName = '$baseName (Fallback)';
      } else {
        final currentMpvDevice = await _engine.getProperty('audio-device');
        if (currentMpvDevice.isEmpty || currentMpvDevice == 'auto') {
          final defaultEp = WindowsAudioDeviceService.instance.activeDefaultEndpoint;
          activeName = defaultEp?.name ?? 'System Default';
        } else {
          final activeEp = WindowsAudioDeviceService.instance.findEndpoint(currentMpvDevice);
          activeName = activeEp?.name ?? currentMpvDevice;
        }
      }

      windowsAudioStatus.value = WindowsAudioStatus(
        reason: reason,
        mode: actualMode,
        selectedDevice: selectedName,
        activeDevice: activeName,
        device: activeName,
        sampleRate: outSampleRate,
        bitDepth: outBitDepth,
        format: outFormatStr,
        channels: outChannelsStr,
        channelCount: outChannelCount,
        sourceSampleRate: srcSampleRate,
        sourceBitDepth: srcBitDepth,
        sourceFormat: srcFormatStr,
        isBitPerfect: isBitPerfect,
        bitPerfectReason: bitPerfectReason,
      );
    } catch (e) {
      _log.w('Failed to query audio parameters: $e');
    }
  }

  String _targetAudioDevice() {
    if (defaultTargetPlatform == TargetPlatform.windows) {
      final deviceSetting = playbackExclusiveDevice.value;
      if (deviceSetting.isEmpty || deviceSetting == 'auto') {
        return 'auto';
      }
      if (deviceSetting.startsWith('wasapi/')) {
        return deviceSetting;
      }
      final ep = WindowsAudioDeviceService.instance.findEndpoint(deviceSetting);
      return ep?.mpvDeviceId ??
          (deviceSetting.startsWith('{') ? 'wasapi/$deviceSetting' : 'auto');
    }
    return 'auto';
  }

  /// Sets the output for [playbackExclusiveOutput] and [playbackExclusiveDevice].
  /// A change while a source is open reloads the output, so it applies at once.
  Future<void> _applyExclusive({bool reload = false}) async {
    final target = _outputFor(exclusive: playbackExclusiveOutput.value);
    final targetDevice = defaultTargetPlatform == TargetPlatform.windows
        ? _targetAudioDevice()
        : null;

    final modeChanged = _output == null || target != _output;
    final deviceChanged = defaultTargetPlatform == TargetPlatform.windows &&
        (_appliedAudioDevice == null || targetDevice != _appliedAudioDevice);

    if (_disposed || (!modeChanged && !deviceChanged)) return;
    _output = target;
    _appliedAudioDevice = targetDevice;
    _exclusive = target != _outputFor(exclusive: false);
    playbackExclusiveStatus.value = ExclusiveOutputStatus.pending;

    if (defaultTargetPlatform == TargetPlatform.windows && targetDevice != null) {
      await _engine.setProperty('audio-device', targetDevice);
      _isFallbackDevice = false;
    }

    await _engine.setProperty(target.name, target.value);
    if (!reload || _disposed || _state == PlaybackDeckState.stopped) {
      if (defaultTargetPlatform == TargetPlatform.windows) {
        unawaited(_updateAudioStatus());
      }
      return;
    }

    final wasPlaying = _state == PlaybackDeckState.playing;
    final wasPaused = _state == PlaybackDeckState.paused;
    final currentPos = await getCurrentPosition() ?? _engine.position;

    try {
      await _engine.command(const ['ao-reload']);
      if (wasPlaying && _state == PlaybackDeckState.playing) {
        await _engine.play();
      } else if (wasPaused && _state == PlaybackDeckState.paused) {
        await _engine.pause();
      }
      if (currentPos > Duration.zero) {
        final posAfter = await getCurrentPosition() ?? _engine.position;
        if (posAfter == Duration.zero && currentPos > const Duration(seconds: 1)) {
          await _engine.seek(currentPos);
        }
      }
    } catch (e) {
      _log.w('ao-reload failed: $e');
    }

    if (_exclusive && _output == target) {
      playbackExclusiveStatus.value = ExclusiveOutputStatus.active;
    }
    if (defaultTargetPlatform == TargetPlatform.windows) {
      unawaited(_updateAudioStatus());
    }
  }

  /// The device refused exclusive access: this source plays through the
  /// system mixer. mpv drops audio whose output failed, so the source opens
  /// again where it was. The next source tries exclusive mode again.
  Future<void> _fallBackToShared() async {
    final shared = _outputFor(exclusive: false);
    _output = shared;
    _exclusive = false;
    playbackExclusiveStatus.value = ExclusiveOutputStatus.unavailable;
    if (defaultTargetPlatform == TargetPlatform.windows) {
      _isFallbackDevice = true;
      _appliedAudioDevice = 'auto';
      await _engine.setProperty('audio-device', 'auto');
    }
    final source = _source;
    final token = _token;
    final playing = _state == PlaybackDeckState.playing;
    final position = _engine.position;
    await _engine.setProperty(shared.name, shared.value);
    if (defaultTargetPlatform == TargetPlatform.windows) {
      unawaited(_updateAudioStatus());
    }
    if (_disposed || token != _token || source == null) return;
    // A pending load completes when the reopened source reports its
    // duration.
    await _engine.open(source);
    if (_disposed || token != _token) return;
    if (position > Duration.zero) await _engine.seek(position);
    if (playing) await _engine.play();
  }

  // mpv's volume is cubic: 100 * cbrt(linear gain). The equalizer gain may
  // add up to +12 dB, within the volume-max the engine sets.
  double get _mpvVolume {
    final linear =
        _gain.clamp(0.0, 1.0) *
        playbackOutputVolume.value *
        math.pow(10, _chainGainDb / 20);
    return 100 * math.pow(linear.clamp(0.0, 4.0), 1 / 3).toDouble();
  }

  @override
  Future<void> setVolume(double volume) async {
    _gain = volume;
    await _engine.setVolume(_mpvVolume);
  }

  void _outputVolumeChanged() {
    if (_disposed) return;
    unawaited(
      _engine
          .setVolume(_mpvVolume)
          .catchError((Object error) => _log.w('Output volume: $error')),
    );
    if (defaultTargetPlatform == TargetPlatform.windows) {
      unawaited(_updateAudioStatus());
    }
  }

  @override
  Future<void> setPlaybackRate(double rate) => _engine.setSpeed(rate);

  @override
  Future<void> setNetworkSource(String url, {bool arriving = false}) =>
      _load(url);

  @override
  Future<void> setFileSource(
    String path, {
    bool preferBitPerfect = false,
    bool directUsb = false,
    bool allowDop = false,
    bool requiresDsd = false,
    bool allowFixedVolume = false,
    bool dapExclusive = false,
  }) => _load(path, requiresDsd: requiresDsd);

  Future<void> _load(String source, {bool requiresDsd = false}) async {
    await stop();
    final token = ++_token;
    final loaded = Completer<String?>();
    _pendingLoad = loaded;
    _failure = null;
    _duration = null;
    _source = source;
    String? error;
    try {
      await _engine.open(source);
      error = await loaded.future.timeout(
        _loadTimeout,
        onTimeout: () => 'Timed out opening the source',
      );
    } finally {
      if (identical(_pendingLoad, loaded)) _pendingLoad = null;
    }
    if (_disposed || token != _token) return;
    if (error != null) {
      await _engine.stop();
      // libmpv converts DSD to PCM when its FFmpeg build has the decoder.
      if (requiresDsd) throw UsbDsdUnavailable();
      throw MediaKitSourceException(error);
    }
    if (_exclusive) {
      playbackExclusiveStatus.value = ExclusiveOutputStatus.active;
    }
  }

  @override
  Future<void> cancelPreparation() async {
    if (_pendingLoad != null) await stop();
  }

  @override
  Future<void> resume() async {
    final failure = _failure;
    if (failure != null) {
      Error.throwWithStackTrace(failure.error, failure.stackTrace);
    }
    await _engine.play();
    _setState(PlaybackDeckState.playing);
  }

  @override
  Future<void> pause() async {
    await _engine.pause();
    _setState(PlaybackDeckState.paused);
  }

  @override
  Future<void> seek(Duration position) async {
    await _engine.seek(position);
    if (!_disposed) _positions.add(position);
  }

  @override
  Future<void> stop() async {
    _token++;
    _finishLoad(null);
    await _engine.stop();
    _duration = null;
    _setState(PlaybackDeckState.stopped);
  }

  /// Each deck owns its own libmpv instance, which cannot hand its output to
  /// another; the next deck starts on the completion event instead.
  @override
  Future<bool> setNextDeck(PlaybackDeck? next) async => false;

  @override
  Future<Duration?> getCurrentPosition() async {
    // Asked directly: media_kit's cached position trails a pause or seek.
    final seconds = double.tryParse(await _engine.getProperty('time-pos'));
    if (seconds == null || !seconds.isFinite) return _engine.position;
    return Duration(microseconds: (seconds * 1000000).round());
  }

  @override
  Future<Duration?> getDuration() async => _duration;

  void _equalizerChanged() {
    // Every change sets the chain again, so slider drags coalesce.
    _equalizerTimer ??= Timer(const Duration(milliseconds: 80), () {
      _equalizerTimer = null;
      _equalizerWrite = _equalizerWrite.then((_) => _syncEqualizer());
    });
  }

  MpvAudioFilterChain _chainFor(EqualizerSettings settings) =>
      MpvAudioFilterChain.fromEqualizer(
        settings,
        sampleRate: _sampleRate,
        unavailable: _missingFilters,
      );

  /// Learns which optional filters libmpv lacks. mpv checks `lavfi-NAME`
  /// when the property is set, before any audio flows through it, so the
  /// first deck probes once while it has no source.
  Future<void> _probeFilters() => _probe ??= () async {
    for (final name in MpvAudioFilterChain.optionalFilters) {
      if (await _engine.setProperty('af', '@mornye_probe:lavfi-$name') < 0) {
        _missingFilters.add(name);
      }
    }
    await _engine.setProperty('af', '');
    if (_missingFilters.isNotEmpty) {
      _log.i('libmpv lacks the audio filters $_missingFilters');
    }
  }();

  // Features the listener turned on that this libmpv cannot apply.
  String? _missingFeatures(EqualizerSettings settings) {
    final missing = [
      if (settings.balance != 0 && _missingFilters.contains('stereotools'))
        'balance',
      if (settings.compressor && _missingFilters.contains('acompressor'))
        'compressor',
    ];
    if (missing.isEmpty) return null;
    return 'The ${missing.join(' and ')} is not available in this system '
        'audio library';
  }

  Future<void> _applyChainGain(MpvAudioFilterChain chain) async {
    if (chain.volumeGainDb == _chainGainDb) return;
    _chainGainDb = chain.volumeGainDb;
    await _engine.setVolume(_mpvVolume);
  }

  Future<void> _syncEqualizer() async {
    if (_disposed) return;
    final settings = playbackEqualizer.value;
    try {
      if (settings.enabled) await _probeFilters();
      if (_disposed) return;
      final chain = _chainFor(settings);
      // mpv keeps filters whose settings did not change and recreates the
      // graph, which also applies changes during playback.
      if (chain.spec != _appliedSpec) {
        final code = await _engine.setProperty('af', chain.spec);
        if (_disposed) return;
        if (code < 0) {
          _appliedSpec = null;
          reportEqualizerError(
            playerId,
            settings.enabled
                ? 'Equalizer is unavailable on this output (mpv error $code)'
                : null,
          );
          return;
        }
        _appliedSpec = chain.spec;
      }
      await _applyChainGain(chain);
      reportEqualizerError(playerId, _missingFeatures(settings));
      if (defaultTargetPlatform == TargetPlatform.windows) {
        unawaited(_updateAudioStatus());
      }
    } catch (error) {
      _appliedSpec = null;
      if (!_disposed && settings.enabled) {
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
    playbackExclusiveOutput.removeListener(_exclusiveChanged);
    playbackExclusiveDevice.removeListener(_exclusiveChanged);
    _equalizerTimer?.cancel();
    _positionTimer?.cancel();
    reportEqualizerError(playerId, null);
    await stop();
    _setState(PlaybackDeckState.disposed);
    _disposed = true;
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    await _equalizerWrite;
    await _engine.dispose();
    await _states.close();
    await _durations.close();
    await _positions.close();
    await _completions.close();
  }
}
