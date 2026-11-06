import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
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
        Map<String, Color> colors = {};
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
                      onChanged: (value) => colors = value,
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
        if (interruption != 'none') expect(colors, isEmpty);
        await tester.pump(const Duration(milliseconds: 334));
        await finishReadback();
        if (interruption == 'none') {
          expect(MornyeArtworkContrast.debugReadbackCount(capture), 2);
          expect(colors['header'], Colors.black);
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
          expect(colors['header'], Colors.black);
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
    Map<String, Color> colors = {};
    await tester.pumpWidget(
      MaterialApp(
        home: Stack(
          fit: StackFit.expand,
          children: [
            MornyeArtworkContrast(
              key: capture,
              enabled: true,
              targets: {'header': target},
              onChanged: (value) => colors = value,
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
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 30)),
      );
    }

    await sample();
    expect(colors['header'], Colors.white);
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
    expect(colors['header'], Colors.black);
    final decoded = MornyeArtworkContrast.debugReadbackCount(capture);
    expect(decoded, greaterThan(initial));
    await sample();
    expect(MornyeArtworkContrast.debugReadbackCount(capture), decoded);

    targetTop.value = 500;
    await tester.pump();
    await sample();
    expect(colors['header'], Colors.white);
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

  testWidgets('foreground follows changing frames separately for each region', (
    tester,
  ) async {
    final header = GlobalKey();
    final controls = GlobalKey();
    Map<String, Color> colors = {};
    var changes = 0;
    Widget app(Color top, Color bottom) => MaterialApp(
      home: Stack(
        fit: StackFit.expand,
        children: [
          MornyeArtworkContrast(
            enabled: true,
            targets: {'header': header, 'controls': controls},
            onChanged: (value) {
              colors = value;
              changes++;
            },
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
    expect(colors, {'header': Colors.black, 'controls': Colors.white});
    await tester.pumpWidget(app(Colors.black, Colors.white));
    await sample();
    expect(colors, {'header': Colors.white, 'controls': Colors.black});
    final previousChanges = changes;
    await sample();
    expect(changes, previousChanges);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pumpWidget(app(Colors.white, Colors.black));
    await sample();
    expect(changes, previousChanges);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    await sample();
    expect(colors, {'header': Colors.black, 'controls': Colors.white});

    // A muted pink frame still supports white player labels, including after
    // a bright frame temporarily required black labels.
    const pastel = Color(0xffa08398);
    await tester.pumpWidget(app(pastel, pastel));
    await sample();
    expect(colors, {'header': Colors.white, 'controls': Colors.white});
    final pastelChanges = changes;
    await tester.pumpWidget(app(const Color(0xff939393), pastel));
    await sample();
    expect(changes, pastelChanges);
    await tester.pumpWidget(app(Colors.white, pastel));
    await sample();
    expect(colors, {'header': Colors.black, 'controls': Colors.white});
    await tester.pumpWidget(app(const Color(0xff939393), pastel));
    await sample();
    expect(colors, {'header': Colors.black, 'controls': Colors.white});
    await tester.pumpWidget(app(pastel, pastel));
    await sample();
    expect(colors, {'header': Colors.white, 'controls': Colors.white});
    await tester.pumpWidget(const SizedBox());
  });
}
