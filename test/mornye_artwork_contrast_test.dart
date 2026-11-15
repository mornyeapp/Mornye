import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/widgets/mornye_artwork_contrast.dart';

void main() {
  for (final interruption in ['none', 'disabled', 'background', 'hidden']) {
    testWidgets(
      'static invalidation survives overlapping readback ($interruption)',
      (tester) async {
        final capture = GlobalKey();
        final target = GlobalKey();
        final captured = Completer<void>();
        final release = Completer<void>();
        var first = true;
        MornyeArtworkContrast.debugReadback = (boundary, scale) async {
          final image = await boundary.toImage(pixelRatio: scale);
          if (first) {
            first = false;
            captured.complete();
            await release.future;
          }
          return image;
        };
        addTearDown(() {
          MornyeArtworkContrast.debugReadback = null;
          if (!release.isCompleted) release.complete();
        });
        final reports = <bool>[];
        Widget app(Color color, {bool enabled = true, bool tickers = true}) =>
            MaterialApp(
              home: TickerMode(
                enabled: tickers,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    MornyeArtworkContrast(
                      key: capture,
                      enabled: enabled,
                      targets: {'header': target},
                      onDimChanged: reports.add,
                      child: ColoredBox(color: color),
                    ),
                    Positioned(
                      top: 20,
                      left: 20,
                      width: 80,
                      height: 20,
                      child: SizedBox(key: target),
                    ),
                  ],
                ),
              ),
            );
        Future<void> finishReadback() => tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 30)),
        );
        await tester.pumpWidget(app(Colors.black));
        await tester.runAsync(() => captured.future);
        await tester.pumpWidget(app(Colors.white));
        // Consume the only queued static invalidation while the old pixels
        // are still held, then finish without submitting another scene.
        await tester.pump(const Duration(milliseconds: 334));
        expect(MornyeArtworkContrast.debugReadbackCount(capture), 1);
        if (interruption == 'disabled') {
          await tester.pumpWidget(app(Colors.white, enabled: false));
        } else if (interruption == 'hidden') {
          await tester.pumpWidget(app(Colors.white, tickers: false));
        } else if (interruption == 'background') {
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.paused,
          );
        }
        release.complete();
        await finishReadback();
        // The held black frame needs no layer, whether or not it was read.
        expect(reports, isEmpty);
        await tester.pump(const Duration(milliseconds: 334));
        await finishReadback();
        if (interruption == 'none') {
          expect(MornyeArtworkContrast.debugReadbackCount(capture), 2);
          expect(reports, [true]);
        } else {
          expect(MornyeArtworkContrast.debugReadbackCount(capture), 1);
          if (interruption == 'disabled' || interruption == 'hidden') {
            await tester.pumpWidget(app(Colors.white));
          } else {
            tester.binding.handleAppLifecycleStateChanged(
              AppLifecycleState.resumed,
            );
          }
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 334));
          await finishReadback();
          expect(reports, [true]);
        }
        final settled = MornyeArtworkContrast.debugReadbackCount(capture);
        for (var frame = 0; frame < 4; frame++) {
          await tester.pump(const Duration(milliseconds: 334));
          await finishReadback();
        }
        expect(MornyeArtworkContrast.debugReadbackCount(capture), settled);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets('static artwork samples late decodes and geometry, then idles', (
    tester,
  ) async {
    final capture = GlobalKey();
    final target = GlobalKey();
    final targetTop = ValueNotifier(20.0);
    addTearDown(targetTop.dispose);
    final cache = PaintingBinding.instance.imageCache;
    addTearDown(() {
      cache.clear();
      cache.clearLiveImages();
    });
    final pending = Completer<ImageInfo>();
    final provider = FileImage(File('/delayed-contrast-cover.png'));
    cache.putIfAbsent(
      provider,
      () => OneFrameImageStreamCompleter(pending.future),
    );
    final reports = <bool>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Stack(
          fit: StackFit.expand,
          children: [
            MornyeArtworkContrast(
              key: capture,
              enabled: true,
              targets: {'header': target},
              onDimChanged: reports.add,
              child: RepaintBoundary(
                child: ColoredBox(
                  color: Colors.black,
                  child: Image(image: provider, fit: BoxFit.fill),
                ),
              ),
            ),
            ValueListenableBuilder<double>(
              valueListenable: targetTop,
              builder: (_, top, _) => Positioned(
                top: top,
                left: 20,
                width: 80,
                height: 20,
                child: SizedBox(key: target),
              ),
            ),
          ],
        ),
      ),
    );
    Future<void> sample() async {
      await tester.pump(const Duration(milliseconds: 334));
      // The test engine can take over 100 ms of real time to rasterize the
      // readback of a scene that draws the decoded cover.
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 300)),
      );
    }

    await sample();
    expect(reports, isEmpty);
    final initial = MornyeArtworkContrast.debugReadbackCount(capture);
    for (var i = 0; i < 4; i++) {
      await sample();
    }
    expect(MornyeArtworkContrast.debugReadbackCount(capture), initial);

    final image = await tester.runAsync(() async {
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      canvas.drawColor(Colors.black, BlendMode.src);
      canvas.drawRect(
        const Rect.fromLTWH(0, 0, 2, 1),
        Paint()..color = Colors.white,
      );
      final picture = recorder.endRecording();
      final image = await picture.toImage(2, 2);
      picture.dispose();
      return image;
    });
    pending.complete(ImageInfo(image: image!));
    await tester.pumpAndSettle();
    await sample();
    expect(reports, [true]);
    final decoded = MornyeArtworkContrast.debugReadbackCount(capture);
    expect(decoded, greaterThan(initial));
    await sample();
    expect(MornyeArtworkContrast.debugReadbackCount(capture), decoded);

    targetTop.value = 500;
    await tester.pump();
    await sample();
    expect(reports, [true, false]);
    expect(MornyeArtworkContrast.debugReadbackCount(capture), decoded + 1);
    await tester.pumpWidget(const SizedBox());
  });

  test('readback luminance matches Flutter exactly for every RGB pixel', () {
    for (var red = 0; red < 256; red++) {
      for (var green = 0; green < 256; green++) {
        for (var blue = 0; blue < 256; blue++) {
          final expected = Color.fromARGB(
            255,
            red,
            green,
            blue,
          ).computeLuminance();
          final actual = artworkPixelLuminance(red, green, blue);
          if (actual != expected) {
            fail('RGB($red, $green, $blue): $actual != $expected');
          }
        }
      }
    }
  });

  testWidgets('any region too light for white labels turns the layer on', (
    tester,
  ) async {
    final header = GlobalKey();
    final controls = GlobalKey();
    final reports = <bool>[];
    Widget app(Color top, Color bottom) => MaterialApp(
      home: Stack(
        fit: StackFit.expand,
        children: [
          MornyeArtworkContrast(
            enabled: true,
            targets: {'header': header, 'controls': controls},
            onDimChanged: reports.add,
            child: Column(
              children: [
                Expanded(
                  child: ColoredBox(color: top, child: const SizedBox.expand()),
                ),
                Expanded(
                  child: ColoredBox(
                    color: bottom,
                    child: const SizedBox.expand(),
                  ),
                ),
              ],
            ),
          ),
          Positioned(
            top: 20,
            left: 20,
            width: 100,
            height: 30,
            child: SizedBox(key: header),
          ),
          Positioned(
            bottom: 20,
            left: 20,
            width: 100,
            height: 30,
            child: SizedBox(key: controls),
          ),
        ],
      ),
    );
    Future<void> sample() async {
      await tester.pump(const Duration(milliseconds: 334));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 30)),
      );
    }

    await tester.pumpWidget(app(Colors.white, Colors.black));
    await sample();
    expect(reports, [true]);
    // A light region anywhere keeps the one layer on.
    await tester.pumpWidget(app(Colors.black, Colors.white));
    await sample();
    expect(reports, [true]);
    await tester.pumpWidget(app(Colors.black, Colors.black));
    await sample();
    expect(reports, [true, false]);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pumpWidget(app(Colors.white, Colors.black));
    await sample();
    expect(reports, [true, false]);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    await sample();
    expect(reports, [true, false, true]);

    // A muted pink frame gives white text under 4.5:1, so it is dimmed too
    // rather than given black labels.
    const pastel = Color(0xffa08398);
    expect(1.05 / (pastel.computeLuminance() + 0.05), lessThan(4.5));
    await tester.pumpWidget(app(pastel, pastel));
    await sample();
    expect(reports, [true, false, true]);

    // A gray between the two thresholds keeps whichever state it finds.
    const dark = Color(0xff606060);
    const between = Color(0xff727272);
    const light = Color(0xff808080);
    expect(between.computeLuminance(), inExclusiveRange(0.16, 0.18));
    reports.clear();
    await tester.pumpWidget(app(dark, dark));
    await sample();
    expect(reports, [false]);
    await tester.pumpWidget(app(between, dark));
    await sample();
    expect(reports, [false]);
    await tester.pumpWidget(app(light, dark));
    await sample();
    expect(reports, [false, true]);
    await tester.pumpWidget(app(between, dark));
    await sample();
    expect(reports, [false, true]);
    await tester.pumpWidget(app(dark, dark));
    await sample();
    expect(reports, [false, true, false]);
    await tester.pumpWidget(const SizedBox());
  });
}
