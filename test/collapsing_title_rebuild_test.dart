import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/download_queue_provider.dart';
import 'package:mornye/providers/library_collections_provider.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/providers/recent_access_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/providers/track_provider.dart';
import 'package:mornye/screens/album_screen.dart';
import 'package:mornye/screens/artist_screen.dart';
import 'package:mornye/screens/playlist_screen.dart';
import 'package:mornye/theme/app_theme.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fixed_settings.dart';

final _tracks = [
  for (var i = 0; i < 30; i++)
    Track(
      id: 'example-track-$i',
      name: 'Example song $i',
      artistName: 'Example artist',
      albumName: 'Example album',
      duration: 180,
      trackNumber: i + 1,
    ),
];

final _albums = [
  for (var i = 0; i < 12; i++)
    ArtistAlbum(
      id: 'album-$i',
      name: 'Album $i',
      releaseDate: '2020',
      totalTracks: 1,
      albumType: i.isEven ? 'album' : 'single',
      artists: 'Example artist',
    ),
];

class _Collections extends LibraryCollectionsNotifier {
  @override
  LibraryCollectionsState build() => LibraryCollectionsState(isLoaded: true);
}

class _Recent extends RecentAccessNotifier {
  @override
  RecentAccessState build() => const RecentAccessState(isLoaded: true);

  @override
  void recordAlbumAccess({
    required String id,
    required String name,
    String? artistName,
    String? imageUrl,
    String? providerId,
  }) {}

  @override
  void recordArtistAccess({
    required String id,
    required String name,
    String? imageUrl,
    String? providerId,
  }) {}
}

/// Opacity of every faded title in the pinned toolbars.
List<double> _titleOpacities(WidgetTester tester) => [
  for (final fade in tester.widgetList<FadeTransition>(
    find.descendant(
      of: find.byType(NavigationToolbar),
      matching: find.byType(FadeTransition),
    ),
  ))
    fade.opacity.value,
];

void main() {
  for (final page in ['album', 'playlist', 'artist']) {
    for (final mornye in [false, true]) {
      testWidgets('$page title flip leaves the page unbuilt in '
          'Mornye=$mornye', (tester) async {
        tester.view.physicalSize = const Size(430, 1000);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        SharedPreferences.setMockInitialValues({});
        const channel = MethodChannel('com.zarz.mornye/backend');
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        messenger.setMockMethodCallHandler(channel, (_) async => null);
        addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
        final container = ProviderContainer(
          overrides: [
            settingsProvider.overrideWith(FixedSettingsNotifier.new),
            libraryCollectionsProvider.overrideWith(_Collections.new),
            recentAccessProvider.overrideWith(_Recent.new),
            currentMediaItemProvider.overrideWithBuild(
              (ref, notifier) => Stream.value(null),
            ),
            downloadQueueLookupProvider.overrideWithValue(
              const DownloadQueueLookup.empty(),
            ),
            downloadHistoryVisibleBatchExistsProvider.overrideWith(
              (ref, request) => const <String>{},
            ),
          ],
        );
        addTearDown(container.dispose);
        final Widget screen = switch (page) {
          'album' => AlbumScreen(
            albumId: 'example-album',
            albumName: 'Example album',
            tracks: _tracks,
          ),
          'playlist' => PlaylistScreen(
            playlistName: 'Example playlist',
            tracks: _tracks,
          ),
          _ => ArtistScreen(
            artistId: 'example-artist',
            artistName: 'Example artist',
            albums: _albums,
            topTracks: _tracks.take(10).toList(),
          ),
        };
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              theme: mornye
                  ? MornyeTheme.build(Brightness.light)
                  : AppTheme.light(),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: screen,
            ),
          ),
        );
        await tester.pumpAndSettle();

        var pageBuilds = 0;
        final previous = debugOnRebuildDirtyWidget;
        debugOnRebuildDirtyWidget = (element, builtOnce) {
          previous?.call(element, builtOnce);
          if (element.widget.runtimeType == screen.runtimeType) pageBuilds++;
        };
        addTearDown(() => debugOnRebuildDirtyWidget = previous);

        final position = tester
            .state<ScrollableState>(find.byType(Scrollable).first)
            .position;
        final hidden = _titleOpacities(tester);
        final frames = <List<double>>[];
        Future<void> scrollTo(double offset) async {
          position.jumpTo(offset);
          await tester.pump();
          for (var frame = 0; frame < 20; frame++) {
            frames.add(_titleOpacities(tester));
            await tester.pump(const Duration(milliseconds: 16));
          }
        }

        await scrollTo(700);
        final shown = _titleOpacities(tester);
        await scrollTo(0);

        expect(pageBuilds, 0);
        expect(shown, isNot(equals(hidden)));
        expect(_titleOpacities(tester), hidden);
        // The title fades through intermediate frames both ways.
        expect(
          frames.where(
            (opacities) =>
                opacities.any((opacity) => opacity > 0 && opacity < 1),
          ),
          isNotEmpty,
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      });
    }
  }
}
