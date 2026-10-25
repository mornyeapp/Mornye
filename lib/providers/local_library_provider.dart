import 'dart:async';
import 'dart:io';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mornye/models/library_scan_failure.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/services/library_cleanup.dart';
import 'package:mornye/services/library_database.dart';
import 'package:mornye/services/network_library_scanner.dart';
import 'package:mornye/services/notification_service.dart';
import 'package:mornye/services/platform_bridge.dart';
import 'package:mornye/utils/logger.dart';
import 'package:mornye/utils/file_access.dart';
import 'package:mornye/utils/local_library_scan_prefs.dart';
import 'package:mornye/utils/progress_stream_poller.dart';

part 'local_library_provider_sources.dart';
part 'local_library_provider_scan.dart';
part 'local_library_provider_covers.dart';

final _log = AppLogger('LocalLibrary');

const _excludedDownloadedCountKey = 'local_library_excluded_downloaded_count';
final _prefs = SharedPreferences.getInstance();

class LocalLibraryState {
  final bool isLoading;
  final bool loadFailed;
  final bool isScanning;
  final bool scanIsFinalizing;
  final bool scanIsPaused;
  final double scanProgress;
  final String? scanCurrentFile;
  final int scanTotalFiles;
  final int scannedFiles;
  final int scanErrorCount;
  final bool scanWasCancelled;
  final int totalCount;
  final int loadedIndexVersion;
  final DateTime? lastScannedAt;
  final List<LocalLibrarySource> sources;
  final String? scanningSourceId;
  final int excludedDownloadedCount;

  /// Files the last scan of each source could not read, by source ID.
  final Map<String, LibraryScanFailures> scanFailures;
  final Set<String> _trackKeySet;
  final Set<String> _isrcSet;

  LocalLibraryState({
    this.isLoading = false,
    this.loadFailed = false,
    this.isScanning = false,
    this.scanIsFinalizing = false,
    this.scanIsPaused = false,
    this.scanProgress = 0,
    this.scanCurrentFile,
    this.scanTotalFiles = 0,
    this.scannedFiles = 0,
    this.scanErrorCount = 0,
    this.scanWasCancelled = false,
    this.totalCount = 0,
    this.loadedIndexVersion = 0,
    this.lastScannedAt,
    this.sources = const <LocalLibrarySource>[],
    this.scanningSourceId,
    this.excludedDownloadedCount = 0,
    this.scanFailures = const {},
    Set<String>? trackKeySet,
    Set<String>? isrcSet,
  }) : _trackKeySet = trackKeySet ?? const <String>{},
       _isrcSet = isrcSet ?? const <String>{};

  bool hasIsrc(String isrc) => _isrcSet.contains(isrc);

  bool hasTrack(String trackName, String artistName) {
    final key = LibraryDatabase.matchKeyFor(trackName, artistName);
    return _trackKeySet.contains(key);
  }

  bool existsInLibrary({String? isrc, String? trackName, String? artistName}) {
    if (isrc != null && isrc.isNotEmpty && hasIsrc(isrc)) {
      return true;
    }
    if (trackName != null && artistName != null) {
      return hasTrack(trackName, artistName);
    }
    return false;
  }

  LocalLibraryState copyWith({
    bool? isLoading,
    bool? loadFailed,
    bool? isScanning,
    bool? scanIsFinalizing,
    bool? scanIsPaused,
    double? scanProgress,
    String? scanCurrentFile,
    int? scanTotalFiles,
    int? scannedFiles,
    int? scanErrorCount,
    bool? scanWasCancelled,
    int? totalCount,
    int? loadedIndexVersion,
    DateTime? lastScannedAt,
    bool clearLastScannedAt = false,
    List<LocalLibrarySource>? sources,
    String? scanningSourceId,
    bool clearScanningSourceId = false,
    int? excludedDownloadedCount,
    Map<String, LibraryScanFailures>? scanFailures,
    Set<String>? trackKeySet,
    Set<String>? isrcSet,
  }) {
    return LocalLibraryState(
      isLoading: isLoading ?? this.isLoading,
      loadFailed: loadFailed ?? this.loadFailed,
      isScanning: isScanning ?? this.isScanning,
      scanIsFinalizing: scanIsFinalizing ?? this.scanIsFinalizing,
      scanIsPaused: scanIsPaused ?? this.scanIsPaused,
      scanProgress: scanProgress ?? this.scanProgress,
      scanCurrentFile: scanCurrentFile ?? this.scanCurrentFile,
      scanTotalFiles: scanTotalFiles ?? this.scanTotalFiles,
      scannedFiles: scannedFiles ?? this.scannedFiles,
      scanErrorCount: scanErrorCount ?? this.scanErrorCount,
      scanWasCancelled: scanWasCancelled ?? this.scanWasCancelled,
      totalCount: totalCount ?? this.totalCount,
      loadedIndexVersion: loadedIndexVersion ?? this.loadedIndexVersion,
      lastScannedAt: clearLastScannedAt
          ? null
          : lastScannedAt ?? this.lastScannedAt,
      sources: sources ?? this.sources,
      scanningSourceId: clearScanningSourceId
          ? null
          : scanningSourceId ?? this.scanningSourceId,
      excludedDownloadedCount:
          excludedDownloadedCount ?? this.excludedDownloadedCount,
      scanFailures: scanFailures ?? this.scanFailures,
      trackKeySet: trackKeySet ?? _trackKeySet,
      isrcSet: isrcSet ?? _isrcSet,
    );
  }
}

typedef LocalLibraryAvailabilityProbe =
    Future<bool?> Function(String path, {String? bookmark});

class LocalLibraryNotifier extends Notifier<LocalLibraryState> {
  LocalLibraryNotifier({
    LibraryDatabase? database,
    LocalLibraryAvailabilityProbe? availabilityProbe,
  }) : _db = database ?? LibraryDatabase.instance,
       _availabilityProbe = availabilityProbe;

  final LibraryDatabase _db;
  final LocalLibraryAvailabilityProbe? _availabilityProbe;
  final NotificationService _notificationService = NotificationService();
  static const _progressPollingInterval = Duration(milliseconds: 350);
  static const _progressStreamBootstrapTimeout = Duration(milliseconds: 900);
  late final ProgressStreamPoller<Map<String, dynamic>> _progressPoller =
      ProgressStreamPoller<Map<String, dynamic>>(
        streamProvider: PlatformBridge.libraryScanProgressStream,
        pollProvider: PlatformBridge.getLibraryScanProgress,
        onProgress: _handleLibraryScanProgress,
        pollingInterval: _progressPollingInterval,
        bootstrapTimeout: _progressStreamBootstrapTimeout,
        onStreamProcessingError: (e) =>
            _log.w('Library scan progress stream processing failed: $e'),
        onStreamFailed: (error) => _log.w(
          'Library scan progress stream failed, fallback to polling: $error',
        ),
        onStreamTimeout: () =>
            _log.w('Library scan progress stream timeout, fallback to polling'),
        onPollError: (e) => _log.w('Library scan progress polling failed: $e'),
      );
  bool _isLoaded = false;
  bool _hasLoadedFromDatabase = false;
  Future<void>? _loadFuture;
  Future<void>? _scanRecovery;
  Future<void> _scanNotificationTail = Future<void>.value();
  bool _scanCancelRequested = false;
  bool _scanPauseRequested = false;
  bool _scanInProgress = false;
  Future<void>? _scanCompletion;
  NetworkLibraryScanner? _networkScanner;
  String? _nativeLibraryRequestId;
  final Set<String> _pendingReconnectScans = {};
  bool _drainingReconnectScans = false;
  StreamSubscription<void>? _storageEventsSubscription;
  Timer? _storageEventDebounce;
  Timer? _availabilityRetry;
  int _availabilityRetryCount = 0;
  int _sourceVersion = 0;
  int _availabilityRequestVersion = 0;
  bool _scanReconnectedOnRefresh = false;
  Future<void>? _availabilityRefreshFuture;
  Future<({List<String> reconnected, bool changed, int requestVersion})>?
  _availabilityCheckFuture;
  static const _scanNotificationHeartbeat = Duration(seconds: 4);
  int _lastScanNotificationPercent = -1;
  int _lastScanNotificationTotalFiles = -1;
  DateTime _lastScanNotificationAt = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  LocalLibraryState build() {
    ref.onDispose(() {
      _scanCancelRequested = true;
      _scanPauseRequested = false;
      _pendingReconnectScans.clear();
      unawaited(
        _networkScanner?.cancelPending().catchError((Object error) {
          _log.w('Failed to cancel disposed network scan reads: $error');
        }),
      );
      if (_scanInProgress) {
        final requestId = _nativeLibraryRequestId;
        if (requestId != null) {
          unawaited(
            PlatformBridge.cancelNativeDataJob(requestId).catchError((
              Object error,
            ) {
              _log.w('Failed to cancel disposed library ingestion: $error');
            }),
          );
        }
        unawaited(
          PlatformBridge.cancelLibraryScan().catchError((Object error) {
            _log.w('Failed to cancel disposed library scan: $error');
          }),
        );
      }
      _progressPoller.stop();
      _storageEventsSubscription?.cancel();
      _storageEventDebounce?.cancel();
      _availabilityRetry?.cancel();
    });

    if (Platform.isAndroid) {
      _storageEventsSubscription = PlatformBridge.libraryStorageEvents().listen(
        (_) {
          _storageEventDebounce?.cancel();
          _storageEventDebounce = Timer(
            const Duration(milliseconds: 900),
            () => refreshSourceAvailability(scanReconnected: true),
          );
        },
        onError: (Object e) =>
            _log.w('Library storage event stream failed: $e'),
      );
    }

    Future.microtask(_ensureLoadedFromDatabase);
    return LocalLibraryState(isLoading: true);
  }

  Future<void> _ensureLoadedFromDatabase() {
    if (!ref.mounted || _hasLoadedFromDatabase) {
      return Future<void>.value();
    }
    return _loadFuture ??= _loadFromDatabase();
  }

  Future<void> _loadFromDatabase() async {
    if (_hasLoadedFromDatabase) return;
    if (_isLoaded) {
      return _loadFuture ?? Future<void>.value();
    }
    _isLoaded = true;
    state = state.copyWith(isLoading: true, loadFailed: false);

    try {
      await _recoverInterruptedScan();
      if (!ref.mounted) return;
      // Folder configuration is independent of the potentially expensive
      // track index and storage probes. Publish it before either can fail.
      final configuredSources = await _db.getSources();
      if (!ref.mounted) return;
      state = state.copyWith(sources: configuredSources);
      await ref.read(settingsProvider.notifier).ensureLoaded();
      await _migrateLegacySource();
      final reconnectedSources = await _refreshSourceAvailabilityInDatabase();
      while (ref.mounted) {
        final sourceVersion = _sourceVersion;
        final sources = await _db.getSources();
        if (!ref.mounted) return;
        if (sourceVersion != _sourceVersion) continue;
        state = state.copyWith(sources: sources);
        final summary = await Future.wait<Object>([
          _db.getCount(),
          _db.getLookupIndex(),
        ]);
        final prefsFuture = _prefs;
        final count = summary[0] as int;
        final lookupIndex = summary[1] as LocalLibraryLookupIndex;

        DateTime? lastScannedAt;
        var excludedDownloadedCount = 0;
        var scanFailures = const <String, LibraryScanFailures>{};
        try {
          final prefs = await prefsFuture;
          lastScannedAt = readLocalLibraryLastScannedAt(prefs);
          excludedDownloadedCount =
              prefs.getInt(_excludedDownloadedCountKey) ?? 0;
          scanFailures = readLocalLibraryScanFailures(prefs);
        } catch (e) {
          _log.w('Failed to load lastScannedAt: $e');
        }

        if (!ref.mounted) return;
        if (sourceVersion != _sourceVersion) {
          if (_hasLoadedFromDatabase) break;
          continue;
        }
        state = state.copyWith(
          totalCount: count,
          loadedIndexVersion: state.loadedIndexVersion + 1,
          lastScannedAt: lastScannedAt,
          excludedDownloadedCount: excludedDownloadedCount,
          scanFailures: scanFailures,
          sources: sources,
          trackKeySet: lookupIndex.matchKeys,
          isrcSet: lookupIndex.isrcs,
        );
        _log.i(
          'Loaded local library summary: $count items, lastScannedAt: '
          '$lastScannedAt, excludedDownloadedCount: $excludedDownloadedCount',
        );
        _hasLoadedFromDatabase = true;
        break;
      }
      if (ref.mounted && reconnectedSources.reconnected.isNotEmpty) {
        unawaited(
          Future<void>.microtask(
            () => _scanSourcesSequentially(reconnectedSources.reconnected),
          ),
        );
      }
    } catch (e, stack) {
      _isLoaded = false;
      if (ref.mounted) state = state.copyWith(loadFailed: true);
      _log.e('Failed to load library from database: $e', e, stack);
    } finally {
      _loadFuture = null;
      if (ref.mounted) state = state.copyWith(isLoading: false);
    }
  }

  Future<void> reloadFromStorage() async {
    final loading = _loadFuture;
    if (loading != null) {
      await loading;
      return;
    }
    _isLoaded = false;
    _hasLoadedFromDatabase = false;
    _sourceVersion++;
    _loadFuture = null;
    await _ensureLoadedFromDatabase();
  }

  Future<LocalLibrarySource> addSource({
    required String path,
    required String displayName,
    String? bookmark,
    String? volumeId,
    bool isRemovable = false,
  }) async {
    final trimmedPath = path.trim();
    if (trimmedPath.isEmpty) {
      throw const FormatException('Library folder path is empty');
    }
    final existing = await _db.getSourceByPath(trimmedPath);
    if (existing != null) {
      _sourceVersion++;
      await _db.updateSourceState(
        existing.id,
        enabled: true,
        available: true,
        lastSeenAt: DateTime.now(),
      );
      await _refreshSummaryFromStorage();
      return existing.copyWith(
        enabled: true,
        available: true,
        lastSeenAt: DateTime.now(),
      );
    }

    final source = LocalLibrarySource(
      id: _newSourceId(trimmedPath),
      path: trimmedPath,
      displayName: displayName.trim().isEmpty
          ? _displayNameForPath(trimmedPath)
          : displayName.trim(),
      bookmark: bookmark?.trim().isEmpty == true ? null : bookmark,
      volumeId: volumeId?.trim().isEmpty == true ? null : volumeId,
      isRemovable: isRemovable || _looksLikeRemovablePath(trimmedPath),
      enabled: true,
      available: true,
      lastSeenAt: DateTime.now(),
    );
    _sourceVersion++;
    await _db.upsertSource(source);
    await _refreshSummaryFromStorage();
    return source;
  }

  Future<void> setSourceEnabled(String sourceId, bool enabled) async {
    final source = state.sources
        .where((entry) => entry.id == sourceId)
        .firstOrNull;
    _sourceVersion++;
    await _db.updateSourceState(sourceId, enabled: enabled);
    await _refreshSummaryFromStorage();
    if (enabled &&
        source?.available == true &&
        source?.isIndexed == true &&
        !_scanInProgress) {
      unawaited(startSourceScan(sourceId));
    }
  }

  Future<void> removeSource(String sourceId) async {
    _sourceVersion++;
    await _db.removeSource(sourceId);
    await _setScanFailures(sourceId, null);
    await _refreshSummaryFromStorage();
  }

  Future<void> refreshSourceAvailability({bool scanReconnected = false}) {
    _availabilityRequestVersion++;
    _scanReconnectedOnRefresh |= scanReconnected;
    return _availabilityRefreshFuture ??= _refreshSourceAvailability()
        .whenComplete(() {
          _availabilityRefreshFuture = null;
          _scanReconnectedOnRefresh = false;
        });
  }

  Future<void> scanAllSources({bool forceFullScan = false}) async {
    await _ensureLoadedFromDatabase();
    final sourceIds = state.sources
        .where((source) => source.enabled && source.available)
        .map((source) => source.id)
        .toList(growable: false);
    await _scanSourcesSequentially(sourceIds, forceFullScan: forceFullScan);
  }

  Future<void> startSourceScan(
    String sourceId, {
    bool forceFullScan = false,
  }) async {
    final reconnect = _pendingReconnectScans.contains(sourceId);
    while (ref.mounted) {
      final source = await _sourceForScan(sourceId);
      if (source == null ||
          (reconnect && !_pendingReconnectScans.contains(sourceId))) {
        return;
      }
      if (_scanInProgress) {
        if (!reconnect) return;
        final active = _scanCompletion;
        if (active != null) await active;
        continue;
      }
      await startScan(
        source.path,
        forceFullScan: forceFullScan,
        iosBookmark: source.bookmark,
        sourceId: source.id,
      );
      return;
    }
  }

  Future<void> startScan(
    String folderPath, {
    bool forceFullScan = false,
    String? iosBookmark,
    String? sourceId,
  }) async {
    if (!ref.mounted) return;
    await _recoverInterruptedScan();
    if (!ref.mounted) return;
    if (_scanInProgress || state.isScanning) {
      _log.w('Scan already in progress');
      return;
    }

    final completion = Completer<void>();
    _scanCompletion = completion.future;
    _scanInProgress = true;
    if (sourceId != null) _pendingReconnectScans.remove(sourceId);
    _scanCancelRequested = false;
    _scanPauseRequested = false;
    _nativeLibraryRequestId = PlatformBridge.supportsCoreBackend
        ? 'library-scan-${DateTime.now().microsecondsSinceEpoch}'
        : null;
    try {
      await _runScan(
        folderPath,
        forceFullScan: forceFullScan,
        iosBookmark: iosBookmark,
        sourceId: sourceId,
      );
    } finally {
      if (ref.mounted) {
        state = state.copyWith(
          isScanning: false,
          scanIsFinalizing: false,
          clearScanningSourceId: true,
          scanIsPaused: false,
        );
      }
      _scanInProgress = false;
      _scanCompletion = null;
      _nativeLibraryRequestId = null;
      completion.complete();
    }
  }

  Future<void> cancelScan() async {
    if (!ref.mounted || (!_scanInProgress && !state.isScanning)) return;

    _log.i('Cancelling library scan');
    _scanCancelRequested = true;
    try {
      await _networkScanner?.cancelPending();
    } catch (error) {
      _log.w('Failed to cancel network scan reads: $error');
    }
    final requestId = _nativeLibraryRequestId;
    if (requestId != null) {
      try {
        await PlatformBridge.cancelNativeDataJob(requestId);
      } catch (error) {
        _log.w('Failed to cancel library data job: $error');
      }
    }
    _pendingReconnectScans.clear();
    _availabilityRequestVersion++;
    _scanReconnectedOnRefresh = false;
    // Native cancel also releases a paused scan.
    _scanPauseRequested = false;
    if (state.isScanning && !_isScanningNetwork) {
      await PlatformBridge.cancelLibraryScan();
    }
    if (!ref.mounted) return;
    state = state.copyWith(
      scanIsFinalizing: false,
      scanIsPaused: false,
      scanWasCancelled: true,
    );
    _stopProgressPolling();
    await _showScanCancelledNotification();
  }

  /// Holds the running scan in place. Files already processed stay in the
  /// native scan's memory, so [resumeScan] continues with the next file.
  Future<void> pauseScan() async {
    if (!state.isScanning ||
        state.scanIsFinalizing ||
        state.scanIsPaused ||
        _scanCancelRequested) {
      return;
    }
    _log.i('Pausing library scan at ${state.scannedFiles} files');
    _scanPauseRequested = true;
    state = state.copyWith(scanIsPaused: true);
    try {
      if (!_isScanningNetwork) await PlatformBridge.pauseLibraryScan();
    } catch (e) {
      _log.w('Failed to pause library scan: $e');
      _scanPauseRequested = false;
      state = state.copyWith(scanIsPaused: false);
      return;
    }
    // A paused scan does no work; release the foreground service and wake
    // lock (iOS background task) until the user resumes.
    await _notificationService.endBackgroundWork(
      NotificationService.libraryScanWorkKind,
    );
    await _showScanPausedNotification(state.scannedFiles);
  }

  Future<void> resumeScan() async {
    if (!state.isScanning || !state.scanIsPaused || !_scanPauseRequested) {
      return;
    }
    _log.i('Resuming library scan from ${state.scannedFiles} files');
    // Reacquire background work first so resumed reads survive screen-off.
    await _notificationService.beginLibraryScanWork();
    await _cancelScanPausedNotification();
    _scanPauseRequested = false;
    _resetScanNotificationTracking();
    state = state.copyWith(scanIsPaused: false);
    await _releaseNativeScanPause();
  }

  Future<int> cleanupMissingFiles({String? iosBookmark}) async {
    await refreshSourceAvailability();
    var removed = 0;
    for (final source in state.sources) {
      if (!source.enabled || !source.available) continue;
      IosSecurityScopedAccess? securityAccess;
      try {
        if (Platform.isIOS &&
            source.bookmark != null &&
            source.bookmark!.isNotEmpty) {
          securityAccess = await PlatformBridge.startAccessingIosBookmark(
            source.bookmark!,
          );
          if (securityAccess == null) continue;
        }
        removed += await _db.cleanupMissingFiles(
          sourceId: source.id,
          canDelete: () async {
            if (isContentUri(source.path)) {
              return await PlatformBridge.probeSafTreeReadAccess(source.path) ==
                  true;
            }
            // Recheck access after the file probes, before deleting a page.
            // An empty but readable source is valid; an offline one throws.
            await Directory(
              securityAccess?.path ?? source.path,
            ).list(followLinks: false).take(1).drain<void>();
            return true;
          },
        );
      } finally {
        if (securityAccess != null) {
          await PlatformBridge.stopAccessingIosBookmark(securityAccess);
        }
      }
    }
    if (removed > 0) await _refreshSummaryFromStorage();
    return removed;
  }

  Future<void> clearLibrary() async {
    _sourceVersion++;
    await _db.clearAll();

    try {
      final prefs = await SharedPreferences.getInstance();
      await clearLocalLibraryLastScannedAt(prefs);
      await prefs.remove(_excludedDownloadedCountKey);
      await writeLocalLibraryScanFailures(prefs, const {});
    } catch (e) {
      _log.w('Failed to clear lastScannedAt: $e');
    }

    await _refreshSummaryFromStorage();
    state = state.copyWith(clearLastScannedAt: true, scanFailures: const {});
    _log.i('Library cleared');
  }

  Future<void> removePhysicalFiles(Iterable<String> filePaths) async {
    await removeItems(await _db.getPhysicalFileIds(filePaths));
  }

  Future<void> removeItem(String id) async {
    await removeItems([id]);
  }

  Future<void> removeItems(Iterable<String> ids) async {
    if (ids.isEmpty) return;
    await _db.deleteByIds(ids);
    await _refreshSummaryFromStorage();
  }

  Future<LocalLibraryItem?> getById(String id) async {
    final json = await _db.getById(id);
    return json == null ? null : LocalLibraryItem.fromJson(json);
  }

  Future<LocalLibraryItem?> getByIsrcAsync(String isrc) async {
    final json = await _db.getByIsrc(isrc);
    return json == null ? null : LocalLibraryItem.fromJson(json);
  }

  Future<LocalLibraryItem?> findByTrackAndArtistAsync(
    String trackName,
    String artistName,
  ) async {
    final json = await _db.findFirstByTrackAndArtist(trackName, artistName);
    return json == null ? null : LocalLibraryItem.fromJson(json);
  }

  Future<LocalLibraryItem?> findExistingAsync({
    String? id,
    String? isrc,
    String? trackName,
    String? artistName,
  }) async {
    if (id != null && id.isNotEmpty) {
      final byId = await getById(id);
      if (byId != null) return byId;
    }
    if (isrc != null && isrc.isNotEmpty) {
      final byIsrc = await getByIsrcAsync(isrc);
      if (byIsrc != null) return byIsrc;
    }
    if (trackName != null && artistName != null) {
      return findByTrackAndArtistAsync(trackName, artistName);
    }
    return null;
  }
}

final localLibraryProvider =
    NotifierProvider<LocalLibraryNotifier, LocalLibraryState>(
      LocalLibraryNotifier.new,
    );
