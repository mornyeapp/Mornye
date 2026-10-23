import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:sqflite/sqflite.dart';
import 'package:mornye/models/library_collections.dart';
import 'package:mornye/services/library_collections_database.dart';
import 'package:mornye/services/library_collections_hydration.dart';
import 'package:mornye/services/platform_bridge.dart';

import '../test/support/library_collections_benchmark.dart';

Future<Database> _database(String path) => openDatabase(
  path,
  version: 2,
  onConfigure: (db) async {
    await db.execute('PRAGMA foreign_keys=ON');
    await db.rawQuery('PRAGMA journal_mode=WAL');
    await db.rawQuery('PRAGMA busy_timeout=5000');
  },
  onCreate: (db, _) async {
    final batch = db.batch();
    for (final sql in [
      'CREATE TABLE wishlist_tracks(track_key TEXT PRIMARY KEY,track_json TEXT NOT NULL,added_at TEXT NOT NULL)',
      'CREATE TABLE loved_tracks(track_key TEXT PRIMARY KEY,track_json TEXT NOT NULL,added_at TEXT NOT NULL)',
      'CREATE TABLE favorite_artists(artist_key TEXT PRIMARY KEY,artist_json TEXT NOT NULL,added_at TEXT NOT NULL)',
      'CREATE TABLE playlists(id TEXT PRIMARY KEY,name TEXT NOT NULL,cover_image_path TEXT,created_at TEXT NOT NULL,updated_at TEXT NOT NULL)',
      'CREATE TABLE playlist_tracks(playlist_id TEXT NOT NULL,track_key TEXT NOT NULL,track_json TEXT NOT NULL,added_at TEXT NOT NULL,PRIMARY KEY(playlist_id,track_key),FOREIGN KEY(playlist_id) REFERENCES playlists(id) ON DELETE CASCADE)',
      'CREATE INDEX idx_wishlist_tracks_added_at ON wishlist_tracks(added_at DESC)',
      'CREATE INDEX idx_loved_tracks_added_at ON loved_tracks(added_at DESC)',
      'CREATE INDEX idx_favorite_artists_added_at ON favorite_artists(added_at DESC)',
      'CREATE INDEX idx_playlists_created_at ON playlists(created_at DESC)',
      'CREATE INDEX idx_playlist_tracks_playlist_id ON playlist_tracks(playlist_id)',
    ]) {
      batch.execute(sql);
    }
    await batch.commit(noResult: true);
  },
);

Future<Map<String, dynamic>> _databaseFixture(int count) => Isolate.run(() {
  final tracks = [
    for (var index = 0; index < count; index++)
      {
        'key': 'example:$index',
        'addedAt': '2026-10-0${index % 3 + 1}T00:00:00Z',
        'track': {
          'id': '$index',
          'name': '音楽 🎵 Track $index',
          'artistName': 'Artist ${index % 97}',
          'albumName': 'Album ${index ~/ 12}',
          'duration': 180,
          'coverUrl': 'https://example.test/cover-$index.jpg',
          'source': 'example',
        },
      },
  ];
  return {
    'wishlist': tracks,
    'loved': tracks.take(32).toList(),
    'favoriteArtists': [
      {
        'key': 'example:artist',
        'artistId': 'artist',
        'providerId': 'example',
        'name': 'İstanbul',
        'addedAt': '2026-10-01T00:00:00Z',
      },
    ],
    'playlists': [
      for (var index = 0; index < 4; index++)
        {
          'id': 'p-$index',
          'name': 'Playlist $index',
          'createdAt': '2026-10-01T00:00:00Z',
          'updatedAt': '2026-10-01T00:00:00Z',
          if (index == 1) 'coverImagePath': '/covers/custom.jpg',
          'tracks': tracks.skip(index * (count ~/ 4)).take(count ~/ 4).toList(),
        },
    ],
  };
});

Future<LibraryCollectionsState> _legacyRead(Database db) async {
  final snapshot = LibraryCollectionsSnapshot(
    wishlistRows: await db.rawQuery(
      'SELECT * FROM wishlist_tracks ORDER BY added_at DESC,rowid DESC',
    ),
    lovedRows: await db.rawQuery(
      'SELECT * FROM loved_tracks ORDER BY added_at DESC,rowid DESC',
    ),
    playlistRows: await db.rawQuery(
      """SELECT p.*, CASE WHEN p.cover_image_path IS NULL OR p.cover_image_path='' THEN
      (SELECT pt.track_json FROM playlist_tracks pt WHERE pt.playlist_id=p.id ORDER BY pt.added_at ASC,pt.rowid ASC LIMIT 1)
      END AS preview_track_json FROM playlists p ORDER BY p.created_at DESC,p.rowid DESC""",
    ),
    playlistTrackRows: await db.rawQuery(
      'SELECT playlist_id,track_key FROM playlist_tracks ORDER BY playlist_id ASC,rowid ASC',
    ),
    favoriteArtistRows: await db.rawQuery(
      'SELECT * FROM favorite_artists ORDER BY added_at DESC,rowid DESC',
    ),
  );
  return decodeLibraryCollectionsSnapshot(snapshot);
}

Future<String> _digest(LibraryCollectionsState state) => Isolate.run(
  () => sha256
      .convert(
        utf8.encode(
          jsonEncode({
            'state': state.toJson(),
            'membership': [
              for (final playlist in state.playlists)
                {
                  'id': playlist.id,
                  'keys': playlist.trackKeys.toList()..sort(),
                },
            ],
          }),
        ),
      )
      .toString(),
);

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final report = <String, dynamic>{
    'platform': Platform.operatingSystem,
    'note': 'Five alternating paired samples; not physical-device FPS/RAM.',
  };
  void publish() {
    binding.reportData ??= <String, dynamic>{};
    binding.reportData!['collection_workers'] = report;
  }

  testWidgets(
    'real sqflite native snapshot and playlist read preserve rows and cleanup',
    (tester) async {
      final directory = await Directory.systemTemp.createTemp(
        'collection-channel-read-',
      );
      final db = await _database('${directory.path}/library_collections.db');
      try {
        await LibraryCollectionsDatabase.replaceDatabaseFromBackup(
          db,
          await _databaseFixture(8000),
        );
        await db.execute('CREATE TABLE projection_write_probe(value INTEGER)');
        await db.execute('INSERT INTO projection_write_probe VALUES(0)');
        var writes = 0;
        var verifyIsolation = false;
        Future<Map<String, dynamic>> nativeRead(
          Map<String, dynamic> request,
        ) async {
          expect(request['collections_path'], isNot(db.path));
          if (verifyIsolation) {
            final databases = await db.rawQuery('PRAGMA database_list');
            expect(
              databases.any(
                (row) => (row['name'] as String).startsWith('collection_read_'),
              ),
              false,
              reason: 'sqflite must detach the private file before native IO',
            );
            // Verify outside the paired timing samples: live writes cannot
            // alter the detached projection and remain on the same engine.
            await db.execute('UPDATE projection_write_probe SET value=value+1');
            writes++;
          }
          return PlatformBridge.runNativeDataJob(request);
        }

        final expectedDigest = await _digest(await _legacyRead(db));
        final baseline = <Map<String, int>>[];
        final native = <Map<String, int>>[];
        for (var sample = 0; sample < 5; sample++) {
          for (final useNative
              in sample.isEven ? [false, true] : [true, false]) {
            final result =
                await measureCollectionOperation<LibraryCollectionsState>(
                  () async {
                    if (!useNative) return _legacyRead(db);
                    final snapshot =
                        await LibraryCollectionsDatabase.readDatabaseSnapshot(
                          db,
                          nativeJobRunner: nativeRead,
                        );
                    expect(snapshot.nativeRowsPath, isNotNull);
                    final staged = snapshot.nativeRowsDirectory!;
                    final state = await hydrateLibraryCollectionsSnapshot(
                      snapshot,
                    );
                    expect(await Directory(staged).exists(), isFalse);
                    return state;
                  },
                );
            expect(await _digest(result.value), expectedDigest);
            (useNative ? native : baseline).add(result.timing);
          }
        }
        verifyIsolation = true;
        final rows =
            await LibraryCollectionsDatabase.readDatabasePlaylistTracks(
              db,
              'p-0',
              nativeJobRunner: nativeRead,
            );
        expect(rows.nativeRowsPath, isNotNull);
        final expectedTracks = await db.rawQuery(
          'SELECT * FROM playlist_tracks WHERE playlist_id=? ORDER BY added_at ASC,rowid ASC',
          ['p-0'],
        );
        final expected = await hydratePlaylistTracks(
          expectedTracks,
          knownKeys: expectedTracks
              .map((row) => row['track_key'] as String)
              .toSet(),
        );
        final staged = rows.nativeRowsDirectory!;
        final tracks = await hydratePlaylistTracksSnapshot(
          rows,
          knownKeys: expected.trackKeys,
        );
        expect(
          jsonEncode(tracks.tracks.map((entry) => entry.toJson()).toList()),
          jsonEncode(expected.tracks.map((entry) => entry.toJson()).toList()),
        );
        expect(tracks.membershipUnchanged, isTrue);
        expect(await Directory(staged).exists(), isFalse);
        expect(await db.rawQuery('SELECT value FROM projection_write_probe'), [
          {'value': writes},
        ]);
        expect(await db.rawQuery('PRAGMA integrity_check'), [
          {'integrity_check': 'ok'},
        ]);
        report['native_database_read'] = {
          'tracks': 8000,
          'membership_rows': 8000,
          'baseline': baseline,
          'native': native,
          'digest': expectedDigest,
          'note':
              'Full original sqflite queries+caller hydration versus same-engine private SQL projection+native file+worker, five alternating pairs; native never opens the live DB.',
        };
        publish();
      } finally {
        await db.close();
        await directory.delete(recursive: true);
      }
    },
  );

  testWidgets(
    'collection snapshot worker preserves parity and caller heartbeat',
    (tester) async {
      final result = await benchmarkCollectionHydration();
      final samples = result['worker'] as List<Map<String, int>>;
      expect(samples.every((sample) => sample['heartbeat_count']! > 0), isTrue);
      report['collection_hydration'] = result;
      publish();
    },
  );

  testWidgets('large playlist search preserves original ranked pages', (
    tester,
  ) async {
    report['playlist_search'] = await benchmarkPlaylistSearch();
    publish();
  });

  testWidgets('metadata-only playlist copies retain all membership indices', (
    tester,
  ) async {
    report['playlist_metadata_copy'] = await benchmarkPlaylistMetadataCopy();
    publish();
  });

  testWidgets(
    'collection export worker preserves model JSON and caller heartbeat',
    (tester) async {
      report['collection_json_export'] = await benchmarkCollectionJsonExport();
      publish();
    },
  );
}
