import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/widgets/settled_blur.dart';

const _capture = ValueKey('capture');

/// Red and blue halves split by a white band, with a theme-coloured strip,
/// so a blur of the wrong size or resolution shows.
class _Pattern extends StatelessWidget {
  const _Pattern({this.color = Colors.red});

  final Color color;

  @override
  Widget build(BuildContext context) => Stack(
    fit: StackFit.expand,
    children: [
      Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(child: ColoredBox(color: color)),
          const Expanded(child: ColoredBox(color: Colors.blue)),
        ],
      ),
      const Center(
        child: SizedBox(
          height: 24,
          width: double.infinity,
          child: ColoredBox(color: Colors.white),
        ),
      ),
      Align(
        alignment: Alignment.bottomCenter,
        child: SizedBox(
          height: 40,
          width: double.infinity,
          child: ColoredBox(color: Theme.of(context).colorScheme.surface),
        ),
      ),
    ],
  );
}

/// A cover that shows a placeholder until [arrive], then fades its image in
/// over 500 ms on top, the way the cached network image does.
class _FadingCover extends StatefulWidget {
  const _FadingCover({super.key});

  @override
  State<_FadingCover> createState() => _FadingCoverState();
}

class _FadingCoverState extends State<_FadingCover>
    with SingleTickerProviderStateMixin {
  late final _fade = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 500),
  );
  bool _arrived = false;

  void arrive() {
    setState(() => _arrived = true);
    _fade.forward();
  }

  @override
  void dispose() {
    _fade.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Stack(
    fit: StackFit.expand,
    children: [
      const ColoredBox(color: Colors.grey),
      if (_arrived)
        FadeTransition(
          opacity: CurvedAnimation(parent: _fade, curve: Curves.easeOut),
          child: const _Pattern(),
        ),
    ],
  );
}

Widget _scene(
  Widget child, {
  double sigma = 32,
  double resolution = 0.25,
  double devicePixelRatio = 2,
  double width = 200,
  Brightness brightness = Brightness.light,
  ValueNotifier<double>? offset,
  ValueNotifier<bool>? visible,
  bool playing = false,
}) => MaterialApp(
  theme: ThemeData(brightness: brightness),
  themeAnimationDuration: Duration.zero,
  home: Builder(
    builder: (context) => MediaQuery(
      data: MediaQuery.of(context).copyWith(devicePixelRatio: devicePixelRatio),
      child: Align(
        alignment: Alignment.topLeft,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            RepaintBoundary(
              key: _capture,
              child: ColoredBox(
                color: Colors.black,
                child: ValueListenableBuilder<double>(
                  valueListenable: offset ?? ValueNotifier(0),
                  builder: (context, offset, child) => Transform.translate(
                    offset: Offset(0, offset),
                    child: child,
                  ),
                  child: ValueListenableBuilder<bool>(
                    valueListenable: visible ?? ValueNotifier(true),
                    builder: (context, visible, child) =>
                        Opacity(opacity: visible ? 1 : 0, child: child),
                    child: ClipRect(
                      child: SizedBox(
                        width: width,
                        height: 240,
                        child: SettledBlur(
                          sigma: sigma,
                          resolution: resolution,
                          child: child,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            // Stands in for the playing mini player, which draws a frame
            // every 33 ms on every Material screen.
            if (playing)
              const SizedBox(width: 100, child: LinearProgressIndicator()),
          ],
        ),
      ),
    ),
  ),
);

RenderSettledBlur _render(WidgetTester tester) =>
    tester.renderObject<RenderSettledBlur>(find.byType(SettledBlur));

ui.Image? _image(WidgetTester tester) => _render(tester).debugImage;

/// Whether the last frame composited a live blur below the widget.
bool _blursLive(WidgetTester tester) {
  var found = false;
  void visit(Layer layer) {
    if (layer is ImageFilterLayer) found = true;
    if (layer is ContainerLayer) {
      for (
        var child = layer.firstChild;
        child != null;
        child = child.nextSibling
      ) {
        visit(child);
      }
    }
  }

  visit(_render(tester).debugLayer!);
  return found;
}

/// Draws a frame that something else on screen asked for, such as a scroll
/// or the playing mini player.
Future<void> _frame(WidgetTester tester) {
  tester.binding.scheduleFrame();
  return tester.pump();
}

/// Pumps [scene], checks that it blurs live, that the next unchanged frame
/// rasterizes it and that the frame it requests draws only the image.
Future<ui.Image> _settle(WidgetTester tester, Widget scene) async {
  await tester.pumpWidget(scene);
  return _settleFrames(tester);
}

Future<ui.Image> _settleFrames(WidgetTester tester) async {
  expect(_image(tester), isNull);
  expect(_blursLive(tester), isTrue);
  await _frame(tester);
  final image = _image(tester);
  expect(image, isNotNull, reason: 'An unchanged frame rasterizes the blur');
  expect(tester.binding.hasScheduledFrame, isTrue);
  await tester.pump();
  expect(_blursLive(tester), isFalse);
  expect(_image(tester), same(image));
  return image!;
}

Future<Uint8List> _pixels(WidgetTester tester, double pixelRatio) async =>
    (await tester.runAsync(() async {
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(_capture),
      );
      final image = await boundary.toImage(pixelRatio: pixelRatio);
      try {
        return (await image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        ))!.buffer.asUint8List();
      } finally {
        image.dispose();
      }
    }))!;

double _meanDifference(Uint8List a, Uint8List b) {
  expect(a.length, b.length);
  var sum = 0;
  for (var i = 0; i < a.length; i++) {
    sum += (a[i] - b[i]).abs();
  }
  return sum / a.length;
}

void main() {
  testWidgets('blurs live, then draws one image once a frame shows it '
      'unchanged', (tester) async {
    final image = await _settle(tester, _scene(const _Pattern()));
    // A quarter of the 200 x 240 dp at 2x in each direction.
    expect((image.width, image.height), (100, 120));
    expect(tester.binding.hasScheduledFrame, isFalse);
  });

  testWidgets('moving it and frames elsewhere reuse the image', (tester) async {
    final offset = ValueNotifier<double>(0);
    addTearDown(offset.dispose);
    final image = await _settle(
      tester,
      _scene(const _Pattern(), offset: offset, playing: true),
    );
    for (var frame = 1; frame <= 60; frame++) {
      if (frame <= 20) offset.value = frame * 2;
      await tester.pump(const Duration(milliseconds: 33));
      expect(_image(tester), same(image));
      expect(_blursLive(tester), isFalse);
    }
    expect(image.debugDisposed, isFalse);
  });

  // One child instance, so only the named input changes.
  const child = _Pattern();
  final changes = <String, Widget>{
    'child': _scene(const _Pattern(color: Colors.amber)),
    'theme brightness': _scene(child, brightness: Brightness.dark),
    'sigma': _scene(child, sigma: 24),
    'resolution': _scene(child, resolution: 0.5),
    'device pixel ratio': _scene(child, devicePixelRatio: 3),
    'size': _scene(child, width: 160),
  };
  testWidgets('a rebuild with the same inputs keeps the image', (tester) async {
    final image = await _settle(tester, _scene(child));
    await tester.pumpWidget(_scene(child));
    await _frame(tester);
    expect(_image(tester), same(image));
    expect(_blursLive(tester), isFalse);
  });

  for (final MapEntry(key: input, value: changed) in changes.entries) {
    testWidgets('a $input change replaces the image', (tester) async {
      final before = await _settle(tester, _scene(child));
      await tester.pumpWidget(changed);
      expect(before.debugDisposed, isTrue);
      final after = await _settleFrames(tester);
      expect(after, isNot(same(before)));
    });
  }

  testWidgets('a rebuilt child replaces the image', (tester) async {
    final before = await _settle(tester, _scene(const _Pattern()));
    // Equal but not identical: a rebuild may change a nested layer that
    // never reports a repaint here.
    // ignore: prefer_const_constructors
    await tester.pumpWidget(_scene(_Pattern()));
    expect(before.debugDisposed, isTrue);
    await _settleFrames(tester);
  });

  testWidgets('keeps blurring live while the child keeps changing', (
    tester,
  ) async {
    await _settle(tester, _scene(child));
    for (var frame = 0; frame < 4; frame++) {
      await tester.pumpWidget(_scene(child, width: 150 + frame * 10.0));
      expect(_image(tester), isNull);
      expect(_blursLive(tester), isTrue);
    }
    await _settleFrames(tester);
  });

  testWidgets('a fading cover settles only once its fade ends', (tester) async {
    final cover = GlobalKey<_FadingCoverState>();
    final placeholder = await _settle(tester, _scene(_FadingCover(key: cover)));

    cover.currentState!.arrive();
    await tester.pump();
    expect(placeholder.debugDisposed, isTrue);
    // The fade runs inside its own layer, which repaints nothing here.
    for (var elapsed = 100; elapsed <= 500; elapsed += 100) {
      await tester.pump(const Duration(milliseconds: 100));
      expect(_image(tester), isNull, reason: 'fading at $elapsed ms');
      expect(_blursLive(tester), isTrue);
    }
    final faded = await _settleFrames(tester);

    // The image holds the finished fade: the same as the plain pattern.
    final fadedPixels = await _pixels(tester, 2);
    await _settle(tester, _scene(const _Pattern()));
    expect(await _pixels(tester, 2), fadedPixels);
    expect(faded.debugDisposed, isTrue);
  });

  testWidgets('a blur hidden before it settles settles once shown', (
    tester,
  ) async {
    final visible = ValueNotifier(true);
    addTearDown(visible.dispose);
    await tester.pumpWidget(_scene(child, visible: visible));
    visible.value = false;
    for (var frame = 0; frame < 3; frame++) {
      await _frame(tester);
      expect(_image(tester), isNull);
    }
    expect(tester.binding.hasScheduledFrame, isFalse);

    visible.value = true;
    await tester.pump();
    await _settleFrames(tester);
  });

  testWidgets('a texture keeps the blur live without extra frames', (
    tester,
  ) async {
    await tester.pumpWidget(
      _scene(
        const Stack(
          fit: StackFit.expand,
          children: [_Pattern(), Texture(textureId: 7)],
        ),
      ),
    );
    for (var frame = 0; frame < 4; frame++) {
      await _frame(tester);
      expect(_image(tester), isNull);
      expect(_blursLive(tester), isTrue);
    }
    expect(tester.binding.hasScheduledFrame, isFalse);
  });

  testWidgets('a zero sigma paints the child without an image', (tester) async {
    await tester.pumpWidget(_scene(child, sigma: 0));
    for (var frame = 0; frame < 3; frame++) {
      await _frame(tester);
      expect(_image(tester), isNull);
      expect(_blursLive(tester), isFalse);
    }
    expect(tester.binding.hasScheduledFrame, isFalse);
  });

  testWidgets('a moved blur drops its image and settles again', (tester) async {
    final blur = GlobalKey();
    Widget build({required bool left}) => MaterialApp(
      home: Row(
        children: [
          for (final side in [true, false])
            SizedBox(
              width: 200,
              height: 240,
              child: side == left
                  ? SettledBlur(key: blur, sigma: 32, child: child)
                  : null,
            ),
        ],
      ),
    );

    final before = await _settle(tester, build(left: true));
    await tester.pumpWidget(build(left: false));
    expect(before.debugDisposed, isTrue);
    await _settleFrames(tester);
  });

  testWidgets('disposes its image when removed', (tester) async {
    final image = await _settle(tester, _scene(child));
    await tester.pumpWidget(const SizedBox());
    expect(image.debugDisposed, isTrue);
  });

  for (final dpr in [1.0, 3.0]) {
    testWidgets('the image matches the live blur at ${dpr}x', (tester) async {
      Future<Uint8List> live(double sigma) async {
        await tester.pumpWidget(const SizedBox());
        await tester.pumpWidget(
          _scene(child, sigma: sigma, devicePixelRatio: dpr),
        );
        expect(_blursLive(tester), isTrue);
        return _pixels(tester, dpr);
      }

      final reference = await live(32);
      await tester.pumpWidget(const SizedBox());
      await _settle(tester, _scene(child, devicePixelRatio: dpr));
      final difference = _meanDifference(await _pixels(tester, dpr), reference);
      // A blur a quarter smaller is a clearly different look; the image
      // stays well within that distance of the live blur.
      final smaller = _meanDifference(await live(24), reference);
      expect(difference, lessThan(1));
      expect(difference, lessThan(smaller / 4));
    });
  }
}
