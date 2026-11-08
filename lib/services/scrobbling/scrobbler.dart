import 'dart:async';
import 'dart:math';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';
import 'package:mornye/services/scrobbling/scrobble_listening.dart';
import 'package:mornye/services/scrobbling/scrobble_store.dart';

enum ScrobbleProblem {
  connection,
  storage,
  pending,
  expired,
  reauthenticate,
  unavailable,
  rejected,
  invalidToken,
}

/// How a service's failed request affects its queue.
enum ScrobbleFailure {
  /// Temporary: the listens stay queued and are retried.
  retry,

  /// The account is no longer accepted: sign in again, listens stay queued.
  reauthenticate,

  /// The service refuses this client: scrobbling turns off.
  unavailable,

  /// The listens themselves were refused and leave the queue.
  rejected,
}

/// One scrobbling service bound to the local audio handler: it counts
/// listening with the shared rules, keeps its own durable queue and retries
/// it independently of other services. Remote Link sessions and short
/// catalog previews never feed it.
///
/// Subclasses sign in and talk to their service; this class owns the
/// listening, the queue and its persistence.
abstract class Scrobbler<S extends ScrobbleAccount> extends ChangeNotifier {
  Scrobbler({
    required ScrobbleStore<S> store,
    DateTime Function()? now,
    Duration Function()? elapsed,
  }) : _store = store,
       _now = now ?? DateTime.now,
       _elapsed = elapsed {
    _clock.start();
    _listening = ScrobbleListening(
      elapsed: () => _elapsed?.call() ?? _clock.elapsed,
      now: _now,
      onNowPlaying: (track) => unawaited(_announce(track)),
      onScrobble: (track, started) => unawaited(_enqueue(track, started)),
    );
  }

  final ScrobbleStore<S> _store;
  final DateTime Function() _now;
  final Duration Function()? _elapsed;
  final _clock = Stopwatch();
  late final ScrobbleListening _listening;
  final _subscriptions = <StreamSubscription<Object?>>[];
  AudioHandler? _handler;
  S? _session;
  final _queue = <QueuedScrobble>[];
  Future<void>? _initializing;
  Future<void>? _flushing;
  Future<void> _writes = Future.value();
  Timer? _ticker;
  Timer? _retry;
  bool _initialized = false;
  bool _enabled = false;
  bool _nowPlaying = true;
  bool _busy = false;
  bool _closed = false;
  bool _durable = false;
  int _generation = 0;
  int _revision = 0;
  ScrobbleProblem? _problem;
  String Function() _unknownTitle = () => 'Unknown title';
  String Function() _unknownArtist = () => 'Unknown artist';

  /// Whether this build can reach the service at all.
  bool get configured;

  /// The most listens one submission carries.
  @protected
  int get batchSize => 50;

  @protected
  Future<void> sendNowPlaying(S session, ScrobbleTrack track);

  /// Submits [batch] in full or throws; a throw keeps or drops the batch as
  /// [classify] decides.
  @protected
  Future<void> submit(S session, List<QueuedScrobble> batch);

  @protected
  ScrobbleFailure classify(Object error);

  /// Reads what a sign-in left behind before the app ended. Must not throw.
  @protected
  Future<void> readPendingConnection() async {}

  /// Called once the saved state is loaded.
  @protected
  void didInitialize() {}

  /// Forgets a sign-in in progress, without notifying.
  @protected
  void abandonConnection() {}

  /// Releases the service client. A sign-in in progress stays saved, so it
  /// can finish after the app starts again.
  @protected
  void closeClient();

  bool get initialized => _initialized;
  bool get connected => _session != null;
  String? get username => _session?.username;
  bool get enabled => _enabled;
  bool get nowPlaying => _nowPlaying;
  bool get busy => _busy;
  int get pendingCount => _queue.length;
  ScrobbleProblem? get problem => _problem;
  bool get _active => !_closed && configured && _enabled && connected;

  @protected
  S? get session => _session;

  @protected
  bool get closed => _closed;

  @protected
  set busy(bool value) => _busy = value;

  @protected
  set problem(ScrobbleProblem? value) => _problem = value;

  /// Requests started before the latest sign-in, sign-out or expiry carry
  /// an older generation and must not apply their results.
  @protected
  int get generation => _generation;

  @protected
  int nextGeneration() => ++_generation;

  @protected
  DateTime now() => _now();

  @protected
  void notify() {
    if (!_closed) notifyListeners();
  }

  Future<void> initialize() {
    if (_closed || _initialized) return Future.value();
    return _initializing ??= _initialize();
  }

  Future<void> _initialize() async {
    try {
      final saved = await _store.read();
      final session = await _store.readSession();
      await readPendingConnection();
      if (_closed) return;
      _enabled = saved.enabled;
      _nowPlaying = saved.nowPlaying;
      _queue.addAll(saved.queue);
      _session = session;
      _durable = true;
      _initialized = true;
      _problem = null;
      _configure();
      unawaited(flush());
      didInitialize();
    } catch (_) {
      _problem = ScrobbleProblem.storage;
    } finally {
      _initializing = null;
      notify();
    }
  }

  void bind(
    AudioHandler? handler, {
    String Function()? unknownTitle,
    String Function()? unknownArtist,
  }) {
    if (_closed || identical(_handler, handler)) return;
    _listening.tick();
    _listening.reset();
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    _subscriptions.clear();
    _handler = handler;
    if (unknownTitle != null) _unknownTitle = unknownTitle;
    if (unknownArtist != null) _unknownArtist = unknownArtist;
    if (handler != null) {
      void update(Object? _) {
        if (identical(handler, _handler)) _updateListening();
      }

      _subscriptions.add(handler.mediaItem.listen(update));
      _subscriptions.add(handler.playbackState.listen(update));
    }
    unawaited(initialize());
    _updateListening();
  }

  void _updateListening() {
    final handler = _handler;
    _listening.update(
      handler?.mediaItem.value,
      handler?.playbackState.value ?? PlaybackState(),
      enabled: _initialized && _active,
      unknownTitle: _unknownTitle(),
      unknownArtist: _unknownArtist(),
    );
    // Counting only matters while a song plays; an idle phone is not woken
    // every second.
    if (_active && _listening.playing) {
      _ticker ??= Timer.periodic(
        const Duration(seconds: 1),
        (_) => _listening.tick(),
      );
    } else {
      _ticker?.cancel();
      _ticker = null;
    }
  }

  void _configure() {
    _ticker?.cancel();
    _retry?.cancel();
    _ticker = null;
    _retry = null;
    _updateListening();
    if (!_active) return;
    _retry = Timer.periodic(
      const Duration(seconds: 30),
      (_) => unawaited(flush()),
    );
  }

  /// Saves a session the service just granted and turns scrobbling on.
  /// Returns false when a newer sign-in, sign-out or close superseded it.
  @protected
  Future<bool> adoptSession(S session, int generation) async {
    await _serialize(() => _store.writeSession(session));
    if (_closed || generation != _generation) return false;
    _session = session;
    abandonConnection();
    _enabled = true;
    _listening.reset();
    await _save();
    _configure();
    unawaited(flush());
    return true;
  }

  Future<void> disconnect() async {
    await initialize();
    if (_closed || !_initialized) return;
    _generation++;
    abandonConnection();
    _busy = false;
    _problem = null;
    _listening.reset();
    _session = null;
    _enabled = false;
    _queue.clear();
    _configure();
    try {
      await _serialize(() => _store.writeSession(null));
      await _save();
    } catch (_) {
      _problem = ScrobbleProblem.storage;
    }
    notify();
  }

  Future<void> setEnabled(bool value) async {
    await initialize();
    if (_closed || !_initialized || !connected) return;
    _listening.tick();
    _enabled = value;
    _configure();
    await _saveSafely();
    if (value) unawaited(flush());
  }

  Future<void> setNowPlaying(bool value) async {
    await initialize();
    if (_closed || !_initialized) return;
    _nowPlaying = value;
    if (value) {
      _listening.resetAnnouncement();
      _updateListening();
    }
    await _saveSafely();
  }

  Future<void> retry() async {
    if (!_initialized) {
      await initialize();
      return;
    }
    await _saveSafely();
    if (_durable) _configure();
    await flush();
  }

  Future<void> _saveSafely() async {
    try {
      await _save();
      if (_problem == ScrobbleProblem.storage) _problem = null;
    } catch (_) {
      _problem = ScrobbleProblem.storage;
    }
    notify();
  }

  /// Runs secure-storage and preference writes one after another.
  @protected
  Future<void> serialize(Future<void> Function() write) => _serialize(write);

  Future<void> _serialize(Future<void> Function() write) {
    final result = _writes.then((_) => write());
    _writes = result.catchError((Object _) {});
    return result;
  }

  Future<void> _save() async {
    final revision = ++_revision;
    _durable = false;
    final enabled = _enabled, nowPlaying = _nowPlaying;
    final queue = List<QueuedScrobble>.of(_queue);
    await _serialize(
      () =>
          _store.write(enabled: enabled, nowPlaying: nowPlaying, queue: queue),
    );
    if (revision == _revision) _durable = true;
  }

  Future<void> _announce(ScrobbleTrack track) async {
    final session = _session;
    if (!_active || !_nowPlaying || session == null) return;
    final generation = _generation;
    try {
      await sendNowPlaying(session, track);
    } catch (error) {
      // Now Playing describes a live moment, so failed requests are not
      // retried.
      if (classify(error) == ScrobbleFailure.reauthenticate) {
        await _expiredSession(generation);
      }
    }
  }

  Future<void> _enqueue(ScrobbleTrack track, DateTime started) async {
    final session = _session;
    if (!_active || session == null) return;
    final random = Random.secure().nextInt(1 << 32);
    _queue.add(
      QueuedScrobble(
        id: '${started.microsecondsSinceEpoch}-$random',
        username: session.username,
        track: track,
        started: started,
      ),
    );
    // Last.fm ignores timestamps older than two weeks. Bound disk usage too.
    final oldest = _now().subtract(const Duration(days: 14));
    _queue.removeWhere((entry) => entry.started.isBefore(oldest));
    if (_queue.length > 2000) _queue.removeRange(0, _queue.length - 2000);
    await _saveSafely();
    unawaited(flush());
  }

  Future<void> flush() {
    if (!_initialized || !_active || !_durable || _queue.isEmpty) {
      return Future.value();
    }
    return _flushing ??= _flush().whenComplete(() => _flushing = null);
  }

  Future<void> _flush() async {
    while (_active && _durable) {
      final session = _session!;
      final generation = _generation;
      final batch = _queue
          .where((entry) => entry.username == session.username)
          .take(batchSize)
          .toList();
      if (batch.isEmpty) return;
      try {
        await submit(session, batch);
      } catch (error) {
        await _failed(error, batch, generation);
        return;
      }
      try {
        if (_closed) return;
        final acknowledged = batch.map((entry) => entry.id).toSet();
        _queue.removeWhere((entry) => acknowledged.contains(entry.id));
        await _save();
        if (generation == _generation) _problem = null;
        notify();
      } catch (_) {
        if (!_closed && generation == _generation) {
          _problem = ScrobbleProblem.storage;
          notify();
        }
        return;
      }
    }
  }

  Future<void> _failed(
    Object error,
    List<QueuedScrobble> batch,
    int generation,
  ) async {
    final failure = classify(error);
    if (failure == ScrobbleFailure.reauthenticate) {
      await _expiredSession(generation);
      return;
    }
    if (_closed || generation != _generation) return;
    switch (failure) {
      case ScrobbleFailure.unavailable:
        _enabled = false;
        _problem = ScrobbleProblem.unavailable;
        _configure();
        await _saveSafely();
      case ScrobbleFailure.rejected:
        final rejected = batch.map((entry) => entry.id).toSet();
        _queue.removeWhere((entry) => rejected.contains(entry.id));
        _problem = ScrobbleProblem.rejected;
        await _saveSafely();
      case ScrobbleFailure.retry || ScrobbleFailure.reauthenticate:
        _problem = _durable
            ? ScrobbleProblem.connection
            : ScrobbleProblem.storage;
        notify();
    }
  }

  Future<void> _expiredSession(int generation) async {
    if (_closed || generation != _generation) return;
    _generation++;
    _busy = false;
    abandonConnection();
    _listening.reset();
    _session = null;
    _enabled = false;
    _problem = ScrobbleProblem.reauthenticate;
    _configure();
    try {
      await _serialize(() => _store.writeSession(null));
      await _save();
    } catch (_) {
      _problem = ScrobbleProblem.storage;
    }
    notify();
  }

  Future<void> close() async {
    if (_closed) return;
    _listening.tick();
    _closed = true;
    _generation++;
    _ticker?.cancel();
    _retry?.cancel();
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    _subscriptions.clear();
    closeClient();
    await _writes;
    _clock.stop();
    super.dispose();
  }
}
