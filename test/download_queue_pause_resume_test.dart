import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';
import 'package:mornye/models/download_item.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/download_queue_provider.dart';
import 'package:mornye/providers/extension_provider.dart';
import 'package:mornye/providers/settings_provider.dart';

class _Settings extends SettingsNotifier {
  _Settings(this.directory);
  final String directory;

  @override
  AppSettings build() => AppSettings(
    downloadDirectory: directory,
    saveDownloadHistory: false,
    autoFallback: false,
    concurrentDownloads: 1,
  );
}

class _Extensions extends ExtensionNotifier {
  @override
  ExtensionState build() => ExtensionState(
    extensions: [
      Extension.fromJson({
        'id': 'example-provider',
        'name': 'Example Provider',
        'enabled': true,
        'has_download_provider': true,
        'has_metadata_provider': true,
        'skip_metadata_enrichment': true,
      }),
    ],
  );

  @override
  Future<void> ensureInitialized() async {}
}

class _Queue extends DownloadQueueNotifier {
  _Queue(this.albumId);
  final String albumId;

  @override
  DownloadQueueState build() {
    super.build();
    return const DownloadQueueState().copyWith(
      isPaused: true,
      items: [
        DownloadItem(
          id: 'song',
          track: Track(
            id: 'example:track',
            name: 'Song',
            artistName: 'Artist',
            albumName: 'Album',
            albumId: albumId,
            source: 'example-provider',
            duration: 180,
          ),
          service: 'example-provider',
          createdAt: DateTime.utc(2026),
        ),
      ],
    );
  }
}

void main() {
  final messenger =
      TestWidgetsFlutterBinding.ensureInitialized().defaultBinaryMessenger;
  const backend = MethodChannel('com.zarz.mornye/backend');
  const sqlite = MethodChannel('com.tekartik.sqflite');
  const paths = MethodChannel('plugins.flutter.io/path_provider');
  const notifications = MethodChannel(
    'dexterous.com/flutter/local_notifications',
  );
  const connectivity = MethodChannel(
    'dev.fluttercommunity.plus/connectivity_status',
  );
  const progress = MethodChannel('com.zarz.mornye/download_progress_stream');

  final previousFactory = databaseFactoryOrNull;
  setUpAll(() {
    databaseFactory = databaseFactorySqflitePlugin;
    AndroidFlutterLocalNotificationsPlugin.registerWith();
  });
  tearDownAll(() => databaseFactory = previousFactory);
  tearDown(() {
    for (final channel in [
      backend,
      sqlite,
      paths,
      notifications,
      connectivity,
      progress,
    ]) {
      messenger.setMockMethodCallHandler(channel, null);
    }
  });

  for (final beforeTransfer in [true, false]) {
    for (final immediateResume in [false, true]) {
      test(
        'resume restarts after pause (before transfer: $beforeTransfer, immediate: $immediateResume)',
        () async {
          final directory = await Directory.systemTemp.createTemp(
            'queue-resume-',
          );
          addTearDown(() => directory.delete(recursive: true));
          SharedPreferences.setMockInitialValues({
            'app_state_migrated_queue_to_sqlite_v1': true,
          });
          messenger.setMockMethodCallHandler(
            paths,
            (_) async => directory.path,
          );
          messenger.setMockMethodCallHandler(connectivity, (_) async => null);
          messenger.setMockMethodCallHandler(progress, (_) async => null);
          messenger.setMockMethodCallHandler(
            notifications,
            (call) async => call.method == 'initialize' ? true : null,
          );
          messenger.setMockMethodCallHandler(sqlite, (call) async {
            if (call.method == 'openDatabase') return {'id': 1};
            if (call.method != 'query') return null;
            final sql = (call.arguments as Map)['sql'] as String;
            return sql.toLowerCase().contains('pragma user_version')
                ? {
                    'columns': ['user_version'],
                    'rows': [
                      [4],
                    ],
                  }
                : {'columns': <String>[], 'rows': <List<Object?>>[]};
          });

          final started = Completer<void>();
          final releaseAttempt = Completer<void>();
          final cancelRequested = Completer<void>();
          final releaseCancel = Completer<void>();
          var cancelled = false;
          var metadataCalls = 0;
          var attempts = 0;
          final resetIds = <String>[];
          messenger.setMockMethodCallHandler(backend, (call) async {
            if (call.method == 'getProviderMetadata') {
              if (beforeTransfer && metadataCalls++ == 0) {
                started.complete();
                await releaseAttempt.future;
              }
              return {'album_artist': 'Artist'};
            }
            if (call.method == 'cancelDownload') {
              cancelRequested.complete();
              await releaseCancel.future;
              // No native lease existed, or it already unwound. This leaves
              // an idle cancellation sentinel until explicitly reset.
              cancelled = true;
            }
            if (call.method == 'resetDownloadCancel') {
              resetIds.add((call.arguments as Map)['item_id'] as String);
              cancelled = false;
            }
            if (call.method != 'downloadByStrategy') return null;
            final request = jsonDecode(call.arguments as String) as Map;
            expect(request['item_id'], 'song');
            attempts++;
            if (!beforeTransfer && attempts == 1) {
              started.complete();
              await releaseAttempt.future;
              return {'success': false, 'error_type': 'cancelled'};
            }
            // Reaching this provider response proves the fresh transfer ran.
            return {
              'success': false,
              'error_type': cancelled ? 'cancelled' : 'not_found',
              'error': cancelled ? 'Cancelled' : 'Fixture provider reached',
            };
          });

          final container = ProviderContainer(
            overrides: [
              settingsProvider.overrideWith(() => _Settings(directory.path)),
              extensionProvider.overrideWith(_Extensions.new),
              downloadQueueProvider.overrideWith(
                () => _Queue('album-$beforeTransfer-$immediateResume'),
              ),
            ],
          );
          addTearDown(container.dispose);
          var finished = Completer<void>();
          container.listen(downloadQueueProvider, (previous, next) {
            if (previous?.isProcessing == true &&
                !next.isProcessing &&
                !finished.isCompleted) {
              finished.complete();
            }
          });
          final queue = container.read(downloadQueueProvider.notifier);
          await queue.flushQueuePersistence();
          queue.resumeQueue();
          await started.future.timeout(const Duration(seconds: 5));
          queue.pauseQueue();
          await cancelRequested.future;
          expect(
            container.read(downloadQueueProvider).items.single.progress,
            0,
          );
          if (immediateResume) queue.resumeQueue();
          releaseAttempt.complete();
          await Future<void>.delayed(const Duration(milliseconds: 25));
          final attemptsBeforeCancel = attempts;
          releaseCancel.complete();
          if (!immediateResume) {
            await finished.future.timeout(const Duration(seconds: 5));
            finished = Completer<void>();
            queue.resumeQueue();
          }
          await finished.future.timeout(const Duration(seconds: 5));
          expect(
            attemptsBeforeCancel,
            beforeTransfer ? 0 : 1,
            reason: 'A late cancel must finish before starting again',
          );
          expect(resetIds, ['song']);
          expect(attempts, beforeTransfer ? 1 : 2);
          expect(container.read(downloadQueueProvider).isPaused, isFalse);
          expect(
            container.read(downloadQueueProvider).items.single.errorType,
            DownloadErrorType.notFound,
          );
          await queue.flushQueuePersistence();
        },
      );
    }
  }
}
