import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';
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

import 'support/tooltip_finder.dart';

void main() {
  tearDown(() => debugDesktopPlatformOverride = null);

  testWidgets('desktop artist singles shelf pages with hover arrows', (
    tester,
  ) async {
    debugDesktopPlatformOverride = true;
    SharedPreferences.setMockInitialValues({});
    await tester.binding.setSurfaceSize(const Size(1200, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    const channel = MethodChannel('com.zarz.mornye/backend');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (_) async => null);
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    final singles = [
      for (var i = 0; i < 24; i++)
        ArtistAlbum(
          id: 'single-$i',
          name: 'Single $i',
          releaseDate: '2020',
          totalTracks: 1,
          albumType: 'single',
          artists: 'Example Artist',
        ),
    ];
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: ArtistScreen(
            artistId: 'example-artist',
            artistName: 'Example Artist',
            albums: singles,
            // Supplied top tracks keep the screen from fetching again.
            topTracks: const [
              Track(
                id: 'example-song',
                name: 'Example Song',
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

    final first = find.text('Single 0');
    expect(first, findsOneWidget);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(first));
    await tester.pump();

    final forward = findByTooltip('Scroll forward');
    expect(forward, findsOneWidget);
    expect(findByTooltip('Scroll back'), findsNothing);
    await tester.tap(forward);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    // A page moves the first single past the list's cache extent.
    expect(first, findsNothing);
    expect(findByTooltip('Scroll back'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  });

  ArtistAlbum album(int index, String type) => ArtistAlbum(
    id: '$type-$index',
    name: '$type $index',
    releaseDate: '2020-01-01',
    totalTracks: 10,
    albumType: type,
    artists: 'Example Artist',
  );

  Future<void> open(
    WidgetTester tester, {
    required List<ArtistAlbum> albums,
    required bool mornye,
    Size size = const Size(430, 900),
  }) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    const channel = MethodChannel('com.zarz.mornye/backend');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (_) async => null);
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: mornye ? MornyeTheme.build(Brightness.dark) : null,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: ArtistScreen(
            artistId: 'example-artist',
            artistName: 'Example Artist',
            albums: albums,
            topTracks: const [
              Track(
                id: 'example-song',
                name: 'Example Song',
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

  for (final mornye in [false, true]) {
    testWidgets('a long shelf opens every album in a grid (Mornye: $mornye)', (
      tester,
    ) async {
      await open(
        tester,
        mornye: mornye,
        albums: [
          for (var i = 0; i < 9; i++) album(i, 'album'),
          album(0, 'single'),
        ],
      );
      final albums = find.byKey(const ValueKey('artist-albums'));
      await tester.scrollUntilVisible(
        albums,
        200,
        scrollable: find.byType(Scrollable).first,
      );
      final showAll = mornye
          ? find.bySemanticsLabel('Show all Albums')
          : find.text('Show all');
      expect(showAll, findsWidgets);
      await tester.ensureVisible(showAll.first);
      await tester.pump(const Duration(seconds: 1));
      await tester.tap(showAll.first);
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 1));
      expect(albums, findsNothing);

      // Two columns on a phone: nine albums, more than the shelf shows, and
      // no single from the shelf beside it.
      final first = tester.getRect(find.text('album 0'));
      final second = tester.getRect(find.text('album 1'));
      expect(second.left, greaterThan(first.right));
      expect(tester.getRect(find.text('album 2')).top, greaterThan(first.top));
      expect(find.text('single 0'), findsNothing);
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 1));
    });
  }

  testWidgets('a shelf that fits its pane offers no grid', (tester) async {
    await open(
      tester,
      mornye: false,
      albums: [for (var i = 0; i < 2; i++) album(i, 'album')],
    );
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('artist-albums')),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Show all'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  });
}
