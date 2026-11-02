import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:mornye/models/library_database_models.dart';
import 'package:mornye/models/unified_library_item.dart';
import 'package:mornye/services/folder_path_template.dart';
import 'package:mornye/services/link/features/link_save_offline.dart';
import 'package:mornye/services/network_storage_service.dart';

String networkOfflineHistoryId(String origin) =>
    'offline_${sha256.convert(utf8.encode('network/$origin'))}';

bool canSaveNetworkOfflineSource(String source) {
  final uri = Uri.tryParse(source);
  return uri?.scheme == 'network' &&
      uri!.host.isNotEmpty &&
      uri.userInfo.isEmpty &&
      !uri.hasPort &&
      !uri.hasQuery &&
      !uri.hasFragment &&
      NetworkStorageService.instance.virtualFor(uri.host) == null;
}

/// A stable origin, never title/artist matching. Download history supplies the
/// preferred local copy while the scanned server row remains independently owned.
String? networkOfflineOrigin(UnifiedLibraryItem item) {
  final origin = item.historyItem?.originFilePath ?? item.filePath;
  return canSaveNetworkOfflineSource(origin) ? origin : null;
}

List<LinkOfflineSong> networkOfflineSongs(Iterable<UnifiedLibraryItem> items) {
  final origins = <String>{};
  return [
    for (final item in items)
      if (networkOfflineOrigin(item) case final origin?)
        if (origins.add(origin))
          LinkOfflineSong(
            songId: origin,
            item:
                item.localItem ??
                LocalLibraryItem.fromJson({
                  ...item.historyItem!.toJson(),
                  'id': 'network_${sha256.convert(utf8.encode(origin))}',
                  'filePath': origin,
                  'coverPath': item.coverUrl ?? item.localCoverPath,
                  'scannedAt': item.addedAt.toIso8601String(),
                }),
          ),
  ];
}

/// Relative paths are decoded once by Uri, then sanitized component by
/// component. A server path must never escape the selected download folder.
({String relativeDir, String fileName}) networkOfflineLayout(
  LocalLibraryItem item,
  String? path,
) {
  if (path == null || path.trim().isEmpty) {
    return (
      relativeDir: LinkOfflineSaver.relativeDirFor(item),
      fileName: LinkOfflineSaver.fileNameFor(item),
    );
  }
  final parts = path
      .replaceAll('\\', '/')
      .split('/')
      .where((part) => part.isNotEmpty)
      .toList();
  if (parts.isEmpty || parts.any((part) => part == '.' || part == '..')) {
    throw const FormatException('Invalid original file path');
  }
  final safe = parts.map(FolderPathTemplate.sanitizeComponent).toList();
  return (
    relativeDir: safe.take(safe.length - 1).join('/'),
    fileName: safe.last,
  );
}

class NetworkOfflineTransport implements LinkOfflineTransport {
  NetworkOfflineTransport({NetworkStorageService? storage})
    : downloadFile = NetworkFileDownload(
        storage ?? NetworkStorageService.instance,
      );

  final NetworkFileDownload downloadFile;

  Future<LinkOfflineSong> prepare(LinkOfflineSong song) async {
    final path = await downloadFile.originalPath(song.songId);
    final layout = networkOfflineLayout(song.item, path);
    return LinkOfflineSong(
      item: song.item,
      songId: song.songId,
      relativeDir: layout.relativeDir,
      fileName: layout.fileName,
    );
  }

  @override
  Future<void> download(
    String songId,
    File output, {
    required void Function() checkpoint,
    required void Function(int received, int? total) progress,
  }) => downloadFile.download(
    songId,
    output,
    checkpoint: checkpoint,
    progress: progress,
  );

  @override
  void close() => downloadFile.close();
}
