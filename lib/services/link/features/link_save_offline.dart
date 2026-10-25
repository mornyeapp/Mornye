import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:mornye/models/download_history.dart';
import 'package:mornye/models/library_database_models.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/services/cover_download_service.dart';
import 'package:mornye/services/folder_path_template.dart';
import 'package:mornye/services/link/features/link_track_refs.dart';
import 'package:mornye/services/link/link_client_api.dart';
import 'package:mornye/services/link/link_protocol.dart';
import 'package:mornye/services/network_storage_service.dart';
import 'package:mornye/services/platform_bridge.dart';

/// A Library song scanned from the paired desktop, which the phone can save.
class LinkOfflineSong {
  const LinkOfflineSong({required this.item, required this.songId});

  /// A song the desktop offered (`transfers.offer`), named and recorded with
  /// the tags it sent.
  factory LinkOfflineSong.offered(
    LinkTransferSong song,
    LinkServerRecord server,
  ) {
    String? text(String? value) =>
        value == null || value.trim().isEmpty ? null : value.trim();
    final durationMs = song.durationMs;
    return LinkOfflineSong(
      songId: song.songId,
      item: LocalLibraryItem(
        id: 'link_offer_${song.songId}',
        trackName: song.title,
        artistName: song.artist,
        albumName: text(song.album) ?? '',
        albumArtist: text(song.albumArtist),
        filePath: linkDesktopSongSource(
          server,
          song.songId,
          format: song.suffix,
        ),
        scannedAt: DateTime.fromMillisecondsSinceEpoch(0),
        isrc: text(song.isrc),
        trackNumber: song.track,
        discNumber: song.disc,
        duration: durationMs == null || durationMs <= 0
            ? null
            : (durationMs / 1000).round(),
        releaseDate: song.year?.toString(),
        bitDepth: song.bitDepth,
        sampleRate: song.sampleRate,
        bitrate: song.bitRate,
        genre: text(song.genre),
        explicit: song.explicit,
        format: song.suffix,
      ),
    );
  }

  final LocalLibraryItem item;

  /// The desktop catalog id of [item].
  final String songId;
}

/// The songs of [items] that stream from [server]'s Subsonic connection.
List<LinkOfflineSong> linkOfflineSongs(
  Iterable<LocalLibraryItem> items,
  LinkServerRecord server,
) => [
  for (final item in items)
    if (linkDesktopSongId(item.filePath, server) case final songId?)
      LinkOfflineSong(item: item, songId: songId),
];

/// Fetches a desktop song's original file.
abstract interface class LinkOfflineTransport {
  /// Writes the original file of [songId] to [output]. [checkpoint] throws
  /// to cancel between chunks.
  Future<void> download(
    String songId,
    File output, {
    required void Function() checkpoint,
    required void Function(int received, int? total) progress,
  });

  /// Ends any download in flight and releases the connection.
  void close();
}

/// Where a saved file landed.
class LinkOfflineStored {
  const LinkOfflineStored({
    required this.filePath,
    required this.storageMode,
    this.treeUri,
    this.relativeDir,
    this.fileName,
  });

  /// A path, or a `content://` URI under Android's storage access.
  final String filePath;

  /// `app` or `saf`, as download history records it.
  final String storageMode;
  final String? treeUri;
  final String? relativeDir;
  final String? fileName;
}

/// The phone's download folder.
abstract interface class LinkOfflineDestination {
  /// Copies [file] to [relativeDir]/[fileName] in the download folder,
  /// renaming it when the name is taken. Throws [LinkOfflineNoFolder] when
  /// the folder is unavailable.
  Future<LinkOfflineStored> store(
    File file, {
    required String relativeDir,
    required String fileName,
    required String mimeType,
  });
}

/// The download folder is unavailable (no storage access granted), so no
/// song can be saved.
class LinkOfflineNoFolder implements Exception {
  const LinkOfflineNoFolder();

  @override
  String toString() => 'LinkOfflineNoFolder: no storage access';
}

class LinkOfflineProgress {
  const LinkOfflineProgress({
    required this.done,
    required this.total,
    required this.title,
    this.received = 0,
    this.size,
  });

  /// Songs finished (saved, skipped or failed) before the current one.
  final int done;
  final int total;

  /// The song being saved.
  final String title;
  final int received;
  final int? size;

  /// The whole job, 0 to 1.
  double get fraction {
    if (total <= 0) return 1;
    final size = this.size;
    final part = size == null || size <= 0
        ? 0.0
        : (received / size).clamp(0.0, 1.0);
    return ((done + part) / total).clamp(0.0, 1.0);
  }
}

/// How one song of a [LinkOfflineSaver.save] run ended.
enum LinkOfflineOutcome {
  saved,

  /// This phone already had it.
  skipped,
  failed,
}

class LinkOfflineResult {
  const LinkOfflineResult({
    required this.saved,
    required this.failed,
    required this.cancelled,
    this.skipped = 0,
  });

  final int saved;
  final int skipped;
  final int failed;
  final bool cancelled;
}

/// Cancels a [LinkOfflineSaver.save] run.
class LinkOfflineCancel {
  bool _cancelled = false;
  void Function()? _onCancel;

  bool get cancelled => _cancelled;

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    _onCancel?.call();
  }
}

class _Cancelled implements Exception {
  const _Cancelled();
}

/// Saves desktop songs to the phone as downloads: the original file goes
/// into the download folder and a history record with the song's tags makes
/// it a Library download straight away.
class LinkOfflineSaver {
  LinkOfflineSaver({
    required this.serverId,
    required this.openTransport,
    required this.destination,
    required this.record,
    required this.temporaryDirectory,
    this.exists,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  /// The paired desktop the songs come from ([LinkServerRecord.serverId]).
  final String serverId;

  /// A transport for one [save] run, closed when the run ends.
  final LinkOfflineTransport Function() openTransport;
  final LinkOfflineDestination destination;

  /// Adds the history record of a saved song.
  final Future<void> Function(DownloadHistoryItem item) record;
  final Future<Directory> Function() temporaryDirectory;

  /// Whether the history record with this id exists and its file is still
  /// there; such songs are skipped. Without it every song is fetched.
  final Future<bool> Function(String historyId)? exists;
  final DateTime Function() _now;

  static const service = 'Mornye Link';

  /// The history id of [songId] (contract section 13.2): the same song
  /// saved again replaces its record.
  String historyId(String songId) =>
      'link_${sha256.convert(utf8.encode('$serverId/$songId'))}';

  Future<bool> _has(LinkOfflineSong song) async {
    final exists = this.exists;
    if (exists == null) return false;
    try {
      return await exists(historyId(song.songId));
    } on Object {
      return false;
    }
  }

  static String _extension(LocalLibraryItem item) {
    final format = item.format?.trim().toLowerCase() ?? '';
    if (RegExp(r'^[a-z0-9]{1,10}$').hasMatch(format)) return format;
    final suffix = p.extension(item.filePath).replaceFirst('.', '');
    return suffix.isEmpty || suffix == 'raw' ? 'audio' : suffix.toLowerCase();
  }

  /// `Album artist/Album`, or the artist alone without an album.
  static String relativeDirFor(LocalLibraryItem item) {
    final artist = (item.albumArtist?.trim().isNotEmpty ?? false)
        ? item.albumArtist!
        : item.artistName;
    final album = item.albumName.trim();
    return [
      FolderPathTemplate.sanitizeComponent(artist),
      if (album.isNotEmpty) FolderPathTemplate.sanitizeComponent(album),
    ].join('/');
  }

  /// `Title - Artist.ext`, like the default download file name.
  static String fileNameFor(LocalLibraryItem item) {
    final stem = FolderPathTemplate.sanitizeComponent(
      item.artistName.trim().isEmpty
          ? item.trackName
          : '${item.trackName} - ${item.artistName}',
    );
    return '$stem.${_extension(item)}';
  }

  DownloadHistoryItem _history(LinkOfflineSong song, LinkOfflineStored stored) {
    final item = song.item;
    final saf = stored.storageMode == 'saf';
    return DownloadHistoryItem(
      id: historyId(song.songId),
      trackName: item.trackName,
      artistName: item.artistName,
      albumName: item.albumName,
      albumArtist: item.albumArtist,
      coverUrl: item.coverPath,
      filePath: stored.filePath,
      storageMode: stored.storageMode,
      downloadTreeUri: saf ? stored.treeUri : null,
      safRelativeDir: saf ? stored.relativeDir : null,
      safFileName: saf ? stored.fileName : null,
      service: service,
      downloadedAt: _now(),
      isrc: item.isrc,
      trackNumber: item.trackNumber,
      totalTracks: item.totalTracks,
      discNumber: item.discNumber,
      totalDiscs: item.totalDiscs,
      duration: item.duration,
      releaseDate: item.releaseDate,
      bitDepth: item.bitDepth,
      sampleRate: item.sampleRate,
      bitrate: item.bitrate,
      format: item.format,
      genre: item.genre,
      composer: item.composer,
      label: item.label,
      copyright: item.copyright,
      explicit: item.explicit,
      hasLyrics: item.hasLyrics,
      lyricsMetadataScanVersion: item.hasLyrics ? 1 : 0,
      hasReplayGain: item.hasReplayGain,
    );
  }

  /// Saves [songs] one by one, skipping those this phone already has
  /// ([exists]). A song that fails is counted and the run goes on; [onSong]
  /// learns how each one ended, by its index. [cancel] stops the run and
  /// discards the song in flight. Throws [LinkOfflineNoFolder] when the
  /// download folder is unavailable.
  Future<LinkOfflineResult> save(
    List<LinkOfflineSong> songs, {
    void Function(LinkOfflineProgress progress)? onProgress,
    void Function(int index, LinkOfflineOutcome outcome)? onSong,
    LinkOfflineCancel? cancel,
  }) async {
    var saved = 0;
    var skipped = 0;
    var failed = 0;
    final transport = openTransport();
    cancel?._onCancel = transport.close;
    void checkpoint() {
      if (cancel?.cancelled ?? false) throw const _Cancelled();
    }

    try {
      final temp = await temporaryDirectory();
      for (var index = 0; index < songs.length; index++) {
        if (cancel?.cancelled ?? false) break;
        final song = songs[index];
        final done = index;
        final title = song.item.trackName;
        onProgress?.call(
          LinkOfflineProgress(done: done, total: songs.length, title: title),
        );
        if (await _has(song)) {
          if (cancel?.cancelled ?? false) break;
          skipped++;
          onSong?.call(index, LinkOfflineOutcome.skipped);
          continue;
        }
        final file = File(
          p.join(
            temp.path,
            'link_offline_${Random.secure().nextInt(1 << 32)}'
            '.${_extension(song.item)}',
          ),
        );
        LinkOfflineOutcome outcome;
        try {
          await transport.download(
            song.songId,
            file,
            checkpoint: checkpoint,
            progress: (received, size) => onProgress?.call(
              LinkOfflineProgress(
                done: done,
                total: songs.length,
                title: title,
                received: received,
                size: size,
              ),
            ),
          );
          checkpoint();
          final fileName = fileNameFor(song.item);
          final stored = await destination.store(
            file,
            relativeDir: relativeDirFor(song.item),
            fileName: fileName,
            mimeType: networkContentType(fileName),
          );
          await record(_history(song, stored));
          saved++;
          outcome = LinkOfflineOutcome.saved;
        } on LinkOfflineNoFolder {
          rethrow;
        } on Object {
          if (cancel?.cancelled ?? false) break;
          failed++;
          outcome = LinkOfflineOutcome.failed;
        } finally {
          try {
            if (await file.exists()) await file.delete();
          } on FileSystemException {
            // A leftover temporary file is cleaned with the cache.
          }
        }
        onSong?.call(index, outcome);
      }
    } finally {
      cancel?._onCancel = null;
      transport.close();
    }
    onProgress?.call(
      LinkOfflineProgress(
        done: saved + skipped + failed,
        total: songs.length,
        title: '',
      ),
    );
    return LinkOfflineResult(
      saved: saved,
      skipped: skipped,
      failed: failed,
      cancelled: cancel?.cancelled ?? false,
    );
  }
}

/// [LinkOfflineTransport] over the desktop's pinned Subsonic connection
/// (`download`).
class LinkSubsonicTransport implements LinkOfflineTransport {
  LinkSubsonicTransport({
    required this.connectionId,
    NetworkStorageService? storage,
  }) : _storage = storage ?? NetworkStorageService.instance;

  final String connectionId;
  final NetworkStorageService _storage;
  SubsonicClient? _client;
  bool _closed = false;

  @override
  Future<void> download(
    String songId,
    File output, {
    required void Function() checkpoint,
    required void Function(int received, int? total) progress,
  }) async {
    if (_closed) throw StateError('Link download closed');
    final client = _client ??= _storage.openSubsonic(
      await _storage.connection(connectionId),
    );
    await client.download(
      songId,
      output,
      checkpoint: checkpoint,
      progress: progress,
    );
  }

  @override
  void close() {
    _closed = true;
    _client?.close();
    _client = null;
  }
}

/// [LinkOfflineDestination] for the download folder the settings choose:
/// Android's storage access tree in `saf` mode, else the download directory
/// (through its security-scoped bookmark on iOS), else `Documents/Mornye`.
class LinkDownloadFolderDestination implements LinkOfflineDestination {
  const LinkDownloadFolderDestination(this.settings);

  final AppSettings settings;

  @override
  Future<LinkOfflineStored> store(
    File file, {
    required String relativeDir,
    required String fileName,
    required String mimeType,
  }) async {
    if (Platform.isAndroid && settings.storageMode == 'saf') {
      final treeUri = settings.downloadTreeUri.trim();
      if (treeUri.isEmpty) throw const LinkOfflineNoFolder();
      final result = await PlatformBridge.createUniqueSafFileFromPath(
        treeUri: treeUri,
        relativeDir: relativeDir,
        fileName: fileName,
        mimeType: mimeType,
        srcPath: file.path,
      );
      final error = result['error']?.toString().trim() ?? '';
      if (error.isNotEmpty) throw FileSystemException(error);
      final uri = result['uri']?.toString().trim() ?? '';
      final name = result['file_name']?.toString().trim() ?? '';
      if (uri.isEmpty || name.isEmpty) {
        throw const FileSystemException('Failed to write to storage');
      }
      return LinkOfflineStored(
        filePath: uri,
        storageMode: 'saf',
        treeUri: treeUri,
        relativeDir: relativeDir,
        fileName: name,
      );
    }
    IosSecurityScopedAccess? access;
    try {
      var root = settings.downloadDirectory.trim();
      if (Platform.isIOS && settings.downloadDirectoryBookmark.isNotEmpty) {
        access = await PlatformBridge.startAccessingIosBookmark(
          settings.downloadDirectoryBookmark,
        );
        final resolved = access?.path.trim() ?? '';
        if (resolved.isEmpty) throw const LinkOfflineNoFolder();
        root = resolved;
      }
      if (root.isEmpty) {
        root = p.join(
          (await getApplicationDocumentsDirectory()).path,
          'Mornye',
        );
      }
      final directory = Directory(p.joinAll([root, ...relativeDir.split('/')]));
      await directory.create(recursive: true);
      final target = await CoverDownloadService.uniqueFilePath(
        directory.path,
        fileName,
      );
      await file.copy(target);
      return LinkOfflineStored(filePath: target, storageMode: 'app');
    } finally {
      if (access != null) await PlatformBridge.stopAccessingIosBookmark(access);
    }
  }
}
