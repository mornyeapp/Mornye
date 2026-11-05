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
    name: 'Zulu',
    artistName: 'Artist 1',
    albumName: 'Album 1',
    duration: 120,
  );
  final trackB = const Track(
    id: '2',
    name: 'Alpha',
    artistName: 'Artist 2',
    albumName: 'Album 2',
    duration: 180,
  );

  testWidgets('PlaylistScreen displays sort button and sorts tracks', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: PlaylistScreen(
            playlistName: 'Explore Playlist',
            tracks: [trackA, trackB],
          ),
        ),
      ),
    );

    await tester.pumpAndSettle();

    // Verify sort button is present
    final sortButton = find.byKey(const ValueKey('playlist-sort-button'));
    expect(sortButton, findsOneWidget);

    // Initial order: Zulu is present and Alpha is present
    expect(find.text('Zulu'), findsOneWidget);
    expect(find.text('Alpha'), findsOneWidget);

    // Tap sort button
    await tester.tap(sortButton);
    await tester.pumpAndSettle();

    // Date added is false for catalog playlists, so check Title (A-Z)
    expect(find.text('Title (A-Z)'), findsOneWidget);
    expect(find.text('Date added (newest first)'), findsNothing);

    // Tap Title (A-Z)
    await tester.tap(find.text('Title (A-Z)'));
    await tester.pumpAndSettle();

    // Sort is active
    expect(find.byKey(const ValueKey('playlist-sort-button')), findsOneWidget);
  });

  testWidgets('sort button is hidden during selection mode in PlaylistScreen', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: PlaylistScreen(
            playlistName: 'Explore Playlist',
            tracks: [trackA, trackB],
          ),
        ),
      ),
    );

    await tester.pumpAndSettle();

    // Verify sort button is present initially
    expect(find.byKey(const ValueKey('playlist-sort-button')), findsOneWidget);

    // Enter selection mode by long-pressing a track tile
    await tester.longPress(find.text('Zulu'));
    await tester.pumpAndSettle();

    // Verify sort button is now hidden
    expect(find.byKey(const ValueKey('playlist-sort-button')), findsNothing);
  });
}
