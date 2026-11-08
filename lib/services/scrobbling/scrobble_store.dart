import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:mornye/services/scrobbling/scrobble_listening.dart';
import 'package:mornye/services/secure_storage_options.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A listen waiting to reach one service. Each service keeps its own queue,
/// scoped to the account that played it.
class QueuedScrobble {
  const QueuedScrobble({
    required this.id,
    required this.username,
    required this.track,
    required this.started,
  });

  factory QueuedScrobble.fromJson(Map<String, dynamic> json) => QueuedScrobble(
    id: json['id'] as String,
    username: json['username'] as String,
    track: ScrobbleTrack.fromJson(json['track'] as Map<String, dynamic>),
    started: DateTime.fromMillisecondsSinceEpoch(
      (json['timestamp'] as int) * 1000,
      isUtc: true,
    ),
  );

  final String id;
  final String username;
  final ScrobbleTrack track;
  final DateTime started;

  /// The Last.fm-compatible `track.scrobble` fields of this listen.
  Map<String, String> get parameters => {
    ...track.lastfmParameters,
    'timestamp': '${started.millisecondsSinceEpoch ~/ 1000}',
  };

  Map<String, Object> toJson() => {
    'id': id,
    'username': username,
    'track': track.toJson(),
    'timestamp': started.millisecondsSinceEpoch ~/ 1000,
  };
}

/// The signed-in account of a service. Its secret never leaves secure
/// storage and the service's own requests.
abstract interface class ScrobbleAccount {
  String get username;
}

typedef ScrobbleState = ({
  bool enabled,
  bool nowPlaying,
  List<QueuedScrobble> queue,
});

abstract class ScrobbleStore<S extends ScrobbleAccount> {
  Future<S?> readSession();
  Future<void> writeSession(S? session);
  Future<ScrobbleState> read();
  Future<void> write({
    required bool enabled,
    required bool nowPlaying,
    required List<QueuedScrobble> queue,
  });
}

const scrobbleSecureStorage = FlutterSecureStorage(
  aOptions: secureStorageAndroidOptions,
  mOptions: secureStorageMacOsOptions,
  // Playback can start the app in the background while the phone is
  // locked; the session must still be readable then.
  iOptions: IOSOptions(
    accessibility: KeychainAccessibility.first_unlock_this_device,
  ),
);

/// Keeps the account in OS secure storage and the switches and queue in
/// preferences, under keys owned by one service.
class LocalScrobbleStore<S extends ScrobbleAccount>
    implements ScrobbleStore<S> {
  LocalScrobbleStore({
    required this.sessionKey,
    required this.stateKey,
    required S Function(Map<String, dynamic> json) decode,
    required Map<String, String> Function(S session) encode,
    Future<SharedPreferences> Function()? preferences,
    FlutterSecureStorage? storage,
  }) : _decode = decode,
       _encode = encode,
       _preferences = preferences ?? SharedPreferences.getInstance,
       storage = storage ?? scrobbleSecureStorage;

  final String sessionKey;
  final String stateKey;
  final S Function(Map<String, dynamic> json) _decode;
  final Map<String, String> Function(S session) _encode;
  final Future<SharedPreferences> Function() _preferences;
  @protected
  final FlutterSecureStorage storage;

  @override
  Future<S?> readSession() async {
    final json = await storage.read(key: sessionKey);
    if (json == null) return null;
    return _decode(jsonDecode(json) as Map<String, dynamic>);
  }

  @override
  Future<void> writeSession(S? session) async {
    if (session == null) {
      await storage.delete(key: sessionKey);
    } else {
      await storage.write(key: sessionKey, value: jsonEncode(_encode(session)));
    }
  }

  @override
  Future<ScrobbleState> read() async {
    final preferences = await _preferences();
    final raw = preferences.getString(stateKey);
    if (raw == null) {
      return (enabled: false, nowPlaying: true, queue: <QueuedScrobble>[]);
    }
    final json = jsonDecode(raw) as Map<String, dynamic>;
    return (
      enabled: json['enabled'] == true,
      nowPlaying: json['nowPlaying'] != false,
      queue: [
        for (final entry in json['queue'] as List<dynamic>? ?? [])
          QueuedScrobble.fromJson(entry as Map<String, dynamic>),
      ],
    );
  }

  @override
  Future<void> write({
    required bool enabled,
    required bool nowPlaying,
    required List<QueuedScrobble> queue,
  }) async {
    final preferences = await _preferences();
    final saved = await preferences.setString(
      stateKey,
      jsonEncode({
        'enabled': enabled,
        'nowPlaying': nowPlaying,
        'queue': queue.map((entry) => entry.toJson()).toList(),
      }),
    );
    if (!saved) throw StateError('Could not save the listening queue');
  }
}
