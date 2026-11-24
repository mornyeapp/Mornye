import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/library_album_artwork.dart';

import 'support/sqlite_process_database.dart';

void main() {
  late Directory root;
  late Directory covers;
  late SqliteProcessDatabase database;
  late LibraryAlbumArtworkStore store;
  late DateTime now;
  late List<String> searches;
  late List<String> downloads;
  late Set<String> motion;
  late bool searchFails;

  // Albums the fake provider knows, by "artist album" query.
  const catalog = {
    'Example Band First Light': {
      'item_type': 'album',
      'id': 'fl',
      'name': 'First Light',
      'artists': 'Example Band',
      'total_tracks': 2,
      'cover_url': 'https://example.com/fl-small.jpg',
    },
    'Other Band Second Sun': {
      'item_type': 'album',
      'id': 'ss',
      'name': 'Second Sun',
      'artists': 'Other Band',
      'cover_url': 'https://example.com/ss-small.jpg',
    },
  };

  setUp(() async {
    root = await Directory.systemTemp.createTemp('album-artwork-');
    covers = Directory('${root.path}/library_covers');
    database = await SqliteProcessDatabase.open(path: '${root.path}/lib.db');
    await database.execute(
      'CREATE TABLE library (id TEXT PRIMARY KEY, file_path TEXT, '
      'album_key TEXT, album_name TEXT, album_artist TEXT, artist_name TEXT, '
      'release_date TEXT, cover_path TEXT)',
    );
    await database.execute(
      'CREATE VIEW library_visible AS SELECT * FROM library',
    );
    store = LibraryAlbumArtworkStore(
      database: () async => database,
      coverDirectory: () async => covers,
    );
    now = DateTime(2026, 11, 8);
    searches = [];
    downloads = [];
    motion = {};
    searchFails = false;
    Future<void> song(
      String id,
      String album,
      String artist, {
      String? cover,
      String? path,
    }) => database.rawInsert(
      'INSERT INTO library VALUES (?, ?, ?, ?, NULL, ?, NULL, ?)',
      [
        id,
        path ?? '/music/$id.flac',
        '${album.toLowerCase()}|${artist.toLowerCase()}',
        album,
        artist,
        cover,
      ],
    );
    await song('a1', 'First Light', 'Example Band');
    await song('a2', 'First Light', 'Example Band');
    await song('b1', 'Second Sun', 'Other Band', cover: '/covers/b.jpg');
    await song('c1', 'Unknown Album', 'Unknown Artist');
    await song('d1', 'Lost Tapes', 'Example Band');
    await song('n1', 'First Light', 'Example Band', path: 'network://nas/n1');
  });

  tearDown(() async {
    await database.close();
    await root.delete(recursive: true);
  });

  AlbumArtworkJob job({List<String> providers = const ['empty', 'full']}) =>
      AlbumArtworkJob(
        store: store,
        now: () => now,
        concurrency: 1,
        lookup: AlbumArtworkLookup(
          providers: providers,
          search: (provider, query) async {
            searches.add('$provider:$query');
            if (searchFails) throw StateError('offline');
            final result = catalog[query];
            return provider == 'full' && result != null ? [result] : [];
          },
          details: (provider, id) async => {
            'album_info': {
              'cover_url': 'https://example.com/$id-large.jpg',
              if (id == 'fl') 'header_video': 'https://example.com/fl.mp4',
            },
          },
        ),
        downloadCover: (url, path) async {
          downloads.add(url);
          await File(path).writeAsBytes([1, 2, 3]);
          return true;
        },
        hasMotion: (album) async => motion.contains(album.album.key),
        saveMotion: (album, url) async => motion.add(album.album.key),
      );

  Future<Map<String, String?>> songCovers() async => {
    for (final row in await database.rawQuery(
      'SELECT id, cover_path FROM library',
    ))
      row['id'] as String: row['cover_path'] as String?,
  };

  test('finds covers once per album, for local albums without one', () async {
    final summary = await job().run(covers: true, motion: false);

    expect(searches, [
      'empty:Example Band First Light',
      'full:Example Band First Light',
      'empty:Example Band Lost Tapes',
      'full:Example Band Lost Tapes',
    ]);
    expect(downloads, ['https://example.com/fl-large.jpg']);
    expect(summary.albums, 2);
    expect(summary.covers, 1);
    expect(summary.songs, 2);
    final found = await songCovers();
    expect(found['a1'], startsWith('${covers.path}/album_'));
    expect(found['a2'], found['a1']);
    expect(File(found['a1']!).existsSync(), isTrue);
    expect(found['b1'], '/covers/b.jpg');
    expect(found['c1'], isNull);
    expect(found['d1'], isNull);
    expect(found['n1'], isNull, reason: 'Network songs keep their own');

    // Neither album is looked up again until a missing one may have come.
    searches.clear();
    await job().run(covers: true, motion: false);
    expect(searches, isEmpty);
    now = now.add(AlbumArtworkJob.recheckAfter);
    await job().run(covers: true, motion: false);
    expect(searches, [
      'empty:Example Band Lost Tapes',
      'full:Example Band Lost Tapes',
    ]);
  });

  test('puts found covers back after a scan and a cleared cache', () async {
    await job().run(covers: true, motion: false);
    final cover = (await songCovers())['a1']!;

    // A scan clears the cover of a song whose file has none.
    await database.rawUpdate('UPDATE library SET cover_path = NULL');
    await database.rawUpdate(
      "UPDATE library SET cover_path = '/covers/b.jpg' WHERE id = 'b1'",
    );
    expect(await store.apply(), 2);
    expect((await songCovers())['a1'], cover);

    // Clearing the cache deletes the file; it comes back without a search.
    await File(cover).delete();
    searches.clear();
    expect(await job().restore(), greaterThan(0));
    expect(searches, isEmpty);
    expect(downloads, [
      'https://example.com/fl-large.jpg',
      'https://example.com/fl-large.jpg',
    ]);
    final restored = (await songCovers())['a1']!;
    expect(File(restored).existsSync(), isTrue);
    expect((await songCovers())['a2'], restored);
  });

  test('a removed cover stays away until the album is looked up', () async {
    await job().run(covers: true, motion: false);
    final cover = (await songCovers())['a1']!;
    const key = 'first light|example band';

    await store.removeCover(key);
    expect((await songCovers())['a1'], isNull);
    expect(File(cover).existsSync(), isFalse);

    searches.clear();
    await job().run(covers: true, motion: false);
    expect(searches, isEmpty);
    expect((await songCovers())['a1'], isNull);

    final summary = await job().run(
      covers: true,
      motion: false,
      albumKey: key,
      force: true,
    );
    expect(summary.covers, 1);
    expect(searches, contains('full:Example Band First Light'));
    expect((await songCovers())['a1'], isNotNull);
  });

  test('animated covers are looked up for albums with covers too', () async {
    final summary = await job().run(covers: false, motion: true);

    expect(summary.albums, 3);
    expect(summary.motion, 1);
    expect(summary.covers, 0);
    expect(motion, {'first light|example band'});
    expect(searches, contains('full:Other Band Second Sun'));
    expect((await songCovers())['a1'], isNull);

    final records = await store.records();
    expect(records['first light|example band']?.motionSaved, isTrue);
    expect(records['second sun|other band']?.matched, isTrue);
    expect(records['second sun|other band']?.motionUrl, isNull);

    searches.clear();
    await job().run(covers: false, motion: true);
    expect(searches, isEmpty);
  });

  test('an album no provider could answer for is tried again', () async {
    searchFails = true;
    final failed = await job().run(covers: true, motion: false);
    expect(failed.failed, 2);
    expect(await store.records(), isEmpty);

    searchFails = false;
    searches.clear();
    final summary = await job().run(covers: true, motion: false);
    expect(summary.covers, 1);
    expect(searches, isNotEmpty);
  });

  test('stops between albums when cancelled', () async {
    var done = 0;
    final summary = await job().run(
      covers: true,
      motion: false,
      cancelled: () => done > 0,
      progress: (finished, total) => done = finished,
    );
    expect(summary.cancelled, isTrue);
    expect(searches, hasLength(2), reason: 'Only the first album');
  });
}
