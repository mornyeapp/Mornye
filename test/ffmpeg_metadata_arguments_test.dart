import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/ffmpeg_conversion.dart';
import 'package:mornye/services/ffmpeg_desktop.dart';
import 'package:mornye/services/ffmpeg_metadata.dart';
import 'package:mornye/utils/desktop_platform.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const paths = MethodChannel('plugins.flutter.io/path_provider');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory root;
  final commands = <List<String>>[];
  final metadataFiles = <String>[];

  setUp(() async {
    root = await Directory.systemTemp.createTemp('metadata-arguments-');
    commands.clear();
    metadataFiles.clear();
    messenger.setMockMethodCallHandler(paths, (_) async => root.path);
    debugDesktopPlatformOverride = true;
    DesktopFFmpegRunner.debugShared = DesktopFFmpegRunner(
      tools: () async => const DesktopFFmpegTools(ffmpegPath: 'ffmpeg'),
      startProcess: (executable, arguments) async {
        commands.add(List.of(arguments));
        for (var i = 0; i + 1 < arguments.length; i++) {
          if (arguments[i] != '-i') continue;
          final file = File(arguments[i + 1]);
          if (file.uri.pathSegments.last != 'tags.ffmetadata') continue;
          expect(await file.exists(), isTrue);
          expect(await file.length(), greaterThan(32767));
          metadataFiles.add(file.path);
        }
        // Observe the real process boundary without launching a conversion.
        throw ProcessException(executable, const [], 'Simulated start failure');
      },
    );
    for (final extension in ['flac', 'mp3', 'm4a', 'opus']) {
      await File.fromUri(
        root.uri.resolve('Song.$extension'),
      ).writeAsBytes([1, 2, 3, 4]);
    }
  });

  tearDown(() async {
    messenger.setMockMethodCallHandler(paths, null);
    DesktopFFmpegRunner.debugShared = null;
    debugDesktopPlatformOverride = null;
    await root.delete(recursive: true);
  });

  test(
    'metadata staging failure retains the source and removes reserved output',
    () async {
      messenger.setMockMethodCallHandler(
        paths,
        (_) async => Directory.fromUri(root.uri.resolve('missing/')).path,
      );
      final source = File.fromUri(root.uri.resolve('Song.flac'));
      final result = await FFmpegConversion.convertAudioFormat(
        inputPath: source.path,
        targetFormat: 'flac',
        bitrate: '128k',
        metadata: {'lyrics': List.filled(4000, 'Lyrics line\n').join()},
        sourceBitDepth: 16,
        deleteOriginal: false,
      );
      expect(result, isNull);
      expect(commands, isEmpty);
      expect(await source.readAsBytes(), [1, 2, 3, 4]);
      expect(await root.list().length, 4);
    },
  );

  for (final format in [
    'FLAC embed',
    'MP3 embed',
    'AAC/M4A embed',
    'Opus embed',
    'flac conversion',
    'alac conversion',
    'wav conversion',
    'aiff conversion',
  ]) {
    test('$format keeps long lyrics out of the Windows command line', () async {
      String source(String extension) =>
          File.fromUri(root.uri.resolve('Song.$extension')).path;
      final lyrics = List.filled(4000, 'Lyrics line\n').join();
      final tags = {'title': 'Song', 'lyrics': lyrics};
      final result = switch (format) {
        'FLAC embed' => await FFmpegMetadata.embedMetadata(
          flacPath: source('flac'),
          metadata: tags,
        ),
        'MP3 embed' => await FFmpegMetadata.embedMetadataToMp3(
          mp3Path: source('mp3'),
          metadata: tags,
        ),
        'AAC/M4A embed' => await FFmpegMetadata.embedMetadataToM4a(
          m4aPath: source('m4a'),
          metadata: tags,
        ),
        'Opus embed' => await FFmpegMetadata.embedMetadataToOpus(
          opusPath: source('opus'),
          metadata: tags,
        ),
        _ => await FFmpegConversion.convertAudioFormat(
          inputPath: source('flac'),
          targetFormat: format.split(' ').first,
          bitrate: '128k',
          metadata: tags,
          sourceBitDepth: 16,
          deleteOriginal: false,
        ),
      };
      expect(result, isNull);
      expect(commands, hasLength(1));
      expect(commands.single.join(' ').length, lessThan(32767));
      expect(
        commands.single.any((argument) => argument.contains(lyrics)),
        isFalse,
      );
      expect(metadataFiles, hasLength(1));
      expect(await File(metadataFiles.single).exists(), isFalse);
      for (final extension in ['flac', 'mp3', 'm4a', 'opus']) {
        expect(await File(source(extension)).readAsBytes(), [1, 2, 3, 4]);
      }
      expect(await root.list().where((entry) => entry is Directory).length, 0);
    });
  }

  test('MP3 lyrics edits preserve existing artwork streams and tags', () async {
    final source = File.fromUri(root.uri.resolve('Song.mp3'));
    await FFmpegMetadata.embedMetadataToMp3(
      mp3Path: source.path,
      metadata: const {'LYRICS': 'Found'},
      preserveMetadata: true,
    );
    expect(commands, hasLength(1));
    expect(commands.single, containsAllInOrder(['-map_metadata', '0']));
    expect(
      commands.single,
      containsAllInOrder(['-map', '0:v?', '-c:v', 'copy']),
    );
    expect(commands.single, containsAllInOrder(['-c:a', 'copy']));
    expect(await source.readAsBytes(), [1, 2, 3, 4]);
  });
}
