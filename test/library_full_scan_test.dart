import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/platform_bridge.dart';
import 'package:mornye/utils/logger.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const backend = MethodChannel('com.zarz.mornye/backend');
  const paths = MethodChannel('plugins.flutter.io/path_provider');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('library-full-scan-');
    messenger.setMockMethodCallHandler(paths, (_) async => root.path);
  });
  tearDown(() async {
    messenger.setMockMethodCallHandler(backend, null);
    messenger.setMockMethodCallHandler(paths, null);
    await root.delete(recursive: true);
  });

  test('SAF scan failures reach Logs even with logging disabled', () async {
    final previousLogging = LogBuffer.loggingEnabled;
    LogBuffer.loggingEnabled = false;
    addTearDown(() => LogBuffer.loggingEnabled = previousLogging);
    LogBuffer().clear();
    messenger.setMockMethodCallHandler(backend, (call) async {
      if (call.method != 'scanSafTreeToNDJSONFile') return null;
      final delivered = Completer<void>();
      messenger.handlePlatformMessage(
        backend.name,
        const StandardMethodCodec().encodeMethodCall(
          const MethodCall('libraryScanError', {
            'path': 'content://library/document/unreadable.flac',
            'operation': 'Read metadata',
            'message': 'Invalid audio header',
          }),
        ),
        (_) => delivered.complete(),
      );
      await delivered.future;
      final output = File((call.arguments as Map)['output_path'] as String);
      await output.writeAsString('');
      return {'path': output.path, 'count': 0, 'error_count': 1};
    });

    final scan = await PlatformBridge.scanSafTreeToNDJSONFile(
      'content://library/tree/music',
    );
    expect(scan.errorCount, 1);
    final error = LogBuffer().entries.single;
    expect(error.level, 'ERROR');
    expect(error.tag, 'LocalLibrary');
    expect(error.message, contains('unreadable.flac'));
    expect(error.message, contains('Read metadata'));
    expect(error.message, contains('Invalid audio header'));
  });

  for (final saf in [false, true]) {
    Future<LibraryScanNDJSONFile> scan({
      bool force = false,
      bool Function()? isCancelled,
    }) => saf
        ? PlatformBridge.scanSafTreeToNDJSONFile(
            'content://library/tree/music',
            forceFullScan: force,
            isCancelled: isCancelled,
          )
        : PlatformBridge.scanLibraryFolderToNDJSONFile(
            '/music',
            forceFullScan: force,
            isCancelled: isCancelled,
          );

    test(
      'forced scan resets checkpoints and keeps cover paths (SAF=$saf)',
      () async {
        final oldCovers = await Directory(
          '${root.path}/library_covers',
        ).create();
        final oldCover = await File(
          '${oldCovers.path}/cover_same-key.jpg',
        ).writeAsBytes([1]);
        final unrelated = await File(
          '${root.path}/library_scan_other.ndjson.state',
        ).writeAsString('other source');
        final marker = File('${oldCovers.path}/$libraryCoverRegenerateMarker');
        final coverDirectories = <String>[];
        final markerStamps = <String>[];
        final resumed = <bool>[];
        messenger.setMockMethodCallHandler(backend, (call) async {
          final args = call.arguments as Map;
          if (call.method == 'setLibraryCoverCacheDir') {
            final directory = args['cache_dir'] as String;
            // Thumbnails keep their names; the marker asks for new extraction.
            expect(directory, oldCovers.path);
            expect(
              await File('$directory/cover_same-key.jpg').exists(),
              isTrue,
            );
            // Each forced scan rewrites the marker (contents, not mtime: some
            // filesystems store whole seconds).
            markerStamps.add(await marker.readAsString());
            coverDirectories.add(directory);
            return null;
          }
          expect(
            call.method,
            saf ? 'scanSafTreeToNDJSONFile' : 'scanLibraryFolderToNDJSONFile',
          );
          final output = File(args['output_path'] as String);
          final checkpoint = File('${output.path}.state');
          final hasCheckpoint = await checkpoint.exists();
          expect(await output.exists(), hasCheckpoint);
          resumed.add(hasCheckpoint);
          await output.writeAsString('{"id":"track"}\n');
          await checkpoint.writeAsString('track\t123\n');
          return {'path': output.path, 'count': 1, 'error_count': 0};
        });

        final first = await scan();
        final resumedScan = await scan();
        expect(resumedScan.file.path, first.file.path);
        expect(coverDirectories, isEmpty);
        final forced = await scan(force: true);
        expect(await forced.rows().toList(), [
          {'id': 'track'},
        ]);
        await scan(force: true);
        expect(resumed, [false, true, false, false]);
        expect(coverDirectories, hasLength(2));
        expect(markerStamps.toSet(), hasLength(2));
        expect(
          await oldCovers.list().map((entry) => entry.path).toList(),
          unorderedEquals([oldCover.path, marker.path]),
        );
        expect(await oldCover.readAsBytes(), [1]);
        expect(await unrelated.readAsString(), 'other source');

        await forced.delete();
        expect(await forced.file.exists(), isFalse);
        expect(await File('${forced.file.path}.state').exists(), isFalse);
      },
    );

    test(
      'cancel before forced scan preserves resumable output (SAF=$saf)',
      () async {
        var calls = 0;
        messenger.setMockMethodCallHandler(backend, (call) async {
          calls++;
          final output = File((call.arguments as Map)['output_path'] as String);
          await output.writeAsString('{"id":"old"}\n');
          await File('${output.path}.state').writeAsString('old\t123\n');
          return {'path': output.path, 'count': 1, 'error_count': 0};
        });
        final previous = await scan();
        await expectLater(
          scan(force: true, isCancelled: () => true),
          throwsStateError,
        );
        expect(calls, 1);
        expect(await previous.file.readAsString(), '{"id":"old"}\n');
        expect(
          await File('${previous.file.path}.state').readAsString(),
          'old\t123\n',
        );
      },
    );
  }

  for (final saf in [false, true]) {
    Future<LibraryScanNDJSONFile> scan() => saf
        ? PlatformBridge.scanSafTreeToNDJSONFile('content://library/tree/music')
        : PlatformBridge.scanLibraryFolderToNDJSONFile('/music');

    for (final count in [0, 2]) {
      test(
        'partial scan exposes readable rows and errors ($count rows, SAF=$saf)',
        () async {
          messenger.setMockMethodCallHandler(backend, (call) async {
            final output = File(
              (call.arguments as Map)['output_path'] as String,
            );
            await output.writeAsString('{"id":"readable"}\n' * count);
            return {'path': output.path, 'count': count, 'error_count': 3};
          });
          final partial = await scan();
          expect(partial.errorCount, 3);
          expect(partial.expectedCount, count);
          expect(await partial.rows().toList(), hasLength(count));
        },
      );
    }

    test('a confirmed empty folder can clear its index (SAF=$saf)', () async {
      messenger.setMockMethodCallHandler(backend, (call) async {
        final output = File((call.arguments as Map)['output_path'] as String);
        await output.writeAsString('');
        return {'path': output.path, 'count': 0, 'error_count': 0};
      });
      final empty = await scan();
      expect(empty.expectedCount, 0);
      expect(await empty.rows().toList(), isEmpty);
    });

    for (final errors in [null, -1, 0.5, '0']) {
      test(
        'missing or invalid error summary is rejected ($errors, SAF=$saf)',
        () async {
          messenger.setMockMethodCallHandler(backend, (call) async {
            final output = File(
              (call.arguments as Map)['output_path'] as String,
            );
            await output.writeAsString('');
            return {'path': output.path, 'count': 0, 'error_count': errors};
          });
          await expectLater(scan(), throwsFormatException);
        },
      );
    }
  }

  test('cache setup failure stops forced scan before native reads', () async {
    final calls = <String>[];
    messenger.setMockMethodCallHandler(backend, (call) async {
      calls.add(call.method);
      throw PlatformException(code: 'cache-unavailable');
    });
    await expectLater(
      PlatformBridge.scanSafTreeToNDJSONFile(
        'content://library/tree/music',
        forceFullScan: true,
      ),
      throwsA(isA<PlatformException>()),
    );
    expect(calls, ['setLibraryCoverCacheDir']);
  });
}
