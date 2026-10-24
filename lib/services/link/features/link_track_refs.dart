import 'package:audio_service/audio_service.dart' show MediaItem;
import 'package:mornye/models/download_history.dart';
import 'package:mornye/models/library_database_models.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/services/history_database.dart';
import 'package:mornye/services/link/link_client_api.dart';
import 'package:mornye/services/link/link_protocol.dart';
import 'package:mornye/services/network_storage_service.dart';
import 'package:mornye/services/playable_media.dart';

/// The match key a [TrackRef] carries: the normalized title and artist, the
/// same key the history and Library tables index. Null without a title.
String? linkMatchKey(String title, String artist) {
  final key = HistoryDatabase.matchKeyFor(title, artist);
  return key.isEmpty ? null : key;
}

String? _isrc(String? value) {
  final normalized = HistoryDatabase.normalizeIsrc(value);
  return normalized.isEmpty ? null : normalized;
}

String? _text(String? value) {
  final trimmed = value?.trim() ?? '';
  return trimmed.isEmpty ? null : trimmed;
}

int? _secondsToMs(int? seconds) =>
    seconds != null && seconds > 0 ? seconds * 1000 : null;

/// The desktop catalog id that [source] streams from [server]'s Subsonic
/// connection, or null when it is another file.
String? linkDesktopSongId(String source, LinkServerRecord server) {
  final uri = Uri.tryParse(source);
  if (uri == null ||
      uri.scheme != 'network' ||
      uri.host != server.connectionId.toLowerCase()) {
    return null;
  }
  return subsonicSongIdFromPath(uri.pathSegments.join('/'));
}

/// The source that streams the desktop catalog song [songId] through
/// [server]'s Subsonic connection, like a scanned network row. The format
/// suffix only names the file; the server sends the original.
String linkDesktopSongSource(
  LinkServerRecord server,
  String songId, {
  String format = 'raw',
}) => NetworkStorageService.source(
  server.connectionId,
  subsonicSongPath(songId, format),
);

TrackRef _ref({
  required String title,
  required String artist,
  String? album,
  int? durationMs,
  String? isrc,
  String? source,
  LinkServerRecord? server,
}) {
  final songId = source == null || server == null
      ? null
      : linkDesktopSongId(source, server);
  return TrackRef(
    title: title,
    artist: artist,
    album: _text(album),
    durationMs: durationMs != null && durationMs > 0 ? durationMs : null,
    isrc: _isrc(isrc),
    matchKey: linkMatchKey(title, artist),
    songId: songId,
    serverId: songId == null ? null : server!.serverId,
  );
}

/// What another device needs to find [media]: the desktop song id when it
/// streams from [server], and [isrc] when its record has one.
TrackRef linkTrackRefFromMedia(
  PlayableMedia media, {
  LinkServerRecord? server,
  String? isrc,
}) => _ref(
  title: media.title,
  artist: media.artist,
  album: media.album,
  durationMs: media.duration?.inMilliseconds,
  isrc: isrc,
  source: media.source,
  server: server,
);

/// [linkTrackRefFromMedia] for a queued [MediaItem], whose file is its
/// `source` extra.
TrackRef linkTrackRefFromMediaItem(
  MediaItem item, {
  LinkServerRecord? server,
  String? isrc,
}) => _ref(
  title: item.title,
  artist: item.artist ?? '',
  album: item.album,
  durationMs: item.duration?.inMilliseconds,
  isrc: isrc,
  source: item.extras?['source']?.toString(),
  server: server,
);

TrackRef linkTrackRefFromHistory(
  DownloadHistoryItem item, {
  LinkServerRecord? server,
}) => _ref(
  title: item.trackName,
  artist: item.artistName,
  album: item.albumName,
  durationMs: _secondsToMs(item.duration),
  isrc: item.isrc,
  source: item.filePath,
  server: server,
);

/// A Library row; rows scanned from [server]'s connection carry its song id.
TrackRef linkTrackRefFromLocal(
  LocalLibraryItem item, {
  LinkServerRecord? server,
}) => _ref(
  title: item.trackName,
  artist: item.artistName,
  album: item.albumName,
  durationMs: _secondsToMs(item.duration),
  isrc: item.isrc,
  source: item.filePath,
  server: server,
);

/// A search result or catalog track. Its id belongs to its provider, so it
/// never becomes a desktop song id.
TrackRef linkTrackRefFromTrack(Track track) => _ref(
  title: track.name,
  artist: track.artistName,
  album: track.albumName,
  durationMs: _secondsToMs(track.duration),
  isrc: track.isrc,
);

/// The part of a queue of [length] items that a player state or handoff
/// sends: at most [max] items around [index], up to [before] of them
/// already played. [index] outside the queue gives the first items.
({int start, int end}) linkQueueWindow(
  int length,
  int index, {
  int max = LinkPlayerState.maxQueue,
  int before = 50,
}) {
  if (length <= max) return (start: 0, end: length);
  final anchor = index < 0 || index >= length ? 0 : index;
  final start = (anchor - before).clamp(0, length - max);
  return (start: start, end: start + max);
}
