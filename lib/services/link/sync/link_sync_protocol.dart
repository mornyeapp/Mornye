import 'package:mornye/utils/cover_art_utils.dart';

/// Mornye Link collections and history sync. Both directions use
/// the same JSON, so the desktop (server) and the phone (client) share one
/// store implementation per database.
///
/// Every database keeps a random sync device id (`device`) and a sequence
/// counter. Each local change to a collection row is recorded once per key
/// (repeated changes coalesce) with the next sequence number; deletions are
/// kept as tombstones. A change applied from a peer keeps the author's
/// `origin` and `updatedMs`, so it is never mistaken for a local change.
///
/// `GET /mornye/v1/collections`, query (strings on the wire):
///   `since`  the responder's cursor from the previous page (default 0),
///   `device` the requester's sync id; changes it authored are skipped,
///   `limit`  page size, 1 to [linkSyncPageSize] (default the maximum).
/// Reply:
///   `{"device": responder sync id, "cursor": int, "latest": int,
///     "more": bool, "changes": [Change]}`
///   `cursor` is the value for the next `since`; `latest` is the responder's
///   newest sequence (a `since` above it means the responder was reset).
///   While `more` is true the requester asks again with the new cursor.
///
/// `POST /mornye/v1/collections`, body `{"device", "changes": [Change]}`.
/// Reply `{"applied": int, "cursor": int}` (`cursor` = the receiver's newest
/// sequence, informational).
///
/// Change:
///   `{"kind": "loved"|"wishlist"|"playlist"|"playlistTrack"|"favoriteArtist",
///     "playlistId": String (playlistTrack only), "key": String,
///     "deleted": bool, "updatedMs": int, "origin": author sync id,
///     "data": {...} (absent when deleted)}`
///   `key` is the track key (`loved`, `wishlist`, `playlistTrack`), the
///   playlist id (`playlist`) or the artist key (`favoriteArtist`).
///   `data`: `loved`, `wishlist`, `playlistTrack`:
///   `{"track": Track JSON, "addedMs": int}` (no `network://` `coverUrl`,
///   which names a connection of the author only; a receiver whose row
///   holds one keeps it when the track comes without a cover); `playlist`:
///   `{"name", "createdMs", "updatedMs"}` (cover images are device-local and
///   never sync); `favoriteArtist`: `{"artist": artist entry JSON,
///   "addedMs": int}`.
///
/// Conflicts: last writer wins per (kind, playlistId, key) by `updatedMs`,
/// ties broken by the greater `origin`. A local edit is always stamped later
/// than the version it replaces, so clock skew between devices cannot hide
/// it. A playlist record carries only its existence and name: renaming and
/// membership never conflict. Deleting a playlist also deletes its members;
/// a later rename recreates it (empty), a later membership edit does not.
/// A page that adds members also carries those playlists' records, so a
/// receiver can create a playlist before its members in any page order.
///
/// History (`/mornye/v1/history`) uses the same query, cursors and replies
/// with `events` instead of `changes`. An event is one author's running
/// total for one song on one day:
///   `{"origin", "day": "YYYY-MM-DD", "trackKey", "title", "artist",
///     "album", "artwork"? (http and https only, no loopback), "ms": int,
///     "plays": int}`
/// Its stable id is (origin, day, trackKey). Totals only grow, so a receiver
/// adds the growth since the last value it saw and re-sending is harmless.
/// Clearing statistics is local to one device.
///
/// `history/artwork` repairs missing covers independently of these counters,
/// so an old event needs no new listening time to acquire artwork. GET pages
/// missing song descriptors and the identities of available covers. POST
/// `want` requests at most four covers; POST `covers` supplies them. Covers
/// carry a web URL or a validated 256-pixel thumbnail (at most 512 KiB each).
/// Device-local artwork paths are never sent as image references. A receiver
/// stores thumbnails locally and retains its existing usable covers.
const linkSyncPageSize = 500;

abstract final class LinkSyncKinds {
  static const loved = 'loved';
  static const wishlist = 'wishlist';
  static const playlist = 'playlist';
  static const playlistTrack = 'playlistTrack';
  static const favoriteArtist = 'favoriteArtist';

  static const all = {loved, wishlist, playlist, playlistTrack, favoriteArtist};
}

String? _string(Object? value) {
  if (value is! String) return null;
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}

int? _int(Object? value) => switch (value) {
  final num number => number.toInt(),
  final String text => int.tryParse(text.trim()),
  _ => null,
};

Map<String, dynamic>? _map(Object? value) =>
    value is Map ? Map<String, dynamic>.from(value) : null;

/// Reads an int from a JSON value or a query string.
int? linkSyncInt(Object? value) => _int(value);

/// One author's change to one collection key.
class LinkSyncChange {
  const LinkSyncChange({
    required this.kind,
    required this.key,
    required this.updatedMs,
    required this.origin,
    this.playlistId = '',
    this.deleted = false,
    this.data,
  });

  final String kind;

  /// The playlist of a `playlistTrack` change, else empty.
  final String playlistId;
  final String key;
  final bool deleted;
  final int updatedMs;
  final String origin;
  final Map<String, dynamic>? data;

  /// Whether this version replaces [updatedMs] by [origin] under last
  /// writer wins.
  bool winsOver({required int updatedMs, required String origin}) =>
      this.updatedMs > updatedMs ||
      (this.updatedMs == updatedMs && this.origin.compareTo(origin) > 0);

  Map<String, dynamic> toJson() => {
    'kind': kind,
    if (kind == LinkSyncKinds.playlistTrack) 'playlistId': playlistId,
    'key': key,
    'deleted': deleted,
    'updatedMs': updatedMs,
    'origin': origin,
    if (!deleted && data != null) 'data': data,
  };

  /// Parses a change; [fallbackOrigin] fills a missing `origin`. Returns
  /// null for an unknown kind, a missing key or a live change without data.
  static LinkSyncChange? fromJson(Object? json, {String? fallbackOrigin}) {
    if (json is! Map) return null;
    final kind = json['kind'];
    final key = _string(json['key']);
    final origin = _string(json['origin']) ?? fallbackOrigin;
    final updatedMs = _int(json['updatedMs']);
    if (kind is! String ||
        !LinkSyncKinds.all.contains(kind) ||
        key == null ||
        origin == null ||
        updatedMs == null) {
      return null;
    }
    final playlistId = kind == LinkSyncKinds.playlistTrack
        ? _string(json['playlistId'])
        : '';
    if (playlistId == null) return null;
    final deleted = json['deleted'] == true;
    final data = _map(json['data']);
    if (!deleted && data == null) return null;
    return LinkSyncChange(
      kind: kind,
      playlistId: playlistId,
      key: key,
      deleted: deleted,
      updatedMs: updatedMs,
      origin: origin,
      data: deleted ? null : data,
    );
  }
}

/// One author's running listening total for one song on one day.
class LinkHistoryEvent {
  const LinkHistoryEvent({
    required this.origin,
    required this.day,
    required this.trackKey,
    required this.title,
    required this.artist,
    required this.album,
    required this.milliseconds,
    required this.plays,
    this.artwork,
  });

  final String origin;
  final String day;
  final String trackKey;
  final String title;
  final String artist;
  final String album;
  final String? artwork;
  final int milliseconds;
  final int plays;

  Map<String, dynamic> toJson() => {
    'origin': origin,
    'day': day,
    'trackKey': trackKey,
    'title': title,
    'artist': artist,
    'album': album,
    if (artwork != null) 'artwork': artwork,
    'ms': milliseconds,
    'plays': plays,
  };

  static final _dayPattern = RegExp(r'^\d{4}-\d{2}-\d{2}$');

  static LinkHistoryEvent? fromJson(Object? json, {String? fallbackOrigin}) {
    if (json is! Map) return null;
    final origin = _string(json['origin']) ?? fallbackOrigin;
    final day = _string(json['day']);
    final trackKey = _string(json['trackKey']);
    final milliseconds = _int(json['ms']);
    final plays = _int(json['plays']);
    if (origin == null ||
        day == null ||
        !_dayPattern.hasMatch(day) ||
        trackKey == null ||
        milliseconds == null ||
        milliseconds < 0 ||
        plays == null ||
        plays < 0) {
      return null;
    }
    return LinkHistoryEvent(
      origin: origin,
      day: day,
      trackKey: trackKey,
      title: json['title'] is String ? json['title'] as String : '',
      artist: json['artist'] is String ? json['artist'] as String : '',
      album: json['album'] is String ? json['album'] as String : '',
      artwork: linkSyncRemoteArtwork(json['artwork']),
      milliseconds: milliseconds,
      plays: plays,
    );
  }
}

/// Artwork another device can load: http and https URLs only, without the
/// loopback URLs older builds recorded, which named the author's own proxy.
String? linkSyncRemoteArtwork(Object? value) {
  final artwork = _string(value);
  if (artwork == null) return null;
  final lower = artwork.toLowerCase();
  return (lower.startsWith('https://') || lower.startsWith('http://')) &&
          !isLoopbackHost(Uri.tryParse(artwork)?.host ?? '')
      ? artwork
      : null;
}

/// A collection [track] (Track JSON) as another device reads it: without a
/// `network://` cover, which names a connection of this device only.
Map<String, dynamic> linkSyncTrack(Map<String, dynamic> track) =>
    _string(track['coverUrl'])?.startsWith('network://') == true
    ? {...track, 'coverUrl': null}
    : track;

/// A page of changes or events (`GET collections`, `GET history`).
class LinkSyncPage<T> {
  const LinkSyncPage({
    required this.device,
    required this.cursor,
    required this.latest,
    required this.more,
    required this.items,
  });

  /// The responder's sync device id.
  final String device;
  final int cursor;
  final int latest;
  final bool more;
  final List<T> items;

  Map<String, dynamic> toJson(
    String listName,
    Map<String, dynamic> Function(T item) encode,
  ) => {
    'device': device,
    'cursor': cursor,
    'latest': latest,
    'more': more,
    listName: [for (final item in items) encode(item)],
  };

  static LinkSyncPage<T>? fromJson<T>(
    Object? json,
    String listName,
    T? Function(Object? item, String origin) decode,
  ) {
    if (json is! Map) return null;
    final device = _string(json['device']);
    final cursor = _int(json['cursor']);
    final list = json[listName];
    if (device == null || cursor == null || list is! List) return null;
    return LinkSyncPage(
      device: device,
      cursor: cursor,
      latest: _int(json['latest']) ?? cursor,
      more: json['more'] == true,
      items: [for (final item in list) ?decode(item, device)],
    );
  }
}

/// A catalog song as the server forwards it with Subsonic ops (contract
/// section 6.2).
class LinkSongInfo {
  const LinkSongInfo({
    required this.id,
    required this.title,
    required this.artist,
    this.album,
    this.albumArtist,
    this.durationMs,
    this.isrc,
    this.matchKey,
    this.path,
  });

  /// `l:<library id>` or `d:<history id>`.
  final String id;
  final String title;
  final String artist;
  final String? album;
  final String? albumArtist;
  final int? durationMs;
  final String? isrc;
  final String? matchKey;
  final String? path;

  static LinkSongInfo? fromJson(Object? json) {
    if (json is! Map) return null;
    final id = _string(json['id']);
    if (id == null) return null;
    return LinkSongInfo(
      id: id,
      title: _string(json['title']) ?? '',
      artist: _string(json['artist']) ?? '',
      album: _string(json['album']),
      albumArtist: _string(json['albumArtist']),
      durationMs: _int(json['durationMs']),
      isrc: _string(json['isrc']),
      matchKey: _string(json['matchKey']),
      path: _string(json['path']),
    );
  }

  static List<LinkSongInfo> listFromJson(Object? json) => json is List
      ? [for (final item in json) ?LinkSongInfo.fromJson(item)]
      : const [];
}

/// A loose comparison form of an artist name (trimmed, inner whitespace
/// collapsed, lowercase). Only for matching names the server sends back; the
/// server alone derives Subsonic artist ids, from names the app reports.
String linkArtistNameKey(String name) =>
    name.trim().replaceAll(RegExp(r'\s+'), ' ').toLowerCase();

/// Milliseconds since the epoch for a stored ISO timestamp, or null.
int? linkSyncIsoToMs(Object? value) =>
    value is String ? DateTime.tryParse(value)?.millisecondsSinceEpoch : null;

/// The stored ISO timestamp format (local time) for [ms].
String linkSyncMsToIso(int ms) =>
    DateTime.fromMillisecondsSinceEpoch(ms).toIso8601String();
