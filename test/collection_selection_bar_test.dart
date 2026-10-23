import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/download_queue_provider.dart';
import 'package:mornye/providers/library_collections_provider.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/providers/recent_access_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/screens/album_screen.dart';
import 'package:mornye/screens/playlist_screen.dart';
import 'package:mornye/theme/app_theme.dart';
import 'package:mornye/widgets/selection_bottom_bar.dart';
import 'package:mornye/widgets/track_list_tile.dart';

import 'support/fixed_settings.dart';

final _tracks = [
  for (var i = 0; i < 4; i++)
    Track(
      id: 'example-track-$i',
      name: 'Example song $i',
      artistName: 'Example artist',
      albumName: 'Example album',
      duration: 180,
      trackNumber: i + 1,
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
}

void main() {
  for (final album in [true, false]) {
    final page = album ? 'album' : 'playlist';
    testWidgets('$page select all toggle selects every track, then exits', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(430, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
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
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: AppTheme.light(),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: album
                ? AlbumScreen(
                    albumId: 'example-album',
                    albumName: 'Example album',
                    tracks: _tracks,
                  )
                : PlaylistScreen(
                    playlistName: 'Example playlist',
                    tracks: _tracks,
                  ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.longPress(find.text('Example song 1'));
      await tester.pumpAndSettle();

      SelectionBottomBar bar() =>
          tester.widget<SelectionBottomBar>(find.byType(SelectionBottomBar));
      List<bool> selected() => [
        for (final tile in tester.widgetList<TrackListTile>(
          find.byType(TrackListTile),
        ))
          tile.isSelected,
      ];
      expect(bar().selectedCount, 1);
      expect(bar().allSelected, isFalse);
      bar().onToggleSelectAll();
      await tester.pumpAndSettle();
      expect(bar().selectedCount, 4);
      expect(bar().allSelected, isTrue);
      expect(selected(), [true, true, true, true]);
      bar().onToggleSelectAll();
      await tester.pumpAndSettle();
      expect(selected(), [false, false, false, false]);
      expect(
        tester
            .widgetList<TrackListTile>(find.byType(TrackListTile))
            .any((tile) => tile.isSelectionMode),
        isFalse,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }
}
