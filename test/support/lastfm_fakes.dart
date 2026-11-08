import 'dart:async';

import 'package:mornye/services/lastfm/lastfm_api.dart';
import 'package:mornye/services/lastfm/lastfm_store.dart';
import 'package:mornye/services/scrobbling/scrobble_listening.dart';
import 'package:mornye/services/scrobbling/scrobble_store.dart';

const lastfmTestSession = LastfmSession(
  username: 'listener',
  key: 'session-key',
);

QueuedScrobble lastfmQueued(
  int id, {
  String username = 'listener',
  String title = 'Song',
}) => QueuedScrobble(
  id: '$id',
  username: username,
  track: ScrobbleTrack(
    title: title,
    artist: 'Artist',
    duration: const Duration(minutes: 4),
  ),
  started: DateTime.utc(2026, 11, 1, 12).add(Duration(minutes: id)),
);

class MemoryLastfmStore implements LastfmStore {
  LastfmSession? session = lastfmTestSession;
  bool enabled = true;
  bool nowPlaying = true;
  List<QueuedScrobble> queue = [];
  LastfmAuthorization? authorization;
  bool failRead = false, failWrite = false;
  int writes = 0;
  Completer<void>? sessionGate;

  @override
  Future<LastfmSession?> readSession() async => session;

  @override
  Future<LastfmAuthorization?> readAuthorization() async => authorization;

  @override
  Future<void> writeAuthorization(LastfmAuthorization? value) async {
    if (failWrite) throw StateError('Secure storage unavailable');
    authorization = value;
  }

  @override
  Future<void> writeSession(LastfmSession? value) async {
    await sessionGate?.future;
    if (failWrite) throw StateError('Secure storage unavailable');
    session = value;
  }

  @override
  Future<ScrobbleState> read() async {
    if (failRead) throw StateError('Storage unavailable');
    return (enabled: enabled, nowPlaying: nowPlaying, queue: List.of(queue));
  }

  @override
  Future<void> write({
    required bool enabled,
    required bool nowPlaying,
    required List<QueuedScrobble> queue,
  }) async {
    if (failWrite) throw StateError('Storage unavailable');
    writes++;
    this.enabled = enabled;
    this.nowPlaying = nowPlaying;
    this.queue = List.of(queue);
  }
}

class FakeLastfmApi extends LastfmApi {
  FakeLastfmApi({bool configured = true})
    : super(
        credentials: LastfmCredentials(
          apiKey: configured ? 'app-key' : '',
          apiSecret: configured ? 'app-secret' : '',
        ),
      );

  final announcements = <Map<String, String>>[];
  final batches = <List<Map<String, String>>>[];
  final accounts = <String>[];
  final accepted = <Map<String, String>>[];
  bool Function(Map<String, String> track)? refuses;
  Object? announceError, batchError, sessionError;
  Completer<LastfmSession>? sessionResult;
  Completer<void>? batchGate;
  int tokenRequests = 0;
  void Function()? onBatch;

  @override
  Future<String> requestToken() async {
    tokenRequests++;
    return 'request-token';
  }

  @override
  Future<LastfmSession> session(String token) async {
    if (sessionError case final error?) throw error;
    return sessionResult?.future ?? Future.value(lastfmTestSession);
  }

  @override
  Future<void> nowPlaying(
    LastfmSession session,
    Map<String, String> track,
  ) async {
    announcements.add(Map.of(track));
    if (announceError case final error?) throw error;
  }

  @override
  Future<void> scrobble(
    LastfmSession session,
    List<Map<String, String>> tracks,
  ) async {
    accounts.add(session.username);
    batches.add([for (final track in tracks) Map.of(track)]);
    onBatch?.call();
    await batchGate?.future;
    if (batchError case final error?) throw error;
    // Last.fm answers a malformed parameter in any listen for the request.
    if (refuses case final test? when tracks.any(test)) {
      throw const LastfmException(6);
    }
    accepted.addAll(tracks);
  }
}
