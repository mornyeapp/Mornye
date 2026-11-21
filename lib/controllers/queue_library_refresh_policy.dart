import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:mornye/utils/audio_format_utils.dart';
import 'package:mornye/utils/audio_quality_badge_policy.dart';
import 'package:mornye/services/downloaded_embedded_cover_resolver.dart';
import 'package:mornye/services/library_database.dart';
import 'package:mornye/services/platform_bridge.dart';
import 'package:mornye/utils/file_access.dart';

bool queueLibraryCountsHaveContent(QueueLibraryCounts counts) =>
    counts.allTrackCount > 0 ||
    counts.albumCount > 0 ||
    counts.singleTrackCount > 0;

QueueLibraryCounts resolveQueueLibraryCountsSnapshot({
  required QueueLibraryCounts current,
  QueueLibraryCounts? cached,
  QueueLibraryCounts? activeDownloadFallback,
}) {
  if (queueLibraryCountsHaveContent(current) ||
      activeDownloadFallback == null) {
    return current;
  }
  if (cached != null && queueLibraryCountsHaveContent(cached)) {
    return cached;
  }
  return activeDownloadFallback;
}

bool shouldRetainQueueLibraryPageSnapshot({
  required bool currentIsEmpty,
  required bool cachedHasContent,
  required bool activeDownloadFallbackAvailable,
}) => currentIsEmpty && cachedHasContent && activeDownloadFallbackAvailable;

/// Keeps a completed queue card visible until the matching Library row has
/// actually landed. A completed item with an in-memory History row must not
/// expire merely because the rest of its album batch was cancelled: the
/// paged Library query can still be one refresh behind that persisted row.
/// Removed requests must never be revived by another active download.
bool shouldRetainCompletionBridge({
  required bool queueItemExists,
  required bool isRequeued,
  required bool hasActiveDownloads,
  required bool libraryRowLanded,
  required bool hasHistoryItem,
  required bool expired,
}) {
  if (!queueItemExists || isRequeued || libraryRowLanded) return false;
  if (hasActiveDownloads || hasHistoryItem) return true;
  return !expired;
}

/// Builds a mode-aware label while a just-completed item is waiting for its
/// History row. This avoids pinning the card to the track's old quality text
/// when the user changes the Library label setting during an album download.
String? buildCompletionBridgeFallbackQualityLabel({
  required String mode,
  required String? completedItemFilePath,
  required String? storedQuality,
}) {
  return buildLibraryAudioQualityLabel(
    mode: mode,
    format: audioFormatForPath(completedItemFilePath),
    storedQuality: storedQuality,
  );
}

/// Returns distinct final-path candidates for a just-completed download.
/// History is authoritative after conversion/SAF publication, while the
/// completed queue item remains a safe fallback if the matched history row is
/// stale or has not been adopted into the in-memory index yet.
List<String> resolveCompletionBridgePlayableCandidates({
  String? historyFilePath,
  String? completedItemFilePath,
}) {
  final candidates = <String>[];
  for (final rawPath in [historyFilePath, completedItemFilePath]) {
    final path = rawPath?.trim();
    if (path != null && path.isNotEmpty && !candidates.contains(path)) {
      candidates.add(path);
    }
  }
  return candidates;
}

/// Synchronous preferred candidate retained for non-probing callers.
String? resolveCompletionBridgePlayablePath({
  String? historyFilePath,
  String? completedItemFilePath,
}) {
  final candidates = resolveCompletionBridgePlayableCandidates(
    historyFilePath: historyFilePath,
    completedItemFilePath: completedItemFilePath,
  );
  return candidates.isEmpty ? null : candidates.first;
}

enum CompletionBridgePlayableStatus { checking, playable, missing }

@immutable
class CompletionBridgePlayableResult {
  final CompletionBridgePlayableStatus status;
  final String? path;

  const CompletionBridgePlayableResult._(this.status, this.path);

  const CompletionBridgePlayableResult.checking()
    : this._(CompletionBridgePlayableStatus.checking, null);

  const CompletionBridgePlayableResult.playable(String path)
    : this._(CompletionBridgePlayableStatus.playable, path);

  const CompletionBridgePlayableResult.missing()
    : this._(CompletionBridgePlayableStatus.missing, null);
}

typedef CompletionBridgePathExists = Future<bool> Function(String path);
typedef LibraryFilePathNormalizer = String Function(String? path);

/// Keeps the per-card Library file check cheap without making a transient
/// storage miss permanent for the lifetime of the tab.
///
/// Android document providers can briefly return `false` immediately after a
/// file is published. Fresh paths therefore stay optimistically playable
/// during a bounded retry window. Confirmed misses are cached, but become
/// eligible for a new probe after [missingRecheckAfter] when their card is
/// rebuilt (for example after returning from the Metadata screen).
class LibraryFileAvailabilityCache {
  static const int _defaultMaxEntries = 500;
  static const int _maxResultEntries = 5000;
  static const int _safBatchSize = 64;
  static const int _maxConcurrentLocalProbes = 8;
  static const Duration _foundRecheckAfter = Duration(minutes: 5);
  static const List<Duration> _defaultRetryDelays = [
    Duration(milliseconds: 350),
    Duration(milliseconds: 700),
    Duration(milliseconds: 1400),
    Duration(milliseconds: 2200),
  ];

  final CompletionBridgePathExists _pathExists;
  final LibraryFilePathNormalizer _normalizePath;
  final List<Duration> _retryDelays;
  final Duration _missingRecheckAfter;
  final int _maxEntries;
  final LinkedHashMap<String, bool> _cache = LinkedHashMap<String, bool>();
  final Map<String, DateTime> _checkedAt = {};
  final Map<String, _LibraryFileAvailabilityNotifier> _notifiers = {};
  final Map<String, Timer> _retryTimers = {};
  final Map<String, int> _generations = {};
  final Set<String> _probingPaths = {};
  final Map<String, ({int generation, int attempt})> _pendingProbes = {};
  Timer? _flushTimer;
  final ValueNotifier<bool> _alwaysMissingNotifier = ValueNotifier(false);
  bool _disposed = false;

  LibraryFileAvailabilityCache({
    CompletionBridgePathExists pathExists = fileExists,
    LibraryFilePathNormalizer normalizePath =
        DownloadedEmbeddedCoverResolver.cleanFilePath,
    List<Duration> retryDelays = _defaultRetryDelays,
    Duration missingRecheckAfter = const Duration(seconds: 5),
    int maxEntries = _defaultMaxEntries,
  }) : assert(maxEntries > 0),
       _pathExists = pathExists,
       _normalizePath = normalizePath,
       _retryDelays = List.unmodifiable(retryDelays),
       _missingRecheckAfter = missingRecheckAfter,
       _maxEntries = maxEntries;

  ValueListenable<bool> listenable(String? filePath) {
    final path = _normalizePath(filePath);
    if (path.isEmpty || _disposed) return _alwaysMissingNotifier;

    final cached = _cache[path];
    final existingNotifier = _notifiers[path];
    if (existingNotifier != null) {
      if (cached != null && existingNotifier.value != cached) {
        existingNotifier.value = cached;
      }
      if (cached == null) {
        _beginProbe(path);
      } else if (!cached && _confirmedMissIsStale(path)) {
        // Keep showing the confirmed state while the background recheck runs;
        // it will flip to playable as soon as storage reports the file.
        _beginProbe(path, force: true);
      }
      return existingNotifier;
    }

    _evictUnusedEntriesIfNeeded();
    final notifier = _LibraryFileAvailabilityNotifier(cached ?? true);
    _notifiers[path] = notifier;
    if (cached == null) {
      _beginProbe(path);
    } else if (cached ? _foundIsStale(path) : _confirmedMissIsStale(path)) {
      _beginProbe(path, force: true);
    } else {
      _touchCachedResult(path, cached);
    }
    return notifier;
  }

  /// Starts a fresh optimistic check for a path whose storage state changed,
  /// such as the destination of a newly completed download.
  void refreshForPath(String? filePath) {
    final path = _normalizePath(filePath);
    if (path.isEmpty || _disposed) return;
    _beginProbe(path, force: true, optimistic: true);
  }

  /// Publishes a successful check performed by another component. This is
  /// used by the completion bridge so its verified final path immediately
  /// heals a stale missing icon on the normal Library card.
  void markExists(String? filePath) {
    final path = _normalizePath(filePath);
    if (path.isEmpty || _disposed) return;

    _generations[path] = (_generations[path] ?? 0) + 1;
    _retryTimers.remove(path)?.cancel();
    _pendingProbes.remove(path);
    _probingPaths.remove(path);
    _recordResult(path, true);
    final notifier = _notifiers[path];
    if (notifier != null && !notifier.value) {
      notifier.value = true;
    }
  }

  void _touchCachedResult(String path, bool exists) {
    _cache.remove(path);
    _cache[path] = exists;
  }

  void _recordResult(String path, bool exists) {
    _touchCachedResult(path, exists);
    _checkedAt[path] = DateTime.now();
    while (_cache.length > _maxResultEntries) {
      final oldest = _cache.keys.first;
      _cache.remove(oldest);
      _checkedAt.remove(oldest);
    }
  }

  bool _confirmedMissIsStale(String path) {
    final checkedAt = _checkedAt[path];
    return checkedAt == null ||
        DateTime.now().difference(checkedAt) >= _missingRecheckAfter;
  }

  /// A found file is checked again when its card returns after this long, so
  /// one deleted outside the app does not stay playable for the session.
  bool _foundIsStale(String path) {
    final checkedAt = _checkedAt[path];
    return checkedAt == null ||
        DateTime.now().difference(checkedAt) >= _foundRecheckAfter;
  }

  void _beginProbe(String path, {bool force = false, bool optimistic = false}) {
    if (_disposed || (!force && _probingPaths.contains(path))) return;

    final generation = (_generations[path] ?? 0) + 1;
    _generations[path] = generation;
    _retryTimers.remove(path)?.cancel();
    _pendingProbes.remove(path);
    _probingPaths.add(path);
    _cache.remove(path);
    _checkedAt.remove(path);
    if (optimistic) {
      final notifier = _notifiers[path];
      if (notifier != null && !notifier.value) notifier.value = true;
    }
    _enqueueProbe(path, generation: generation, attempt: 0);
  }

  void _enqueueProbe(
    String path, {
    required int generation,
    required int attempt,
  }) {
    if (_disposed || _generations[path] != generation) return;
    _pendingProbes[path] = (generation: generation, attempt: attempt);
    _flushTimer ??= Timer(Duration.zero, _flushPendingProbes);
  }

  void _flushPendingProbes() {
    _flushTimer = null;
    if (_disposed || _pendingProbes.isEmpty) return;

    final batch = Map<String, ({int generation, int attempt})>.of(
      _pendingProbes,
    );
    _pendingProbes.clear();

    final canBatchSaf = identical(_pathExists, fileExists);
    final safEntries = <MapEntry<String, ({int generation, int attempt})>>[];
    final singleEntries = <MapEntry<String, ({int generation, int attempt})>>[];
    for (final entry in batch.entries) {
      if (_generations[entry.key] != entry.value.generation) continue;
      if (canBatchSaf && isContentUri(entry.key)) {
        safEntries.add(entry);
      } else {
        singleEntries.add(entry);
      }
    }

    if (safEntries.isNotEmpty) {
      unawaited(_probeSafBatch(safEntries));
    }
    if (singleEntries.isNotEmpty) {
      unawaited(_probeSingleBatch(singleEntries));
    }
  }

  Future<void> _probeSafBatch(
    List<MapEntry<String, ({int generation, int attempt})>> entries,
  ) async {
    for (var i = 0; i < entries.length; i += _safBatchSize) {
      if (_disposed) return;
      final end = i + _safBatchSize > entries.length
          ? entries.length
          : i + _safBatchSize;
      final chunk = entries.sublist(i, end);
      // A CUE track is checked against its backing file, as fileExists does.
      final uris = {
        for (final entry in chunk) stripCueTrackSuffix(entry.key),
      }.toList(growable: false);
      Map<String, bool?>? results;
      try {
        results = await PlatformBridge.safExistsBatch(uris);
      } catch (_) {}
      if (_disposed) return;

      final fallback = <MapEntry<String, ({int generation, int attempt})>>[];
      for (final entry in chunk) {
        if (_generations[entry.key] != entry.value.generation) continue;
        final exists = results?[stripCueTrackSuffix(entry.key)];
        if (exists != null) {
          _handleProbeResult(
            entry.key,
            generation: entry.value.generation,
            attempt: entry.value.attempt,
            exists: exists,
          );
        } else {
          fallback.add(entry);
        }
      }
      if (fallback.isNotEmpty) {
        await _probeSingleBatch(fallback);
      }
    }
  }

  Future<void> _probeSingleBatch(
    List<MapEntry<String, ({int generation, int attempt})>> entries,
  ) async {
    var cursor = 0;
    final workers = entries.length < _maxConcurrentLocalProbes
        ? entries.length
        : _maxConcurrentLocalProbes;
    Future<void> worker() async {
      while (!_disposed) {
        if (cursor >= entries.length) return;
        final entry = entries[cursor++];
        final path = entry.key;
        final generation = entry.value.generation;
        if (_generations[path] != generation) continue;
        var exists = false;
        try {
          exists = await _pathExists(path);
        } catch (_) {}
        if (_disposed || _generations[path] != generation) continue;
        _handleProbeResult(
          path,
          generation: generation,
          attempt: entry.value.attempt,
          exists: exists,
        );
      }
    }

    await Future.wait([for (var i = 0; i < workers; i++) worker()]);
  }

  void _handleProbeResult(
    String path, {
    required int generation,
    required int attempt,
    required bool exists,
  }) {
    if (_disposed || _generations[path] != generation) return;

    if (exists) {
      markExists(path);
      return;
    }

    if (attempt < _retryDelays.length) {
      _retryTimers[path] = Timer(_retryDelays[attempt], () {
        _retryTimers.remove(path);
        if (_disposed || _generations[path] != generation) return;
        _enqueueProbe(path, generation: generation, attempt: attempt + 1);
      });
      return;
    }

    _probingPaths.remove(path);
    _recordResult(path, false);
    final notifier = _notifiers[path];
    if (notifier != null && notifier.value) notifier.value = false;
  }

  void _evictUnusedEntriesIfNeeded() {
    while (_notifiers.length >= _maxEntries) {
      String? evictionPath;
      for (final entry in _notifiers.entries) {
        if (!entry.value.hasActiveListeners) {
          evictionPath = entry.key;
          break;
        }
      }
      if (evictionPath == null) return;
      _removeNotifierOnly(evictionPath);
    }
  }

  void _removeNotifierOnly(String path) {
    _retryTimers.remove(path)?.cancel();
    _pendingProbes.remove(path);
    _probingPaths.remove(path);
    _generations.remove(path);
    _notifiers.remove(path)?.dispose();
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _flushTimer?.cancel();
    _flushTimer = null;
    _pendingProbes.clear();
    for (final timer in _retryTimers.values) {
      timer.cancel();
    }
    for (final notifier in _notifiers.values) {
      notifier.dispose();
    }
    _retryTimers.clear();
    _notifiers.clear();
    _probingPaths.clear();
    _cache.clear();
    _checkedAt.clear();
    _generations.clear();
    _alwaysMissingNotifier.dispose();
  }
}

class _LibraryFileAvailabilityNotifier extends ValueNotifier<bool> {
  _LibraryFileAvailabilityNotifier(super.value);

  bool get hasActiveListeners => hasListeners;
}

/// Probes both completion-path candidates and keeps a bridge in a neutral
/// checking state while delayed SAF publication becomes visible. A definitive
/// missing result is emitted only after the retry window is exhausted.
class CompletionBridgePlayableProbeCache {
  static const int _defaultMaxEntries = 500;
  static const List<Duration> _defaultRetryDelays = [
    Duration(milliseconds: 350),
    Duration(milliseconds: 700),
    Duration(milliseconds: 1400),
    Duration(milliseconds: 2200),
  ];

  final CompletionBridgePathExists _pathExists;
  final ValueChanged<String>? _onPlayable;
  final List<Duration> _retryDelays;
  final int _maxEntries;
  final Map<String, _CompletionBridgeProbeEntry> _entries = {};
  final ValueNotifier<CompletionBridgePlayableResult> _missingNotifier =
      ValueNotifier(const CompletionBridgePlayableResult.missing());
  bool _disposed = false;

  CompletionBridgePlayableProbeCache({
    CompletionBridgePathExists pathExists = fileExists,
    ValueChanged<String>? onPlayable,
    List<Duration> retryDelays = _defaultRetryDelays,
    int maxEntries = _defaultMaxEntries,
  }) : assert(maxEntries > 0),
       _pathExists = pathExists,
       _onPlayable = onPlayable,
       _retryDelays = List.unmodifiable(retryDelays),
       _maxEntries = maxEntries;

  ValueListenable<CompletionBridgePlayableResult> listenable({
    String? historyFilePath,
    String? completedItemFilePath,
  }) {
    final candidates = resolveCompletionBridgePlayableCandidates(
      historyFilePath: historyFilePath,
      completedItemFilePath: completedItemFilePath,
    );
    if (candidates.isEmpty || _disposed) return _missingNotifier;

    final key = candidates.join('\u0000');
    final existing = _entries[key];
    if (existing != null) return existing.notifier;

    while (_entries.length >= _maxEntries) {
      String? evictionKey;
      for (final candidate in _entries.entries) {
        if (!candidate.value.notifier.hasActiveListeners) {
          evictionKey = candidate.key;
          break;
        }
      }
      if (evictionKey == null) break;
      _entries.remove(evictionKey)?.dispose();
    }

    final entry = _CompletionBridgeProbeEntry(candidates);
    _entries[key] = entry;
    unawaited(_probe(entry, attempt: 0));
    return entry.notifier;
  }

  /// Rechecks cached probes that mention [filePath], including a previously
  /// missing result from an earlier completion of the same destination.
  void refreshForPath(String? filePath) {
    final path = filePath?.trim();
    if (path == null || path.isEmpty || _disposed) return;
    for (final entry in _entries.values) {
      if (!entry.candidates.contains(path)) continue;
      entry.timer?.cancel();
      entry.timer = null;
      entry.generation++;
      entry.notifier.value = const CompletionBridgePlayableResult.checking();
      unawaited(_probe(entry, attempt: 0));
    }
  }

  Future<void> _probe(
    _CompletionBridgeProbeEntry entry, {
    required int attempt,
  }) async {
    final generation = entry.generation;
    for (final path in entry.candidates) {
      var exists = false;
      try {
        exists = await _pathExists(path);
      } catch (_) {}
      if (_disposed || generation != entry.generation) return;
      if (exists) {
        _onPlayable?.call(path);
        entry.notifier.value = CompletionBridgePlayableResult.playable(path);
        return;
      }
    }

    if (attempt >= _retryDelays.length) {
      entry.notifier.value = const CompletionBridgePlayableResult.missing();
      return;
    }

    entry.timer = Timer(_retryDelays[attempt], () {
      entry.timer = null;
      if (_disposed || generation != entry.generation) return;
      unawaited(_probe(entry, attempt: attempt + 1));
    });
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    for (final entry in _entries.values) {
      entry.dispose();
    }
    _entries.clear();
    _missingNotifier.dispose();
  }
}

class _CompletionBridgeProbeEntry {
  final List<String> candidates;
  final _CompletionBridgeProbeNotifier notifier =
      _CompletionBridgeProbeNotifier();
  Timer? timer;
  int generation = 0;
  bool disposed = false;

  _CompletionBridgeProbeEntry(this.candidates);

  void dispose() {
    if (disposed) return;
    disposed = true;
    generation++;
    timer?.cancel();
    notifier.dispose();
  }
}

class _CompletionBridgeProbeNotifier
    extends ValueNotifier<CompletionBridgePlayableResult> {
  _CompletionBridgeProbeNotifier()
    : super(const CompletionBridgePlayableResult.checking());

  bool get hasActiveListeners => hasListeners;
}
