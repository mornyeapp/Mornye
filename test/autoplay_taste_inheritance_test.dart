import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/autoplay_personalization.dart';
import 'package:mornye/services/autoplay_taste.dart';
import 'package:mornye/services/playable_media.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _d = AutoplayTasteModel.dimensions;

/// A unit vector along [axis], or between two axes.
Float32List _unit(int axis, [int? other]) {
  final vector = Float32List(_d)..[axis] = 1;
  if (other != null) {
    vector[axis] = sqrt1_2;
    vector[other] = sqrt1_2;
  }
  return vector;
}

PlayableMedia _media(
  String artist,
  String title, {
  String album = '',
  String? genre,
}) => PlayableMedia(
  id: '$artist/$title',
  source: '/$artist/$album/$title.flac',
  title: title,
  artist: artist,
  album: album,
  genre: genre,
);

String _song(String artist, String title) =>
    'song:${artist.toLowerCase()}|${title.toLowerCase()}';

final _start = DateTime(2026, 10, 1, 8);

/// Sessions three hours apart of two groups the listener never plays
/// together: Night 1-3 and Day 1-3.
List<AutoplayFeedback> _clusters({int sessions = 16}) {
  final random = Random(5);
  return [
    for (var session = 0; session < sessions; session++)
      for (var i = 0; i < 8; i++)
        AutoplayFeedback(
          kind: AutoplayFeedbackKind.listened,
          track: AutoplayLearningTrack(
            source: '/private/path/$session/$i.flac',
            title: 'Song ${random.nextInt(4)}',
            artist:
                '${session.isEven ? 'Night' : 'Day'} '
                '${1 + random.nextInt(3)}',
          ),
          previous: null,
          at: _start.add(Duration(hours: 3 * session, minutes: 4 * i)),
          reward: 1,
        ),
  ];
}

Future<Database> _database() async {
  sqfliteFfiInit();
  final directory = await Directory.systemTemp.createTemp('taste-inherit-');
  addTearDown(() => directory.delete(recursive: true));
  final db = await AutoplayTaste.openWithFactory(
    databaseFactoryFfi,
    '${directory.path}/taste.db',
  );
  addTearDown(db.close);
  return db;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // The session sits on axis 0; axis 1 is unrelated to it.
  final session = [_media('Session', 'One'), _media('Session', 'Two')];
  Map<String, Float32List> vectors() => {
    _song('Session', 'One'): _unit(0),
    _song('Session', 'Two'): _unit(0),
    _song('Own', 'Fits'): _unit(0),
    _song('Own', 'Apart'): _unit(1),
  };
  final fits = _media('Own', 'Fits');
  final apart = _media('Own', 'Apart');

  test('a song the model does not know inherits from its album, its '
      'credited artists and its genre, each trusted less', () {
    final map = vectors()
      ..[_song('Band', 'Heard 1')] = _unit(0)
      ..[_song('Band', 'Heard 2')] = _unit(0)
      ..[_song('Band', 'Heard 3')] = _unit(0)
      ..[_song('Duo', 'Heard')] = _unit(0)
      ..['artist:guest'] = _unit(0)
      ..[_song('Jazz', 'Known')] = _unit(0)
      ..[_song('Elsewhere', 'Far')] = _unit(1);
    final heard = [
      for (var i = 1; i <= 3; i++)
        _media('Band', 'Heard $i', album: 'Record', genre: 'Rock'),
      _media('Duo', 'Heard', album: 'Pair'),
      _media('Jazz', 'Known', genre: 'Jazz'),
      _media('Elsewhere', 'Far', album: 'Away'),
    ];
    final album = _media('Band', 'Unheard', album: 'Record');
    final smallAlbum = _media('Duo', 'Unheard', album: 'Pair');
    final credited = _media('Newcomer feat. Guest', 'Single');
    final allCredited = _media('Guest', 'Single');
    final genre = _media('Stranger', 'Tune', genre: 'Jazz');
    final farAlbum = _media('Elsewhere', 'Near', album: 'Away');
    // Another artist's album of the same name is not this one.
    final sameName = _media('Other', 'Unheard', album: 'Record');
    final nothing = _media('Nobody', 'Anything');
    final candidates = [
      fits,
      apart,
      ...heard,
      album,
      smallAlbum,
      credited,
      allCredited,
      genre,
      farAlbum,
      sameName,
      nothing,
    ];
    final signal = AutoplayTasteSignal(map)..prepare(session, candidates);
    final own = [fits, apart, ...heard, allCredited].map(signal.score).toList();
    final average = own.reduce((a, b) => a + b) / own.length;
    final scores = {
      for (final media in [album, smallAlbum, credited, genre, farAlbum])
        media.id: signal.score(media),
    };
    debugPrint('Inherited scores $scores, average $average');

    // Nothing to inherit: an average known song, as before.
    expect(signal.score(nothing), closeTo(average, 1e-9));
    expect(signal.score(sameName), closeTo(average, 1e-9));
    // Its own exact artist counts as the song's own vector, as before.
    expect(signal.score(allCredited), signal.score(fits));
    // Inherited vectors move a song less far than its own would.
    for (final media in [album, smallAlbum, credited, genre]) {
      expect(signal.score(media), greaterThan(average));
      expect(signal.score(media), lessThan(signal.score(fits)));
    }
    expect(signal.score(farAlbum), lessThan(average));
    expect(signal.score(farAlbum), greaterThan(signal.score(apart)));
    // More album songs are more evidence; an album beats a guest credit,
    // which beats a genre.
    expect(signal.score(album), greaterThan(signal.score(smallAlbum)));
    expect(signal.score(album), greaterThan(signal.score(credited)));
    expect(signal.score(credited), greaterThan(signal.score(genre)));
  });

  test('known songs score as before, and scores repeat', () {
    final plain = AutoplayTasteSignal(vectors())
      ..prepare(session, [fits, apart, _media('Nobody', 'Anything')]);
    final map = vectors()..['artist:guest'] = _unit(1);
    final candidates = [
      fits,
      apart,
      _media('Nobody', 'Anything'),
      _media('Newcomer & Guest', 'Single'),
    ];
    final first = AutoplayTasteSignal(map)..prepare(session, candidates);
    final second = AutoplayTasteSignal(map)..prepare(session, candidates);
    expect(first.score(fits), plain.score(fits));
    expect(first.score(apart), plain.score(apart));
    expect(
      [for (final media in candidates) first.score(media)],
      [for (final media in candidates) second.score(media)],
    );
  });

  test('songs that can only inherit still score around their mean', () {
    final map = {
      _song('Session', 'One'): _unit(0),
      _song('Session', 'Two'): _unit(0),
      'artist:near': _unit(0),
      'artist:far': _unit(1),
    };
    final near = _media('Near; Newcomer', 'A');
    final far = _media('Far; Newcomer', 'B');
    final nothing = _media('Nobody', 'C');
    final signal = AutoplayTasteSignal(map)
      ..prepare(session, [near, far, nothing]);
    final mean = (signal.score(near) + signal.score(far)) / 2;
    expect(signal.score(near), greaterThan(signal.score(far)));
    expect(signal.score(nothing), closeTo(mean, 1e-9));
  });

  test('the signal carries the credited artists of unknown songs, keys only, '
      'and a Library of 20000 songs stays cheap', () async {
    final db = await _database();
    final taste = AutoplayTaste(
      open: () async => db,
      train: (plays) async => trainAutoplayTaste(plays),
    );
    addTearDown(taste.dispose);
    _clusters().forEach(taste.record);
    await taste.train();
    final listening = [
      _media('Night 1', 'Song 0'),
      _media('Night 2', 'Song 1'),
    ];
    final mate = _media('Night 3 feat. Guest', 'New');
    final stranger = _media('Day 2 feat. Guest', 'New');
    final unknown = _media('Guest', 'New');
    final signal = (await taste.signal(listening, [
      mate,
      stranger,
      unknown,
      _media('Night 3', 'Song 2'),
      _media('Day 1', 'Song 2'),
    ]))!;
    expect(signal.vectors.keys, contains('artist:night 3'));
    expect(signal.vectors.keys, contains('artist:day 2'));
    expect(
      signal.vectors.keys.every(
        (key) =>
            (key.startsWith('song:') || key.startsWith('artist:')) &&
            !key.contains('/'),
      ),
      isTrue,
    );
    signal.prepare(listening, [
      mate,
      stranger,
      unknown,
      _media('Night 3', 'Song 2'),
      _media('Day 1', 'Song 2'),
    ]);
    debugPrint(
      'Credited scores: mate ${signal.score(mate)}, '
      'stranger ${signal.score(stranger)}, unknown ${signal.score(unknown)}',
    );
    expect(signal.score(mate), greaterThan(signal.score(stranger)));

    // A Library where most songs are unknown but share albums, artists and
    // genres with known ones.
    String group(int i) => '${i % 4 < 2 ? 'Night' : 'Day'} ${1 + i % 3}';
    final library = [
      for (var i = 0; i < 20000; i++)
        _media(
          i < 200
              ? group(i)
              : i.isEven
              ? '${group(i)} feat. Guest $i'
              : 'Artist ${i % 500}',
          i < 200 ? 'Song ${i % 4}' : 'Track $i',
          album: 'Album ${i % 700}',
          genre: ['Rock', 'Jazz', 'Pop'][i % 3],
        ),
    ];
    final clock = Stopwatch()..start();
    final large = (await taste.signal(listening, library))!;
    final collected = clock.elapsedMilliseconds;
    large.prepare(listening, library);
    final prepared = clock.elapsedMilliseconds - collected;
    debugPrint(
      'Taste inheritance over ${library.length} songs: signal $collected ms, '
      'prepare $prepared ms, ${large.vectors.length} vectors',
    );
    expect(collected + prepared, lessThan(5000));
  });

  test('the lasting taste follows the latest listening and places credited '
      'artists for less', () {
    final plays = _clusters().map(AutoplayTastePlay.of).toList();
    final model = trainAutoplayTaste(plays);
    final now = DateTime(2027, 6, 1);
    AutoplayTasteProfile profile({required String recent}) =>
        autoplayTasteProfile(model, [
          for (final play in plays)
            AutoplayTastePlay(
              song: play.song,
              artist: play.artist,
              at: now.subtract(
                Duration(days: play.artist.startsWith(recent) ? 1 : 200),
              ),
              kind: play.kind,
              reward: play.reward,
            ),
        ], at: now)!;
    final night = profile(recent: 'night');
    final day = profile(recent: 'day');
    debugPrint(
      'Lasting taste: night ${night.fit('Night 2', 'Song 1')}, '
      '${night.fit('Day 2', 'Song 1')}; credited '
      '${night.fit('Night 1 feat. Guest', 'Unheard')}',
    );
    expect(night.fit('Night 2', 'Song 1'), greaterThan(0));
    expect(
      night.fit('Night 2', 'Song 1'),
      greaterThan(night.fit('Day 2', 'Song 1')!),
    );
    expect(
      day.fit('Day 2', 'Song 1'),
      greaterThan(day.fit('Night 2', 'Song 1')!),
    );
    // An artist's unheard song is the artist; a credit counts for less.
    final artist = night.fit('Night 1', 'Unheard')!;
    final credited = night.fit('Night 1 feat. Guest', 'Unheard')!;
    expect(artist, greaterThan(0));
    expect(credited, greaterThan(0));
    expect(credited, lessThan(artist));
    expect(night.fit('Somebody Else', 'Song 1'), isNull);
    // Skips are not taste.
    expect(
      autoplayTasteProfile(model, [
        for (final play in plays)
          AutoplayTastePlay(
            song: play.song,
            artist: play.artist,
            at: play.at,
            kind: AutoplayFeedbackKind.skipped,
            reward: 0,
          ),
      ], at: now),
      isNull,
    );
  });

  test('the lasting taste waits for enough plays', () async {
    final db = await _database();
    final taste = AutoplayTaste(
      open: () async => db,
      train: (plays) async => trainAutoplayTaste(plays),
    );
    addTearDown(taste.dispose);
    final history = _clusters();
    history.take(40).forEach(taste.record);
    await taste.train();
    expect(await taste.profile(), isNull);
    history.skip(40).forEach(taste.record);
    await taste.train();
    final profile = (await taste.profile(at: _start.add(Duration(days: 3))))!;
    expect(profile.fit('Night 3', 'Song 2'), isNotNull);
  });
}
