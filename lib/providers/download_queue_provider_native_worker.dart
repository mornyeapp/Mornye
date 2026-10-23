// ignore_for_file: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
part of 'download_queue_provider.dart';

class _NativeWorkerRequestContext {
  final DownloadItem item;
  final String requestJson;
  final String outputDir;
  final String quality;
  final String storageMode;
  final String outputExt;
  final String? downloadTreeUri;
  final String? safRelativeDir;
  final String? safFileName;
  final bool qualityVariantCollisionOnly;

  const _NativeWorkerRequestContext({
    required this.item,
    required this.requestJson,
    required this.outputDir,
    required this.quality,
    required this.storageMode,
    required this.outputExt,
    this.downloadTreeUri,
    this.safRelativeDir,
    this.safFileName,
    this.qualityVariantCollisionOnly = false,
  });

  _NativeWorkerRequestContext withResolvedFolder(Map<String, dynamic> result) {
    final directory = result['saf_relative_dir'];
    if (storageMode != 'saf' || directory is! String) return this;
    return _NativeWorkerRequestContext(
      item: item,
      requestJson: requestJson,
      outputDir: directory,
      quality: quality,
      storageMode: storageMode,
      outputExt: outputExt,
      downloadTreeUri: downloadTreeUri,
      safRelativeDir: directory,
      safFileName: safFileName,
      qualityVariantCollisionOnly: qualityVariantCollisionOnly,
    );
  }
}

extension _DownloadQueueNativeWorker on DownloadQueueNotifier {
  Future<bool> _recoverNativeWorkerStorageFailure({
    required _NativeWorkerRequestContext context,
    required String errorType,
    required String errorMessage,
    required Map<String, _NativeWorkerRequestContext> contexts,
    required Set<String> reconciledIds,
  }) async {
    if (!isStorageWriteFailure(
      errorType: errorType,
      errorMessage: errorMessage,
    )) {
      return false;
    }

    if (storageWriteRecoveryFor(useSaf: context.storageMode == 'saf') ==
        StorageWriteRecovery.requestSafAccess) {
      _log.w(
        'Native worker lost SAF access; cancelling the run without changing the selected destination',
      );
      try {
        await PlatformBridge.cancelNativeDownloadWorker();
      } catch (e) {
        _log.w('Failed to cancel native worker after SAF access loss: $e');
      }
      for (final pendingId in contexts.keys) {
        if (reconciledIds.contains(pendingId)) continue;
        final pending = _findItemById(pendingId);
        if (pending == null ||
            pending.status == DownloadStatus.completed ||
            pending.status == DownloadStatus.skipped) {
          continue;
        }
        reconciledIds.add(pendingId);
        _recordFailedDownload(
          pendingId,
          error: safPermissionLostErrorMessage,
          errorType: DownloadErrorType.permission,
        );
      }
      return true;
    }

    final fallbackRoot = await _activateAppFolderStorageFallback(
      failedOutputDir: context.outputDir,
    );
    if (_pathIsInside(context.outputDir, fallbackRoot)) {
      // This request already used the verified fallback. Do not create an
      // infinite retry loop if the failure has another device-specific cause.
      return false;
    }

    _log.w(
      'Native worker could not write its destination; cancelling this run '
      'and retrying pending items in $fallbackRoot',
    );
    try {
      await PlatformBridge.cancelNativeDownloadWorker();
    } catch (e) {
      _log.w('Failed to cancel native worker for storage fallback: $e');
    }

    for (final pendingId in contexts.keys) {
      if (reconciledIds.contains(pendingId)) continue;
      final pending = _findItemById(pendingId);
      if (pending == null ||
          pending.status == DownloadStatus.completed ||
          pending.status == DownloadStatus.skipped) {
        continue;
      }
      reconciledIds.add(pendingId);
      updateItemStatus(pendingId, DownloadStatus.queued, progress: 0.0);
    }
    return true;
  }

  Future<void> _persistNativeFinalizedHistoryFallback(
    _NativeWorkerRequestContext context,
    Map<String, dynamic> result,
    String filePath,
  ) async {
    final format =
        normalizeAudioFormatValue(
          result['audio_codec']?.toString() ?? result['format']?.toString(),
        ) ??
        normalizeAudioFormatValue(audioFormatForPath(filePath));
    final isLossy = isLossyAudioFormat(format);
    final bitDepth = isLossy
        ? null
        : readPositiveInt(result['actual_bit_depth'] ?? result['bit_depth']);
    final sampleRate = isLossy
        ? null
        : readPositiveInt(
            result['actual_sample_rate'] ?? result['sample_rate'],
          );
    final bitrate = readPositiveBitrateKbps(
      result['actual_bitrate'] ?? result['bitrate'],
    );
    final storedQuality =
        result['quality']?.toString().trim().isNotEmpty == true
        ? result['quality'].toString()
        : context.quality;
    final quality =
        resolveDisplayQuality(
          filePath: filePath,
          fileName: result['file_name']?.toString(),
          detectedFormat: format,
          bitDepth: bitDepth,
          sampleRate: sampleRate,
          bitrateKbps: bitrate,
          storedQuality: storedQuality,
        ) ??
        storedQuality;
    final useSaf = context.storageMode == 'saf';
    final resultFileName = result['file_name']?.toString().trim();
    final lyricsAvailability = await _resolveFinalLyricsAvailability(
      filePath: filePath,
    );

    await ref
        .read(downloadHistoryProvider.notifier)
        .addToHistory(
          _historyItemFromResult(
            item: context.item,
            trackToDownload: context.item.track,
            result: result,
            filePath: filePath,
            quality: quality,
            useSaf: useSaf,
            downloadTreeUri: context.downloadTreeUri,
            safRelativeDir: context.safRelativeDir,
            safFileName: resultFileName?.isNotEmpty == true
                ? resultFileName
                : context.safFileName,
            bitDepth: bitDepth,
            sampleRate: sampleRate,
            bitrate: bitrate,
            format: format,
            genre: normalizeOptionalString(result['genre']?.toString()),
            label: normalizeOptionalString(result['label']?.toString()),
            copyright: normalizeOptionalString(result['copyright']?.toString()),
            hasLyrics: lyricsAvailability.hasLyrics,
            lyricsMetadataScanVersion: lyricsAvailability.scanVersion,
            hasReplayGain: lyricsAvailability.hasReplayGain,
            replayGainMetadataScanVersion:
                lyricsAvailability.replayGainScanVersion,
          ),
          preserveTrackVariant: context.item.preserveQualityVariant,
        );
  }

  bool _canUseAndroidNativeWorker(AppSettings settings) {
    // Network publication runs in the shared queue after native tag processing.
    // Do not let the worker publish a local history row or completion early.
    if (state.items.any((item) => item.networkDownloadFolder.isNotEmpty)) {
      return false;
    }
    if (!Platform.isAndroid || !settings.nativeDownloadWorkerEnabled) {
      return false;
    }
    if (!settings.useExtensionProviders) {
      return false;
    }
    if (_isSafMode(settings)) {
      if (settings.downloadTreeUri.isEmpty) {
        return false;
      }
    }
    final extensionState = ref.read(extensionProvider);
    final hasEnabledDownloadProvider = extensionState.extensions.any(
      (extension) => extension.enabled && extension.hasDownloadProvider,
    );
    if (!hasEnabledDownloadProvider) {
      return false;
    }
    return true;
  }

  String _newNativeWorkerRunId() =>
      'native-${DateTime.now().microsecondsSinceEpoch}-${Random().nextInt(1 << 32)}';

  String _snapshotRunId(Map<String, dynamic> snapshot) {
    final direct = snapshot['run_id']?.toString() ?? '';
    if (direct.isNotEmpty) return direct;

    final settingsJson = snapshot['settings_json'];
    if (settingsJson is String && settingsJson.isNotEmpty) {
      try {
        final decoded = jsonDecode(settingsJson);
        if (decoded is Map) {
          return decoded['run_id']?.toString() ?? '';
        }
      } catch (_) {}
    } else if (settingsJson is Map) {
      return settingsJson['run_id']?.toString() ?? '';
    }
    return '';
  }

  bool _isNativeWorkerSnapshotContractCompatible(
    Map<String, dynamic> snapshot,
  ) {
    final version = snapshot['contract_version'];
    return version == DownloadRequestPayload.nativeWorkerContractVersion;
  }

  /// Serial of the last fully-processed state snapshot, echoed back to the
  /// native side so steady-state polls skip the per-item payload. Falls back
  /// to the previous value for snapshots without the field.
  int _snapshotStateSerial(Map<String, dynamic> snapshot, int previous) {
    final serial = snapshot['state_serial'];
    if (serial is num && serial > 0) {
      return serial.toInt();
    }
    return previous;
  }

  bool _isNativeWorkerSnapshotForRun(
    Map<String, dynamic> snapshot,
    String runId,
  ) =>
      runId.isNotEmpty &&
      _snapshotRunId(snapshot) == runId &&
      _isNativeWorkerSnapshotContractCompatible(snapshot);

  Future<void> _persistNativeWorkerRunId(String runId) async {
    _activeNativeWorkerRunId = runId;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      DownloadQueueNotifier._nativeWorkerRunIdPrefsKey,
      runId,
    );
  }

  Future<String?> _loadNativeWorkerRunId() async {
    if (_activeNativeWorkerRunId != null) return _activeNativeWorkerRunId;
    final prefs = await SharedPreferences.getInstance();
    final runId = prefs.getString(
      DownloadQueueNotifier._nativeWorkerRunIdPrefsKey,
    );
    if (runId != null && runId.isNotEmpty) {
      _activeNativeWorkerRunId = runId;
      return runId;
    }
    return null;
  }

  Future<void> _clearNativeWorkerRunId(String runId) async {
    if (_activeNativeWorkerRunId == runId) {
      _activeNativeWorkerRunId = null;
    }
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getString(DownloadQueueNotifier._nativeWorkerRunIdPrefsKey) ==
        runId) {
      await prefs.remove(DownloadQueueNotifier._nativeWorkerRunIdPrefsKey);
    }
  }

  Future<bool> _tryAdoptAndroidNativeWorkerSnapshot(
    List<DownloadItem> restoredItems,
  ) async {
    final settings = ref.read(settingsProvider);
    // Adoption deliberately skips _canUseAndroidNativeWorker: that gate reads
    // extension state that loads asynchronously after startup, and toggles the
    // user may have flipped mid-run. If a native batch is already running we
    // must reconcile with it regardless, or the Dart queue would download the
    // same items a second time alongside it.
    if (!Platform.isAndroid) {
      return false;
    }

    Map<String, dynamic> snapshot;
    try {
      snapshot = await PlatformBridge.getNativeDownloadWorkerSnapshot();
    } catch (_) {
      return false;
    }
    final runId = await _loadNativeWorkerRunId();
    if (runId == null ||
        runId.isEmpty ||
        !_isNativeWorkerSnapshotForRun(snapshot, runId)) {
      return false;
    }

    final rawItems = snapshot['items'];
    final rawItemIds = snapshot['item_ids'];
    final snapshotIds = rawItems is List
        ? rawItems
              .whereType<Map<Object?, Object?>>()
              .map((item) => item['item_id']?.toString() ?? '')
              .where((id) => id.isNotEmpty)
              .toSet()
        : rawItemIds is List
        ? rawItemIds
              .map((id) => id?.toString() ?? '')
              .where((id) => id.isNotEmpty)
              .toSet()
        : <String>{};
    if (snapshotIds.isEmpty) {
      return false;
    }
    if (!restoredItems.any((item) => snapshotIds.contains(item.id))) {
      return false;
    }

    final contexts = <String, _NativeWorkerRequestContext>{};
    final pendingContextIds = <String>{};
    for (final item in restoredItems) {
      if (!snapshotIds.contains(item.id)) continue;
      final context = await _buildAndroidNativeWorkerRequest(item, settings);
      if (context != null) {
        contexts[item.id] = context;
      } else {
        // Extensions may still be loading this early in startup; remember the
        // item and retry building its context on later reconcile polls.
        pendingContextIds.add(item.id);
      }
    }

    final snapshotClaimsRunning = snapshot['is_running'] == true;
    if (snapshotClaimsRunning && !await _isNativeWorkerServiceAlive()) {
      // The service died mid-batch (process kill/reboot): the snapshot is
      // frozen at is_running=true and nothing will ever update it. Reconcile
      // what the worker managed to finish, requeue the rest, and let the
      // caller fall back to the Dart queue.
      _log.w(
        'Native worker snapshot claims running but the service is dead; reclaiming run $runId',
      );
      if (contexts.isNotEmpty) {
        await _applyAndroidNativeWorkerSnapshot(
          snapshot,
          contexts,
          <String>{},
          settings,
        );
      }
      _requeueInFlightNativeWorkerItems(snapshotIds);
      await _clearNativeWorkerRunId(runId);
      return false;
    }
    if (contexts.isEmpty && pendingContextIds.isEmpty) {
      return false;
    }

    _log.i('Adopting Android native worker snapshot');
    final reconciledIds = <String>{};
    _totalQueuedAtStart = contexts.length + pendingContextIds.length;
    _completedInSession = 0;
    _failedInSession = 0;
    state = state.copyWith(
      isProcessing: snapshot['is_running'] == true,
      isPaused: snapshot['is_paused'] == true,
    );
    await _applyAndroidNativeWorkerSnapshot(
      snapshot,
      contexts,
      reconciledIds,
      settings,
    );

    if (snapshot['is_running'] == true) {
      unawaited(
        _continueAndroidNativeWorkerAdoption(
          contexts,
          pendingContextIds,
          reconciledIds,
          settings,
          runId,
        ),
      );
    } else if (state.items.any(
      (item) => item.status == DownloadStatus.queued,
    )) {
      await _clearNativeWorkerRunId(runId);
      Future.microtask(() => _processQueue());
    } else {
      await _clearNativeWorkerRunId(runId);
    }

    return true;
  }

  Future<bool> _isNativeWorkerServiceAlive() async {
    try {
      return await PlatformBridge.isDownloadServiceRunning();
    } catch (_) {
      return false;
    }
  }

  /// Puts items the dead native worker left mid-flight back into the queue so
  /// the Dart queue can pick them up.
  void _requeueInFlightNativeWorkerItems(Set<String> itemIds) {
    for (final id in itemIds) {
      final current = _findItemById(id);
      if (current == null) continue;
      if (current.status == DownloadStatus.downloading ||
          current.status == DownloadStatus.finalizing) {
        updateItemStatus(id, DownloadStatus.queued, progress: 0.0);
      }
    }
  }

  Future<void> _rebuildPendingNativeWorkerContexts(
    Map<String, _NativeWorkerRequestContext> contexts,
    Set<String> pendingContextIds,
    AppSettings settings,
  ) async {
    if (pendingContextIds.isEmpty) return;
    final resolved = <String>{};
    for (final id in pendingContextIds) {
      final item = _findItemById(id);
      if (item == null) {
        resolved.add(id);
        continue;
      }
      final context = await _buildAndroidNativeWorkerRequest(item, settings);
      if (context != null) {
        contexts[id] = context;
        resolved.add(id);
      }
    }
    pendingContextIds.removeAll(resolved);
  }

  Future<void> _continueAndroidNativeWorkerAdoption(
    Map<String, _NativeWorkerRequestContext> contexts,
    Set<String> pendingContextIds,
    Set<String> reconciledIds,
    AppSettings settings,
    String runId,
  ) async {
    var deadServicePolls = 0;
    var lastStateSerial = 0;
    try {
      while (true) {
        final snapshot = await PlatformBridge.getNativeDownloadWorkerSnapshot(
          sinceStateSerial: lastStateSerial,
        );
        final matchesRun = _isNativeWorkerSnapshotForRun(snapshot, runId);
        if (!matchesRun || snapshot['is_running'] == true) {
          if (await _isNativeWorkerServiceAlive()) {
            deadServicePolls = 0;
          } else {
            deadServicePolls++;
            if (deadServicePolls >= 3) {
              _log.w(
                'Native worker run $runId died without a final snapshot; reclaiming queue',
              );
              if (matchesRun) {
                await _applyAndroidNativeWorkerSnapshot(
                  snapshot,
                  contexts,
                  reconciledIds,
                  settings,
                );
              }
              _requeueInFlightNativeWorkerItems({
                ...contexts.keys,
                ...pendingContextIds,
              });
              await _clearNativeWorkerRunId(runId);
              if (state.items.any(
                (item) => item.status == DownloadStatus.queued,
              )) {
                Future.microtask(() => _processQueue());
              }
              return;
            }
          }
        }
        if (!matchesRun) {
          lastStateSerial = 0;
          await Future<void>.delayed(const Duration(seconds: 1));
          continue;
        }
        state = state.copyWith(isPaused: snapshot['is_paused'] == true);
        await _rebuildPendingNativeWorkerContexts(
          contexts,
          pendingContextIds,
          settings,
        );
        await _applyAndroidNativeWorkerSnapshot(
          snapshot,
          contexts,
          reconciledIds,
          settings,
        );
        lastStateSerial = _snapshotStateSerial(snapshot, lastStateSerial);
        if (snapshot['is_running'] != true) {
          await _clearNativeWorkerRunId(runId);
          // Items may have been requeued during reconciliation (e.g. batch
          // mates of a verification challenge); hand them to the queue.
          if (!state.isPaused &&
              state.items.any((item) => item.status == DownloadStatus.queued)) {
            Future.microtask(() => _processQueue());
          }
          break;
        }
        await Future<void>.delayed(const Duration(seconds: 1));
      }
    } catch (e) {
      _log.w('Android native worker adoption stopped: $e');
    } finally {
      state = state.copyWith(isProcessing: false, currentDownload: null);
    }
  }

  Future<bool> _tryProcessQueueWithAndroidNativeWorker(
    AppSettings settings,
  ) async {
    if (!_canUseAndroidNativeWorker(settings)) {
      return false;
    }

    final queuedItems = state.items
        .where((item) => item.status == DownloadStatus.queued)
        .toList(growable: false);
    if (queuedItems.isEmpty) {
      return false;
    }

    _log.i(
      'Starting Android native download worker for ${queuedItems.length} items',
    );

    final isSafMode = _isSafMode(settings);
    if (!isSafMode && state.outputDir.isEmpty) {
      await _initOutputDir();
    }
    if (!isSafMode && state.outputDir.isEmpty) {
      final musicDir = await _ensureDefaultDocumentsOutputDir();
      state = state.copyWith(outputDir: musicDir.path);
    }

    final contexts = <String, _NativeWorkerRequestContext>{};
    Map<String, dynamic> encodeRequest(
      DownloadItem item,
      _NativeWorkerRequestContext context,
    ) {
      return {
        'contract_version': DownloadRequestPayload.nativeWorkerContractVersion,
        'item_id': item.id,
        'track_name': item.track.name,
        'artist_name': item.track.artistName,
        'item_json': jsonEncode(item.toJson()),
        'request_json': context.requestJson,
      };
    }

    // Only the first request blocks startup. The rest are prepared with a
    // small metadata pipeline and appended to the already-running native
    // worker, reducing time-to-first-byte for large albums/playlists.
    final firstItem = queuedItems.first;
    final firstContext = await _buildAndroidNativeWorkerRequest(
      firstItem,
      settings,
    );
    if (firstContext == null) {
      _log.w(
        'Native worker gate rejected ${firstItem.track.name}; falling back to Dart queue',
      );
      return false;
    }
    contexts[firstItem.id] = firstContext;

    if (!canStartForegroundDownloadForLifecycle(
      WidgetsBinding.instance.lifecycleState,
    )) {
      _log.i(
        'Native worker preparation finished after the app entered the background; deferring start',
      );
      _stopConnectivityMonitoring();
      return true;
    }

    state = state.copyWith(isProcessing: true, isPaused: false);
    _totalQueuedAtStart = queuedItems.length;
    _completedInSession = 0;
    _failedInSession = 0;

    final runId = _newNativeWorkerRunId();
    await _persistNativeWorkerRunId(runId);
    final reconciledIds = <String>{};
    Future<void>? preparationFuture;
    var preparationStopRequested = false;
    try {
      await PlatformBridge.startNativeDownloadWorker(
        requests: [encodeRequest(firstItem, firstContext)],
        settings: {
          'worker': 'android_native',
          'version': 1,
          'contract_version':
              DownloadRequestPayload.nativeWorkerContractVersion,
          'run_id': runId,
          'created_at': DateTime.now().toIso8601String(),
          'save_download_history': settings.saveDownloadHistory,
          'download_network_mode': settings.downloadNetworkMode,
          'concurrent_downloads': settings.concurrentDownloads.clamp(1, 3),
          'finalizer_concurrency': 1,
          'preparation_streaming': true,
          'expected_total_items': queuedItems.length,
        },
      );

      preparationFuture = () async {
        var nextIndex = 1;
        try {
          while (nextIndex < queuedItems.length && !preparationStopRequested) {
            while (contexts.length >=
                    DownloadQueueNotifier._nativePreparationWindowSize &&
                !preparationStopRequested) {
              await Future<void>.delayed(const Duration(milliseconds: 250));
            }
            if (preparationStopRequested) break;

            final capacity =
                DownloadQueueNotifier._nativePreparationWindowSize -
                contexts.length;
            final batchLength = min(
              DownloadQueueNotifier._nativePreparationBatchSize,
              min(capacity, queuedItems.length - nextIndex),
            );
            if (batchLength <= 0) continue;

            final batchItems = queuedItems.sublist(
              nextIndex,
              nextIndex + batchLength,
            );
            nextIndex += batchLength;
            final prepared = List<_NativeWorkerRequestContext?>.filled(
              batchItems.length,
              null,
            );
            var preparationIndex = 0;
            final preparationConcurrency = min(2, batchItems.length);
            await Future.wait(
              List.generate(preparationConcurrency, (_) async {
                while (true) {
                  final index = preparationIndex++;
                  if (index >= batchItems.length) return;
                  final item = batchItems[index];
                  try {
                    prepared[index] = await _buildAndroidNativeWorkerRequest(
                      item,
                      settings,
                    );
                  } catch (e, stack) {
                    _log.e(
                      'Could not prepare native request for ${item.track.name}: $e',
                      e,
                      stack,
                    );
                  }
                }
              }),
            );

            final appendRequests = <Map<String, dynamic>>[];
            final appendedIds = <String>[];
            for (var index = 0; index < batchItems.length; index++) {
              final item = batchItems[index];
              final context = prepared[index];
              if (context == null) {
                _log.w(
                  'Native worker gate rejected ${item.track.name}; leaving it queued for the Dart worker',
                );
                continue;
              }
              contexts[item.id] = context;
              appendedIds.add(item.id);
              appendRequests.add(encodeRequest(item, context));
            }
            if (appendRequests.isEmpty) continue;

            try {
              await PlatformBridge.appendNativeDownloadWorkerRequests(
                runId: runId,
                requests: appendRequests,
              );
            } catch (e, stack) {
              for (final id in appendedIds) {
                contexts.remove(id);
              }
              _log.e(
                'Could not append ${appendRequests.length} prepared native requests: $e',
                e,
                stack,
              );
            }
          }
        } finally {
          try {
            await PlatformBridge.finishNativeDownloadWorkerPreparation(
              runId: runId,
            );
          } catch (_) {
            // Do not leave the foreground worker waiting forever on an open
            // preparation channel if the final hand-off fails.
            await PlatformBridge.cancelNativeDownloadWorker();
            rethrow;
          }
        }
      }();

      final exit =
          await NativeDownloadWorkerMonitor(
            readSnapshot: PlatformBridge.getNativeDownloadWorkerSnapshot,
            matchesRun: (snapshot) =>
                _isNativeWorkerSnapshotForRun(snapshot, runId),
            isServiceAlive: _isNativeWorkerServiceAlive,
          ).run(
            onSnapshot: (snapshot) async {
              if (snapshot['is_running'] != true) {
                preparationStopRequested = true;
              }
              await _applyAndroidNativeWorkerSnapshot(
                snapshot,
                contexts,
                reconciledIds,
                settings,
              );
            },
          );
      preparationStopRequested = true;
      if (exit == NativeDownloadWorkerExit.serviceLost) {
        _log.w('Native worker run $runId lost its service; reclaiming queue');
        _requeueInFlightNativeWorkerItems(contexts.keys.toSet());
      }
      await _clearNativeWorkerRunId(runId);
    } catch (e, stack) {
      preparationStopRequested = true;
      if (isForegroundServiceStartNotAllowed(e)) {
        _log.w(
          'Android rejected the native worker start while backgrounded; keeping the queue pending',
        );
        await _clearNativeWorkerRunId(runId);
        state = state.copyWith(isProcessing: false, currentDownload: null);
        return true;
      }
      if (e is NativeDownloadWorkerStartupTimeout) {
        _log.w(
          'Android native worker did not publish a matching snapshot; cancelling native worker and falling back to Dart queue',
        );
        try {
          await PlatformBridge.cancelNativeDownloadWorker();
        } catch (cancelError) {
          _log.w('Failed to cancel timed-out native worker: $cancelError');
        }
        await _clearNativeWorkerRunId(runId);
        state = state.copyWith(isProcessing: false, currentDownload: null);
        await Future<void>.delayed(const Duration(milliseconds: 500));
        return false;
      }
      _log.e('Android native worker failed: $e', e, stack);
      // The native worker keeps downloading on its own; without cancelling
      // it here the batch we just marked failed would continue in the
      // background, its completions never reconciled, and the Dart queue
      // could even restart alongside it.
      try {
        await PlatformBridge.cancelNativeDownloadWorker();
      } catch (cancelError) {
        _log.w('Failed to cancel native worker after error: $cancelError');
      }
      await _clearNativeWorkerRunId(runId);
      for (final item in queuedItems) {
        final current = _findItemById(item.id);
        if (current == null ||
            current.status == DownloadStatus.completed ||
            current.status == DownloadStatus.failed ||
            current.status == DownloadStatus.skipped) {
          continue;
        }
        _recordFailedDownload(
          item.id,
          error: 'Native download worker failed: $e',
          errorType: DownloadErrorType.unknown,
        );
      }
    } finally {
      preparationStopRequested = true;
      if (preparationFuture != null) {
        try {
          await preparationFuture;
        } catch (e) {
          _log.w('Native worker preparation pipeline stopped: $e');
        }
      }
      state = state.copyWith(isProcessing: false, currentDownload: null);
      _stopConnectivityMonitoring();
      try {
        await PlatformBridge.cleanupConnections();
      } catch (e) {
        _log.e('Native worker cleanup failed: $e');
      }
    }

    final hasQueuedItems = state.items.any(
      (item) => item.status == DownloadStatus.queued,
    );
    if (hasQueuedItems && !state.isPaused) {
      _log.i(
        'Found queued items after Android native worker finished, restarting queue...',
      );
      Future.microtask(() => _processQueue());
    }

    return true;
  }

  Future<_NativeWorkerRequestContext?> _buildAndroidNativeWorkerRequest(
    DownloadItem item,
    AppSettings settings,
  ) async {
    if (!_hasActiveDownloadProvider(item.service)) {
      return null;
    }

    var quality = item.qualityOverride ?? state.audioQuality;
    if (quality == 'DEFAULT') quality = state.audioQuality;

    // The fake Hi-Res check and its LOSSLESS re-download live in the Dart
    // run (_DownloadRun._replaceFakeHiResIfNeeded); the native finalizer has
    // no equivalent, so these items stay on the Dart queue.
    if (settings.redownloadFakeHiRes &&
        HiResCheckService.isHiResQuality(quality)) {
      return null;
    }

    final sourceTrack = await _metadataResolver.prepareSourceTrack(item.track);
    item = item.copyWith(
      track: await _resolveDownloadAlbumCredit(sourceTrack, settings),
    );

    final customFolderPath = await _resolveCustomFolderPath(
      item.track,
      item,
      settings,
      quality,
    );
    final isSafMode = _isSafMode(settings);
    final rawOutputDir = isSafMode
        ? _buildRelativeOutputDir(
            item.track,
            settings,
            customFolderPath: customFolderPath,
            playlistName: item.playlistName,
          )
        : await _buildOutputDir(
            item.track,
            settings,
            customFolderPath: customFolderPath,
            playlistName: item.playlistName,
          );
    final outputDir = isSafMode
        ? _sanitizeSafRelativeDir(rawOutputDir)
        : rawOutputDir;
    if (!isSafMode) {
      await _ensureDirExists(outputDir, label: 'Output folder');
    }

    final outputExt = _determineOutputExt(quality, item.service);
    String? safFileName;
    final safOutputExt = isSafMode ? outputExt : '';
    final baseFilenameFormat = _shouldTreatAsSingleRelease(item.track)
        ? state.singleFilenameFormat
        : state.filenameFormat;
    final effectiveFilenameFormat = _filenameFormatForItem(
      item,
      baseFilenameFormat,
    );
    final qualityVariantCollisionOnly =
        item.preserveQualityVariant &&
        !_explicitQualityFilenameTokenPattern.hasMatch(baseFilenameFormat);
    if (isSafMode) {
      safFileName = await _buildSafFileNameForItem(
        item,
        item.track,
        filenameFormat: effectiveFilenameFormat,
        quality: quality,
        outputExt: safOutputExt,
      );
    }

    var trackForPayload = item.track;
    final extensionState = ref.read(extensionProvider);
    final skipMetadataEnrichment =
        DownloadMetadataResolver.shouldSkipMetadataEnrichment(
          extensionState,
          trackForPayload.source,
          item.service,
        );
    String? nativeDeezerTrackId;
    if (skipMetadataEnrichment) {
      nativeDeezerTrackId = DownloadMetadataResolver.knownDeezerTrackId(
        trackForPayload,
      );
    } else {
      nativeDeezerTrackId = await _metadataResolver
          .resolveDeezerIdFromKnownOrIsrc(
            trackForPayload,
            item.id,
            lookupContext: 'native worker ISRC',
          );
      final providerResolved = await _metadataResolver
          .resolveDeezerIdViaProviderIfNeeded(
            trackForPayload,
            nativeDeezerTrackId,
            item.id,
            extensionState: extensionState,
          );
      trackForPayload = providerResolved.track;
      nativeDeezerTrackId = providerResolved.deezerTrackId;
    }

    final extendedMetadata = skipMetadataEnrichment
        ? null
        : await _metadataResolver.loadExtendedMetadataForDeezerId(
            nativeDeezerTrackId,
          );

    final payload = _buildDownloadRequestPayload(
      track: trackForPayload,
      item: item,
      settings: settings,
      extensionState: extensionState,
      quality: quality,
      filenameFormat: effectiveFilenameFormat,
      outputDir: outputDir,
      outputExt: outputExt,
      useSaf: isSafMode,
      safFileName: safFileName,
      deezerTrackId: nativeDeezerTrackId,
      genre: extendedMetadata?.genre,
      label: extendedMetadata?.label,
      copyright: extendedMetadata?.copyright,
      stageSafForDeferredPublish: isSafMode,
      qualityVariantCollisionOnly: qualityVariantCollisionOnly,
    ).withStrategy(useExtensions: true, useFallback: state.autoFallback);

    return _NativeWorkerRequestContext(
      item: item.copyWith(track: trackForPayload),
      requestJson: jsonEncode(payload.toJson()),
      outputDir: outputDir,
      quality: quality,
      storageMode: isSafMode ? 'saf' : 'app',
      outputExt: outputExt,
      downloadTreeUri: isSafMode ? settings.downloadTreeUri : null,
      safRelativeDir: isSafMode ? outputDir : null,
      safFileName: safFileName,
      qualityVariantCollisionOnly: qualityVariantCollisionOnly,
    );
  }

  Future<void> _applyAndroidNativeWorkerSnapshot(
    Map<String, dynamic> snapshot,
    Map<String, _NativeWorkerRequestContext> contexts,
    Set<String> reconciledIds,
    AppSettings settings,
  ) async {
    final rawItems = snapshot['items'];
    final rawDelta = snapshot['item_delta'];
    final rawDeltas = snapshot['item_deltas'];
    final itemSnapshots = <Map<String, dynamic>>[];
    if (rawItems is List) {
      for (final rawItem in rawItems) {
        if (rawItem is Map) {
          itemSnapshots.add(Map<String, dynamic>.from(rawItem));
        }
      }
    }
    if (rawDelta is Map) {
      itemSnapshots.add(Map<String, dynamic>.from(rawDelta));
    }
    if (rawDeltas is List) {
      for (final rawItem in rawDeltas) {
        if (rawItem is Map) {
          itemSnapshots.add(Map<String, dynamic>.from(rawItem));
        }
      }
    }
    if (itemSnapshots.isEmpty) {
      return;
    }
    final workerRunning = snapshot['is_running'] == true;

    for (final itemSnapshot in itemSnapshots) {
      final itemId = itemSnapshot['item_id']?.toString() ?? '';
      if (itemId.isEmpty || reconciledIds.contains(itemId)) {
        continue;
      }
      final context = contexts[itemId];
      if (context == null) continue;

      final status = nativeWorkerStatusAfterSnapshotStop(
        workerRunning: workerRunning,
        status: itemSnapshot['status']?.toString() ?? 'queued',
      );
      final progress = ((itemSnapshot['progress'] as num?)?.toDouble() ?? 0.0)
          .clamp(0.0, 1.0)
          .toDouble();
      final current = _findItemById(itemId);
      if (current == null) {
        reconciledIds.add(itemId);
        continue;
      }

      if (status == 'queued') {
        updateItemStatus(itemId, DownloadStatus.queued, progress: 0.0);
        continue;
      }

      if (status == 'preparing') {
        updateItemStatus(itemId, DownloadStatus.downloading, progress: 0.0);
        continue;
      }

      if (status == 'downloading') {
        updateItemStatus(
          itemId,
          DownloadStatus.downloading,
          progress: progress,
        );
        continue;
      }

      if (status == 'finalizing') {
        updateItemStatus(
          itemId,
          DownloadStatus.finalizing,
          progress: nativeWorkerFinalizingProgress(progress),
        );
        continue;
      }

      if (status == 'completed') {
        final result = itemSnapshot['result'];
        if (result is Map) {
          try {
            await _completeAndroidNativeWorkerItem(
              context,
              Map<String, dynamic>.from(result),
              settings,
            );
            reconciledIds.add(itemId);
          } catch (e, stack) {
            // A native output can be complete while Library persistence or
            // Dart-side adoption fails. Do not leave the queue permanently at
            // 100%: surface the reconciliation failure and keep processing
            // the rest of the worker batch.
            _log.e(
              'Failed to reconcile completed native worker item $itemId: $e',
              e,
              stack,
            );
            if (_findItemById(itemId) != null) {
              _recordFailedDownload(
                itemId,
                error: 'Downloaded file could not be added to the Library: $e',
                errorType: DownloadErrorType.unknown,
              );
            }
            reconciledIds.add(itemId);
          }
        }
        continue;
      }

      if (status == 'failed' || status == 'skipped') {
        final result = itemSnapshot['result'];
        final error = itemSnapshot['error']?.toString();
        if (status == 'skipped') {
          reconciledIds.add(itemId);
          updateItemStatus(itemId, DownloadStatus.skipped);
        } else {
          final resultMap = result is Map
              ? Map<String, dynamic>.from(result)
              : null;
          final errorMsg = (error == null || error.isEmpty)
              ? (resultMap?['error']?.toString() ?? 'Download failed')
              : error;
          _log.e(
            'Native worker item $itemId failed '
            '(service: ${context.item.service}, '
            'storage: ${context.storageMode}, '
            'stage: ${resultMap?['failure_stage'] ?? 'unknown'}): $errorMsg',
          );
          final backendErrorType = resultMap == null
              ? null
              : downloadErrorTypeFromBackend(
                  resultMap['error_type']?.toString(),
                );
          final errorType =
              backendErrorType ?? _downloadErrorTypeFromMessage(errorMsg);
          try {
            if (await _recoverNativeWorkerStorageFailure(
              context: context,
              errorType: resultMap?['error_type']?.toString() ?? '',
              errorMessage: errorMsg,
              contexts: contexts,
              reconciledIds: reconciledIds,
            )) {
              continue;
            }
          } catch (e) {
            _log.e('Could not recover native-worker storage failure: $e');
          }
          reconciledIds.add(itemId);
          if (errorType == DownloadErrorType.verificationRequired) {
            _log.i(
              'Android native worker requires verification for ${current.track.name}; switching back to interactive queue',
            );
            // Cancelling the native worker marks every remaining batch item
            // "skipped" on the native side. Those items did nothing wrong —
            // remember them now and requeue them below so the batch resumes
            // after the challenge instead of being abandoned.
            final pendingBatchIds = <String>[];
            for (final pendingId in contexts.keys) {
              if (pendingId == itemId || reconciledIds.contains(pendingId)) {
                continue;
              }
              final pending = _findItemById(pendingId);
              if (pending == null) continue;
              if (pending.status == DownloadStatus.queued ||
                  pending.status == DownloadStatus.downloading ||
                  pending.status == DownloadStatus.finalizing) {
                pendingBatchIds.add(pendingId);
              }
            }
            try {
              await PlatformBridge.cancelNativeDownloadWorker();
            } catch (e) {
              _log.w('Failed to cancel native worker before verification: $e');
            }
            for (final pendingId in pendingBatchIds) {
              reconciledIds.add(pendingId);
              updateItemStatus(pendingId, DownloadStatus.queued, progress: 0.0);
            }
            if (_queueStartupPending) {
              // This snapshot predates the browser return. Let startup finish
              // exchanging its callback before retrying through the regular
              // queue; opening another challenge here would race that grant
              // and wait on our own queue-restoration barrier.
              updateItemStatus(itemId, DownloadStatus.queued, progress: 0.0);
              continue;
            }
            await _handleVerificationRequiredDownload(
              current,
              errorMsg,
              _nativeWorkerVerificationService(resultMap, context),
            );
            continue;
          }
          _recordFailedDownload(itemId, error: errorMsg, errorType: errorType);
        }
      }
    }

    final releasableIds = contexts.keys
        .where(reconciledIds.contains)
        .toList(growable: false);
    if (releasableIds.isEmpty) return;

    // Restored state is already published here; startup adoption must not
    // await the public lifecycle gate whose completion depends on adoption.
    await _queuePersistence.flush();
    if (!workerRunning) {
      for (final itemId in releasableIds) {
        contexts.remove(itemId);
        reconciledIds.remove(itemId);
      }
      return;
    }

    final runId = _snapshotRunId(snapshot);
    if (runId.isEmpty) return;
    try {
      await PlatformBridge.acknowledgeNativeDownloadWorkerItems(
        runId: runId,
        itemIds: releasableIds,
      );
      for (final itemId in releasableIds) {
        contexts.remove(itemId);
        reconciledIds.remove(itemId);
      }
    } catch (e) {
      // Keep contexts so the acknowledgement is retried on the next poll.
      // This also keeps the preparation window bounded while native results
      // are still retained by the service.
      _log.w('Could not release reconciled native queue items: $e');
    }
  }

  Future<void> _completeAndroidNativeWorkerItem(
    _NativeWorkerRequestContext context,
    Map<String, dynamic> rawResult,
    AppSettings settings,
  ) async {
    final result = DownloadResult.fromMap(rawResult);
    context = context.withResolvedFolder(result);
    final item = context.item;
    var filePath = result.filePath;
    if (filePath == null || filePath.isEmpty) {
      _recordFailedDownload(
        item.id,
        error: 'Native worker completed without a file path',
        errorType: DownloadErrorType.unknown,
      );
      return;
    }

    if (result.nativeFinalized) {
      final nativeFinalizedFilePath = filePath;
      await _saveDownloadedMotionArtwork(ref, item, item.track, result);
      await persistBeforePublishingDownloadCompletion(
        persist: () async {
          if (!settings.saveDownloadHistory) return;
          final history = ref.read(downloadHistoryProvider.notifier);
          await reconcileNativeDownloadHistory(
            result: result,
            adopt: (json) => history.adoptNativeHistoryItem(
              DownloadHistoryItem.fromJson(json),
              preserveTrackVariant: item.preserveQualityVariant,
            ),
            reload: history.reloadFromStorage,
            persistFallback: () => _persistNativeFinalizedHistoryFallback(
              context,
              result,
              nativeFinalizedFilePath,
            ),
          );
        },
        publish: () {
          _completedInSession++;
          updateItemStatus(
            item.id,
            DownloadStatus.completed,
            progress: 1.0,
            filePath: nativeFinalizedFilePath,
          );
        },
      );
      removeItem(item.id);
      return;
    }

    final rawDecryptFileName =
        result.fileName ?? context.safFileName ?? 'track';
    final decryptOutcome = await _fileFinalizer.decrypt(
      result: result,
      filePath: filePath,
      useSaf: context.storageMode == 'saf',
      treeUri: context.downloadTreeUri,
      relativeDir: context.safRelativeDir ?? '',
      baseName: rawDecryptFileName.replaceFirst(RegExp(r'\.[^.]+$'), ''),
      extensionFallback: context.outputExt,
      repairContainer: false,
      onStart: (strategy) => _log.i(
        'Native-worker encrypted stream detected, decrypting via $strategy...',
      ),
    );
    if (decryptOutcome.path == null) {
      _recordFailedDownload(
        item.id,
        error: 'Failed to decrypt encrypted stream',
        errorType: DownloadErrorType.unknown,
      );
      return;
    }
    filePath = decryptOutcome.path!;
    if (decryptOutcome.fileName != null) {
      result.fileName = decryptOutcome.fileName;
    }

    var actualQuality = context.quality;
    var actualBitDepth = result.actualBitDepth;
    var actualSampleRate = result.actualSampleRate;
    var actualFormat =
        normalizeAudioFormatValue(
          result['audio_codec']?.toString() ?? result['format']?.toString(),
        ) ??
        normalizeAudioFormatValue(audioFormatForPath(filePath));
    var actualBitrate = readPositiveBitrateKbps(
      result['bitrate'] ?? result['actual_bitrate'],
    );
    final resolvedQuality = resolveDisplayQuality(
      filePath: filePath,
      detectedFormat: actualFormat,
      bitDepth: actualBitDepth,
      sampleRate: actualSampleRate,
      bitrateKbps: actualBitrate,
      storedQuality: actualQuality,
    );
    if (resolvedQuality != null) {
      actualQuality = resolvedQuality;
    }

    final resolvedAlbumArtist = DownloadMetadataResolver.albumArtistForMetadata(
      item.track,
      settings,
    );
    final trackToDownload = buildTrackForMetadataEmbedding(
      item.track,
      result,
      resolvedAlbumArtist,
    );
    final convertedContainerPath =
        await _finalizeNativeWorkerContainerConversion(
          context: context,
          result: result,
          settings: settings,
          track: trackToDownload,
          filePath: filePath,
        );
    if (convertedContainerPath == null) {
      _recordFailedDownload(
        item.id,
        error: 'Failed to convert downloaded container',
        errorType: DownloadErrorType.unknown,
      );
      return;
    }
    filePath = convertedContainerPath;

    final postProcessedPath = await _runPostProcessingHooks(
      filePath,
      trackToDownload,
      item.id,
    );
    if (postProcessedPath != null && postProcessedPath.isNotEmpty) {
      filePath = postProcessedPath;
    }
    final autoConvertOutcome = await _autoConvertDownloadedFile(
      itemId: item.id,
      filePath: filePath,
      fileName: result.fileName ?? context.safFileName,
      currentQuality: actualQuality,
      settings: settings,
      track: trackToDownload,
      result: result,
      downloadService: context.item.service,
      storageMode: context.storageMode,
      downloadTreeUri: context.downloadTreeUri,
      safRelativeDir: context.safRelativeDir,
    );
    filePath = autoConvertOutcome.filePath;
    actualQuality = autoConvertOutcome.quality;
    if (autoConvertOutcome.fileName != null) {
      result.fileName = autoConvertOutcome.fileName;
    }
    if (autoConvertOutcome.converted) {
      actualBitDepth = null;
      actualSampleRate = null;
      actualFormat = normalizeAutoConvertFormat(settings.autoConvertFormat);
      actualBitrate = autoConvertBitrateKbps(settings.autoConvertBitrate);
    } else if (settings.embedMetadata &&
        _isMp4Container(result['file_name']?.toString() ?? filePath)) {
      // Native lossy containers still need tags and lyrics even though their
      // audio is no longer passed through the retired quality conversion.
      Future<void> embedNativeMetadata(String path) async {
        final lyrics = await _embedMetadataToFile(
          path,
          trackToDownload,
          format: 'm4a',
          genre: result['genre'] as String?,
          label: result['label'] as String?,
          copyright: result['copyright'] as String?,
          comment: result['comment'] as String?,
          lyricsLrc: result['lyrics_lrc'] as String?,
          downloadService: context.item.service,
          writeExternalLrc: context.storageMode != 'saf',
        );
        if (lyrics != null && lyrics.isNotEmpty) result['lyrics_lrc'] = lyrics;
      }

      if (context.storageMode == 'saf' && isContentUri(filePath)) {
        final treeUri = context.downloadTreeUri;
        if (treeUri != null && treeUri.isNotEmpty) {
          final fileName =
              result['file_name']?.toString() ?? context.safFileName;
          if (fileName != null && fileName.isNotEmpty) {
            final updatedUri = await _replaceSafFileVia(
              uri: filePath,
              treeUri: treeUri,
              relativeDir: context.safRelativeDir ?? '',
              op: (tempPath, _) async {
                await embedNativeMetadata(tempPath);
                return (tempPath, fileName);
              },
            );
            if (updatedUri != null) filePath = updatedUri;
          }
        }
      } else {
        await embedNativeMetadata(filePath);
      }
    }
    await _writeNativeWorkerReplayGain(
      settings: settings,
      track: trackToDownload,
      filePath: filePath,
    );

    if (item.preserveQualityVariant) {
      final variantOutcome = await _finalizeQualityVariantFilename(
        item: item,
        result: result,
        filePath: filePath,
        storageMode: context.storageMode,
        downloadTreeUri: context.downloadTreeUri,
        safRelativeDir: context.safRelativeDir,
        fileName: result['file_name'] as String? ?? context.safFileName,
        collisionOnly: context.qualityVariantCollisionOnly,
      );
      filePath = variantOutcome.filePath;
      actualBitDepth = readPositiveInt(result['actual_bit_depth']);
      actualSampleRate = readPositiveInt(result['actual_sample_rate']);
      actualFormat =
          normalizeAudioFormatValue(result['audio_codec']?.toString()) ??
          normalizeAudioFormatValue(audioFormatForPath(filePath));
      actualBitrate = readPositiveBitrateKbps(
        result['bitrate'] ?? result['actual_bitrate'],
      );
      final finalQuality = resolveDisplayQuality(
        filePath: filePath,
        fileName: variantOutcome.fileName,
        detectedFormat: actualFormat,
        bitDepth: actualBitDepth,
        sampleRate: actualSampleRate,
        bitrateKbps: actualBitrate,
        storedQuality: actualQuality,
      );
      if (finalQuality != null) actualQuality = finalQuality;
    }

    final externalLrcWritten = await _saveExternalLrc(
      result: result,
      settings: settings,
      extensionState: ref.read(extensionProvider),
      track: trackToDownload,
      service: context.item.service,
      filePath: filePath,
      storageMode: context.storageMode,
      downloadTreeUri: context.downloadTreeUri,
      safRelativeDir: context.safRelativeDir ?? '',
      resolveBaseName: () async {
        final resultFileName = result['file_name'] as String?;
        final fileName = (resultFileName != null && resultFileName.isNotEmpty)
            ? resultFileName
            : context.safFileName;
        return fileName != null && fileName.isNotEmpty
            ? fileName.replaceFirst(RegExp(r'\.[^.]+$'), '')
            : await PlatformBridge.sanitizeFilename(
                '${trackToDownload.artistName} - ${trackToDownload.name}',
              );
      },
      onFetchError: (e) =>
          _log.w('Failed to fetch native-worker external LRC: $e'),
    );

    final resultSafFileName = result['file_name'] as String?;
    final lowerFilePath = filePath.toLowerCase();
    // Recompute from the FINAL file path/result: automatic and container
    // conversions above may have changed the format since actualFormat was
    // derived from the pre-conversion output.
    final historyFormat =
        normalizeAudioFormatValue(
          result['audio_codec']?.toString() ?? result['format']?.toString(),
        ) ??
        normalizeAudioFormatValue(audioFormatForPath(filePath));
    final isLossyOutput =
        isLossyAudioFormat(historyFormat) ||
        lowerFilePath.endsWith('.mp3') ||
        lowerFilePath.endsWith('.opus') ||
        lowerFilePath.endsWith('.ogg');

    final completedFilePath = filePath;
    await _saveDownloadedMotionArtwork(ref, item, trackToDownload, result);
    final lyricsAvailability = await _resolveFinalLyricsAvailability(
      filePath: completedFilePath,
      externalLrcWritten: externalLrcWritten,
    );
    await persistBeforePublishingDownloadCompletion(
      persist: () async {
        if (!settings.saveDownloadHistory) return;
        await ref
            .read(downloadHistoryProvider.notifier)
            .addToHistory(
              _historyItemFromResult(
                item: item,
                trackToDownload: trackToDownload,
                result: result,
                filePath: completedFilePath,
                quality: actualQuality,
                useSaf: context.storageMode == 'saf',
                downloadTreeUri: context.downloadTreeUri,
                safRelativeDir: context.safRelativeDir,
                safFileName:
                    (resultSafFileName != null && resultSafFileName.isNotEmpty)
                    ? resultSafFileName
                    : context.safFileName,
                bitDepth: isLossyOutput ? null : actualBitDepth,
                sampleRate: isLossyOutput ? null : actualSampleRate,
                bitrate: actualBitrate,
                format: historyFormat,
                genre: normalizeOptionalString(result['genre'] as String?),
                label: normalizeOptionalString(result['label'] as String?),
                copyright: normalizeOptionalString(
                  result['copyright'] as String?,
                ),
                hasLyrics: lyricsAvailability.hasLyrics,
                lyricsMetadataScanVersion: lyricsAvailability.scanVersion,
                hasReplayGain: lyricsAvailability.hasReplayGain,
                replayGainMetadataScanVersion:
                    lyricsAvailability.replayGainScanVersion,
              ),
              preserveTrackVariant: item.preserveQualityVariant,
            );
      },
      publish: () {
        _completedInSession++;
        updateItemStatus(
          item.id,
          DownloadStatus.completed,
          progress: 1.0,
          filePath: completedFilePath,
        );
      },
    );
    // Quality-variant renaming may have changed the path since the scan.
    _updateAlbumRgFilePath(trackToDownload, completedFilePath);
    await _checkAndWriteAlbumReplayGain(trackToDownload);
    removeItem(item.id);
  }

  Future<void> _writeNativeWorkerReplayGain({
    required AppSettings settings,
    required Track track,
    required String filePath,
  }) async {
    if (!settings.embedReplayGain) {
      return;
    }
    final ext = audioFormatForPath(filePath)?.toLowerCase();
    if (ext != 'flac' &&
        ext != 'm4a' &&
        ext != 'mp3' &&
        ext != 'opus' &&
        !isContentUri(filePath)) {
      return;
    }

    try {
      final rgResult = await ReplayGainService.scanAndApplyToFile(filePath);
      if (rgResult == null) {
        return;
      }
      _storeTrackReplayGainForAlbum(track, filePath, rgResult);
      _log.d(
        'Native-worker ReplayGain written: gain=${rgResult.trackGain}, peak=${rgResult.trackPeak}',
      );
    } catch (e) {
      _log.w('Failed to write native-worker ReplayGain: $e');
    }
  }

  String _nativeWorkerVerificationService(
    Map<String, dynamic>? result,
    _NativeWorkerRequestContext context,
  ) {
    if (result != null) {
      for (final key in const [
        'service',
        'verification_service',
        'provider',
        'source',
      ]) {
        final value = result[key]?.toString().trim() ?? '';
        if (value.isNotEmpty) return value;
      }
    }
    return context.item.service;
  }
}
