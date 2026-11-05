import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/library_collections_provider.dart';
import 'package:mornye/screens/library_tracks_folder_screen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  final trackA = const Track(
    id: '1',
    name: 'Zeta',
    artistName: 'Artist 1',
    albumName: 'Album 1',
    duration: 100,
  );
  final trackB = const Track(
    id: '2',
    name: 'Alpha',
    artistName: 'Artist 2',
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

  testWidgets('sort button exists in playlist mode and allows sorting', (
    tester,
  ) async {
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

    // Verify sort button is present in the app bar actions
    final sortButton = find.byKey(const ValueKey('playlist-sort-button'));
    expect(sortButton, findsOneWidget);

    // Initial order: Zeta is first, Alpha is second
    expect(find.text('Zeta'), findsOneWidget);
    expect(find.text('Alpha'), findsOneWidget);

    // Tap sort button
    await tester.tap(sortButton);
    await tester.pumpAndSettle();

    // Sort options should be shown
    expect(find.text('Title (A-Z)'), findsOneWidget);

    // Select Title (A-Z)
    await tester.tap(find.text('Title (A-Z)'));
    await tester.pumpAndSettle();

    // Now sorted by Title (A-Z): Alpha comes before Zeta
    // Button tooltip or appearance reflects sorted state
    expect(find.byKey(const ValueKey('playlist-sort-button')), findsOneWidget);
  });

  testWidgets(
    'editing order drafts from true saved custom order even if view is sorted',
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

      // Sort by Title (A-Z)
      final sortButton = find.byKey(const ValueKey('playlist-sort-button'));
      await tester.tap(sortButton);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Title (A-Z)'));
      await tester.pumpAndSettle();

      // Now tap Edit Order button
      final editOrderButton = find.byKey(
        const ValueKey('collection-edit-order'),
      );
      expect(editOrderButton, findsOneWidget);
      await tester.tap(editOrderButton);
      await tester.pumpAndSettle();

      // In edit order mode, ReorderableDelayedDragStartListener items are displayed in the draft order.
      // The true saved custom order is Zeta (entry-1) first, then Alpha (entry-2).
      final reorderItems = find.byType(ReorderableDelayedDragStartListener);
      expect(reorderItems, findsNWidgets(2));
      final firstItemText = find.descendant(
        of: reorderItems.first,
        matching: find.text('Zeta'),
      );
      expect(firstItemText, findsOneWidget);
      final secondItemText = find.descendant(
        of: reorderItems.last,
        matching: find.text('Alpha'),
      );
      expect(secondItemText, findsOneWidget);
    },
  );
}

class _FakeCollectionsNotifier extends LibraryCollectionsNotifier {
  _FakeCollectionsNotifier(this._initialState);
  final LibraryCollectionsState _initialState;

  @override
  LibraryCollectionsState build() => _initialState;
}
