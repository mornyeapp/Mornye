import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/screens/listening_rewind_screen.dart';
import 'package:mornye/services/listening_rewind.dart';
import 'package:mornye/services/listening_statistics.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/widgets/app_shape.dart';
import 'package:mornye/widgets/cached_cover_image.dart';
import 'package:mornye/widgets/decorative_phase.dart';
import 'package:mornye/widgets/settled_blur.dart';

const _size = Size(1080, 2400);
const _pixelRatio = 2.5;

Map<String, Object?> _row(
  String day,
  String key, {
  String artist = 'Artist',
  String album = 'Album',
  required int minutes,
}) => {
  'day': day,
  'track_key': key,
  'title': 'Song $key',
  'artist': artist,
  'album': album,
  'artwork': null,
  'milliseconds': minutes * 60000,
  'plays': 1,
};

/// The top song is by Other, so the top artist's slides show another cover.
ListeningRewind _rewind({required String songCover, String? artistCover}) {
  final base = ListeningSummary.fromRows([
    _row('2026-10-01', 'a', minutes: 40),
    _row('2026-10-02', 'b', minutes: 30),
    _row('2026-10-03', 'c', artist: 'Other', album: 'Else', minutes: 50),
    _row('2026-10-05', 'd', artist: 'Fresh', album: 'New', minutes: 5),
  ]);
  final covers = {'a': artistCover, 'c': songCover};
  return ListeningRewind.compute(
    range: ListeningRewindRange.of(
      ListeningRewindPeriod.weeks,
      DateTime(2026, 10, 14, 21),
    ),
    summary: ListeningSummary(
      milliseconds: base.milliseconds,
      plays: base.plays,
      tracks: [
        for (final total in base.tracks)
          ListeningTotal(
            ListeningTrack(
              key: total.track.key,
              title: total.track.title,
              artist: total.track.artist,
              album: total.track.album,
              artwork: covers[total.track.key],
            ),
            total.milliseconds,
            total.plays,
          ),
      ],
      artists: base.artists,
      days: base.days,
    ),
    previousMilliseconds: 100 * 60000,
  );
}

Future<String> _writeCover(Directory directory, String name, Color tint) async {
  const side = 256;
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(
    const Rect.fromLTWH(0, 0, 256, 256),
    Paint()..color = const Color(0xFF101828),
  );
  for (var i = 0; i < 8; i++) {
    canvas.drawRect(
      Rect.fromLTWH(i * 32.0, 0, 16, 256),
      Paint()..color = Color.lerp(tint, Colors.white, i / 8)!,
    );
    canvas.drawCircle(
      Offset(16 + i * 30.0, 40 + (i * 53 % 180)),
      26,
      Paint()..color = Color.lerp(Colors.amber, tint, i / 8)!,
    );
  }
  final image = await recorder.endRecording().toImage(side, side);
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  final file = File('${directory.path}/$name.png');
  await file.writeAsBytes(bytes!.buffer.asUint8List());
  return file.path;
}

Future<Uint8List> _rgba(ui.Image image) async {
  final bytes = await image.toByteData();
  image.dispose();
  return bytes!.buffer.asUint8List();
}

double _meanDifference(Uint8List a, Uint8List b) {
  expect(a.length, b.length);
  var total = 0;
  for (var i = 0; i < a.length; i++) {
    total += (a[i] - b[i]).abs();
  }
  return total / a.length;
}

void main() {
  late Directory directory;
  late String songCover;
  late String artistCover;
  late ValueNotifier<bool> reduced;
  late ValueNotifier<bool> tickers;

  setUp(() {
    reduced = ValueNotifier(false);
    tickers = ValueNotifier(true);
  });

  tearDown(() {
    DecorativePhase.debugResetClock();
    reduced.dispose();
    tickers.dispose();
  });

  Future<void> open(WidgetTester tester, {required bool mornye}) async {
    tester.view.physicalSize = _size;
    tester.view.devicePixelRatio = _pixelRatio;
    addTearDown(tester.view.reset);
    await tester.runAsync(() async {
      directory = await Directory.systemTemp.createTemp('rewind_backdrop_');
      songCover = await _writeCover(directory, 'song', Colors.deepPurple);
      artistCover = await _writeCover(directory, 'artist', Colors.teal);
    });
    addTearDown(() => directory.deleteSync(recursive: true));
    await tester.pumpWidget(const SizedBox());
    final context = tester.element(find.byType(SizedBox));
    await tester.runAsync(
      () => Future.wait([
        for (final cover in [songCover, artistCover])
          precacheImage(coverImageProvider(cover, cacheWidth: 200)!, context),
      ]),
    );
    final rewind = _rewind(songCover: songCover, artistCover: artistCover);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          listeningRewindProvider.overrideWith((ref, period) async => rewind),
        ],
        child: MaterialApp(
          theme: mornye ? MornyeTheme.build(Brightness.dark) : ThemeData(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (context, child) => ListenableBuilder(
            listenable: Listenable.merge([reduced, tickers]),
            builder: (context, _) => TickerMode(
              enabled: tickers.value,
              child: MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(disableAnimations: reduced.value),
                child: child!,
              ),
            ),
          ),
          home: const ListeningRewindScreen(
            period: ListeningRewindPeriod.weeks,
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('Your Rewind'), findsOneWidget);
  }

  Iterable<RenderSettledBlur> blurs(WidgetTester tester) =>
      tester.renderObjectList<RenderSettledBlur>(find.byType(SettledBlur));

  PageController pages(WidgetTester tester) =>
      tester.widget<PageView>(find.byType(PageView)).controller!;

  double progress(WidgetTester tester) => tester
      .widgetList<FractionallySizedBox>(find.byType(FractionallySizedBox))
      .firstWhere((widget) => widget.heightFactor == 1)
      .widthFactor!;

  testWidgets('Mornye blurs each slide cover once while it zooms and swipes', (
    tester,
  ) async {
    await open(tester, mornye: true);
    var frames = 0;
    var liveFrames = 0;
    final images = Set<ui.Image>.identity();
    Future<void> frame([
      Duration duration = const Duration(milliseconds: 16),
    ]) async {
      await tester.pump(duration);
      frames++;
      if (tester.layers.whereType<ImageFilterLayer>().isNotEmpty) liveFrames++;
      for (final blur in blurs(tester)) {
        if (blur.debugImage case final image?) images.add(image);
      }
    }

    final story = tester.getRect(find.byType(PageView));
    // Two seconds on the first slide, then tap to the next slide (same
    // cover) and to the top artist (another cover), with the zoom running.
    for (var i = 0; i < 120; i++) {
      await frame();
    }
    expect(images, hasLength(1));
    expect(blurs(tester).single.debugImage, same(images.single));
    for (var slide = 0; slide < 2; slide++) {
      await tester.tapAt(Offset(story.right - 40, story.center.dy));
      for (var i = 0; i < 40; i++) {
        await frame();
      }
    }
    expect(find.text('Your top artist'), findsOneWidget);
    // A slow manual swipe toward the next slide holds both covers' images.
    final gesture = await tester.startGesture(story.center);
    for (var i = 0; i < 30; i++) {
      await gesture.moveBy(const Offset(-8, 0));
      await frame();
    }
    await gesture.up();
    for (var i = 0; i < 40; i++) {
      await frame();
    }

    // The old backdrop blurred live on every frame (270 of 270).
    expect(frames, 270);
    expect(liveFrames, lessThanOrEqualTo(6));
    expect(images, hasLength(2));
    expect(tester.takeException(), isNull);
  });

  for (final mornye in [false, true]) {
    testWidgets(
      'the backdrop drift moves at 30 Hz on the same clock ($mornye)',
      (tester) async {
        await open(tester, mornye: mornye);
        // The Ken Burns zoom (Mornye) or the largest shape's pulse (Material).
        final transform = mornye
            ? find
                  .ancestor(
                    of: find.byType(SettledBlur),
                    matching: find.byType(Transform),
                  )
                  .first
            : find
                  .ancestor(
                    of: find.byType(AppShapeBadge).first,
                    matching: find.byType(Transform),
                  )
                  .first;
        // Drift phase in [0, 1) of the 24 s loop from the drawn scale.
        double phase() {
          final scale = tester.widget<Transform>(transform).transform[0];
          return mornye
              ? math.asin((scale - 1.15) / 0.06) / (2 * math.pi)
              : math.asin((scale - 1) / 0.05) / (4 * math.pi);
        }

        const step = Duration(microseconds: 8333);
        var elapsed = Duration.zero;
        var changes = 0;
        var previous = phase();
        for (var i = 0; i < 120; i++) {
          await tester.pump(step);
          elapsed += step;
          final value = phase();
          if (value != previous) changes++;
          previous = value;
          // Where the drift was 0 to 34 ms (one decorative tick) earlier.
          final at = value * 24e6;
          expect(at, lessThanOrEqualTo(elapsed.inMicroseconds + 1));
          expect(
            at,
            greaterThanOrEqualTo(
              elapsed.inMicroseconds -
                  DecorativePhase.interval.inMicroseconds -
                  step.inMicroseconds,
            ),
          );
        }
        // The old vsync drift changed on all 120 frames of the 120 Hz second.
        expect(changes, inInclusiveRange(28, 30));
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('the drift clock stops while paused, hidden, still or closed', (
    tester,
  ) async {
    await open(tester, mornye: false);
    expect(DecorativePhase.debugClockRunning, isTrue);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    expect(DecorativePhase.debugClockRunning, isFalse);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    expect(DecorativePhase.debugClockRunning, isTrue);

    tickers.value = false;
    await tester.pump();
    expect(DecorativePhase.debugClockRunning, isFalse);
    tickers.value = true;
    await tester.pump();
    expect(DecorativePhase.debugClockRunning, isTrue);

    reduced.value = true;
    await tester.pump();
    expect(DecorativePhase.debugClockRunning, isFalse);
    reduced.value = false;
    await tester.pump();
    expect(DecorativePhase.debugClockRunning, isTrue);

    await tester.pumpWidget(const SizedBox());
    expect(DecorativePhase.debugClockRunning, isFalse);
  });

  testWidgets('story progress redraws at 30 Hz without a vsync ticker', (
    tester,
  ) async {
    await open(tester, mornye: false);
    await tester.pump(const Duration(milliseconds: 1600));
    expect(tester.binding.transientCallbackCount, 0);

    var previous = progress(tester);
    var changes = 0;
    for (var i = 0; i < 120; i++) {
      await tester.pump(const Duration(microseconds: 8333));
      final value = progress(tester);
      if (value != previous) changes++;
      previous = value;
      expect(tester.binding.transientCallbackCount, 0);
    }
    expect(changes, inInclusiveRange(28, 30));
    expect(previous, closeTo(2.6 / 6, 0.006));
  });

  testWidgets('auto-advance keeps its six-second deadline', (tester) async {
    await open(tester, mornye: false);
    await tester.pump(const Duration(milliseconds: 5999));
    expect(pages(tester).page, 0);
    expect(pages(tester).position.isScrollingNotifier.value, isFalse);
    await tester.pump(const Duration(milliseconds: 1));
    expect(pages(tester).position.isScrollingNotifier.value, isTrue);
    await tester.pump(const Duration(seconds: 1));
    expect(pages(tester).page, 1);
    expect(progress(tester), 1);
  });

  testWidgets('holding pauses elapsed time and resumes the remaining time', (
    tester,
  ) async {
    await open(tester, mornye: false);
    await tester.pump(const Duration(seconds: 1));
    final gesture = await tester.startGesture(
      tester.getRect(find.byType(PageView)).center,
    );
    await tester.pump(const Duration(milliseconds: 600));
    final held = progress(tester);
    await tester.pump(const Duration(seconds: 10));
    expect(pages(tester).page, 0);
    expect(progress(tester), held);
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 4499));
    expect(pages(tester).position.isScrollingNotifier.value, isFalse);
    await tester.pump(const Duration(milliseconds: 1));
    expect(pages(tester).position.isScrollingNotifier.value, isTrue);
    await tester.pump(const Duration(seconds: 1));
    expect(pages(tester).page, 1);
  });

  for (final background in [false, true]) {
    testWidgets('hidden stories catch up on return ($background)', (
      tester,
    ) async {
      await open(tester, mornye: false);
      await tester.pump(const Duration(seconds: 1));
      if (background) {
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      } else {
        tickers.value = false;
      }
      await tester.pump();
      expect(DecorativePhase.debugClockRunning, isFalse);
      await tester.pump(const Duration(seconds: 10));
      expect(pages(tester).page, 0);
      if (background) {
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
      } else {
        tickers.value = true;
      }
      await tester.pump();
      await tester.pump(Duration.zero);
      await tester.pump(const Duration(seconds: 1));
      expect(pages(tester).page, 1);
      expect(DecorativePhase.debugClockRunning, isTrue);
    });
  }

  testWidgets('reduced motion stops advance and restarts from six seconds', (
    tester,
  ) async {
    await open(tester, mornye: false);
    await tester.pump(const Duration(seconds: 1));
    reduced.value = true;
    await tester.pump();
    await tester.pump(const Duration(seconds: 10));
    expect(pages(tester).page, 0);
    expect(progress(tester), 1);
    expect(DecorativePhase.debugClockRunning, isFalse);
    reduced.value = false;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 5999));
    expect(pages(tester).position.isScrollingNotifier.value, isFalse);
    await tester.pump(const Duration(milliseconds: 1));
    expect(pages(tester).position.isScrollingNotifier.value, isTrue);
  });

  testWidgets('sharing captures the live blur at full resolution', (
    tester,
  ) async {
    reduced.value = true;
    await open(tester, mornye: true);
    final temporary = Directory('${directory.path}/share')..createSync();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const paths = MethodChannel('plugins.flutter.io/path_provider');
    const share = MethodChannel('dev.fluttercommunity.plus/share');
    final shared = Completer<String>();
    messenger.setMockMethodCallHandler(paths, (_) async => temporary.path);
    messenger.setMockMethodCallHandler(share, (call) async {
      final arguments = call.arguments as Map;
      shared.complete((arguments['paths'] as List).single as String);
      return 'dev.fluttercommunity.plus/share/success';
    });
    addTearDown(() {
      messenger.setMockMethodCallHandler(paths, null);
      messenger.setMockMethodCallHandler(share, null);
    });

    await tester.pumpAndSettle();
    final story = tester.getRect(find.byType(PageView));
    while (find.text('Share').evaluate().isEmpty) {
      await tester.tapAt(Offset(story.right - 40, story.center.dy));
      await tester.pumpAndSettle();
    }
    final blur = blurs(tester).single;
    expect(blur.debugImage, isNotNull);
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find
          .ancestor(
            of: find.byType(PageView),
            matching: find.byType(RepaintBoundary),
          )
          .first,
    );
    Future<Uint8List> capture() async => (await tester.runAsync(
      () async => _rgba(await boundary.toImage(pixelRatio: _pixelRatio)),
    ))!;

    final settled = await capture();
    // Any new image resolution drops the settled image for one live frame.
    blur.pixelRatio = _pixelRatio / 2;
    await tester.pump();
    expect(blur.debugImage, isNull);
    final live = await capture();
    tester.binding.scheduleFrame();
    await tester.pumpAndSettle();
    expect(blur.debugImage, isNotNull);

    await tester.runAsync(() => tester.tap(find.text('Share')));
    await tester.pump();
    for (var attempt = 0; attempt < 100 && !shared.isCompleted; attempt++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
    }
    expect(shared.isCompleted, isTrue);
    final file = await shared.future;
    final image = await tester.runAsync(() async {
      final codec = await ui.instantiateImageCodec(
        await File(file).readAsBytes(),
      );
      return (await codec.getNextFrame()).image;
    });
    expect(image!.width, _size.width);
    expect(image.height, _size.height);
    final sharedPixels = (await tester.runAsync(() => _rgba(image)))!;
    expect(sharedPixels, live);
    // The settled image is the approved quarter-resolution blur.
    expect(_meanDifference(settled, live), lessThan(0.5));
    await tester.pumpAndSettle();
    expect(blur.debugImage, isNotNull);
    expect(tester.takeException(), isNull);
  });
}
