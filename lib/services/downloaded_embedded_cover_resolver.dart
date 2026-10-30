import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:mornye/services/platform_bridge.dart';
import 'package:mornye/utils/file_access.dart';

class _EmbeddedCoverCacheEntry {
  final String previewPath;
  final int? sourceModTimeMillis;
  DateTime? lastValidatedAt;

  _EmbeddedCoverCacheEntry({
    required this.previewPath,
    this.sourceModTimeMillis,
  });
}

class _PendingPreviewValidation {
  final _EmbeddedCoverCacheEntry entry;
  final Set<VoidCallback> callbacks = {};
  _PendingPreviewValidation(this.entry);

  void notify() {
    for (final callback in callbacks) {
      callback();
    }
  }
}

class _PendingEmbeddedCoverExtraction {
  final String cleanPath;
  final bool forceRefresh;
  final int? knownModTime;
  final int generation;
  final Completer<String?> completer = Completer<String?>();
  final LinkedHashSet<VoidCallback> callbacks = LinkedHashSet<VoidCallback>();
  bool isForeground;
  bool started = false;
  bool cancelled = false;

  _PendingEmbeddedCoverExtraction({
    required this.cleanPath,
    required this.forceRefresh,
    required this.knownModTime,
    required this.generation,
    required this.isForeground,
    VoidCallback? onChanged,
  }) {
    if (onChanged != null) callbacks.add(onChanged);
  }

  Future<String?> get future => completer.future;
}

/// Shared resolver for embedded cover previews from downloaded/local files.
///
/// The in-memory LRU is backed by a source-versioned persistent cache, while
/// all misses still pass through the bounded, foreground-prioritized scheduler
/// so Library scrolling cannot fan out native I/O.
class DownloadedEmbeddedCoverResolver {
  static const int _maxCacheEntries = 180;
  static const int _maxFailedExtractEntries = 360;
  static const int _maxConcurrentExtractions = 2;
  static const int _maxQueuedBackgroundExtractions = 24;
  static const String _persistentCacheDirectoryName = 'embedded_cover_previews';
  // v1 SAF previews could contain the Library's 800px thumbnail instead of
  // original embedded artwork. Re-extract even when the audio has not changed.
  static const String _persistentCacheVersion = 'v2';
  static const int _maxPersistentCacheEntries = 384;
  static const int _maxPersistentCacheBytes = 160 << 20;
  static const int _persistentCacheSweepTargetBytes = 128 << 20;

  static final LinkedHashMap<String, _EmbeddedCoverCacheEntry> _cache =
      LinkedHashMap<String, _EmbeddedCoverCacheEntry>();
  static final Map<String, _PendingEmbeddedCoverExtraction> _pendingExtract =
      <String, _PendingEmbeddedCoverExtraction>{};
  static final Queue<_PendingEmbeddedCoverExtraction>
  _foregroundExtractionQueue = Queue<_PendingEmbeddedCoverExtraction>();
  static final Queue<_PendingEmbeddedCoverExtraction>
  _backgroundExtractionQueue = Queue<_PendingEmbeddedCoverExtraction>();
  static int _activeExtractions = 0;
  static bool _drainScheduled = false;
  static final Map<String, int> _cacheGeneration = <String, int>{};
  static final Set<String> _pendingRefresh = <String>{};
  static final _pendingPreviewValidation =
      <String, _PendingPreviewValidation>{};
  static Future<void>? _previewValidationFuture;
  static const _previewValidationInterval = Duration(seconds: 5);
  static const _previewValidationBatchSize = 8;
  static const _maxPendingPreviewValidations = 64;
  static DateTime Function() _validationClock = DateTime.now;
  static final _failedExtract = <String, DateTime>{};
  static const _documentFailureRetryDelay = Duration(seconds: 30);

  static Directory? _persistentCacheDirectoryOverride;
  static Future<String>? _persistentCacheRootFuture;
  static String? _persistentCacheRootPath;
  static Future<void>? _persistentMaintenanceFuture;
  static int _stagingSequence = 0;

  static String cleanFilePath(String? filePath) {
    if (filePath == null) return '';
    if (filePath.startsWith('EXISTS:')) {
      return filePath.substring(7);
    }
    return filePath;
  }

  static Future<int?> readFileModTimeMillis(String? filePath) async {
    final cleanPath = cleanFilePath(filePath);
    if (cleanPath.isEmpty) return null;

    if (isContentUri(cleanPath)) {
      try {
        final modTimes = await PlatformBridge.getSafFileModTimes([cleanPath]);
        final modTime = modTimes[cleanPath];
        return modTime != null && modTime > 0 ? modTime : null;
      } catch (_) {
        return null;
      }
    }

    try {
      final stat = await File(cleanPath).stat();
      if (stat.type == FileSystemEntityType.notFound) return null;
      final modTime = stat.modified.millisecondsSinceEpoch;
      return modTime > 0 ? modTime : null;
    } catch (_) {
      return null;
    }
  }

  static String? resolve(String? filePath, {VoidCallback? onChanged}) {
    final cleanPath = cleanFilePath(filePath);
    if (cleanPath.isEmpty) return null;

    if (_pendingRefresh.remove(cleanPath)) {
      unawaited(
        _ensureCover(
          cleanPath,
          forceRefresh: true,
          onChanged: onChanged,
          isForeground: true,
        ),
      );
    }

    final cached = _cache[cleanPath];
    if (cached != null) {
      _touch(cleanPath, cached);
      _validateCachedPreviewAsync(cleanPath, cached, onChanged: onChanged);
      return cached.previewPath;
    }

    // A downloaded file is the source of truth for its artwork. Start the
    // extraction on a cold cache so Library does not remain stuck on the
    // metadata provider's online cover until Metadata Screen is opened.
    unawaited(_ensureCover(cleanPath, onChanged: onChanged));
    return null;
  }

  /// Returns the cached embedded cover, waiting for one shared extraction when
  /// needed. Navigation uses this to start its Hero and blurred backdrop from
  /// the same file artwork instead of swapping from the online fallback after
  /// the route is already visible.
  static Future<String?> resolveOrExtract(
    String? filePath, {
    VoidCallback? onChanged,
  }) async {
    final cleanPath = cleanFilePath(filePath);
    if (cleanPath.isEmpty) return null;

    if (_pendingRefresh.remove(cleanPath)) {
      return _ensureCover(
        cleanPath,
        forceRefresh: true,
        onChanged: onChanged,
        isForeground: true,
      );
    }

    final cached = _cache[cleanPath];
    if (cached != null) {
      _touch(cleanPath, cached);
      _validateCachedPreviewAsync(cleanPath, cached, onChanged: onChanged);
      return cached.previewPath;
    }

    return _ensureCover(cleanPath, onChanged: onChanged, isForeground: true);
  }

  /// Whether [previewPath] belongs to this resolver. Persistent previews stay
  /// owned even after memory-LRU eviction, so borrowers must never delete a
  /// file or recursively delete its shared parent directory.
  static bool isManagedPreviewPath(String? previewPath) {
    if (previewPath == null || previewPath.isEmpty) return false;
    if (_cache.values.any((entry) => entry.previewPath == previewPath)) {
      return true;
    }
    return _isPathInsidePersistentRoot(previewPath);
  }

  static Future<void> scheduleRefreshForPath(
    String? filePath, {
    int? beforeModTime,
    bool force = false,
    VoidCallback? onChanged,
  }) async {
    final cleanPath = cleanFilePath(filePath);
    if (cleanPath.isEmpty) return;

    if (!force) {
      if (beforeModTime == null) return;
      final afterModTime = await readFileModTimeMillis(cleanPath);
      if (afterModTime != null && afterModTime == beforeModTime) {
        return;
      }
    }

    _pendingRefresh.add(cleanPath);
    _failedExtract.remove(cleanPath);
    onChanged?.call();
  }

  static Future<void> invalidate(String? filePath) async {
    final cleanPath = cleanFilePath(filePath);
    if (cleanPath.isEmpty) return;

    _cacheGeneration[cleanPath] = (_cacheGeneration[cleanPath] ?? 0) + 1;
    final cached = _cache.remove(cleanPath);
    _cancelPendingExtraction(cleanPath);
    _cacheGeneration.remove(cleanPath);
    _pendingRefresh.remove(cleanPath);
    _pendingPreviewValidation.remove(cleanPath);
    _failedExtract.remove(cleanPath);
    if (cached != null) {
      await _cleanupCacheEntry(cached);
    }
    await _deletePersistentVariantsForSource(cleanPath);
  }

  /// Clears resolver state together with its App Cache-backed disk entries.
  /// Running native work is generation-cancelled and awaited before the disk
  /// directory is wiped, so a completed clear leaves no late staging output.
  static Future<void> clearPersistentCache() async {
    final keys = <String>{..._cache.keys, ..._pendingExtract.keys};
    for (final key in keys) {
      _cacheGeneration[key] = (_cacheGeneration[key] ?? 0) + 1;
      _cancelPendingExtraction(key);
      _cacheGeneration.remove(key);
    }
    while (_activeExtractions > 0) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    _cacheGeneration.clear();

    _cache.clear();
    _pendingRefresh.clear();
    _pendingPreviewValidation.clear();
    await _previewValidationFuture;
    _failedExtract.clear();

    final maintenance = _persistentMaintenanceFuture;
    if (maintenance != null) await maintenance;
    final directory = await _getPersistentCacheDirectory();
    await _clearDirectoryContents(directory);
  }

  @visibleForTesting
  static void setPersistentCacheDirectoryForTesting(Directory? directory) {
    if (_activeExtractions != 0 || _pendingExtract.isNotEmpty) {
      throw StateError('Cannot replace persistent cache while work is active');
    }
    _persistentCacheDirectoryOverride = directory;
    _persistentCacheRootFuture = null;
    _persistentCacheRootPath = directory == null
        ? null
        : _normalizedAbsolutePath(directory.path);
  }

  /// Simulates a process restart without deleting persistent preview files.
  @visibleForTesting
  static Future<void> resetMemoryStateForTesting({
    bool preservePersistentFiles = true,
  }) async {
    final maintenance = _persistentMaintenanceFuture;
    if (maintenance != null) await maintenance;

    final keys = <String>{..._cache.keys, ..._pendingExtract.keys};
    for (final key in keys) {
      _cacheGeneration[key] = (_cacheGeneration[key] ?? 0) + 1;
      _cancelPendingExtraction(key);
    }
    while (_activeExtractions > 0) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }

    _cache.clear();
    _pendingExtract.clear();
    _foregroundExtractionQueue.clear();
    _backgroundExtractionQueue.clear();
    _pendingRefresh.clear();
    _pendingPreviewValidation.clear();
    await _previewValidationFuture;
    _validationClock = DateTime.now;
    _failedExtract.clear();
    _cacheGeneration.clear();
    _drainScheduled = false;

    if (!preservePersistentFiles) {
      final directory = await _getPersistentCacheDirectory();
      await _clearDirectoryContents(directory);
    }
  }

  @visibleForTesting
  static Future<void> runPersistentCacheMaintenanceForTesting({
    int maxEntries = _maxPersistentCacheEntries,
    int maxBytes = _maxPersistentCacheBytes,
    int targetBytes = _persistentCacheSweepTargetBytes,
  }) async {
    final scheduled = _persistentMaintenanceFuture;
    if (scheduled != null) await scheduled;
    final directory = await _getPersistentCacheDirectory();
    await _runPersistentCacheMaintenance(
      directory,
      maxEntries: maxEntries,
      maxBytes: maxBytes,
      targetBytes: targetBytes,
    );
  }

  static void _touch(String cleanPath, _EmbeddedCoverCacheEntry entry) {
    _cache
      ..remove(cleanPath)
      ..[cleanPath] = entry;
  }

  static void _trimCacheIfNeeded() {
    while (_cache.length > _maxCacheEntries) {
      // The preview file stays: players and sessions may still show it.
      // Only the disk budget in _runPersistentCacheMaintenance removes it.
      final oldestKey = _cache.keys.first;
      _cache.remove(oldestKey);
      _cacheGeneration[oldestKey] = (_cacheGeneration[oldestKey] ?? 0) + 1;
      _cancelPendingExtraction(oldestKey);
      _cacheGeneration.remove(oldestKey);
      _pendingRefresh.remove(oldestKey);
      _pendingPreviewValidation.remove(oldestKey);
      _failedExtract.remove(oldestKey);
    }
  }

  static void _rememberFailedExtract(String cleanPath) {
    _failedExtract
      ..remove(cleanPath)
      ..[cleanPath] = _validationClock();
    while (_failedExtract.length > _maxFailedExtractEntries) {
      _failedExtract.remove(_failedExtract.keys.first);
    }
  }

  static void _validateCachedPreviewAsync(
    String cleanPath,
    _EmbeddedCoverCacheEntry entry, {
    VoidCallback? onChanged,
  }) {
    final existing = _pendingPreviewValidation[cleanPath];
    if (existing != null && identical(existing.entry, entry)) {
      if (onChanged != null) existing.callbacks.add(onChanged);
      return;
    }
    final lastValidated = entry.lastValidatedAt;
    if (lastValidated != null &&
        _validationClock().difference(lastValidated) <
            _previewValidationInterval) {
      return;
    }
    if (_pendingPreviewValidation.length >= _maxPendingPreviewValidations) {
      return; // A later visible cache hit can retry; extraction is unaffected.
    }
    final request = _PendingPreviewValidation(entry);
    if (onChanged != null) request.callbacks.add(onChanged);
    _pendingPreviewValidation[cleanPath] = request;
    _previewValidationFuture ??= Future.microtask(_drainPreviewValidations);
  }

  static Future<void> _drainPreviewValidations() async {
    try {
      while (_pendingPreviewValidation.isNotEmpty) {
        final batch = _pendingPreviewValidation.entries
            .take(_previewValidationBatchSize)
            .toList(growable: false);
        final safPaths = batch
            .where(
              (item) =>
                  isContentUri(item.key) &&
                  item.value.entry.sourceModTimeMillis != null,
            )
            .map((item) => item.key)
            .toList(growable: false);
        Map<String, int> safModTimes = const {};
        if (safPaths.isNotEmpty) {
          try {
            safModTimes = await PlatformBridge.getSafFileModTimes(safPaths);
          } catch (_) {
            // An unavailable provider is not evidence of changed artwork.
          }
        }
        await Future.wait(
          batch.map((item) async {
            final path = item.key;
            final request = item.value;
            final entry = request.entry;
            bool isCurrent() =>
                identical(_cache[path], entry) &&
                identical(_pendingPreviewValidation[path], request);
            try {
              if (!isCurrent()) return;
              final exists = await fileExists(entry.previewPath);
              if (!isCurrent()) return;
              if (!exists) {
                _cache.remove(path);
                _failedExtract.remove(path);
                await _cleanupCacheEntry(entry);
                request.notify();
                return;
              }
              final cachedModTime = entry.sourceModTimeMillis;
              final currentModTime = cachedModTime == null
                  ? null
                  : isContentUri(path)
                  ? safModTimes[path]
                  : await readFileModTimeMillis(path);
              if (!isCurrent()) return;
              entry.lastValidatedAt = _validationClock();
              if (currentModTime != null &&
                  currentModTime > 0 &&
                  currentModTime != cachedModTime) {
                await _ensureCover(
                  path,
                  forceRefresh: true,
                  knownModTime: currentModTime,
                  onChanged: request.notify,
                );
              }
            } catch (_) {
              // Keep the cached preview on inconclusive I/O failures.
            } finally {
              if (identical(_pendingPreviewValidation[path], request)) {
                _pendingPreviewValidation.remove(path);
              }
            }
          }),
        );
      }
    } finally {
      _previewValidationFuture = null;
    }
  }

  @visibleForTesting
  static void setValidationClockForTesting(DateTime Function() clock) {
    _validationClock = clock;
  }

  @visibleForTesting
  static Future<void> waitForPreviewValidationForTesting() async {
    await _previewValidationFuture;
  }

  static Future<String?> _ensureCover(
    String cleanPath, {
    bool forceRefresh = false,
    int? knownModTime,
    VoidCallback? onChanged,
    bool isForeground = false,
  }) {
    if (cleanPath.isEmpty) return Future<String?>.value();

    final inFlight = _pendingExtract[cleanPath];
    if (inFlight != null) {
      if (onChanged != null) inFlight.callbacks.add(onChanged);
      if (isForeground && !inFlight.started && !inFlight.isForeground) {
        inFlight.isForeground = true;
        if (_backgroundExtractionQueue.remove(inFlight)) {
          _foregroundExtractionQueue.addLast(inFlight);
        }
        _scheduleExtractionDrain();
      }
      return inFlight.future;
    }

    final cached = _cache[cleanPath];
    if (!forceRefresh && cached != null) {
      return Future<String?>.value(cached.previewPath);
    }
    if (!forceRefresh && _failedExtract.containsKey(cleanPath)) {
      // A SAF provider may temporarily be offline or still opening its remote
      // file. Do not turn that failure into "no artwork" for the whole session.
      // Retry on demand, with a cooldown so scrolling cannot flood the NAS.
      final failedAt = _failedExtract[cleanPath]!;
      if (!isContentUri(cleanPath) ||
          _validationClock().difference(failedAt) <
              _documentFailureRetryDelay) {
        return Future<String?>.value();
      }
      _failedExtract.remove(cleanPath);
    }

    final job = _PendingEmbeddedCoverExtraction(
      cleanPath: cleanPath,
      forceRefresh: forceRefresh,
      knownModTime: knownModTime,
      generation: _cacheGeneration[cleanPath] ?? 0,
      isForeground: isForeground,
      onChanged: onChanged,
    );
    _pendingExtract[cleanPath] = job;
    if (isForeground) {
      _foregroundExtractionQueue.addLast(job);
    } else {
      _backgroundExtractionQueue.addLast(job);
      _trimBackgroundExtractionQueue();
    }
    _scheduleExtractionDrain();
    return job.future;
  }

  static void _trimBackgroundExtractionQueue() {
    while (_backgroundExtractionQueue.length >
        _maxQueuedBackgroundExtractions) {
      final staleJob = _backgroundExtractionQueue.removeFirst();
      staleJob.cancelled = true;
      if (identical(_pendingExtract[staleJob.cleanPath], staleJob)) {
        _pendingExtract.remove(staleJob.cleanPath);
      }
      if (!staleJob.completer.isCompleted) {
        staleJob.completer.complete(null);
      }
    }
  }

  static void _scheduleExtractionDrain() {
    if (_drainScheduled) return;
    _drainScheduled = true;
    scheduleMicrotask(() {
      _drainScheduled = false;
      _drainExtractionQueue();
    });
  }

  static void _drainExtractionQueue() {
    while (_activeExtractions < _maxConcurrentExtractions) {
      final _PendingEmbeddedCoverExtraction? job;
      if (_foregroundExtractionQueue.isNotEmpty) {
        job = _foregroundExtractionQueue.removeFirst();
      } else if (_backgroundExtractionQueue.isNotEmpty) {
        job = _backgroundExtractionQueue.removeFirst();
      } else {
        return;
      }

      if (job.cancelled || !identical(_pendingExtract[job.cleanPath], job)) {
        if (!job.completer.isCompleted) job.completer.complete(null);
        continue;
      }

      job.started = true;
      _activeExtractions++;
      unawaited(_executeExtractionJob(job));
    }
  }

  static Future<void> _executeExtractionJob(
    _PendingEmbeddedCoverExtraction job,
  ) async {
    String? result;
    try {
      result = await _extractCover(job);
    } finally {
      if (!job.completer.isCompleted) job.completer.complete(result);
      if (identical(_pendingExtract[job.cleanPath], job)) {
        _pendingExtract.remove(job.cleanPath);
      }
      _activeExtractions--;
      _scheduleExtractionDrain();
    }
  }

  static bool _isCurrentExtraction(_PendingEmbeddedCoverExtraction job) {
    return !job.cancelled &&
        (_cacheGeneration[job.cleanPath] ?? 0) == job.generation;
  }

  static Future<String?> _extractCover(
    _PendingEmbeddedCoverExtraction job,
  ) async {
    final cleanPath = job.cleanPath;
    String? outputPath;
    try {
      if (!_isCurrentExtraction(job)) return null;
      final candidateModTime =
          job.knownModTime ?? await readFileModTimeMillis(cleanPath);
      final modTime = candidateModTime != null && candidateModTime > 0
          ? candidateModTime
          : null;
      if (!_isCurrentExtraction(job)) return null;

      final directory = await _getPersistentCacheDirectory();
      final persistentPath = p.join(
        directory.path,
        _persistentFileName(cleanPath, modTime),
      );
      // Without a timestamp a disk copy cannot be validated: it is extracted
      // again once per memory miss and named by its content below.
      if (modTime != null &&
          !job.forceRefresh &&
          await _isReusablePersistentPreview(persistentPath, cleanPath)) {
        if (!_isCurrentExtraction(job)) return null;
        await _touchPersistentPreview(persistentPath);
        final next = _EmbeddedCoverCacheEntry(
          previewPath: persistentPath,
          sourceModTimeMillis: modTime,
        );
        _touch(cleanPath, next);
        _failedExtract.remove(cleanPath);
        _trimCacheIfNeeded();
        _notifyCoverChanged(job);
        _schedulePersistentMaintenance();
        return persistentPath;
      }

      outputPath = p.join(
        directory.path,
        '.${p.basenameWithoutExtension(persistentPath)}.stage_'
        '${DateTime.now().microsecondsSinceEpoch}_${_stagingSequence++}.jpg',
      );

      final result = await PlatformBridge.extractCoverToFile(
        cleanPath,
        outputPath,
      );

      if (!_isCurrentExtraction(job)) {
        await _cleanupCoverPath(outputPath);
        return null;
      }

      final outputFile = File(outputPath);
      final hasCover =
          result['error'] == null &&
          await outputFile.exists() &&
          await outputFile.length() > 0;
      if (!hasCover) {
        _rememberFailedExtract(cleanPath);
        if (job.forceRefresh) {
          final previous = _cache.remove(cleanPath);
          if (previous != null) await _cleanupCacheEntry(previous);
          await _deletePersistentVariantsForSource(cleanPath);
          _notifyCoverChanged(job);
        }
        await _cleanupCoverPath(outputPath);
        return null;
      }

      if (!_isCurrentExtraction(job)) {
        await _cleanupCoverPath(outputPath);
        return null;
      }

      // An unchanged cover keeps its path; an edited one gets a new path, so
      // no decoded image of the old cover is shown for it.
      final targetPath = modTime != null
          ? persistentPath
          : p.join(
              directory.path,
              _persistentFileName(
                cleanPath,
                null,
                content: await _contentHash(outputPath),
              ),
            );
      if (!_isCurrentExtraction(job)) {
        await _cleanupCoverPath(outputPath);
        return null;
      }
      final finalPath = await _publishPersistentPreview(
        stagingPath: outputPath,
        targetPath: targetPath,
        cleanPath: cleanPath,
      );
      outputPath = finalPath;

      if (!_isCurrentExtraction(job)) {
        await _cleanupCoverPath(finalPath);
        return null;
      }

      final previous = _cache[cleanPath];
      final next = _EmbeddedCoverCacheEntry(
        previewPath: finalPath,
        sourceModTimeMillis: modTime,
      );
      _touch(cleanPath, next);
      _failedExtract.remove(cleanPath);
      _trimCacheIfNeeded();

      if (previous != null && previous.previewPath != finalPath) {
        await _cleanupCacheEntry(previous);
      }
      await _deletePersistentVariantsForSource(
        cleanPath,
        exceptPath: finalPath,
      );
      _schedulePersistentMaintenance();
      _notifyCoverChanged(job);
      return finalPath;
    } catch (_) {
      if (_isCurrentExtraction(job)) {
        _rememberFailedExtract(cleanPath);
        if (job.forceRefresh) {
          final previous = _cache.remove(cleanPath);
          if (previous != null) await _cleanupCacheEntry(previous);
          await _deletePersistentVariantsForSource(cleanPath);
          _notifyCoverChanged(job);
        }
      }
      await _cleanupCoverPath(outputPath);
      return null;
    }
  }

  static void _notifyCoverChanged(_PendingEmbeddedCoverExtraction job) {
    for (final callback in job.callbacks.toList(growable: false)) {
      try {
        callback();
      } catch (_) {}
    }
  }

  static void _cancelPendingExtraction(String cleanPath) {
    final job = _pendingExtract.remove(cleanPath);
    if (job == null) return;
    job.cancelled = true;
    if (!job.started) {
      _foregroundExtractionQueue.remove(job);
      _backgroundExtractionQueue.remove(job);
    }
    if (!job.completer.isCompleted) job.completer.complete(null);
  }

  static Future<Directory> _getPersistentCacheDirectory() async {
    final override = _persistentCacheDirectoryOverride;
    final String rootPath;
    if (override != null) {
      rootPath = override.path;
    } else {
      final future = _persistentCacheRootFuture ??= () async {
        final appCache = await getApplicationCacheDirectory();
        return p.join(appCache.path, _persistentCacheDirectoryName);
      }();
      rootPath = await future;
    }

    final directory = Directory(rootPath);
    _persistentCacheRootPath = _normalizedAbsolutePath(rootPath);
    if (!await directory.exists()) await directory.create(recursive: true);
    return directory;
  }

  /// A source without a timestamp (null [modTime]) is named `_0_<content>`
  /// by a hash of the extracted preview.
  static String _persistentFileName(
    String cleanPath,
    int? modTime, {
    String? content,
  }) {
    return '${_persistentCacheVersion}_${_stablePathHash(cleanPath)}_'
        '${(modTime ?? 0).toRadixString(16)}'
        '${content == null ? '' : '_$content'}.jpg';
  }

  static Future<String> _contentHash(String path) async {
    final digest = await sha256.bind(File(path).openRead()).first;
    return digest.toString().substring(0, 16);
  }

  /// Two independently mixed 63-bit FNV-1a lanes keep filenames compact.
  /// The exact source path is also stored in a sidecar and verified on every
  /// disk hit, so even a theoretical hash collision cannot serve wrong art.
  static String _stablePathHash(String value) {
    const mask = 0x7fffffffffffffff;
    const prime = 0x100000001b3;
    var first = 0x4bf29ce484222325;
    var second = 0x6c62272e07bb0142;
    for (final byte in utf8.encode(value)) {
      first ^= byte;
      first = (first * prime) & mask;
      second ^= (byte + 0x9d) & 0xff;
      second = ((second * prime) + 0x9e3779b9) & mask;
    }
    return '${first.toRadixString(16).padLeft(16, '0')}'
        '${second.toRadixString(16).padLeft(16, '0')}';
  }

  static String _persistentSourceSidecarPath(String previewPath) =>
      '$previewPath.source';

  static Future<bool> _isReusablePersistentPreview(
    String previewPath,
    String cleanPath,
  ) async {
    final preview = File(previewPath);
    final sidecar = File(_persistentSourceSidecarPath(previewPath));
    try {
      if (!await preview.exists() || await preview.length() <= 0) return false;
      if (!await sidecar.exists()) return false;
      if (await sidecar.readAsString() != cleanPath) return false;
      final input = await preview.open();
      try {
        final header = await input.read(4);
        // Older ID3 extraction could cache an extra NUL before JPEG data.
        return !(header.length == 4 &&
            header[0] == 0 &&
            header[1] == 0xff &&
            header[2] == 0xd8 &&
            header[3] == 0xff);
      } finally {
        await input.close();
      }
    } catch (_) {
      return false;
    }
  }

  static Future<String> _publishPersistentPreview({
    required String stagingPath,
    required String targetPath,
    required String cleanPath,
  }) async {
    final target = File(targetPath);
    final sidecar = File(_persistentSourceSidecarPath(targetPath));
    final sidecarStaging = File(
      '${sidecar.path}.stage_${DateTime.now().microsecondsSinceEpoch}_'
      '${_stagingSequence++}',
    );
    try {
      await sidecarStaging.writeAsString(cleanPath, flush: true);
      if (await sidecar.exists()) await sidecar.delete();
      await sidecarStaging.rename(sidecar.path);

      // Rename replaces the target atomically, so readers never miss it.
      await File(stagingPath).rename(target.path);
      return targetPath;
    } finally {
      await _deleteFileIfPresent(sidecarStaging);
    }
  }

  static Future<void> _touchPersistentPreview(String previewPath) async {
    try {
      await File(previewPath).setLastModified(DateTime.now());
    } catch (_) {}
  }

  static void _schedulePersistentMaintenance() {
    if (_persistentMaintenanceFuture != null) return;
    late final Future<void> future;
    future = Future<void>(() async {
      try {
        final directory = await _getPersistentCacheDirectory();
        await _runPersistentCacheMaintenance(
          directory,
          maxEntries: _maxPersistentCacheEntries,
          maxBytes: _maxPersistentCacheBytes,
          targetBytes: _persistentCacheSweepTargetBytes,
        );
      } finally {
        if (identical(_persistentMaintenanceFuture, future)) {
          _persistentMaintenanceFuture = null;
        }
      }
    });
    _persistentMaintenanceFuture = future;
    unawaited(future);
  }

  static Future<void> _runPersistentCacheMaintenance(
    Directory directory, {
    required int maxEntries,
    required int maxBytes,
    required int targetBytes,
  }) async {
    if (maxEntries < 0 || maxBytes < 0 || targetBytes < 0) {
      throw ArgumentError('Persistent cache limits must not be negative');
    }
    if (!await directory.exists()) return;

    final activePaths = _cache.values
        .map((entry) => _normalizedAbsolutePath(entry.previewPath))
        .toSet();
    final files = <File>[];
    final stats = <String, FileStat>{};
    var totalSize = 0;
    final now = DateTime.now();

    await for (final entity in directory.list(followLinks: false)) {
      if (entity is! File) continue;
      final name = p.basename(entity.path);
      try {
        final stat = await entity.stat();
        if (name.startsWith('v1_') && name.endsWith('.jpg')) {
          await entity.delete();
          await _deleteFileIfPresent(
            File(_persistentSourceSidecarPath(entity.path)),
          );
          continue;
        }
        final isAbandonedImageStage =
            name.startsWith('.$_persistentCacheVersion') &&
            name.contains('.stage_');
        final isAbandonedSidecarStage = name.contains('.jpg.source.stage_');
        if (isAbandonedImageStage || isAbandonedSidecarStage) {
          if (now.difference(stat.modified) > const Duration(hours: 1)) {
            await entity.delete();
          }
          continue;
        }
        if (name.endsWith('.jpg.source')) {
          final previewPath = entity.path.substring(
            0,
            entity.path.length - '.source'.length,
          );
          if (!await File(previewPath).exists()) await entity.delete();
          continue;
        }
        if (!name.startsWith('${_persistentCacheVersion}_') ||
            !name.endsWith('.jpg')) {
          continue;
        }
        files.add(entity);
        stats[entity.path] = stat;
        totalSize += stat.size;
      } catch (_) {}
    }

    if (files.length <= maxEntries && totalSize <= maxBytes) return;
    files.sort(
      (a, b) => stats[a.path]!.modified.compareTo(stats[b.path]!.modified),
    );
    var remainingEntries = files.length;
    final byteGoal = totalSize > maxBytes ? targetBytes : maxBytes;
    for (final file in files) {
      if (remainingEntries <= maxEntries && totalSize <= byteGoal) break;
      if (activePaths.contains(_normalizedAbsolutePath(file.path))) continue;
      final stat = stats[file.path]!;
      try {
        await file.delete();
        await _deleteFileIfPresent(
          File(_persistentSourceSidecarPath(file.path)),
        );
        remainingEntries--;
        totalSize -= stat.size;
      } catch (_) {}
    }
  }

  static Future<void> _deletePersistentVariantsForSource(
    String cleanPath, {
    String? exceptPath,
  }) async {
    final directory = await _getPersistentCacheDirectory();
    final prefix = '${_persistentCacheVersion}_${_stablePathHash(cleanPath)}_';
    final normalizedExcept = exceptPath == null
        ? null
        : _normalizedAbsolutePath(exceptPath);
    try {
      await for (final entity in directory.list(followLinks: false)) {
        if (entity is! File) continue;
        final name = p.basename(entity.path);
        if (!name.startsWith(prefix) || !name.endsWith('.jpg')) continue;
        if (normalizedExcept != null &&
            _normalizedAbsolutePath(entity.path) == normalizedExcept) {
          continue;
        }

        final sidecar = File(_persistentSourceSidecarPath(entity.path));
        if (await sidecar.exists()) {
          try {
            if (await sidecar.readAsString() != cleanPath) continue;
          } catch (_) {
            continue;
          }
        }
        await _deleteFileIfPresent(entity);
        await _deleteFileIfPresent(sidecar);
      }
    } catch (_) {}
  }

  static bool _isPathInsidePersistentRoot(String candidatePath) {
    final root = _persistentCacheRootPath;
    if (root == null) return false;
    try {
      final candidate = _normalizedAbsolutePath(candidatePath);
      return p.equals(candidate, root) || p.isWithin(root, candidate);
    } catch (_) {
      return false;
    }
  }

  static String _normalizedAbsolutePath(String path) =>
      p.normalize(p.absolute(path));

  static Future<void> _cleanupCacheEntry(_EmbeddedCoverCacheEntry entry) =>
      _cleanupCoverPath(entry.previewPath);

  /// Only files inside the persistent root are ever deleted here.
  static Future<void> _cleanupCoverPath(String? coverPath) async {
    if (coverPath == null ||
        coverPath.isEmpty ||
        !_isPathInsidePersistentRoot(coverPath)) {
      return;
    }
    await _deleteFileIfPresent(File(coverPath));
    await _deleteFileIfPresent(File(_persistentSourceSidecarPath(coverPath)));
  }

  static Future<void> _deleteFileIfPresent(File file) async {
    await deleteFileQuietly(file);
  }

  static Future<void> _clearDirectoryContents(Directory directory) async {
    if (!await directory.exists()) {
      await directory.create(recursive: true);
      return;
    }
    try {
      await for (final entity in directory.list(followLinks: false)) {
        try {
          await entity.delete(recursive: true);
        } catch (_) {}
      }
    } catch (_) {}
    if (!await directory.exists()) await directory.create(recursive: true);
  }
}
