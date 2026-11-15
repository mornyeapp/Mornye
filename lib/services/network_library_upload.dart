import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:mornye/models/library_database_models.dart';
import 'package:mornye/models/unified_library_item.dart';
import 'package:mornye/services/folder_path_template.dart';
import 'package:mornye/services/link/features/link_save_offline.dart';
import 'package:mornye/services/lyrics_sidecar.dart';
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

  /// The folders under the chosen folder, as the download folder settings
  /// arrange a download of the song; empty for the chosen folder itself.
  final String relativeDir;
  final String fileName;
}

/// The songs of [items] stored on this device, once each by file.
List<UnifiedLibraryItem> networkUploadItems(
  Iterable<UnifiedLibraryItem> items,
) {
  final paths = <String>{};
  return [
    for (final item in items)
      if (canUploadLibraryItem(item) && paths.add(item.filePath)) item,
  ];
}

/// The uploadable songs of [items], once each by file, each in the folder
/// [folderFor] gives it: where the download folder settings put a download
/// of it, so the copies are laid out like the songs on this device.
Future<List<NetworkUploadSong>> networkUploadSongs(
  Iterable<UnifiedLibraryItem> items, {
  required Future<String> Function(UnifiedLibraryItem item) folderFor,
}) async => [
  for (final item in networkUploadItems(items))
    NetworkUploadSong(
      path: item.filePath,
      title: item.trackName,
      relativeDir: await folderFor(item),
      fileName: networkUploadFileName(item),
    ),
];

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
    this.readDocumentLyrics = _readDocumentLyrics,
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

  /// The `.lrc` text beside an Android document, which has no file path.
  final Future<String?> Function(String uri) readDocumentLyrics;

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

  /// A `.lrc` beside the file goes along, as network downloads do; it is
  /// optional, so a lyrics failure leaves the song uploaded. An Android
  /// document's sidecar is read through its storage access into a
  /// temporary file first.
  Future<void> _publishLyrics(
    NetworkUploadSong song,
    String target,
    void Function() checkpoint,
  ) async {
    Directory? temporary;
    try {
      final File lyrics;
      final String transferId;
      if (isContentUri(song.path)) {
        final text = await readDocumentLyrics(song.path);
        checkpoint();
        if (text == null || text.trim().isEmpty) return;
        temporary = await Directory.systemTemp.createTemp('mornye-upload-');
        lyrics = File(p.join(temporary.path, 'lyrics.lrc'));
        await lyrics.writeAsString(text);
        transferId = 'library/${song.path}.lrc';
      } else {
        lyrics = File(p.setExtension(song.path, '.lrc'));
        if (!await lyrics.exists()) return;
        transferId = 'library/${lyrics.path}';
      }
      final uri = Uri.parse(target);
      await publish(
        NetworkStorageService.source(
          uri.host,
          p.posix.setExtension(uri.pathSegments.join('/'), '.lrc'),
        ),
        lyrics,
        transferId,
        checkpoint: checkpoint,
        progress: (_, _) {},
      );
    } on _Cancelled {
      rethrow;
    } on Object {
      // Kept local only; never replaces a remote file of that name.
    } finally {
      try {
        await temporary?.delete(recursive: true);
      } on Object {
        // A leftover temporary copy is not worth failing the song.
      }
    }
  }
}

Future<String?> _readDocumentLyrics(String uri) =>
    const LyricsSidecarStore(extension: lrcExtension).read(uri);
