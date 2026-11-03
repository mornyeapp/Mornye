import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:mornye/services/downloaded_embedded_cover_resolver.dart';
import 'package:mornye/widgets/cached_cover_image.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const backendChannel = MethodChannel('com.zarz.mornye/backend');
  final sourcePaths = <String>[];
  final tempDirectories = <Directory>[];

  late Directory persistentCacheDirectory;

  setUp(() async {
    persistentCacheDirectory = await Directory.systemTemp.createTemp(
      'embedded_cover_persistent_test_',
    );
    DownloadedEmbeddedCoverResolver.setPersistentCacheDirectoryForTesting(
      persistentCacheDirectory,
    );
  });

  Future<String> createAudioFixture(String name) async {
    final directory = await Directory.systemTemp.createTemp(
      'embedded_cover_resolver_test_',
    );
    tempDirectories.add(directory);
    final source = File('${directory.path}${Platform.pathSeparator}$name.flac');
    await source.writeAsBytes(const [0, 1, 2, 3]);
    sourcePaths.add(source.path);
    return source.path;
  }

  tearDown(() async {
    await DownloadedEmbeddedCoverResolver.resetMemoryStateForTesting(
      preservePersistentFiles: false,
    );
    DownloadedEmbeddedCoverResolver.setPersistentCacheDirectoryForTesting(null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(backendChannel, null);
    sourcePaths.clear();
    for (final directory in tempDirectories) {
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
    }
    tempDirectories.clear();
    if (await persistentCacheDirectory.exists()) {
      await persistentCacheDirectory.delete(recursive: true);
    }
  });

  test('metadata artwork prefers embedded, then local, then remote', () {
    expect(
      resolveMetadataArtworkSource(
        embeddedCoverPath: ' C:/covers/embedded.jpg ',
        localCoverPath: 'C:/covers/local.jpg',
        remoteCoverUrl: 'https://example.com/online.jpg',
      ),
      'C:/covers/embedded.jpg',
    );
    expect(
      resolveMetadataArtworkSource(
        embeddedCoverPath: ' ',
        localCoverPath: ' C:/covers/local.jpg ',
        remoteCoverUrl: 'https://example.com/online.jpg',
      ),
      'C:/covers/local.jpg',
    );
    expect(
      resolveMetadataArtworkSource(
        remoteCoverUrl: ' https://example.com/online.jpg ',
      ),
      'https://example.com/online.jpg',
    );
    expect(resolveMetadataArtworkSource(), isNull);
  });

  test(
    'a temporarily offline SAF cover retries after cooldown without restarting',
    () async {
      const source = 'content://example.documents/tree/nas/document/song.flac';
      var now = DateTime(2026, 10, 3);
      DownloadedEmbeddedCoverResolver.setValidationClockForTesting(() => now);
      var extractions = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(backendChannel, (call) async {
            if (call.method == 'getSafFileModTimes') {
              return jsonEncode({source: 1234});
            }
            expect(call.method, 'extractCoverToFile');
            extractions++;
            if (extractions == 1) {
              return jsonEncode({'error': 'Provider temporarily unavailable'});
            }
            final args = call.arguments as Map<Object?, Object?>;
            await File(args['output_path']! as String).writeAsBytes([4, 5, 6]);
            return jsonEncode({'success': true});
          });
      expect(
        await DownloadedEmbeddedCoverResolver.resolveOrExtract(source),
        isNull,
      );
      for (var i = 0; i < 5; i++) {
        expect(
          await DownloadedEmbeddedCoverResolver.resolveOrExtract(source),
          isNull,
        );
      }
      expect(extractions, 1);
      now = now.add(const Duration(seconds: 31));
      final recovered = await DownloadedEmbeddedCoverResolver.resolveOrExtract(
        source,
      );
      expect(recovered, isNotNull);
      expect(await File(recovered!).readAsBytes(), [4, 5, 6]);
      expect(extractions, 2);
      expect(
        await DownloadedEmbeddedCoverResolver.resolveOrExtract(source),
        recovered,
      );
      expect(extractions, 2);
    },
  );

  test(
    'a preview without a source timestamp stays on disk after memory eviction',
    () async {
      const untimed = 'content://example.documents/tree/nas/document/u.flac';
      var hashes = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(backendChannel, (call) async {
            if (call.method == 'runNativeDataJob') {
              final request =
                  jsonDecode((call.arguments as Map)['request_json'] as String)
                      as Map;
              expect(request['operation'], 'hash_file');
              expect(await File(request['path'] as String).readAsBytes(), [
                7,
                8,
              ]);
              hashes++;
              return {
                'sha256': sha256.convert([7, 8]).toString(),
              };
            }
            if (call.method == 'getSafFileModTimes') {
              final uris = jsonDecode(
                (call.arguments as Map)['uris'] as String,
              );
              return jsonEncode({
                for (final uri in uris as List)
                  if (uri != untimed) uri: 1234,
              });
            }
            expect(call.method, 'extractCoverToFile');
            final args = call.arguments as Map<Object?, Object?>;
            await File(args['output_path']! as String).writeAsBytes([7, 8]);
            return jsonEncode({'success': true});
          });

      final preview = await DownloadedEmbeddedCoverResolver.resolveOrExtract(
        untimed,
      );
      expect(preview, isNotNull);
      expect(hashes, 1);
      expect(
        preview,
        endsWith('_${sha256.convert([7, 8]).toString().substring(0, 16)}.jpg'),
      );
      expect(p.isWithin(persistentCacheDirectory.path, preview!), isTrue);
      // 180 newer previews push the first one out of the memory cache.
      for (var index = 0; index < 180; index++) {
        await DownloadedEmbeddedCoverResolver.resolveOrExtract(
          'content://example.documents/tree/nas/document/$index.flac',
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(await File(preview).readAsBytes(), [7, 8]);
      expect(
        await DownloadedEmbeddedCoverResolver.resolveOrExtract(untimed),
        preview,
      );
    },
  );

  test(
    'an edited cover of a source without a timestamp gets a new path',
    () async {
      const untimed = 'content://example.documents/tree/nas/document/e.flac';
      var cover = [7, 8];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(backendChannel, (call) async {
            if (call.method == 'getSafFileModTimes') return jsonEncode({});
            if (call.method == 'runNativeDataJob') {
              final request =
                  jsonDecode((call.arguments as Map)['request_json'] as String)
                      as Map;
              expect(request['operation'], 'hash_file');
              final bytes = await File(request['path'] as String).readAsBytes();
              return {'sha256': sha256.convert(bytes).toString()};
            }
            expect(call.method, 'extractCoverToFile');
            final args = call.arguments as Map<Object?, Object?>;
            await File(args['output_path']! as String).writeAsBytes(cover);
            return jsonEncode({'success': true});
          });

      final original = await DownloadedEmbeddedCoverResolver.resolveOrExtract(
        untimed,
      );
      // A memory miss extracts the same cover to the same path.
      await DownloadedEmbeddedCoverResolver.resetMemoryStateForTesting();
      expect(
        await DownloadedEmbeddedCoverResolver.resolveOrExtract(untimed),
        original,
      );

      // Editing the cover in the app invalidates and extracts again.
      cover = [9, 9, 9];
      await DownloadedEmbeddedCoverResolver.invalidate(untimed);
      final edited = await DownloadedEmbeddedCoverResolver.resolveOrExtract(
        untimed,
      );
      expect(edited, isNot(original));
      expect(await File(edited!).readAsBytes(), [9, 9, 9]);
      expect(await File(original!).exists(), isFalse);
    },
  );

  test(
    'cold resolve starts extraction and reports the cached preview',
    () async {
      final sourcePath = await createAudioFixture('cold-cache');
      var extractionCalls = 0;
      final changed = Completer<void>();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(backendChannel, (call) async {
            expect(call.method, 'extractCoverToFile');
            extractionCalls++;
            final arguments = call.arguments as Map<Object?, Object?>;
            await File(
              arguments['output_path']! as String,
            ).writeAsBytes(const [4, 5, 6]);
            return jsonEncode({'success': true});
          });

      final initial = DownloadedEmbeddedCoverResolver.resolve(
        sourcePath,
        onChanged: () {
          if (!changed.isCompleted) changed.complete();
        },
      );

      expect(initial, isNull);
      await changed.future.timeout(const Duration(seconds: 2));
      final cached = DownloadedEmbeddedCoverResolver.resolve(sourcePath);
      expect(extractionCalls, 1);
      expect(cached, isNotNull);
      expect(await File(cached!).exists(), isTrue);
      expect(
        DownloadedEmbeddedCoverResolver.isManagedPreviewPath(cached),
        isTrue,
      );
    },
  );

  test('concurrent resolveOrExtract calls share one extraction', () async {
    final sourcePath = await createAudioFixture('concurrent');
    var extractionCalls = 0;
    var callbacks = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(backendChannel, (call) async {
          expect(call.method, 'extractCoverToFile');
          extractionCalls++;
          final arguments = call.arguments as Map<Object?, Object?>;
          await Future<void>.delayed(const Duration(milliseconds: 20));
          await File(
            arguments['output_path']! as String,
          ).writeAsBytes(const [7, 8, 9]);
          return jsonEncode({'success': true});
        });

    final results = await Future.wait([
      DownloadedEmbeddedCoverResolver.resolveOrExtract(
        sourcePath,
        onChanged: () => callbacks++,
      ),
      DownloadedEmbeddedCoverResolver.resolveOrExtract(
        sourcePath,
        onChanged: () => callbacks++,
      ),
      DownloadedEmbeddedCoverResolver.resolveOrExtract(
        sourcePath,
        onChanged: () => callbacks++,
      ),
    ]);

    expect(extractionCalls, 1);
    expect(callbacks, 3);
    expect(results.toSet(), hasLength(1));
    expect(results.first, isNotNull);
    expect(await File(results.first!).exists(), isTrue);
  });

  test(
    'background cover extraction is limited to two concurrent jobs',
    () async {
      final paths = await Future.wait([
        for (var index = 0; index < 5; index++)
          createAudioFixture('bounded-$index'),
      ]);
      final release = Completer<void>();
      final firstTwoStarted = Completer<void>();
      final allCompleted = Completer<void>();
      var calls = 0;
      var active = 0;
      var maxActive = 0;
      var completed = 0;
      addTearDown(() {
        if (!release.isCompleted) release.complete();
      });

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(backendChannel, (call) async {
            expect(call.method, 'extractCoverToFile');
            calls++;
            active++;
            if (active > maxActive) maxActive = active;
            if (calls == 2 && !firstTwoStarted.isCompleted) {
              firstTwoStarted.complete();
            }
            try {
              await release.future;
              final arguments = call.arguments as Map<Object?, Object?>;
              await File(
                arguments['output_path']! as String,
              ).writeAsBytes(const [13, 14, 15]);
              return jsonEncode({'success': true});
            } finally {
              active--;
            }
          });

      void onChanged() {
        completed++;
        if (completed == paths.length && !allCompleted.isCompleted) {
          allCompleted.complete();
        }
      }

      for (final path in paths) {
        expect(
          DownloadedEmbeddedCoverResolver.resolve(path, onChanged: onChanged),
          isNull,
        );
      }

      await firstTwoStarted.future.timeout(const Duration(seconds: 2));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(calls, 2);
      expect(maxActive, 2);

      release.complete();
      await allCompleted.future.timeout(const Duration(seconds: 2));
      expect(calls, paths.length);
      expect(maxActive, 2);
    },
  );

  test(
    'cached SAF previews batch validation and throttle repeated hits',
    () async {
      var now = DateTime.utc(2026);
      DownloadedEmbeddedCoverResolver.setValidationClockForTesting(() => now);
      final paths = List.generate(
        18,
        (index) => 'content://covers/document/$index',
      );
      final batches = <List<String>>[];
      var extractions = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(backendChannel, (call) async {
            final args = call.arguments as Map;
            if (call.method == 'getSafFileModTimes') {
              final uris = (jsonDecode(args['uris'] as String) as List)
                  .cast<String>();
              batches.add(uris);
              return jsonEncode({for (final path in uris) path: 1234});
            }
            expect(call.method, 'extractCoverToFile');
            extractions++;
            await File(args['output_path'] as String).writeAsBytes([1, 2, 3]);
            return jsonEncode({'success': true});
          });
      for (final path in paths) {
        expect(
          await DownloadedEmbeddedCoverResolver.resolveOrExtract(path),
          isNotNull,
        );
      }
      batches.clear();
      for (final path in paths) {
        DownloadedEmbeddedCoverResolver.resolve(path);
        DownloadedEmbeddedCoverResolver.resolve(path);
      }
      await DownloadedEmbeddedCoverResolver.waitForPreviewValidationForTesting();
      expect(batches.map((batch) => batch.length), [8, 8, 2]);
      expect(batches.expand((batch) => batch).toSet(), paths.toSet());
      for (final path in paths) {
        DownloadedEmbeddedCoverResolver.resolve(path);
      }
      await DownloadedEmbeddedCoverResolver.waitForPreviewValidationForTesting();
      expect(batches.length, 3);
      now = now.add(const Duration(seconds: 5));
      for (final path in paths) {
        DownloadedEmbeddedCoverResolver.resolve(path);
      }
      await DownloadedEmbeddedCoverResolver.waitForPreviewValidationForTesting();
      expect(batches.length, 6);
      expect(extractions, paths.length);
      // Explicit edits bypass the interval, even immediately after validation.
      await DownloadedEmbeddedCoverResolver.scheduleRefreshForPath(
        paths.first,
        force: true,
      );
      await DownloadedEmbeddedCoverResolver.resolveOrExtract(paths.first);
      expect(extractions, paths.length + 1);
    },
  );

  test(
    'validation shares callbacks and detects external changes after interval',
    () async {
      var now = DateTime.utc(2026);
      DownloadedEmbeddedCoverResolver.setValidationClockForTesting(() => now);
      const path = 'content://covers/document/external';
      var modTime = 1234;
      var extractions = 0;
      var modTimeCalls = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(backendChannel, (call) async {
            if (call.method == 'getSafFileModTimes') {
              modTimeCalls++;
              return jsonEncode({path: modTime});
            }
            expect(call.method, 'extractCoverToFile');
            extractions++;
            await File(
              (call.arguments as Map)['output_path'] as String,
            ).writeAsBytes([1, 2, 3]);
            return jsonEncode({'success': true});
          });
      await DownloadedEmbeddedCoverResolver.resolveOrExtract(path);
      DownloadedEmbeddedCoverResolver.resolve(path);
      await DownloadedEmbeddedCoverResolver.waitForPreviewValidationForTesting();
      modTime = 5678;
      DownloadedEmbeddedCoverResolver.resolve(path);
      await DownloadedEmbeddedCoverResolver.waitForPreviewValidationForTesting();
      expect(extractions, 1);
      expect(modTimeCalls, 2);
      now = now.add(const Duration(seconds: 5));
      var firstNotified = 0;
      var secondNotified = 0;
      DownloadedEmbeddedCoverResolver.resolve(
        path,
        onChanged: () => firstNotified++,
      );
      DownloadedEmbeddedCoverResolver.resolve(
        path,
        onChanged: () => secondNotified++,
      );
      await DownloadedEmbeddedCoverResolver.waitForPreviewValidationForTesting();
      expect(extractions, 2);
      expect(firstNotified, 1);
      expect(secondNotified, 1);
    },
  );

  test(
    'invalidation during a pending validation cannot restore stale artwork',
    () async {
      const path = 'content://covers/document/invalidation';
      final entered = Completer<void>();
      final release = Completer<void>();
      addTearDown(() {
        if (!release.isCompleted) release.complete();
      });
      var modTimeCalls = 0;
      var extractions = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(backendChannel, (call) async {
            if (call.method == 'getSafFileModTimes') {
              if (++modTimeCalls == 2) {
                entered.complete();
                await release.future;
                return jsonEncode({path: 5678});
              }
              return jsonEncode({path: 1234});
            }
            expect(call.method, 'extractCoverToFile');
            extractions++;
            await File(
              (call.arguments as Map)['output_path'] as String,
            ).writeAsBytes([1, 2, 3]);
            return jsonEncode({'success': true});
          });
      final preview = await DownloadedEmbeddedCoverResolver.resolveOrExtract(
        path,
      );
      var notified = false;
      DownloadedEmbeddedCoverResolver.resolve(
        path,
        onChanged: () => notified = true,
      );
      await entered.future.timeout(const Duration(seconds: 2));
      await DownloadedEmbeddedCoverResolver.invalidate(path);
      release.complete();
      await DownloadedEmbeddedCoverResolver.waitForPreviewValidationForTesting();
      expect(extractions, 1);
      expect(notified, isFalse);
      expect(await File(preview!).exists(), isFalse);
    },
  );

  test('foreground extraction is promoted ahead of background jobs', () async {
    final paths = await Future.wait([
      for (var index = 0; index < 4; index++)
        createAudioFixture('priority-$index'),
    ]);
    final releaseFirst = Completer<void>();
    final releaseSecond = Completer<void>();
    final firstTwoStarted = Completer<void>();
    final thirdStarted = Completer<void>();
    final allCompleted = Completer<void>();
    final startedPaths = <String>[];
    var completed = 0;
    addTearDown(() {
      if (!releaseFirst.isCompleted) releaseFirst.complete();
      if (!releaseSecond.isCompleted) releaseSecond.complete();
    });

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(backendChannel, (call) async {
          expect(call.method, 'extractCoverToFile');
          final arguments = call.arguments as Map<Object?, Object?>;
          final audioPath = arguments['audio_path']! as String;
          startedPaths.add(audioPath);
          final callIndex = startedPaths.length - 1;
          if (startedPaths.length == 2 && !firstTwoStarted.isCompleted) {
            firstTwoStarted.complete();
          }
          if (startedPaths.length == 3 && !thirdStarted.isCompleted) {
            thirdStarted.complete();
          }
          if (callIndex == 0) {
            await releaseFirst.future;
          } else if (callIndex == 1) {
            await releaseSecond.future;
          }
          await File(
            arguments['output_path']! as String,
          ).writeAsBytes(const [16, 17, 18]);
          return jsonEncode({'success': true});
        });

    void onChanged() {
      completed++;
      if (completed == paths.length && !allCompleted.isCompleted) {
        allCompleted.complete();
      }
    }

    DownloadedEmbeddedCoverResolver.resolve(paths[0], onChanged: onChanged);
    DownloadedEmbeddedCoverResolver.resolve(paths[1], onChanged: onChanged);
    await firstTwoStarted.future.timeout(const Duration(seconds: 2));

    DownloadedEmbeddedCoverResolver.resolve(paths[2], onChanged: onChanged);
    DownloadedEmbeddedCoverResolver.resolve(paths[3], onChanged: onChanged);
    final foreground = DownloadedEmbeddedCoverResolver.resolveOrExtract(
      paths[3],
    );

    releaseFirst.complete();
    await thirdStarted.future.timeout(const Duration(seconds: 2));
    expect(startedPaths[2], paths[3]);

    releaseSecond.complete();
    expect(await foreground, isNotNull);
    await allCompleted.future.timeout(const Duration(seconds: 2));
    expect(startedPaths, hasLength(paths.length));
  });

  test('force refresh drops a stale cover when artwork is removed', () async {
    final sourcePath = await createAudioFixture('removed-cover');
    var extractionCalls = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(backendChannel, (call) async {
          expect(call.method, 'extractCoverToFile');
          extractionCalls++;
          if (extractionCalls == 1) {
            final arguments = call.arguments as Map<Object?, Object?>;
            await File(
              arguments['output_path']! as String,
            ).writeAsBytes(const [10, 11, 12]);
            return jsonEncode({'success': true});
          }
          return jsonEncode({'error': 'embedded cover not found'});
        });

    final original = await DownloadedEmbeddedCoverResolver.resolveOrExtract(
      sourcePath,
    );
    expect(original, isNotNull);
    expect(
      DownloadedEmbeddedCoverResolver.isManagedPreviewPath(original),
      isTrue,
    );

    await DownloadedEmbeddedCoverResolver.scheduleRefreshForPath(
      sourcePath,
      force: true,
    );
    final refreshed = await DownloadedEmbeddedCoverResolver.resolveOrExtract(
      sourcePath,
    );

    expect(extractionCalls, 2);
    expect(refreshed, isNull);
    expect(await File(original!).exists(), isFalse);
    expect(
      DownloadedEmbeddedCoverResolver.isManagedPreviewPath(original),
      isTrue,
    );
    expect(DownloadedEmbeddedCoverResolver.resolve(sourcePath), isNull);
  });

  test(
    'persistent preview survives memory reset and revalidates source changes',
    () async {
      final sourcePath = await createAudioFixture('persistent-restart');
      var extractionCalls = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(backendChannel, (call) async {
            expect(call.method, 'extractCoverToFile');
            extractionCalls++;
            final arguments = call.arguments as Map<Object?, Object?>;
            await File(
              arguments['output_path']! as String,
            ).writeAsBytes([extractionCalls, 20, 21]);
            return jsonEncode({'success': true});
          });

      final first = await DownloadedEmbeddedCoverResolver.resolveOrExtract(
        sourcePath,
      );
      expect(first, isNotNull);
      expect(extractionCalls, 1);

      await DownloadedEmbeddedCoverResolver.resetMemoryStateForTesting();
      expect(
        DownloadedEmbeddedCoverResolver.isManagedPreviewPath(first),
        isTrue,
      );
      final reused = await DownloadedEmbeddedCoverResolver.resolveOrExtract(
        sourcePath,
      );
      expect(reused, first);
      expect(extractionCalls, 1);

      await File(sourcePath).writeAsBytes(const [9, 8, 7, 6, 5]);
      await File(
        sourcePath,
      ).setLastModified(DateTime.now().add(const Duration(seconds: 2)));
      await DownloadedEmbeddedCoverResolver.resetMemoryStateForTesting();

      final refreshed = await DownloadedEmbeddedCoverResolver.resolveOrExtract(
        sourcePath,
      );
      expect(extractionCalls, 2);
      expect(refreshed, isNotNull);
      expect(refreshed, isNot(first));
      expect(await File(refreshed!).exists(), isTrue);
      expect(await File(first!).exists(), isFalse);
    },
  );

  test('legacy NUL-prefixed JPEG previews are re-extracted', () async {
    final sourcePath = await createAudioFixture('legacy-padded-cover');
    var extractions = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(backendChannel, (call) async {
          expect(call.method, 'extractCoverToFile');
          extractions++;
          await File(
            (call.arguments as Map)['output_path'] as String,
          ).writeAsBytes([0xff, 0xd8, 0xff, 0xe0]);
          return jsonEncode({'success': true});
        });
    final preview = (await DownloadedEmbeddedCoverResolver.resolveOrExtract(
      sourcePath,
    ))!;
    await File(preview).writeAsBytes([0, 0xff, 0xd8, 0xff, 0xe0]);
    await DownloadedEmbeddedCoverResolver.resetMemoryStateForTesting();
    final refreshed = await DownloadedEmbeddedCoverResolver.resolveOrExtract(
      sourcePath,
    );
    expect(extractions, 2);
    expect(await File(refreshed!).readAsBytes(), [0xff, 0xd8, 0xff, 0xe0]);
  });

  test('legacy SAF thumbnails are replaced without changing the audio', () async {
    const source = 'content://covers/document/original-artwork.flac';
    sourcePaths.add(source);
    var extractions = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(backendChannel, (call) async {
          if (call.method == 'getSafFileModTimes') {
            return jsonEncode({source: 1234});
          }
          expect(call.method, 'extractCoverToFile');
          extractions++;
          await File(
            (call.arguments as Map)['output_path'] as String,
          ).writeAsBytes([1, 2, 3]);
          return jsonEncode({'success': true});
        });
    final preview = (await DownloadedEmbeddedCoverResolver.resolveOrExtract(
      source,
    ))!;
    await DownloadedEmbeddedCoverResolver.resetMemoryStateForTesting();
    final legacy = preview.replaceFirst('v2_', 'v1_');
    expect(legacy, isNot(preview));
    await File(preview).rename(legacy);
    await File('$preview.source').rename('$legacy.source');
    await File(legacy).writeAsBytes([8, 0, 0]);

    final refreshed = await DownloadedEmbeddedCoverResolver.resolveOrExtract(
      source,
    );
    expect(extractions, 2);
    expect(await File(refreshed!).readAsBytes(), [1, 2, 3]);
    await DownloadedEmbeddedCoverResolver.runPersistentCacheMaintenanceForTesting();
    expect(await File(legacy).exists(), isFalse);
    expect(await File('$legacy.source').exists(), isFalse);
  });

  test('invalidate removes persistent variants after memory reset', () async {
    final sourcePath = await createAudioFixture('persistent-invalidate');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(backendChannel, (call) async {
          final arguments = call.arguments as Map<Object?, Object?>;
          await File(
            arguments['output_path']! as String,
          ).writeAsBytes(const [22, 23, 24]);
          return jsonEncode({'success': true});
        });

    final preview = await DownloadedEmbeddedCoverResolver.resolveOrExtract(
      sourcePath,
    );
    expect(preview, isNotNull);
    await DownloadedEmbeddedCoverResolver.resetMemoryStateForTesting();
    await DownloadedEmbeddedCoverResolver.invalidate(sourcePath);

    expect(await File(preview!).exists(), isFalse);
    final remainingPreviews = await persistentCacheDirectory
        .list()
        .where((entity) => entity is File && entity.path.endsWith('.jpg'))
        .toList();
    expect(remainingPreviews, isEmpty);
  });

  test('persistent maintenance enforces entry and byte caps', () async {
    final paths = await Future.wait([
      for (var index = 0; index < 3; index++)
        createAudioFixture('persistent-cap-$index'),
    ]);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(backendChannel, (call) async {
          final arguments = call.arguments as Map<Object?, Object?>;
          await File(
            arguments['output_path']! as String,
          ).writeAsBytes(const [25, 26, 27, 28]);
          return jsonEncode({'success': true});
        });

    final previews = <String>[];
    for (final path in paths) {
      previews.add(
        (await DownloadedEmbeddedCoverResolver.resolveOrExtract(path))!,
      );
    }
    await DownloadedEmbeddedCoverResolver.resetMemoryStateForTesting();
    for (var index = 0; index < previews.length; index++) {
      await File(previews[index]).setLastModified(DateTime(2024, 1, index + 1));
    }

    await DownloadedEmbeddedCoverResolver.runPersistentCacheMaintenanceForTesting(
      maxEntries: 2,
      maxBytes: 100,
      targetBytes: 100,
    );
    expect(await File(previews[0]).exists(), isFalse);
    expect(await File(previews[1]).exists(), isTrue);
    expect(await File(previews[2]).exists(), isTrue);
    expect(
      DownloadedEmbeddedCoverResolver.isManagedPreviewPath(previews[1]),
      isTrue,
    );

    await DownloadedEmbeddedCoverResolver.runPersistentCacheMaintenanceForTesting(
      maxEntries: 10,
      maxBytes: 5,
      targetBytes: 4,
    );
    final survivors = await Future.wait([
      for (final preview in previews) File(preview).exists(),
    ]);
    expect(survivors.where((exists) => exists), hasLength(1));
  });

  test(
    'persistent cache clear waits for cancelled native extraction cleanup',
    () async {
      final sourcePath = await createAudioFixture('clear-in-flight');
      final started = Completer<void>();
      final release = Completer<void>();
      addTearDown(() {
        if (!release.isCompleted) release.complete();
      });
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(backendChannel, (call) async {
            if (!started.isCompleted) started.complete();
            await release.future;
            final arguments = call.arguments as Map<Object?, Object?>;
            await File(
              arguments['output_path']! as String,
            ).writeAsBytes(const [29, 30, 31]);
            return jsonEncode({'success': true});
          });

      final resolution = DownloadedEmbeddedCoverResolver.resolveOrExtract(
        sourcePath,
      );
      await started.future.timeout(const Duration(seconds: 2));
      var clearCompleted = false;
      final clear = DownloadedEmbeddedCoverResolver.clearPersistentCache().then(
        (_) => clearCompleted = true,
      );
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(clearCompleted, isFalse);

      release.complete();
      expect(await resolution, isNull);
      await clear.timeout(const Duration(seconds: 2));
      expect(clearCompleted, isTrue);
      expect(await persistentCacheDirectory.list().toList(), isEmpty);
    },
  );

  test('metadata cover pipeline enforces shared resolver ownership', () {
    final coverSource = File(
      'lib/screens/track_metadata_screen_cover.dart',
    ).readAsStringSync();
    final cardsSource = File(
      'lib/screens/track_metadata_cards.dart',
    ).readAsStringSync();

    expect(
      coverSource,
      contains('DownloadedEmbeddedCoverResolver.isManagedPreviewPath(path)'),
    );
    expect(
      coverSource,
      contains('DownloadedEmbeddedCoverResolver.resolveOrExtract('),
    );
    expect(coverSource, isNot(contains('PlatformBridge.extractCoverToFile')));
    expect(
      cardsSource,
      contains('Downloaded-item entry points must await resolveOrExtract'),
    );
    expect(
      cardsSource,
      contains(
        'Widget coverImage() => artworkImage(cacheWidth: coverCacheWidth)',
      ),
    );
    expect(cardsSource, contains('cacheHeight: backdropCacheWidth'));
  });
}
