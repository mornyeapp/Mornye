import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mornye/l10n/app_localizations.dart';
import 'package:mornye/models/unified_library_item.dart';
import 'package:mornye/providers/download_history_provider.dart';
import 'package:mornye/providers/library_search_provider.dart';
import 'package:mornye/providers/library_lyrics_search_provider.dart';
import 'package:mornye/providers/playback_provider.dart';
import 'package:mornye/screens/track_metadata_screen.dart';
import 'package:mornye/services/library_database.dart';
import 'package:mornye/services/library_search.dart';
import 'package:mornye/services/library_lyrics_search.dart';
import 'package:mornye/services/music_player_service.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:mornye/widgets/app_choice_chip.dart';
import 'package:mornye/widgets/library_search_results.dart';
import 'package:mornye/widgets/track_card.dart';

import 'support/app_icon_finder.dart';

class _PlaybackRecorder extends PlaybackController {
  final paths = <String>[];

  @override
  Future<void> playMediaQueue(
    Iterable<PlayableMedia> queue, {
    required int startIndex,
    required String externalPath,
  }) async {
    paths.add(externalPath);
  }
}

LibrarySearchHit _hit(
  LibrarySearchKind kind,
  int index, {
  String query = 'Found',
}) => LibrarySearchHit(
  kind: kind,
  id: '$index',
  title: '$query ${kind.name} $index',
);

void main() {
  for (final desktop in [false, true]) {
    for (final mornye in [false, true]) {
      testWidgets(
        'Lyrics filter is explicit, reuses indexing while typing, and cancels on exit ($desktop/$mornye)',
        (tester) async {
          debugDesktopPlatformOverride = desktop;
          addTearDown(() => debugDesktopPlatformOverride = null);
          tester.view.physicalSize = Size(desktop ? 1280 : 390, 900);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          SharedPreferences.setMockInitialValues({});
          final query = ValueNotifier('moonlight');
          addTearDown(query.dispose);
          var started = 0;
          var stopped = 0;
          final progress = StreamController<LibraryLyricsIndexProgress>();
          addTearDown(progress.close);
          final queries = <String>[];
          await tester.pumpWidget(
            ProviderScope(
              overrides: [
                librarySearchProvider.overrideWith((ref, request) async => []),
                libraryLyricsIndexProvider.overrideWith((ref) {
                  started++;
                  ref.onDispose(() => stopped++);
                  return progress.stream;
                }),
                libraryLyricsSearchProvider.overrideWith((ref, request) async {
                  queries.add(request.query);
                  return [_hit(LibrarySearchKind.songs, 0, query: 'Matching')];
                }),
              ],
              child: MaterialApp(
                theme: mornye
                    ? MornyeTheme.build(Brightness.light)
                    : ThemeData(),
                localizationsDelegates: AppLocalizations.localizationsDelegates,
                supportedLocales: AppLocalizations.supportedLocales,
                home: Scaffold(
                  body: ValueListenableBuilder<String>(
                    valueListenable: query,
                    builder: (context, value, _) => CustomScrollView(
                      slivers: [
                        LibrarySearchResults(
                          query: value,
                          shelves: mornye,
                          onOpenArtist: (_) {},
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(started, 0);
          expect(queries, isEmpty);
          final lyrics = find.widgetWithText(AppChoiceChip, 'Lyrics');
          await tester.ensureVisible(lyrics);
          await tester.pumpAndSettle();
          await tester.tap(lyrics);
          await tester.pump();
          await tester.pump();
          progress.add(const LibraryLyricsIndexProgress(checked: 8));
          await tester.pump();
          await tester.pump();
          expect(started, 1);
          expect(find.textContaining('8 songs checked'), findsOneWidget);
          expect(find.text('Matching songs 0'), findsOneWidget);
          query.value = 'dancing';
          await tester.pump();
          await tester.pump();
          expect(queries, ['moonlight', 'dancing']);
          expect(started, 1);
          final all = find.widgetWithText(AppChoiceChip, 'All');
          await tester.ensureVisible(all);
          await tester.pump(const Duration(milliseconds: 300));
          await tester.tap(all);
          await tester.pumpAndSettle();
          expect(stopped, 1);
          expect(find.textContaining('songs checked'), findsNothing);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  for (final mornye in [false, true]) {
    for (final local in [false, true]) {
      testWidgets(
        'search opens metadata; only Play starts audio ($mornye/$local)',
        (tester) async {
          SharedPreferences.setMockInitialValues({});
          FlutterSecureStorage.setMockInitialValues({});
          const channel = MethodChannel('com.zarz.mornye/backend');
          tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            channel,
            (call) async => switch (call.method) {
              'safStat' => jsonEncode({'exists': true, 'size': 100}),
              'readAudioMetadata' || 'readFileMetadata' => '{}',
              'getLyricsLRCWithSource' => jsonEncode({
                'lyrics': '',
                'source': '',
              }),
              'getSafFileModTimes' => '{}',
              _ => null,
            },
          );
          addTearDown(
            () => tester.binding.defaultBinaryMessenger
                .setMockMethodCallHandler(channel, null),
          );
          const path = 'content://library/document/song.flac';
          final item = local
              ? UnifiedLibraryItem.fromLocalLibrary(
                  LocalLibraryItem(
                    id: 'chosen',
                    trackName: 'Song',
                    artistName: 'Artist',
                    albumName: 'Album',
                    filePath: path,
                    scannedAt: DateTime(2026),
                  ),
                )
              : UnifiedLibraryItem.fromDownloadHistory(
                  DownloadHistoryItem(
                    id: 'chosen',
                    trackName: 'Song',
                    artistName: 'Artist',
                    albumName: 'Album',
                    filePath: path,
                    service: 'provider-a',
                    downloadedAt: DateTime(2026),
                  ),
                );
          final player = _PlaybackRecorder();
          await tester.pumpWidget(
            ProviderScope(
              overrides: [
                playbackProvider.overrideWith(() => player),
                librarySearchProvider.overrideWith(
                  (ref, request) async =>
                      request.kind == LibrarySearchKind.songs
                      ? [
                          LibrarySearchHit(
                            kind: LibrarySearchKind.songs,
                            id: 'chosen',
                            title: 'Song',
                            source: local ? 'local' : 'history',
                          ),
                        ]
                      : [],
                ),
                librarySearchTrackProvider.overrideWith((ref, key) async {
                  expect(key, (
                    source: local ? 'local' : 'history',
                    id: 'chosen',
                  ));
                  return item;
                }),
              ],
              child: MaterialApp(
                theme: mornye
                    ? MornyeTheme.build(Brightness.dark)
                    : ThemeData(),
                localizationsDelegates: AppLocalizations.localizationsDelegates,
                supportedLocales: AppLocalizations.supportedLocales,
                home: Scaffold(
                  body: CustomScrollView(
                    slivers: [
                      LibrarySearchResults(query: 'Song', onOpenArtist: (_) {}),
                    ],
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(
            tester.widget<TrackCard>(find.byType(TrackCard)).style,
            mornye ? TrackCardStyle.flat : TrackCardStyle.filled,
          );
          await tester.tap(find.text('Song'));
          await tester.pumpAndSettle();
          final details = tester.widget<TrackMetadataScreen>(
            find.byType(TrackMetadataScreen),
          );
          expect(details.item, item.historyItem);
          expect(details.localItem, item.localItem);
          expect(player.paths, isEmpty);
          tester.state<NavigatorState>(find.byType(Navigator).first).pop();
          await tester.pumpAndSettle();
          await tester.tap(find.byTooltip('Play'));
          await tester.pumpAndSettle();
          expect(player.paths, [path]);
          expect(find.byType(TrackMetadataScreen), findsNothing);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  for (final mornye in [false, true]) {
    testWidgets('Library shows every result type and paginates ($mornye)', (
      tester,
    ) async {
      final requests = <LibrarySearchRequest>[];
      final artists = <String>[];
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            librarySearchProvider.overrideWith((ref, request) async {
              requests.add(request);
              return List.generate(
                request.limit,
                (i) => _hit(request.kind, request.offset + i),
              );
            }),
          ],
          child: MaterialApp(
            theme: mornye ? MornyeTheme.build(Brightness.dark) : ThemeData(),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: CustomScrollView(
                slivers: [
                  LibrarySearchResults(
                    query: 'Found',
                    onOpenArtist: artists.add,
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        requests.map((r) => r.kind).toSet(),
        LibrarySearchKind.values.toSet(),
      );
      expect(requests.every((r) => r.limit == 6 && r.offset == 0), isTrue);
      await tester.tap(find.text('Artists').first);
      await tester.pumpAndSettle();
      expect(requests.last.limit, 41);
      await tester.tap(find.text('Found artists 0'));
      expect(artists, ['Found artists 0']);
      await tester.scrollUntilVisible(
        findAppIcon(Icons.expand_more),
        600,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(findAppIcon(Icons.expand_more));
      await tester.pumpAndSettle();
      expect(requests.last.offset, 40);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('an older query cannot replace newer results', (tester) async {
    final old = Completer<List<LibrarySearchHit>>();
    late StateSetter update;
    var query = 'old';
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          librarySearchProvider.overrideWith((ref, request) {
            if (request.kind != LibrarySearchKind.songs) {
              return Future.value([]);
            }
            return request.query == 'old'
                ? old.future
                : Future.value([_hit(request.kind, 0, query: request.query)]);
          }),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: StatefulBuilder(
            builder: (context, setState) {
              update = setState;
              return Scaffold(
                body: CustomScrollView(
                  slivers: [
                    LibrarySearchResults(query: query, onOpenArtist: (_) {}),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
    await tester.pump();
    update(() => query = 'new');
    await tester.pumpAndSettle();
    old.complete([_hit(LibrarySearchKind.songs, 0, query: 'old')]);
    await tester.pumpAndSettle();
    expect(find.text('new songs 0'), findsOneWidget);
    expect(find.text('old songs 0'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  for (final mornye in [false, true]) {
    testWidgets(
      'long-press selects songs for Library batch actions ($mornye)',
      (tester) async {
        SharedPreferences.setMockInitialValues({});
        FlutterSecureStorage.setMockInitialValues({});
        // Tall enough that the selection bar never covers a result row.
        tester.view.physicalSize = const Size(800, 1600);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        UnifiedLibraryItem local(String id) =>
            UnifiedLibraryItem.fromLocalLibrary(
              LocalLibraryItem(
                id: id,
                trackName: 'Song $id',
                artistName: 'Artist',
                albumName: 'Album',
                filePath: '/music/$id.mp3',
                scannedAt: DateTime(2026),
              ),
            );
        final query = ValueNotifier('Song');
        addTearDown(query.dispose);
        final player = _PlaybackRecorder();
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              playbackProvider.overrideWith(() => player),
              librarySearchProvider.overrideWith(
                (ref, request) async => switch (request.kind) {
                  LibrarySearchKind.songs => [
                    for (final id in ['a', 'b'])
                      LibrarySearchHit(
                        kind: LibrarySearchKind.songs,
                        id: id,
                        title: 'Song $id',
                        source: 'local',
                      ),
                  ],
                  LibrarySearchKind.albums => [
                    _hit(LibrarySearchKind.albums, 0, query: 'Song'),
                  ],
                  _ => [],
                },
              ),
              librarySearchTrackProvider.overrideWith(
                (ref, key) async => local(key.id),
              ),
            ],
            child: MaterialApp(
              theme: mornye ? MornyeTheme.build(Brightness.dark) : ThemeData(),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: Scaffold(
                body: ValueListenableBuilder(
                  valueListenable: query,
                  builder: (context, value, _) => CustomScrollView(
                    slivers: [
                      LibrarySearchResults(query: value, onOpenArtist: (_) {}),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byTooltip('Play'), findsNWidgets(2));

        await tester.longPress(find.text('Song a'));
        await tester.pumpAndSettle();
        expect(find.text('1 selected'), findsOneWidget);
        expect(find.text('Re-enrich (1)'), findsOneWidget);
        expect(find.text('Convert 1 track'), findsOneWidget);
        expect(find.text('Delete 1 track'), findsOneWidget);
        // Selecting hides row actions and keeps taps on the selection.
        expect(find.byTooltip('Play'), findsNothing);
        await tester.tap(find.text('Song b'));
        await tester.pumpAndSettle();
        expect(find.text('2 selected'), findsOneWidget);
        expect(find.text('All tracks selected'), findsOneWidget);
        await tester.tap(find.text('Song albums 0'));
        await tester.pumpAndSettle();
        expect(find.byType(LibrarySearchResults), findsOneWidget);
        expect(find.text('2 selected'), findsOneWidget);
        expect(player.paths, isEmpty);

        await tester.tap(find.text('Song b'));
        await tester.pumpAndSettle();
        expect(find.text('1 selected'), findsOneWidget);
        // Back leaves selection mode instead of the screen.
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        expect(find.textContaining('selected'), findsNothing);
        expect(find.byTooltip('Play'), findsNWidgets(2));

        await tester.longPress(find.text('Song a'));
        await tester.pumpAndSettle();
        expect(find.text('1 selected'), findsOneWidget);
        query.value = 'Song ';
        await tester.pumpAndSettle();
        expect(find.textContaining('selected'), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final mornye in [false, true]) {
    testWidgets('wide Library search offers covers, songs included ($mornye)', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      FlutterSecureStorage.setMockInitialValues({});
      tester.view.physicalSize = const Size(1280, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final requests = <LibrarySearchRequest>[];
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            librarySearchProvider.overrideWith((ref, request) async {
              requests.add(request);
              return List.generate(request.limit, (i) {
                final hit = _hit(request.kind, request.offset + i);
                return request.kind == LibrarySearchKind.songs
                    ? LibrarySearchHit(
                        kind: hit.kind,
                        id: hit.id,
                        title: hit.title,
                        source: 'local',
                      )
                    : hit;
              });
            }),
            librarySearchTrackProvider.overrideWith(
              (ref, key) async => UnifiedLibraryItem.fromLocalLibrary(
                LocalLibraryItem(
                  id: key.id,
                  trackName: 'Song ${key.id}',
                  artistName: 'Artist',
                  albumName: 'Album',
                  filePath: '/music/${key.id}.mp3',
                  scannedAt: DateTime(2026),
                ),
              ),
            ),
          ],
          child: MaterialApp(
            theme: mornye ? MornyeTheme.build(Brightness.dark) : ThemeData(),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: CustomScrollView(
                slivers: [
                  LibrarySearchResults(query: 'Found', onOpenArtist: (_) {}),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      // Rows until the shared view setting picks covers.
      expect(find.byType(TrackCard), findsWidgets);
      expect(find.byTooltip('Grid'), findsOneWidget);

      await tester.tap(find.byTooltip('Grid'));
      await tester.pumpAndSettle();
      expect(find.byType(TrackCard), findsNothing);
      expect(find.byTooltip('List'), findsOneWidget);
      // The overview: one shelf per kind, songs as covers the albums' size.
      expect(find.byType(SliverGrid), findsNothing);
      final song = find.byKey(const ValueKey('songs:local:0'));
      expect(song, findsOneWidget);
      expect(
        tester.getSize(song).width,
        tester.getSize(find.byKey(const ValueKey('albums::0'))).width,
      );

      // One kind fills a grid of covers and still pages.
      await tester.tap(find.text('Songs').first);
      await tester.pumpAndSettle();
      expect(requests.last.kind, LibrarySearchKind.songs);
      expect(requests.last.limit, 41);
      expect(find.byType(SliverGrid), findsOneWidget);
      expect(find.byType(TrackCard), findsNothing);

      // A long press selects, as on the rows.
      await tester.longPress(find.text('Found songs 0'));
      await tester.pumpAndSettle();
      expect(find.text('1 selected'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('songs:local:0')),
          matching: find.byIcon(Icons.check),
        ),
        findsOneWidget,
      );
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.textContaining('selected'), findsNothing);

      // A narrow pane keeps the rows and offers no switch.
      tester.view.physicalSize = const Size(700, 1600);
      await tester.pumpAndSettle();
      expect(find.byType(SliverGrid), findsNothing);
      expect(find.byType(TrackCard), findsWidgets);
      expect(find.byTooltip('List'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }
}
