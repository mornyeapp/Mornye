import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/autoplay_personalization.dart';
import 'package:mornye/services/library_mixes.dart';
import 'package:mornye/services/suggestion_outcomes.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

final _start = DateTime(2026, 11, 1, 9);

MixSongOutcome _mix(LibraryMixKind kind, {required bool played}) =>
    MixSongOutcome(at: _start, kind: kind, played: played);

RecommendationImpression _shown(
  String day,
  int song, {
  required int rank,
  int? sourceRank,
  double? fit,
  bool acted = false,
  DateTime? at,
}) => RecommendationImpression(
  day: day,
  song: song,
  at: at ?? _start,
  rank: rank,
  sourceRank: sourceRank ?? rank,
  fit: fit,
  actions: acted ? const {SuggestionAction.downloaded} : const {},
);

/// [days] shelves of four songs in the extension's order, the last one
/// acted on and fitting as [actedFit] against 0.5 for the others.
List<RecommendationImpression> _shelves(int days, {required double actedFit}) =>
    [
      for (var day = 0; day < days; day++)
        for (var song = 0; song < 4; song++)
          _shown(
            'd$day',
            day * 10 + song,
            rank: song,
            fit: song == 3 ? actedFit : 0.5,
            acted: song == 3,
          ),
    ];

AutoplayFeedback _feedback(
  String source, {
  AutoplayFeedbackKind kind = AutoplayFeedbackKind.listened,
  DateTime? at,
}) => AutoplayFeedback(
  kind: kind,
  track: AutoplayLearningTrack(source: source, title: source, artist: 'A'),
  previous: null,
  at: at ?? _start.add(const Duration(minutes: 1)),
  reward: kind == AutoplayFeedbackKind.skipped ? 0 : 1,
);

Future<Database> _database() async {
  sqfliteFfiInit();
  final directory = await Directory.systemTemp.createTemp('suggestions-');
  addTearDown(() => directory.delete(recursive: true));
  final db = await SuggestionOutcomes.openWithFactory(
    databaseFactoryFfi,
    '${directory.path}/suggestions.db',
  );
  addTearDown(db.close);
  return db;
}

void main() {
  test('mixes count songs played through, overall and by kind', () {
    final outcomes = [
      _mix(LibraryMixKind.genre, played: true),
      _mix(LibraryMixKind.genre, played: false),
      _mix(LibraryMixKind.genre, played: true),
      _mix(LibraryMixKind.discover, played: false),
    ];
    final all = mixPlayedShare(outcomes);
    expect((all.hits, all.total, all.share), (2, 4, 0.5));
    final kinds = mixPlayedShareByKind(outcomes);
    expect(kinds.keys, [LibraryMixKind.genre, LibraryMixKind.discover]);
    expect(kinds[LibraryMixKind.genre]!.share, closeTo(2 / 3, 1e-9));
    expect(kinds[LibraryMixKind.discover]!.share, 0);
    expect(mixPlayedShare(const []).share, isNull);
  });

  test('a recommended song counts once its week has passed', () {
    final now = _start.add(recommendationIgnoredAfter);
    final impressions = [
      _shown('old', 1, rank: 0, acted: true),
      _shown('old', 2, rank: 1),
      _shown('old', 3, rank: 2),
      // Still within its week, acted on or not.
      _shown('new', 4, rank: 0, acted: true, at: now),
      _shown('new', 5, rank: 1, at: now),
    ];
    final share = recommendationActedShare(impressions, now: now);
    expect((share.hits, share.total), (1, 3));
  });

  test('the fit is measured on shelves in the extension\'s order, pairs '
      'within a day and ties counting half', () {
    final now = _start.add(const Duration(days: 8));
    final evaluation = evaluateRecommendationFit([
      // Day a: the acted on song fits best, so both pairs are right.
      _shown('a', 1, rank: 0, fit: 0.9, acted: true),
      _shown('a', 2, rank: 1, fit: 0.2),
      _shown('a', 3, rank: 2, fit: 0.1),
      // Day b: one pair wrong, one tie; a song without a fit has no pair.
      _shown('b', 4, rank: 0, fit: 0.8),
      _shown('b', 5, rank: 1, fit: 0.4, acted: true),
      _shown('b', 6, rank: 2, fit: 0.4),
      _shown('b', 7, rank: 3),
      // A day without an ignored song has no pair.
      _shown('c', 8, rank: 0, fit: 0.9, acted: true),
      // A shelf put in the order of its fits is not measured.
      _shown('d', 9, rank: 0, sourceRank: 1, fit: 0.9, acted: true),
      _shown('d', 10, rank: 1, sourceRank: 0, fit: 0.1),
    ], now: now);
    expect((evaluation.actedOn, evaluation.ignored), (2, 4));
    expect(evaluation.auc, (2 + 0 + 0.5) / 4);
    expect(evaluation.helps, isNull);
  });

  test('the fit is judged only with enough evidence', () {
    final now = _start.add(const Duration(days: 8));
    // Nine acted on songs are not enough.
    expect(
      evaluateRecommendationFit(_shelves(9, actedFit: 0.9), now: now).helps,
      isNull,
    );
    final better = evaluateRecommendationFit(
      _shelves(10, actedFit: 0.9),
      now: now,
    );
    expect((better.actedOn, better.ignored), (10, 30));
    expect(better.auc, 1);
    expect(better.helps, isTrue);
    // A fit that tells nothing is no worse than the extension's order.
    expect(
      evaluateRecommendationFit(_shelves(10, actedFit: 0.5), now: now).helps,
      isTrue,
    );
    expect(
      evaluateRecommendationFit(_shelves(10, actedFit: 0.1), now: now).helps,
      isFalse,
    );
    // Unsettled shelves are not evidence yet.
    expect(
      evaluateRecommendationFit(_shelves(10, actedFit: 0.1), now: _start).helps,
      isNull,
    );
  });

  test('a song is keyed by its normalized artist and title only', () {
    expect(
      suggestionSongKey(' Some Artist ', 'A Song'),
      suggestionSongKey('some artist', 'a song  '.trim()),
    );
    expect(
      suggestionSongKey('Some Artist', 'A Song'),
      isNot(suggestionSongKey('Some Artist', 'Another Song')),
    );
  });

  test('a mix counts its songs only while its queue plays', () async {
    final db = await _database();
    final outcomes = SuggestionOutcomes(open: () async => db)..enabled = true;
    outcomes.followMix(
      LibraryMixKind.genre,
      ['/one', '/two', '/three'],
      queue: 4,
      since: _start,
    );
    // The song playing before the mix began.
    outcomes.recordPlay(
      _feedback('/one', at: _start.subtract(const Duration(minutes: 3))),
      queue: 4,
    );
    outcomes.recordPlay(_feedback('/one'), queue: 4);
    // Played again: only the first verdict counts.
    outcomes.recordPlay(
      _feedback('/one', kind: AutoplayFeedbackKind.skipped),
      queue: 4,
    );
    // A love is not how a play went; an autoplay pick is not the mix's.
    outcomes.recordPlay(
      _feedback('/two', kind: AutoplayFeedbackKind.loved),
      queue: 4,
    );
    outcomes.recordPlay(_feedback('/picked'), queue: 4);
    outcomes.recordPlay(
      _feedback('/two', kind: AutoplayFeedbackKind.skipped),
      queue: 4,
    );
    // Another queue replaced the mix; nothing after counts, even back on 4.
    outcomes.recordPlay(_feedback('/three'), queue: 5);
    outcomes.recordPlay(_feedback('/three'), queue: 4);
    expect(
      [
        for (final outcome in await outcomes.readMixOutcomes())
          (outcome.kind, outcome.played),
      ],
      [(LibraryMixKind.genre, true), (LibraryMixKind.genre, false)],
    );

    // Learning off follows nothing and ends the mix being followed.
    outcomes.followMix(
      LibraryMixKind.fresh,
      ['/four'],
      queue: 6,
      since: _start,
    );
    outcomes.enabled = false;
    outcomes.enabled = true;
    outcomes.recordPlay(_feedback('/four'), queue: 6);
    outcomes.enabled = false;
    outcomes.followMix(
      LibraryMixKind.fresh,
      ['/four'],
      queue: 6,
      since: _start,
    );
    outcomes.enabled = true;
    outcomes.recordPlay(_feedback('/four'), queue: 6);
    expect(await outcomes.readMixOutcomes(), hasLength(2));
  });

  test('a shown song keeps its first place of the day and its actions '
      'of the week', () async {
    final db = await _database();
    var now = _start;
    final outcomes = SuggestionOutcomes(open: () async => db, now: () => now)
      ..enabled = true;
    outcomes.recommendationShown(artist: 'Artist', title: 'Song', rank: 2);
    // The shelf rebuilt with the song moved up: still shown once today.
    outcomes.recommendationShown(artist: 'artist', title: 'song', rank: 1);
    outcomes.recommendationShown(
      artist: 'Artist',
      title: 'Other',
      rank: 3,
      sourceRank: 7,
      fit: 0.4,
    );
    now = now.add(const Duration(minutes: 5));
    outcomes.recommendationActed(
      artist: 'Artist',
      title: 'Song',
      action: SuggestionAction.previewed,
    );
    // Shown again the next day, then acted on.
    now = _start.add(const Duration(days: 1));
    outcomes.recommendationShown(artist: 'Artist', title: 'Song', rank: 0);
    now = now.add(const Duration(hours: 1));
    outcomes.recommendationActed(
      artist: 'Artist',
      title: 'Song',
      action: SuggestionAction.wishlisted,
    );
    // A week after the first day only the second still takes actions.
    now = _start.add(const Duration(days: 7, hours: 2));
    outcomes.recommendationActed(
      artist: 'Artist',
      title: 'Song',
      action: SuggestionAction.downloaded,
    );
    final song = suggestionSongKey('Artist', 'Song');
    final rows = await outcomes.readImpressions();
    expect(
      [
        for (final row in rows)
          (
            row.song == song,
            row.rank,
            row.sourceRank,
            row.fit,
            [for (final action in row.actions) action.name].join(','),
          ),
      ],
      [
        (true, 2, 2, null, 'previewed,wishlisted'),
        (false, 3, 7, 0.4, ''),
        (true, 0, 0, null, 'downloaded,wishlisted'),
      ],
    );
    expect(rows.first.day, '2026-11-01');
  });

  test('a shown song takes the place and fit the shelf gave it', () async {
    final db = await _database();
    final outcomes = SuggestionOutcomes(open: () async => db)..enabled = true;
    outcomes.placeRecommendations({
      suggestionSongKey('Artist', 'Song'): (sourceRank: 5, fit: 0.7),
      suggestionSongKey('Artist', 'Plain'): (sourceRank: 1, fit: null),
    });
    outcomes.recommendationShown(artist: 'Artist', title: 'Song', rank: 0);
    outcomes.recommendationShown(artist: 'Artist', title: 'Plain', rank: 1);
    outcomes.recommendationShown(artist: 'Artist', title: 'Unplaced', rank: 2);
    expect(
      [
        for (final row in await outcomes.readImpressions())
          (row.rank, row.sourceRank, row.fit),
      ],
      [(0, 5, 0.7), (1, 1, null), (2, 2, null)],
    );
  });

  test('nothing is logged while learning is off', () async {
    final db = await _database();
    final outcomes = SuggestionOutcomes(open: () async => db);
    outcomes.recommendationShown(artist: 'Artist', title: 'Song', rank: 0);
    outcomes.followMix(LibraryMixKind.genre, ['/one'], queue: 1, since: _start);
    outcomes.recordPlay(_feedback('/one'), queue: 1);
    expect(await outcomes.readImpressions(), isEmpty);
    expect(await outcomes.readMixOutcomes(), isEmpty);
  });

  test('a write reads the summary again for a listener, otherwise at the '
      'next read', () async {
    final db = await _database();
    final outcomes = SuggestionOutcomes(open: () async => db)..enabled = true;
    outcomes.followMix(
      LibraryMixKind.genre,
      ['/one', '/two', '/three'],
      queue: 1,
      since: _start,
    );
    Future<void> settle(int total) async {
      for (var i = 0; i < 100; i++) {
        if (outcomes.summary.value?.mixes.total == total) return;
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    }

    outcomes.recordPlay(_feedback('/one'), queue: 1);
    await outcomes.flush();
    await outcomes.refresh();
    expect(outcomes.summary.value!.mixes.total, 1);

    // Nothing listens: the write leaves the logs unread until the next read.
    final summary = outcomes.summary;
    outcomes.recordPlay(_feedback('/two'), queue: 1);
    await outcomes.flush();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(summary.value!.mixes.total, 1);
    await settle(2);
    expect(summary.value!.mixes.total, 2);

    // A listener sees each write.
    var heard = 0;
    void listener() => heard++;
    summary.addListener(listener);
    addTearDown(() => summary.removeListener(listener));
    outcomes.recordPlay(_feedback('/three'), queue: 1);
    await outcomes.flush();
    await settle(3);
    expect(summary.value!.mixes.total, 3);
    expect(heard, greaterThan(0));
  });

  test('each log keeps its latest rows, and a reset clears both', () async {
    final db = await _database();
    var now = _start;
    final outcomes = SuggestionOutcomes(open: () async => db, now: () => now)
      ..enabled = true;
    final sources = [
      for (var i = 0; i < suggestionOutcomesLogLimit + 5; i++) '/$i',
    ];
    outcomes.followMix(LibraryMixKind.genre, sources, queue: 1, since: _start);
    for (final (index, source) in sources.indexed) {
      outcomes.recordPlay(_feedback(source), queue: 1);
      if (index % 100 == 0) await outcomes.flush();
    }
    outcomes.recommendationShown(artist: 'Artist', title: 'Song', rank: 0);
    expect(
      await outcomes.readMixOutcomes(),
      hasLength(suggestionOutcomesLogLimit),
    );

    final summary = outcomes.summary;
    await outcomes.refresh();
    expect(summary.value!.mixes.total, suggestionOutcomesLogLimit);
    now = now.add(const Duration(days: 8));
    await outcomes.refresh();
    expect(summary.value!.recommendations.total, 1);

    await outcomes.reset();
    expect(summary.value!.mixes.total, 0);
    expect(await outcomes.readMixOutcomes(), isEmpty);
    expect(await outcomes.readImpressions(), isEmpty);
    // The day's songs may show again after a reset.
    now = _start;
    outcomes.recommendationShown(artist: 'Artist', title: 'Song', rank: 0);
    expect(await outcomes.readImpressions(), hasLength(1));
  });
}
