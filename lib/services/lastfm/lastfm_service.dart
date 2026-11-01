import 'dart:async';
import 'dart:math';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';
import 'package:mornye/services/lastfm/lastfm_api.dart';
import 'package:mornye/services/lastfm/lastfm_listening.dart';
import 'package:mornye/services/lastfm/lastfm_store.dart';
import 'package:url_launcher/url_launcher.dart';

enum LastfmProblem {
  connection,
  storage,
  pending,
  expired,
  reauthenticate,
  unavailable,
  rejected,
}

/// Bound only to the local audio handler. Remote Link sessions and short
/// catalog previews never feed this service.
class LastfmService extends ChangeNotifier {
  LastfmService({
    LastfmApi? api,
    LastfmStore? store,
    DateTime Function()? now,
    Duration Function()? elapsed,
    Future<bool> Function(Uri)? openBrowser,
  }) : _api = api ?? LastfmApi(),
       _store = store ?? LocalLastfmStore(),
       _now = now ?? DateTime.now,
       _elapsed = elapsed,
       _openBrowser = openBrowser ?? _launch {
    _clock.start();
    _listening = LastfmListening(
      elapsed: () => _elapsed?.call() ?? _clock.elapsed,
      now: _now,
      onNowPlaying: (track) => unawaited(_announce(track)),
      onScrobble: (track, started) => unawaited(_enqueue(track, started)),
    );
  }

  static Future<bool> _launch(Uri url) =>
      launchUrl(url, mode: LaunchMode.externalApplication);

  final LastfmApi _api;
  final LastfmStore _store;
  final DateTime Function() _now;
  final Duration Function()? _elapsed;
  final Future<bool> Function(Uri) _openBrowser;
  final _clock = Stopwatch();
  late final LastfmListening _listening;
  final _subscriptions = <StreamSubscription<Object?>>[];
  AudioHandler? _handler;
  LastfmSession? _session;
  String? _token;
  DateTime? _tokenCreated;
  final _queue = <LastfmScrobble>[];
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
  LastfmProblem? _problem;
  String Function() _unknownTitle = () => 'Unknown title';
  String Function() _unknownArtist = () => 'Unknown artist';

  bool get configured => _api.credentials.configured;
  bool get initialized => _initialized;
  bool get connected => _session != null;
  String? get username => _session?.username;
  bool get enabled => _enabled;
  bool get nowPlaying => _nowPlaying;
  bool get busy => _busy;
  bool get awaitingAuthorization => _token != null;
  int get pendingCount => _queue.length;
  LastfmProblem? get problem => _problem;
  bool get _active => !_closed && configured && _enabled && connected;

  void _notify() {
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
    } catch (_) {
      _problem = LastfmProblem.storage;
    } finally {
      _initializing = null;
      _notify();
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
  }

  void _configure() {
    _ticker?.cancel();
    _retry?.cancel();
    _ticker = null;
    _retry = null;
    _updateListening();
    if (!_active) return;
    _ticker = Timer.periodic(
      const Duration(seconds: 1),
      (_) => _listening.tick(),
    );
    _retry = Timer.periodic(
      const Duration(seconds: 30),
      (_) => unawaited(flush()),
    );
  }

  Future<void> beginConnection() async {
    await initialize();
    if (_closed || _busy || !_initialized) return;
    if (!configured) {
      _problem = LastfmProblem.unavailable;
      _notify();
      return;
    }
    final generation = ++_generation;
    _busy = true;
    _problem = null;
    _notify();
    try {
      final token = await _api.requestToken();
      if (_closed || generation != _generation) return;
      _token = token;
      _tokenCreated = _now();
      if (!await _openBrowser(_api.authorizationUrl(token))) {
        throw StateError('Could not open Last.fm');
      }
    } catch (_) {
      if (!_closed && generation == _generation) {
        _token = null;
        _problem = LastfmProblem.connection;
      }
    } finally {
      if (generation == _generation) _busy = false;
      _notify();
    }
  }

  Future<void> finishConnection() async {
    final token = _token;
    if (_closed || _busy || token == null) return;
    if (_now().difference(_tokenCreated!) >= const Duration(hours: 1)) {
      cancelConnection();
      _problem = LastfmProblem.expired;
      _notify();
      return;
    }
    final generation = _generation;
    _busy = true;
    _problem = null;
    _notify();
    var savingSession = false;
    try {
      final session = await _api.session(token);
      if (_closed || generation != _generation) return;
      savingSession = true;
      await _serialize(() => _store.writeSession(session));
      if (_closed || generation != _generation) return;
      _session = session;
      _token = null;
      _enabled = true;
      _listening.reset();
      await _save();
      _configure();
      unawaited(flush());
    } on LastfmException catch (error) {
      if (!_closed && generation == _generation) {
        _problem = error.code == 14
            ? LastfmProblem.pending
            : error.code == 15 || error.code == 4
            ? LastfmProblem.expired
            : LastfmProblem.connection;
        if (_problem == LastfmProblem.expired) _token = null;
      }
    } catch (_) {
      if (!_closed && generation == _generation) {
        _problem = savingSession
            ? LastfmProblem.storage
            : LastfmProblem.connection;
      }
    } finally {
      if (generation == _generation) _busy = false;
      _notify();
    }
  }

  void cancelConnection() {
    _generation++;
    _token = null;
    _busy = false;
    _problem = null;
    _notify();
  }

  Future<void> disconnect() async {
    await initialize();
    if (_closed || !_initialized) return;
    cancelConnection();
    _listening.reset();
    _session = null;
    _enabled = false;
    _queue.clear();
    _configure();
    try {
      await _serialize(() => _store.writeSession(null));
      await _save();
    } catch (_) {
      _problem = LastfmProblem.storage;
    }
    _notify();
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
      if (_problem == LastfmProblem.storage) _problem = null;
    } catch (_) {
      _problem = LastfmProblem.storage;
    }
    _notify();
  }

  Future<void> _serialize(Future<void> Function() write) {
    final result = _writes.then((_) => write());
    _writes = result.catchError((Object _) {});
    return result;
  }

  Future<void> _save() async {
    final revision = ++_revision;
    _durable = false;
    final enabled = _enabled, nowPlaying = _nowPlaying;
    final queue = List<LastfmScrobble>.of(_queue);
    await _serialize(
      () =>
          _store.write(enabled: enabled, nowPlaying: nowPlaying, queue: queue),
    );
    if (revision == _revision) _durable = true;
  }

  Future<void> _announce(LastfmTrack track) async {
    final session = _session;
    if (!_active || !_nowPlaying || session == null) return;
    final generation = _generation;
    try {
      await _api.nowPlaying(session, track.toJson());
    } on LastfmException catch (error) {
      if (error.code == 9) await _expiredSession(generation);
    } catch (_) {
      // Now Playing describes a live moment, so failed requests are not retried.
    }
  }

  Future<void> _enqueue(LastfmTrack track, DateTime started) async {
    final session = _session;
    if (!_active || session == null) return;
    final random = Random.secure().nextInt(1 << 32);
    _queue.add(
      LastfmScrobble(
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
          .take(50)
          .toList();
      if (batch.isEmpty) return;
      try {
        await _api.scrobble(
          session,
          batch.map((entry) => entry.parameters).toList(),
        );
        if (_closed) return;
        final acknowledged = batch.map((entry) => entry.id).toSet();
        _queue.removeWhere((entry) => acknowledged.contains(entry.id));
        await _save();
        if (generation == _generation) _problem = null;
        _notify();
      } on LastfmException catch (error) {
        if (error.code == 9) {
          await _expiredSession(generation);
        } else if (!_closed && generation == _generation && !error.retryable) {
          if (const {10, 13, 26}.contains(error.code)) {
            _enabled = false;
            _problem = LastfmProblem.unavailable;
            _configure();
          } else {
            final rejected = batch.map((entry) => entry.id).toSet();
            _queue.removeWhere((entry) => rejected.contains(entry.id));
            _problem = LastfmProblem.rejected;
          }
          await _saveSafely();
        } else if (!_closed && generation == _generation) {
          _problem = LastfmProblem.connection;
          _notify();
        }
        return;
      } catch (_) {
        if (!_closed && generation == _generation) {
          _problem = _durable
              ? LastfmProblem.connection
              : LastfmProblem.storage;
          _notify();
        }
        return;
      }
    }
  }

  Future<void> _expiredSession(int generation) async {
    if (_closed || generation != _generation) return;
    _generation++;
    _busy = false;
    _token = null;
    _listening.reset();
    _session = null;
    _enabled = false;
    _problem = LastfmProblem.reauthenticate;
    _configure();
    try {
      await _serialize(() => _store.writeSession(null));
      await _save();
    } catch (_) {
      _problem = LastfmProblem.storage;
    }
    _notify();
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
    _api.close();
    await _writes;
    _clock.stop();
    super.dispose();
  }
}
