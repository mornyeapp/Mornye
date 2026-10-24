import 'dart:convert';

import 'package:crypto/crypto.dart';

/// Mornye Link: the phone app talking to the desktop app over the local
/// network. Wire constants and models shared by the desktop host and the
/// phone client. The desktop serves HTTPS (OpenSubsonic under `/rest`,
/// Mornye endpoints under [linkApiPath], a WebSocket at [linkSocketPath]).
const linkProtocolVersion = 1;

/// The mDNS service type the desktop advertises.
const linkServiceType = '_mornye._tcp';

/// First port tried by the desktop server; it walks up to [linkPortLast].
const linkPortFirst = 47710;
const linkPortLast = 47729;

const linkApiPath = '/mornye/v1';
const linkSocketPath = '$linkApiPath/ws';

/// `PUT <linkFilesPath>/<id>.<extension>` uploads a song file the phone has
/// and the desktop lacks; [TrackRef.fileId] then names it.
const linkFilesPath = '$linkApiPath/files';

/// The audio extensions the desktop accepts in an upload name.
const linkUploadExtensions = {
  'flac',
  'mp3',
  'm4a',
  'mp4',
  'aac',
  'ogg',
  'oga',
  'opus',
  'wav',
  'aif',
  'aiff',
  'aifc',
  'wv',
  'ape',
  'dsf',
  'dff',
  'mka',
  'wma',
  'webm',
};

final _fileId = RegExp(r'^[0-9a-f]{32}$');

/// Whether [value] is a [TrackRef.fileId]: 32 lowercase hex characters.
bool isLinkFileId(String? value) => value != null && _fileId.hasMatch(value);

/// The [TrackRef.fileId] of the phone's file at [source] (a path or content
/// URI) with [size] bytes: the same file keeps its id, so the desktop does
/// not receive it twice.
String linkFileIdFor(String source, int size) =>
    sha256.convert(utf8.encode('$source\n$size')).toString().substring(0, 32);

/// Forwarded `/mornye/v1` operations (the path after [linkApiPath]).
abstract final class LinkOps {
  static const state = 'state';
  static const command = 'command';
  static const handoffPlay = 'handoff/play';
  static const handoffAppend = 'handoff/append';
  static const handoffCurrent = 'handoff/current';
  static const queueAdd = 'queue/add';
  static const downloads = 'downloads';
  static const open = 'open';
  static const resolve = 'resolve';
  static const collections = 'collections';
  static const history = 'history';

  /// Subsonic calls the server forwards to the app (prefix + method name).
  static const subsonicPrefix = 'subsonic/';
  static const getPlayQueue = 'subsonic/getPlayQueue';
  static const savePlayQueue = 'subsonic/savePlayQueue';
}

/// WebSocket message `type` values.
abstract final class LinkMessageTypes {
  static const hello = 'hello';
  static const welcome = 'welcome';
  static const playerState = 'player.state';
  static const command = 'command';
  static const open = 'open';
  static const downloadsChanged = 'downloads.changed';
  static const collectionsChanged = 'collections.changed';
  static const catalogChanged = 'catalog.changed';
}

/// Player command `action` values (`POST command` and the `command`
/// message).
abstract final class LinkActions {
  static const play = 'play';
  static const pause = 'pause';
  static const toggle = 'toggle';
  static const next = 'next';
  static const previous = 'previous';
  static const seek = 'seek';
  static const volume = 'volume';
  static const shuffle = 'shuffle';
  static const repeat = 'repeat';
  static const jump = 'jump';

  /// `{"from","to"}`: moves a queue entry; indexes as for [jump].
  static const move = 'move';

  /// `{"index"}`: removes a queue entry other than the current one.
  static const remove = 'remove';
  static const playQueue = 'play_queue';
}

/// The pairing proof: HMAC-SHA256 keyed by the PIN over the certificate
/// fingerprint the phone observed and its device id. A relay presenting
/// another certificate cannot produce it.
String linkPairingProof({
  required String pin,
  required String fingerprint,
  required String deviceId,
}) {
  final message = 'mornye-link-pair-v1:${fingerprint.toLowerCase()}:$deviceId';
  return Hmac(
    sha256,
    utf8.encode(pin),
  ).convert(utf8.encode(message)).toString();
}

String? _string(Object? value) {
  if (value is! String) return null;
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}

int? _int(Object? value) => value is num ? value.toInt() : null;

/// A track as another device can resolve it: by desktop catalog id when the
/// server matches, else ISRC, match key, then title and artist with the
/// duration within two seconds.
class TrackRef {
  const TrackRef({
    required this.title,
    required this.artist,
    this.album,
    this.durationMs,
    this.isrc,
    this.matchKey,
    this.songId,
    this.serverId,
    this.fileId,
  });

  final String title;
  final String artist;
  final String? album;
  final int? durationMs;
  final String? isrc;
  final String? matchKey;

  /// A desktop catalog id, valid for [serverId].
  final String? songId;
  final String? serverId;

  /// The phone's file for this track, once uploaded to the desktop
  /// ([linkFileIdFor]). The desktop plays it when its Library lacks the
  /// track.
  final String? fileId;

  Map<String, dynamic> toJson() => {
    'title': title,
    'artist': artist,
    if (album != null) 'album': album,
    if (durationMs != null) 'durationMs': durationMs,
    if (isrc != null) 'isrc': isrc,
    if (matchKey != null) 'matchKey': matchKey,
    if (songId != null) 'songId': songId,
    if (serverId != null) 'serverId': serverId,
    if (fileId != null) 'fileId': fileId,
  };

  /// This ref naming the uploaded file [fileId].
  TrackRef withFileId(String fileId) => TrackRef(
    title: title,
    artist: artist,
    album: album,
    durationMs: durationMs,
    isrc: isrc,
    matchKey: matchKey,
    songId: songId,
    serverId: serverId,
    fileId: fileId,
  );

  static TrackRef? fromJson(Object? json) {
    if (json is! Map) return null;
    final title = _string(json['title']);
    if (title == null) return null;
    return TrackRef(
      title: title,
      artist: _string(json['artist']) ?? '',
      album: _string(json['album']),
      durationMs: _int(json['durationMs']),
      isrc: _string(json['isrc']),
      matchKey: _string(json['matchKey']),
      songId: _string(json['songId']),
      serverId: _string(json['serverId']),
      fileId: switch (_string(json['fileId'])) {
        final fileId? when isLinkFileId(fileId) => fileId,
        _ => null,
      },
    );
  }

  @override
  bool operator ==(Object other) =>
      other is TrackRef &&
      other.title == title &&
      other.artist == artist &&
      other.album == album &&
      other.durationMs == durationMs &&
      other.isrc == isrc &&
      other.matchKey == matchKey &&
      other.songId == songId &&
      other.serverId == serverId &&
      other.fileId == fileId;

  @override
  int get hashCode => Object.hash(
    title,
    artist,
    album,
    durationMs,
    isrc,
    matchKey,
    songId,
    serverId,
    fileId,
  );
}

enum LinkRepeatMode { none, one, all }

/// One device's player, as sent in `player.state` and `GET state`.
class LinkPlayerState {
  const LinkPlayerState({
    this.track,
    this.playing = false,
    this.positionMs = 0,
    this.durationMs,
    required this.updatedMs,
    this.queue = const [],
    this.index = -1,
    this.shuffle = false,
    this.repeat = LinkRepeatMode.none,
    this.volume = 1,
  });

  /// At most this many queue entries around the current one are sent.
  static const maxQueue = 200;

  final TrackRef? track;
  final bool playing;
  final int positionMs;
  final int? durationMs;

  /// When [positionMs] was read, in Unix milliseconds.
  final int updatedMs;
  final List<TrackRef> queue;

  /// Index of the current item in [queue], or -1.
  final int index;
  final bool shuffle;
  final LinkRepeatMode repeat;

  /// 0 to 1.
  final double volume;

  /// The position at [nowMs], advanced while playing.
  int positionAt(int nowMs) {
    if (!playing) return positionMs;
    final advanced = positionMs + (nowMs - updatedMs).clamp(0, 1 << 31);
    final duration = durationMs;
    return duration == null ? advanced : advanced.clamp(0, duration);
  }

  Map<String, dynamic> toJson() => {
    if (track != null) 'track': track!.toJson(),
    'playing': playing,
    'positionMs': positionMs,
    if (durationMs != null) 'durationMs': durationMs,
    'updatedMs': updatedMs,
    'queue': [for (final item in queue) item.toJson()],
    'index': index,
    'shuffle': shuffle,
    'repeat': repeat.name,
    'volume': volume,
  };

  static LinkPlayerState? fromJson(Object? json) {
    if (json is! Map) return null;
    final queue = json['queue'];
    return LinkPlayerState(
      track: TrackRef.fromJson(json['track']),
      playing: json['playing'] == true,
      positionMs: _int(json['positionMs']) ?? 0,
      durationMs: _int(json['durationMs']),
      updatedMs: _int(json['updatedMs']) ?? 0,
      queue: queue is List
          ? [for (final item in queue) ?TrackRef.fromJson(item)]
          : const [],
      index: _int(json['index']) ?? -1,
      shuffle: json['shuffle'] == true,
      repeat:
          LinkRepeatMode.values.asNameMap()[json['repeat']] ??
          LinkRepeatMode.none,
      volume: ((json['volume'] as num?)?.toDouble() ?? 1).clamp(0, 1),
    );
  }
}

/// A player command (`POST command`, or the `command` message to a phone).
class LinkCommand {
  const LinkCommand(this.action, [this.args = const {}]);

  final String action;
  final Map<String, dynamic> args;

  Map<String, dynamic> toJson() => {'action': action, 'args': args};

  static LinkCommand? fromJson(Object? json) {
    if (json is! Map) return null;
    final action = _string(json['action']);
    if (action == null) return null;
    final args = json['args'];
    return LinkCommand(
      action,
      args is Map ? Map<String, dynamic>.from(args) : const {},
    );
  }
}

/// `GET /mornye/v1/info`.
class LinkServerInfo {
  const LinkServerInfo({
    required this.serverId,
    required this.name,
    required this.protocol,
    required this.appVersion,
    required this.fingerprint,
    required this.pairing,
  });

  final String serverId;
  final String name;
  final int protocol;
  final String appVersion;
  final String fingerprint;

  /// Whether a pairing window is open.
  final bool pairing;

  Map<String, dynamic> toJson() => {
    'serverId': serverId,
    'name': name,
    'protocol': protocol,
    'appVersion': appVersion,
    'fingerprint': fingerprint,
    'pairing': pairing,
  };

  static LinkServerInfo? fromJson(Object? json) {
    if (json is! Map) return null;
    final serverId = _string(json['serverId']);
    final fingerprint = _string(json['fingerprint']);
    if (serverId == null || fingerprint == null) return null;
    return LinkServerInfo(
      serverId: serverId,
      name: _string(json['name']) ?? '',
      protocol: _int(json['protocol']) ?? 0,
      appVersion: _string(json['appVersion']) ?? '',
      fingerprint: fingerprint.toLowerCase(),
      pairing: json['pairing'] == true,
    );
  }
}

/// A WebSocket client as the desktop sees it (`linkClients`, `linkStatus`).
class LinkClientInfo {
  const LinkClientInfo({
    required this.deviceId,
    required this.name,
    required this.platform,
    this.appVersion = '',
    this.connectedMs = 0,
  });

  final String deviceId;
  final String name;
  final String platform;
  final String appVersion;
  final int connectedMs;

  Map<String, dynamic> toJson() => {
    'deviceId': deviceId,
    'name': name,
    'platform': platform,
    'appVersion': appVersion,
    'connectedMs': connectedMs,
  };

  static LinkClientInfo? fromJson(Object? json) {
    if (json is! Map) return null;
    final deviceId = _string(json['deviceId']);
    if (deviceId == null) return null;
    return LinkClientInfo(
      deviceId: deviceId,
      name: _string(json['name']) ?? '',
      platform: _string(json['platform']) ?? '',
      appVersion: _string(json['appVersion']) ?? '',
      connectedMs: _int(json['connectedMs']) ?? 0,
    );
  }
}

/// A forwarded request failed. [code] follows the contract: `invalid`,
/// `not_found`, `unavailable`, `timeout` or another code.
class LinkException implements Exception {
  const LinkException(this.code, [this.message = '']);

  final String code;
  final String message;

  Map<String, dynamic> toJson() => {'code': code, 'message': message};

  @override
  String toString() =>
      'LinkException($code${message.isEmpty ? '' : ': $message'})';
}
