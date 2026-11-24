import 'dart:io';
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_color_utilities/hct/hct.dart';
import 'package:mornye/theme/app_theme.dart';
import 'package:mornye/theme/cover_palette.dart';
import 'package:mornye/theme/mornye_theme.dart';

double _chroma(Color color) => Hct.fromInt(color.toARGB32()).chroma;

/// Neutral grays still measure a little HCT chroma, so compare channels.
bool _isGray(Color color) => color.r == color.g && color.g == color.b;

void main() {
  test('only covers that read as gray count as grayscale', () {
    expect(isNearGrayscaleCover(const Color(0xff808080)), isTrue);
    expect(isNearGrayscaleCover(const Color(0xff141414)), isTrue);
    expect(isNearGrayscaleCover(const Color(0xff7d8085)), isTrue);
    expect(isNearGrayscaleCover(const Color(0xffd4ddac)), isFalse);
    expect(isNearGrayscaleCover(Colors.blue), isFalse);
  });

  testWidgets('a black and white cover gets a neutral scheme on request', (
    tester,
  ) async {
    late String gray;
    late ColorScheme tonal;
    late ColorScheme neutral;
    final cache = PaintingBinding.instance.imageCache;
    final directory = await tester.runAsync(
      () => Directory.systemTemp.createTemp('palette-gray-'),
    );
    addTearDown(() async {
      cache.clear();
      cache.clearLiveImages();
      await tester.runAsync(() => directory!.delete(recursive: true));
    });

    await tester.runAsync(() async {
      Future<String> write(String name, List<Color> stripes) async {
        final recorder = ui.PictureRecorder();
        final canvas = Canvas(recorder);
        for (var index = 0; index < stripes.length; index++) {
          canvas.drawRect(
            Rect.fromLTWH(index * 64.0 / stripes.length, 0, 64, 64),
            Paint()..color = stripes[index],
          );
        }
        final picture = recorder.endRecording();
        final image = await picture.toImage(64, 64);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        image.dispose();
        picture.dispose();
        final file = File('${directory!.path}/$name');
        await file.writeAsBytes(bytes!.buffer.asUint8List());
        return file.path;
      }

      gray = await write('gray.png', const [
        Color(0xff0a0a0a),
        Color(0xff8a8a8a),
        Color(0xfff2f2f2),
      ]);
      final blue = await write('blue.png', const [Colors.blue]);

      // No pixel clears Score's chroma filter, so the tonal scheme takes
      // Material's fallback hue. Mornye keeps it and shades from the source
      // colour instead.
      tonal = (await CoverPalette.resolve(gray, Brightness.dark))!;
      expect(_chroma(tonal.primary), greaterThan(12));
      neutral = (await CoverPalette.resolve(
        gray,
        Brightness.dark,
        neutralGrayscale: true,
      ))!;
      for (final role in [
        neutral.primary,
        neutral.primaryContainer,
        neutral.secondaryContainer,
        neutral.surface,
        neutral.surfaceContainer,
        neutral.onSurfaceVariant,
      ]) {
        expect(_isGray(role), isTrue, reason: '$role');
      }
      expect(CoverPalette.peek(gray, Brightness.dark), same(tonal));
      expect(
        CoverPalette.peek(gray, Brightness.dark, neutralGrayscale: true),
        same(neutral),
      );

      // A colourful cover keeps its tonal scheme either way.
      final colourful = await CoverPalette.resolve(blue, Brightness.dark);
      expect(
        await CoverPalette.resolve(
          blue,
          Brightness.dark,
          neutralGrayscale: true,
        ),
        same(colourful),
      );
    });

    // Material headers opt in; Mornye headers keep the tonal scheme.
    for (final (theme, expected) in [
      (AppTheme.dark(), neutral),
      (MornyeTheme.build(Brightness.dark), tonal),
    ]) {
      ColorScheme? built;
      await tester.pumpWidget(
        MaterialApp(
          // A fresh app, so the style does not tween in from the last one.
          key: ObjectKey(theme),
          theme: theme,
          home: CoverPaletteBuilder(
            imageSource: gray,
            builder: (context, scheme) {
              built = scheme;
              return const SizedBox();
            },
          ),
        ),
      );
      expect(built, same(expected));
    }
  });
}
