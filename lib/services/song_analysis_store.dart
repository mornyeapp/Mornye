import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:sqflite/sqflite.dart';
import 'package:mornye/services/song_features.dart';
import 'package:mornye/services/sqlite_helpers.dart' as sqlite;

/// A file's size in bytes and modification time in milliseconds; -1 where the
/// platform cannot tell, such as a document provider's size.
typedef SongFileStamp = ({int size, int modified});

/// What the store knows about one file, without its features.
class SongAnalysisRecord {
  const SongAnalysisRecord({
    required this.stamp,
    required this.version,
    required this.failed,
  });

  /// The file as it was when analyzed.
  final SongFileStamp stamp;
  final int version;

  /// The file could not be described. It is tried again only once it
  /// changes or the analysis version does.
  final bool failed;
}

/// How each analyzed song sounds, by file path, in a small database of its
/// own. Rows carry the file's stamp and the analysis version, so changed
/// files and older analyses are told apart.
class SongAnalysisStore {
  SongAnalysisStore({
    Future<Database> Function()? open,
    this.version = SongFeatures.version,
  }) : _openDatabase = open;

  /// The analysis version this store reads and writes.
  final int version;
  final Future<Database> Function()? _openDatabase;
  final _database = sqlite.SingleFlightInitializer<Database>();

  static const _schemaVersion = 1;
  // Below SQLite's default limit of 999 variables on older Android.
  static const _chunk = 450;

  Future<Database> _open() => _database.getOrCreate(
    _openDatabase ??
        () => sqlite.openAppDatabase(
          'song_analysis.db',
          version: _schemaVersion,
          onCreate: _create,
          onUpgrade: _upgrade,
        ),
  );

  static Future<void> _create(Database db, int version) => db.execute('''
    CREATE TABLE song_features (
      path TEXT PRIMARY KEY NOT NULL,
      size INTEGER NOT NULL,
      modified INTEGER NOT NULL,
      version INTEGER NOT NULL,
      features BLOB,
      analyzed_at INTEGER NOT NULL
    ) WITHOUT ROWID
  ''');

  static Future<void> _upgrade(Database db, int oldVersion, int _) async {}

  /// Opens [path] with this schema through [factory], for host tests that
  /// use FFI.
  @visibleForTesting
  static Future<Database> openWithFactory(
    DatabaseFactory factory,
    String path,
  ) => factory.openDatabase(
    path,
    options: OpenDatabaseOptions(
      version: _schemaVersion,
      onCreate: _create,
      onUpgrade: _upgrade,
    ),
  );

  /// Runs [query] over [paths] in chunks small enough for one statement.
  Future<void> _chunked(
    Iterable<String> paths,
    Future<void> Function(Database db, List<String> chunk, String marks) query,
  ) async {
    final values = paths.where((path) => path.isNotEmpty).toSet().toList();
    if (values.isEmpty) return;
    final db = await _open();
    for (var start = 0; start < values.length; start += _chunk) {
      final chunk = values.sublist(start, min(start + _chunk, values.length));
      await query(db, chunk, List.filled(chunk.length, '?').join(','));
    }
  }

  /// The features of those [paths] this version described.
  Future<Map<String, Float32List>> features(Iterable<String> paths) async {
    final result = <String, Float32List>{};
    await _chunked(paths, (db, chunk, marks) async {
      final rows = await db.rawQuery(
        'SELECT path, features FROM song_features '
        'WHERE version = ? AND features IS NOT NULL AND path IN ($marks)',
        [version, ...chunk],
      );
      for (final row in rows) {
        final features = SongFeatures.decode(row['features']);
        if (features != null) result[row['path'] as String] = features;
      }
    });
    return result;
  }

  /// The records of [paths], or of every stored file without them.
  Future<Map<String, SongAnalysisRecord>> records([
    Iterable<String>? paths,
  ]) async {
    final result = <String, SongAnalysisRecord>{};
    void add(List<Map<String, Object?>> rows) {
      for (final row in rows) {
        result[row['path'] as String] = SongAnalysisRecord(
          stamp: (size: row['size'] as int, modified: row['modified'] as int),
          version: row['version'] as int,
          failed: row['failed'] == 1,
        );
      }
    }

    const columns =
        'SELECT path, size, modified, version, features IS NULL AS failed '
        'FROM song_features';
    if (paths == null) {
      add(await (await _open()).rawQuery(columns));
      return result;
    }
    await _chunked(paths, (db, chunk, marks) async {
      add(await db.rawQuery('$columns WHERE path IN ($marks)', chunk));
    });
    return result;
  }

  /// Stores [features] for [path], or a failed attempt when null.
  Future<void> save(
    String path,
    SongFileStamp stamp,
    Float32List? features,
  ) async {
    await (await _open()).insert('song_features', {
      'path': path,
      'size': stamp.size,
      'modified': stamp.modified,
      'version': version,
      'features': features == null ? null : SongFeatures.encode(features),
      'analyzed_at': DateTime.now().millisecondsSinceEpoch,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> remove(Iterable<String> paths) => _chunked(
    paths,
    (db, chunk, marks) =>
        db.rawDelete('DELETE FROM song_features WHERE path IN ($marks)', chunk),
  );

  Future<void> clear() async {
    final db = await _open();
    await db.delete('song_features');
    // The database opens with incremental auto-vacuum; return the space.
    await db.rawQuery('PRAGMA incremental_vacuum');
  }
}
