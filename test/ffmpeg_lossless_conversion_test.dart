import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/download_result.dart';
import 'package:mornye/services/download_file_finalizer.dart';
import 'package:mornye/services/ffmpeg_conversion.dart';
import 'package:mornye/models/ffmpeg_models.dart';
import 'package:mornye/services/ffmpeg_desktop.dart';
import 'package:mornye/services/ffmpeg_probe.dart';
import 'package:mornye/utils/audio_conversion_utils.dart';
import 'package:mornye/utils/desktop_platform.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late DesktopFFmpegTools tools;
  late DesktopFFmpegTools conversionTools;
  late Directory directory;
  var haveSoxr = false;

  setUpAll(() async {
    tools = await DesktopFFmpegTools.locate(
      environment: {'PATH': Platform.environment['PATH'] ?? ''},
    );
    // Fixture generation needs lavfi. A bundled converter can still be tested
    // via MORNYE_FFMPEG_DIR even when that bundle excludes input generators.
    conversionTools = await DesktopFFmpegTools.locate();
    if (conversionTools.ffmpegPath != null) {
      final configuration = await Process.run(conversionTools.ffmpegPath!, [
        '-buildconf',
      ]);
      haveSoxr = '${configuration.stdout}${configuration.stderr}'.contains(
        '--enable-libsoxr',
      );
    }
  });

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('lossless-conversion-');
    debugDesktopPlatformOverride = true;
    DesktopFFmpegRunner.debugShared = DesktopFFmpegRunner(
      tools: () async => conversionTools,
    );
  });

  tearDown(() async {
    debugDesktopPlatformOverride = null;
    DesktopFFmpegRunner.debugShared = null;
    await directory.delete(recursive: true);
  });

  bool haveTools() {
    if (tools.ffmpegPath != null &&
        tools.ffprobePath != null &&
        conversionTools.ffmpegPath != null &&
        conversionTools.ffprobePath != null) {
      return true;
    }
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

  test('CUE split keeps the original and preserves every PCM sample', () async {
    if (!haveTools()) return;
    final wav = await source(24, 48000);
    final input = '${directory.path}/Album.flac';
    await ffmpeg(['-i', wav, '-c:a', 'flac', input]);
    final originalHash = await pcmHash(input, 24);
    final folder = await Directory('${directory.path}/split').create();
    final existing = await File(
      '${folder.path}/01 - First.flac',
    ).writeAsString('existing split');
    final paths = await FFmpegConversion.splitCueToTracks(
      audioPath: input,
      outputDir: folder.path,
      tracks: [
        CueSplitTrackInfo(
          number: 1,
          title: 'First',
          artist: 'Artist',
          startSec: 0,
          endSec: 0.15,
        ),
        CueSplitTrackInfo(
          number: 2,
          title: 'Second',
          artist: 'Artist',
          startSec: 0.15,
          endSec: -1,
        ),
      ],
      albumMetadata: {'album': 'Album', 'artist': 'Artist'},
    );
    expect(paths, hasLength(2));
    expect(paths!.first, '${folder.path}/01 - First (2).flac');
    expect(await existing.readAsString(), 'existing split');
    expect(await File(input).exists(), isTrue);
    expect(await pcmHash(input, 24), originalHash);
    final combinedHash = await ffmpeg([
      '-i',
      paths[0],
      '-i',
      paths[1],
      '-filter_complex',
      '[0:a:0][1:a:0]concat=n=2:v=0:a=1[a]',
      '-map',
      '[a]',
      '-c:a',
      'pcm_s24le',
      '-f',
      'hash',
      '-hash',
      'sha256',
      '-',
    ]);
    expect(combinedHash, originalHash);
    for (final path in paths) {
      expect((await FFmpegProbe.audioProperties(path)).bitDepth, 24);
    }
  });

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

  for (final rate in [44100, 96000]) {
    test(
      'FLAC 16/48 caps preserve embedded artwork and tags at $rate',
      () async {
        if (!haveTools()) return;
        final wav = await source(24, rate);
        final input = '${directory.path}/Tagged.flac';
        await ffmpeg([
          '-i',
          wav,
          '-f',
          'lavfi',
          '-i',
          'color=c=blue:s=16x16',
          '-map',
          '0:a',
          '-map',
          '1:v',
          '-c:a',
          'flac',
          '-c:v',
          'png',
          '-frames:v',
          '1',
          '-disposition:v',
          'attached_pic',
          '-metadata',
          'TITLE=Song',
          '-metadata',
          'LYRICS=[00:01.00]Lyrics',
          input,
        ]);
        final output = await FFmpegConversion.convertAudioFormat(
          inputPath: input,
          targetFormat: 'flac',
          bitrate: '',
          metadata: const {},
          losslessQuality: const LosslessConversionQuality(
            maxBitDepth: 16,
            maxSampleRate: 48000,
          ),
        );
        expect(output, input);
        final properties = await FFmpegProbe.audioProperties(output!);
        expect(properties.bitDepth, 16);
        expect(properties.sampleRate, rate > 48000 ? 48000 : rate);
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
        final probe =
            jsonDecode(result.stdout as String) as Map<String, dynamic>;
        final tags = (probe['format'] as Map)['tags'] as Map;
        expect(tags['TITLE'], 'Song');
        expect(tags['LYRICS'], '[00:01.00]Lyrics');
        final streams = (probe['streams'] as List).cast<Map<String, dynamic>>();
        final artwork = streams.singleWhere((s) => s['codec_type'] == 'video');
        expect((artwork['disposition'] as Map)['attached_pic'], 1);
      },
    );
  }

  for (final format in ['flac', 'alac', 'wav', 'aiff']) {
    for (final (sourceDepth, targetDepth) in [(24, 16), (32, 24)]) {
      test('Smart dithers $format $sourceDepth to $targetDepth-bit', () async {
        if (!haveTools()) return;
        final input = await source(sourceDepth, 48000);
        Future<String> convert(String mode) async {
          final output = await FFmpegConversion.convertAudioFormat(
            inputPath: input,
            targetFormat: format,
            bitrate: '',
            metadata: const {},
            // Leave depth unspecified to exercise per-file probing.
            losslessQuality: LosslessConversionQuality(
              maxBitDepth: targetDepth,
            ),
            losslessProcessing: LosslessConversionProcessing(dither: mode),
            deleteOriginal: false,
          );
          expect(output, isNotNull);
          final properties = await FFmpegProbe.audioProperties(output!);
          expect(properties.bitDepth, targetDepth);
          expect(properties.sampleRate, 48000);
          return pcmHash(output, targetDepth);
        }

        final originalHash = await pcmHash(input, sourceDepth);
        final smart = await convert('auto');
        expect(smart, await convert('triangular'));
        expect(smart, isNot(await convert('none')));
        expect(await pcmHash(input, sourceDepth), originalHash);
      });
    }
  }

  for (final resampler in ['swr', 'soxr']) {
    for (final depth in [16, 24]) {
      test(
        'Smart preserves $depth-bit PCM without a reduction ($resampler)',
        () async {
          if (!haveTools()) return;
          final input = await source(depth, 44100);
          final originalHash = await pcmHash(input, depth);
          final output = await FFmpegConversion.convertAudioFormat(
            inputPath: input,
            targetFormat: 'flac',
            bitrate: '',
            metadata: const {},
            losslessQuality: const LosslessConversionQuality(
              maxBitDepth: 24,
              maxSampleRate: 48000,
            ),
            losslessProcessing: LosslessConversionProcessing(
              resampler: resampler,
            ),
            deleteOriginal: false,
          );
          expect(output, isNotNull);
          expect(await pcmHash(output!, depth), originalHash);
          final properties = await FFmpegProbe.audioProperties(output);
          expect(properties.bitDepth, depth);
          expect(properties.sampleRate, 44100);
        },
      );
    }

    test('Smart dithers after resampling with $resampler', () async {
      if (!haveTools()) return;
      if (resampler == 'soxr' && !haveSoxr) {
        markTestSkipped('Requires FFmpeg built with libsoxr');
        return;
      }
      final input = await source(24, 96000);
      final hashes = <String, String>{};
      for (final mode in ['auto', 'triangular', 'none']) {
        final output = await FFmpegConversion.convertAudioFormat(
          inputPath: input,
          targetFormat: 'flac',
          bitrate: '',
          metadata: const {},
          sourceBitDepth: 24,
          losslessQuality: const LosslessConversionQuality(
            maxBitDepth: 16,
            maxSampleRate: 48000,
          ),
          losslessProcessing: LosslessConversionProcessing(
            dither: mode,
            resampler: resampler,
          ),
          deleteOriginal: false,
        );
        expect(output, isNotNull);
        hashes[mode] = await pcmHash(output!, 16);
      }
      expect(hashes['auto'], hashes['triangular']);
      expect(hashes['auto'], isNot(hashes['none']));
    });

    test('every $resampler quality level converts, each its own way', () async {
      if (!haveTools()) return;
      if (resampler == 'soxr' && !haveSoxr) {
        markTestSkipped('Requires FFmpeg built with libsoxr');
        return;
      }
      final input = await source(24, 96000);
      final hashes = <String, String>{};
      for (final quality in [
        null,
        ...losslessResamplerQualityOptionsFor(resampler),
      ]) {
        final output = await FFmpegConversion.convertAudioFormat(
          inputPath: input,
          targetFormat: 'flac',
          bitrate: '',
          metadata: const {},
          sourceBitDepth: 24,
          losslessQuality: const LosslessConversionQuality(
            maxSampleRate: 44100,
          ),
          losslessProcessing: LosslessConversionProcessing(
            dither: 'none',
            resampler: resampler,
            resamplerQuality: quality,
          ),
          deleteOriginal: false,
        );
        expect(output, isNotNull, reason: '$quality');
        hashes['$quality'] = await pcmHash(output!, 24);
      }
      // No choice is the resampler's default level; the levels all differ.
      expect(
        hashes['null'],
        hashes[defaultLosslessResamplerQuality(resampler)],
      );
      expect(
        hashes.values.toSet(),
        hasLength(losslessResamplerQualityOptionsFor(resampler).length),
      );
    });
  }

  test('auto conversion writes ALAC M4A and then keeps it', () async {
    if (!haveTools()) return;
    final wav = await source(24, 96000);
    final input = '${directory.path}/Song.flac';
    await ffmpeg(['-i', wav, '-c:a', 'flac', '-metadata', 'TITLE=Song', input]);
    final aac = '${directory.path}/Other.m4a';
    await ffmpeg(['-i', wav, '-c:a', 'aac', '-b:a', '128k', aac]);
    final embedded = <String>[];
    // The same converter and probe the download queue wires in.
    final stage = DownloadFileFinalizer(
      decryptFile:
          ({
            required inputPath,
            required descriptor,
            required deleteOriginal,
            prepareOutput,
          }) async => null,
      probeCodec: FFmpegProbe.audioCodec,
      repairAc4: (_, _) async {},
      convertAudio:
          ({
            required inputPath,
            required targetFormat,
            required bitrate,
            required deleteOriginal,
            required losslessQuality,
            required losslessProcessing,
          }) => FFmpegConversion.convertAudioFormat(
            inputPath: inputPath,
            targetFormat: targetFormat,
            bitrate: bitrate,
            metadata: const {},
            deleteOriginal: deleteOriginal,
            losslessQuality: losslessQuality,
            losslessProcessing: losslessProcessing,
          ),
      replaceSafFile:
          ({
            required uri,
            required treeUri,
            required relativeDir,
            required op,
            avoidOverwrite = false,
            onPublishedFileName,
          }) async => null,
      warn: (message) => fail(message),
      info: (_) {},
    );
    Future<DownloadConversionOutcome> convert(String path) => stage.autoConvert(
      result: DownloadResult.fromMap({}),
      filePath: path,
      fileName: path.split('/').last,
      quality: '24-bit/96kHz',
      enabled: true,
      targetFormat: 'alac',
      targetBitrate: '320k',
      useSaf: false,
      losslessQuality: const LosslessConversionQuality(
        maxBitDepth: 16,
        maxSampleRate: 48000,
      ),
      embedMetadata: (_, format) async => embedded.add(format),
    );

    final outcome = await convert(input);
    expect(outcome.converted, isTrue);
    expect(outcome.filePath, '${directory.path}/Song.m4a');
    expect(outcome.fileName, 'Song.m4a');
    expect(outcome.quality, '16-bit/48kHz');
    expect(await File(input).exists(), isFalse);
    expect(embedded, ['m4a']);
    final properties = await FFmpegProbe.audioProperties(outcome.filePath);
    expect(properties.codec, 'alac');
    expect(properties.bitDepth, 16);
    expect(properties.sampleRate, 48000);
    final format = await Process.run(tools.ffprobePath!, [
      '-v',
      'error',
      '-show_entries',
      'format=format_name:format_tags=major_brand',
      '-of',
      'json',
      outcome.filePath,
    ]);
    final container =
        (jsonDecode(format.stdout as String) as Map)['format'] as Map;
    expect(container['format_name'], contains('m4a'));
    expect((container['tags'] as Map)['major_brand'], 'M4A ');

    // A second pass finds ALAC within the caps; AAC in .m4a is lossy.
    for (final path in [outcome.filePath, aac]) {
      final kept = await convert(path);
      expect(kept.converted, isFalse);
      expect(kept.filePath, path);
    }
    expect(embedded, ['m4a']);
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
