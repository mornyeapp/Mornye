part of 'download_queue_provider.dart';

class _QualityVariantFileOutcome {
  final String filePath;
  final String? fileName;
  final Map<String, dynamic>? metadata;

  const _QualityVariantFileOutcome({
    required this.filePath,
    this.fileName,
    this.metadata,
  });
}

/// AC-4 repair only applies to MP4 containers; decrypt can also emit raw
/// FLAC, which the native MP4 box parser would reject as corrupt.
bool _isMp4Container(String path) {
  final lower = path.toLowerCase();
  return lower.endsWith('.m4a') || lower.endsWith('.mp4');
}

extension _DownloadQueueFinalization on DownloadQueueNotifier {
  DownloadFileFinalizer get _fileFinalizer => DownloadFileFinalizer(
    decryptFile: FFmpegDecryption.decrypt,
    probeCodec: FFmpegProbe.audioCodec,
    repairAc4: (path, source) async {
      await PlatformBridge.ensureAC4Config(path, source);
    },
    convertAudio:
        ({
          required inputPath,
          required targetFormat,
          required bitrate,
          required deleteOriginal,
          required losslessQuality,
        }) => FFmpegConversion.convertAudioFormat(
          inputPath: inputPath,
          targetFormat: targetFormat,
          bitrate: bitrate,
          metadata: const {},
          deleteOriginal: deleteOriginal,
          losslessQuality: losslessQuality,
        ),
    replaceSafFile: _replaceSafFileVia,
    warn: _log.w,
    info: _log.i,
  );

  Future<void> _saveDownloadedMotionArtwork(
    Ref ref,
    DownloadItem item,
    Track track,
    Map<String, dynamic> result,
  ) async {
    // Store independently of history preferences and the selected UI theme.
    // A later switch to Mornye must still work without network access.
    try {
      final album = (
        album:
            _resolveMetadataText(
              track.albumName,
              result['album']?.toString(),
            ) ??
            item.track.albumName,
        artist:
            _resolveMetadataText(
              track.artistName,
              result['artist']?.toString(),
            ) ??
            item.track.artistName,
      );
      final store = ref.read(motionArtworkStoreProvider);
      final artwork = await store.save(
        album,
        resolveSource: () => resolveDownloadMotionArtworkSource(
          original: item.track,
          downloaded: track,
          result: result,
          getMetadata: PlatformBridge.getProviderMetadata,
        ),
      );
      if (artwork != null && ref.mounted) {
        ref.invalidate(playerMotionArtworkProvider(album));
      }
    } catch (error) {
      _log.w('Optional motion artwork was not saved: ${error.runtimeType}');
    }
  }

  Future<DownloadConversionOutcome> _autoConvertDownloadedFile({
    required String itemId,
    required String filePath,
    required String? fileName,
    required String currentQuality,
    required AppSettings settings,
    required Track track,
    required Map<String, dynamic> result,
    required String downloadService,
    required String storageMode,
    String? downloadTreeUri,
    String? safRelativeDir,
  }) => _fileFinalizer.autoConvert(
    result: DownloadResult.fromMap(result),
    filePath: filePath,
    fileName: fileName,
    quality: currentQuality,
    enabled: settings.autoConvertDownloads,
    targetFormat: settings.autoConvertFormat,
    targetBitrate: settings.autoConvertBitrate,
    losslessQuality: LosslessConversionQuality(
      maxBitDepth: settings.autoConvertMaxBitDepth == 0
          ? null
          : settings.autoConvertMaxBitDepth,
      maxSampleRate: settings.autoConvertMaxSampleRate == 0
          ? null
          : settings.autoConvertMaxSampleRate,
    ),
    useSaf: storageMode == 'saf',
    treeUri: downloadTreeUri,
    relativeDir: safRelativeDir ?? '',
    onStart: () =>
        updateItemStatus(itemId, DownloadStatus.finalizing, progress: 0.97),
    embedMetadata: settings.embedMetadata
        ? (path, format) async {
            await _embedMetadataToFile(
              path,
              track,
              format: format,
              genre: result['genre'] as String?,
              label: result['label'] as String?,
              copyright: result['copyright'] as String?,
              comment: result['comment'] as String?,
              lyricsLrc: result['lyrics_lrc'] as String?,
              downloadService: downloadService,
              writeExternalLrc: storageMode != 'saf',
            );
          }
        : null,
  );

  /// Builds the [DownloadHistoryItem] shared by the native-worker and inline
  /// completion paths. Fields whose source/derivation legitimately differs
  /// between the two callers (SAF location, probed vs. raw audio metadata,
  /// genre/label/copyright fallback chain) are left as parameters.
  DownloadHistoryItem _historyItemFromResult({
    required DownloadItem item,
    required Track trackToDownload,
    required Map<String, dynamic> result,
    required String filePath,
    required String quality,
    required bool useSaf,
    String? downloadTreeUri,
    String? safRelativeDir,
    String? safFileName,
    int? bitDepth,
    int? sampleRate,
    int? bitrate,
    String? format,
    String? genre,
    String? label,
    String? copyright,
    required bool hasLyrics,
    required int lyricsMetadataScanVersion,
    required bool hasReplayGain,
    required int replayGainMetadataScanVersion,
  }) {
    final backendTitle = result['title'] as String?;
    final backendArtist = result['artist'] as String?;
    final backendAlbum = result['album'] as String?;
    final backendYear = result['release_date'] as String?;
    final backendTrackNum = readPositiveInt(result['track_number']);
    final backendDiscNum = readPositiveInt(result['disc_number']);
    final backendTotalTracks = readPositiveInt(result['total_tracks']);
    final backendTotalDiscs = readPositiveInt(result['total_discs']);
    final backendISRC = result['isrc'] as String?;
    final backendComposer = result['composer'] as String?;

    final historyTotalTracks = _resolvePositiveMetadataInt(
      trackToDownload.totalTracks,
      backendTotalTracks,
    );
    final historyTotalDiscs = _resolvePositiveMetadataInt(
      trackToDownload.totalDiscs,
      backendTotalDiscs,
    );
    final historyTrackNumber = _resolveMetadataIndex(
      sourceValue: trackToDownload.trackNumber,
      backendValue: backendTrackNum,
      total: historyTotalTracks,
    );
    final historyDiscNumber = _resolveMetadataIndex(
      sourceValue: trackToDownload.discNumber,
      backendValue: backendDiscNum,
      total: historyTotalDiscs,
    );
    final historyTitle =
        _resolveMetadataText(trackToDownload.name, backendTitle) ??
        item.track.name;
    final historyArtist =
        _resolveMetadataText(trackToDownload.artistName, backendArtist) ??
        item.track.artistName;
    final historyAlbum =
        _resolveMetadataText(trackToDownload.albumName, backendAlbum) ??
        item.track.albumName;
    final historyIsrc = _resolveMetadataText(trackToDownload.isrc, backendISRC);
    final historyReleaseDate = _resolveMetadataText(
      trackToDownload.releaseDate,
      backendYear,
    );
    final historyComposer = _resolveMetadataText(
      trackToDownload.composer,
      backendComposer,
    );

    return DownloadHistoryItem(
      id: item.id,
      trackName: historyTitle,
      artistName: historyArtist,
      albumName: historyAlbum,
      albumArtist: normalizeOptionalString(trackToDownload.albumArtist),
      coverUrl: normalizeCoverReference(trackToDownload.coverUrl),
      filePath: filePath,
      storageMode: filePath.startsWith('network://')
          ? 'network'
          : useSaf
          ? 'saf'
          : 'app',
      downloadTreeUri: useSaf ? downloadTreeUri : null,
      safRelativeDir: useSaf ? safRelativeDir : null,
      safFileName: useSaf ? safFileName : null,
      safRepaired: false,
      service: result['service'] as String? ?? item.service,
      downloadedAt: DateTime.now(),
      isrc: historyIsrc,
      spotifyId: trackToDownload.id,
      trackNumber: historyTrackNumber,
      totalTracks: historyTotalTracks,
      discNumber: historyDiscNumber,
      totalDiscs: historyTotalDiscs,
      duration: trackToDownload.duration,
      releaseDate: historyReleaseDate,
      quality: quality,
      bitDepth: bitDepth,
      sampleRate: sampleRate,
      bitrate: bitrate,
      format: format,
      genre: genre,
      composer: historyComposer,
      label: label,
      copyright: copyright,
      explicit:
          trackToDownload.isExplicit ||
          parseExplicitFlag(result['explicit']) == true,
      hasLyrics: hasLyrics,
      lyricsMetadataScanVersion: lyricsMetadataScanVersion,
      hasReplayGain: hasReplayGain,
      replayGainMetadataScanVersion: replayGainMetadataScanVersion,
    );
  }

  Future<
    ({
      bool hasLyrics,
      int scanVersion,
      bool hasReplayGain,
      int replayGainScanVersion,
    })
  >
  _resolveFinalLyricsAvailability({
    required String filePath,
    Map<String, dynamic>? probedMetadata,
    bool externalLrcWritten = false,
  }) async {
    var metadataScanned = false;
    var hasEmbeddedLyrics = false;
    var hasReplayGain = false;
    var replayGainScanVersion = 0;
    try {
      final metadata =
          probedMetadata ?? await PlatformBridge.readFileMetadata(filePath);
      if (replayGainMetadataWasRead(metadata)) {
        hasReplayGain = metadataHasReplayGain(metadata);
        replayGainScanVersion = 1;
      }
      if (metadata['error'] == null &&
          (metadata.containsKey('lyrics') ||
              metadata.containsKey('hasLyrics'))) {
        metadataScanned = true;
        hasEmbeddedLyrics =
            metadata['hasLyrics'] == true ||
            hasUsableLyricsContent(metadata['lyrics']?.toString() ?? '');
      }
    } catch (e) {
      _log.d('Final lyrics metadata probe failed for $filePath: $e');
    }

    var hasSidecarLyrics = externalLrcWritten;
    if (!isContentUri(filePath)) {
      try {
        final lrcPath = filePath.replaceAll(RegExp(r'\.[^.]+$'), '.lrc');
        final safeLrcPath = lrcPath == filePath ? '$filePath.lrc' : lrcPath;
        final sidecar = File(safeLrcPath);
        if (await sidecar.exists()) {
          hasSidecarLyrics = hasUsableLyricsContent(
            await sidecar.readAsString(),
          );
        }
      } catch (e) {
        _log.d('Final sidecar lyrics probe failed for $filePath: $e');
      }
    }

    final hasLyrics = hasEmbeddedLyrics || hasSidecarLyrics;
    return (
      hasLyrics: hasLyrics,
      scanVersion: hasLyrics || metadataScanned ? 1 : 0,
      hasReplayGain: hasReplayGain,
      replayGainScanVersion: replayGainScanVersion,
    );
  }

  Future<String?> _copySafToTemp(String uri) async {
    try {
      return await PlatformBridge.copyContentUriToTemp(uri);
    } catch (e) {
      _log.w('Failed to copy SAF uri to temp: $e');
      return null;
    }
  }

  Future<String?> _writeTempToSaf({
    required String treeUri,
    required String relativeDir,
    required String fileName,
    required String mimeType,
    required String srcPath,
  }) async {
    try {
      return await PlatformBridge.createSafFileFromPath(
        treeUri: treeUri,
        relativeDir: relativeDir,
        fileName: fileName,
        mimeType: mimeType,
        srcPath: srcPath,
      );
    } catch (e) {
      _log.w('Failed to write temp file to SAF: $e');
      return null;
    }
  }

  Future<({String uri, String fileName, bool alreadyExists})?>
  _writeTempToSafIfAbsent({
    required String treeUri,
    required String relativeDir,
    required String fileName,
    required String mimeType,
    required String srcPath,
  }) async {
    try {
      final result = await PlatformBridge.createSafFileIfAbsentFromPath(
        treeUri: treeUri,
        relativeDir: relativeDir,
        fileName: fileName,
        mimeType: mimeType,
        srcPath: srcPath,
      );
      final published = _publishedSafFile(result);
      if (published == null) return null;
      return (
        uri: published.uri,
        fileName: published.fileName,
        alreadyExists: result['already_exists'] == true,
      );
    } catch (e) {
      _log.w('Failed to publish deferred SAF file: $e');
      return null;
    }
  }

  ({String uri, String fileName})? _publishedSafFile(
    Map<String, dynamic> result,
  ) {
    final timings = result['publish_timings_ms'];
    if (timings is Map && timings.isNotEmpty) {
      _log.d('SAF publish timings (ms): $timings');
    }
    final uri = (result['uri'] as String? ?? '').trim();
    final fileName = (result['file_name'] as String? ?? '').trim();
    if (uri.isEmpty || fileName.isEmpty) return null;
    return (uri: uri, fileName: fileName);
  }

  Future<({String uri, String fileName})?> _writeTempToSafUnique({
    required String treeUri,
    required String relativeDir,
    required String fileName,
    required String mimeType,
    required String srcPath,
    String preservedSuffix = '',
  }) async {
    try {
      final result = await PlatformBridge.createUniqueSafFileFromPath(
        treeUri: treeUri,
        relativeDir: relativeDir,
        fileName: fileName,
        mimeType: mimeType,
        srcPath: srcPath,
        preservedSuffix: preservedSuffix,
      );
      return _publishedSafFile(result);
    } catch (e) {
      _log.w('Failed to write unique temp file to SAF: $e');
      return null;
    }
  }

  Future<({String uri, String fileName})?> _writeTempToSafCollisionAware({
    required String treeUri,
    required String relativeDir,
    required String cleanFileName,
    required String variantFileName,
    required String mimeType,
    required String srcPath,
    String preservedSuffix = '',
  }) async {
    try {
      final result = await PlatformBridge.createCollisionAwareSafFileFromPath(
        treeUri: treeUri,
        relativeDir: relativeDir,
        cleanFileName: cleanFileName,
        variantFileName: variantFileName,
        mimeType: mimeType,
        srcPath: srcPath,
        preservedSuffix: preservedSuffix,
      );
      return _publishedSafFile(result);
    } catch (e) {
      _log.w('Failed to write collision-aware temp file to SAF: $e');
      return null;
    }
  }

  Future<bool> _writeLrcToSaf({
    required String treeUri,
    required String relativeDir,
    required String baseName,
    required String lrcContent,
  }) async {
    try {
      if (!hasUsableLyricsContent(lrcContent)) return false;
      final tempDir = await getTemporaryDirectory();
      final tempPath = '${tempDir.path}/$baseName.lrc';
      await File(tempPath).writeAsString(lrcContent);
      final lrcName = '$baseName.lrc';
      final uri = await _writeTempToSaf(
        treeUri: treeUri,
        relativeDir: relativeDir,
        fileName: lrcName,
        mimeType: _mimeTypeForExt('.lrc'),
        srcPath: tempPath,
      );
      if (uri != null) {
        _log.d('External LRC saved to SAF: $lrcName');
      } else {
        _log.w('Failed to write external LRC to SAF');
      }
      try {
        await File(tempPath).delete();
      } catch (_) {}
      return uri != null;
    } catch (e) {
      _log.w('Failed to create external LRC in SAF: $e');
      return false;
    }
  }

  Future<void> _deleteSafFile(String uri) async {
    try {
      await PlatformBridge.safDelete(uri);
    } catch (e) {
      _log.w('Failed to delete SAF file: $e');
    }
  }

  Future<String?> _replaceSafFileVia({
    required String uri,
    required String treeUri,
    required String relativeDir,
    required SafFileOperation op,
    bool avoidOverwrite = false,
    String preservedSuffix = '',
    String? collisionCleanFileName,
    String? collisionVariantFileName,
    void Function(String fileName)? onPublishedFileName,
  }) =>
      DownloadSafFileReplacer(
        copyToTemp: _copySafToTemp,
        deleteSource: _deleteSafFile,
        publish:
            ({
              required treeUri,
              required relativeDir,
              required fileName,
              required srcPath,
              required avoidOverwrite,
              required preservedSuffix,
              collisionCleanFileName,
              collisionVariantFileName,
            }) async {
              final dotIndex = fileName.lastIndexOf('.');
              final ext = dotIndex >= 0 ? fileName.substring(dotIndex) : '';
              if (collisionCleanFileName != null &&
                  collisionVariantFileName != null) {
                return _writeTempToSafCollisionAware(
                  treeUri: treeUri,
                  relativeDir: relativeDir,
                  cleanFileName: collisionCleanFileName,
                  variantFileName: collisionVariantFileName,
                  mimeType: _mimeTypeForExt(ext),
                  srcPath: srcPath,
                  preservedSuffix: preservedSuffix,
                );
              } else if (avoidOverwrite) {
                return _writeTempToSafUnique(
                  treeUri: treeUri,
                  relativeDir: relativeDir,
                  fileName: fileName,
                  mimeType: _mimeTypeForExt(ext),
                  srcPath: srcPath,
                  preservedSuffix: preservedSuffix,
                );
              }
              final newUri = await _writeTempToSaf(
                treeUri: treeUri,
                relativeDir: relativeDir,
                fileName: fileName,
                mimeType: _mimeTypeForExt(ext),
                srcPath: srcPath,
              );
              return newUri == null ? null : (uri: newUri, fileName: fileName);
            },
      ).replace(
        uri: uri,
        treeUri: treeUri,
        relativeDir: relativeDir,
        op: op,
        avoidOverwrite: avoidOverwrite,
        preservedSuffix: preservedSuffix,
        collisionCleanFileName: collisionCleanFileName,
        collisionVariantFileName: collisionVariantFileName,
        onPublishedFileName: onPublishedFileName,
      );

  Future<_QualityVariantFileOutcome> _finalizeQualityVariantFilename({
    required DownloadItem item,
    required Map<String, dynamic> result,
    required String filePath,
    required String storageMode,
    String? downloadTreeUri,
    String? safRelativeDir,
    String? fileName,
    bool collisionOnly = false,
  }) async {
    if (!item.preserveQualityVariant || result['already_exists'] == true) {
      return _QualityVariantFileOutcome(filePath: filePath, fileName: fileName);
    }

    Map<String, dynamic>? metadata;
    try {
      metadata = await PlatformBridge.readFileMetadata(filePath);
      if (metadata['error'] != null) metadata = null;
    } catch (e) {
      _log.d('Quality variant metadata probe failed for $filePath: $e');
    }

    final bitDepth = readPositiveInt(
      metadata?['bit_depth'] ?? result['actual_bit_depth'],
    );
    final sampleRate = readPositiveInt(
      metadata?['sample_rate'] ?? result['actual_sample_rate'],
    );
    final detectedFormat =
        normalizeAudioFormatValue(
          metadata?['audio_codec']?.toString() ??
              metadata?['codec']?.toString() ??
              metadata?['format']?.toString(),
        ) ??
        normalizeAudioFormatValue(
          result['audio_codec']?.toString() ?? result['format']?.toString(),
        ) ??
        normalizeAudioFormatValue(
          audioFormatForPath(filePath, fileName: fileName),
        );
    final bitrateKbps = readPositiveBitrateKbps(
      metadata?['bitrate'] ??
          metadata?['bit_rate'] ??
          result['bitrate'] ??
          result['actual_bitrate'],
    );
    final qualityLabel = buildQualityVariantFilenameLabel(
      detectedFormat: detectedFormat,
      bitDepth: bitDepth,
      sampleRate: sampleRate,
      bitrateKbps: bitrateKbps,
      measuredQuality:
          result['_native_actual_quality']?.toString() ??
          result['quality']?.toString(),
    );
    if (qualityLabel == null) {
      _log.w(
        'Keeping collision-safe temporary quality label because the final '
        'audio specification could not be measured: $filePath',
      );
      return _QualityVariantFileOutcome(
        filePath: filePath,
        fileName: fileName,
        metadata: metadata,
      );
    }

    if (bitDepth != null) result['actual_bit_depth'] = bitDepth;
    if (sampleRate != null) result['actual_sample_rate'] = sampleRate;
    if (detectedFormat != null) result['audio_codec'] = detectedFormat;
    if (bitrateKbps != null) {
      result['bitrate'] = bitrateKbps;
    }

    final stagingLabel = qualityVariantStagingLabel(item.id);
    final localPathSegments = File(filePath).uri.pathSegments;
    final logicalFileName = storageMode == 'saf'
        ? (fileName ?? result['file_name']?.toString() ?? '')
        : (localPathSegments.isEmpty ? '' : localPathSegments.last);
    final outputExtension =
        DownloadResult.fromMap(result).outputExtension(path: filePath) ??
        '.flac';
    // Deferred SAF still points to a local file. Its logical name came from
    // the provider before conversion and must use the finalized container.
    final currentFileName = isContentUri(filePath)
        ? logicalFileName
        : finalizedAudioFileName(
            fileName: logicalFileName,
            localPath: filePath,
            fallbackExtension: outputExtension,
          );
    final variantFileName = applyQualityVariantFilenameLabel(
      fileName: currentFileName,
      stagingLabel: stagingLabel,
      qualityLabel: qualityLabel,
    );
    final cleanFileName = removeQualityVariantStagingLabel(
      fileName: currentFileName,
      stagingLabel: stagingLabel,
    );
    final preferredFileName = variantFileName;
    if (preferredFileName == currentFileName) {
      return _QualityVariantFileOutcome(
        filePath: filePath,
        fileName: fileName,
        metadata: metadata,
      );
    }

    if (storageMode == 'saf' && isContentUri(filePath)) {
      if (downloadTreeUri == null || downloadTreeUri.isEmpty) {
        return _QualityVariantFileOutcome(
          filePath: filePath,
          fileName: fileName,
          metadata: metadata,
        );
      }
      String? publishedFileName;
      final renamedUri = await _replaceSafFileVia(
        uri: filePath,
        treeUri: downloadTreeUri,
        relativeDir: safRelativeDir ?? '',
        avoidOverwrite: !collisionOnly,
        preservedSuffix: qualityLabel,
        collisionCleanFileName: collisionOnly ? cleanFileName : null,
        collisionVariantFileName: collisionOnly ? variantFileName : null,
        onPublishedFileName: (name) => publishedFileName = name,
        op: (tempPath, addCleanup) async => (tempPath, preferredFileName),
      );
      if (renamedUri == null) {
        return _QualityVariantFileOutcome(
          filePath: filePath,
          fileName: fileName,
          metadata: metadata,
        );
      }
      final finalName = publishedFileName ?? preferredFileName;
      result['file_path'] = renamedUri;
      result['file_name'] = finalName;
      return _QualityVariantFileOutcome(
        filePath: renamedUri,
        fileName: finalName,
        metadata: metadata,
      );
    }

    final source = File(filePath);
    final parent = source.parent;
    final cleanTarget = File(
      '${parent.path}${Platform.pathSeparator}$cleanFileName',
    );
    final lockTarget = collisionOnly
        ? cleanTarget
        : File('${parent.path}${Platform.pathSeparator}$preferredFileName');
    return _withQualityVariantFileLock(lockTarget.path, () async {
      final selectedFileName = collisionOnly
          ? resolveQualityVariantFilename(
              fileName: currentFileName,
              stagingLabel: stagingLabel,
              qualityLabel: qualityLabel,
              collisionOnly: true,
              cleanNameExists:
                  cleanTarget.path != source.path && await cleanTarget.exists(),
            )
          : preferredFileName;
      if (selectedFileName == currentFileName) {
        return _QualityVariantFileOutcome(
          filePath: filePath,
          fileName: fileName,
          metadata: metadata,
        );
      }

      var target = File(
        '${parent.path}${Platform.pathSeparator}$selectedFileName',
      );
      var counter = 2;
      while (await target.exists() && target.path != source.path) {
        final dotIndex = selectedFileName.lastIndexOf('.');
        final hasExtension = dotIndex > 0;
        final stem = hasExtension
            ? selectedFileName.substring(0, dotIndex)
            : selectedFileName;
        final extension = hasExtension
            ? selectedFileName.substring(dotIndex)
            : '';
        target = File(
          '${parent.path}${Platform.pathSeparator}$stem ($counter)$extension',
        );
        counter++;
      }
      try {
        final renamed = await source.rename(target.path);
        result['file_path'] = renamed.path;
        final renamedSegments = renamed.uri.pathSegments;
        result['file_name'] = renamedSegments.isEmpty
            ? null
            : renamedSegments.last;
        return _QualityVariantFileOutcome(
          filePath: renamed.path,
          fileName: result['file_name'] as String?,
          metadata: metadata,
        );
      } catch (e) {
        _log.w('Failed to apply measured quality filename: $e');
        return _QualityVariantFileOutcome(
          filePath: filePath,
          fileName: fileName,
          metadata: metadata,
        );
      }
    });
  }

  Future<String?> _finalizeNativeWorkerContainerConversion({
    required _NativeWorkerRequestContext context,
    required DownloadResult result,
    required AppSettings settings,
    required Track track,
    required String filePath,
  }) =>
      DownloadContainerFinalizer(
        probeCodec: FFmpegProbe.audioCodec,
        isNativeFlac: FFmpegProbe.isNativeFlacFile,
        ensureFlacExtension: FFmpegConversion.ensureNativeFlacExtension,
        convertToFlac: FFmpegConversion.convertM4aToFlac,
        replaceSafFile: _replaceSafFileVia,
        debug: _log.d,
      ).finalize(
        result: result,
        filePath: filePath,
        requestedExtension: context.outputExt,
        forceConversion: _shouldRequestContainerConversion(
          context.item.service,
          context.outputExt,
        ),
        useSaf: context.storageMode == 'saf',
        treeUri: context.downloadTreeUri,
        relativeDir: context.safRelativeDir ?? '',
        fallbackFileName: context.safFileName,
        embedMetadata: settings.embedMetadata
            ? (path) async {
                await _embedMetadataToFile(
                  path,
                  track,
                  format: 'flac',
                  genre: result['genre'] as String?,
                  label: result['label'] as String?,
                  copyright: result['copyright'] as String?,
                  comment: result['comment'] as String?,
                  lyricsLrc: result['lyrics_lrc'] as String?,
                  downloadService: context.item.service,
                  writeExternalLrc: context.storageMode != 'saf',
                );
              }
            : null,
      );

  /// Shared external-LRC finalize used by both the inline single-item
  /// pipeline (SAF only; the local-file case is already handled during
  /// metadata embedding) and the native-worker pipeline (both storage
  /// modes). [resolveBaseName] and [onFetchError] are each caller's own
  /// base-name fallback chain and fetch-failure log line, evaluated lazily
  /// to match the original call sites exactly.
  Future<bool> _saveExternalLrc({
    required Map<String, dynamic> result,
    required AppSettings settings,
    required ExtensionState extensionState,
    required Track track,
    required String service,
    required String filePath,
    required String storageMode,
    String? downloadTreeUri,
    required String safRelativeDir,
    required Future<String> Function() resolveBaseName,
    required void Function(Object e) onFetchError,
  }) async {
    final lyricsMode = settings.lyricsMode;
    final shouldSaveExternalLrc =
        settings.embedMetadata &&
        settings.embedLyrics &&
        !DownloadMetadataResolver.shouldSkipLyrics(
          extensionState,
          track.source,
          service,
        ) &&
        (lyricsMode == 'external' || lyricsMode == 'both');
    if (!shouldSaveExternalLrc) {
      return false;
    }

    String? lrcContent = result['lyrics_lrc'] as String?;
    if (!hasUsableLyricsContent(lrcContent ?? '')) {
      try {
        lrcContent = await PlatformBridge.getLyricsLRC(
          track.id,
          track.name,
          track.artistName,
          durationMs: track.duration * 1000,
        );
      } catch (e) {
        onFetchError(e);
      }
    }
    if (!hasUsableLyricsContent(lrcContent ?? '') ||
        isInstrumentalLyricsMarker(lrcContent!)) {
      return false;
    }
    final resolvedLrc = lrcContent;

    if (storageMode == 'saf' && isContentUri(filePath)) {
      if (downloadTreeUri == null || downloadTreeUri.isEmpty) {
        return false;
      }
      final baseName = await resolveBaseName();
      final written = await _writeLrcToSaf(
        treeUri: downloadTreeUri,
        relativeDir: safRelativeDir,
        baseName: baseName,
        lrcContent: resolvedLrc,
      );
      if (written) result['lyrics_lrc'] = resolvedLrc;
      return written;
    }

    try {
      final lrcPath = filePath.replaceAll(RegExp(r'\.[^.]+$'), '.lrc');
      final safeLrcPath = lrcPath == filePath ? '$filePath.lrc' : lrcPath;
      await File(safeLrcPath).writeAsString(resolvedLrc);
      result['lyrics_lrc'] = resolvedLrc;
      _log.d('Native-worker external LRC saved: $safeLrcPath');
      return true;
    } catch (e) {
      _log.w('Failed to save native-worker external LRC: $e');
      return false;
    }
  }
}
