import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:sqflite/sqflite.dart';
import 'package:mornye/models/library_database_models.dart';
import 'package:mornye/services/library_cleanup.dart';
import 'package:mornye/utils/file_access.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/sqlite_process_database.dart';

// Records the paging/compare-and-delete contract without requiring a device DB.
class _CleanupDatabase implements Database, Transaction {
  final rows = <String, Map<String, Object?>>{};
  final keys = <String>{};
  final limits = <int?>[];
  int transactions = 0;
  void add(String id, String path, {String source = 'source'}) {
    rows[id] = {'id': id, 'file_path': path, 'source_id': source};
    keys.add(id);
  }

  @override
  Future<List<Map<String, Object?>>> query(
    String table, {
    bool? distinct,
    List<String>? columns,
    String? where,
    List<Object?>? whereArgs,
    String? groupBy,
    String? having,
    String? orderBy,
    int? limit,
    int? offset,
  }) async {
    expect(offset, isNull);
    limits.add(limit);
    var argsIndex = 0;
    final source = where?.contains('source_id = ?') == true
        ? whereArgs![argsIndex++]
        : null;
    final upper = where?.contains('id <= ?') == true
        ? whereArgs![argsIndex++] as String
        : null;
    final after = where?.contains('id > ?') == true
        ? whereArgs![argsIndex++] as String
        : null;
    final result =
        rows.values.where((row) {
            final id = row['id'] as String;
            return (source == null || row['source_id'] == source) &&
                (upper == null || id.compareTo(upper) <= 0) &&
                (after == null || id.compareTo(after) > 0);
          }).toList()
          ..sort((a, b) => (a['id'] as String).compareTo(b['id'] as String));
    final sorted = orderBy == 'id DESC' ? result.reversed : result;
    return sorted
        .take(limit!)
        .map((row) => {for (final key in columns!) key: row[key]})
        .toList();
  }

  @override
  Future<T> transaction<T>(
    Future<T> Function(Transaction txn) action, {
    bool? exclusive,
  }) {
    transactions++;
    return action(this);
  }

  @override
  Future<int> rawDelete(String sql, [List<Object?>? arguments]) async {
    expect(sql, contains('id = ? AND file_path = ?'));
    final hasSource = sql.contains('source_id = ?');
    final count = arguments!.length - (hasSource ? 1 : 0);
    final ids = <String>[];
    for (var i = 0; i < count; i += 2) {
      final id = arguments[i] as String;
      final row = rows[id];
      if (row != null &&
          row['file_path'] == arguments[i + 1] &&
          (!hasSource || row['source_id'] == arguments.last)) {
        ids.add(id);
      }
    }
    for (final id in ids) {
      if (sql.startsWith('DELETE FROM library_path_keys')) {
        keys.remove(id);
      } else {
        rows.remove(id);
      }
    }
    return ids.length;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.zarz.mornye/backend');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test(
    'native pruning reads a detached projection without transferring reference lists',
    () async {
      final directory = await Directory.systemTemp.createTemp('native-prune-');
      addTearDown(() => directory.delete(recursive: true));
      final databasePath = '${directory.path}/local_library.db';
      final database = await SqliteProcessDatabase.open(path: databasePath);
      addTearDown(database.close);
      await database.execute('CREATE TABLE library (cover_path TEXT)');
      await database.execute("INSERT INTO library VALUES ('retained.jpg')");
      final deleted = await pruneUnreferencedLibraryCovers(
        directory,
        {'not-transferred'},
        referenceColumns: const [],
        libraryDatabase: database,
        temporaryDirectory: directory,
        requestId: 'scan-lease',
        minimumAge: const Duration(minutes: 1),
        nativeJobRunner: (request, {requestId}) async {
          expect(requestId, 'scan-lease');
          final snapshotPath = request['library_path'] as String;
          expect(snapshotPath, isNot(databasePath));
          expect(snapshotPath, endsWith('/local_library.db'));
          expect(await File(snapshotPath).exists(), true);
          expect(request, {
            'operation': 'cache_prune_library',
            'directory': directory.absolute.path,
            'library_path': snapshotPath,
            'minimum_age_us': 60000000,
          });
          return {
            'deleted': 2,
            'errors': <String>[],
            'error_count': 0,
            'committed': true,
            'cancelled': true,
          };
        },
      );
      expect(deleted, 2);
    },
  );

  test(
    'clearing library covers makes the next scan extract local covers again',
    () async {
      final root = await Directory.systemTemp.createTemp('clear-covers-');
      addTearDown(() => root.delete(recursive: true));
      // Settings clears the Dart spelling of the folder, while scans store
      // their own: a canonical alias target (older Android) or backslashes.
      final canonical = await Directory('${root.path}/data').create();
      final alias = await Link('${root.path}/user').create(canonical.path);
      final covers = await Directory('${alias.path}/library_covers').create();
      final stored = '${canonical.path}/library_covers';
      await File('${covers.path}/cover_a.jpg').writeAsBytes([1]);
      await File('${covers.path}/network_cover_b.image').writeAsBytes([2]);
      final database = await SqliteProcessDatabase.open(
        path: '${root.path}/local_library.db',
      );
      addTearDown(database.close);
      await database.execute(
        'CREATE TABLE library (id TEXT PRIMARY KEY, file_path TEXT, '
        'cover_path TEXT, file_mod_time INTEGER, '
        'audio_metadata_scan_version INTEGER)',
      );
      for (final (id, path, cover, version) in [
        ('local', '/music/a.flac', '$stored/cover_a.jpg', 4),
        ('saf', 'content://tree/b.flac', '${covers.path}/cover_b.png', 4),
        (
          'windows',
          r'C:\Music\f.flac',
          r'\\?\C:\Users\me\AppData\Roaming\mornye\library_covers\cover_f.jpg',
          4,
        ),
        ('network', 'network://nas/b.flac', '$stored/x.image', 4),
        ('download', '/music/c.flac', '${root.path}/downloads/c.jpg', 4),
        ('named', '/music/d.flac', null, 0),
        ('sibling', '/music/e.flac', '${stored}_old/e.jpg', 4),
      ]) {
        await database.rawInsert(
          'INSERT INTO library VALUES (?, ?, ?, 1000, ?)',
          [id, path, cover, version],
        );
      }

      expect(await clearLibraryCoverFiles(covers, database), 3);

      expect(await covers.list().toList(), isEmpty);
      final rows = await database.rawQuery(
        'SELECT id, file_mod_time, audio_metadata_scan_version FROM library',
      );
      expect(
        {
          for (final row in rows)
            row['id']: libraryIncrementalSnapshotModTime(
              storedModTime: row['file_mod_time'] as int,
              storedScanVersion: row['audio_metadata_scan_version'] as int,
            ),
        },
        {
          'local': -1,
          'saf': -1,
          'windows': -1,
          'network': 1000,
          'download': 1000,
          'named': -1,
          'sibling': 1000,
        },
      );
      // Lyrics filters treat a marked song as before.
      expect(
        rows.where(
          (row) =>
              (row['audio_metadata_scan_version'] as int) <
              libraryLyricsMetadataScanVersion,
        ),
        [
          {
            'id': 'named',
            'file_mod_time': 1000,
            'audio_metadata_scan_version': 0,
          },
        ],
      );
    },
  );

  test(
    'cover cleanup retains recent payloads awaiting a DB reference',
    () async {
      final directory = await Directory.systemTemp.createTemp('recent-prune-');
      addTearDown(() => directory.delete(recursive: true));
      final active = await File('${directory.path}/active').writeAsBytes([1]);
      final stale = await File('${directory.path}/stale').writeAsBytes([2]);
      await stale.setLastModified(DateTime(2020));
      expect(
        await pruneUnreferencedLibraryCovers(
          directory,
          {},
          referenceColumns: const [],
          minimumAge: const Duration(minutes: 1),
        ),
        1,
      );
      expect(await active.exists(), true);
      expect(await stale.exists(), false);
    },
  );

  test(
    'cover cleanup preserves references through directory aliases',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'library-cover-cleanup-',
      );
      addTearDown(() => root.delete(recursive: true));
      final directory = await Directory('${root.path}/covers').create();
      final alias = await Link('${root.path}/alias').create(directory.path);
      final canonical = await File(
        '${directory.path}/canonical.jpg',
      ).writeAsBytes([1]);
      final legacy = await File(
        '${directory.path}/legacy.jpg',
      ).writeAsBytes([2]);
      final orphan = await File(
        '${directory.path}/orphan.jpg',
      ).writeAsBytes([3]);
      final outside = await File('${root.path}/outside.jpg').writeAsBytes([4]);
      await Link('${directory.path}/outside.jpg').create(outside.path);

      final deleted =
          await pruneUnreferencedLibraryCovers(Directory(alias.path), {
            await canonical.resolveSymbolicLinks(),
            '${alias.path}/legacy.jpg',
            '${alias.path}/already-missing.jpg',
          }, referenceColumns: const []);

      expect(await canonical.exists(), isTrue);
      expect(await legacy.exists(), isTrue);
      expect(await orphan.exists(), isFalse);
      expect(await outside.readAsBytes(), [4]);
      expect(deleted, 1);
    },
  );

  test(
    'cleanup pages without skipping after deletions and preserves unknown',
    () async {
      final db = _CleanupDatabase();
      for (var i = 0; i < 700; i++) {
        db.add(i.toString().padLeft(4, '0'), 'file-$i');
      }
      db.add('other', 'file-other', source: 'other');
      final checked = <String>[];
      final removed = await cleanupMissingLibraryRows(
        db,
        sourceId: 'source',
        checkPaths: (paths) async {
          expect(paths.length, lessThanOrEqualTo(256));
          checked.addAll(paths);
          return {
            for (final path in paths)
              path: switch (int.parse(path.split('-').last) % 3) {
                0 => false,
                1 => true,
                _ => null,
              },
          };
        },
      );
      expect(checked.length, 700);
      expect(checked.toSet().length, 700);
      expect(removed, 234);
      expect(db.rows.length, 467);
      expect(db.keys, db.rows.keys.toSet());
      expect(db.rows.containsKey('other'), isTrue);
      expect(db.limits.first, 1);
      expect(db.limits.skip(1), everyElement(256));
    },
  );

  test(
    'cleanup retains repaired paths, newly added rows and unavailable sources',
    () async {
      final db = _CleanupDatabase()
        ..add('a', 'old')
        ..add('b', 'missing');
      final removed = await cleanupMissingLibraryRows(
        db,
        checkPaths: (paths) async {
          db.add('a', 'repaired');
          db.add('z', 'new-row');
          return {for (final path in paths) path: false};
        },
      );
      expect(removed, 1);
      expect(db.keys, {'a', 'z'});
      expect(
        await cleanupMissingLibraryRows(
          db,
          canDelete: () async => false,
          checkPaths: (paths) async => {for (final path in paths) path: false},
        ),
        0,
      );
      expect(
        await cleanupMissingLibraryRows(
          db,
          checkPaths: (_) async => throw const FileSystemException('offline'),
        ),
        0,
      );
      expect(db.keys, {'a', 'z'});
    },
  );

  test(
    'SAF probes use bounded batches and preserve unknown or failed results',
    () async {
      final batches = <List<String>>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'safExistsBatch');
        final paths =
            (jsonDecode((call.arguments as Map)['uris_json'] as String) as List)
                .cast<String>();
        batches.add(paths);
        if (batches.length == 2) {
          throw PlatformException(code: 'permission-denied');
        }
        return jsonEncode({
          for (final path in paths)
            path: path.endsWith('/0')
                ? 'missing'
                : path.endsWith('/1')
                ? 'unknown'
                : 'found',
        });
      });
      final paths = List.generate(140, (i) => 'content://test/$i');
      final results = await fileExistenceByPath([
        ...paths,
        '${paths.first}#track01',
      ]);
      expect(batches.map((batch) => batch.length), [64, 64, 12]);
      expect(results[paths[0]], isFalse);
      expect(results['${paths.first}#track01'], isFalse);
      expect(results[paths[1]], isNull);
      expect(results[paths[64]], isNull);
      expect(results[paths.last], isTrue);
    },
  );

  test(
    'local probes distinguish present and missing files and keep empty paths unknown',
    () async {
      final dir = await Directory.systemTemp.createTemp('cleanup_probes_');
      addTearDown(() => dir.delete(recursive: true));
      final file = await File('${dir.path}/album.cue').writeAsString('test');
      final absent = '${dir.path}/missing.flac';
      final result = await fileExistenceByPath([
        file.path,
        '${file.path}#track01',
        absent,
        '',
      ]);
      expect(result[file.path], isTrue);
      expect(result['${file.path}#track01'], isTrue);
      expect(result[absent], isFalse);
      expect(result[''], isNull);
    },
  );
}
