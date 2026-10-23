import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:sqflite/sqflite.dart';
import 'package:mornye/providers/library_collections_provider.dart';
import 'package:mornye/services/library_collections_database.dart';
import 'package:mornye/services/collection_track_batch.dart';
import 'package:mornye/services/platform_bridge.dart';

import '../test/support/library_collections_benchmark.dart';
import '../test/support/playlist_batch_benchmark.dart';

// Redirect only persistence to a private fixture. The notifier and the existing
// per-track Love All operations run unchanged on the real platform SQLite.
class _Database implements LibraryCollectionsDatabase {
  _Database(this.owner);
  final Database owner;

  @override
  Future<void> upsertLovedEntry({
    required String trackKey,
    required String trackJson,
    required String addedAt,
  }) async {
    await owner.insert('loved_tracks', {
      'track_key': trackKey,
      'track_json': trackJson,
      'added_at': addedAt,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  @override
  Future<void> deleteLovedEntry(String trackKey) async {
    await owner.delete(
      'loved_tracks',
      where: 'track_key=?',
      whereArgs: [trackKey],
    );
  }

  @override
  Future<void> upsertLovedTracksBatch(List<Map<String, String>> rows) =>
      LibraryCollectionsDatabase.writeDatabaseLovedTracks(owner, rows);

  @override
  Future<void> deleteLovedTracks(List<String> keys) =>
      LibraryCollectionsDatabase.deleteDatabaseLovedTracks(owner, keys);

  @override
  Future<void> upsertLovedTracksFile({
    required String addedAt,
    required String rowsPath,
    required int expectedCount,
  }) => publishLovedBatch(
    database: owner,
    addedAt: addedAt,
    rowsPath: rowsPath,
    expectedCount: expectedCount,
  );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Collections extends LibraryCollectionsNotifier {
  _Collections({required super.database});

  @override
  LibraryCollectionsState build() => LibraryCollectionsState(isLoaded: true);
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final report = <String, dynamic>{
    'platform': Platform.operatingSystem,
    'note':
        'Five alternating pairs, real notifier and private SQLite. Heartbeat is not FPS.',
  };
  var completed = 0;
  tearDownAll(() {
    report['completed_cases'] = completed;
    binding.reportData ??= {};
    binding.reportData!['loved_batch'] = report;
  });

  for (final count in [2000, 3000]) {
    testWidgets('Love All paired add and remove on actual SQLite ($count)', (
      tester,
    ) async {
      final root = await Directory.systemTemp.createTemp('loved-batch-device-');
      final extensions = await Directory('${root.path}/extensions').create();
      final data = await Directory('${root.path}/data').create();
      final output = await Directory('${root.path}/output').create();
      await PlatformBridge.initExtensionSystem(
        extensions.path,
        data.path,
        masterKey: base64Encode(List<int>.filled(32, 1)),
        lyricsProviders: const [],
        lyricsFetchOptions: const {},
        allowedDirectories: [output.path],
      );
      expect(
        (await PlatformBridge.getBackendImplementations())['extensions'],
        'rust',
      );
      final db = await openDatabase(
        '${root.path}/collections.db',
        version: 2,
        onConfigure: (db) async {
          await db.execute('PRAGMA auto_vacuum=INCREMENTAL');
          await db.execute('PRAGMA recursive_triggers=ON');
          await db.rawQuery('PRAGMA journal_mode=WAL');
          await db.execute('PRAGMA synchronous=NORMAL');
          await db.rawQuery('PRAGMA busy_timeout=5000');
        },
        onCreate: (db, _) async {
          await db.execute(
            'CREATE TABLE loved_tracks(track_key TEXT PRIMARY KEY,track_json TEXT NOT NULL,added_at TEXT NOT NULL)',
          );
          await db.execute(
            'CREATE INDEX idx_loved_tracks_added_at ON loved_tracks(added_at DESC)',
          );
        },
      );
      final tracks = await playlistBatchFixture(count);
      final baseline = <Map<String, dynamic>>[];
      final optimized = <Map<String, dynamic>>[];
      try {
        for (var sample = 0; sample < 5; sample++) {
          for (final candidate
              in sample.isEven ? [false, true] : [true, false]) {
            final container = ProviderContainer(
              overrides: [
                libraryCollectionsProvider.overrideWith(
                  () => _Collections(database: _Database(db)),
                ),
              ],
            );
            try {
              final notifier = container.read(
                libraryCollectionsProvider.notifier,
              );
              var publications = 0;
              container.listen(
                libraryCollectionsProvider,
                (_, _) => publications++,
              );
              final add = await measureCollectionOperation(() async {
                if (candidate) {
                  expect(await notifier.toggleLovedTracks(tracks), (
                    removed: false,
                    count: count,
                  ));
                  return;
                }
                for (final track in tracks) {
                  await notifier.toggleLoved(track);
                }
              });
              final state = container.read(libraryCollectionsProvider);
              expect(
                state.loved.map((entry) => entry.track.id),
                tracks.reversed.map((track) => track.id),
              );
              expect(publications, candidate ? 1 : tracks.length);
              expect(
                Sqflite.firstIntValue(
                  await db.rawQuery('SELECT COUNT(*) FROM loved_tracks'),
                ),
                tracks.length,
              );
              final rows = await db.rawQuery(
                'SELECT track_key,track_json,added_at FROM loved_tracks ORDER BY added_at DESC,rowid DESC',
              );
              expect(
                rows.map((row) => row['track_key']),
                state.loved.map((entry) => entry.key),
              );
              for (var index = 0; index < rows.length; index++) {
                expect(
                  rows[index]['track_json'],
                  jsonEncode(state.loved[index].track.toJson()),
                );
                expect(
                  rows[index]['added_at'],
                  state.loved[index].addedAt.toIso8601String(),
                );
              }
              publications = 0;
              final remove = await measureCollectionOperation(() async {
                if (candidate) {
                  expect(await notifier.toggleLovedTracks(tracks), (
                    removed: true,
                    count: count,
                  ));
                  return;
                }
                for (final track in tracks) {
                  await notifier.toggleLoved(track);
                }
              });
              expect(container.read(libraryCollectionsProvider).loved, isEmpty);
              expect(await db.rawQuery('SELECT * FROM loved_tracks'), isEmpty);
              expect(publications, candidate ? 1 : tracks.length);
              (candidate ? optimized : baseline).add({
                'add': add.timing,
                'remove': remove.timing,
                'publications_per_operation': publications,
              });
            } finally {
              container.dispose();
            }
          }
        }
        report['$count'] = {'baseline': baseline, 'optimized': optimized};
        completed++;
      } finally {
        await db.close();
        await PlatformBridge.cleanupExtensions();
        await root.delete(recursive: true);
      }
    });
  }
}
