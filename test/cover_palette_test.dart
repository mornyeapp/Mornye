import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/theme/cover_palette.dart';

void main() {
  ByteData pixels(List<(Color, int)> runs) {
    final data = ByteData(runs.fold(0, (sum, run) => sum + run.$2) * 4);
    var offset = 0;
    for (final (color, count) in runs) {
      for (var i = 0; i < count; i++, offset += 4) {
        data
          ..setUint8(offset, (color.r * 255).round())
          ..setUint8(offset + 1, (color.g * 255).round())
          ..setUint8(offset + 2, (color.b * 255).round())
          ..setUint8(offset + 3, 255);
      }
    }
    return data;
  }

  test('a dark cover with one clear colour keeps that colour, not gray', () {
    // Mostly black art with a pale avocado strip, as in issue #658.
    final color = coverSourceColor(
      pixels([
        (const Color(0xff050505), 65),
        (const Color(0xffd4ddac), 30),
        (const Color(0xff6a6e72), 5),
      ]),
    )!;
    final hsl = HSLColor.fromColor(color);
    expect(hsl.hue, inInclusiveRange(60, 80));
    expect(hsl.saturation, greaterThan(0.3));
  });

  test('a small colourful detail does not tint a neutral cover', () {
    final color = coverSourceColor(
      pixels([(const Color(0xff808080), 95), (const Color(0xffff0000), 5)]),
    )!;
    expect(HSLColor.fromColor(color).saturation, lessThan(0.1));
  });

  testWidgets(
    'same-path cover replacement refreshes palette and decoded image',
    (tester) async {
      await tester.runAsync(() async {
        final directory = await Directory.systemTemp.createTemp(
          'palette-replace-',
        );
        final file = File('${directory.path}/cover.png');
        final cache = PaintingBinding.instance.imageCache;
        Future<void> write(Color color) async {
          final recorder = ui.PictureRecorder();
          Canvas(
            recorder,
          ).drawRect(const Rect.fromLTWH(0, 0, 32, 32), Paint()..color = color);
          final picture = recorder.endRecording();
          final image = await picture.toImage(32, 32);
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          image.dispose();
          picture.dispose();
          await file.writeAsBytes(bytes!.buffer.asUint8List());
        }

        try {
          await write(Colors.blue);
          expect(
            (await CoverPalette.resolveSourceColor(file.path))?.toARGB32(),
            Colors.blue.toARGB32(),
          );
          final first = await CoverPalette.resolve(file.path, Brightness.light);
          expect(first, isNotNull);
          final oldKey = await CoverPalette.cacheKeyFor(
            file.path,
            Brightness.light,
          );
          // The small source-key lookup may evict a file while Flutter still
          // retains its decoded image. A later edit must stay fresh too.
          for (var index = 0; index < 33; index++) {
            await CoverPalette.resolve(
              '${directory.path}/missing-$index.png',
              Brightness.light,
            );
          }
          expect(CoverPalette.peek(file.path, Brightness.light), isNull);
          await write(Colors.red);
          await file.setLastModified(
            DateTime.now().add(const Duration(seconds: 1)),
          );
          expect(
            await CoverPalette.cacheKeyFor(file.path, Brightness.light),
            isNot(oldKey),
          );
          expect(
            (await CoverPalette.resolveSourceColor(file.path))?.toARGB32(),
            Colors.red.toARGB32(),
          );
          final second = await CoverPalette.resolve(
            file.path,
            Brightness.light,
          );
          expect(second, isNot(same(first)));
          expect(
            CoverPalette.sourceColor(file.path, Brightness.light)?.toARGB32(),
            Colors.red.toARGB32(),
          );
        } finally {
          cache.clear();
          cache.clearLiveImages();
          await directory.delete(recursive: true);
        }
      });
    },
  );

  testWidgets('palette requests share a small aspect-preserving decode', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final directory = await Directory.systemTemp.createTemp('palette-test-');
      final cache = PaintingBinding.instance.imageCache;
      cache.clear();
      cache.clearLiveImages();
      try {
        final recorder = ui.PictureRecorder();
        Canvas(recorder).drawRect(
          const Rect.fromLTWH(0, 0, 512, 256),
          Paint()..color = Colors.blue,
        );
        final picture = recorder.endRecording();
        final image = await picture.toImage(512, 256);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        image.dispose();
        picture.dispose();
        final file = File('${directory.path}/cover.png');
        await file.writeAsBytes(bytes!.buffer.asUint8List());

        final first = CoverPalette.resolve(file.path, Brightness.light);
        final second = CoverPalette.resolve(file.path, Brightness.light);
        expect(identical(first, second), isTrue);
        final scheme = await first;
        expect(scheme, isNotNull);
        expect(
          CoverPalette.sourceColor(file.path, Brightness.light)?.toARGB32(),
          Colors.blue.toARGB32(),
        );
        // The original is 512 x 256. Its cached decode fits inside 112 x 112
        // while preserving the 2:1 aspect ratio, instead of retaining 512 KiB.
        expect(cache.currentSizeBytes, 112 * 56 * 4);
        expect(
          await CoverPalette.resolve(file.path, Brightness.light),
          same(scheme),
        );
      } finally {
        cache.clear();
        cache.clearLiveImages();
        await directory.delete(recursive: true);
      }
    });
  });

  testWidgets('a file URI and its path share one palette entry', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final directory = await Directory.systemTemp.createTemp('palette-uri-');
      final cache = PaintingBinding.instance.imageCache;
      try {
        final recorder = ui.PictureRecorder();
        Canvas(recorder).drawColor(Colors.teal, BlendMode.src);
        final picture = recorder.endRecording();
        final image = await picture.toImage(32, 32);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        image.dispose();
        picture.dispose();
        final file = File('${directory.path}/cover.png');
        await file.writeAsBytes(bytes!.buffer.asUint8List());
        final uri = Uri.file(file.path).toString();

        expect(
          await CoverPalette.cacheKeyFor(uri, Brightness.light),
          await CoverPalette.cacheKeyFor(file.path, Brightness.light),
        );
        final scheme = await CoverPalette.resolve(uri, Brightness.light);
        expect(scheme, isNotNull);
        expect(CoverPalette.peek(file.path, Brightness.light), same(scheme));
        expect(
          (await CoverPalette.resolveSourceColor(uri))?.toARGB32(),
          Colors.teal.toARGB32(),
        );
        expect(
          CoverPalette.peekSourceColor(file.path)?.toARGB32(),
          Colors.teal.toARGB32(),
        );
      } finally {
        cache.clear();
        cache.clearLiveImages();
        await directory.delete(recursive: true);
      }
    });
  });

  testWidgets('source colour path matches the full palette bit for bit', (
    tester,
  ) async {
    // Seed and source colour each cover produced before the palette pipeline
    // moved into one background job, as (width, height, paint, seed, source).
    final covers = <String, (int, int, void Function(Canvas), int, int)>{
      'blue': (
        32,
        32,
        (canvas) => canvas.drawColor(Colors.blue, BlendMode.src),
        0xff2196f3,
        0xff2196f3,
      ),
      'dark with one colour': (
        100,
        100,
        (canvas) => canvas
          ..drawColor(const Color(0xff050505), BlendMode.src)
          ..drawRect(
            const Rect.fromLTWH(0, 0, 100, 30),
            Paint()..color = const Color(0xffd4ddac),
          )
          ..drawRect(
            const Rect.fromLTWH(0, 95, 100, 5),
            Paint()..color = const Color(0xff6a6e72),
          ),
        0xffd4ddac,
        0xffd4ddac,
      ),
      'gray stripes': (
        64,
        64,
        (canvas) {
          const stripes = [
            Color(0xff0a0a0a),
            Color(0xff8a8a8a),
            Color(0xfff2f2f2),
          ];
          for (var index = 0; index < stripes.length; index++) {
            canvas.drawRect(
              Rect.fromLTWH(index * 64 / 3, 0, 64, 64),
              Paint()..color = stripes[index],
            );
          }
        },
        0xff4285f4,
        0xff828282,
      ),
      'gray with a red detail': (
        100,
        100,
        (canvas) => canvas
          ..drawColor(const Color(0xff808080), BlendMode.src)
          ..drawCircle(const Offset(70, 30), 12, Paint()..color = Colors.red),
        0xfff44336,
        0xff7f7f7f,
      ),
      'wide gradient': (
        300,
        180,
        (canvas) => canvas.drawRect(
          const Rect.fromLTWH(0, 0, 300, 180),
          Paint()
            ..shader = const LinearGradient(
              colors: [
                Colors.red,
                Colors.orange,
                Colors.yellow,
                Colors.green,
                Colors.blue,
                Colors.purple,
              ],
            ).createShader(const Rect.fromLTWH(0, 0, 300, 180)),
        ),
        0xfff86321,
        0xfffda61b,
      ),
      'translucent': (
        80,
        120,
        (canvas) => canvas
          ..drawRect(
            const Rect.fromLTWH(0, 0, 80, 60),
            Paint()..color = const Color(0x99e91e63),
          )
          ..drawRect(
            const Rect.fromLTWH(0, 60, 40, 60),
            Paint()..color = const Color(0xff1a237e),
          ),
        0xff8c123b,
        0xffe91e62,
      ),
    };
    const backend = MethodChannel('com.zarz.mornye/backend');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    var paletteJobs = 0;
    messenger.setMockMethodCallHandler(backend, (call) async {
      if (call.method == 'runNativeDataJob') paletteJobs++;
      // Keep the host quantizer, as without a native backend.
      throw MissingPluginException();
    });
    addTearDown(() => messenger.setMockMethodCallHandler(backend, null));

    await tester.runAsync(() async {
      final directory = await Directory.systemTemp.createTemp('palette-same-');
      try {
        for (final MapEntry(
              key: name,
              value: (width, height, paint, seed, source),
            )
            in covers.entries) {
          final recorder = ui.PictureRecorder();
          paint(Canvas(recorder));
          final picture = recorder.endRecording();
          final image = await picture.toImage(width, height);
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          image.dispose();
          picture.dispose();
          final path = '${directory.path}/$name.png';
          await File(path).writeAsBytes(bytes!.buffer.asUint8List());

          final color = await CoverPalette.resolveSourceColor(path);
          expect(color?.toARGB32(), source, reason: name);
          expect(CoverPalette.peekSourceColor(path), color, reason: name);
          // No quantization and no scheme for this cover yet.
          expect(paletteJobs, 0, reason: name);
          for (final brightness in Brightness.values) {
            expect(CoverPalette.peek(path, brightness), isNull, reason: name);
          }

          for (final brightness in Brightness.values) {
            expect(
              await CoverPalette.resolve(path, brightness),
              ColorScheme.fromSeed(
                seedColor: Color(seed),
                brightness: brightness,
              ),
              reason: '$name ${brightness.name}',
            );
            expect(
              CoverPalette.sourceColor(path, brightness)?.toARGB32(),
              source,
              reason: name,
            );
          }
          expect(
            await CoverPalette.resolve(
              path,
              Brightness.dark,
              neutralGrayscale: true,
            ),
            isNearGrayscaleCover(Color(source))
                ? ColorScheme.fromSeed(
                    seedColor: Color(source),
                    brightness: Brightness.dark,
                    dynamicSchemeVariant: DynamicSchemeVariant.monochrome,
                  )
                : same(CoverPalette.peek(path, Brightness.dark)),
            reason: name,
          );
          expect(paletteJobs, 2, reason: name);
          paletteJobs = 0;
        }
      } finally {
        PaintingBinding.instance.imageCache.clear();
        PaintingBinding.instance.imageCache.clearLiveImages();
        await directory.delete(recursive: true);
      }
    });
  });

  testWidgets('source colour builder reads the cached colour', (tester) async {
    final directory = await tester.runAsync(
      () => Directory.systemTemp.createTemp('palette-builder-'),
    );
    addTearDown(() async {
      PaintingBinding.instance.imageCache.clear();
      PaintingBinding.instance.imageCache.clearLiveImages();
      await tester.runAsync(() => directory!.delete(recursive: true));
    });
    final path = '${directory!.path}/cover.png';
    await tester.runAsync(() async {
      final recorder = ui.PictureRecorder();
      Canvas(recorder).drawColor(Colors.green, BlendMode.src);
      final picture = recorder.endRecording();
      final image = await picture.toImage(16, 16);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      picture.dispose();
      await File(path).writeAsBytes(bytes!.buffer.asUint8List());
      await CoverPalette.resolveSourceColor(path);
    });

    for (final (source, expected) in [
      (path, Colors.green.toARGB32()),
      (null, null),
      ('', null),
    ]) {
      Color? built;
      await tester.pumpWidget(
        CoverSourceColorBuilder(
          imageSource: source,
          builder: (context, color) {
            built = color;
            return const SizedBox();
          },
        ),
      );
      expect(built?.toARGB32(), expected, reason: source);
    }
  });

  testWidgets('white and near-black artwork keeps a neutral source colour', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final directory = await Directory.systemTemp.createTemp('neutral-cover-');
      try {
        final recorder = ui.PictureRecorder();
        final canvas = Canvas(recorder);
        canvas.drawRect(
          const Rect.fromLTWH(0, 0, 100, 100),
          Paint()..color = Colors.white,
        );
        canvas.drawRect(
          const Rect.fromLTWH(50, 0, 50, 100),
          Paint()..color = const Color(0xff02020f),
        );
        final picture = recorder.endRecording();
        final image = await picture.toImage(100, 100);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        image.dispose();
        picture.dispose();
        final file = File('${directory.path}/monochrome.png');
        await file.writeAsBytes(bytes!.buffer.asUint8List());

        expect(
          await CoverPalette.resolve(file.path, Brightness.dark),
          isNotNull,
        );
        final color = CoverPalette.sourceColor(file.path, Brightness.dark)!;
        expect(color.r, color.g);
        expect(color.g, color.b);
        expect(color.r, inInclusiveRange(0.49, 0.52));
      } finally {
        PaintingBinding.instance.imageCache.clear();
        PaintingBinding.instance.imageCache.clearLiveImages();
        await directory.delete(recursive: true);
      }
    });
  });
}
