import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show compute, visibleForTesting;
import 'package:flutter/services.dart' show MissingPluginException;
import 'package:mornye/services/autoplay_personalization.dart';
import 'package:mornye/services/autoplay_signal.dart';
import 'package:mornye/services/playable_media.dart';
import 'package:mornye/services/platform_bridge.dart';
import 'package:mornye/services/sqlite_helpers.dart' as sqlite;
import 'package:mornye/utils/artist_utils.dart' show splitArtistTagValues;
import 'package:mornye/utils/logger.dart';
import 'package:sqflite/sqflite.dart';

final _log = AppLogger('AutoplayTaste');

/// The most plays the log keeps, about 250 hours of listening. The oldest
/// go first.
const autoplayTasteLogLimit = 5000;

/// A pause longer than this starts a new listening session.
const autoplayTasteSessionGap = Duration(minutes: 30);

/// New plays that start learning again.
const _retrainAfter = 25;

/// Plays listened through before the model affects autoplay.
const _coldStart = 50;

/// Session songs, newest weighing most, that set what fits.
const _sessionWindow = 12;

/// The most the signal adds to a song that fits the session.
const _maxScore = 4.0;

// Skip-gram: songs on each side that count as played together, random
// tokens contrasted per pair, plays a token needs, and tokens kept.
const _window = 3;
const _negatives = 5;
const _minCount = 2;
const _vocabulary = 3000;
const _learningRate = 0.025;
const _seed = 0x7a57e;

String _key(String value) {
  final normalized = sqlite.normalizeLookupText(value);
  return normalized.length > 160 ? normalized.substring(0, 160) : normalized;
}

String _songToken(String song) => 'song:$song';
String _artistToken(String artist) => 'artist:$artist';

// How much a vector a song inherits counts at most against its own, from
// its album's songs, its credited artists, its genre's songs and in all.
const _albumTrust = 0.8;
const _creditTrust = 0.7;
const _genreTrust = 0.4;
const _inheritedTrust = 0.8;

/// Genre songs that give half the trust a genre can.
const _genreEvidence = 5;

final _genreSeparator = RegExp(r'[,;/|&]');

/// Each artist credited on [artist], normalized and once.
List<String> _credits(String artist) => {
  for (final credit in splitArtistTagValues(artist))
    if (_key(credit) case final key when key.isNotEmpty) key,
}.toList();

Iterable<String> _genreKeys(String? genre) => {
  for (final part in (genre ?? '').split(_genreSeparator))
    if (_key(part) case final key when key.isNotEmpty) key,
};

class _Sum {
  final vector = Float64List(AutoplayTasteModel.dimensions);
  int count = 0;

  void add(List<double> other, [int count = 1]) {
    for (var k = 0; k < vector.length; k++) {
      vector[k] += other[k];
    }
    this.count += count;
  }
}

/// Vectors songs without their own inherit from songs and artists the model
/// knows. An inherited vector's length is how much it counts, below 1.
class _TasteInheritance {
  _TasteInheritance(this._lookup);

  final Float32List? Function(String token) _lookup;
  final _albums = <String, _Sum>{}, _genres = <String, _Sum>{};

  // Libraries repeat artists far more often than they add new ones.
  final _creditsOf = <String, List<String>>{};
  final _genresOf = <String, List<String>>{};
  List<String> _creditsFor(String artist) =>
      _creditsOf[artist] ??= _credits(artist);
  List<String> _genreKeysFor(String? genre) =>
      _genresOf[genre ?? ''] ??= _genreKeys(genre).toList();

  /// A song with its own [vector], which its album and genre songs inherit.
  void learn(String artist, String album, String? genre, Float32List vector) {
    final albumKey = _key(album);
    if (albumKey.isNotEmpty) {
      // By album and artist, so albums that share a name stay apart.
      for (final credit in _creditsFor(artist)) {
        (_albums['$albumKey|$credit'] ??= _Sum()).add(vector);
      }
    }
    for (final key in _genreKeysFor(genre)) {
      (_genres[key] ??= _Sum()).add(vector);
    }
  }

  final _inherited = <String, Float64List?>{};

  /// The vector a song without its own inherits, or null when nothing it
  /// could inherit from is known. Each source adds its songs' mean vector,
  /// scaled by its trust and how much evidence it rests on, so sources that
  /// disagree cancel out. Asked after every [learn].
  Float64List? inherit(String artist, String album, String? genre) {
    // An album's songs mostly share all three.
    final key = '$artist\n$album\n${genre ?? ''}';
    if (_inherited.containsKey(key)) return _inherited[key];
    return _inherited[key] = _inherit(artist, album, genre);
  }

  Float64List? _inherit(String artist, String album, String? genre) {
    final vector = Float64List(AutoplayTasteModel.dimensions);
    void add(_Sum sum, double scale) {
      if (sum.count == 0) return;
      for (var k = 0; k < vector.length; k++) {
        vector[k] += scale * sum.vector[k] / sum.count;
      }
    }

    final credits = _creditsFor(artist);
    final albumKey = _key(album);
    if (albumKey.isNotEmpty && _albums.isNotEmpty) {
      final mates = _Sum();
      for (final credit in credits) {
        if (_albums['$albumKey|$credit'] case final sum?) {
          mates.add(sum.vector, sum.count);
        }
      }
      add(mates, _albumTrust * mates.count / (mates.count + 1));
    }
    final known = _Sum();
    for (final credit in credits) {
      if (_lookup(_artistToken(credit)) case final credited?) {
        known.add(credited);
      }
    }
    // An artist credited beside unknown ones explains less of the song.
    if (credits.isNotEmpty) {
      add(known, _creditTrust * known.count / credits.length);
    }
    if (_genres.isNotEmpty) {
      final genres = _Sum();
      for (final key in _genreKeysFor(genre)) {
        if (_genres[key] case final sum?) genres.add(sum.vector, sum.count);
      }
      add(genres, _genreTrust * genres.count / (genres.count + _genreEvidence));
    }

    final trust = sqrt(vector.fold(0.0, (sum, value) => sum + value * value));
    if (trust == 0) return null;
    if (trust > _inheritedTrust) {
      for (var k = 0; k < vector.length; k++) {
        vector[k] *= _inheritedTrust / trust;
      }
    }
    return vector;
  }
}

/// One play in the taste log. Metadata keys only: never a path, catalog id,
/// artwork or the original spelling.
class AutoplayTastePlay {
  const AutoplayTastePlay({
    this.id = 0,
    required this.song,
    required this.artist,
    required this.at,
    required this.kind,
    required this.reward,
  });

  factory AutoplayTastePlay.of(AutoplayFeedback feedback) {
    final artist = _key(feedback.track.artist);
    return AutoplayTastePlay(
      song: '$artist|${_key(feedback.track.title)}',
      artist: artist,
      at: feedback.at,
      kind: feedback.kind,
      reward: feedback.reward.isFinite ? feedback.reward.clamp(0.0, 1.0) : 0,
    );
  }

  /// The log's order; 0 until the play is stored.
  final int id;

  /// Normalized `artist|title`, and the normalized artist.
  final String song, artist;
  final DateTime at;
  final AutoplayFeedbackKind kind;
  final double reward;
}

/// [plays] in log order, split where more than [gap] passes after the
/// latest play before. Loves are logged when they happen and plays when
/// they start, so times may step back a little within a session.
List<List<AutoplayTastePlay>> splitAutoplayTasteSessions(
  List<AutoplayTastePlay> plays, {
  Duration gap = autoplayTasteSessionGap,
}) {
  final sessions = <List<AutoplayTastePlay>>[];
  DateTime? latest;
  for (final play in plays) {
    if (latest == null || play.at.difference(latest) > gap) {
      sessions.add([]);
      latest = play.at;
    }
    sessions.last.add(play);
    if (play.at.isAfter(latest)) latest = play.at;
  }
  return sessions;
}

/// Unit vectors of the songs and artists the listener plays, close together
/// when they are played together.
class AutoplayTasteModel {
  AutoplayTasteModel({
    required this.tokens,
    required this.vectors,
    required this.positives,
    required this.through,
  });

  static const int dimensions = 16;
  static const int _version = 1;

  /// `song:` and `artist:` keys, one row of [vectors] each.
  final List<String> tokens;
  final Float32List vectors;

  /// Plays listened through or replayed that the model learned from.
  final int positives;

  /// The last log entry the model learned.
  final int through;

  Map<String, int>? _rows;

  Float32List? _vector(String token) {
    final row = (_rows ??= {
      for (var i = 0; i < tokens.length; i++) tokens[i]: i,
    })[token];
    return row == null
        ? null
        : vectors.sublist(row * dimensions, (row + 1) * dimensions);
  }

  Float32List? song(String artist, String title) =>
      _vector(_songToken('${_key(artist)}|${_key(title)}'));

  Float32List? artist(String artist) => _vector(_artistToken(_key(artist)));

  /// Replaces the stored model. One row per token keeps rows small.
  Future<void> _save(Database db, List<(String, Uint8List)> rows) =>
      db.transaction((transaction) async {
        final batch = transaction.batch()
          ..delete('model')
          ..delete('vectors')
          ..insert('model', {
            'id': 1,
            'version': _version,
            'through': through,
            'positives': positives,
          });
        for (final (token, bytes) in rows) {
          batch.insert('vectors', {'token': token, 'vector': bytes});
        }
        await batch.commit(noResult: true);
      });

  static Future<AutoplayTasteModel?> _load(Database db) async {
    final meta = await db.query('model', where: 'id = 1');
    if (meta.isEmpty) return null;
    final through = meta.first['through'];
    final positives = meta.first['positives'];
    if (meta.first['version'] != _version ||
        through is! int ||
        positives is! int) {
      return null;
    }
    final rows = await db.query('vectors');
    if (rows.length > _vocabulary) return null;
    final tokens = <String>[];
    final vectors = Float32List(rows.length * dimensions);
    for (final row in rows) {
      final token = row['token'], bytes = row['vector'];
      if (token is! String ||
          bytes is! Uint8List ||
          bytes.length != dimensions * 4) {
        return null;
      }
      final data = ByteData.sublistView(bytes);
      for (var k = 0; k < dimensions; k++) {
        final value = data.getFloat32(k * 4, Endian.little);
        // An unreadable model is learned again from the log.
        if (!value.isFinite || value.abs() > 1.001) return null;
        vectors[tokens.length * dimensions + k] = value;
      }
      tokens.add(token);
    }
    return AutoplayTasteModel(
      tokens: tokens,
      vectors: vectors,
      positives: positives,
      through: through,
    );
  }
}

typedef _PackedTaste = ({
  AutoplayTasteModel model,
  List<(String, Uint8List)> rows,
});

_PackedTaste _packTaste(AutoplayTasteModel model) {
  const dimensions = AutoplayTasteModel.dimensions;
  final rows = <(String, Uint8List)>[];
  for (var row = 0; row < model.tokens.length; row++) {
    final data = ByteData(dimensions * 4);
    for (var k = 0; k < dimensions; k++) {
      data.setFloat32(
        k * 4,
        model.vectors[row * dimensions + k],
        Endian.little,
      );
    }
    rows.add((model.tokens[row], data.buffer.asUint8List()));
  }
  return (model: model, rows: rows);
}

_PackedTaste _trainPackedTaste(List<AutoplayTastePlay> plays) =>
    _packTaste(trainAutoplayTaste(plays));

Map<String, dynamic> _tasteTrainingRequest(List<AutoplayTastePlay> plays) => {
  'operation': 'train_autoplay_taste',
  'plays': [
    for (final play in plays)
      {
        'id': play.id,
        'song': play.song,
        'artist': play.artist,
        'atMicros': play.at.microsecondsSinceEpoch,
        'kind': play.kind.name,
        'reward': play.reward,
      },
  ],
};

_PackedTaste _hydrateNativeTaste(Map<String, dynamic> result) {
  final tokens = (result['tokens'] as List).cast<String>();
  final values = (result['vectors'] as List).cast<num>();
  if (tokens.length > _vocabulary ||
      values.length != tokens.length * AutoplayTasteModel.dimensions ||
      values.any((value) => !value.isFinite || value.abs() > 1.001)) {
    throw const FormatException('Invalid native autoplay taste model');
  }
  return _packTaste(
    AutoplayTasteModel(
      tokens: tokens,
      vectors: Float32List.fromList([
        for (final value in values) value.toDouble(),
      ]),
      positives: result['positives'] as int,
      through: result['through'] as int,
    ),
  );
}

Future<_PackedTaste> _trainNativePackedTaste(
  List<AutoplayTastePlay> plays,
) async {
  try {
    final request = await compute(_tasteTrainingRequest, plays);
    final result = await PlatformBridge.runNativeDataJob(request);
    return await compute(_hydrateNativeTaste, result);
  } on MissingPluginException {
    return compute(_trainPackedTaste, plays, debugLabel: 'autoplay-taste');
  }
}

/// Trains one snapshot on the native worker; persistence stays with Dart.
Future<AutoplayTasteModel> trainAutoplayTasteInBackground(
  List<AutoplayTastePlay> plays,
) async => (await _trainNativePackedTaste(plays)).model;

/// A training run's model and how many plays it learned from.
typedef _TasteRun = ({_PackedTaste taste, int plays});

/// The plays of stored `plays` [rows], in their order. A row of a kind this
/// build does not know drops out.
List<AutoplayTastePlay> autoplayTastePlaysFromRows(
  List<Map<String, Object?>> rows,
) {
  final kinds = AutoplayFeedbackKind.values.asNameMap();
  return [
    for (final row in rows)
      if (kinds[row['kind']] case final kind?)
        AutoplayTastePlay(
          id: row['id'] as int,
          song: row['song'] as String,
          artist: row['artist'] as String,
          at: DateTime.fromMillisecondsSinceEpoch(row['at'] as int),
          kind: kind,
          reward: (row['reward'] as num).toDouble(),
        ),
  ];
}

Map<String, dynamic> _tasteTrainingRequestFromRows(
  List<Map<String, Object?>> rows,
) => _tasteTrainingRequest(autoplayTastePlaysFromRows(rows));

_TasteRun? _trainPackedTasteFromRows(List<Map<String, Object?>> rows) {
  final plays = autoplayTastePlaysFromRows(rows);
  if (plays.isEmpty) return null;
  return (taste: _trainPackedTaste(plays), plays: plays.length);
}

/// As [_trainNativePackedTaste], with the rows read into plays on the worker
/// that already runs. Null when no row holds a play.
Future<_TasteRun?> _trainNativeTasteFromRows(
  List<Map<String, Object?>> rows,
) async {
  try {
    final request = await compute(_tasteTrainingRequestFromRows, rows);
    final plays = (request['plays'] as List).length;
    if (plays == 0) return null;
    final result = await PlatformBridge.runNativeDataJob(request);
    return (taste: await compute(_hydrateNativeTaste, result), plays: plays);
  } on MissingPluginException {
    return compute(
      _trainPackedTasteFromRows,
      rows,
      debugLabel: 'autoplay-taste',
    );
  }
}

class _Position {
  _Position(this.song, this.artist, this.weight);
  final String song, artist;

  /// How strongly the play ties the song to its session; negative for a
  /// skip.
  double weight;
}

typedef _Slot = ({int song, int artist, double weight});
typedef _Skip = ({int song, int at, double weight});

/// Learns song and artist vectors from [plays], in log order: skip-gram with
/// negative sampling (item2vec) over listening sessions, where each play is
/// its song and its artist. Songs played near each other, and each song and
/// its artist, are pulled together; random tokens, drawn by how often they
/// play, and songs skipped among them are pushed apart. Deterministic.
AutoplayTasteModel trainAutoplayTaste(List<AutoplayTastePlay> plays) {
  const d = AutoplayTasteModel.dimensions;
  var positives = 0, through = 0;
  final sessions = <List<_Position>>[];
  for (final session in splitAutoplayTasteSessions(plays)) {
    final positions = <_Position>[];
    final endorsed = <String, double>{};
    for (final play in session) {
      through = max(through, play.id);
      final strength = switch (play.kind) {
        AutoplayFeedbackKind.listened => play.reward,
        AutoplayFeedbackKind.replayed => 1.5,
        AutoplayFeedbackKind.loved => 2.0,
        AutoplayFeedbackKind.playlisted => 1.5,
        AutoplayFeedbackKind.skipped => -(1 - 2 * play.reward).clamp(0.0, 1.0),
      };
      if (play.kind == AutoplayFeedbackKind.loved ||
          play.kind == AutoplayFeedbackKind.playlisted) {
        // A choice, not a play: it strengthens the song's play here, and a
        // song chosen while another plays was not played with it.
        endorsed[play.song] = max(endorsed[play.song] ?? 0, strength);
        continue;
      }
      if (strength > 0) positives++;
      if (strength == 0) continue;
      final last = positions.isEmpty ? null : positions.last;
      if (last != null && last.song == play.song) {
        // A replay or a restart is one play of the song.
        last.weight = max(last.weight, strength);
      } else {
        positions.add(_Position(play.song, play.artist, strength));
      }
    }
    for (final position in positions) {
      final endorsement = endorsed[position.song];
      if (endorsement != null) {
        position.weight = max(position.weight, endorsement);
      }
    }
    sessions.add(positions);
  }

  final counts = <String, int>{};
  for (final session in sessions) {
    for (final position in session) {
      if (position.weight <= 0) continue;
      counts.update(
        _songToken(position.song),
        (count) => count + 1,
        ifAbsent: () => 1,
      );
      if (position.artist.isNotEmpty) {
        counts.update(
          _artistToken(position.artist),
          (count) => count + 1,
          ifAbsent: () => 1,
        );
      }
    }
  }
  final tokens = [
    for (final entry in counts.entries)
      if (entry.value >= _minCount) entry.key,
  ];
  tokens.sort((a, b) {
    final order = counts[b]!.compareTo(counts[a]!);
    return order != 0 ? order : a.compareTo(b);
  });
  if (tokens.length > _vocabulary) tokens.length = _vocabulary;
  final ids = {for (var i = 0; i < tokens.length; i++) tokens[i]: i};

  // Each session as its kept plays, and its skips with the number of kept
  // plays before them. -1 is a token the model does not keep.
  final encoded = <({List<_Slot> plays, List<_Skip> skips})>[];
  var slots = 0;
  for (final session in sessions) {
    final kept = <_Slot>[];
    final skips = <_Skip>[];
    for (final position in session) {
      final song = ids[_songToken(position.song)] ?? -1;
      if (position.weight < 0) {
        if (song >= 0) {
          skips.add((song: song, at: kept.length, weight: -position.weight));
        }
        continue;
      }
      final artist = position.artist.isEmpty
          ? -1
          : ids[_artistToken(position.artist)] ?? -1;
      if (song >= 0 || artist >= 0) {
        kept.add((song: song, artist: artist, weight: position.weight));
      }
    }
    if (kept.length > 1 || (kept.length == 1 && skips.isNotEmpty)) {
      encoded.add((plays: kept, skips: skips));
      slots += kept.length;
    }
  }

  final input = Float64List(tokens.length * d);
  final output = Float64List(tokens.length * d);
  final random = Random(_seed);
  for (var i = 0; i < input.length; i++) {
    input[i] = (random.nextDouble() - 0.5) / d;
  }
  // Negatives in proportion to count^0.75, so frequent tokens do not crowd
  // out the rest.
  final cumulative = Float64List(tokens.length);
  var total = 0.0;
  for (var i = 0; i < tokens.length; i++) {
    total += pow(counts[tokens[i]]!, 0.75);
    cumulative[i] = total;
  }
  int negative() {
    final target = random.nextDouble() * total;
    var low = 0, high = tokens.length - 1;
    while (low < high) {
      final middle = (low + high) >> 1;
      if (cumulative[middle] <= target) {
        low = middle + 1;
      } else {
        high = middle;
      }
    }
    return low;
  }

  final error = Float64List(d);
  void update(int center, int target, double label, double rate) {
    final c = center * d, t = target * d;
    var dot = 0.0;
    for (var k = 0; k < d; k++) {
      dot += input[c + k] * output[t + k];
    }
    final gradient = (label - 1 / (1 + exp(-dot))) * rate;
    for (var k = 0; k < d; k++) {
      error[k] += gradient * output[t + k];
      output[t + k] += gradient * input[c + k];
    }
  }

  void apply(int center) {
    final c = center * d;
    for (var k = 0; k < d; k++) {
      input[c + k] += error[k];
      error[k] = 0;
    }
  }

  // [center] played with [context].
  void together(int center, int context, double rate) {
    if (center < 0 || context < 0 || center == context) return;
    update(center, context, 1, rate);
    for (var n = 0; n < _negatives; n++) {
      final other = negative();
      if (other != center && other != context) update(center, other, 0, rate);
    }
    apply(center);
  }

  // [center] skipped among [context], or the reverse.
  void apart(int center, int context, double rate) {
    if (center < 0 || context < 0 || center == context) return;
    update(center, context, 0, rate);
    apply(center);
  }

  // Small histories get more passes, so a few sessions still learn.
  final epochs = slots == 0 ? 0 : (40000 / slots).ceil().clamp(5, 40);
  final steps = max(1, epochs * slots);
  var step = 0;
  for (var epoch = 0; epoch < epochs; epoch++) {
    for (final session in encoded) {
      final kept = session.plays;
      var alpha = _learningRate;
      for (var i = 0; i < kept.length; i++) {
        alpha = _learningRate * max(0.0001, 1 - step++ / steps);
        final here = kept[i];
        together(here.song, here.artist, alpha * here.weight);
        together(here.artist, here.song, alpha * here.weight);
        for (
          var j = max(0, i - _window);
          j <= min(kept.length - 1, i + _window);
          j++
        ) {
          if (j == i) continue;
          final there = kept[j];
          final rate =
              alpha *
              sqrt(here.weight * there.weight) *
              (_window + 1 - (i - j).abs()) /
              _window;
          together(here.song, there.song, rate);
          together(here.song, there.artist, rate);
          together(here.artist, there.song, rate);
          together(here.artist, there.artist, rate);
        }
      }
      for (final skip in session.skips) {
        for (
          var j = max(0, skip.at - _window);
          j < min(kept.length, skip.at + _window);
          j++
        ) {
          final there = kept[j];
          final distance = j < skip.at ? skip.at - j : j - skip.at + 1;
          final rate =
              alpha *
              0.5 *
              skip.weight *
              sqrt(there.weight) *
              (_window + 1 - distance) /
              _window;
          apart(skip.song, there.song, rate);
          apart(skip.song, there.artist, rate);
          apart(there.song, skip.song, rate);
          apart(there.artist, skip.song, rate);
        }
      }
    }
  }

  // Skip-gram vectors share a common direction that makes every pair look
  // alike; without it, unrelated songs sit near zero.
  final mean = Float64List(d);
  for (var i = 0; i < input.length; i++) {
    mean[i % d] += input[i] / tokens.length;
  }
  final vectors = Float32List(tokens.length * d);
  for (var row = 0; row < tokens.length; row++) {
    var norm = 0.0;
    for (var k = 0; k < d; k++) {
      final value = input[row * d + k] -= mean[k];
      norm += value * value;
    }
    norm = sqrt(norm);
    for (var k = 0; k < d; k++) {
      vectors[row * d + k] = norm == 0 ? 0 : input[row * d + k] / norm;
    }
  }
  return AutoplayTasteModel(
    tokens: tokens,
    vectors: vectors,
    positives: positives,
    through: through,
  );
}

/// Favors the songs the listener plays with the session's songs, across
/// artists and genres that tags do not connect. A song the model does not
/// know inherits a vector from its album's songs, its credited artists and
/// its genre's songs, which counts for less. Plain data only, so ranking
/// can run on a worker isolate.
class AutoplayTasteSignal extends AutoplaySignal {
  AutoplayTasteSignal(this.vectors);

  /// Unit vectors of the session's and candidates' songs and artists, and
  /// of the artists credited on candidates the model does not know.
  final Map<String, Float32List> vectors;

  @override
  String get name => 'taste';
  final _scores = <String, double>{};
  double _average = 0;

  Float32List? _song(PlayableMedia media) =>
      vectors[_songToken('${_key(media.artist)}|${_key(media.title)}')];

  /// The song's own vector, or its artist's when the song has none.
  Float32List? _vector(PlayableMedia media) =>
      _song(media) ?? vectors[_artistToken(_key(media.artist))];

  @override
  void prepare(List<PlayableMedia> session, List<PlayableMedia> candidates) {
    _scores.clear();
    _average = 0;
    final centre = Float64List(AutoplayTasteModel.dimensions);
    var weight = 1.0;
    for (var back = 0; back < min(session.length, _sessionWindow); back++) {
      final vector = _vector(session[session.length - 1 - back]);
      if (vector != null) {
        for (var k = 0; k < centre.length; k++) {
          centre[k] += weight * vector[k];
        }
      }
      weight *= 0.75;
    }
    final norm = sqrt(centre.fold(0.0, (sum, value) => sum + value * value));
    if (norm == 0) return;
    double fit(List<double> vector, double length) {
      var cosine = 0.0;
      for (var k = 0; k < centre.length; k++) {
        cosine += centre[k] * vector[k];
      }
      return _maxScore * (cosine / (norm * length)).clamp(0.0, 1.0);
    }

    final inheritance = _TasteInheritance((token) => vectors[token]);
    void learn(PlayableMedia media, Float32List? vector) {
      if (vector == null) return;
      inheritance.learn(media.artist, media.album, media.genre, vector);
    }

    final songs = [for (final candidate in candidates) _song(candidate)];
    for (final media in session) {
      learn(media, _song(media));
    }
    for (final (index, media) in candidates.indexed) {
      learn(media, songs[index]);
    }
    var total = 0.0;
    final inherited = <(String, double, double)>[];
    for (final (index, candidate) in candidates.indexed) {
      final vector =
          songs[index] ?? vectors[_artistToken(_key(candidate.artist))];
      if (vector != null) {
        final score = fit(vector, 1);
        _scores[candidate.source] = score;
        total += score;
      } else if (inheritance.inherit(
            candidate.artist,
            candidate.album,
            candidate.genre,
          )
          case final vector?) {
        final trust = sqrt(vector.fold(0.0, (sum, v) => sum + v * v));
        inherited.add((candidate.source, fit(vector, trust), trust));
      }
    }
    // Songs the model does not know score as an average known one.
    if (_scores.isNotEmpty) {
      _average = total / _scores.length;
    } else if (inherited.isNotEmpty) {
      _average =
          inherited.fold(0.0, (sum, entry) => sum + entry.$2) /
          inherited.length;
    }
    // An inherited vector moves a song from there only as far as it is
    // trusted.
    for (final (source, score, trust) in inherited) {
      _scores.putIfAbsent(source, () => _average + trust * (score - _average));
    }
  }

  @override
  double score(PlayableMedia candidate) =>
      _scores[candidate.source] ?? _average;
}

/// What [model] knows about [session] (in playback order, newest last) and
/// [candidates], or null when it knows none of the session's songs. Pure, so
/// it can run on a worker isolate.
AutoplayTasteSignal? autoplayTasteSignal(
  AutoplayTasteModel model,
  List<PlayableMedia> session,
  List<PlayableMedia> candidates,
) {
  final vectors = <String, Float32List>{};
  final credited = <String>{};
  void add(PlayableMedia media, {bool credits = false}) {
    final artist = _key(media.artist);
    var known = false;
    for (final token in [
      _songToken('$artist|${_key(media.title)}'),
      if (artist.isNotEmpty) _artistToken(artist),
    ]) {
      if (model._vector(token) case final vector?) {
        vectors[token] = vector;
        known = true;
      }
    }
    // What an unknown candidate may inherit from its credited artists.
    if (known || !credits || !credited.add(media.artist)) return;
    for (final credit in _credits(media.artist)) {
      final token = _artistToken(credit);
      if (vectors.containsKey(token)) continue;
      if (model._vector(token) case final vector?) vectors[token] = vector;
    }
  }

  // A few more than the window, as ranking merges repeats.
  for (final media in session.skip(
    max(0, session.length - _sessionWindow - 4),
  )) {
    add(media);
  }
  if (vectors.isEmpty) return null;
  for (final media in candidates) {
    add(media, credits: true);
  }
  return AutoplayTasteSignal(vectors);
}

/// Days after which a play counts half toward the listener's lasting taste.
const _profileHalfLife = 30;

/// The listener's lasting taste: the direction of what they listened
/// through, the latest counting most, for songs outside any session.
class AutoplayTasteProfile {
  AutoplayTasteProfile._(this._model, this._centre);

  final AutoplayTasteModel _model;

  /// A unit vector.
  final Float64List _centre;

  /// How well a song fits, -1 to 1: its vector's cosine to the taste, an
  /// inherited one shrunk toward 0 by its trust. Null when the model can
  /// place neither the song nor its artists.
  double? fit(String artist, String title) {
    final List<double>? vector =
        _model.song(artist, title) ??
        _model.artist(artist) ??
        _TasteInheritance(_model._vector).inherit(artist, '', null);
    if (vector == null) return null;
    var dot = 0.0;
    for (var k = 0; k < _centre.length; k++) {
      dot += _centre[k] * vector[k];
    }
    return dot;
  }
}

/// [model]'s taste of [plays] at [at]: listens, replays and loves by their
/// strength, halving every [_profileHalfLife] days; skips count for nothing.
/// Null when none of them is known.
AutoplayTasteProfile? autoplayTasteProfile(
  AutoplayTasteModel model,
  List<AutoplayTastePlay> plays, {
  required DateTime at,
}) {
  final centre = Float64List(AutoplayTasteModel.dimensions);
  for (final play in plays) {
    final strength = switch (play.kind) {
      AutoplayFeedbackKind.listened => play.reward,
      AutoplayFeedbackKind.replayed => 1.5,
      AutoplayFeedbackKind.loved => 2.0,
      AutoplayFeedbackKind.playlisted => 1.5,
      AutoplayFeedbackKind.skipped => 0.0,
    };
    if (strength <= 0) continue;
    final vector =
        model._vector(_songToken(play.song)) ??
        model._vector(_artistToken(play.artist));
    if (vector == null) continue;
    final days = max(0, at.difference(play.at).inHours) / 24;
    final weight = strength * pow(0.5, days / _profileHalfLife);
    for (var k = 0; k < centre.length; k++) {
      centre[k] += weight * vector[k];
    }
  }
  final norm = sqrt(centre.fold(0.0, (sum, value) => sum + value * value));
  if (norm == 0 || !norm.isFinite) return null;
  for (var k = 0; k < centre.length; k++) {
    centre[k] /= norm;
  }
  return AutoplayTasteProfile._(model, centre);
}

/// Learns, from this device's listening sessions only, which songs and
/// artists the listener plays together. Logs what [AutoplayPersonalization]
/// observes, which it reports only while learning is on.
class AutoplayTaste {
  AutoplayTaste({
    Future<Database> Function()? open,
    Future<AutoplayTasteModel> Function(List<AutoplayTastePlay>)? train,
  }) : _open = open ?? _openShared,
       _trainer = train == null
           ? _trainOnWorker
           : ((rows) async {
               final plays = autoplayTastePlaysFromRows(rows);
               if (plays.isEmpty) return null;
               return (
                 taste: _packTaste(await train(plays)),
                 plays: plays.length,
               );
             });

  final Future<Database> Function() _open;
  final Future<_TasteRun?> Function(List<Map<String, Object?>> rows) _trainer;
  final _pending = <AutoplayTastePlay>[];
  AutoplayTasteModel? _model;
  Future<void>? _loading, _training, _queued;
  Future<void> _writing = Future<void>.value();
  Timer? _saveTimer, _trainTimer;
  int _sinceTraining = 0, _generation = 0;
  bool _disposed = false;

  static final _shared = sqlite.SingleFlightInitializer<Database>();
  static const _schema = 1;

  static Future<Database> _openShared() => _shared.getOrCreate(
    () => sqlite.openAppDatabase(
      'autoplay_taste.db',
      version: _schema,
      onCreate: _create,
      onUpgrade: (_, _, _) async {},
    ),
  );

  static Future<void> _create(Database db, int version) async {
    await db.execute('''
      CREATE TABLE plays (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        at INTEGER NOT NULL,
        kind TEXT NOT NULL,
        reward REAL NOT NULL,
        song TEXT NOT NULL,
        artist TEXT NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE model (
        id INTEGER PRIMARY KEY CHECK (id = 1),
        version INTEGER NOT NULL,
        through INTEGER NOT NULL,
        positives INTEGER NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE vectors (
        token TEXT PRIMARY KEY,
        vector BLOB NOT NULL
      )
    ''');
  }

  /// Opens [path] with the taste schema through [factory], for host tests
  /// that use FFI.
  @visibleForTesting
  static Future<Database> openWithFactory(
    DatabaseFactory factory,
    String path,
  ) => factory.openDatabase(
    path,
    options: OpenDatabaseOptions(version: _schema, onCreate: _create),
  );

  static Future<_TasteRun?> _trainOnWorker(List<Map<String, Object?>> rows) =>
      _trainNativeTasteFromRows(rows);

  /// The model autoplay uses now, if any.
  @visibleForTesting
  AutoplayTasteModel? get model => _model;

  /// Logs [feedback]. Writes are batched and never wait on playback.
  void record(AutoplayFeedback feedback) {
    if (_disposed || _key(feedback.track.title).isEmpty) return;
    _pending.add(AutoplayTastePlay.of(feedback));
    if (_pending.length > autoplayTasteLogLimit) _pending.removeAt(0);
    _saveTimer ??= Timer(const Duration(seconds: 10), () => unawaited(flush()));
    if (++_sinceTraining >= _retrainAfter) _scheduleTraining();
  }

  void _scheduleTraining() {
    if (_disposed) return;
    _trainTimer ??= Timer(const Duration(seconds: 20), () {
      _trainTimer = null;
      unawaited(train());
    });
  }

  Future<void> flush() {
    _saveTimer?.cancel();
    _saveTimer = null;
    if (_pending.isEmpty) return _writing;
    final plays = List.of(_pending);
    _pending.clear();
    final generation = _generation;
    return _writing = _writing.then((_) async {
      if (generation != _generation) return;
      try {
        final batch = (await _open()).batch();
        for (final play in plays) {
          batch.insert('plays', {
            'at': play.at.millisecondsSinceEpoch,
            'kind': play.kind.name,
            'reward': play.reward,
            'song': play.song,
            'artist': play.artist,
          });
        }
        batch.rawDelete(
          'DELETE FROM plays WHERE id <= (SELECT MAX(id) FROM plays) - ?',
          [autoplayTasteLogLimit],
        );
        await batch.commit(noResult: true);
      } catch (error) {
        if (generation == _generation && !_disposed) {
          _pending.insertAll(0, plays);
          if (_pending.length > autoplayTasteLogLimit) {
            _pending.removeRange(0, _pending.length - autoplayTasteLogLimit);
          }
        }
        _log.w('Could not save autoplay listening sessions: $error');
      }
    });
  }

  /// The stored log, oldest first.
  Future<List<AutoplayTastePlay>> readLog() async =>
      autoplayTastePlaysFromRows(await _readRows());

  Future<List<Map<String, Object?>>> _readRows() async {
    await flush();
    return (await _open()).query('plays', orderBy: 'id');
  }

  /// Loads the cached model, and learns again when the log is newer.
  Future<void> _ensureLoaded() => _loading ??= () async {
    final generation = _generation;
    try {
      final db = await _open();
      final stored = await AutoplayTasteModel._load(db);
      final last =
          Sqflite.firstIntValue(
            await db.rawQuery('SELECT MAX(id) FROM plays'),
          ) ??
          0;
      if (generation != _generation || _disposed) return;
      // Training may have finished first.
      final model = _model ??= stored;
      if (last > (model?.through ?? 0)) _scheduleTraining();
    } catch (error) {
      _loading = null;
      _log.w('Autoplay listening sessions unavailable: $error');
    }
  }();

  /// Learns from the whole log on a worker isolate, then caches the model.
  /// A run already learning read the log before any later plays, so one
  /// more follows it then.
  Future<void> train() {
    _trainTimer?.cancel();
    _trainTimer = null;
    if (_disposed) return Future<void>.value();
    final running = _training;
    if (running == null) {
      return _training = _train().whenComplete(() => _training = null);
    }
    if (_sinceTraining == 0) return running;
    return _queued ??= running.then((_) {
      _queued = null;
      return train();
    });
  }

  Future<void> _train() async {
    final generation = _generation;
    _sinceTraining = 0;
    try {
      final rows = await _readRows();
      if (rows.isEmpty || generation != _generation || _disposed) return;
      final clock = Stopwatch()..start();
      // Null when no row holds a play this build knows.
      final run = await _trainer(rows);
      if (run == null || generation != _generation || _disposed) return;
      final trained = run.taste;
      final model = trained.model;
      _model = model;
      _log.d(
        'Learned ${model.tokens.length} songs and artists from '
        '${run.plays} plays in ${clock.elapsedMilliseconds} ms',
      );
      await (_writing = _writing.then((_) async {
        try {
          if (generation == _generation) {
            await model._save(await _open(), trained.rows);
          }
        } catch (error) {
          // The log stays; the next launch learns from it again.
          _log.w('Could not cache what autoplay learned: $error');
        }
      }));
    } catch (error) {
      _log.w('Could not learn from autoplay listening sessions: $error');
    }
  }

  /// The model when it knows enough to rank, else null.
  Future<AutoplayTasteModel?> _ready() async {
    if (_disposed) return null;
    await _ensureLoaded();
    final model = _model;
    if (model == null || model.positives < _coldStart) return null;
    return model;
  }

  /// What the model knows about [session] (in playback order, newest last)
  /// and [candidates], or null before it knows enough.
  Future<AutoplayTasteSignal?> signal(
    List<PlayableMedia> session,
    List<PlayableMedia> candidates,
  ) async {
    final model = await _ready();
    return model == null
        ? null
        : autoplayTasteSignal(model, session, candidates);
  }

  /// The model [autoplayTasteSignal] reads, for a worker isolate, or null
  /// before it knows enough. Its token index stays behind, so it copies less.
  Future<AutoplayTasteModel?> signalModel() async {
    final model = await _ready();
    if (model == null) return null;
    return AutoplayTasteModel(
      tokens: model.tokens,
      vectors: model.vectors,
      positives: model.positives,
      through: model.through,
    );
  }

  /// The listener's lasting taste, or null before the model knows enough.
  /// Reads the whole log, so callers wait until startup has settled.
  Future<AutoplayTasteProfile?> profile({DateTime? at}) async {
    if (_disposed) return null;
    await _ensureLoaded();
    final model = _model;
    if (model == null || model.positives < _coldStart) return null;
    try {
      final plays = await readLog();
      if (_disposed) return null;
      return autoplayTasteProfile(model, plays, at: at ?? DateTime.now());
    } catch (error) {
      _log.w('Could not read the lasting autoplay taste: $error');
      return null;
    }
  }

  Future<void> reset() async {
    _generation++;
    _pending.clear();
    _saveTimer?.cancel();
    _saveTimer = null;
    _trainTimer?.cancel();
    _trainTimer = null;
    _model = null;
    _sinceTraining = 0;
    await (_writing = _writing.then((_) async {
      try {
        final db = await _open();
        await db.transaction((transaction) async {
          await transaction.delete('plays');
          await transaction.delete('model');
          await transaction.delete('vectors');
        });
      } catch (error) {
        _log.w('Could not clear autoplay listening sessions: $error');
      }
    }));
  }

  Future<void> dispose() async {
    _disposed = true;
    _trainTimer?.cancel();
    _trainTimer = null;
    await flush();
  }
}
