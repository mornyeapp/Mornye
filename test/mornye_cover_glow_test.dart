import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mornye/widgets/cached_cover_image.dart';
import 'package:mornye/widgets/mornye_artwork_contrast.dart';
import 'package:mornye/widgets/mornye_cover_glow.dart';
import 'package:mornye/widgets/mornye_motion_glow.dart';
import 'package:mornye/widgets/mornye_player_background.dart';
import 'package:mornye/widgets/player_artwork.dart';

/// A one-colour cover file, decoded into the image cache the way the glow
/// asks for it.
Future<String> _cover(WidgetTester tester, Directory directory, Color color) =>
    tester
        .runAsync(() async {
          final file = File('${directory.path}/${color.toARGB32()}.png');
          final recorder = ui.PictureRecorder();
          Canvas(recorder).drawColor(color, BlendMode.src);
          final picture = recorder.endRecording();
          final image = await picture.toImage(32, 32);
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          image.dispose();
          picture.dispose();
          await file.writeAsBytes(bytes!.buffer.asUint8List());
          final provider = coverImageProvider(
            file.path,
            cacheWidth: PlayerArtwork.miniCacheWidth,
          )!;
          final stream = provider.resolve(ImageConfiguration.empty);
          final done = Completer<void>();
          late final ImageStreamListener listener;
          listener = ImageStreamListener((info, _) {
            info.dispose();
            stream.removeListener(listener);
            done.complete();
          });
          stream.addListener(listener);
          await done.future;
          return file.path;
        })
        .then((path) => path!);

void main() {
  late Directory directory;

  setUp(() {
    directory = Directory.systemTemp.createTempSync('cover-glow-');
    final view =
        TestWidgetsFlutterBinding.instance.platformDispatcher.views.single;
    view.physicalSize = const Size(400, 800);
    view.devicePixelRatio = 1;
  });
  tearDown(() {
    directory.deleteSync(recursive: true);
    TestWidgetsFlutterBinding.instance.platformDispatcher.views.single.reset();
  });

  /// Shows the glow and lets it read the cover's pixels.
  Future<void> pumpGlow(
    WidgetTester tester, {
    required String? artUri,
    bool visible = true,
    bool reducedMotion = false,
    double fadeStart = 0.72,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(disableAnimations: reducedMotion),
            child: MornyeCoverGlow(
              artUri: artUri,
              visible: visible,
              fadeStart: fadeStart,
            ),
          ),
        ),
      ),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump();
  }

  double opacity(WidgetTester tester) => tester
      .widget<AnimatedOpacity>(
        find.descendant(
          of: find.byType(MornyeCoverGlow),
          matching: find.byType(AnimatedOpacity),
        ),
      )
      .opacity;

  List<RawImage> layers(WidgetTester tester) =>
      tester.widgetList<RawImage>(find.byType(RawImage)).toList();

  Future<(ui.Image, Uint8List)> pixels(WidgetTester tester) async {
    final image = layers(tester).last.image!;
    final data = await tester.runAsync(
      () => image.toByteData(format: ui.ImageByteFormat.rawRgba),
    );
    return (image, data!.buffer.asUint8List());
  }

  List<int> pixel((ui.Image, Uint8List) drawn, int x, int y) {
    final (image, data) = drawn;
    final index = (y * image.width + x) * 4;
    return data.sublist(index, index + 4);
  }

  testWidgets('a cover ends in a soft copy, then its lower edge colour', (
    tester,
  ) async {
    final red = await _cover(tester, directory, const Color(0xffd02020));
    await pumpGlow(tester, artUri: red);
    await tester.pump();

    expect(opacity(tester), 1);
    expect(layers(tester), hasLength(1));
    // A square cover on a 400 dp page is 400 dp tall and fades from 72%.
    final glow = tester.getRect(find.byType(RawImage));
    expect(glow.top, 400 * 0.72);
    expect(glow.bottom, 800);

    // Drawn at a quarter of the physical pixels.
    final drawn = await pixels(tester);
    expect(drawn.$1.width, 100);
    expect(drawn.$1.height, 128);
    // The soft copy comes in from nothing at the top of the fade.
    expect(pixel(drawn, 50, 0)[3], lessThan(16));
    // The one colour is the cover shaded for the white labels.
    const shade = 1 - MornyeMotionGlow.colourShade;
    final bottom = pixel(drawn, 50, 127);
    expect(bottom[0], closeTo(0xd0 * shade, 3));
    expect(bottom[1], closeTo(0x20 * shade, 3));
    expect(bottom[2], closeTo(0x20 * shade, 3));
    expect(bottom[3], 255);
    // It is one colour across the page.
    expect(pixel(drawn, 0, 127), pixel(drawn, 99, 127));
  });

  testWidgets('a white cover gives a colour the dark layer clears', (
    tester,
  ) async {
    final white = await _cover(tester, directory, const Color(0xffffffff));
    await pumpGlow(tester, artUri: white);

    final bottom = pixel(await pixels(tester), 50, 127);
    // Under the controls' full dark layer white labels keep their 3.5:1.
    const kept = 1 - mornyeControlsDimAlpha;
    final dimmed = Color.fromARGB(
      255,
      (bottom[0] * kept).round(),
      (bottom[1] * kept).round(),
      (bottom[2] * kept).round(),
    ).computeLuminance();
    expect(dimmed, lessThanOrEqualTo(mornyeLabelBackgroundLuminance + 0.01));
    expect(dimmed, greaterThan(mornyeLabelBackgroundLuminance - 0.03));
  });

  testWidgets('no line is left where the soft copy ends', (tester) async {
    final white = await _cover(tester, directory, const Color(0xffffffff));
    // The fade is 114 dp, 28.5 pixels of the drawn image: its last row is
    // covered in half.
    await pumpGlow(tester, artUri: white, fadeStart: 0.715);

    final drawn = await pixels(tester);
    final colour = pixel(drawn, 50, drawn.$1.height - 1);
    // The soft copy is all but gone in its last row, and gone after it.
    for (var y = 28; y < 32; y++) {
      final row = pixel(drawn, 50, y);
      for (var channel = 0; channel < 3; channel++) {
        expect(
          row[channel],
          closeTo(colour[channel], y == 28 ? 3 : 1),
          reason: 'row $y',
        );
      }
    }
  });

  test('the one colour is the lower edge as the page shows it', () {
    // White above. The lower 30%: green at both sides, red then blue in
    // the middle.
    const width = 10, height = 10;
    final pixels = ByteData(width * height * 4);
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        final index = (y * width + x) * 4;
        final (red, green, blue) = y < 7
            ? (255, 255, 255)
            : x < 2 || x > 7
            ? (0, 200, 0)
            : x < 5
            ? (200, 0, 0)
            : (0, 0, 200);
        pixels
          ..setUint8(index, red)
          ..setUint8(index + 1, green)
          ..setUint8(index + 2, blue)
          ..setUint8(index + 3, 255);
      }
    }
    const shade = 1 - MornyeMotionGlow.colourShade;
    Color edge(Size artwork) => MornyeCoverGlow.lowerEdgeColour(
      pixels,
      width: width,
      height: height,
      artwork: artwork,
    );
    final square = edge(const Size(100, 100));
    expect(square.r * 255, closeTo(60 * shade, 0.5));
    expect(square.g * 255, closeTo(80 * shade, 0.5));
    expect(square.b * 255, closeTo(60 * shade, 0.5));
    // A tall page crops the sides: only the middle of the edge shows.
    final tall = edge(const Size(20, 100));
    expect(tall.r * 255, closeTo(100 * shade, 0.5));
    expect(tall.g, 0);
    expect(tall.b * 255, closeTo(100 * shade, 0.5));
  });

  testWidgets('a new cover fades in over the previous glow', (tester) async {
    final red = await _cover(tester, directory, const Color(0xffd02020));
    final blue = await _cover(tester, directory, const Color(0xff2040d0));
    await pumpGlow(tester, artUri: red);
    await tester.pump();
    final first = layers(tester).single.image;

    await pumpGlow(tester, artUri: blue);
    await tester.pump();

    expect(layers(tester), hasLength(2));
    expect(layers(tester).first.image, same(first));
    expect(layers(tester).last.image, isNot(same(first)));
    expect(layers(tester).last.opacity!.value, lessThan(1));

    await tester.pumpAndSettle();

    expect(layers(tester), hasLength(1));
    expect(layers(tester).single.opacity!.value, 1);
  });

  testWidgets('reduced motion swaps the glow at once', (tester) async {
    final red = await _cover(tester, directory, const Color(0xffd02020));
    final blue = await _cover(tester, directory, const Color(0xff2040d0));
    await pumpGlow(tester, artUri: red, reducedMotion: true);
    await tester.pump();

    await pumpGlow(tester, artUri: blue, reducedMotion: true);
    await tester.pump();

    expect(layers(tester), hasLength(1));
    expect(layers(tester).single.opacity!.value, 1);
  });

  testWidgets('behind lyrics it leaves and draws nothing new', (tester) async {
    final red = await _cover(tester, directory, const Color(0xffd02020));
    await pumpGlow(tester, artUri: red, visible: false);
    await tester.pump();

    expect(opacity(tester), 0);
    expect(layers(tester), isEmpty);

    await pumpGlow(tester, artUri: red);
    await tester.pump();

    expect(opacity(tester), 1);
    expect(layers(tester), hasLength(1));
  });

  testWidgets('a song without a cover keeps the plain fade', (tester) async {
    await pumpGlow(tester, artUri: null);
    await tester.pump();

    expect(opacity(tester), 0);
    expect(layers(tester), isEmpty);
  });
}
