import 'dart:async';

import 'package:mornye/services/network_storage_service.dart';
import 'package:mornye/services/playback_deck.dart';

/// Restarts non-seekable Subsonic transcodes at an absolute song position.
/// The engine sees a segment starting at zero; consumers see the full song.
class SubsonicPlaybackDeck implements PlaybackDeck, QueuedPlaybackDeck {
  SubsonicPlaybackDeck({required this.inner, required this.lookup}) {
    _subscriptions.addAll([
      inner.onPlayerStateChanged.listen((state) {
        if (!_loading) _states.add(state);
      }, onError: _states.addError),
      inner.onPositionChanged.listen((position) {
        if (!_loading) _positions.add(_absolute(position));
      }, onError: _positions.addError),
      inner.onDurationChanged.listen((duration) {
        if (!_loading) _durations.add(_stream?.duration ?? duration + _offset);
      }, onError: _durations.addError),
      inner.onPlayerComplete.listen((_) {
        if (!_loading) _completions.add(null);
      }, onError: _completions.addError),
    ]);
  }

  final PlaybackDeck inner;
  final Future<SubsonicPlaybackStream?> Function(String url) lookup;
  final _states = StreamController<PlaybackDeckState>.broadcast();
  final _positions = StreamController<Duration>.broadcast();
  final _durations = StreamController<Duration>.broadcast();
  final _completions = StreamController<void>.broadcast();
  final _subscriptions = <StreamSubscription<dynamic>>[];
  SubsonicPlaybackStream? _stream;
  Duration _offset = Duration.zero;
  bool _loading = false, _disposed = false, _wantPlaying = false;
  bool _needsReload = false;
  int _revision = 0;
  int _queueRevision = 0;
  double _volume = 1, _rate = 1;

  Duration _absolute(Duration position) {
    final result = position + _offset;
    final duration = _stream?.duration;
    return duration != null && result > duration ? duration : result;
  }

  bool _current(int revision) => !_disposed && revision == _revision;

  @override
  PlaybackDeckState get state => inner.state;
  @override
  bool get isDirect => inner.isDirect;
  @override
  bool get needsSourceReload => _needsReload || inner.needsSourceReload;
  @override
  Stream<PlaybackDeckState> get onPlayerStateChanged => _states.stream;
  @override
  Stream<Duration> get onPositionChanged => _positions.stream;
  @override
  Stream<Duration> get onDurationChanged => _durations.stream;
  @override
  Stream<void> get onPlayerComplete => _completions.stream;
  @override
  void startPositionUpdates(Duration interval, {bool Function()? wanted}) =>
      inner.startPositionUpdates(interval, wanted: wanted);
  @override
  Future<void> configureOutput() => inner.configureOutput();
  @override
  Future<void> setVolume(double volume) {
    _volume = volume;
    return inner.setVolume(volume);
  }

  @override
  Future<void> setPlaybackRate(double rate) {
    _rate = rate;
    return inner.setPlaybackRate(rate);
  }

  @override
  Future<void> setNetworkSource(String url, {bool arriving = false}) async {
    final revision = ++_revision;
    _stream = null;
    _offset = Duration.zero;
    _wantPlaying = false;
    _loading = true;
    try {
      final stream = await lookup(url);
      if (!_current(revision)) return;
      _stream = stream;
      _loading = false;
      await inner.setNetworkSource(url, arriving: arriving);
      if (_current(revision)) {
        _needsReload = false;
        if (stream?.duration case final duration?) _durations.add(duration);
      }
    } finally {
      if (_current(revision)) _loading = false;
    }
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
  }) {
    ++_revision;
    _stream = null;
    _offset = Duration.zero;
    _loading = false;
    _wantPlaying = false;
    _needsReload = false;
    return inner.setFileSource(
      path,
      preferBitPerfect: preferBitPerfect,
      directUsb: directUsb,
      allowDop: allowDop,
      requiresDsd: requiresDsd,
      allowFixedVolume: allowFixedVolume,
      dapExclusive: dapExclusive,
    );
  }

  @override
  Future<void> seek(Duration position) async {
    final stream = _stream;
    if (stream == null ||
        (_offset == Duration.zero && !stream.requiresOffset(stream.url))) {
      return inner.seek(position);
    }
    var target = position < Duration.zero ? Duration.zero : position;
    final duration = stream.duration;
    if (duration != null && duration > Duration.zero && target >= duration) {
      // An exact EOF offset produces no audio for the engine to prepare.
      target = duration - const Duration(microseconds: 1);
    }
    // stream.timeOffset is expressed in whole seconds. Keep the engine
    // offset identical to the value sent to the server.
    target = Duration(seconds: target.inSeconds);
    final revision = ++_revision;
    _loading = true;
    _needsReload = true;
    try {
      await inner.pause();
      if (!_current(revision)) return;
      await inner.setNetworkSource(stream.at(target));
      if (!_current(revision)) return;
      _offset = target;
      await inner.setVolume(_volume);
      await inner.setPlaybackRate(_rate);
      if (!_current(revision)) return;
      _needsReload = false;
      _loading = false;
      if (duration != null) _durations.add(duration);
      _positions.add(target);
      if (_wantPlaying) await inner.resume();
    } finally {
      if (_current(revision)) _loading = false;
    }
  }

  @override
  Future<Duration?> getCurrentPosition() async {
    final revision = _revision;
    final position = await inner.getCurrentPosition();
    return _current(revision) && !_loading && !_needsReload && position != null
        ? _absolute(position)
        : null;
  }

  @override
  Future<Duration?> getDuration() async {
    if (_stream?.duration case final duration?) return duration;
    final revision = _revision;
    final duration = await inner.getDuration();
    return _current(revision) && duration != null ? duration + _offset : null;
  }

  @override
  Future<void> pause() {
    _wantPlaying = false;
    return inner.pause();
  }

  @override
  Future<void> resume() async {
    _wantPlaying = true;
    if (!_loading) await inner.resume();
  }

  @override
  Future<void> cancelPreparation() {
    _needsReload = _needsReload || _loading;
    ++_revision;
    _loading = false;
    _wantPlaying = false;
    return inner.cancelPreparation();
  }

  @override
  Future<void> stop() {
    ++_revision;
    _stream = null;
    _offset = Duration.zero;
    _loading = false;
    _wantPlaying = false;
    _needsReload = false;
    return inner.stop();
  }

  @override
  bool get canQueueNextSource =>
      inner is QueuedPlaybackDeck &&
      (inner as QueuedPlaybackDeck).canQueueNextSource;
  @override
  Future<bool> queueNextSource(
    String source, {
    required double volume,
    required void Function() onStarted,
  }) async {
    if (!canQueueNextSource) return false;
    final revision = _revision;
    final queueRevision = ++_queueRevision;
    final stream = await lookup(source);
    if (!_current(revision) || queueRevision != _queueRevision) return false;
    return (inner as QueuedPlaybackDeck).queueNextSource(
      source,
      volume: volume,
      onStarted: () {
        if (!_current(revision) || queueRevision != _queueRevision) return;
        ++_revision;
        _stream = stream;
        _offset = Duration.zero;
        _loading = false;
        _wantPlaying = true;
        if (stream?.duration case final duration?) _durations.add(duration);
        onStarted();
      },
    );
  }

  @override
  Future<void> clearNextSource() async {
    ++_queueRevision;
    if (inner case final QueuedPlaybackDeck queued) {
      await queued.clearNextSource();
    }
  }

  @override
  Future<bool> setNextDeck(PlaybackDeck? next) =>
      inner.setNextDeck(next is SubsonicPlaybackDeck ? next.inner : next);
  @override
  Future<void> dispose() async {
    _disposed = true;
    ++_revision;
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    await inner.dispose();
    await _states.close();
    await _positions.close();
    await _durations.close();
    await _completions.close();
  }
}
