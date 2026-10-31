import 'dart:convert';
import 'dart:math';

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

/// Songs per `POST phone/catalog` page.
const linkPhoneCatalogPage = 500;

/// The `network://` host of a paired phone's songs in the desktop's
/// Library: `link-phone-` and the first 16 hex characters of the SHA-256
/// of its device id.
String linkPhoneSourceId(String deviceId) =>
    'link-phone-${sha256.convert(utf8.encode(deviceId)).toString().substring(0, 16)}';

/// Whether [id] is a [linkPhoneSourceId].
bool isLinkPhoneSourceId(String id) =>
    RegExp(r'^link-phone-[0-9a-f]{16}$').hasMatch(id);

/// The id the desktop keeps a cover fetched from [url] under: the first 32
/// hex characters of its SHA-256.
String linkCoverUrlId(String url) =>
    sha256.convert(utf8.encode(url)).toString().substring(0, 32);

/// [value] when it is an `https` address of at most 2048 characters.
String? linkCoverUrl(Object? value) {
  if (value is! String || value.length > 2048) return null;
  final uri = Uri.tryParse(value.trim());
  if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) return null;
  return uri.toString();
}

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
  static const libraryJobs = 'library/jobs';
  static const collections = 'collections';
  static const history = 'history';

  /// A phone's songs for the desktop's Library: GET `{"version"}` held,
  /// POST one page of [LinkPhoneSong]s.
  static const phoneCatalog = 'phone/catalog';

  /// Covers of a phone's songs: GET `{"ids"}` held, POST `{"covers"}`.
  static const phoneCovers = 'phone/covers';

  /// Phone to desktop: copy phone songs into the desktop's Library, POST
  /// `{"transferId","songs":[LinkPhoneSong]}`, reply `{"accepted":int}`.
  static const transfersOffer = 'transfers/offer';

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
  static const lyricsTranslation = 'lyrics.translation';
  static const lyricsTranslationRequest = 'lyrics.translation.request';

  /// Desktop to phone: send the song `{"name"}` (`<fileId>.<suffix>` of a
  /// [LinkPhoneSong]) to `PUT <linkFilesPath>`.
  static const filesRequest = 'files.request';

  /// Phone to desktop: the requested `name` is on its way as `file`, of
  /// `size` bytes; `streamable` is false when it plays only once whole.
  static const filesSending = 'files.sending';

  /// Phone to desktop: the requested `name` cannot be sent (`reason`).
  static const filesFailed = 'files.failed';

  /// Desktop to phone: copy desktop songs to the phone,
  /// `{"transferId","songs":[LinkTransferSong]}`.
  static const transfersOffer = 'transfers.offer';

  /// Either way, from the device receiving a transfer to the one sending
  /// it: a [LinkTransferStatus].
  static const transfersStatus = 'transfers.status';

  /// Either way: stop the transfer `{"transferId"}`.
  static const transfersCancel = 'transfers.cancel';
}

/// The most songs one transfer offer carries; a larger choice is sent as
/// several transfers.
const linkTransferOfferLimit = 1000;

final _transferId = RegExp(r'^[0-9a-f]{32}$');

/// Whether [value] is a transfer id: 32 lowercase hex characters.
bool isLinkTransferId(String? value) =>
    value != null && _transferId.hasMatch(value);

/// A new random transfer id.
String newLinkTransferId([Random? random]) {
  final source = random ?? Random.secure();
  return [
    for (var i = 0; i < 16; i++)
      source.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ].join();
}

/// A desktop song offered to the phone (`transfers.offer`): its catalog id,
/// which the phone downloads over Subsonic, and the tags the phone names
/// and records the copy with.
class LinkTransferSong {
  const LinkTransferSong({
    required this.songId,
    required this.suffix,
    required this.title,
    required this.artist,
    this.size = 0,
    this.album,
    this.albumArtist,
    this.track,
    this.disc,
    this.year,
    this.genre,
    this.durationMs,
    this.isrc,
    this.bitRate,
    this.sampleRate,
    this.bitDepth,
    this.explicit = false,
  });

  /// The desktop catalog id (`l:<library id>` or `d:<history id>`).
  final String songId;

  /// The original file's lowercase extension.
  final String suffix;
  final String title;
  final String artist;

  /// Bytes; 0 when unknown.
  final int size;
  final String? album;
  final String? albumArtist;
  final int? track;
  final int? disc;
  final int? year;
  final String? genre;
  final int? durationMs;
  final String? isrc;

  /// Kilobits per second.
  final int? bitRate;
  final int? sampleRate;
  final int? bitDepth;
  final bool explicit;

  Map<String, dynamic> toJson() => {
    'songId': songId,
    'suffix': suffix,
    'title': title,
    'artist': artist,
    if (size > 0) 'size': size,
    if (album != null) 'album': album,
    if (albumArtist != null) 'albumArtist': albumArtist,
    if (track != null) 'track': track,
    if (disc != null) 'disc': disc,
    if (year != null) 'year': year,
    if (genre != null) 'genre': genre,
    if (durationMs != null) 'durationMs': durationMs,
    if (isrc != null) 'isrc': isrc,
    if (bitRate != null) 'bitRate': bitRate,
    if (sampleRate != null) 'sampleRate': sampleRate,
    if (bitDepth != null) 'bitDepth': bitDepth,
    if (explicit) 'explicit': true,
  };

  /// Null for a song without a [songId], [title] or a short alphanumeric
  /// [suffix].
  static LinkTransferSong? fromJson(Object? json) {
    if (json is! Map) return null;
    final songId = _string(json['songId']);
    final suffix = _string(json['suffix'])?.toLowerCase();
    final title = _string(json['title']);
    if (songId == null ||
        suffix == null ||
        !RegExp(r'^[a-z0-9]{1,10}$').hasMatch(suffix) ||
        title == null) {
      return null;
    }
    final size = _int(json['size']) ?? 0;
    return LinkTransferSong(
      songId: songId,
      suffix: suffix,
      title: title,
      artist: _string(json['artist']) ?? '',
      size: size > 0 ? size : 0,
      album: _string(json['album']),
      albumArtist: _string(json['albumArtist']),
      track: _int(json['track']),
      disc: _int(json['disc']),
      year: _int(json['year']),
      genre: _string(json['genre']),
      durationMs: _int(json['durationMs']),
      isrc: _string(json['isrc']),
      bitRate: _int(json['bitRate']),
      sampleRate: _int(json['sampleRate']),
      bitDepth: _int(json['bitDepth']),
      explicit: json['explicit'] == true,
    );
  }
}

/// Where a transfer stands.
enum LinkTransferState {
  /// Accepted, waiting for transfers before it.
  queued,
  running,

  /// Every song was saved, skipped or failed.
  done,
  cancelled,

  /// The transfer could not run at all (no connection, no download folder).
  failed;

  bool get active => this == queued || this == running;

  static LinkTransferState? fromName(Object? name) {
    for (final state in values) {
      if (state.name == name) return state;
    }
    return null;
  }
}

/// How a transfer stands on the device receiving it (`transfers.status`).
/// Songs before [index] are finished: saved unless listed in [skipped] (the
/// receiver already had it) or [failed]; [received] of [size] bytes of the
/// song at [index] have arrived.
class LinkTransferStatus {
  const LinkTransferStatus({
    required this.transferId,
    required this.state,
    required this.total,
    this.index = 0,
    this.received = 0,
    this.size,
    this.skipped = const [],
    this.failed = const [],
    this.reason,
  });

  final String transferId;
  final LinkTransferState state;
  final int total;
  final int index;
  final int received;
  final int? size;

  /// Indexes of songs the receiver already had, in order.
  final List<int> skipped;

  /// Indexes of songs that could not be copied, in order.
  final List<int> failed;

  /// Why the whole transfer failed, a short code.
  final String? reason;

  int get saved => index - skipped.length - failed.length;

  /// The whole transfer, 0 to 1; a stopped one keeps the songs it finished.
  double get fraction {
    if (total <= 0 || state == LinkTransferState.done) return 1;
    final size = this.size;
    final part = !state.active || size == null || size <= 0
        ? 0.0
        : (received / size).clamp(0.0, 1.0);
    return ((index + part) / total).clamp(0.0, 1.0);
  }

  LinkTransferStatus copyWith({
    LinkTransferState? state,
    int? index,
    int? received,
    int? size,
    List<int>? skipped,
    List<int>? failed,
    String? reason,
  }) => LinkTransferStatus(
    transferId: transferId,
    state: state ?? this.state,
    total: total,
    index: index ?? this.index,
    received: received ?? this.received,
    size: size ?? this.size,
    skipped: skipped ?? this.skipped,
    failed: failed ?? this.failed,
    reason: reason ?? this.reason,
  );

  Map<String, dynamic> toJson() => {
    'transferId': transferId,
    'state': state.name,
    'total': total,
    'index': index,
    if (received > 0) 'received': received,
    if (size != null) 'size': size,
    if (skipped.isNotEmpty) 'skipped': skipped,
    if (failed.isNotEmpty) 'failed': failed,
    if (reason != null) 'reason': reason,
  };

  /// Null without a valid [transferId], [state] and [total].
  static LinkTransferStatus? fromJson(Object? json) {
    if (json is! Map) return null;
    final transferId = _string(json['transferId']);
    final state = LinkTransferState.fromName(json['state']);
    final total = _int(json['total']);
    if (!isLinkTransferId(transferId) || state == null || total == null) {
      return null;
    }
    List<int> indexes(Object? raw) => raw is List
        ? [
            for (final value in raw)
              if (value is num) value.toInt(),
          ]
        : const [];
    final size = _int(json['size']);
    return LinkTransferStatus(
      transferId: transferId!,
      state: state,
      total: max(0, total),
      index: (_int(json['index']) ?? 0).clamp(0, max(0, total)),
      received: max(0, _int(json['received']) ?? 0),
      size: size == null || size <= 0 ? null : size,
      skipped: indexes(json['skipped']),
      failed: indexes(json['failed']),
      reason: _string(json['reason']),
    );
  }
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
  static const autoplay = 'autoplay';
  static const autoMix = 'auto_mix';
  static const jump = 'jump';

  /// `{"from","to"}`: moves a queue entry; indexes as for [jump].
  static const move = 'move';

  /// `{"index"}`: removes a queue entry other than the current one.
  static const remove = 'remove';
  static const playQueue = 'play_queue';

  /// Asks a phone to continue its queue on the paired computer.
  static const playOnDesktop = 'play_on_desktop';
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

  /// The phone catalog file for this track ([linkFileIdFor]), which also
  /// identifies its cover before the audio is sent. The desktop plays the
  /// received copy when its own Library lacks the track.
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

/// One song of a phone's Library as the desktop lists it (`phone/catalog`).
/// The desktop asks for `<fileId>.<suffix>` when it plays the song.
class LinkPhoneSong {
  const LinkPhoneSong({
    required this.fileId,
    required this.suffix,
    required this.title,
    required this.artist,
    this.size = 0,
    this.album,
    this.albumArtist,
    this.track,
    this.disc,
    this.year,
    this.genre,
    this.durationMs,
    this.isrc,
    this.bitRate,
    this.sampleRate,
    this.bitDepth,
    this.explicit = false,
    this.coverId,
    this.coverUrl,
    this.addedMs,
  });

  /// [linkFileIdFor] of the file, as Play on desktop names its upload.
  final String fileId;

  /// One of [linkUploadExtensions].
  final String suffix;
  final String title;
  final String artist;

  /// Bytes; 0 when the phone does not know before reading the file.
  final int size;
  final String? album;
  final String? albumArtist;
  final int? track;
  final int? disc;
  final int? year;
  final String? genre;
  final int? durationMs;
  final String? isrc;

  /// Kilobits per second.
  final int? bitRate;
  final int? sampleRate;
  final int? bitDepth;
  final bool explicit;

  /// The cover sent with `phone/covers`: 32 lowercase hex characters.
  final String? coverId;

  /// The `https` address of the cover when the phone holds no cover file,
  /// as for a downloaded song; the desktop fetches it.
  final String? coverUrl;
  final int? addedMs;

  /// The upload name: `<fileId>.<suffix>`.
  String get name => '$fileId.$suffix';

  /// The id the desktop keeps the cover under: [coverId], else the
  /// [linkCoverUrlId] of [coverUrl].
  String? get coverKey {
    final url = coverUrl;
    return coverId ?? (url == null ? null : linkCoverUrlId(url));
  }

  Map<String, dynamic> toJson() => {
    'fileId': fileId,
    'suffix': suffix,
    'title': title,
    'artist': artist,
    if (size > 0) 'size': size,
    if (album != null) 'album': album,
    if (albumArtist != null) 'albumArtist': albumArtist,
    if (track != null) 'track': track,
    if (disc != null) 'disc': disc,
    if (year != null) 'year': year,
    if (genre != null) 'genre': genre,
    if (durationMs != null) 'durationMs': durationMs,
    if (isrc != null) 'isrc': isrc,
    if (bitRate != null) 'bitRate': bitRate,
    if (sampleRate != null) 'sampleRate': sampleRate,
    if (bitDepth != null) 'bitDepth': bitDepth,
    if (explicit) 'explicit': true,
    if (coverId != null) 'coverId': coverId,
    if (coverUrl != null) 'coverUrl': coverUrl,
    if (addedMs != null) 'addedMs': addedMs,
  };

  /// Null for a song without a valid [fileId], [suffix] or [title].
  static LinkPhoneSong? fromJson(Object? json) {
    if (json is! Map) return null;
    final fileId = _string(json['fileId']);
    final suffix = _string(json['suffix'])?.toLowerCase();
    final title = _string(json['title']);
    if (!isLinkFileId(fileId) ||
        !linkUploadExtensions.contains(suffix) ||
        title == null) {
      return null;
    }
    final size = _int(json['size']) ?? 0;
    return LinkPhoneSong(
      fileId: fileId!,
      suffix: suffix!,
      title: title,
      artist: _string(json['artist']) ?? '',
      size: size > 0 ? size : 0,
      album: _string(json['album']),
      albumArtist: _string(json['albumArtist']),
      track: _int(json['track']),
      disc: _int(json['disc']),
      year: _int(json['year']),
      genre: _string(json['genre']),
      durationMs: _int(json['durationMs']),
      isrc: _string(json['isrc']),
      bitRate: _int(json['bitRate']),
      sampleRate: _int(json['sampleRate']),
      bitDepth: _int(json['bitDepth']),
      explicit: json['explicit'] == true,
      coverId: switch (_string(json['coverId'])) {
        final coverId? when isLinkFileId(coverId) => coverId,
        _ => null,
      },
      coverUrl: linkCoverUrl(json['coverUrl']),
      addedMs: _int(json['addedMs']),
    );
  }
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
    this.autoplay,
    this.autoMix,
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

  /// Null when a peer predates playback preference synchronization.
  final bool? autoplay;
  final bool? autoMix;

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
    if (autoplay != null) 'autoplay': autoplay,
    if (autoMix != null) 'autoMix': autoMix,
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
      autoplay: json['autoplay'] is bool ? json['autoplay'] as bool : null,
      autoMix: json['autoMix'] is bool ? json['autoMix'] as bool : null,
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
