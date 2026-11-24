import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/providers/download_history_provider.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/screens/downloaded_album_screen.dart';
import 'package:mornye/services/downloaded_embedded_cover_resolver.dart';
import 'package:mornye/theme/app_theme.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/widgets/album_track_tile.dart';
import 'package:mornye/widgets/now_playing_indicator.dart';
import 'package:mornye/widgets/song_row_tap.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/app_icon_finder.dart';
import 'support/re_enrich_settings.dart';
import 'support/tooltip_finder.dart';

class _History extends DownloadHistoryNotifier {
  @override
  DownloadHistoryState build() => DownloadHistoryState();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final mornye in [false, true]) {
    for (final tapPlays in [false, true]) {
      testWidgets(
        'downloaded album rows follow playback '
        '(mornye: $mornye, tapPlays: $tapPlays)',
        (tester) =>
            _rowsFollowPlayback(tester, mornye: mornye, tapPlays: tapPlays),
      );
    }
  }
}

Future<void> _rowsFollowPlayback(
  WidgetTester tester, {
  required bool mornye,
  required bool tapPlays,
}) async {
  SharedPreferences.setMockInitialValues({});
  tester.view.physicalSize = const Size(430, 1200);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final cache = Directory.systemTemp.createTempSync('album_now_playing_');
  DownloadedEmbeddedCoverResolver.setPersistentCacheDirectoryForTesting(cache);
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

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        settingsProvider.overrideWith(ReEnrichTestSettings.new),
        librarySongTapPlaysProvider.overrideWithValue(tapPlays),
        downloadHistoryProvider.overrideWith(_History.new),
        downloadedAlbumTracksProvider(
          const DownloadedAlbumTracksRequest(
            albumName: 'Album',
            artistName: 'Artist',
          ),
        ).overrideWith(
          (ref) async => [
            for (final (index, id) in ['first', 'second'].indexed)
              DownloadHistoryItem(
                id: id,
                trackName: id == 'first' ? 'First' : 'Second',
                artistName: 'Artist',
                albumName: 'Album',
                filePath: '/music/$id.flac',
                service: 'example-provider',
                downloadedAt: DateTime(2026),
                trackNumber: index + 1,
                duration: 180,
              ),
          ],
        ),
        currentMediaItemProvider.overrideWithBuild(
          (ref, notifier) =>
              Stream.value(const MediaItem(id: 'second', title: 'Second')),
        ),
        playbackPlayingProvider.overrideWith((ref) => true),
        playbackLoadingProvider.overrideWith((ref) => false),
      ],
      child: MaterialApp(
        theme: mornye ? MornyeTheme.build(Brightness.light) : AppTheme.light(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const DownloadedAlbumScreen(
          albumName: 'Album',
          artistName: 'Artist',
        ),
      ),
    ),
  );
  // The current row's glyph loops, so pump in bounded steps. Real file
  // IO from the cover lookups needs real time between the frames, or the
  // teardown waits for it forever.
  for (var i = 0; i < 20; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
    await tester.pump(const Duration(milliseconds: 50));
  }

  Finder row(String title) => find.byWidgetPredicate(
    (widget) => widget is AlbumTrackTile && widget.trackName == title,
  );
  expect(row('Second'), findsOneWidget);
  expect(tester.widget<AlbumTrackTile>(row('Second')).isCurrent, isTrue);
  expect(tester.widget<AlbumTrackTile>(row('First')).isCurrent, isFalse);
  expect(
    find.descendant(of: row('Second'), matching: findByTooltip('Pause')),
    tapPlays ? findsNothing : findsOneWidget,
  );
  expect(
    find.descendant(of: row('First'), matching: findByTooltip('Play')),
    tapPlays ? findsNothing : findsOneWidget,
  );
  // A tap plays, so each row's button opens the details instead.
  expect(
    findByTooltip('Show details'),
    tapPlays ? findsNWidgets(2) : findsNothing,
  );
  expect(
    find.descendant(
      of: row('Second'),
      matching: find.byType(NowPlayingIndicator),
    ),
    mornye ? findsNothing : findsOneWidget,
  );
  expect(
    find.descendant(
      of: row('Second'),
      matching: findAppIcon(mornye ? CupertinoIcons.pause_fill : Icons.pause),
    ),
    tapPlays ? findsNothing : findsOneWidget,
  );
}
