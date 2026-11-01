import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mornye/services/lastfm/lastfm_api.dart';

void main() {
  const credentials = LastfmCredentials(
    apiKey: 'app-key',
    apiSecret: 'app-secret',
  );

  test('signature sorts ASCII keys and signs UTF-8 before URL encoding', () {
    final parameters = {
      'track[1]': 'Jóga',
      'artist[1]': 'Björk',
      'track[10]': '十',
      'method': 'track.scrobble',
      'format': 'json',
      'callback': 'ignored',
    };
    final expected = md5
        .convert(
          utf8.encode(
            'artist[1]Björkmethodtrack.scrobbletrack[10]十track[1]Jógaapp-secret',
          ),
        )
        .toString();
    expect(lastfmSignature(parameters, credentials.apiSecret), expected);
  });

  test('token and session requests use HTTPS and signed form bodies', () async {
    final requests = <http.Request>[];
    final api = LastfmApi(
      credentials: credentials,
      client: MockClient((request) async {
        requests.add(request);
        if (request.bodyFields['method'] == 'auth.getToken') {
          return http.Response('{"token":"request-token"}', 200);
        }
        return http.Response(
          '{"session":{"name":"listener","key":"session-key"}}',
          200,
        );
      }),
    );
    addTearDown(api.close);
    final token = await api.requestToken();
    expect(api.authorizationUrl(token).queryParameters, {
      'api_key': 'app-key',
      'token': token,
    });
    final session = await api.session(token);
    expect(session.username, 'listener');
    for (final request in requests) {
      expect(request.method, 'POST');
      expect(request.url.toString(), 'https://ws.audioscrobbler.com/2.0/');
      expect(request.url.query, isEmpty);
      expect(
        request.bodyFields['api_sig'],
        lastfmSignature(request.bodyFields, 'app-secret'),
      );
    }
  });

  test(
    'a 200 response can reject a session without leaking credentials',
    () async {
      final api = LastfmApi(
        credentials: credentials,
        client: MockClient(
          (_) async => http.Response(
            '{"error":9,"message":"private-response-session-key"}',
            200,
          ),
        ),
      );
      addTearDown(api.close);
      await expectLater(
        api.session('private-request-token'),
        throwsA(
          isA<LastfmException>()
              .having((error) => error.code, 'code', 9)
              .having(
                (error) => error.toString(),
                'message',
                isNot(contains('private')),
              ),
        ),
      );
    },
  );

  test(
    'scrobble batches retain start timestamps and distinguish ignored plays',
    () async {
      late Map<String, String> sent;
      final api = LastfmApi(
        credentials: credentials,
        client: MockClient((request) async {
          sent = request.bodyFields;
          return http.Response(
            '{"scrobbles":{"@attr":{"accepted":"1","ignored":"1"}}}',
            200,
          );
        }),
      );
      addTearDown(api.close);
      await api.scrobble(
        const LastfmSession(username: 'listener', key: 'session-key'),
        [
          {'track': 'First', 'artist': 'Artist', 'timestamp': '1700000000'},
          {'track': 'Second', 'artist': 'Artist', 'timestamp': '1700000100'},
        ],
      );
      expect(sent['timestamp[0]'], '1700000000');
      expect(sent['timestamp[1]'], '1700000100');
      expect(sent['sk'], 'session-key');
      expect(sent.keys, isNot(contains('username')));
    },
  );

  test(
    'incomplete acknowledgement is not treated as a successful batch',
    () async {
      final api = LastfmApi(
        credentials: credentials,
        client: MockClient(
          (_) async => http.Response(
            '{"scrobbles":{"@attr":{"accepted":"0","ignored":"0"}}}',
            200,
          ),
        ),
      );
      addTearDown(api.close);
      await expectLater(
        api.scrobble(const LastfmSession(username: 'listener', key: 'key'), [
          {'track': 'Song', 'artist': 'Artist', 'timestamp': '1700000000'},
        ]),
        throwsFormatException,
      );
    },
  );

  test('unconfigured builds make no network requests', () async {
    final api = LastfmApi(
      credentials: const LastfmCredentials(apiKey: '', apiSecret: ''),
      client: MockClient((_) async => fail('Unexpected network request')),
    );
    addTearDown(api.close);
    await expectLater(api.requestToken(), throwsA(isA<LastfmException>()));
  });

  test(
    'HTTP service outages and rate limiting are retryable even without JSON',
    () async {
      for (final status in [429, 500, 503]) {
        final api = LastfmApi(
          credentials: credentials,
          client: MockClient(
            (_) async => http.Response('<html>Unavailable</html>', status),
          ),
        );
        addTearDown(api.close);
        await expectLater(
          api.requestToken(),
          throwsA(
            isA<LastfmException>().having(
              (error) => error.retryable,
              'retryable',
              isTrue,
            ),
          ),
        );
      }
    },
  );

  test(
    'non-API HTTP errors do not reject otherwise valid cached scrobbles',
    () async {
      final api = LastfmApi(
        credentials: credentials,
        client: MockClient(
          (_) async => http.Response('<html>Proxy unavailable</html>', 403),
        ),
      );
      addTearDown(api.close);
      await expectLater(api.requestToken(), throwsFormatException);
    },
  );
}
