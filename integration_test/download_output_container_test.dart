import 'dart:convert';
import 'dart:io';

import 'package:ffmpeg_kit_flutter_new_audio/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_audio/return_code.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:mornye/models/download_result.dart';
import 'package:mornye/models/extension.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/services/download_metadata_embedding.dart';
import 'package:mornye/services/download_request_payload.dart';
import 'package:mornye/services/ffmpeg_probe.dart';
import 'package:mornye/services/platform_bridge.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.zarz.mornye/backend');
  late Directory root;
  late Directory output;
  late Directory sources;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('download-container-');
    output = await Directory('${root.path}/output').create();
    sources = await Directory('${root.path}/extensions').create();
    final data = await Directory('${root.path}/data').create();
    await PlatformBridge.initExtensionSystem(
      sources.path,
      data.path,
      masterKey: base64Encode(List<int>.filled(32, 1)),
      lyricsProviders: const [],
      lyricsFetchOptions: const {},
      allowedDirectories: [output.path],
    );
    final implementations = await PlatformBridge.getBackendImplementations();
    expect(implementations['downloads'], 'rust');
    expect(implementations['extensions'], 'rust');
  });

  tearDown(() async {
    await PlatformBridge.cleanupExtensions();
    await root.delete(recursive: true);
  });

  for (final (format, returnedExtension) in [
    ('m4a', 'm4a'),
    ('m4a', 'mp4'),
    ('m4a', 'flac'),
    ('mp3', 'mp3'),
    ('flac', 'flac'),
  ]) {
    for (final explicitWorkingPath in [false, true]) {
      testWidgets(
        'foreground $format returned as $returnedExtension (working: $explicitWorkingPath)',
        (tester) async {
          final fixture = File('${root.path}/fixture.$format');
          final codec = switch (format) {
            'm4a' => 'aac',
            'mp3' => 'libmp3lame',
            _ => 'flac',
          };
          final session = await FFmpegKit.executeWithArguments([
            '-y',
            '-f',
            'lavfi',
            '-i',
            'sine=frequency=440:sample_rate=44100',
            '-t',
            '0.25',
            '-c:a',
            codec,
            fixture.path,
          ]);
          expect(
            ReturnCode.isSuccess(await session.getReturnCode()),
            true,
            reason: await session.getOutput(),
          );
          final audio = await fixture.readAsBytes();
          final provider = await Directory(
            '${sources.path}/example.audio',
          ).create();
          await File('${provider.path}/manifest.json').writeAsString(
            jsonEncode({
              'name': 'example.audio',
              'version': '1',
              'description': 'Generic native-container fixture',
              'type': ['download_provider'],
              'permissions': {'file': true},
              'skipMetadataEnrichment': true,
            }),
          );
          await File('${provider.path}/index.js').writeAsString('''
registerExtension({
  checkAvailability() { return { available: true, track_id: 'track' }; },
  download(trackId, quality, outputPath) {
    const path = outputPath.slice(0, outputPath.lastIndexOf('.')) + '.$returnedExtension';
    file.writeBytes(path, ${jsonEncode(base64Encode(audio))});
    return { success: true, file_path: path };
  }
});
''');
          await PlatformBridge.loadExtensionsFromDir(sources.path);
          await PlatformBridge.setExtensionEnabled('example.audio', true);
          const settings = AppSettings(
            nativeDownloadWorkerEnabled: false,
            embedMetadata: true,
            embedLyrics: false,
            embedReplayGain: false,
          );
          final request = DownloadRequestPayload(
            service: 'example.audio',
            providerTrackId: 'track',
            trackName: 'Track',
            artistName: 'Artist & Guest',
            albumName: 'Album',
            outputDir: output.path,
            filenameFormat: '{title}',
            outputExt: '.flac',
            // MP4 bytes named .flac must never enter the Rust FLAC tag writer.
            embedMetadata: format == 'm4a' && returnedExtension == 'flac',
            embedLyrics: false,
            useExtensions: true,
            useFallback: false,
          );
          // These are the foreground queue's real bridge and explicit local
          // working-path contract. No service-owned worker or channel mock.
          final Map<String, dynamic> response;
          if (explicitWorkingPath) {
            final raw = await channel.invokeMethod<String>(
              'downloadByStrategy',
              jsonEncode({
                ...request.toJson(),
                'output_path': '${output.path}/working.flac',
              }),
            );
            response = Map<String, dynamic>.from(jsonDecode(raw!) as Map);
          } else {
            response = await PlatformBridge.downloadByStrategy(
              payload: request,
            );
          }
          expect(response['success'], true, reason: response.toString());
          final result = DownloadResult.fromMap(response);
          final suffix = '.$format';
          final stem = explicitWorkingPath ? 'working' : 'Track';
          expect(result.filePath, '${output.path}/$stem$suffix');
          expect(result.outputExtension(), suffix);
          expect(response['resolved_file_name'], 'Track$suffix');
          final downloaded = File(result.filePath!);
          expect(await downloaded.readAsBytes(), audio);
          if (format != 'flac') {
            expect(await File('${output.path}/$stem.flac').exists(), false);
          }
          final audioCodec = format == 'mp3' ? 'mp3' : codec;
          expect(await FFmpegProbe.audioCodec(downloaded.path), audioCodec);
          // The same tag writer used by the foreground queue must preserve
          // the native stream while embedding source credits into its container.
          await DownloadMetadataEmbedding(onReplayGain: (_, _, _) {}).embed(
            downloaded.path,
            const Track(
              id: 'example:track',
              name: 'Track',
              artistName: 'Artist & Guest',
              albumName: 'Album',
              duration: 1,
            ),
            settings: settings,
            extensionState: const ExtensionState(),
            format: format,
          );
          final metadata = await PlatformBridge.readFileMetadata(
            downloaded.path,
          );
          expect(metadata['title'], 'Track');
          expect(metadata['artist'], 'Artist & Guest');
          expect(metadata['album'], 'Album');
          expect(await FFmpegProbe.audioCodec(downloaded.path), audioCodec);
        },
      );
    }
  }
}
