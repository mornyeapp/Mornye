import 'dart:async';

import 'package:flutter/widgets.dart'
    show AppLifecycleListener, AppLifecycleState;
import 'package:mornye/services/lastfm/lastfm_api.dart';
import 'package:mornye/services/lastfm/lastfm_store.dart';
import 'package:mornye/services/scrobbling/scrobble_listening.dart';
import 'package:mornye/services/scrobbling/scrobble_store.dart';
import 'package:mornye/services/scrobbling/scrobbler.dart';
import 'package:url_launcher/url_launcher.dart';

/// Scrobbles to a Last.fm-compatible server, Last.fm itself or Libre.fm,
/// signed in through the server's approval page in the browser.
class LastfmService extends Scrobbler<LastfmSession> {
  LastfmService({
    LastfmApi? api,
    LastfmStore? store,
    DateTime Function()? now,
    Duration Function()? elapsed,
    Future<bool> Function(Uri)? openBrowser,
  }) : this._(
         api ?? LastfmApi(),
         store ?? LocalLastfmStore(),
         openBrowser ?? _launch,
         now,
         elapsed,
       );

  LastfmService._(
    this._api,
    LastfmStore store,
    this._openBrowser,
    DateTime Function()? now,
    Duration Function()? elapsed,
  ) : _authorizations = store,
      super(store: store, now: now, elapsed: elapsed);

  /// Libre.fm, with its own account, switches and queue.
  factory LastfmService.librefm() => LastfmService(
    api: LastfmApi(server: LastfmServer.librefm),
    store: LocalLastfmStore(prefix: 'librefm'),
  );

  static Future<bool> _launch(Uri url) =>
      launchUrl(url, mode: LaunchMode.externalApplication);

  final LastfmApi _api;
  final LastfmStore _authorizations;
  final Future<bool> Function(Uri) _openBrowser;
  String? _token;
  DateTime? _tokenCreated;
  LastfmAuthorization? _restoring;
  AppLifecycleListener? _lifecycle;
  bool _away = false;
  static const _tokenLifetime = Duration(hours: 1);

  @override
  bool get configured => _api.credentials.configured;
  bool get awaitingAuthorization => _token != null;

  @override
  Future<void> readPendingConnection() async {
    try {
      _restoring = await _authorizations.readAuthorization();
    } catch (_) {
      // A lost request only means connecting again.
      _restoring = null;
    }
  }

  @override
  void didInitialize() {
    final authorization = _restoring;
    _restoring = null;
    if (authorization == null) return;
    // The app ended while the browser was open: pick the request up.
    _token = authorization.token;
    _tokenCreated = authorization.created;
    if (connected ||
        now().difference(authorization.created) >= _tokenLifetime) {
      _clearToken();
    } else {
      _watchReturn();
      unawaited(finishConnection());
    }
  }

  Future<void> beginConnection() async {
    await initialize();
    if (closed || busy || !initialized) return;
    if (!configured) {
      problem = ScrobbleProblem.unavailable;
      notify();
      return;
    }
    final generation = nextGeneration();
    busy = true;
    problem = null;
    notify();
    try {
      final token = await _api.requestToken();
      if (closed || generation != this.generation) return;
      final created = now();
      _token = token;
      _tokenCreated = created;
      try {
        // Saved before the browser opens: the app may not outlive it.
        await serialize(
          () => _authorizations.writeAuthorization((
            token: token,
            created: created,
          )),
        );
      } catch (_) {
        // Without it, connecting still finishes while the app stays open.
      }
      if (closed || generation != this.generation) return;
      _watchReturn();
      if (!await _openBrowser(_api.authorizationUrl(token))) {
        throw StateError('Could not open the approval page');
      }
    } catch (_) {
      if (!closed && generation == this.generation) {
        _clearToken();
        problem = ScrobbleProblem.connection;
      }
    } finally {
      if (generation == this.generation) busy = false;
      notify();
    }
  }

  Future<void> finishConnection() async {
    final token = _token;
    if (closed || busy || token == null) return;
    if (now().difference(_tokenCreated!) >= _tokenLifetime) {
      cancelConnection();
      problem = ScrobbleProblem.expired;
      notify();
      return;
    }
    final generation = this.generation;
    busy = true;
    problem = null;
    notify();
    var savingSession = false;
    try {
      final session = await _api.session(token);
      if (closed || generation != this.generation) return;
      savingSession = true;
      await adoptSession(session, generation);
    } on LastfmException catch (error) {
      if (!closed && generation == this.generation) {
        problem = error.code == 14
            ? ScrobbleProblem.pending
            : error.code == 15 || error.code == 4
            ? ScrobbleProblem.expired
            : ScrobbleProblem.connection;
        if (problem == ScrobbleProblem.expired) _clearToken();
      }
    } catch (_) {
      if (!closed && generation == this.generation) {
        problem = savingSession
            ? ScrobbleProblem.storage
            : ScrobbleProblem.connection;
      }
    } finally {
      if (generation == this.generation) busy = false;
      notify();
    }
  }

  void cancelConnection() {
    nextGeneration();
    _clearToken();
    busy = false;
    problem = null;
    notify();
  }

  /// Finishes connecting once the app comes back from the browser. Only a
  /// return from the background counts, not the notification shade or a
  /// dialog over the app.
  void _onLifecycle(AppLifecycleState state) {
    if (closed || _token == null) return;
    switch (state) {
      case AppLifecycleState.hidden || AppLifecycleState.paused:
        _away = true;
      case AppLifecycleState.resumed when _away:
        _away = false;
        unawaited(finishConnection());
      default:
        break;
    }
  }

  void _watchReturn() {
    _away = false;
    _lifecycle ??= AppLifecycleListener(onStateChange: _onLifecycle);
  }

  void _clearToken() {
    _lifecycle?.dispose();
    _lifecycle = null;
    _away = false;
    if (_token == null) return;
    _token = null;
    _tokenCreated = null;
    unawaited(
      serialize(
        () => _authorizations.writeAuthorization(null),
      ).catchError((Object _) {}),
    );
  }

  @override
  void abandonConnection() => _clearToken();

  @override
  Future<void> sendNowPlaying(LastfmSession session, ScrobbleTrack track) =>
      _api.nowPlaying(session, track.lastfmParameters);

  @override
  Future<void> submit(LastfmSession session, List<QueuedScrobble> batch) =>
      _api.scrobble(session, batch.map((entry) => entry.parameters).toList());

  @override
  ScrobbleFailure classify(Object error) => switch (error) {
    LastfmException(code: 9) => ScrobbleFailure.reauthenticate,
    LastfmException(retryable: false, code: 10 || 13 || 26) =>
      ScrobbleFailure.unavailable,
    LastfmException(retryable: false) => ScrobbleFailure.rejected,
    _ => ScrobbleFailure.retry,
  };

  @override
  void closeClient() {
    _lifecycle?.dispose();
    _lifecycle = null;
    _api.close();
  }
}
