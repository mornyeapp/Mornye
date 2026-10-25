import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/models/unified_library_item.dart';
import 'package:mornye/providers/download_history_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/services/history_database.dart';
import 'package:mornye/services/library_database.dart';
import 'package:mornye/services/link/desktop/link_catalog_exporter.dart';
import 'package:mornye/services/link/desktop/link_catalog_index.dart';
import 'package:mornye/services/link/desktop/link_phone_catalogs.dart';
import 'package:mornye/services/link/features/link_save_offline.dart';
import 'package:mornye/services/link/link_host_router.dart';
import 'package:mornye/services/link/link_protocol.dart';
import 'package:mornye/services/link/link_transfers.dart';
import 'package:mornye/utils/desktop_folders.dart';
import 'package:path/path.dart' as p;

/// A phone song the desktop receives, with its cover when known.
typedef LinkIncomingSong = ({LinkPhoneSong song, String? coverPath});

/// A desktop song offered to a phone, with its cover when known.
typedef LinkOutgoingSong = ({LinkTransferSong song, String? coverPath});

/// A phone song of the desktop's Library: its phone's Library source and
/// upload name.
typedef LinkPhoneSongPath = ({String sourceId, String name});

final _suffixPattern = RegExp(r'^[a-z0-9]{1,10}$');
final _yearPattern = RegExp(r'^\s*(\d{4})');

/// The history id of a song received from [peerId] (contract 13.2): the
/// same song received again replaces its record.
String linkTransferHistoryId(String peerId, String song) =>
    'link_${sha256.convert(utf8.encode('$peerId/$song'))}';

/// [path] as a phone song of the desktop's Library
/// (`network://<phone source id>/<fileId>.<suffix>`), or null.
LinkPhoneSongPath? linkPhoneSongPath(String path) {
  if (!path.startsWith('network://')) return null;
  final uri = Uri.tryParse(path);
  if (uri == null ||
      !isLinkPhoneSourceId(uri.host) ||
      uri.pathSegments.length != 1) {
    return null;
  }
  final name = uri.pathSegments.single;
  final dot = name.indexOf('.');
  if (dot <= 0 ||
      !isLinkFileId(name.substring(0, dot)) ||
      !linkUploadExtensions.contains(name.substring(dot + 1))) {
    return null;
  }
  return (sourceId: uri.host, name: name);
}

/// The catalog id the export gives [item] (`d:` and the history id for a
/// download, `l:` and the library id for a scanned song), or null for a
/// song whose file is not on this computer, such as a phone's.
String? linkDesktopSongIdOf(UnifiedLibraryItem item) {
  if (linkLocalFilePath(item.filePath) == null) return null;
  final history = item.historyItem;
  if (history != null) return linkDownloadSongId(history.id);
  final local = item.localItem;
  if (local != null) return linkLocalSongId(local.id);
  return null;
}

String? _text(String? value) {
  final trimmed = value?.trim() ?? '';
  return trimmed.isEmpty ? null : trimmed;
}

int? _year(String? date) {
  final match = _yearPattern.firstMatch(date ?? '');
  return match == null ? null : int.parse(match[1]!);
}

/// The lowercase extension of [path], else [format], else `audio`.
String _suffixOf(String path, String? format) {
  final extension = p.extension(path).replaceFirst('.', '').toLowerCase();
  if (_suffixPattern.hasMatch(extension)) return extension;
  final fallback = format?.trim().toLowerCase() ?? '';
  return _suffixPattern.hasMatch(fallback) ? fallback : 'audio';
}

/// [item] as a phone downloads it from the catalog song [songId], with its
/// tags and cover.
LinkOutgoingSong linkOutgoingSongOf(
  UnifiedLibraryItem item, {
  required String songId,
  int size = 0,
}) {
  final history = item.historyItem;
  final local = item.localItem;
  final path = linkLocalFilePath(item.filePath) ?? item.filePath;
  final seconds = history?.duration ?? local?.duration;
  return (
    song: LinkTransferSong(
      songId: songId,
      suffix: _suffixOf(path, history?.format ?? local?.format),
      title: _text(item.trackName) ?? p.basenameWithoutExtension(path).trim(),
      artist: item.artistName.trim(),
      size: size,
      album: _text(item.albumName),
      albumArtist: _text(history?.albumArtist ?? local?.albumArtist),
      track: history?.trackNumber ?? local?.trackNumber,
      disc: history?.discNumber ?? local?.discNumber,
      year: _year(history?.releaseDate ?? local?.releaseDate),
      genre: _text(history?.genre ?? local?.genre),
      durationMs: seconds != null && seconds > 0 ? seconds * 1000 : null,
      isrc: _text(history?.isrc ?? local?.isrc),
      bitRate: history?.bitrate ?? local?.bitrate,
      sampleRate: history?.sampleRate ?? local?.sampleRate,
      bitDepth: history?.bitDepth ?? local?.bitDepth,
      explicit: history?.explicit ?? local?.explicit ?? false,
    ),
    coverPath: _text(item.localCoverPath) ?? _text(item.coverUrl),
  );
}

/// The desktop's own songs of [items] that a phone can download: those in
/// the exported catalog [index], once each, with their file sizes.
Future<List<LinkOutgoingSong>> linkOutgoingSongs(
  Iterable<UnifiedLibraryItem> items,
  LinkCatalogIndex index,
) async {
  final songs = <LinkOutgoingSong>[];
  final seen = <String>{};
  for (final item in items) {
    final songId = linkDesktopSongIdOf(item);
    if (songId == null || !seen.add(songId) || index.songById(songId) == null) {
      continue;
    }
    var size = 0;
    try {
      size = await File(linkLocalFilePath(item.filePath)!).length();
    } on FileSystemException {
      // The phone learns the size when it downloads the file.
    }
    songs.add(linkOutgoingSongOf(item, songId: songId, size: size));
  }
  return songs;
}

/// Whether a playlist [track] may be a phone song: a scanned network row.
bool linkMayBePhoneTrack(Track track) =>
    track.source == 'local' && track.id.startsWith('network_');

/// The Library songs behind playlist [tracks], in order: the desktop's own
/// songs the identity [index] finds, and scanned network rows, which phone
/// songs are. Tracks neither of these are left out.
Future<List<UnifiedLibraryItem>> linkLibraryItemsForTracks(
  List<Track> tracks,
  LinkCatalogIndex? index, {
  Future<Map<String, Map<String, dynamic>>> Function(List<String> ids)?
  loadHistory,
  Future<List<Map<String, dynamic>>> Function(List<String> ids)? loadLibrary,
}) async {
  final keys = <String?>[];
  final historyIds = <String>[];
  final libraryIds = <String>[];
  for (final track in tracks) {
    final songId =
        index?.songIdForTrack(track) ??
        (linkMayBePhoneTrack(track) ? linkLocalSongId(track.id) : null);
    keys.add(songId);
    if (songId == null) continue;
    final id = linkRecordIdOf(songId);
    (songId == linkDownloadSongId(id) ? historyIds : libraryIds).add(id);
  }
  final downloads = historyIds.isEmpty
      ? const <String, Map<String, dynamic>>{}
      : await (loadHistory ?? HistoryDatabase.instance.getByIds)(historyIds);
  final scanned = {
    if (libraryIds.isNotEmpty)
      for (final row
          in await (loadLibrary ?? LibraryDatabase.instance.getByIds)(
            libraryIds,
          ))
        row['id'] as String: row,
  };
  final items = <UnifiedLibraryItem>[];
  for (final songId in keys.nonNulls) {
    final id = linkRecordIdOf(songId);
    if (songId == linkDownloadSongId(id)) {
      final row = downloads[id];
      if (row != null) {
        items.add(
          UnifiedLibraryItem.fromDownloadHistory(
            DownloadHistoryItem.fromJson(row),
          ),
        );
      }
    } else if (scanned[id] case final row?) {
      items.add(
        UnifiedLibraryItem.fromLocalLibrary(LocalLibraryItem.fromJson(row)),
      );
    }
  }
  return items;
}

/// The phone songs among [items] by phone Library source, once each.
Map<String, List<({String name, LocalLibraryItem item})>> linkPhoneSongsOf(
  Iterable<UnifiedLibraryItem> items,
) {
  final bySource = <String, List<({String name, LocalLibraryItem item})>>{};
  final seen = <String>{};
  for (final item in items) {
    final local = item.localItem;
    final path = local == null ? null : linkPhoneSongPath(local.filePath);
    if (local == null || path == null || !seen.add(local.filePath)) continue;
    (bySource[path.sourceId] ??= []).add((name: path.name, item: local));
  }
  return bySource;
}

/// The phone song [name] as the desktop's Library row [item] shows it, for
/// a song missing from the phone's stored list.
LinkPhoneSong linkPhoneSongOfItem(String name, LocalLibraryItem item) {
  final dot = name.indexOf('.');
  final seconds = item.duration;
  return LinkPhoneSong(
    fileId: name.substring(0, dot),
    suffix: name.substring(dot + 1),
    title: _text(item.trackName) ?? name,
    artist: item.artistName.trim(),
    album: _text(item.albumName),
    albumArtist: _text(item.albumArtist),
    track: item.trackNumber,
    disc: item.discNumber,
    year: _year(item.releaseDate),
    genre: _text(item.genre),
    durationMs: seconds != null && seconds > 0 ? seconds * 1000 : null,
    isrc: _text(item.isrc),
    bitRate: item.bitrate,
    sampleRate: item.sampleRate,
    bitDepth: item.bitDepth,
    explicit: item.explicit,
  );
}

/// The songs [chosen] of the phone [sourceId] as the desktop receives them:
/// the phone's stored song when it has one, else the Library row, each with
/// its stored cover.
Future<List<LinkIncomingSong>> linkIncomingSongs(
  LinkPhoneCatalogs catalogs,
  String sourceId,
  List<({String name, LocalLibraryItem item})> chosen,
) async {
  final wanted = {for (final entry in chosen) entry.name};
  final stored = <String, LinkPhoneSong>{};
  await for (final song in catalogs.songs(sourceId)) {
    if (wanted.contains(song.name)) stored[song.name] = song;
  }
  final covers = await catalogs.coverPaths(sourceId);
  return [
    for (final entry in chosen)
      switch (stored[entry.name]) {
        final song? => (
          song: song,
          coverPath: covers[song.coverKey] ?? song.coverUrl,
        ),
        null => (
          song: linkPhoneSongOfItem(entry.name, entry.item),
          coverPath: _text(entry.item.coverPath),
        ),
      },
  ];
}

/// [song] as the Transfers list shows it.
LinkTransferEntry linkIncomingEntry(LinkIncomingSong song) => LinkTransferEntry(
  title: song.song.title,
  artist: song.song.artist,
  album: song.song.album,
  coverPath: song.coverPath,
);

/// [song] as the Transfers list shows it.
LinkTransferEntry linkOutgoingEntry(LinkOutgoingSong song) => LinkTransferEntry(
  title: song.song.title,
  artist: song.song.artist,
  album: song.song.album,
  coverPath: song.coverPath,
);

/// [song], received as the file at [path], as the saver names it.
LocalLibraryItem linkReceivedItem(LinkPhoneSong song, String path) =>
    LocalLibraryItem(
      id: song.fileId,
      trackName: song.title,
      artistName: song.artist,
      albumName: song.album ?? '',
      albumArtist: song.albumArtist,
      filePath: path,
      scannedAt: DateTime.fromMillisecondsSinceEpoch(0),
      format: _suffixOf(path, song.suffix),
    );

/// The download history record of [song], stored as [stored] from the file
/// at [path].
DownloadHistoryItem linkReceivedHistory(
  LinkPhoneSong song, {
  required String id,
  required String path,
  required LinkOfflineStored stored,
  required DateTime downloadedAt,
}) {
  final durationMs = song.durationMs;
  return DownloadHistoryItem(
    id: id,
    trackName: song.title,
    artistName: song.artist,
    albumName: song.album ?? '',
    albumArtist: song.albumArtist,
    coverUrl: song.coverUrl,
    filePath: stored.filePath,
    storageMode: stored.storageMode,
    service: LinkOfflineSaver.service,
    downloadedAt: downloadedAt,
    isrc: song.isrc,
    trackNumber: song.track,
    discNumber: song.disc,
    duration: durationMs == null ? null : (durationMs / 1000).round(),
    releaseDate: song.year?.toString(),
    bitDepth: song.bitDepth,
    sampleRate: song.sampleRate,
    bitrate: song.bitRate,
    format: _suffixOf(path, song.suffix),
    genre: song.genre,
    explicit: song.explicit,
  );
}

/// The desktop's download folder: the one the settings choose, else the
/// desktop default (`<Music>/Mornye`), as downloads use it.
class LinkDesktopDownloadFolder implements LinkOfflineDestination {
  LinkDesktopDownloadFolder(
    this.settings, {
    Future<String?> Function()? defaultRoot,
  }) : _defaultRoot = defaultRoot ?? resolveDesktopDefaultOutputDirectory;

  final AppSettings settings;
  final Future<String?> Function() _defaultRoot;

  @override
  Future<LinkOfflineStored> store(
    File file, {
    required String relativeDir,
    required String fileName,
    required String mimeType,
  }) async {
    var root = settings.downloadDirectory.trim();
    if (root.isEmpty) root = (await _defaultRoot())?.trim() ?? '';
    return LinkDownloadFolderDestination(
      settings.copyWith(downloadDirectory: root),
    ).store(
      file,
      relativeDir: relativeDir,
      fileName: fileName,
      mimeType: mimeType,
    );
  }
}

/// Where the desktop keeps the songs it receives: its download folder and
/// download history.
abstract interface class LinkTransferDownloads {
  /// The download folder as the settings choose it now.
  LinkOfflineDestination destination();

  /// Adds the history record of a received song.
  Future<void> record(DownloadHistoryItem item);

  /// Whether the history record [id] exists and its file is still there.
  Future<bool> has(String id);
}

class _AppTransferDownloads implements LinkTransferDownloads {
  _AppTransferDownloads(this._ref);

  final Ref _ref;

  @override
  LinkOfflineDestination destination() =>
      LinkDesktopDownloadFolder(_ref.read(settingsProvider));

  @override
  Future<void> record(DownloadHistoryItem item) =>
      _ref.read(downloadHistoryProvider.notifier).addToHistory(item);

  @override
  Future<bool> has(String id) async {
    final row = await HistoryDatabase.instance.getById(id);
    final path = row?['filePath'];
    return path is String && path.isNotEmpty && await File(path).exists();
  }
}

/// The download folder and history received songs go to. Tests override
/// it.
final linkTransferDownloadsProvider = Provider<LinkTransferDownloads>(
  _AppTransferDownloads.new,
);
