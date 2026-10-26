import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/ffmpeg_conversion.dart';
import 'package:mornye/services/ffmpeg_desktop.dart';
import 'package:mornye/services/ffmpeg_probe.dart';
import 'package:mornye/utils/audio_conversion_utils.dart';
import 'package:mornye/utils/desktop_platform.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late DesktopFFmpegTools tools;
  late Directory directory;

  setUpAll(() async {
    tools = await DesktopFFmpegTools.locate(
      environment: {'PATH': Platform.environment['PATH'] ?? ''},
    );
  });

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('lossless-conversion-');
    debugDesktopPlatformOverride = true;
    DesktopFFmpegRunner.debugShared = DesktopFFmpegRunner(
      tools: () async => tools,
    );
  });

  tearDown(() async {
    debugDesktopPlatformOverride = null;
    DesktopFFmpegRunner.debugShared = null;
    await directory.delete(recursive: true);
  });

  bool haveTools() {
    if (tools.ffmpegPath != null && tools.ffprobePath != null) return true;
    markTestSkipped('Requires ffmpeg and ffprobe on PATH');
    return false;
  }

  Future<String> ffmpeg(List<String> arguments) async {
    final result = await Process.run(tools.ffmpegPath!, [
      '-nostdin',
      '-v',
      'error',
      ...arguments,
    ]);
    expect(result.exitCode, 0, reason: result.stderr.toString());
    return result.stdout as String;
  }

  Future<String> source(int depth, int rate) async {
    final path = '${directory.path}/Song "live".wav';
    await ffmpeg([
      '-f',
      'lavfi',
      '-i',
      'aevalsrc=0.4*sin(440*2*PI*t)|0.3*sin(997*2*PI*t):s=$rate:d=0.3',
      '-c:a',
      'pcm_s${depth}le',
      path,
    ]);
    return path;
  }

  Future<String> pcmHash(String path, int depth) => ffmpeg([
    '-i',
    path,
    '-map',
    '0:a:0',
    '-c:a',
    'pcm_s${depth}le',
    '-f',
    'hash',
    '-hash',
    'sha256',
    '-',
  ]);

  for (final (depth, rate) in [(16, 44100), (24, 96000)]) {
    test('WAV to FLAC preserves $depth-bit PCM, tags and artwork', () async {
      if (!haveTools()) return;
      final path = await source(depth, rate);
      final originalHash = await pcmHash(path, depth);
      final cover = '${directory.path}/cover.png';
      await ffmpeg([
        '-f',
        'lavfi',
        '-i',
        'color=c=blue:s=16x16',
        '-frames:v',
        '1',
        cover,
      ]);
      final sibling = File('${directory.path}/Song "live".flac');
      await sibling.writeAsString('existing sibling');

      final output = await FFmpegConversion.convertAudioFormat(
        inputPath: path,
        targetFormat: 'flac',
        bitrate: '',
        metadata: const {
          'TITLE': 'Lagu',
          'ARTIST': 'Artist',
          'ALBUM': 'Album',
          'LYRICS': '[00:01.00]Lyrics',
        },
        coverPath: cover,
        sourceBitDepth: depth,
      );

      expect(output, '${directory.path}/Song "live" (2).flac');
      expect(await File(path).exists(), isFalse);
      expect(await sibling.readAsString(), 'existing sibling');
      expect(await pcmHash(output!, depth), originalHash);
      final properties = await FFmpegProbe.audioProperties(output);
      expect(properties.codec, 'flac');
      expect(properties.bitDepth, depth);
      expect(properties.sampleRate, rate);

      final result = await Process.run(tools.ffprobePath!, [
        '-v',
        'error',
        '-show_format',
        '-show_streams',
        '-of',
        'json',
        output,
      ]);
      expect(result.exitCode, 0, reason: result.stderr.toString());
      final probe = jsonDecode(result.stdout as String) as Map<String, dynamic>;
      final tags = (probe['format'] as Map<String, dynamic>)['tags'] as Map;
      expect(tags['TITLE'], 'Lagu');
      expect(tags['ARTIST'], 'Artist');
      expect(tags['LYRICS'], '[00:01.00]Lyrics');
      final streams = (probe['streams'] as List).cast<Map<String, dynamic>>();
      final artwork = streams.singleWhere((s) => s['codec_type'] == 'video');
      expect((artwork['disposition'] as Map)['attached_pic'], 1);
    });
  }

  test('WAV quality caps still apply and can keep the original', () async {
    if (!haveTools()) return;
    final path = await source(24, 96000);
    final originalHash = await pcmHash(path, 24);
    final output = await FFmpegConversion.convertAudioFormat(
      inputPath: path,
      targetFormat: 'flac',
      bitrate: '',
      metadata: const {},
      sourceBitDepth: 24,
      losslessQuality: const LosslessConversionQuality(
        maxBitDepth: 16,
        maxSampleRate: 44100,
      ),
      losslessProcessing: const LosslessConversionProcessing(
        dither: 'triangular',
      ),
      deleteOriginal: false,
    );

    expect(output, isNotNull);
    final properties = await FFmpegProbe.audioProperties(output!);
    expect(properties.bitDepth, 16);
    expect(properties.sampleRate, 44100);
    expect(await pcmHash(path, 24), originalHash);
  });

  test('invalid WAV preserves the source and removes partial FLAC', () async {
    if (!haveTools()) return;
    final path = File('${directory.path}/invalid.wav');
    await path.writeAsString('not audio');
    expect(
      await FFmpegConversion.convertAudioFormat(
        inputPath: path.path,
        targetFormat: 'flac',
        bitrate: '',
        metadata: const {},
      ),
      isNull,
    );
    expect(await path.readAsString(), 'not audio');
    expect(await directory.list().length, 1);
  });
}
