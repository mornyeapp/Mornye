// ignore_for_file: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
part of 'local_library_provider.dart';

/// Source identity, availability probing, reconnect scans and the summary
/// refresh that follows a source change.
extension _LocalLibrarySources on LocalLibraryNotifier {
  String _newSourceId(String path) {
    const offset = 0xcbf29ce484222325;
    const prime = 0x100000001b3;
    const mask = 0xffffffffffffffff;
    var hash = offset;
    for (final unit in path.codeUnits) {
      hash = ((hash ^ unit) * prime) & mask;
    }
    return 'source_${hash.toRadixString(16).padLeft(16, '0')}';
  }

  Future<void> _refreshSourceAvailability() async {
    await _ensureLoadedFromDatabase();
    final reconnected = <String>{};
    while (ref.mounted) {
      final result = await _refreshSourceAvailabilityInDatabase();
      if (!ref.mounted) return;
      reconnected.addAll(result.reconnected);
      if (result.changed) await _refreshSummaryFromStorage();
      if (result.requestVersion == _availabilityRequestVersion) break;
    }

    // Existing rows become visible as soon as availability flips. The
    // incremental pass then verifies changes made while storage was detached
    // without re-reading metadata for unchanged files.
    if (ref.mounted && _scanReconnectedOnRefresh && reconnected.isNotEmpty) {
      _pendingReconnectScans.addAll(reconnected);
      unawaited(_drainReconnectScans());
    }
  }

  Future<void> _scanSourcesSequentially(
    Iterable<String> sourceIds, {
    bool forceFullScan = false,
    bool notify = true,
  }) async {
    for (final sourceId in sourceIds) {
      if (!ref.mounted) break;
      await startSourceScan(
        sourceId,
        forceFullScan: forceFullScan,
        notify: notify,
      );
      if (_scanCancelRequested) break;
    }
  }

  Future<LocalLibrarySource?> _sourceForScan(String sourceId) async {
    if (!ref.mounted) return null;
    await _ensureLoadedFromDatabase();
    if (!ref.mounted) return null;
    while (ref.mounted) {
      final sourceVersion = _sourceVersion;
      final source = (await _db.getSources())
          .where((entry) => entry.id == sourceId)
          .firstOrNull;
      if (!ref.mounted) return null;
      if (sourceVersion != _sourceVersion) continue;
      return source?.enabled == true && source?.available == true
          ? source
          : null;
    }
    return null;
  }

  Future<void> _drainReconnectScans() async {
    if (_drainingReconnectScans || !ref.mounted) return;
    _drainingReconnectScans = true;
    try {
      while (ref.mounted && _pendingReconnectScans.isNotEmpty) {
        final active = _scanCompletion;
        if (active != null) await active;
        if (!ref.mounted || _pendingReconnectScans.isEmpty) break;
        final sourceId = _pendingReconnectScans.first;
        await startSourceScan(sourceId, notify: false);
        _pendingReconnectScans.remove(sourceId);
      }
    } catch (error, stack) {
      _log.e('Failed to scan reconnected library source: $error', error, stack);
    } finally {
      _drainingReconnectScans = false;
    }
  }

  Future<void> _refreshSummaryFromStorage({
    DateTime? lastScannedAt,
    int? excludedDownloadedCount,
  }) async {
    final sourceVersion = ++_sourceVersion;
    final sources = await _db.getSources();
    if (!ref.mounted || sourceVersion != _sourceVersion) return;
    state = state.copyWith(sources: sources);
    final summary = await Future.wait<Object>([
      _db.getCount(),
      _db.getLookupIndex(),
    ]);
    final count = summary[0] as int;
    final index = summary[1] as LocalLibraryLookupIndex;
    if (!ref.mounted || sourceVersion != _sourceVersion) return;
    final latestSourceScan = sources
        .map((source) => source.lastScannedAt)
        .whereType<DateTime>()
        .fold<DateTime?>(
          null,
          (latest, value) =>
              latest == null || value.isAfter(latest) ? value : latest,
        );
    state = state.copyWith(
      loadFailed: false,
      totalCount: count,
      loadedIndexVersion: state.loadedIndexVersion + 1,
      lastScannedAt: lastScannedAt ?? latestSourceScan,
      excludedDownloadedCount: excludedDownloadedCount,
      sources: sources,
      trackKeySet: index.matchKeys,
      isrcSet: index.isrcs,
    );
    ref.read(localLibraryIndexRevisionProvider.notifier)._bump();
    _hasLoadedFromDatabase = true;
    _isLoaded = true;
  }

  Future<void> _migrateLegacySource() async {
    final settings = ref.read(settingsProvider);
    final path = settings.localLibraryPath.trim();
    if (path.isEmpty) return;
    if (await _db.getSourceByPath(path) != null) return;
    DateTime? legacyLastScannedAt;
    try {
      legacyLastScannedAt = readLocalLibraryLastScannedAt(await _prefs);
    } catch (_) {}
    _sourceVersion++;
    await _db.migrateLegacySource(
      path: path,
      displayName: _displayNameForPath(path),
      bookmark: settings.localLibraryBookmark.trim().isEmpty
          ? null
          : settings.localLibraryBookmark,
      isRemovable: _looksLikeRemovablePath(path),
      available: await _isPathAvailable(
        path,
        bookmark: settings.localLibraryBookmark,
      ),
      lastScannedAt: legacyLastScannedAt,
    );
  }

  String _displayNameForPath(String path) {
    if (isContentUri(path)) {
      try {
        final decoded = Uri.decodeComponent(Uri.parse(path).pathSegments.last);
        final relative = decoded.contains(':')
            ? decoded.substring(decoded.indexOf(':') + 1)
            : decoded;
        if (relative.trim().isNotEmpty) {
          return relative.split('/').last;
        }
      } catch (_) {}
      return 'Music';
    }
    final normalized = path
        .replaceAll('\\', '/')
        .replaceAll(RegExp(r'/+$'), '');
    final name = normalized.split('/').last;
    return name.isEmpty ? path : name;
  }

  bool _looksLikeRemovablePath(String path) {
    if (isContentUri(path)) {
      try {
        final decoded = Uri.decodeComponent(Uri.parse(path).pathSegments.last);
        return !decoded.startsWith('primary:');
      } catch (_) {
        return false;
      }
    }
    final normalized = path.replaceAll('\\', '/').toLowerCase();
    return normalized.startsWith('/storage/') &&
        !normalized.startsWith('/storage/emulated/');
  }

  Future<bool> _isPathAvailable(String path, {String? bookmark}) async {
    return await _probePathAvailability(path, bookmark: bookmark) ?? true;
  }

  Future<bool?> _probePathAvailability(String path, {String? bookmark}) async {
    // Network outages are transient. Keep the indexed collection visible;
    // opening/scanning a source reports connectivity errors without dropping it.
    if (path.startsWith('network://')) return true;
    try {
      if (_availabilityProbe != null) {
        return await _availabilityProbe(path, bookmark: bookmark);
      }
      if (Platform.isAndroid && isContentUri(path)) {
        return await PlatformBridge.probeSafTreeReadAccess(path);
      }
      if (Platform.isIOS && bookmark != null && bookmark.trim().isNotEmpty) {
        final access = await PlatformBridge.startAccessingIosBookmark(bookmark);
        if (access == null) return false;
        try {
          return await Directory(access.path).exists();
        } finally {
          await PlatformBridge.stopAccessingIosBookmark(access);
        }
      }
      return await Directory(path).exists();
    } catch (error) {
      // A busy provider or a filesystem exception cannot prove detachment.
      _log.w('Library source access probe failed: $error');
      return null;
    }
  }

  Future<({List<String> reconnected, bool changed, int requestVersion})>
  _refreshSourceAvailabilityInDatabase() =>
      _availabilityCheckFuture ??= _checkSourceAvailability().whenComplete(() {
        _availabilityCheckFuture = null;
      });

  Future<({List<String> reconnected, bool changed, int requestVersion})>
  _checkSourceAvailability() async {
    final reconnected = <String>{};
    var changed = false;
    while (ref.mounted) {
      final sourceVersion = _sourceVersion;
      final requestVersion = _availabilityRequestVersion;
      final sources = await _db.getSources();
      var inconclusive = false;
      for (final source in sources) {
        final available = await _probePathAvailability(
          source.path,
          bookmark: source.bookmark,
        );
        if (!ref.mounted ||
            sourceVersion != _sourceVersion ||
            requestVersion != _availabilityRequestVersion) {
          break;
        }
        if (available == null) {
          inconclusive = true;
          _log.w(
            'Library source access inconclusive; retaining status: ${source.id}',
          );
          continue;
        }
        if (available != source.available) {
          await _db.updateSourceState(
            source.id,
            available: available,
            lastSeenAt: available ? DateTime.now() : null,
          );
          changed = true;
          if (available && source.enabled && source.isIndexed) {
            reconnected.add(source.id);
          }
        }
      }
      if (!ref.mounted) break;
      // A folder edit or a newer storage event supersedes pending probe
      // results. Re-read the source snapshot before applying them.
      if (sourceVersion != _sourceVersion ||
          requestVersion != _availabilityRequestVersion) {
        continue;
      }
      _availabilityRetry?.cancel();
      if (inconclusive && _availabilityRetryCount < 3) {
        _availabilityRetryCount++;
        _availabilityRetry = Timer(const Duration(seconds: 2), () {
          unawaited(refreshSourceAvailability(scanReconnected: true));
        });
      } else if (!inconclusive) {
        _availabilityRetryCount = 0;
      }
      return (
        reconnected: reconnected.toList(growable: false),
        changed: changed,
        requestVersion: requestVersion,
      );
    }
    return (
      reconnected: reconnected.toList(growable: false),
      changed: changed,
      requestVersion: _availabilityRequestVersion,
    );
  }
}
