// ignore_for_file: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
part of 'download_queue_provider.dart';

extension _SingleItemDownload on DownloadQueueNotifier {
  Future<String?> _runPostProcessingHooks(
    String filePath,
    Track track,
    String itemId,
  ) async {
    try {
      final settings = ref.read(settingsProvider);
      final extensionState = ref.read(extensionProvider);
      final resolvedAlbumArtist =
          DownloadMetadataResolver.albumArtistForMetadata(track, settings);

      if (!settings.useExtensionProviders) return null;

      final hasPostProcessing = extensionState.extensions.any(
        (e) => e.enabled && e.hasPostProcessing,
      );
      if (!hasPostProcessing) return null;

      _log.d('Running post-processing hooks on: $filePath');

      final metadata = <String, dynamic>{
        'title': track.name,
        'artist': track.artistName,
        'album': track.albumName,
        'track_number': track.trackNumber ?? 0,
        'disc_number': track.discNumber ?? 0,
        'isrc': track.isrc ?? '',
        'release_date': track.releaseDate ?? '',
        'duration_ms': track.duration * 1000,
        'cover_url': track.coverUrl ?? '',
      };
      if (resolvedAlbumArtist != null) {
        metadata['album_artist'] = resolvedAlbumArtist;
      }

      final result = await PlatformBridge.runPostProcessingV2(
        filePath,
        metadata: metadata,
        itemId: itemId,
      );

      if (result['success'] == true) {
        final hooksRun = result['hooks_run'] as int? ?? 0;
        final newPath = result['file_path'] as String?;
        _log.i('Post-processing completed: $hooksRun hook(s) executed');

        if (newPath != null && newPath != filePath) {
          _log.d('File path changed by post-processing: $newPath');
          return newPath;
        }
        return filePath;
      } else {
        final error = result['error'] as String? ?? 'Unknown error';
        _log.w('Post-processing failed: $error');
      }
    } catch (e) {
      _log.w('Post-processing error: $e');
    }
    return null;
  }

  Future<void> _downloadSingleItem(DownloadItem item) =>
      _DownloadRun(this, item)._run();
}

/// One download attempt for a single queue item.
///
/// The stage order is enrich -> resolve output -> resolve identifiers ->
/// download -> decrypt/convert/embed -> publish. `n` owns shared queue state.
class _DownloadRun {
  _DownloadRun(this.n, this.item);

  final DownloadQueueNotifier n;

  DownloadItem item;
  bool pausedDuringThisRun = false;

  late AppSettings settings;
  bool get metadataEmbeddingEnabled => settings.embedMetadata;
  late Track trackToDownload;
  String? resolvedAlbumArtist;
  late String quality;
  late String safOutputExt;
  late String effectiveFilenameFormat;
  bool effectiveSafMode = false;
  String effectiveOutputDir = '';
  String? appOutputDir;
  String? customFolderPath;
  String? safFileName;
  bool qualityVariantCollisionOnly = false;
  String? safBaseName;
  String? finalSafFileName;

  late ExtensionState extensionState;
  late bool selectedExtensionDownloadProvider;
  late bool shouldSkipExtensionSongLinkPrelookup;
  late bool shouldSkipMetadataEnrichment;
  late bool useExtensions;

  String? deezerTrackId;
  String? genre;
  String? label;
  String? copyright;

  late DownloadResult result;

  String? filePath;
  bool wasExisting = false;
  String actualQuality = '';
  String? resultOutputExt;
  bool shouldPreserveNativeM4a = false;
  bool forceContainerConversion = false;

  /// Filled by the SAF embed op from the local temp so the final quality
  /// probe doesn't have to copy the published file back out of SAF.
  Map<String, dynamic>? probedFinalMetadata;
  bool externalLrcWritten = false;
  final Map<String, String> _directoryScopes = {};
  bool fakeHiResChecked = false;
  bool get isNetworkDownload => item.networkDownloadFolder.isNotEmpty;
  String networkRelativeDir = '';
  String? fakeHiResOriginalPath;

  Future<void> _run() async {
    final normalizedService = n._normalizeQueuedService(item.service);
    if (normalizedService != item.service) {
      item = item.copyWith(service: normalizedService);
      n.state = n.state.copyWith(
        items: [
          for (final existing in n.state.items)
            if (existing.id == item.id) item else existing,
        ],
        currentDownload: n.state.currentDownload?.id == item.id
            ? item
            : n.state.currentDownload,
      );
      n._saveQueueToStorage();
    }

    if (!isNetworkDownload && !n._hasActiveDownloadProvider(item.service)) {
      n.updateItemStatus(
        item.id,
        DownloadStatus.failed,
        error: 'Download provider is no longer available',
        errorType: DownloadErrorType.notFound,
      );
      return;
    }

    _log.d('Processing: ${item.track.name} by ${item.track.artistName}');

    final currentItem = n._findItemById(item.id) ?? item;
    if (n._isLocallyCancelled(item.id, item: currentItem)) {
      _log.i('Download was cancelled before start, skipping');
      return;
    }

    if (n._isPausePending(item.id)) {
      pausedDuringThisRun = true;
      n._requeueItemForPause(item.id);
      _log.i('Download is pause-pending before start, skipping');
      return;
    }

    n.state = n.state.copyWith(currentDownload: item);

    n.updateItemStatus(item.id, DownloadStatus.downloading);

    try {
      settings = n.ref.read(settingsProvider);
      trackToDownload = item.track;

      if (isNetworkDownload) {
        final prepared = await NetworkDownloadStaging.instance.read(item.id);
        if (prepared != null) {
          trackToDownload = Track.fromJson(
            Map<String, dynamic>.from(prepared['track'] as Map),
          );
          result = DownloadResult.fromMap(
            Map<String, dynamic>.from(prepared['result'] as Map),
          );
          filePath = prepared['localPath'] as String;
          actualQuality = prepared['quality'] as String;
          externalLrcWritten = prepared['externalLrcWritten'] == true;
          networkRelativeDir = prepared['relativeDir'] as String;
          await _persistCompletionAndNotify();
          return;
        }
        if (!n._hasActiveDownloadProvider(item.service)) {
          throw StateError('Download provider is no longer available');
        }
      }

      if (!await _enrichDeezerTrackIfNeeded()) return;

      trackToDownload = await n._resolveDownloadAlbumCredit(
        trackToDownload,
        settings,
      );
      if (await _shouldAbort('during album metadata lookup')) return;

      resolvedAlbumArtist = DownloadMetadataResolver.albumArtistForMetadata(
        trackToDownload,
        settings,
      );
      await _resolveOutputTarget();
      _resolveExtensionFlags();
      if (!await _resolveTrackIdentifiers()) return;

      // Genre/label/copyright are only consumed at embed time (the payload
      // copy is just echoed back in the response), so this lookup overlaps
      // with the download instead of delaying its start; it is awaited right
      // after the download returns.
      final extendedMetadataFuture = shouldSkipMetadataEnrichment
          ? Future<DownloadExtendedMetadata?>.value(null)
          : n._metadataResolver
                .loadExtendedMetadataForDeezerId(deezerTrackId)
                .catchError((Object e) {
                  _log.w('Extended metadata lookup failed: $e');
                  return null;
                });

      if (await _shouldAbort('before native download start')) {
        return;
      }

      if (!await _downloadAndMaybeFallback()) return;

      _log.d(
        'Native download result: success=${result.success}, '
        'service=${result.service ?? item.service}, '
        'errorType=${result['error_type'] ?? 'none'}, '
        'filePresent=${result.filePath?.isNotEmpty == true}',
      );

      final extendedMetadata = await extendedMetadataFuture;
      if (extendedMetadata != null) {
        genre = extendedMetadata.genre;
        label = extendedMetadata.label;
        copyright = extendedMetadata.copyright;
      }

      final resultFilePath = result.filePath;
      final resultFileToCleanup = (resultFilePath != null && result.success)
          ? resultFilePath
          : null;
      if (await _shouldAbort(
        'after result',
        deleteFileOnAbort: resultFileToCleanup,
      )) {
        return;
      }

      if (result.success) {
        final resolvedDirectory = result.resolvedSafDirectory;
        if (effectiveSafMode && resolvedDirectory != null) {
          effectiveOutputDir = n._sanitizeSafRelativeDir(resolvedDirectory);
          _log.d('Resolved output dir: $effectiveOutputDir');
        }
        if (!await _handleDownloadSuccess()) return;
      } else {
        if (!await _handleBackendFailure()) return;
      }

      n._downloadCount++;
      // The HTTP pool expires idle connections itself. Keep warm connections
      // for the next track; network changes/errors and queue teardown still
      // recycle the pool when needed.
    } catch (e, stackTrace) {
      await _handleRunException(e, stackTrace);
    } finally {
      if (isNetworkDownload && n._findItemById(item.id) == null) {
        try {
          await NetworkDownloadStaging.instance.discard(item.id);
        } catch (e) {
          _log.w('Could not remove dismissed network staging: $e');
        }
      }
      for (final token in _directoryScopes.values) {
        try {
          await PlatformBridge.releaseDownloadDirectory(token);
        } catch (e) {
          _log.w('Failed to release output directory scope: $e');
        }
      }
      _directoryScopes.clear();
      if (pausedDuringThisRun) {
        n._pausePendingItemIds.remove(item.id);
      }
    }
  }

  /// Shared guard for every checkpoint in the pipeline: an item that vanished
  /// from the queue or was flagged locally-cancelled aborts immediately; a
  /// pause-pending item re-queues instead. [deleteFileOnAbort], when given,
  /// is removed before returning (used once a file has already been written).
  Future<bool> _shouldAbort(String stage, {String? deleteFileOnAbort}) async {
    final current = n._findItemById(item.id);
    if (current == null || n._isLocallyCancelled(item.id, item: current)) {
      _log.i('Download was cancelled $stage, skipping');
      if (deleteFileOnAbort != null) {
        await deleteFile(deleteFileOnAbort);
        _log.d('Deleted cancelled download file: $deleteFileOnAbort');
      }
      return true;
    }
    if (n._isPausePending(item.id)) {
      pausedDuringThisRun = true;
      if (deleteFileOnAbort != null) {
        await deleteFile(deleteFileOnAbort);
        _log.d('Deleted paused download file: $deleteFileOnAbort');
      }
      n._requeueItemForPause(item.id);
      _log.i('Download pause requested $stage, re-queueing');
      return true;
    }
    return false;
  }

  Future<bool> _enrichDeezerTrackIfNeeded() async {
    trackToDownload = await n._metadataResolver.prepareSourceTrack(
      trackToDownload,
    );
    return !await _shouldAbort('during metadata enrichment');
  }

  Future<void> _resolveOutputTarget() async {
    quality = item.qualityOverride ?? n.state.audioQuality;
    if (quality == 'DEFAULT') quality = n.state.audioQuality;
    customFolderPath = await n._resolveCustomFolderPath(
      trackToDownload,
      item,
      settings,
      quality,
    );
    final isSafMode = !isNetworkDownload && n._isSafMode(settings);
    final relativeOutputDir = isSafMode || isNetworkDownload
        ? n._buildRelativeOutputDir(
            trackToDownload,
            settings,
            customFolderPath: customFolderPath,
            playlistName: item.playlistName,
          )
        : '';
    networkRelativeDir = relativeOutputDir;
    final initialOutputDir = isNetworkDownload
        ? (await NetworkDownloadStaging.instance.workDirectory(item.id)).path
        : isSafMode
        ? relativeOutputDir
        : await n._buildOutputDir(
            trackToDownload,
            settings,
            customFolderPath: customFolderPath,
            playlistName: item.playlistName,
          );
    effectiveOutputDir = isSafMode
        ? n._sanitizeSafRelativeDir(initialOutputDir)
        : initialOutputDir;
    effectiveSafMode = isSafMode;

    safOutputExt = n._determineOutputExt(quality, item.service);
    final baseFilenameFormat = n._shouldTreatAsSingleRelease(trackToDownload)
        ? n.state.singleFilenameFormat
        : n.state.filenameFormat;
    effectiveFilenameFormat = n._filenameFormatForItem(
      item,
      baseFilenameFormat,
    );
    qualityVariantCollisionOnly =
        item.preserveQualityVariant &&
        !_explicitQualityFilenameTokenPattern.hasMatch(baseFilenameFormat);
    if (isSafMode) {
      final builtSafFileName = await n._buildSafFileNameForItem(
        item,
        trackToDownload,
        filenameFormat: effectiveFilenameFormat,
        quality: quality,
        outputExt: safOutputExt,
      );
      safFileName = builtSafFileName;
      safBaseName = builtSafFileName.replaceFirst(RegExp(r'\.[^.]+$'), '');
    }
    finalSafFileName = safFileName;
  }

  void _resolveExtensionFlags() {
    extensionState = n.ref.read(extensionProvider);
    selectedExtensionDownloadProvider =
        settings.useExtensionProviders &&
        extensionState.extensions.any(
          (e) =>
              e.enabled &&
              e.hasDownloadProvider &&
              e.id.toLowerCase() == item.service.toLowerCase(),
        );
    final trackSource = (trackToDownload.source ?? '').trim().toLowerCase();
    shouldSkipExtensionSongLinkPrelookup =
        trackSource.isNotEmpty &&
        extensionState.extensions.any(
          (e) =>
              e.enabled &&
              e.hasMetadataProvider &&
              e.id.toLowerCase() == trackSource,
        );
    shouldSkipMetadataEnrichment =
        DownloadMetadataResolver.shouldSkipMetadataEnrichment(
          extensionState,
          trackToDownload.source,
          item.service,
        );
    final hasActiveExtensions = extensionState.extensions.any((e) => e.enabled);
    useExtensions = settings.useExtensionProviders && hasActiveExtensions;
  }

  Future<bool> _resolveTrackIdentifiers() async {
    if (shouldSkipMetadataEnrichment) {
      deezerTrackId = DownloadMetadataResolver.knownDeezerTrackId(
        trackToDownload,
      );
      _log.d('Skipping cross-provider metadata enrichment for ${item.service}');
      return true;
    }
    deezerTrackId = await n._metadataResolver.resolveDeezerIdFromKnownOrIsrc(
      trackToDownload,
      item.id,
      lookupContext: 'ISRC',
    );
    if (await _shouldAbort('during Deezer ISRC lookup')) {
      return false;
    }

    // For tidal:/qobuz: tracks without ISRC, resolve ISRC from provider
    // API directly (faster than SongLink and avoids rate limits).
    final providerResolved = await n._metadataResolver
        .resolveDeezerIdViaProviderIfNeeded(
          trackToDownload,
          deezerTrackId,
          item.id,
          extensionState: extensionState,
        );
    trackToDownload = providerResolved.track;
    deezerTrackId = providerResolved.deezerTrackId;
    if (await _shouldAbort('during provider ISRC resolution')) {
      return false;
    }

    if (!selectedExtensionDownloadProvider &&
        deezerTrackId == null &&
        !shouldSkipExtensionSongLinkPrelookup &&
        trackToDownload.id.isNotEmpty &&
        !trackToDownload.id.startsWith('deezer:') &&
        !trackToDownload.id.startsWith('extension:') &&
        !trackToDownload.id.startsWith('tidal:') &&
        !trackToDownload.id.startsWith('qobuz:')) {
      final spotifyLookup = await n._metadataResolver
          .resolveSpotifyTrackViaDeezer(trackToDownload);
      trackToDownload = spotifyLookup.track;
      deezerTrackId ??= spotifyLookup.deezerTrackId;

      if (await _shouldAbort('during SongLink availability lookup')) {
        return false;
      }
    } else if (selectedExtensionDownloadProvider && deezerTrackId == null) {
      _log.d(
        'Skipping Flutter SongLink Deezer prelookup for extension provider: ${item.service}',
      );
    } else if (shouldSkipExtensionSongLinkPrelookup && deezerTrackId == null) {
      _log.d(
        'Skipping Flutter SongLink Deezer prelookup for extension-sourced track; backend metadata enrichment will resolve identifiers first',
      );
    }
    return true;
  }

  Future<DownloadResult> _invokeDownload({
    required bool useSaf,
    required String outputDir,
  }) async {
    final outputExt = safOutputExt;
    final shouldUseExtensions = useExtensions;
    final shouldUseFallback = n.state.autoFallback;

    if (shouldUseExtensions) {
      _log.d('Using extension providers for download');
      _log.d(
        'Quality: $quality${item.qualityOverride != null ? ' (override)' : ''}',
      );
    } else if (shouldUseFallback) {
      _log.d('Using auto-fallback mode');
      _log.d(
        'Quality: $quality${item.qualityOverride != null ? ' (override)' : ''}',
      );
    }

    if (!useSaf) {
      await n._ensureDirExists(outputDir, label: 'Output folder');
      if (!_directoryScopes.containsKey(outputDir)) {
        _directoryScopes[outputDir] =
            await PlatformBridge.acquireDownloadDirectory(outputDir);
      }
    }

    _log.d('Output dir: $outputDir');

    final payload = n._buildDownloadRequestPayload(
      track: trackToDownload,
      item: item,
      settings: settings,
      extensionState: extensionState,
      quality: quality,
      filenameFormat: effectiveFilenameFormat,
      outputDir: outputDir,
      outputExt: outputExt,
      useSaf: useSaf,
      safFileName: safFileName,
      deezerTrackId: deezerTrackId,
      genre: genre,
      label: label,
      copyright: copyright,
      stageSafForDeferredPublish: useSaf,
      qualityVariantCollisionOnly: qualityVariantCollisionOnly,
    );

    return DownloadResult.fromMap(
      await PlatformBridge.downloadByStrategy(
        payload: payload,
        useExtensions: shouldUseExtensions,
        useFallback: shouldUseFallback,
      ),
    );
  }

  Future<bool> _downloadAndMaybeFallback() async {
    result = await _invokeDownload(
      useSaf: effectiveSafMode,
      outputDir: effectiveOutputDir,
    );

    if (!isNetworkDownload &&
        !result.success &&
        isStorageWriteFailure(
          errorType: result['error_type']?.toString(),
          errorMessage: (result['error'] ?? result['message'])?.toString(),
        )) {
      if (n._isLocallyCancelled(item.id)) {
        _log.i('Download was cancelled before storage fallback, skipping');
        return false;
      }
      if (storageWriteRecoveryFor(useSaf: effectiveSafMode) ==
          StorageWriteRecovery.requestSafAccess) {
        _log.w(
          'SAF write failed; preserving the selected destination for reauthorization',
        );
        result = DownloadResult.fromMap({
          ...result,
          'success': false,
          'error': safPermissionLostErrorMessage,
          'error_type': 'permission',
        });
        return true;
      }
      _log.w('Storage write failed, retrying with a writable app folder');
      try {
        await n._activateAppFolderStorageFallback(
          failedOutputDir: effectiveSafMode ? null : effectiveOutputDir,
        );
        final fallbackDir =
            appOutputDir ??
            await n._buildOutputDir(
              trackToDownload,
              settings,
              customFolderPath: customFolderPath,
              playlistName: item.playlistName,
            );
        appOutputDir = fallbackDir;
        final fallbackResult = await _invokeDownload(
          useSaf: false,
          outputDir: fallbackDir,
        );
        result = fallbackResult;
        if (fallbackResult.success) {
          effectiveSafMode = false;
          effectiveOutputDir = fallbackDir;
          finalSafFileName = null;
        }
      } catch (e) {
        _log.e('App-folder storage fallback failed: $e');
      }
    }
    return true;
  }

  Future<bool> _handleDownloadSuccess() async {
    final stageWatch = LogBuffer.loggingEnabled ? (Stopwatch()..start()) : null;
    void stageCompleted(String stage) {
      if (stageWatch == null) return;
      _log.d(
        'Finalization [${item.id}] $stage: ${stageWatch.elapsedMilliseconds} ms',
      );
      stageWatch.reset();
    }

    filePath = result.filePath;
    final reportedFileName = result.fileName;
    if (effectiveSafMode &&
        reportedFileName != null &&
        reportedFileName.isNotEmpty) {
      finalSafFileName = reportedFileName;
    }

    wasExisting = result.alreadyExists;
    _log.i('Download completed (existing=$wasExisting)');

    final actualBitDepth = result.actualBitDepth;
    final actualSampleRate = result.actualSampleRate;
    actualQuality = quality;

    if (actualBitDepth != null && actualBitDepth > 0) {
      final sampleRateKHz = actualSampleRate != null && actualSampleRate > 0
          ? (actualSampleRate / 1000).toStringAsFixed(
              actualSampleRate % 1000 == 0 ? 0 : 1,
            )
          : '?';
      actualQuality = '$actualBitDepth-bit/${sampleRateKHz}kHz';
      _log.i('Actual quality: $actualQuality');
    }

    final actualService =
        result.service?.toLowerCase() ?? item.service.toLowerCase();
    resultOutputExt = result.outputExtension(path: filePath);
    final resultAudioFormat = normalizeAudioFormatValue(result.audioCodec);
    final resultIsKnownLossyAudio =
        isLossyAudioFormat(resultAudioFormat) &&
        !isInconclusiveAudioCodec(resultAudioFormat);
    forceContainerConversion =
        result.requiresContainerConversion ||
        (!resultIsKnownLossyAudio &&
            n._shouldRequestContainerConversion(actualService, safOutputExt));
    final preferredOutputExt = n._extensionPreferredOutputExt(actualService);
    shouldPreserveNativeM4a =
        // M4A/MP4 may contain FLAC. A requested FLAC output must reach the
        // codec probe even if the extension did not ask for conversion.
        safOutputExt != '.flac' &&
        !forceContainerConversion &&
        (resultOutputExt == '.m4a' ||
            resultOutputExt == '.mp4' ||
            preferredOutputExt == '.m4a' ||
            preferredOutputExt == '.mp4' ||
            n._extensionPreservesNativeOutputExt(actualService, '.m4a') ||
            n._extensionPreservesNativeOutputExt(actualService, '.mp4'));
    final requestTrack = trackToDownload;
    trackToDownload = buildTrackForMetadataEmbedding(
      trackToDownload,
      result,
      resolvedAlbumArtist,
    );
    if (!await _decryptIfNeeded()) {
      return false;
    }
    stageCompleted('decrypt');
    await _applyFormatHandling(actualService);
    stageCompleted('format and metadata');

    final originalHiResPath = fakeHiResOriginalPath;
    if (originalHiResPath != null &&
        (filePath == null ||
            !await HiResCheckService.replacementPreservesAudio(
              originalHiResPath,
              filePath!,
            ))) {
      throw StateError(
        'Lossless replacement does not preserve the original audio',
      );
    }

    if (await _shouldAbort(
      'during finalization',
      deleteFileOnAbort: filePath,
    )) {
      return false;
    }

    // At most once per run: the LOSSLESS replacement is not checked again.
    if (!fakeHiResChecked) {
      fakeHiResChecked = true;
      switch (await _replaceFakeHiResIfNeeded(requestTrack)) {
        case _FakeHiResOutcome.completed:
          return true;
        case _FakeHiResOutcome.aborted:
          return false;
        case _FakeHiResOutcome.kept:
          break;
      }
    }

    final deferredSafPublish =
        effectiveSafMode &&
        result.deferredSafPublish &&
        filePath != null &&
        !isContentUri(filePath!);
    if (!deferredSafPublish) {
      await _recoverSafUriIfNeeded();
    }
    stageCompleted('resolve storage');

    final hookInput = filePath;
    if (hookInput != null) {
      final postProcessedPath = await n._runPostProcessingHooks(
        hookInput,
        trackToDownload,
        item.id,
      );
      if (postProcessedPath != null && postProcessedPath.isNotEmpty) {
        if (deferredSafPublish && postProcessedPath != hookInput) {
          final output = File(postProcessedPath);
          if (!await output.exists() || await output.length() <= 0) {
            throw StateError('Post-processing output missing or empty');
          }
          await deleteFile(hookInput);
        }
        filePath = postProcessedPath;
        result.filePath = postProcessedPath;
      }
      if (await _shouldAbort(
        'during post-processing',
        deleteFileOnAbort: wasExisting ? null : filePath,
      )) {
        if (!wasExisting && filePath != hookInput) {
          await deleteFile(hookInput);
        }
        return false;
      }
    }

    final autoConvertInput = filePath;
    stageCompleted('extension hooks');
    if (!wasExisting && autoConvertInput != null) {
      final outcome = await n._autoConvertDownloadedFile(
        itemId: item.id,
        filePath: autoConvertInput,
        fileName: finalSafFileName ?? result.fileName,
        currentQuality: actualQuality,
        settings: settings,
        track: trackToDownload,
        result: result,
        downloadService: item.service,
        storageMode: effectiveSafMode ? 'saf' : 'app',
        downloadTreeUri: settings.downloadTreeUri,
        safRelativeDir: effectiveOutputDir,
      );
      filePath = outcome.filePath;
      finalSafFileName = outcome.fileName;
      actualQuality = outcome.quality;
      if (outcome.converted) probedFinalMetadata = null;
    }
    stageCompleted('automatic conversion');

    final variantInput = filePath;
    if (variantInput != null && item.preserveQualityVariant) {
      final variantOutcome = await n._finalizeQualityVariantFilename(
        item: item,
        result: result,
        filePath: variantInput,
        storageMode: effectiveSafMode ? 'saf' : 'app',
        downloadTreeUri: settings.downloadTreeUri,
        safRelativeDir: effectiveOutputDir,
        fileName: finalSafFileName ?? safFileName,
        collisionOnly: qualityVariantCollisionOnly,
      );
      filePath = variantOutcome.filePath;
      if (variantOutcome.fileName != null) {
        finalSafFileName = variantOutcome.fileName;
      }
      if (variantOutcome.metadata != null) {
        probedFinalMetadata = variantOutcome.metadata;
      }
    }
    stageCompleted('quality filename');

    if (normalizeOptionalString(filePath) == null) {
      throw StateError(
        'Download backend reported success without a final file path',
      );
    }

    if (originalHiResPath != null &&
        !await HiResCheckService.replacementPreservesAudio(
          originalHiResPath,
          filePath!,
        )) {
      throw StateError(
        'Finalized replacement no longer preserves the original audio',
      );
    }

    if (await _shouldAbort(
      'before publishing finalized audio',
      deleteFileOnAbort: wasExisting ? null : filePath,
    )) {
      return false;
    }

    if (deferredSafPublish && !await _publishDeferredSafOutputOnce()) {
      throw StateError('Failed to publish deferred SAF output');
    }
    stageCompleted('publish audio');

    final lrcTarget = filePath;
    if (lrcTarget != null &&
        (!wasExisting || (effectiveSafMode && isContentUri(lrcTarget)))) {
      externalLrcWritten = await n._saveExternalLrc(
        result: result,
        settings: settings,
        extensionState: extensionState,
        track: trackToDownload,
        service: item.service,
        filePath: lrcTarget,
        storageMode: effectiveSafMode ? 'saf' : 'app',
        downloadTreeUri: settings.downloadTreeUri,
        safRelativeDir: effectiveOutputDir,
        resolveBaseName: () async {
          final currentFinalName = finalSafFileName;
          return currentFinalName != null
              ? currentFinalName.replaceFirst(RegExp(r'\.[^.]+$'), '')
              : safBaseName ??
                    await PlatformBridge.sanitizeFilename(
                      '${trackToDownload.artistName} - ${trackToDownload.name}',
                    );
        },
        onFetchError: (e) =>
            _log.w('Failed to fetch lyrics for external LRC: $e'),
      );
    }

    final rgPath = filePath;
    stageCompleted('external lyrics');
    if (wasExisting &&
        rgPath != null &&
        !isNetworkDownload &&
        settings.embedReplayGain) {
      // A retry after history persistence failed may reuse the finished file.
      // retryItem purges the old scan, and normal metadata embedding is skipped
      // for existing files, so recover the measurement for this attempt.
      try {
        final scan = await ReplayGainService.scanAndApplyToFile(rgPath);
        if (scan != null) {
          n._storeTrackReplayGainForAlbum(trackToDownload, rgPath, scan);
        }
      } catch (e) {
        _log.w('Could not recover ReplayGain for existing download: $e');
      }
    }
    // Album ReplayGain: update the accumulator path to the final file
    // location.  For SAF downloads the metadata was embedded on a temp
    // copy, so the stored path still points there.  Replace it with the
    // actual output path (SAF content URI or local path) so the later
    // album-gain writer targets the correct file.
    if (rgPath != null && !isNetworkDownload) {
      n._updateAlbumRgFilePath(trackToDownload, rgPath);
    }
    await _persistCompletionAndNotify();
    stageCompleted('quality probe, history and notification');
    return true;
  }

  Future<bool> _decryptIfNeeded() async {
    final path = filePath;
    final descriptor = result.decryption;
    if (wasExisting || descriptor == null || path == null) {
      return true;
    }
    _log.i(
      'Encrypted stream detected, decrypting via ${descriptor.normalizedStrategy}...',
    );
    n.updateItemStatus(item.id, DownloadStatus.finalizing, progress: 0.9);

    final isSafSource = effectiveSafMode && isContentUri(path);
    final decryptOutcome = await n._fileFinalizer.decrypt(
      result: result,
      filePath: path,
      useSaf: effectiveSafMode,
      treeUri: settings.downloadTreeUri,
      relativeDir: effectiveOutputDir,
      baseName: safBaseName ?? 'track',
      extensionFallback: '.flac',
      repairContainer: true,
    );
    if (decryptOutcome.path == null) {
      final String errorMsg;
      switch (decryptOutcome.failure) {
        case DownloadDecryptionFailure.safAccess:
          _log.e('Failed to copy encrypted SAF file to temp for decrypt');
          errorMsg = 'Failed to access encrypted SAF file';
          break;
        case DownloadDecryptionFailure.safWrite:
          _log.e('Failed to write decrypted stream back to SAF');
          errorMsg = 'Failed to write decrypted file to storage';
          break;
        default:
          _log.e(
            isSafSource
                ? 'FFmpeg decrypt failed for SAF file'
                : 'FFmpeg decrypt failed for local file',
          );
          errorMsg = 'Failed to decrypt encrypted stream';
          break;
      }
      n.updateItemStatus(
        item.id,
        DownloadStatus.failed,
        error: errorMsg,
        errorType: DownloadErrorType.unknown,
      );
      return false;
    }
    filePath = decryptOutcome.path;
    if (decryptOutcome.fileName != null) {
      finalSafFileName = decryptOutcome.fileName;
    }
    _log.i(
      isSafSource ? 'SAF decryption completed' : 'Local decryption completed',
    );
    return true;
  }

  Future<void> _applyFormatHandling(String actualService) async {
    final path = filePath;
    if (path == null) return;
    final isContentUriPath = isContentUri(path);
    final mimeType = isContentUriPath ? await n._getSafMimeType(path) : null;
    final isM4aFile =
        (path.endsWith('.m4a') ||
        path.endsWith('.mp4') ||
        resultOutputExt == '.m4a' ||
        resultOutputExt == '.mp4' ||
        (mimeType != null && mimeType.contains('mp4')));
    final isFlacFile =
        (path.endsWith('.flac') ||
        resultOutputExt == '.flac' ||
        (mimeType != null && mimeType.contains('flac')));
    final shouldForceDashSafM4aHandling =
        !wasExisting &&
        isContentUriPath &&
        effectiveSafMode &&
        n._downloadProviderReplacesLegacyProvider(actualService, 'tidal') &&
        path.endsWith('.flac') &&
        (mimeType == null || mimeType.contains('flac'));

    if (shouldForceDashSafM4aHandling) {
      _log.w(
        'SAF file is labeled FLAC but backend returned an M4A stream; converting it back to FLAC.',
      );
    }

    if (isM4aFile || shouldForceDashSafM4aHandling) {
      if (isContentUriPath && effectiveSafMode) {
        if (shouldPreserveNativeM4a) {
          await _preserveSafNativeM4a(path);
        } else {
          await _convertSafM4aToFlac(path);
        }
      } else {
        if (shouldPreserveNativeM4a) {
          await _preserveLocalNativeM4a(path);
        } else {
          await _convertLocalM4aToFlac(path);
        }
      }
    } else if (metadataEmbeddingEnabled &&
        isContentUriPath &&
        effectiveSafMode &&
        !isM4aFile &&
        !wasExisting) {
      await _embedSafNonM4a(path);
    } else if (metadataEmbeddingEnabled &&
        !isContentUriPath &&
        isFlacFile &&
        !wasExisting) {
      await _embedLocalFlac(path);
    } else if (metadataEmbeddingEnabled &&
        !isContentUriPath &&
        !isFlacFile &&
        !isM4aFile &&
        !wasExisting) {
      final isOpus =
          path.toLowerCase().endsWith('.opus') ||
          path.toLowerCase().endsWith('.ogg') ||
          resultOutputExt == '.opus' ||
          resultOutputExt == '.ogg';
      final isMp3 =
          path.toLowerCase().endsWith('.mp3') || resultOutputExt == '.mp3';
      if (isOpus || isMp3) {
        await _embedFinalMetadata(
          path,
          format: isOpus ? 'opus' : 'mp3',
          writeExternalLrc: false,
        );
      }
    }
  }

  void _markFinalOutputAsFlac() {
    final path = filePath;
    String? name;
    if (path != null) {
      name = finalizedAudioFileName(
        fileName: effectiveSafMode
            ? (finalSafFileName ?? safFileName ?? result.fileName ?? 'track')
            : File(path).uri.pathSegments.last,
        localPath: path,
        fallbackExtension: '.flac',
      );
      if (effectiveSafMode) finalSafFileName = name;
    }
    result.markFlacContainer(path: path, name: name);
    resultOutputExt = '.flac';
  }

  Future<bool> _publishDeferredSafOutputOnce() async {
    final localPath = filePath;
    if (localPath == null || isContentUri(localPath)) return true;
    final localFile = File(localPath);
    if (!await localFile.exists()) return false;
    final localSize = await localFile.length();
    if (localSize <= 0) return false;
    _log.d('Publishing finalized SAF output ($localSize bytes)');

    var finalName =
        normalizeOptionalString(finalSafFileName) ??
        normalizeOptionalString(result['file_name']?.toString()) ??
        normalizeOptionalString(safFileName) ??
        (localFile.uri.pathSegments.isEmpty
            ? 'track$safOutputExt'
            : localFile.uri.pathSegments.last);
    finalName = finalizedAudioFileName(
      fileName: finalName,
      localPath: localPath,
      fallbackExtension:
          result.outputExtension(path: localPath) ?? safOutputExt,
    );
    final localExt = finalName.substring(finalName.lastIndexOf('.'));

    final measured = probedFinalMetadata;
    final qualityLabel = buildQualityVariantFilenameLabel(
      detectedFormat:
          normalizeAudioFormatValue(
            measured?['audio_codec']?.toString() ??
                measured?['format']?.toString(),
          ) ??
          normalizeAudioFormatValue(
            result['audio_codec']?.toString() ?? result['format']?.toString(),
          ),
      bitDepth: readPositiveInt(
        measured?['bit_depth'] ?? result['actual_bit_depth'],
      ),
      sampleRate: readPositiveInt(
        measured?['sample_rate'] ?? result['actual_sample_rate'],
      ),
      bitrateKbps: readPositiveBitrateKbps(
        measured?['bitrate'] ??
            measured?['bit_rate'] ??
            result['bitrate'] ??
            result['actual_bitrate'],
      ),
      measuredQuality: actualQuality,
    );

    String? publishedUri;
    String? publishedName;
    var alreadyExists = false;
    if (item.preserveQualityVariant && qualityVariantCollisionOnly) {
      final logicalName = finalizedAudioFileName(
        fileName: safFileName ?? finalName,
        localPath: localPath,
        fallbackExtension: localExt,
      );
      final stagingLabel = qualityVariantStagingLabel(item.id);
      final cleanName = removeQualityVariantStagingLabel(
        fileName: logicalName,
        stagingLabel: stagingLabel,
      );
      final variantName = qualityLabel == null
          ? finalName
          : applyQualityVariantFilenameLabel(
              fileName: logicalName,
              stagingLabel: stagingLabel,
              qualityLabel: qualityLabel,
            );
      final published = await n._writeTempToSafCollisionAware(
        treeUri: settings.downloadTreeUri,
        relativeDir: effectiveOutputDir,
        cleanFileName: cleanName,
        variantFileName: variantName,
        mimeType: n._mimeTypeForExt(localExt),
        srcPath: localPath,
        preservedSuffix: qualityLabel ?? '',
      );
      publishedUri = published?.uri;
      publishedName = published?.fileName;
    } else if (item.preserveQualityVariant) {
      final published = await n._writeTempToSafUnique(
        treeUri: settings.downloadTreeUri,
        relativeDir: effectiveOutputDir,
        fileName: finalName,
        mimeType: n._mimeTypeForExt(localExt),
        srcPath: localPath,
        preservedSuffix: qualityLabel ?? '',
      );
      publishedUri = published?.uri;
      publishedName = published?.fileName;
    } else {
      final published = await n._writeTempToSafIfAbsent(
        treeUri: settings.downloadTreeUri,
        relativeDir: effectiveOutputDir,
        fileName: finalName,
        mimeType: n._mimeTypeForExt(localExt),
        srcPath: localPath,
      );
      publishedUri = published?.uri;
      publishedName = published?.fileName;
      alreadyExists = published?.alreadyExists == true;
    }
    if (publishedUri == null || publishedName == null) return false;

    try {
      await localFile.delete();
    } catch (_) {}
    filePath = publishedUri;
    finalSafFileName = publishedName;
    wasExisting = alreadyExists;
    result['file_path'] = publishedUri;
    result['file_name'] = publishedName;
    result['saf_deferred_published'] = true;
    if (alreadyExists) {
      result['already_exists'] = true;
      result['message'] = 'File already exists';
    }
    _log.i('Published finalized SAF output once: $publishedName');
    return true;
  }

  Future<void> _preserveSafNativeM4a(String currentFilePath) async {
    // Preserve explicitly requested M4A/MP4 output, including spatial audio.
    _log.d('M4A/MP4 file detected (SAF), preserving native container...');
    final preserveExt = currentFilePath.toLowerCase().endsWith('.mp4')
        ? '.mp4'
        : '.m4a';
    final newFileName = '${safBaseName ?? 'track'}$preserveExt';
    var opStarted = false;
    try {
      final newUri = await n._replaceSafFileVia(
        uri: currentFilePath,
        treeUri: settings.downloadTreeUri,
        relativeDir: effectiveOutputDir,
        op: (tempPath, _) async {
          opStarted = true;
          if (metadataEmbeddingEnabled) {
            n.updateItemStatus(
              item.id,
              DownloadStatus.finalizing,
              progress: 0.99,
            );
            await _embedFinalMetadata(
              tempPath,
              format: 'm4a',
              writeExternalLrc: false,
            );
          }
          return (tempPath, newFileName);
        },
      );

      if (newUri != null) {
        filePath = newUri;
        finalSafFileName = newFileName;
      } else if (opStarted) {
        _log.w('Failed to write M4A to SAF, keeping original');
      }
    } catch (e) {
      _log.w('SAF native M4A handling failed: $e');
    }
  }

  Future<void> _convertSafM4aToFlac(String currentFilePath) async {
    _log.d('M4A file detected (SAF), converting to FLAC...');
    String? branch;
    String? producedFileName;
    try {
      final newUri = await n._replaceSafFileVia(
        uri: currentFilePath,
        treeUri: settings.downloadTreeUri,
        relativeDir: effectiveOutputDir,
        op: (tempPath, addCleanup) async {
          final length = await File(tempPath).length();
          if (length < 1024) {
            _log.w('Temp M4A is too small (<1KB), skipping conversion');
            branch = 'skip';
            return null;
          }
          final codec = await FFmpegProbe.audioCodec(tempPath);
          final isAlreadyNativeFlac =
              codec == 'flac' && await FFmpegProbe.isNativeFlacFile(tempPath);
          final shouldAttemptConversion =
              shouldAttemptLosslessContainerConversion(
                forceConversion: forceContainerConversion,
                probedCodec: codec,
              );
          if (!shouldAttemptConversion) {
            _log.d(
              'Preserving native container; audio codec is ${codec ?? 'unknown'}, '
              'no FLAC container conversion needed.',
            );
            branch = 'preserve';
            final preserveExt = resultOutputExt == '.mp4' ? '.mp4' : '.m4a';
            final newFileName = '${safBaseName ?? 'track'}$preserveExt';
            producedFileName = newFileName;
            if (metadataEmbeddingEnabled) {
              await _embedFinalMetadata(
                tempPath,
                format: 'm4a',
                writeExternalLrc: false,
              );
            }
            return (tempPath, newFileName);
          } else if (isAlreadyNativeFlac) {
            _log.d(
              'Native FLAC payload detected in SAF temp file; '
              'publishing as FLAC and embedding metadata.',
            );
            branch = 'nativeFlac';
            await _embedFinalMetadata(
              tempPath,
              format: 'flac',
              writeExternalLrc: false,
            );

            final newFileName = '${safBaseName ?? 'track'}.flac';
            producedFileName = newFileName;
            return (tempPath, newFileName);
          } else {
            n.updateItemStatus(
              item.id,
              DownloadStatus.finalizing,
              progress: 0.95,
            );
            final flacPath = await FFmpegConversion.convertM4aToFlac(
              tempPath,
              sourceCodec: codec,
            );
            if (flacPath == null) {
              _log.w('FFmpeg conversion returned null, keeping M4A file');
              branch = 'convertFailed';
              return null;
            }
            addCleanup(flacPath);
            _log.d('Converted to FLAC (temp): $flacPath');
            _log.d('Embedding metadata and cover to converted FLAC...');
            await _embedFinalMetadata(
              flacPath,
              format: 'flac',
              writeExternalLrc: false,
            );

            final newFileName = '${safBaseName ?? 'track'}.flac';
            branch = 'convert';
            producedFileName = newFileName;
            return (flacPath, newFileName);
          }
        },
      );

      if (newUri != null) {
        filePath = newUri;
        finalSafFileName = producedFileName;
        if (branch == 'nativeFlac' || branch == 'convert') {
          _markFinalOutputAsFlac();
        }
      } else if (branch == 'nativeFlac') {
        _log.w('Failed to write native FLAC to SAF');
      } else if (branch == 'convert') {
        _log.w('Failed to write FLAC to SAF, keeping M4A');
      }
    } catch (e) {
      _log.w('SAF M4A->FLAC conversion failed: $e');
    }
  }

  Future<void> _preserveLocalNativeM4a(String currentFilePath) async {
    _log.d('M4A/MP4 file detected, preserving native container...');

    try {
      var targetPath = currentFilePath;
      final file = File(targetPath);
      if (!await file.exists()) {
        _log.e('File does not exist at path: $filePath');
      } else {
        if (!(targetPath.toLowerCase().endsWith('.m4a') ||
            targetPath.toLowerCase().endsWith('.mp4'))) {
          final renamedPath = targetPath.replaceAll(
            RegExp(r'\.[^.]+$'),
            '.m4a',
          );
          final finalRenamedPath = renamedPath == targetPath
              ? '$targetPath.m4a'
              : renamedPath;
          await file.rename(finalRenamedPath);
          targetPath = finalRenamedPath;
        }
        filePath = targetPath;

        if (metadataEmbeddingEnabled) {
          n.updateItemStatus(
            item.id,
            DownloadStatus.finalizing,
            progress: 0.99,
          );
          await _embedFinalMetadata(targetPath, format: 'm4a');
        }
      }
    } catch (e) {
      _log.w('Native M4A handling failed: $e');
    }
  }

  Future<void> _convertLocalM4aToFlac(String currentFilePath) async {
    _log.d('M4A file detected, attempting conversion to FLAC...');

    try {
      final file = File(currentFilePath);
      if (!await file.exists()) {
        _log.e('File does not exist at path: $filePath');
      } else {
        final length = await file.length();
        _log.i('File size before conversion: ${length / 1024} KB');

        if (length < 1024) {
          _log.w(
            'File is too small (<1KB), skipping conversion. Download might be corrupt.',
          );
        } else {
          final codec = await FFmpegProbe.audioCodec(currentFilePath);
          final isAlreadyNativeFlac =
              codec == 'flac' &&
              await FFmpegProbe.isNativeFlacFile(currentFilePath);
          final shouldAttemptConversion =
              shouldAttemptLosslessContainerConversion(
                forceConversion: forceContainerConversion,
                probedCodec: codec,
              );
          if (!shouldAttemptConversion) {
            _log.d(
              'Preserving native container; audio codec is ${codec ?? 'unknown'}, '
              'no FLAC container conversion needed.',
            );
            await _preserveLocalNativeM4a(currentFilePath);
          } else if (isAlreadyNativeFlac) {
            _log.d(
              'Native FLAC payload detected; ensuring .flac '
              'extension and embedding metadata.',
            );
            final flacPath = await FFmpegConversion.ensureNativeFlacExtension(
              currentFilePath,
            );
            filePath = flacPath;

            await _embedFinalMetadata(flacPath, format: 'flac');
            _markFinalOutputAsFlac();
          } else {
            n.updateItemStatus(
              item.id,
              DownloadStatus.finalizing,
              progress: 0.95,
            );
            final flacPath = await FFmpegConversion.convertM4aToFlac(
              currentFilePath,
              sourceCodec: codec,
            );

            if (flacPath != null) {
              filePath = flacPath;
              _markFinalOutputAsFlac();
              _log.d('Converted to FLAC: $flacPath');

              _log.d('Embedding metadata and cover to converted FLAC...');
              await _embedFinalMetadata(flacPath, format: 'flac');
            } else {
              _log.w('FFmpeg conversion returned null, keeping M4A file');
            }
          }
        }
      }
    } catch (e) {
      _log.w('FFmpeg conversion process failed: $e, keeping M4A file');
    }
  }

  Future<void> _embedSafNonM4a(String currentFilePath) async {
    final isOpusFile =
        currentFilePath.endsWith('.opus') ||
        currentFilePath.endsWith('.ogg') ||
        resultOutputExt == '.opus' ||
        resultOutputExt == '.ogg';
    final isMp3File =
        currentFilePath.endsWith('.mp3') || resultOutputExt == '.mp3';
    final (ext, formatName) = isOpusFile
        ? (resultOutputExt == '.ogg' ? '.ogg' : '.opus', 'Opus')
        : isMp3File
        ? ('.mp3', 'MP3')
        : ('.flac', 'FLAC');
    // MP3 takes precedence for the embed format when both checks match.
    final embedFormat = isMp3File
        ? 'mp3'
        : isOpusFile
        ? 'opus'
        : 'flac';
    _log.d(
      'SAF $formatName detected, embedding metadata and cover via temp file...',
    );
    final newFileName = '${safBaseName ?? 'track'}$ext';
    var opStarted = false;
    try {
      final newUri = await n._replaceSafFileVia(
        uri: currentFilePath,
        treeUri: settings.downloadTreeUri,
        relativeDir: effectiveOutputDir,
        op: (tempPath, _) async {
          opStarted = true;
          n.updateItemStatus(
            item.id,
            DownloadStatus.finalizing,
            progress: 0.99,
          );

          // writeExternalLrc: false — tempPath lives in the cache dir,
          // so a sidecar .lrc written next to it would be orphaned;
          // the SAF .lrc is written by _saveExternalLrc after publish,
          // reusing the LRC fetched here via result['lyrics_lrc'].
          final fetchedLrc = await _embedFinalMetadata(
            tempPath,
            format: embedFormat,
            writeExternalLrc: false,
          );
          final existingLrc = result['lyrics_lrc'] as String?;
          if ((existingLrc == null || existingLrc.isEmpty) &&
              fetchedLrc != null &&
              fetchedLrc.isNotEmpty) {
            result['lyrics_lrc'] = fetchedLrc;
          }

          // Probe quality from the local temp now: the same probe on
          // the published content:// URI would copy the whole file
          // out of SAF again just to read a few header bytes.
          try {
            probedFinalMetadata = await PlatformBridge.readFileMetadata(
              tempPath,
            );
          } catch (_) {}

          return (tempPath, newFileName);
        },
      );

      if (newUri != null) {
        filePath = newUri;
        finalSafFileName = newFileName;
        _log.d('SAF $formatName metadata embedding completed');
      } else if (opStarted) {
        _log.w('Failed to write metadata-updated $formatName back to SAF');
      }
    } catch (e) {
      _log.w('SAF $formatName metadata embedding failed: $e');
    }
  }

  Future<void> _embedLocalFlac(String currentFilePath) async {
    _log.d('Local FLAC detected, embedding metadata and cover...');
    try {
      n.updateItemStatus(item.id, DownloadStatus.finalizing, progress: 0.99);

      await _embedFinalMetadata(
        currentFilePath,
        format: 'flac',
        writeExternalLrc: false,
      );
      _log.d('Local FLAC metadata embedding completed');
    } catch (e) {
      _log.w('Local FLAC metadata embedding failed: $e');
    }
  }

  /// Final metadata embed shared by every publish branch. Backend-provided
  /// genre/label/copyright win over the Deezer extended-metadata lookup.
  Future<String?> _embedFinalMetadata(
    String path, {
    required String format,
    bool writeExternalLrc = false,
  }) async {
    final track = buildTrackForMetadataEmbedding(
      trackToDownload,
      result,
      resolvedAlbumArtist,
    );
    final lrcContent = await n._embedMetadataToFile(
      path,
      track,
      format: format,
      genre: (result['genre'] as String?) ?? genre,
      label: (result['label'] as String?) ?? label,
      copyright: result['copyright'] as String?,
      comment: result['comment'] as String?,
      lyricsLrc: result['lyrics_lrc'] as String?,
      downloadService: item.service,
      writeExternalLrc: writeExternalLrc,
    );
    if (lrcContent != null && lrcContent.isNotEmpty) {
      result['lyrics_lrc'] = lrcContent;
    }
    return lrcContent;
  }

  Future<void> _recoverSafUriIfNeeded() async {
    final path = filePath;
    if (!effectiveSafMode ||
        path == null ||
        path.isEmpty ||
        isContentUri(path) ||
        settings.downloadTreeUri.isEmpty) {
      return;
    }
    final fallbackName = (finalSafFileName ?? safFileName ?? '').trim();
    if (fallbackName.isNotEmpty) {
      try {
        final resolved = await PlatformBridge.resolveSafFile(
          treeUri: settings.downloadTreeUri,
          relativeDir: effectiveOutputDir,
          fileName: fallbackName,
        );
        final resolvedUri = (resolved['uri'] as String? ?? '').trim();
        final resolvedRelativeDir = (resolved['relative_dir'] as String? ?? '')
            .trim();
        if (resolvedUri.isNotEmpty && isContentUri(resolvedUri)) {
          _log.w('Recovered SAF URI from transient path: $path');
          filePath = resolvedUri;
          finalSafFileName = fallbackName;
          if (resolvedRelativeDir.isNotEmpty) {
            effectiveOutputDir = resolvedRelativeDir;
          }
        } else {
          _log.w(
            'Failed to recover SAF URI (fileName=$fallbackName, dir=$effectiveOutputDir)',
          );
        }
      } catch (e) {
        _log.w('SAF URI recovery failed: $e');
      }
    } else {
      _log.w(
        'SAF download returned non-URI path without filename metadata: $filePath',
      );
    }
  }

  Future<void> _persistCompletionAndNotify() async {
    final path = filePath;
    final historyNotifier = n.ref.read(downloadHistoryProvider.notifier);
    final existingInHistory = path == null
        ? null
        : await historyNotifier.getByFilePathAsync(path);

    if (wasExisting && existingInHistory != null) {
      _log.i(
        'Track file already exists in library; refreshing its history metadata',
      );
    }

    if (path != null) {
      var historyFilePath = path;
      final audio = await resolveDownloadCompletionAudio(
        result: result,
        filePath: path,
        fileName: finalSafFileName,
        quality: actualQuality,
        metadata: probedFinalMetadata,
        readMetadata: PlatformBridge.readFileMetadata,
        debug: _log.d,
      );
      actualQuality = audio.quality;
      probedFinalMetadata = audio.metadata;
      final backendGenre = result['genre'] as String?;
      final backendLabel = result['label'] as String?;
      final backendCopyright = result['copyright'] as String?;
      final effectiveGenre =
          normalizeOptionalString(backendGenre) ??
          normalizeOptionalString(genre) ??
          normalizeOptionalString(existingInHistory?.genre);
      final effectiveLabel =
          normalizeOptionalString(backendLabel) ??
          normalizeOptionalString(label) ??
          normalizeOptionalString(existingInHistory?.label);
      final effectiveCopyright =
          normalizeOptionalString(backendCopyright) ??
          normalizeOptionalString(copyright) ??
          normalizeOptionalString(existingInHistory?.copyright);

      final lyricsAvailability = await n._resolveFinalLyricsAvailability(
        filePath: historyFilePath,
        probedMetadata: probedFinalMetadata,
        externalLrcWritten: externalLrcWritten,
      );

      if (isNetworkDownload) {
        final staging = NetworkDownloadStaging.instance;
        await staging.prepareCompletion(
          id: item.id,
          localPath: path,
          folder: item.networkDownloadFolder,
          relativeDir: networkRelativeDir,
          quality: actualQuality,
          track: trackToDownload.toJson(),
          externalLrcWritten: externalLrcWritten,
          result: result,
        );
        void checkpoint() {
          if (n._findItemById(item.id) == null ||
              n._isLocallyCancelled(item.id) ||
              n._isPausePending(item.id)) {
            throw StateError('Network upload interrupted');
          }
        }

        n.updateItemStatus(
          item.id,
          DownloadStatus.finalizing,
          progress: 0.99,
          preparationStage: 'network_upload',
        );
        var lastProgress = DateTime.fromMillisecondsSinceEpoch(0);
        historyFilePath = await staging.publish(
          item.id,
          checkpoint: checkpoint,
          progress: (sent, total) {
            final now = DateTime.now();
            if (sent != total &&
                now.difference(lastProgress).inMilliseconds < 250) {
              return;
            }
            lastProgress = now;
            n.updateItemStatus(
              item.id,
              DownloadStatus.finalizing,
              progress: 0.99,
              preparationStage: 'network_upload',
              bytesReceived: sent,
              bytesTotal: total,
            );
          },
        );
      }

      await n._saveDownloadedMotionArtwork(
        n.ref,
        item,
        trackToDownload,
        result,
      );
      await persistBeforePublishingDownloadCompletion(
        persist: () async {
          if (!settings.saveDownloadHistory) return;
          await n.ref
              .read(downloadHistoryProvider.notifier)
              .addToHistory(
                n._historyItemFromResult(
                  item: item,
                  trackToDownload: trackToDownload,
                  result: result,
                  filePath: historyFilePath,
                  quality: actualQuality,
                  useSaf: effectiveSafMode,
                  downloadTreeUri: settings.downloadTreeUri,
                  safRelativeDir: effectiveOutputDir,
                  safFileName: finalSafFileName ?? safFileName,
                  bitDepth: audio.bitDepth,
                  sampleRate: audio.sampleRate,
                  bitrate: audio.bitrate,
                  format: audio.format,
                  genre: effectiveGenre,
                  label: effectiveLabel,
                  copyright: effectiveCopyright,
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
          n._completedInSession++;
          n.updateItemStatus(
            item.id,
            DownloadStatus.completed,
            progress: 1.0,
            filePath: historyFilePath,
          );
        },
      );
      // Only durable completions can unblock an album. Checking while this
      // item is still finalizing makes the final track block its own album.
      if (!isNetworkDownload) {
        await n._checkAndWriteAlbumReplayGain(trackToDownload);
      }
      try {
        await n._notificationService.showDownloadComplete(
          trackName: item.track.name,
          artistName: item.track.artistName,
          completedCount: n._completedInSession,
          totalCount: n._totalQueuedAtStart,
          alreadyInLibrary: wasExisting,
        );
      } catch (e) {
        // Audio and history are already committed. A notification failure
        // must not roll back a valid replacement or its persisted history.
        _log.w('Download completed but notification failed: $e');
      }
      if (isNetworkDownload) {
        n._purgeAlbumRgEntry(trackToDownload);
        try {
          await NetworkDownloadStaging.instance.discard(item.id);
        } catch (e) {
          _log.w('Could not clean uploaded network staging: $e');
        }
      }
      n.removeItem(item.id);
    }
  }

  Future<bool> _handleBackendFailure() async {
    if (await _shouldAbort('after backend failure')) {
      return false;
    }

    final failure = result.failure!;
    final errorMsg = failure.retryMessage;
    final errorTypeStr = failure.backendType;
    if (failure.cancelled) {
      if (n._isPausePending(item.id)) {
        pausedDuringThisRun = true;
        n._requeueItemForPause(item.id);
        _log.i('Download was paused by backend cancellation, re-queueing');
      } else {
        _log.i('Download was cancelled by backend, skipping error handling');
        n.updateItemStatus(item.id, DownloadStatus.skipped);
      }
      return false;
    }

    final backendErrorType = failure.type;
    final errorType =
        backendErrorType ?? n._downloadErrorTypeFromMessage(errorMsg);

    if (errorType == DownloadErrorType.verificationRequired) {
      await n._handleVerificationRequiredDownload(
        item,
        errorMsg,
        failure.service,
      );
      return false;
    }
    if (errorType == DownloadErrorType.rateLimit &&
        await n._handleRateLimitedDownload(item, errorMsg)) {
      return false;
    }

    _log.e('Download failed: $errorMsg (type: $errorTypeStr)');
    n._recordFailedDownload(item.id, error: errorMsg, errorType: errorType);

    try {
      await PlatformBridge.cleanupConnections();
    } catch (e) {
      _log.e('Post-failure connection cleanup failed: $e');
    }
    return true;
  }

  Future<void> _handleRunException(Object e, StackTrace stackTrace) async {
    if (await _shouldAbort('after exception')) {
      return;
    }

    _log.e('Exception: $e', e, stackTrace);

    if (isNetworkDownload) {
      n._recordFailedDownload(
        item.id,
        error: 'Network download failed. Retry keeps prepared audio: $e',
        errorType: DownloadErrorType.unknown,
      );
      return;
    }

    String errorMsg = e.toString();
    DownloadErrorType errorType = DownloadErrorType.unknown;

    if (isStorageWriteFailure(errorMessage: errorMsg) &&
        storageWriteRecoveryFor(useSaf: n._isSafMode(settings)) ==
            StorageWriteRecovery.requestSafAccess) {
      errorMsg = safPermissionLostErrorMessage;
      errorType = DownloadErrorType.permission;
    } else if (isStorageWriteFailure(errorMessage: errorMsg)) {
      try {
        await n._activateAppFolderStorageFallback(
          failedOutputDir: effectiveOutputDir.isNotEmpty
              ? effectiveOutputDir
              : n.state.outputDir,
        );
        n.updateItemStatus(item.id, DownloadStatus.queued, progress: 0.0);
        _log.w(
          'Storage exception recovered; re-queued ${item.track.name} in the app folder',
        );
        return;
      } catch (fallbackError) {
        _log.e(
          'Could not recover storage exception with app-folder fallback: '
          '$fallbackError',
        );
      }
    }

    if (errorType == DownloadErrorType.permission) {
      // Keep the explicit SAF reauthorization error selected above.
    } else if (errorMsg.contains('could not find Deezer equivalent') ||
        errorMsg.contains('track not found on Deezer')) {
      errorMsg = 'Track not found on Deezer (Metadata Unavailable)';
      errorType = DownloadErrorType.notFound;
    } else {
      errorType = n._downloadErrorTypeFromMessage(errorMsg);
    }

    if (errorType == DownloadErrorType.verificationRequired) {
      await n._handleVerificationRequiredDownload(item, errorMsg, item.service);
      return;
    }
    if (errorType == DownloadErrorType.rateLimit &&
        await n._handleRateLimitedDownload(item, errorMsg)) {
      return;
    }

    n._recordFailedDownload(item.id, error: errorMsg, errorType: errorType);

    try {
      await PlatformBridge.cleanupConnections();
    } catch (cleanupErr) {
      _log.e('Post-exception connection cleanup failed: $cleanupErr');
    }
  }
}
