import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/controllers/local_track_batch_actions.dart';
import 'package:mornye/l10n/app_localizations.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/services/batch_metadata_re_enrich.dart';
import 'package:mornye/services/library_database.dart';
import 'package:mornye/widgets/app_action_button.dart';
import 'package:mornye/widgets/re_enrich_candidate_sheet.dart';
import 'package:mornye/widgets/re_enrich_review_sheet.dart';

LocalLibraryItem _song(String id, {String album = 'Album'}) => LocalLibraryItem(
  id: id,
  trackName: 'Song $id',
  artistName: 'Artist',
  albumName: album,
  filePath: '/music/$id.flac',
  scannedAt: DateTime(2026),
);

Map<String, dynamic> _candidate(
  String id,
  String match, {
  String album = 'Album',
  String provider = 'provider-a',
}) => {
  'provider_id': provider,
  'id': id,
  'name': 'Song $id',
  'artists': 'Artist',
  'album_name': album,
  'genre': 'Genre $id',
  'match': match,
  'match_score': 0,
};

Widget _host(void Function(BuildContext context) open) => ProviderScope(
  child: MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(
      body: Builder(
        builder: (context) => TextButton(
          onPressed: () => open(context),
          child: const Text('Open'),
        ),
      ),
    ),
  ),
);

void main() {
  const fields = ReEnrichFieldSelection(
    mode: ReEnrichBatchMode.selectedFields,
    fields: ['genre'],
  );

  test(
    'a song nothing fitted is kept for a pick, then updated from it',
    () async {
      final requests = <Map<String, dynamic>>[];
      final runner = BatchReEnrichRunner(
        beginPhase: () async => const AppSettings(),
        reEnrich: (request) async {
          requests.add(request);
          final picked = request['selected_candidate'] as Map?;
          if (picked != null) {
            return {
              'method': 'preview',
              'auto_match': picked['match'],
              'enriched_metadata': {'genre': picked['genre']},
            };
          }
          return switch (request['file_path']) {
            '/music/1.flac' => {
              'method': 'preview',
              'auto_match': 'none',
              'enriched_metadata': {'genre': ''},
              'candidates': [
                _candidate('x', 'weak', album: 'Other Album'),
                _candidate('y', 'other'),
              ],
            },
            '/music/2.flac' => {
              'method': 'preview',
              'auto_match': 'strong',
              'enriched_metadata': {'genre': 'Rock'},
              'candidates': [_candidate('z', 'strong')],
            },
            _ => {
              'method': 'preview',
              'auto_match': 'none',
              'enriched_metadata': {'genre': ''},
            },
          };
        },
      );

      final previews = await runner.preview(
        [_song('1'), _song('2'), _song('3')],
        fields,
        shouldStop: () => false,
        onProgress: (_, _) {},
      );

      expect(
        requests.every((request) => request['include_candidates'] == true),
        isTrue,
      );
      expect(previews.map((preview) => preview.item.id), ['1', '2']);
      expect(previews[0].needsChoice, isTrue);
      expect(previews[0].changes, isEmpty);
      expect(previews[1].needsChoice, isFalse);
      expect(previews[1].match, ReEnrichMatch.strong);

      final picked = await runner.choose(
        previews[0],
        previews[0].candidates[0],
      );
      final request = requests.last;
      expect(request['preview_only'], isTrue);
      expect(request['search_online'], isTrue);
      expect(request.containsKey('include_candidates'), isFalse);
      expect((request['selected_candidate'] as Map)['id'], 'x');
      expect(picked?.chosen?['id'], 'x');
      expect(picked?.match, ReEnrichMatch.weak);
      expect(picked?.needsChoice, isFalse);
      expect(picked?.changes.single.newValue, 'Genre x');
      expect(picked?.candidates, hasLength(2));
    },
  );

  testWidgets('results that fit come first and the rest stay folded', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    Future<Map<String, dynamic>?>? picked;
    await tester.pumpWidget(
      _host(
        (context) => picked = showReEnrichCandidateSheet(
          context,
          candidates: [
            _candidate('1', 'exact'),
            _candidate('2', 'weak', provider: 'catalog'),
            _candidate('3', 'other'),
            _candidate('4', 'other'),
          ],
          title: 'Re-enrich',
          providerName: (id) => id == 'provider-a' ? 'Provider A' : id,
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();

    expect(find.text('Best matches'), findsOneWidget);
    expect(find.text('Song 1'), findsOneWidget);
    expect(find.textContaining('Provider A · Same ISRC'), findsOneWidget);
    expect(find.textContaining('catalog · Same title and artist'), findsOne);
    expect(find.text('Song 3'), findsNothing);

    await tester.tap(find.text('Show 2 more results'));
    await tester.pumpAndSettle();
    expect(find.text('Song 3'), findsOneWidget);
    expect(find.text('Song 4'), findsOneWidget);

    await tester.tap(find.text('Song 4'));
    await tester.pumpAndSettle();
    expect((await picked)?['id'], '4');
  });

  testWidgets('with nothing close, the other results show at once', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        (context) => showReEnrichCandidateSheet(
          context,
          candidates: [_candidate('1', 'other')],
          title: 'Re-enrich',
          providerName: (id) => id,
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(find.text('No close match'), findsOneWidget);
    expect(find.text('Song 1'), findsOneWidget);
  });

  testWidgets('the review picks a result for a song nothing fitted', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final unmatched = BatchReEnrichPreview(
      item: _song('1'),
      updateFields: const ['genre'],
      enrichedMetadata: const {},
      changes: const [],
      match: ReEnrichMatch.none,
      candidates: [_candidate('x', 'weak'), _candidate('y', 'other')],
    );
    final chosen = <String>[];
    Future<List<BatchReEnrichPreview>?>? result;
    await tester.pumpWidget(
      _host(
        (context) => result = showReEnrichReviewSheet(
          context,
          previews: [unmatched],
          providerName: (id) => 'Provider A',
          onChoose: (preview, candidate) async {
            chosen.add(candidate['id'] as String);
            return preview.withChoice(candidate, {'genre': candidate['genre']});
          },
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();

    expect(find.text('Choose a result'), findsOneWidget);
    expect(
      tester.widget<AppActionButton>(find.byType(AppActionButton)).onPressed,
      isNull,
      reason: 'Nothing would change before a result is picked',
    );

    await tester.tap(find.text('Choose a result'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Song x'));
    await tester.pumpAndSettle();

    expect(chosen, ['x']);
    expect(find.text('Change result'), findsOneWidget);
    expect(find.textContaining('Genre x', findRichText: true), findsOneWidget);
    await tester.tap(find.text('Apply changes'));
    await tester.pumpAndSettle();
    final applied = await result;
    expect(applied?.single.chosen?['id'], 'x');
    expect(applied?.single.changes.single.newValue, 'Genre x');
  });

  test('candidate requests ask for results only in previews', () {
    final item = _song('1');
    final preview = buildBatchReEnrichRequest(
      item: item,
      settings: const AppSettings(),
      updateFields: const ['genre'],
      previewOnly: true,
      includeCandidates: true,
    );
    expect(preview['include_candidates'], isTrue);
    expect(preview['quick_candidates'], isTrue);
    expect(preview.containsKey('selected_candidate'), isFalse);

    final write = buildBatchReEnrichRequest(
      item: item,
      settings: const AppSettings(),
      updateFields: const [ReEnrichFields.lyrics],
      includeCandidates: true,
      selectedCandidate: _candidate('x', 'weak'),
    );
    expect(write.containsKey('include_candidates'), isFalse);
    expect(write['search_online'], isTrue);
    expect((write['selected_candidate'] as Map)['id'], 'x');
  });
}
