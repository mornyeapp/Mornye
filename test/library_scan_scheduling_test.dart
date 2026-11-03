import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/providers/local_library_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/services/library_database.dart';
import 'package:mornye/services/link/client/link_client_library.dart';
import 'package:mornye/services/link/desktop/link_phone_library.dart';
import 'package:mornye/services/platform_bridge.dart';
import 'package:mornye/services/notification_service.dart';
import 'package:mornye/services/network_storage_service.dart';
import 'package:mornye/utils/local_library_scan_prefs.dart';

class _Settings extends SettingsNotifier {
  @override
  AppSettings build() => const AppSettings();

  @override
  Future<void> ensureLoaded() async {}
}

class _ListingStorage extends NetworkStorageService {
  _ListingStorage() : super(read: () async => null, write: (_) async {});

  final started = Completer<void>();
  final listing = Completer<List<NetworkEntry>>();

  @override
  Future<List<NetworkEntry>> list(
    NetworkConnection connection, [
    String path = '',
  ]) {
    if (!started.isCompleted) started.complete();
    return listing.future;
  }
}

class _Database implements LibraryDatabase {
  _Database(this.sources);

  List<LocalLibrarySource> sources;
  Future<List<LocalLibrarySource>> Function()? sourceRead;
  Future<LocalLibrarySource?> Function(String)? sourceLookup;
  bool failLookup = false;
  bool failScanErrorWrite = false;
  int? countOverride;
  Future<({int inserted, int skipped})> Function()? fullReplacement;

  @override
  Future<List<LocalLibrarySource>> getSources() async =>
      sourceRead == null ? List.of(sources) : await sourceRead!();

  @override
  Future<LocalLibrarySource?> getSourceByPath(String path) async {
    if (sourceLookup != null) return sourceLookup!(path);
    if (failLookup) throw StateError('source lookup failed');
    return sources.where((source) => source.path == path).firstOrNull;
  }

  @override
  Future<int> getCount() async =>
      countOverride ??
      sources.where((source) => source.enabled && source.available).length;

  @override
  Future<({int inserted, int skipped})> replaceSourceScanFile(
    String sourceId,
    LibraryScanNDJSONFile scan, {
    required String requestId,
    required bool Function() isCancelled,
  }) => fullReplacement!();

  @override
  Future<LocalLibraryLookupIndex> getLookupIndex() async =>
      const LocalLibraryLookupIndex();

  @override
  Future<int> getSourceCount(String sourceId) async => 1;

  @override
  Future<Map<String, int>> getFileModTimes({String? sourceId}) async => {
    '/music/song.flac': 1,
  };

  @override
  Future<void> removeSource(String sourceId) async {
    sources.removeWhere((source) => source.id == sourceId);
  }

  @override
  Future<int> deleteDownloadedRowsForSource(String sourceId) async => 0;

  @override
  Future<void> updateSourceState(
    String sourceId, {
    bool? enabled,
    bool? available,
    DateTime? lastScannedAt,
    DateTime? lastSeenAt,
    String? lastScanError,
    bool clearLastScanError = false,
  }) async {
    if (lastScanError != null && failScanErrorWrite) {
      throw StateError('Could not save scan failure');
    }
    sources = [
      for (final source in sources)
        source.id == sourceId
            ? source.copyWith(
                enabled: enabled,
                available: available,
                lastScanError: lastScanError,
                clearLastScanError: clearLastScanError,
              )
            : source,
    ];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> _waitFor(bool Function() condition) async {
  for (var i = 0; i < 100 && !condition(); i++) {
    await Future<void>.delayed(Duration.zero);
  }
  expect(condition(), isTrue);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  AndroidFlutterLocalNotificationsPlugin.registerWith();
  SharedPreferences.setMockInitialValues({});
  const backend = MethodChannel('com.zarz.mornye/backend');
  const paths = MethodChannel('plugins.flutter.io/path_provider');
  const notifications = MethodChannel(
    'dexterous.com/flutter/local_notifications',
  );
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory directory;
  late _Database database;
  late ProviderContainer container;
  late LocalLibraryNotifier library;
  late Map<String, bool> available;
  late LocalLibraryAvailabilityProbe probe;
  late List<(String, Completer<String>)> scans;
  late List<String> calls;
  late List<MethodCall> notificationCalls;
  var completeOnCancel = false;
  late _ListingStorage storage;

  setUp(() async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    await (await SharedPreferences.getInstance()).clear();
    directory = await Directory.systemTemp.createTemp('library-scheduling-');
    database = _Database([
      for (final id in ['active', 'reconnect'])
        LocalLibrarySource(
          id: id,
          path: '${directory.path}/$id',
          displayName: id,
          trackCount: 1,
          available: id == 'active',
        ),
    ]);
    available = {
      for (final source in database.sources) source.path: source.available,
    };
    probe = (path, {bookmark}) async => available[path];
    scans = [];
    calls = [];
    notificationCalls = [];
    completeOnCancel = false;
    storage = _ListingStorage();
    messenger.setMockMethodCallHandler(paths, (_) async => directory.path);
    messenger.setMockMethodCallHandler(notifications, (call) async {
      notificationCalls.add(call);
      return call.method == 'initialize' ? true : null;
    });
    messenger.setMockMethodCallHandler(backend, (call) async {
      calls.add(call.method);
      if (call.method == 'scanLibraryFolderIncremental') {
        final result = Completer<String>();
        scans.add(((call.arguments as Map)['folder_path'] as String, result));
        return result.future;
      }
      if (call.method == 'cancelLibraryScan' && completeOnCancel) {
        for (final (_, response) in scans) {
          if (!response.isCompleted) response.complete('{"cancelled":true}');
        }
      }
      return null;
    });
    container = ProviderContainer(
      overrides: [
        settingsProvider.overrideWith(_Settings.new),
        localLibraryProvider.overrideWith(
          () => LocalLibraryNotifier(
            database: database,
            networkStorage: storage,
            availabilityProbe: (path, {bookmark}) =>
                probe(path, bookmark: bookmark),
          ),
        ),
      ],
    );
    library = container.read(localLibraryProvider.notifier);
    await _waitFor(() => !container.read(localLibraryProvider).isLoading);
  });

  tearDown(() async {
    container.dispose();
    if (storage.started.isCompleted && !storage.listing.isCompleted) {
      storage.listing.complete([]);
    }
    await storage.dispose();
    for (final (_, response) in scans) {
      if (!response.isCompleted) response.complete('{"cancelled":true}');
    }
    await Future<void>.delayed(Duration.zero);
    messenger.setMockMethodCallHandler(backend, null);
    messenger.setMockMethodCallHandler(paths, null);
    messenger.setMockMethodCallHandler(notifications, null);
    await directory.delete(recursive: true);
    debugDefaultTargetPlatformOverride = null;
  });

  Future<void> reconnect() async {
    available['${directory.path}/reconnect'] = true;
    await library.refreshSourceAvailability(scanReconnected: true);
  }

  Future<void> restartLibrary() async {
    container.dispose();
    container = ProviderContainer(
      overrides: [
        settingsProvider.overrideWith(_Settings.new),
        localLibraryProvider.overrideWith(
          () => LocalLibraryNotifier(
            database: database,
            networkStorage: storage,
            availabilityProbe: probe,
          ),
        ),
      ],
    );
    library = container.read(localLibraryProvider.notifier);
    await _waitFor(() => !container.read(localLibraryProvider).isLoading);
  }

  test(
    'removing a NAS cancels its blocked listing and retains its offline index',
    () async {
      const connection = NetworkConnection(
        id: 'nas',
        name: 'NAS',
        protocol: NetworkProtocol.smb,
        address: 'smb://nas.test/music/',
      );
      await storage.save(connection);
      const path = 'network://nas/';
      database.sources[0] = LocalLibrarySource(
        id: 'active',
        path: path,
        displayName: 'NAS',
        available: true,
      );
      available[path] = true;
      final scan = library.startSourceScan('active', forceFullScan: true);
      await storage.started.future.timeout(const Duration(seconds: 5));
      expect(container.read(localLibraryProvider).isScanning, isTrue);

      available[path] = false;
      await storage.remove('nas').timeout(const Duration(seconds: 1));
      await scan;
      final state = container.read(localLibraryProvider);
      expect(state.isScanning, isFalse);
      expect(state.scanWasCancelled, isTrue);
      expect(
        state.sources.firstWhere((s) => s.id == 'active').available,
        isFalse,
      );
      expect(
        storage.listing.isCompleted,
        isFalse,
        reason: 'Cancellation must not wait for the old NAS response',
      );
      storage.listing.completeError(
        const SocketException('Old connection closed'),
      );
      await Future<void>.delayed(Duration.zero);
    },
  );

  test(
    'removing the active library source waits for its scan to stop',
    () async {
      completeOnCancel = true;
      final scan = library.startSourceScan('active');
      await _waitFor(() => scans.isNotEmpty);
      await library.removeSource('active').timeout(const Duration(seconds: 1));
      await scan;
      expect(calls, contains('cancelLibraryScan'));
      expect(container.read(localLibraryProvider).isScanning, isFalse);
      expect(database.sources.any((s) => s.id == 'active'), isFalse);
    },
  );

  test('removing another connection keeps the active scan running', () async {
    final scan = library.startSourceScan('active');
    await _waitFor(() => scans.isNotEmpty);
    await storage.remove('another-nas');
    expect(calls, isNot(contains('cancelLibraryScan')));
    expect(container.read(localLibraryProvider).isScanning, isTrue);
    scans.single.$2.complete('{"cancelled":true}');
    await scan;
  });

  test(
    'Android crash details are recovered and retained without manual logs',
    () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(localLibraryActiveScanStartedAtKey, 100);
      await prefs.setString(localLibraryActiveScanSourceKey, 'active');
      var exitReads = 0;
      messenger.setMockMethodCallHandler(backend, (call) async {
        if (call.method == 'getLibraryScanExitInfo') {
          exitReads++;
          expect((call.arguments as Map)['started_after'], 100);
          return {
            'reason': 'Native crash',
            'description': 'SIGSEGV in example codec',
            'timestamp': 200,
            'status': 11,
          };
        }
        return null;
      });
      await restartLibrary();
      final state = container.read(localLibraryProvider);
      expect(state.sources.first.lastScanError, contains('Native crash'));
      expect(
        state.sources.first.lastScanError,
        contains('SIGSEGV in example codec'),
      );
      expect(state.totalCount, 1);
      expect(exitReads, 1);
      final shows = notificationCalls
          .where((call) => call.method == 'show')
          .length;
      await restartLibrary();
      expect(exitReads, 1);
      expect(
        notificationCalls.where((call) => call.method == 'show').length,
        shows,
      );
      expect(
        container.read(localLibraryProvider).sources.first.lastScanError,
        contains('Native crash'),
      );
    },
  );

  for (final failErrorWrite in [false, true]) {
    test(
      'restart reports an interrupted scan with auto-scan off (save failure: $failErrorWrite)',
      () async {
        final previousCount = container.read(localLibraryProvider).totalCount;
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(localLibraryActiveScanSourceKey, 'active');
        database.failScanErrorWrite = failErrorWrite;
        container.dispose();
        container = ProviderContainer(
          overrides: [
            settingsProvider.overrideWith(_Settings.new),
            localLibraryProvider.overrideWith(
              () => LocalLibraryNotifier(
                database: database,
                availabilityProbe: probe,
              ),
            ),
          ],
        );
        library = container.read(localLibraryProvider.notifier);
        await _waitFor(() => !container.read(localLibraryProvider).isLoading);
        final state = container.read(localLibraryProvider);
        expect(state.isScanning, isFalse);
        expect(state.loadFailed, isFalse);
        expect(state.totalCount, previousCount);
        expect(scans, isEmpty);
        expect(prefs.getString(localLibraryActiveScanSourceKey), 'active');
        if (!failErrorWrite) {
          expect(state.sources.first.lastScanError, contains('interrupted'));
        }
        final shows = notificationCalls.where((call) => call.method == 'show');
        final failure = shows.last.arguments as Map;
        expect(failure['title'], 'Library scan failed');
        expect(failure['body'], contains('interrupted'));
        expect(
          notificationCalls.any((call) => call.method == 'cancel'),
          isTrue,
        );
        final notificationCount = shows.length;
        await library.reloadFromStorage();
        expect(
          notificationCalls.where((call) => call.method == 'show').length,
          notificationCount,
        );
      },
    );
  }

  test(
    'a silent scan retains failures without result banners or noisy recovery',
    () async {
      final prefs = await SharedPreferences.getInstance();
      final active = library.startSourceScan('active', notify: false);
      await _waitFor(() => scans.length == 1);
      expect(prefs.getBool(localLibraryActiveScanNotifyKey), isFalse);
      scans.single.$2.completeError(StateError('PC disconnected'));
      await active;
      final state = container.read(localLibraryProvider);
      expect(state.sources.first.lastScanError, contains('PC disconnected'));
      expect(state.totalCount, 1);
      expect(notificationCalls.where((call) => call.method == 'show'), isEmpty);
      expect(prefs.containsKey(localLibraryActiveScanNotifyKey), isFalse);

      // A process exit during an automatic scan is still diagnosed on restart.
      await prefs.setString(localLibraryActiveScanSourceKey, 'active');
      await prefs.setInt(localLibraryActiveScanStartedAtKey, 100);
      await prefs.setBool(localLibraryActiveScanNotifyKey, false);
      await restartLibrary();
      expect(
        container.read(localLibraryProvider).sources.first.lastScanError,
        contains('interrupted'),
      );
      expect(notificationCalls.where((call) => call.method == 'show'), isEmpty);

      // Manual scans resume their normal failure notifications.
      final manual = library.startSourceScan('active');
      await _waitFor(() => scans.length == 2);
      scans.last.$2.completeError(StateError('Manual scan failed'));
      await manual;
      final notice =
          notificationCalls.lastWhere((call) => call.method == 'show').arguments
              as Map;
      expect(notice['title'], 'Library scan failed');
      expect(notice['body'], contains('Manual scan failed'));
    },
  );

  test('a successful automatic scan posts no result notification', () async {
    final active = library.startSourceScan('active', notify: false);
    await _waitFor(() => scans.length == 1);
    scans.single.$2.complete('{"files":[],"totalFiles":1,"skippedCount":1}');
    await active;
    expect(container.read(localLibraryProvider).isScanning, isFalse);
    expect(notificationCalls.where((call) => call.method == 'show'), isEmpty);
  });

  for (final automatic in [false, true]) {
    test('scan all preserves its notification policy ($automatic)', () async {
      final scan = automatic
          ? library.scanAllSources(notify: false)
          : library.scanAllSources();
      await _waitFor(() => scans.length == 1);
      scans.single.$2.complete('{"files":[],"totalFiles":1,"skippedCount":1}');
      await scan;
      final shows = notificationCalls.where((call) => call.method == 'show');
      if (automatic) {
        expect(shows, isEmpty);
      } else {
        expect((shows.last.arguments as Map)['title'], 'Library scan complete');
      }
    });
  }

  for (final desktop in [false, true]) {
    test(
      'Link automatic scan failures stay silent (desktop: $desktop)',
      () async {
        const connection = NetworkConnection(
          id: 'peer',
          name: 'Peer',
          protocol: NetworkProtocol.smb,
          address: 'smb://peer.test/music/',
        );
        await storage.save(connection);
        final root = NetworkStorageService.source('peer', '');
        database.sources[0] = LocalLibrarySource(
          id: 'active',
          path: root,
          displayName: 'Peer',
        );
        available[root] = true;
        final bridge = Provider<Future<void> Function(String)>((ref) {
          if (desktop) {
            return LinkPhoneLibraryBridge(ref, database: database).rescan;
          }
          return LinkNetworkLibraryBridge(
            ref,
            database: database,
            storage: storage,
          ).rescan;
        });
        await container.read(bridge)('peer');
        await storage.started.future.timeout(const Duration(seconds: 5));
        storage.listing.completeError(
          const SocketException('Peer disconnected'),
        );
        await _waitFor(
          () =>
              database.sources.first.lastScanError?.contains(
                'Peer disconnected',
              ) ==
              true,
        );
        final prefs = await SharedPreferences.getInstance();
        await _waitFor(
          () => !prefs.containsKey(localLibraryActiveScanSourceKey),
        );
        expect(
          notificationCalls.where((call) => call.method == 'show'),
          isEmpty,
        );
      },
    );

    test('Link disposal cancels a pending source lookup ($desktop)', () async {
      final response = Completer<LocalLibrarySource?>();
      database.sourceLookup = (_) => response.future;
      final bridge = Provider<Future<void> Function(String)>((ref) {
        if (desktop) {
          return LinkPhoneLibraryBridge(ref, database: database).rescan;
        }
        return LinkNetworkLibraryBridge(
          ref,
          database: database,
          storage: storage,
        ).rescan;
      });
      final pending = container.read(bridge)('peer');
      container.dispose();
      response.complete(database.sources.first);
      await pending;
      expect(scans, isEmpty);
      expect(storage.started.isCompleted, isFalse);
    });
  }

  test('simultaneous automatic starts serialize after admission', () async {
    final first = library.startSourceScan(
      'active',
      notify: false,
      waitForCurrentScan: true,
    );
    final second = library.startSourceScan(
      'active',
      notify: false,
      waitForCurrentScan: true,
    );
    await _waitFor(() => scans.length == 1);
    scans.first.$2.complete('{"cancelled":true}');
    await first;
    await _waitFor(() => scans.length == 2);
    scans.last.$2.complete('{"cancelled":true}');
    await second;
    expect(container.read(localLibraryProvider).isScanning, isFalse);
  });

  test('queued automatic scans wait for the previous cleanup', () async {
    final entered = Completer<void>();
    final release = Completer<void>();
    messenger.setMockMethodCallHandler(notifications, (call) async {
      notificationCalls.add(call);
      if (call.method == 'show' &&
          (call.arguments as Map)['title'] == 'Library scan failed') {
        entered.complete();
        await release.future;
      }
      return call.method == 'initialize' ? true : null;
    });
    final first = library.startSourceScan('active');
    await _waitFor(() => scans.length == 1);
    scans.first.$2.completeError(StateError('First scan failed'));
    await entered.future.timeout(const Duration(seconds: 5));
    expect(container.read(localLibraryProvider).isScanning, isFalse);
    final queued = library.startSourceScan(
      'active',
      notify: false,
      waitForCurrentScan: true,
    );
    await Future<void>.delayed(Duration.zero);
    expect(scans, hasLength(1));
    release.complete();
    await first;
    await _waitFor(() => scans.length == 2);
    scans.last.$2.complete('{"cancelled":true}');
    await queued;
    final shows = notificationCalls.where((call) => call.method == 'show');
    expect((shows.last.arguments as Map)['title'], 'Library scan failed');
  });

  test(
    'a scan failure remains visible when saving the error also fails',
    () async {
      final previousCount = container.read(localLibraryProvider).totalCount;
      database.failScanErrorWrite = true;
      final active = library.startSourceScan('active');
      await _waitFor(() => scans.length == 1);
      scans.single.$2.completeError(
        PlatformException(code: 'scan_failed', message: 'Invalid audio header'),
      );
      await active;
      final state = container.read(localLibraryProvider);
      expect(state.isScanning, isFalse);
      expect(state.totalCount, previousCount);
      expect(
        state.sources.first.lastScanError,
        contains('Invalid audio header'),
      );
      final failure =
          notificationCalls.lastWhere((call) => call.method == 'show').arguments
              as Map;
      expect(failure['title'], 'Library scan failed');
      expect(failure['body'], contains('Invalid audio header'));
      expect(
        (await SharedPreferences.getInstance()).getString(
          localLibraryActiveScanSourceKey,
        ),
        isNull,
      );
    },
  );

  test(
    'a delayed progress notification cannot overwrite a scan failure',
    () async {
      final entered = Completer<void>();
      final release = Completer<void>();
      messenger.setMockMethodCallHandler(notifications, (call) async {
        if (call.method == 'show' &&
            (call.arguments as Map)['body'].toString().contains('track.flac')) {
          if (!entered.isCompleted) entered.complete();
          await release.future;
        }
        notificationCalls.add(call);
        return call.method == 'initialize' ? true : null;
      });
      messenger.setMockMethodCallHandler(backend, (call) async {
        if (call.method == 'scanLibraryFolderIncremental') {
          final response = Completer<String>();
          scans.add((
            (call.arguments as Map)['folder_path'] as String,
            response,
          ));
          return response.future;
        }
        if (call.method == 'getLibraryScanProgress') {
          return {
            'scanned_files': 785,
            'total_files': 1877,
            'progress_pct': 42,
            'current_file': 'track.flac',
          };
        }
        return null;
      });
      final active = library.startSourceScan('active');
      await entered.future.timeout(const Duration(seconds: 5));
      scans.single.$2.completeError(StateError('Scan stopped'));
      await _waitFor(() => !container.read(localLibraryProvider).isScanning);
      release.complete();
      await active;
      final shows = notificationCalls
          .where((call) => call.method == 'show')
          .toList();
      expect((shows.last.arguments as Map)['title'], 'Library scan failed');
      expect((shows.last.arguments as Map)['body'], contains('Scan stopped'));
      expect(
        (shows.last.arguments as Map)['id'],
        NotificationService.libraryScanId,
      );
    },
  );

  test('concurrent starts own one preflight and one native scan', () async {
    final pending = Completer<bool?>();
    var probes = 0;
    probe = (path, {bookmark}) {
      probes++;
      return pending.future;
    };
    final first = library.startSourceScan('active');
    await _waitFor(() => probes == 1);
    await library.startSourceScan('active');
    expect(probes, 1);
    pending.complete(true);
    await _waitFor(() => scans.length == 1);
    scans.single.$2.complete('{"cancelled":true}');
    await first;
    expect(scans, hasLength(1));
  });

  for (final dispose in [false, true]) {
    test('${dispose ? 'disposal' : 'cancel'} stops owned preflight', () async {
      final pending = Completer<bool?>();
      final started = Completer<void>();
      probe = (path, {bookmark}) {
        started.complete();
        return pending.future;
      };
      final scan = library.startSourceScan('active');
      await started.future;
      if (dispose) {
        container.dispose();
      } else {
        await library.cancelScan();
      }
      pending.complete(true);
      await scan;
      expect(scans, isEmpty);
      if (!dispose) {
        expect(container.read(localLibraryProvider).scanWasCancelled, isTrue);
        probe = (path, {bookmark}) async => available[path];
        final retry = library.startSourceScan('active');
        await _waitFor(() => scans.length == 1);
        scans.single.$2.complete('{"cancelled":true}');
        await retry;
      }
    });
  }

  for (final remove in [false, true]) {
    for (final duringProbe in [false, true]) {
      test(
        '${remove ? 'remove' : 'disable'} supersedes ${duringProbe ? 'probe' : 'source read'}',
        () async {
          final started = Completer<void>();
          final pending = Completer<bool?>();
          final snapshot = Completer<List<LocalLibrarySource>>();
          final oldSources = List.of(database.sources);
          if (duringProbe) {
            probe = (path, {bookmark}) {
              started.complete();
              return pending.future;
            };
          } else {
            database.sourceRead = () {
              started.complete();
              return snapshot.future;
            };
          }
          final scan = library.startSourceScan('active');
          await started.future;
          database.sourceRead = null;
          if (remove) {
            await library.removeSource('active');
          } else {
            await library.setSourceEnabled('active', false);
          }
          if (duringProbe) {
            pending.complete(true);
          } else {
            snapshot.complete(oldSources);
          }
          await scan;
          expect(scans, isEmpty);
        },
      );
    }
  }

  test('a finished scan keeps the files it could not read', () async {
    var progress = <String, Object>{
      'is_complete': true,
      'error_count': 3,
      'failures': [
        {'path': '/music/A/broken.flac', 'message': 'invalid FLAC header'},
        {
          'path':
              'content://example.documents/tree/primary%3AMusic/document/'
              'primary%3AMusic%2FB%2Fcut.mp3',
          'message': 'Input/output error',
        },
      ],
    };
    messenger.setMockMethodCallHandler(backend, (call) async {
      if (call.method == 'scanLibraryFolderIncremental') {
        return '{"files":[],"totalFiles":4,"skippedCount":1}';
      }
      if (call.method == 'getLibraryScanProgress') return progress;
      return null;
    });

    await library.startSourceScan('active');
    var state = container.read(localLibraryProvider);
    expect(state.scanErrorCount, 3);
    final failures = state.scanFailures['active']!;
    expect(failures.count, 3);
    expect(failures.files.map((file) => file.fileName), [
      'broken.flac',
      'cut.mp3',
    ]);
    expect(failures.files.map((file) => file.folder), ['/music/A', 'Music/B']);
    expect(failures.files.last.message, 'Input/output error');

    await restartLibrary();
    state = container.read(localLibraryProvider);
    expect(state.scanFailures['active']?.files, hasLength(2));

    // A clean scan forgets the old list.
    progress = {'is_complete': true, 'error_count': 0};
    await library.startSourceScan('active');
    expect(container.read(localLibraryProvider).scanFailures, isEmpty);
    await restartLibrary();
    expect(container.read(localLibraryProvider).scanFailures, isEmpty);

    // A removed folder takes its list with it.
    progress = {
      'is_complete': true,
      'error_count': 1,
      'failures': [
        {'path': '/music/broken.flac', 'message': 'EIO'},
      ],
    };
    await library.startSourceScan('active');
    expect(container.read(localLibraryProvider).scanFailures, hasLength(1));
    await library.removeSource('active');
    expect(container.read(localLibraryProvider).scanFailures, isEmpty);
    await restartLibrary();
    expect(container.read(localLibraryProvider).scanFailures, isEmpty);
  });

  test('paused scan retains reconnect work until it completes', () async {
    final active = library.startSourceScan('active');
    await _waitFor(() => scans.length == 1);
    await library.pauseScan();
    await reconnect();
    await reconnect();
    expect(scans, hasLength(1));
    await library.resumeScan();
    scans.first.$2.complete('{"cancelled":true}');
    await active;
    await _waitFor(() => scans.length == 2);
    expect(scans.last.$1, '${directory.path}/reconnect');
    scans.last.$2.complete('{"cancelled":true}');
    await _waitFor(() => !container.read(localLibraryProvider).isScanning);
  });

  test('cancel drops queued and pending-refresh reconnect work', () async {
    final active = library.startSourceScan('active');
    await _waitFor(() => scans.length == 1);
    await reconnect();
    final pending = Completer<bool?>();
    final started = Completer<void>();
    probe = (path, {bookmark}) {
      if (path.endsWith('/reconnect') && !started.isCompleted) {
        started.complete();
        return pending.future;
      }
      return Future<bool?>.value(available[path]);
    };
    // Make a second source transition pending rather than reusing the queue.
    await database.updateSourceState('reconnect', available: false);
    final refresh = library.refreshSourceAvailability(scanReconnected: true);
    await started.future;
    await library.cancelScan();
    pending.complete(true);
    await refresh;
    scans.first.$2.complete('{"cancelled":true}');
    await active;
    await Future<void>.delayed(Duration.zero);
    expect(scans, hasLength(1));
  });

  test('disposing a paused scan cancels native ownership', () async {
    final active = library.startSourceScan('active');
    await _waitFor(() => scans.length == 1);
    await library.pauseScan();
    await reconnect();
    completeOnCancel = true;
    container.dispose();
    await active;
    expect(calls, contains('cancelLibraryScan'));
    expect(scans, hasLength(1));
  });

  test('setup failure releases admission for a later scan', () async {
    database.failLookup = true;
    await library.startScan('${directory.path}/active');
    database.failLookup = false;
    final retry = library.startSourceScan('active');
    await _waitFor(() => scans.length == 1);
    scans.single.$2.complete(jsonEncode({'cancelled': true}));
    await retry;
    expect(container.read(localLibraryProvider).isScanning, isFalse);
  });

  test(
    'cancel after incremental native commit publishes the changed index',
    () async {
      final version = container.read(localLibraryProvider).loadedIndexVersion;
      final active = library.startSourceScan('active');
      await _waitFor(() => scans.length == 1);
      await library.cancelScan();
      database.countOverride = 7;
      scans.single.$2.complete(jsonEncode({'committed': true, 'skipped': 2}));
      await active;
      final state = container.read(localLibraryProvider);
      expect(state.totalCount, 7);
      expect(state.loadedIndexVersion, greaterThan(version));
      expect(state.excludedDownloadedCount, 2);
      expect(state.scanWasCancelled, isTrue);
      expect(state.isScanning, isFalse);
    },
  );

  test('cancel after full replacement publishes the committed index', () async {
    final entered = Completer<void>();
    final release = Completer<void>();
    database.fullReplacement = () async {
      entered.complete();
      await release.future;
      database.countOverride = 7;
      return (inserted: 7, skipped: 2);
    };
    messenger.setMockMethodCallHandler(backend, (call) async {
      if (call.method == 'scanLibraryFolderToNDJSONFile') {
        final path = (call.arguments as Map)['output_path'] as String;
        await File(path).writeAsString('');
        return {'path': path, 'count': 0, 'error_count': 0};
      }
      return null;
    });
    final version = container.read(localLibraryProvider).loadedIndexVersion;
    final active = library.startSourceScan('active', forceFullScan: true);
    await entered.future;
    await library.cancelScan();
    release.complete();
    await active;
    final state = container.read(localLibraryProvider);
    expect(state.totalCount, 7);
    expect(state.loadedIndexVersion, greaterThan(version));
    expect(state.excludedDownloadedCount, 2);
    expect(state.scanWasCancelled, isTrue);
    expect(state.isScanning, isFalse);
  });
}
