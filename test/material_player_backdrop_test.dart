import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderRepaintBoundary;
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/routes/now_playing_route.dart';
import 'package:mornye/widgets/material_player_backdrop.dart';
import 'package:mornye/widgets/player_artwork.dart';

const _key = ValueKey('backdrop');
final _cached = find.byWidgetPredicate(
  (widget) => widget is RawImage && widget.fit == BoxFit.fill,
);
final _scheme = ColorScheme.fromSeed(seedColor: Colors.teal);

late File _cover;

Widget _app(Widget child) => MaterialApp(
  home: RepaintBoundary(key: _key, child: child),
);

Widget _backdrop({ColorScheme? scheme}) => _app(
  MaterialPlayerBackdrop(
    mediaItem: MediaItem(
      id: 'cover',
      title: 'Track',
      artUri: Uri.file(_cover.path),
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
    final artwork = find.byWidgetPredicate(
      (widget) => widget is PlayerArtwork && widget.cacheWidth == 160,
    );
    await _waitForCover(
      tester,
      find.descendant(
        of: artwork,
        matching: find.byWidgetPredicate(
          (widget) => widget is RawImage && widget.image != null,
        ),
      ),
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

    // A new surface colour draws a new image and releases the old one.
    await tester.pumpWidget(
      _backdrop(scheme: _scheme.copyWith(surface: Colors.black)),
    );
    final dark = _blur(tester);
    expect(dark, isNot(same(first)));
    expect(first.debugDisposed, isTrue);

    // So does a new size.
    tester.view.physicalSize = const Size(800, 400);
    await tester.pump();
    final landscape = _blur(tester);
    expect((landscape.width, landscape.height), (200, 100));
    expect(dark.debugDisposed, isTrue);
    expect(
      find.byType(Hero),
      findsNothing,
      reason: 'The landscape cover card owns the artwork Hero',
    );

    await tester.pumpWidget(const SizedBox());
    expect(landscape.debugDisposed, isTrue);
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
}
