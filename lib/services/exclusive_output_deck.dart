import 'dart:async';

import 'package:mornye/services/playback_deck.dart';
import 'package:mornye/utils/logger.dart';

final _log = AppLogger('ExclusiveOutputDeck');

/// macOS: AVPlayer cannot play while the app holds the output in hog mode,
/// so exclusive output plays through a libmpv deck (`audio-exclusive`)
/// instead. This deck plays through the shared deck and moves to a libmpv
/// deck while [playbackExclusiveOutput] is on; a change mid-track reopens the
/// source on the other deck where it was. Leaving exclusive output disposes
/// the libmpv deck, which gives the device back.
class ExclusiveOutputDeck implements PlaybackDeck {
  ExclusiveOutputDeck({
    required PlaybackDeck shared,
    required PlaybackDeck Function() createExclusive,
    required bool Function() exclusiveAvailable,
  }) : _shared = shared,
       _active = shared,
       _createExclusive = createExclusive,
       _exclusiveAvailable = exclusiveAvailable {
    _attach(shared);
    playbackExclusiveOutput.addListener(_exclusiveChanged);
  }

  final PlaybackDeck _shared;
  final PlaybackDeck Function() _createExclusive;
  final bool Function() _exclusiveAvailable;
  PlaybackDeck? _exclusive;
  PlaybackDeck _active;
  final _subscriptions = <PlaybackDeck, List<StreamSubscription<dynamic>>>{};
  final _states = StreamController<PlaybackDeckState>.broadcast();
  final _durations = StreamController<Duration>.broadcast();
  final _positions = StreamController<Duration>.broadcast();
  final _completions = StreamController<void>.broadcast();

  /// Settings a deck taking over must apply as well.
  double _volume = 1, _rate = 1;
  Duration? _positionInterval;

  /// Loads the current source on a deck; null before the first.
  Future<void> Function(PlaybackDeck deck)? _source;

  /// Switches run one at a time, in order.
  Future<void> _switching = Future.value();
  bool _disposed = false;

  void _attach(PlaybackDeck deck) {
    void Function(T) forward<T>(StreamController<T> to) => (value) {
      if (identical(deck, _active)) to.add(value);
    };
    _subscriptions[deck] = [
      deck.onPlayerStateChanged.listen(
        forward(_states),
        onError: (Object error, StackTrace stack) {
          if (identical(deck, _active)) _states.addError(error, stack);
        },
      ),
      deck.onDurationChanged.listen(forward(_durations)),
      deck.onPositionChanged.listen(forward(_positions)),
      deck.onPlayerComplete.listen(forward(_completions)),
    ];
  }

  bool get _wantsExclusive {
    if (!playbackExclusiveOutput.value) return false;
    if (_exclusiveAvailable()) return true;
    playbackExclusiveStatus.value = ExclusiveOutputStatus.unavailable;
    return false;
  }

  void _exclusiveChanged() {
    if (_disposed) return;
    unawaited(
      _queueSwitch(
        reload: true,
      ).catchError((Object error) => _log.w('Exclusive output: $error')),
    );
  }

  Future<void> _queueSwitch({bool reload = false}) =>
      _switching = _switching.then((_) => _switchTo(reload: reload));

  Future<void> _switchTo({required bool reload}) async {
    if (_disposed) return;
    final exclusive = _wantsExclusive;
    final previous = _active;
    if (exclusive == !identical(previous, _shared)) return;
    final PlaybackDeck target;
    if (exclusive) {
      target = _exclusive = _createExclusive();
      _attach(target);
    } else {
      target = _shared;
    }
    final state = previous.state;
    final position = await previous.getCurrentPosition();
    _active = target;
    await target.setVolume(_volume);
    await target.setPlaybackRate(_rate);
    if (_positionInterval case final interval?) {
      target.startPositionUpdates(interval);
    }
    await previous.stop();
    if (!exclusive) {
      _exclusive = null;
      for (final subscription
          in _subscriptions.remove(previous) ??
              const <StreamSubscription<dynamic>>[]) {
        await subscription.cancel();
      }
      await previous.dispose();
    }
    final source = _source;
    if (!reload ||
        source == null ||
        (state != PlaybackDeckState.playing &&
            state != PlaybackDeckState.paused)) {
      return;
    }
    await target.configureOutput();
    await source(target);
    if (position != null && position > Duration.zero) {
      await target.seek(position);
    }
    if (state == PlaybackDeckState.playing) await target.resume();
  }

  @override
  PlaybackDeckState get state => _active.state;
  @override
  bool get isDirect => _active.isDirect;
  @override
  bool get needsSourceReload => _active.needsSourceReload;
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
    _positionInterval = interval;
    _active.startPositionUpdates(interval);
  }

  @override
  Future<void> configureOutput() async {
    await _queueSwitch();
    await _active.configureOutput();
  }

  @override
  Future<void> setVolume(double volume) {
    _volume = volume;
    return _active.setVolume(volume);
  }

  @override
  Future<void> setPlaybackRate(double rate) {
    _rate = rate;
    return _active.setPlaybackRate(rate);
  }

  @override
  Future<void> setNetworkSource(String url, {bool arriving = false}) {
    _source = (deck) => deck.setNetworkSource(url, arriving: arriving);
    return _active.setNetworkSource(url, arriving: arriving);
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
    _source = (deck) => deck.setFileSource(
      path,
      preferBitPerfect: preferBitPerfect,
      directUsb: directUsb,
      allowDop: allowDop,
      requiresDsd: requiresDsd,
      allowFixedVolume: allowFixedVolume,
      dapExclusive: dapExclusive,
    );
    return _source!(_active);
  }

  @override
  Future<void> cancelPreparation() => _active.cancelPreparation();
  @override
  Future<void> resume() => _active.resume();
  @override
  Future<void> pause() => _active.pause();
  @override
  Future<void> seek(Duration position) => _active.seek(position);
  @override
  Future<void> stop() => _active.stop();
  @override
  Future<Duration?> getCurrentPosition() => _active.getCurrentPosition();
  @override
  Future<Duration?> getDuration() => _active.getDuration();

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    playbackExclusiveOutput.removeListener(_exclusiveChanged);
    for (final subscriptions in _subscriptions.values) {
      for (final subscription in subscriptions) {
        await subscription.cancel();
      }
    }
    _subscriptions.clear();
    await _shared.dispose();
    await _exclusive?.dispose();
    await _states.close();
    await _durations.close();
    await _positions.close();
    await _completions.close();
  }
}
