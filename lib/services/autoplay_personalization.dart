import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mornye/utils/logger.dart';

final _log = AppLogger('AutoplayLearning');
const _modelKey = 'autoplay_learning_model_v1';

/// Metadata only: signed URLs, credentials, artwork and audio never enter the
/// model. Source is used by the live session, not persisted as a feature.
class AutoplayLearningTrack {
  const AutoplayLearningTrack({
    required this.source,
    required this.title,
    required this.artist,
    this.album = '',
    this.genre = '',
    this.duration,
  });

  final String source, title, artist, album, genre;
  final Duration? duration;
}

/// What a learning observation came from.
enum AutoplayFeedbackKind {
  /// Played on, through at least half of the song.
  listened,

  /// Skipped early, or after a short part of the song.
  skipped,

  /// Played again on purpose and kept playing.
  replayed,

  /// Added to the loved songs.
  loved,

  /// Added to a playlist.
  playlisted,
}

/// One observation the model learns from. [weight] scales how far it moves
/// the model: an explicit choice, such as loving a song, counts more than
/// letting it play.
class AutoplayFeedback {
  const AutoplayFeedback({
    required this.kind,
    required this.track,
    required this.previous,
    required this.at,
    required this.reward,
    this.weight = 1,
  });

  final AutoplayFeedbackKind kind;
  final AutoplayLearningTrack track;
  final AutoplayLearningTrack? previous;
  final DateTime at;
  final double reward, weight;
}

String _text(String value) {
  final normalized = value.trim().toLowerCase();
  return normalized.length > 160 ? normalized.substring(0, 160) : normalized;
}

/// Online logistic regression with AdaGrad and hashed context interactions.
/// Two fixed arrays occupy 64 KiB regardless of Library/listening-history size.
/// The prior ranker supplies cold-start relevance; this model learns engagement.
class AutoplayPreferenceModel {
  static const int dimensions = 4096;
  final Float64List _weights = Float64List(dimensions);
  final Float64List _gradientSquares = Float64List(dimensions);
  int _observations = 0;
  DateTime? _updatedAt;

  int get observations => _observations;

  AutoplayPreferenceModel snapshot() {
    final copy = AutoplayPreferenceModel();
    copy._weights.setAll(0, _weights);
    copy._observations = _observations;
    return copy;
  }

  Map<int, double> _features(
    AutoplayLearningTrack track,
    AutoplayLearningTrack? previous,
    DateTime at,
  ) {
    final artist = _text(track.artist), album = _text(track.album);
    final genres = track.genre
        .split(RegExp(r'[,;/]'))
        .map(_text)
        .where((value) => value.isNotEmpty)
        .take(3)
        .toSet();
    final previousArtist = _text(previous?.artist ?? '');
    final previousGenre = _text(previous?.genre ?? '');
    final period = at.hour ~/ 6;
    // Whether a song continues the previous one's artist or genre, so the
    // model learns how much variety the listener keeps playing through.
    final sameArtist = artist.isNotEmpty && artist == previousArtist;
    final sameGenre = genres.isNotEmpty && genres.contains(previousGenre);
    final tokens = <String>[
      if (artist.isNotEmpty) 'artist:$artist',
      if (artist.isNotEmpty && album.isNotEmpty) 'album:$artist|$album',
      if (track.title.trim().isNotEmpty) 'song:$artist|${_text(track.title)}',
      for (final genre in genres) 'genre:$genre',
      if (artist.isNotEmpty) 'time:$period|artist:$artist',
      for (final genre in genres) 'time:$period|genre:$genre',
      if (previousArtist.isNotEmpty && artist.isNotEmpty)
        'transition:$previousArtist|$artist',
      for (final genre in genres)
        if (previousGenre.isNotEmpty) 'transition:$previousGenre|$genre',
      if (previousArtist.isNotEmpty && artist.isNotEmpty)
        sameArtist ? 'flow:same-artist' : 'flow:new-artist',
      if (previousGenre.isNotEmpty && genres.isNotEmpty)
        sameGenre ? 'flow:same-genre' : 'flow:new-genre',
      if (track.duration != null && track.duration! > Duration.zero)
        'duration:${min(5, track.duration!.inSeconds ~/ 90)}',
    ];
    final features = <int, double>{};
    for (final token in tokens) {
      // Stable FNV-1a, rather than String.hashCode (not stable across runtimes).
      var hash = 2166136261;
      for (final unit in token.codeUnits) {
        hash = ((hash ^ unit) * 16777619) & 0xffffffff;
      }
      final index = hash & (dimensions - 1);
      final sign = (hash & 0x80000000) == 0 ? 1.0 : -1.0;
      features[index] = (features[index] ?? 0) + sign;
    }
    final norm = sqrt(features.values.fold(0.0, (sum, v) => sum + v * v));
    if (norm > 0) features.updateAll((_, value) => value / norm);
    return features;
  }

  double _probability(Map<int, double> features) {
    var logit = 0.0;
    for (final entry in features.entries) {
      logit += _weights[entry.key] * entry.value;
    }
    return 1 / (1 + exp(-logit.clamp(-20.0, 20.0)));
  }

  double preference(
    AutoplayLearningTrack track, {
    AutoplayLearningTrack? previous,
    required DateTime at,
  }) => _probability(_features(track, previous, at));

  double rankAdjustment(
    AutoplayLearningTrack track, {
    required AutoplayLearningTrack previous,
    required DateTime at,
  }) =>
      20 *
      min(1.0, _observations / 20) *
      (preference(track, previous: previous, at: at) - 0.5);

  void learn(
    AutoplayLearningTrack track, {
    AutoplayLearningTrack? previous,
    required DateTime at,
    required double reward,
    double weight = 1,
  }) {
    if (!reward.isFinite || !weight.isFinite || weight <= 0) return;
    final features = _features(track, previous, at);
    if (features.isEmpty) return;
    final last = _updatedAt;
    if (last != null) {
      final days = at.difference(last).inDays;
      if (days > 0) {
        final decay = pow(0.98, min(90, days)).toDouble();
        for (var i = 0; i < dimensions; i++) {
          _weights[i] *= decay;
          _gradientSquares[i] *= decay;
        }
      }
    }
    final error =
        (_probability(features) - reward.clamp(0.0, 1.0)) * min(weight, 4);
    for (final entry in features.entries) {
      final i = entry.key;
      final gradient = error * entry.value + 0.001 * _weights[i];
      _gradientSquares[i] += gradient * gradient;
      _weights[i] =
          (_weights[i] - 0.18 * gradient / sqrt(_gradientSquares[i] + 0.01))
              .clamp(-8.0, 8.0);
    }
    _observations = min(1000000, _observations + 1);
    if (last == null || at.isAfter(last)) _updatedAt = at;
  }

  String encode() {
    final data = ByteData(dimensions * 16);
    for (var i = 0; i < dimensions; i++) {
      data.setFloat64(i * 16, _weights[i], Endian.little);
      data.setFloat64(i * 16 + 8, _gradientSquares[i], Endian.little);
    }
    return jsonEncode({
      'version': 1,
      'observations': _observations,
      'updatedAt': _updatedAt?.millisecondsSinceEpoch,
      'parameters': base64Encode(data.buffer.asUint8List()),
    });
  }

  static AutoplayPreferenceModel decode(String? raw) {
    final empty = AutoplayPreferenceModel();
    if (raw == null || raw.length > 100000) return empty;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map || decoded['version'] != 1) return empty;
      final count = decoded['observations'];
      final parameters = decoded['parameters'];
      final updated = decoded['updatedAt'];
      if (count is! int ||
          count < 0 ||
          count > 1000000 ||
          parameters is! String ||
          (updated != null && updated is! int)) {
        return empty;
      }
      final bytes = base64Decode(parameters);
      if (bytes.length != dimensions * 16) return empty;
      final data = ByteData.sublistView(bytes);
      final model = AutoplayPreferenceModel();
      for (var i = 0; i < dimensions; i++) {
        final weight = data.getFloat64(i * 16, Endian.little);
        final square = data.getFloat64(i * 16 + 8, Endian.little);
        if (!weight.isFinite ||
            weight.abs() > 8 ||
            !square.isFinite ||
            square < 0 ||
            square > 1e9) {
          return empty;
        }
        model._weights[i] = weight;
        model._gradientSquares[i] = square;
      }
      model._observations = count;
      if (updated is int) {
        model._updatedAt = DateTime.fromMillisecondsSinceEpoch(updated);
      }
      return model;
    } catch (_) {
      // Invalid/older snapshots are a cold start, never a playback failure.
      return empty;
    }
  }
}

class _LearningSession {
  _LearningSession(this.track, this.previous, this.at);
  AutoplayLearningTrack track;
  final AutoplayLearningTrack? previous;
  final DateTime at;
  Duration listened = Duration.zero;
  Duration? lastElapsed;
  bool playing = false;
  bool replayed = false;
}

/// Independent of listening-statistics opt-in. This explicitly enabled feature
/// records actual audible elapsed time, not seek position or paused wall time.
class AutoplayPersonalization {
  AutoplayPersonalization({
    Future<String?> Function()? load,
    Future<void> Function(String)? save,
    Duration Function()? elapsed,
    DateTime Function()? now,
  }) : _load = load ?? _loadPreferences,
       _save = save ?? _savePreferences,
       _elapsed = elapsed ?? (Stopwatch()..start()).elapsedGetter,
       _now = now ?? DateTime.now;

  final Future<String?> Function() _load;
  final Future<void> Function(String) _save;
  final Duration Function() _elapsed;
  final DateTime Function() _now;
  AutoplayPreferenceModel _model = AutoplayPreferenceModel();
  Future<void>? _loading;
  Future<void> _writing = Future<void>.value();
  bool _loaded = false, _enabled = false, _disposed = false, _dirty = false;
  Timer? _saveTimer;
  _LearningSession? _session;
  AutoplayLearningTrack? _previous;
  final _pending = <AutoplayFeedback>[];
  final _feedback = StreamController<AutoplayFeedback>.broadcast();

  int get observations => _model.observations;

  /// Each observation as the model learns it, only while learning is on.
  Stream<AutoplayFeedback> get feedback => _feedback.stream;

  AutoplayPreferenceModel? get rankingSnapshot =>
      _enabled && _loaded && !_disposed && _model.observations > 0
      ? _model.snapshot()
      : null;

  static Future<String?> _loadPreferences() async =>
      (await SharedPreferences.getInstance()).getString(_modelKey);

  static Future<void> _savePreferences(String value) async {
    if (!await (await SharedPreferences.getInstance()).setString(
      _modelKey,
      value,
    )) {
      throw StateError('Could not save autoplay learning');
    }
  }

  Future<void> ensureLoaded() => _loading ??= () async {
    try {
      _model = AutoplayPreferenceModel.decode(await _load());
    } catch (error) {
      _log.w('Learning unavailable; using ordinary autoplay: $error');
    }
    _loaded = true;
    // Feedback completed before disposal still belongs in the saved model.
    // Opt-out clears this buffer and prevents its application.
    if (_enabled) {
      for (final feedback in _pending) {
        _learn(feedback);
      }
    }
    _pending.clear();
  }();

  void setEnabled(bool enabled) {
    if (_disposed || _enabled == enabled) return;
    _enabled = enabled;
    _session = null;
    _previous = null;
    _pending.clear();
    if (enabled) {
      unawaited(ensureLoaded());
    } else {
      unawaited(flush());
    }
  }

  void begin(AutoplayLearningTrack track) {
    if (!_enabled || _disposed) return;
    finish();
    _session = _LearningSession(track, _previous, _now());
    _session!.lastElapsed = _elapsed();
    _previous = track;
  }

  void updatePlayback({
    required String? source,
    required bool playing,
    Duration? duration,
  }) {
    checkpoint();
    final session = _session;
    if (session == null) return;
    if (session.track.source != source) {
      session.playing = false;
      return;
    }
    if (duration != null && duration > Duration.zero) {
      final track = session.track;
      session.track = AutoplayLearningTrack(
        source: track.source,
        title: track.title,
        artist: track.artist,
        album: track.album,
        genre: track.genre,
        duration: duration,
      );
    }
    session.playing = playing;
  }

  void checkpoint() {
    final session = _session;
    if (session == null) return;
    final elapsed = _elapsed(), last = session.lastElapsed;
    session.lastElapsed = elapsed;
    if (session.playing && last != null && elapsed > last) {
      session.listened += elapsed - last;
    }
  }

  void finish({bool skipped = false}) {
    checkpoint();
    final session = _session;
    _session = null;
    if (session == null || !_enabled || _disposed) return;
    final seconds = session.listened.inMilliseconds / 1000;
    // Rapid queue taps and loading failures carry no preference signal.
    if (seconds < 3) return;
    final duration = session.track.duration?.inMilliseconds;
    final fraction = duration != null && duration > 0
        ? session.listened.inMilliseconds / duration
        : null;
    final AutoplayFeedbackKind kind;
    final double reward;
    var weight = 1.0;
    if (session.replayed && seconds >= 30) {
      kind = AutoplayFeedbackKind.replayed;
      reward = 1;
      weight = 1.5;
    } else if (skipped &&
        seconds < 30 &&
        (fraction == null || fraction < 0.25)) {
      // Skipping a song in its first seconds says the most.
      kind = AutoplayFeedbackKind.skipped;
      reward = 0;
      weight = seconds < 10 ? 1.5 : 1;
    } else if (skipped && fraction != null && fraction < 0.5) {
      kind = AutoplayFeedbackKind.skipped;
      reward = 0.25;
      weight = 0.5;
    } else if (fraction != null && fraction >= 0.5) {
      kind = AutoplayFeedbackKind.listened;
      reward = !skipped && fraction >= 0.9
          ? 1
          : (0.5 + fraction.clamp(0.0, 1.0) / 2).clamp(0.0, 1.0);
    } else if (fraction == null && seconds >= 120) {
      kind = AutoplayFeedbackKind.listened;
      reward = 0.75;
    } else {
      return;
    }
    _record(
      AutoplayFeedback(
        kind: kind,
        track: session.track,
        previous: session.previous,
        at: session.at,
        reward: reward,
        weight: weight,
      ),
    );
  }

  /// The listener went back to hear the current song again. It counts once
  /// they keep listening to it.
  void replayed() {
    if (!_enabled || _disposed) return;
    _session?.replayed = true;
  }

  /// The listener chose [track] outright, such as by loving it: a stronger
  /// signal than letting it play. The current song keeps its context.
  void endorse(AutoplayLearningTrack track, AutoplayFeedbackKind kind) {
    if (!_enabled || _disposed) return;
    final session = _session;
    final current =
        session != null &&
        _text(session.track.artist) == _text(track.artist) &&
        _text(session.track.title) == _text(track.title);
    _record(
      AutoplayFeedback(
        kind: kind,
        track: current ? session.track : track,
        previous: current ? session.previous : null,
        at: _now(),
        reward: 1,
        weight: kind == AutoplayFeedbackKind.loved ? 2 : 1.5,
      ),
    );
  }

  void _record(AutoplayFeedback feedback) {
    if (_loaded) {
      _learn(feedback);
    } else {
      if (_pending.length == 32) _pending.removeAt(0);
      _pending.add(feedback);
    }
  }

  void _learn(AutoplayFeedback feedback) {
    _model.learn(
      feedback.track,
      previous: feedback.previous,
      at: feedback.at,
      reward: feedback.reward,
      weight: feedback.weight,
    );
    if (!_feedback.isClosed) _feedback.add(feedback);
    _dirty = true;
    if (!_disposed) {
      _saveTimer ??= Timer(
        const Duration(seconds: 30),
        () => unawaited(flush()),
      );
    }
  }

  @visibleForTesting
  double adjustment(
    AutoplayLearningTrack track,
    AutoplayLearningTrack seed,
    DateTime at,
  ) => !_enabled || !_loaded || _disposed
      ? 0
      : _model.rankAdjustment(track, previous: seed, at: at);

  Future<void> flush() {
    _saveTimer?.cancel();
    _saveTimer = null;
    if (!_dirty || !_loaded) return _writing;
    final snapshot = _model.encode();
    _dirty = false;
    return _writing = _writing.then((_) async {
      try {
        await _save(snapshot);
      } catch (error) {
        _dirty = true;
        _log.w('Could not persist autoplay learning: $error');
      }
    });
  }

  Future<void> reset() async {
    _session = null;
    _previous = null;
    _pending.clear();
    await ensureLoaded();
    _model = AutoplayPreferenceModel();
    _dirty = true;
    await flush();
  }

  Future<void> dispose() async {
    finish();
    _disposed = true;
    await _loading;
    await flush();
    await _feedback.close();
  }
}

extension on Stopwatch {
  Duration elapsedGetter() => elapsed;
}
