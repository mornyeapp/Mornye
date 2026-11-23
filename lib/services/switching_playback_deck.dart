import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:mornye/services/playback_deck.dart';
import 'package:mornye/utils/logger.dart';

final _log = AppLogger('SwitchingPlaybackDeck');

/// A source as a deck was asked to load it, kept so another deck can open
/// it again.
@immutable
class DeckSource {
  const DeckSource.file(
    this.location, {
    this.preferBitPerfect = false,
    this.directUsb = false,
    this.allowDop = false,
    this.requiresDsd = false,
    this.allowFixedVolume = false,
    this.dapExclusive = false,
    this.usbMaxSampleRate = 0,
    this.usbDitherHighPass = false,
  }) : network = false,
       arriving = false;

  const DeckSource.network(this.location, {this.arriving = false})
    : network = true,
      preferBitPerfect = false,
      directUsb = false,
      allowDop = false,
      requiresDsd = false,
      allowFixedVolume = false,
      dapExclusive = false,
      usbMaxSampleRate = 0,
      usbDitherHighPass = false;

  /// What a [QueuedPlaybackDeck] started: a URL or a path.
  factory DeckSource.queued(String source) =>
      const {'http', 'https'}.contains(Uri.tryParse(source)?.scheme)
      ? DeckSource.network(source)
      : DeckSource.file(source);

  /// A path or URL.
  final String location;
  final bool network;
  final bool arriving;
  final bool preferBitPerfect;
  final bool directUsb;
  final bool allowDop;
  final bool requiresDsd;
  final bool allowFixedVolume;
  final bool dapExclusive;
  final int usbMaxSampleRate;
  final bool usbDitherHighPass;

  /// Whether only Android's native USB and AAudio outputs, which the
  /// audioplayers deck hosts, can play this source the way it was asked
  /// for. [directUsb], [dapExclusive] and [allowDop] refine
  /// [preferBitPerfect] and change nothing without it.
  bool get needsNativeOutput => preferBitPerfect || requiresDsd;

  Future<void> loadOn(PlaybackDeck deck) => network
      ? deck.setNetworkSource(location, arriving: arriving)
      : deck.setFileSource(
          location,
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

/// One deck for the music runtime that plays through a primary deck, or
/// through an alternate deck created while a subclass wants it, and moves
/// between the two. A deck taking over gets the volume, rate and position
/// updates set so far; leaving the alternate disposes it.
///
/// A subclass picks the deck either before each source, in
/// [configureOutput], or as each source loads ([routesEachSource]), and
/// decides whether a [trigger] change mid-track reopens the source on the
/// other deck where it was ([reloadsOnChange]).
abstract class SwitchingPlaybackDeck
    implements PlaybackDeck, QueuedPlaybackDeck {
  SwitchingPlaybackDeck({
    required PlaybackDeck primary,
    required PlaybackDeck Function() createAlternate,
    Listenable? trigger,
  }) : _primary = primary,
       _active = primary,
       _createAlternate = createAlternate,
       _trigger = trigger {
    _attach(primary);
    trigger?.addListener(_triggerChanged);
  }

  final PlaybackDeck _primary;
  final PlaybackDeck Function() _createAlternate;
  final Listenable? _trigger;
  PlaybackDeck? _alternate;
  PlaybackDeck _active;
  final _subscriptions = <PlaybackDeck, List<StreamSubscription<dynamic>>>{};
  final _states = StreamController<PlaybackDeckState>.broadcast();
  final _durations = StreamController<Duration>.broadcast();
  final _positions = StreamController<Duration>.broadcast();
  final _completions = StreamController<void>.broadcast();
  int _queueRevision = 0;

  /// Settings a deck taking over must apply as well.
  double _volume = 1, _rate = 1;
  Duration? _positionInterval;
  bool Function()? _positionWanted;

  /// The current source; null before the first.
  DeckSource? _source;

  /// Switches run one at a time, in order.
  Future<void> _switching = Future.value();
  int _pendingSwitches = 0;
  int _transportRevision = 0;
  int _stopRevision = 0;
  int _loadRevision = 0;
  PlaybackDeckState? _requestedState;
  bool _disposed = false;

  /// Whether the alternate deck should play. [source] is the source about to
  /// load when [routesEachSource], the current one for a [trigger] reload,
  /// and null for the choice [configureOutput] makes.
  @protected
  bool wantsAlternate(DeckSource? source);

  /// True: a [trigger] change mid-track reopens the current source on the
  /// other deck where it was. False: the change applies from the next source.
  @protected
  bool get reloadsOnChange;

  /// True: each source picks its deck as it loads, from [wantsAlternate]
  /// with that source. False: [configureOutput] picks it before the source.
  @protected
  bool get routesEachSource;

  /// Whether [error], from loading a source on the alternate deck, means
  /// its engine is missing; the source then loads on the primary deck.
  @protected
  bool alternateUnavailable(Object error) => false;

  /// Names the switch in log messages.
  @protected
  String get switchName;

  /// The deck playing now, for checks that need the engine's own type.
  PlaybackDeck get activeDeck => _active;

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

  void _triggerChanged() {
    if (_disposed || !reloadsOnChange) return;
    unawaited(
      _queueSwitch(
        reload: true,
      ).catchError((Object error) => _log.w('$switchName: $error')),
    );
  }

  Future<void> _queueSwitch({bool reload = false, DeckSource? source}) {
    _pendingSwitches++;
    final operation = _switching
        .then((_) => _switchTo(reload: reload, source: source))
        .whenComplete(() => _pendingSwitches--);
    // Keep later output changes available after a failed switch.
    _switching = operation.catchError((Object _) {});
    return operation;
  }

  Future<void> _switchTo({required bool reload, DeckSource? source}) async {
    if (_disposed) return;
    final alternate = wantsAlternate(reload ? _source : source);
    final previous = _active;
    if (alternate == !identical(previous, _primary)) return;
    _queueRevision++;
    final PlaybackDeck target;
    if (alternate) {
      target = _alternate = _createAlternate();
      _attach(target);
    } else {
      target = _primary;
    }
    final state = previous.state;
    final transportRevision = _transportRevision;
    final stopRevision = _stopRevision;
    final position = reload ? await previous.getCurrentPosition() : null;
    if (_disposed) return;
    _active = target;
    if (target.tempoSupport != previous.tempoSupport) {
      notifyPlaybackTempoSupportChanged();
    }
    await target.setVolume(_volume);
    await target.setPlaybackRate(_rate);
    if (_positionInterval case final interval?) {
      target.startPositionUpdates(interval, wanted: _positionWanted);
    }
    await previous.stop();
    if (!alternate) {
      _alternate = null;
      for (final subscription
          in _subscriptions.remove(previous) ??
              const <StreamSubscription<dynamic>>[]) {
        await subscription.cancel();
      }
      await previous.dispose();
    }
    final current = _source;
    if (_disposed ||
        stopRevision != _stopRevision ||
        !reload ||
        current == null ||
        (state != PlaybackDeckState.playing &&
            state != PlaybackDeckState.paused)) {
      return;
    }
    await target.configureOutput();
    if (_disposed || stopRevision != _stopRevision) return;
    await current.loadOn(target);
    if (_disposed) return;
    if (stopRevision != _stopRevision) {
      await target.stop();
      return;
    }
    if (position != null && position > Duration.zero) {
      await target.seek(position);
    }
    if (_disposed || stopRevision != _stopRevision) return;
    if (transportRevision == _transportRevision) {
      if (state == PlaybackDeckState.playing) await target.resume();
    } else if (_requestedState == PlaybackDeckState.paused) {
      await target.pause();
    }
  }

  /// Loads [source] on the deck it routes to, or on the active deck when
  /// the deck is picked before each source.
  Future<void> _load(DeckSource source) async {
    _queueRevision++;
    _source = source;
    if (!routesEachSource) return source.loadOn(_active);
    final revision = ++_loadRevision;
    bool stale() => _disposed || revision != _loadRevision;
    final previous = _active;
    try {
      if (_pendingSwitches > 0 ||
          wantsAlternate(source) == identical(previous, _primary)) {
        await _queueSwitch(source: source);
        if (stale()) return;
      }
      final target = _active;
      // configureOutput reached the deck that played before; this one needs
      // it as well.
      if (!identical(target, previous)) await target.configureOutput();
      if (stale()) return;
      await source.loadOn(target);
    } catch (error) {
      if (identical(_active, _primary) ||
          !alternateUnavailable(error) ||
          stale()) {
        rethrow;
      }
      _log.w('$switchName unavailable, using the primary deck: $error');
      // wantsAlternate now answers false.
      await _queueSwitch(source: source);
      if (stale()) return;
      await _active.configureOutput();
      if (stale()) return;
      await source.loadOn(_active);
    }
  }

  @override
  PlaybackDeckState get state => _active.state;
  @override
  bool get isDirect => _active.isDirect;

  /// Every deck reads [playbackSpeed] and [playbackPitch] itself, so the one
  /// taking over already plays at the current values.
  @override
  PlaybackTempoSupport get tempoSupport => _active.tempoSupport;
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
  bool get canQueueNextSource =>
      _active is QueuedPlaybackDeck &&
      (_active as QueuedPlaybackDeck).canQueueNextSource;

  @override
  Future<bool> queueNextSource(
    String source, {
    required double volume,
    required void Function() onStarted,
  }) async {
    final active = _active;
    if (active is! QueuedPlaybackDeck || !active.canQueueNextSource) {
      return false;
    }
    final revision = ++_queueRevision;
    return active.queueNextSource(
      source,
      volume: volume,
      onStarted: () {
        if (_disposed ||
            revision != _queueRevision ||
            !identical(active, _active)) {
          return;
        }
        _volume = volume;
        _source = DeckSource.queued(source);
        onStarted();
      },
    );
  }

  @override
  Future<void> clearNextSource() async {
    _queueRevision++;
    if (_disposed) return;
    if (_active case final QueuedPlaybackDeck deck) {
      await deck.clearNextSource();
    }
  }

  @override
  void startPositionUpdates(Duration interval, {bool Function()? wanted}) {
    _positionInterval = interval;
    _positionWanted = wanted;
    _active.startPositionUpdates(interval, wanted: wanted);
  }

  @override
  Future<void> configureOutput() async {
    if (routesEachSource) {
      if (_pendingSwitches > 0) await _switching;
    } else {
      await _queueSwitch();
    }
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
  Future<void> setNetworkSource(String url, {bool arriving = false}) =>
      _load(DeckSource.network(url, arriving: arriving));

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
  }) => _load(
    DeckSource.file(
      path,
      preferBitPerfect: preferBitPerfect,
      directUsb: directUsb,
      allowDop: allowDop,
      requiresDsd: requiresDsd,
      allowFixedVolume: allowFixedVolume,
      dapExclusive: dapExclusive,
      usbMaxSampleRate: usbMaxSampleRate,
      usbDitherHighPass: usbDitherHighPass,
    ),
  );

  @override
  Future<void> cancelPreparation() {
    _transportRevision++;
    _stopRevision++;
    _loadRevision++;
    return _active.cancelPreparation();
  }

  @override
  Future<void> resume() async {
    final revision = ++_transportRevision;
    _requestedState = PlaybackDeckState.playing;
    await _switching;
    if (_disposed || revision != _transportRevision) return;
    await _active.resume();
  }

  @override
  Future<void> pause() {
    _transportRevision++;
    _requestedState = PlaybackDeckState.paused;
    return _active.pause();
  }

  @override
  Future<void> seek(Duration position) => _active.seek(position);
  @override
  Future<void> stop() {
    _queueRevision++;
    _transportRevision++;
    _stopRevision++;
    _loadRevision++;
    _requestedState = PlaybackDeckState.stopped;
    return _active.stop();
  }

  @override
  Future<bool> setNextDeck(PlaybackDeck? next) =>
      _active.setNextDeck(next is SwitchingPlaybackDeck ? next._active : next);
  @override
  Future<Duration?> getCurrentPosition() => _active.getCurrentPosition();
  @override
  Future<Duration?> getDuration() => _active.getDuration();

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _trigger?.removeListener(_triggerChanged);
    await _switching;
    for (final subscriptions in _subscriptions.values) {
      for (final subscription in subscriptions) {
        await subscription.cancel();
      }
    }
    _subscriptions.clear();
    await _primary.dispose();
    await _alternate?.dispose();
    await _states.close();
    await _durations.close();
    await _positions.close();
    await _completions.close();
  }
}
