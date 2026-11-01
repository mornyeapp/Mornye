import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show listEquals;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import 'package:mornye/utils/logger.dart';

const _migrationKey = 'android_content_covers_v1';
final _legacyName = RegExp(r'^cover_[0-9a-f]{32}\.(jpg|png)$');

Future<void> migrateAndroidLibraryCovers(Database db) async {
  if (!Platform.isAndroid) return;
  try {
    final support = await getApplicationSupportDirectory();
    await migrateLibraryCoverPaths(
      db,
      Directory('${support.path}/library_covers'),
    );
  } catch (error) {
    AppLogger('LibraryDatabase').w('Could not migrate library artwork: $error');
  }
}

/// Publish before changing references. Legacy files remain owned by saved
/// playlists, sessions and history until the reference-based sweep releases them.
Future<int> migrateLibraryCoverPaths(Database db, Directory directory) async {
  final marker = await db.query(
    'library_state',
    columns: ['value'],
    where: 'key = ?',
    whereArgs: [_migrationKey],
  );
  if (marker.firstOrNull?['value'] == '1') return 0;
  if (!await directory.exists()) return 0;
  final root = await directory.resolveSymbolicLinks();
  var changed = 0;
  var complete = true;
  String? after;
  while (true) {
    final rows = await db.rawQuery(
      'SELECT id, cover_path FROM library '
      'WHERE cover_path IS NOT NULL '
      '${after == null ? '' : 'AND id > ? '}'
      'ORDER BY id LIMIT 256',
      [?after],
    );
    if (rows.isEmpty) break;
    final paths = rows
        .map((row) => row['cover_path'] as String)
        .toSet()
        .toList();
    final published = await _publishLegacyCoversOnWorker(root, paths);
    complete = complete && published.complete;
    await db.transaction((txn) async {
      for (final row in rows) {
        final old = row['cover_path'] as String;
        final path = published.paths[old];
        if (path == null) continue;
        changed += await txn.rawUpdate(
          'UPDATE library SET cover_path = ? WHERE id = ? AND cover_path = ?',
          [path, row['id'], old],
        );
      }
    });
    after = rows.last['id'] as String;
    if (rows.length < 256) break;
  }
  if (complete) {
    await db.insert('library_state', {
      'key': _migrationKey,
      'value': '1',
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }
  return changed;
}

Future<({Map<String, String> paths, bool complete})>
_publishLegacyCoversOnWorker(String root, List<String> paths) =>
    Isolate.run(() => _publishLegacyCovers(root, paths));

({Map<String, String> paths, bool complete}) _publishLegacyCovers(
  String root,
  List<String> paths,
) {
  final published = <String, String>{};
  var complete = true;
  for (final path in paths) {
    if (!_legacyName.hasMatch(p.basename(path))) continue;
    try {
      final parent = Directory(p.dirname(path));
      if (!parent.existsSync() || parent.resolveSymbolicLinksSync() != root) {
        continue;
      }
      final source = File(path);
      if (FileSystemEntity.typeSync(path, followLinks: false) !=
              FileSystemEntityType.file ||
          source.lengthSync() > 24 * 1024 * 1024) {
        continue;
      }
      final bytes = source.readAsBytesSync();
      if (bytes.isEmpty) {
        continue;
      }
      final extension =
          bytes.length >= 4 &&
              bytes[0] == 0x89 &&
              bytes[1] == 0x50 &&
              bytes[2] == 0x4e &&
              bytes[3] == 0x47
          ? '.png'
          : bytes.length >= 2 && bytes[0] == 0xff && bytes[1] == 0xd8
          ? '.jpg'
          : p.extension(path);
      final name = 'cover_content_${sha256.convert(bytes)}$extension';
      final output = File(p.join(root, name));
      if (output.existsSync()) {
        if (FileSystemEntity.typeSync(output.path, followLinks: false) !=
                FileSystemEntityType.file ||
            output.lengthSync() != bytes.length ||
            !listEquals(output.readAsBytesSync(), bytes)) {
          complete = false;
          continue;
        }
      } else {
        final stage = Directory(root).createTempSync('.cover-migration-');
        try {
          final file = File(p.join(stage.path, name));
          file.writeAsBytesSync(bytes, flush: true);
          file.renameSync(output.path);
        } finally {
          stage.deleteSync(recursive: true);
        }
      }
      published[path] = output.path;
    } on FileSystemException {
      complete = false;
    }
  }
  return (paths: published, complete: complete);
}
