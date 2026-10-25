import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/services/library_database.dart';
import 'package:mornye/services/music_player_service.dart';

PlayableMedia track(
  String id, {
  String artist = 'Artist',
  String? genre,
  String? source,
}) => PlayableMedia(
  id: id,
  source: source ?? '/$id.flac',
  title: id,
  artist: artist,
  genre: genre,
);

/// Favors 'a', then each song after the one it names.
class _ChainSignal extends AutoplaySignal {
  _ChainSignal(this.after);

  final Map<String, String> after;
  List<PlayableMedia> session = const [], candidates = const [];

  @override
  String get name => 'chain';

  @override
  void prepare(List<PlayableMedia> session, List<PlayableMedia> candidates) {
    this.session = session;
    this.candidates = candidates;
  }

  @override
  double score(PlayableMedia candidate) => candidate.id == 'a' ? 5 : 0;

  @override
  double follow(PlayableMedia previous, PlayableMedia candidate) =>
      after[candidate.id] == previous.id ? 10 : 0;
}

class _NoNoise implements Random {
  @override
  double nextDouble() => 0;
  @override
  int nextInt(int max) => 0;
  @override
  bool nextBool() => false;
}

/// A Library whose every page holds [rows].
class _Library implements LibraryDatabase {
  _Library(this.rows);

  final List<Map<String, dynamic>> rows;

  @override
  Future<QueueLibraryCounts> getQueueCounts(
    QueueLibraryDbQuery request,
  ) async => QueueLibraryCounts(
    allTrackCount: rows.length,
    albumCount: 0,
    singleTrackCount: 0,
  );

  @override
  Future<List<Map<String, dynamic>>> getQueueTrackPage(
    QueueLibraryDbQuery request,
  ) async => rows;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test('Autoplay prefers related unplayed Library tracks, after another '
      'artist, and deduplicates', () {
    final seed = track('seed', genre: 'Rock');
    final related = track('related', genre: 'Rock');
    final recent = track('recent', genre: 'Rock');
    final selected = selectAutoplayTracks(
      seed: seed,
      candidates: [
        seed,
        related,
        related,
        recent,
        track('unrelated', artist: 'Other'),
        track('queued'),
        track('dismissed'),
        track('remote', source: 'https://example.com/audio.flac'),
        track('related', source: '/copy.flac', genre: 'Rock'),
      ],
      upcoming: [track('queued')],
      recent: [recent],
      dismissedSources: {'/dismissed.flac'},
      random: Random(1),
    );
    // The seed's artist plays now and next ('queued'), so another comes
    // first.
    expect(selected.map((item) => item.id), ['unrelated', 'related', 'recent']);
  });

  test('a favorite artist does not take over the queue', () {
    final seed = track('seed', artist: 'Favorite', genre: 'Pop');
    final selected = selectAutoplayTracks(
      seed: seed,
      candidates:
          [
                for (var i = 0; i < 10; i++) track('fav$i', artist: 'Favorite'),
                for (var i = 0; i < 10; i++) track('pop$i', artist: 'Pop $i'),
              ]
              .map((item) => track(item.id, artist: item.artist, genre: 'Pop'))
              .toList(),
      upcoming: [],
      recent: [seed],
      dismissedSources: {},
      random: Random(3),
      // Even a strong learned preference.
      preferenceAdjustment: (item) => item.artist == 'Favorite' ? 9 : 0,
    );
    final favorites = [
      for (var i = 0; i < selected.length; i++)
        if (selected[i].artist == 'Favorite') i,
    ];
    expect(selected, hasLength(6));
    expect(favorites, hasLength(1));
    // Three other artists play between the seed and its artist's return.
    expect(favorites.single, greaterThanOrEqualTo(3));
  });

  test('the session sets the genres, not the seed alone', () {
    final selected = selectAutoplayTracks(
      seed: track('seed', artist: 'Untagged'),
      candidates: [
        for (var i = 0; i < 3; i++)
          track('rock$i', artist: 'R$i', genre: 'Rock'),
        for (var i = 0; i < 3; i++)
          track('jazz$i', artist: 'J$i', genre: 'Jazz; Soul'),
      ],
      upcoming: [],
      recent: [
        track('heard1', artist: 'H1', genre: 'Jazz'),
        track('heard2', artist: 'H2', genre: 'Soul'),
      ],
      dismissedSources: {},
      random: Random(1),
      limit: 3,
    );
    expect(selected.map((item) => item.genre), everyElement('Jazz; Soul'));
  });

  test('signals score songs and how each follows the one before', () {
    final signal = _ChainSignal({'b': 'a', 'c': 'b', 'd': 'c'});
    final selected = selectAutoplayTracks(
      seed: track('seed', artist: 'S'),
      candidates: [
        for (final id in ['d', 'c', 'b', 'a']) track(id, artist: id),
      ],
      upcoming: [],
      recent: [],
      dismissedSources: {},
      random: _NoNoise(),
      signals: [signal],
    );
    expect(signal.session.map((item) => item.id), ['seed']);
    expect(signal.candidates, hasLength(4));
    // 'a' scores most on its own; each other song follows only one.
    expect(selected.map((item) => item.id), ['a', 'b', 'c', 'd']);
  });

  test('picks carry their score parts, which weights multiply', () {
    final seed = track('seed', artist: 'S', genre: 'Rock');
    List<AutoplayPick> rank(Map<String, double> weights) => rankAutoplayTracks(
      seed: seed,
      candidates: [
        track('rock', artist: 'R', genre: 'Rock'),
        track('chain', artist: 'C'),
      ],
      upcoming: [],
      recent: [seed],
      dismissedSources: {},
      random: _NoNoise(),
      limit: 1,
      signals: [
        _ChainSignal({'chain': 'seed'}),
      ],
      weights: weights,
    );
    final first = rank(const {}).single;
    // Following the seed (10) beats fitting its genre (6); both artists
    // are new to the session.
    expect(first.media.id, 'chain');
    expect(first.parts, {
      'genre': 0,
      'signal:chain': 0,
      'novelty': 1,
      'follow:chain': 10,
    });
    // A listener for whom transitions count little.
    final rock = rank(const {'follow:chain': 0.5}).single;
    expect(rock.media.id, 'rock');
    expect(rock.parts['genre'], 6);
    expect(rock.parts['follow:chain'], 0);
  });

  test('a one-artist Library still fills the queue', () {
    final selected = selectAutoplayTracks(
      seed: track('seed', artist: 'Solo'),
      candidates: [for (var i = 0; i < 4; i++) track('solo$i', artist: 'Solo')],
      upcoming: [],
      recent: [],
      dismissedSources: {},
      random: Random(1),
    );
    expect(selected, hasLength(4));
  });

  test('a small Library never recommends the current song to itself', () {
    final seed = track('only');
    expect(
      selectAutoplayTracks(
        seed: seed,
        candidates: [seed],
        upcoming: [],
        recent: [seed],
        dismissedSources: {},
        random: Random(1),
      ),
      isEmpty,
    );
  });

  test('recency uses the latest source or normalized song match', () {
    final source = track('source-match', artist: 'A', source: '/same.flac');
    final song = track(' Song ', artist: ' ARTIST ');
    final older = track('older', artist: 'D');
    final unplayed = track('new', artist: 'E');
    final selected = selectAutoplayTracks(
      seed: track('seed', artist: 'Seed'),
      candidates: [source, song, older, unplayed],
      upcoming: [],
      recent: [
        track('source-match', artist: ' a ', source: '/copy.flac'),
        older,
        track(' song ', artist: 'artist', source: '/other.flac'),
        track('renamed', artist: 'different', source: '/same.flac'),
      ],
      dismissedSources: {},
      random: _NoNoise(),
    );
    expect(selected, [unplayed, older, song, source]);
  });

  test('bounded ranking retains its seeded ordering with a full history', () {
    PlayableMedia song(int id) => PlayableMedia(
      id: '$id',
      source: '/music/$id.flac',
      title: ' Song $id ',
      artist: ' Artist ${id % 24} ',
      album: ' Album ${id % 35} ',
      genre: ' Genre ${id % 8} ',
    );
    final selected = selectAutoplayTracks(
      seed: song(1000),
      candidates: List.generate(384, song),
      upcoming: [song(16), song(17)],
      recent: List.generate(200, (i) => song(i + 192)),
      dismissedSources: {'/music/18.flac'},
      random: Random(1),
    );
    expect(selected.map((item) => item.id), [
      '96',
      '80',
      '81',
      '25',
      '90',
      '135',
    ]);
    // Six artists, none heard in the last songs.
    expect(selected.map((item) => item.artist).toSet(), hasLength(6));
  });

  test('Autoplay preference and recommendation provenance survive restore', () {
    expect(AppSettings.fromJson({}).autoplay, isFalse);
    final settings = const AppSettings().copyWith(autoplay: true);
    expect(AppSettings.fromJson(settings.toJson()).autoplay, isTrue);
    final media = PlayableMedia.fromJson({
      ...track('one', genre: 'Rock').toJson(),
      'autoplay': true,
    })!;
    final restored = PlayableMedia.fromJson(media.toJson())!;
    expect(restored.autoplay, isTrue);
    expect(restored.genre, 'Rock');
    expect(restored.toMediaItem().extras?['autoplay'], isTrue);
  });

  test(
    'Autoplay draws on network Library songs while their host is reachable',
    () async {
      final dir = await Directory.systemTemp.createTemp('autoplay_library');
      addTearDown(() => dir.delete(recursive: true));
      final local = File('${dir.path}/local.flac')..writeAsStringSync('x');
      Map<String, dynamic> row(String id, String path) => {
        'item': {
          'id': id,
          'filePath': path,
          'trackName': id,
          'artistName': 'A',
        },
      };
      final asked = <String>[];
      final runtime = MusicPlayerRuntime(
        settings: const AppSettings(localLibraryEnabled: true),
        dependencies: PlaybackDependencies(
          libraryDatabase: _Library([
            row('local', local.path),
            row('missing', '${dir.path}/missing.flac'),
            row('phone 1', 'network://link-phone-1/a.flac'),
            row('phone 2', 'network://link-phone-1/b.flac'),
            row('away', 'network://link-phone-2/c.flac'),
            row('web', 'https://example.com/d.flac'),
          ]),
          networkSourceReachable: (source) async {
            asked.add(source);
            return source.contains('link-phone-1');
          },
        ),
      );

      final songs = await loadAutoplayLibrary(track('seed'), runtime);
      expect(songs.map((song) => song.id), ['local', 'phone 1', 'phone 2']);
      // One question per host.
      expect(asked, [
        'network://link-phone-1/a.flac',
        'network://link-phone-2/c.flac',
      ]);
    },
  );
}
