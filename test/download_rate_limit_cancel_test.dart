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
        'skip_metadata_enrichment': true,
      }),
    ],
  );

  @override
  Future<void> ensureInitialized() async {}
}

class _Queue extends DownloadQueueNotifier {
  @override
  DownloadQueueState build() {
    super.build();
    return const DownloadQueueState().copyWith(
      isPaused: true,
      items: [
        DownloadItem(
          id: 'song',
          track: const Track(
            id: 'example:track',
            name: 'Song',
            artistName: 'Artist',
            albumName: 'Album',
            source: 'example-provider',
            duration: 1,
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

  for (final synchronous in [true, false]) {
    for (final action in ['retry', 'retryAll', 'pause', 'dismiss', 'clear']) {
      test(
        '$action releases 300s backoff (synchronous: $synchronous)',
        () async {
          final directory = await Directory.systemTemp.createTemp('backoff-');
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
          var attempts = 0;
          var resets = 0;
          messenger.setMockMethodCallHandler(backend, (call) async {
            if (call.method == 'getProviderMetadata') {
              return {'album_artist': 'Artist'};
            }
            if (call.method == 'resetDownloadCancel' ||
                call.method == 'resetDownloadCancels') {
              resets++;
            }
            if (call.method != 'downloadByStrategy') return null;
            final request = jsonDecode(call.arguments as String) as Map;
            expect(request['item_id'], 'song');
            attempts++;
            return attempts == 1
                ? {
                    'success': false,
                    'error_type': 'rate_limit',
                    'error': 'Busy retry-after: 300',
                  }
                : {
                    'success': false,
                    'error_type': 'not_found',
                    'error': 'Fresh attempt reached provider',
                  };
          });
          final container = ProviderContainer(
            overrides: [
              settingsProvider.overrideWith(() => _Settings(directory.path)),
              extensionProvider.overrideWith(_Extensions.new),
              downloadQueueProvider.overrideWith(_Queue.new),
            ],
          );
          addTearDown(container.dispose);
          final queue = container.read(downloadQueueProvider.notifier);
          await queue.flushQueuePersistence();
          final acted = Completer<void>();
          final settled = Completer<void>();
          var interrupted = false;
          Future<void>? retried;
          void interrupt() {
            switch (action) {
              case 'retry':
              case 'retryAll':
                queue.cancelItem('song');
                retried = action == 'retry'
                    ? queue.retryItem('song')
                    : queue.retryAllFailed();
              case 'pause':
                queue.pauseQueue(persistAcrossRestarts: false);
                queue.resumeQueue();
              case 'dismiss':
                queue.dismissItem('song');
              case 'clear':
                queue.clearAll();
            }
            acted.complete();
          }

          container.listen(downloadQueueProvider, (previous, next) {
            final item = next.items.firstOrNull;
            if (!interrupted &&
                item?.errorType == DownloadErrorType.rateLimit) {
              interrupted = true;
              if (synchronous) {
                interrupt();
              } else {
                scheduleMicrotask(interrupt);
              }
            }
            if (interrupted &&
                previous?.isProcessing == true &&
                !next.isProcessing &&
                (next.items.isEmpty ||
                    item?.errorType == DownloadErrorType.notFound) &&
                !settled.isCompleted) {
              settled.complete();
            }
          });
          queue.resumeQueue();
          await acted.future.timeout(const Duration(seconds: 3));
          await settled.future.timeout(const Duration(seconds: 3));
          if (retried != null) await retried;
          expect(attempts, action == 'dismiss' || action == 'clear' ? 1 : 2);
          expect(resets, action == 'dismiss' || action == 'clear' ? 0 : 1);
          await queue.flushQueuePersistence();
        },
      );
    }
  }
}
