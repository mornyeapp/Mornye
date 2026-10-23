import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/ffmpeg_conversion.dart';
import 'package:mornye/services/ffmpeg_models.dart';

void main() {
  late Directory directory;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('conversion-output-');
  });
  tearDown(() async => directory.delete(recursive: true));

  Future<File> input(String name) =>
      File('${directory.path}/$name').writeAsString('source');

  Future<FFmpegResult> succeed(List<String> arguments) async {
    await File(arguments[arguments.length - 2]).writeAsString('converted');
    return FFmpegResult(success: true, returnCode: 0, output: '');
  }

  test(
    'conversion preserves existing sibling and handles quoted paths',
    () async {
      final source = await input('Song "live".m4a');
      final sibling = await File(
        '${directory.path}/Song "live".flac',
      ).writeAsString('existing');
      final result = await FFmpegConversion.convertM4aToFlac(
        source.path,
        sourceCodec: 'alac',
        execute: (arguments) async {
          expect(arguments[arguments.indexOf('-i') + 1], source.path);
          expect(await source.exists(), isTrue);
          return succeed(arguments);
        },
      );
      expect(result, '${directory.path}/Song "live" (2).flac');
      expect(await sibling.readAsString(), 'existing');
      expect(await File(result!).readAsString(), 'converted');
      expect(await source.exists(), isFalse);
    },
  );

  test('failed conversion removes partial output and retains source', () async {
    final source = await input('Song.m4a');
    final result = await FFmpegConversion.convertM4aToFlac(
      source.path,
      sourceCodec: 'alac',
      execute: (arguments) async {
        await File(arguments[arguments.length - 2]).writeAsString('partial');
        return FFmpegResult(success: false, returnCode: 1, output: 'failure');
      },
    );
    expect(result, isNull);
    expect(await source.readAsString(), 'source');
    expect(await directory.list().length, 1);
  });

  test(
    'exceptions and empty successful outputs preserve the original',
    () async {
      final source = await input('Song.m4a');
      for (final execute in <Future<FFmpegResult> Function(List<String>)>[
        (_) async => throw StateError('execution failed'),
        (_) async => FFmpegResult(success: true, returnCode: 0, output: ''),
      ]) {
        expect(
          await FFmpegConversion.convertM4aToFlac(
            source.path,
            sourceCodec: 'alac',
            execute: execute,
          ),
          isNull,
        );
        expect(await source.readAsString(), 'source');
        expect(await directory.list().length, 1);
      }
    },
  );

  test('same-suffix conversion stages output until it is complete', () async {
    final source = await input('Song.flac');
    final result = await FFmpegConversion.convertM4aToFlac(
      source.path,
      sourceCodec: 'alac',
      execute: (arguments) async {
        expect(arguments[arguments.length - 2], isNot(source.path));
        expect(await source.readAsString(), 'source');
        return succeed(arguments);
      },
    );
    expect(result, source.path);
    expect(await source.readAsString(), 'converted');
    expect(await directory.list().length, 1);
  });

  test('concurrent conversions reserve distinct output paths', () async {
    final first = await input('Song.m4a');
    final second = await input('Song.mp4');
    final bothStarted = Completer<void>();
    final outputPaths = <String>{};
    Future<FFmpegResult> execute(List<String> arguments) async {
      outputPaths.add(arguments[arguments.length - 2]);
      if (outputPaths.length == 2) bothStarted.complete();
      await bothStarted.future.timeout(const Duration(seconds: 3));
      return succeed(arguments);
    }

    final results = await Future.wait([
      FFmpegConversion.convertM4aToFlac(
        first.path,
        sourceCodec: 'alac',
        execute: execute,
      ),
      FFmpegConversion.convertM4aToFlac(
        second.path,
        sourceCodec: 'alac',
        execute: execute,
      ),
    ]);
    expect(results.toSet(), hasLength(2));
    expect(results, everyElement(isNotNull));
    expect(await directory.list().length, 2);
  });

  test(
    'FLAC payload is remuxed and decoded before deleting its source',
    () async {
      final source = await input('Song.m4a');
      final commands = <List<String>>[];
      final result = await FFmpegConversion.convertM4aToFlac(
        source.path,
        sourceCodec: 'flac',
        execute: (arguments) async {
          commands.add(arguments);
          expect(await source.exists(), isTrue);
          if (arguments.contains('copy')) {
            // Preserve FFmpeg's existing attached-artwork stream selection.
            expect(arguments, isNot(contains('-map')));
            await File(arguments[arguments.length - 2]).writeAsBytes([
              0x66,
              0x4c,
              0x61,
              0x43,
              ...List<int>.filled(64, 0),
            ]);
          } else {
            expect(arguments, containsAllInOrder(['-f', 'null', '-']));
            expect(
              arguments,
              containsAllInOrder(['-err_detect', 'crccheck+explode', '-i']),
            );
            expect(arguments, isNot(contains('-frames:a')));
          }
          return FFmpegResult(success: true, returnCode: 0, output: '');
        },
      );
      expect(result, isNotNull);
      expect(commands, hasLength(2));
      expect(await source.exists(), isFalse);
    },
  );

  for (final failure in ['copy', 'header', 'decode']) {
    test(
      'invalid FLAC $failure falls back to encoding the intact source',
      () async {
        final source = await input('Song.m4a');
        var encoded = false;
        final result = await FFmpegConversion.convertM4aToFlac(
          source.path,
          sourceCodec: 'flac',
          execute: (arguments) async {
            expect(await source.readAsString(), 'source');
            if (arguments.contains('copy')) {
              await File(arguments[arguments.length - 2]).writeAsBytes([
                if (failure != 'header') ...[0x66, 0x4c, 0x61, 0x43],
                ...List<int>.filled(64, 0),
              ]);
              return FFmpegResult(
                success: failure != 'copy',
                returnCode: failure == 'copy' ? 1 : 0,
                output: '',
              );
            }
            if (arguments.last == '-') {
              return FFmpegResult(success: false, returnCode: 1, output: 'bad');
            }
            encoded = true;
            expect(arguments, containsAllInOrder(['-c:a', 'flac']));
            return succeed(arguments);
          },
        );
        expect(encoded, isTrue);
        expect(await File(result!).readAsString(), 'converted');
        expect(await source.exists(), isFalse);
      },
    );
  }

  test(
    'native FLAC rename preserves sibling files and adds missing suffix',
    () async {
      final source = await input('Song.m4a');
      final sibling = await File(
        '${directory.path}/Song.flac',
      ).writeAsString('existing');
      final result = await FFmpegConversion.ensureNativeFlacExtension(
        source.path,
      );
      expect(result, '${directory.path}/Song (2).flac');
      expect(await sibling.readAsString(), 'existing');
      expect(await File(result).readAsString(), 'source');
      expect(await FFmpegConversion.ensureNativeFlacExtension(result), result);
      final noSuffix = await input('Other');
      expect(
        await FFmpegConversion.ensureNativeFlacExtension(noSuffix.path),
        '${noSuffix.path}.flac',
      );
    },
  );

  test('failed native rename releases its reserved destination', () async {
    await expectLater(
      FFmpegConversion.ensureNativeFlacExtension(
        '${directory.path}/missing.m4a',
      ),
      throwsA(isA<FileSystemException>()),
    );
    expect(await directory.list().length, 0);
  });
}
