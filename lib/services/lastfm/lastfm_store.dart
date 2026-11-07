import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:mornye/services/lastfm/lastfm_api.dart';
import 'package:mornye/services/lastfm/lastfm_listening.dart';
import 'package:mornye/services/secure_storage_options.dart';
import 'package:shared_preferences/shared_preferences.dart';

class LastfmScrobble {
  const LastfmScrobble({
    required this.id,
    required this.username,
    required this.track,
    required this.started,
  });

  factory LastfmScrobble.fromJson(Map<String, dynamic> json) => LastfmScrobble(
    id: json['id'] as String,
    username: json['username'] as String,
    track: LastfmTrack.fromJson(json['track'] as Map<String, dynamic>),
    started: DateTime.fromMillisecondsSinceEpoch(
      (json['timestamp'] as int) * 1000,
      isUtc: true,
    ),
  );

  final String id;
  final String username;
  final LastfmTrack track;
  final DateTime started;

  Map<String, String> get parameters => {
    ...track.toJson(),
    'timestamp': '${started.millisecondsSinceEpoch ~/ 1000}',
  };

  Map<String, Object> toJson() => {
    'id': id,
    'username': username,
    'track': track.toJson(),
    'timestamp': started.millisecondsSinceEpoch ~/ 1000,
  };
}

/// A token waiting for approval in the browser. It is kept so a phone that
/// ends the app while the browser is open can still finish connecting.
typedef LastfmAuthorization = ({String token, DateTime created});

abstract class LastfmStore {
  Future<LastfmSession?> readSession();
  Future<void> writeSession(LastfmSession? session);
  Future<LastfmAuthorization?> readAuthorization();
  Future<void> writeAuthorization(LastfmAuthorization? authorization);
  Future<({bool enabled, bool nowPlaying, List<LastfmScrobble> queue})> read();
  Future<void> write({
    required bool enabled,
    required bool nowPlaying,
    required List<LastfmScrobble> queue,
  });
}

class LocalLastfmStore implements LastfmStore {
  LocalLastfmStore({
    Future<SharedPreferences> Function()? preferences,
    FlutterSecureStorage? storage,
  }) : _preferences = preferences ?? SharedPreferences.getInstance,
       _storage =
           storage ??
           const FlutterSecureStorage(
             aOptions: secureStorageAndroidOptions,
             mOptions: secureStorageMacOsOptions,
             // Playback can start the app in the background while the
             // phone is locked; the session must still be readable then.
             iOptions: IOSOptions(
               accessibility: KeychainAccessibility.first_unlock_this_device,
             ),
           );

  static const _sessionKey = 'lastfm_session_v1';
  static const _authorizationKey = 'lastfm_authorization_v1';
  static const _stateKey = 'lastfm_scrobbles_v1';
  final Future<SharedPreferences> Function() _preferences;
  final FlutterSecureStorage _storage;

  @override
  Future<LastfmSession?> readSession() async {
    final json = await _storage.read(key: _sessionKey);
    if (json == null) return null;
    return LastfmSession.fromJson(jsonDecode(json) as Map<String, dynamic>);
  }

  @override
  Future<void> writeSession(LastfmSession? session) async {
    if (session == null) {
      await _storage.delete(key: _sessionKey);
    } else {
      await _storage.write(
        key: _sessionKey,
        value: jsonEncode(session.toJson()),
      );
    }
  }

  @override
  Future<LastfmAuthorization?> readAuthorization() async {
    final raw = await _storage.read(key: _authorizationKey);
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
      await _storage.delete(key: _authorizationKey);
    } else {
      await _storage.write(
        key: _authorizationKey,
        value: jsonEncode({
          'token': authorization.token,
          'created': authorization.created.millisecondsSinceEpoch,
        }),
      );
    }
  }

  @override
  Future<({bool enabled, bool nowPlaying, List<LastfmScrobble> queue})>
  read() async {
    final preferences = await _preferences();
    final raw = preferences.getString(_stateKey);
    if (raw == null) {
      return (enabled: false, nowPlaying: true, queue: <LastfmScrobble>[]);
    }
    final json = jsonDecode(raw) as Map<String, dynamic>;
    return (
      enabled: json['enabled'] == true,
      nowPlaying: json['nowPlaying'] != false,
      queue: [
        for (final entry in json['queue'] as List<dynamic>? ?? [])
          LastfmScrobble.fromJson(entry as Map<String, dynamic>),
      ],
    );
  }

  @override
  Future<void> write({
    required bool enabled,
    required bool nowPlaying,
    required List<LastfmScrobble> queue,
  }) async {
    final preferences = await _preferences();
    final saved = await preferences.setString(
      _stateKey,
      jsonEncode({
        'enabled': enabled,
        'nowPlaying': nowPlaying,
        'queue': queue.map((entry) => entry.toJson()).toList(),
      }),
    );
    if (!saved) throw StateError('Could not save Last.fm listening queue');
  }
}
