import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/controllers/local_track_batch_actions.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/services/batch_metadata_re_enrich.dart';
import 'package:mornye/services/library_database.dart';
import 'package:mornye/theme/app_theme.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/widgets/app_bottom_sheet.dart';
import 'package:mornye/widgets/re_enrich_review_sheet.dart';
import 'package:mornye/widgets/selection_bottom_bar.dart';

import 'support/re_enrich_settings.dart';

void main() {
  testWidgets('review rows span their track card', (tester) async {
    tester.view.physicalSize = const Size(400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: AppTheme.light(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => showReEnrichReviewSheet(
                context,
                previews: [
                  BatchReEnrichPreview(
                    item: LocalLibraryItem(
                      id: 'song',
                      trackName: 'Song',
                      artistName: 'Artist',
                      albumName: 'Album',
                      filePath: '/music/song.flac',
                      scannedAt: DateTime(2026),
                    ),
                    updateFields: const ['date', 'isrc'],
                    enrichedMetadata: const {},
                    changes: const [
                      ReEnrichMetadataChange(
                        field: 'date',
                        oldValue: '2012',
                        newValue: '2012-07-16',
                      ),
                      ReEnrichMetadataChange(
                        field: 'isrc',
                        oldValue: '',
                        newValue: 'INY091200026',
                      ),
                    ],
                  ),
                ],
              ),
              child: const Text('Review'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Review'));
    await tester.pumpAndSettle();
    final card = tester.getRect(find.byType(ListTile));
    for (final value in ['2012-07-16', 'INY091200026']) {
      final row = tester.getRect(
        find
            .ancestor(
              of: find.textContaining(value, findRichText: true),
              matching: find.byType(Material),
            )
            .first,
      );
      expect(row.left, card.left, reason: value);
      expect(row.width, card.width, reason: value);
    }
  });

  for (final mornye in [false, true]) {
    testWidgets('result is readable above an open metadata sheet ($mornye)', (
      tester,
    ) async {
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            theme: mornye ? MornyeTheme.build(Brightness.dark) : ThemeData(),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () => showAppBottomSheet<void>(
                    context: context,
                    builder: (sheetContext) => SizedBox(
                      height: 400,
                      child: TextButton(
                        onPressed: () => showReEnrichResultDialog(
                          sheetContext,
                          message: 'Metadata lookup failed',
                        ),
                        child: const Text('Look up metadata'),
                      ),
                    ),
                  ),
                  child: const Text('Open metadata'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open metadata'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Look up metadata'));
      await tester.pumpAndSettle();
      expect(find.text('Metadata lookup failed').hitTestable(), findsOneWidget);
      expect(find.text('Look up metadata').hitTestable(), findsNothing);
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      expect(find.text('Look up metadata').hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    for (final fails in [false, true]) {
      testWidgets(
        'empty/failed preview stays visible before selection returns ($mornye/$fails)',
        (tester) async {
          const channel = MethodChannel('com.zarz.mornye/backend');
          tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            channel,
            (call) async {
              expect(call.method, 'reEnrichFile');
              if (fails) throw PlatformException(code: 'lookup_failed');
              return {
                'method': 'preview',
                'enriched_metadata': <String, dynamic>{},
              };
            },
          );
          addTearDown(
            () => tester.binding.defaultBinaryMessenger
                .setMockMethodCallHandler(channel, null),
          );
          final overlay = SelectionOverlayController();
          addTearDown(overlay.hide);
          var restored = 0;
          Future<void>? action;
          await tester.pumpWidget(
            ProviderScope(
              overrides: [
                settingsProvider.overrideWith(ReEnrichTestSettings.new),
              ],
              child: MaterialApp(
                theme: mornye
                    ? MornyeTheme.build(Brightness.dark)
                    : ThemeData(),
                localizationsDelegates: AppLocalizations.localizationsDelegates,
                supportedLocales: AppLocalizations.supportedLocales,
                home: Scaffold(
                  body: Consumer(
                    builder: (context, ref, _) => TextButton(
                      onPressed: () {
                        action = reEnrichLocalTracks(
                          context,
                          ref,
                          [
                            LocalLibraryItem(
                              id: 'song',
                              trackName: 'Song',
                              artistName: 'Artist',
                              albumName: 'Album',
                              filePath: '/music/song.flac',
                              scannedAt: DateTime(2026),
                            ),
                          ],
                          isActive: () => true,
                          onSelectionHide: () async => overlay.hide(),
                          onSelectionRestore: () {
                            restored++;
                            overlay.show(
                              context,
                              (_) => const SizedBox(
                                height: 350,
                                child: ColoredBox(
                                  color: Colors.blue,
                                  child: Center(child: Text('Selection card')),
                                ),
                              ),
                            );
                          },
                          onComplete: () => fail('No tags should be applied'),
                        );
                      },
                      child: const Text('Re-enrich song'),
                    ),
                  ),
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
          expect(
            find
                .text('No metadata changes were found for the selected tracks.')
                .hitTestable(),
            findsOneWidget,
          );
          expect(restored, 0);
          await tester.tap(find.text('OK'));
          await tester.pumpAndSettle();
          await action;
          expect(restored, 1);
          expect(find.text('Selection card').hitTestable(), findsOneWidget);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
}
