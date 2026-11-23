import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/providers/library_mixes_provider.dart';
import 'package:mornye/services/autoplay_taste.dart';
import 'package:mornye/services/library_mixes.dart';
import 'package:mornye/services/library_queue_store.dart';
import 'package:mornye/services/library_schema.dart';
import 'package:mornye/services/library_shadow_sql.dart';
import 'package:mornye/services/listening_statistics.dart';
import 'package:mornye/services/playable_media.dart';
import 'package:mornye/services/sqlite_helpers.dart' show normalizeLookupText;

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

/// Two large genres and seven small ones, each enough for a mix.
List<PlayableMedia> _wideLibrary() {
  const small = [
    'Country',
    'Electronic',
    'Folk',
    'Jazz',
    'Metal',
    'Pop',
    'Reggae',
  ];
  return [
    for (var a = 0; a < 30; a++)
      for (var s = 0; s < 6; s++) _song('hh$a-$s', 'Rapper $a', 'Hip-Hop'),
    for (var a = 0; a < 20; a++)
      for (var s = 0; s < 6; s++) _song('rock$a-$s', 'Band $a', 'Rock'),
    for (final (g, genre) in small.indexed)
      for (var a = 0; a < 7; a++)
        for (var s = 0; s < 3; s++)
          _song('small$g-$a-$s', '$genre Act $a', genre),
  ];
}

Map<String, Object?> _json(List<LibraryMix> mixes) => {
  for (final mix in mixes) '${mix.kind.name}:${mix.key}': mix.toJson(),
};

ListeningTotal _heard(String source, String artist, String title, int plays) =>
    ListeningTotal(
      ListeningTrack(
        key: source,
        title: title,
        artist: artist,
        album: '',
        artwork: 'https://example.com/cover.jpg',
      ),
      plays * 180000,
      plays,
    );

/// Plays by song id as the provider counted them before the mix worker did.
Map<String, double> _playsInline(
  List<PlayableMedia> songs,
  List<ListeningSummary> summaries,
) {
  String songKey(String artist, String title) =>
      '${normalizeLookupText(artist)}|${normalizeLookupText(title)}';
  final bySource = <String, double>{}, bySong = <String, double>{};
  for (final summary in summaries) {
    for (final total in summary.tracks) {
      if (total.plays <= 0) continue;
      final track = total.track;
      bySource[track.key] = (bySource[track.key] ?? 0) + total.plays;
      final key = songKey(track.artist, track.title);
      bySong[key] = (bySong[key] ?? 0) + total.plays;
    }
  }
  return {
    for (final song in songs)
      song.id:
          ?(bySource[song.source] ?? bySong[songKey(song.artist, song.title)]),
  };
}

/// The mixes as the provider made them before the mix worker read the
/// plays and the taste model itself.
List<LibraryMix> _mixesInline({
  required List<PlayableMedia> songs,
  required DateTime at,
  required List<ListeningSummary> recent,
  required ListeningSummary past,
  LibraryMixHints hints = const LibraryMixHints(),
  AutoplayTasteModel? taste,
}) {
  final plays = _playsInline(songs, recent);
  final pastPlays = _playsInline(songs, [past]);
  if (plays.length < libraryMixFavoritesMinPlayed) {
    final hinted = libraryMixHintPlays(songs, hints, at);
    for (final MapEntry(:key, :value) in hinted.entries) {
      plays[key] = (plays[key] ?? 0) + value;
    }
  }
  final favorites = songs.where((song) => (plays[song.id] ?? 0) > 0).toList()
    ..sort((a, b) => plays[b.id]!.compareTo(plays[a.id]!));
  final session = favorites.take(16).toList();
  final signal = taste != null && session.isNotEmpty
      ? autoplayTasteSignal(taste, session, songs)
      : null;
  return buildLibraryMixes(
    LibraryMixRequest(
      songs: songs,
      at: at,
      plays: plays,
      pastPlays: pastPlays,
      signals: [?signal],
      exists: (_) => true,
    ),
  );
}

/// A taste model that knows the first [count] songs, the artists of every
/// third of them and one artist credited only beside others.
AutoplayTasteModel _tasteModel(List<PlayableMedia> songs, int count) {
  String key(String value) => normalizeLookupText(value);
  final tokens = <String>{
    for (final song in songs.take(count))
      'song:${key(song.artist)}|${key(song.title)}',
    for (final song in songs.take(count).indexed)
      if (song.$1 % 3 == 0) 'artist:${key(song.$2.artist)}',
    'artist:guest star',
  }.toList();
  final random = Random(11);
  final vectors = Float32List(tokens.length * AutoplayTasteModel.dimensions);
  for (var row = 0; row < tokens.length; row++) {
    var norm = 0.0;
    for (var k = 0; k < AutoplayTasteModel.dimensions; k++) {
      final value = random.nextDouble() - 0.5;
      vectors[row * AutoplayTasteModel.dimensions + k] = value;
      norm += value * value;
    }
    for (var k = 0; k < AutoplayTasteModel.dimensions; k++) {
      vectors[row * AutoplayTasteModel.dimensions + k] /= sqrt(norm);
    }
  }
  return AutoplayTasteModel(
    tokens: tokens,
    vectors: vectors,
    positives: 500,
    through: 500,
  );
}

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

    test('Deep Cuts holds what the artists played most are not played for', () {
      final songs = _wideLibrary();
      final mixes = buildLibraryMixes(
        LibraryMixRequest(
          songs: songs,
          at: day,
          exists: exists,
          // One song each of five rappers is played.
          plays: {for (var a = 0; a < 5; a++) 'local_hh$a-0': 9.0 - a},
        ),
      );
      final deep = mixes.singleWhere(
        (mix) => mix.kind == LibraryMixKind.deepCuts,
      );
      expect(deep.songIds.length, greaterThanOrEqualTo(libraryMixMinSongs));
      for (final id in deep.songIds) {
        expect(id, matches(RegExp(r'^local_hh[0-4]-[1-5]$')));
      }
    });

    test('the newest year with enough songs is a mix', () {
      final songs = _library();
      Map<String, int> released(int year) => {
        for (var a = 0; a < 2; a++)
          for (var s = 0; s < 6; s++) ...{
            'local_hh$a-$s': year,
            'local_rock$a-$s': year,
          },
        for (var a = 0; a < 4; a++)
          for (var s = 0; s < 3; s++) 'local_jazz$a-$s': year,
      };
      LibraryMix year(Map<String, int> years) => buildLibraryMixes(
        LibraryMixRequest(songs: songs, at: day, exists: exists, years: years),
      ).singleWhere((mix) => mix.kind == LibraryMixKind.year);

      final thisYear = year(released(2026));
      expect(thisYear.key, '2026');
      expect(thisYear.label, '2026');
      expect(thisYear.songIds.toSet(), released(2026).keys.toSet());
      // Too few this year: the last one names the mix.
      expect(year({...released(2025), 'local_jazz6-0': 2026}).label, '2025');
      // A Library all of one year has no year to set apart.
      expect(
        buildLibraryMixes(
          LibraryMixRequest(
            songs: songs,
            at: day,
            exists: exists,
            years: {for (final song in songs) song.id: 2026},
          ),
        ).where((mix) => mix.kind == LibraryMixKind.year),
        isEmpty,
      );
    });

    test('a tagged Library names a mix after an artist played much', () {
      final songs = _wideLibrary();
      List<LibraryMix> artists(DateTime at) => [
        for (final mix in buildLibraryMixes(
          LibraryMixRequest(
            songs: songs,
            at: at,
            exists: exists,
            plays: {
              for (var a = 0; a < 4; a++)
                for (var s = 0; s < 6; s++) 'local_hh$a-$s': 20.0 - a,
            },
          ),
        ))
          if (mix.kind == LibraryMixKind.artist) mix,
      ];
      final leading = {'Rapper 0', 'Rapper 1', 'Rapper 2', 'Rapper 3'};
      final first = <String>{};
      for (var d = 0; d < 12; d++) {
        final mixes = artists(day.add(Duration(days: d)));
        expect(mixes, isNotEmpty);
        expect(mixes.length, lessThanOrEqualTo(2));
        for (final mix in mixes) {
          expect(leading, contains(mix.label));
        }
        first.add(mixes.first.label);
      }
      // The artist is not the same one every day.
      expect(first.length, greaterThan(1));
    });

    test('a genre keeps its mix over an artist mix of the same songs', () {
      const played = ['Rock', 'Pop', 'Jazz'];
      final songs = [
        for (final genre in played)
          for (var a = 0; a < 12; a++)
            for (var s = 0; s < 3; s++)
              _song('$genre$a-$s', '$genre Act $a', genre),
        // The fourth genre, whose one played artist has songs enough to
        // name a mix drawn from the same songs.
        for (var a = 0; a < 8; a++)
          for (var s = 0; s < 5; s++)
            _song('metal$a-$s', 'Metal Act $a', 'Metal'),
      ];
      final mixes = buildLibraryMixes(
        LibraryMixRequest(
          songs: songs,
          at: day,
          exists: exists,
          plays: {
            for (final genre in played)
              for (var a = 0; a < 4; a++) 'local_$genre$a-0': 9,
            for (var s = 0; s < 5; s++) 'local_metal0-$s': 2,
          },
        ),
      );
      expect([
        for (final mix in mixes)
          if (mix.kind == LibraryMixKind.genre) mix.key,
      ], containsAll(['rock', 'pop', 'jazz', 'metal']));
      expect(mixes.where((mix) => mix.kind == LibraryMixKind.artist), isEmpty);
    });

    test('one genre past the five played most joins, a new one each day', () {
      final songs = _wideLibrary();
      const leading = ['hiphop', 'rock', 'country', 'electronic', 'folk'];
      const others = {'jazz', 'metal', 'pop', 'reggae'};
      final extra = <String>{};
      for (var d = 0; d < 12; d++) {
        final genres = [
          for (final mix in buildLibraryMixes(
            LibraryMixRequest(
              songs: songs,
              at: day.add(Duration(days: d)),
              exists: exists,
            ),
          ))
            if (mix.kind == LibraryMixKind.genre) mix.key,
        ];
        expect(genres.toSet(), containsAll(leading));
        expect(genres.length, 6);
        final added = genres.toSet().difference(leading.toSet()).single;
        expect(others, contains(added));
        extra.add(added);
      }
      expect(extra.length, greaterThan(1));
    });

    test('discoveries take turns with the mixes played less', () {
      final songs = _wideLibrary();
      final mixes = buildLibraryMixes(
        LibraryMixRequest(
          songs: songs,
          at: day,
          exists: exists,
          plays: {
            for (var a = 0; a < 4; a++)
              for (var s = 0; s < 3; s++) 'local_hh$a-$s': 12.0 - a,
            'local_rock0-0': 3,
          },
          pastPlays: {
            for (var a = 4; a < 12; a++)
              for (var s = 0; s < 4; s++) 'local_rock$a-$s': 2,
          },
          added: {
            for (var a = 0; a < 7; a++)
              for (var s = 0; s < 3; s++)
                'local_small0-$a-$s': day.subtract(const Duration(days: 3)),
          },
        ),
      );
      bool discovery(LibraryMix mix) => const {
        LibraryMixKind.fresh,
        LibraryMixKind.rediscover,
        LibraryMixKind.discover,
        LibraryMixKind.deepCuts,
      }.contains(mix.kind);
      expect(mixes.first.kind, LibraryMixKind.favorites);
      expect(mixes.where(discovery).length, greaterThanOrEqualTo(2));
      expect(discovery(mixes[1]) || discovery(mixes[2]), isFalse);
      expect(discovery(mixes[3]), isTrue);
      expect(discovery(mixes[4]), isFalse);
      expect(discovery(mixes[5]), isTrue);
      expect(mixes.length, lessThanOrEqualTo(libraryMixMaxCount));
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
          release_date TEXT, downloaded_at TEXT, origin_file_path TEXT
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

    test('are built again when none came out, even at the same total', () {
      expect(stale(cachedEmpty: true), isTrue);
    });
  });

  group('mix worker', () {
    final day = DateTime(2026, 10, 27, 9);
    final songs = [
      ..._wideLibrary(),
      for (var s = 0; s < 4; s++) ...[
        _song('duet$s', 'Rapper 1 & Guest Star', 'Hip-Hop'),
        _song('feature$s', 'Newcomer feat. Guest Star', 'Hip-Hop'),
      ],
    ];
    final season = ListeningSummary(
      tracks: [
        for (var i = 0; i < 40; i++)
          _heard(songs[i].source, songs[i].artist, songs[i].title, 1 + i % 4),
        // Another copy of a Library song, spelled differently.
        _heard('/phone/copy.flac', ' RAPPER 9 ', 'song HH9-2', 3),
        _heard(songs[45].source, songs[45].artist, songs[45].title, 0),
        _heard('/gone/song.flac', 'Nobody', 'Gone', 7),
      ],
    );
    final recent = ListeningSummary(
      tracks: [
        for (var i = 0; i < 10; i++)
          _heard(songs[i].source, songs[i].artist, songs[i].title, 2),
      ],
    );
    final past = ListeningSummary(
      tracks: [
        for (var i = 50; i < 80; i++)
          _heard(songs[i].source, songs[i].artist, songs[i].title, 1),
        // Matched by its file before its title and artist.
        _heard(songs[3].source, 'Other', 'Other', 5),
      ],
    );
    final hints = LibraryMixHints(
      loved: [
        for (var s = 0; s < 4; s++) (artist: 'band 2', title: 'SONG ROCK2-$s'),
      ],
      liked: [(song: 'rapper 4|song hh4-0', reward: 0.8, at: day)],
      queued: const ['/music/hh3-0.flac', '/music/hh3-1.flac'],
    );

    LibraryMixInputs inputs({
      required List<ListeningSummary> recent,
      required ListeningSummary past,
      LibraryMixHints? hints,
      AutoplayTasteModel? taste,
    }) => LibraryMixInputs(
      songs: songs,
      at: day,
      recent: [for (final summary in recent) summary.tracks],
      past: past.tracks,
      hints: hints,
      taste: taste,
      exists: (_) => true,
    );

    test('counts plays as the provider did', () {
      for (final periods in [
        [season, recent],
        [past],
        [const ListeningSummary()],
      ]) {
        expect(
          libraryMixPlays(songs, [for (final p in periods) p.tracks]),
          _playsInline(songs, periods),
        );
      }
      final plays = libraryMixPlays(songs, [season.tracks, recent.tracks]);
      expect(plays[songs[0].id], 3);
      expect(plays['local_hh9-2'], 3);
      expect(plays, isNot(contains(songs[45].id)));
      expect(libraryMixPlays(songs, [past.tracks])[songs[3].id], 5);
    });

    test('makes the mixes the provider made, with and without taste', () {
      final model = _tasteModel(songs, 60);
      // Every song heard lately is known, so the taste signal applies.
      expect(
        autoplayTasteSignal(model, songs.take(16).toList(), songs),
        isNotNull,
      );
      final made = <Map<String, Object?>>[];
      for (final taste in [model, null]) {
        final mixes = buildLibraryMixesFrom(
          inputs(recent: [season, recent], past: past, taste: taste),
        );
        expect(mixes, isNotNull);
        expect(mixes, isNotEmpty);
        made.add(_json(mixes!));
        expect(
          made.last,
          _json(
            _mixesInline(
              songs: songs,
              at: day,
              recent: [season, recent],
              past: past,
              taste: taste,
            ),
          ),
        );
      }
      // The taste model reached the ranking.
      expect(made.first, isNot(made.last));
    });

    test('asks for the hints only while plays are too few', () {
      final few = ListeningSummary(
        tracks: [
          for (var i = 0; i < 3; i++)
            _heard(songs[i].source, songs[i].artist, songs[i].title, 2),
        ],
      );
      final model = _tasteModel(songs, 60);
      expect(
        buildLibraryMixesFrom(inputs(recent: [few], past: past, taste: model)),
        isNull,
      );
      for (final (summary, hinted) in [
        (few, hints),
        (const ListeningSummary(), hints),
        (const ListeningSummary(), const LibraryMixHints()),
      ]) {
        final mixes = buildLibraryMixesFrom(
          inputs(recent: [summary], past: past, hints: hinted, taste: model),
        );
        expect(
          _json(mixes!),
          _json(
            _mixesInline(
              songs: songs,
              at: day,
              recent: [summary],
              past: past,
              hints: hinted,
              taste: model,
            ),
          ),
        );
      }
    });
  });
}
