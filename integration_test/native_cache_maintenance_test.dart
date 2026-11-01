import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:sqflite/sqflite.dart';
import 'package:mornye/services/library_cleanup.dart';
import 'package:mornye/services/library_schema.dart';
import 'package:mornye/services/native_cache_maintenance.dart';
import 'package:mornye/utils/cache_byte_budget.dart';

Future<File> _payload(
  Directory directory,
  String name, {
  bool recent = false,
}) async {
  final file = await File(
    '${directory.path}/$name',
  ).writeAsBytes(List.filled(100, 0));
  if (!recent) await file.setLastModified(DateTime(2020));
  return file;
}

Future<Database> _library(String path) => openDatabase(
  path,
  version: LibrarySchema.version,
  singleInstance: false,
  onConfigure: (db) async {
    await db.rawQuery('PRAGMA journal_mode=WAL');
  },
  onCreate: (db, version) async {
    await LibrarySchema.create(db, version);
  },
);

Future<void> _reference(Database db, String id, String path) => db
    .insert('library', {
      'id': id,
      'track_name': 'Track $id',
      'artist_name': 'Artist',
      'album_name': 'Album',
      'file_path': '/music/$id.flac',
      'cover_path': path,
      'scanned_at': '2026-10-07T00:00:00.000Z',
    })
    .then((_) {});

Future<void> _createPayloads(String path, int count) => Isolate.run(() {
  final directory = Directory(path)..createSync(recursive: true);
  final bytes = List.filled(1024, 1);
  for (var index = 0; index < count; index++) {
    File('${directory.path}/cover-$index.jpg')
      ..writeAsBytesSync(bytes)
      ..setLastModifiedSync(DateTime(2020));
  }
});

Future<void> _restoreOrphans(String path) => Isolate.run(() {
  final bytes = List.filled(1024, 1);
  for (var index = 4000; index < 5000; index++) {
    File('$path/cover-$index.jpg')
      ..writeAsBytesSync(bytes)
      ..setLastModifiedSync(DateTime(2020));
  }
});

Future<int> _originalDartPrune(String path, Set<String> references) async {
  final retained = {...references};
  for (final reference in references) {
    try {
      retained.add(await File(reference).resolveSymbolicLinks());
    } on FileSystemException {
      /* stale reference */
    }
  }
  var deleted = 0;
  await for (final entity in Directory(
    path,
  ).list(recursive: true, followLinks: false)) {
    if (entity is! File || retained.contains(entity.path)) continue;
    try {
      if (retained.contains(await entity.resolveSymbolicLinks())) continue;
      await entity.delete();
      deleted++;
    } on FileSystemException {
      /* best effort */
    }
  }
  return deleted;
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('native-cache-maintenance-');
  });
  tearDown(() => root.delete(recursive: true));

  testWidgets(
    'production byte-budget route retains metadata, active files and symlinks',
    (tester) async {
      final cache = await Directory('${root.path}/cache').create();
      final oldest = await _payload(cache, 'oldest');
      final newer = await _payload(cache, 'newer');
      await newer.setLastModified(DateTime(2021));
      final active = await _payload(cache, 'active', recent: true);
      final metadata = await _payload(cache, 'metadata.json');
      final outside = await _payload(root, 'outside');
      await Link('${cache.path}/outside-link').create(outside.path);
      expect(
        await trimCacheToByteBudget(cache, maxBytes: 350, targetBytes: 150),
        0,
      );
      expect(
        await trimCacheToByteBudget(cache, maxBytes: 250, targetBytes: 150),
        2,
      );
      expect(await oldest.exists(), false);
      expect(await newer.exists(), false);
      expect(await active.exists(), true);
      expect(await metadata.exists(), true);
      expect(await outside.length(), 100);
      expect(await Link('${cache.path}/outside-link').exists(), true);
    },
  );

  testWidgets(
    'production pruning retains all source references, aliases and recent uncommitted covers',
    (tester) async {
      final covers = await Directory('${root.path}/covers').create();
      final alias = await Link('${root.path}/alias').create(covers.path);
      final canonical = await _payload(covers, 'canonical.jpg');
      final legacy = await _payload(covers, 'legacy.jpg');
      final stale = await _payload(covers, 'stale.jpg');
      final active = await _payload(
        covers,
        'awaiting-reference.jpg',
        recent: true,
      );
      final outside = await _payload(root, 'outside.jpg');
      await Link('${covers.path}/outside-link.jpg').create(outside.path);
      final db = await _library('${root.path}/local_library.db');
      try {
        await _reference(
          db,
          'canonical',
          await canonical.resolveSymbolicLinks(),
        );
        await _reference(db, 'legacy', '${alias.path}/legacy.jpg');
        // Invisibility must never make a source's artwork an orphan.
        await db.update('library_sources', {'enabled': 0, 'available': 0});
        expect(
          await pruneUnreferencedLibraryCovers(
            Directory(alias.path),
            {},
            referenceColumns: const [],
            libraryDatabase: db,
            temporaryDirectory: root,
            minimumAge: const Duration(minutes: 1),
          ),
          1,
        );
        expect(await canonical.exists(), true);
        expect(await legacy.exists(), true);
        expect(await stale.exists(), false);
        expect(await active.exists(), true);
        expect(await outside.length(), 100);
        expect(
          Sqflite.firstIntValue(
            await db.rawQuery('SELECT COUNT(*) FROM library'),
          ),
          2,
        );
        expect(await db.rawQuery('PRAGMA integrity_check'), [
          {'integrity_check': 'ok'},
        ]);
        expect(
          (await db.rawQuery('PRAGMA database_list')).map((row) => row['name']),
          unorderedEquals(['main', 'temp']),
        );
        expect(
          await root
              .list()
              .where(
                (entry) => entry.path
                    .split('/')
                    .last
                    .startsWith('library-cover-snapshot-'),
              )
              .toList(),
          isEmpty,
        );
      } finally {
        await db.close();
      }
    },
  );

  testWidgets(
    'private native sweep retains source writer barrier and releases it after maintenance',
    (tester) async {
      final covers = await Directory('${root.path}/barrier-covers').create();
      final retained = await _payload(covers, 'retained.jpg');
      final orphan = await _payload(covers, 'orphan.jpg');
      final db = await _library('${root.path}/local_library.db');
      final writer = await openDatabase(
        db.path,
        singleInstance: false,
        onConfigure: (db) async => db.rawQuery('PRAGMA busy_timeout=1'),
      );
      try {
        await _reference(db, 'retained', retained.path);
        var nativeCalls = 0;
        expect(
          await pruneUnreferencedLibraryCovers(
            covers,
            const {},
            referenceColumns: const [],
            libraryDatabase: db,
            temporaryDirectory: root,
            minimumAge: const Duration(minutes: 1),
            nativeJobRunner: (request, {requestId}) async {
              nativeCalls++;
              final privatePath = request['library_path'] as String;
              expect(privatePath, isNot(db.path));
              expect(await File(privatePath).exists(), true);
              await expectLater(
                _reference(
                  writer,
                  'during-sweep',
                  '${covers.path}/waiting.jpg',
                ),
                throwsA(isA<DatabaseException>()),
              );
              return (await runNativeCacheMaintenance(
                request,
                requestId: requestId,
              ))!;
            },
          ),
          1,
        );
        expect(nativeCalls, 1);
        expect(await retained.exists(), true);
        expect(await orphan.exists(), false);
        await _reference(writer, 'after-sweep', '${covers.path}/waiting.jpg');
        expect(await db.rawQuery('PRAGMA integrity_check'), [
          {'integrity_check': 'ok'},
        ]);
        expect(
          Sqflite.firstIntValue(
            await db.rawQuery('SELECT COUNT(*) FROM library'),
          ),
          2,
        );
      } finally {
        await writer.close();
        await db.close();
      }
    },
  );

  testWidgets(
    '5000-file pruning benchmark preserves 4000 referenced covers and UI heartbeat',
    (tester) async {
      final covers = await Directory('${root.path}/benchmark-covers').create();
      await _createPayloads(covers.path, 5000);
      final db = await _library('${root.path}/local_library.db');
      try {
        final batch = db.batch();
        for (var index = 0; index < 4000; index++) {
          batch.insert('library', {
            'id': 'track-$index',
            'track_name': 'Track $index',
            'artist_name': 'Artist',
            'album_name': 'Album',
            'file_path': '/music/$index.flac',
            'cover_path': '${covers.path}/cover-$index.jpg',
            'scanned_at': '2026-10-07T00:00:00.000Z',
          });
        }
        await batch.commit(noResult: true);
        final dartTimes = <double>[];
        final nativeTimes = <double>[];
        final nativeHeartbeatGaps = <int>[];
        for (var sample = 0; sample < 7; sample++) {
          for (final native in sample.isEven ? [false, true] : [true, false]) {
            await _restoreOrphans(covers.path);
            final stopwatch = Stopwatch()..start();
            var lastTick = stopwatch.elapsedMicroseconds;
            final gaps = <int>[];
            final heartbeat = Timer.periodic(const Duration(milliseconds: 10), (
              _,
            ) {
              final now = stopwatch.elapsedMicroseconds;
              gaps.add(now - lastTick);
              lastTick = now;
            });
            int deleted;
            try {
              if (native) {
                deleted = await pruneUnreferencedLibraryCovers(
                  covers,
                  {},
                  referenceColumns: const [],
                  libraryDatabase: db,
                  temporaryDirectory: root,
                );
              } else {
                final references = <String>{};
                for (var offset = 0; ; offset += 500) {
                  final rows = await db.query(
                    'library',
                    columns: ['cover_path'],
                    limit: 500,
                    offset: offset,
                  );
                  if (rows.isEmpty) break;
                  references.addAll(
                    rows.map((row) => row['cover_path'] as String),
                  );
                }
                deleted = await _originalDartPrune(covers.path, references);
              }
            } finally {
              gaps.add(stopwatch.elapsedMicroseconds - lastTick);
              stopwatch.stop();
              heartbeat.cancel();
            }
            expect(deleted, 1000);
            (native ? nativeTimes : dartTimes).add(
              stopwatch.elapsedMicroseconds / 1000,
            );
            if (native) nativeHeartbeatGaps.addAll(gaps);
            expect(await File('${covers.path}/cover-0.jpg').length(), 1024);
            expect(await File('${covers.path}/cover-3999.jpg').length(), 1024);
            final remainingNames = await covers
                .list()
                .map((file) => file.path.split('/').last)
                .toSet();
            expect(remainingNames, {
              for (var index = 0; index < 4000; index++) 'cover-$index.jpg',
            });
          }
        }
        final remaining = await covers.list().length;
        expect(remaining, 4000);
        binding.reportData ??= {};
        binding.reportData!['cache_maintenance'] = {
          'cache_prune_benchmark': {
            'files': 5000,
            'references': 4000,
            'deleted_per_run': 1000,
            'dart_ms': dartTimes,
            'native_ms': nativeTimes,
            'native_heartbeat_max_gap_us': nativeHeartbeatGaps.isEmpty
                ? null
                : (nativeHeartbeatGaps..sort()).last,
            'remaining_files': remaining,
          },
        };
      } finally {
        await db.close();
      }
    },
  );
}
