import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/download_item.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/download_queue_provider.dart';
import 'package:mornye/providers/extension_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/services/ffmpeg_desktop.dart';
import 'package:mornye/services/ffmpeg_support.dart';
import 'package:mornye/services/history_database.dart';
import 'package:mornye/services/notification_service.dart';
import 'package:mornye/services/platform_bridge.dart';
import 'package:mornye/utils/logger.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'performance_probe.dart';

class _Settings extends SettingsNotifier {
  _Settings(this.path, {required this.convert});
  final String path;
  final bool convert;

  @override
  AppSettings build() => AppSettings(
    downloadDirectory: path,
    nativeDownloadWorkerEnabled: false,
    concurrentDownloads: 1,
    autoFallback: false,
    embedLyrics: false,
    embedReplayGain: false,
    autoConvertDownloads: convert,
    autoConvertFormat: 'mp3',
    autoConvertBitrate: '192',
    saveDownloadHistory: true,
  );
}

class _Extensions extends ExtensionNotifier {
  @override
  ExtensionState build() => const ExtensionState(
    isInitialized: true,
    extensions: [
      Extension(
        id: 'example.pipeline',
        name: 'example.pipeline',
        displayName: 'Example Pipeline',
        version: '1',
        description: 'Local synthetic fixture',
        enabled: true,
        status: 'loaded',
        hasDownloadProvider: true,
        skipMetadataEnrichment: true,
        skipLyrics: true,
      ),
    ],
  );

  @override
  Future<void> ensureInitialized() async {}
}

void main() {
  final binding = PerformanceTestBinding.ensureInitialized();

  testWidgets('foreground download pipeline with local native fixtures', (
    tester,
  ) async {
    if (!Platform.isMacOS) {
      markTestSkipped('Desktop process instrumentation is scoped to macOS');
      return;
    }
    final probe = PerformanceProbe(binding, tester, suite: 'download_pipeline');
    final root = await Directory.systemTemp.createTemp('download-pipeline-');
    final output = await Directory('${root.path}/output').create();
    final sources = await Directory('${root.path}/extensions').create();
    final data = await Directory('${root.path}/data').create();
    final requests = <Map<String, Object?>>[];
    final processes = <Map<String, Object?>>[];
    final runs = <Map<String, Object?>>[];
    final fixtureHistoryIds = <String>[];
    final originalLogging = LogBuffer.loggingEnabled;
    final originalSink = LogBuffer.fileSink;
    final logs = <LogEntry>[];
    Stopwatch? runWatch;
    var permitRateLimitDownload = false;
    LogBuffer.loggingEnabled = true;
    LogBuffer.fileSink = (entry) {
      logs.add(entry);
      originalSink?.call(entry);
    };
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final base = 'http://127.0.0.1:${server.port}';
    const key = '00112233445566778899aabbccddeeff';
    final payloads = <String, List<int>>{};
    server.listen((request) async {
      final path = request.uri.path;
      final bytes = payloads[path];
      final event = <String, Object?>{
        'path': path,
        'method': request.method,
        'at_us': runWatch?.elapsedMicroseconds,
        'bytes': bytes?.length ?? 0,
      };
      requests.add(event);
      if (path == '/rate-limit') {
        request.response.headers.contentType = ContentType.json;
        request.response.headers.set(
          HttpHeaders.cacheControlHeader,
          'no-store',
        );
        request.response.write(jsonEncode({'busy': !permitRateLimitDownload}));
        await request.response.close();
        event['finished_us'] = runWatch?.elapsedMicroseconds;
        return;
      }
      if (bytes == null) {
        request.response.statusCode = HttpStatus.notFound;
      } else {
        request.response.contentLength = bytes.length;
        request.response.headers.contentType = path.endsWith('.png')
            ? ContentType('image', 'png')
            : ContentType('audio', 'mp4');
        for (var offset = 0; offset < bytes.length; offset += 8192) {
          request.response.add(
            bytes.sublist(offset, (offset + 8192).clamp(0, bytes.length)),
          );
          await request.response.flush();
          await Future<void>.delayed(const Duration(milliseconds: 2));
        }
      }
      await request.response.close();
      event['finished_us'] = runWatch?.elapsedMicroseconds;
    });
    SharedPreferences.setMockInitialValues({
      'app_state_migrated_queue_to_sqlite_v1': true,
    });
    try {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(() async {
        binding.scheduleFrame();
        await binding.endOfFrame.timeout(const Duration(seconds: 10));
        await (await getTemporaryDirectory()).create(recursive: true);
        for (final codec in ['flac', 'aac']) {
          final path = '${root.path}/$codec.m4a';
          final generated = await FFmpegExecution.arguments([
            '-v',
            'error',
            '-f',
            'lavfi',
            '-i',
            'sine=frequency=997:sample_rate=48000:duration=4',
            '-c:a',
            codec,
            '-strict',
            '-2',
            '-f',
            'mp4',
            path,
          ]);
          expect(generated.success, true, reason: generated.output);
          payloads['/$codec.m4a'] = await File(path).readAsBytes();
        }
        final encrypted = '${root.path}/encrypted.m4a';
        final generated = await FFmpegExecution.arguments([
          '-v',
          'error',
          '-i',
          '${root.path}/aac.m4a',
          '-c',
          'copy',
          '-encryption_scheme',
          'cenc-aes-ctr',
          '-encryption_key',
          key,
          '-encryption_kid',
          'ffeeddccbbaa99887766554433221100',
          encrypted,
        ]);
        expect(generated.success, true, reason: generated.output);
        payloads['/encrypted.m4a'] = await File(encrypted).readAsBytes();
        final cover = '${root.path}/cover.png';
        final image = await FFmpegExecution.arguments([
          '-v',
          'error',
          '-f',
          'lavfi',
          '-i',
          'color=c=blue:s=64x64',
          '-frames:v',
          '1',
          cover,
        ]);
        expect(image.success, true, reason: image.output);
        payloads['/cover.png'] = await File(cover).readAsBytes();
        await PlatformBridge.initExtensionSystem(
          sources.path,
          data.path,
          masterKey: base64Encode(List<int>.filled(32, 1)),
          lyricsProviders: const [],
          lyricsFetchOptions: const {},
          allowedDirectories: [output.path],
        );
        await PlatformBridge.setAllowPrivateNetwork(true);
        final implementations =
            await PlatformBridge.getBackendImplementations();
        expect(implementations['downloads'], 'rust');
        final provider = await Directory(
          '${sources.path}/example.pipeline',
        ).create();
        await File('${provider.path}/manifest.json').writeAsString(
          jsonEncode({
            'name': 'example.pipeline',
            'version': '1',
            'description': 'Provider-neutral local pipeline fixture',
            'type': ['download_provider'],
            'permissions': {
              'file': true,
              'network': ['127.0.0.1'],
              'allowHttp': true,
            },
            'skipMetadataEnrichment': true,
          }),
        );
        await File('${provider.path}/index.js').writeAsString('''
registerExtension({
  checkAvailability(track) { return { available: true, track_id: track.id }; },
  download(trackId, quality, outputPath) {
    if (quality === 'RATE_LIMIT' && fetch('$base/rate-limit').json().busy) {
      return { success: false, error_type: 'rate_limit',
        error: 'Synthetic busy retry-after: 300', retry_after_seconds: 300 };
    }
    const encrypted = quality === 'ENCRYPTED';
    const source = encrypted ? 'encrypted' : 'flac';
    const path = outputPath.slice(0, outputPath.lastIndexOf('.')) + '.m4a';
    const transfer = file.download('$base/' + source + '.m4a', path, {maxAttempts: 1});
    if (!transfer.success) return transfer;
    return { success: true, file_path: path, output_extension: '.m4a',
      decryption: encrypted ? { strategy: 'ffmpeg.mov_key', key: '$key',
        input_format: 'mov', output_extension: '.m4a' } : undefined };
  }
});
''');
        await PlatformBridge.loadExtensionsFromDir(sources.path);
        await PlatformBridge.setExtensionEnabled('example.pipeline', true);
        // Resolve the isolated bundle's permission prompt before timing.
        await NotificationService().showDownloadComplete(
          trackName: 'Synthetic fixture setup',
          artistName: 'Example',
        );
      });
      final permission = await FlutterLocalNotificationsPlugin()
          .resolvePlatformSpecificImplementation<
            MacOSFlutterLocalNotificationsPlugin
          >()
          ?.checkPermissions();
      DesktopFFmpegRunner.debugShared = DesktopFFmpegRunner(
        startProcess: (executable, arguments) async {
          final elapsed = Stopwatch()..start();
          final codecFlag = arguments.indexWhere(
            (argument) => argument == '-c:a' || argument == '-codec:a',
          );
          final codec = codecFlag >= 0 ? arguments[codecFlag + 1] : null;
          final event = <String, Object?>{
            'kind': executable.endsWith('ffprobe')
                ? 'probe'
                : arguments.contains('-decryption_key')
                ? 'decrypt'
                : codec == 'copy'
                ? 'remux_or_tag'
                : codec != null
                ? 'convert'
                : 'ffmpeg',
            'at_us': runWatch?.elapsedMicroseconds,
          };
          processes.add(event);
          final process = await Process.start(executable, arguments);
          unawaited(
            process.exitCode.then((code) {
              event['elapsed_us'] = elapsed.elapsedMicroseconds;
              event['exit_code'] = code;
            }),
          );
          return process;
        },
      );
      var sequence = 0;
      for (final kind in [
        'container',
        'encrypted',
        'auto_mp3',
        'cancel_retry',
      ]) {
        await probe.measure(
          kind,
          () async {
            permitRateLimitDownload = false;
            final scope = ProviderContainer(
              overrides: [
                settingsProvider.overrideWith(
                  () => _Settings(output.path, convert: kind == 'auto_mp3'),
                ),
                extensionProvider.overrideWith(_Extensions.new),
              ],
            );
            final statusEvents = <Map<String, Object?>>[];
            final historyEvents = <Map<String, Object?>>[];
            final requestStart = requests.length;
            final processStart = processes.length;
            final logStart = logs.length;
            final done = Completer<DownloadItem>();
            DownloadItem? completed;
            Future<void>? retried;
            int? cancellationAt;
            int? retryReadyAt;
            runWatch = Stopwatch()..start();
            try {
              final history = scope.read(downloadHistoryProvider.notifier);
              await history.reloadFromStorage();
              scope.listen(downloadHistoryProvider, (previous, next) {
                historyEvents.add({
                  'at_us': runWatch!.elapsedMicroseconds,
                  'items': next.items.length,
                  'index_version': next.loadedIndexVersion,
                });
              });
              final queue = scope.read(downloadQueueProvider.notifier);
              queue.pauseQueue(persistAcrossRestarts: false);
              await queue.flushQueuePersistence();
              final name = 'Fixture $kind ${sequence++}';
              final id = queue.addToQueue(
                Track(
                  id: 'example.pipeline:$name',
                  source: 'example.pipeline',
                  name: name,
                  artistName: 'Example Artist',
                  albumName: 'Example Album',
                  duration: 4,
                  coverUrl: '$base/cover.png',
                ),
                'example.pipeline',
                qualityOverride: kind == 'encrypted'
                    ? 'ENCRYPTED'
                    : kind == 'cancel_retry'
                    ? 'RATE_LIMIT'
                    : 'LOSSLESS',
              );
              fixtureHistoryIds.add(id);
              scope.listen(downloadQueueProvider, (previous, next) {
                final item = next.items
                    .where((item) => item.id == id)
                    .firstOrNull;
                if (kind == 'cancel_retry' &&
                    item?.errorType == DownloadErrorType.rateLimit &&
                    cancellationAt == null) {
                  cancellationAt = runWatch!.elapsedMicroseconds;
                  // Run after the status callback so the production delay has
                  // registered before cancellation reaches the old attempt.
                  scheduleMicrotask(() {
                    queue.cancelItem(id);
                    permitRateLimitDownload = true;
                    retried = queue.retryItem(id).then((_) {
                      retryReadyAt = runWatch!.elapsedMicroseconds;
                    });
                  });
                }
                if (item != null &&
                    (statusEvents.isEmpty ||
                        statusEvents.last['status'] != item.status.name)) {
                  statusEvents.add({
                    'at_us': runWatch!.elapsedMicroseconds,
                    'status': item.status.name,
                  });
                }
                if (item?.status == DownloadStatus.failed &&
                    !done.isCompleted) {
                  done.completeError(
                    StateError(item!.error ?? 'Download failed'),
                  );
                }
                if (item?.status == DownloadStatus.completed) {
                  expect(
                    scope
                        .read(downloadHistoryProvider)
                        .items
                        .any((row) => row.id == id),
                    true,
                    reason: 'History must be visible before completion',
                  );
                  completed = item;
                }
                if (!next.isProcessing &&
                    completed != null &&
                    !done.isCompleted) {
                  done.complete(completed);
                }
              });
              final admittedAt = runWatch!.elapsedMicroseconds;
              queue.resumeQueue();
              final item = await done.future.timeout(
                const Duration(seconds: 45),
              );
              final finishedAt = runWatch!.elapsedMicroseconds;
              if (retried != null) await retried;
              if (kind == 'cancel_retry') {
                expect(cancellationAt, isNotNull);
                expect(retryReadyAt, isNotNull);
              }
              final stored = await HistoryDatabase.instance.getById(id);
              expect(stored, isNotNull);
              expect(
                DownloadHistoryItem.fromJson(stored!).filePath,
                item.filePath,
              );
              expect(await File(item.filePath!).length(), greaterThan(0));
              expect(scope.read(downloadQueueProvider).items, isEmpty);
              final runProcesses = processes.sublist(processStart);
              final runRequests = requests.sublist(requestStart);
              final metadata = await PlatformBridge.readFileMetadata(
                item.filePath!,
              );
              expect(metadata['title'], name);
              expect(metadata['artist'], 'Example Artist');
              expect(
                metadata['audio_codec'],
                kind == 'auto_mp3'
                    ? 'mp3'
                    : kind == 'encrypted'
                    ? 'aac'
                    : 'flac',
              );
              final decode = await FFmpegExecution.arguments([
                '-v',
                'error',
                '-xerror',
                '-i',
                item.filePath!,
                '-f',
                'null',
                '-',
              ]);
              expect(decode.success, true, reason: decode.output);
              await queue.flushQueuePersistence();
              runs.add({
                'kind': kind,
                'enqueue_to_queue_idle_us': finishedAt - admittedAt,
                'setup_and_restore_us': admittedAt,
                if (cancellationAt != null)
                  'cancel_to_retry_ready_us': retryReadyAt! - cancellationAt!,
                'status_events': statusEvents,
                'history_events': historyEvents,
                'requests': runRequests,
                'desktop_processes': runProcesses,
                'finalization_stages': logs
                    .skip(logStart)
                    .where(
                      (entry) => entry.message.startsWith('Finalization [$id]'),
                    )
                    .map((entry) => entry.message.replaceAll(id, 'item'))
                    .toList(),
                'history_visible_before_completed': true,
                'durable_history_matches_output': true,
                'output_decodes': true,
                'notification_api_finished_before_removal': true,
                'notification_warning': logs
                    .skip(logStart)
                    .any(
                      (entry) => entry.message.startsWith(
                        'Download completed but notification failed:',
                      ),
                    ),
              });
            } catch (error) {
              debugPrint(
                'DOWNLOAD_PIPELINE_FAILURE: ${jsonEncode({'kind': kind, 'error': '$error', 'status_events': statusEvents, 'history_events': historyEvents, 'requests': requests.sublist(requestStart), 'desktop_processes': processes.sublist(processStart), 'logs': logs.skip(logStart).take(80).map((entry) => '${entry.tag}: ${entry.message}').toList()})}',
              );
              await probe.finish(
                metadata: {
                  'partial': true,
                  'failed_kind': kind,
                  'error': '$error',
                  'notification_permission_enabled': permission?.isEnabled,
                  'runs': runs,
                },
              );
              rethrow;
            } finally {
              runWatch = null;
              scope.dispose();
            }
          },
          warmup: () async {},
          repetitions: 2,
          allowIdle: true,
        );
      }
      await probe.finish(
        metadata: {
          'scope':
              'Real foreground queue, local HTTP extension transfer, CENC '
              'decrypt/container conversion, tags/cover, optional MP3 conversion, '
              'native metadata, SQLite history, completion notification API and removal. '
              'Setup excluded from per-run enqueue timings. No provider accounts. '
              'No native background worker, SAF, network upload or OS banner assertion.',
          'notification_permission_enabled': permission?.isEnabled,
          'runs': runs,
        },
      );
    } finally {
      DesktopFFmpegRunner.debugShared = null;
      LogBuffer.fileSink = originalSink;
      LogBuffer.loggingEnabled = originalLogging;
      await PlatformBridge.cleanupExtensions();
      await server.close(force: true);
      if (fixtureHistoryIds.isNotEmpty) {
        await HistoryDatabase.instance.deleteByIds(fixtureHistoryIds);
      }
      await root.delete(recursive: true);
    }
  });
}
