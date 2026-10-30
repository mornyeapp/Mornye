import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:mornye/services/sync/sync_storage_driver.dart';
import 'package:mornye/utils/logger.dart';

final _log = AppLogger('LocalFolderSyncDriver');

/// Sync driver operating directly on a local filesystem directory.
///
/// Used on desktop platforms to synchronize directly to a local or mounted directory
/// (such as a local directory or virtual drive mount).
/// Direct local file I/O provides fast writes and zero network overhead.
class LocalFolderSyncDriver implements SyncStorageDriver {
  LocalFolderSyncDriver(String rootPath) : rootPath = p.normalize(rootPath);

  final String rootPath;

  String _resolve(String relativePath) {
    final clean = relativePath.replaceAll('/', Platform.pathSeparator);
    return p.join(rootPath, clean);
  }

  @override
  Future<bool> isAvailable() async {
    try {
      final dir = Directory(rootPath);
      if (await dir.exists()) return true;
      // If parent drive or folder exists, check writability
      final parent = dir.parent;
      return await parent.exists();
    } catch (e) {
      _log.w('Local storage path $rootPath unavailable: $e');
      return false;
    }
  }

  @override
  Future<List<SyncFileEntry>> listFiles(String path) async {
    final target = Directory(_resolve(path));
    if (!await target.exists()) return const [];

    final entries = <SyncFileEntry>[];
    await for (final entity in target.list(followLinks: false)) {
      final name = p.basename(entity.path);
      // Skip incomplete atomic write temporary files
      if (name.endsWith('.tmp') || name.startsWith('.')) continue;

      final isDir = entity is Directory;
      int? size;
      int? modTime;
      String? etag;

      try {
        final stat = await entity.stat();
        modTime = stat.modified.millisecondsSinceEpoch;
        if (!isDir) {
          size = stat.size;
          etag = '"${stat.size}_$modTime"';
        }
      } catch (_) {}

      entries.add(
        SyncFileEntry(
          path: p.relative(entity.path, from: rootPath).replaceAll('\\', '/'),
          name: name,
          isDirectory: isDir,
          size: size,
          modifiedTime: modTime,
          etag: etag,
        ),
      );
    }
    return entries;
  }

  @override
  Future<SyncFileEntry?> stat(String path) async {
    final full = _resolve(path);
    final entityType = await FileSystemEntity.type(full);
    if (entityType == FileSystemEntityType.notFound) return null;

    final stat = await FileStat.stat(full);
    final isDir = entityType == FileSystemEntityType.directory;
    final modTime = stat.modified.millisecondsSinceEpoch;
    final size = isDir ? null : stat.size;
    final etag = isDir ? null : '"${stat.size}_$modTime"';

    return SyncFileEntry(
      path: path.replaceAll('\\', '/'),
      name: p.basename(full),
      isDirectory: isDir,
      size: size,
      modifiedTime: modTime,
      etag: etag,
    );
  }

  @override
  Future<Uint8List> readFile(String path) async {
    final file = File(_resolve(path));
    return file.readAsBytes();
  }

  @override
  Future<String> readText(String path) async {
    final bytes = await readFile(path);
    return utf8.decode(bytes, allowMalformed: true);
  }

  @override
  Future<void> writeFile(
    String path,
    Uint8List data, {
    bool overwrite = true,
  }) async {
    final full = _resolve(path);
    final targetFile = File(full);
    if (!overwrite && await targetFile.exists()) {
      throw StateError(
        'Target file $path already exists and overwrite is false',
      );
    }

    await targetFile.parent.create(recursive: true);

    // Atomic staging write: write to a .tmp file then copy in-place with retry loop.
    // Overwriting in-place avoids deleting the file first, which creates transient 404
    // windows on rclone virtual drives and causes WebDAV clients to miss files.
    final tmpPath = '$full.${DateTime.now().microsecondsSinceEpoch}.tmp';
    final tmpFile = File(tmpPath);
    await tmpFile.writeAsBytes(data, flush: true);

    var retries = 5;
    while (retries > 0) {
      try {
        await tmpFile.copy(full);
        try {
          await tmpFile.delete();
        } catch (_) {}
        return;
      } catch (e) {
        retries--;
        if (retries == 0) {
          rethrow;
        }
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }
  }

  @override
  Future<void> writeText(
    String path,
    String text, {
    bool overwrite = true,
  }) async {
    await writeFile(
      path,
      Uint8List.fromList(utf8.encode(text)),
      overwrite: overwrite,
    );
  }

  @override
  Future<void> deleteFile(String path) async {
    final file = File(_resolve(path));
    if (await file.exists()) {
      await file.delete();
    }
  }

  @override
  Future<void> deleteDirectory(String path) async {
    final dir = Directory(_resolve(path));
    if (await dir.exists()) {
      await dir.delete(recursive: true);
    }
  }

  @override
  Future<void> createDirectory(String path) async {
    final dir = Directory(_resolve(path));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
  }
}
