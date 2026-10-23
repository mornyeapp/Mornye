import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/theme/cover_palette.dart';
import 'package:mornye/widgets/mornye_player_background.dart';

const _width = 200.0;
const _height = 400.0;

/// The full-bleed composition before the artwork fade became an overlay: the
/// artwork masked into the background with a `ShaderMask`.
class _MaskedBackground extends StatelessWidget {
  const _MaskedBackground({
    required this.artUri,
    required this.artwork,
    required this.artworkAspectRatio,
    required this.fadeStart,
  });

  final Uri? artUri;
  final Widget? artwork;
  final double? artworkAspectRatio;
  final double fadeStart;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Theme(
      data: theme.copyWith(
        colorScheme: theme.colorScheme.copyWith(
          brightness: Brightness.dark,
          primary: const Color(0xff808080),
        ),
      ),
      child: CoverSourceColorBuilder(
        imageSource: artUri?.toFilePath(),
        builder: (context, sourceColor) {
          final dominant = HSLColor.fromColor(
            sourceColor ?? const Color(0xff808080),
          );
          final muted = dominant.withSaturation(
            dominant.saturation.clamp(0.0, 0.34),
          );
          final backdrop = dominant.withSaturation(
            dominant.saturation.clamp(0.0, 0.2),
          );
          const motion = Duration(milliseconds: 380);
          final size = MediaQuery.sizeOf(context);
          return AnimatedContainer(
            duration: motion,
            curve: Curves.easeInOutCubic,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: artwork == null
                    ? Alignment.topLeft
                    : Alignment.topCenter,
                end: artwork == null
                    ? Alignment.bottomRight
                    : Alignment.bottomCenter,
                stops: artwork == null ? null : const [0, 0.5, 1],
                colors: artwork == null
                    ? [
                        muted
                            .withLightness(0.28 + dominant.lightness * 0.24)
                            .toColor(),
                        muted
                            .withLightness(0.14 + dominant.lightness * 0.20)
                            .toColor(),
                      ]
                    : [
                        backdrop.withLightness(0.62).toColor(),
                        backdrop.withLightness(0.54).toColor(),
                        backdrop.withLightness(0.34).toColor(),
                      ],
              ),
            ),
            child: Stack(
              fit: StackFit.expand,
              children: [
                Positioned(
                  left: 0,
                  right: 0,
                  top: 0,
                  height: artworkAspectRatio == null
                      ? size.width
                      : (size.width / artworkAspectRatio!).clamp(
                          0.0,
                          size.height * 0.75,
                        ),
                  child: ShaderMask(
                    blendMode: BlendMode.dstIn,
                    shaderCallback: (bounds) => LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      stops: [0, fadeStart, 1],
                      colors: const [
                        Colors.white,
                        Colors.white,
                        Colors.transparent,
                      ],
                    ).createShader(bounds),
                    child: AnimatedSwitcher(
                      duration: motion,
                      switchInCurve: Curves.easeInOutCubic,
                      switchOutCurve: Curves.easeInOutCubic,
                      layoutBuilder: (current, previous) => Stack(
                        fit: StackFit.expand,
                        children: [...previous, ?current],
                      ),
                      child: artwork == null
                          ? null
                          : KeyedSubtree(
                              key: const ValueKey('full-player-artwork'),
                              child: artwork!,
                            ),
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

const _artwork = DecoratedBox(
  decoration: BoxDecoration(
    gradient: SweepGradient(
      colors: [
        Color(0xffff0000),
        Color(0xffffff00),
        Color(0xff00ff00),
        Color(0xff00ffff),
        Color(0xff0000ff),
        Color(0xffff00ff),
        Color(0xffff0000),
      ],
    ),
  ),
);

Future<Uri> _cover(Directory directory, Color color) async {
  final file = File('${directory.path}/${color.toARGB32()}.png');
  final recorder = ui.PictureRecorder();
  Canvas(recorder).drawColor(color, BlendMode.src);
  final picture = recorder.endRecording();
  final image = await picture.toImage(32, 32);
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  picture.dispose();
  await file.writeAsBytes(bytes!.buffer.asUint8List());
  await CoverPalette.resolveSourceColor(file.path);
  return file.uri;
}

void main() {
  const masked = ValueKey('masked');
  const overlay = ValueKey('overlay');

  Widget side(Key key, Widget child) => RepaintBoundary(
    key: key,
    child: SizedBox(
      width: _width,
      height: _height,
      child: MediaQuery(
        data: const MediaQueryData(size: Size(_width, _height)),
        child: child,
      ),
    ),
  );

  Widget pair({
    required Uri? artUri,
    required bool artwork,
    required double? ratio,
    required double fadeStart,
    double? overlayFadeStart,
  }) => Directionality(
    textDirection: TextDirection.ltr,
    child: Row(
      children: [
        side(
          masked,
          _MaskedBackground(
            artUri: artUri,
            artwork: artwork ? _artwork : null,
            artworkAspectRatio: ratio,
            fadeStart: fadeStart,
          ),
        ),
        side(
          overlay,
          MornyePlayerBackground(
            artUri: artUri,
            artwork: artwork ? _artwork : null,
            artworkAspectRatio: ratio,
            fadeStart: overlayFadeStart ?? fadeStart,
          ),
        ),
      ],
    ),
  );

  Future<Uint8List> pixels(WidgetTester tester, Key key) async =>
      (await tester.runAsync(() async {
        final image = await tester
            .renderObject<RenderRepaintBoundary>(find.byKey(key))
            .toImage();
        final data = await image.toByteData();
        image.dispose();
        return data!.buffer.asUint8List();
      }))!;

  Future<int> difference(WidgetTester tester) async {
    final expected = await pixels(tester, masked);
    final actual = await pixels(tester, overlay);
    var largest = 0;
    for (var index = 0; index < expected.length; index++) {
      final delta = (expected[index] - actual[index]).abs();
      if (delta > largest) largest = delta;
    }
    return largest;
  }

  setUp(() {
    final view =
        TestWidgetsFlutterBinding.instance.platformDispatcher.views.single;
    view.physicalSize = const Size(_width * 2, _height);
    view.devicePixelRatio = 1;
  });
  tearDown(
    () => TestWidgetsFlutterBinding.instance.platformDispatcher.views.single
        .reset(),
  );

  testWidgets('artwork fade matches the masked composite', (tester) async {
    final directory = Directory.systemTemp.createTempSync('player-fade-');
    addTearDown(() => directory.deleteSync(recursive: true));
    final covers = (await tester.runAsync(
      () => Future.wait([
        for (final color in const [
          Color(0xff1e8c7a),
          Color(0xfff28c28),
          Color(0xfff4f1e8),
          Color(0xff2a0a4a),
          Color(0xff050505),
          Color(0xffe8e010),
        ])
          _cover(directory, color),
      ]),
    ))!;
    final pairs = <(Uri?, Uri?)>[
      (covers[0], covers[1]),
      (covers[2], covers[3]),
      (covers[4], covers[5]),
      (null, covers[0]),
    ];
    final layouts = <(double?, double)>[(0.8, 0.58), (null, 0.72)];

    var largest = 0;
    Future<void> check(String label) async {
      final delta = await difference(tester);
      expect(delta, lessThanOrEqualTo(3), reason: label);
      if (delta > largest) largest = delta;
    }

    for (final (from, to) in pairs) {
      for (final (ratio, fadeStart) in layouts) {
        final label = '$from -> $to, ratio $ratio, fade $fadeStart';
        Future<void> show(Uri? cover, {required bool artwork}) =>
            tester.pumpWidget(
              pair(
                artUri: cover,
                artwork: artwork,
                ratio: ratio,
                fadeStart: fadeStart,
              ),
            );
        await show(from, artwork: true);
        await check('$label: settled');
        // The background colour lerps under a static artwork.
        await show(to, artwork: true);
        await tester.pump(const Duration(milliseconds: 150));
        await check('$label: colour lerp');
        await tester.pump(const Duration(seconds: 1));
        await check('$label: next track');
        // Lyrics: the gradient tilts while the artwork fades out.
        await show(to, artwork: false);
        await tester.pump(const Duration(milliseconds: 120));
        await check('$label: artwork fading out');
        await tester.pump(const Duration(milliseconds: 160));
        await check('$label: artwork almost gone');
        await tester.pump(const Duration(seconds: 1));
        await check('$label: lyrics');
        await show(from, artwork: true);
        await tester.pump(const Duration(milliseconds: 200));
        await check('$label: artwork fading in');
        await tester.pumpWidget(const SizedBox());
      }
    }
    debugPrint('largest channel difference: $largest');

    // The comparison does notice a different fade.
    await tester.pumpWidget(
      pair(
        artUri: covers[0],
        artwork: true,
        ratio: 0.8,
        fadeStart: 0.58,
        overlayFadeStart: 0.62,
      ),
    );
    expect(await difference(tester), greaterThan(3));
  });

  testWidgets('full-bleed artwork fades without an offscreen mask', (
    tester,
  ) async {
    Widget background({required bool artwork}) => Directionality(
      textDirection: TextDirection.ltr,
      child: side(
        overlay,
        MornyePlayerBackground(
          artUri: null,
          artwork: artwork ? _artwork : null,
        ),
      ),
    );
    final fade = find.descendant(
      of: find.byType(MornyePlayerBackground),
      matching: find.byType(CustomPaint),
    );

    await tester.pumpWidget(background(artwork: true));
    expect(find.byType(ShaderMask), findsNothing);
    expect(tester.layers.whereType<ShaderMaskLayer>(), isEmpty);
    expect(tester.renderObject(fade), paintsExactlyCountTimes(#saveLayer, 0));

    // Only the tilted gradient of the lyrics transition needs a layer.
    await tester.pumpWidget(background(artwork: false));
    await tester.pump(const Duration(milliseconds: 150));
    expect(tester.renderObject(fade), paintsExactlyCountTimes(#saveLayer, 1));
    await tester.pump(const Duration(seconds: 1));
    expect(fade, findsNothing);
  });
}
