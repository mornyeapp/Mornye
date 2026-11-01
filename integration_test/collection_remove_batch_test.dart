import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:sqflite/sqflite.dart';
import 'package:mornye/providers/library_collections_provider.dart';
import 'package:mornye/services/library_collections_database.dart';

import '../test/support/library_collections_benchmark.dart';
import '../test/support/playlist_batch_benchmark.dart';

class _Database implements LibraryCollectionsDatabase {
  _Database(this.owner);
  final Database owner;

  @override
  Future<void> deleteWishlistTracks(List<String> keys) =>
      LibraryCollectionsDatabase.deleteDatabaseWishlistTracks(owner, keys);

  @override
  Future<void> deleteLovedTracks(List<String> keys) =>
      LibraryCollectionsDatabase.deleteDatabaseLovedTracks(owner, keys);

  @override
  Future<void> deletePlaylistTracks({
    required String playlistId,
    required List<String> trackKeys,
    required String playlistUpdatedAt,
  }) => LibraryCollectionsDatabase.deleteDatabasePlaylistTracks(
    owner,
    playlistId: playlistId,
    trackKeys: trackKeys,
    playlistUpdatedAt: playlistUpdatedAt,
  );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Collections extends LibraryCollectionsNotifier {
  _Collections(this._initial, {required super.database});
  final LibraryCollectionsState _initial;
  @override
  LibraryCollectionsState build() => _initial;
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final report = <String, dynamic>{
    'platform': Platform.operatingSystem,
    'note':
        'Five alternating pairs, real production notifier and private platform SQLite. Heartbeat is not FPS.',
  };
  var completed = 0;
  late Directory root;
  late Database db;
  final now = DateTime.utc(2026);
  final stamp = now.toIso8601String();
  setUp(() async {
    root = await Directory.systemTemp.createTemp('collection-remove-device-');
    db = await openDatabase(
      '${root.path}/collections.db',
      version: 2,
      onConfigure: (db) async {
        await db.execute('PRAGMA foreign_keys=ON');
        await db.execute('PRAGMA recursive_triggers=ON');
        await db.rawQuery('PRAGMA journal_mode=WAL');
        await db.execute('PRAGMA synchronous=NORMAL');
        await db.rawQuery('PRAGMA busy_timeout=5000');
      },
      onCreate: (db, _) async {
        for (final table in ['wishlist_tracks', 'loved_tracks']) {
          await db.execute(
            'CREATE TABLE $table(track_key TEXT PRIMARY KEY,track_json TEXT NOT NULL,added_at TEXT NOT NULL)',
          );
          await db.execute(
            'CREATE INDEX idx_${table}_added_at ON $table(added_at DESC)',
          );
        }
        await db.execute(
          'CREATE TABLE playlists(id TEXT PRIMARY KEY,name TEXT NOT NULL,cover_image_path TEXT,created_at TEXT NOT NULL,updated_at TEXT NOT NULL)',
        );
        await db.execute(
          'CREATE TABLE playlist_tracks(playlist_id TEXT NOT NULL,track_key TEXT NOT NULL,track_json TEXT NOT NULL,added_at TEXT NOT NULL,PRIMARY KEY(playlist_id,track_key),FOREIGN KEY(playlist_id) REFERENCES playlists(id) ON DELETE CASCADE)',
        );
        await db.execute(
          'CREATE INDEX idx_playlist_tracks_playlist_id ON playlist_tracks(playlist_id)',
        );
      },
    );
  });
  tearDown(() async {
    await db.close();
    await root.delete(recursive: true);
  });
  tearDownAll(() {
    report['completed_cases'] = completed;
    binding.reportData ??= {};
    binding.reportData!['collection_removal'] = report;
  });

  Future<LibraryCollectionsState> seed(int count) async {
    final tracks = await playlistBatchFixture(count + 1);
    final prepared = inlinePlaylistBatch(tracks, {}, now);
    await db.transaction((txn) async {
      final batch = txn.batch();
      for (final table in [
        'playlist_tracks',
        'playlists',
        'wishlist_tracks',
        'loved_tracks',
      ]) {
        batch.delete(table);
      }
      for (final id in ['p', 'other']) {
        batch.insert('playlists', {
          'id': id,
          'name': id,
          'cover_image_path': 'cover',
          'created_at': stamp,
          'updated_at': stamp,
        });
      }
      for (final row in prepared.rows) {
        batch.insert('wishlist_tracks', row);
        batch.insert('loved_tracks', row);
        batch.insert('playlist_tracks', {'playlist_id': 'p', ...row});
      }
      for (final row in prepared.rows.take(2)) {
        batch.insert('playlist_tracks', {'playlist_id': 'other', ...row});
      }
      await batch.commit(noResult: true);
    });
    return LibraryCollectionsState(
      isLoaded: true,
      wishlist: prepared.entries.reversed.toList(),
      loved: prepared.entries.reversed.toList(),
      playlists: [
        for (final id in ['p', 'other'])
          UserPlaylistCollection(
            id: id,
            name: id,
            coverImagePath: 'cover',
            createdAt: now,
            updatedAt: now,
            tracks: id == 'p'
                ? prepared.entries
                : prepared.entries.take(2).toList(),
          ),
      ],
    );
  }

  ProviderContainer container(LibraryCollectionsState state) =>
      ProviderContainer(
        overrides: [
          libraryCollectionsProvider.overrideWith(
            () => _Collections(state, database: _Database(db)),
          ),
        ],
      );

  Future<int> remove(
    LibraryCollectionsNotifier notifier,
    String kind,
    List<String> keys,
  ) => switch (kind) {
    'wishlist' => notifier.removeWishlistTracks(keys),
    'loved' => notifier.removeLovedTracks(keys),
    _ => notifier.removeTracksFromPlaylist('p', keys),
  };

  for (final kind in ['wishlist', 'loved', 'playlist']) {
    testWidgets('remove 2000 $kind tracks in one selection', (tester) async {
      final samples = <String, List<Map<String, int>>>{
        'per_track': [],
        'batch': [],
      };
      for (var pair = 0; pair < 5; pair++) {
        for (final candidate in pair.isEven ? [false, true] : [true, false]) {
          final initial = await seed(2000);
          final owner = container(initial);
          try {
            final notifier = owner.read(libraryCollectionsProvider.notifier);
            final keys = [
              for (var index = 0; index < 2000; index++) 'example:$index',
            ];
            var publications = 0;
            owner.listen(libraryCollectionsProvider, (_, _) => publications++);
            final measured = await measureCollectionOperation(() async {
              if (candidate) {
                expect(await remove(notifier, kind, keys), 2000);
              } else {
                for (final key in keys) {
                  await remove(notifier, kind, [key]);
                }
              }
            });
            expect(publications, candidate ? 1 : 2000);
            final state = owner.read(libraryCollectionsProvider);
            final remaining = switch (kind) {
              'wishlist' => state.wishlist,
              'loved' => state.loved,
              _ => state.playlistById('p')!.tracks,
            };
            expect(remaining.single.key, 'example:2000');
            expect(remaining.single.addedAt, now);
            expect(
              state.playlistById('other'),
              same(initial.playlistById('other')),
            );
            for (final table in ['wishlist_tracks', 'loved_tracks']) {
              expect(
                Sqflite.firstIntValue(
                  await db.rawQuery('SELECT COUNT(*) FROM $table'),
                ),
                table == '${kind}_tracks' ? 1 : 2001,
              );
            }
            expect(
              Sqflite.firstIntValue(
                await db.rawQuery(
                  "SELECT COUNT(*) FROM playlist_tracks WHERE playlist_id='other'",
                ),
              ),
              2,
            );
            expect(
              Sqflite.firstIntValue(
                await db.rawQuery(
                  "SELECT COUNT(*) FROM playlist_tracks WHERE playlist_id='p'",
                ),
              ),
              kind == 'playlist' ? 1 : 2001,
            );
            final rows = await db.query(
              '${kind}_tracks',
              where: kind == 'playlist' ? 'playlist_id=?' : null,
              whereArgs: kind == 'playlist' ? ['p'] : null,
            );
            expect(
              rows.single['track_json'],
              jsonEncode(remaining.single.track.toJson()),
            );
            expect(rows.single['added_at'], stamp);
            expect(
              (await db.query(
                'playlists',
                where: 'id=?',
                whereArgs: ['p'],
              )).single['updated_at'],
              state.playlistById('p')!.updatedAt.toIso8601String(),
            );
            samples[candidate ? 'batch' : 'per_track']!.add({
              ...measured.timing,
              'publications': publications,
            });
          } finally {
            owner.dispose();
          }
        }
      }
      report[kind] = samples;
      completed++;
    });

    testWidgets('$kind rollback retains state and retry succeeds', (
      tester,
    ) async {
      final initial = await seed(300);
      final owner = container(initial);
      try {
        final notifier = owner.read(libraryCollectionsProvider.notifier);
        var publications = 0;
        owner.listen(libraryCollectionsProvider, (_, _) => publications++);
        await db.execute(
          "CREATE TRIGGER reject_delete BEFORE DELETE ON ${kind}_tracks WHEN old.track_key='example:150' BEGIN SELECT RAISE(ABORT,'denied'); END",
        );
        final keys = [for (var i = 0; i < 300; i++) 'example:$i'];
        await expectLater(
          remove(notifier, kind, keys),
          throwsA(isA<DatabaseException>()),
        );
        expect(owner.read(libraryCollectionsProvider), same(initial));
        expect(publications, 0);
        expect(
          Sqflite.firstIntValue(
            await db.rawQuery(
              'SELECT COUNT(*) FROM ${kind}_tracks${kind == 'playlist' ? " WHERE playlist_id='p'" : ''}',
            ),
          ),
          301,
        );
        await db.execute('DROP TRIGGER reject_delete');
        expect(await remove(notifier, kind, keys), 300);
        expect(publications, 1);
        expect(await db.rawQuery('PRAGMA foreign_key_check'), isEmpty);
        completed++;
      } finally {
        owner.dispose();
      }
    });
  }
}
