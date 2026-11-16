import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/widgets/mornye_artwork_contrast.dart';
import 'package:mornye/widgets/mornye_player_background.dart';

/// Records in [reports] when the readings turn the dark layer on or off.
ValueChanged<double> changes(List<bool> reports) => (strength) {
  final on = strength > 0;
  if (on != (reports.isNotEmpty && reports.last)) reports.add(on);
};

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
                      onDim: changes(reports),
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
              onDim: changes(reports),
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

  test('the layer is only as strong as white labels need', () {
    expect(mornyeDimStrength(0), 0);
    expect(mornyeDimStrength(mornyeLabelBackgroundLuminance), 0);
    expect(mornyeDimStrength(1), 1);
    var previous = 0.0;
    for (var luminance = 0.0; luminance <= 1; luminance += 0.01) {
      final strength = mornyeDimStrength(luminance);
      expect(strength, greaterThanOrEqualTo(previous));
      previous = strength;
      if (strength == 0 || strength == 1) continue;
      // Dimmed, the background is about as light as the limit: no darker
      // than a step of the layer below it.
      final scale = 1 - strength * mornyeControlsDimAlpha;
      expect(
        luminance * math.pow(scale, 2.2),
        closeTo(mornyeLabelBackgroundLuminance, 0.03),
        reason: 'luminance $luminance',
      );
    }
  });

  testWidgets('the lightest region sets how strong the layer is', (
    tester,
  ) async {
    final header = GlobalKey();
    final controls = GlobalKey();
    final reports = <double>[];
    Widget app(Color top, Color bottom) => MaterialApp(
      home: Stack(
        fit: StackFit.expand,
        children: [
          MornyeArtworkContrast(
            enabled: true,
            targets: {'header': header, 'controls': controls},
            onDim: reports.add,
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
    expect(reports.last, 1);
    // A light region anywhere keeps the one layer on.
    await tester.pumpWidget(app(Colors.black, Colors.white));
    await sample();
    expect(reports.last, 1);
    await tester.pumpWidget(app(Colors.black, Colors.black));
    await sample();
    expect(reports.last, 0);
    final readings = reports.length;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pumpWidget(app(Colors.white, Colors.black));
    await sample();
    expect(reports, hasLength(readings));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    await sample();
    expect(reports, hasLength(greaterThan(readings)));
    expect(reports.last, 1);

    // A mid-tone cover stays as bright as it is: white reads on it, though
    // under 4.5:1.
    const teal = Color(0xff4f8f96);
    expect(1.05 / (teal.computeLuminance() + 0.05), inExclusiveRange(3.5, 4.5));
    await tester.pumpWidget(app(teal, teal));
    await sample();
    expect(reports.last, 0);

    // A light cover is dimmed as far as it needs, not all the way, rather
    // than given black labels.
    const silver = Color(0xffc0c0c0);
    await tester.pumpWidget(app(silver, Colors.black));
    await sample();
    expect(reports.last, inExclusiveRange(0.5, 0.9));
    expect(
      reports.last,
      closeTo(mornyeDimStrength(silver.computeLuminance()), 0.051),
    );
    await tester.pumpWidget(const SizedBox());
  });
}
