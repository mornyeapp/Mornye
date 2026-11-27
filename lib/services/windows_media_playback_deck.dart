import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:mornye/services/playback_deck.dart';
import 'package:mornye/services/playback_equalizer.dart';
import 'package:mornye/services/switching_playback_deck.dart';
import 'package:mornye/utils/logger.dart';

final _log = AppLogger('WindowsMediaDeck');

/// Windows: whether Dolby songs (E-AC-3, AC-4) play through Windows' own
/// media engine, which keeps Dolby Atmos, instead of libmpv, which decodes
/// them to plain channels. On by default; a change applies from the next
/// song.
final playbackWindowsDolbyEngine = ValueNotifier<bool>(true);

/// What this PC offers [WindowsMediaPlaybackDeck] for Dolby songs.
@immutable
class WindowsDolbySupport {
  const WindowsDolbySupport({
    required this.dolbyDigitalPlus,
    required this.ac4,
    required this.spatialSound,
  });

  /// A Dolby Digital Plus (E-AC-3) decoder, which Windows includes.
  final bool dolbyDigitalPlus;

  /// An AC-4 decoder, which only PC makers install.
  final bool ac4;

  /// A spatial sound format is on for the default output, so Atmos is
  /// rendered rather than only the channel mix.
  final bool spatialSound;
}

/// Asks Windows which Dolby decoders it has and whether spatial sound is on.
/// Null where the Windows engine is missing (Linux, macOS, Windows without
/// Media Foundation).
Future<WindowsDolbySupport?> windowsDolbySupport() async {
  try {
    final reply = await WindowsMediaPlaybackDeck._channel
        .invokeMapMethod<String, Object?>('getCapabilities');
    if (reply == null || reply['available'] != true) return null;
    return WindowsDolbySupport(
      dolbyDigitalPlus: reply['dolbyDigitalPlus'] == true,
      ac4: reply['ac4'] == true,
      spatialSound: reply['spatialSound'] == true,
    );
  } on MissingPluginException {
    return null;
  } on PlatformException catch (error) {
    _log.w('Dolby support unavailable: ${error.code}');
    return null;
  }
}

/// A failure the Windows media engine reported after its source loaded.
class WindowsMediaPlaybackException implements Exception {
  const WindowsMediaPlaybackException(this.message, {this.errorCode});

  final String message;
  final String? errorCode;

  @override
  String toString() =>
      'WindowsMediaPlaybackException: $message'
      '${errorCode == null ? '' : ' ($errorCode)'}';
}

const _rawDolbyExtensions = {'ec3', 'eac3', 'ac4'};
const _isoBmffExtensions = {'m4a', 'mp4', 'm4b', 'mov'};
const _matroskaExtensions = {'mkv', 'mka'};

String _extensionOf(String location) {
  final path = Uri.tryParse(location)?.path ?? location;
  final name = path.split(RegExp(r'[\\/]')).last;
  final dot = name.lastIndexOf('.');
  return dot <= 0 ? '' : name.substring(dot + 1).toLowerCase();
}

bool _contains(Uint8List bytes, List<int> pattern) {
  final last = bytes.length - pattern.length;
  outer:
  for (var i = 0; i <= last; i++) {
    for (var j = 0; j < pattern.length; j++) {
      if (bytes[i + j] != pattern[j]) continue outer;
    }
    return true;
  }
  return false;
}

/// Whether [path] holds Dolby Digital Plus (E-AC-3, the format of Dolby
/// Atmos music) or AC-4 audio. MP4 files are recognized by their sample
/// entry (`ec-3`, `ac-4`) in the `moov` box, wherever it sits; Matroska
/// files by their codec ID near the start. Any read failure answers false,
/// which keeps the song on libmpv.
@visibleForTesting
Future<bool> isDolbyAudioFile(String path) async {
  final extension = _extensionOf(path);
  if (_rawDolbyExtensions.contains(extension)) return true;
  final iso = _isoBmffExtensions.contains(extension);
  final matroska = _matroskaExtensions.contains(extension);
  if (!iso && !matroska) return false;
  RandomAccessFile? input;
  try {
    input = await File(path).open();
    if (matroska) {
      final head = await input.read(1 << 20);
      return _contains(head, 'A_EAC3'.codeUnits) ||
          _contains(head, 'A_AC4'.codeUnits);
    }
    final length = await input.length();
    var offset = 0;
    for (var boxes = 0; boxes < 64 && offset + 8 <= length; boxes++) {
      await input.setPosition(offset);
      final header = await input.read(16);
      if (header.length < 8) return false;
      var size = header.take(4).fold(0, (value, byte) => value << 8 | byte);
      var headerSize = 8;
      if (size == 1 && header.length == 16) {
        size = header.skip(8).fold(0, (value, byte) => value << 8 | byte);
        headerSize = 16;
      } else if (size == 0) {
        size = length - offset;
      }
      final type = String.fromCharCodes(header.sublist(4, 8));
      if (type == 'moov') {
        final body = size - headerSize;
        // A moov box describes the tracks; 32 MB is far beyond any song's.
        if (body <= 0 || body > 32 << 20) return false;
        await input.setPosition(offset + headerSize);
        final moov = await input.read(body);
        return _contains(moov, 'ec-3'.codeUnits) ||
            _contains(moov, 'ac-4'.codeUnits);
      }
      if (size < 8) return false;
      offset += size;
    }
    return false;
  } catch (error) {
    _log.w('Could not check the audio format: $error');
    return false;
  } finally {
    await input?.close();
  }
}

PlaybackDeckState? _eventState(Object? state) => switch (state) {
  'playing' => PlaybackDeckState.playing,
  'paused' => PlaybackDeckState.paused,
  _ => null,
};

/// Windows: one Media Foundation media engine in the runner
/// (`windows/runner/dolby_media_player.cpp`, channel
/// `com.zarz.mornye/windows_media_player`). Windows decodes the song with
/// its own Dolby decoders and renders Dolby Atmos through the spatial sound
/// format chosen in the sound settings (Dolby Atmos for headphones, for
/// speakers, or for home theater).
///
/// The audio never passes through the app, so the equalizer, speed and
/// pitch do not apply; volume does. No gapless queue: the next song starts
/// through the ordinary handoff.
class WindowsMediaPlaybackDeck implements PlaybackDeck {
  WindowsMediaPlaybackDeck({required this.playerId}) {
    playbackEqualizer.addListener(_equalizerChanged);
    playbackOutputVolume.addListener(_outputVolumeChanged);
    _equalizerChanged();
  }

  static const _channel = MethodChannel('com.zarz.mornye/windows_media_player');

  /// False once the native player turned out to be missing or unusable.
  static bool _missing = false;

  @visibleForTesting
  static bool? debugAvailableOverride;

  @visibleForTesting
  static void debugResetAvailability() => _missing = false;

  static bool get isAvailable => debugAvailableOverride ?? !_missing;

  /// Marks the native player unusable for the rest of this run.
  static void markUnavailable() => _missing = true;

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
  bool _loaded = false;
  Completer<void>? _preparation;
  int _token = 0;
  double _gain = 1;
  Duration? _positionInterval;
  bool Function()? _positionWanted;
  Timer? _positionTimer;
  bool _polling = false;
  bool _disposed = false;

  @override
  PlaybackDeckState get state => _state;
  @override
  bool get isDirect => false;
  @override
  PlaybackTempoSupport get tempoSupport => PlaybackTempoSupport.none;
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

  void _equalizerChanged() {
    if (_disposed) return;
    reportEqualizerError(
      playerId,
      playbackEqualizer.value.enabled
          ? 'The equalizer does not apply to Dolby Atmos playback.'
          : null,
    );
  }

  Future<void> _ensureCreated() => _created ??= _create();

  Future<void> _create() async {
    try {
      await _channel.invokeMethod<void>('create', {'playerId': playerId});
    } catch (error) {
      _created = null;
      if (error is MissingPluginException ||
          (error is PlatformException && error.code == 'unavailable')) {
        _missing = true;
      }
      rethrow;
    }
    if (_disposed) return;
    // The native side registers this stream before create replies.
    _events =
        EventChannel(
          'com.zarz.mornye/windows_media_player/events/$playerId',
        ).receiveBroadcastStream().listen(
          _onEvent,
          onError: (Object error) => _log.w('Player events: $error'),
        );
  }

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
        final state = _eventState(event['state']);
        if (state != null && _preparation == null && _loaded) _setState(state);
      case 'duration':
        final milliseconds = event['durationMs'];
        if (milliseconds is num && milliseconds > 0) {
          _duration = Duration(milliseconds: milliseconds.toInt());
          _durations.add(_duration!);
        }
      case 'completed':
        if (!_loaded) return;
        _setState(PlaybackDeckState.completed);
        _completions.add(null);
      case 'error':
        if (_preparation != null) return;
        final failure = WindowsMediaPlaybackException(
          event['message'] as String? ?? 'Windows could not play this audio.',
          errorCode: event['errorCode'] as String?,
        );
        final stack = StackTrace.current;
        _failure = AsyncError(failure, stack);
        _loaded = false;
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

  @override
  Future<void> configureOutput() =>
      _disposed ? Future.value() : _ensureCreated();

  double get _volume =>
      (_gain.clamp(0.0, 1.0) * playbackOutputVolume.value).clamp(0.0, 1.0);

  @override
  Future<void> setVolume(double volume) async {
    _gain = volume;
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

  /// Speed and pitch do not apply ([tempoSupport] is none).
  @override
  Future<void> setPlaybackRate(double rate) async {}

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
  }) => _load(path, isLocal: true);

  Future<void> _load(String uri, {required bool isLocal}) async {
    await stop();
    if (_disposed) return;
    final token = ++_token;
    _failure = null;
    _loaded = false;
    _duration = null;
    final abandoned = _preparation = Completer<void>();
    Map<Object?, Object?>? reply;
    try {
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
    // The volume set before the source applies to it as well.
    await _invoke<void>('setVolume', {'volume': _volume});
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
    final preparation = _preparation;
    _preparation = null;
    preparation?.complete();
    if (_disposed || _created == null) return;
    await _invoke<void>('stop');
    _setState(PlaybackDeckState.stopped);
  }

  /// The engine cannot hand its output to another deck.
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

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    playbackEqualizer.removeListener(_equalizerChanged);
    playbackOutputVolume.removeListener(_outputVolumeChanged);
    reportEqualizerError(playerId, null);
    _disposed = true;
    _token++;
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

/// Windows' music deck: libmpv, with Dolby songs (E-AC-3 and AC-4, see
/// [isDolbyAudioFile]) moved to [WindowsMediaPlaybackDeck] so Windows keeps
/// their Dolby Atmos. Each source picks its engine as it loads. Exclusive
/// output keeps every song on libmpv, which owns the device then. A song
/// Windows cannot open falls back to libmpv.
class WindowsDolbyEngineDeck extends SwitchingPlaybackDeck {
  WindowsDolbyEngineDeck({
    required PlaybackDeck mpv,
    required PlaybackDeck Function() createWindowsMedia,
    Future<bool> Function(String path)? isDolby,
  }) : _isDolby = isDolby ?? isDolbyAudioFile,
       super(primary: mpv, createAlternate: createWindowsMedia);

  final Future<bool> Function(String path) _isDolby;

  /// What each source was found to hold; false also for a song Windows
  /// refused, so it stays on libmpv.
  final _dolby = <String, bool>{};

  /// The source loading now, for [alternateUnavailable].
  String? _loading;

  Future<bool> _classify(String location, {required bool network}) async {
    final known = _dolby[location];
    if (known != null) return known;
    final dolby = network
        ? _rawDolbyExtensions.contains(_extensionOf(location))
        : await _isDolby(location);
    if (_dolby.length >= 512) _dolby.clear();
    return _dolby[location] = dolby;
  }

  bool get _engineWanted =>
      playbackWindowsDolbyEngine.value &&
      WindowsMediaPlaybackDeck.isAvailable &&
      !playbackExclusiveOutput.value;

  @override
  String get switchName => 'Windows Dolby engine';

  @override
  bool get reloadsOnChange => false;

  @override
  bool get routesEachSource => true;

  @override
  bool wantsAlternate(DeckSource? source) =>
      source != null && _engineWanted && (_dolby[source.location] ?? false);

  @override
  bool alternateUnavailable(Object error) {
    if (error is MissingPluginException) {
      WindowsMediaPlaybackDeck.markUnavailable();
      return true;
    }
    if (error is! PlatformException) return false;
    if (error.code == 'unavailable') {
      WindowsMediaPlaybackDeck.markUnavailable();
      return true;
    }
    if (error.code == 'unsupported') {
      final loading = _loading;
      if (loading != null) _dolby[loading] = false;
      _log.w('Windows could not open this song; playing it through libmpv');
      return true;
    }
    return false;
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
    if (_engineWanted) await _classify(path, network: false);
    _loading = path;
    return super.setFileSource(
      path,
      preferBitPerfect: preferBitPerfect,
      directUsb: directUsb,
      allowDop: allowDop,
      requiresDsd: requiresDsd,
      allowFixedVolume: allowFixedVolume,
      dapExclusive: dapExclusive,
      usbMaxSampleRate: usbMaxSampleRate,
      usbDitherHighPass: usbDitherHighPass,
    );
  }

  @override
  Future<void> setNetworkSource(String url, {bool arriving = false}) async {
    if (_engineWanted) await _classify(url, network: true);
    _loading = url;
    return super.setNetworkSource(url, arriving: arriving);
  }

  /// libmpv queues the next song on its own output; a Dolby song must not
  /// go there, so it is left to the ordinary handoff, which routes it.
  @override
  Future<bool> queueNextSource(
    String source, {
    required double volume,
    required void Function() onStarted,
  }) async {
    if (_engineWanted) {
      final network = const {
        'http',
        'https',
      }.contains(Uri.tryParse(source)?.scheme);
      if (await _classify(source, network: network)) return false;
    }
    return super.queueNextSource(source, volume: volume, onStarted: onStarted);
  }
}
