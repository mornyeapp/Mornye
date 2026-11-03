import 'dart:io';

import 'package:mornye/services/cache_maintenance_service.dart';

/// Original Dart traversal retained for parity and paired performance checks.
Future<DirectoryStats> scanDirectoryReference(
  Directory directory, {
  bool followLinks = false,
}) async {
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

Future<void> createDirectoryStatsFixture(Directory root, int count) async {
  for (var folder = 0; folder < 10; folder++) {
    await Directory('${root.path}/$folder').create(recursive: true);
  }
  for (var i = 0; i < count; i++) {
    await File(
      '${root.path}/${i % 10}/file-$i',
    ).writeAsBytes(List.filled(i % 256, i % 256));
  }
}
