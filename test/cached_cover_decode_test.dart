import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:mornye/utils/image_cache_utils.dart';
import 'package:mornye/widgets/cached_cover_image.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final override in [false, true]) {
    testWidgets('local thumbnail fade keeps its size in a row ($override)', (
      tester,
    ) async {
      final directory = await tester.runAsync(() async {
        final directory = await Directory.systemTemp.createTemp('cover-row-');
        await _writeCover(directory, const Size(128, 64));
        return directory;
      });
      try {
        await tester.runAsync(() async {
          await tester.pumpWidget(
            MaterialApp(
              home: Center(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    LocalOrNetworkCoverImage(
                      url: '${directory!.path}/cover.png',
                      width: 56,
                      height: 56,
                      localCacheWidth: override ? 112 : null,
                      fadeInDuration: const Duration(milliseconds: 180),
                      placeholder: (_) => const SizedBox.square(dimension: 56),
                    ),
                    const Text('Local song'),
                  ],
                ),
              ),
            ),
          );
          expect(tester.takeException(), isNull);
          expect(
            tester.getSize(find.byType(LocalOrNetworkCoverImage)),
            const Size(56, 56),
          );
          final provider = tester.widget<Image>(find.byType(Image)).image;
          await _decodedImageSize(provider);
        });
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(
          tester.getSize(find.byType(LocalOrNetworkCoverImage)),
          const Size(56, 56),
        );
      } finally {
        await tester.pumpWidget(const SizedBox());
        PaintingBinding.instance.imageCache.clear();
        PaintingBinding.instance.imageCache.clearLiveImages();
        await tester.runAsync(() => directory!.delete(recursive: true));
      }
    });
  }

  for (final source in [
    'network cover',
    'network backdrop',
    'local backdrop',
  ]) {
    testWidgets('metadata $source prewarm reuses the display bitmap', (
      tester,
    ) async {
      final cache = PaintingBinding.instance.imageCache;
      cache.clear();
      cache.clearLiveImages();
      late BuildContext context;
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(
              size: Size(393, 852),
              devicePixelRatio: 2,
            ),
            child: Builder(
              builder: (value) {
                context = value;
                return const SizedBox();
              },
            ),
          ),
        ),
      );
      final network = source != 'local backdrop';
      final backdrop = source != 'network cover';
      const url = 'https://example.invalid/metadata-prewarm.png';
      final ImageProvider provider = network
          ? cachedCoverImageProvider(url)
          : FileImage(File('/metadata-prewarm.png'));
      final width = backdrop
          ? metadataBackdropCacheExtent(context)
          : coverCacheWidthForViewport(context);
      final display = ResizeImage(
        provider,
        width: width,
        height: network ? null : width,
      );
      final key = await display.obtainKey(ImageConfiguration.empty);
      final image = await tester.runAsync(() async {
        final recorder = ui.PictureRecorder();
        Canvas(recorder).drawColor(Colors.blue, BlendMode.src);
        final picture = recorder.endRecording();
        final image = await picture.toImage(1, 1);
        picture.dispose();
        return image;
      });
      cache.putIfAbsent(
        key,
        () => OneFrameImageStreamCompleter(
          Future.value(ImageInfo(image: image!)),
        ),
      );
      await tester.pump();
      try {
        await tester.runAsync(() async {
          if (backdrop) {
            await precacheMetadataBackdrop(
              context,
              network ? url : '/metadata-prewarm.png',
            );
          } else {
            precacheCoverImage(context, url);
            await Future<void>.delayed(Duration.zero);
          }
        });
        expect(cache.statusForKey(key).live, isTrue);
        expect(cache.pendingImageCount, 0);
        expect(cache.currentSize, 1);
        await tester.pumpWidget(
          MaterialApp(
            home: network
                ? CachedCoverImage(
                    imageUrl: url,
                    memCacheWidth: width,
                    memCacheHeight: backdrop ? width : null,
                  )
                : Image.file(
                    File('/metadata-prewarm.png'),
                    cacheWidth: width,
                    cacheHeight: width,
                  ),
          ),
        );
        expect(tester.widget<RawImage>(find.byType(RawImage)).image, isNotNull);
        expect(cache.currentSize, 1);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox());
        cache.clear();
        cache.clearLiveImages();
      }
    });
  }

  for (final explicit in [false, true]) {
    testWidgets(
      'grid decode follows constraints, explicit override=$explicit',
      (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            home: MediaQuery(
              data: const MediaQueryData(devicePixelRatio: 2),
              child: Center(
                child: SizedBox.square(
                  dimension: 180,
                  child: CachedCoverImage(
                    imageUrl: 'https://example.invalid/cover.png',
                    memCacheWidth: explicit ? 1200 : null,
                    errorWidget: (_, _, _) => const SizedBox(),
                  ),
                ),
              ),
            ),
          ),
        );
        final image = tester.widget<CachedNetworkImage>(
          find.byType(CachedNetworkImage),
        );
        expect(image.memCacheWidth, explicit ? 1200 : 360);
        expect(image.memCacheHeight, isNull);
        expect(image.maxWidthDiskCache, isNull);
        expect(
          tester.getSize(find.byType(CachedCoverImage)),
          const Size(180, 180),
        );
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets('explicit height decode keeps one axis even with square bounds', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Center(
          child: CachedCoverImage(
            imageUrl: 'https://example.invalid/height-cover.png',
            width: 56,
            height: 56,
            memCacheHeight: 128,
          ),
        ),
      ),
    );
    final image = tester.widget<CachedNetworkImage>(
      find.byType(CachedNetworkImage),
    );
    expect(image.memCacheWidth, isNull);
    expect(image.memCacheHeight, 128);
    await tester.pumpWidget(const SizedBox());
  });

  for (final override in [false, true]) {
    testWidgets(
      'playlist thumbnail preserves network proportions ($override)',
      (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            home: MediaQuery(
              data: const MediaQueryData(devicePixelRatio: 2),
              child: Center(
                child: SizedBox.square(
                  dimension: 56,
                  child: LocalOrNetworkCoverImage(
                    url: 'https://example.invalid/playlist-cover.png',
                    width: 56,
                    height: 56,
                    networkCacheWidth: override ? 112 : null,
                    placeholder: (_) => const SizedBox(),
                  ),
                ),
              ),
            ),
          ),
        );
        final image = tester.widget<CachedNetworkImage>(
          find.byType(CachedNetworkImage),
        );
        expect(image.memCacheWidth, 112);
        expect(image.memCacheHeight, isNull);
        expect(image.fit, BoxFit.cover);
        expect(
          tester.getSize(find.byType(LocalOrNetworkCoverImage)),
          const Size(56, 56),
        );
        // Exercise the same Flutter decode sizing used by CachedNetworkImage,
        // with non-square artwork rather than checking only the widget bounds.
        final directory = await tester.runAsync(() async {
          final directory = await Directory.systemTemp.createTemp(
            'playlist-cover-',
          );
          await _writeCover(directory, const Size(320, 160));
          return directory;
        });
        try {
          final decoded = await tester.runAsync(() async {
            final bytes = await File(
              '${directory!.path}/cover.png',
            ).readAsBytes();
            return _decodedImageSize(
              ResizeImage.resizeIfNeeded(
                image.memCacheWidth,
                image.memCacheHeight,
                MemoryImage(bytes),
              ),
            );
          });
          expect(decoded, const Size(112, 56));
        } finally {
          await tester.runAsync(() => directory!.delete(recursive: true));
        }
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  for (final scenario in [
    (
      name: 'explicit row size',
      width: 64.0,
      height: 64.0,
      bound: 64.0,
      dpr: 2.0,
      override: null,
      fit: BoxFit.cover,
      source: const Size(2048, 1024),
      expected: const Size(256, 128),
    ),
    (
      name: 'grid constraints',
      width: null,
      height: null,
      bound: 96.0,
      dpr: 3.0,
      override: null,
      fit: BoxFit.cover,
      source: const Size(2048, 1024),
      expected: const Size(576, 288),
    ),
    (
      name: 'explicit decode override',
      width: 64.0,
      height: 64.0,
      bound: 64.0,
      dpr: 2.0,
      override: 640,
      fit: BoxFit.cover,
      source: const Size(2048, 1024),
      expected: const Size(640, 320),
    ),
    (
      name: 'tight constraints override requested height',
      width: null,
      height: 48.0,
      bound: 96.0,
      dpr: 2.0,
      override: null,
      fit: BoxFit.cover,
      source: const Size(2048, 1024),
      expected: const Size(384, 192),
    ),
    (
      name: 'unbounded artwork',
      width: null,
      height: null,
      bound: null,
      dpr: 2.0,
      override: null,
      fit: BoxFit.cover,
      source: const Size(2048, 1024),
      expected: const Size(2048, 1024),
    ),
    for (final fit in [BoxFit.contain, BoxFit.fitWidth, BoxFit.scaleDown])
      (
        name: '$fit uses visible source detail',
        width: 64.0,
        height: 64.0,
        bound: 64.0,
        dpr: 2.0,
        override: null,
        fit: fit,
        source: const Size(2048, 1024),
        expected: const Size(128, 64),
      ),
    for (final fit in [BoxFit.fill, BoxFit.fitHeight])
      (
        name: '$fit retains detail along both axes',
        width: 64.0,
        height: 64.0,
        bound: 64.0,
        dpr: 2.0,
        override: null,
        fit: fit,
        source: const Size(2048, 1024),
        expected: const Size(256, 128),
      ),
    (
      name: 'none keeps original pixel scale',
      width: 64.0,
      height: 64.0,
      bound: 64.0,
      dpr: 2.0,
      override: null,
      fit: BoxFit.none,
      source: const Size(2048, 1024),
      expected: const Size(2048, 1024),
    ),
    (
      name: 'portrait cover',
      width: 64.0,
      height: 64.0,
      bound: 64.0,
      dpr: 2.0,
      override: null,
      fit: BoxFit.cover,
      source: const Size(1024, 2048),
      expected: const Size(128, 256),
    ),
    (
      name: 'small source is never upscaled during decode',
      width: 64.0,
      height: 64.0,
      bound: 64.0,
      dpr: 2.0,
      override: null,
      fit: BoxFit.cover,
      source: const Size(32, 16),
      expected: const Size(32, 16),
    ),
  ]) {
    testWidgets(
      'local ${scenario.name} retains only the expected decoded bitmap',
      (tester) async {
        final cache = PaintingBinding.instance.imageCache;
        cache.clear();
        cache.clearLiveImages();
        final directory = await tester.runAsync(() async {
          final directory = await Directory.systemTemp.createTemp(
            'local-cover-decode-',
          );
          await _writeCover(directory, scenario.source);
          return directory;
        });
        try {
          final cover = LocalOrNetworkCoverImage(
            url: '${directory!.path}/cover.png',
            width: scenario.width,
            height: scenario.height,
            fit: scenario.fit,
            localCacheWidth: scenario.override,
            placeholder: (_) => const SizedBox(),
          );
          final decoded = await tester.runAsync(() async {
            await tester.pumpWidget(
              MaterialApp(
                home: MediaQuery(
                  data: MediaQueryData(devicePixelRatio: scenario.dpr),
                  child: Center(
                    child: scenario.bound == null
                        ? OverflowBox(
                            maxWidth: double.infinity,
                            maxHeight: double.infinity,
                            child: cover,
                          )
                        : SizedBox.square(
                            dimension: scenario.bound,
                            child: cover,
                          ),
                  ),
                ),
              ),
            );
            final imageWidget = tester.widget<Image>(find.byType(Image));
            return _decodedImageSize(imageWidget.image);
          });
          expect(decoded, scenario.expected);
          expect(
            cache.currentSizeBytes,
            scenario.expected.width.toInt() *
                scenario.expected.height.toInt() *
                4,
          );
          expect(
            decoded!.width / decoded.height,
            scenario.source.width / scenario.source.height,
          );
          await tester.pump();
          expect(tester.takeException(), isNull);
        } finally {
          await tester.pumpWidget(const SizedBox());
          cache.clear();
          cache.clearLiveImages();
          await tester.runAsync(() => directory!.delete(recursive: true));
        }
      },
    );
  }

  testWidgets('local cache keys distinguish bounds and fit symmetrically', (
    tester,
  ) async {
    final cache = PaintingBinding.instance.imageCache;
    cache.clear();
    cache.clearLiveImages();
    final directory = await tester.runAsync(() async {
      final directory = await Directory.systemTemp.createTemp(
        'local-cover-key-',
      );
      await _writeCover(directory, const Size(2048, 1024));
      return directory;
    });
    try {
      final keys = <Object>[];
      for (final scenario in [
        (bound: 64.0, fit: BoxFit.cover, expected: const Size(256, 128)),
        (bound: 64.0, fit: BoxFit.cover, expected: const Size(256, 128)),
        (bound: 96.0, fit: BoxFit.cover, expected: const Size(384, 192)),
        (bound: 64.0, fit: BoxFit.contain, expected: const Size(128, 64)),
      ]) {
        final decoded = await tester.runAsync(() async {
          await tester.pumpWidget(
            MaterialApp(
              home: MediaQuery(
                data: const MediaQueryData(devicePixelRatio: 2),
                child: Center(
                  child: SizedBox.square(
                    dimension: scenario.bound,
                    child: LocalOrNetworkCoverImage(
                      url: '${directory!.path}/cover.png',
                      fit: scenario.fit,
                      placeholder: (_) => const SizedBox(),
                    ),
                  ),
                ),
              ),
            ),
          );
          final provider = tester.widget<Image>(find.byType(Image)).image;
          keys.add(await provider.obtainKey(ImageConfiguration.empty));
          return _decodedImageSize(provider);
        });
        expect(decoded, scenario.expected);
      }
      expect(keys[0], keys[1]);
      expect(keys[0].hashCode, keys[1].hashCode);
      expect(keys.toSet(), hasLength(3));
      final original = FileImage(File('${directory!.path}/cover.png'));
      for (final key in keys) {
        expect(key == original, isFalse);
        expect(original == key, isFalse);
      }
      expect(cache.currentSize, 3);
      expect(cache.currentSizeBytes, (256 * 128 + 384 * 192 + 128 * 64) * 4);
      await tester.pump();
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox());
      cache.clear();
      cache.clearLiveImages();
      await tester.runAsync(() => directory!.delete(recursive: true));
    }
  });

  for (final override in [false, true]) {
    testWidgets('a file URI cover decodes the file it names ($override)', (
      tester,
    ) async {
      final directory = await tester.runAsync(() async {
        final directory = await Directory.systemTemp.createTemp('cover-uri-');
        await _writeCover(directory, const Size(128, 128));
        return directory;
      });
      final path = '${directory!.path}/cover.png';
      try {
        await tester.runAsync(() async {
          await tester.pumpWidget(
            MaterialApp(
              home: Center(
                child: LocalOrNetworkCoverImage(
                  url: Uri.file(path).toString(),
                  width: 56,
                  height: 56,
                  localCacheWidth: override ? 112 : null,
                  placeholder: (_) => const SizedBox.square(dimension: 56),
                ),
              ),
            ),
          );
          final provider = tester.widget<Image>(find.byType(Image)).image;
          final file = provider is ResizeImage
              ? provider.imageProvider
              : provider;
          expect((file as FileImage).file.path, path);
          await _decodedImageSize(provider);
        });
      } finally {
        await tester.pumpWidget(const SizedBox());
        PaintingBinding.instance.imageCache.clear();
        PaintingBinding.instance.imageCache.clearLiveImages();
        await tester.runAsync(() => directory.delete(recursive: true));
      }
    });
  }

  for (final form in ['path', 'file URI']) {
    testWidgets('metadata cover prewarm decodes a local $form', (tester) async {
      final cache = PaintingBinding.instance.imageCache;
      cache.clear();
      cache.clearLiveImages();
      late BuildContext context;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (value) {
              context = value;
              return const SizedBox();
            },
          ),
        ),
      );
      final directory = await tester.runAsync(() async {
        final directory = await Directory.systemTemp.createTemp(
          'cover-prewarm-',
        );
        await _writeCover(directory, const Size(64, 64));
        return directory;
      });
      final path = '${directory!.path}/cover.png';
      // The Track Metadata hero decodes a local cover with this key.
      final key = await ResizeImage(
        FileImage(File(path)),
        width: coverCacheWidthForViewport(context),
      ).obtainKey(ImageConfiguration.empty);
      try {
        await tester.runAsync(() async {
          precacheCoverImage(
            context,
            form == 'path' ? path : Uri.file(path).toString(),
          );
          for (var i = 0; i < 200 && !cache.statusForKey(key).keepAlive; i++) {
            await Future<void>.delayed(const Duration(milliseconds: 5));
          }
        });
        expect(cache.statusForKey(key).keepAlive, isTrue);
      } finally {
        await tester.pumpWidget(const SizedBox());
        cache.clear();
        cache.clearLiveImages();
        await tester.runAsync(() => directory.delete(recursive: true));
      }
    });
  }

  testWidgets('covers in other forms show the placeholder', (tester) async {
    for (final url in ['content://media/cover', 'network://nas/cover.jpg']) {
      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: LocalOrNetworkCoverImage(
              url: url,
              width: 56,
              height: 56,
              borderRadius: BorderRadius.circular(8),
              placeholder: (_) => const SizedBox.square(
                key: ValueKey('placeholder'),
                dimension: 56,
              ),
            ),
          ),
        ),
      );
      final placeholder = find.byKey(const ValueKey('placeholder'));
      expect(placeholder, findsOneWidget);
      expect(
        find.ancestor(of: placeholder, matching: find.byType(ClipRRect)),
        findsOneWidget,
      );
      expect(find.byType(Image), findsNothing);
    }
    await tester.pumpWidget(const SizedBox());
  });
}

Future<void> _writeCover(Directory directory, Size size) async {
  final recorder = ui.PictureRecorder();
  Canvas(recorder).drawRect(Offset.zero & size, Paint()..color = Colors.blue);
  final picture = recorder.endRecording();
  final image = await picture.toImage(size.width.toInt(), size.height.toInt());
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  picture.dispose();
  await File(
    '${directory.path}/cover.png',
  ).writeAsBytes(bytes!.buffer.asUint8List());
}

Future<Size> _decodedImageSize(ImageProvider provider) async {
  final result = Completer<Size>();
  final stream = provider.resolve(ImageConfiguration.empty);
  final listener = ImageStreamListener((info, _) {
    if (!result.isCompleted) {
      result.complete(
        Size(info.image.width.toDouble(), info.image.height.toDouble()),
      );
    }
    info.dispose();
  }, onError: result.completeError);
  stream.addListener(listener);
  try {
    return await result.future.timeout(const Duration(seconds: 10));
  } finally {
    stream.removeListener(listener);
  }
}
