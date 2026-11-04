import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/track_provider.dart';
import 'package:mornye/screens/artist_screen.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  tearDown(() => debugDesktopPlatformOverride = null);

  Future<void> pumpArtist(WidgetTester tester, {required bool desktop}) async {
    debugDesktopPlatformOverride = desktop;
    SharedPreferences.setMockInitialValues({});
    await tester.binding.setSurfaceSize(const Size(1000, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    const channel = MethodChannel('com.zarz.mornye/backend');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (_) async => null);
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: MornyeTheme.build(Brightness.dark),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: ArtistScreen(
            artistId: 'example-artist',
            artistName: 'Example Artist',
            albums: [
              for (var i = 0; i < 6; i++)
                ArtistAlbum(
                  id: 'album-$i',
                  name: 'Album $i',
                  releaseDate: '2024-03-0${i + 1}',
                  totalTracks: 4,
                  albumType: 'album',
                  artists: 'Example Artist',
                ),
            ],
            topTracks: [
              for (var i = 0; i < 7; i++)
                Track(
                  id: 'song-$i',
                  name: 'Song $i',
                  artistName: 'Example Artist',
                  albumName: 'Example Album',
                  duration: 180,
                ),
            ],
          ),
        ),
      ),
    );
    await tester.pump(const Duration(seconds: 1));
  }

  Future<void> dispose(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  }

  testWidgets('Latest Release sits beside the top songs and moves with them', (
    tester,
  ) async {
    await pumpArtist(tester, desktop: true);
    final latest = find.text('Latest Release');
    final songs = find.text('Top Songs');
    expect(tester.getTopLeft(latest).dy, tester.getTopLeft(songs).dy);
    expect(tester.getTopLeft(latest).dx, 24);
    final columnStep = tester.getTopLeft(songs).dx - 24;
    expect(columnStep, closeTo((1000 - 48 - 16) / 2 + 16, 0.01));
    // Three songs share a column, with the first row beside the release.
    expect(
      tester.getTopLeft(find.text('Song 3')).dx -
          tester.getTopLeft(find.text('Song 0')).dx,
      closeTo(columnStep, 1),
    );
    expect(
      tester.getTopLeft(find.text('Song 2')).dx,
      tester.getTopLeft(find.text('Song 0')).dx,
    );

    final latestStart = tester.getTopLeft(latest).dx;
    final songStart = tester.getTopLeft(songs).dx;
    await tester.drag(
      find.byKey(const ValueKey('artist-highlights')),
      const Offset(-300, 0),
    );
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(latest).dx - latestStart, closeTo(-columnStep, 1));
    expect(tester.getTopLeft(songs).dx - songStart, closeTo(-columnStep, 1));
    await dispose(tester);
  });

  testWidgets('album shelves drop the count and fit four covers to the pane', (
    tester,
  ) async {
    await pumpArtist(tester, desktop: true);
    expect(find.textContaining('(6)'), findsNothing);
    final shelf = find.byType(CustomScrollView);
    await tester.dragUntilVisible(
      find.text('Album 1'),
      shelf,
      const Offset(0, -200),
    );
    await tester.pumpAndSettle();
    // Newest first.
    final step =
        tester.getTopLeft(find.text('Album 1')).dx -
        tester.getTopLeft(find.text('Album 2')).dx;
    final column = (1000 - 48 - 16) / 2;
    expect(step, closeTo((column - 16) / 2 + 8, 1));
    await dispose(tester);
  });

  testWidgets('phones keep the stacked Mornye artist layout', (tester) async {
    await pumpArtist(tester, desktop: false);
    expect(find.text('Latest Release'), findsNothing);
    expect(find.byKey(const ValueKey('artist-highlights')), findsNothing);
    await dispose(tester);
  });
}
