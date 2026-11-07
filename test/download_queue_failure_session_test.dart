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
import 'package:mornye/services/app_state_database.dart';
import 'package:mornye/utils/logger.dart';

class _Settings extends SettingsNotifier {
  _Settings(this._directory);
  final String _directory;

  @override
  AppSettings build() => AppSettings(
    downloadDirectory: _directory,
    embedMetadata: false,
    saveDownloadHistory: false,
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

DownloadItem _item(
  String id, {
  String service = 'example-provider',
  String networkDownloadFolder = '',
}) => DownloadItem(
  id: id,
  track: Track(
    id: 'extension:example:$id',
    name: id,
    artistName: 'Artist',
    albumName: 'Album',
    duration: 180,
  ),
  service: service,
  networkDownloadFolder: networkDownloadFolder,
  createdAt: DateTime.utc(2026),
);

class _Queue extends DownloadQueueNotifier {
  @override
  DownloadQueueState build() {
    super.build();
    return const DownloadQueueState().copyWith(
      items: [
        _item('backend-failure'),
        _item('exception'),
        _item(
          'network-failure',
          service: 'unavailable-provider',
          networkDownloadFolder: 'smb://example.test/music',
        ),
        _item('unavailable', service: 'unavailable-provider'),
        _item('cancelled'),
      ],
    );
  }
}

void main() {
  final messenger =
      TestWidgetsFlutterBinding.ensureInitialized().defaultBinaryMessenger;

  test(
    'queue counts failures and retries even when its summary notification fails',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'queue-failures-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final previousFactory = databaseFactoryOrNull;
      databaseFactory = databaseFactorySqflitePlugin;
      addTearDown(() => databaseFactory = previousFactory);
      AndroidFlutterLocalNotificationsPlugin.registerWith();
      SharedPreferences.setMockInitialValues({
        'app_state_migrated_queue_to_sqlite_v1': true,
      });
      const backend = MethodChannel('com.zarz.mornye/backend');
      const sqlite = MethodChannel('com.tekartik.sqflite');
      const paths = MethodChannel('plugins.flutter.io/path_provider');
      const notifications = MethodChannel(
        'dexterous.com/flutter/local_notifications',
      );
      const connectivity = MethodChannel(
        'dev.fluttercommunity.plus/connectivity_status',
      );
      const progress = MethodChannel(
        'com.zarz.mornye/download_progress_stream',
      );
      final summaries = <String>[];
      final attempts = <String>[];
      final resetIds = <String>[];
      messenger.setMockMethodCallHandler(paths, (_) async => directory.path);
      messenger.setMockMethodCallHandler(connectivity, (_) async => null);
      messenger.setMockMethodCallHandler(progress, (_) async => null);
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
      messenger.setMockMethodCallHandler(notifications, (call) async {
        if (call.method == 'initialize') return true;
        if (call.method == 'show') {
          final body = (call.arguments as Map)['body'] as String?;
          if (body != null && body.contains('downloaded,')) {
            summaries.add(body);
            if (summaries.length == 1) {
              throw PlatformException(
                code: 'notification_unavailable',
                message: 'Notification server unavailable',
              );
            }
          }
        }
        return null;
      });
      messenger.setMockMethodCallHandler(backend, (call) async {
        if (call.method == 'resetDownloadCancel') {
          resetIds.add((call.arguments as Map)['item_id'] as String);
        }
        if (call.method != 'downloadByStrategy') return null;
        final request = jsonDecode(call.arguments as String) as Map;
        final id = request['item_id'] as String;
        attempts.add(id);
        if (id == 'exception') {
          throw PlatformException(
            code: 'fixture',
            message: 'Fixture processing error',
          );
        }
        return {
          'success': false,
          'error': id == 'cancelled'
              ? 'Cancelled'
              : 'Fixture track unavailable',
          'error_type': id == 'cancelled' ? 'cancelled' : 'not_found',
        };
      });
      addTearDown(() {
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

      final container = ProviderContainer(
        overrides: [
          settingsProvider.overrideWith(() => _Settings(directory.path)),
          extensionProvider.overrideWith(_Extensions.new),
          downloadQueueProvider.overrideWith(_Queue.new),
        ],
      );
      addTearDown(container.dispose);
      final queue = container.read(downloadQueueProvider.notifier);
      queue.pauseQueue(persistAcrossRestarts: false);
      await queue.flushQueuePersistence();
      var finished = Completer<void>();
      container.listen(downloadQueueProvider, (previous, next) {
        if (previous?.isProcessing == true &&
            !next.isProcessing &&
            !finished.isCompleted) {
          finished.complete();
        }
      });

      queue.resumeQueue();
      await finished.future.timeout(const Duration(seconds: 10));
      final first = container.read(downloadQueueProvider);
      expect(attempts, ['backend-failure', 'exception', 'cancelled']);
      expect(first.lookup.failedCount, 4);
      expect(
        first.lookup.byItemId['cancelled']!.status,
        DownloadStatus.skipped,
      );
      expect(
        first.lookup.byItemId['backend-failure']!.errorType,
        DownloadErrorType.notFound,
      );
      expect(
        first.lookup.byItemId['exception']!.error,
        contains('Fixture processing error'),
      );
      expect(
        first.lookup.byItemId['network-failure']!.error,
        startsWith('Network download failed. Retry keeps prepared audio:'),
      );
      expect(
        first.lookup.byItemId['unavailable']!.error,
        'Download provider is no longer available',
      );
      // A missing provider counts toward the session failure total; a
      // cancellation does not.
      expect(summaries, ['0 downloaded, 4 failed']);
      expect(
        LogBuffer().entries.where(
          (entry) => entry.message.contains('Download queue processing failed'),
        ),
        isEmpty,
      );

      finished = Completer<void>();
      await queue.retryItem('backend-failure');
      await finished.future.timeout(const Duration(seconds: 10));
      expect(resetIds, ['backend-failure']);
      expect(attempts, [
        'backend-failure',
        'exception',
        'cancelled',
        'backend-failure',
      ]);
      expect(container.read(downloadQueueProvider).lookup.failedCount, 4);
      expect(summaries, ['0 downloaded, 4 failed', '0 downloaded, 1 failed']);
      await queue.flushQueuePersistence();
      await (await AppStateDatabase.instance.database).close();
    },
  );
}
