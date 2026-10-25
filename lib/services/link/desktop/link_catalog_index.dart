import 'package:mornye/models/track.dart';
import 'package:mornye/services/history_database.dart';
import 'package:mornye/services/link/link_host_router.dart';
import 'package:mornye/services/link/link_protocol.dart';
import 'package:mornye/utils/isrc_utils.dart';

/// Two durations name the same recording when they differ by at most this.
const linkDurationToleranceMs = 2000;

const _localPrefix = 'l:';
const _downloadPrefix = 'd:';

/// The catalog id of a scanned Library row.
String linkLocalSongId(String libraryId) => '$_localPrefix$libraryId';

/// The catalog id of a download history row.
String linkDownloadSongId(String historyId) => '$_downloadPrefix$historyId';

/// The Library or history row id behind a catalog [songId].
String linkRecordIdOf(String songId) =>
    songId.startsWith(_localPrefix) || songId.startsWith(_downloadPrefix)
    ? songId.substring(2)
    : songId;

/// Title and artist as the app compares them (`HistoryDatabase`), or '' when
/// the title is empty.
String linkMatchKey(String title, String artist) =>
    HistoryDatabase.matchKeyFor(title, artist);

final _bracketed = RegExp(r'[\(\[][^\)\]]*[\)\]]');
final _nonWord = RegExp(r'[^\p{L}\p{N}]+', unicode: true);
final _artistSeparator = RegExp(
  r'\s*(?:,|;|/|&|\sfeat\.?\s|\sft\.?\s|\sfeaturing\s|\swith\s)\s*',
  caseSensitive: false,
);

/// A looser title and artist key for the last resolution step: case,
/// punctuation, bracketed suffixes such as "(Remastered)" and featured
/// artists do not count. Durations still have to agree.
String linkLooseKey(String title, String artist) {
  String compact(String value) => value.toLowerCase().replaceAll(_nonWord, '');
  var name = compact(title.replaceAll(_bracketed, ' '));
  if (name.isEmpty) name = compact(title);
  if (name.isEmpty) return '';
  final firstArtist = artist
      .split(_artistSeparator)
      .firstWhere((part) => part.trim().isNotEmpty, orElse: () => '');
  return '$name|${compact(firstArtist)}';
}

/// A file path as the media item or catalog row stores it, without the
/// download queue's `EXISTS:` marker.
String linkCleanPath(String path) =>
    path.startsWith('EXISTS:') ? path.substring(7) : path;

/// Collects exported songs, then freezes them into a
/// [DesktopLinkCatalogIndex].
class LinkCatalogIndexBuilder {
  final _songs = <LinkCatalogSong>[];
  final _covers = <String, String>{};

  int get length => _songs.length;

  void add(LinkCatalogSong song, {String? cover}) {
    _songs.add(song);
    if (cover != null) _covers[song.id] = cover;
  }

  DesktopLinkCatalogIndex build(String serverId) => DesktopLinkCatalogIndex(
    serverId: serverId,
    songs: _songs,
    covers: _covers,
  );
}

/// The identity index of one catalog export (contract sections 8 and 9).
///
/// Resolution order for a [TrackRef]: its `songId` when it names this server,
/// then the ISRC, then the match key with the duration within two seconds,
/// then the looser title and artist key with the duration within two
/// seconds. A side without a duration does not block a match.
class DesktopLinkCatalogIndex implements LinkCatalogIndex {
  DesktopLinkCatalogIndex({
    required this.serverId,
    required List<LinkCatalogSong> songs,
    Map<String, String> covers = const {},
  }) : _covers = Map.unmodifiable(covers) {
    for (final song in songs) {
      _byId[song.id] = song;
      _byPath.putIfAbsent(song.path, () => song.id);
      final isrc = normalizeIsrc(song.isrc);
      if (isrc.isNotEmpty) (_byIsrc[isrc] ??= []).add(song);
      final matchKey = song.matchKey ?? linkMatchKey(song.title, song.artist);
      if (matchKey.isNotEmpty) (_byMatchKey[matchKey] ??= []).add(song);
      final loose = linkLooseKey(song.title, song.artist);
      if (loose.isNotEmpty) (_byLooseKey[loose] ??= []).add(song);
    }
  }

  /// An index without songs, for a server that has not exported yet.
  factory DesktopLinkCatalogIndex.empty(String serverId) =>
      DesktopLinkCatalogIndex(serverId: serverId, songs: const []);

  /// The server whose song ids this index holds.
  final String serverId;

  final _byId = <String, LinkCatalogSong>{};
  final _byPath = <String, String>{};
  final _byIsrc = <String, List<LinkCatalogSong>>{};
  final _byMatchKey = <String, List<LinkCatalogSong>>{};
  final _byLooseKey = <String, List<LinkCatalogSong>>{};
  final Map<String, String> _covers;

  @override
  int get length => _byId.length;

  @override
  LinkCatalogSong? songById(String id) => _byId[id];

  /// The cover file or web cover URL the desktop player shows for [id], or
  /// null.
  String? coverFor(String id) => _covers[id];

  /// The catalog song that plays the file at [path].
  String? songIdForPath(String path) => _byPath[linkCleanPath(path)];

  /// The catalog song behind a player item: by its file, then by its media
  /// id when that is a Library or history row id.
  String? songIdForMedia({required String id, required String path}) {
    final byPath = path.isEmpty ? null : songIdForPath(path);
    if (byPath != null) return byPath;
    if (id.isEmpty) return null;
    for (final candidate in [linkLocalSongId(id), linkDownloadSongId(id)]) {
      if (_byId.containsKey(candidate)) return candidate;
    }
    return null;
  }

  @override
  String? songIdForRef(TrackRef ref) {
    final songId = ref.songId;
    if (songId != null) {
      final song = _byId[songId];
      // An id without a server can come from another desktop's catalog, so
      // it also has to carry the same title.
      final sameServer = ref.serverId == null
          ? song != null &&
                linkLooseKey(song.title, '') == linkLooseKey(ref.title, '')
          : ref.serverId == serverId;
      if (song != null && sameServer) return song.id;
    }
    return _match(
      title: ref.title,
      artist: ref.artist,
      durationMs: ref.durationMs,
      isrc: ref.isrc,
      matchKey: ref.matchKey,
    );
  }

  @override
  String? songIdForTrack(Track track) {
    final id = track.id.trim();
    if (id.isNotEmpty) {
      final local = linkLocalSongId(id);
      final download = linkDownloadSongId(id);
      final direct = track.source == 'local'
          ? [local, download]
          : [download, local];
      final title = linkLooseKey(track.name, '');
      for (final candidate in direct) {
        final song = _byId[candidate];
        // Provider catalog ids are not Library ids; the title confirms it.
        if (song != null && linkLooseKey(song.title, '') == title) {
          return song.id;
        }
      }
    }
    return _match(
      title: track.name,
      artist: track.artistName,
      durationMs: track.duration > 0 ? track.duration * 1000 : null,
      isrc: track.isrc,
      matchKey: null,
    );
  }

  String? _match({
    required String title,
    required String artist,
    required int? durationMs,
    required String? isrc,
    required String? matchKey,
  }) {
    final normalizedIsrc = normalizeIsrc(isrc);
    if (normalizedIsrc.isNotEmpty) {
      final hit = _closest(
        _byIsrc[normalizedIsrc],
        durationMs,
        requireDuration: false,
      );
      if (hit != null) return hit.id;
    }
    final key = matchKey?.trim().toLowerCase() ?? '';
    final exact = key.isNotEmpty ? key : linkMatchKey(title, artist);
    if (exact.isNotEmpty) {
      final hit = _closest(_byMatchKey[exact], durationMs);
      if (hit != null) return hit.id;
    }
    final loose = linkLooseKey(title, artist);
    if (loose.isNotEmpty) {
      final hit = _closest(_byLooseKey[loose], durationMs);
      if (hit != null) return hit.id;
    }
    return null;
  }

  /// The candidate whose duration is closest to [durationMs]. Unless
  /// [requireDuration] is false, known durations further apart than the
  /// tolerance never match.
  static LinkCatalogSong? _closest(
    List<LinkCatalogSong>? candidates,
    int? durationMs, {
    bool requireDuration = true,
  }) {
    if (candidates == null || candidates.isEmpty) return null;
    if (durationMs == null) return candidates.first;
    LinkCatalogSong? best;
    var bestDiff = 1 << 62;
    LinkCatalogSong? unknown;
    for (final song in candidates) {
      final songDuration = song.durationMs;
      if (songDuration == null) {
        unknown ??= song;
        continue;
      }
      final diff = (songDuration - durationMs).abs();
      if (requireDuration && diff > linkDurationToleranceMs) continue;
      if (diff < bestDiff) {
        best = song;
        bestDiff = diff;
      }
    }
    return best ?? unknown;
  }
}
