import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/screens/playlist_screen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  final trackA = const Track(
    id: '1',
    name: 'Zulu Night',
    artistName: 'Artist One',
    albumName: 'Album 1',
    duration: 120,
  );
  final trackB = const Track(
    id: '2',
    name: 'Alpha Morning',
    artistName: 'Artist Two',
    albumName: 'Album 2',
    duration: 180,
  );

  testWidgets('PlaylistScreen search button toggles and filters track list', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: PlaylistScreen(
            playlistName: 'Test Playlist',
            tracks: [trackA, trackB],
          ),
        ),
      ),
    );

    await tester.pumpAndSettle();

    // Verify both tracks are visible initially
    expect(find.text('Zulu Night'), findsOneWidget);
    expect(find.text('Alpha Morning'), findsOneWidget);

    // Find the search button
    final searchButton = find.byKey(const ValueKey('playlist-search-button'));
    expect(searchButton, findsOneWidget);

    // Tap search button to open search bar
    await tester.tap(searchButton);
    await tester.pumpAndSettle();

    // Find the search input field
    final searchInput = find.byKey(const ValueKey('playlist-search-input'));
    expect(searchInput, findsOneWidget);

    // Type 'Zulu'
    await tester.enterText(searchInput, 'Zulu');
    await tester.pumpAndSettle();

    // Only 'Zulu Night' should match
    expect(find.text('Zulu Night'), findsOneWidget);
    expect(find.text('Alpha Morning'), findsNothing);

    // Type 'Artist Two'
    await tester.enterText(searchInput, 'Artist Two');
    await tester.pumpAndSettle();

    // Only 'Alpha Morning' should match
    expect(find.text('Alpha Morning'), findsOneWidget);
    expect(find.text('Zulu Night'), findsNothing);

    // Close search by tapping search button again
    await tester.tap(searchButton);
    await tester.pumpAndSettle();

    // Search bar closed and both tracks visible again
    expect(find.byKey(const ValueKey('playlist-search-input')), findsNothing);
    expect(find.text('Zulu Night'), findsOneWidget);
    expect(find.text('Alpha Morning'), findsOneWidget);
  });
}
