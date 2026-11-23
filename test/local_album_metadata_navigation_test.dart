import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/providers/download_history_provider.dart';
import 'package:mornye/providers/library_album_artwork_provider.dart';
import 'package:mornye/providers/playback_provider.dart';
import 'package:mornye/providers/player_motion_artwork_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/screens/downloaded_album_screen.dart';
import 'package:mornye/screens/local_album_screen.dart';
import 'package:mornye/screens/track_metadata_screen.dart';
import 'package:mornye/services/library_album_artwork.dart';
import 'package:mornye/services/library_database.dart';
import 'package:mornye/services/motion_artwork_store.dart';
import 'package:mornye/theme/app_theme.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/widgets/album_track_tile.dart';
import 'package:mornye/widgets/app_loading_indicator.dart';

import 'support/fixed_settings.dart';
import 'support/tooltip_finder.dart';

class _Playback extends PlaybackController {
  final played = <String>[];

  @override
  Future<void> playLocalLibraryQueue(
    List<LocalLibraryItem> items, {
    required LocalLibraryItem startItem,
  }) async {
    played.add(startItem.id);
  }
}

void main() {
  for (final mornye in [false, true]) {
    testWidgets('downloaded album order survives empty and reload ($mornye)', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      tester.view.physicalSize = const Size(430, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final loads = <Completer<List<DownloadHistoryItem>>>[];
      final provider = downloadedAlbumTracksProvider(
        const DownloadedAlbumTracksRequest(
          albumName: 'Album',
          artistName: 'Artist',
        ),
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            provider.overrideWith((ref) {
              final load = Completer<List<DownloadHistoryItem>>();
              loads.add(load);
              return load.future;
            }),
          ],
          child: MaterialApp(
            theme: mornye
                ? MornyeTheme.build(Brightness.light)
                : AppTheme.light(),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: const DownloadedAlbumScreen(
              albumName: 'Album',
              artistName: 'Artist',
            ),
          ),
        ),
      );
      expect(find.byType(AppLoadingIndicator), findsOneWidget);
      loads.single.complete([]);
      await tester.pumpAndSettle();
      expect(find.byType(AlbumTrackTile), findsNothing);
      final container = ProviderScope.containerOf(
        tester.element(find.byType(DownloadedAlbumScreen)),
      );
      container.invalidate(provider);
      await tester.pump();
      expect(find.byType(AppLoadingIndicator), findsOneWidget);
      loads.last.complete([
        for (final disc in [2, 1])
          DownloadHistoryItem(
            id: '$disc',
            trackName: 'Disc $disc',
            artistName: 'Artist',
            albumName: 'Album',
            filePath: '/missing/song-$disc.flac',
            service: 'example',
            downloadedAt: DateTime.utc(2026),
            discNumber: disc,
            trackNumber: 1,
          ),
      ]);
      await tester.pumpAndSettle();
      expect(
        tester
            .widgetList<AlbumTrackTile>(find.byType(AlbumTrackTile))
            .map((tile) => tile.trackName),
        ['Disc 1', 'Disc 2'],
      );
      container.invalidate(provider);
      await tester.pump();
      loads.last.complete([]);
      await tester.pumpAndSettle();
      expect(find.byType(AlbumTrackTile), findsNothing);
      expect(tester.takeException(), isNull);
    });

    for (final tapPlays in [false, true]) {
      testWidgets(
        'album row opens metadata on ${tapPlays ? 'its info button' : 'a tap'} '
        'and plays on ${tapPlays ? 'a tap' : 'Play'} ($mornye)',
        (tester) =>
            _albumRowTapTest(tester, mornye: mornye, tapPlays: tapPlays),
      );
    }

    testWidgets('artwork lookups that find nothing keep the album rows '
        '($mornye)', (tester) async {
      SharedPreferences.setMockInitialValues({});
      tester.view.physicalSize = const Size(430, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      const path = '/missing/song-1.flac';
      final found =
          Completer<({String albumKey, AlbumArtworkRecord? record})?>();
      final motion = Completer<MotionArtwork?>();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            libraryAlbumArtworkForSongProvider(
              path,
            ).overrideWith((ref) => found.future),
            songMotionArtworkProvider((
              album: 'Album',
              artist: 'Artist',
              source: path,
            )).overrideWith((ref) => motion.future),
          ],
          child: MaterialApp(
            theme: mornye
                ? MornyeTheme.build(Brightness.light)
                : AppTheme.light(),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: LocalAlbumScreen(
              albumName: 'Album',
              artistName: 'Artist',
              tracks: [
                LocalLibraryItem(
                  id: '1',
                  trackName: 'Song 1',
                  artistName: 'Artist',
                  albumName: 'Album',
                  filePath: path,
                  trackNumber: 1,
                  scannedAt: DateTime(2026),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final row = tester.widget(find.byType(AlbumTrackTile));

      found.complete((albumKey: 'album', record: null));
      motion.complete(null);
      await tester.pumpAndSettle();
      expect(tester.widget(find.byType(AlbumTrackTile)), same(row));
      expect(tester.takeException(), isNull);
    });
  }
}

Future<void> _albumRowTapTest(
  WidgetTester tester, {
  required bool mornye,
  required bool tapPlays,
}) async {
  SharedPreferences.setMockInitialValues({});
  tester.view.physicalSize = const Size(430, 1200);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final playback = _Playback();
  final navigator = GlobalKey<NavigatorState>();
  final tracks = [
    for (final number in [2, 1])
      LocalLibraryItem(
        id: '$number',
        trackName: 'Song $number',
        artistName: 'Artist',
        albumName: 'Album',
        filePath: '/missing/song-$number.flac',
        trackNumber: number,
        scannedAt: DateTime(2026),
      ),
  ];
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        playbackProvider.overrideWith(() => playback),
        settingsProvider.overrideWith(
          () => FixedSettingsNotifier(
            AppSettings(
              librarySongTap: tapPlays
                  ? AppSettings.librarySongTapPlay
                  : AppSettings.librarySongTapDetails,
            ),
          ),
        ),
      ],
      child: MaterialApp(
        navigatorKey: navigator,
        theme: mornye ? MornyeTheme.build(Brightness.light) : AppTheme.light(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: LocalAlbumScreen(
          albumName: 'Album',
          artistName: 'Artist',
          tracks: tracks,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  await tester.scrollUntilVisible(find.text('Song 2'), 150);
  final row = find.byWidgetPredicate(
    (widget) => widget is AlbumTrackTile && widget.trackName == 'Song 2',
  );
  final button = find.descendant(of: row, matching: find.byType(IconButton));
  expect(
    find.descendant(of: row, matching: findByTooltip('Show details')),
    tapPlays ? findsOneWidget : findsNothing,
  );
  await tester.tap(tapPlays ? button : find.text('Song 2'));
  // Details wait a moment for the picture inside the file.
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pumpAndSettle();
  final metadata = tester.widget<TrackMetadataScreen>(
    find.byType(TrackMetadataScreen),
  );
  expect(metadata.localItem!.id, '2');
  expect(metadata.localNavigationItems!.map((track) => track.id), ['1', '2']);
  expect(metadata.navigationIndex, 1);
  expect(playback.played, isEmpty);
  navigator.currentState!.pop();
  await tester.pumpAndSettle();
  await tester.tap(tapPlays ? find.text('Song 2') : button);
  await tester.pumpAndSettle();
  expect(playback.played, ['2']);
  expect(find.byType(TrackMetadataScreen), findsNothing);

  // Selection keeps the tap, whatever the setting.
  await tester.longPress(find.text('Song 2'));
  await tester.pumpAndSettle();
  expect(find.text('1 selected'), findsOneWidget);
  // The first row stays clear of the selection bar.
  await tester.tap(find.text('Song 1'));
  await tester.pumpAndSettle();
  expect(
    tester
        .widgetList<AlbumTrackTile>(find.byType(AlbumTrackTile))
        .map((tile) => tile.isSelected),
    [true, true],
  );
  expect(playback.played, ['2']);
  expect(find.byType(TrackMetadataScreen), findsNothing);
  expect(tester.takeException(), isNull);
}
