import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:mornye/services/scrobbling/scrobble_listening.dart';
import 'package:mornye/services/secure_storage_options.dart';
import 'package:mornye/utils/logger.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

final _log = AppLogger('ScrobbleStore');

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

/// Keeps the account in OS secure storage, the switches in preferences and
/// the queue in a file of its own, under keys owned by one service.
///
/// Older versions kept the queue in the preference too. A queue found there
/// joins the file and leaves the preference only once the file is written,
/// and a version that only knows the preference still reads the switches.
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
  File? _file;

  /// What the file and the preference hold as far as this store knows, so
  /// a write skips the part that did not change.
  List<String>? _savedIds;
  ({bool enabled, bool nowPlaying})? _savedSwitches;

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

  Future<File> _queueFile() async => _file ??= File(
    '${(await getApplicationSupportDirectory()).path}'
    '/scrobble_queues/$stateKey.json',
  );

  @override
  Future<ScrobbleState> read() async {
    final preferences = await _preferences();
    final raw = preferences.getString(stateKey);
    final json = raw == null
        ? const <String, dynamic>{}
        : jsonDecode(raw) as Map<String, dynamic>;
    final saved = await _readQueue();
    final legacy = json['queue'] as List<dynamic>?;
    final ids = {for (final entry in saved) entry.id};
    final queue = List.of(saved);
    for (final entry in legacy ?? const <dynamic>[]) {
      final listen = QueuedScrobble.fromJson(entry as Map<String, dynamic>);
      if (ids.add(listen.id)) queue.add(listen);
    }
    final enabled = json['enabled'] == true;
    final nowPlaying = json['nowPlaying'] != false;
    _savedIds = [for (final entry in saved) entry.id];
    _savedSwitches = raw == null || legacy != null
        ? null
        : (enabled: enabled, nowPlaying: nowPlaying);
    if (legacy != null) {
      try {
        await write(enabled: enabled, nowPlaying: nowPlaying, queue: queue);
      } catch (error) {
        // The preference still holds the queue; the next write moves it.
        _log.w('Could not move the $stateKey queue to its file: $error');
      }
    }
    return (enabled: enabled, nowPlaying: nowPlaying, queue: queue);
  }

  @override
  Future<void> write({
    required bool enabled,
    required bool nowPlaying,
    required List<QueuedScrobble> queue,
  }) async {
    final ids = [for (final entry in queue) entry.id];
    if (!listEquals(ids, _savedIds)) {
      await _writeQueue(queue);
      _savedIds = ids;
    }
    final switches = (enabled: enabled, nowPlaying: nowPlaying);
    if (switches == _savedSwitches) return;
    final preferences = await _preferences();
    final saved = await preferences.setString(
      stateKey,
      jsonEncode({'enabled': enabled, 'nowPlaying': nowPlaying}),
    );
    if (!saved) throw StateError('Could not save the listening queue');
    _savedSwitches = switches;
  }

  Future<List<QueuedScrobble>> _readQueue() async {
    final String raw;
    try {
      raw = await (await _queueFile()).readAsString();
    } on PathNotFoundException {
      return [];
    }
    final json = jsonDecode(raw) as Map<String, dynamic>;
    return [
      for (final entry in json['queue'] as List<dynamic>)
        QueuedScrobble.fromJson(entry as Map<String, dynamic>),
    ];
  }

  /// Replaces the file in one step, so an app ended mid-write keeps the
  /// previous queue whole.
  Future<void> _writeQueue(List<QueuedScrobble> queue) async {
    final file = await _queueFile();
    await file.parent.create(recursive: true);
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsString(
      jsonEncode({'queue': queue.map((entry) => entry.toJson()).toList()}),
      flush: true,
    );
    await temporary.rename(file.path);
  }
}
