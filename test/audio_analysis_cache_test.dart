import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/audio_analysis_cache.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();

  group('spectrogram disk cache', () {
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    late Directory support;

    setUp(() async {
      support = await Directory.systemTemp.createTemp('spectrogram-cache-');
      binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        (_) async => support.path,
      );
    });

    tearDown(() async {
      binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
      await support.delete(recursive: true);
    });

    test('a corrupt PNG completes as a cache miss', () async {
      const source = '/music/corrupt.flac';
      final directory = await AudioAnalysisDiskCache.cacheDir();
      final key = AudioAnalysisDiskCache.cacheKey(source);
      await File('${directory.path}/${key}_ch0.png').writeAsBytes([1, 2, 3]);

      await expectLater(
        AudioAnalysisDiskCache.loadSpectrogramFromCache(
          source,
          channel: 0,
        ).timeout(const Duration(seconds: 2)),
        completion(isNull),
      );
    });

    test('a decoded frame stays usable until its caller disposes it', () async {
      const source = '/music/valid.flac';
      final directory = await AudioAnalysisDiskCache.cacheDir();
      final key = AudioAnalysisDiskCache.cacheKey(source);
      final recorder = ui.PictureRecorder();
      ui.Canvas(
        recorder,
      ).drawPaint(ui.Paint()..color = const ui.Color(0xff123456));
      final picture = recorder.endRecording();
      final original = await picture.toImage(2, 1);
      try {
        final bytes = await original.toByteData(format: ui.ImageByteFormat.png);
        await File(
          '${directory.path}/$key.png',
        ).writeAsBytes(bytes!.buffer.asUint8List());
      } finally {
        original.dispose();
        picture.dispose();
      }

      final image = await AudioAnalysisDiskCache.loadSpectrogramFromCache(
        source,
        channel: -1,
      );
      expect(image, isNotNull);
      addTearDown(image!.dispose);
      expect((image.width, image.height), (2, 1));
      expect(await image.toByteData(), isNotNull);
    });
  });

  test('eviction removes whole bundles and retains active analyses', () async {
    final directory = await Directory.systemTemp.createTemp('analysis-budget-');
    addTearDown(() => directory.delete(recursive: true));
    Future<File> write(String name, int size, int age) async {
      final file = await File(
        '${directory.path}/$name',
      ).writeAsBytes(List.filled(size, 0));
      await file.setLastModified(DateTime(2026, 1, age));
      return file;
    }

    final old = [
      await write('aa.json', 10, 1),
      await write('aa.png', 40, 1),
      await write('aa_ch0.png', 40, 1),
    ];
    final active = await write('bb.png', 80, 2);
    final recent = await write('cc.png', 80, 3);
    final unrelated = await write('unrelated.txt', 500, 1);
    final cache = AudioAnalysisCache();
    final release = cache.retain('bb');
    await cache.trim(directory, maxBytes: 180, targetBytes: 160);
    for (final file in old) {
      expect(await file.exists(), false);
    }
    expect(await active.exists(), true);
    expect(await recent.exists(), true);
    expect(await unrelated.exists(), true);

    release();
    release(); // Releasing a cancelled request twice cannot drop another lease.
    await cache.trim(directory, maxBytes: 100, targetBytes: 80);
    expect(await active.exists(), false);
    expect(await recent.exists(), true);
  });

  test(
    'overlapping leases keep a source protected until both finish',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'analysis-active-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final file = await File('${directory.path}/aa.png').writeAsBytes([1, 2]);
      final cache = AudioAnalysisCache();
      final first = cache.retain('aa');
      final second = cache.retain('aa');
      first();
      await cache.trim(directory, maxBytes: 1, targetBytes: 0);
      expect(await file.exists(), true);
      second();
      await cache.trim(directory, maxBytes: 1, targetBytes: 0);
      expect(await file.exists(), false);
    },
  );
}
