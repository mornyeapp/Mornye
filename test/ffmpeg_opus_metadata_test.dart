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

  const originalTags = {
    'title': 'Example Song',
    'artist': 'Example Artist',
    'album': 'Example Album',
    'album_artist': 'Album Artist',
    'date': '2026-01-02',
    'genre': 'Rock',
    'composer': 'Example Composer',
    'lyrics': 'Existing lyrics',
    'replaygain_track_gain': '-4.00 dB',
    'custom_tag': 'Keep this tag',
  };

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
    directory = await Directory.systemTemp.createTemp('opus-metadata-');
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
    expect(arguments.join(' ').length, lessThan(32767));
    final result = await Process.run('ffmpeg', arguments);
    return FFmpegResult(
      success: result.exitCode == 0,
      returnCode: result.exitCode,
      output: '${result.stdout}${result.stderr}',
    );
  }

  Future<String> audioHash(String path) async {
    final result = await run('ffmpeg', [
      '-v',
      'error',
      '-i',
      path,
      '-map',
      '0:a:0',
      '-c:a',
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

  for (final cover in [
    (
      fileName: 'cover.png',
      mimeType: 'image/png',
      signature: [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a],
      length: 1024 * 1024,
    ),
    (
      fileName: 'cover.jpeg',
      mimeType: 'image/jpeg',
      signature: [0xff, 0xd8],
      length: 256,
    ),
    (
      fileName: 'cover.image',
      mimeType: 'image/png',
      signature: [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a],
      length: 512,
    ),
  ]) {
    test(
      'Opus picture block preserves every byte of ${cover.fileName}',
      () async {
        final imageBytes = List<int>.generate(
          cover.length,
          (index) => index & 0xff,
        );
        imageBytes.setRange(0, cover.signature.length, cover.signature);
        final coverFile = File('${directory.path}/${cover.fileName}');
        await coverFile.writeAsBytes(imageBytes);
        final opusPath = '${directory.path}/track.opus';
        final audioBytes = [0x4f, 0x67, 0x67, 0x53];
        await File(opusPath).writeAsBytes(audioBytes);
        List<int>? pictureBytes;
        String? pictureMetadataPath;

        expect(
          await FFmpegMetadata.embedMetadataToOpus(
            opusPath: opusPath,
            coverPath: coverFile.path,
            metadata: const {'METADATA_BLOCK_PICTURE': 'obsolete cover'},
            execute: (arguments) async {
              expect(
                arguments.join(' ').length,
                lessThan(32767),
                reason: 'Cover bytes must not exceed the Windows command limit',
              );
              const prefix = 'METADATA_BLOCK_PICTURE=';
              final format = arguments.indexOf('ffmetadata');
              if (cover.length > 32767) {
                expect(format, greaterThan(0));
                expect(
                  arguments.any((argument) => argument.startsWith(prefix)),
                  isFalse,
                );
              }
              if (format >= 0) {
                pictureMetadataPath = arguments[format + 2];
                final lines = await File(pictureMetadataPath!).readAsLines();
                expect(lines.first, ';FFMETADATA1');
                final picture = lines.singleWhere(
                  (argument) => argument.startsWith(prefix),
                );
                pictureBytes = base64Decode(
                  picture.substring(prefix.length).replaceAll(r'\=', '='),
                );
              } else {
                final picture = arguments.lastWhere(
                  (argument) => argument.startsWith(prefix),
                );
                pictureBytes = base64Decode(picture.substring(prefix.length));
              }
              await File(
                arguments[arguments.length - 2],
              ).writeAsBytes(audioBytes);
              return FFmpegResult(success: true, returnCode: 0, output: '');
            },
          ),
          opusPath,
        );

        final mimeBytes = utf8.encode(cover.mimeType);
        expect(pictureBytes, [
          0, 0, 0, 3, // Front cover.
          0, 0, 0, mimeBytes.length,
          ...mimeBytes,
          ...List<int>.filled(20, 0), // Empty description and image dimensions.
          (cover.length >> 24) & 0xff,
          (cover.length >> 16) & 0xff,
          (cover.length >> 8) & 0xff,
          cover.length & 0xff,
          ...imageBytes,
        ]);
        expect(await File(opusPath).readAsBytes(), audioBytes);
        if (pictureMetadataPath != null) {
          expect(await File(pictureMetadataPath!).exists(), isFalse);
        }
      },
    );
  }

  for (final throws in [false, true]) {
    test(
      'failed Opus embedding cleans temporary files (throws=$throws)',
      () async {
        final source = File('${directory.path}/track.opus');
        final original = [0x4f, 0x67, 0x67, 0x53];
        await source.writeAsBytes(original);
        final cover = File('${directory.path}/cover.png');
        await cover.writeAsBytes([0x89, 0x50, 0x4e, 0x47]);
        String? pictureMetadataPath;
        String? output;
        final embedding = FFmpegMetadata.embedMetadataToOpus(
          opusPath: source.path,
          coverPath: cover.path,
          metadata: {'lyrics': List.filled(4000, 'Lyrics line\n').join()},
          execute: (arguments) async {
            pictureMetadataPath =
                arguments[arguments.indexOf('ffmetadata') + 2];
            output = arguments[arguments.length - 2];
            expect(await File(pictureMetadataPath!).exists(), isTrue);
            await File(output!).writeAsString('partial output');
            if (throws) throw StateError('FFmpeg could not start');
            return FFmpegResult(
              success: false,
              returnCode: 1,
              output: 'failed',
            );
          },
        );
        if (throws) {
          await expectLater(embedding, throwsStateError);
        } else {
          expect(await embedding, isNull);
        }
        expect(await source.readAsBytes(), original);
        expect(await File(pictureMetadataPath!).exists(), isFalse);
        expect(await File(output!).exists(), isFalse);
        expect(
          await directory.list().where((entry) => entry is Directory).length,
          0,
        );
      },
    );
  }

  for (final scenario in [
    (
      name: 'ISRC only',
      metadata: {'isrc': 'USABC2600001'},
      cover: false,
      preserve: true,
    ),
    (
      name: 'selected fields',
      metadata: {
        'title': 'Updated Song',
        'artist': 'Updated Artist',
        'album': 'Updated Album',
        'genre': 'Jazz',
      },
      cover: false,
      preserve: true,
    ),
    (
      name: 'cover only',
      metadata: <String, String>{},
      cover: true,
      preserve: true,
    ),
    (
      name: 'full replacement',
      metadata: {'title': 'New Song', 'artist': 'New Artist'},
      cover: false,
      preserve: false,
    ),
    (
      name: 'full replacement with a large cover',
      metadata: {
        'title': 'Song 音楽',
        'artist': 'Артист',
        'lyrics': List.filled(4000, 'Line = #; \\ \r\n音楽 😀\n').join(),
      },
      cover: true,
      preserve: false,
    ),
  ]) {
    test('Opus ${scenario.name} survives a metadata reread', () async {
      if (!toolsAvailable) {
        markTestSkipped('Requires ffmpeg and ffprobe on PATH');
        return;
      }
      final cache = await Directory('${directory.path}/cache').create();
      final path = '${cache.path}/Example "Song" - Example Artist.opus';
      await run('ffmpeg', [
        '-v',
        'error',
        '-f',
        'lavfi',
        '-i',
        'sine=frequency=440:duration=0.1',
        '-c:a',
        'libopus',
        for (final tag in originalTags.entries) ...[
          '-metadata',
          '${tag.key}=${tag.value}',
        ],
        path,
      ]);
      final beforeHash = await audioHash(path);

      String? coverPath;
      if (scenario.cover) {
        coverPath = '${directory.path}/cover.png';
        await run('ffmpeg', [
          '-v',
          'error',
          '-f',
          'lavfi',
          '-i',
          'testsrc=size=1024x1024,noise=alls=20:allf=t',
          '-frames:v',
          '1',
          coverPath,
        ]);
        expect(
          base64Encode(await File(coverPath).readAsBytes()).length,
          greaterThan(32767),
        );
      }
      expect(
        await FFmpegMetadata.embedMetadataToOpus(
          opusPath: path,
          coverPath: coverPath,
          metadata: scenario.metadata,
          preserveMetadata: scenario.preserve,
          execute: execute,
        ),
        path,
      );

      final probe = await run('ffprobe', [
        '-v',
        'error',
        '-show_streams',
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
      final tags = (audio['tags'] as Map<String, dynamic>).map(
        (key, value) => MapEntry(key.toLowerCase(), value.toString()),
      );
      expect(
        tags,
        containsPair(
          'title',
          scenario.metadata['title'] ?? originalTags['title'],
        ),
      );
      expect(
        tags,
        containsPair(
          'artist',
          scenario.metadata['artist'] ?? originalTags['artist'],
        ),
      );
      for (final tag in originalTags.entries) {
        if (scenario.preserve || scenario.metadata.containsKey(tag.key)) {
          expect(
            tags[tag.key],
            scenario.metadata[tag.key] ?? tag.value,
            reason: tag.key,
          );
        } else {
          expect(tags, isNot(contains(tag.key)));
        }
      }
      for (final tag in scenario.metadata.entries) {
        expect(tags[tag.key], tag.value);
      }
      if (scenario.cover) {
        expect(
          streams.any(
            (stream) =>
                stream['codec_type'] == 'video' &&
                (stream['disposition']
                        as Map<String, dynamic>)['attached_pic'] ==
                    1,
          ),
          isTrue,
        );
        final picture = streams.singleWhere(
          (stream) => stream['codec_type'] == 'video',
        );
        expect(picture['width'], 1024);
        expect(picture['height'], 1024);
        final extracted = '${directory.path}/extracted.png';
        await run('ffmpeg', [
          '-v',
          'error',
          '-i',
          path,
          '-map',
          '0:v:0',
          '-c:v',
          'copy',
          extracted,
        ]);
        expect(
          await File(extracted).readAsBytes(),
          await File(coverPath!).readAsBytes(),
        );
      }
      expect(
        await audioHash(path),
        beforeHash,
        reason: 'Re-enrich must preserve the encoded audio',
      );
    });
  }
}
