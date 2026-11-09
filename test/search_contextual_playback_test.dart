import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/library_collections_provider.dart';
import 'package:mornye/providers/playback_provider.dart';
import 'package:mornye/screens/library_tracks_folder_screen.dart';
import 'package:mornye/theme/mornye_theme.dart';

class _FakeCollectionsNotifier extends LibraryCollectionsNotifier {
  final LibraryCollectionsState _initial;
  _FakeCollectionsNotifier(this._initial);

  @override
  LibraryCollectionsState build() => _initial;
}

class _FakePlaybackNotifier extends PlaybackController {
  List<Track>? lastPlayedTracks;
  int? lastStartIndex;

  @override
  PlaybackState build() => const PlaybackState();

  @override
  Future<void> playTrackList(List<Track> tracks, {int startIndex = 0}) async {
    lastPlayedTracks = tracks;
    lastStartIndex = startIndex;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  final track1 = const Track(
    id: 't-1',
    name: 'Yellow',
    artistName: 'Coldplay',
    albumName: 'Parachutes',
    duration: 269,
  );
  final track2 = const Track(
    id: 't-2',
    name: 'Fix You',
    artistName: 'Coldplay',
    albumName: 'X&Y',
    duration: 295,
  );
  final track3 = const Track(
    id: 't-3',
    name: 'Bohemian Rhapsody',
    artistName: 'Queen',
    albumName: 'A Night at the Opera',
    duration: 354,
  );

  testWidgets(
    'search filtering plays only filtered tracks and updates play/shuffle actions',
    (tester) async {
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      final fakePlayback = _FakePlaybackNotifier();
      final playlist = UserPlaylistCollection(
        id: 'p-1',
        name: 'My Playlist',
        createdAt: DateTime.utc(2026, 1, 1),
        updatedAt: DateTime.utc(2026, 1, 2),
        tracks: [
          CollectionTrackEntry(
            track: track1,
            key: 'k-1',
            addedAt: DateTime.utc(2026, 1, 1),
          ),
          CollectionTrackEntry(
            track: track3,
            key: 'k-3',
            addedAt: DateTime.utc(2026, 1, 2),
          ),
          CollectionTrackEntry(
            track: track2,
            key: 'k-2',
            addedAt: DateTime.utc(2026, 1, 3),
          ),
        ],
      );

      final collectionsState = LibraryCollectionsState(playlists: [playlist]);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            playbackProvider.overrideWith(() => fakePlayback),
            libraryCollectionsProvider.overrideWith(
              () => _FakeCollectionsNotifier(collectionsState),
            ),
          ],
          child: MaterialApp(
            theme: MornyeTheme.build(Brightness.dark),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: const LibraryTracksFolderScreen(
              mode: LibraryTracksFolderMode.playlist,
              playlistId: 'p-1',
            ),
          ),
        ),
      );

      await tester.pumpAndSettle();

      // Initially all 3 tracks are in the list
      expect(find.text('Yellow'), findsOneWidget);
      expect(find.text('Fix You'), findsOneWidget);
      expect(find.text('Bohemian Rhapsody'), findsOneWidget);

      // Tap search button
      final searchButton = find.byKey(const ValueKey('library-search-button'));
      expect(searchButton, findsOneWidget);
      await tester.tap(searchButton);
      await tester.pumpAndSettle();

      // Enter "Coldplay" into the search field
      final searchField = find.byKey(const ValueKey('library-search-input'));
      expect(searchField, findsOneWidget);
      await tester.enterText(searchField, 'Coldplay');
      await tester.pumpAndSettle();

      // Queen is filtered out, only 2 Coldplay songs remain
      expect(find.text('Yellow'), findsOneWidget);
      expect(find.text('Fix You'), findsOneWidget);
      expect(find.text('Bohemian Rhapsody'), findsNothing);

      // Tap the shuffle button
      final shuffleButton = find.byKey(const ValueKey('collection-shuffle'));
      expect(shuffleButton, findsOneWidget);
      await tester.tap(shuffleButton);
      await tester.pumpAndSettle();

      // Verify that fakePlayback received only the 2 Coldplay songs!
      expect(fakePlayback.lastPlayedTracks, isNotNull);
      expect(fakePlayback.lastPlayedTracks!.length, equals(2));
      expect(
        fakePlayback.lastPlayedTracks!.every(
          (t) => t.artistName == 'Coldplay',
        ),
        isTrue,
      );
    },
  );
}
