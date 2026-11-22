import 'dart:async';
import 'dart:convert';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/screens/local_album_screen.dart';
import 'package:mornye/screens/track_metadata_screen.dart';
import 'package:mornye/services/library_database.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/widgets/animation_utils.dart';
import 'package:mornye/widgets/settled_blur.dart';

LocalLibraryItem _track(int number) => LocalLibraryItem(
  id: 'track-$number',
  trackName: 'Song $number',
  artistName: 'Artist',
  albumName: 'Album',
  filePath: 'content://library/document/song-$number.flac',
  trackNumber: number,
  scannedAt: DateTime(2026),
);

void main() {
  Future<GlobalKey<NavigatorState>> mount(
    WidgetTester tester, {
    ThemeData? theme,
  }) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(430, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          navigatorKey: navigator,
          theme: theme ?? MornyeTheme.build(Brightness.light),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const Scaffold(body: Text('Library')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return navigator;
  }

  PageRoute<void> route(Widget page) => PageRouteBuilder<void>(
    transitionDuration: const Duration(milliseconds: 400),
    reverseTransitionDuration: const Duration(milliseconds: 400),
    pageBuilder: (_, _, _) => page,
    transitionsBuilder: (_, animation, _, child) => SlideTransition(
      position: Tween(
        begin: const Offset(1, 0),
        end: Offset.zero,
      ).animate(animation),
      child: child,
    ),
  );

  for (final popEarly in [false, true]) {
    testWidgets(
      'metadata starts reading during entrance, early pop=$popEarly',
      (tester) async {
        final navigator = await mount(tester);
        var statCalls = 0;
        var followUpCalls = 0;
        final delayedStat = Completer<String>();
        const channel = MethodChannel('com.zarz.mornye/backend');
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        messenger.setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'safStat') {
            statCalls++;
            if (popEarly) return delayedStat.future;
            return jsonEncode({'exists': false});
          }
          followUpCalls++;
          return null;
        });
        addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
        unawaited(
          navigator.currentState!.push(
            route(TrackMetadataScreen(localItem: _track(1))),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 150));
        expect(find.text('Song 1'), findsWidgets);
        expect(statCalls, 1);
        if (popEarly) navigator.currentState!.pop();
        await tester.pumpAndSettle();
        if (popEarly) {
          delayedStat.complete(jsonEncode({'exists': true, 'size': 100}));
          await tester.pump();
          expect(followUpCalls, 0);
        }
        expect(statCalls, 1);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('track details apply the file check once the page is in, '
      'and keep the blurred backdrop through the rebuild', (tester) async {
    final navigator = await mount(
      tester,
      theme: ThemeData.dark(useMaterial3: true),
    );
    const channel = MethodChannel('com.zarz.mornye/backend');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      channel,
      (call) async =>
          call.method == 'safStat' ? jsonEncode({'exists': false}) : null,
    );
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    final track = LocalLibraryItem(
      id: 'track-1',
      trackName: 'Song 1',
      artistName: 'Artist',
      albumName: 'Album',
      filePath: 'content://library/document/song-1.flac',
      coverPath: '/missing/cover.jpg',
      scannedAt: DateTime(2026),
    );
    unawaited(
      navigator.currentState!.push(
        route(TrackMetadataScreen(localItem: track)),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
    expect(find.text('File not found'), findsNothing);
    final backdrop = tester.widget<SettledBlur>(find.byType(SettledBlur)).child;
    await tester.pumpAndSettle();
    expect(find.text('File not found'), findsOneWidget);
    expect(
      tester.widget<SettledBlur>(find.byType(SettledBlur)).child,
      same(backdrop),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'album shows header immediately and applies rows during entrance',
    (tester) async {
      final navigator = await mount(tester);
      final result = Completer<List<LocalLibraryItem>>();
      unawaited(
        navigator.currentState!.push(
          route(
            LocalAlbumScreen(
              albumName: 'Album',
              artistName: 'Artist',
              loadTracks: () => result.future,
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
      expect(find.text('Album'), findsWidgets);
      expect(find.text('No tracks found for this album'), findsNothing);
      expect(find.byType(AlbumTrackListSkeleton), findsOneWidget);
      expect(find.byType(ShimmerLoading), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      result.complete([_track(2), _track(1)]);
      await tester.pump(const Duration(milliseconds: 150));
      await tester.pump();
      expect(find.text('Song 1'), findsOneWidget);
      expect(find.text('Song 2'), findsOneWidget);
      expect(find.byType(AlbumTrackListSkeleton), findsNothing);
      expect(
        ModalRoute.of(
          tester.element(find.byType(LocalAlbumScreen)),
        )!.animation!.value,
        lessThan(1),
      );
      await tester.pumpAndSettle();
      expect(find.text('Song 1'), findsOneWidget);
      expect(find.text('Song 2'), findsOneWidget);
      expect(
        tester.getTopLeft(find.text('Song 1')).dy,
        lessThan(tester.getTopLeft(find.text('Song 2')).dy),
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('album retries failed loading and ignores completion after pop', (
    tester,
  ) async {
    final navigator = await mount(tester);
    final result = Completer<List<LocalLibraryItem>>();
    var attempts = 0;
    unawaited(
      navigator.currentState!.push(
        route(
          LocalAlbumScreen(
            albumName: 'Album',
            artistName: 'Artist',
            loadTracks: () async {
              if (++attempts == 1) throw StateError('Unavailable');
              return result.future;
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Retry'));
    await tester.pump();
    expect(attempts, 2);
    navigator.currentState!.pop();
    await tester.pumpAndSettle();
    result.complete([_track(1)]);
    await tester.pump();
    expect(find.byType(LocalAlbumScreen), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
