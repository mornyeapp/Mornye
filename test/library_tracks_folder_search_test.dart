import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/library_collections_provider.dart';
import 'package:mornye/screens/library_tracks_folder_screen.dart';

class _FakeCollectionsNotifier extends LibraryCollectionsNotifier {
  final LibraryCollectionsState _initial;
  _FakeCollectionsNotifier(this._initial);

  @override
  LibraryCollectionsState build() => _initial;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  final trackA = const Track(
    id: '1',
    name: 'Zeta Sunset',
    artistName: 'Artist One',
    albumName: 'Album 1',
    duration: 100,
  );
  final trackB = const Track(
    id: '2',
    name: 'Alpha Sunrise',
    artistName: 'Artist Two',
    albumName: 'Album 2',
    duration: 200,
  );

  final playlist = UserPlaylistCollection(
    id: 'test-playlist',
    name: 'My Playlist',
    createdAt: DateTime.utc(2026, 1, 1),
    updatedAt: DateTime.utc(2026, 1, 2),
    tracks: [
      CollectionTrackEntry(
        key: 'entry-1',
        track: trackA,
        addedAt: DateTime.utc(2026, 1, 1),
      ),
      CollectionTrackEntry(
        key: 'entry-2',
        track: trackB,
        addedAt: DateTime.utc(2026, 2, 1),
      ),
    ],
  );

  testWidgets(
    'search button exists in LibraryTracksFolderScreen and filters tracks',
    (tester) async {
      final state = LibraryCollectionsState(playlists: [playlist]);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            libraryCollectionsProvider.overrideWith(
              () => _FakeCollectionsNotifier(state),
            ),
          ],
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: const LibraryTracksFolderScreen(
              mode: LibraryTracksFolderMode.playlist,
              playlistId: 'test-playlist',
            ),
          ),
        ),
      );

      await tester.pumpAndSettle();

      // Both tracks present
      expect(find.text('Zeta Sunset'), findsOneWidget);
      expect(find.text('Alpha Sunrise'), findsOneWidget);

      // Search button exists
      final searchButton = find.byKey(const ValueKey('library-search-button'));
      expect(searchButton, findsOneWidget);

      // Tap search button
      await tester.tap(searchButton);
      await tester.pumpAndSettle();

      // Search field appears
      final searchInput = find.byKey(const ValueKey('library-search-input'));
      expect(searchInput, findsOneWidget);

      // Filter by 'Zeta'
      await tester.enterText(searchInput, 'Zeta');
      await tester.pumpAndSettle();

      expect(find.text('Zeta Sunset'), findsOneWidget);
      expect(find.text('Alpha Sunrise'), findsNothing);

      // Filter by 'Artist Two'
      await tester.enterText(searchInput, 'Artist Two');
      await tester.pumpAndSettle();

      expect(find.text('Alpha Sunrise'), findsOneWidget);
      expect(find.text('Zeta Sunset'), findsNothing);

      // Tap search button to close
      await tester.tap(searchButton);
      await tester.pumpAndSettle();

      // Both visible again
      expect(find.byKey(const ValueKey('library-search-input')), findsNothing);
      expect(find.text('Zeta Sunset'), findsOneWidget);
      expect(find.text('Alpha Sunrise'), findsOneWidget);
    },
  );
}
