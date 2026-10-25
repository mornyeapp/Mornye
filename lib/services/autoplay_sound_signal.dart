import 'dart:math';
import 'dart:typed_data';

import 'package:mornye/services/autoplay_signal.dart';
import 'package:mornye/services/playable_media.dart';
import 'package:mornye/services/song_features.dart';

/// How songs sound, from their analyzed features. A candidate that sounds
/// like the latest songs of the session scores up to [maxScore]; each pick
/// prefers a song whose tempo, energy and key follow the one before it.
/// Features are standardized over the songs at hand, so the comparison
/// adapts to each Library, and timbre weighs most.
class SoundAutoplaySignal extends AutoplaySignal {
  SoundAutoplaySignal(this.features);

  /// Analyzed features by song source.
  final Map<String, Float32List> features;

  @override
  String get name => 'sound';

  /// The most a song gains for sounding like the session.
  static const maxScore = 5.0;

  /// The most a transition loses for a tempo jump (octaves folded) and for
  /// an energy jump, and gains for a compatible key.
  static const tempoPenalty = 1.5, energyPenalty = 1.5, keyBonus = 0.5;

  /// The latest songs, newest weighing most, that set the session's sound.
  static const _window = 12;

  // The comparison space: MFCC means and spreads (timbre), brightness and
  // texture, then energy, with each group's share of the distance. Tempo,
  // which folds by octaves, takes the rest.
  static const _energy = 2 * SongFeatures.mfccCount + 7;
  static const _loudness = _energy, _flux = _energy + 2, _onsets = _energy + 3;
  static const _dimensions = _energy + 4;
  static const _tempoWeight = 0.10;
  static final _weights = Float64List.fromList([
    for (var i = 0; i < SongFeatures.mfccCount; i++) 0.40 / 13,
    for (var i = 0; i < SongFeatures.mfccCount; i++) 0.15 / 13,
    for (var i = 0; i < 7; i++) 0.20 / 7,
    for (var i = 0; i < 4; i++) 0.15 / 4,
  ]);

  // Typical spreads across songs, which steady the standardization while
  // few songs are known.
  static final _priorScales = Float64List.fromList([
    3,
    for (var i = 1; i < SongFeatures.mfccCount; i++) 1,
    1.2,
    for (var i = 1; i < SongFeatures.mfccCount; i++) 0.4,
    0.3, 0.3, 0.4, 0.7, 0.15, 0.15, 0.03, // brightness and texture
    2, 0.8, 0.25, 0.5, // energy
  ]);
  static const _priorWeight = 4.0;

  final _points = <String, Float64List>{};
  final _fits = <String, double>{};
  List<PlayableMedia> _candidates = const [];
  double _unknownScore = 0;
  String? _followed;
  double _unknownFollow = 0;

  static Float64List _point(Float32List v) {
    double logOf(int index, double floor) => log(max(v[index], floor));
    return Float64List.fromList([
      for (var i = 0; i < SongFeatures.mfccCount; i++) v[SongFeatures.mfcc + i],
      for (var i = 0; i < SongFeatures.mfccCount; i++)
        v[SongFeatures.mfccSpread + i],
      logOf(SongFeatures.centroid, 1),
      logOf(SongFeatures.centroidSpread, 1),
      logOf(SongFeatures.rolloff, 1),
      logOf(SongFeatures.flatness, 1e-6),
      for (var i = 0; i < 3; i++) v[SongFeatures.bands + i],
      v[SongFeatures.loudness],
      v[SongFeatures.loudnessSpread],
      logOf(SongFeatures.flux, 1e-4),
      v[SongFeatures.onsetRate],
    ]);
  }

  /// How far apart two tempos are in octaves, folded so that double and
  /// half time match: 0 to 0.5.
  static double _octaves(double a, double b) {
    final distance = (log(a / b) / ln2).abs() % 1;
    return min(distance, 1 - distance);
  }

  bool _hasTempo(Float32List v) =>
      v[SongFeatures.tempo] > 0 && v[SongFeatures.tempoConfidence] >= 0.3;

  @override
  void prepare(List<PlayableMedia> session, List<PlayableMedia> candidates) {
    _points.clear();
    _fits.clear();
    _followed = null;
    _unknownScore = 0;
    _candidates = candidates;
    final raw = <String, Float64List>{};
    for (final item in [...session, ...candidates]) {
      final vector = features[item.source];
      if (vector != null && vector.length == SongFeatures.length) {
        raw[item.source] ??= _point(vector);
      }
    }
    if (raw.isEmpty) return;
    final mean = Float64List(_dimensions);
    for (final point in raw.values) {
      for (var d = 0; d < _dimensions; d++) {
        mean[d] += point[d] / raw.length;
      }
    }
    final scale = Float64List(_dimensions);
    for (var d = 0; d < _dimensions; d++) {
      var squares = 0.0;
      for (final point in raw.values) {
        squares += pow(point[d] - mean[d], 2);
      }
      final prior = _priorScales[d];
      scale[d] = sqrt(
        (squares + _priorWeight * prior * prior) / (raw.length + _priorWeight),
      );
    }
    for (final MapEntry(key: source, value: point) in raw.entries) {
      _points[source] = Float64List.fromList([
        for (var d = 0; d < _dimensions; d++) (point[d] - mean[d]) / scale[d],
      ]);
    }

    final profile = <(String, double)>[];
    for (var back = 0; back < min(_window, session.length); back++) {
      final source = session[session.length - 1 - back].source;
      if (_points.containsKey(source)) {
        profile.add((source, pow(0.75, back).toDouble()));
      }
    }
    if (profile.isEmpty) return;
    var total = 0.0;
    for (final candidate in candidates) {
      if (!_points.containsKey(candidate.source) ||
          _fits.containsKey(candidate.source)) {
        continue;
      }
      var fit = 0.0, weights = 0.0;
      for (final (source, weight) in profile) {
        fit += weight * _similarity(candidate.source, source);
        weights += weight;
      }
      _fits[candidate.source] = fit / weights;
      total += fit / weights;
    }
    if (_fits.isNotEmpty) _unknownScore = maxScore * total / _fits.length;
  }

  /// 1 for songs that sound alike, toward 0 for ones that do not; two
  /// songs picked at random land near 0.37.
  double _similarity(String a, String b) {
    final p = _points[a]!, q = _points[b]!;
    var distance = 0.0;
    for (var d = 0; d < _dimensions; d++) {
      distance += _weights[d] * pow(p[d] - q[d], 2);
    }
    final va = features[a]!, vb = features[b]!;
    // An unknown tempo counts as a random pair's distance.
    final tempo = _hasTempo(va) && _hasTempo(vb)
        ? min(
            9.0,
            pow(
              _octaves(va[SongFeatures.tempo], vb[SongFeatures.tempo]) / 0.1,
              2,
            ),
          )
        : 2.0;
    distance += _tempoWeight * tempo;
    return exp(-distance / 2);
  }

  @override
  double score(PlayableMedia candidate) {
    final fit = _fits[candidate.source];
    return fit == null ? _unknownScore : maxScore * fit;
  }

  /// How well [next] follows [previous]: tempo and energy jumps lose, keys
  /// next to each other on the Camelot wheel gain.
  double _transition(String previous, String next) {
    final a = features[previous]!, b = features[next]!;
    var term = 0.0;
    if (a[SongFeatures.tempo] > 0 && b[SongFeatures.tempo] > 0) {
      final sure =
          min(
            a[SongFeatures.tempoConfidence],
            b[SongFeatures.tempoConfidence],
          ) /
          0.5;
      final jump =
          pow(2, _octaves(a[SongFeatures.tempo], b[SongFeatures.tempo])) - 1;
      term -=
          tempoPenalty *
          sure.clamp(0.0, 1.0) *
          ((jump - 0.03) / 0.09).clamp(0.0, 1.0);
    }
    final p = _points[previous]!, q = _points[next]!;
    double energy(Float64List point) =>
        0.5 * point[_loudness] + 0.25 * point[_flux] + 0.25 * point[_onsets];
    final change = (energy(p) - energy(q)).abs();
    term -= energyPenalty * ((change - 0.3) / 1.2).clamp(0.0, 1.0);
    if (a[SongFeatures.keyStrength] >= 0.5 &&
        b[SongFeatures.keyStrength] >= 0.5 &&
        _compatibleKeys(a, b)) {
      term += keyBonus;
    }
    return term;
  }

  /// The Camelot wheel: the same number (the same key or its relative), or
  /// a neighbor in the same mode.
  static bool _compatibleKeys(Float32List a, Float32List b) {
    int number(Float32List v) {
      final tonic = v[SongFeatures.key].round() % 12;
      final major = v[SongFeatures.mode] >= 0.5;
      // A minor key shares its number with its relative major.
      final relative = major ? tonic : (tonic + 3) % 12;
      return (7 * relative + 7) % 12;
    }

    final distance = (number(a) - number(b)).abs();
    final sameMode =
        (a[SongFeatures.mode] >= 0.5) == (b[SongFeatures.mode] >= 0.5);
    return distance == 0 || (sameMode && (distance == 1 || distance == 11));
  }

  @override
  double follow(PlayableMedia previous, PlayableMedia candidate) {
    if (!_points.containsKey(previous.source)) return 0;
    if (_followed != previous.source) {
      // Songs without features follow as an average known song does.
      _followed = previous.source;
      var total = 0.0, count = 0;
      for (final item in _candidates) {
        if (_points.containsKey(item.source)) {
          total += _transition(previous.source, item.source);
          count++;
        }
      }
      _unknownFollow = count == 0 ? 0 : total / count;
    }
    return _points.containsKey(candidate.source)
        ? _transition(previous.source, candidate.source)
        : _unknownFollow;
  }
}
