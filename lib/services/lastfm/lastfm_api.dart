import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:mornye/services/scrobbling/scrobble_store.dart';

class LastfmCredentials {
  const LastfmCredentials({
    this.apiKey = const String.fromEnvironment('LASTFM_API_KEY'),
    this.apiSecret = const String.fromEnvironment('LASTFM_API_SECRET'),
  });

  /// Libre.fm has no client registration: it accepts any 32 character key,
  /// which only names the client, and does not check signatures. Requests
  /// are still signed so other compatible servers accept them too. Neither
  /// value grants access to an account.
  const LastfmCredentials.librefm()
    : apiKey = const String.fromEnvironment(
        'LIBREFM_API_KEY',
        defaultValue: 'mornyemusicplayerlibrefmclient01',
      ),
      apiSecret = const String.fromEnvironment(
        'LIBREFM_API_SECRET',
        defaultValue: 'mornye',
      );

  final String apiKey;
  final String apiSecret;

  bool get configured => apiKey.isNotEmpty && apiSecret.isNotEmpty;
}

/// A server speaking the Last.fm 2.0 API, with its browser approval page.
class LastfmServer {
  const LastfmServer({
    required this.apiHost,
    required this.authHost,
    required this.credentials,
    this.apiPath = '/2.0/',
    this.authPath = '/api/auth/',
  });

  static const lastfm = LastfmServer(
    apiHost: 'ws.audioscrobbler.com',
    authHost: 'www.last.fm',
    credentials: LastfmCredentials(),
  );

  static const librefm = LastfmServer(
    apiHost: 'libre.fm',
    authHost: 'libre.fm',
    credentials: LastfmCredentials.librefm(),
  );

  final String apiHost;
  final String apiPath;
  final String authHost;
  final String authPath;
  final LastfmCredentials credentials;
}

class LastfmSession implements ScrobbleAccount {
  const LastfmSession({required this.username, required this.key});

  factory LastfmSession.fromJson(Map<String, dynamic> json) {
    final username = json['name'] as String? ?? '';
    final key = json['key'] as String? ?? '';
    if (username.isEmpty || key.isEmpty) {
      throw const FormatException('Invalid Last.fm session');
    }
    return LastfmSession(username: username, key: key);
  }

  @override
  final String username;
  final String key;

  Map<String, String> toJson() => {'name': username, 'key': key};
}

class LastfmException implements Exception {
  const LastfmException(this.code);

  final int code;

  bool get retryable => const {11, 16, 29}.contains(code);

  @override
  String toString() => 'Last.fm request failed (code $code)';
}

/// Last.fm signs the original UTF-8 parameter values, before form encoding.
/// Response format and callback parameters are excluded from the signature.
String lastfmSignature(Map<String, String> parameters, String secret) {
  final keys =
      parameters.keys
          .where(
            (key) => !const {'format', 'callback', 'api_sig'}.contains(key),
          )
          .toList()
        ..sort();
  final input = '${keys.map((key) => '$key${parameters[key]}').join()}$secret';
  return md5.convert(utf8.encode(input)).toString();
}

class LastfmApi {
  LastfmApi({
    this.server = LastfmServer.lastfm,
    LastfmCredentials? credentials,
    http.Client? client,
  }) : credentials = credentials ?? server.credentials,
       _endpoint = Uri.https(server.apiHost, server.apiPath),
       _client = client ?? http.Client();

  final LastfmServer server;
  final LastfmCredentials credentials;
  final http.Client _client;
  final Uri _endpoint;

  Future<Map<String, dynamic>> _request(
    String method,
    Map<String, String> parameters,
  ) async {
    if (!credentials.configured) throw const LastfmException(10);
    final body = {
      ...parameters,
      'method': method,
      'api_key': credentials.apiKey,
    };
    body['api_sig'] = lastfmSignature(body, credentials.apiSecret);
    body['format'] = 'json';
    final response = await _client
        .post(_endpoint, body: body)
        .timeout(const Duration(seconds: 15));
    if (response.statusCode == 429) throw const LastfmException(29);
    if (response.statusCode >= 500) throw const LastfmException(16);
    // HTTP 200 can still contain an API error. Never include the response
    // body or request parameters in exceptions, as they can contain tokens.
    final decoded = jsonDecode(response.body);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Invalid Last.fm response');
    }
    final code = decoded['error'];
    if (code is num) throw LastfmException(code.toInt());
    if (response.statusCode != 200) {
      throw const FormatException('Unexpected Last.fm HTTP response');
    }
    return decoded;
  }

  Future<String> requestToken() async {
    final response = await _request('auth.getToken', const {});
    final token = response['token'] as String? ?? '';
    if (token.isEmpty) throw const FormatException('Missing Last.fm token');
    return token;
  }

  Uri authorizationUrl(String token) => Uri.https(
    server.authHost,
    server.authPath,
    {'api_key': credentials.apiKey, 'token': token},
  );

  Future<LastfmSession> session(String token) async {
    final response = await _request('auth.getSession', {'token': token});
    return LastfmSession.fromJson(response['session'] as Map<String, dynamic>);
  }

  Future<void> nowPlaying(
    LastfmSession session,
    Map<String, String> track,
  ) async => _request('track.updateNowPlaying', {...track, 'sk': session.key});

  /// Successful responses include ignored scrobbles, which must also leave
  /// the queue. A server failure throws and retains the entire batch.
  Future<void> scrobble(
    LastfmSession session,
    List<Map<String, String>> tracks,
  ) async {
    if (tracks.isEmpty || tracks.length > 50) {
      throw ArgumentError.value(tracks.length, 'tracks', 'Expected 1 to 50');
    }
    final parameters = <String, String>{'sk': session.key};
    for (var i = 0; i < tracks.length; i++) {
      for (final entry in tracks[i].entries) {
        parameters['${entry.key}[$i]'] = entry.value;
      }
    }
    final response = await _request('track.scrobble', parameters);
    final result = response['scrobbles'];
    if (result is! Map<String, dynamic> || result['@attr'] is! Map) {
      throw const FormatException('Missing Last.fm scrobble result');
    }
    final attributes = result['@attr'] as Map<String, dynamic>;
    final accepted = int.tryParse('${attributes['accepted']}');
    final ignored = int.tryParse('${attributes['ignored']}');
    if (accepted == null ||
        ignored == null ||
        accepted + ignored != tracks.length) {
      throw const FormatException('Incomplete Last.fm scrobble result');
    }
  }

  void close() => _client.close();
}
