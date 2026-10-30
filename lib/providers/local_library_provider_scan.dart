// ignore_for_file: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
part of 'local_library_provider.dart';

/// Scan execution, progress polling, pause handling and scan notifications.
extension _LocalLibraryScan on LocalLibraryNotifier {
  Future<void> _recoverInterruptedScan() =>
      _scanRecovery ??= _recoverPreviousScan();

  Future<void> _recoverPreviousScan() async {
    try {
      final prefs = await _prefs;
      final sourceId = prefs.getString(localLibraryActiveScanSourceKey);
      if (!ref.mounted || sourceId == null || sourceId.trim().isEmpty) return;
      final startedAfter =
          prefs.getInt(localLibraryActiveScanStartedAtKey) ?? 0;
      final recoveryKey = '$sourceId:$startedAfter';
      if (prefs.getString(localLibraryRecoveredScanKey) == recoveryKey) return;
      var message = _notificationService.libraryScanInterruptedMessage;
      try {
        final exit = await PlatformBridge.getLibraryScanExitInfo(
          startedAfter: startedAfter,
        );
        if (exit != null) {
          _log.e('Android process exit during library scan: $exit');
          final reason = exit['reason'] as String?;
          final description = exit['description'] as String?;
          message = [
            message,
            if (reason != null && reason.isNotEmpty) reason,
            if (description != null && description.isNotEmpty) description,
          ].join('\n');
        }
      } catch (e) {
        _log.w('Android did not provide a scan exit report: $e');
      }
      _log.e('Interrupted library scan for $sourceId: $message');
      await _notificationService.endBackgroundWork(
        NotificationService.libraryScanWorkKind,
      );
      await _cancelScanPausedNotification();
      await _showScanFailedNotification(message);
      // Keep the checkpoint marker so enabled auto-scan can resume it. This
      // recovery also runs when auto-scan is off and never deletes tracks.
      await _db.updateSourceState(sourceId, lastScanError: message);
      await prefs.setString(localLibraryRecoveredScanKey, recoveryKey);
    } catch (e, stack) {
      _log.e('Could not fully recover interrupted library scan: $e', e, stack);
    }
  }

  Future<LibraryScanNDJSONFile> _scanNetworkFolder(
    String source, {
    required String sourceId,
    required bool forceFullScan,
    required Future<void> Function() checkpoint,
    required void Function(int processed, int errors, String name) onProgress,
  }) async {
    final scanner = NetworkLibraryScanner(
      storage: _networkStorage,
      readCachedRows: (paths) => _db.readNetworkScanRows(sourceId, paths),
    );
    _networkScanner = scanner;
    try {
      return await scanner.scan(
        source,
        forceFullScan: forceFullScan,
        checkpoint: checkpoint,
        onProgress: onProgress,
      );
    } finally {
      if (identical(_networkScanner, scanner)) _networkScanner = null;
    }
  }

  Future<({int inserted, int skipped})?> _replaceFromFullScanStream({
    required String sourceId,
    required String folderPath,
    required bool isSaf,
    required bool forceFullScan,
  }) async {
    if (_scanCancelRequested) return null;
    final scanFile = folderPath.startsWith('network://')
        ? await _scanNetworkFolder(
            folderPath,
            sourceId: sourceId,
            forceFullScan: forceFullScan,
            checkpoint: () async {
              while (_scanPauseRequested &&
                  !_scanCancelRequested &&
                  ref.mounted) {
                await Future<void>.delayed(const Duration(milliseconds: 100));
              }
              if (_scanCancelRequested || !ref.mounted) {
                throw StateError('Network library scan cancelled');
              }
            },
            onProgress: (processed, errors, name) {
              if (!ref.mounted) return;
              state = state.copyWith(
                scannedFiles: processed,
                scanErrorCount: errors,
                scanCurrentFile: name,
              );
              if (_shouldShowScanProgressNotification(
                progress: 0,
                totalFiles: 0,
                isComplete: false,
              )) {
                unawaited(
                  _showScanProgressNotification(
                    progress: 0,
                    scannedFiles: processed,
                    totalFiles: 0,
                    currentFile: name,
                  ),
                );
              }
            },
          )
        : isSaf
        ? await PlatformBridge.scanSafTreeToNDJSONFile(
            folderPath,
            forceFullScan: forceFullScan,
            isCancelled: () => _scanCancelRequested,
          )
        : await PlatformBridge.scanLibraryFolderToNDJSONFile(
            folderPath,
            forceFullScan: forceFullScan,
            isCancelled: () => _scanCancelRequested,
          );
    var ingested = false;
    try {
      if (_scanCancelRequested) return null;
      await _endPauseForFinalization();
      state = state.copyWith(
        scanIsFinalizing: true,
        scanProgress: state.scanProgress >= 99 ? state.scanProgress : 99,
        scanCurrentFile: null,
        scannedFiles: scanFile.expectedCount,
        scanErrorCount: scanFile.errorCount,
      );
      final result = await _db.replaceSourceScanFile(
        sourceId,
        scanFile,
        requestId: _nativeLibraryRequestId ?? 'desktop-library-scan',
        isCancelled: () => _scanCancelRequested || !ref.mounted,
      );
      _log.i(
        'Stream-ingested ${result.inserted}/${scanFile.expectedCount} scan rows '
        '(${result.skipped} downloads excluded)',
      );
      ingested = true;
      return result;
    } finally {
      if (ingested || folderPath.startsWith('network://')) {
        await scanFile.delete();
      }
    }
  }

  Future<void> _runScan(
    String folderPath, {
    required bool forceFullScan,
    required String? iosBookmark,
    required String? sourceId,
  }) async {
    var activeSourceId = sourceId;
    IosSecurityScopedAccess? securityAccess;
    try {
      if (activeSourceId == null) {
        final existingSource = await _db.getSourceByPath(folderPath);
        if (!ref.mounted || _scanCancelRequested) return;
        activeSourceId = existingSource?.id;
        if (activeSourceId == null) {
          final source = await addSource(
            path: folderPath,
            displayName: _displayNameForPath(folderPath),
            bookmark: iosBookmark,
            isRemovable: _looksLikeRemovablePath(folderPath),
          );
          activeSourceId = source.id;
        }
      }

      _activeScanSourceId = activeSourceId;
      final available = await _isPathAvailable(
        folderPath,
        bookmark: iosBookmark,
      );
      if (!ref.mounted || _scanCancelRequested) return;
      if (!available) {
        _sourceVersion++;
        await _db.updateSourceState(activeSourceId, available: false);
        await _refreshSummaryFromStorage();
        return;
      }
      if (await _sourceForScan(activeSourceId) == null ||
          !ref.mounted ||
          _scanCancelRequested) {
        return;
      }

      // A pause left behind by an interrupted Dart session would hold the new
      // native scan forever; clear it before the pause control becomes visible.
      await _releaseNativeScanPause();
      try {
        final prefs = await _prefs;
        await prefs.setInt(
          localLibraryActiveScanStartedAtKey,
          DateTime.now().millisecondsSinceEpoch,
        );
        await prefs.setString(localLibraryActiveScanSourceKey, activeSourceId);
        await prefs.remove(localLibraryRecoveredScanKey);
      } catch (e) {
        _log.w('Failed to persist active library scan marker: $e');
      }
      if (!ref.mounted || _scanCancelRequested) return;
      _log.i(
        'Starting library scan: $folderPath (incremental: ${!forceFullScan})',
      );
      state = state.copyWith(
        isScanning: true,
        scanIsFinalizing: false,
        scanIsPaused: false,
        scanProgress: 0,
        scanCurrentFile: null,
        scanTotalFiles: 0,
        scannedFiles: 0,
        scanErrorCount: 0,
        scanWasCancelled: false,
        scanningSourceId: activeSourceId,
      );
      _resetScanNotificationTracking();
      // Hold before the first progress notification so Android shows a single
      // foreground-service notification; released in the final cleanup below.
      await _notificationService.beginLibraryScanWork();
      if (_shouldShowScanProgressNotification(
        progress: 0,
        totalFiles: 0,
        isComplete: false,
      )) {
        await _showScanProgressNotification(
          progress: 0,
          scannedFiles: 0,
          totalFiles: 0,
          currentFile: null,
        );
      }

      try {
        final appSupportDir = await getApplicationSupportDirectory();
        final coverCacheDir = '${appSupportDir.path}/library_covers';
        await PlatformBridge.setLibraryCoverCacheDir(coverCacheDir);
        _log.i('Cover cache directory set to: $coverCacheDir');
      } catch (e) {
        _log.w('Failed to set cover cache directory: $e');
      }
      if (!ref.mounted || _scanCancelRequested) return;

      if (!folderPath.startsWith('network://')) _startProgressPolling();

      String? resolvedPath;
      if (Platform.isIOS && iosBookmark != null && iosBookmark.isNotEmpty) {
        securityAccess = await PlatformBridge.startAccessingIosBookmark(
          iosBookmark,
        );
        resolvedPath = securityAccess?.path;
        if (securityAccess != null) {
          _log.i('Started iOS security-scoped access: $resolvedPath');
        } else {
          _log.w(
            'Failed to start iOS security-scoped access, '
            'falling back to original path',
          );
        }
      }
      if (!ref.mounted || _scanCancelRequested) return;
      final effectiveFolderPath = resolvedPath ?? folderPath;

      final isSaf = isContentUri(effectiveFolderPath);

      final useStreamingFullScan =
          effectiveFolderPath.startsWith('network://') ||
          forceFullScan ||
          await _db.getSourceCount(activeSourceId) == 0;
      if (useStreamingFullScan) {
        if (await _sourceForScan(activeSourceId) == null ||
            !ref.mounted ||
            _scanCancelRequested) {
          return;
        }
        final scanResult = await _replaceFromFullScanStream(
          sourceId: activeSourceId,
          folderPath: effectiveFolderPath,
          isSaf: isSaf,
          forceFullScan: forceFullScan,
        );
        if (!ref.mounted) return;
        if (scanResult == null || _scanCancelRequested) {
          if (scanResult != null) {
            await _refreshSummaryFromStorage(
              excludedDownloadedCount: scanResult.skipped,
            );
          }
          if (!ref.mounted) return;
          state = state.copyWith(
            isScanning: false,
            scanIsFinalizing: false,
            scanWasCancelled: true,
          );
          await _showScanCancelledNotification();
          return;
        }

        state = state.copyWith(
          scanIsFinalizing: true,
          scanProgress: state.scanProgress >= 99 ? state.scanProgress : 99,
          scanCurrentFile: null,
        );

        final skippedDownloads = scanResult.skipped;

        if (skippedDownloads > 0) {
          _log.i('Skipped $skippedDownloads files already in download history');
        }
        if (forceFullScan) {
          // A forced scan rewrites thumbnails under their existing paths.
          PaintingBinding.instance.imageCache
            ..clear()
            ..clearLiveImages();
        }

        await _finishScan(
          sourceId: activeSourceId,
          skippedDownloads: skippedDownloads,
          pruneCoverCache: true,
          nativeScan: !effectiveFolderPath.startsWith('network://'),
          summary: () =>
              'Full scan complete: ${state.totalCount} tracks found, '
              '$skippedDownloads already in downloads, '
              '${state.scanErrorCount} errors',
        );
      } else {
        final nativeIngestion = PlatformBridge.supportsCoreBackend;
        final existingFiles = nativeIngestion
            ? const <String, int>{}
            : await _db.getFileModTimes(sourceId: activeSourceId);
        if (!nativeIngestion) {
          _log.i(
            'Incremental scan: ${existingFiles.length} existing files in database',
          );
          final backfilledModTimes = await _backfillLegacyFileModTimes(
            isSaf: isSaf,
            existingFiles: existingFiles,
          );
          if (backfilledModTimes.isNotEmpty) {
            await _db.updateFileModTimes(backfilledModTimes);
            existingFiles.addAll(backfilledModTimes);
            _log.i('Backfilled ${backfilledModTimes.length} legacy mod times');
          }
        }

        final snapshotPath = nativeIngestion
            ? await _db.writeNativeFileModTimesSnapshot(
                activeSourceId,
                requestId: _nativeLibraryRequestId!,
                isCancelled: () => _scanCancelRequested || !ref.mounted,
              )
            : null;

        Map<String, dynamic> result;
        try {
          if (await _sourceForScan(activeSourceId) == null ||
              _scanCancelRequested ||
              !ref.mounted) {
            return;
          }
          if (nativeIngestion) {
            result = await _db.scanIncrementalNative(
              activeSourceId,
              effectiveFolderPath,
              snapshotPath!,
              isSaf: isSaf,
              requestId: _nativeLibraryRequestId!,
              isCancelled: () => _scanCancelRequested || !ref.mounted,
            );
          } else if (isSaf) {
            result = await PlatformBridge.scanSafTreeIncremental(
              effectiveFolderPath,
              existingFiles,
            );
          } else {
            result = await PlatformBridge.scanLibraryFolderIncremental(
              effectiveFolderPath,
              existingFiles,
            );
          }
        } finally {
          if (snapshotPath != null) {
            try {
              await File(snapshotPath).delete();
            } catch (_) {}
          }
        }

        if (!ref.mounted) return;
        if (_scanCancelRequested || result['cancelled'] == true) {
          if (result['committed'] == true) {
            await _refreshSummaryFromStorage(
              excludedDownloadedCount: (result['skipped'] as num?)?.toInt(),
            );
          }
          if (!ref.mounted) return;
          state = state.copyWith(
            isScanning: false,
            scanIsFinalizing: false,
            scanWasCancelled: true,
          );
          await _showScanCancelledNotification();
          return;
        }

        await _endPauseForFinalization();
        state = state.copyWith(
          scanIsFinalizing: true,
          scanProgress: state.scanProgress >= 99 ? state.scanProgress : 99,
          scanCurrentFile: null,
        );

        final scannedList =
            (result['files'] as List<dynamic>?) ??
            (result['scanned'] as List<dynamic>?) ??
            [];
        final deletedPaths =
            (result['removedUris'] as List<dynamic>?)
                ?.map((e) => e as String)
                .toList() ??
            (result['deletedPaths'] as List<dynamic>?)
                ?.map((e) => e as String)
                .toList() ??
            [];
        final skippedCount = result['skippedCount'] as int? ?? 0;
        final totalFiles = result['totalFiles'] as int? ?? 0;
        final scannedCount = nativeIngestion
            ? (result['scanned_count'] as num).toInt()
            : scannedList.length;
        final deletedCount = nativeIngestion
            ? (result['deleted_count'] as num).toInt()
            : deletedPaths.length;
        if (nativeIngestion && result['committed'] != true) {
          throw StateError('Native Library scan did not commit its index');
        }

        _log.i(
          'Incremental result: $scannedCount scanned, '
          '$skippedCount skipped, $deletedCount deleted, $totalFiles total',
        );

        final removedDownloaded = nativeIngestion
            ? 0
            : await _db.deleteDownloadedRowsForSource(activeSourceId);
        if (removedDownloaded > 0) {
          _log.i(
            'Removed $removedDownloaded downloaded tracks already present in '
            'the local Library index',
          );
        }

        final updatedItems = <LocalLibraryItem>[];
        var skippedDownloads = nativeIngestion
            ? (result['skipped'] as num).toInt()
            : removedDownloaded;
        if (!nativeIngestion && scannedList.isNotEmpty) {
          for (final json in scannedList) {
            final map = json as Map<String, dynamic>;
            final item = LocalLibraryItem.fromJson(map);
            updatedItems.add(item);
          }
          if (updatedItems.isNotEmpty) {
            final upsertResult = await _db.upsertBatchExcludingHistory(
              updatedItems.map((e) => e.toJson()).toList(),
              sourceId: activeSourceId,
            );
            skippedDownloads += upsertResult.skipped;
            _log.i('Upserted ${upsertResult.upserted} items');
          }
          if (skippedDownloads > 0) {
            _log.i(
              'Skipped $skippedDownloads files already in download history',
            );
          }
        }

        if (!nativeIngestion && deletedPaths.isNotEmpty) {
          final deleteCount = await _db.deleteByPaths(deletedPaths);
          _log.i('Deleted $deleteCount items from database');
        }

        await _finishScan(
          sourceId: activeSourceId,
          skippedDownloads: skippedDownloads,
          pruneCoverCache: false,
          nativeScan: true,
          summary: () =>
              'Incremental scan complete: ${state.totalCount} total tracks '
              '($scannedCount new/updated, $skippedCount unchanged, '
              '$deletedCount removed, $skippedDownloads already in downloads, '
              '${state.scanErrorCount} errors)',
        );
      }
    } catch (e, stack) {
      if (!ref.mounted) return;
      if (_scanCancelRequested) {
        _log.i('Library scan cancelled');
        state = state.copyWith(
          isScanning: false,
          scanIsFinalizing: false,
          scanWasCancelled: true,
        );
        await _showScanCancelledNotification();
        return;
      }
      _log.e('Library scan failed: $e', e, stack);
      state = state.copyWith(
        isScanning: false,
        scanIsFinalizing: false,
        scanWasCancelled: false,
        sources: [
          for (final source in state.sources)
            source.id == activeSourceId
                ? source.copyWith(lastScanError: e.toString())
                : source,
        ],
      );
      _stopProgressPolling();
      await _showScanFailedNotification(e.toString());
      if (activeSourceId != null) {
        try {
          await _db.updateSourceState(
            activeSourceId,
            lastScanError: e.toString(),
          );
          await _refreshSummaryFromStorage();
        } catch (saveError, saveStack) {
          _log.e(
            'Could not save library scan failure: $saveError',
            saveError,
            saveStack,
          );
        }
      }
    } finally {
      _stopProgressPolling();
      await _scanNotificationTail;
      await _notificationService.endBackgroundWork(
        NotificationService.libraryScanWorkKind,
      );
      if (securityAccess != null) {
        await PlatformBridge.stopAccessingIosBookmark(securityAccess);
        _log.i('Stopped iOS security-scoped access');
      }
      if (_scanPauseRequested) {
        _scanPauseRequested = false;
        await _releaseNativeScanPause();
      }
      try {
        final prefs = await _prefs;
        if (prefs.getString(localLibraryActiveScanSourceKey) ==
            activeSourceId) {
          await prefs.remove(localLibraryActiveScanSourceKey);
          await prefs.remove(localLibraryActiveScanStartedAtKey);
          await prefs.remove(localLibraryRecoveredScanKey);
        }
      } catch (e) {
        _log.w('Failed to clear active library scan marker: $e');
      }
    }
  }

  /// Shared completion tail of a successful full or incremental scan.
  /// [summary] is evaluated after the final state update so it reads the
  /// refreshed totals. A [nativeScan] reports which files it could not read;
  /// a network scan only counts them.
  Future<void> _finishScan({
    required String sourceId,
    required int skippedDownloads,
    required bool pruneCoverCache,
    required bool nativeScan,
    required String Function() summary,
  }) async {
    final reported = nativeScan ? await _readNativeScanFailures() : null;
    if (!ref.mounted) return;
    final failures =
        reported ??
        LibraryScanFailures(count: state.scanErrorCount, files: const []);
    // Progress polling stops before the last files finish, so the finished
    // report has the final count.
    if (failures.count > state.scanErrorCount) {
      state = state.copyWith(scanErrorCount: failures.count);
    }
    await _setScanFailures(sourceId, failures.count > 0 ? failures : null);
    if (!ref.mounted) return;
    final now = DateTime.now();
    _sourceVersion++;
    await _db.updateSourceState(
      sourceId,
      available: true,
      lastSeenAt: now,
      lastScannedAt: now,
      clearLastScanError: true,
    );
    try {
      final prefs = await SharedPreferences.getInstance();
      await writeLocalLibraryLastScannedAt(prefs, now);
      await prefs.setInt(_excludedDownloadedCountKey, skippedDownloads);
      _log.d('Saved lastScannedAt: $now');
    } catch (e) {
      _log.w('Failed to save lastScannedAt: $e');
    }

    await _refreshSummaryFromStorage(
      lastScannedAt: now,
      excludedDownloadedCount: skippedDownloads,
    );
    if (!ref.mounted) return;
    state = state.copyWith(
      isScanning: false,
      scanIsFinalizing: false,
      scanProgress: 100,
      lastScannedAt: now,
      scanWasCancelled: false,
      excludedDownloadedCount: skippedDownloads,
    );
    if (pruneCoverCache) await _pruneLibraryCoverCache();

    final message = summary();
    if (state.scanErrorCount > 0) {
      _log.e(message);
    } else {
      _log.i(message);
    }
    await _showScanCompleteNotification(
      totalTracks: state.totalCount,
      excludedDownloadedCount: skippedDownloads,
      errorCount: state.scanErrorCount,
    );
  }

  Future<LibraryScanFailures?> _readNativeScanFailures() async {
    try {
      final progress = await PlatformBridge.getLibraryScanProgress();
      if (progress['is_complete'] != true) return null;
      return LibraryScanFailures.fromProgress(progress);
    } catch (e) {
      _log.w('Failed to read library scan failures: $e');
      return null;
    }
  }

  Future<void> _setScanFailures(
    String sourceId,
    LibraryScanFailures? failures,
  ) async {
    final current = state.scanFailures;
    if (failures == null && !current.containsKey(sourceId)) return;
    final next = {...current};
    if (failures == null) {
      next.remove(sourceId);
    } else {
      next[sourceId] = failures;
    }
    state = state.copyWith(scanFailures: next);
    try {
      await writeLocalLibraryScanFailures(await _prefs, next);
    } catch (e) {
      _log.w('Failed to save library scan failures: $e');
    }
  }

  void _startProgressPolling() {
    final useStream = PlatformBridge.supportsCoreBackend;
    _progressPoller.start(useStream: useStream);
    if (useStream) {
      Future<void>.microtask(
        () => _progressPoller.pollOnce(
          (e) => _log.w('Initial library scan progress fetch failed: $e'),
        ),
      );
    }
  }

  Future<void> _handleLibraryScanProgress(Map<String, dynamic> progress) async {
    // A newly subscribed native stream may still contain the previous scan's
    // terminal snapshot (including the initial idle snapshot). Only the scan
    // method's result can start finalization; never stop polling on that replay.
    if (_scanCancelRequested ||
        !state.isScanning ||
        state.scanIsFinalizing ||
        progress['is_complete'] == true) {
      return;
    }
    final nextProgress = (progress['progress_pct'] as num?)?.toDouble() ?? 0;
    final normalizedProgress = ((nextProgress * 10).round() / 10).clamp(
      0.0,
      100.0,
    );
    final displayProgress = normalizedProgress >= 100.0
        ? 99.0
        : normalizedProgress;
    final currentFile = progress['current_file'] as String?;
    final totalFiles = (progress['total_files'] as num?)?.toInt() ?? 0;
    final scannedFiles = (progress['scanned_files'] as num?)?.toInt() ?? 0;
    final errorCount = (progress['error_count'] as num?)?.toInt() ?? 0;

    final shouldUpdateState =
        state.scanProgress != displayProgress ||
        state.scanCurrentFile != currentFile ||
        state.scanTotalFiles != totalFiles ||
        state.scannedFiles != scannedFiles ||
        state.scanErrorCount != errorCount;

    if (shouldUpdateState) {
      state = state.copyWith(
        scanProgress: displayProgress,
        scanCurrentFile: currentFile,
        scanTotalFiles: totalFiles,
        scannedFiles: scannedFiles,
        scanErrorCount: errorCount,
      );
    }

    // Files already in flight still finish after a pause; count them, but
    // keep the paused notice instead of reposting progress.
    if (!state.scanIsPaused &&
        _shouldShowScanProgressNotification(
          progress: normalizedProgress,
          totalFiles: totalFiles,
          isComplete: false,
        )) {
      await _showScanProgressNotification(
        progress: normalizedProgress,
        scannedFiles: scannedFiles,
        totalFiles: totalFiles,
        currentFile: currentFile,
      );
    }
  }

  void _stopProgressPolling() {
    _progressPoller.stop();
    _resetScanNotificationTracking();
  }

  void _resetScanNotificationTracking() {
    _lastScanNotificationPercent = -1;
    _lastScanNotificationTotalFiles = -1;
    _lastScanNotificationAt = DateTime.fromMillisecondsSinceEpoch(0);
  }

  bool _shouldShowScanProgressNotification({
    required double progress,
    required int totalFiles,
    required bool isComplete,
  }) {
    final now = DateTime.now();
    final percent = progress.round().clamp(0, 100);
    final percentChanged = percent != _lastScanNotificationPercent;
    final totalFilesChanged = totalFiles != _lastScanNotificationTotalFiles;
    final heartbeatDue =
        now.difference(_lastScanNotificationAt) >=
        LocalLibraryNotifier._scanNotificationHeartbeat;

    if (!percentChanged && !totalFilesChanged && !isComplete && !heartbeatDue) {
      return false;
    }

    _lastScanNotificationPercent = percent;
    _lastScanNotificationTotalFiles = totalFiles;
    _lastScanNotificationAt = now;
    return true;
  }

  bool get _isScanningNetwork => state.sources.any(
    (source) =>
        source.id == state.scanningSourceId &&
        source.path.startsWith('network://'),
  );

  Future<void> _releaseNativeScanPause() async {
    try {
      await PlatformBridge.resumeLibraryScan();
    } catch (e) {
      _log.w('Failed to release library scan pause: $e');
    }
  }

  /// The native scan can finish while paused when the pause lands after its
  /// last file. Ingestion then runs normally, so restore background work.
  Future<void> _endPauseForFinalization() async {
    if (!_scanPauseRequested) return;
    _scanPauseRequested = false;
    state = state.copyWith(scanIsPaused: false);
    await _notificationService.beginLibraryScanWork();
    await _cancelScanPausedNotification();
    await _releaseNativeScanPause();
  }

  Future<void> _showScanPausedNotification(int scannedFiles) async {
    try {
      await _queueScanNotification(
        () => _notificationService.showLibraryScanPaused(
          scannedFiles: scannedFiles,
        ),
      );
    } catch (e) {
      _log.w('Failed to show scan paused notification: $e');
    }
  }

  Future<void> _cancelScanPausedNotification() async {
    try {
      await _queueScanNotification(
        _notificationService.cancelLibraryScanNotification,
      );
    } catch (e) {
      _log.w('Failed to clear scan paused notification: $e');
    }
  }

  Future<void> _showScanProgressNotification({
    required double progress,
    required int scannedFiles,
    required int totalFiles,
    required String? currentFile,
  }) async {
    try {
      await _queueScanNotification(() async {
        if (!ref.mounted || !state.isScanning || state.scanIsPaused) return;
        await _notificationService.showLibraryScanProgress(
          progress: progress,
          scannedFiles: scannedFiles,
          totalFiles: totalFiles,
          currentFile: _shortenFileForNotification(currentFile),
        );
      });
    } catch (e) {
      _log.w('Failed to show scan progress notification: $e');
    }
  }

  Future<void> _showScanCompleteNotification({
    required int totalTracks,
    required int excludedDownloadedCount,
    required int errorCount,
  }) async {
    try {
      await _queueScanNotification(
        () => _notificationService.showLibraryScanComplete(
          totalTracks: totalTracks,
          excludedDownloadedCount: excludedDownloadedCount,
          errorCount: errorCount,
        ),
      );
    } catch (e) {
      _log.w('Failed to show scan complete notification: $e');
    }
  }

  Future<void> _showScanFailedNotification(String message) async {
    try {
      await _queueScanNotification(
        () => _notificationService.showLibraryScanFailed(message),
      );
    } catch (e) {
      _log.w('Failed to show scan failure notification: $e');
    }
  }

  Future<void> _showScanCancelledNotification() async {
    try {
      await _queueScanNotification(
        _notificationService.showLibraryScanCancelled,
      );
    } catch (e) {
      _log.w('Failed to show scan cancelled notification: $e');
    }
  }

  Future<void> _queueScanNotification(Future<void> Function() notify) {
    final next = _scanNotificationTail.then((_) => notify());
    // A failed notification must not prevent the terminal notice or cleanup.
    _scanNotificationTail = next.catchError((Object _) {});
    return next;
  }

  String? _shortenFileForNotification(String? path) {
    final raw = path?.trim() ?? '';
    if (raw.isEmpty) return null;

    var decoded = raw;
    try {
      decoded = Uri.decodeFull(raw);
    } catch (_) {}

    final slashIdx = decoded.lastIndexOf('/');
    final backslashIdx = decoded.lastIndexOf('\\');
    final cut = slashIdx > backslashIdx ? slashIdx : backslashIdx;
    if (cut >= 0 && cut < decoded.length - 1) {
      return decoded.substring(cut + 1);
    }
    return decoded;
  }

  Future<void> _pruneLibraryCoverCache() async {
    try {
      final appSupportDir = await getApplicationSupportDirectory();
      final libraryCoverDir = Directory('${appSupportDir.path}/library_covers');
      if (!await libraryCoverDir.exists()) {
        return;
      }

      if (!ref.mounted || _scanCancelRequested) return;
      final libraryDatabase = await _db.database;
      if (!ref.mounted || _scanCancelRequested) return;

      final deletedCount = await pruneUnreferencedLibraryCovers(
        libraryCoverDir,
        const {},
        libraryDatabase: libraryDatabase,
        requestId: _nativeLibraryRequestId,
        canPrune: () => ref.mounted && !_scanCancelRequested,
        // Avoid removing covers being written by a background producer before
        // its Library transaction publishes the reference. The scan guard is
        // still held here; the source sqflite transaction holds the writer
        // barrier while Rust reads its detached, private cover projection.
        minimumAge: const Duration(minutes: 1),
      );

      if (deletedCount > 0) {
        _log.i('Pruned $deletedCount stale library cover cache files');
      }
    } catch (e) {
      _log.w('Failed pruning library cover cache: $e');
    }
  }

  Future<Map<String, int>> _backfillLegacyFileModTimes({
    required bool isSaf,
    required Map<String, int> existingFiles,
  }) async {
    final legacyPaths = existingFiles.entries
        // Negative timestamps deliberately force a metadata-version rescan;
        // only a missing timestamp (zero) may be filled from the filesystem.
        .where((entry) => entry.value == 0)
        .map((entry) => entry.key)
        .toList();
    if (legacyPaths.isEmpty) {
      return const {};
    }

    if (isSaf) {
      final uris = legacyPaths.where((path) => isContentUri(path)).toList();
      if (uris.isEmpty) {
        return const {};
      }
      const chunkSize = 500;
      final backfilled = <String, int>{};
      try {
        for (var i = 0; i < uris.length; i += chunkSize) {
          if (_scanCancelRequested) {
            break;
          }
          final end = (i + chunkSize < uris.length)
              ? i + chunkSize
              : uris.length;
          final chunk = uris.sublist(i, end);
          final chunkResult = await PlatformBridge.getSafFileModTimes(chunk);
          backfilled.addAll(chunkResult);
        }
        return backfilled;
      } catch (e) {
        _log.w('Failed to backfill SAF mod times: $e');
        return const {};
      }
    }

    final paths = legacyPaths
        .where((path) => !isContentUri(path))
        .toList(growable: false);
    const chunkSize = 24;
    final backfilled = <String, int>{};

    for (var i = 0; i < paths.length; i += chunkSize) {
      if (_scanCancelRequested) {
        break;
      }
      final end = (i + chunkSize < paths.length) ? i + chunkSize : paths.length;
      final chunk = paths.sublist(i, end);
      final chunkEntries = await Future.wait<MapEntry<String, int>?>(
        chunk.map((path) async {
          try {
            final stat = await File(path).stat();
            if (stat.type == FileSystemEntityType.file) {
              return MapEntry(path, stat.modified.millisecondsSinceEpoch);
            }
          } catch (_) {}
          return null;
        }),
      );
      for (final entry in chunkEntries) {
        if (entry != null) {
          backfilled[entry.key] = entry.value;
        }
      }
    }
    return backfilled;
  }
}
