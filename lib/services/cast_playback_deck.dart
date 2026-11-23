import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:mornye/services/cast_output.dart';
import 'package:mornye/services/playback_deck.dart';
import 'package:mornye/utils/logger.dart';

final _log = AppLogger('CastPlaybackDeck');

/// Plays the queue on a Cast receiver. Songs reach it through the native
/// media server (`serve`, `register`), which exposes only the registered
/// files and streams, on the interface that reaches the receiver.
class CastPlaybackDeck implements PlaybackDeck {
  CastPlaybackDeck({required this.output, required this.metadata}) {
    _subscription = output.updates.listen(_receive);
  }

  final CastOutput output;
  final MediaItem? Function() metadata;
  final _states = StreamController<PlaybackDeckState>.broadcast(sync: true);
  final _positions = StreamController<Duration>.broadcast(sync: true);
  final _durations = StreamController<Duration>.broadcast(sync: true);
  final _completions = StreamController<void>.broadcast(sync: true);
  late final StreamSubscription<Map<Object?, Object?>> _subscription;
  Future<void>? _serving;
  static int _nextToken = 0;
  int _token = 0;
  bool _ready = false;
  // The receiver played the loaded song to its end.
  bool _finished = false;
  Duration _position = Duration.zero, _duration = Duration.zero;
  PlaybackDeckState _state = PlaybackDeckState.stopped;

  @override
  PlaybackDeckState get state => _state;
  @override
  bool get isDirect => false;

  /// The receiver plays the file itself, at normal speed and pitch.
  @override
  PlaybackTempoSupport get tempoSupport => PlaybackTempoSupport.none;
  @override
  bool get needsSourceReload => !output.connected;
  @override
  Stream<PlaybackDeckState> get onPlayerStateChanged => _states.stream;
  @override
  Stream<Duration> get onPositionChanged => _positions.stream;
  @override
  Stream<Duration> get onDurationChanged => _durations.stream;
  @override
  Stream<void> get onPlayerComplete => _completions.stream;

  void _setState(PlaybackDeckState value) {
    if (_state == PlaybackDeckState.disposed || _state == value) return;
    _state = value;
    _states.add(value);
  }

  void _receive(Map<Object?, Object?> event) {
    final mediaError = event['mediaError'];
    if (mediaError != null) _log.w('TV reported a media error: $mediaError');
    if (!_ready ||
        event['token'] != _token ||
        _state == PlaybackDeckState.disposed) {
      return;
    }
    if (event['failed'] == true || event['error'] != null) {
      _ready = false;
      _setState(PlaybackDeckState.paused);
      _states.addError(
        StateError('The cast device could not play this audio file'),
      );
      return;
    }
    _position = Duration(
      milliseconds: (event['position'] as num?)?.toInt() ?? 0,
    );
    _positions.add(_position);
    final duration = Duration(
      milliseconds: (event['duration'] as num?)?.toInt() ?? 0,
    );
    if (duration > Duration.zero && duration != _duration) {
      _duration = duration;
      _durations.add(duration);
    }
    if (event['finished'] == true) {
      if (_finished) return;
      _finished = true;
      _setState(PlaybackDeckState.completed);
      _completions.add(null);
    } else if (event['suspended'] == true) {
      _setState(PlaybackDeckState.paused);
    } else if (event['state'] == 2) {
      _setState(PlaybackDeckState.playing);
    } else if (event['state'] == 3) {
      _setState(PlaybackDeckState.paused);
    }
  }

  static String mimeType(String? format) => switch (format?.toLowerCase()) {
    'mp3' => 'audio/mpeg',
    'flac' => 'audio/flac',
    'm4a' || 'mp4' || 'alac' => 'audio/mp4',
    'aac' => 'audio/aac',
    'ogg' || 'opus' => 'audio/ogg',
    'wav' => 'audio/wav',
    'webm' => 'audio/webm',
    _ => throw UnsupportedError('This audio format cannot be cast'),
  };

  Future<void> _load(String source) async {
    final token = _token = ++_nextToken;
    _ready = false;
    _finished = false;
    final item = metadata();
    final path = Uri.tryParse(source)?.path ?? source;
    final format = item?.extras?['format'] as String?;
    final mime = mimeType(
      format == null || format.isEmpty ? path.split('.').last : format,
    );
    final serving = _serving ??= output.command('serve', {
      'host':
          output.host ??
          (throw StateError('The cast device has no network address')),
    });
    try {
      await serving;
    } on Object {
      if (identical(_serving, serving)) _serving = null;
      rethrow;
    }
    if (token != _token || _state == PlaybackDeckState.disposed) return;
    await output.command('clearMedia');
    final url = await _register(source, mime);
    String? artwork;
    final art = item?.artUri;
    if (art != null && const {'http', 'https', 'file'}.contains(art.scheme)) {
      artwork = await _register(
        art.scheme == 'file' ? art.toFilePath() : art.toString(),
        'image/jpeg',
      );
    }
    if (token != _token || _state == PlaybackDeckState.disposed) return;
    _duration = item?.duration ?? Duration.zero;
    if (_network(Uri.tryParse(url)?.host) != _network(output.host)) {
      _log.w('The TV and the media server may be on different networks');
    }
    // A TV that cannot reach the media server answers nothing. The platform
    // gives up first, and its error says why; this limit is the backstop.
    await output.command('load', {
      'url': url,
      'mime': mime,
      'token': token,
      'title': item?.title ?? '',
      'artist': item?.artist ?? '',
      'album': item?.album ?? '',
      'duration': _duration.inMilliseconds,
      'artwork': ?artwork,
    }, const Duration(seconds: 35));
    if (token != _token || _state == PlaybackDeckState.disposed) return;
    _position = Duration.zero;
    _ready = true;
    _setState(PlaybackDeckState.paused);
  }

  /// The first three parts of an IPv4 address, for the log only.
  static String _network(String? address) =>
      address == null ? '' : address.substring(0, address.lastIndexOf('.') + 1);

  Future<String> _register(String source, String mime) async {
    final reply = await output.request<Map<Object?, Object?>>('register', {
      'source': source,
      'mime': mime,
    });
    final url = reply?['url'];
    if (url is! String) {
      throw StateError('The cast media server did not answer');
    }
    return url;
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
  }) => _load(path);
  @override
  Future<void> setNetworkSource(String url, {bool arriving = false}) =>
      _load(url);
  @override
  Future<void> configureOutput() async {}
  @override
  Future<void> setVolume(double volume) async {}
  @override
  Future<void> setPlaybackRate(double rate) async {}
  @override
  void startPositionUpdates(Duration interval, {bool Function()? wanted}) {}
  @override
  Future<void> cancelPreparation() async {
    if (!_ready) _token = ++_nextToken;
  }

  @override
  Future<void> resume() async {
    if (!_ready) throw StateError('The cast source is not ready');
    await output.command('play');
    _setState(PlaybackDeckState.playing);
  }

  /// The receiver still holds the loaded song. One that finished it has no
  /// media session left and answers a transport command with an error.
  bool get _holdsSong => _ready && !_finished && output.connected;

  @override
  Future<void> pause() async {
    if (_holdsSong) await output.command('pause');
    _setState(PlaybackDeckState.paused);
  }

  @override
  Future<void> seek(Duration position) async {
    if (!_ready) return;
    await output.command('seek', {'position': position.inMilliseconds});
    _position = position;
    _positions.add(position);
  }

  @override
  Future<void> stop() async {
    final holdsSong = _holdsSong;
    _ready = false;
    if (holdsSong) {
      try {
        await output.command('stop');
      } on Object catch (error) {
        // The song change that asked for this must go on: the next load
        // replaces whatever the receiver still plays.
        _log.w('TV did not stop: $error');
      }
    }
    _setState(PlaybackDeckState.stopped);
  }

  @override
  Future<bool> setNextDeck(PlaybackDeck? next) async => false;
  @override
  Future<Duration?> getCurrentPosition() async => _position;
  @override
  Future<Duration?> getDuration() async => _duration;
  @override
  Future<void> dispose() async {
    _state = PlaybackDeckState.disposed;
    _token = ++_nextToken;
    await _subscription.cancel();
    if (_serving != null) {
      try {
        await output.command('closeMedia');
      } on Object {
        // The session or the native side may already be gone.
      }
    }
    unawaited(_states.close());
    unawaited(_positions.close());
    unawaited(_durations.close());
    unawaited(_completions.close());
  }
}
