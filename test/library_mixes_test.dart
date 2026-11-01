import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/providers/library_mixes_provider.dart';
import 'package:mornye/services/library_mixes.dart';
import 'package:mornye/services/library_queue_store.dart';
import 'package:mornye/services/library_schema.dart';
import 'package:mornye/services/library_shadow_sql.dart';
import 'package:mornye/services/playable_media.dart';

import 'support/sqlite_process_database.dart';

PlayableMedia _song(String id, String artist, String? genre) => PlayableMedia(
  id: 'local_$id',
  source: '/music/$id.flac',
  title: 'Song $id',
  artist: artist,
  album: '$artist Album ${id.hashCode % 2}',
  genre: genre,
);

/// Hip-hop under four spellings, rock and a smaller jazz shelf.
List<PlayableMedia> _library() {
  const hipHop = ['Hip-Hop', 'Rap', 'hip hop', 'Trap'];
  return [
    for (var a = 0; a < 8; a++)
      for (var s = 0; s < 6; s++)
        _song(
          'hh$a-$s',
          a == 0 ? 'Tyler, The Creator' : 'Rapper $a',
          hipHop[(a + s) % hipHop.length],
        ),
    for (var a = 0; a < 6; a++)
      for (var s = 0; s < 6; s++) _song('rock$a-$s', 'Band $a', 'Rock'),
    for (var a = 0; a < 7; a++)
      for (var s = 0; s < 3; s++) _song('jazz$a-$s', 'Trio $a', 'Jazz'),
  ];
}

Map<String, Object?> _json(List<LibraryMix> mixes) => {
  for (final mix in mixes) '${mix.kind.name}:${mix.key}': mix.toJson(),
};

void main() {
  group('genre families', () {
    test('spellings of one genre share a family', () {
      for (final tag in [
        'Hip-Hop',
        'hip hop',
        'HipHop',
        'Rap',
        'Pop Rap',
        'Trap',
        'Alternative Hip-Hop',
      ]) {
        expect(libraryGenreFamilies(tag), ['hiphop'], reason: tag);
      }
      for (final tag in ['R&B', 'Contemporary R&B', "R'n'B", 'rnb', 'Soul']) {
        expect(libraryGenreFamilies(tag), ['rnb'], reason: tag);
      }
    });

    test('a genre is named by its last word, the longer name winning', () {
      expect(libraryGenreFamilies('Dance Pop'), ['pop']);
      expect(libraryGenreFamilies('K-Pop'), ['kpop']);
      expect(libraryGenreFamilies('J-Rock'), ['jpop']);
      expect(libraryGenreFamilies('Indie Rock'), ['indie']);
      expect(libraryGenreFamilies('Drum & Bass'), ['electronic']);
      expect(libraryGenreFamilies('Lo-Fi'), ['chill']);
    });

    test('tags split into their families, skipping empty ones', () {
      expect(libraryGenreFamilies('Hip-Hop/Rap; R&B'), ['hiphop', 'rnb']);
      expect(libraryGenreFamilies('Pop, Rock'), ['pop', 'rock']);
      expect(libraryGenreFamilies('(17)'), isEmpty);
      expect(libraryGenreFamilies('Other'), isEmpty);
      expect(libraryGenreFamilies(null), isEmpty);
      expect(libraryGenreFamilies('Sundanese'), ['tag:sundanese']);
      expect(libraryGenreFamilyLabel('hiphop'), 'Hip-Hop');
      expect(libraryGenreFamilyLabel('tag:sundanese'), isNull);
    });
  });

  group('mixes', () {
    final day = DateTime(2026, 10, 27, 9);
    bool exists(String _) => true;

    test('a small Library gets no mixes', () {
      final songs = _library().take(libraryMixMinLibrary - 1).toList();
      expect(
        buildLibraryMixes(
          LibraryMixRequest(songs: songs, at: day, exists: exists),
        ),
        isEmpty,
      );
    });

    test('one artist alone makes no mix', () {
      final songs = [
        for (var s = 0; s < 60; s++) _song('solo$s', 'Solo', 'Hip-Hop'),
      ];
      expect(
        buildLibraryMixes(
          LibraryMixRequest(songs: songs, at: day, exists: exists),
        ),
        isEmpty,
      );
    });

    test('genre spellings form one mix, led by what is played', () {
      final songs = _library();
      final mixes = buildLibraryMixes(
        LibraryMixRequest(
          songs: songs,
          at: day,
          exists: exists,
          plays: {
            for (var s = 0; s < 6; s++) 'local_hh0-$s': 10.0 + s,
            'local_rock0-0': 2,
          },
        ),
      );
      final genres = [
        for (final mix in mixes)
          if (mix.kind == LibraryMixKind.genre) mix,
      ];
      expect(genres.map((mix) => mix.key), ['hiphop', 'rock', 'jazz']);
      final hipHop = genres.first;
      expect(hipHop.label, 'Hip-Hop');
      expect(hipHop.artists, contains('Tyler, The Creator'));
      // The most played song by the most played artist starts the mix.
      expect(hipHop.songIds.first, 'local_hh0-5');
      final byId = {for (final song in songs) song.id: song};
      expect({
        for (final id in hipHop.songIds) byId[id]!.genre,
      }, containsAll(['Hip-Hop', 'Rap', 'hip hop', 'Trap']));
      for (final id in hipHop.songIds) {
        expect(id, startsWith('local_hh'));
      }
    });

    test('mixes keep their size and space their artists', () {
      final songs = _library();
      final byId = {for (final song in songs) song.id: song};
      final mixes = buildLibraryMixes(
        LibraryMixRequest(
          songs: songs,
          at: day,
          exists: exists,
          plays: {for (final song in songs.take(12)) song.id: 3},
        ),
      );
      expect(mixes, isNotEmpty);
      expect(mixes.length, lessThanOrEqualTo(libraryMixMaxCount));
      for (final mix in mixes) {
        expect(
          mix.songIds.length,
          inInclusiveRange(libraryMixMinSongs, libraryMixTargetSongs),
        );
        expect(mix.songIds.toSet(), hasLength(mix.songIds.length));
        final counts = <String, int>{};
        String? previous;
        for (final id in mix.songIds) {
          final artist = byId[id]!.artist;
          expect(artist, isNot(previous), reason: '${mix.key}: $id');
          previous = artist;
          counts[artist] = (counts[artist] ?? 0) + 1;
        }
        final cap = (libraryMixTargetSongs * 0.2).ceil();
        for (final count in counts.values) {
          expect(count, lessThanOrEqualTo(cap), reason: mix.key);
        }
      }
    });

    test('the favorites mix leads with the most played songs', () {
      final songs = _library();
      final mixes = buildLibraryMixes(
        LibraryMixRequest(
          songs: songs,
          at: day,
          exists: exists,
          plays: {
            for (var a = 0; a < 6; a++) 'local_rock$a-0': 5.0 + a,
            'local_hh3-1': 20,
            'local_jazz2-2': 1,
          },
        ),
      );
      expect(mixes.first.kind, LibraryMixKind.favorites);
      expect(mixes.first.songIds.first, 'local_hh3-1');
    });

    test('a day keeps its mixes and the next day changes them', () {
      final songs = _library();
      LibraryMixRequest request(DateTime at) => LibraryMixRequest(
        songs: songs,
        at: at,
        exists: exists,
        plays: {'local_hh1-1': 4, 'local_rock2-2': 2},
      );
      final morning = _json(buildLibraryMixes(request(day)));
      final evening = _json(
        buildLibraryMixes(request(DateTime(2026, 10, 27, 22))),
      );
      final tomorrow = _json(
        buildLibraryMixes(request(DateTime(2026, 10, 28, 9))),
      );
      expect(evening, morning);
      expect(tomorrow.keys, morning.keys);
      expect(tomorrow, isNot(morning));
    });

    test('songs whose files are gone stay out', () {
      final songs = _library();
      final gone = {for (final song in songs.take(20)) song.source};
      final mixes = buildLibraryMixes(
        LibraryMixRequest(
          songs: songs,
          at: day,
          exists: (source) => !gone.contains(source),
          plays: {songs.first.id: 9},
        ),
      );
      expect(mixes, isNotEmpty);
      for (final mix in mixes) {
        for (final id in mix.songIds) {
          expect(gone, isNot(contains('/music/${id.substring(6)}.flac')));
        }
      }
    });

    test('an untagged song joins its artist\'s genre', () {
      final songs = [..._library(), _song('jazz0-untagged', 'Trio 0', null)];
      final mixes = buildLibraryMixes(
        LibraryMixRequest(
          songs: songs,
          at: day,
          exists: exists,
          plays: {'local_jazz0-untagged': 3},
        ),
      );
      final jazz = mixes.firstWhere((mix) => mix.key == 'jazz');
      expect(jazz.songIds.first, 'local_jazz0-untagged');
    });

    test('without genre tags, the artists played most anchor mixes', () {
      final songs = [
        for (var a = 0; a < 10; a++)
          for (var s = 0; s < 6; s++)
            _song('u$a-$s', a == 0 ? 'Anchor' : 'Artist $a', null),
      ];
      final mixes = buildLibraryMixes(
        LibraryMixRequest(
          songs: songs,
          at: day,
          exists: exists,
          plays: {'local_u0-0': 6, 'local_u0-1': 4},
        ),
      );
      final anchored = mixes.firstWhere(
        (mix) => mix.kind == LibraryMixKind.artist,
      );
      expect(anchored.key, 'anchor');
      expect(anchored.label, 'Anchor');
      expect(anchored.songIds.first, 'local_u0-0');
    });

    test('without statistics, other taste hints count as plays', () {
      final songs = _library();
      final plays = libraryMixHintPlays(
        songs,
        LibraryMixHints(
          loved: [
            for (var s = 0; s < 4; s++)
              (artist: 'band 2', title: 'SONG ROCK2-$s'),
          ],
          liked: [
            (song: 'trio 1|song jazz1-0', reward: 0.8, at: day),
            (
              song: 'trio 1|song jazz1-1',
              reward: 0.8,
              at: day.subtract(const Duration(days: 30)),
            ),
            // Skipped, and too old to count.
            (song: 'trio 1|song jazz1-2', reward: 0, at: day),
            (
              song: 'trio 2|song jazz2-0',
              reward: 1,
              at: day.subtract(const Duration(days: 120)),
            ),
          ],
          queued: const ['/music/hh3-0.flac', '/music/hh3-1.flac'],
          albums: [(album: songs.first.album, artist: 'Tyler, The Creator')],
        ),
        day,
      );
      expect(plays['local_rock2-0'], 3);
      expect(plays['local_jazz1-0'], closeTo(1.6, 1e-9));
      expect(plays['local_jazz1-1'], closeTo(0.8, 1e-9));
      expect(plays, isNot(contains('local_jazz1-2')));
      expect(plays, isNot(contains('local_jazz2-0')));
      expect(plays['local_hh3-1'], 1);
      expect(plays['local_hh0-0'], 0.5);
      expect(plays, isNot(contains('local_hh1-0')));

      final mixes = buildLibraryMixes(
        LibraryMixRequest(songs: songs, at: day, exists: exists, plays: plays),
      );
      expect(mixes.first.kind, LibraryMixKind.favorites);
      expect(mixes.first.songIds.first, startsWith('local_rock2-'));
    });

    test('without statistics or hints, there is no favorites mix', () {
      final songs = _library();
      final plays = libraryMixHintPlays(songs, const LibraryMixHints(), day);
      expect(plays, isEmpty);
      final mixes = buildLibraryMixes(
        LibraryMixRequest(songs: songs, at: day, exists: exists, plays: plays),
      );
      expect(mixes, isNotEmpty);
      expect(
        mixes.map((mix) => mix.kind),
        isNot(contains(LibraryMixKind.favorites)),
      );
    });

    test('a small genre never borrows whole neighboring genres', () {
      // A J-Rock band also tagged Rock linked J-Pop to every rock song,
      // and pop with it, before.
      final songs = [
        for (var a = 0; a < 6; a++)
          for (var s = 0; s < 3; s++) _song('jp$a-$s', 'Idol $a', 'J-Pop'),
        for (var s = 0; s < 3; s++) _song('jr$s', 'J Band', 'J-Rock'),
        for (var s = 0; s < 6; s++) _song('jbr$s', 'J Band', 'Rock'),
        for (var a = 0; a < 8; a++)
          for (var s = 0; s < 6; s++) _song('rock$a-$s', 'Band $a', 'Rock'),
        for (var a = 0; a < 8; a++)
          for (var s = 0; s < 6; s++) _song('pop$a-$s', 'Singer $a', 'Pop'),
      ];
      final byId = {for (final song in songs) song.id: song};
      final mixes = buildLibraryMixes(
        LibraryMixRequest(
          songs: songs,
          at: day,
          exists: exists,
          plays: {'local_jp0-0': 5, 'local_rock0-0': 1},
        ),
      );
      final jpop = mixes.singleWhere((mix) => mix.key == 'jpop');
      for (final id in jpop.songIds) {
        expect(byId[id]!.genre, anyOf('J-Pop', 'J-Rock'), reason: id);
      }
    });

    test('the New Additions mix holds the songs added lately', () {
      final songs = _library();
      final fresh = {
        for (var a = 0; a < 5; a++)
          for (var s = 0; s < 2; s++) ...['local_hh$a-$s', 'local_rock$a-$s'],
        for (var a = 0; a < 5; a++) 'local_jazz$a-0',
      };
      final mixes = buildLibraryMixes(
        LibraryMixRequest(
          songs: songs,
          at: day,
          exists: exists,
          added: {
            for (final song in songs)
              song.id: day.subtract(
                Duration(days: fresh.contains(song.id) ? 3 : 200),
              ),
          },
        ),
      );
      final mix = mixes.singleWhere((mix) => mix.kind == LibraryMixKind.fresh);
      expect(mix.songIds.length, greaterThanOrEqualTo(libraryMixMinSongs));
      expect(fresh, containsAll(mix.songIds));
    });

    test('a Library added all at once has no New Additions mix', () {
      final songs = _library();
      final mixes = buildLibraryMixes(
        LibraryMixRequest(
          songs: songs,
          at: day,
          exists: exists,
          added: {for (final song in songs) song.id: day},
        ),
      );
      expect(
        mixes.map((mix) => mix.kind),
        isNot(contains(LibraryMixKind.fresh)),
      );
    });

    test('Rediscover holds songs played before and not since', () {
      final songs = _library();
      final past = {
        for (var a = 0; a < 5; a++)
          for (var s = 0; s < 2; s++) ...['local_hh$a-$s', 'local_rock$a-$s'],
        for (var a = 0; a < 7; a++) 'local_jazz$a-0',
      };
      final mixes = buildLibraryMixes(
        LibraryMixRequest(
          songs: songs,
          at: day,
          exists: exists,
          pastPlays: {for (final id in past) id: 4},
          // Played again lately: no longer forgotten.
          plays: {'local_hh0-0': 2, 'local_rock0-0': 1},
        ),
      );
      final mix = mixes.singleWhere(
        (mix) => mix.kind == LibraryMixKind.rediscover,
      );
      expect(past, containsAll(mix.songIds));
      expect(mix.songIds, isNot(contains('local_hh0-0')));
      expect(mix.songIds, isNot(contains('local_rock0-0')));
    });

    test('Discover holds unplayed songs of the genres played most', () {
      final songs = [
        for (var a = 0; a < 8; a++)
          for (var s = 0; s < 15; s++) _song('hh$a-$s', 'Rapper $a', 'Rap'),
        for (var a = 0; a < 6; a++)
          for (var s = 0; s < 6; s++) _song('jazz$a-$s', 'Trio $a', 'Jazz'),
      ];
      final played = {for (var a = 0; a < 8; a++) 'local_hh$a-0': 3.0};
      final mixes = buildLibraryMixes(
        LibraryMixRequest(
          songs: songs,
          at: day,
          exists: exists,
          plays: played,
          pastPlays: {'local_hh0-1': 2},
        ),
      );
      final mix = mixes.singleWhere(
        (mix) => mix.kind == LibraryMixKind.discover,
      );
      for (final id in mix.songIds) {
        expect(id, startsWith('local_hh'));
        expect(played, isNot(contains(id)));
        expect(id, isNot('local_hh0-1'));
      }
      // Without plays there is no taste to discover from.
      expect(
        buildLibraryMixes(
          LibraryMixRequest(songs: songs, at: day, exists: exists),
        ).map((mix) => mix.kind),
        isNot(contains(LibraryMixKind.discover)),
      );
    });

    test('a decade with enough songs in its main genres is a mix', () {
      final songs = _library();
      final mixes = buildLibraryMixes(
        LibraryMixRequest(
          songs: songs,
          at: day,
          exists: exists,
          years: {
            // The 1990s: rock and hip-hop lead, so its few jazz songs stay
            // out of its mix.
            for (var a = 0; a < 3; a++)
              for (var s = 0; s < 6; s++) ...{
                'local_rock$a-$s': 1994,
                'local_hh$a-$s': 1997,
              },
            for (var a = 0; a < 4; a++) 'local_jazz$a-0': 1991,
            // Too few to make the 2000s a mix.
            for (var a = 4; a < 7; a++) 'local_jazz$a-0': 2004,
          },
        ),
      );
      final decades = [
        for (final mix in mixes)
          if (mix.kind == LibraryMixKind.decade) mix,
      ];
      expect(decades.map((mix) => mix.label), ['1990']);
      for (final id in decades.single.songIds) {
        expect(id, matches(RegExp(r'^local_(rock|hh)[0-2]-')));
      }
    });

    test('discoveries follow the favorites and the two mixes played most', () {
      final songs = _library();
      final mixes = buildLibraryMixes(
        LibraryMixRequest(
          songs: songs,
          at: day,
          exists: exists,
          plays: {
            for (var s = 0; s < 6; s++) 'local_hh0-$s': 10.0 + s,
            for (var s = 0; s < 3; s++) 'local_rock0-$s': 2.0,
            'local_jazz0-0': 1,
          },
          pastPlays: {
            for (var a = 1; a < 6; a++)
              for (var s = 0; s < 4; s++) 'local_hh$a-$s': 3,
          },
        ),
      );
      final kinds = mixes.map((mix) => mix.kind).toList();
      expect(kinds.first, LibraryMixKind.favorites);
      expect(kinds.indexOf(LibraryMixKind.rediscover), 3);
      expect(mixes.length, lessThanOrEqualTo(libraryMixMaxCount));
    });

    test('a mix survives a JSON round trip', () {
      const mix = LibraryMix(
        kind: LibraryMixKind.genre,
        key: 'hiphop',
        label: 'Hip-Hop',
        artists: ['Tyler, The Creator', 'Rapper 1'],
        songIds: ['local_1', 'dl_2'],
      );
      final copy = LibraryMix.fromJson(mix.toJson())!;
      expect(copy.toJson(), mix.toJson());
      expect(LibraryMix.fromJson({'kind': 'unknown'}), isNull);
    });
  });

  group('Library songs', () {
    late SqliteProcessDatabase db;
    late LibraryQueueStore store;

    setUp(() async {
      db = await SqliteProcessDatabase.open();
      await LibrarySchema.create(db, LibrarySchema.version);
      await db.execute("ATTACH DATABASE ':memory:' AS history_db");
      await db.execute('''
        CREATE TABLE history_db.history (
          id TEXT PRIMARY KEY, file_path TEXT, track_name TEXT,
          artist_name TEXT, album_name TEXT, genre TEXT, duration INTEGER,
          release_date TEXT, downloaded_at TEXT
        )
      ''');
      await db.execute('''
        CREATE TABLE history_db.history_path_keys (
          item_id TEXT NOT NULL, path_key TEXT NOT NULL,
          PRIMARY KEY (item_id, path_key)
        )
      ''');
      await db.insert('history_db.history', {
        'id': 'download',
        'file_path': '/music/download.flac',
        'track_name': 'Downloaded',
        'artist_name': 'Artist',
        'album_name': 'Album',
        'genre': 'Rap',
        'duration': 200,
        'release_date': '2019-05-10',
        'downloaded_at': '2026-10-20T10:00:00.000',
      });
      await db.insert('history_db.history', {'id': 'pending', 'file_path': ''});
      await db.insert('history_db.history_path_keys', {
        'item_id': 'download',
        'path_key': 'shared',
      });
      for (final (id, key) in [('copy', 'shared'), ('scanned', 'own')]) {
        await db.insert('library', {
          'id': id,
          'source_id': 'legacy',
          'track_name': id,
          'artist_name': 'Artist',
          'album_name': 'Album',
          'album_key': 'album|artist',
          'file_path': '/music/$id.flac',
          'scanned_at': '2026-10-27T00:00:00Z',
          'genre': 'Jazz',
          'duration': 180,
          'release_date': '1959',
          'file_mod_time': 1700000000000,
        });
        await db.insert('library_path_keys', {'item_id': id, 'path_key': key});
      }
      store = LibraryQueueStore(db, historyFts: false, localFts: false);
    });
    tearDown(() => db.close());

    test(
      'pages hold downloads and the scanned files they do not shadow',
      () async {
        final first = await store.mixSongs(source: 'downloaded', limit: 1);
        final second = await store.mixSongs(source: 'local', limit: 10);
        expect(
          [...first, ...second],
          [
            {
              'source': 'downloaded',
              'id': 'download',
              'file_path': '/music/download.flac',
              'track_name': 'Downloaded',
              'artist_name': 'Artist',
              'album_name': 'Album',
              'genre': 'Rap',
              'duration': 200,
              'release_date': '2019-05-10',
              'added_at': '2026-10-20T10:00:00.000',
              'file_mod_time': null,
            },
            {
              'source': 'local',
              'id': 'scanned',
              'file_path': '/music/scanned.flac',
              'track_name': 'scanned',
              'artist_name': 'Artist',
              'album_name': 'Album',
              'genre': 'Jazz',
              'duration': 180,
              'release_date': '1959',
              'added_at': '2026-10-27T00:00:00Z',
              'file_mod_time': 1700000000000,
            },
          ],
        );
        expect(libraryMixReleaseYear(first.single['release_date']), 2019);
        expect(libraryMixReleaseYear(second.single['release_date']), 1959);
        expect(libraryMixReleaseYear(''), isNull);
        expect(libraryMixReleaseYear(null), isNull);
        expect(libraryMixAddedAt(first.single), DateTime(2026, 10, 20, 10));
        // A scanned file counts from when it was modified, not scanned.
        expect(
          libraryMixAddedAt(second.single),
          DateTime.fromMillisecondsSinceEpoch(1700000000000),
        );
        // A pending download without a file is no song.
        expect(
          await store.mixSongs(
            source: 'downloaded',
            afterId: 'download',
            limit: 10,
          ),
          isEmpty,
        );
      },
    );

    test('keyset pages list the songs OFFSET pages did, in order', () async {
      // Ids out of insertion order, scanned copies a download shadows,
      // files without a path and a source that is offline.
      await db.insert('library_sources', {
        'id': 'offline',
        'path': '/offline',
        'display_name': 'Offline',
        'enabled': 1,
        'available': 0,
      });
      for (var index = 0; index < 23; index++) {
        final id = 'h${(index * 7) % 23}';
        await db.insert('history_db.history', {
          'id': id,
          'file_path': index % 9 == 4 ? '' : '/music/$id.flac',
          'track_name': 'Download $index',
          'artist_name': 'Artist ${index % 3}',
          'album_name': 'Album',
          'genre': 'Rap',
          'duration': 200 + index,
          'release_date': '2019',
          'downloaded_at': '2026-10-20T10:00:00.000',
        });
        if (index % 4 == 0) {
          await db.insert('history_db.history_path_keys', {
            'item_id': id,
            'path_key': 'shadow-$index',
          });
        }
      }
      for (var index = 0; index < 31; index++) {
        final id = 's${(index * 11) % 31}';
        await db.insert('library', {
          'id': id,
          'source_id': index % 10 == 3 ? 'offline' : 'legacy',
          'track_name': 'Scanned $index',
          'artist_name': 'Artist ${index % 5}',
          'album_name': 'Album $index',
          'album_key': 'album$index|artist',
          'file_path': index == 6 ? '' : '/music/$id.flac',
          'scanned_at': '2026-10-27T00:00:00Z',
          'genre': 'Jazz',
          'duration': 180 + index,
          'release_date': '${1990 + index}',
          'file_mod_time': 1700000000000 + index,
        });
        await db.insert('library_path_keys', {
          'item_id': id,
          'path_key': index.isEven && index < 23
              ? 'shadow-$index'
              : 'own-$index',
        });
      }

      Future<List<Map<String, Object?>>> offsetPages(bool includeLocal) async {
        final rows = <Map<String, Object?>>[];
        for (var offset = 0; ; offset += 5) {
          final page = await db.rawQuery(
            '''
            SELECT * FROM (
              SELECT 'downloaded' AS source, h.id, h.file_path, h.track_name,
                h.artist_name, h.album_name, h.genre, h.duration,
                h.release_date, h.downloaded_at AS added_at,
                NULL AS file_mod_time
              FROM history_db.history h
              WHERE COALESCE(h.file_path, '') != ''
              ${includeLocal ? '''
              UNION ALL
              SELECT 'local' AS source, l.id, l.file_path, l.track_name,
                l.artist_name, l.album_name, l.genre, l.duration,
                l.release_date, l.scanned_at AS added_at, l.file_mod_time
              FROM ${LibrarySchema.visibleView} l
              WHERE COALESCE(l.file_path, '') != ''
                AND ${libraryNotShadowedSql('l')}
              ''' : ''}
            )
            ORDER BY source, id
            LIMIT ? OFFSET ?
            ''',
            [5, offset],
          );
          rows.addAll(page);
          if (page.length < 5) return rows;
        }
      }

      Future<List<Map<String, Object?>>> keysetPages(bool includeLocal) async {
        final rows = <Map<String, Object?>>[];
        for (final source in ['downloaded', if (includeLocal) 'local']) {
          String? afterId;
          while (true) {
            final page = await store.mixSongs(
              source: source,
              afterId: afterId,
              limit: 5,
            );
            rows.addAll(page);
            afterId = page.lastOrNull?['id'] as String?;
            if (page.length < 5 || afterId == null) break;
          }
        }
        return rows;
      }

      for (final includeLocal in [true, false]) {
        final expected = await offsetPages(includeLocal);
        expect(expected, hasLength(includeLocal ? 43 : 21));
        expect(await keysetPages(includeLocal), expected);
      }
    });
  });

  group('cached mixes', () {
    bool stale({
      String day = '2026-10-27',
      bool includeLocal = true,
      int count = 500,
      bool cachedEmpty = false,
    }) => libraryMixesStale(
      cachedDay: '2026-10-27',
      cachedIncludeLocal: true,
      cachedCount: 500,
      cachedEmpty: cachedEmpty,
      day: day,
      includeLocal: includeLocal,
      count: count,
    );

    test('last the day while the Library holds steady', () {
      expect(stale(), isFalse);
      expect(stale(count: 520), isFalse);
      expect(stale(count: 460), isFalse);
    });

    test('give way to a new day, a Local Library switch or a large change', () {
      expect(stale(day: '2026-10-28'), isTrue);
      expect(stale(includeLocal: false), isTrue);
      expect(stale(count: 550), isTrue);
      expect(stale(count: 440), isTrue);
      expect(stale(count: 501, cachedEmpty: true), isTrue);
    });
  });
}
