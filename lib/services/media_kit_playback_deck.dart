import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show AppExitResponse;

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show AppLifecycleListener;
import 'package:media_kit/media_kit.dart';
import 'package:mornye/models/equalizer_settings.dart';
import 'package:mornye/services/media_kit_audio_filters.dart';
import 'package:mornye/services/music_playback_deck.dart'
    show UsbDsdUnavailable;
import 'package:mornye/services/playback_deck.dart';
import 'package:mornye/services/playback_equalizer.dart';
import 'package:mornye/utils/logger.dart';

final _log = AppLogger('MediaKitDeck');

typedef MpvLogError = ({String prefix, String text});

/// A line mpv's audio output wrote below the error level. A [warning] is a
/// fault such as an underrun; the rest describe the device as it opens.
typedef MpvOutputNote = ({String prefix, String text, bool warning});

/// The libmpv operations [MediaKitPlaybackDeck] uses. [MediaKitEngine] is the
/// media_kit implementation; host tests substitute a fake.
abstract interface class MpvEngine {
  Stream<bool> get completed;
  Stream<Duration> get duration;
  Stream<int> get sampleRate;
  Stream<MpvLogError> get errors;
  Stream<MpvOutputNote> get outputNotes;
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

/// Optional native playlist support. The hook runs before decoding the next
/// file, so its normalization does not change the previous file's queued tail.
abstract interface class MpvPlaylistEngine implements MpvEngine {
  Future<void> appendNext(String source, Future<void> Function() onStarting);
  Future<void> clearNext();
}

class MediaKitEngine implements MpvEngine, MpvPlaylistEngine {
  MediaKitEngine()
    : _player = NativePlayer(
        // Verbose, for the audio output's own account of the device it
        // opened (see [outputNotes]); mpv writes little else at this level
        // while a song plays.
        configuration: const PlayerConfiguration(
          title: 'Mornye',
          logLevel: MPVLogLevel.v,
        ),
      ) {
    _player.onLoadHooks.add(_onLoad);
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
      // Music playback needs scheduling headroom rather than the shortest
      // device period, which can underrun on otherwise working endpoints.
      if (defaultTargetPlatform == TargetPlatform.windows)
        setProperty('wasapi-exclusive-buffer', 'default'),
      // Until a successor is queued, EOF must wait for the output to drain.
      setProperty('gapless-audio', 'no'),
      // Room for an equalizer preamp of +12 dB applied through the volume
      // when the libmpv build has no volume filter.
      setProperty('volume-max', '200'),
    ]);
  }

  final NativePlayer _player;
  late final Future<void> _configured;
  ({int index, Future<void> Function() start})? _next;
  Future<void> _playlistWrite = Future.value();
  int _playlistGeneration = 0;

  Future<void> _writePlaylist(Future<void> Function() write) {
    final operation = _playlistWrite.then((_) => write());
    _playlistWrite = operation.catchError((Object _) {});
    return operation;
  }

  Future<void> _onLoad() async {
    final next = _next;
    if (next == null) return;
    final generation = _playlistGeneration;
    final index = int.tryParse(await getProperty('playlist-pos'));
    if (generation != _playlistGeneration ||
        next != _next ||
        index != next.index) {
      return;
    }
    _next = null;
    await next.start();
  }

  @override
  Future<void> appendNext(String source, Future<void> Function() onStarting) {
    final generation = ++_playlistGeneration;
    return _writePlaylist(() async {
      if (generation != _playlistGeneration) return;
      await _removeNext();
      // Keep only the current entry before appending, bounding the native list.
      while ((int.tryParse(await getProperty('playlist-pos')) ?? 0) > 0) {
        await _player.remove(0);
      }
      if (generation != _playlistGeneration) return;
      _next = (index: _player.state.playlist.medias.length, start: onStarting);
      await _player.add(Media(source));
    });
  }

  @override
  Future<void> clearNext() {
    _playlistGeneration++;
    _next = null;
    return _writePlaylist(_removeNext);
  }

  Future<void> _removeNext() async {
    // media_kit's playlist stream can still describe the previous file while
    // on_load is running. Read mpv directly so cancellation keeps the new one.
    while (_player.state.playlist.medias.length >
        (int.tryParse(await getProperty('playlist-pos')) ?? 0) + 1) {
      await _player.remove(_player.state.playlist.medias.length - 1);
    }
  }

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

  static const _noteLevels = {'warn', 'info', 'v'};

  // The output drivers log as `ao` and `ao/NAME`. The player core reports
  // an underrun it noticed itself.
  @override
  Stream<MpvOutputNote> get outputNotes => _player.stream.log
      .where(
        (log) =>
            _noteLevels.contains(log.level) &&
            (log.prefix == 'ao' ||
                log.prefix.startsWith('ao/') ||
                (log.level == 'warn' &&
                    log.text.toLowerCase().contains('underrun'))),
      )
      .map(
        (log) =>
            (prefix: log.prefix, text: log.text, warning: log.level == 'warn'),
      );
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
  Future<void> dispose() async {
    _next = null;
    _playlistGeneration++;
    await _playlistWrite;
    _player.onLoadHooks.remove(_onLoad);
    await _player.dispose();
  }
}

class MediaKitSourceException implements Exception {
  const MediaKitSourceException(this.message);
  final String message;

  @override
  String toString() => 'MediaKitSourceException: $message';
}

/// The Windows and Linux deck: one libmpv player through media_kit, with the
/// equalizer as an mpv audio filter chain. [playbackSpeed] and
/// [playbackPitch] apply through mpv's speed and the same chain (see
/// [MpvTempo]).
///
/// Gapless uses the native playlist on this same output, including exclusive
/// mode. AutoMix still owns separate decks while it is enabled.
class MediaKitPlaybackDeck implements PlaybackDeck, QueuedPlaybackDeck {
  MediaKitPlaybackDeck({required this.playerId, MpvEngine? engine})
    : _engine = engine ?? debugEngineFactory?.call() ?? MediaKitEngine() {
    playbackEqualizer.addListener(_equalizerChanged);
    playbackSpeed.addListener(_equalizerChanged);
    playbackPitch.addListener(_equalizerChanged);
    playbackOutputVolume.addListener(_outputVolumeChanged);
    playbackExclusiveOutput.addListener(_exclusiveChanged);
    playbackExclusiveDevice.addListener(_exclusiveChanged);
    _subscriptions.addAll([
      _engine.completed.listen((done) {
        if (!done ||
            _disposed ||
            _state != PlaybackDeckState.playing ||
            _nextSource != null) {
          return;
        }
        _setState(PlaybackDeckState.completed);
        _completions.add(null);
      }),
      _engine.duration.listen((value) {
        if (_disposed || value <= Duration.zero) return;
        _duration = value;
        _durations.add(value);
        _finishLoad(null);
      }),
      _engine.sampleRate.listen((rate) {
        if (_disposed || rate == _sampleRate) return;
        _sampleRate = rate;
        // Band frequencies are limited to 45% of the rate.
        _equalizerChanged();
      }),
      _engine.errors.listen(_onError),
      _engine.outputNotes.listen(_onOutputNote),
    ]);
    _live.add(this);
    // At once, so a source opened right away already plays at the current
    // speed and pitch.
    _equalizerWrite = _syncEqualizer();
  }

  final String playerId;
  final MpvEngine _engine;

  static bool? _available;

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

  /// The decks not yet disposed, for [releaseOutputs].
  static final _live = <MediaKitPlaybackDeck>{};
  static AppLifecycleListener? _exitListener;

  /// Desktop startup: gives the audio device back when the app is asked to
  /// quit. Nothing else closes it: the process would end with the stream
  /// open, and an exclusive device has been reported to stay silent after
  /// that until it is plugged in again.
  static void releaseOutputsOnExit() {
    _exitListener ??= AppLifecycleListener(
      onExitRequested: () async {
        try {
          await releaseOutputs();
        } catch (error) {
          // The quit goes on whatever happens here.
          _log.w('Closing the audio output before quitting: $error');
        }
        return AppExitResponse.exit;
      },
    );
  }

  /// Stops every deck and waits, for [timeout] at most, until libmpv has
  /// closed its audio output.
  static Future<void> releaseOutputs({
    Duration timeout = const Duration(milliseconds: 800),
  }) async {
    final decks = _live.toList();
    if (decks.isEmpty) return;
    final watch = Stopwatch()..start();
    // The quit waits for this, so a stop held up behind a source that is
    // still opening does not get longer than the same limit.
    final closed = await Future.wait([
      for (final deck in decks)
        deck._releaseOutput(timeout).timeout(timeout, onTimeout: () => false),
    ]);
    _log.i(
      closed.contains(false)
          ? 'An audio output was still open ${watch.elapsedMilliseconds} ms '
                'after the quit request'
          : 'Audio output closed for quitting '
                '(${watch.elapsedMilliseconds} ms)',
    );
  }

  final _states = StreamController<PlaybackDeckState>.broadcast();
  final _durations = StreamController<Duration>.broadcast();
  final _positions = StreamController<Duration>.broadcast();
  final _completions = StreamController<void>.broadcast();
  ({String source, double volume})? _nextSource;
  int _nextRevision = 0;
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

  /// Where the song was when [_releaseOutput] stopped the engine, which
  /// reports zero from then on. Null while the engine is in use.
  Duration? _releasedAt;

  /// Output notes already logged, each once: they repeat with every song.
  final _loggedNotes = <String>{};
  final _warningClock = Stopwatch();
  int _warningsHeld = 0;

  /// The output property as last set; null before the first set.
  ({String name, String value})? _output;

  bool _exclusive = false;
  int? _sampleRate;

  /// The `af` value libmpv accepted last, null when unknown.
  String? _appliedSpec;

  /// The last `af` value with a semitone shift that libmpv refused.
  String? _rejectedSpec;
  double _chainGainDb = 0;

  /// The rate [setPlaybackRate] gave, before [playbackSpeed].
  double _rate = 1;

  /// mpv's `speed` and `audio-pitch-correction` as last set (its defaults
  /// until then).
  double _speed = 1;
  bool _pitchCorrection = true;

  bool _pitchFailed = false;

  /// Optional filters this process's libmpv lacks, found by probing once.
  static final _missingFilters = <String>{};
  static Future<void>? _probe;
  static Future<void>? _tempoProbe;

  @visibleForTesting
  static void debugResetMissingFilters() {
    _missingFilters.clear();
    _probe = null;
    _tempoProbe = null;
  }

  Timer? _equalizerTimer;
  Future<void> _equalizerWrite = Future.value();

  @visibleForTesting
  Future<String> debugProperty(String name) => _engine.getProperty(name);

  @override
  PlaybackDeckState get state => _state;
  @override
  bool get isDirect => false;
  @override
  bool get needsSourceReload => false;
  @override
  PlaybackTempoSupport get tempoSupport =>
      _pitchFailed ? PlaybackTempoSupport.speedOnly : PlaybackTempoSupport.full;
  @override
  Stream<PlaybackDeckState> get onPlayerStateChanged => _states.stream;
  @override
  Stream<Duration> get onDurationChanged => _durations.stream;
  @override
  Stream<Duration> get onPositionChanged => _positions.stream;
  @override
  Stream<void> get onPlayerComplete => _completions.stream;

  @override
  bool get canQueueNextSource => _engine is MpvPlaylistEngine;

  @override
  Future<bool> queueNextSource(
    String source, {
    required double volume,
    required void Function() onStarted,
  }) async {
    final engine = _engine;
    if (engine is! MpvPlaylistEngine || _disposed) return false;
    final token = _token;
    final revision = ++_nextRevision;
    final next = (source: source, volume: volume);
    _nextSource = next;
    // Retain the device for matching formats. A rate or channel change may
    // reopen it rather than resampling everything to the first track's format.
    if (await _engine.setProperty('gapless-audio', 'weak') < 0) {
      _nextSource = null;
      return false;
    }
    if (_disposed || token != _token || revision != _nextRevision) return false;
    try {
      await engine.appendNext(source, () async {
        if (_disposed || token != _token || revision != _nextRevision) return;
        _nextSource = null;
        _source = source;
        _duration = null;
        _gain = volume;
        // The on_load hook blocks event delivery. Use the synchronous native
        // property setter rather than media_kit's event-acknowledged volume API.
        await _engine.setProperty('volume', _mpvVolume.toString());
        if (_disposed || token != _token || revision != _nextRevision) return;
        unawaited(
          _drainOnceStarted(token, revision).catchError(
            (Object error) => _log.w('Gapless drain setting: $error'),
          ),
        );
        onStarted();
      });
      return !_disposed && token == _token && revision == _nextRevision;
    } catch (_) {
      if (revision == _nextRevision) await clearNextSource();
      rethrow;
    }
  }

  /// With no following entry, completion must wait for the audible tail, so
  /// `gapless-audio` goes back to `no`. mpv decides whether the queued song
  /// keeps the open device only when that song's first audio is ready, after
  /// the load hook returns: `no` set inside the hook closes and reopens the
  /// device at every song change. `seeking` reads `yes` until that decision
  /// is made, and nothing while the file still loads.
  Future<void> _drainOnceStarted(int token, int revision) async {
    final watch = Stopwatch()..start();
    var delayMs = _startPoll.inMilliseconds;
    while (watch.elapsed < _startPollTimeout) {
      if (_disposed || token != _token || revision != _nextRevision) return;
      if (await _engine.getProperty('seeking') == 'no') break;
      await Future<void>.delayed(Duration(milliseconds: delayMs));
      if (delayMs < 40) delayMs = math.min(40, delayMs * 2);
    }
    // A newer queued song or source owns the setting by now.
    if (_disposed || token != _token || revision != _nextRevision) return;
    await _engine.setProperty('gapless-audio', 'no');
  }

  static const _startPoll = Duration(milliseconds: 20);

  /// Ten seconds: a song that has not started by then loses only the
  /// retained device, not its ending.
  static const _startPollTimeout = Duration(seconds: 10);

  @override
  Future<void> clearNextSource() async {
    _nextRevision++;
    _nextSource = null;
    if (_disposed) return;
    if (_engine case final MpvPlaylistEngine engine) await engine.clearNext();
    if (!_disposed) await _engine.setProperty('gapless-audio', 'no');
  }

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
      if (error.text.contains('mornye_tempo')) {
        // The speed a shift through scaletempo set needs that filter; play
        // the unshifted speed instead and keep this chain from returning.
        _rejectedSpec = _appliedSpec;
        _setPitchFailed(true);
        final unshifted = _tempoFor(
          PlaybackPitch(followsRate: playbackPitch.value.followsRate),
        );
        _equalizerWrite = _equalizerWrite.then(
          (_) => _applyTempo(
            unshifted,
          ).catchError((Object error) => _log.w('Unshifted speed: $error')),
        );
      }
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

  static const _warningInterval = Duration(seconds: 5);

  /// Keeps the output's account of itself in the log: the device period,
  /// buffer and format once each, and faults such as an underrun, which can
  /// repeat many times a second, at most once per [_warningInterval].
  void _onOutputNote(MpvOutputNote note) {
    if (_disposed) return;
    final line = 'mpv ${note.prefix}: ${note.text}';
    if (!note.warning) {
      // Not counted as logged while logging is off, so the lines are there
      // once the listener turns it on and plays the next song.
      if ((LogBuffer.loggingEnabled || kDebugMode) &&
          _loggedNotes.length < 200 &&
          _loggedNotes.add(line)) {
        _log.i(line);
      }
      return;
    }
    if (_warningClock.isRunning && _warningClock.elapsed < _warningInterval) {
      _warningsHeld++;
      return;
    }
    _log.w(_warningsHeld == 0 ? line : '$line ($_warningsHeld more before)');
    _warningsHeld = 0;
    _warningClock
      ..reset()
      ..start();
  }

  /// Stops the engine without a deck state change, which the player would
  /// save as the end of the song. `stop` returns before libmpv is idle,
  /// where it closes the output, so this waits for that. False when the
  /// output was still open after [timeout].
  Future<bool> _releaseOutput(Duration timeout) async {
    if (_disposed) return true;
    _releasedAt ??= _engine.position;
    _syncPositionTimer();
    final watch = Stopwatch()..start();
    try {
      await _engine.stop();
      while ((await _engine.getProperty('current-ao')).isNotEmpty) {
        if (_disposed) return true;
        if (watch.elapsed >= timeout) return false;
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      return true;
    } catch (error) {
      _log.w('Closing the audio output: $error');
      return false;
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

  /// Positions are published only while playing, so the timer runs only
  /// then: an idle deck does not wake the isolate.
  void _syncPositionTimer() {
    final interval = _positionInterval;
    if (_disposed ||
        interval == null ||
        _releasedAt != null ||
        _state != PlaybackDeckState.playing) {
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

  /// Sets the output for [playbackExclusiveOutput]. A change while a source
  /// is open reopens the output, so it applies at once.
  Future<void> _applyExclusive({bool reload = false}) async {
    final target = _outputFor(exclusive: playbackExclusiveOutput.value);
    if (_disposed || target == _output) return;
    _output = target;
    _exclusive = target != _outputFor(exclusive: false);
    playbackExclusiveStatus.value = ExclusiveOutputStatus.pending;
    await _engine.setProperty(target.name, target.value);
    if (!reload || _disposed || _state == PlaybackDeckState.stopped) return;
    await _engine.command(const ['ao-reload']);
    if (_exclusive && _output == target) {
      playbackExclusiveStatus.value = ExclusiveOutputStatus.active;
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
    final source = _source;
    final token = _token;
    final playing = _state == PlaybackDeckState.playing;
    final position = _engine.position;
    await _engine.setProperty(shared.name, shared.value);
    if (_disposed || token != _token || source == null) return;
    // A pending load completes when the reopened source reports its
    // duration.
    await clearNextSource();
    await _engine.open(source);
    if (_disposed || token != _token) return;
    if (position > Duration.zero) await _engine.seek(position);
    if (_disposed || token != _token) return;
    if (playing && _state == PlaybackDeckState.playing) await _engine.play();
  }

  // mpv's volume is cubic: 100 * cbrt(linear gain). The equalizer gain and a
  // normalization raise may add up to +12 dB, within the engine's volume-max.
  double get _mpvVolume {
    final linear =
        _gain.clamp(0.0, 4.0) *
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
  }

  /// Applies at once, through the same serialized write as the filters: a
  /// semitone shift without `rubberband` changes the chain with the speed.
  @override
  Future<void> setPlaybackRate(double rate) {
    if (rate <= 0) return Future.value();
    _rate = rate;
    _equalizerTimer?.cancel();
    _equalizerTimer = null;
    return _equalizerWrite = _equalizerWrite.then((_) => _syncEqualizer());
  }

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
    int usbMaxSampleRate = 0,
    bool usbDitherHighPass = false,
  }) => _load(path, requiresDsd: requiresDsd);

  Future<void> _load(String source, {bool requiresDsd = false}) async {
    await stop();
    final token = ++_token;
    final loaded = Completer<String?>();
    _pendingLoad = loaded;
    _failure = null;
    _duration = null;
    _releasedAt = null;
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
    await clearNextSource();
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
    final released = _releasedAt;
    if (released != null) return released;
    // Asked directly: media_kit's cached position trails a pause or seek.
    final seconds = double.tryParse(await _engine.getProperty('time-pos'));
    if (seconds == null || !seconds.isFinite) return _engine.position;
    return Duration(microseconds: (seconds * 1000000).round());
  }

  @override
  Future<Duration?> getDuration() async => _duration;

  void _equalizerChanged() {
    // Every change sets the chain again, so slider drags coalesce. Speed and
    // pitch changes take the same path, since a shift lives in the chain.
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
    _appliedSpec = '';
    if (_missingFilters.isNotEmpty) {
      _log.i('libmpv lacks the audio filters $_missingFilters');
    }
  }();

  /// Like [_probeFilters], for the filters a semitone shift prefers. Probed
  /// apart, once a shift is first asked for.
  Future<void> _probeTempoFilters() => _tempoProbe ??= () async {
    final missing = <String>{};
    for (final name in MpvTempo.optionalFilters) {
      if (await _engine.setProperty('af', '@mornye_probe:lavfi-$name') < 0) {
        missing.add(name);
      }
    }
    await _engine.setProperty('af', '');
    _appliedSpec = '';
    _missingFilters.addAll(missing);
    if (missing.isNotEmpty) {
      _log.i('libmpv lacks $missing; pitch shifts use scaletempo');
    }
  }();

  MpvTempo _tempoFor(PlaybackPitch pitch) => MpvTempo.of(
    _rate * playbackSpeed.value,
    pitch,
    unavailable: _missingFilters,
  );

  Future<void> _applyTempo(MpvTempo tempo) async {
    if (tempo.pitchCorrection != _pitchCorrection) {
      _pitchCorrection = tempo.pitchCorrection;
      await _engine.setProperty(
        'audio-pitch-correction',
        tempo.pitchCorrection ? 'yes' : 'no',
      );
    }
    if (tempo.speed != _speed) {
      _speed = tempo.speed;
      await _engine.setSpeed(tempo.speed);
    }
  }

  void _setPitchFailed(bool failed) {
    if (failed == _pitchFailed) return;
    _pitchFailed = failed;
    notifyPlaybackTempoSupportChanged();
  }

  // Features the listener turned on that this libmpv cannot apply.
  String? _missingFeatures(EqualizerSettings settings) {
    final missing = [
      if (settings.balance != 0 && _missingFilters.contains('stereotools'))
        'balance',
      if (settings.compressor && _missingFilters.contains('acompressor'))
        'compressor',
      for (final (type, name) in const [
        (EqualizerFilterType.lowShelf, 'lowshelf'),
        (EqualizerFilterType.highShelf, 'highshelf'),
      ])
        if (settings.parametric &&
            _missingFilters.contains(name) &&
            settings.filters.any(
              (filter) => filter.enabled && filter.type == type,
            ))
          type == EqualizerFilterType.lowShelf
              ? 'low shelf filter'
              : 'high shelf filter',
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

  /// Sets the filter chain, the speed and the pitch correction for the
  /// current equalizer, [playbackSpeed] and [playbackPitch].
  Future<void> _syncEqualizer() async {
    if (_disposed) return;
    final settings = playbackEqualizer.value;
    final pitch = playbackPitch.value;
    try {
      if (settings.enabled) await _probeFilters();
      if (pitch.semitones != 0) await _probeTempoFilters();
      if (_disposed) return;
      final equalizer = _chainFor(settings);
      // The speed with the pitch following it or kept, without a shift.
      final unshifted = _tempoFor(
        PlaybackPitch(followsRate: pitch.followsRate),
      );
      var tempo = _tempoFor(pitch);
      var chain = equalizer.withTempo(tempo);
      var pitchFailed = false;
      if (pitch.semitones != 0 && chain.spec == _rejectedSpec) {
        pitchFailed = true;
        tempo = unshifted;
        chain = equalizer.withTempo(tempo);
      }
      // mpv keeps filters whose settings did not change and recreates the
      // graph, which also applies changes during playback.
      if (chain.spec != _appliedSpec) {
        var code = await _engine.setProperty('af', chain.spec);
        if (_disposed) return;
        if (code < 0 && pitch.semitones != 0 && !pitchFailed) {
          // The equalizer may still work without the shift.
          _log.w('Pitch shift unavailable (mpv error $code)');
          _rejectedSpec = chain.spec;
          pitchFailed = true;
          tempo = unshifted;
          chain = equalizer.withTempo(tempo);
          code = chain.spec == _appliedSpec
              ? 0
              : await _engine.setProperty('af', chain.spec);
          if (_disposed) return;
        }
        if (code < 0) {
          _appliedSpec = null;
          _setPitchFailed(pitch.semitones != 0);
          // A scaletempo speed without its filter would play at the wrong
          // tempo; the unshifted speed keeps the effective speed.
          await _applyTempo(unshifted);
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
      _setPitchFailed(pitchFailed);
      await _applyTempo(tempo);
      await _applyChainGain(chain);
      reportEqualizerError(playerId, _missingFeatures(settings));
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
    playbackSpeed.removeListener(_equalizerChanged);
    playbackPitch.removeListener(_equalizerChanged);
    playbackOutputVolume.removeListener(_outputVolumeChanged);
    playbackExclusiveOutput.removeListener(_exclusiveChanged);
    playbackExclusiveDevice.removeListener(_exclusiveChanged);
    _equalizerTimer?.cancel();
    _positionTimer?.cancel();
    reportEqualizerError(playerId, null);
    await stop();
    _setState(PlaybackDeckState.disposed);
    _disposed = true;
    _live.remove(this);
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
