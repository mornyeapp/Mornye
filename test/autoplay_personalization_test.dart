import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/services/autoplay_personalization.dart';
import 'package:mornye/services/music_player_service.dart';

import 'support/preference_blob_fixture.dart';

final _at = DateTime(2026, 10, 11, 9);
const _rock = AutoplayLearningTrack(
  source: '/rock.flac',
  title: 'Rock',
  artist: 'Rock Artist',
  genre: 'Rock',
  duration: Duration(seconds: 120),
);
const _jazz = AutoplayLearningTrack(
  source: '/jazz.flac',
  title: 'Jazz',
  artist: 'Jazz Artist',
  genre: 'Jazz',
  duration: Duration(seconds: 120),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  group('file persistence', () {
    late PreferenceBlobFixture files;
    setUp(() async {
      files = await PreferenceBlobFixture.create();
      SharedPreferences.setMockInitialValues({});
    });
    tearDown(() => files.close());

    test(
      'migrates learning, persists new feedback and resets without legacy copies',
      () async {
        final model = AutoplayPreferenceModel()
          ..learn(_jazz, previous: _rock, at: _at, reward: 1);
        final encoded = model.encode();
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('autoplay_learning_model_v1', encoded);
        await prefs.setBool('unrelated_setting', true);
        var elapsed = Duration.zero;
        final service = AutoplayPersonalization(
          elapsed: () => elapsed,
          now: () => _at,
        );
        service.setEnabled(true);
        await service.ensureLoaded();
        expect(service.observations, 1);
        expect(prefs.containsKey('autoplay_learning_model_v1'), isFalse);
        final file = File(
          '${files.root.path}/preference_blobs/autoplay_model_v1.json',
        );
        expect(
          (jsonDecode(await file.readAsString())
              as Map)['autoplay_learning_model_v1'],
          encoded,
        );
        service.begin(_jazz);
        service.updatePlayback(source: _jazz.source, playing: true);
        elapsed += const Duration(seconds: 10);
        service.finish(skipped: true);
        await service.flush();
        expect(service.observations, 2);
        final reopened = AutoplayPersonalization();
        await reopened.ensureLoaded();
        expect(reopened.observations, 2);
        await reopened.dispose();
        await service.reset();
        expect(service.observations, 0);
        await service.dispose();
        final reset = AutoplayPersonalization();
        await reset.ensureLoaded();
        expect(reset.observations, 0);
        await reset.dispose();
        expect(prefs.getKeys(), {'unrelated_setting'});
      },
    );

    test(
      'failed migration and save retain learning until a successful retry',
      () async {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(
          'autoplay_learning_model_v1',
          (AutoplayPreferenceModel()..learn(_jazz, at: _at, reward: 1))
              .encode(),
        );
        final blocked = Directory(
          '${files.root.path}/preference_blobs/autoplay_model_v1.json',
        );
        await blocked.create(recursive: true);
        final service = AutoplayPersonalization();
        await service.ensureLoaded();
        expect(service.observations, 1);
        expect(prefs.containsKey('autoplay_learning_model_v1'), isTrue);
        await service.reset();
        expect(prefs.containsKey('autoplay_learning_model_v1'), isTrue);
        await blocked.delete();
        await service.flush();
        expect(prefs.containsKey('autoplay_learning_model_v1'), isFalse);
        final reopened = AutoplayPersonalization();
        await reopened.ensureLoaded();
        expect(reopened.observations, 0);
        await reopened.dispose();
        await service.dispose();
      },
    );
  });

  test(
    'disposal persists completed feedback even while initial loading is pending',
    () async {
      var elapsed = Duration.zero;
      final gate = Completer<String?>();
      String? saved;
      final service = AutoplayPersonalization(
        load: () => gate.future,
        save: (value) async => saved = value,
        elapsed: () => elapsed,
        now: () => _at,
      );
      service.setEnabled(true);
      service.begin(_rock);
      service.updatePlayback(source: _rock.source, playing: true);
      elapsed += const Duration(seconds: 10);
      service.finish(skipped: true);
      final disposed = service.dispose();
      gate.complete(null);
      await disposed;
      expect(AutoplayPreferenceModel.decode(saved).observations, 1);
    },
  );
  test('bounded 384-candidate ranking stress and snapshot isolation', () {
    final model = AutoplayPreferenceModel();
    for (var i = 0; i < 60; i++) {
      model.learn(_jazz, previous: _rock, at: _at, reward: 1);
    }
    final snapshot = model.snapshot();
    final before = snapshot.preference(_jazz, previous: _rock, at: _at);
    for (var i = 0; i < 20; i++) {
      model.learn(_jazz, previous: _rock, at: _at, reward: 0);
    }
    expect(snapshot.preference(_jazz, previous: _rock, at: _at), before);
    final candidates = List.generate(
      384,
      (i) => PlayableMedia(
        id: '$i',
        source: '/$i.flac',
        title: 'Track $i',
        artist: 'Artist ${i % 24}',
        album: 'Album ${i % 50}',
        genre: i.isEven ? 'Jazz' : 'Rock',
        duration: const Duration(seconds: 180),
      ),
    );
    const seed = PlayableMedia(
      id: 'seed',
      source: '/seed.flac',
      title: 'Seed',
      artist: 'Seed',
    );
    final durations = <int>[];
    for (var i = 0; i < 40; i++) {
      final clock = Stopwatch()..start();
      final selected = selectAutoplayTracks(
        seed: seed,
        candidates: candidates,
        upcoming: [],
        recent: [],
        dismissedSources: {},
        random: Random(i),
        preferenceAdjustment: (track) => snapshot.rankAdjustment(
          AutoplayLearningTrack(
            source: track.source,
            title: track.title,
            artist: track.artist,
            album: track.album,
            genre: track.genre ?? '',
            duration: track.duration,
          ),
          previous: _rock,
          at: _at,
        ),
      );
      clock.stop();
      expect(selected, hasLength(6));
      expect(selected.map((track) => track.source).toSet(), hasLength(6));
      if (i >= 10) durations.add(clock.elapsedMicroseconds);
    }
    durations.sort();
    debugPrint(
      'Autoplay host ranking: 384 candidates, median '
      '${durations[durations.length ~/ 2]} us, p95 '
      '${durations[(durations.length * .95).floor()]} us; model parameters 65536 bytes.',
    );
  });
  test('cold start is neutral and personalization is on independently', () {
    final model = AutoplayPreferenceModel();
    expect(model.preference(_rock, at: _at), 0.5);
    expect(model.rankAdjustment(_rock, previous: _jazz, at: _at), 0);
    expect(AppSettings.fromJson({}).autoplayPersonalization, isTrue);
    final settings = const AppSettings().copyWith(
      autoplayPersonalization: false,
    );
    final restored = AppSettings.fromJson(settings.toJson());
    expect(restored.autoplayPersonalization, isFalse);
    expect(restored.autoplay, isFalse);
  });

  test('learning favors engagement, transfers genre and handles context', () {
    final model = AutoplayPreferenceModel();
    for (var i = 0; i < 100; i++) {
      model.learn(_jazz, previous: _rock, at: _at, reward: 1);
      model.learn(_rock, previous: _rock, at: _at, reward: 0);
    }
    expect(model.preference(_jazz, previous: _rock, at: _at), greaterThan(0.8));
    expect(model.preference(_rock, previous: _rock, at: _at), lessThan(0.2));
    const unseenJazz = AutoplayLearningTrack(
      source: '/new',
      title: 'New',
      artist: 'Unseen Artist',
      genre: 'Jazz',
    );
    const unseenRock = AutoplayLearningTrack(
      source: '/other',
      title: 'Other',
      artist: 'Different Artist',
      genre: 'Rock',
    );
    expect(
      model.preference(unseenJazz, previous: _rock, at: _at),
      greaterThan(model.preference(unseenRock, previous: _rock, at: _at)),
    );
    expect(
      model.preference(_jazz, previous: _rock, at: _at),
      greaterThan(
        model.preference(
          _jazz,
          previous: _rock,
          at: _at.add(const Duration(hours: 12)),
        ),
      ),
    );
  });

  test('learns how much variety the listener plays through', () {
    final model = AutoplayPreferenceModel();
    AutoplayLearningTrack song(String artist, int i, {String genre = 'Pop'}) =>
        AutoplayLearningTrack(
          source: '/$artist$i',
          title: '$artist $i',
          artist: artist,
          genre: genre,
        );
    // The listener skips a second song by the same artist and keeps
    // listening when another artist follows.
    for (var round = 0; round < 30; round++) {
      for (var a = 0; a < 6; a++) {
        final first = song('Artist $a', round);
        model.learn(
          song('Artist $a', round + 100),
          previous: first,
          at: _at,
          reward: 0,
        );
        model.learn(
          song('Artist ${a + 6}', round),
          previous: first,
          at: _at,
          reward: 1,
        );
      }
    }
    // Artists it never heard follow the same habit.
    final heard = song('Unheard', 0);
    expect(
      model.preference(song('Unheard', 1), previous: heard, at: _at),
      lessThan(model.preference(song('Other', 0), previous: heard, at: _at)),
    );
  });

  test(
    'learned rank changes recommendations but preserves queue exclusions',
    () {
      final model = AutoplayPreferenceModel();
      for (var i = 0; i < 100; i++) {
        model.learn(_jazz, previous: _rock, at: _at, reward: 1);
        model.learn(_rock, previous: _rock, at: _at, reward: 0);
      }
      const seed = PlayableMedia(
        id: 'seed',
        source: '/seed',
        title: 'Seed',
        artist: 'Seed',
        genre: 'Rock',
      );
      const rock = PlayableMedia(
        id: 'rock',
        source: '/rock.flac',
        title: 'Rock',
        artist: 'Rock Artist',
        genre: 'Rock',
      );
      const jazz = PlayableMedia(
        id: 'jazz',
        source: '/jazz.flac',
        title: 'Jazz',
        artist: 'Jazz Artist',
        genre: 'Jazz',
      );
      List<PlayableMedia> rank({
        bool personalized = false,
        Set<String> dismissed = const {},
      }) => selectAutoplayTracks(
        seed: seed,
        candidates: [rock, jazz, jazz, seed],
        upcoming: [],
        recent: [],
        dismissedSources: dismissed,
        random: Random(1),
        preferenceAdjustment: personalized
            ? (track) => model.rankAdjustment(
                track.id == 'rock' ? _rock : _jazz,
                previous: _rock,
                at: _at,
              )
            : null,
      );
      expect(rank().first.id, 'rock');
      expect(rank(personalized: true).first.id, 'jazz');
      expect(rank(personalized: true), hasLength(2));
      expect(
        rank(personalized: true, dismissed: {'/jazz.flac'}).single.id,
        'rock',
      );
    },
  );

  test(
    'snapshot is bounded, stable, contains no metadata, rejects bad input',
    () {
      final model = AutoplayPreferenceModel();
      model.learn(_jazz, previous: _rock, at: _at, reward: 1);
      final raw = model.encode();
      final restored = AutoplayPreferenceModel.decode(raw);
      expect(raw.length, lessThan(100000));
      expect(raw, isNot(contains('/jazz.flac')));
      expect(raw, isNot(contains('Jazz Artist')));
      expect(restored.observations, 1);
      expect(
        restored.preference(_jazz, previous: _rock, at: _at),
        model.preference(_jazz, previous: _rock, at: _at),
      );
      for (final input in [
        'garbage',
        '{"version":2}',
        '{"version":1}',
        '{"version":1,"observations":-1,"parameters":""}',
      ]) {
        expect(AutoplayPreferenceModel.decode(input).observations, 0);
      }
      final bad = jsonDecode(raw) as Map<String, dynamic>;
      final bytes = base64Decode(bad['parameters'] as String);
      ByteData.sublistView(bytes).setFloat64(0, double.nan, Endian.little);
      bad['parameters'] = base64Encode(bytes);
      expect(AutoplayPreferenceModel.decode(jsonEncode(bad)).observations, 0);
    },
  );

  test('Thompson sampling explores little-heard artists, not skipped ones', () {
    final model = AutoplayPreferenceModel();
    AutoplayLearningTrack song(String artist, int i) => AutoplayLearningTrack(
      source: '/$artist$i',
      title: '$i',
      artist: artist,
    );
    for (var i = 0; i < 6; i++) {
      model.learn(song('Skipped', i), at: _at, reward: 0, weight: 1.5);
      model.learn(song('Liked', i), at: _at, reward: 1);
    }
    for (var i = 0; i < 8; i++) {
      model.learn(song('Other $i', i), at: _at, reward: 0.75);
    }
    (double, double) spread(String artist) {
      final draws = [
        for (var i = 0; i < 400; i++)
          model.explore(Random(i)).adjustment(song(artist, 99)),
      ];
      final mean = draws.reduce((a, b) => a + b) / draws.length;
      final variance =
          draws.map((d) => (d - mean) * (d - mean)).reduce((a, b) => a + b) /
          draws.length;
      return (mean, sqrt(variance));
    }

    final (skipped, _) = spread('Skipped');
    final (liked, likedSpread) = spread('Liked');
    final (unheard, unheardSpread) = spread('Unheard');
    expect(skipped, lessThan(-1.5));
    expect(liked, greaterThan(1.5));
    expect(unheard.abs(), lessThan(0.3));
    // An unheard artist sometimes outranks a liked one.
    expect(unheardSpread, greaterThan(2 * likedSpread));
    // One draw per artist and refill.
    final exploration = model.explore(Random(1));
    expect(
      exploration.adjustment(song('Unheard', 1)),
      exploration.adjustment(song('unheard ', 2)),
    );
  });

  test('the arms are bounded, persisted and read from older models', () {
    final model = AutoplayPreferenceModel();
    for (var i = 0; i < AutoplayPreferenceModel.maxArms + 100; i++) {
      model.learn(
        AutoplayLearningTrack(source: '/$i', title: '$i', artist: 'Artist $i'),
        at: _at,
        reward: i.isEven ? 1 : 0,
      );
    }
    expect(model.arms, AutoplayPreferenceModel.maxArms);
    final raw = model.encode();
    expect(raw.length, lessThan(140000));
    final restored = AutoplayPreferenceModel.decode(raw);
    expect(restored.arms, model.arms);
    expect(restored.encode(), raw);
    final older = jsonDecode(raw) as Map<String, dynamic>
      ..['version'] = 1
      ..remove('arms');
    final upgraded = AutoplayPreferenceModel.decode(jsonEncode(older));
    expect(upgraded.observations, model.observations);
    expect(upgraded.arms, 0);
    expect(
      upgraded.preference(_jazz, previous: _rock, at: _at),
      model.preference(_jazz, previous: _rock, at: _at),
    );
    final bad = jsonDecode(raw) as Map<String, dynamic>;
    bad['arms'] = base64Encode(Uint8List(13));
    expect(AutoplayPreferenceModel.decode(jsonEncode(bad)).observations, 0);
  });

  test(
    'elapsed listening excludes pauses, loading, rapid taps and seeks',
    () async {
      var elapsed = Duration.zero;
      final service = AutoplayPersonalization(
        load: () async => null,
        save: (_) async {},
        elapsed: () => elapsed,
        now: () => _at,
      );
      addTearDown(service.dispose);
      service.setEnabled(true);
      await service.ensureLoaded();
      service.begin(_rock);
      elapsed += const Duration(seconds: 60); // Loading, never playing.
      service.updatePlayback(source: _rock.source, playing: true);
      elapsed += const Duration(seconds: 2);
      service.finish(skipped: true);
      expect(service.observations, 0);
      service.begin(_rock);
      service.updatePlayback(source: _rock.source, playing: true);
      elapsed += const Duration(seconds: 10);
      service.updatePlayback(source: _rock.source, playing: false);
      elapsed += const Duration(
        hours: 2,
      ); // Paused wall time is not engagement.
      service.updatePlayback(source: _rock.source, playing: true);
      // Playback position is deliberately not an input: seeking to the end
      // cannot manufacture completed listening.
      service.finish(skipped: true);
      expect(service.observations, 1);
      expect(service.adjustment(_rock, _jazz, _at), lessThan(0));
      service.finish(skipped: true);
      expect(service.observations, 1);
    },
  );

  test('each kind of feedback carries its reward and weight', () async {
    var elapsed = Duration.zero;
    final service = AutoplayPersonalization(
      load: () async => null,
      save: (_) async {},
      elapsed: () => elapsed,
      now: () => _at,
    );
    addTearDown(service.dispose);
    final feedback = <AutoplayFeedback>[];
    service.feedback.listen(feedback.add);
    service.setEnabled(true);
    await service.ensureLoaded();
    void listen(int seconds, {bool skipped = false, bool replay = false}) {
      service.begin(_rock);
      service.updatePlayback(source: _rock.source, playing: true);
      if (replay) service.replayed();
      elapsed += Duration(seconds: seconds);
      service.finish(skipped: skipped);
    }

    listen(5, skipped: true);
    listen(20, skipped: true);
    listen(45, skipped: true);
    listen(115);
    listen(70, skipped: true);
    listen(40, skipped: true, replay: true);
    listen(10, skipped: true, replay: true);
    service.endorse(_jazz, AutoplayFeedbackKind.loved);
    await pumpEventQueue();
    expect(
      [for (final item in feedback) (item.kind, item.reward, item.weight)],
      [
        (AutoplayFeedbackKind.skipped, 0, 1.5),
        (AutoplayFeedbackKind.skipped, 0, 1),
        (AutoplayFeedbackKind.skipped, 0.25, 0.5),
        (AutoplayFeedbackKind.listened, 1, 1),
        (AutoplayFeedbackKind.listened, 0.5 + 70 / 120 / 2, 1),
        (AutoplayFeedbackKind.replayed, 1, 1.5),
        // A replay left within seconds is a skip.
        (AutoplayFeedbackKind.skipped, 0, 1),
        (AutoplayFeedbackKind.loved, 1, 2),
      ],
    );
    // A loved song that is not playing carries no transition.
    expect(feedback.last.previous, isNull);
    expect(service.observations, feedback.length);
  });

  test('loving the current song keeps its context, only while on', () async {
    final service = AutoplayPersonalization(
      load: () async => null,
      save: (_) async {},
      now: () => _at,
    );
    addTearDown(service.dispose);
    final feedback = <AutoplayFeedback>[];
    service.feedback.listen(feedback.add);
    service.endorse(_rock, AutoplayFeedbackKind.loved);
    service.setEnabled(true);
    await service.ensureLoaded();
    service.begin(_jazz);
    service.begin(_rock);
    service.endorse(
      const AutoplayLearningTrack(
        source: 'catalog-id',
        title: ' ROCK ',
        artist: 'rock artist',
      ),
      AutoplayFeedbackKind.playlisted,
    );
    await pumpEventQueue();
    expect(feedback, hasLength(1));
    expect(feedback.single.kind, AutoplayFeedbackKind.playlisted);
    expect(feedback.single.track.source, _rock.source);
    expect(feedback.single.previous?.source, _jazz.source);
    expect(feedback.single.weight, 1.5);
  });

  test('duration updates and long listening yield positive feedback', () async {
    var elapsed = Duration.zero;
    final service = AutoplayPersonalization(
      load: () async => null,
      save: (_) async {},
      elapsed: () => elapsed,
      now: () => _at,
    );
    addTearDown(service.dispose);
    service.setEnabled(true);
    await service.ensureLoaded();
    service.begin(
      const AutoplayLearningTrack(
        source: '/jazz.flac',
        title: 'Jazz',
        artist: 'Jazz Artist',
        genre: 'Jazz',
      ),
    );
    service.updatePlayback(
      source: _jazz.source,
      playing: true,
      duration: const Duration(seconds: 120),
    );
    elapsed += const Duration(seconds: 95);
    service.finish();
    expect(service.observations, 1);
    expect(service.adjustment(_jazz, _rock, _at), greaterThan(0));
  });

  test(
    'off performs no loading/training and disables a pending load',
    () async {
      var elapsed = Duration.zero;
      var loads = 0;
      final gate = Completer<String?>();
      final service = AutoplayPersonalization(
        load: () {
          loads++;
          return gate.future;
        },
        save: (_) async {},
        elapsed: () => elapsed,
        now: () => _at,
      );
      addTearDown(service.dispose);
      service.begin(_rock);
      expect(loads, 0);
      service.setEnabled(true);
      service.begin(_rock);
      service.updatePlayback(source: _rock.source, playing: true);
      elapsed += const Duration(seconds: 90);
      service.finish();
      service.setEnabled(false);
      gate.complete(null);
      await service.ensureLoaded();
      expect(service.observations, 0);
      expect(service.adjustment(_rock, _jazz, _at), 0);
    },
  );

  test(
    'ordered writes, reload, reset, and disabling preserve explicit control',
    () async {
      var elapsed = Duration.zero;
      String? saved;
      final firstSave = Completer<void>();
      var saves = 0;
      final service = AutoplayPersonalization(
        load: () async => null,
        save: (raw) async {
          if (saves++ == 0) await firstSave.future;
          saved = raw;
        },
        elapsed: () => elapsed,
        now: () => _at,
      );
      addTearDown(service.dispose);
      service.setEnabled(true);
      await service.ensureLoaded();
      service.begin(_rock);
      service.updatePlayback(source: _rock.source, playing: true);
      elapsed += const Duration(seconds: 15);
      service.finish(skipped: true);
      final write = service.flush();
      final reset = service.reset();
      firstSave.complete();
      await Future.wait([write, reset]);
      expect(AutoplayPreferenceModel.decode(saved).observations, 0);
      expect(service.observations, 0);
      service.begin(_jazz);
      service.updatePlayback(source: _jazz.source, playing: true);
      elapsed += const Duration(seconds: 100);
      service.finish();
      service.setEnabled(false);
      await service.flush();
      expect(service.adjustment(_jazz, _rock, _at), 0);
      final next = AutoplayPersonalization(
        load: () async => saved,
        save: (_) async {},
      );
      addTearDown(next.dispose);
      next.setEnabled(true);
      await next.ensureLoaded();
      expect(next.observations, 1);
    },
  );

  test(
    'failed persistence is retried without blocking recommendation',
    () async {
      var elapsed = Duration.zero, saves = 0;
      String? saved;
      final service = AutoplayPersonalization(
        load: () async => null,
        save: (raw) async {
          if (saves++ == 0) throw StateError('Unavailable');
          saved = raw;
        },
        elapsed: () => elapsed,
        now: () => _at,
      );
      addTearDown(service.dispose);
      service.setEnabled(true);
      await service.ensureLoaded();
      service.begin(_rock);
      service.updatePlayback(source: _rock.source, playing: true);
      elapsed += const Duration(seconds: 10);
      service.finish(skipped: true);
      await service.flush();
      await service.flush();
      expect(AutoplayPreferenceModel.decode(saved).observations, 1);
    },
  );
}
