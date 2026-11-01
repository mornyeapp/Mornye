import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:mornye/services/cast_media_server.dart';
import 'package:mornye/services/cast_output.dart';
import 'package:mornye/services/playback_deck.dart';

class CastPlaybackDeck implements PlaybackDeck {
  CastPlaybackDeck({
    required this.output,
    required this.metadata,
    CastMediaServer? server,
  }) : _server = server ?? CastMediaServer() {
    _subscription = output.updates.listen(_receive);
  }

  final CastOutput output;
  final MediaItem? Function() metadata;
  final CastMediaServer _server;
  final _states = StreamController<PlaybackDeckState>.broadcast(sync: true);
  final _positions = StreamController<Duration>.broadcast(sync: true);
  final _durations = StreamController<Duration>.broadcast(sync: true);
  final _completions = StreamController<void>.broadcast(sync: true);
  late final StreamSubscription<Map<Object?, Object?>> _subscription;
  Future<void>? _serving;
  static int _nextToken = 0;
  int _token = 0;
  bool _ready = false;
  Duration _position = Duration.zero, _duration = Duration.zero;
  PlaybackDeckState _state = PlaybackDeckState.stopped;

  @override
  PlaybackDeckState get state => _state;
  @override
  bool get isDirect => false;
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
    if (!_ready ||
        event['token'] != _token ||
        _state == PlaybackDeckState.disposed) {
      return;
    }
    if (event['failed'] == true || event['error'] != null) {
      _ready = false;
      _setState(PlaybackDeckState.paused);
      _states.addError(StateError('TV could not play this audio file'));
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
    if (event['finished'] == true && _state != PlaybackDeckState.completed) {
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
    _ => throw UnsupportedError(
      'This audio format is not supported by Google Cast',
    ),
  };

  Future<void> _load(String source) async {
    final token = _token = ++_nextToken;
    _ready = false;
    final item = metadata();
    final path = Uri.tryParse(source)?.path ?? source;
    final format = item?.extras?['format'] as String?;
    final mime = mimeType(
      format == null || format.isEmpty ? path.split('.').last : format,
    );
    final serving = _serving ??= _server.start(
      output.host ?? (throw StateError('TV has no network address')),
    );
    try {
      await serving;
    } on Object {
      if (identical(_serving, serving)) _serving = null;
      rethrow;
    }
    if (token != _token || _state == PlaybackDeckState.disposed) return;
    _server.clear();
    final url = _server.register(source, mime);
    String? artwork;
    final art = item?.artUri;
    if (art != null && const {'http', 'https', 'file'}.contains(art.scheme)) {
      artwork = _server
          .register(
            art.scheme == 'file' ? art.toFilePath() : art.toString(),
            'image/jpeg',
          )
          .toString();
    }
    _duration = item?.duration ?? Duration.zero;
    await output.command('load', {
      'url': url.toString(),
      'mime': mime,
      'token': token,
      'title': item?.title ?? '',
      'artist': item?.artist ?? '',
      'album': item?.album ?? '',
      'duration': _duration.inMilliseconds,
      'artwork': ?artwork,
    });
    if (token != _token || _state == PlaybackDeckState.disposed) return;
    _position = Duration.zero;
    _ready = true;
    _setState(PlaybackDeckState.paused);
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
    if (!_ready) throw StateError('TV source is not ready');
    await output.command('play');
    _setState(PlaybackDeckState.playing);
  }

  @override
  Future<void> pause() async {
    if (_ready && output.connected) await output.command('pause');
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
    final loaded = _ready;
    _ready = false;
    if (loaded && output.connected) await output.command('stop');
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
    await _server.close();
    unawaited(_states.close());
    unawaited(_positions.close());
    unawaited(_durations.close());
    unawaited(_completions.close());
  }
}
