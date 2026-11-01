import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/providers/player_artwork_video_provider.dart';
import 'package:mornye/providers/player_motion_artwork_provider.dart';
import 'package:mornye/providers/runtime_profile_provider.dart';
import 'package:mornye/services/motion_artwork_store.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/widgets/audio_quality_badges.dart';
import 'package:mornye/widgets/mini_player.dart';
import 'package:mornye/widgets/overflow_marquee.dart';
import 'package:video_player/video_player.dart';

void main() {
  const longTitle = 'A long song title with enough words to leave the viewport';

  Future<void> pumpTitle(
    WidgetTester tester, {
    String title = longTitle,
    double width = 160,
    bool explicit = false,
    bool disableAnimations = false,
    bool tickersEnabled = true,
    TextDirection direction = TextDirection.ltr,
    CustomPainter? foregroundPainter,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: MediaQuery(
          data: MediaQueryData(disableAnimations: disableAnimations),
          child: Directionality(
            textDirection: direction,
            child: TickerMode(
              enabled: tickersEnabled,
              child: Center(
                child: SizedBox(
                  width: width,
                  child: OverflowMarquee(
                    resetKey: title,
                    child: CustomPaint(
                      foregroundPainter: foregroundPainter,
                      child: ExplicitTrackTitle(
                        title: title,
                        explicit: explicit,
                        style: const TextStyle(fontSize: 16),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
  }

  ScrollController controller(WidgetTester tester) => tester
      .widget<SingleChildScrollView>(find.byType(SingleChildScrollView))
      .controller!;

  Future<void> startScrolling(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 3));
    await tester.pump(const Duration(seconds: 1));
  }

  testWidgets('short titles stay still and schedule no animation', (
    tester,
  ) async {
    await pumpTitle(tester, title: 'RH YNO', explicit: true);
    await tester.pump(const Duration(seconds: 10));
    expect(controller(tester).position.maxScrollExtent, 0);
    expect(controller(tester).offset, 0);
    expect(find.byType(ExplicitBadge), findsOneWidget);
    expect(tester.binding.transientCallbackCount, 0);
  });

  testWidgets('long titles loop forward without reversing or a visible jump', (
    tester,
  ) async {
    await pumpTitle(tester, explicit: true);
    final scroll = controller(tester);
    await tester.pump(const Duration(milliseconds: 2500));
    expect(scroll.offset, 0);
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(seconds: 1));
    expect(scroll.offset, closeTo(28, 1));
    final titles = find.byType(ExplicitTrackTitle);
    expect(titles, findsNWidgets(2));
    final distance =
        tester.getTopLeft(titles.last).dx - tester.getTopLeft(titles.first).dx;
    final travelMs = (distance / 28 * 1000).round();
    await tester.pump(Duration(milliseconds: travelMs - 1000 - 10));
    expect(scroll.offset, greaterThan(distance - 1));
    final nextCopyPosition = tester.getTopLeft(titles.last);
    await tester.pump(const Duration(milliseconds: 11));
    await tester.pump();
    expect(scroll.offset, 0);
    expect(
      (tester.getTopLeft(titles.first) - nextCopyPosition).distance,
      lessThan(0.5),
    );
    expect(find.byType(ExplicitBadge), findsNWidgets(2));
    await tester.pump(const Duration(milliseconds: 2500));
    expect(scroll.offset, 0);
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(seconds: 1));
    expect(scroll.offset, closeTo(28, 1));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('track changes and compact widths restart at the beginning', (
    tester,
  ) async {
    await pumpTitle(tester);
    await startScrolling(tester);
    expect(controller(tester).offset, greaterThan(0));
    await pumpTitle(tester, width: 100);
    expect(controller(tester).offset, 0);
    await startScrolling(tester);
    expect(controller(tester).offset, greaterThan(0));
    await pumpTitle(tester, title: 'Next', width: 100);
    expect(controller(tester).offset, 0);
    await tester.pump(const Duration(seconds: 10));
    expect(controller(tester).offset, 0);
    expect(tester.binding.transientCallbackCount, 0);
  });

  testWidgets('scrolling retains text painting and track changes refresh it', (
    tester,
  ) async {
    final counter = _PaintCounter();
    await pumpTitle(tester, foregroundPainter: counter);
    await startScrolling(tester);
    final scroll = controller(tester);
    final start = scroll.offset;
    final paints = counter.paints;
    expect(start, greaterThan(0));
    for (var frame = 0; frame < 20; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(scroll.offset, greaterThan(start));
    expect(counter.paints, paints);

    await pumpTitle(
      tester,
      title: '$longTitle updated',
      foregroundPainter: counter,
    );
    expect(scroll.offset, 0);
    expect(counter.paints, greaterThan(paints));
    expect(find.text('$longTitle updated'), findsNWidgets(2));
    await startScrolling(tester);
    final updatedPaints = counter.paints;
    await tester.pump(const Duration(milliseconds: 100));
    expect(scroll.offset, greaterThan(28));
    expect(counter.paints, updatedPaints);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('reduced motion and hidden routes stop the marquee', (
    tester,
  ) async {
    await pumpTitle(tester);
    await startScrolling(tester);
    await pumpTitle(tester, disableAnimations: true);
    expect(find.byType(SingleChildScrollView), findsNothing);
    expect(
      tester
          .widget<ExplicitTrackTitle>(find.byType(ExplicitTrackTitle))
          .overflow,
      TextOverflow.ellipsis,
    );
    await tester.pump(const Duration(seconds: 10));
    expect(tester.binding.transientCallbackCount, 0);
    await pumpTitle(tester);
    await startScrolling(tester);
    expect(controller(tester).offset, greaterThan(0));
    await pumpTitle(tester, tickersEnabled: false);
    await tester.pump(const Duration(seconds: 10));
    expect(tester.binding.transientCallbackCount, 0);
  });

  testWidgets('backgrounding stops motion and resume waits before scrolling', (
    tester,
  ) async {
    await pumpTitle(tester);
    await startScrolling(tester);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    await tester.pump(const Duration(seconds: 10));
    expect(controller(tester).offset, 0);
    expect(tester.binding.transientCallbackCount, 0);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(controller(tester).offset, 0);
    await startScrolling(tester);
    expect(controller(tester).offset, greaterThan(0));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('bounded marquee rests at the start after its passes', (
    tester,
  ) async {
    Future<void> pumpBounded(String title, {int? maxCycles = 2}) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: SizedBox(
              width: 160,
              child: OverflowMarquee(
                resetKey: title,
                maxCycles: maxCycles,
                child: Text(
                  title,
                  maxLines: 1,
                  style: const TextStyle(fontSize: 16),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
    }

    await pumpBounded(longTitle);
    final scroll = controller(tester);
    final distance = scroll.position.maxScrollExtent;
    expect(distance, greaterThan(0));
    // Two passes of pause + travel, then nothing else is scheduled.
    var passes = 0;
    var moving = false;
    for (var i = 0; i < 600; i++) {
      await tester.pump(const Duration(milliseconds: 250));
      if (scroll.offset > 0) {
        moving = true;
      } else if (moving) {
        moving = false;
        passes++;
      }
    }
    expect(passes, 2);
    expect(controller(tester).offset, 0);
    expect(tester.binding.transientCallbackCount, 0);
    await tester.pump(const Duration(seconds: 10));
    expect(controller(tester).offset, 0);

    // Restoring full effects restarts a resting title without changing tracks.
    await pumpBounded(longTitle, maxCycles: null);
    await startScrolling(tester);
    expect(controller(tester).offset, greaterThan(0));

    // A new track starts a fresh count.
    await pumpBounded('$longTitle again');
    await startScrolling(tester);
    expect(controller(tester).offset, greaterThan(0));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('RTL titles scroll from the reading direction', (tester) async {
    await pumpTitle(tester, direction: TextDirection.rtl);
    expect(controller(tester).position.axisDirection, AxisDirection.left);
    await startScrolling(tester);
    expect(controller(tester).offset, greaterThan(0));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final liquid in [false, true]) {
    testWidgets(
      'Mornye mini player prepares the motion cover only with liquid glass '
      '(liquid: $liquid)',
      (tester) async {
        final prepared = <String>[];
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              currentMediaItemProvider.overrideWithBuild(
                (ref, notifier) => Stream.value(
                  const MediaItem(
                    id: 'track',
                    title: 'Song',
                    album: 'Album',
                    artist: 'Artist',
                  ),
                ),
              ),
              playbackStateProvider.overrideWith((ref) => const Stream.empty()),
              deviceSupportsLiquidGlassProvider.overrideWithValue(liquid),
              backdropBlurEnabledProvider.overrideWithValue(false),
              playerMotionArtworkProvider.overrideWith(
                (ref, album) async =>
                    const MotionArtwork('file:///cover.mp4', aspectRatio: 1),
              ),
              playerArtworkVideoProvider.overrideWith((ref, source) {
                prepared.add(source);
                return Completer<VideoPlayerController>().future;
              }),
            ],
            child: MaterialApp(
              theme: MornyeTheme.build(Brightness.dark),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: const Scaffold(
                body: Center(child: SizedBox(width: 320, child: MiniPlayer())),
              ),
            ),
          ),
        );
        for (var i = 0; i < 4; i++) {
          await tester.pump();
        }
        expect(find.text('Song'), findsWidgets);
        expect(prepared, liquid ? ['file:///cover.mp4'] : isEmpty);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  for (final liquid in [false, true]) {
    testWidgets('Mornye mini player rests title and artist after two passes '
        '(liquid: $liquid)', (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            currentMediaItemProvider.overrideWithBuild(
              (ref, notifier) => Stream.value(
                const MediaItem(
                  id: 'long-track',
                  title: longTitle,
                  artist: 'First artist, second artist and another artist',
                ),
              ),
            ),
            playbackStateProvider.overrideWith((ref) => const Stream.empty()),
            deviceSupportsLiquidGlassProvider.overrideWithValue(liquid),
            lowEndDeviceProvider.overrideWithValue(false),
            backdropBlurEnabledProvider.overrideWithValue(false),
          ],
          child: MaterialApp(
            theme: MornyeTheme.build(Brightness.dark),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: const Scaffold(
              body: Center(child: SizedBox(width: 320, child: MiniPlayer())),
            ),
          ),
        ),
      );
      for (var i = 0; i < 4; i++) {
        await tester.pump();
      }
      final scrolls = tester
          .widgetList<SingleChildScrollView>(
            find.descendant(
              of: find.byType(MiniPlayer),
              matching: find.byType(SingleChildScrollView),
            ),
          )
          .map((view) => view.controller!)
          .toList();
      expect(scrolls, hasLength(2));
      // The first pass still starts after the pause at the usual speed.
      await tester.pump(const Duration(seconds: 3));
      await tester.pump(const Duration(seconds: 1));
      for (final scroll in scrolls) {
        expect(scroll.offset, closeTo(28, 1));
      }
      final passes = [0, 0];
      final moving = [true, true];
      for (var i = 0; i < 600; i++) {
        await tester.pump(const Duration(milliseconds: 250));
        for (var j = 0; j < scrolls.length; j++) {
          if (scrolls[j].offset > 0) {
            moving[j] = true;
          } else if (moving[j]) {
            moving[j] = false;
            passes[j]++;
          }
        }
      }
      expect(passes, [2, 2]);
      for (final scroll in scrolls) {
        expect(scroll.offset, 0);
      }
      expect(tester.binding.transientCallbackCount, 0);
      expect(tester.binding.hasScheduledFrame, isFalse);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  for (final mornye in [false, true]) {
    for (final compact in [false, true]) {
      testWidgets(
        'mini player scrolls title and artist (Mornye: $mornye, compact: $compact)',
        (tester) async {
          await tester.pumpWidget(
            ProviderScope(
              overrides: [
                currentMediaItemProvider.overrideWithBuild(
                  (ref, notifier) => Stream.value(
                    const MediaItem(
                      id: 'long-track',
                      title: longTitle,
                      artist: 'First artist, second artist and another artist',
                      extras: {'explicit': true},
                    ),
                  ),
                ),
                playbackStateProvider.overrideWith(
                  (ref) => const Stream.empty(),
                ),
                lowEndDeviceProvider.overrideWithValue(true),
                backdropBlurEnabledProvider.overrideWithValue(false),
              ],
              child: MaterialApp(
                theme: mornye
                    ? MornyeTheme.build(Brightness.light)
                    : ThemeData(),
                localizationsDelegates: AppLocalizations.localizationsDelegates,
                supportedLocales: AppLocalizations.supportedLocales,
                home: Scaffold(
                  body: Center(
                    child: SizedBox(
                      width: 320,
                      child: MiniPlayer(compact: compact),
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.pump();
          await tester.pump();
          await tester.pump();
          await tester.pump();
          await startScrolling(tester);
          final scrollViews = tester.widgetList<SingleChildScrollView>(
            find.descendant(
              of: find.byType(MiniPlayer),
              matching: find.byType(SingleChildScrollView),
            ),
          );
          expect(scrollViews, hasLength(2));
          for (final view in scrollViews) {
            expect(view.controller!.offset, greaterThan(0));
          }
          expect(find.byType(ExplicitBadge), findsNWidgets(2));
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
        },
      );
    }
  }
}

class _PaintCounter extends CustomPainter {
  int paints = 0;

  @override
  void paint(Canvas canvas, Size size) => paints++;

  @override
  bool shouldRepaint(_PaintCounter oldDelegate) => false;
}
