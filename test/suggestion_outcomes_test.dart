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
  bool acted = false,
  DateTime? at,
}) => RecommendationImpression(
  day: day,
  song: song,
  at: at ?? _start,
  rank: rank,
  sourceRank: sourceRank ?? rank,
  actions: acted ? const {SuggestionAction.downloaded} : const {},
);

/// [days] shelves of four songs where the extension's order puts the acted
/// on song last and the shown order puts it [shownRank].
List<RecommendationImpression> _shelves(int days, {required int shownRank}) => [
  for (var day = 0; day < days; day++)
    for (var song = 0; song < 4; song++)
      _shown(
        'd$day',
        day * 10 + song,
        // Song 3 is the one acted on.
        sourceRank: song,
        rank: song == 3
            ? shownRank
            : (song < shownRank ? song : song + 1).clamp(0, 3),
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

  test('order AUC pairs songs within a day, ties counting half', () {
    final now = _start.add(const Duration(days: 8));
    // Day a: acted on first, so both pairs are right.
    // Day b: acted on between two ignored, and one tie.
    final impressions = [
      _shown('a', 1, rank: 0, acted: true),
      _shown('a', 2, rank: 1),
      _shown('a', 3, rank: 2),
      _shown('b', 4, rank: 0),
      _shown('b', 5, rank: 1, acted: true),
      _shown('b', 6, rank: 2),
      _shown('b', 7, rank: 1),
      // A day without an ignored song has no pair.
      _shown('c', 8, rank: 5, acted: true),
    ];
    expect(
      recommendationOrderAuc(impressions, (i) => i.rank, now: now),
      (2 + 0 + 1 + 0.5) / 5,
    );
    expect(
      recommendationOrderAuc(
        impressions.where((i) => !i.actedOn),
        (i) => i.rank,
        now: now,
      ),
      isNull,
    );
  });

  test('the shown order is judged only with enough evidence', () {
    final now = _start.add(const Duration(days: 8));
    // Nine acted on songs are not enough.
    expect(
      compareRecommendationOrders(
        _shelves(9, shownRank: 0),
        now: now,
      ).shownAtLeastAsGood,
      isNull,
    );
    final better = compareRecommendationOrders(
      _shelves(10, shownRank: 0),
      now: now,
    );
    expect((better.actedOn, better.ignored), (10, 30));
    expect((better.shown, better.source), (1.0, 0.0));
    expect(better.shownAtLeastAsGood, isTrue);
    // The same order ranks as well as itself.
    expect(
      compareRecommendationOrders(
        _shelves(10, shownRank: 3),
        now: now,
      ).shownAtLeastAsGood,
      isTrue,
    );
    final worse = compareRecommendationOrders([
      for (final impression in _shelves(10, shownRank: 3))
        RecommendationImpression(
          day: impression.day,
          song: impression.song,
          at: impression.at,
          rank: impression.rank,
          sourceRank: 3 - impression.sourceRank,
          actions: impression.actions,
        ),
    ], now: now);
    expect(worse.shownAtLeastAsGood, isFalse);
    // Unsettled shelves are not evidence yet.
    expect(
      compareRecommendationOrders(
        _shelves(10, shownRank: 0),
        now: _start,
      ).shownAtLeastAsGood,
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

  test('nothing is logged while learning is off', () async {
    final db = await _database();
    final outcomes = SuggestionOutcomes(open: () async => db);
    outcomes.recommendationShown(artist: 'Artist', title: 'Song', rank: 0);
    outcomes.followMix(LibraryMixKind.genre, ['/one'], queue: 1, since: _start);
    outcomes.recordPlay(_feedback('/one'), queue: 1);
    expect(await outcomes.readImpressions(), isEmpty);
    expect(await outcomes.readMixOutcomes(), isEmpty);
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
