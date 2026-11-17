import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:audio_service/audio_service.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/rendering.dart'
    show ClipRectLayer, PictureLayer, RenderRepaintBoundary, ShaderMaskLayer;
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/routes/now_playing_route.dart';
import 'package:mornye/theme/app_motion.dart';
import 'package:mornye/widgets/material_player_backdrop.dart';
import 'package:mornye/widgets/player_artwork.dart';

const _key = ValueKey('backdrop');
final _cached = find.byWidgetPredicate(
  (widget) => widget is RawImage && widget.fit == BoxFit.fill,
);
final _scheme = ColorScheme.fromSeed(seedColor: Colors.teal);

late File _cover;
late File _noise;
late File _translucent;

MediaItem _item(File cover) =>
    MediaItem(id: cover.path, title: 'Track', artUri: Uri.file(cover.path));

/// One colour per pixel at an odd size, so any shift in how the cover is
/// sampled or masked shows up; [translucent] also varies the alpha.
Future<File> _writeNoise(Directory dir, {required bool translucent}) async {
  final random = math.Random(translucent ? 2 : 1);
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  for (var y = 0; y < 89; y++) {
    for (var x = 0; x < 97; x++) {
      canvas.drawRect(
        Rect.fromLTWH(x.toDouble(), y.toDouble(), 1, 1),
        Paint()
          ..color = Color.fromARGB(
            translucent ? 64 + random.nextInt(192) : 255,
            random.nextInt(256),
            random.nextInt(256),
            random.nextInt(256),
          ),
      );
    }
  }
  final image = await recorder.endRecording().toImage(97, 89);
  final png = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return File('${dir.path}/noise_$translucent.png')
    ..writeAsBytesSync(png!.buffer.asUint8List());
}

/// [MaterialPlayerBackdrop] as it drew the cover before the band mask: one
/// `ShaderMask` over the whole cover box. The blurred surface below it is
/// the widget's own.
class _WholeBoxMask extends StatelessWidget {
  const _WholeBoxMask({required this.mediaItem, required this.showArtwork});

  final MediaItem mediaItem;
  final bool showArtwork;

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final appBarHeight = MediaQuery.paddingOf(context).top + kToolbarHeight;
    // The same fade as the widget's own.
    final motion = AppMotion.effects(
      context,
      const AppMotionSpec(Duration.zero, Curves.linear),
    );
    return Stack(
      fit: StackFit.expand,
      children: [
        HeroMode(
          enabled: false,
          child: MaterialPlayerBackdrop(
            mediaItem: mediaItem,
            colorScheme: _scheme,
            showArtwork: false,
          ),
        ),
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          height: size.width < size.height * 0.56
              ? size.height * 0.56
              : size.width.clamp(0.0, size.height * 0.62),
          child: AnimatedOpacity(
            opacity: showArtwork ? 1 : 0,
            duration: motion.duration,
            curve: motion.curve,
            child: Hero(
              tag: kNowPlayingArtworkHeroTag,
              child: ShaderMask(
                blendMode: BlendMode.dstIn,
                shaderCallback: (bounds) => const LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  stops: [0, 0.72, 1],
                  colors: [Colors.white, Colors.white, Colors.transparent],
                ).createShader(bounds),
                child: PlayerArtwork(
                  artUri: mediaItem.artUri?.toString(),
                  colorScheme: _scheme,
                  cacheWidth: PlayerArtwork.transitionCacheWidth(context),
                ),
              ),
            ),
          ),
        ),
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          height: appBarHeight + 32,
          child: AnimatedOpacity(
            opacity: showArtwork ? 1 : 0,
            duration: motion.duration,
            curve: motion.curve,
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  stops: [0, appBarHeight / (appBarHeight + 32), 1],
                  colors: const [
                    Color(0x40000000),
                    Color(0x14000000),
                    Color(0x00000000),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

typedef _BuildBackdrop = Widget Function(MediaItem item, bool showArtwork);

/// Labels the frames captured while the cover fades for lyrics.
const _fading = 'fading to ';

Widget _bandMask(MediaItem item, bool showArtwork) => MaterialPlayerBackdrop(
  mediaItem: item,
  colorScheme: _scheme,
  showArtwork: showArtwork,
);

Widget _wholeBoxMask(MediaItem item, bool showArtwork) =>
    _WholeBoxMask(mediaItem: item, showArtwork: showArtwork);

/// Waits until the blur is cached and every image on screen has decoded.
Future<void> _waitForImages(WidgetTester tester) async {
  bool ready() =>
      _cached.evaluate().isNotEmpty &&
      tester
          .widgetList<RawImage>(find.byType(RawImage))
          .every((image) => image.image != null);
  for (var i = 0; i < 200 && !ready(); i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
    await tester.pump();
  }
  expect(ready(), isTrue);
}

/// The largest channel difference between two captures, and how many
/// channels differ at all.
({int max, int count}) _difference(Uint8List a, Uint8List b) {
  expect(a.length, b.length);
  var max = 0;
  var count = 0;
  for (var i = 0; i < a.length; i++) {
    final difference = (a[i] - b[i]).abs();
    if (difference == 0) continue;
    count++;
    if (difference > max) max = difference;
  }
  return (max: max, count: count);
}

/// What drawing the cover directly instead of through an 8-bit offscreen
/// copy may change: rounding, by at most one level in a channel. With an
/// opaque cover only a few channels are left where the offscreen's origin
/// rounded a sample differently; a translucent cover blends every pixel.
void _expectRounding(
  Uint8List band,
  Uint8List whole, {
  required bool opaque,
  String? reason,
}) {
  final difference = _difference(band, whole);
  expect(difference.max, lessThanOrEqualTo(1), reason: reason);
  if (opaque) {
    expect(difference.count, lessThan(band.length ~/ 5000), reason: reason);
  }
}

Widget _app(Widget child) => MaterialApp(
  home: RepaintBoundary(key: _key, child: child),
);

Widget _backdrop({ColorScheme? scheme, File? cover}) => _app(
  MaterialPlayerBackdrop(
    mediaItem: MediaItem(
      id: 'cover',
      title: 'Track',
      artUri: Uri.file((cover ?? _cover).path),
    ),
    colorScheme: scheme ?? _scheme,
    showArtwork: false,
  ),
);

/// The look before caching: the surface, the cover blurred live, the tint.
Widget _liveBlur(double sigma) => _app(
  Stack(
    fit: StackFit.expand,
    children: [
      ColoredBox(color: _scheme.surface),
      ImageFiltered(
        imageFilter: ui.ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
        child: Image(
          image: ResizeImage(
            FileImage(_cover),
            width: PlayerArtwork.miniCacheWidth,
          ),
          fit: BoxFit.cover,
        ),
      ),
      ColoredBox(color: _scheme.surface.withValues(alpha: 0.72)),
    ],
  ),
);

Future<void> _waitForCover(WidgetTester tester, Finder done) async {
  for (var i = 0; i < 200 && done.evaluate().isEmpty; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
    await tester.pump();
  }
  expect(done, findsOneWidget);
}

ui.Image _blur(WidgetTester tester) => tester.widget<RawImage>(_cached).image!;

Future<Uint8List> _capture(WidgetTester tester, double pixelRatio) async =>
    (await tester.runAsync(() async {
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(_key),
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
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    // Red and blue halves split by a white band: enough structure to show
    // how far the blur spreads.
    final recorder = ui.PictureRecorder();
    Canvas(recorder)
      ..drawRect(const Rect.fromLTWH(0, 0, 32, 64), Paint()..color = Colors.red)
      ..drawRect(
        const Rect.fromLTWH(32, 0, 32, 64),
        Paint()..color = Colors.blue,
      )
      ..drawRect(
        const Rect.fromLTWH(0, 28, 64, 8),
        Paint()..color = Colors.white,
      );
    final image = await recorder.endRecording().toImage(64, 64);
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    final dir = Directory.systemTemp.createTempSync('backdrop_test');
    _cover = File('${dir.path}/cover.png')
      ..writeAsBytesSync(png!.buffer.asUint8List());
    _noise = await _writeNoise(dir, translucent: false);
    _translucent = await _writeNoise(dir, translucent: true);
  });

  tearDownAll(() => _cover.parent.deleteSync(recursive: true));

  setUp(() {
    PaintingBinding.instance.imageCache
      ..clear()
      ..clearLiveImages();
  });

  testWidgets('the full-screen gradient stays on the cover during opening', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(160, 320);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final navigator = GlobalKey<NavigatorState>();
    final artUri = Uri.file(_cover.path).toString();
    await tester.pumpWidget(
      RepaintBoundary(
        key: _key,
        child: MaterialApp(
          navigatorKey: navigator,
          home: Align(
            alignment: Alignment.bottomLeft,
            child: SizedBox.square(
              dimension: 44,
              child: Hero(
                tag: kNowPlayingArtworkHeroTag,
                child: PlayerArtwork(
                  artUri: artUri,
                  colorScheme: _scheme,
                  cacheWidth: PlayerArtwork.miniCacheWidth,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    unawaited(
      navigator.currentState!.push(
        NowPlayingRoute(
          child: MaterialPlayerBackdrop(
            mediaItem: MediaItem(
              id: 'cover',
              title: 'Track',
              artUri: Uri.file(_cover.path),
            ),
            colorScheme: _scheme,
            showArtwork: true,
          ),
        ),
      ),
    );
    await tester.pump();
    await _waitForCover(tester, _cached);
    // Two copies of the cover share the box: one above the fade, one in it.
    final artwork = find
        .byWidgetPredicate(
          (widget) => widget is PlayerArtwork && widget.cacheWidth == 160,
        )
        .first;
    await _waitForCover(
      tester,
      find
          .descendant(
            of: artwork,
            matching: find.byWidgetPredicate(
              (widget) => widget is RawImage && widget.image != null,
            ),
          )
          .first,
    );

    Future<List<int>> fadePixel() async {
      final bounds = tester.getRect(artwork);
      final x = (bounds.left + bounds.width * 0.25).floor();
      final y = (bounds.top + bounds.height * 0.9).floor();
      final pixels = await _capture(tester, 1);
      return pixels.sublist((y * 160 + x) * 4, (y * 160 + x) * 4 + 4);
    }

    await tester.pump(const Duration(milliseconds: 390));
    final flying = await fadePixel();
    await tester.pump(const Duration(milliseconds: 50));
    final settled = await fadePixel();
    for (var channel = 0; channel < 4; channel++) {
      expect(flying[channel], closeTo(settled[channel], 5));
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('blurs live until the cover decodes, then draws it once', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_backdrop());
    expect(find.byType(ImageFiltered), findsOneWidget);
    await _waitForCover(tester, _cached);
    expect(find.byType(ImageFiltered), findsNothing);
    final first = _blur(tester);
    // A quarter of the 400 x 800 physical pixels in each direction.
    expect((first.width, first.height), (100, 200));

    // Frames and rebuilds with the same inputs reuse the image.
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpWidget(_backdrop(scheme: _scheme.copyWith()));
    expect(_blur(tester), same(first));
    expect(first.debugDisposed, isFalse);

    // A new surface colour, as each frame of the artwork scheme moving to
    // the next track's colours brings, keeps the image: the surface and
    // the tint are layers of their own.
    await tester.pumpWidget(
      _backdrop(scheme: _scheme.copyWith(surface: Colors.black)),
    );
    expect(_blur(tester), same(first));
    expect(first.debugDisposed, isFalse);
    final surfaces = tester
        .widgetList<ColoredBox>(find.byType(ColoredBox))
        .map((box) => box.color);
    expect(surfaces, contains(Colors.black));
    expect(surfaces, contains(Colors.black.withValues(alpha: 0.72)));

    // A new size draws a new image and releases the old one.
    tester.view.physicalSize = const Size(800, 400);
    await tester.pump();
    final landscape = _blur(tester);
    expect((landscape.width, landscape.height), (200, 100));
    expect(first.debugDisposed, isTrue);
    expect(
      find.byType(Hero),
      findsNothing,
      reason: 'The landscape cover card owns the artwork Hero',
    );

    await tester.pumpWidget(const SizedBox());
    expect(landscape.debugDisposed, isTrue);
  });

  testWidgets('a window resize stretches the blur and draws it once settled', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_backdrop());
    await _waitForCover(tester, _cached);
    final first = _blur(tester);
    expect((first.width, first.height), (200, 150));

    // Every frame of a live resize keeps the blur drawn for the first size.
    for (var frame = 1; frame <= 10; frame++) {
      tester.view.physicalSize = Size(800 + frame * 16, 600 + frame * 8);
      await tester.pump(const Duration(milliseconds: 16));
      expect(first.debugDisposed, isFalse, reason: 'frame $frame');
      expect(identical(_blur(tester), first), isTrue, reason: 'frame $frame');
    }
    expect(tester.getSize(_cached), const Size(960, 680));

    // Once the size settles, the blur is drawn for it.
    await tester.pump(const Duration(milliseconds: 200));
    final settled = _blur(tester);
    expect(settled, isNot(same(first)));
    expect((settled.width, settled.height), (240, 170));
    expect(first.debugDisposed, isTrue);
    await tester.pump(const Duration(seconds: 1));
    expect(_blur(tester), same(settled));

    await tester.pumpWidget(const SizedBox());
    expect(settled.debugDisposed, isTrue);
  });

  for (final dpr in [1.0, 3.0]) {
    testWidgets('cached blur matches the live blur at ${dpr}x', (tester) async {
      tester.view.physicalSize = Size(160 * dpr, 320 * dpr);
      tester.view.devicePixelRatio = dpr;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(_backdrop());
      await _waitForCover(tester, _cached);
      final cached = await _capture(tester, dpr);

      Future<Uint8List> live(double sigma) async {
        await tester.pumpWidget(_liveBlur(sigma));
        await _waitForCover(
          tester,
          find.byWidgetPredicate((w) => w is RawImage && w.image != null),
        );
        return _capture(tester, dpr);
      }

      final reference = await live(48);
      final difference = _meanDifference(cached, reference);
      // A blur a third smaller is a clearly different look; the cached
      // image stays well within that distance of the live blur.
      final smaller = _meanDifference(await live(32), reference);
      expect(difference, lessThan(1));
      expect(difference, lessThan(smaller / 4));
    });
  }

  for (final (physical, dpr) in [
    (const Size(160, 320), 1.0),
    (const Size(540, 1170), 3.0),
    (const Size(1080, 2340), 2.625),
    (const Size(800, 1000), 2.0),
  ]) {
    testWidgets('the band mask draws the whole-box mask at $physical, '
        '${dpr}x', (tester) async {
      tester.view.physicalSize = physical;
      tester.view.devicePixelRatio = dpr;
      addTearDown(tester.view.reset);

      for (final cover in [_cover, _noise, _translucent]) {
        Future<Uint8List> capture(_BuildBackdrop backdrop) async {
          await tester.pumpWidget(_app(backdrop(_item(cover), true)));
          await _waitForImages(tester);
          return _capture(tester, dpr);
        }

        _expectRounding(
          await capture(_bandMask),
          await capture(_wholeBoxMask),
          opaque: cover != _translucent,
          reason: cover.path,
        );
      }
    });
  }

  testWidgets('masks only the band of the cover the fade changes', (
    tester,
  ) async {
    const dpr = 2.625;
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = dpr;
    addTearDown(tester.view.reset);
    final box = Rect.fromLTWH(0, 0, 1080 / dpr, 2340 / dpr * 0.56);

    Future<ShaderMaskLayer> mask(_BuildBackdrop backdrop) async {
      await tester.pumpWidget(_app(backdrop(_item(_noise), true)));
      await _waitForImages(tester);
      final masks = tester.layers.whereType<ShaderMaskLayer>();
      expect(masks, hasLength(1));
      return masks.single;
    }

    expect((await mask(_wholeBoxMask)).maskRect, box);
    final layer = await mask(_bandMask);
    final band = layer.maskRect!;
    expect(band.left, 0);
    expect(band.right, box.right);
    expect(band.bottom, box.bottom);
    // On a whole device pixel, one or two above the first faded row: the
    // offscreen layer covers 28% of the box instead of all of it.
    final top = band.top * dpr;
    expect(top, closeTo(top.roundToDouble(), 1e-9));
    expect(
      top,
      inInclusiveRange(
        box.height * 0.72 * dpr - 2,
        box.height * 0.72 * dpr - 1,
      ),
    );
    expect(band.height / box.height, lessThan(0.282));

    // The masked copy draws nothing above the band, so the offscreen
    // layer holds the band alone. The cover's track change fade gives it
    // a layer of its own, so a clip layer bounds it to the band.
    final clip = layer.firstChild! as ClipRectLayer;
    expect(clip.clipRect, band);
    expect(
      clip.depthFirstIterateChildren().whereType<PictureLayer>(),
      isNotEmpty,
    );
  });

  testWidgets('a skip fades the sharp cover in without growing it', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_app(_bandMask(_item(_cover), true)));
    // Both copies of the cover, above the fade and in it, fade together.
    final covers = tester.widgetList<PlayerArtwork>(
      find.byWidgetPredicate(
        (widget) => widget is PlayerArtwork && widget.cacheWidth == 400,
      ),
    );
    expect(covers, hasLength(2));
    for (final cover in covers) {
      expect(cover.crossfade?.duration, greaterThan(Duration.zero));
      expect(cover.crossfadeScale, isNull);
    }
  });

  testWidgets('a new cover fades its blur in over the previous one', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_backdrop());
    await _waitForCover(tester, _cached);
    final first = _blur(tester);

    await tester.pumpWidget(_backdrop(cover: _noise));
    // The previous blur stays alone until the next cover decodes.
    expect(_blur(tester), same(first));
    for (var i = 0; i < 200 && _cached.evaluate().length < 2; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)),
      );
      await tester.pump();
    }
    final layers = tester.widgetList<RawImage>(_cached).toList();
    expect(layers, hasLength(2));
    expect(layers.first.image, same(first));
    final next = layers.last.image!;
    final fade = tester.widget<FadeTransition>(
      find
          .ancestor(
            of: find.byWidget(layers.last),
            matching: find.byType(FadeTransition),
          )
          .first,
    );
    expect(fade.opacity.value, lessThan(0.1));

    await tester.pump(const Duration(milliseconds: 100));
    expect(fade.opacity.value, inExclusiveRange(0.1, 1));
    expect(first.debugDisposed, isFalse);

    await tester.pumpAndSettle();
    expect(_blur(tester), same(next));
    expect(first.debugDisposed, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('reduced motion swaps the blur at once', (tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);

    await tester.pumpWidget(_backdrop());
    await _waitForCover(tester, _cached);
    final first = _blur(tester);

    await tester.pumpWidget(_backdrop(cover: _noise));
    for (var i = 0; i < 200 && identical(_blur(tester), first); i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)),
      );
      await tester.pump();
    }
    expect(_cached, findsOneWidget);
    expect(_blur(tester), isNot(same(first)));
    expect(first.debugDisposed, isTrue);
  });

  for (final dpr in [1.0, 3.0]) {
    for (final dragToClose in [false, true]) {
      testWidgets('the band mask draws the whole-box mask while opening, '
          'dragging, showing lyrics and closing by '
          '${dragToClose ? 'drag' : 'button'} at ${dpr}x', (tester) async {
        final logical = dpr == 1 ? const Size(160, 320) : const Size(120, 260);
        tester.view.physicalSize = logical * dpr;
        tester.view.devicePixelRatio = dpr;
        addTearDown(tester.view.reset);

        final band = await _transitionFrames(
          tester,
          _bandMask,
          dpr: dpr,
          pageHeight: logical.height,
          dragToClose: dragToClose,
        );
        final whole = await _transitionFrames(
          tester,
          _wholeBoxMask,
          dpr: dpr,
          pageHeight: logical.height,
          dragToClose: dragToClose,
        );
        expect(band.map((frame) => frame.$1), whole.map((frame) => frame.$1));
        for (final (index, (label, pixels)) in band.indexed) {
          final (_, reference) = whole[index];
          if (label.startsWith(_fading)) {
            // The opacity reaches the rows above the band directly instead
            // of through the offscreen copy: two roundings become one.
            expect(
              _difference(pixels, reference).max,
              lessThanOrEqualTo(2),
              reason: label,
            );
          } else {
            _expectRounding(pixels, reference, opaque: true, reason: label);
          }
        }
        expect(tester.takeException(), isNull);
      });
    }
  }
}

/// Opens the player over a mini player cover, drags it, shows and hides
/// lyrics, and closes it, capturing the screen along the way.
Future<List<(String, Uint8List)>> _transitionFrames(
  WidgetTester tester,
  _BuildBackdrop backdrop, {
  required double dpr,
  required double pageHeight,
  required bool dragToClose,
}) async {
  final navigator = GlobalKey<NavigatorState>();
  final showArtwork = ValueNotifier(true);
  addTearDown(showArtwork.dispose);
  final item = _item(_noise);
  await tester.pumpWidget(
    RepaintBoundary(
      key: _key,
      child: MaterialApp(
        navigatorKey: navigator,
        home: Align(
          alignment: Alignment.bottomLeft,
          child: SizedBox.square(
            dimension: 44,
            child: Hero(
              tag: kNowPlayingArtworkHeroTag,
              child: PlayerArtwork(
                artUri: item.artUri.toString(),
                colorScheme: _scheme,
                cacheWidth: PlayerArtwork.miniCacheWidth,
              ),
            ),
          ),
        ),
      ),
    ),
  );
  final route = NowPlayingRoute(
    child: ValueListenableBuilder(
      valueListenable: showArtwork,
      builder: (_, show, _) => backdrop(item, show),
    ),
  );
  final frames = <(String, Uint8List)>[];
  Future<void> capture(String label) async =>
      frames.add((label, await _capture(tester, dpr)));
  Future<void> captureEvery(
    String label,
    int milliseconds,
    int end, {
    bool fading = false,
  }) async {
    for (var time = 0; time < end; time += milliseconds) {
      await capture('${fading ? _fading : ''}$label $time ms');
      await tester.pump(Duration(milliseconds: milliseconds));
    }
    await tester.pumpAndSettle();
    await capture('$label settled');
  }

  unawaited(navigator.currentState!.push(route));
  await tester.pump();
  await _waitForImages(tester);
  await captureEvery('opening', 40, 400);

  route
    ..startDrag()
    ..updateDrag(
      DragUpdateDetails(
        globalPosition: Offset.zero,
        delta: const Offset(0, 37.3),
        primaryDelta: 37.3,
      ),
      pageHeight,
    );
  await tester.pump();
  await capture('dragged');
  if (dragToClose) {
    route.endDrag(
      DragEndDetails(
        velocity: const Velocity(pixelsPerSecond: Offset(0, 2000)),
        primaryVelocity: 2000,
      ),
      pageHeight,
    );
  } else {
    route.cancelDrag();
    await captureEvery('settling', 55, 220);
    showArtwork.value = false;
    await captureEvery('lyrics', 50, 300, fading: true);
    showArtwork.value = true;
    await captureEvery('cover', 75, 300, fading: true);
    navigator.currentState!.pop();
  }
  await tester.pump();
  await captureEvery('closing', 40, 300);
  return frames;
}
