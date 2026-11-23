import 'dart:async';

import 'package:flutter/foundation.dart'
    show ValueListenable, ValueNotifier, visibleForTesting;
import 'package:mornye/services/autoplay_personalization.dart';
import 'package:mornye/services/library_mixes.dart' show LibraryMixKind;
import 'package:mornye/services/listening_statistics.dart' show listeningDay;
import 'package:mornye/services/sqlite_helpers.dart' as sqlite;
import 'package:mornye/utils/logger.dart';
import 'package:sqflite/sqflite.dart';

final _log = AppLogger('SuggestionOutcomes');

/// The most rows each log keeps; the oldest go first.
const suggestionOutcomesLogLimit = 2000;

/// A recommended song with no action this long after it showed is ignored.
const recommendationIgnoredAfter = Duration(days: 7);

/// Outcomes a share needs before Settings shows it.
const suggestionShareMinimum = 20;

/// Acted on and ignored songs each needed before the taste fit is judged.
const recommendationOrderMinimum = 10;

// Writes waiting on a store that keeps failing; the oldest go first.
const _pendingLimit = 500;

/// What the listener did with a recommended song. Stored as one bit per
/// value by index, so new values go last.
enum SuggestionAction {
  opened,
  previewed,
  downloaded,
  wishlisted,
  loved,
  playlisted,
}

/// How one song of a mix went: played on or skipped. No song identity.
class MixSongOutcome {
  const MixSongOutcome({
    required this.at,
    required this.kind,
    required this.played,
  });

  final DateTime at;
  final LibraryMixKind kind;

  /// Listened through or replayed, rather than skipped.
  final bool played;
}

/// One recommended song shown on one day: where it sat, and what the
/// listener did with it. [song] is a hash of the normalized `artist|title`.
class RecommendationImpression {
  const RecommendationImpression({
    required this.day,
    required this.song,
    required this.at,
    required this.rank,
    required this.sourceRank,
    this.fit,
    this.actions = const {},
  });

  /// The listening day, as `listeningDay` spells it.
  final String day;
  final int song;
  final DateTime at;

  /// Its position as shown and as the extension gave it; 0 is first.
  final int rank, sourceRank;

  /// How well it fits the listener's taste, when the order used one.
  final double? fit;
  final Set<SuggestionAction> actions;

  bool get actedOn => actions.isNotEmpty;

  /// Whether its week has passed, so no later action can count for it.
  bool settledBy(DateTime now) =>
      now.difference(at) >= recommendationIgnoredAfter;
}

/// [hits] of [total] outcomes, such as songs played rather than skipped.
class OutcomeShare {
  const OutcomeShare(this.hits, this.total);

  final int hits, total;

  /// Null without outcomes.
  double? get share => total == 0 ? null : hits / total;
}

/// The share of mix songs played rather than skipped, of [kind] or of all.
OutcomeShare mixPlayedShare(
  Iterable<MixSongOutcome> outcomes, {
  LibraryMixKind? kind,
}) {
  var hits = 0, total = 0;
  for (final outcome in outcomes) {
    if (kind != null && outcome.kind != kind) continue;
    total++;
    if (outcome.played) hits++;
  }
  return OutcomeShare(hits, total);
}

/// [mixPlayedShare] for each kind that has outcomes.
Map<LibraryMixKind, OutcomeShare> mixPlayedShareByKind(
  Iterable<MixSongOutcome> outcomes,
) => {
  for (final kind in LibraryMixKind.values)
    if (mixPlayedShare(outcomes, kind: kind) case final share
        when share.total > 0)
      kind: share,
};

/// The share of settled recommended songs the listener acted on. Songs
/// still within their week wait, so acted on and ignored ones count alike.
OutcomeShare recommendationActedShare(
  Iterable<RecommendationImpression> impressions, {
  required DateTime now,
}) {
  var hits = 0, total = 0;
  for (final impression in impressions) {
    if (!impression.settledBy(now)) continue;
    total++;
    if (impression.actedOn) hits++;
  }
  return OutcomeShare(hits, total);
}

/// Settled impressions by day, only the days with an acted on and an
/// ignored song: the shelves where an order could be right or wrong.
Map<String, List<RecommendationImpression>> _comparableDays(
  Iterable<RecommendationImpression> impressions,
  DateTime now,
) {
  final days = <String, List<RecommendationImpression>>{};
  for (final impression in impressions) {
    if (impression.settledBy(now)) {
      (days[impression.day] ??= []).add(impression);
    }
  }
  days.removeWhere(
    (_, shelf) =>
        !shelf.any((impression) => impression.actedOn) ||
        shelf.every((impression) => impression.actedOn),
  );
  return days;
}

/// Whether the taste fit tells the songs acted on from the ignored ones:
/// measured on the settled shelves shown in the extension's order, where a
/// song's place owes nothing to its fit.
class RecommendationFitEvaluation {
  const RecommendationFitEvaluation({
    this.actedOn = 0,
    this.ignored = 0,
    this.auc,
  });

  /// Songs with a fit counted, on the shelves measured.
  final int actedOn, ignored;

  /// The share of acted on and ignored pairs of one shelf where the acted
  /// on song fits better, ties counting half. Null without such a pair.
  final double? auc;

  /// Whether ordering by fit helps; null until each kind has
  /// [recommendationOrderMinimum].
  bool? get helps {
    final auc = this.auc;
    if (actedOn < recommendationOrderMinimum ||
        ignored < recommendationOrderMinimum ||
        auc == null) {
      return null;
    }
    return auc >= 0.5;
  }
}

RecommendationFitEvaluation evaluateRecommendationFit(
  Iterable<RecommendationImpression> impressions, {
  required DateTime now,
}) {
  var right = 0.0;
  var pairs = 0, actedOn = 0, ignored = 0;
  for (final shelf in _comparableDays(impressions, now).values) {
    // A shelf put in the order of its fits says little about them: songs
    // shown first are acted on more wherever they come from.
    if (shelf.any((impression) => impression.rank != impression.sourceRank)) {
      continue;
    }
    final fitted = shelf.where((impression) => impression.fit != null);
    final acted = [...fitted.where((impression) => impression.actedOn)];
    final rest = [...fitted.where((impression) => !impression.actedOn)];
    if (acted.isEmpty || rest.isEmpty) continue;
    actedOn += acted.length;
    ignored += rest.length;
    for (final a in acted) {
      for (final b in rest) {
        pairs++;
        right += a.fit! > b.fit! ? 1 : (a.fit == b.fit ? 0.5 : 0);
      }
    }
  }
  return RecommendationFitEvaluation(
    actedOn: actedOn,
    ignored: ignored,
    auc: pairs == 0 ? null : right / pairs,
  );
}

/// What the logs say so far, for Settings and for ordering the shelf.
class SuggestionOutcomeSummary {
  const SuggestionOutcomeSummary({
    this.mixes = const OutcomeShare(0, 0),
    this.mixKinds = const {},
    this.recommendations = const OutcomeShare(0, 0),
    this.fit = const RecommendationFitEvaluation(),
  });

  final OutcomeShare mixes;
  final Map<LibraryMixKind, OutcomeShare> mixKinds;
  final OutcomeShare recommendations;
  final RecommendationFitEvaluation fit;
}

SuggestionOutcomeSummary summarizeSuggestionOutcomes(
  List<MixSongOutcome> mixes,
  List<RecommendationImpression> impressions, {
  required DateTime now,
}) => SuggestionOutcomeSummary(
  mixes: mixPlayedShare(mixes),
  mixKinds: mixPlayedShareByKind(mixes),
  recommendations: recommendationActedShare(impressions, now: now),
  fit: evaluateRecommendationFit(impressions, now: now),
);

String _key(String value) {
  final normalized = sqlite.normalizeLookupText(value);
  return normalized.length > 160 ? normalized.substring(0, 160) : normalized;
}

/// The key a recommended song is logged under: FNV-1a of the normalized
/// `artist|title`, as autoplay learning hashes its tokens.
int suggestionSongKey(String artist, String title) {
  var hash = 2166136261;
  for (final unit in '${_key(artist)}|${_key(title)}'.codeUnits) {
    hash = ((hash ^ unit) * 16777619) & 0xffffffff;
  }
  return hash;
}

/// A mix the listener started, followed while its queue plays.
class _MixPlay {
  _MixPlay(this.kind, this.sources, this.queue, this.since);

  final LibraryMixKind kind;
  final Set<String> sources;
  final int queue;
  final DateTime since;

  /// Songs already counted, so a repeat counts once.
  final heard = <String>{};
}

class _SummaryNotifier extends ValueNotifier<SuggestionOutcomeSummary?> {
  _SummaryNotifier() : super(null);

  bool get listened => hasListeners;
}

/// Whether Home's suggestions work for this listener, on this device only:
/// how the songs of a played mix go, and what the listener does with the
/// recommended songs shown. No titles, names, paths or ids are stored.
class SuggestionOutcomes {
  SuggestionOutcomes({
    Future<Database> Function()? open,
    DateTime Function()? now,
  }) : _open = open ?? _openShared,
       _now = now ?? DateTime.now;

  final Future<Database> Function() _open;
  final DateTime Function() _now;
  final _pendingMixes = <MixSongOutcome>[];
  final _pendingShown = <RecommendationImpression>[];
  final _pendingActions = <(int, SuggestionAction, DateTime)>[];
  final _summary = _SummaryNotifier();
  final _shownToday = <int>{};
  String? _shownDay;
  Map<int, ({int sourceRank, double? fit})> _places = const {};
  _MixPlay? _mix;
  Future<void> _writing = Future<void>.value();
  Future<void>? _loading;
  bool _enabled = false, _flushScheduled = false, _disposed = false;
  int _generation = 0;

  static final _shared = sqlite.SingleFlightInitializer<Database>();
  static const _schema = 1;

  static Future<Database> _openShared() => _shared.getOrCreate(
    () => sqlite.openAppDatabase(
      'suggestion_outcomes.db',
      version: _schema,
      onCreate: _create,
      onUpgrade: (_, _, _) async {},
    ),
  );

  static Future<void> _create(Database db, int version) async {
    await db.execute('''
      CREATE TABLE mix_outcomes (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        at INTEGER NOT NULL,
        kind TEXT NOT NULL,
        played INTEGER NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE impressions (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        day TEXT NOT NULL,
        song INTEGER NOT NULL,
        at INTEGER NOT NULL,
        rank INTEGER NOT NULL,
        source_rank INTEGER NOT NULL,
        fit REAL,
        actions INTEGER NOT NULL DEFAULT 0,
        UNIQUE (day, song)
      )
    ''');
    await db.execute('CREATE INDEX impressions_song ON impressions (song, at)');
  }

  /// Opens [path] with this schema through [factory], for host tests that
  /// use FFI.
  @visibleForTesting
  static Future<Database> openWithFactory(
    DatabaseFactory factory,
    String path,
  ) => factory.openDatabase(
    path,
    options: OpenDatabaseOptions(version: _schema, onCreate: _create),
  );

  /// Whether learning is on, by its setting and the player mode. Nothing is
  /// logged while it is off.
  bool get enabled => _enabled && !_disposed;

  set enabled(bool value) {
    _enabled = value;
    if (!value) _mix = null;
  }

  /// Follows a mix of [kind] the listener just started as queue number
  /// [queue], with songs [sources]: until another queue replaces it, how
  /// each of its songs that began after [since] goes counts for the mix.
  void followMix(
    LibraryMixKind kind,
    Iterable<String> sources, {
    required int queue,
    required DateTime since,
  }) {
    _mix = enabled ? _MixPlay(kind, sources.toSet(), queue, since) : null;
  }

  /// Counts [feedback] for the mix being followed, while [queue] is still
  /// the one the mix started. Only the first verdict on each song counts.
  void recordPlay(AutoplayFeedback feedback, {required int? queue}) {
    final mix = _mix;
    if (mix == null || !enabled) return;
    if (queue != mix.queue) {
      _mix = null;
      return;
    }
    final played = switch (feedback.kind) {
      AutoplayFeedbackKind.listened || AutoplayFeedbackKind.replayed => true,
      AutoplayFeedbackKind.skipped => false,
      // Loves and playlist additions are not how a play went.
      AutoplayFeedbackKind.loved || AutoplayFeedbackKind.playlisted => null,
    };
    final source = feedback.track.source;
    if (played == null ||
        feedback.at.isBefore(mix.since) ||
        !mix.sources.contains(source) ||
        !mix.heard.add(source)) {
      return;
    }
    _add(
      _pendingMixes,
      MixSongOutcome(at: feedback.at, kind: mix.kind, played: played),
    );
  }

  /// Where the extension put the shelf's songs and how well each fits, by
  /// [suggestionSongKey]: what [recommendationShown] logs for a song whose
  /// caller knows only where it shows.
  void placeRecommendations(Map<int, ({int sourceRank, double? fit})> places) =>
      _places = places;

  /// Logs a recommended song the shelf showed, once a day per song: at
  /// [rank] as shown and [sourceRank] as the extension gave it (the same
  /// when neither it nor its place is known), with its taste [fit], if any.
  void recommendationShown({
    required String artist,
    required String title,
    required int rank,
    int? sourceRank,
    double? fit,
  }) {
    if (!enabled || title.trim().isEmpty) return;
    final at = _now();
    final day = listeningDay(at);
    if (day != _shownDay) {
      _shownDay = day;
      _shownToday.clear();
    }
    final song = suggestionSongKey(artist, title);
    if (!_shownToday.add(song)) return;
    final place = _places[song];
    fit ??= place?.fit;
    _add(
      _pendingShown,
      RecommendationImpression(
        day: day,
        song: song,
        at: at,
        rank: rank,
        sourceRank: sourceRank ?? place?.sourceRank ?? rank,
        fit: fit != null && fit.isFinite ? fit : null,
      ),
    );
  }

  /// Logs [action] on a recommended song, for each day the shelf showed it
  /// within the last [recommendationIgnoredAfter].
  void recommendationActed({
    required String artist,
    required String title,
    required SuggestionAction action,
  }) {
    if (!enabled || title.trim().isEmpty) return;
    _add(_pendingActions, (suggestionSongKey(artist, title), action, _now()));
  }

  void _add<T>(List<T> pending, T entry) {
    if (pending.length >= _pendingLimit) pending.removeAt(0);
    pending.add(entry);
    // A burst, such as a shelf's songs showing, is written at once.
    if (_flushScheduled) return;
    _flushScheduled = true;
    scheduleMicrotask(() {
      _flushScheduled = false;
      unawaited(flush());
    });
  }

  Future<void> flush() {
    if (_pendingMixes.isEmpty &&
        _pendingShown.isEmpty &&
        _pendingActions.isEmpty) {
      return _writing;
    }
    final mixes = List.of(_pendingMixes);
    final shown = List.of(_pendingShown);
    final actions = List.of(_pendingActions);
    _pendingMixes.clear();
    _pendingShown.clear();
    _pendingActions.clear();
    final generation = _generation;
    return _writing = _writing.then((_) async {
      if (generation != _generation) return;
      try {
        final batch = (await _open()).batch();
        for (final impression in shown) {
          batch.insert('impressions', {
            'day': impression.day,
            'song': impression.song,
            'at': impression.at.millisecondsSinceEpoch,
            'rank': impression.rank,
            'source_rank': impression.sourceRank,
            'fit': impression.fit,
          }, conflictAlgorithm: ConflictAlgorithm.ignore);
        }
        for (final (song, action, at) in actions) {
          final ms = at.millisecondsSinceEpoch;
          batch.rawUpdate(
            'UPDATE impressions SET actions = actions | ? '
            'WHERE song = ? AND at <= ? AND at > ?',
            [
              1 << action.index,
              song,
              ms,
              ms - recommendationIgnoredAfter.inMilliseconds,
            ],
          );
        }
        for (final outcome in mixes) {
          batch.insert('mix_outcomes', {
            'at': outcome.at.millisecondsSinceEpoch,
            'kind': outcome.kind.name,
            'played': outcome.played ? 1 : 0,
          });
        }
        for (final table in ['impressions', 'mix_outcomes']) {
          batch.rawDelete(
            'DELETE FROM $table WHERE id <= (SELECT MAX(id) FROM $table) - ?',
            [suggestionOutcomesLogLimit],
          );
        }
        await batch.commit(noResult: true);
      } catch (error) {
        if (generation == _generation && !_disposed) {
          _pendingMixes.insertAll(0, mixes);
          _pendingShown.insertAll(0, shown);
          _pendingActions.insertAll(0, actions);
        }
        _log.w('Could not save suggestion outcomes: $error');
        return;
      }
      // Read the logs again only for a listener; otherwise the next read of
      // [summary] does.
      if (_summary.value != null) {
        _summary.listened ? unawaited(refresh()) : _loading = null;
      }
    });
  }

  /// The stored mix outcomes, oldest first.
  Future<List<MixSongOutcome>> readMixOutcomes() async {
    await flush();
    final rows = await (await _open()).query('mix_outcomes', orderBy: 'id');
    return [
      for (final row in rows)
        if (LibraryMixKind.values.asNameMap()[row['kind']] case final kind?)
          MixSongOutcome(
            at: DateTime.fromMillisecondsSinceEpoch(row['at'] as int),
            kind: kind,
            played: row['played'] == 1,
          ),
    ];
  }

  /// The stored impressions, oldest first.
  Future<List<RecommendationImpression>> readImpressions() async {
    await flush();
    final rows = await (await _open()).query('impressions', orderBy: 'id');
    return [
      for (final row in rows)
        RecommendationImpression(
          day: row['day'] as String,
          song: row['song'] as int,
          at: DateTime.fromMillisecondsSinceEpoch(row['at'] as int),
          rank: row['rank'] as int,
          sourceRank: row['source_rank'] as int,
          fit: (row['fit'] as num?)?.toDouble(),
          actions: {
            for (final action in SuggestionAction.values)
              if ((row['actions'] as int) & (1 << action.index) != 0) action,
          },
        ),
    ];
  }

  /// The latest summary, null until the logs are read.
  ValueListenable<SuggestionOutcomeSummary?> get summary {
    if (!_disposed) _loading ??= refresh();
    return _summary;
  }

  /// Reads the logs again into [summary].
  Future<void> refresh() async {
    final generation = _generation;
    try {
      final (mixes, impressions) = await (
        readMixOutcomes(),
        readImpressions(),
      ).wait;
      if (generation != _generation || _disposed) return;
      _summary.value = summarizeSuggestionOutcomes(
        mixes,
        impressions,
        now: _now(),
      );
    } catch (error) {
      _loading = null;
      _log.w('Could not read suggestion outcomes: $error');
    }
  }

  /// Forgets every outcome, as resetting learning does.
  Future<void> reset() async {
    _generation++;
    _mix = null;
    _pendingMixes.clear();
    _pendingShown.clear();
    _pendingActions.clear();
    _shownToday.clear();
    _shownDay = null;
    _places = const {};
    _summary.value = const SuggestionOutcomeSummary();
    await (_writing = _writing.then((_) async {
      try {
        final db = await _open();
        await db.delete('mix_outcomes');
        await db.delete('impressions');
      } catch (error) {
        _log.w('Could not clear suggestion outcomes: $error');
      }
    }));
  }

  Future<void> dispose() async {
    _disposed = true;
    _mix = null;
    await flush();
  }
}
