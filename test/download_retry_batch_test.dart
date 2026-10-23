import 'dart:async';

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
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/services/platform_bridge.dart';

import 'support/fixed_settings.dart';

class _Queue extends DownloadQueueNotifier {
  _Queue(this._items);
  final List<DownloadItem> _items;

  @override
  DownloadQueueState build() {
    super.build();
    // An existing processing run owns scheduling. These tests exercise the
    // retry mutation without launching audio downloads from a test fixture.
    return const DownloadQueueState().copyWith(
      items: _items,
      isProcessing: true,
      isPaused: true,
    );
  }
}

DownloadItem _item(String id, DownloadStatus status, DownloadErrorType? type) =>
    DownloadItem(
      id: id,
      track: Track(
        id: id,
        name: id,
        artistName: 'Artist',
        albumName: 'Album',
        duration: 180,
      ),
      service: 'example',
      status: status,
      createdAt: DateTime.utc(2026),
      error: 'Old error',
      errorType: type,
      filePath: '/old/$id',
      progress: .5,
      speedMBps: 1,
      bytesReceived: 100,
      bytesTotal: 200,
      qualityOverride: 'HIGH',
      playlistName: 'Playlist',
      playlistPosition: 7,
      fromBatch: true,
      networkDownloadFolder: 'smb://example.test/music',
    );

void main() {
  final messenger =
      TestWidgetsFlutterBinding.ensureInitialized().defaultBinaryMessenger;
  const backend = MethodChannel('com.zarz.mornye/backend');
  const sqlite = MethodChannel('com.tekartik.sqflite');
  const paths = MethodChannel('plugins.flutter.io/path_provider');
  const notifications = MethodChannel(
    'dexterous.com/flutter/local_notifications',
  );
  final previousFactory = databaseFactoryOrNull;
  setUpAll(() {
    databaseFactory = databaseFactorySqflitePlugin;
    AndroidFlutterLocalNotificationsPlugin.registerWith();
  });
  tearDownAll(() => databaseFactory = previousFactory);
  setUp(() {
    messenger.setMockMethodCallHandler(notifications, (_) async => null);
    SharedPreferences.setMockInitialValues({
      'app_state_migrated_queue_to_sqlite_v1': true,
    });
    messenger.setMockMethodCallHandler(
      paths,
      (_) async => '/fixture/documents',
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
  });
  tearDown(() {
    for (final channel in [backend, sqlite, paths, notifications]) {
      messenger.setMockMethodCallHandler(channel, null);
    }
  });

  test(
    'bridge snapshots, deduplicates and bounds requests, retaining successful chunks',
    () async {
      final ids = [for (var i = 0; i < 600; i++) 'id-$i', 'id-0'];
      final original = ids.toList();
      final calls = <List<String>>[];
      var concurrent = 0;
      var peak = 0;
      messenger.setMockMethodCallHandler(backend, (call) async {
        expect(call.method, 'resetDownloadCancels');
        final chunk = List<String>.from(
          (call.arguments as Map)['item_ids'] as List,
        );
        calls.add(chunk);
        concurrent++;
        if (concurrent > peak) peak = concurrent;
        await Future<void>.delayed(Duration.zero);
        concurrent--;
        if (chunk.first == 'id-256') throw PlatformException(code: 'fixture');
        return null;
      });
      final reset = PlatformBridge.resetDownloadCancels(ids);
      ids.clear();
      expect(await reset, {
        ...original.take(256),
        ...original.skip(512).take(88),
      });
      expect(calls.map((chunk) => chunk.length), [256, 256, 88]);
      expect(calls.expand((chunk) => chunk), original.take(600));
      expect(peak, 1);
      expect(await PlatformBridge.resetDownloadCancels([]), isEmpty);
      expect(calls, hasLength(3));
    },
  );

  for (final networkOnly in [false, true]) {
    for (final failFirst in [false, true]) {
      test(
        'retry keeps filter and failed chunks (network: $networkOnly, fail: $failFirst)',
        () async {
          final initial = [
            for (var i = 0; i < 600; i++)
              _item(
                '$i',
                i.isEven ? DownloadStatus.failed : DownloadStatus.skipped,
                i % 3 == 0
                    ? DownloadErrorType.notFound
                    : DownloadErrorType.network,
              ),
            _item(
              'active',
              DownloadStatus.downloading,
              DownloadErrorType.network,
            ),
            _item('complete', DownloadStatus.completed, null),
          ];
          final container = ProviderContainer(
            overrides: [
              settingsProvider.overrideWith(
                () => FixedSettingsNotifier(
                  const AppSettings(downloadDirectory: '/fixture/output'),
                ),
              ),
              downloadQueueProvider.overrideWith(() => _Queue(initial)),
            ],
          );
          final queue = container.read(downloadQueueProvider.notifier);
          queue.pauseQueue(persistAcrossRestarts: false);
          await queue.flushQueuePersistence();
          final requested = <String>[];
          final succeeded = <String>{};
          messenger.setMockMethodCallHandler(backend, (call) async {
            expect(call.method, 'resetDownloadCancels');
            final ids = List<String>.from(
              (call.arguments as Map)['item_ids'] as List,
            );
            final first = requested.isEmpty;
            requested.addAll(ids);
            if (failFirst && first) throw PlatformException(code: 'fixture');
            succeeded.addAll(ids);
            return null;
          });
          try {
            await queue.retryAllFailed(networkOnly: networkOnly);
            expect(
              requested,
              initial
                  .take(600)
                  .where(
                    (item) =>
                        !networkOnly ||
                        item.errorType == DownloadErrorType.network,
                  )
                  .map((item) => item.id),
            );
            final state = container.read(downloadQueueProvider);
            expect(state.isPaused, false);
            expect(state.isProcessing, true);
            expect(
              state.items.map((item) => item.id),
              initial.map((item) => item.id),
            );
            for (var i = 0; i < initial.length; i++) {
              final before = initial[i];
              final after = state.items[i];
              if (!succeeded.contains(before.id)) {
                expect(after, same(before));
                continue;
              }
              expect(after.status, DownloadStatus.queued);
              expect([
                after.error,
                after.errorType,
                after.filePath,
              ], everyElement(isNull));
              expect([
                after.progress,
                after.speedMBps,
                after.bytesReceived,
                after.bytesTotal,
              ], everyElement(0));
              expect(after.track, same(before.track));
              expect(after.createdAt, before.createdAt);
              expect(after.qualityOverride, before.qualityOverride);
              expect(after.playlistName, before.playlistName);
              expect(after.playlistPosition, before.playlistPosition);
              expect(after.fromBatch, before.fromBatch);
              expect(after.networkDownloadFolder, before.networkDownloadFolder);
            }
            await queue.flushQueuePersistence();
          } finally {
            container.dispose();
          }
        },
      );
    }
  }

  for (final outcome in ['failed', 'changed', 'disposed']) {
    test('pending reset respects $outcome outcome', () async {
      final initial = [
        _item('a', DownloadStatus.failed, DownloadErrorType.network),
        _item('b', DownloadStatus.skipped, DownloadErrorType.network),
      ];
      final container = ProviderContainer(
        overrides: [
          settingsProvider.overrideWith(
            () => FixedSettingsNotifier(
              const AppSettings(downloadDirectory: '/fixture/output'),
            ),
          ),
          downloadQueueProvider.overrideWith(() => _Queue(initial)),
        ],
      );
      final queue = container.read(downloadQueueProvider.notifier);
      queue.pauseQueue(persistAcrossRestarts: false);
      await queue.flushQueuePersistence();
      final before = container.read(downloadQueueProvider);
      final started = Completer<void>();
      final release = Completer<void>();
      messenger.setMockMethodCallHandler(backend, (call) async {
        if (call.method != 'resetDownloadCancels') return null;
        started.complete();
        await release.future;
        if (outcome == 'failed') throw PlatformException(code: 'fixture');
        return null;
      });
      final pending = queue.retryAllFailed();
      await started.future;
      if (outcome == 'disposed') {
        container.dispose();
      } else if (outcome == 'changed') {
        queue.updateItemStatus(
          'a',
          DownloadStatus.completed,
          filePath: '/finished/a',
        );
        queue.dismissItem('b');
      }
      release.complete();
      await pending;
      if (outcome == 'disposed') return;
      final state = container.read(downloadQueueProvider);
      if (outcome == 'failed') {
        expect(state, same(before));
        expect(state.isPaused, true);
      } else {
        expect(state.items.single.id, 'a');
        expect(state.items.single.status, DownloadStatus.completed);
        expect(state.items.single.filePath, '/finished/a');
      }
      await queue.flushQueuePersistence();
      container.dispose();
    });
  }

  test(
    'bulk cancel snapshots IDs, bounds dispatch and continues after failure',
    () async {
      final ids = [for (var i = 0; i < 600; i++) 'cancel-$i', 'cancel-0'];
      final expected = ids.take(600).toList();
      final calls = <List<String>>[];
      var concurrent = 0;
      var peak = 0;
      messenger.setMockMethodCallHandler(backend, (call) async {
        expect(call.method, 'cancelDownloads');
        final chunk = List<String>.from(
          (call.arguments as Map)['item_ids'] as List,
        );
        calls.add(chunk);
        concurrent++;
        if (concurrent > peak) peak = concurrent;
        await Future<void>.delayed(Duration.zero);
        concurrent--;
        if (chunk.first == 'cancel-256') {
          throw PlatformException(code: 'fixture');
        }
        return null;
      });
      final cancelled = PlatformBridge.cancelDownloads(ids);
      ids.clear();
      await cancelled;
      expect(calls.expand((chunk) => chunk), expected);
      expect(calls.map((chunk) => chunk.length), [256, 256, 88]);
      expect(peak, 1);
      await PlatformBridge.cancelDownloads([]);
      expect(calls, hasLength(3));
    },
  );

  for (final dispose in [false, true]) {
    test(
      'clearAll publishes immediately and bounds native work (dispose: $dispose)',
      () async {
        final initial = [
          for (var i = 0; i < 600; i++)
            _item('$i', switch (i % 3) {
              0 => DownloadStatus.queued,
              1 => DownloadStatus.downloading,
              _ => DownloadStatus.finalizing,
            }, null).copyWith(networkDownloadFolder: ''),
          for (final status in [
            DownloadStatus.completed,
            DownloadStatus.failed,
            DownloadStatus.skipped,
          ])
            _item(
              status.name,
              status,
              null,
            ).copyWith(networkDownloadFolder: ''),
        ];
        final container = ProviderContainer(
          overrides: [
            settingsProvider.overrideWith(
              () => FixedSettingsNotifier(
                const AppSettings(downloadDirectory: '/fixture/output'),
              ),
            ),
            downloadQueueProvider.overrideWith(() => _Queue(initial)),
          ],
        );
        final queue = container.read(downloadQueueProvider.notifier);
        queue.pauseQueue(persistAcrossRestarts: false);
        await queue.flushQueuePersistence();
        final started = Completer<void>();
        final release = Completer<void>();
        final done = Completer<void>();
        final calls = <List<String>>[];
        messenger.setMockMethodCallHandler(backend, (call) async {
          expect(call.method, 'cancelDownloads');
          final ids = List<String>.from(
            (call.arguments as Map)['item_ids'] as List,
          );
          calls.add(ids);
          if (calls.length == 1) {
            started.complete();
            await release.future;
            throw PlatformException(code: 'fixture');
          }
          if (ids.last == '599') done.complete();
          return null;
        });
        queue.clearAll();
        expect(container.read(downloadQueueProvider).items, isEmpty);
        expect(container.read(downloadQueueProvider).isPaused, false);
        expect(container.read(downloadQueueProvider).currentDownload, isNull);
        await started.future;
        if (dispose) container.dispose();
        release.complete();
        await done.future;
        expect(
          calls.expand((ids) => ids),
          initial.take(600).map((item) => item.id),
        );
        expect(calls.map((ids) => ids.length), [256, 256, 88]);
        if (!dispose) {
          // Late progress for removed work and a repeated Clear all must not
          // recreate rows or issue cancellation for completed/failed/skipped IDs.
          queue.updateItemStatus(
            '0',
            DownloadStatus.downloading,
            progress: 0.9,
          );
          queue.clearAll();
          expect(container.read(downloadQueueProvider).items, isEmpty);
          expect(calls, hasLength(3));
          await queue.flushQueuePersistence();
          container.dispose();
        }
      },
    );
  }
}
