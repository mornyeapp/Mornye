import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/app_localizations.dart';
import 'package:mornye/models/library_database_models.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/models/unified_library_item.dart';
import 'package:mornye/providers/download_queue_provider.dart';
import 'package:mornye/providers/library_browse_provider.dart';
import 'package:mornye/providers/library_genres_provider.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/screens/library_mix_screen.dart';
import 'package:mornye/screens/mornye_library_screen.dart';
import 'package:mornye/services/playable_media.dart' show PlayableMedia;
import 'package:mornye/theme/app_theme.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:mornye/widgets/desktop/track_table.dart';
import 'package:mornye/widgets/track_card.dart';

import 'support/fixed_settings.dart';
import 'support/tooltip_finder.dart';

const _rock = LibraryBrowseEntry(
  source: '',
  key: 'rock',
  name: 'Rock',
  artist: '',
  samplePath: '',
  trackCount: 3,
);

const _jazz = LibraryBrowseEntry(
  source: '',
  key: 'jazz',
  name: 'Jazz',
  artist: '',
  samplePath: '',
  trackCount: 1,
);

UnifiedLibraryItem _song(String id) => UnifiedLibraryItem.fromLocalLibrary(
  LocalLibraryItem(
    id: id,
    trackName: 'Song $id',
    artistName: 'Artist $id',
    albumName: 'Album $id',
    // Network songs need no file on disk to play.
    filePath: 'network://example/$id.flac',
    scannedAt: DateTime(2026, 11, 16),
    duration: 200,
  ),
);

final _songs = {
  'rock': [_song('r1'), _song('r2'), _song('r3')],
  'jazz': [_song('j1')],
};

class _History extends DownloadHistoryNotifier {
  @override
  DownloadHistoryState build() => DownloadHistoryState();
}

class _Player implements MusicPlayerController {
  final queues = <List<String>>[];
  final starts = <int>[];
  final shuffles = <bool>[];

  @override
  Future<void> playAll(
    List<PlayableMedia> items, {
    int initialIndex = 0,
  }) async {
    queues.add([for (final media in items) media.source]);
    starts.add(initialIndex);
  }

  @override
  Future<void> setShuffle(bool enabled) async => shuffles.add(enabled);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<_Player> _pump(
  WidgetTester tester,
  Widget home, {
  required bool mornye,
  bool desktop = false,
  List<LibraryBrowseEntry> genres = const [_rock, _jazz],
}) async {
  debugDesktopPlatformOverride = desktop;
  addTearDown(() => debugDesktopPlatformOverride = null);
  tester.view.physicalSize = desktop
      ? const Size(1280, 900)
      : const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final player = _Player();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        settingsProvider.overrideWith(
          () => FixedSettingsNotifier(
            const AppSettings(listeningStatisticsEnabled: false),
          ),
        ),
        downloadHistoryProvider.overrideWith(_History.new),
        libraryBrowsePageLoaderProvider.overrideWithValue(
          (_) async => const LibraryBrowsePage([]),
        ),
        libraryGenresProvider.overrideWith((ref) async => genres),
        libraryGenreSongsProvider.overrideWith(
          (ref, genre) async => _songs[genre] ?? const [],
        ),
        musicPlayerControllerProvider.overrideWithValue(player),
      ],
      child: MaterialApp(
        theme: mornye ? MornyeTheme.build(Brightness.dark) : AppTheme.dark(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: home,
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
  return player;
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  for (final desktop in [false, true]) {
    testWidgets('the Mornye Library lists genres and opens one '
        '(desktop: $desktop)', (tester) async {
      await _pump(
        tester,
        Scaffold(body: MornyeLibraryScreen(onOpenSection: (_) {})),
        mornye: true,
        desktop: desktop,
      );
      final row = find.widgetWithText(ListTile, 'Genres');
      expect(row, findsOneWidget);

      await tester.tap(row);
      await _settle(tester);
      expect(find.text('Rock'), findsOneWidget);
      expect(find.text('3 tracks'), findsOneWidget);
      expect(find.text('Jazz'), findsOneWidget);
      // The page keeps the order the query sorts them in.
      expect(
        tester.getTopLeft(find.text('Rock')).dy,
        lessThan(tester.getTopLeft(find.text('Jazz')).dy),
      );

      await tester.tap(find.text('Jazz'));
      await _settle(tester);
      expect(find.byType(LibraryMixScreen), findsOneWidget);
      expect(find.text('Song j1'), findsOneWidget);
      expect(find.text('Song r1'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('the Mornye Genres page explains an empty Library', (
    tester,
  ) async {
    await _pump(
      tester,
      Scaffold(
        body: MornyeLibraryScreen(
          page: MornyeLibraryPage.genres,
          onOpenSection: (_) {},
        ),
      ),
      mornye: true,
      genres: const [],
    );
    await _settle(tester);
    expect(find.text('Your music will appear here'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final desktop in [false, true]) {
    for (final mornye in [false, true]) {
      testWidgets('a genre lists exactly its songs, and Play and Shuffle '
          'queue them (desktop: $desktop, Mornye: $mornye)', (tester) async {
        final player = await _pump(
          tester,
          const LibraryMixScreen.genre(genre: _rock),
          mornye: mornye,
          desktop: desktop,
        );
        await _settle(tester);

        expect(find.text('Rock'), findsWidgets);
        expect(find.text('3 tracks'), findsOneWidget);
        // A genre is not a mix: no artists line or daily refresh.
        expect(find.text('Updated daily'), findsNothing);
        for (final id in ['r1', 'r2', 'r3']) {
          expect(find.text('Song $id'), findsOneWidget);
        }
        expect(find.text('Song j1'), findsNothing);
        if (desktop) {
          expect(find.byType(SliverTrackTable), findsOneWidget);
        } else {
          expect(find.byType(TrackCard), findsNWidgets(3));
        }

        await tester.tap(find.text('Play'));
        await _settle(tester);
        const queue = [
          'network://example/r1.flac',
          'network://example/r2.flac',
          'network://example/r3.flac',
        ];
        expect(player.queues.single, queue);
        expect(player.starts.single, 0);
        expect(player.shuffles, [false]);

        // The Mornye phone header labels its Shuffle button.
        await tester.tap(
          mornye && !desktop
              ? find.text('Shuffle')
              : findByTooltip('Shuffle').hitTestable().first,
        );
        await _settle(tester);
        expect(player.queues.last, queue);
        expect(player.shuffles.last, isTrue);
        expect(tester.takeException(), isNull);
      });
    }
  }
}
