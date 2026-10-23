import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:mornye/models/settings.dart';
import 'package:mornye/controllers/queue_library_refresh_policy.dart';
import 'package:mornye/services/library_database.dart';

void main() {
  const empty = QueueLibraryCounts(
    allTrackCount: 0,
    albumCount: 0,
    singleTrackCount: 0,
  );
  const cached = QueueLibraryCounts(
    allTrackCount: 20,
    albumCount: 2,
    singleTrackCount: 3,
  );
  const fallback = QueueLibraryCounts(
    allTrackCount: 15,
    albumCount: 1,
    singleTrackCount: 4,
  );

  test('keeps cached counts when a download refresh returns empty', () {
    final resolved = resolveQueueLibraryCountsSnapshot(
      current: empty,
      cached: cached,
      activeDownloadFallback: fallback,
    );

    expect(identical(resolved, cached), isTrue);
  });

  test('uses in-memory history when no page cache exists yet', () {
    final resolved = resolveQueueLibraryCountsSnapshot(
      current: empty,
      activeDownloadFallback: fallback,
    );

    expect(identical(resolved, fallback), isTrue);
  });

  test('allows a legitimate empty refresh without an active fallback', () {
    final resolved = resolveQueueLibraryCountsSnapshot(
      current: empty,
      cached: cached,
    );

    expect(identical(resolved, empty), isTrue);
    expect(
      shouldRetainQueueLibraryPageSnapshot(
        currentIsEmpty: true,
        cachedHasContent: true,
        activeDownloadFallbackAvailable: false,
      ),
      isFalse,
    );
  });

  test('retains a non-empty page only while its fallback is available', () {
    expect(
      shouldRetainQueueLibraryPageSnapshot(
        currentIsEmpty: true,
        cachedHasContent: true,
        activeDownloadFallbackAvailable: true,
      ),
      isTrue,
    );
    expect(
      shouldRetainQueueLibraryPageSnapshot(
        currentIsEmpty: false,
        cachedHasContent: true,
        activeDownloadFallbackAvailable: true,
      ),
      isFalse,
    );
  });

  test('completion bridge prefers distinct finalized path candidates', () {
    expect(
      resolveCompletionBridgePlayableCandidates(
        historyFilePath: ' /music/final.flac ',
        completedItemFilePath: '/music/completed.flac',
      ),
      ['/music/final.flac', '/music/completed.flac'],
    );
    expect(
      resolveCompletionBridgePlayableCandidates(
        historyFilePath: ' /music/final.flac ',
        completedItemFilePath: '/music/final.flac',
      ),
      ['/music/final.flac'],
    );
    expect(
      resolveCompletionBridgePlayablePath(
        historyFilePath: ' ',
        completedItemFilePath: ' /music/completed.flac ',
      ),
      '/music/completed.flac',
    );
    expect(
      resolveCompletionBridgePlayablePath(
        historyFilePath: null,
        completedItemFilePath: '',
      ),
      isNull,
    );
  });

  test(
    'completion bridge survives partial album cancellation until landing',
    () {
      expect(
        shouldRetainCompletionBridge(
          queueItemExists: true,
          isRequeued: false,
          hasActiveDownloads: false,
          libraryRowLanded: false,
          hasHistoryItem: true,
          expired: true,
        ),
        isTrue,
      );
      expect(
        shouldRetainCompletionBridge(
          queueItemExists: true,
          isRequeued: false,
          hasActiveDownloads: false,
          libraryRowLanded: true,
          hasHistoryItem: true,
          expired: true,
        ),
        isFalse,
      );
    },
  );

  test('unpersisted completion bridge retains only its short grace period', () {
    expect(
      shouldRetainCompletionBridge(
        queueItemExists: true,
        isRequeued: false,
        hasActiveDownloads: false,
        libraryRowLanded: false,
        hasHistoryItem: false,
        expired: false,
      ),
      isTrue,
    );
    expect(
      shouldRetainCompletionBridge(
        queueItemExists: true,
        isRequeued: false,
        hasActiveDownloads: false,
        libraryRowLanded: false,
        hasHistoryItem: false,
        expired: true,
      ),
      isFalse,
    );
  });

  test('removed completion cannot reappear during another download', () {
    for (final expired in [false, true]) {
      for (final hasHistoryItem in [false, true]) {
        expect(
          shouldRetainCompletionBridge(
            queueItemExists: false,
            isRequeued: false,
            hasActiveDownloads: true,
            libraryRowLanded: false,
            hasHistoryItem: hasHistoryItem,
            expired: expired,
          ),
          isFalse,
        );
      }
    }
  });

  test('completion bridge fallback follows the current label mode', () {
    expect(
      buildCompletionBridgeFallbackQualityLabel(
        mode: AppSettings.libraryQualityLabelFileFormat,
        completedItemFilePath: '/music/completed.flac',
        storedQuality: '24-bit/96kHz',
      ),
      'FLAC',
    );
    expect(
      buildCompletionBridgeFallbackQualityLabel(
        mode: AppSettings.libraryQualityLabelBitDepthOnly,
        completedItemFilePath: '/music/completed.flac',
        storedQuality: '24-bit/96kHz',
      ),
      '24-bit',
    );
    expect(
      buildCompletionBridgeFallbackQualityLabel(
        mode: AppSettings.libraryQualityLabelBitrate,
        completedItemFilePath: '/music/completed.flac',
        storedQuality: '24-bit/96kHz',
      ),
      isNull,
    );
  });

  test(
    'completion probe falls back from stale history to completed path',
    () async {
      final checkedPaths = <String>[];
      final probe = CompletionBridgePlayableProbeCache(
        pathExists: (path) async {
          checkedPaths.add(path);
          return path == '/music/completed.flac';
        },
        retryDelays: const [],
      );
      addTearDown(probe.dispose);

      final result = probe.listenable(
        historyFilePath: '/music/stale.flac',
        completedItemFilePath: '/music/completed.flac',
      );
      expect(result.value.status, CompletionBridgePlayableStatus.checking);
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(checkedPaths, ['/music/stale.flac', '/music/completed.flac']);
      expect(result.value.status, CompletionBridgePlayableStatus.playable);
      expect(result.value.path, '/music/completed.flac');
    },
  );

  test('library file cache hides transient publication misses', () async {
    var checks = 0;
    final cache = LibraryFileAvailabilityCache(
      pathExists: (_) async => ++checks >= 3,
      normalizePath: (path) => path ?? '',
      retryDelays: const [Duration.zero, Duration.zero],
    );
    addTearDown(cache.dispose);

    final availability = cache.listenable('/music/new.flac');
    final publishedValues = <bool>[];
    availability.addListener(() => publishedValues.add(availability.value));
    expect(availability.value, isTrue);

    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(checks, 3);
    expect(availability.value, isTrue);
    expect(publishedValues, isNot(contains(false)));
  });

  test('library file cache rechecks a stale confirmed miss', () async {
    var exists = false;
    final cache = LibraryFileAvailabilityCache(
      pathExists: (_) async => exists,
      normalizePath: (path) => path ?? '',
      retryDelays: const [],
      missingRecheckAfter: Duration.zero,
    );
    addTearDown(cache.dispose);

    final availability = cache.listenable('/music/late.flac');
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(availability.value, isFalse);

    exists = true;
    expect(identical(cache.listenable('/music/late.flac'), availability), true);
    await Future<void>.delayed(const Duration(milliseconds: 10));

    expect(availability.value, isTrue);
  });

  test('completion probe heals the normal library file cache', () async {
    final availabilityCache = LibraryFileAvailabilityCache(
      pathExists: (_) async => false,
      normalizePath: (path) => path ?? '',
      retryDelays: const [],
    );
    addTearDown(availabilityCache.dispose);

    final availability = availabilityCache.listenable(
      'content://downloads/final.flac',
    );
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(availability.value, isFalse);

    final completionProbe = CompletionBridgePlayableProbeCache(
      pathExists: (_) async => true,
      onPlayable: availabilityCache.markExists,
      retryDelays: const [],
    );
    addTearDown(completionProbe.dispose);
    completionProbe.listenable(
      completedItemFilePath: 'content://downloads/final.flac',
    );
    await Future<void>.delayed(const Duration(milliseconds: 10));

    expect(availability.value, isTrue);
  });

  test(
    'download completion explicitly refreshes cached missing paths',
    () async {
      var exists = false;
      final cache = LibraryFileAvailabilityCache(
        pathExists: (_) async => exists,
        normalizePath: (path) => path ?? '',
        retryDelays: const [],
      );
      addTearDown(cache.dispose);

      final availability = cache.listenable('/music/reused.flac');
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(availability.value, isFalse);

      exists = true;
      cache.refreshForPath('/music/reused.flac');
      expect(availability.value, isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(availability.value, isTrue);
    },
  );

  test(
    'completion probe retries publication before reporting missing',
    () async {
      var checks = 0;
      final probe = CompletionBridgePlayableProbeCache(
        pathExists: (_) async => ++checks >= 3,
        retryDelays: const [Duration.zero, Duration.zero],
      );
      addTearDown(probe.dispose);

      final result = probe.listenable(
        completedItemFilePath: 'content://downloads/final.flac',
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(checks, 3);
      expect(result.value.status, CompletionBridgePlayableStatus.playable);
      expect(result.value.path, 'content://downloads/final.flac');
    },
  );

  test('completion probe can refresh a cached missing destination', () async {
    var exists = false;
    final probe = CompletionBridgePlayableProbeCache(
      pathExists: (_) async => exists,
      retryDelays: const [],
    );
    addTearDown(probe.dispose);

    final result = probe.listenable(
      completedItemFilePath: '/music/reused.flac',
    );
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(result.value.status, CompletionBridgePlayableStatus.missing);

    exists = true;
    probe.refreshForPath('/music/reused.flac');
    expect(result.value.status, CompletionBridgePlayableStatus.checking);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(result.value.status, CompletionBridgePlayableStatus.playable);
    expect(result.value.path, '/music/reused.flac');
  });

  test(
    'completion probe does not evict an actively listened notifier',
    () async {
      final probe = CompletionBridgePlayableProbeCache(
        pathExists: (_) async => true,
        retryDelays: const [],
        maxEntries: 2,
      );
      addTearDown(probe.dispose);

      final first = probe.listenable(
        completedItemFilePath: '/music/first.flac',
      );
      void listener() {}

      first.addListener(listener);
      final second = probe.listenable(
        completedItemFilePath: '/music/second.flac',
      );
      probe.listenable(completedItemFilePath: '/music/third.flac');
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(
        identical(
          first,
          probe.listenable(completedItemFilePath: '/music/first.flac'),
        ),
        isTrue,
      );
      expect(
        identical(
          second,
          probe.listenable(completedItemFilePath: '/music/second.flac'),
        ),
        isFalse,
      );
      expect(() => first.removeListener(listener), returnsNormally);
    },
  );

  test('completion bridge cards probe before showing Play or missing', () {
    final source = File(
      'lib/screens/queue_tab_collection_items.dart',
    ).readAsStringSync();
    // One builder draws both the grid cell and the list row.
    final bridgeStart = source.indexOf('Widget _buildBridgeItem(');
    final badgeStart = source.indexOf('Widget _buildLibraryQualityBadge(');

    expect(bridgeStart, greaterThanOrEqualTo(0));
    expect(badgeStart, greaterThan(bridgeStart));

    final bridgeSource = source.substring(bridgeStart, badgeStart);

    expect(bridgeSource, contains('resolveCompletionBridgePlayablePath('));
    expect(
      bridgeSource,
      contains('_completionBridgePlayableProbe.listenable('),
    );
    expect(bridgeSource, contains('CompletionBridgePlayableStatus.checking'));
    expect(bridgeSource, contains('semanticLabel:'));
    expect(bridgeSource, contains('queueCheckingDownloadedFile'));
    expect(bridgeSource, contains('_LibraryPlaybackButton('));
    expect(bridgeSource, contains('grid: grid'));
    expect(bridgeSource, contains('TrackGridCard('));
    expect(bridgeSource, contains('TrackCard('));
  });
}
