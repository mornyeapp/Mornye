import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:sqflite/sqflite.dart';
import 'package:mornye/providers/library_collections_provider.dart';

import '../test/support/library_collections_benchmark.dart';
import '../test/support/playlist_deletion_fixture.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final report = <String, dynamic>{
    'platform': Platform.operatingSystem,
    'note':
        'Five alternating pairs of actual notifier calls on private platform SQLite with FK cascades. Playlists retain lazy track membership. Timings include deletion and state publication, not seeding or assertions; heartbeat is not FPS.',
  };
  var completed = 0;
  late Directory root;
  late Database db;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('playlist-deletion-');
    db = await openDatabase('${root.path}/collections.db');
    await createPlaylistDeletionSchema(db);
  });
  tearDown(() async {
    await db.close();
    await root.delete(recursive: true);
  });
  tearDownAll(() {
    report['completed_cases'] = completed;
    binding.reportData ??= {};
    binding.reportData!['playlist_deletion'] = report;
  });

  ProviderContainer scope(LibraryCollectionsState state) => ProviderContainer(
    overrides: [
      libraryCollectionsProvider.overrideWith(
        () => PlaylistDeletionCollections(state, db),
      ),
    ],
  );

  for (final count in [20, 200]) {
    testWidgets('delete $count playlists with 20 shared tracks each', (
      tester,
    ) async {
      final samples = <String, List<Map<String, int>>>{
        'single': [],
        'batch': [],
      };
      final ids = [for (var i = 0; i < count; i++) 'playlist-$i'];
      for (var pair = 0; pair < 5; pair++) {
        for (final bulk in pair.isEven ? [false, true] : [true, false]) {
          final initial = await seedPlaylistDeletion(db, count);
          final before = await playlistDeletionSnapshot(db);
          final container = scope(initial);
          try {
            final notifier = container.read(
              libraryCollectionsProvider.notifier,
            );
            var publications = 0;
            container.listen(
              libraryCollectionsProvider,
              (_, _) => publications++,
            );
            final result = await measureCollectionOperation<int>(() async {
              if (bulk) return notifier.deletePlaylists(ids);
              for (final id in ids) {
                await notifier.deletePlaylists([id]);
              }
              return count;
            });
            expect(result.value, count);
            expect(publications, bulk ? 1 : count);
            final state = container.read(libraryCollectionsProvider);
            expect(state.playlists.single, same(initial.playlists.last));
            expect(state.playlists.single.tracksLoaded, false);
            expect(state.playlists.single.trackCount, 20);
            expect(state.loved, initial.loved);
            expect(state.wishlist, initial.wishlist);
            final after = await playlistDeletionSnapshot(db);
            expect(
              after['playlists'],
              before['playlists']!.where((p) => p['id'] == "keep'quoted"),
            );
            expect(
              after['playlist_tracks'],
              before['playlist_tracks']!.where(
                (p) => p['playlist_id'] == "keep'quoted",
              ),
            );
            for (final table in ['wishlist_tracks', 'loved_tracks']) {
              expect(after[table], before[table]);
            }
            expect(await db.rawQuery('PRAGMA foreign_key_check'), isEmpty);
            samples[bulk ? 'batch' : 'single']!.add({
              ...result.timing,
              'publications': publications,
            });
          } finally {
            container.dispose();
          }
        }
      }
      report['playlists_$count'] = samples;
      completed++;
    });
  }

  for (final cascade in [false, true]) {
    testWidgets(
      'failed ${cascade ? 'child' : 'parent'} deletion rolls back all chunks',
      (tester) async {
        final initial = await seedPlaylistDeletion(
          db,
          300,
          tracksPerPlaylist: 2,
        );
        final before = await playlistDeletionSnapshot(db);
        final container = scope(initial);
        try {
          final notifier = container.read(libraryCollectionsProvider.notifier);
          var publications = 0;
          container.listen(
            libraryCollectionsProvider,
            (_, _) => publications++,
          );
          final table = cascade ? 'playlist_tracks' : 'playlists';
          final column = cascade ? 'playlist_id' : 'id';
          await db.execute(
            "CREATE TRIGGER reject_delete BEFORE DELETE ON $table WHEN old.$column='playlist-150' BEGIN SELECT RAISE(ABORT,'denied'); END",
          );
          final ids = [for (var i = 0; i < 300; i++) 'playlist-$i'];
          await expectLater(
            notifier.deletePlaylists(ids),
            throwsA(isA<DatabaseException>()),
          );
          expect(container.read(libraryCollectionsProvider), same(initial));
          expect(publications, 0);
          expect(await playlistDeletionSnapshot(db), before);
          await db.execute('DROP TRIGGER reject_delete');
          expect(await notifier.deletePlaylists(ids), 300);
          expect(publications, 1);
          expect(await db.query('playlists'), hasLength(1));
          expect(await db.query('playlist_tracks'), hasLength(2));
          expect(await db.rawQuery('PRAGMA foreign_key_check'), isEmpty);
          completed++;
        } finally {
          container.dispose();
        }
      },
    );
  }
}
