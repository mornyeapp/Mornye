import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/unified_library_item.dart';
import 'package:mornye/providers/library_search_provider.dart';
import 'package:mornye/providers/local_library_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/services/library_database.dart';
import 'package:mornye/services/library_search.dart';
import 'package:mornye/theme/app_theme.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/widgets/library_search_results.dart';
import 'package:mornye/widgets/selection_bottom_bar.dart';

import 'support/re_enrich_settings.dart';

class _Library extends LocalLibraryNotifier {
  @override
  LocalLibraryState build() => LocalLibraryState();

  @override
  Future<void> scanAllSources({
    bool forceFullScan = false,
    bool notify = true,
  }) async {}
}

void main() {
  for (final mornye in [false, true]) {
    for (final hosted in [false, true]) {
      testWidgets(
        'search can re-enrich another song without leaving search ($mornye/$hosted)',
        (tester) async {
          SharedPreferences.setMockInitialValues({});
          tester.view.physicalSize = const Size(800, 1600);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          const channel = MethodChannel('com.zarz.mornye/backend');
          final messenger = tester.binding.defaultBinaryMessenger;
          final requests = <Map<String, dynamic>>[];
          messenger.setMockMethodCallHandler(channel, (call) async {
            if (call.method != 'reEnrichFile') return null;
            final request = Map<String, dynamic>.from(
              jsonDecode((call.arguments as Map)['request_json'] as String)
                  as Map,
            );
            requests.add(request);
            return request['preview_only'] == true
                ? {
                    'method': 'preview',
                    'enriched_metadata': {'isrc': 'USABC2600001'},
                  }
                : {'method': 'native'};
          });
          addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
          const search = Scaffold(
            body: CustomScrollView(
              slivers: [
                LibrarySearchResults(query: 'Song', onOpenArtist: _openArtist),
              ],
            ),
          );
          await tester.pumpWidget(
            ProviderScope(
              overrides: [
                settingsProvider.overrideWith(ReEnrichTestSettings.new),
                localLibraryProvider.overrideWith(_Library.new),
                librarySearchProvider.overrideWith(
                  (ref, request) async =>
                      request.kind == LibrarySearchKind.songs
                      ? [
                          for (final id in ['a', 'b'])
                            LibrarySearchHit(
                              kind: LibrarySearchKind.songs,
                              id: id,
                              title: 'Song $id',
                              source: 'local',
                            ),
                        ]
                      : [],
                ),
                librarySearchTrackProvider.overrideWith(
                  (ref, key) async => UnifiedLibraryItem.fromLocalLibrary(
                    LocalLibraryItem(
                      id: key.id,
                      trackName: 'Song ${key.id}',
                      artistName: 'Artist',
                      albumName: 'Album',
                      filePath: '/music/${key.id}.flac',
                      scannedAt: DateTime(2026),
                    ),
                  ),
                ),
              ],
              child: MaterialApp(
                theme: mornye
                    ? MornyeTheme.build(Brightness.dark)
                    : AppTheme.light(),
                localizationsDelegates: AppLocalizations.localizationsDelegates,
                supportedLocales: AppLocalizations.supportedLocales,
                home: hosted
                    ? const SelectionOverlayHost(child: search)
                    : search,
              ),
            ),
          );
          await tester.pumpAndSettle();

          for (final id in ['a', 'b']) {
            await tester.longPress(find.text('Song $id'));
            await tester.pumpAndSettle();
            expect(find.text('Re-enrich (1)'), findsOneWidget);
            await tester.tap(find.text('Re-enrich (1)'));
            await tester.pumpAndSettle();
            expect(find.byType(SelectionBottomBar), findsNothing);
            await tester.tap(find.text('Fill missing tags'));
            await tester.ensureVisible(find.text('Review changes'));
            await tester.pumpAndSettle();
            await tester.tap(find.text('Review changes'));
            await tester.pumpAndSettle();
            await tester.ensureVisible(find.text('Apply changes'));
            await tester.pumpAndSettle();
            await tester.tap(find.text('Apply changes'));
            await tester.pumpAndSettle();
            await tester.tap(find.text('OK'));
            await tester.pumpAndSettle();
            expect(find.byType(SelectionBottomBar), findsNothing);
            expect(find.byType(LibrarySearchResults), findsOneWidget);
            expect(find.text('Song a'), findsOneWidget);
            expect(find.text('Song b'), findsOneWidget);
          }
          expect(requests.map((request) => request['file_path']), [
            '/music/a.flac',
            '/music/a.flac',
            '/music/b.flac',
            '/music/b.flac',
          ]);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
}

void _openArtist(String _) {}
