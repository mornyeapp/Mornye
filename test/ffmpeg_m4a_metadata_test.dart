import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/ffmpeg_metadata.dart';
import 'package:mornye/services/ffmpeg_models.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('plugins.flutter.io/path_provider');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  var toolsAvailable = false;
  late Directory directory;

  setUpAll(() async {
    try {
      final ffmpeg = await Process.run('ffmpeg', ['-version']);
      final ffprobe = await Process.run('ffprobe', ['-version']);
      toolsAvailable = ffmpeg.exitCode == 0 && ffprobe.exitCode == 0;
    } on ProcessException {
      // The media round-trip tests run when FFmpeg tools are on PATH.
    }
  });

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('m4a-metadata-');
    messenger.setMockMethodCallHandler(channel, (_) async => directory.path);
  });

  tearDown(() async {
    messenger.setMockMethodCallHandler(channel, null);
    await directory.delete(recursive: true);
  });

  Future<ProcessResult> run(String executable, List<String> arguments) async {
    final result = await Process.run(executable, arguments);
    expect(result.exitCode, 0, reason: result.stderr.toString());
    return result;
  }

  Future<FFmpegResult> execute(List<String> arguments) async {
    final result = await Process.run('ffmpeg', arguments);
    return FFmpegResult(
      success: result.exitCode == 0,
      returnCode: result.exitCode,
      output: '${result.stdout}${result.stderr}',
    );
  }

  Future<String> streamHash(String path, String stream) async {
    final result = await run('ffmpeg', [
      '-v',
      'error',
      '-i',
      path,
      '-map',
      stream,
      '-c',
      'copy',
      '-f',
      'hash',
      '-hash',
      'sha256',
      '-',
    ]);
    final hash = result.stdout.toString().trim();
    expect(hash, matches(r'^SHA256=[a-f0-9]{64}$'));
    return hash;
  }

  Future<String> createCover(String color) async {
    final path = '${directory.path}/$color.png';
    await run('ffmpeg', [
      '-v',
      'error',
      '-f',
      'lavfi',
      '-i',
      'color=c=$color:s=16x16',
      '-frames:v',
      '1',
      path,
    ]);
    return path;
  }

  test(
    'M4A enables FLAC-in-MP4 compatibility on older FFmpeg builds',
    () async {
      final input = File('${directory.path}/track.m4a');
      await input.writeAsBytes([1, 2, 3]);
      var calls = 0;

      expect(
        await FFmpegMetadata.embedMetadataToM4a(
          m4aPath: input.path,
          execute: (arguments) async {
            calls++;
            expect(arguments[arguments.indexOf('-f') + 1], 'mp4');
            expect(arguments[arguments.indexOf('-strict') + 1], 'experimental');
            await File(arguments[arguments.length - 2]).writeAsBytes([4, 5, 6]);
            return FFmpegResult(success: true, returnCode: 0, output: '');
          },
        ),
        input.path,
      );
      expect(calls, 1);
      expect(await input.readAsBytes(), [4, 5, 6]);
    },
  );

  for (final retrySucceeds in [true, false]) {
    test('M4A MOV codec fallback with success=$retrySucceeds', () async {
      final input = File('${directory.path}/track.m4a');
      final original = [1, 2, 3];
      await input.writeAsBytes(original);
      var calls = 0;
      String? outputPath;

      final result = await FFmpegMetadata.embedMetadataToM4a(
        m4aPath: input.path,
        execute: (arguments) async {
          calls++;
          final output = File(arguments[arguments.length - 2]);
          final muxer = arguments[arguments.indexOf('-f') + 1];
          expect(await input.readAsBytes(), original);
          expect(await output.exists(), isFalse);
          if (calls == 1) {
            expect(muxer, 'mp4');
            outputPath = output.path;
            await output.writeAsBytes([0]);
            return FFmpegResult(
              success: false,
              returnCode: 1,
              output:
                  'Could not find tag for codec ac4 in stream #0, '
                  'codec not currently supported in container',
            );
          }
          expect(calls, 2);
          expect(muxer, 'mov');
          expect(output.path, outputPath);
          await output.writeAsBytes([4, 5, 6]);
          return FFmpegResult(
            success: retrySucceeds,
            returnCode: retrySucceeds ? 0 : 1,
            output: retrySucceeds ? '' : 'Could not write header',
          );
        },
      );

      expect(result, retrySucceeds ? input.path : isNull);
      expect(calls, 2);
      expect(await input.readAsBytes(), retrySucceeds ? [4, 5, 6] : original);
      expect(await File(outputPath!).exists(), isFalse);
    });
  }

  test(
    'M4A preserves input and avoids a MOV retry after a write failure',
    () async {
      final input = File('${directory.path}/track.m4a');
      await input.writeAsBytes([1, 2, 3]);
      var calls = 0;
      String? outputPath;

      expect(
        await FFmpegMetadata.embedMetadataToM4a(
          m4aPath: input.path,
          execute: (arguments) async {
            calls++;
            outputPath = arguments[arguments.length - 2];
            await File(outputPath!).writeAsBytes([0]);
            return FFmpegResult(
              success: false,
              returnCode: 1,
              output: 'Error writing trailer: No space left on device',
            );
          },
        ),
        isNull,
      );
      expect(calls, 1);
      expect(await input.readAsBytes(), [1, 2, 3]);
      expect(await File(outputPath!).exists(), isFalse);
    },
  );

  for (final codec in ['flac', 'alac', 'aac']) {
    for (final scenario in [
      (
        name: 'metadata only',
        existingCover: false,
        newCover: false,
        preserve: true,
      ),
      (
        name: 'preserved cover with missing replacement',
        existingCover: true,
        newCover: false,
        preserve: true,
      ),
      (name: 'new cover', existingCover: false, newCover: true, preserve: true),
      (
        name: 'replaced cover',
        existingCover: true,
        newCover: true,
        preserve: true,
      ),
      (
        name: 'full replacement',
        existingCover: true,
        newCover: false,
        preserve: false,
      ),
    ]) {
      test('M4A $codec ${scenario.name} preserves encoded audio', () async {
        if (!toolsAvailable) {
          markTestSkipped('Requires ffmpeg and ffprobe on PATH');
          return;
        }
        final path = '${directory.path}/Example "Song".m4a';
        final originalCover = scenario.existingCover
            ? await createCover('red')
            : null;
        final replacementCover = scenario.newCover
            ? await createCover('blue')
            : null;
        await run('ffmpeg', [
          '-v',
          'error',
          '-f',
          'lavfi',
          '-i',
          'sine=frequency=440:duration=0.1',
          if (originalCover != null) ...['-i', originalCover],
          '-map',
          '0:a',
          '-c:a',
          codec,
          if (originalCover != null) ...[
            '-map',
            '1:v',
            '-c:v',
            'copy',
            '-disposition:v:0',
            'attached_pic',
          ],
          '-metadata',
          'title=Original Song',
          '-metadata',
          'artist=Original Artist',
          '-f',
          'mp4',
          '-strict',
          'experimental',
          path,
        ]);
        final beforeHash = await streamHash(path, '0:a:0');
        var calls = 0;
        expect(
          await FFmpegMetadata.embedMetadataToM4a(
            m4aPath: path,
            coverPath:
                replacementCover ??
                (scenario.existingCover
                    ? '${directory.path}/missing.png'
                    : null),
            metadata: {'title': 'Updated Song'},
            preserveMetadata: scenario.preserve,
            execute: (arguments) async {
              calls++;
              return execute(arguments);
            },
          ),
          path,
        );
        expect(calls, 1, reason: 'Supported MP4 audio needs no fallback');

        final probe = await run('ffprobe', [
          '-v',
          'error',
          '-show_streams',
          '-show_format',
          '-of',
          'json',
          path,
        ]);
        final json = jsonDecode(probe.stdout as String) as Map<String, dynamic>;
        final streams = (json['streams'] as List<dynamic>)
            .cast<Map<String, dynamic>>();
        final audio = streams.singleWhere(
          (stream) => stream['codec_type'] == 'audio',
        );
        expect(audio['codec_name'], codec);
        expect(await streamHash(path, '0:a:0'), beforeHash);

        final format = json['format'] as Map<String, dynamic>;
        final tags = format['tags'] as Map<String, dynamic>;
        expect(tags['title'], 'Updated Song');
        expect(tags['artist'], scenario.preserve ? 'Original Artist' : isNull);
        final expectedCover =
            replacementCover ?? (scenario.preserve ? originalCover : null);
        final pictures = streams.where(
          (stream) => stream['codec_type'] == 'video',
        );
        expect(pictures, hasLength(expectedCover == null ? 0 : 1));
        if (expectedCover != null) {
          final disposition =
              pictures.single['disposition'] as Map<String, dynamic>;
          expect(disposition['attached_pic'], 1);
          expect(
            await streamHash(path, '0:v:0'),
            await streamHash(expectedCover, '0:v:0'),
          );
          expect(
            latin1.decode(await File(path).readAsBytes()),
            contains('covr'),
            reason: 'M4A artwork must be stored in a covr atom',
          );
        }
      });
    }
  }
}
