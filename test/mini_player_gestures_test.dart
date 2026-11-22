import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/providers/runtime_profile_provider.dart';
import 'package:mornye/routes/now_playing_route.dart';
import 'package:mornye/services/remote_playback.dart';
import 'package:mornye/theme/app_theme.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/widgets/mini_player.dart';
import 'package:mornye/widgets/player_artwork.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/tooltip_finder.dart';

class _Controller implements MusicPlayerController {
  _Controller({this.onDismiss});

  final VoidCallback? onDismiss;
  final calls = <String>[];

  @override
  Future<void> dismiss() async {
    calls.add('dismiss');
    onDismiss?.call();
  }

  @override
  Future<void> next() async => calls.add('next');

  @override
  Future<void> previous() async => calls.add('previous');

  @override
  Future<void> togglePlayPause(bool isPlaying) async =>
      calls.add(isPlaying ? 'pause' : 'play');

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _RemotePlayback implements RemotePlayback {
  @override
  String get name => 'Desktop';

  @override
  Stream<RemoteTransfer?> get transfers => const Stream.empty();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _PushObserver extends NavigatorObserver {
  final pushed = <Route<dynamic>>[];

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      pushed.add(route);
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final configuration in [
    (name: 'Material', mornye: false, compact: false),
    (name: 'Mornye', mornye: true, compact: false),
    (name: 'Mornye compact', mornye: true, compact: true),
  ]) {
    Future<_Controller> pumpPlayer(
      WidgetTester tester, {
      ScrollController? carousel,
      Stream<MediaItem?>? mediaItems,
      bool playing = false,
      bool loading = false,
      RemotePlayback? remote,
      VoidCallback? onDismiss,
      NavigatorObserver? observer,
    }) async {
      final controller = _Controller(onDismiss: onDismiss);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            currentMediaItemProvider.overrideWithBuild(
              (ref, notifier) =>
                  mediaItems ??
                  Stream.value(
                    const MediaItem(
                      id: 'song',
                      title: 'Song',
                      artist: 'Artist',
                    ),
                  ),
            ),
            playbackStateProvider.overrideWith((ref) => const Stream.empty()),
            playbackPlayingProvider.overrideWithValue(playing),
            playbackLoadingProvider.overrideWithValue(loading),
            activeRemotePlaybackProvider.overrideWithValue(remote),
            musicPlayerControllerProvider.overrideWithValue(controller),
            mornyeLiquidGlassProvider.overrideWithValue(false),
            backdropBlurEnabledProvider.overrideWithValue(false),
          ],
          child: MaterialApp(
            navigatorObservers: [?observer],
            theme: configuration.mornye
                ? MornyeTheme.build(Brightness.light)
                : AppTheme.light(),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: carousel == null
                  ? null
                  : SizedBox(
                      height: 100,
                      child: ListView.builder(
                        controller: carousel,
                        scrollDirection: Axis.horizontal,
                        itemExtent: 120,
                        itemCount: 20,
                        itemBuilder: (_, index) => Text('Album $index'),
                      ),
                    ),
              bottomNavigationBar: Align(
                heightFactor: 1,
                child: SizedBox(
                  width: configuration.compact ? 260 : 360,
                  child: MiniPlayer(compact: configuration.compact),
                ),
              ),
            ),
          ),
        ),
      );
      if (loading) {
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
      } else {
        await tester.pumpAndSettle();
      }
      return controller;
    }

    testWidgets(
      '${configuration.name}: mounted player follows track and metadata changes',
      (tester) async {
        final mediaItems = StreamController<MediaItem?>();
        addTearDown(mediaItems.close);
        await pumpPlayer(tester, mediaItems: mediaItems.stream);
        final playerState = tester.state(find.byType(MiniPlayer));
        const first = MediaItem(
          id: 'first',
          title: 'First',
          artist: 'Artist A',
        );
        const second = MediaItem(
          id: 'second',
          title: 'Second',
          artist: 'Artist B',
        );
        String? previousTitle;
        String? previousArtist;
        for (final item in [
          first,
          second,
          second.copyWith(title: 'Revised', artist: 'Artist C'),
          first,
        ]) {
          mediaItems.add(item);
          await tester.pumpAndSettle();
          expect(find.text(item.title), findsOneWidget);
          expect(find.text(item.artist!), findsOneWidget);
          if (previousTitle != null) {
            expect(find.text(previousTitle), findsNothing);
            expect(find.text(previousArtist!), findsNothing);
          }
          expect(tester.state(find.byType(MiniPlayer)), same(playerState));
          expect(tester.takeException(), isNull);
          previousTitle = item.title;
          previousArtist = item.artist;
        }
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );

    testWidgets(
      '${configuration.name}: returning to the mini player shows the latest song',
      (tester) async {
        final mediaItems = StreamController<MediaItem?>();
        addTearDown(mediaItems.close);
        await pumpPlayer(tester, mediaItems: mediaItems.stream);
        mediaItems.add(
          const MediaItem(id: 'first', title: 'First', artist: 'Artist A'),
        );
        await tester.pumpAndSettle();
        final playerState = tester.state(find.byType(MiniPlayer));
        final navigator = tester.state<NavigatorState>(find.byType(Navigator));
        unawaited(
          navigator.push<void>(
            MaterialPageRoute(
              builder: (_) => const Scaffold(body: Text('Another screen')),
            ),
          ),
        );
        await tester.pumpAndSettle();
        mediaItems.add(
          const MediaItem(id: 'second', title: 'Second', artist: 'Artist B'),
        );
        await tester.pumpAndSettle();
        mediaItems.add(
          const MediaItem(id: 'third', title: 'Third', artist: 'Artist C'),
        );
        await tester.pumpAndSettle();
        navigator.pop();
        await tester.pumpAndSettle();
        expect(find.text('Third'), findsOneWidget);
        expect(find.text('Artist C'), findsOneWidget);
        expect(find.text('First'), findsNothing);
        expect(find.text('Second'), findsNothing);
        expect(tester.state(find.byType(MiniPlayer)), same(playerState));
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );

    testWidgets('${configuration.name}: sideways swipes navigate and keep '
        'the playing mini player visible', (tester) async {
      final controller = await pumpPlayer(tester, playing: true);
      final title = find.text('Song');
      final playerState = tester.state(find.byType(MiniPlayer));
      final bounds = tester.getRect(find.byType(MiniPlayer));

      await tester.timedDrag(
        title,
        const Offset(-100, 0),
        const Duration(milliseconds: 600),
      );
      await tester.pumpAndSettle();
      expect(controller.calls, ['next']);
      expect(title, findsOneWidget);
      expect(tester.getRect(find.byType(MiniPlayer)), bounds);

      await tester.timedDrag(
        title,
        const Offset(100, 0),
        const Duration(milliseconds: 600),
      );
      await tester.pumpAndSettle();
      expect(controller.calls, ['next', 'previous']);
      expect(tester.state(find.byType(MiniPlayer)), same(playerState));
      expect(tester.takeException(), isNull);
    });

    {
      for (final dx in [-100.0, 100.0]) {
        testWidgets('${configuration.name}: paused swipe $dx closes the '
            'player and a new song shows it again', (tester) async {
          final mediaItems = StreamController<MediaItem?>();
          addTearDown(mediaItems.close);
          final controller = await pumpPlayer(
            tester,
            mediaItems: mediaItems.stream,
            onDismiss: () => mediaItems.add(null),
          );
          mediaItems.add(const MediaItem(id: 'song', title: 'Song'));
          await tester.pumpAndSettle();

          expect(findByTooltip('Dismiss'), findsNothing);
          await tester.timedDrag(
            find.text('Song'),
            Offset(dx, 0),
            const Duration(milliseconds: 600),
          );
          await tester.pumpAndSettle();
          expect(controller.calls, ['dismiss']);
          expect(find.text('Song'), findsNothing);
          expect(tester.getSize(find.byType(MiniPlayer)).height, 0);

          mediaItems.add(const MediaItem(id: 'next', title: 'Next song'));
          await tester.pumpAndSettle();
          expect(find.text('Next song'), findsOneWidget);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
        });
      }

      testWidgets('${configuration.name}: loading swipes leave the player '
          'open', (tester) async {
        final controller = await pumpPlayer(tester, loading: true);
        for (final dx in [-100.0, 100.0]) {
          await tester.timedDrag(
            find.text('Song'),
            Offset(dx, 0),
            const Duration(milliseconds: 600),
          );
          await tester.pump(const Duration(milliseconds: 300));
        }
        expect(controller.calls, isEmpty);
        expect(find.text('Song'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });

      testWidgets('${configuration.name}: paused remote swipes keep track '
          'navigation', (tester) async {
        final controller = await pumpPlayer(tester, remote: _RemotePlayback());
        for (final dx in [-100.0, 100.0]) {
          await tester.timedDrag(
            find.text('Song'),
            Offset(dx, 0),
            const Duration(milliseconds: 600),
          );
          await tester.pumpAndSettle();
        }
        expect(controller.calls, ['next', 'previous']);
        expect(find.text('Song'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }

    for (final reducedMotion in [false, true]) {
      testWidgets('${configuration.name}: the title lines follow a sideways '
          'drag while the cover stays (reduced motion: $reducedMotion)', (
        tester,
      ) async {
        if (reducedMotion) {
          tester.platformDispatcher.accessibilityFeaturesTestValue =
              const FakeAccessibilityFeatures(disableAnimations: true);
          addTearDown(
            tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
          );
        }
        final controller = await pumpPlayer(tester, playing: true);
        final title = find.text('Song');
        final cover = find.byType(PlayerArtwork);
        final start = tester.getTopLeft(title);
        final coverRect = tester.getRect(cover);

        final gesture = await tester.startGesture(tester.getCenter(title));
        for (var step = 0; step < 4; step++) {
          await gesture.moveBy(const Offset(-10, 0));
          await tester.pump(const Duration(milliseconds: 16));
        }
        // The Mornye glass leans toward a held finger, carrying the cover
        // with it; only the lines move against the cover.
        final coverShift = tester.getCenter(cover).dx - coverRect.center.dx;
        final moved = tester.getTopLeft(title).dx - start.dx;
        expect(coverShift.abs(), lessThan(6));
        if (reducedMotion) {
          expect(moved - coverShift, closeTo(0, 0.5));
        } else {
          expect(moved - coverShift, lessThan(-20));
        }

        // A short, slow release keeps the song and returns the lines.
        await tester.pump(const Duration(milliseconds: 250));
        await gesture.up();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 140));
        if (!reducedMotion) {
          expect(tester.getTopLeft(title).dx, greaterThan(start.dx + moved));
        }
        await tester.pumpAndSettle();
        expect(tester.getTopLeft(title), start);
        expect(controller.calls, isEmpty);
        expect(tester.takeException(), isNull);
      });
    }

    for (final reducedMotion in [false, true]) {
      testWidgets('${configuration.name}: the full player opens from the mini '
          'player bounds (reduced motion: $reducedMotion)', (tester) async {
        if (reducedMotion) {
          tester.platformDispatcher.accessibilityFeaturesTestValue =
              const FakeAccessibilityFeatures(disableAnimations: true);
          addTearDown(
            tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
          );
        }
        final observer = _PushObserver();
        await pumpPlayer(tester, observer: observer);
        await tester.tap(find.text('Song'));
        final route = observer.pushed.whereType<NowPlayingRoute>().single;
        final geometry = route.miniPlayerGeometry!()!;
        // The surface without the Mornye bar's bottom padding.
        final mini = tester.getRect(find.byType(MiniPlayer));
        expect(geometry.surface.topLeft, mini.topLeft);
        expect(geometry.surface.width, mini.width);
        if (configuration.mornye) {
          expect(route.morph, isNull);
        } else {
          expect(
            route.morph!.duration,
            reducedMotion ? Duration.zero : greaterThan(Duration.zero),
          );
        }
        // The test leaves the full player itself unbuilt.
        route.navigator!.removeRoute(route);
        await tester.pumpWidget(const SizedBox.shrink());
      });
    }

    testWidgets('${configuration.name}: the cover hides while a closing '
        'player lands its own', (tester) async {
      addTearDown(() => NowPlayingRoute.coverLanding.value = false);
      await pumpPlayer(tester);
      double coverOpacity() => tester
          .widget<Opacity>(
            find
                .ancestor(
                  of: find.byType(PlayerArtwork),
                  matching: find.byType(Opacity),
                )
                .first,
          )
          .opacity;
      expect(coverOpacity(), 1);
      NowPlayingRoute.coverLanding.value = true;
      await tester.pump();
      expect(coverOpacity(), 0);
      NowPlayingRoute.coverLanding.value = false;
      await tester.pump();
      expect(coverOpacity(), 1);
    });

    testWidgets('${configuration.name}: a new song fades the lines through', (
      tester,
    ) async {
      final mediaItems = StreamController<MediaItem?>();
      addTearDown(mediaItems.close);
      await pumpPlayer(tester, mediaItems: mediaItems.stream);
      mediaItems.add(
        const MediaItem(id: 'first', title: 'First', artist: 'Artist A'),
      );
      await tester.pumpAndSettle();
      mediaItems.add(
        const MediaItem(id: 'second', title: 'Second', artist: 'Artist B'),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.text('First'), findsOneWidget);
      expect(find.text('Second'), findsOneWidget);
      await tester.pumpAndSettle();
      expect(find.text('First'), findsNothing);
      expect(find.text('Second'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('${configuration.name}: an upward drag ticks once where '
        'letting go opens the player', (tester) async {
      final haptics = <Object?>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'HapticFeedback.vibrate') {
            haptics.add(call.arguments);
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      final observer = _PushObserver();
      final controller = await pumpPlayer(tester, observer: observer);
      final gesture = await tester.startGesture(
        tester.getCenter(find.text('Song')),
      );
      await gesture.moveBy(const Offset(0, -30));
      await tester.pump();
      await gesture.moveBy(const Offset(0, -12));
      await tester.pump();
      expect(haptics, isEmpty);
      await gesture.moveBy(const Offset(0, -20));
      await tester.pump();
      await gesture.moveBy(const Offset(0, -20));
      await tester.pump();
      expect(haptics, hasLength(1));
      // Cancelling keeps the player closed.
      await gesture.cancel();
      await tester.pumpAndSettle();
      expect(observer.pushed.whereType<NowPlayingRoute>(), isEmpty);
      expect(controller.calls, isEmpty);
    });

    testWidgets('${configuration.name}: short and cancelled drags do not act', (
      tester,
    ) async {
      final controller = await pumpPlayer(tester);
      final title = find.text('Song');
      for (final dx in [-30.0, 30.0]) {
        final gesture = await tester.startGesture(tester.getCenter(title));
        await gesture.moveBy(Offset(dx, 0));
        await tester.pump(const Duration(milliseconds: 250));
        await gesture.up();
        await tester.pumpAndSettle();
      }
      final gesture = await tester.startGesture(tester.getCenter(title));
      await gesture.moveBy(const Offset(-100, 0));
      await gesture.cancel();
      await tester.pumpAndSettle();
      expect(controller.calls, isEmpty);

      // A cancelled drag must not contribute travel to the next gesture.
      await tester.drag(title, const Offset(30, 0));
      await tester.pumpAndSettle();
      expect(controller.calls, isEmpty);

      await tester.timedDrag(
        title,
        const Offset(-40, 0),
        const Duration(milliseconds: 50),
        frequency: 120,
      );
      await tester.pumpAndSettle();
      expect(controller.calls, ['dismiss']);
    });

    testWidgets('${configuration.name}: Home carousel and playback buttons '
        'keep their own gestures', (tester) async {
      final carousel = ScrollController();
      addTearDown(carousel.dispose);
      final controller = await pumpPlayer(tester, carousel: carousel);
      await tester.drag(find.byType(ListView), const Offset(-200, 0));
      await tester.pumpAndSettle();
      expect(carousel.offset, greaterThan(0));
      expect(controller.calls, isEmpty);

      await tester.tap(findByTooltip('Play'));
      await tester.pumpAndSettle();
      expect(controller.calls, ['play']);
      if (!configuration.compact) {
        await tester.tap(findByTooltip('Next track'));
        await tester.pumpAndSettle();
        expect(controller.calls, ['play', 'next']);
      }
      expect(tester.takeException(), isNull);
    });
  }
}
