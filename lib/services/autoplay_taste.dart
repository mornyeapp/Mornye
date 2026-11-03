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

@visibleForTesting
Future<AutoplayTasteModel> trainAutoplayTasteDartInBackground(
  List<AutoplayTastePlay> plays,
) async => (await compute(
  _trainPackedTaste,
  plays,
  debugLabel: 'autoplay-taste',
)).model;

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
/// artists and genres that tags do not connect. Plain data only, so ranking
/// can run on a worker isolate.
class AutoplayTasteSignal extends AutoplaySignal {
  AutoplayTasteSignal(this.vectors);

  /// Unit vectors of the session's and candidates' songs and artists only.
  final Map<String, Float32List> vectors;

  @override
  String get name => 'taste';
  final _scores = <String, double>{};
  double _average = 0;

  /// The song's own vector, or its artist's when the song has none.
  Float32List? _vector(PlayableMedia media) {
    final artist = _key(media.artist);
    return vectors[_songToken('$artist|${_key(media.title)}')] ??
        vectors[_artistToken(artist)];
  }

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
    var total = 0.0;
    for (final candidate in candidates) {
      final vector = _vector(candidate);
      if (vector == null) continue;
      var cosine = 0.0;
      for (var k = 0; k < centre.length; k++) {
        cosine += centre[k] * vector[k];
      }
      final score = _maxScore * (cosine / norm).clamp(0.0, 1.0);
      _scores[candidate.source] = score;
      total += score;
    }
    // Songs the model does not know score as an average known one.
    if (_scores.isNotEmpty) _average = total / _scores.length;
  }

  @override
  double score(PlayableMedia candidate) =>
      _scores[candidate.source] ?? _average;
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
           : ((plays) async => _packTaste(await train(plays)));

  final Future<Database> Function() _open;
  final Future<_PackedTaste> Function(List<AutoplayTastePlay>) _trainer;
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

  static Future<_PackedTaste> _trainOnWorker(List<AutoplayTastePlay> plays) =>
      _trainNativePackedTaste(plays);

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
  Future<List<AutoplayTastePlay>> readLog() async {
    await flush();
    final rows = await (await _open()).query('plays', orderBy: 'id');
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
      final plays = await readLog();
      if (plays.isEmpty || generation != _generation || _disposed) return;
      final clock = Stopwatch()..start();
      final trained = await _trainer(plays);
      if (generation != _generation || _disposed) return;
      final model = trained.model;
      _model = model;
      _log.d(
        'Learned ${model.tokens.length} songs and artists from '
        '${plays.length} plays in ${clock.elapsedMilliseconds} ms',
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

  /// What the model knows about [session] (in playback order, newest last)
  /// and [candidates], or null before it knows enough.
  Future<AutoplayTasteSignal?> signal(
    List<PlayableMedia> session,
    List<PlayableMedia> candidates,
  ) async {
    if (_disposed) return null;
    await _ensureLoaded();
    final model = _model;
    if (model == null || model.positives < _coldStart) return null;
    final vectors = <String, Float32List>{};
    void add(PlayableMedia media) {
      final artist = _key(media.artist);
      for (final token in [
        _songToken('$artist|${_key(media.title)}'),
        if (artist.isNotEmpty) _artistToken(artist),
      ]) {
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
      add(media);
    }
    return AutoplayTasteSignal(vectors);
  }

  /// Forgets every logged play and the model learned from them.
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
