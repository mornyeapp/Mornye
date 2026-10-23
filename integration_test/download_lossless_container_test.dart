import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ffmpeg_kit_flutter_new_audio/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_audio/return_code.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mornye/models/download_item.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/download_queue_provider.dart';
import 'package:mornye/providers/extension_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/services/app_state_database.dart';
import 'package:mornye/services/ffmpeg_probe.dart';
import 'package:mornye/services/platform_bridge.dart';

class _Paths extends PathProviderPlatform {
  _Paths(this._path);
  final String _path;
  @override
  Future<String?> getApplicationDocumentsPath() async => _path;
}

class _Settings extends SettingsNotifier {
  _Settings(this._path);
  final String _path;
  @override
  AppSettings build() => AppSettings(
    downloadDirectory: _path,
    nativeDownloadWorkerEnabled: false,
    autoFallback: false,
    embedLyrics: false,
    embedReplayGain: false,
    saveDownloadHistory: false,
  );
}

class _Extensions extends ExtensionNotifier {
  @override
  ExtensionState build() => const ExtensionState(
    isInitialized: true,
    extensions: [
      Extension(
        id: 'example.audio',
        name: 'example.audio',
        displayName: 'Example',
        version: '1',
        description: '',
        enabled: true,
        status: 'loaded',
        hasDownloadProvider: true,
        skipMetadataEnrichment: true,
        skipLyrics: true,
      ),
    ],
  );
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'foreground queue finalizes lossless M4A without provider hints',
    (tester) async {
      final root = await Directory.systemTemp.createTemp('lossless-queue-');
      final originalPaths = PathProviderPlatform.instance;
      PathProviderPlatform.instance = _Paths(root.path);
      SharedPreferences.setMockInitialValues({
        'app_state_migrated_queue_to_sqlite_v1': true,
      });
      final db = await AppStateDatabase.instance.database;
      final output = await Directory('${root.path}/output').create();
      final sources = await Directory('${root.path}/extensions').create();
      final data = await Directory('${root.path}/data').create();
      final scope = ProviderContainer(
        overrides: [
          settingsProvider.overrideWith(() => _Settings(output.path)),
          extensionProvider.overrideWith(_Extensions.new),
        ],
      );
      try {
        await PlatformBridge.initExtensionSystem(
          sources.path,
          data.path,
          masterKey: base64Encode(List<int>.filled(32, 1)),
          lyricsProviders: const [],
          lyricsFetchOptions: const {},
          allowedDirectories: [output.path],
        );
        final samples = <String, String>{};
        for (final codec in ['flac', 'aac', 'alac']) {
          final source = File('${root.path}/$codec.m4a');
          final session = await FFmpegKit.executeWithArguments([
            '-v',
            'error',
            '-f',
            'lavfi',
            '-i',
            'sine=frequency=997:sample_rate=48000',
            '-t',
            '0.3',
            '-c:a',
            codec,
            '-strict',
            '-2',
            '-f',
            'mp4',
            source.path,
          ]);
          expect(
            ReturnCode.isSuccess(await session.getReturnCode()),
            true,
            reason: await session.getOutput(),
          );
          samples[codec] = base64Encode(await source.readAsBytes());
        }
        final extension = await Directory(
          '${sources.path}/example.audio',
        ).create();
        await File('${extension.path}/manifest.json').writeAsString(
          jsonEncode({
            'name': 'example.audio',
            'version': '1',
            'description': 'Container fixture',
            'type': ['download_provider'],
            'permissions': {'file': true},
            'skipMetadataEnrichment': true,
          }),
        );
        await File('${extension.path}/index.js').writeAsString('''
const samples = ${jsonEncode(samples)};
registerExtension({
  checkAvailability(track) { return { available: true, track_id: track.id }; },
  download(trackId, quality, outputPath) {
    const codec = quality === 'ALAC' ? 'alac' : (quality === 'LOSSY_FALLBACK' ? 'aac' : 'flac');
    const path = outputPath.slice(0, outputPath.lastIndexOf('.')) + '.m4a';
    file.writeBytes(path, samples[codec]);
    return { success: true, file_path: path, output_extension: '.m4a' };
  }
});
''');
        await PlatformBridge.loadExtensionsFromDir(sources.path);
        await PlatformBridge.setExtensionEnabled('example.audio', true);
        binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
        final queue = scope.read(downloadQueueProvider.notifier);
        queue.pauseQueue(persistAcrossRestarts: false);
        await queue.flushQueuePersistence();
        for (final (quality, codec, extension) in [
          ('LOSSLESS', 'flac', '.flac'),
          ('LOSSY_FALLBACK', 'aac', '.m4a'),
          ('ALAC', 'alac', '.m4a'),
        ]) {
          final done = Completer<DownloadItem>();
          final id = queue.addToQueue(
            Track(
              id: 'example.audio:$codec',
              source: 'example.audio',
              name: 'Track $codec',
              artistName: 'Example artist',
              albumName: 'Example album',
              duration: 1,
            ),
            'example.audio',
            qualityOverride: quality,
          );
          DownloadItem? finished;
          final subscription = scope.listen(downloadQueueProvider, (_, next) {
            final item = next.items.where((item) => item.id == id).firstOrNull;
            if (item != null &&
                (item.status == DownloadStatus.completed ||
                    item.status == DownloadStatus.failed)) {
              finished = item;
            }
            // Successful items leave the queue before processing becomes idle.
            if (!next.isProcessing && finished != null && !done.isCompleted) {
              done.complete(finished);
            }
          });
          try {
            queue.resumeQueue();
            final item = await done.future.timeout(const Duration(seconds: 45));
            expect(item.status, DownloadStatus.completed, reason: item.error);
            expect(item.filePath, endsWith(extension));
            expect(await FFmpegProbe.audioCodec(item.filePath!), codec);
            expect(
              await FFmpegProbe.isNativeFlacFile(item.filePath!),
              codec == 'flac',
            );
            final tags = await PlatformBridge.readFileMetadata(item.filePath!);
            expect(tags['title'], 'Track $codec');
            expect(tags['artist'], 'Example artist');
          } finally {
            subscription.close();
          }
        }
        await queue.flushQueuePersistence();
      } finally {
        scope.dispose();
        await PlatformBridge.cleanupExtensions();
        await db.close();
        PathProviderPlatform.instance = originalPaths;
        await root.delete(recursive: true);
      }
    },
  );
}
