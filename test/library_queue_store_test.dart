import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart';
import 'package:mornye/models/library_database_models.dart';
import 'package:mornye/services/library_queue_store.dart';
import 'package:mornye/services/library_row_mapper.dart';
import 'package:mornye/services/library_schema.dart';

import 'support/sqlite_process_database.dart';

List<String> _tracks(QueueLibraryDbPage page) => [
  for (final row in page.rows) '${row['source']}:${(row['item'] as Map)['id']}',
];

class _AlbumQueryDatabase implements Database {
  _AlbumQueryDatabase(this.db);

  final Database db;
  late String sql;
  List<Object?>? args;

  @override
  Future<List<Map<String, Object?>>> rawQuery(
    String sql, [
    List<Object?>? arguments,
  ]) {
    this.sql = sql;
    args = arguments;
    return db.rawQuery(sql, arguments);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SqliteProcessDatabase db;
  late LibraryQueueStore store;

  Future<void> addHistory(
    String id,
    String album,
    int number, {
    String artist = 'Artist',
    String title = 'Song',
    String? path,
  }) async {
    final file = path ?? '/$id.flac';
    await db.insert('history_db.history', {
      'id': id,
      'track_name': title,
      'artist_name': artist,
      'album_name': album,
      'album_artist': artist,
      'file_path': file,
      'downloaded_at': '2026-01-01',
      'service': 'example-provider',
      'album_key': '${album.toLowerCase()}|${artist.toLowerCase()}',
      'track_number': number,
      'total_tracks': 2,
      'disc_number': 1,
      'total_discs': 1,
      'bit_depth': 16,
      'genre': 'Pop',
      'release_date': '2026',
      'sort_track': title.toLowerCase(),
      'sort_artist': artist.toLowerCase(),
      'sort_album': album.toLowerCase(),
      'sort_album_artist': artist.toLowerCase(),
      'sort_genre': 'pop',
      'sort_release': '2026',
      'sort_added': 1,
      'search_text': '$title $artist $album'.toLowerCase(),
      'has_replaygain': number == 1 ? 1 : 0,
    });
    await db.insert('history_db.history_path_keys', {
      'item_id': id,
      'path_key': file,
    });
  }

  Future<void> addLocal(
    String id,
    int number, {
    String? path,
    String source = 'legacy',
    String album = 'Local',
    String artist = 'Artist',
  }) async {
    final file = path ?? '/$id.flac';
    final track = LocalLibraryItem(
      id: id,
      sourceId: source,
      trackName: 'Song',
      artistName: artist,
      albumName: album,
      filePath: file,
      scannedAt: DateTime.utc(2026),
      fileModTime: 1,
      trackNumber: number,
      totalTracks: 2,
      discNumber: 1,
      totalDiscs: 1,
      bitDepth: 16,
      genre: 'Pop',
      releaseDate: '2026',
      hasReplayGain: number == 1,
    );
    await db.insert('library', LibraryRowMapper.encode(track.toJson()));
    await db.insert('library_path_keys', {'item_id': id, 'path_key': file});
  }

  setUp(() async {
    db = await SqliteProcessDatabase.open();
    await LibrarySchema.create(db, LibrarySchema.version);
    await db.execute("ATTACH DATABASE ':memory:' AS history_db");
    final definition = RegExp(r'CREATE TABLE history\s*\([\s\S]*?\n\s*\)')
        .firstMatch(
          File('lib/services/history_schema.dart').readAsStringSync(),
        )!
        .group(0)!;
    await db.execute(
      definition.replaceFirst(
        'CREATE TABLE history',
        'CREATE TABLE history_db.history',
      ),
    );
    await db.execute(
      'CREATE TABLE history_db.history_path_keys (item_id TEXT, path_key TEXT)',
    );
    await addHistory('h1', 'Downloaded', 1);
    await addHistory('h2', 'Downloaded', 2);
    await addHistory('single', 'Single', 2, artist: 'Another Artist');
    await addLocal('l1', 1);
    await addLocal('l2', 2);
    await addLocal('mirror', 1, path: '/h1.flac');
    await db.insert('library_sources', {
      'id': 'offline',
      'path': '/offline',
      'display_name': 'Offline',
      'available': 0,
    });
    await addLocal('hidden', 1, source: 'offline');
    store = LibraryQueueStore(db, historyFts: false, localFts: false);
  });
  tearDown(() => db.close());

  test(
    'track cursors match offset ordering across source ties for every sort',
    () async {
      for (final sort in [
        'latest',
        'oldest',
        'a-z',
        'z-a',
        'artist-asc',
        'artist-desc',
        'album-asc',
        'album-desc',
        'release-oldest',
        'release-newest',
        'genre-asc',
        'genre-desc',
      ]) {
        final expected = _tracks(
          await store.trackPage(QueueLibraryDbQuery(sortMode: sort)),
        );
        final actual = <String>[];
        QueueLibraryDbCursor? cursor;
        do {
          final page = await store.trackPage(
            QueueLibraryDbQuery(sortMode: sort, limit: 2, cursor: cursor),
          );
          actual.addAll(_tracks(page));
          cursor = page.nextCursor;
        } while (cursor != null);
        expect(actual, expected, reason: sort);
        expect(actual, hasLength(5), reason: sort);
        expect(actual, isNot(contains('local:mirror')));
        expect(actual, isNot(contains('local:hidden')));
      }
    },
  );

  test(
    'album cursors and invalid-cursor offset fallback preserve results',
    () async {
      for (final sort in [
        'latest',
        'album-asc',
        'album-desc',
        'artist-asc',
        'release-newest',
      ]) {
        final expected = (await store.albumPage(
          QueueLibraryDbQuery(sortMode: sort),
        )).rows;
        final first = await store.albumPage(
          QueueLibraryDbQuery(sortMode: sort, limit: 1),
        );
        final second = await store.albumPage(
          QueueLibraryDbQuery(
            sortMode: sort,
            limit: 1,
            cursor: first.nextCursor,
          ),
        );
        expect([...first.rows, ...second.rows], expected, reason: sort);
        final fallback = await store.albumPage(
          QueueLibraryDbQuery(
            sortMode: sort,
            offset: 1,
            limit: 1,
            cursor: const QueueLibraryDbCursor(['wrong length']),
          ),
        );
        expect(fallback.rows, [expected.last], reason: sort);
      }
    },
  );

  test(
    'unfiltered albums match the original aggregation across sources and pages',
    () async {
      await db.update('history_db.history', {
        'sort_added': 900,
      }, where: "id = 'h1'");
      await db.update('history_db.history', {
        'artist_name': 'Guest Artist',
      }, where: "id = 'h2'");
      await addHistory('edition1', 'Downloaded', 1, artist: 'Other Artist');
      await addHistory('edition2', 'Downloaded', 2, artist: 'Other Artist');
      await addHistory('null-key', 'Invalid', 1);
      await db.update('history_db.history', {
        'album_key': null,
      }, where: "id = 'null-key'");
      await addLocal('local-edition1', 1, artist: 'Other Artist');
      await addLocal('local-edition2', 2, artist: 'Other Artist');
      await addLocal('local-single', 1, album: 'Local Single');
      await db.insert('library_sources', {
        'id': 'disabled',
        'path': '/disabled',
        'display_name': 'Disabled',
        'enabled': 0,
      });
      await addLocal('disabled1', 1, source: 'disabled');
      await addLocal('disabled2', 2, source: 'disabled');
      for (final source in [null, 'downloaded', 'local']) {
        for (final includeLocal in [false, true]) {
          for (final singles in [false, true]) {
            for (final sort in [
              'latest',
              'oldest',
              'album-asc',
              'album-desc',
              'artist-asc',
              'release-newest',
            ]) {
              for (final offset in [0, 1]) {
                Future<QueueLibraryDbPage> page(String? quality) =>
                    store.albumPage(
                      QueueLibraryDbQuery(
                        source: source,
                        includeLocal: includeLocal,
                        includeSingleTrackAlbums: singles,
                        sortMode: sort,
                        offset: offset,
                        limit: 1,
                        searchQuery: '  ',
                        quality: quality,
                      ),
                    );
                // Unknown quality adds no predicate but uses the original join.
                final original = await page('unrecognized');
                final fast = await page(null);
                expect(fast.rows, original.rows);
                expect(fast.nextCursor, original.nextCursor);
              }
            }
          }
        }
      }
      final albums = (await store.albumPage(const QueueLibraryDbQuery())).rows;
      expect(albums.map((row) => row['track_count']), everyElement(2));
      expect(albums, hasLength(4));
      expect(
        (await store.albumPage(
          const QueueLibraryDbQuery(includeSingleTrackAlbums: true),
        )).rows,
        hasLength(6),
      );
      final filtered = (await store.albumPage(
        const QueueLibraryDbQuery(
          source: 'downloaded',
          metadata: 'missing-replaygain',
        ),
      )).rows;
      final downloaded = filtered.singleWhere(
        (row) => row['album_key'] == 'downloaded|artist',
      );
      expect(downloaded['track_count'], 1);
      expect(downloaded['sort_added'], 900);
    },
  );

  test(
    'unfiltered local album query removes the second inventory pass',
    () async {
      await db.execute('''
      WITH RECURSIVE numbered(value) AS (
        SELECT 1 UNION ALL SELECT value + 1 FROM numbered WHERE value < 20000
      )
      INSERT INTO library (id, source_id, file_path, track_name, artist_name,
        album_name, album_key, track_name_norm, album_name_norm, album_artist_norm, sort_added, scanned_at)
      SELECT 'bulk-' || value, 'legacy', '/bulk-' || value || '.flac',
        'Song', 'Artist', 'Album ' || (value / 10), 'bulk-album-' || (value / 10),
        'song', 'album ' || (value / 10), 'artist', value, '2026-01-01' FROM numbered
    ''');
      await db.execute('''
      INSERT INTO library_path_keys (item_id, path_key)
      SELECT id, file_path FROM library WHERE id LIKE 'bulk-%'
    ''');
      final recorded = _AlbumQueryDatabase(db);
      final albums = LibraryQueueStore(
        recorded,
        historyFts: false,
        localFts: false,
      );
      final fast = await albums.albumPage(
        const QueueLibraryDbQuery(source: 'local', limit: 40),
      );
      final fastSql = recorded.sql;
      final fastArgs = recorded.args;
      final original = await albums.albumPage(
        const QueueLibraryDbQuery(
          source: 'local',
          limit: 40,
          quality: 'unrecognized',
        ),
      );
      final originalSql = recorded.sql;
      final originalArgs = recorded.args;
      expect(fast.rows, original.rows);
      final fastPlan = await db.rawQuery(
        'EXPLAIN QUERY PLAN $fastSql',
        fastArgs,
      );
      final originalPlan = await db.rawQuery(
        'EXPLAIN QUERY PLAN $originalSql',
        originalArgs,
      );
      int duplicateChecks(List<Map<String, Object?>> plan) => plan
          .where(
            (step) => (step['detail'] as String).contains(
              'CORRELATED SCALAR SUBQUERY',
            ),
          )
          .length;
      expect(duplicateChecks(fastPlan), 1);
      expect(duplicateChecks(originalPlan), 2);
    },
  );

  test(
    'fast counts agree with filtered counts and deduplicate visible paths',
    () async {
      final fast = await store.counts(const QueueLibraryDbQuery());
      final filtered = await store.counts(
        const QueueLibraryDbQuery(quality: 'cd'),
      );
      expect(
        [fast.allTrackCount, fast.albumCount, fast.singleTrackCount],
        [5, 2, 1],
      );
      expect(
        [
          filtered.allTrackCount,
          filtered.albumCount,
          filtered.singleTrackCount,
        ],
        [5, 2, 1],
      );
      final local = await store.counts(
        const QueueLibraryDbQuery(source: 'local'),
      );
      expect(local.allTrackCount, 2);
      final gain = await store.trackPage(
        const QueueLibraryDbQuery(metadata: 'missing-replaygain'),
      );
      expect(_tracks(gain).toSet(), {
        'downloaded:h2',
        'downloaded:single',
        'local:l2',
      });
    },
  );

  test('artist counts use the same filter as the track query', () async {
    for (final artist in ['Artist', 'Another Artist', 'Missing Artist']) {
      final query = QueueLibraryDbQuery(albumArtist: artist);
      final counts = await store.counts(query);
      final tracks = await store.trackPage(query);
      expect(counts.allTrackCount, tracks.rows.length, reason: artist);
      expect(
        [counts.allTrackCount, counts.albumCount, counts.singleTrackCount],
        switch (artist) {
          'Artist' => [4, 2, 0],
          'Another Artist' => [1, 0, 1],
          _ => [0, 0, 0],
        },
      );
    }
  });

  test(
    'format aliases find indexed and filename-only tracks in both sources',
    () async {
      for (final sample in [
        (filter: 'm4a', format: 'MP4', extension: 'MP4'),
        (filter: 'aac', format: 'mp4a', extension: 'AAC'),
        (filter: 'alac', format: 'alac', extension: 'ALAC'),
        (filter: 'opus', format: 'opus', extension: 'OPUS'),
        (filter: 'ogg', format: 'vorbis', extension: 'OGG'),
        (filter: 'wav', format: 'wave', extension: 'WAVE'),
        (filter: 'aiff', format: 'aifc', extension: 'AIF'),
        (filter: 'ape', format: 'ape', extension: 'APE'),
        (filter: 'wv', format: 'wavpack', extension: 'WV'),
        (filter: 'dsf', format: 'dsf', extension: 'DSF'),
        (filter: 'dff', format: 'dff', extension: 'DFF'),
        (filter: 'mpc', format: 'musepack', extension: 'MPC'),
        (filter: 'eac3', format: 'ec-3', extension: 'EAC3'),
        (filter: 'ac3', format: 'ac_3', extension: 'AC3'),
        (filter: 'ac4', format: 'ac-4', extension: 'AC4'),
      ]) {
        // SAF may expose an opaque URI, so the indexed format must also work.
        for (final table in ['history_db.history', 'library']) {
          await db.update(table, {
            'format': ' ${sample.format} ',
            'file_path': 'content://example/document/123',
          }, where: table == 'library' ? "id = 'l1'" : "id = 'h1'");
          await db.update(table, {
            'format': null,
            'file_path': '/track.${sample.extension}',
          }, where: table == 'library' ? "id = 'l2'" : "id = 'h2'");
        }
        final request = QueueLibraryDbQuery(format: sample.filter);
        expect(_tracks(await store.trackPage(request)).toSet(), {
          'downloaded:h1',
          'downloaded:h2',
          'local:l1',
          'local:l2',
        }, reason: sample.filter);
        expect((await store.counts(request)).allTrackCount, 4);
        expect((await store.albumPage(request)).rows, hasLength(2));
        final tagged = QueueLibraryDbQuery(
          format: sample.filter,
          metadata: 'has-replaygain',
          source: 'local',
          quality: 'cd',
          searchQuery: 'Artist',
        );
        expect(_tracks(await store.trackPage(tagged)), ['local:l1']);
        expect((await store.counts(tagged)).allTrackCount, 1);
      }
    },
  );

  test(
    'ReplayGain presence follows tag updates, paging and source deduplication',
    () async {
      const request = QueueLibraryDbQuery(metadata: 'has-replaygain', limit: 1);
      final first = await store.trackPage(request);
      final second = await store.trackPage(
        QueueLibraryDbQuery(
          metadata: 'has-replaygain',
          limit: 1,
          cursor: first.nextCursor,
        ),
      );
      expect(
        {..._tracks(first), ..._tracks(second)},
        {'downloaded:h1', 'local:l1'},
      );
      expect((await store.counts(request)).allTrackCount, 2);
      expect((await store.albumPage(request)).rows.single['track_count'], 1);

      await db.update('history_db.history', {
        'has_replaygain': 0,
      }, where: "id = 'h1'");
      await db.update('library', {'has_replaygain': 1}, where: "id = 'l2'");
      final updated = await store.trackPage(
        const QueueLibraryDbQuery(metadata: 'has-replaygain'),
      );
      expect(_tracks(updated).toSet(), {'local:l1', 'local:l2'});
      expect((await store.counts(request)).allTrackCount, 2);
      final missing = await store.trackPage(
        const QueueLibraryDbQuery(metadata: 'missing-replaygain'),
      );
      expect(_tracks(missing).toSet(), {
        'downloaded:h1',
        'downloaded:h2',
        'downloaded:single',
      });
    },
  );

  test(
    'independent FTS inputs match LIKE fallback and escape literal search',
    () async {
      await db.execute(
        "CREATE VIRTUAL TABLE history_db.history_search_fts USING fts5(search_text, tokenize='trigram')",
      );
      await db.execute(
        'INSERT INTO history_db.history_search_fts(rowid, search_text) SELECT rowid, search_text FROM history_db.history',
      );
      final expected = _tracks(
        await store.trackPage(const QueueLibraryDbQuery(searchQuery: 'Artist')),
      );
      const search = QueueLibraryDbQuery(searchQuery: 'Artist');
      final expectedAlbums = (await store.albumPage(search)).rows;
      final expectedCounts = await store.counts(search);
      final expectedArtists = await store.artistPage(search);
      for (final flags in [(true, false), (false, true), (true, true)]) {
        final indexed = LibraryQueueStore(
          db,
          historyFts: flags.$1,
          localFts: flags.$2,
        );
        expect(
          _tracks(
            await indexed.trackPage(
              const QueueLibraryDbQuery(searchQuery: 'Artist'),
            ),
          ),
          expected,
        );
        expect((await indexed.albumPage(search)).rows, expectedAlbums);
        final counts = await indexed.counts(search);
        expect(
          [counts.allTrackCount, counts.albumCount, counts.singleTrackCount],
          [
            expectedCounts.allTrackCount,
            expectedCounts.albumCount,
            expectedCounts.singleTrackCount,
          ],
        );
        expect(await indexed.artistPage(search), expectedArtists);
      }
      await addHistory(
        'literal',
        'Special',
        1,
        artist: 'Literal',
        title: 'Percent % Track',
      );
      expect(
        _tracks(
          await store.trackPage(const QueueLibraryDbQuery(searchQuery: '%')),
        ),
        ['downloaded:literal'],
      );
    },
  );

  test(
    'artist pages aggregate visible inventory without loading track models',
    () async {
      final artists = await store.artistPage(const QueueLibraryDbQuery());
      expect(artists.map((row) => row['artist_name']), [
        'Another Artist',
        'Artist',
      ]);
      expect(artists.map((row) => row['track_count']), [1, 4]);
      final downloaded = await store.artistPage(
        const QueueLibraryDbQuery(includeLocal: false),
      );
      expect(downloaded.map((row) => row['track_count']), [1, 2]);
    },
  );
}
