import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/autoplay_sound_signal.dart';
import 'package:mornye/services/music_player_service.dart';
import 'package:mornye/services/song_features.dart';

PlayableMedia track(String id) =>
    PlayableMedia(id: id, source: '/$id.flac', title: id, artist: 'by $id');

/// Features of a song: [timbre] moves its MFCCs and brightness together.
Float32List sound({
  double timbre = 0,
  double tempo = 120,
  double tempoConfidence = 0.9,
  double loudness = -10,
  int key = 0,
  bool major = true,
  double keyStrength = 0.8,
}) {
  final v = Float32List(SongFeatures.length);
  v[SongFeatures.tempo] = tempo;
  v[SongFeatures.tempoConfidence] = tempoConfidence;
  v[SongFeatures.loudness] = loudness;
  v[SongFeatures.loudnessSpread] = 3;
  v[SongFeatures.centroid] = 2000 * exp(0.3 * timbre);
  v[SongFeatures.centroidSpread] = 500;
  v[SongFeatures.rolloff] = 4000 * exp(0.3 * timbre);
  v[SongFeatures.flatness] = 0.01;
  v[SongFeatures.onsetRate] = 2;
  v[SongFeatures.flux] = 0.05;
  v[SongFeatures.bands] = 0.5;
  v[SongFeatures.bands + 1] = 0.4;
  v[SongFeatures.bands + 2] = 0.1;
  v[SongFeatures.key] = key.toDouble();
  v[SongFeatures.mode] = major ? 1 : 0;
  v[SongFeatures.keyStrength] = keyStrength;
  for (var i = 0; i < SongFeatures.mfccCount; i++) {
    v[SongFeatures.mfcc + i] = timbre * (i.isEven ? 1 : -1);
    v[SongFeatures.mfccSpread + i] = 1;
  }
  return v;
}

class _NoNoise implements Random {
  @override
  double nextDouble() => 0;
  @override
  int nextInt(int max) => 0;
  @override
  bool nextBool() => false;
}

void main() {
  final seed = track('seed'), earlier = track('earlier');

  test('songs that sound like the session rank above ones that do not', () {
    final near = track('near'), far = track('far');
    final signal = SoundAutoplaySignal({
      earlier.source: sound(),
      seed.source: sound(timbre: 0.2),
      near.source: sound(timbre: 0.3),
      far.source: sound(timbre: 4),
    });
    final selected = selectAutoplayTracks(
      seed: seed,
      candidates: [far, near],
      upcoming: [],
      recent: [earlier],
      dismissedSources: {},
      random: _NoNoise(),
      signals: [signal],
    );
    expect(selected, [near, far]);
    expect(signal.score(near), lessThanOrEqualTo(SoundAutoplaySignal.maxScore));
    expect(signal.score(near) - signal.score(far), greaterThan(2.5));
  });

  test('songs without analysis score and follow as an average analyzed '
      'song', () {
    final near = track('near'), far = track('far'), unknown = track('new');
    final signal = SoundAutoplaySignal({
      seed.source: sound(),
      near.source: sound(timbre: 0.3, tempo: 121),
      far.source: sound(timbre: 4, tempo: 150, loudness: -3),
    })..prepare([seed], [near, far, unknown]);
    expect(
      signal.score(unknown),
      closeTo((signal.score(near) + signal.score(far)) / 2, 1e-9),
    );
    expect(
      signal.follow(seed, unknown),
      closeTo((signal.follow(seed, near) + signal.follow(seed, far)) / 2, 1e-9),
    );
    // Nothing is known about how songs follow an unanalyzed one.
    expect(signal.follow(unknown, near), 0);
    expect(signal.follow(unknown, far), 0);
  });

  test('picks follow the song before in tempo, energy and key', () {
    final steady = track('steady'),
        doubled = track('doubled'),
        faster = track('faster'),
        louder = track('louder'),
        unsure = track('unsure'),
        fifth = track('fifth'),
        relative = track('relative'),
        distant = track('distant'),
        parallel = track('parallel');
    final signal = SoundAutoplaySignal({
      seed.source: sound(tempo: 120, key: 0),
      steady.source: sound(tempo: 121, key: 6),
      doubled.source: sound(tempo: 241, key: 6),
      faster.source: sound(tempo: 150, key: 6),
      louder.source: sound(tempo: 121, loudness: -1, key: 6),
      unsure.source: sound(tempo: 150, tempoConfidence: 0.1, key: 6),
      fifth.source: sound(tempo: 121, key: 7),
      relative.source: sound(tempo: 121, key: 9, major: false),
      distant.source: sound(tempo: 121, key: 2),
      parallel.source: sound(tempo: 121, key: 0, major: false),
    });
    signal.prepare(
      [seed],
      [
        steady,
        doubled,
        faster,
        louder,
        unsure,
        fifth,
        relative,
        distant,
        parallel,
      ],
    );
    double follow(PlayableMedia next) => signal.follow(seed, next);

    expect(follow(steady), closeTo(0, 1e-9));
    // Double time folds onto the same beat.
    expect(follow(doubled), closeTo(0, 1e-9));
    expect(follow(faster), closeTo(-SoundAutoplaySignal.tempoPenalty, 1e-9));
    // An unsure tempo weighs its jump less.
    expect(follow(unsure), closeTo(-0.3, 1e-6));
    expect(follow(louder), lessThan(-1));
    expect(follow(louder), greaterThanOrEqualTo(-1.5));
    // C major leads to G major and A minor, its Camelot neighbors.
    expect(follow(fifth), closeTo(SoundAutoplaySignal.keyBonus, 1e-9));
    expect(follow(relative), closeTo(SoundAutoplaySignal.keyBonus, 1e-9));
    expect(follow(distant), closeTo(0, 1e-9));
    expect(follow(parallel), closeTo(0, 1e-9));

    final selected = selectAutoplayTracks(
      seed: seed,
      candidates: [faster, louder, steady],
      upcoming: [],
      recent: [],
      dismissedSources: {},
      random: _NoNoise(),
      limit: 1,
      signals: [signal],
    );
    expect(selected, [steady]);
  });

  test('a weak key earns no key bonus', () {
    final fifth = track('fifth');
    final signal = SoundAutoplaySignal({
      seed.source: sound(key: 0, keyStrength: 0.3),
      fifth.source: sound(key: 7),
    })..prepare([seed], [fifth]);
    expect(signal.follow(seed, fifth), closeTo(0, 1e-9));
  });
}
