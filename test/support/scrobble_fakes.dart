import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mornye/services/listenbrainz/listenbrainz_api.dart';
import 'package:mornye/services/scrobbling/scrobble_store.dart';

class MemoryScrobbleStore<S extends ScrobbleAccount>
    implements ScrobbleStore<S> {
  MemoryScrobbleStore({this.session, this.enabled = true});

  S? session;
  bool enabled;
  bool nowPlaying = true;
  List<QueuedScrobble> queue = [];

  @override
  Future<S?> readSession() async => session;

  @override
  Future<void> writeSession(S? value) async => session = value;

  @override
  Future<ScrobbleState> read() async =>
      (enabled: enabled, nowPlaying: nowPlaying, queue: List.of(queue));

  @override
  Future<void> write({
    required bool enabled,
    required bool nowPlaying,
    required List<QueuedScrobble> queue,
  }) async {
    this.enabled = enabled;
    this.nowPlaying = nowPlaying;
    this.queue = List.of(queue);
  }
}

const listenBrainzTestAccount = ListenBrainzAccount(
  username: 'listener',
  token: 'test-token',
);

/// A ListenBrainz server answering from memory. [submitStatus] answers
/// stored listens; Now Playing always succeeds.
class FakeListenBrainzServer {
  int submitStatus = 200;
  bool tokenValid = true;
  final submissions = <Map<String, dynamic>>[];

  /// Every stored-listen request, accepted or not.
  final requests = <Map<String, dynamic>>[];
  final urls = <Uri>[];
  bool Function(Map<String, dynamic> listen)? refuses;

  List<Map<String, dynamic>> get listens => [
    for (final body in submissions)
      if (body['listen_type'] != 'playing_now')
        for (final listen in body['payload'] as List)
          listen as Map<String, dynamic>,
  ];

  int get nowPlaying =>
      submissions.where((body) => body['listen_type'] == 'playing_now').length;

  ListenBrainzApi api() => ListenBrainzApi(
    client: MockClient((request) async {
      urls.add(request.url);
      if (request.url.path.endsWith('/validate-token')) {
        return http.Response(
          tokenValid
              ? '{"valid":true,"user_name":"listener"}'
              : '{"valid":false}',
          200,
        );
      }
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      if (body['listen_type'] == 'playing_now') {
        submissions.add(body);
        return http.Response('{"status":"ok"}', 200);
      }
      requests.add(body);
      // One malformed listen fails the whole request with HTTP 400.
      final payload = (body['payload'] as List).cast<Map<String, dynamic>>();
      if (refuses case final test? when payload.any(test)) {
        return http.Response('{"code":400,"error":"Invalid listen"}', 400);
      }
      if (submitStatus == 200) submissions.add(body);
      return http.Response('{"status":"ok"}', submitStatus);
    }),
  );
}
