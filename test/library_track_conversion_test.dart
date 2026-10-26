import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/controllers/batch_track_actions.dart';
import 'package:mornye/utils/audio_conversion_utils.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const backend = MethodChannel('com.zarz.mornye/backend');
  const paths = MethodChannel('plugins.flutter.io/path_provider');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory directory;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('library-conversion-');
    messenger.setMockMethodCallHandler(paths, (_) async => directory.path);
  });

  tearDown(() async {
    messenger.setMockMethodCallHandler(backend, null);
    messenger.setMockMethodCallHandler(paths, null);
    await directory.delete(recursive: true);
  });

  Future<LibraryTrackConversionResult> convert(String path) =>
      convertLibraryTrack(
        filePath: path,
        metadata: {},
        trackName: 'Song',
        artistName: 'Artist',
        spotifyId: '',
        durationMs: 120000,
        sourceBitDepth: 24,
        sourceSampleRate: 96000,
        historyItem: null,
        localItem: null,
        targetFormat: 'FLAC',
        bitrate: '',
        losslessQuality: const LosslessConversionQuality(),
        losslessProcessing: const LosslessConversionProcessing(),
        keepOriginal: true,
        shouldEmbedLyrics: false,
        readArtistTagMode: () => throw StateError('Stop before encoding'),
        losslessLabels: const LosslessConversionLabels(
          original: 'Original',
          originalQuality: 'Original quality',
          lossless: 'Lossless',
        ),
        coverTempPrefix: 'cover_',
        treatEmptySafTempPathAsFailure: true,
        onCleanupFailed: (path, error) => fail('Cleanup failed: $error'),
      );

  test(
    'SAF metadata and artwork reuse the encoder copy and clean it',
    () async {
      const uri = 'content://library/document/song.wav';
      final copy = File('${directory.path}/song.wav');
      final calls = <String>[];
      String? coverPath;
      messenger.setMockMethodCallHandler(backend, (call) async {
        calls.add(call.method);
        final arguments = call.arguments as Map;
        switch (call.method) {
          case 'safCopyToTemp':
            expect(arguments['uri'], uri);
            await copy.writeAsString('source audio');
            return copy.path;
          case 'readFileMetadata':
            expect(arguments['file_path'], copy.path);
            expect(await copy.readAsString(), 'source audio');
            return jsonEncode({'title': 'Song', 'artist': 'Artist'});
          case 'extractCoverToFile':
            expect(arguments['audio_path'], copy.path);
            coverPath = arguments['output_path'] as String;
            await File(coverPath!).writeAsString('artwork');
            return jsonEncode({'success': true});
          default:
            fail('Unexpected source read or write: ${call.method}');
        }
      });

      final result = await convert(uri);

      expect(calls, [
        'safCopyToTemp',
        'readFileMetadata',
        'extractCoverToFile',
      ]);
      expect(result.failureStage, 'FFmpeg conversion');
      expect(result.error, isA<StateError>());
      expect(await copy.exists(), isFalse);
      expect(await File(coverPath!).exists(), isFalse);
    },
  );

  test('failed SAF copy stops before metadata, artwork or encoding', () async {
    final calls = <String>[];
    messenger.setMockMethodCallHandler(backend, (call) async {
      calls.add(call.method);
      expect(call.method, 'safCopyToTemp');
      return null;
    });

    final result = await convert('content://library/document/song.wav');

    expect(result.isPipelineFailure, isTrue);
    expect(result.failureStage, 'read SAF source');
    expect(calls, ['safCopyToTemp', 'safCopyToTemp']);
    expect(await directory.list().length, 0);
  });

  test('filesystem conversion reads the original without a SAF copy', () async {
    final source = File('${directory.path}/song.wav');
    await source.writeAsString('original audio');
    final calls = <String>[];
    messenger.setMockMethodCallHandler(backend, (call) async {
      calls.add(call.method);
      final arguments = call.arguments as Map;
      if (call.method == 'readFileMetadata') {
        expect(arguments['file_path'], source.path);
        return '{}';
      }
      expect(call.method, 'extractCoverToFile');
      expect(arguments['audio_path'], source.path);
      return jsonEncode({'error': 'No cover'});
    });

    await convert(source.path);

    expect(calls, ['readFileMetadata', 'extractCoverToFile']);
    expect(await source.readAsString(), 'original audio');
  });
}
