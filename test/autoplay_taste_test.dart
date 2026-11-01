import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/autoplay_personalization.dart';
import 'package:mornye/services/autoplay_taste.dart';
import 'package:mornye/services/music_player_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

final _start = DateTime(2026, 10, 1, 8);

AutoplayFeedback _feedback(
  String artist,
  String title,
  DateTime at, {
  AutoplayFeedbackKind kind = AutoplayFeedbackKind.listened,
  double reward = 1,
}) => AutoplayFeedback(
  kind: kind,
  track: AutoplayLearningTrack(
    source: '/$artist/$title.flac',
    title: title,
    artist: artist,
  ),
  previous: null,
  at: at,
  reward: reward,
);

PlayableMedia _media(String artist, String title) => PlayableMedia(
  id: '$artist/$title',
  source: '/$artist/$title.flac',
  title: title,
  artist: artist,
);

/// Sessions three hours apart, alternating between two groups of artists
/// the listener never plays together: Night 1-3 and Day 1-3.
List<AutoplayFeedback> _clusters({int sessions = 16, int length = 8}) {
  final random = Random(7);
  final history = <AutoplayFeedback>[];
  for (var session = 0; session < sessions; session++) {
    final group = session.isEven ? 'Night' : 'Day';
    final start = _start.add(Duration(hours: 3 * session));
    for (var i = 0; i < length; i++) {
      history.add(
        _feedback(
          '$group ${1 + random.nextInt(3)}',
          'Song ${random.nextInt(4)}',
          start.add(Duration(minutes: 4 * i)),
        ),
      );
    }
  }
  return history;
}

double _cosine(Float32List a, Float32List b) {
  var dot = 0.0;
  for (var i = 0; i < a.length; i++) {
    dot += a[i] * b[i];
  }
  return dot;
}

Future<Database> _database(Directory directory, [String name = 'taste']) =>
    AutoplayTaste.openWithFactory(
      databaseFactoryFfi,
      '${directory.path}/$name.db',
    );

Future<Directory> _directory() async {
  sqfliteFfiInit();
  final directory = await Directory.systemTemp.createTemp('autoplay-taste-');
  addTearDown(() => directory.delete(recursive: true));
  return directory;
}

/// A taste learning on this isolate from [db].
AutoplayTaste _taste(Database db, {List<int>? trainings}) {
  final taste = AutoplayTaste(
    open: () async => db,
    train: (plays) async {
      trainings?.add(plays.length);
      return trainAutoplayTaste(plays);
    },
  );
  addTearDown(taste.dispose);
  return taste;
}

class _TrainingTimer implements Timer {
  _TrainingTimer(this.callback);

  final void Function() callback;
  @override
  bool isActive = true;
  @override
  int tick = 0;

  @override
  void cancel() => isActive = false;

  void fire() {
    if (!isActive) return;
    isActive = false;
    tick++;
    callback();
  }
}

R _captureTraining<R>(List<_TrainingTimer> timers, R Function() action) =>
    runZoned(
      action,
      zoneSpecification: ZoneSpecification(
        createTimer: (self, parent, zone, duration, callback) {
          if (duration != const Duration(seconds: 20)) {
            return parent.createTimer(zone, duration, callback);
          }
          final timer = _TrainingTimer(callback);
          timers.add(timer);
          return timer;
        },
      ),
    );

void main() {
  test(
    'a feedback burst schedules one training outside the track change',
    () async {
      final db = await _database(await _directory());
      addTearDown(db.close);
      final trainings = <int>[];
      final taste = _taste(db, trainings: trainings);
      final timers = <_TrainingTimer>[];
      _captureTraining(timers, () {
        for (var i = 0; i < 100; i++) {
          taste.record(_feedback('Artist', 'Song ${i % 4}', _start));
        }
      });
      await taste.flush();
      expect(trainings, isEmpty);
      expect(timers, hasLength(1));
      expect(timers.single.isActive, isTrue);
      timers.single.fire();
      await taste.train();
      expect(trainings, [100]);
      expect(taste.model?.through, 100);
      expect(timers.single.isActive, isFalse);
    },
  );

  for (final reset in [false, true]) {
    test(
      'pending training is cancelled on ${reset ? 'reset' : 'dispose'}',
      () async {
        final db = await _database(await _directory());
        addTearDown(db.close);
        final trainings = <int>[];
        final taste = _taste(db, trainings: trainings);
        final timers = <_TrainingTimer>[];
        _captureTraining(timers, () {
          for (var i = 0; i < 25; i++) {
            taste.record(_feedback('Artist', 'Song $i', _start));
          }
        });
        expect(timers, hasLength(1));
        if (reset) {
          await taste.reset();
        } else {
          await taste.dispose();
        }
        expect(timers.single.isActive, isFalse);
        timers.single.fire();
        expect(trainings, isEmpty);
        expect(await taste.readLog(), hasLength(reset ? 0 : 25));
      },
    );
  }

  test(
    'loading an older model schedules catch-up without immediate training',
    () async {
      final db = await _database(await _directory());
      addTearDown(db.close);
      final earlier = _taste(db);
      for (var i = 0; i < 24; i++) {
        earlier.record(_feedback('Artist', 'Song ${i % 4}', _start));
      }
      await earlier.dispose();
      final trainings = <int>[];
      final taste = _taste(db, trainings: trainings);
      final timers = <_TrainingTimer>[];
      await _captureTraining(timers, () => taste.signal([], []));
      expect(trainings, isEmpty);
      expect(timers, hasLength(1));
      timers.single.fire();
      await taste.train();
      expect(trainings, [24]);
    },
  );

  test(
    'worker-packed vectors retain the existing persisted model format',
    () async {
      final db = await _database(await _directory());
      addTearDown(db.close);
      final taste = AutoplayTaste(open: () async => db);
      addTearDown(taste.dispose);
      for (final feedback in _clusters()) {
        taste.record(feedback);
      }
      await taste.train();
      final expected = trainAutoplayTaste(await taste.readLog());
      expect(taste.model?.vectors, expected.vectors);
      final rows = await db.query('vectors');
      expect(rows, hasLength(expected.tokens.length));
      expect(
        rows.every((row) => (row['vector'] as Uint8List).length == 64),
        isTrue,
      );
      final restored = _taste(db);
      await restored.signal([], []);
      expect(restored.model?.tokens, expected.tokens);
      expect(restored.model?.vectors, expected.vectors);
      expect(restored.model?.through, expected.through);
    },
  );

  test('the log is bounded, persisted, retrains every 25 plays and '
      'reset clears it', () async {
    final directory = await _directory();
    final first = await _database(directory);
    final trainings = <int>[];
    final taste = AutoplayTaste(
      open: () async => first,
      train: (plays) async {
        trainings.add(plays.length);
        return AutoplayTasteModel(
          tokens: const ['artist:artist'],
          vectors: Float32List(AutoplayTasteModel.dimensions)..[0] = 1,
          positives: plays.length,
          through: plays.last.id,
        );
      },
    );
    for (var i = 0; i < 24; i++) {
      taste.record(_feedback('Artist', 'Song $i', _start));
    }
    await taste.flush();
    expect(trainings, isEmpty);
    taste.record(_feedback('Artist', 'Song 24', _start));
    await taste.train();
    expect(trainings, [25]);
    for (var i = 25; i < autoplayTasteLogLimit + 10; i++) {
      taste.record(_feedback('Artist', 'Song $i', _start));
    }
    await taste.train();
    await taste.dispose();
    await first.close();

    final second = await _database(directory);
    addTearDown(second.close);
    final restored = _taste(second);
    final log = await restored.readLog();
    expect(log, hasLength(autoplayTasteLogLimit));
    expect(log.first.song, 'artist|song 10');
    expect(log.last.song, 'artist|song ${autoplayTasteLogLimit + 9}');
    expect(log.first.kind, AutoplayFeedbackKind.listened);
    // Metadata keys only.
    final row = (await second.query('plays', limit: 1)).single;
    expect(
      row.keys,
      unorderedEquals(['id', 'at', 'kind', 'reward', 'song', 'artist']),
    );
    expect(row.values, isNot(contains('/Artist/Song 10.flac')));
    // The cached model loads without learning again.
    expect(await restored.signal(const [], const []), isNull);
    expect(restored.model?.tokens, ['artist:artist']);
    expect(restored.model?.positives, autoplayTasteLogLimit);
    expect(restored.model?.artist(' ARTIST '), [
      1,
      for (var i = 1; i < 16; i++) 0,
    ]);
    await restored.reset();
    expect(await restored.readLog(), isEmpty);
    expect(await second.query('model'), isEmpty);
    expect(await second.query('vectors'), isEmpty);
    expect(restored.model, isNull);
  });

  test('sessions split where a long pause passes', () {
    AutoplayTastePlay play(int minutes) => AutoplayTastePlay(
      song: 'a|$minutes',
      artist: 'a',
      at: _start.add(Duration(minutes: minutes)),
      kind: AutoplayFeedbackKind.listened,
      reward: 1,
    );
    final sessions = splitAutoplayTasteSessions([
      play(0),
      play(5),
      // A love while the song plays is logged before the song's play.
      play(9),
      play(6),
      play(39),
      play(70),
      play(200),
    ]);
    expect(
      [
        for (final session in sessions)
          [for (final play in session) play.at.difference(_start).inMinutes],
      ],
      [
        [0, 5, 9, 6, 39],
        [70],
        [200],
      ],
    );
  });

  test('songs and artists played together end up close', () {
    final plays = _clusters().map(AutoplayTastePlay.of).toList();
    final model = trainAutoplayTaste(plays);
    expect(model.positives, plays.length);
    double artists(String a, String b) =>
        _cosine(model.artist(a)!, model.artist(b)!);
    final together = [
      for (final group in ['Night', 'Day'])
        for (var a = 1; a <= 3; a++)
          for (var b = a + 1; b <= 3; b++) artists('$group $a', '$group $b'),
    ];
    final apart = [
      for (var a = 1; a <= 3; a++)
        for (var b = 1; b <= 3; b++) artists('Night $a', 'Day $b'),
    ];
    debugPrint('Taste artists: together $together, apart $apart');
    expect(together.reduce(min), greaterThan(apart.reduce(max)));

    final songs = [
      for (final group in ['Night', 'Day'])
        for (var a = 1; a <= 3; a++)
          for (var s = 0; s < 4; s++)
            if (model.song('$group $a', 'Song $s') case final vector?)
              (group, vector),
    ];
    var closer = 0, pairs = 0;
    for (final (group, vector) in songs) {
      final mates = [
        for (final other in songs)
          if (other.$1 == group && !identical(other.$2, vector))
            _cosine(vector, other.$2),
      ];
      final strangers = [
        for (final other in songs)
          if (other.$1 != group) _cosine(vector, other.$2),
      ];
      final mean = mates.reduce((a, b) => a + b) / mates.length;
      for (final stranger in strangers) {
        pairs++;
        if (mean > stranger) closer++;
      }
    }
    expect(songs.length, greaterThan(16));
    expect(closer, pairs);
    // The same history learns the same model.
    expect(trainAutoplayTaste(plays).vectors, model.vectors);
  });

  test('the signal favors cluster mates, keeps unknown songs neutral and '
      'waits for enough plays', () async {
    final directory = await _directory();
    final db = await _database(directory);
    addTearDown(db.close);
    final trainings = <int>[];
    final taste = _taste(db, trainings: trainings);
    final history = _clusters();
    // Too few plays: no effect yet.
    for (final feedback in history.take(40)) {
      taste.record(feedback);
    }
    await taste.train();
    final session = [_media('Night 1', 'Song 0'), _media('Night 2', 'Song 1')];
    final mate = _media('Night 3', 'Song 2');
    final unheardMate = _media('Night 3', 'Song 9');
    final stranger = _media('Day 2', 'Song 2');
    final unknown = _media('Somebody Else', 'Song 1');
    final candidates = [mate, unheardMate, stranger, unknown];
    expect(taste.model?.positives, 40);
    expect(await taste.signal(session, candidates), isNull);

    for (final feedback in history.skip(40)) {
      taste.record(feedback);
    }
    await taste.train();
    // Learning again covers every play logged before it was asked for.
    expect(taste.model?.positives, history.length);
    expect(trainings.last, history.length);
    // No session song known: no effect.
    expect(
      await taste.signal([unknown, _media('Day 9', 'Song 0')], candidates),
      isNull,
    );
    final signal = (await taste.signal(session, candidates))!;
    signal.prepare(session, candidates);
    final known = [mate, unheardMate, stranger].map(signal.score).toList();
    debugPrint('Taste scores: mate, unheard mate, stranger $known');
    expect(signal.score(mate), greaterThan(signal.score(stranger) + 2));
    expect(signal.score(unheardMate), greaterThan(signal.score(stranger) + 2));
    expect(signal.score(mate), lessThanOrEqualTo(4));
    expect(
      signal.score(unknown),
      closeTo(known.reduce((a, b) => a + b) / known.length, 1e-9),
    );
    final selected = selectAutoplayTracks(
      seed: session.last,
      candidates: [stranger, mate],
      upcoming: [],
      recent: [session.first],
      dismissedSources: {},
      random: Random(1),
      signals: [signal],
    );
    expect(selected, [mate, stranger]);

    // The cached model serves a later launch without learning again.
    final later = _taste(db, trainings: trainings);
    final count = trainings.length;
    expect(await later.signal(session, candidates), isNotNull);
    expect(later.model!.vectors, taste.model!.vectors);
    expect(trainings, hasLength(count));
  });

  test(
    'learning off logs nothing, and resetting learning clears the log',
    () async {
      final directory = await _directory();
      final db = await _database(directory);
      addTearDown(db.close);
      final taste = _taste(db);
      var elapsed = Duration.zero;
      final learning = AutoplayPersonalization(
        load: () async => null,
        save: (_) async {},
        elapsed: () => elapsed,
        now: () => _start,
      );
      final runtime = MusicPlayerRuntime(
        dependencies: PlaybackDependencies(
          createPersonalization: () => learning,
          createTaste: () => taste,
        ),
      );
      addTearDown(runtime.dispose);
      void listen() {
        const track = AutoplayLearningTrack(
          source: '/one.flac',
          title: 'One',
          artist: 'Artist',
          duration: Duration(seconds: 100),
        );
        runtime.personalization.begin(track);
        runtime.personalization.updatePlayback(
          source: track.source,
          playing: true,
        );
        elapsed += const Duration(seconds: 100);
        runtime.personalization.finish();
      }

      listen();
      await pumpEventQueue();
      expect(await taste.readLog(), isEmpty);
      learning.setEnabled(true);
      await learning.ensureLoaded();
      listen();
      await pumpEventQueue();
      expect(
        [for (final play in await taste.readLog()) (play.song, play.kind)],
        [('artist|one', AutoplayFeedbackKind.listened)],
      );
      await resetAutoplayLearning(runtime: runtime);
      expect(await taste.readLog(), isEmpty);
    },
  );

  test('training 5000 plays stays cheap', () {
    // Eight groups of six artists; sessions mostly within one group, with
    // skips, loves and some songs from elsewhere.
    final random = Random(3);
    final plays = <AutoplayTastePlay>[];
    var at = _start;
    while (plays.length < autoplayTasteLogLimit) {
      final group = random.nextInt(8);
      final length = 5 + random.nextInt(16);
      for (var i = 0; i < length && plays.length < autoplayTasteLogLimit; i++) {
        final from = random.nextDouble() < 0.1 ? random.nextInt(8) : group;
        final artist = 'Artist $from-${random.nextInt(6)}';
        final roll = random.nextDouble();
        plays.add(
          AutoplayTastePlay.of(
            _feedback(
              artist,
              'Song ${random.nextInt(10)}',
              at,
              kind: roll < 0.15
                  ? AutoplayFeedbackKind.skipped
                  : roll < 0.18
                  ? AutoplayFeedbackKind.loved
                  : AutoplayFeedbackKind.listened,
              reward: roll < 0.15 ? 0 : 1,
            ),
          ),
        );
        at = at.add(const Duration(minutes: 4));
      }
      at = at.add(const Duration(hours: 2));
    }
    final durations = <int>[];
    late AutoplayTasteModel model;
    for (var i = 0; i < 3; i++) {
      final clock = Stopwatch()..start();
      model = trainAutoplayTaste(plays);
      durations.add(clock.elapsedMilliseconds);
    }
    debugPrint(
      'Autoplay taste training: ${plays.length} plays, '
      '${model.tokens.length} tokens, ${durations.join(', ')} ms; '
      'model ${model.vectors.lengthInBytes} bytes.',
    );
    expect(model.tokens.length, lessThanOrEqualTo(3000));
    expect(model.positives, greaterThan(4000));
    // Artists of one group still end up closer than those of two.
    final together = <double>[], apart = <double>[];
    for (var a = 0; a < 48; a++) {
      for (var b = a + 1; b < 48; b++) {
        final similarity = _cosine(
          model.artist('Artist ${a ~/ 6}-${a % 6}')!,
          model.artist('Artist ${b ~/ 6}-${b % 6}')!,
        );
        (a ~/ 6 == b ~/ 6 ? together : apart).add(similarity);
      }
    }
    double mean(List<double> values) =>
        values.reduce((a, b) => a + b) / values.length;
    debugPrint(
      'Taste artists of 5000 plays: together ${mean(together)}, '
      'apart ${mean(apart)}',
    );
    expect(mean(together), greaterThan(mean(apart) + 0.4));
  });
}
