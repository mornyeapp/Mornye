import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:mornye/models/library_database_models.dart';
import 'package:mornye/models/unified_library_item.dart';
import 'package:mornye/services/folder_path_template.dart';
import 'package:mornye/services/link/features/link_save_offline.dart';
import 'package:mornye/services/network_storage_service.dart';
import 'package:mornye/services/platform_bridge.dart';
import 'package:mornye/utils/file_access.dart'
    show deleteFileQuietly, isContentUri, isCueVirtualPath;

/// Whether [item] is a file on this device that can be copied to network
/// storage: a path or an Android content URI. Network and Link songs already
/// live on a server, an offline copy came from one, and a CUE track is only a
/// range of its album file.
bool canUploadLibraryItem(UnifiedLibraryItem item) {
  final path = item.filePath;
  return path.isNotEmpty &&
      (isContentUri(path) || !path.contains('://')) &&
      !isCueVirtualPath(path) &&
      item.historyItem?.originFilePath == null;
}

/// Whether [folder] is a `network://` folder of a saved connection that
/// accepts writes (SMB or WebDAV).
bool canUploadToNetworkFolder(
  String folder,
  Iterable<NetworkConnection> connections,
) {
  final uri = Uri.tryParse(folder);
  if (uri == null ||
      uri.scheme != 'network' ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasPort ||
      uri.hasQuery ||
      uri.hasFragment ||
      (uri.path.isNotEmpty && !uri.path.endsWith('/'))) {
    return false;
  }
  return connections.any((c) => c.id == uri.host && c.writable);
}

/// One Library file and where it goes under the chosen folder.
class NetworkUploadSong {
  const NetworkUploadSong({
    required this.path,
    required this.title,
    required this.relativeDir,
    required this.fileName,
  });

  /// A path, or a `content://` URI under Android's storage access.
  final String path;
  final String title;

  /// `Album Artist/Album`, as Save offline and the default download layout
  /// name folders.
  final String relativeDir;
  final String fileName;
}

/// The uploadable songs of [items], once each by file.
List<NetworkUploadSong> networkUploadSongs(Iterable<UnifiedLibraryItem> items) {
  final paths = <String>{};
  return [
    for (final item in items)
      if (canUploadLibraryItem(item) && paths.add(item.filePath))
        NetworkUploadSong(
          path: item.filePath,
          title: item.trackName,
          relativeDir: networkUploadRelativeDir(item),
          fileName: networkUploadFileName(item),
        ),
  ];
}

String networkUploadRelativeDir(UnifiedLibraryItem item) {
  final albumArtist =
      item.localItem?.albumArtist ?? item.historyItem?.albumArtist;
  final artist = albumArtist?.trim().isNotEmpty ?? false
      ? albumArtist!
      : item.artistName;
  final album = item.albumName.trim();
  return [
    FolderPathTemplate.sanitizeComponent(artist),
    if (album.isNotEmpty) FolderPathTemplate.sanitizeComponent(album),
  ].join('/');
}

/// The file's own name, so the copy matches the original. A content URI's
/// name comes from its download record or its document id, else the default
/// `Title - Artist.ext`.
String networkUploadFileName(UnifiedLibraryItem item) {
  final path = item.filePath;
  String? name;
  if (!isContentUri(path)) {
    name = p.basename(path);
  } else if (item.historyItem?.safFileName case final saf?
      when saf.trim().isNotEmpty) {
    name = saf;
  } else {
    final segment = Uri.tryParse(path)?.pathSegments.lastOrNull;
    name = segment?.split(RegExp(r'[/:]')).last;
  }
  if (name != null && name.trim().isNotEmpty && p.extension(name).length > 1) {
    final extension = p.extension(name);
    final stem = FolderPathTemplate.sanitizeComponent(
      p.basenameWithoutExtension(name),
    );
    return '$stem$extension';
  }
  return LinkOfflineSaver.fileNameFor(
    item.localItem ??
        LocalLibraryItem(
          id: item.id,
          trackName: item.trackName,
          artistName: item.artistName,
          albumName: item.albumName,
          filePath: path,
          scannedAt: item.addedAt,
          format: item.historyItem?.format,
        ),
  );
}

/// The enabled network Library sources that hold any of [uploaded], which a
/// rescan brings up to date.
List<String> networkUploadSourcesToRescan(
  Iterable<LocalLibrarySource> sources,
  Iterable<String> uploaded,
) => [
  for (final source in sources)
    if (source.enabled &&
        source.path.startsWith('network://') &&
        uploaded.any(
          (target) => target.startsWith(
            source.path.endsWith('/') ? source.path : '${source.path}/',
          ),
        ))
      source.id,
];

/// A readable copy of a Library file; [release] removes a temporary copy.
class NetworkUploadFile {
  const NetworkUploadFile(this.file, this.release);
  final File file;
  final Future<void> Function() release;
}

/// Content URIs are copied to a temporary file first, as the other file
/// actions on Android's storage access do.
Future<NetworkUploadFile> openNetworkUploadFile(String path) async {
  if (isContentUri(path)) {
    final temp = await PlatformBridge.copyContentUriToTemp(path);
    if (temp == null) {
      throw FileSystemException('Library file could not be read', path);
    }
    final file = File(temp);
    return NetworkUploadFile(file, () => deleteFileQuietly(file));
  }
  final file = File(path);
  if (!await file.exists()) {
    throw FileSystemException('Library file is missing', path);
  }
  return NetworkUploadFile(file, () async {});
}

/// The chosen folder is not a writable network connection.
class NetworkUploadReadOnly implements Exception {
  const NetworkUploadReadOnly();

  @override
  String toString() => 'NetworkUploadReadOnly: connection is not writable';
}

class NetworkUploadResult extends LinkOfflineResult {
  const NetworkUploadResult({
    required super.saved,
    required super.failed,
    required super.cancelled,
    super.skipped,
    this.uploaded = const [],
  });

  /// The `network://` sources of the files written.
  final List<String> uploaded;
}

class _Cancelled implements Exception {
  const _Cancelled();
}

typedef NetworkUploadPublish =
    Future<void> Function(
      String target,
      File file,
      String transferId, {
      required void Function() checkpoint,
      required void Function(int sent, int total) progress,
    });

/// Copies Library files to a network folder, never replacing a remote file:
/// a name already there counts as skipped, and the transfer itself publishes
/// with a non-overwriting rename.
class NetworkLibraryUploader {
  NetworkLibraryUploader({
    required this.connections,
    required this.prepare,
    required this.publish,
    this.openFile = openNetworkUploadFile,
  });

  final Future<List<NetworkConnection>> Function() connections;

  /// The target source of a new file, or null when the name is taken.
  final Future<String?> Function(
    String folder,
    String relativeDir,
    String fileName,
  )
  prepare;
  final NetworkUploadPublish publish;
  final Future<NetworkUploadFile> Function(String path) openFile;

  Future<NetworkUploadResult> upload(
    List<NetworkUploadSong> songs, {
    required String folder,
    LinkOfflineCancel? cancel,
    void Function(LinkOfflineProgress progress)? onProgress,
  }) async {
    if (!canUploadToNetworkFolder(folder, await connections())) {
      throw const NetworkUploadReadOnly();
    }
    void checkpoint() {
      if (cancel?.cancelled ?? false) throw const _Cancelled();
    }

    var saved = 0, skipped = 0, failed = 0;
    final uploaded = <String>[];
    for (final song in songs) {
      if (cancel?.cancelled ?? false) break;
      final done = saved + skipped + failed;
      onProgress?.call(
        LinkOfflineProgress(done: done, total: songs.length, title: song.title),
      );
      NetworkUploadFile? local;
      try {
        final target = await prepare(folder, song.relativeDir, song.fileName);
        checkpoint();
        if (target == null) {
          skipped++;
          continue;
        }
        local = await openFile(song.path);
        checkpoint();
        await publish(
          target,
          local.file,
          'library/${song.path}',
          checkpoint: checkpoint,
          progress: (sent, total) => onProgress?.call(
            LinkOfflineProgress(
              done: done,
              total: songs.length,
              title: song.title,
              received: sent,
              size: total,
            ),
          ),
        );
        saved++;
        uploaded.add(target);
        await _publishLyrics(song, target, checkpoint);
      } on Object {
        if (cancel?.cancelled ?? false) break;
        failed++;
      } finally {
        try {
          await local?.release();
        } on Object {
          // A leftover temporary copy is not worth failing the song.
        }
      }
    }
    return NetworkUploadResult(
      saved: saved,
      skipped: skipped,
      failed: failed,
      cancelled: cancel?.cancelled ?? false,
      uploaded: uploaded,
    );
  }

  /// A `.lrc` beside a plain file goes along, as network downloads do; it is
  /// optional, so a lyrics failure leaves the song uploaded.
  Future<void> _publishLyrics(
    NetworkUploadSong song,
    String target,
    void Function() checkpoint,
  ) async {
    if (isContentUri(song.path)) return;
    final lyrics = File(p.setExtension(song.path, '.lrc'));
    try {
      if (!await lyrics.exists()) return;
      final uri = Uri.parse(target);
      await publish(
        NetworkStorageService.source(
          uri.host,
          p.posix.setExtension(uri.pathSegments.join('/'), '.lrc'),
        ),
        lyrics,
        'library/${lyrics.path}',
        checkpoint: checkpoint,
        progress: (_, _) {},
      );
    } on _Cancelled {
      rethrow;
    } on Object {
      // Kept local only; never replaces a remote file of that name.
    }
  }
}
