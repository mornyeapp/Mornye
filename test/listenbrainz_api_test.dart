import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mornye/services/listenbrainz/listenbrainz_api.dart';
import 'package:mornye/services/scrobbling/scrobble_listening.dart';
import 'package:mornye/services/scrobbling/scrobble_store.dart';

void main() {
  const account = ListenBrainzAccount(
    username: 'listener',
    token: 'test-token',
  );
  const track = ScrobbleTrack(
    title: 'Song',
    artist: 'Artist',
    album: 'Album',
    duration: Duration(minutes: 4),
    isrc: 'XX0000000001',
    trackNumber: 3,
  );
  QueuedScrobble queued(int minute, {ScrobbleTrack value = track}) =>
      QueuedScrobble(
        id: '$minute',
        username: 'listener',
        track: value,
        started: DateTime.utc(2026, 11, 1, 12, minute),
      );

  test('the token check sends the token only in the header', () async {
    final requests = <http.Request>[];
    final api = ListenBrainzApi(
      client: MockClient((request) async {
        requests.add(request);
        return http.Response(
          request.headers['Authorization'] == 'Token test-token'
              ? '{"code":200,"message":"Token valid.","valid":true,'
                    '"user_name":"listener"}'
              : '{"code":200,"message":"Token invalid.","valid":false}',
          200,
        );
      }),
    );
    addTearDown(api.close);
    expect(await api.validateToken('test-token'), 'listener');
    expect(await api.validateToken('other-token'), isNull);
    for (final request in requests) {
      expect(request.method, 'GET');
      expect(
        request.url.toString(),
        'https://api.listenbrainz.org/1/validate-token',
      );
      expect(request.url.query, isEmpty);
    }
  });

  test(
    'a compatible server gets the same requests under its own path',
    () async {
      final urls = <String>[];
      final api = ListenBrainzApi(
        client: MockClient((request) async {
          urls.add(request.url.toString());
          return http.Response('{"valid":true,"user_name":"listener"}', 200);
        }),
      );
      addTearDown(api.close);
      final server = normalizeListenBrainzServer(
        ' http://music.example.test:8080/apis/listenbrainz/1/ ',
      )!;
      expect(server, 'http://music.example.test:8080/apis/listenbrainz');
      await api.validateToken('test-token', server: server);
      await api.nowPlaying(
        ListenBrainzAccount(
          username: 'listener',
          token: 'test-token',
          server: server,
        ),
        track,
      );
      expect(urls, [
        'http://music.example.test:8080/apis/listenbrainz/1/validate-token',
        'http://music.example.test:8080/apis/listenbrainz/1/submit-listens',
      ]);
    },
  );

  test('server addresses must be plain http or https', () {
    expect(normalizeListenBrainzServer(''), listenBrainzDefaultServer);
    expect(
      normalizeListenBrainzServer('https://api.listenbrainz.org/'),
      listenBrainzDefaultServer,
    );
    for (final invalid in [
      'ftp://music.example.test',
      'music.example.test',
      'https://user:secret@music.example.test',
      'https://music.example.test/?token=x',
      'https://music.example.test/#x',
    ]) {
      expect(normalizeListenBrainzServer(invalid), isNull, reason: invalid);
    }
  });

  test('listens carry the known metadata and the right listen type', () async {
    final bodies = <Map<String, dynamic>>[];
    final api = ListenBrainzApi(
      client: MockClient((request) async {
        expect(request.headers['Authorization'], 'Token test-token');
        expect(request.headers['Content-Type'], startsWith('application/json'));
        bodies.add(jsonDecode(request.body) as Map<String, dynamic>);
        return http.Response('{"status":"ok"}', 200);
      }),
    );
    addTearDown(api.close);
    await api.nowPlaying(account, track);
    await api.submit(account, [queued(0)]);
    await api.submit(account, [
      queued(1),
      queued(
        2,
        value: const ScrobbleTrack(title: 'Other', artist: 'Artist'),
      ),
    ]);
    expect(bodies.map((body) => body['listen_type']), [
      'playing_now',
      'single',
      'import',
    ]);
    final playing = (bodies[0]['payload'] as List).single as Map;
    expect(playing.containsKey('listened_at'), isFalse);
    final single = (bodies[1]['payload'] as List).single as Map;
    expect(
      single['listened_at'],
      DateTime.utc(2026, 11, 1, 12).millisecondsSinceEpoch ~/ 1000,
    );
    final metadata = single['track_metadata'] as Map;
    expect(metadata['artist_name'], 'Artist');
    expect(metadata['track_name'], 'Song');
    expect(metadata['release_name'], 'Album');
    final info = metadata['additional_info'] as Map;
    expect(info['duration_ms'], 240000);
    expect(info['isrc'], 'XX0000000001');
    expect(info['tracknumber'], 3);
    expect(info['submission_client'], 'Mornye');
    final sparse =
        ((bodies[2]['payload'] as List)[1] as Map)['track_metadata'] as Map;
    expect(sparse.containsKey('release_name'), isFalse);
    expect(
      (sparse['additional_info'] as Map).keys,
      isNot(anyOf(contains('isrc'), contains('duration_ms'))),
    );
  });

  test('failures expose only the status code, never the token', () async {
    final api = ListenBrainzApi(
      client: MockClient(
        (request) async => http.Response(
          '{"code":401,"error":"Invalid authorization token."}',
          request.url.path.endsWith('validate-token') ? 500 : 401,
        ),
      ),
    );
    addTearDown(api.close);
    await expectLater(
      api.submit(account, [queued(0)]),
      throwsA(
        isA<ListenBrainzException>()
            .having((error) => error.statusCode, 'statusCode', 401)
            .having(
              (error) => error.toString(),
              'message',
              isNot(contains('test-token')),
            ),
      ),
    );
    await expectLater(
      api.validateToken('test-token'),
      throwsA(isA<ListenBrainzException>()),
    );
    expect(() => api.submit(account, const []), throwsArgumentError);
  });

  test('an account round-trips and rejects incomplete saved data', () {
    final restored = ListenBrainzAccount.fromJson(account.toJson());
    expect(restored.username, 'listener');
    expect(restored.token, 'test-token');
    expect(restored.server, listenBrainzDefaultServer);
    expect(restored.customServer, isFalse);
    expect(
      () => ListenBrainzAccount.fromJson({'name': 'listener'}),
      throwsFormatException,
    );
  });
}
