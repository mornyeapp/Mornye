import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/app_localizations.dart';
import 'package:mornye/models/library_database_models.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/models/unified_library_item.dart';
import 'package:mornye/providers/download_queue_provider.dart';
import 'package:mornye/providers/library_artist_songs_provider.dart';
import 'package:mornye/providers/library_browse_provider.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/screens/library_artist_screen.dart';
import 'package:mornye/services/playable_media.dart' show PlayableMedia;
import 'package:mornye/theme/app_theme.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/widgets/track_card.dart';

import 'support/fixed_settings.dart';

const _album = LibraryBrowseEntry(
  source: 'local',
  key: 'first album|ana',
  name: 'First Album',
  artist: 'Ana',
  samplePath: '',
  trackCount: 2,
);

UnifiedLibraryItem _song(String id) => UnifiedLibraryItem.fromLocalLibrary(
  LocalLibraryItem(
    id: id,
    trackName: 'Song $id',
    artistName: 'Ana',
    albumName: 'Album $id',
    // Network songs need no file on disk to play.
    filePath: 'network://example/$id.flac',
    scannedAt: DateTime(2026, 11, 17),
    duration: 200,
  ),
);

/// Keeps the chosen view in memory only.
class _Settings extends FixedSettingsNotifier {
  _Settings(super.initial);

  @override
  void setLibraryArtistShowsSongs(bool songs) =>
      state = state.copyWith(libraryArtistShowsSongs: songs);
}

class _History extends DownloadHistoryNotifier {
  @override
  DownloadHistoryState build() => DownloadHistoryState();
}

class _Player implements MusicPlayerController {
  final queues = <List<String>>[];

  @override
  Future<void> playAll(
    List<PlayableMedia> items, {
    int initialIndex = 0,
  }) async => queues.add([for (final media in items) media.source]);

  @override
  Future<void> setShuffle(bool enabled) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<(_Player, ProviderContainer)> _pump(
  WidgetTester tester, {
  required bool mornye,
  bool songs = false,
}) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final player = _Player();
  final artists = <String>[];
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        settingsProvider.overrideWith(
          () => _Settings(
            AppSettings(
              listeningStatisticsEnabled: false,
              libraryArtistShowsSongs: songs,
            ),
          ),
        ),
        downloadHistoryProvider.overrideWith(_History.new),
        libraryBrowsePageLoaderProvider.overrideWithValue((request) async {
          artists.add(request.browse.artist ?? '');
          return const LibraryBrowsePage([_album]);
        }),
        libraryArtistSongsProvider.overrideWith(
          (ref, artist) async =>
              artist == 'Ana' ? [_song('a1'), _song('a2')] : const [],
        ),
        musicPlayerControllerProvider.overrideWithValue(player),
      ],
      child: MaterialApp(
        theme: mornye ? MornyeTheme.build(Brightness.dark) : AppTheme.dark(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const LibraryArtistScreen(artist: 'Ana'),
      ),
    ),
  );
  await _settle(tester);
  expect(artists.toSet(), songs ? isEmpty : {'Ana'});
  return (
    player,
    ProviderScope.containerOf(tester.element(find.byType(LibraryArtistScreen))),
  );
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  for (final mornye in [false, true]) {
    testWidgets('an artist opens on their albums and switches to all their '
        'songs (Mornye: $mornye)', (tester) async {
      final (player, container) = await _pump(tester, mornye: mornye);

      expect(find.text('Ana'), findsWidgets);
      expect(find.text('First Album'), findsOneWidget);
      expect(find.byType(TrackCard), findsNothing);
      expect(find.text('Artist Page'), findsOneWidget);

      // A connected group lays out each label twice.
      await tester.tap(find.text('Songs').hitTestable().first);
      await _settle(tester);

      expect(container.read(settingsProvider).libraryArtistShowsSongs, isTrue);
      expect(find.text('First Album'), findsNothing);
      expect(find.byType(TrackCard), findsNWidgets(2));
      expect(find.text('Song a1'), findsOneWidget);
      expect(find.text('2 tracks'), findsOneWidget);
      // The switch and the artist link stay on the songs view.
      expect(find.text('Artist Page'), findsOneWidget);

      await tester.tap(find.text('Play'));
      await _settle(tester);
      expect(player.queues.single, [
        'network://example/a1.flac',
        'network://example/a2.flac',
      ]);

      await tester.tap(find.text('Albums').hitTestable().first);
      await _settle(tester);
      expect(container.read(settingsProvider).libraryArtistShowsSongs, isFalse);
      expect(find.text('First Album'), findsOneWidget);
      expect(find.byType(TrackCard), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('an artist opens on their songs when that view was chosen '
        'last (Mornye: $mornye)', (tester) async {
      await _pump(tester, mornye: mornye, songs: true);

      expect(find.byType(TrackCard), findsNWidgets(2));
      expect(find.text('First Album'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }
}
