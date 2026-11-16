import 'dart:async';

import 'package:mornye/services/listenbrainz/listenbrainz_api.dart';
import 'package:mornye/services/scrobbling/scrobble_listening.dart';
import 'package:mornye/services/scrobbling/scrobble_store.dart';
import 'package:mornye/services/scrobbling/scrobbler.dart';

LocalScrobbleStore<ListenBrainzAccount> localListenBrainzStore() =>
    LocalScrobbleStore(
      sessionKey: 'listenbrainz_session_v1',
      stateKey: 'listenbrainz_scrobbles_v1',
      decode: ListenBrainzAccount.fromJson,
      encode: (account) => account.toJson(),
    );

/// Submits listens to ListenBrainz or a compatible server, signed in with
/// the user token from the account's settings page.
class ListenBrainzService extends Scrobbler<ListenBrainzAccount> {
  ListenBrainzService({
    ListenBrainzApi? api,
    ScrobbleStore<ListenBrainzAccount>? store,
    super.now,
    super.elapsed,
  }) : _api = api ?? ListenBrainzApi(),
       super(store: store ?? localListenBrainzStore());

  final ListenBrainzApi _api;

  @override
  bool get configured => true;

  String? get server => session?.server;

  /// Checks [token] with [server] (empty for ListenBrainz itself) and signs
  /// in when it is accepted.
  Future<void> connect(String token, {String server = ''}) async {
    await initialize();
    if (closed || busy || !initialized) return;
    final value = token.trim();
    final address = normalizeListenBrainzServer(server);
    if (value.isEmpty ||
        address == null ||
        !listenBrainzServerSecure(address)) {
      problem = value.isEmpty
          ? ScrobbleProblem.invalidToken
          : address == null
          ? ScrobbleProblem.connection
          : ScrobbleProblem.insecureServer;
      notify();
      return;
    }
    final generation = nextGeneration();
    busy = true;
    problem = null;
    notify();
    var savingSession = false;
    try {
      final username = await _api.validateToken(value, server: address);
      if (closed || generation != this.generation) return;
      if (username == null) {
        problem = ScrobbleProblem.invalidToken;
        return;
      }
      savingSession = true;
      await adoptSession(
        ListenBrainzAccount(username: username, token: value, server: address),
        generation,
      );
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

  /// An account saved with a plain http:// address outside the local
  /// network is signed out before anything is sent. Its listens stay
  /// queued for the next sign-in.
  @override
  void didInitialize() {
    if (session case final account?
        when !listenBrainzServerSecure(account.server)) {
      unawaited(endSession(ScrobbleProblem.insecureServer));
    }
  }

  @override
  Future<void> sendNowPlaying(
    ListenBrainzAccount session,
    ScrobbleTrack track,
  ) => _api.nowPlaying(session, track);

  @override
  Future<void> submit(
    ListenBrainzAccount session,
    List<QueuedScrobble> batch,
  ) => _api.submit(session, batch);

  @override
  ScrobbleFailure classify(Object error) => switch (error) {
    // Forgets a token that would otherwise be sent in the clear.
    ListenBrainzException(statusCode: 401) ||
    ListenBrainzInsecureServerException() => ScrobbleFailure.reauthenticate,
    ListenBrainzException(statusCode: 400 || 413) => ScrobbleFailure.rejected,
    _ => ScrobbleFailure.retry,
  };

  @override
  void closeClient() => _api.close();
}
