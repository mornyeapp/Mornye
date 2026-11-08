import 'dart:convert';

import 'package:mornye/services/lastfm/lastfm_api.dart';
import 'package:mornye/services/scrobbling/scrobble_store.dart';

/// A token waiting for approval in the browser. It is kept so a phone that
/// ends the app while the browser is open can still finish connecting.
typedef LastfmAuthorization = ({String token, DateTime created});

abstract class LastfmStore implements ScrobbleStore<LastfmSession> {
  Future<LastfmAuthorization?> readAuthorization();
  Future<void> writeAuthorization(LastfmAuthorization? authorization);
}

/// [prefix] names the service. Last.fm keeps the keys it always used, so a
/// saved session and queue carry over unchanged.
class LocalLastfmStore extends LocalScrobbleStore<LastfmSession>
    implements LastfmStore {
  LocalLastfmStore({String prefix = 'lastfm', super.preferences, super.storage})
    : _authorizationKey = '${prefix}_authorization_v1',
      super(
        sessionKey: '${prefix}_session_v1',
        stateKey: '${prefix}_scrobbles_v1',
        decode: LastfmSession.fromJson,
        encode: (session) => session.toJson(),
      );

  final String _authorizationKey;

  @override
  Future<LastfmAuthorization?> readAuthorization() async {
    final raw = await storage.read(key: _authorizationKey);
    if (raw == null) return null;
    final json = jsonDecode(raw);
    if (json is! Map) return null;
    final token = json['token'], created = json['created'];
    if (token is! String || token.isEmpty || created is! int) return null;
    return (
      token: token,
      created: DateTime.fromMillisecondsSinceEpoch(created, isUtc: true),
    );
  }

  @override
  Future<void> writeAuthorization(LastfmAuthorization? authorization) async {
    if (authorization == null) {
      await storage.delete(key: _authorizationKey);
    } else {
      await storage.write(
        key: _authorizationKey,
        value: jsonEncode({
          'token': authorization.token,
          'created': authorization.created.millisecondsSinceEpoch,
        }),
      );
    }
  }
}
