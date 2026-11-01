import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:sqflite/sqflite.dart';
import 'package:mornye/models/ffmpeg_models.dart';
import 'package:mornye/services/library_database.dart';
import 'package:mornye/services/library_row_mapper.dart';
import 'package:mornye/services/platform_bridge.dart';
import 'package:mornye/services/sqlite_helpers.dart' as sqlite;
import 'package:mornye/utils/file_access.dart';

/// Publishes a complete split and its visibility rule in one transaction.
/// Original rows stay indexed for playlists and can return if outputs disappear.
class CueSplitLibraryService {
  CueSplitLibraryService({
    Future<Database> Function()? database,
    Future<Map<String, dynamic>?> Function(String)? readMetadata,
    Future<FileAccessStat?> Function(String)? stat,
  }) : _database = database ?? (() => LibraryDatabase.instance.database),
       _readMetadata = readMetadata ?? PlatformBridge.readAudioMetadata,
       _stat = stat ?? fileStat;

  final Future<Database> Function() _database;
  final Future<Map<String, dynamic>?> Function(String) _readMetadata;
  final Future<FileAccessStat?> Function(String) _stat;

  Future<void> publish({
    required String cuePath,
    required String audioPath,
    required List<CueSplitTrackInfo> tracks,
    required List<String> outputPaths,
    String sourceId = LocalLibraryItem.legacySourceId,
  }) async {
    if (tracks.isEmpty ||
        tracks.length != outputPaths.length ||
        outputPaths.toSet().length != tracks.length ||
        cuePath.isEmpty ||
        audioPath.isEmpty) {
      throw StateError('CUE split is incomplete');
    }
    final originals = {
      cuePath,
      audioPath,
      for (final track in tracks) ...[
        '$cuePath#track${track.number}',
        '$cuePath#track${track.number.toString().padLeft(2, '0')}',
      ],
    };
    final rows = <Map<String, dynamic>>[];
    for (final path in outputPaths) {
      if (path.isEmpty || originals.contains(path) || isCueVirtualPath(path)) {
        throw StateError('CUE split output overlaps its source');
      }
      final stat = await _stat(path);
      if (stat == null || (!isContentUri(path) && (stat.size ?? 0) <= 0)) {
        throw StateError('CUE split output is unavailable');
      }
      final metadata = await _readMetadata(path);
      if (metadata == null ||
          metadata['error'] != null ||
          metadata['metadataFromFilename'] == true ||
          (metadata['id'] as String? ?? '').isEmpty) {
        throw StateError('CUE split output could not be indexed');
      }
      rows.add({
        ...metadata,
        // Match Android's SAF scanner, since metadata can use a reused file
        // descriptor or temporary copy as its ID instead of the document URI.
        'id': isContentUri(path)
            ? 'lib_${sha1.convert(utf8.encode(path))}'
            : metadata['id'],
        'filePath': path,
        'fileModTime': stat.modified?.millisecondsSinceEpoch,
        'scannedAt': DateTime.now().toUtc().toIso8601String(),
      });
    }
    final db = await _database();
    await sqlite.transactionWithBusyRetry(db, (txn) async {
      final batch = txn.batch();
      for (final row in rows) {
        batch.insert(
          'library',
          LibraryRowMapper.encode(row, sourceId: sourceId),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
        batch.delete(
          'library_path_keys',
          where: 'item_id = ?',
          whereArgs: [row['id']],
        );
        sqlite.putPathKeysInBatch(
          batch,
          'library_path_keys',
          row['id'] as String,
          row['filePath'] as String,
        );
      }
      for (final table in const [
        'library_cue_split_sources',
        'library_cue_split_outputs',
      ]) {
        batch.delete(table, where: 'cue_path = ?', whereArgs: [cuePath]);
      }
      for (final path in originals) {
        batch.insert('library_cue_split_sources', {
          'file_path': path,
          'cue_path': cuePath,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
      for (final path in outputPaths) {
        batch.insert('library_cue_split_outputs', {
          'file_path': path,
          'cue_path': cuePath,
        });
      }
      await batch.commit(noResult: true);
    });
  }
}
