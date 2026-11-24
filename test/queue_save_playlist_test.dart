import 'package:audio_service/audio_service.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/library_collections_provider.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/theme/app_theme.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/widgets/app_action_button.dart';
import 'package:mornye/widgets/expressive_button.dart';
import 'package:mornye/widgets/mornye_player_queue.dart';
import 'package:mornye/widgets/player_queue_sheet.dart';

import 'support/tooltip_finder.dart';

class _Settings extends SettingsNotifier {
  @override
  AppSettings build() => const AppSettings();
}

class _Collections extends LibraryCollectionsNotifier {
  final added = <(String, List<String>)>[];

  @override
  LibraryCollectionsState build() => LibraryCollectionsState(isLoaded: true);

  @override
  Future<PlaylistAddBatchResult> addTracksToPlaylist(
    String playlistId,
    Iterable<Track> tracks, {
    bool preserveOccurrences = false,
  }) async {
    added.add((playlistId, [for (final track in tracks) track.name]));
    return PlaylistAddBatchResult(
      addedCount: tracks.length,
      alreadyInPlaylistCount: 0,
    );
  }
}

const _playlist = PlaylistPickerSummary(
  id: 'evening',
  name: 'Evening',
  trackCount: 4,
  containsAllRequestedTracks: false,
);

Future<_Collections> _pump(
  WidgetTester tester, {
  required bool mornye,
  required List<MediaItem> queue,
}) async {
  final collections = _Collections();
  final theme = mornye ? MornyeTheme.build(Brightness.dark) : AppTheme.light();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        settingsProvider.overrideWith(_Settings.new),
        libraryCollectionsProvider.overrideWith(() => collections),
        libraryPlaylistPickerSummariesProvider.overrideWith(
          (ref, request) async => [_playlist],
        ),
        currentMediaItemProvider.overrideWithBuild(
          (ref, notifier) => Stream.value(queue.firstOrNull),
        ),
        playQueueProvider.overrideWith((ref) => Stream.value(queue)),
        playbackStateProvider.overrideWith(
          (ref) => Stream.value(PlaybackState(queueIndex: 0)),
        ),
        playerCollectionTrackProvider.overrideWith(
          (ref, item) async => Track(
            id: item.id,
            name: item.title,
            artistName: 'Artist',
            albumName: 'Album',
            duration: 180,
          ),
        ),
      ],
      child: MaterialApp(
        theme: theme,
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: mornye
              ? MornyePlayerQueue(colorScheme: theme.colorScheme)
              : PlayerQueueSheet(
                  colorScheme: theme.colorScheme,
                  scrollController: ScrollController(),
                ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return collections;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final mornye in [false, true]) {
    testWidgets('the queue saves as a playlist in its order ($mornye)', (
      tester,
    ) async {
      final collections = await _pump(
        tester,
        mornye: mornye,
        queue: [
          for (final name in ['Current', 'Next', 'Last'])
            MediaItem(id: name, title: name, artist: 'Artist'),
        ],
      );
      await tester.tap(findByTooltip('Save queue as playlist'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Evening'));
      await tester.pump();
      // The picker's Done is the last action; the queue has its own below.
      final done = mornye
          ? tester
                .widget<AppActionButton>(find.byType(AppActionButton).last)
                .onPressed
          : tester
                .widget<ExpressiveButton>(find.byType(ExpressiveButton).last)
                .onPressed;
      done!();
      await tester.pumpAndSettle();
      expect(collections.added, hasLength(1));
      expect(collections.added.single.$1, 'evening');
      expect(collections.added.single.$2, ['Current', 'Next', 'Last']);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the header fits a narrow phone ($mornye)', (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await _pump(
        tester,
        mornye: mornye,
        queue: [MediaItem(id: 'one', title: 'One', artist: 'Artist')],
      );
      expect(findByTooltip('Save queue as playlist'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('an empty queue has nothing to save ($mornye)', (tester) async {
      await _pump(tester, mornye: mornye, queue: const []);
      final save = findByTooltip('Save queue as playlist');
      if (save.evaluate().isNotEmpty) {
        await tester.tap(save, warnIfMissed: false);
        await tester.pumpAndSettle();
      }
      expect(find.text('Evening'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }
}
