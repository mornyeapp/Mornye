import 'dart:convert';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/controllers/local_track_batch_actions.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/services/batch_metadata_re_enrich.dart';
import 'package:mornye/services/library_database.dart';
import 'package:mornye/services/metadata_cover_resources.dart';
import 'package:mornye/services/metadata_persistence_service.dart';
import 'package:mornye/services/re_enrich_undo.dart';
import 'package:mornye/services/re_enrich_undo_store.dart';
import 'package:mornye/theme/app_theme.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:mornye/widgets/app_switch.dart';
import 'package:mornye/widgets/re_enrich_review_sheet.dart';

import 'support/re_enrich_settings.dart';

LocalLibraryItem _song() => LocalLibraryItem(
  id: 'song',
  trackName: 'Song',
  artistName: 'Artist',
  albumName: 'Original Album',
  filePath: '/music/song.flac',
  coverPath: '/covers/song.jpg',
  scannedAt: DateTime(2026),
  releaseDate: '2012',
  hasLyrics: true,
);

BatchReEnrichPreview _preview() {
  const metadata = <String, dynamic>{
    'album_name': 'Greatest Hits Collection',
    'release_date': '2012-07-16',
    'cover_url': 'https://example.invalid/cover.jpg',
  };
  return BatchReEnrichPreview(
    item: _song(),
    updateFields: ReEnrichFields.all,
    enrichedMetadata: metadata,
    changes: buildReEnrichMetadataChanges(
      _song(),
      metadata,
      ReEnrichFields.all,
    ),
  );
}

MetadataCoverPreview _cover(String name, int size) => MetadataCoverPreview(
  path: '/missing/$name.jpg',
  tempDir: '/missing',
  details: (width: size, height: size, bytes: 1),
);

Widget _host({required bool mornye, required Widget Function() child}) =>
    ProviderScope(
      overrides: [settingsProvider.overrideWith(ReEnrichTestSettings.new)],
      child: MaterialApp(
        theme: mornye ? MornyeTheme.build(Brightness.light) : AppTheme.light(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: Builder(builder: (_) => child())),
      ),
    );

void main() {
  for (final mornye in [false, true]) {
    Future<Future<List<BatchReEnrichPreview>?> Function()> open(
      WidgetTester tester, {
      Size size = const Size(400, 900),
      ReEnrichCoverLoader? loadCovers,
    }) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      Future<List<BatchReEnrichPreview>?>? result;
      await tester.pumpWidget(
        _host(
          mornye: mornye,
          child: () => Builder(
            builder: (context) => TextButton(
              onPressed: () => result = showReEnrichReviewSheet(
                context,
                previews: [_preview()],
                chooseFields: true,
                loadCovers: loadCovers,
              ),
              child: const Text('Review'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Review'));
      await tester.pumpAndSettle();
      return () => result!;
    }

    List<bool> switches(WidgetTester tester) => [
      for (final widget in tester.widgetList<AppSwitch>(find.byType(AppSwitch)))
        widget.value,
    ];

    testWidgets('a smaller cover starts off and Apply keeps the rest '
        '($mornye)', (tester) async {
      final result = await open(
        tester,
        loadCovers: (_) async => ReEnrichReviewCovers(
          current: _cover('current', 3000),
          proposed: _cover('new', 640),
        ),
      );
      expect(find.text('Original Album'), findsOneWidget);
      expect(find.text('Greatest Hits Collection'), findsOneWidget);
      expect(find.text('Has lyrics'), findsOneWidget);
      expect(find.text('3000 × 3000 px'), findsOneWidget);
      expect(find.text('640 × 640 px'), findsOneWidget);
      expect(find.text('Smaller than the current cover'), findsOneWidget);
      // Album, date, cover, lyrics.
      expect(switches(tester), [true, true, false, true]);
      expect(find.text('3 of 4 changes selected'), findsOneWidget);

      await tester.tap(find.byType(AppSwitch).first);
      await tester.pumpAndSettle();
      expect(switches(tester), [false, true, false, true]);
      expect(find.text('2 of 4 changes selected'), findsOneWidget);

      await tester.ensureVisible(find.text('Apply changes'));
      await tester.tap(find.text('Apply changes'));
      await tester.pumpAndSettle();
      final applied = (await result())!.single;
      expect(
        [for (final change in applied.changes) change.field],
        ['release_date', 'lyrics'],
      );
      expect(applied.updateFields, ['release_date', ReEnrichFields.lyrics]);
      expect(applied.enrichedMetadata.containsKey('cover_url'), isFalse);
      expect(applied.enrichedMetadata.containsKey('album_name'), isFalse);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a larger cover starts on ($mornye)', (tester) async {
      await open(
        tester,
        loadCovers: (_) async => ReEnrichReviewCovers(
          current: _cover('current', 600),
          proposed: _cover('new', 1400),
        ),
      );
      expect(find.text('Smaller than the current cover'), findsNothing);
      expect(switches(tester), [true, true, true, true]);
    });

    testWidgets('Cancel returns nothing to write ($mornye)', (tester) async {
      final result = await open(tester);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(await result(), isNull);
    });

    testWidgets('a phone stacks the current value above the new one '
        '($mornye)', (tester) async {
      await open(tester);
      final current = tester.getRect(find.text('Original Album'));
      final proposed = tester.getRect(find.text('Greatest Hits Collection'));
      expect(proposed.top, greaterThan(current.bottom - 1));
      expect(tester.takeException(), isNull);
    });

    testWidgets('a desktop dialog shows them side by side ($mornye)', (
      tester,
    ) async {
      debugDesktopPlatformOverride = true;
      addTearDown(() => debugDesktopPlatformOverride = null);
      await open(tester, size: const Size(1400, 1000));
      final current = tester.getRect(find.text('Original Album'));
      final proposed = tester.getRect(find.text('Greatest Hits Collection'));
      expect(proposed.top, moreOrLessEquals(current.top, epsilon: 1));
      expect(proposed.left, greaterThan(current.right));
      final cancel = tester.getRect(find.text('Cancel'));
      final apply = tester.getRect(find.text('Apply changes'));
      expect(apply.left, greaterThan(cancel.right), reason: 'end aligned');
      expect(tester.takeException(), isNull);
    });

    testWidgets('one song: cancelling the review writes nothing ($mornye)', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      const channel = MethodChannel('com.zarz.mornye/backend');
      final requests = <Map<String, dynamic>>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        if (call.method != 'reEnrichFile') return null;
        final request =
            jsonDecode((call.arguments as Map)['request_json'] as String)
                as Map<String, dynamic>;
        requests.add(request);
        if (request['selected_candidate'] != null) {
          return {
            'method': 'preview',
            'enriched_metadata': {'album_name': 'Picked Album'},
          };
        }
        return {
          'method': 'preview',
          'enriched_metadata': <String, dynamic>{},
          'candidates': [
            {
              'provider_id': 'provider-a',
              'id': 'x',
              'name': 'Song x',
              'artists': 'Artist',
              'album_name': 'Picked Album',
              'match': 'weak',
            },
          ],
        };
      });
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        ),
      );
      var restored = 0;
      Future<void>? action;
      await tester.pumpWidget(
        _host(
          mornye: mornye,
          child: () => Consumer(
            builder: (context, ref, _) => TextButton(
              onPressed: () => action = reEnrichLocalTracks(
                context,
                ref,
                [_song()],
                isActive: () => true,
                onSelectionHide: () async {},
                onSelectionRestore: () => restored++,
                onComplete: () => fail('Nothing should be written'),
              ),
              child: const Text('Re-enrich song'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Re-enrich song'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Review changes'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Review changes'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Song x'));
      await tester.pumpAndSettle();

      expect(find.text('Picked Album'), findsOneWidget);
      expect(find.byType(AppSwitch), findsWidgets);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      await action;
      expect(restored, 1);
      expect(
        requests.where((request) => request['preview_only'] != true),
        isEmpty,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('a batch result undoes every song it changed ($mornye)', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      const channel = MethodChannel('com.zarz.mornye/backend');
      final writes = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        if (call.method != 'reEnrichFile') return null;
        final request =
            jsonDecode((call.arguments as Map)['request_json'] as String)
                as Map<String, dynamic>;
        if (request['preview_only'] == true) {
          return {
            'method': 'preview',
            'enriched_metadata': {'genre': 'Pop'},
          };
        }
        writes.add(request['file_path'] as String);
        return {'method': 'native', 'lyrics_status': 'not_requested'};
      });
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        ),
      );
      final store = _MemoryStore();
      final restores = <MetadataSaveRequest>[];
      final undo = ReEnrichUndo(
        store: store,
        readTags: (path) async => {'genre': 'Rock'},
        save: (request) async {
          restores.add(request);
          return const MetadataSaveResult.saved();
        },
      );
      final refreshed = <Set<String>>[];
      Future<void>? action;
      LocalLibraryItem song(String id) => LocalLibraryItem(
        id: id,
        trackName: 'Song $id',
        artistName: 'Artist',
        albumName: 'Album',
        filePath: '/music/$id.flac',
        scannedAt: DateTime(2026),
        genre: 'Rock',
      );
      await tester.pumpWidget(
        _host(
          mornye: mornye,
          child: () => Consumer(
            builder: (context, ref, _) => TextButton(
              onPressed: () => action = reEnrichLocalTracks(
                context,
                ref,
                [song('1'), song('2')],
                isActive: () => true,
                onSelectionHide: () async {},
                onSelectionRestore: () {},
                onComplete: () {},
                refreshLibrary: (ids) async => refreshed.add(ids),
                undo: undo,
              ),
              child: const Text('Re-enrich songs'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Re-enrich songs'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Review changes'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Review changes'));
      await tester.pumpAndSettle();
      expect(find.byType(AppSwitch), findsNothing, reason: 'a batch review');
      await tester.tap(find.text('Apply changes'));
      await tester.pumpAndSettle();
      expect(writes, ['/music/1.flac', '/music/2.flac']);
      expect(store.states.keys, ['/music/1.flac', '/music/2.flac']);

      await tester.tap(find.text('Undo all'));
      await tester.pumpAndSettle();
      expect(find.text('Restored 2 of 2 songs'), findsOneWidget);
      expect(
        [for (final r in restores) r.filePath],
        ['/music/1.flac', '/music/2.flac'],
      );
      expect(restores.first.metadata, {'genre': 'Rock'});
      expect(store.states, isEmpty);
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      await action;
      expect(refreshed.last, {'1', '2'});
      expect(tester.takeException(), isNull);
    });
  }
}

/// Keeps states in memory: app storage never answers under fake time.
class _MemoryStore extends ReEnrichUndoStore {
  final states = <String, ReEnrichUndoState>{};

  @override
  Future<ReEnrichUndoState?> read(String source) async => states[source];

  @override
  Future<String?> coverPath(ReEnrichUndoState state) async => null;

  @override
  Future<void> save(ReEnrichUndoState state, {String? coverFile}) async =>
      states[state.source] = state;

  @override
  Future<void> remove(String source) async => states.remove(source);
}
