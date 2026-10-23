import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/unified_library_item.dart';
import 'package:mornye/providers/download_history_provider.dart';
import 'package:mornye/providers/local_library_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/screens/downloaded_album_screen.dart';
import 'package:mornye/services/downloaded_embedded_cover_resolver.dart';
import 'package:mornye/services/library_database.dart';
import 'package:mornye/services/local_track_batch_actions.dart';
import 'package:mornye/theme/app_theme.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/widgets/selection_bottom_bar.dart';

import 'support/re_enrich_settings.dart';

class _History extends DownloadHistoryNotifier {
  final _updates = <String, String?>{};

  @override
  DownloadHistoryState build() => DownloadHistoryState();

  @override
  Future<void> updateMetadataForItem({
    required String id,
    required String trackName,
    required String artistName,
    required String albumName,
    String? albumArtist,
    String? isrc,
    int? trackNumber,
    int? totalTracks,
    int? discNumber,
    int? totalDiscs,
    String? releaseDate,
    String? genre,
    String? composer,
    String? label,
    String? copyright,
    bool? explicit,
    bool? hasLyrics,
    int? lyricsMetadataScanVersion,
  }) async {
    _updates[id] = isrc;
  }
}

class _Library extends LocalLibraryNotifier {
  int _refreshes = 0;

  @override
  LocalLibraryState build() => LocalLibraryState();

  @override
  Future<void> scanAllSources({bool forceFullScan = false}) async {
    _refreshes++;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.zarz.mornye/backend');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  for (final includeLocal in [false, true]) {
    testWidgets(
      'Library re-enrich includes downloaded tracks and refreshes each source (mixed: $includeLocal)',
      (tester) async {
        SharedPreferences.setMockInitialValues({});
        final cache = Directory.systemTemp.createTempSync('library_reenrich_');
        DownloadedEmbeddedCoverResolver.setPersistentCacheDirectoryForTesting(
          cache,
        );
        addTearDown(() async {
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.runAsync(() async {
            await DownloadedEmbeddedCoverResolver.resetMemoryStateForTesting();
            DownloadedEmbeddedCoverResolver.setPersistentCacheDirectoryForTesting(
              null,
            );
            await cache.delete(recursive: true);
          });
        });
        final history = _History();
        final library = _Library();
        final requests = <Map<String, dynamic>>[];
        final paths = [
          'content://library/document/download.flac',
          if (includeLocal) '/music/local.flac',
        ];
        var completed = false;
        messenger.setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'reEnrichFile') {
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
          }
          if (call.method == 'readAudioMetadata') {
            return {
              'trackName': 'Downloaded',
              'artistName': 'Artist',
              'albumName': 'Album',
              'isrc': 'USABC2600001',
            };
          }
          return null;
        });
        addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              settingsProvider.overrideWith(ReEnrichTestSettings.new),
              downloadHistoryProvider.overrideWith(() => history),
              localLibraryProvider.overrideWith(() => library),
            ],
            child: MaterialApp(
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: Scaffold(
                body: Consumer(
                  builder: (context, ref, _) => TextButton(
                    onPressed: () => reEnrichLibraryTracks(
                      context,
                      ref,
                      [
                        UnifiedLibraryItem.fromDownloadHistory(
                          DownloadHistoryItem(
                            id: 'download',
                            spotifyId: 'provider-a:track-1',
                            trackName: 'Downloaded',
                            artistName: 'Artist',
                            albumName: 'Album',
                            filePath: paths.first,
                            service: 'example-provider',
                            downloadedAt: DateTime(2026),
                          ),
                        ),
                        if (includeLocal)
                          UnifiedLibraryItem.fromLocalLibrary(
                            LocalLibraryItem(
                              id: 'local',
                              trackName: 'Local',
                              artistName: 'Artist',
                              albumName: 'Album',
                              filePath: paths.last,
                              scannedAt: DateTime(2026),
                            ),
                          ),
                      ],
                      isActive: () => context.mounted,
                      onSelectionHide: () async {},
                      onSelectionRestore: () {},
                      onComplete: () => completed = true,
                    ),
                    child: const Text('Start'),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('Start'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Review changes'));
        await tester.pumpAndSettle();
        expect(requests.map((request) => request['file_path']), paths);
        expect(requests.first['spotify_id'], 'provider-a:track-1');
        await tester.tap(find.text('Apply changes'));
        for (var attempt = 0; attempt < 50 && !completed; attempt++) {
          await tester.pump(const Duration(milliseconds: 100));
          await tester.runAsync(() async {
            await Future<void>.delayed(const Duration(milliseconds: 10));
          });
        }
        await tester.pumpAndSettle();
        expect(requests.map((request) => request['file_path']), [
          ...paths,
          ...paths,
        ]);
        expect(requests[paths.length]['spotify_id'], 'provider-a:track-1');
        expect(history._updates, {'download': 'USABC2600001'});
        expect(library._refreshes, includeLocal ? 1 : 0);
        expect(completed, isTrue);
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final mornye in [false, true]) {
    testWidgets(
      'downloaded album re-enrich restores selection on cancel and updates only selected files ($mornye)',
      (tester) async {
        SharedPreferences.setMockInitialValues({});
        final cache = Directory.systemTemp.createTempSync('album_reenrich_');
        DownloadedEmbeddedCoverResolver.setPersistentCacheDirectoryForTesting(
          cache,
        );
        addTearDown(() async {
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.runAsync(() async {
            await DownloadedEmbeddedCoverResolver.resetMemoryStateForTesting();
            DownloadedEmbeddedCoverResolver.setPersistentCacheDirectoryForTesting(
              null,
            );
            await cache.delete(recursive: true);
          });
        });
        const path = 'content://library/document/track.flac';
        final requests = <Map<String, dynamic>>[];
        messenger.setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'reEnrichFile') {
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
          }
          if (call.method == 'readAudioMetadata') {
            return {
              'trackName': 'Track',
              'artistName': 'Artist',
              'albumName': 'Album',
              'isrc': 'USABC2600001',
              'hasLyrics': true,
            };
          }
          return null;
        });
        addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
        final history = _History();
        final navigator = GlobalKey<NavigatorState>();
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              settingsProvider.overrideWith(ReEnrichTestSettings.new),
              downloadHistoryProvider.overrideWith(() => history),
              downloadedAlbumTracksProvider(
                const DownloadedAlbumTracksRequest(
                  albumName: 'Album',
                  artistName: 'Artist',
                ),
              ).overrideWith(
                (ref) async => [
                  for (final id in ['track', 'other'])
                    DownloadHistoryItem(
                      id: id,
                      trackName: id == 'track' ? 'Track' : 'Other',
                      artistName: 'Artist',
                      albumName: 'Album',
                      filePath: id == 'track' ? path : '/music/other.flac',
                      service: 'example-provider',
                      downloadedAt: DateTime(2026),
                      duration: 180,
                    ),
                ],
              ),
            ],
            child: MaterialApp(
              navigatorKey: navigator,
              theme: mornye
                  ? MornyeTheme.build(Brightness.light)
                  : AppTheme.light(),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: const SelectionOverlayHost(
                child: DownloadedAlbumScreen(
                  albumName: 'Album',
                  artistName: 'Artist',
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.scrollUntilVisible(find.text('Track'), 200);
        await tester.longPress(find.text('Track'));
        await tester.pumpAndSettle();
        final l10n = AppLocalizations.of(
          tester.element(find.byType(SelectionBottomBar)),
        );

        Future<void> openReEnrich() async {
          await tester.tap(find.text('${l10n.trackReEnrich} (1)'));
          await tester.pumpAndSettle();
          expect(find.byType(SelectionBottomBar), findsNothing);
          expect(find.text('Review changes'), findsOneWidget);
        }

        await openReEnrich();
        navigator.currentState!.pop();
        await tester.pumpAndSettle();
        expect(find.byType(SelectionBottomBar), findsOneWidget);
        expect(requests, isEmpty);

        await openReEnrich();
        await tester.ensureVisible(find.text('Review changes'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Review changes'));
        await tester.pumpAndSettle();
        expect(requests, hasLength(1));
        expect(requests.single['file_path'], path);
        expect(requests.single['duration_ms'], 180000);
        await tester.ensureVisible(find.text('Apply changes'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Apply changes'));
        // The history refresh also invalidates the disk-backed cover cache.
        for (
          var attempt = 0;
          attempt < 50 && history._updates.isEmpty;
          attempt++
        ) {
          await tester.pump(const Duration(milliseconds: 100));
          await tester.runAsync(() async {
            await Future<void>.delayed(const Duration(milliseconds: 10));
          });
        }
        await tester.pumpAndSettle();
        expect(requests, hasLength(2));
        expect(requests.last['file_path'], path);
        expect(history._updates, {'track': 'USABC2600001'});
        expect(find.byType(SelectionBottomBar), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }
}
