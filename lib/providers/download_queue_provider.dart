import 'dart:async';
import 'dart:math';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:mornye/services/network_download_staging.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mornye/models/download_item.dart';
import 'package:mornye/models/download_result.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/providers/extension_provider.dart';
import 'package:mornye/providers/player_motion_artwork_provider.dart';
import 'package:mornye/providers/download_verification_retry_guard.dart';
import 'package:mornye/providers/download_queue_state.dart';
import 'package:mornye/providers/download_queue_policy.dart';
import 'package:mornye/services/download_queue_persistence.dart';
import 'package:mornye/providers/download_progress.dart';
import 'package:mornye/services/download_file_finalizer.dart';
import 'package:mornye/services/download_container_finalizer.dart';
import 'package:mornye/services/download_completion_audio.dart';
import 'package:mornye/services/download_metadata_resolver.dart';
import 'package:mornye/services/download_metadata_embedding.dart';
import 'package:mornye/services/download_saf_file_replacer.dart';
import 'package:mornye/services/download_connectivity_policy.dart';
import 'package:mornye/services/download_keep_awake.dart';
import 'package:mornye/services/download_scheduler.dart';
import 'package:mornye/services/source_deletion_events.dart';
import 'package:mornye/services/platform_bridge.dart';
import 'package:mornye/services/download_request_payload.dart';
import 'package:mornye/services/folder_path_template.dart';
import 'package:mornye/services/download_motion_artwork_source.dart';
import 'package:mornye/services/ffmpeg_conversion.dart';
import 'package:mornye/services/ffmpeg_decryption.dart';
import 'package:mornye/services/ffmpeg_models.dart';
import 'package:mornye/services/ffmpeg_probe.dart';
import 'package:mornye/services/hires_check_service.dart';
import 'package:mornye/services/replaygain_service.dart';
import 'package:mornye/services/album_replaygain_readiness.dart';
import 'package:mornye/services/notification_service.dart';
import 'package:mornye/services/verification_notification.dart';
import 'package:mornye/utils/logger.dart';
import 'package:mornye/utils/desktop_folders.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:mornye/utils/file_access.dart';
import 'package:mornye/utils/string_utils.dart';
import 'package:mornye/utils/audio_format_utils.dart';
import 'package:mornye/utils/int_utils.dart';
import 'package:mornye/utils/path_match_keys.dart';
import 'package:mornye/controllers/extension_auth_launcher.dart';
import 'package:mornye/utils/download_error_type.dart';
import 'package:mornye/utils/lyrics_metadata_helper.dart';
import 'package:mornye/utils/progress_stream_poller.dart';

import 'package:mornye/providers/download_history_provider.dart';
import 'package:mornye/services/native_download_history.dart';
import 'package:mornye/services/native_download_worker_monitor.dart';

export 'package:mornye/providers/download_history_provider.dart';
export 'package:mornye/providers/download_queue_policy.dart';
export 'package:mornye/providers/download_queue_state.dart';
export 'package:mornye/services/download_metadata_resolver.dart'
    show copyTrackWithResolvedMetadata;
export 'package:mornye/services/download_queue_persistence.dart'
    show encodeDownloadQueueItemForPersistence, downloadQueuePersistenceStatus;

export 'package:mornye/services/history_database.dart'
    show HistoryLookupRequest, HistoryBatchLookupRequest;

part 'download_queue_provider_paths.dart';
part 'download_queue_provider_progress.dart';
part 'download_queue_provider_verification.dart';
part 'download_queue_provider_connectivity.dart';
part 'download_queue_provider_native_worker.dart';
part 'download_queue_provider_finalization.dart';
part 'download_queue_provider_replaygain.dart';
part 'download_queue_provider_embedding.dart';
part 'download_queue_provider_single_item.dart';
part 'download_queue_provider_hires_check.dart';

final _log = AppLogger('DownloadQueue');

final _invalidFolderChars = RegExp(r'[<>:"/\\|?*]');
final _trimDotsAndSpacesRegex = RegExp(r'^[. ]+|[. ]+$');
final _trimUnderscoresAndSpacesRegex = RegExp(r'^[_ ]+|[_ ]+$');
final _multiWhitespaceRegex = RegExp(r'\s+');
final _multiUnderscoreRegex = RegExp(r'_+');

double _log10(num x) => log(x) / ln10;
final _yearRegex = RegExp(r'^(\d{4})');
const _defaultOutputFolderName = 'Mornye';
const _defaultAndroidDownloadSubpath = 'Download/$_defaultOutputFolderName';
const _maxSafFilenameUtf8Bytes = 180;
const _maxSafDirSegmentUtf8Bytes = 120;
final _batchUniqueFilenameTokenPattern = RegExp(
  r'\{(?:title|track(?:_raw)?|track:\d+|playlist_position(?:_raw)?|playlist_position:\d+|playlist position|playlistPosition|position(?::\d+)?)\}',
  caseSensitive: false,
);
final _qualityFilenameTokenPattern = RegExp(
  r'\{quality_variant\}',
  caseSensitive: false,
);
final _explicitQualityFilenameTokenPattern = RegExp(
  r'\{(?:quality|quality_variant)\}',
  caseSensitive: false,
);

extension on DownloadItem {
  DownloadItem resetToQueued() => copyWith(
    status: DownloadStatus.queued,
    progress: 0,
    speedMBps: 0,
    bytesReceived: 0,
    bytesTotal: 0,
  );
}

class DownloadQueueNotifier extends Notifier<DownloadQueueState> {
  late final _queuePersistence = DownloadQueuePersistence(
    currentItems: () => state.items,
    onError: (error) => _log.e('Failed to persist queue: $error'),
  );
  final QueueProcessingGate _queueProcessingGate = QueueProcessingGate();
  final DownloadProgressTracker _progressTracker = DownloadProgressTracker();
  final DownloadConnectivityPolicy _connectivityPolicy =
      DownloadConnectivityPolicy();
  StreamSubscription<List<ConnectivityResult>>? _connectivitySub;
  int _downloadCount = 0;
  static const _progressPollingInterval = Duration(milliseconds: 1200);
  static const _progressStreamBootstrapTimeout = Duration(seconds: 3);
  static const _queueSchedulingInterval = Duration(milliseconds: 250);
  static const _nativePreparationBatchSize = 32;
  static const _nativePreparationWindowSize = 128;
  static const _nativeWorkerRunIdPrefsKey =
      'download_queue_native_worker_run_id';
  final NotificationService _notificationService = NotificationService();
  final _metadataResolver = DownloadMetadataResolver();
  late final _metadataEmbedding = DownloadMetadataEmbedding(
    onReplayGain: _storeTrackReplayGainForAlbum,
  );
  late final ProgressStreamPoller<Map<String, dynamic>> _progressPoller =
      ProgressStreamPoller<Map<String, dynamic>>(
        streamProvider: PlatformBridge.downloadProgressStream,
        pollProvider: PlatformBridge.getAllDownloadProgress,
        onProgress: (allProgress) async =>
            _processAllDownloadProgress(allProgress),
        pollingInterval: _progressPollingInterval,
        bootstrapTimeout: _progressStreamBootstrapTimeout,
        onStreamProcessingError: (e) =>
            _log.w('Progress stream processing failed: $e'),
        onStreamFailed: (error) => _log.w(
          'Download progress stream failed, fallback to polling: $error',
        ),
        onStreamTimeout: () =>
            _log.w('Download progress stream timeout, fallback to polling'),
        onPollError: (e) => _log.w('Progress polling failed: $e'),
        shouldPollTick: () => _progressTracker.shouldPoll(state),
      );
  int _totalQueuedAtStart = 0;
  int _completedInSession = 0;
  int _failedInSession = 0;
  int _queueItemSequence = 0;
  bool _isLoaded = false;
  Completer<void> _queueRestored = Completer<void>();
  bool _queueStartupPending = false;
  bool _queueStorageReady = true;
  bool? _startupPausedOverride;
  bool _foregroundResumeScheduled = false;
  bool _iosBackgroundExecutionExpired = false;
  StreamSubscription<List<String>>? _iosBackgroundExpirationSubscription;
  final Set<String> _ensuredDirs = {};
  final Map<String, Future<void>> _qualityVariantFileLocks = {};
  Future<String>? _appFolderStorageFallback;
  final Set<String> _rejectedAppFolderRoots = {};

  Future<T> _withQualityVariantFileLock<T>(
    String path,
    Future<T> Function() action,
  ) async {
    final key = path.toLowerCase();
    final previous = _qualityVariantFileLocks[key];
    final completer = Completer<void>();
    final current = completer.future;
    _qualityVariantFileLocks[key] = current;
    if (previous != null) await previous;
    try {
      return await action();
    } finally {
      completer.complete();
      if (identical(_qualityVariantFileLocks[key], current)) {
        _qualityVariantFileLocks.remove(key);
      }
    }
  }

  bool _networkPausedByWifiOnly = false;
  final Set<String> _locallyCancelledItemIds = {};
  final Set<String> _pausePendingItemIds = {};
  final Map<String, Future<void>> _nativeCancelRequests = {};
  final DownloadVerificationRetryGuard _verificationRetryGuard =
      DownloadVerificationRetryGuard();
  final DownloadVerificationWaitCoordinator _verificationWaitCoordinator =
      DownloadVerificationWaitCoordinator();
  final Set<String> _rateLimitRetriedItemIds = {};
  String? _activeNativeWorkerRunId;
  bool get _hasActiveAndroidNativeWorker =>
      Platform.isAndroid && _activeNativeWorkerRunId?.isNotEmpty == true;

  // Album ReplayGain accumulator: keyed by album identifier.
  // Stores per-track loudness data until all album tracks are done,
  // then computes and writes album gain/peak to every track in the album.
  final Map<String, _AlbumRgAccumulator> _albumRgData = {};

  @override
  DownloadQueueState build() {
    ref.onDispose(
      SourceDeletionEvents.instance.subscribe((source) async {
        _removeDeletedFile(source);
      }),
    );
    if (Platform.isIOS) {
      _iosBackgroundExpirationSubscription ??=
          PlatformBridge.iosBackgroundDownloadExpirationEvents().listen(
            _handleIosBackgroundDownloadExpiration,
          );
      ref.onDispose(() {
        _iosBackgroundExpirationSubscription?.cancel();
        _iosBackgroundExpirationSubscription = null;
      });
    }
    ref.listen<AppSettings>(settingsProvider, (previous, next) {
      updateSettings(next);
      if (previous?.downloadNetworkMode != next.downloadNetworkMode) {
        _handleDownloadNetworkModeChanged(next.downloadNetworkMode);
      }
    });

    ref.onDispose(() {
      if (!_queueRestored.isCompleted) _queueRestored.complete();
      _verificationWaitCoordinator.cancelAll();
      _progressPoller.stop();
      _connectivitySub?.cancel();
      _connectivitySub = null;
      _queuePersistence.dispose();
    });

    _queueStorageReady = false;
    _startQueueRestore(initializeOutputDir: true);
    return const DownloadQueueState();
  }

  void _startQueueRestore({bool initializeOutputDir = false}) {
    if (_queueStartupPending || _queueStorageReady || !ref.mounted) return;
    _queueStartupPending = true;
    final restored = _queueRestored = Completer<void>();
    Future.microtask(() async {
      try {
        if (!ref.mounted) return;
        updateSettings(ref.read(settingsProvider));
        if (initializeOutputDir) {
          try {
            await _initOutputDir();
          } catch (error, stack) {
            _log.e(
              'Failed to initialize download folder: $error',
              error,
              stack,
            );
          }
        }
        await _loadQueueFromStorage();
      } catch (error, stack) {
        _log.e('Failed to initialize download queue: $error', error, stack);
      } finally {
        if (ref.mounted && _queueStorageReady) {
          // Native adoption can publish an older paused snapshot after a user
          // has changed this choice while its platform calls were awaiting.
          final paused = _startupPausedOverride;
          if (paused != null && state.isPaused != paused) {
            if (paused && state.isProcessing) {
              pauseQueue(persistAcrossRestarts: false);
            } else if (!paused) {
              resumeQueue();
            } else {
              state = state.copyWith(isPaused: true);
            }
          }
          _startupPausedOverride = null;
        }
        _queueStartupPending = false;
        if (ref.mounted && _queueStorageReady) {
          _saveQueueToStorage();
          if (!state.isProcessing && !state.isPaused && state.queuedCount > 0) {
            Future.microtask(_processQueue);
          }
        }
        if (!restored.isCompleted) restored.complete();
      }
    });
  }

  /// Flush any debounced queue persistence to disk immediately. Called when
  /// the app is backgrounded: the OS may kill the process without a graceful
  /// teardown, and a pending debounce timer would silently drop the most
  /// recent queue mutations.
  Future<void> flushQueuePersistence({bool requireDurable = false}) async {
    // Startup publishes restored items before completing this gate. Capturing
    // the initial empty state while hydration is in flight would delete the
    // restored rows when the persistence writer reaches that empty snapshot.
    if (!_queueStorageReady) _startQueueRestore();
    await _queueRestored.future;
    if (!ref.mounted) return;
    if (!_queueStorageReady) {
      throw StateError('Download queue restoration failed; retry the flush');
    }
    await _queuePersistence.flush(requireDurable: requireDurable);
  }

  void _persistUserPausedQueue(bool paused) {
    if (_queueStartupPending) _startupPausedOverride = paused;
    _queuePersistence.setUserPaused(paused);
  }

  /// Restarts a queue that was deliberately left pending because Android did
  /// not allow a foreground service to be launched while the app was hidden.
  void resumePendingDownloadsOnForeground() {
    if (Platform.isIOS && _iosBackgroundExecutionExpired) {
      _iosBackgroundExecutionExpired = false;
      if (state.isPaused) {
        state = state.copyWith(isPaused: false);
      }
    }
    if (_foregroundResumeScheduled ||
        state.isProcessing ||
        state.isPaused ||
        !state.items.any((item) => item.status == DownloadStatus.queued)) {
      return;
    }
    _foregroundResumeScheduled = true;
    Future.microtask(() async {
      _foregroundResumeScheduled = false;
      if (!state.isProcessing &&
          !state.isPaused &&
          state.items.any((item) => item.status == DownloadStatus.queued)) {
        await _processQueue();
      }
    });
  }

  Future<void> handleVerificationNotificationTap(
    VerificationNotification target,
  ) => _handleVerificationNotificationTap(target);

  void _handleIosBackgroundDownloadExpiration(List<String> nativeItemIds) {
    if (!Platform.isIOS) return;
    final cancelledItemIds = nativeItemIds.toSet();
    final requeueItemIds = cancelledItemIds.where((id) {
      final item = state.lookup.byItemId[id];
      return item != null && item.status != DownloadStatus.completed;
    }).toSet();
    if (!state.isProcessing && requeueItemIds.isEmpty) return;

    final alreadyForeground =
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    _log.w(
      'iOS background execution time expired; safely deferring active downloads until foreground',
    );
    _iosBackgroundExecutionExpired = true;
    if (state.isProcessing && !state.isPaused) {
      pauseQueue(
        persistAcrossRestarts: false,
        nativeCancelledItemIds: cancelledItemIds,
      );
    }

    if (requeueItemIds.isNotEmpty) {
      final updatedItems = state.items
          .map((item) {
            if (!requeueItemIds.contains(item.id)) {
              return item;
            }
            return item.resetToQueued();
          })
          .toList(growable: false);
      if (state.isProcessing) {
        _pausePendingItemIds.addAll(requeueItemIds);
      }
      state = state.copyWith(
        items: updatedItems,
        isPaused: true,
        currentDownload: null,
      );
    } else if (!state.isProcessing) {
      state = state.copyWith(isPaused: true, currentDownload: null);
    }
    unawaited(
      flushQueuePersistence().catchError((Object error) {
        _log.e('Failed to flush expired iOS queue: $error');
      }),
    );
    // The native expiration callback cancels the download synchronously before this
    // asynchronous event reaches Dart. If foregrounding won that race, still
    // requeue the cancelled item, then immediately let the running queue loop
    // continue instead of misclassifying it as a skipped download.
    if (alreadyForeground) {
      resumePendingDownloadsOnForeground();
    }
  }

  Future<void> _loadQueueFromStorage() async {
    if (_isLoaded || !ref.mounted) return;

    try {
      final restorePaused = await _queuePersistence.loadUserPaused();
      if (!ref.mounted) return;
      final restoredItems = await _queuePersistence.restore();
      if (!ref.mounted) return;
      final pendingItems = restoredItems.map((item) {
        final service = _normalizeQueuedService(item.service);
        return service == item.service ? item : item.copyWith(service: service);
      }).toList();

      final normalizedPendingItems = _normalizeRestoredQueueIds(pendingItems);
      state = state.copyWith(
        // Additions remain visible immediately while the database and codec
        // worker are awaiting. Append them without deduplicating track IDs:
        // distinct requests/quality variants are deliberately separate items.
        items: [...normalizedPendingItems, ...state.items],
        isPaused:
            _startupPausedOverride ??
            (normalizedPendingItems.isNotEmpty && restorePaused),
      );
      _isLoaded = true;
      _queueStorageReady = true;
      _saveQueueToStorage();
      if (pendingItems.isEmpty) {
        if (restorePaused && _startupPausedOverride == null) {
          _queuePersistence.setUserPaused(false);
        }
        _log.d('No pending items to restore');
        await _queuePersistence.flush();
        return;
      }
      _log.i(
        'Restored ${normalizedPendingItems.length} pending items from storage',
      );
      if (await _tryAdoptAndroidNativeWorkerSnapshot(normalizedPendingItems)) {
        return;
      }
      if (!ref.mounted) return;
      if (state.isPaused) {
        _log.i('Restored queue in user-paused state');
      }
    } catch (e) {
      _log.e('Failed to load queue from storage: $e');
    }
  }

  void _saveQueueToStorage() {
    // A partial startup snapshot must never enter the writer's debounce or
    // dispose path: it would otherwise delete the restored IDs later on.
    if (!_queueStorageReady) {
      _startQueueRestore();
      return;
    }
    if (_queueStartupPending) return;
    _queuePersistence.schedule();
  }

  bool _isSafMode(AppSettings settings) {
    return Platform.isAndroid &&
        settings.storageMode == 'saf' &&
        settings.downloadTreeUri.isNotEmpty;
  }

  String _normalizeQueuedService(String service) {
    final normalized = service.trim();
    if (normalized.isEmpty) {
      return normalized;
    }

    final replacement = ref
        .read(extensionProvider.notifier)
        .replacedBuiltInDownloadProviderFor(normalized);
    if (replacement != null && replacement.isNotEmpty) {
      return replacement;
    }

    return normalized;
  }

  bool _hasActiveDownloadProvider(String service) {
    final normalized = service.trim();
    if (normalized.isEmpty) {
      return false;
    }

    final extensionState = ref.read(extensionProvider);
    return extensionState.extensions.any(
      (ext) =>
          ext.enabled &&
          ext.hasDownloadProvider &&
          ext.id.toLowerCase() == normalized.toLowerCase(),
    );
  }

  /// Builds the backend [DownloadRequestPayload] shared by the native-worker
  /// request builder and the inline single-item download path. Fields whose
  /// source value legitimately differs between the two callers (SAF staging,
  /// download strategy) are left as parameters.
  DownloadRequestPayload _buildDownloadRequestPayload({
    required Track track,
    required DownloadItem item,
    required AppSettings settings,
    required ExtensionState extensionState,
    required String quality,
    required String filenameFormat,
    required String outputDir,
    required String outputExt,
    required bool useSaf,
    String? safFileName,
    String? deezerTrackId,
    String? genre,
    String? label,
    String? copyright,
    bool stageSafForDeferredPublish = false,
    bool qualityVariantCollisionOnly = false,
  }) {
    final resolvedAlbumArtist = DownloadMetadataResolver.albumArtistForMetadata(
      track,
      settings,
    );
    final postProcessingEnabled =
        settings.useExtensionProviders &&
        extensionState.extensions.any((e) => e.enabled && e.hasPostProcessing);
    final selectedDownloadExtension = extensionState.extensions
        .where(
          (extension) =>
              extension.enabled &&
              extension.hasDownloadProvider &&
              extension.id.toLowerCase() == item.service.toLowerCase(),
        )
        .firstOrNull;
    final normalizedTrackNumber =
        (track.trackNumber != null && track.trackNumber! > 0)
        ? track.trackNumber!
        : 0;
    final normalizedDiscNumber =
        (track.discNumber != null && track.discNumber! > 0)
        ? track.discNumber!
        : 0;

    String payloadSpotifyId = track.id;
    String payloadQobuzId = '';
    String payloadTidalId = '';
    if (track.id.startsWith('qobuz:')) {
      payloadQobuzId = track.id.substring(6);
      if (_downloadProviderReplacesLegacyProvider(item.service, 'qobuz')) {
        payloadSpotifyId = '';
      }
    }
    if (track.id.startsWith('tidal:')) {
      payloadTidalId = track.id.substring(6);
      if (_downloadProviderReplacesLegacyProvider(item.service, 'tidal')) {
        payloadSpotifyId = '';
      }
    }

    return DownloadRequestPayload(
      isrc: track.isrc ?? '',
      service: item.service,
      downloadProvider: item.service,
      providerTrackId: _knownProviderTrackId(track, item.service),
      spotifyId: payloadSpotifyId,
      trackName: track.name,
      artistName: track.artistName,
      albumName: track.albumName,
      albumArtist: resolvedAlbumArtist ?? '',
      coverUrl: settings.embedMetadata ? (track.coverUrl ?? '') : '',
      coverMaxDimension: settings.embeddedCoverMaxDimension,
      outputDir: outputDir,
      albumFolderTemplate: _unresolvedAlbumFolderTemplate(
        track,
        item,
        settings,
      ),
      filenameFormat: filenameFormat,
      quality: quality,
      embedMetadata: settings.embedMetadata,
      artistTagMode: settings.artistTagMode,
      metadataSeparators: settings.metadataSeparators,
      embedLyrics:
          settings.embedMetadata &&
          settings.embedLyrics &&
          !DownloadMetadataResolver.shouldSkipLyrics(
            extensionState,
            track.source,
            item.service,
          ),
      embedReplayGain: settings.embedReplayGain,
      postProcessingEnabled: postProcessingEnabled,
      autoConvertDownloads: settings.autoConvertDownloads,
      autoConvertFormat: normalizeAutoConvertFormat(settings.autoConvertFormat),
      autoConvertBitrate: normalizeAutoConvertBitrate(
        settings.autoConvertBitrate,
      ),
      trackNumber: normalizedTrackNumber,
      playlistPosition: _validPlaylistPosition(item),
      discNumber: normalizedDiscNumber,
      totalTracks: track.totalTracks ?? 0,
      totalDiscs: track.totalDiscs ?? 0,
      releaseDate: track.releaseDate ?? '',
      itemId: item.id,
      durationMs: track.duration * 1000,
      source: track.source ?? '',
      genre: genre ?? track.genre ?? '',
      label: label ?? track.label ?? '',
      copyright: copyright ?? track.copyright ?? '',
      composer: track.composer ?? '',
      comment: track.comment ?? '',
      explicit: track.explicit == true,
      albumType: track.albumType ?? '',
      upc: track.upc ?? '',
      qobuzId: payloadQobuzId,
      tidalId: payloadTidalId,
      deezerId: deezerTrackId ?? '',
      lyricsMode: settings.lyricsMode,
      storageMode: useSaf ? 'saf' : 'app',
      safTreeUri: useSaf ? settings.downloadTreeUri : '',
      safRelativeDir: useSaf ? outputDir : '',
      safFileName: useSaf ? (safFileName ?? '') : '',
      safOutputExt: useSaf ? outputExt : '',
      outputExt: outputExt,
      stageSafOutput: stageSafForDeferredPublish,
      deferSafPublish: stageSafForDeferredPublish,
      requiresContainerConversion: _shouldRequestContainerConversion(
        item.service,
        outputExt,
      ),
      allowQualityVariant: item.preserveQualityVariant,
      qualityVariant: item.preserveQualityVariant
          ? qualityVariantStagingLabel(item.id)
          : '',
      qualityVariantCollisionOnly: qualityVariantCollisionOnly,
      songLinkRegion: settings.songLinkRegion,
      networkConcurrencyLimit:
          selectedDownloadExtension
              ?.downloadTransferPolicy
              .maxConcurrentDownloads ??
          3,
    );
  }

  String _newQueueItemId(Track track, {Set<String>? takenIds}) {
    final trimmedIsrc = track.isrc?.trim();
    final trimmedTrackId = track.id.trim();
    final base = (trimmedIsrc != null && trimmedIsrc.isNotEmpty)
        ? trimmedIsrc
        : (trimmedTrackId.isNotEmpty ? trimmedTrackId : 'track');

    while (true) {
      _queueItemSequence++;
      final candidate =
          '$base-${DateTime.now().microsecondsSinceEpoch}-$_queueItemSequence';
      if (takenIds == null || !takenIds.contains(candidate)) {
        return candidate;
      }
    }
  }

  List<DownloadItem> _normalizeRestoredQueueIds(List<DownloadItem> items) {
    if (items.isEmpty) return items;

    final seen = <String>{};
    var regeneratedCount = 0;
    final normalized = <DownloadItem>[];

    for (final item in items) {
      final trimmedId = item.id.trim();
      final shouldRegenerate = trimmedId.isEmpty || seen.contains(trimmedId);
      if (shouldRegenerate) {
        final newId = _newQueueItemId(item.track, takenIds: seen);
        seen.add(newId);
        normalized.add(item.copyWith(id: newId));
        regeneratedCount++;
      } else {
        seen.add(trimmedId);
        normalized.add(item);
      }
    }

    if (regeneratedCount > 0) {
      _log.w(
        'Regenerated $regeneratedCount duplicate/empty queue item IDs during restore',
      );
    }

    return normalized;
  }

  void updateSettings(AppSettings settings) {
    state = _withSettings(settings);
  }

  DownloadQueueState _withSettings(
    AppSettings settings, {
    List<DownloadItem>? items,
  }) {
    return state.copyWith(
      items: items,
      outputDir: settings.downloadDirectory.isNotEmpty
          ? settings.downloadDirectory
          : state.outputDir,
      filenameFormat: settings.filenameFormat,
      singleFilenameFormat: settings.singleFilenameFormat,
      audioQuality: settings.audioQuality,
      autoFallback: settings.autoFallback,
    );
  }

  String addToQueue(
    Track track,
    String service, {
    String? qualityOverride,
    String? playlistName,
    int? playlistPosition,
  }) {
    final settings = ref.read(settingsProvider);
    updateSettings(settings);

    final takenIds = state.items.map((item) => item.id).toSet();
    final id = _newQueueItemId(track, takenIds: takenIds);
    final item = DownloadItem(
      id: id,
      track: track,
      service: _normalizeQueuedService(service),
      createdAt: DateTime.now(),
      qualityOverride: qualityOverride,
      playlistName: playlistName,
      playlistPosition: playlistPosition,
      preserveQualityVariant: settings.allowQualityVariants,
      networkDownloadFolder: settings.networkDownloadFolder,
    );

    state = state.copyWith(items: [...state.items, item]);
    _saveQueueToStorage();

    if (!state.isProcessing) {
      Future.microtask(() => _processQueue());
    }

    return id;
  }

  /// Enqueues a selection without album-batch normalization or naming rules.
  /// Equivalent to separate [addToQueue] calls, with one queue publication.
  void addIndividualTracksToQueue(List<Track> tracks, String service) {
    if (tracks.isEmpty) return;
    final settings = ref.read(settingsProvider);
    final normalizedService = _normalizeQueuedService(service);
    final takenIds = state.items.map((item) => item.id).toSet();
    final newItems = <DownloadItem>[];
    for (final track in tracks) {
      final id = _newQueueItemId(track, takenIds: takenIds);
      takenIds.add(id);
      newItems.add(
        DownloadItem(
          id: id,
          track: track,
          service: normalizedService,
          createdAt: DateTime.now(),
          preserveQualityVariant: settings.allowQualityVariants,
          networkDownloadFolder: settings.networkDownloadFolder,
        ),
      );
    }
    state = _withSettings(settings, items: [...state.items, ...newItems]);
    _saveQueueToStorage();
    if (!state.isProcessing) {
      Future.microtask(() => _processQueue());
    }
  }

  void addMultipleToQueue(
    List<Track> tracks,
    String service, {
    String? qualityOverride,
    String? playlistName,
    List<int?>? playlistPositions,
  }) {
    addBatchesToQueue(
      [
        DownloadQueueBatch(
          tracks: tracks,
          playlistName: playlistName,
          playlistPositions: playlistPositions,
        ),
      ],
      service,
      qualityOverride: qualityOverride,
    );
  }

  /// Publishes several independent album/playlist batches together. Keep each
  /// group's artist normalization, batch flag and playlist positions separate.
  void addBatchesToQueue(
    List<DownloadQueueBatch> batches,
    String service, {
    String? qualityOverride,
  }) {
    if (batches.isEmpty) return;
    final settings = ref.read(settingsProvider);
    String? normalizedService;
    final takenIds = state.items.map((item) => item.id).toSet();
    final newItems = <DownloadItem>[];
    for (final batch in batches) {
      final playlistName = batch.playlistName;
      final playlistPositions = batch.playlistPositions;
      final shouldAssignPlaylistPositions =
          playlistName != null && playlistName.trim().isNotEmpty;
      final normalizedTracks = normalizeBatchAlbumArtists(batch.tracks);
      final fromBatch = normalizedTracks.length > 1;
      for (var index = 0; index < normalizedTracks.length; index++) {
        final track = normalizedTracks[index];
        final explicitPosition =
            playlistPositions != null &&
                index < playlistPositions.length &&
                (playlistPositions[index] ?? 0) > 0
            ? playlistPositions[index]
            : null;
        final id = _newQueueItemId(track, takenIds: takenIds);
        takenIds.add(id);
        newItems.add(
          DownloadItem(
            id: id,
            track: track,
            service: normalizedService ??= _normalizeQueuedService(service),
            createdAt: DateTime.now(),
            qualityOverride: qualityOverride,
            playlistName: playlistName,
            playlistPosition:
                explicitPosition ??
                (shouldAssignPlaylistPositions ? index + 1 : null),
            fromBatch: fromBatch,
            preserveQualityVariant: settings.allowQualityVariants,
            networkDownloadFolder: settings.networkDownloadFolder,
          ),
        );
      }
    }

    state = _withSettings(settings, items: [...state.items, ...newItems]);
    _saveQueueToStorage();

    if (!state.isProcessing) {
      Future.microtask(() => _processQueue());
    }
  }

  void updateItemStatus(
    String id,
    DownloadStatus status, {
    double? progress,
    double? speedMBps,
    String? filePath,
    String? error,
    DownloadErrorType? errorType,
    String? preparationStage,
    int? bytesReceived,
    int? bytesTotal,
  }) {
    final items = state.items;
    final index = state.lookup.indexByItemId[id] ?? -1;
    if (index == -1) return;

    final current = items[index];
    final next = current.copyWith(
      status: status,
      progress: progress ?? current.progress,
      speedMBps: speedMBps ?? current.speedMBps,
      filePath: filePath,
      error: error,
      errorType: errorType,
      preparationStage: preparationStage,
      bytesReceived: bytesReceived,
      bytesTotal: bytesTotal,
    );

    if (current.status == next.status &&
        current.progress == next.progress &&
        current.speedMBps == next.speedMBps &&
        current.filePath == next.filePath &&
        current.error == next.error &&
        current.errorType == next.errorType &&
        current.preparationStage == next.preparationStage &&
        current.bytesReceived == next.bytesReceived &&
        current.bytesTotal == next.bytesTotal) {
      return;
    }

    state = state.withItemReplacements({index: next});

    if (Platform.isAndroid && status == DownloadStatus.finalizing) {
      PlatformBridge.clearItemProgress(id).catchError((_) {});
      final queueCount = state.lookup.queuedCount;
      _maybeUpdateAndroidDownloadService(
        trackName: next.track.name,
        artistName: _notificationService.embeddingMetadataLabel,
        progress: 100,
        total: 100,
        queueCount: queueCount,
        status: 'finalizing',
      );
    }

    if (status == DownloadStatus.completed ||
        status == DownloadStatus.failed ||
        status == DownloadStatus.skipped) {
      _saveQueueToStorage();
    }
  }

  void _recordFailedDownload(
    String id, {
    required String error,
    required DownloadErrorType errorType,
  }) {
    updateItemStatus(
      id,
      DownloadStatus.failed,
      error: error,
      errorType: errorType,
    );
    _failedInSession++;
  }

  /// Fails requests that have not started when shared queue setup cannot
  /// continue. Active and terminal items keep their current state.
  void failQueuedDownloads({
    required String error,
    DownloadErrorType? errorType,
  }) {
    final items = state.items;
    final changes = <int, DownloadItem>{};
    for (var index = 0; index < items.length; index++) {
      final item = items[index];
      if (item.status != DownloadStatus.queued) continue;
      changes[index] = item.copyWith(
        status: DownloadStatus.failed,
        filePath: null,
        error: error,
        errorType: errorType,
      );
    }
    if (changes.isEmpty) return;

    state = state.withItemReplacements(changes);
    _saveQueueToStorage();
  }

  @visibleForTesting
  String relativeOutputDirFor(
    Track track,
    AppSettings settings, {
    String? customFolderPath,
    String? playlistName,
  }) => _buildRelativeOutputDir(
    track,
    settings,
    customFolderPath: customFolderPath,
    playlistName: playlistName,
  );

  DownloadItem? _findItemById(String id) {
    return state.lookup.byItemId[id];
  }

  bool _isLocallyCancelled(String id, {DownloadItem? item}) {
    if (_locallyCancelledItemIds.contains(id)) return true;
    final resolved = item ?? _findItemById(id);
    return resolved?.status == DownloadStatus.skipped;
  }

  bool _isPausePending(String id) => _pausePendingItemIds.contains(id);

  void _requeueItemForPause(String id) {
    final updatedItems = state.items
        .map((item) {
          if (item.id != id) return item;
          if (item.status == DownloadStatus.completed ||
              item.status == DownloadStatus.failed ||
              item.status == DownloadStatus.skipped) {
            return item;
          }
          return item.resetToQueued();
        })
        .toList(growable: false);

    final currentDownload = state.currentDownload?.id == id
        ? null
        : state.currentDownload;
    state = state.copyWith(
      items: updatedItems,
      currentDownload: currentDownload,
    );
  }

  void _requestNativeCancel(String id) {
    _verificationWaitCoordinator.cancelItem(id);
    final previous = _nativeCancelRequests[id] ?? Future<void>.value();
    final request = previous
        .then((_) => PlatformBridge.cancelDownload(id))
        .catchError((Object error) => _log.w('Could not cancel $id: $error'));
    _nativeCancelRequests[id] = request;
    unawaited(
      request.whenComplete(() {
        if (identical(_nativeCancelRequests[id], request)) {
          _nativeCancelRequests.remove(id);
        }
      }),
    );
    PlatformBridge.clearItemProgress(id).catchError((_) {});
  }

  Future<void> _finishPausedDownload(String id) async {
    try {
      final cancellation = _nativeCancelRequests[id];
      if (cancellation != null) await cancellation;
      // Pausing before the backend acquires a lease, or after it releases
      // one, leaves an idle cancel flag. Reset it only after this attempt and
      // its cancellation have finished, before the scheduler can restart it.
      if (_findItemById(id) != null && !_isLocallyCancelled(id)) {
        await PlatformBridge.resetDownloadCancel(id);
      }
    } catch (error) {
      _log.w('Could not reset paused download $id: $error');
    } finally {
      _pausePendingItemIds.remove(id);
    }
  }

  void cancelItem(String id) {
    _pausePendingItemIds.remove(id);
    _locallyCancelledItemIds.add(id);
    updateItemStatus(id, DownloadStatus.skipped);
    _requestNativeCancel(id);
  }

  void dismissItem(String id) {
    final item = _findItemById(id);
    if (item == null) return;

    final isActive =
        item.status == DownloadStatus.queued ||
        item.status == DownloadStatus.downloading ||
        item.status == DownloadStatus.finalizing;
    final wasFailed =
        item.status == DownloadStatus.failed ||
        item.status == DownloadStatus.skipped;

    if (isActive) {
      _pausePendingItemIds.remove(id);
      _locallyCancelledItemIds.add(id);
      _requestNativeCancel(id);
    } else {
      _locallyCancelledItemIds.remove(id);
    }

    if (item.status != DownloadStatus.completed) {
      _purgeAlbumRgEntry(item.track);
    }

    final items = state.items.where((entry) => entry.id != id).toList();
    final currentDownload = state.currentDownload?.id == id
        ? null
        : state.currentDownload;
    state = state.copyWith(items: items, currentDownload: currentDownload);
    _saveQueueToStorage();

    // Dismissing a failed/skipped item may unblock album RG.
    if (wasFailed) {
      _retriggerAlbumRgChecks();
    }
    if (item.status != DownloadStatus.downloading &&
        item.status != DownloadStatus.finalizing &&
        item.networkDownloadFolder.isNotEmpty) {
      unawaited(
        NetworkDownloadStaging.instance.discard(id).catchError((Object e) {
          _log.w('Could not remove network staging: $e');
        }),
      );
    }
  }

  void clearAll() {
    for (final item in state.items) {
      if (item.networkDownloadFolder.isNotEmpty &&
          item.status != DownloadStatus.downloading &&
          item.status != DownloadStatus.finalizing) {
        unawaited(
          NetworkDownloadStaging.instance.discard(item.id).catchError((
            Object e,
          ) {
            _log.w('Could not clear network staging: $e');
          }),
        );
      }
    }
    final wasProcessing = state.isProcessing;
    final activeIds = state.items
        .where(
          (item) =>
              item.status == DownloadStatus.queued ||
              item.status == DownloadStatus.downloading ||
              item.status == DownloadStatus.finalizing,
        )
        .map((item) => item.id)
        .toList(growable: false);

    if (activeIds.isNotEmpty) {
      _pausePendingItemIds.addAll(activeIds);
      _locallyCancelledItemIds.addAll(activeIds);
      for (final id in activeIds) {
        _verificationWaitCoordinator.cancelItem(id);
      }
      unawaited(PlatformBridge.cancelDownloads(activeIds));
    }

    state = state.copyWith(items: [], isPaused: false, currentDownload: null);
    _persistUserPausedQueue(false);
    if (_hasActiveAndroidNativeWorker) {
      PlatformBridge.cancelNativeDownloadWorker().catchError((_) {});
    }
    _notificationService.cancelDownloadNotification();
    _saveQueueToStorage();
    _albumRgData.clear();
    if (!wasProcessing) {
      _locallyCancelledItemIds.clear();
    }
    _pausePendingItemIds.clear();
  }

  void pauseQueue({
    bool persistAcrossRestarts = true,
    Set<String> nativeCancelledItemIds = const {},
  }) {
    if (_queueStartupPending) {
      _startupPausedOverride = true;
      if (!state.isProcessing) {
        state = state.copyWith(isPaused: true, currentDownload: null);
        if (persistAcrossRestarts) _persistUserPausedQueue(true);
        return;
      }
    }
    if (state.isProcessing && !state.isPaused) {
      final nativeWorkerActive = _hasActiveAndroidNativeWorker;
      if (nativeWorkerActive) {
        PlatformBridge.pauseNativeDownloadWorker().catchError((_) {});
      }
      final activeIds = state.items
          .where(
            (item) =>
                item.status == DownloadStatus.downloading ||
                item.status == DownloadStatus.finalizing,
          )
          .map((item) => item.id)
          .toSet();

      if (activeIds.isNotEmpty) {
        _pausePendingItemIds.addAll(activeIds);
        for (final id in activeIds) {
          if (nativeWorkerActive || nativeCancelledItemIds.contains(id)) {
            // The native worker or iOS expiry already cancelled this attempt.
            // A second cancel can arrive after it unwinds and leave a flag
            // that aborts the resumed download before it starts.
            _verificationWaitCoordinator.cancelItem(id);
          } else {
            _requestNativeCancel(id);
          }
          _requeueItemForPause(id);
        }
      }

      state = state.copyWith(isPaused: true, currentDownload: null);
      if (persistAcrossRestarts) {
        _persistUserPausedQueue(true);
      }
      _notificationService.cancelDownloadNotification();
      _log.i('Queue paused');
    }
  }

  void resumeQueue() {
    if (_queueStartupPending || !_queueStorageReady) {
      _startupPausedOverride = false;
      _persistUserPausedQueue(false);
      _startQueueRestore();
    }
    if (state.isPaused) {
      if (_hasActiveAndroidNativeWorker) {
        PlatformBridge.resumeNativeDownloadWorker().catchError((_) {});
      }
      state = state.copyWith(isPaused: false);
      _persistUserPausedQueue(false);
      _log.i('Queue resumed');
      if (state.queuedCount > 0 && !state.isProcessing) {
        Future.microtask(() => _processQueue());
      }
    }
  }

  void togglePause() {
    if (state.isPaused) {
      resumeQueue();
    } else {
      pauseQueue();
    }
  }

  Future<void> retryItem(String id) async {
    final item = state.items.where((i) => i.id == id).firstOrNull;
    if (item == null) {
      _log.w('retryItem: Item not found: $id');
      return;
    }

    if (item.status != DownloadStatus.failed &&
        item.status != DownloadStatus.skipped) {
      _log.w('retryItem: Item status is ${item.status}, not retrying');
      return;
    }

    _log.i('Retrying item: ${item.track.name} (id: $id)');
    // A cancel issued while the item never started leaves a pre-registered
    // flag in the backend that the next attempt would consume and abort
    // instantly; the user asked for a retry, so drop it first.
    try {
      await PlatformBridge.resetDownloadCancel(id);
    } catch (e) {
      _log.w('Failed to reset cancel flag for $id: $e');
      return;
    }
    final current = state.items.where((i) => i.id == id).firstOrNull;
    if (current == null ||
        (current.status != DownloadStatus.failed &&
            current.status != DownloadStatus.skipped)) {
      return;
    }
    _locallyCancelledItemIds.remove(id);
    _verificationRetryGuard.clearItem(id);
    _rateLimitRetriedItemIds.remove(id);

    // Purge stale ReplayGain entry for this track so a re-scan doesn't
    // produce duplicate entries that bias album gain.
    _purgeAlbumRgEntry(item.track);

    final items = state.items.map((i) {
      if (i.id == id) {
        return i.copyWith(
          status: DownloadStatus.queued,
          progress: 0,
          error: null,
          errorType: null,
          filePath: null,
        );
      }
      return i;
    }).toList();
    state = state.copyWith(items: items);
    _saveQueueToStorage();

    if (!state.isProcessing) {
      _log.d('Starting queue processing for retry');
      Future.microtask(() => _processQueue());
    } else {
      _log.d('Queue already processing, item will be picked up');
    }
  }

  Future<void> retryAllFailed({bool networkOnly = false}) async {
    final failedIds = state.items
        .where(
          (item) =>
              (item.status == DownloadStatus.failed ||
                  item.status == DownloadStatus.skipped) &&
              (!networkOnly || item.errorType == DownloadErrorType.network),
        )
        .map((item) => item.id)
        .toSet();
    if (failedIds.isEmpty) {
      _log.d('retryAllFailed: no failed downloads to retry');
      return;
    }

    _log.i('Retrying ${failedIds.length} failed download(s)');
    final retryableIds = await PlatformBridge.resetDownloadCancels(failedIds);
    if (!ref.mounted || retryableIds.isEmpty) return;
    _locallyCancelledItemIds.removeAll(retryableIds);
    _pausePendingItemIds.removeAll(retryableIds);

    for (final item in state.items) {
      if (!retryableIds.contains(item.id)) continue;
      _purgeAlbumRgEntry(item.track);
    }

    final items = state.items
        .map((item) {
          if (!retryableIds.contains(item.id)) return item;
          if (item.status != DownloadStatus.failed &&
              item.status != DownloadStatus.skipped) {
            return item;
          }
          _verificationRetryGuard.clearItem(item.id);
          _rateLimitRetriedItemIds.remove(item.id);
          return item.resetToQueued().copyWith(
            error: null,
            errorType: null,
            filePath: null,
          );
        })
        .toList(growable: false);

    state = state.copyWith(items: items, isPaused: false);
    _persistUserPausedQueue(false);
    _saveQueueToStorage();

    if (!state.isProcessing) {
      Future.microtask(() => _processQueue());
    }
  }

  /// Reinserts a queued item ahead of all other queued items so the next
  /// free download slot picks it up. During an active native worker run the
  /// current batch keeps its order; the new order applies from the next run.
  void downloadNext(String id) {
    final items = state.items;
    final index = items.indexWhere((item) => item.id == id);
    if (index == -1) return;
    final item = items[index];
    if (item.status != DownloadStatus.queued) return;
    final firstQueuedIndex = items.indexWhere(
      (candidate) => candidate.status == DownloadStatus.queued,
    );
    if (firstQueuedIndex == index) return;
    final reordered = List<DownloadItem>.from(items)
      ..removeAt(index)
      ..insert(firstQueuedIndex, item);
    state = state.copyWith(items: reordered);
    _saveQueueToStorage();
  }

  /// Moves a queued item [offset] positions up (negative) or down (positive)
  /// among the queued items, leaving non-queued rows in place. Same native
  /// worker caveat as [downloadNext]: an in-flight batch keeps its order.
  void moveQueuedItem(String id, int offset) {
    if (offset == 0) return;
    final items = state.items;
    final index = items.indexWhere((item) => item.id == id);
    if (index == -1) return;
    final item = items[index];
    if (item.status != DownloadStatus.queued) return;
    final queuedIndices = <int>[
      for (var i = 0; i < items.length; i++)
        if (items[i].status == DownloadStatus.queued) i,
    ];
    final position = queuedIndices.indexOf(index);
    final targetPosition = position + offset;
    if (targetPosition < 0 || targetPosition >= queuedIndices.length) return;
    final reordered = List<DownloadItem>.from(items)..removeAt(index);
    // Inserting at the target's pre-removal index lands the item directly
    // before it when moving up and directly after it when moving down.
    reordered.insert(queuedIndices[targetPosition], item);
    state = state.copyWith(items: reordered);
    _saveQueueToStorage();
  }

  void removeItem(String id) {
    final removedItem = state.items.where((item) => item.id == id).firstOrNull;
    _locallyCancelledItemIds.remove(id);
    state = state.withoutItem(id);
    _saveQueueToStorage();

    // Clean stale album RG entries when a track is removed from the queue.
    // Only purge for items that were NOT completed — completed items' RG data
    // must survive removal because album gain is computed after the last track
    // finishes, by which time earlier completed tracks have been removed.
    if (removedItem != null && removedItem.status != DownloadStatus.completed) {
      _purgeAlbumRgEntry(removedItem.track);
      // Removing a failed/skipped item may unblock album RG for the album.
      _retriggerAlbumRgChecks();
    }
  }

  void _removeDeletedFile(String filePath) {
    final deletedKeys = buildPhysicalPathMatchKeys(filePath);
    if (deletedKeys.isEmpty) return;
    final removedIds = <String>{
      for (final item in state.items)
        if (item.status == DownloadStatus.completed &&
            buildPhysicalPathMatchKeys(item.filePath).any(deletedKeys.contains))
          item.id,
    };
    if (removedIds.isEmpty) return;
    // Match the deleted file, not the song: another provider or format may
    // be downloading the same track and must keep its independent request.
    state = state.copyWith(
      items: state.items
          .where((item) => !removedIds.contains(item.id))
          .toList(growable: false),
      currentDownload: removedIds.contains(state.currentDownload?.id)
          ? null
          : state.currentDownload,
    );
    _saveQueueToStorage();
  }

  Future<String?> exportFailedDownloads() async {
    final failedItems = state.items
        .where((item) => item.status == DownloadStatus.failed)
        .toList();

    if (failedItems.isEmpty) {
      _log.d('No failed downloads to export');
      return null;
    }

    try {
      String baseDir = state.outputDir;
      if (baseDir.isEmpty) {
        final dir = await getApplicationDocumentsDirectory();
        baseDir = dir.path;
      }

      final failedDownloadsDir = '$baseDir/failed_downloads';
      final failedDir = Directory(failedDownloadsDir);
      if (!await failedDir.exists()) {
        await failedDir.create(recursive: true);
      }

      final now = DateTime.now();
      final dateStr =
          '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
      final fileName = 'failed_downloads_$dateStr.txt';
      final filePath = '$failedDownloadsDir/$fileName';

      final file = File(filePath);
      final bool fileExists = await file.exists();

      final buffer = StringBuffer();

      if (!fileExists) {
        buffer.writeln('# Mornye Failed Downloads');
        buffer.writeln('# Date: $dateStr');
        buffer.writeln('#');
        buffer.writeln('# Format: [Time] Track - Artist | URL | Error');
        buffer.writeln('');
      }

      final timeStr =
          '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:${now.second.toString().padLeft(2, '0')}';

      for (final item in failedItems) {
        final track = item.track;
        final spotifyUrl = track.id.startsWith('deezer:')
            ? 'https://www.deezer.com/track/${track.id.substring(7)}'
            : 'https://open.spotify.com/track/${track.id}';
        final error = item.error ?? 'Unknown error';
        buffer.writeln(
          '[$timeStr] ${track.name} - ${track.artistName} | $spotifyUrl | $error',
        );
      }

      if (fileExists) {
        await file.writeAsString(buffer.toString(), mode: FileMode.append);
        _log.i('Appended ${failedItems.length} failed downloads to: $filePath');
      } else {
        await file.writeAsString(buffer.toString());
        _log.i('Created new failed downloads file: $filePath');
      }

      return filePath;
    } catch (e) {
      _log.e('Failed to export failed downloads: $e');
      return null;
    }
  }

  DownloadErrorType _downloadErrorTypeFromMessage(String errorMsg) {
    final lowerMsg = errorMsg.toLowerCase();
    if (isExtensionVerificationRequired(errorMsg)) {
      return DownloadErrorType.verificationRequired;
    }
    if (errorMsg.contains('429') ||
        lowerMsg.contains('rate limit') ||
        lowerMsg.contains('too many requests')) {
      return DownloadErrorType.rateLimit;
    }
    if (lowerMsg.contains('not found') ||
        lowerMsg.contains('not available') ||
        lowerMsg.contains('no results')) {
      return DownloadErrorType.notFound;
    }
    if (lowerMsg.contains('permission') ||
        lowerMsg.contains('operation not permitted') ||
        lowerMsg.contains('access denied')) {
      return DownloadErrorType.permission;
    }
    if (lowerMsg.contains('network') ||
        lowerMsg.contains('connection') ||
        lowerMsg.contains('timeout') ||
        lowerMsg.contains('dial')) {
      return DownloadErrorType.network;
    }
    return DownloadErrorType.unknown;
  }

  Future<void> _processQueue() async {
    // Wait before acquiring the single-flight processing lock. Restoration
    // may adopt an existing native run and must be free to finish that work.
    if (_queueStartupPending || !_queueStorageReady) {
      _startQueueRestore();
      await _queueRestored.future;
      if (!ref.mounted || !_queueStorageReady || state.isPaused) return;
    }
    if (!ref.mounted) return;
    if (!_queueProcessingGate.tryEnter()) return;

    try {
      if (state.isProcessing) return;
      await _processQueueSingleFlight();
    } catch (error, stack) {
      _log.e('Download queue processing failed: $error', error, stack);
      _stopProgressPolling();
      _metadataEmbedding.clearCoverCache();
      _stopConnectivityMonitoring();
      if (ref.mounted) {
        state = state.copyWith(isProcessing: false, currentDownload: null);
      }
      // Setup and finalization can fail outside the per-item pipeline. The
      // queue owner still releases the execution window before another run.
      try {
        if (Platform.isAndroid) {
          await PlatformBridge.stopDownloadService();
        } else if (Platform.isIOS) {
          await PlatformBridge.endBackgroundDownloadTask();
        }
        await downloadKeepAwake.end();
      } catch (cleanupError, cleanupStack) {
        _log.e(
          'Failed to release download execution window: $cleanupError',
          cleanupError,
          cleanupStack,
        );
      }
    } finally {
      if (_queueProcessingGate.leave()) {
        Future.microtask(_processQueue);
      }
    }
  }

  Future<void> _processQueueSingleFlight() async {
    if (Platform.isAndroid &&
        state.items.any((item) => item.status == DownloadStatus.queued) &&
        !canStartForegroundDownloadForLifecycle(
          WidgetsBinding.instance.lifecycleState,
        )) {
      _log.i(
        'Download queue is waiting for the app to return to the foreground',
      );
      return;
    }

    var settings = ref.read(settingsProvider);
    updateSettings(settings);
    var isSafMode = _isSafMode(settings);
    final networkOnlyQueue = state.items
        .where((item) => item.status == DownloadStatus.queued)
        .every((item) => item.networkDownloadFolder.isNotEmpty);
    if (!networkOnlyQueue && settings.useExtensionProviders) {
      // Cold browser callbacks and restored downloads share initialization.
      // An empty list while loading must not be treated as removed providers.
      await ref.read(extensionProvider.notifier).ensureInitialized();
      if (!ref.mounted || state.isPaused) return;
      settings = ref.read(settingsProvider);
      updateSettings(settings);
      isSafMode = _isSafMode(settings);
    }
    IosSecurityScopedAccess? iosDownloadBookmarkAccess;

    // Validate SAF before handing the batch to either queue implementation.
    // Never silently redirect a user-selected SAF destination into private app
    // storage: keep the selection intact so the UI can request access again.
    if (!networkOnlyQueue &&
        Platform.isAndroid &&
        settings.storageMode == 'saf') {
      var safAccessible = settings.downloadTreeUri.isNotEmpty;
      if (safAccessible) {
        try {
          safAccessible = await PlatformBridge.validateSafTreeAccess(
            settings.downloadTreeUri,
          );
        } catch (e) {
          safAccessible = false;
          _log.w('SAF access validation threw an error: $e');
        }
      }
      if (!safAccessible) {
        _log.w(
          'SAF grant is missing or no longer writable; download location must be reselected',
        );
        failQueuedDownloads(
          error: safPermissionLostErrorMessage,
          errorType: DownloadErrorType.permission,
        );
        return;
      }
    }
    if (Platform.isAndroid &&
        !networkOnlyQueue &&
        !isSafMode &&
        state.outputDir.isNotEmpty &&
        !await _isDirectoryWritable(Directory(state.outputDir))) {
      final failedOutputDir = state.outputDir;
      _log.w(
        'Configured app-folder path is not writable; resolving a safe fallback',
      );
      try {
        await _activateAppFolderStorageFallback(
          failedOutputDir: failedOutputDir,
        );
        settings = ref.read(settingsProvider);
      } catch (e) {
        _log.e('No writable app-folder fallback is available: $e');
      }
    }
    if (settings.downloadNetworkMode == 'wifi_only') {
      final connectivityResult = await Connectivity().checkConnectivity();
      final hasWifi = connectivityResult.contains(ConnectivityResult.wifi);
      if (!hasWifi) {
        _log.w('WiFi-only mode enabled but no WiFi connection. Queue paused.');
        _networkPausedByWifiOnly = true;
        _startConnectivityMonitoring();
        state = state.copyWith(isProcessing: false, isPaused: true);
        return;
      }
    }
    // Monitor in every mode so idle connections are recycled on a network
    // switch, even though only wifi_only pauses the queue.
    _networkPausedByWifiOnly = false;
    _startConnectivityMonitoring();

    if (await _tryProcessQueueWithAndroidNativeWorker(settings)) {
      return;
    }

    // Native request construction can perform asynchronous metadata lookups.
    // The app may have moved to the background while those were running.
    if (Platform.isAndroid &&
        !canStartForegroundDownloadForLifecycle(
          WidgetsBinding.instance.lifecycleState,
        )) {
      _log.i(
        'Download queue moved to the background during preparation; deferring start',
      );
      _stopConnectivityMonitoring();
      return;
    }

    state = state.copyWith(isProcessing: true);
    _log.i('Starting queue processing...');

    _totalQueuedAtStart = state.items
        .where((i) => i.status == DownloadStatus.queued)
        .length;
    _completedInSession = 0;
    _failedInSession = 0;

    if (Platform.isAndroid && _totalQueuedAtStart > 0) {
      final firstItem = state.items.firstWhere(
        (item) => item.status == DownloadStatus.queued,
        orElse: () => state.items.first,
      );
      try {
        await _notificationService.cancelDownloadNotification();
        await PlatformBridge.startDownloadService(
          trackName: firstItem.track.name,
          artistName: firstItem.track.artistName,
          queueCount: _totalQueuedAtStart,
        );
        _log.d('Foreground service started');
      } catch (e) {
        if (isForegroundServiceStartNotAllowed(e)) {
          _log.w(
            'Android deferred the download service start until the app returns to the foreground',
          );
          state = state.copyWith(isProcessing: false, currentDownload: null);
          _stopConnectivityMonitoring();
          return;
        }
        _log.e('Failed to start foreground service: $e');
      }
    }

    // iOS: request a background execution window (no foreground service).
    if (Platform.isIOS && _totalQueuedAtStart > 0) {
      await PlatformBridge.beginBackgroundDownloadTask();
    }

    // Desktop: keep the computer from idle sleeping until the queue stops.
    if (_totalQueuedAtStart > 0) await downloadKeepAwake.begin();

    if (!isSafMode && state.outputDir.isEmpty) {
      _log.d('Output dir empty, initializing...');
      await _initOutputDir();
    }

    // iOS: Validate that outputDir is writable (not iCloud Drive which native code
    // can't access), unless a bookmark makes this app-Documents path-shape
    // check irrelevant (see shouldValidateIosOutputDir).
    if (!networkOnlyQueue &&
        shouldValidateIosOutputDir(
          isIOS: Platform.isIOS,
          isSafMode: isSafMode,
          outputDir: state.outputDir,
          downloadDirectoryBookmark: settings.downloadDirectoryBookmark,
        )) {
      final isICloudPath =
          state.outputDir.contains('Mobile Documents') ||
          state.outputDir.contains('CloudDocs') ||
          state.outputDir.contains('com~apple~CloudDocs');
      if (isICloudPath) {
        _log.w(
          'iOS: iCloud Drive path detected, falling back to app Documents folder',
        );
        _log.w('Native backend cannot access this iCloud Drive path');
        final musicDir = await _ensureDefaultDocumentsOutputDir();
        state = state.copyWith(outputDir: musicDir.path);
        ref.read(settingsProvider.notifier).setDownloadDirectory(musicDir.path);
      } else if (!isValidIosWritablePath(state.outputDir)) {
        _log.w(
          'iOS: Invalid output path detected (container root?), falling back to app Documents folder',
        );
        _log.w('Original path: ${state.outputDir}');
        final correctedPath = await validateOrFixIosPath(state.outputDir);
        _log.i('Corrected path: $correctedPath');
        state = state.copyWith(outputDir: correctedPath);
        ref.read(settingsProvider.notifier).setDownloadDirectory(correctedPath);
      }
    }

    if (!isSafMode && state.outputDir.isEmpty) {
      _log.d('Using fallback directory...');
      final musicDir = await _ensureDefaultDocumentsOutputDir();
      state = state.copyWith(outputDir: musicDir.path);
    }

    _log.d('Download storage mode: ${isSafMode ? 'SAF' : 'filesystem'}');

    if (!isSafMode &&
        !networkOnlyQueue &&
        Platform.isIOS &&
        settings.downloadDirectoryBookmark.isNotEmpty) {
      iosDownloadBookmarkAccess =
          await PlatformBridge.startAccessingIosBookmark(
            settings.downloadDirectoryBookmark,
          );
      final resolvedPath = iosDownloadBookmarkAccess?.path;
      if (resolvedPath != null && resolvedPath.isNotEmpty) {
        if (resolvedPath != state.outputDir) {
          _log.i('Resolved iOS download bookmark path: $resolvedPath');
          state = state.copyWith(outputDir: resolvedPath);
        }
      } else {
        _log.e('Failed to access iOS download folder bookmark');
        _log.w(
          'The saved download folder may have been moved, deleted, or its access grant lost',
        );
        failQueuedDownloads(error: downloadFolderAccessLostErrorMessage);
        state = state.copyWith(isProcessing: false);
        await PlatformBridge.endBackgroundDownloadTask();
        return;
      }
    }

    try {
      await _runQueueLoop();
    } finally {
      if (iosDownloadBookmarkAccess != null) {
        await PlatformBridge.stopAccessingIosBookmark(
          iosDownloadBookmarkAccess,
        );
        iosDownloadBookmarkAccess = null;
      }
    }
    final stoppedWhilePaused = state.isPaused;
    final keepConnectivityMonitoring =
        stoppedWhilePaused && _networkPausedByWifiOnly;

    _stopProgressPolling();
    _metadataEmbedding.clearCoverCache();
    if (!keepConnectivityMonitoring) {
      _stopConnectivityMonitoring();
    }

    if (Platform.isAndroid) {
      try {
        await PlatformBridge.stopDownloadService();
        _log.d('Foreground service stopped');
      } catch (e) {
        _log.e('Failed to stop foreground service: $e');
      }
    }

    if (Platform.isIOS) {
      await PlatformBridge.endBackgroundDownloadTask();
    }

    await downloadKeepAwake.end();

    if (stoppedWhilePaused && _downloadCount > 0) {
      try {
        await PlatformBridge.cleanupConnections();
      } catch (e) {
        _log.e('Final cleanup failed: $e');
      }
    }
    _downloadCount = 0;

    if (!stoppedWhilePaused) {
      // Releasing idle runtimes already recycles the Rust HTTP pool. A
      // separate cleanup immediately beforehand only builds it twice.
      await PlatformBridge.releaseNativeMemory();
    }

    _log.i(
      'Queue stats - completed: $_completedInSession, failed: $_failedInSession, totalAtStart: $_totalQueuedAtStart',
    );
    final hasSessionResults = _completedInSession > 0 || _failedInSession > 0;
    if (!stoppedWhilePaused && _totalQueuedAtStart > 0 && hasSessionResults) {
      try {
        await _notificationService.showQueueComplete(
          completedCount: _completedInSession,
          failedCount: _failedInSession,
        );
      } catch (error) {
        _log.w('Failed to show queue completion notification: $error');
      }

      final settings = ref.read(settingsProvider);
      if (settings.autoExportFailedDownloads && _failedInSession > 0) {
        final exportPath = await exportFailedDownloads();
        if (exportPath != null) {
          _log.i('Auto-exported failed downloads to: $exportPath');
        }
      }
    } else if (!stoppedWhilePaused && _totalQueuedAtStart > 0) {
      try {
        await _notificationService.showQueueCanceled(
          canceledCount: _totalQueuedAtStart,
        );
      } catch (error) {
        _log.w('Failed to show queue cancellation notification: $error');
      }
    }

    if (stoppedWhilePaused) {
      _log.i('Queue processing paused');
    } else {
      _log.i('Queue processing finished');
    }
    // All per-item futures have completed at this point. Remove any iOS
    // expiration guards that arrived after an individual worker's finally
    // block, otherwise the safely requeued item would be filtered forever on
    // the next queue run.
    _pausePendingItemIds.removeWhere(
      (id) => state.lookup.byItemId[id]?.status == DownloadStatus.queued,
    );
    state = state.copyWith(isProcessing: false, currentDownload: null);

    final hasQueuedItems = state.items.any(
      (item) => item.status == DownloadStatus.queued,
    );
    if (hasQueuedItems && !state.isPaused) {
      _log.i(
        'Found queued items after processing finished, restarting queue...',
      );
      Future.microtask(() => _processQueue());
    }
  }

  Future<void> _runQueueLoop() async {
    _startMultiProgressPolling();
    try {
      await DownloadScheduler<DownloadItem>(
        queuedItems: () => state.queuedItems.where(
          (item) => !_pausePendingItemIds.contains(item.id),
        ),
        idOf: (item) => item.id,
        isPaused: () => state.isPaused,
        concurrency: () => ref.read(settingsProvider).concurrentDownloads,
        checkInterval: _queueSchedulingInterval,
        start: (item) {
          updateItemStatus(item.id, DownloadStatus.downloading);
          _log.d('Started download: ${item.track.name}');
          return _downloadSingleItem(item);
        },
        onFinished: (id) =>
            PlatformBridge.clearItemProgress(id).catchError((_) {}),
      ).run();
      _log.d(
        state.isPaused
            ? 'Queue is paused and no active download remains'
            : 'No more items to process',
      );
    } finally {
      _stopProgressPolling();
      final remainingIds = state.items.map((item) => item.id).toSet();
      _locallyCancelledItemIds.removeWhere((id) => !remainingIds.contains(id));
      _pausePendingItemIds.removeWhere((id) => !remainingIds.contains(id));
      _verificationRetryGuard.retainItems(remainingIds);
      _rateLimitRetriedItemIds.removeWhere((id) => !remainingIds.contains(id));
    }
  }
}

final downloadQueueProvider =
    NotifierProvider<DownloadQueueNotifier, DownloadQueueState>(
      DownloadQueueNotifier.new,
    );

final downloadQueueLookupProvider = Provider<DownloadQueueLookup>((ref) {
  return ref.watch(downloadQueueProvider.select((s) => s.lookup));
});
