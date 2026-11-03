import 'dart:io';
import 'dart:isolate';

import 'package:flutter/services.dart';
import 'package:mornye/services/platform_bridge.dart';

class DirectoryStats {
  final int fileCount;
  final int totalSizeBytes;

  const DirectoryStats({required this.fileCount, required this.totalSizeBytes});
}

/// Directory sizing and clearing for the cache management page.
abstract final class CacheMaintenanceService {
  static Future<DirectoryStats> scanDirectory(
    Directory directory, {
    bool followLinks = false,
  }) async {
    final path = directory.absolute.path;
    final Map<String, dynamic> result;
    try {
      result = await PlatformBridge.runNativeDataJob({
        'operation': 'directory_stats',
        'path': path,
        'follow_links': followLinks,
      });
    } on MissingPluginException {
      return Isolate.run(() => _scanDirectoryFallback(path, followLinks));
    }
    final fileCount = result['file_count'];
    final totalSize = result['total_size_bytes'];
    if (fileCount is! int ||
        fileCount < 0 ||
        totalSize is! int ||
        totalSize < 0) {
      throw StateError('Invalid native directory statistics');
    }
    return DirectoryStats(fileCount: fileCount, totalSizeBytes: totalSize);
  }

  static Future<DirectoryStats> _scanDirectoryFallback(
    String path,
    bool followLinks,
  ) async {
    final directory = Directory(path);
    if (!await directory.exists()) {
      return const DirectoryStats(fileCount: 0, totalSizeBytes: 0);
    }

    var fileCount = 0;
    var totalSize = 0;

    try {
      await for (final entity in directory.list(
        recursive: true,
        followLinks: followLinks,
      )) {
        if (entity is File) {
          fileCount++;
          totalSize += await entity.length();
        }
      }
    } catch (_) {}

    return DirectoryStats(fileCount: fileCount, totalSizeBytes: totalSize);
  }

  static Future<void> clearDirectoryContents(String path) async {
    final directory = Directory(path);
    if (!await directory.exists()) return;

    try {
      final entities = <FileSystemEntity>[];
      await for (final entity in directory.list(followLinks: false)) {
        entities.add(entity);
      }

      const deleteChunkSize = 24;
      for (var i = 0; i < entities.length; i += deleteChunkSize) {
        final end = (i + deleteChunkSize < entities.length)
            ? i + deleteChunkSize
            : entities.length;
        final chunk = entities.sublist(i, end);
        await Future.wait(
          chunk.map((entity) async {
            try {
              await entity.delete(recursive: true);
            } catch (_) {}
          }),
        );
      }
    } catch (_) {}

    try {
      await directory.create(recursive: true);
    } catch (_) {}
  }
}
