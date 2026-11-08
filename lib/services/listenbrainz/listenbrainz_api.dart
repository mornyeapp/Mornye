import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:mornye/constants/app_info.dart';
import 'package:mornye/services/scrobbling/scrobble_listening.dart';
import 'package:mornye/services/scrobbling/scrobble_store.dart';

const listenBrainzDefaultServer = 'https://api.listenbrainz.org';

class ListenBrainzAccount implements ScrobbleAccount {
  const ListenBrainzAccount({
    required this.username,
    required this.token,
    this.server = listenBrainzDefaultServer,
  });

  factory ListenBrainzAccount.fromJson(Map<String, dynamic> json) {
    final username = json['name'] as String? ?? '';
    final token = json['token'] as String? ?? '';
    final server = normalizeListenBrainzServer(json['server'] as String? ?? '');
    if (username.isEmpty || token.isEmpty || server == null) {
      throw const FormatException('Invalid ListenBrainz account');
    }
    return ListenBrainzAccount(
      username: username,
      token: token,
      server: server,
    );
  }

  @override
  final String username;
  final String token;

  /// The API root, without the `/1/` version segment.
  final String server;

  bool get customServer => server != listenBrainzDefaultServer;

  Map<String, String> toJson() => {
    'name': username,
    'token': token,
    'server': server,
  };
}

class ListenBrainzException implements Exception {
  const ListenBrainzException(this.statusCode);

  final int statusCode;

  @override
  String toString() => 'ListenBrainz request failed (HTTP $statusCode)';
}

/// The API root for [value], or null when it is not an http or https
/// address. Empty means the official server. A pasted `/1` version
/// segment or trailing slash is dropped.
String? normalizeListenBrainzServer(String value) {
  final text = value.trim();
  if (text.isEmpty) return listenBrainzDefaultServer;
  final uri = Uri.tryParse(text);
  if (uri == null ||
      !(uri.isScheme('https') || uri.isScheme('http')) ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasQuery ||
      uri.hasFragment) {
    return null;
  }
  var path = uri.path;
  while (path.endsWith('/')) {
    path = path.substring(0, path.length - 1);
  }
  if (path.endsWith('/1')) path = path.substring(0, path.length - 2);
  return uri.replace(path: path).toString();
}

/// Whether the user token may be sent to [server]: any https:// address,
/// and plain http:// only to this device or the local network, so the
/// token never crosses the internet unencrypted.
bool listenBrainzServerSecure(String server) {
  final uri = Uri.tryParse(server);
  if (uri == null) return false;
  if (uri.isScheme('https')) return true;
  return uri.isScheme('http') && isListenBrainzLocalHost(uri.host);
}

/// Loopback, private IPv4 (10/8, 172.16/12, 192.168/16), link-local, IPv6
/// unique local addresses, `localhost` and `.local` names. Nothing is
/// resolved: a public name stays public even if it points at a LAN.
bool isListenBrainzLocalHost(String host) {
  final name = host.toLowerCase().replaceFirst(RegExp(r'\.$'), '');
  if (name == 'localhost' || name.endsWith('.local')) return true;
  final address = InternetAddress.tryParse(name.split('%').first);
  if (address == null) return false;
  if (address.isLoopback || address.isLinkLocal) return true;
  var bytes = address.rawAddress;
  if (bytes.length == 16) {
    final mapped =
        bytes.take(10).every((byte) => byte == 0) &&
        bytes[10] == 255 &&
        bytes[11] == 255;
    if (!mapped) return bytes[0] & 0xfe == 0xfc;
    bytes = bytes.sublist(12);
  }
  return bytes[0] == 127 ||
      bytes[0] == 10 ||
      (bytes[0] == 172 && bytes[1] >= 16 && bytes[1] <= 31) ||
      (bytes[0] == 192 && bytes[1] == 168) ||
      (bytes[0] == 169 && bytes[1] == 254);
}

/// The server would receive the token over plain http:// outside the
/// local network, so nothing was sent.
class ListenBrainzInsecureServerException implements Exception {
  const ListenBrainzInsecureServerException();

  @override
  String toString() => 'ListenBrainz server must use HTTPS';
}

/// ListenBrainz `track_metadata` for [track]. Unknown fields are left out.
Map<String, Object> listenBrainzMetadata(ScrobbleTrack track) {
  final duration = track.duration;
  return {
    'artist_name': track.artist,
    'track_name': track.title,
    if (track.album.isNotEmpty) 'release_name': track.album,
    'additional_info': {
      if (duration != null && duration > Duration.zero)
        'duration_ms': duration.inMilliseconds,
      'isrc': ?track.isrc,
      'tracknumber': ?track.trackNumber,
      'media_player': 'Mornye',
      'submission_client': 'Mornye',
      'submission_client_version': AppInfo.version,
    },
  };
}

/// The ListenBrainz API or a compatible server. The user token travels only
/// in the Authorization header; it never appears in URLs or exceptions.
class ListenBrainzApi {
  ListenBrainzApi({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;
  static const _timeout = Duration(seconds: 15);

  /// Checked on every request, so an address saved by an older version
  /// cannot send the token in the clear either.
  Uri _endpoint(String server, String path) {
    if (!listenBrainzServerSecure(server)) {
      throw const ListenBrainzInsecureServerException();
    }
    return Uri.parse('$server/1/$path');
  }

  /// The account name the token belongs to, or null when the server does
  /// not accept the token.
  Future<String?> validateToken(
    String token, {
    String server = listenBrainzDefaultServer,
  }) async {
    final response = await _client
        .get(
          _endpoint(server, 'validate-token'),
          headers: {'Authorization': 'Token $token'},
        )
        .timeout(_timeout);
    if (response.statusCode == 401 || response.statusCode == 403) return null;
    if (response.statusCode != 200) {
      throw ListenBrainzException(response.statusCode);
    }
    final decoded = jsonDecode(response.body);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Invalid ListenBrainz response');
    }
    if (decoded['valid'] != true) return null;
    final username = decoded['user_name'];
    if (username is! String || username.isEmpty) {
      throw const FormatException('Missing ListenBrainz user name');
    }
    return username;
  }

  Future<void> nowPlaying(ListenBrainzAccount account, ScrobbleTrack track) =>
      _submit(account, 'playing_now', [
        {'track_metadata': listenBrainzMetadata(track)},
      ]);

  /// One listen goes as `single`, a saved backlog as `import`.
  Future<void> submit(
    ListenBrainzAccount account,
    List<QueuedScrobble> listens,
  ) {
    if (listens.isEmpty || listens.length > 100) {
      throw ArgumentError.value(listens.length, 'listens', 'Expected 1 to 100');
    }
    return _submit(account, listens.length == 1 ? 'single' : 'import', [
      for (final listen in listens)
        {
          'listened_at': listen.started.millisecondsSinceEpoch ~/ 1000,
          'track_metadata': listenBrainzMetadata(listen.track),
        },
    ]);
  }

  Future<void> _submit(
    ListenBrainzAccount account,
    String type,
    List<Map<String, Object>> payload,
  ) async {
    final response = await _client
        .post(
          _endpoint(account.server, 'submit-listens'),
          headers: {
            'Authorization': 'Token ${account.token}',
            'Content-Type': 'application/json',
          },
          body: jsonEncode({'listen_type': type, 'payload': payload}),
        )
        .timeout(_timeout);
    // The response body is never kept: it can echo the submission.
    if (response.statusCode != 200) {
      throw ListenBrainzException(response.statusCode);
    }
  }

  void close() => _client.close();
}
