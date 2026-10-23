part of 'track_metadata_screen.dart';

extension _TrackMetadataConvertAndCueSplit on _TrackMetadataScreenState {
  bool get _isConvertibleFormat {
    final lower = cleanFilePath.toLowerCase();
    return lower.endsWith('.flac') ||
        lower.endsWith('.m4a') ||
        lower.endsWith('.aac') ||
        lower.endsWith('.wav') ||
        lower.endsWith('.aiff') ||
        lower.endsWith('.aif') ||
        lower.endsWith('.mp3') ||
        lower.endsWith('.opus') ||
        lower.endsWith('.ogg');
  }

  /// Whether the current file is a CUE sheet (or CUE-referenced)
  bool get _isCueFile {
    if (isCueVirtualPath(rawFilePath)) return true;
    final lower = cleanFilePath.toLowerCase();
    if (lower.endsWith('.cue')) return true;
    if (_isLocalItem && _localLibraryItem != null) {
      final format = _localLibraryItem!.format ?? '';
      if (format.startsWith('cue+')) return true;
    }
    return false;
  }

  String get _currentFileFormat {
    // For CUE tracks, use the format from the library item (e.g. "cue+flac")
    if (_isCueFile && _isLocalItem && _localLibraryItem != null) {
      final format = _localLibraryItem!.format ?? '';
      if (format.startsWith('cue+')) {
        final audioFmt = format.substring(4).toUpperCase();
        return 'CUE+$audioFmt';
      }
    }
    if (_isLocalItem && _localLibraryItem != null) {
      final format = normalizeOptionalString(
        _localLibraryItem!.format,
      )?.toLowerCase().replaceAll('-', '_');
      switch (format) {
        case 'flac':
          return 'FLAC';
        case 'alac':
          return 'ALAC';
        case 'm4a':
          return 'M4A';
        case 'aac':
        case 'mp4a':
          return 'AAC';
        case 'mp3':
          return 'MP3';
        case 'opus':
        case 'ogg':
          return 'Opus';
        case 'wav':
        case 'wave':
          return 'WAV';
        case 'aiff':
        case 'aif':
        case 'aifc':
          return 'AIFF';
      }
    }
    final lower = cleanFilePath.toLowerCase();
    if (lower.endsWith('.flac')) return 'FLAC';
    if (lower.endsWith('.m4a')) return 'M4A';
    if (lower.endsWith('.aac')) return 'AAC';
    if (lower.endsWith('.wav')) return 'WAV';
    if (lower.endsWith('.aiff') || lower.endsWith('.aif')) return 'AIFF';
    if (lower.endsWith('.mp3')) return 'MP3';
    if (lower.endsWith('.opus') || lower.endsWith('.ogg')) return 'Opus';
    if (lower.endsWith('.cue')) return 'CUE';
    return 'Unknown';
  }

  Map<String, String> _buildFallbackMetadata() {
    String formatIndexTag(int number, int? total) {
      if (total != null && total > 0) {
        return '$number/$total';
      }
      return number.toString();
    }

    return {
      'TITLE': trackName,
      'ARTIST': artistName,
      'ALBUM': albumName,
      if (albumArtist != null && albumArtist!.isNotEmpty)
        'ALBUMARTIST': albumArtist!,
      if (trackNumber != null)
        'TRACKNUMBER': formatIndexTag(trackNumber!, totalTracks),
      if (discNumber != null)
        'DISCNUMBER': formatIndexTag(discNumber!, totalDiscs),
      if (releaseDate != null && releaseDate!.isNotEmpty) 'DATE': releaseDate!,
      if (isrc != null && isrc!.isNotEmpty) 'ISRC': isrc!,
      if (genre != null && genre!.isNotEmpty) 'GENRE': genre!,
      if (label != null && label!.isNotEmpty) 'LABEL': label!,
      if (copyright != null && copyright!.isNotEmpty) 'COPYRIGHT': copyright!,
      if (composer != null && composer!.isNotEmpty) 'COMPOSER': composer!,
      if (isExplicit) 'ITUNESADVISORY': '1',
    };
  }

  String? _extractLossyBitrateLabel(String? quality) {
    if (quality == null || quality.isEmpty) return null;
    final match = RegExp(
      r'(\d+)\s*k(?:bps)?',
      caseSensitive: false,
    ).firstMatch(quality);
    if (match == null) return null;
    return '${match.group(1)}kbps';
  }

  String _extractFileNameFromPathOrUri(String pathOrUri) {
    if (pathOrUri.isEmpty) return '';
    try {
      if (pathOrUri.startsWith('content://')) {
        final uri = Uri.parse(pathOrUri);
        if (uri.pathSegments.isNotEmpty) {
          var last = Uri.decodeComponent(uri.pathSegments.last);
          if (last.contains('/')) {
            last = last.split('/').last;
          }
          if (last.contains(':')) {
            last = last.split(':').last;
          }
          if (last.isNotEmpty) return last;
        }
      }
    } catch (_) {}

    final normalized = pathOrUri.replaceAll('\\', '/');
    if (normalized.contains('/')) {
      return normalized.split('/').last;
    }
    return normalized;
  }

  Future<void> _removeReplayGain() async {
    if (!_fileExists) return;
    final sourcePath = cleanFilePath;
    final confirmed = await showAppDialog<bool>(
      context: context,
      builder: (ctx) => AppAlertDialog(
        title: Text(ctx.l10n.trackRemoveReplayGain),
        content: Text(ctx.l10n.replayGainRemoveConfirmMessage(1)),
        actions: [
          AppDialogAction(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(ctx.l10n.dialogCancel),
          ),
          AppDialogAction(
            filled: true,
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(ctx.l10n.trackRemoveReplayGain),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted || sourcePath != cleanFilePath) return;
    await _updateReplayGain(remove: true);
  }

  Future<void> _updateReplayGain({bool remove = false}) async {
    if (!_fileExists) return;
    final sourcePath = cleanFilePath;
    final generation = _metadataLoadGeneration;
    final messenger = ScaffoldMessenger.of(context);
    messenger.clearSnackBars();
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          remove
              ? context.l10n.replayGainRemoving
              : context.l10n.trackReplayGainScanning,
        ),
        duration: const Duration(seconds: 30),
      ),
    );
    bool ok = false;
    try {
      ok = remove
          ? await ReplayGainService.removeFromFile(sourcePath)
          : await ReplayGainService.applyToFile(sourcePath);
    } catch (e) {
      _log.w('ReplayGain update failed: $e');
    }
    if (!mounted) return;
    if (ok &&
        generation == _metadataLoadGeneration &&
        sourcePath == cleanFilePath) {
      _hasLoadedResolvedAudioMetadata = false;
      await _refreshResolvedAudioMetadataFromFile();
    }
    if (!mounted) return;
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          remove
              ? (ok
                    ? context.l10n.trackRemoveReplayGainSuccess
                    : context.l10n.trackRemoveReplayGainFailed)
              : (ok
                    ? context.l10n.trackReplayGainSuccess
                    : context.l10n.trackReplayGainFailed),
        ),
      ),
    );
  }

  void _showConvertSheet(BuildContext context) {
    final currentFormat = _currentFileFormat;
    final isLosslessSource = isLosslessConversionSource(currentFormat);

    final formats = audioConversionTargetFormats
        .where(
          (target) => canConvertAudioFormat(
            sourceFormat: currentFormat,
            targetFormat: target,
          ),
        )
        .toList(growable: false);

    final labels = context.l10n.losslessConversionLabels;

    showAppModalBottomSheet<void>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      // The sheet draws its own glass.
      mornyeGlass: false,
      builder: (sheetContext) => BatchConvertSheet(
        formats: formats,
        title: context.l10n.trackConvertTitle,
        subtitle: currentFormat,
        sourceIsLossless: isLosslessSource,
        sourceBitDepth: bitDepth,
        sourceSampleRate: sampleRate,
        confirmLabelBuilder:
            (format, bitrate, isLosslessTarget, losslessQuality) {
              return isLosslessTarget
                  ? context.l10n.trackConvertActionLabelLossless(
                      currentFormat,
                      format,
                      losslessQualityLabel(
                        losslessQuality,
                        originalLabel: labels.original,
                        originalQualityLabel: labels.originalQuality,
                      ),
                    )
                  : context.l10n.trackConvertActionLabelLossy(
                      currentFormat,
                      format,
                      bitrate,
                    );
            },
        onConvert:
            (
              format,
              bitrate,
              losslessQuality,
              losslessProcessing,
              keepOriginal,
            ) {
              Navigator.pop(sheetContext);
              _confirmAndConvert(
                context: this.context,
                sourceFormat: currentFormat,
                targetFormat: format,
                bitrate: bitrate,
                losslessQuality: losslessQuality,
                losslessProcessing: losslessProcessing,
                keepOriginal: keepOriginal,
              );
            },
      ),
    );
  }

  void _showCueSplitSheet(BuildContext context) async {
    var cuePath = cleanFilePath;
    final unknownAlbum = context.l10n.unknownAlbum;
    final unknownArtist = context.l10n.unknownArtist;
    final trackSuffix = RegExp(r'#track\d+$');
    if (trackSuffix.hasMatch(cuePath)) {
      cuePath = cuePath.replaceFirst(trackSuffix, '');
    }

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(context.l10n.snackbarLoadingCueSheet)),
    );

    try {
      final cueInfo = await PlatformBridge.parseCueSheet(cuePath);

      if (!mounted) return;
      ScaffoldMessenger.of(this.context).hideCurrentSnackBar();

      if (cueInfo.containsKey('error')) {
        _showSnackBarMessage(this.context.l10n.cueSplitNoAudioFile);
        return;
      }

      final album = cueInfo['album'] as String? ?? unknownAlbum;
      final artist = cueInfo['artist'] as String? ?? unknownArtist;
      final audioPath = cueInfo['audio_path'] as String? ?? '';
      final genre = cueInfo['genre'] as String? ?? '';
      final date = cueInfo['date'] as String? ?? '';
      final tracksRaw = cueInfo['tracks'] as List<dynamic>? ?? [];

      if (audioPath.isEmpty) {
        _showSnackBarMessage(this.context.l10n.cueSplitNoAudioFile);
        return;
      }

      final tracks = tracksRaw
          .map((t) => CueSplitTrackInfo.fromJson(t as Map<String, dynamic>))
          .toList();

      if (tracks.isEmpty) {
        _showSnackBarMessage(this.context.l10n.cueSplitFailed);
        return;
      }

      if (!mounted) return;

      showAppModalBottomSheet<void>(
        context: this.context,
        useRootNavigator: true,
        isScrollControlled: true,
        builder: (sheetContext) {
          final colorScheme = Theme.of(sheetContext).colorScheme;
          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const AppSheetHandle(),
                  const SizedBox(height: 16),
                  Text(
                    sheetContext.l10n.cueSplitTitle,
                    style: Theme.of(sheetContext).textTheme.titleLarge
                        ?.copyWith(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    sheetContext.l10n.cueSplitAlbum(album),
                    style: Theme.of(sheetContext).textTheme.bodyMedium
                        ?.copyWith(color: colorScheme.onSurfaceVariant),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    sheetContext.l10n.cueSplitArtist(artist),
                    style: Theme.of(sheetContext).textTheme.bodyMedium
                        ?.copyWith(color: colorScheme.onSurfaceVariant),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    sheetContext.l10n.cueSplitTrackCount(tracks.length),
                    style: Theme.of(sheetContext).textTheme.bodyMedium
                        ?.copyWith(
                          color: colorScheme.primary,
                          fontWeight: FontWeight.w600,
                        ),
                  ),
                  const SizedBox(height: 16),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 200),
                    child: ListView.builder(
                      shrinkWrap: true,
                      itemCount: tracks.length,
                      itemBuilder: (context, index) {
                        final track = tracks[index];
                        final duration = track.endSec > 0
                            ? track.endSec - track.startSec
                            : 0.0;
                        final durationStr = duration > 0
                            ? '${(duration ~/ 60).toString().padLeft(2, '0')}:${(duration.toInt() % 60).toString().padLeft(2, '0')}'
                            : '';
                        return ListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          leading: CircleAvatar(
                            radius: 14,
                            backgroundColor: colorScheme.primaryContainer,
                            child: Text(
                              '${track.number}',
                              style: TextStyle(
                                fontSize: 11,
                                color: colorScheme.onPrimaryContainer,
                              ),
                            ),
                          ),
                          title: Text(
                            track.title,
                            style: const TextStyle(fontSize: 13),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: track.artist.isNotEmpty
                              ? Text(
                                  track.artist,
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: colorScheme.onSurfaceVariant,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                )
                              : null,
                          trailing: durationStr.isNotEmpty
                              ? Text(
                                  durationStr,
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: colorScheme.onSurfaceVariant,
                                  ),
                                )
                              : null,
                        );
                      },
                    ),
                  ),
                  const SizedBox(height: 16),
                  SizedBox(
                    width: double.infinity,
                    child: ExpressiveButton(
                      onPressed: () {
                        Navigator.pop(sheetContext);
                        _confirmAndSplitCue(
                          context: this.context,
                          audioPath: audioPath,
                          album: album,
                          artist: artist,
                          genre: genre,
                          date: date,
                          tracks: tracks,
                        );
                      },
                      icon: const Icon(Icons.call_split),
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      child: Text(sheetContext.l10n.cueSplitButton),
                    ),
                  ),
                  const SizedBox(height: 8),
                ],
              ),
            ),
          );
        },
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(this.context).hideCurrentSnackBar();
      _showSnackBarMessage(this.context.l10n.cueSplitFailed);
      _log.e('Failed to parse CUE sheet: $e');
    }
  }

  void _confirmAndSplitCue({
    required BuildContext context,
    required String audioPath,
    required String album,
    required String artist,
    required String genre,
    required String date,
    required List<CueSplitTrackInfo> tracks,
  }) {
    showAppDialog<void>(
      context: context,
      builder: (dialogContext) {
        return AppAlertDialog(
          title: Text(dialogContext.l10n.cueSplitConfirmTitle),
          content: Text(
            dialogContext.l10n.cueSplitConfirmMessage(album, tracks.length),
          ),
          actions: [
            AppDialogAction(
              onPressed: () => Navigator.pop(dialogContext),
              child: Text(dialogContext.l10n.dialogCancel),
            ),
            AppDialogAction(
              filled: true,
              onPressed: () {
                Navigator.pop(dialogContext);
                _performCueSplit(
                  audioPath: audioPath,
                  album: album,
                  artist: artist,
                  genre: genre,
                  date: date,
                  tracks: tracks,
                );
              },
              child: Text(dialogContext.l10n.cueSplitButton),
            ),
          ],
        );
      },
    );
  }

  Future<Directory> _resolvePersistentCueSplitOutputDir() async {
    final settings = ref.read(settingsProvider);
    final queueState = ref.read(downloadQueueProvider);
    final configuredOutputDir = queueState.outputDir.trim();
    if (settings.storageMode != 'saf' &&
        configuredOutputDir.isNotEmpty &&
        !isContentUri(configuredOutputDir)) {
      final dir = Directory(configuredOutputDir);
      await dir.create(recursive: true);
      return dir;
    }

    if (Platform.isAndroid) {
      final externalDir = await getExternalStorageDirectory();
      if (externalDir != null) {
        final musicDir = Directory(
          '${externalDir.parent.parent.parent.parent.path}'
          '${Platform.pathSeparator}Music'
          '${Platform.pathSeparator}Mornye',
        );
        await musicDir.create(recursive: true);
        return musicDir;
      }
    }

    final docsDir = await getApplicationDocumentsDirectory();
    final fallbackDir = Directory(
      '${docsDir.path}${Platform.pathSeparator}Mornye',
    );
    await fallbackDir.create(recursive: true);
    return fallbackDir;
  }

  Future<List<String>?> _exportCueSplitOutputsToSaf({
    required List<String> outputPaths,
    required String treeUri,
    required String relativeDir,
  }) async {
    final exportedUris = <String>[];
    for (final path in outputPaths) {
      final fileName = path.split(Platform.pathSeparator).last;
      final safUri = await PlatformBridge.createSafFileFromPath(
        treeUri: treeUri,
        relativeDir: relativeDir,
        fileName: fileName,
        mimeType: audioMimeTypeForPath(path),
        srcPath: path,
      );
      if (safUri != null && safUri.isNotEmpty) {
        exportedUris.add(safUri);
      }
    }
    return exportedUris.isEmpty ? null : exportedUris;
  }

  Future<void> _performCueSplit({
    required String audioPath,
    required String album,
    required String artist,
    required String genre,
    required String date,
    required List<CueSplitTrackInfo> tracks,
  }) async {
    if (_isConverting) return;
    _setState(() => _isConverting = true);

    String? safTempAudioPath;
    Directory? tempSplitDir;
    try {
      // For SAF content:// audio paths, copy to temp for FFmpeg processing
      String workingAudioPath = audioPath;
      final isSafSource = isContentUri(audioPath);
      if (isSafSource) {
        final tempPath = await PlatformBridge.copyContentUriToTemp(audioPath);
        if (tempPath == null || tempPath.isEmpty) {
          throw Exception('Failed to copy SAF audio file to temp');
        }
        safTempAudioPath = tempPath;
        workingAudioPath = tempPath;
      }

      final String outputDir;
      final treeUri = !_isLocalItem
          ? (_downloadItem?.downloadTreeUri ?? '')
          : '';
      final relativeDir = !_isLocalItem
          ? (_downloadItem?.safRelativeDir ?? '')
          : '';
      final writeBackToSaf = isSafSource && treeUri.isNotEmpty;
      if (writeBackToSaf) {
        final tempDir = await getTemporaryDirectory();
        tempSplitDir = Directory(
          '${tempDir.path}${Platform.pathSeparator}'
          'cue_split_${DateTime.now().millisecondsSinceEpoch}',
        );
        await tempSplitDir.create(recursive: true);
        outputDir = tempSplitDir.path;
      } else if (isSafSource) {
        final persistentDir = await _resolvePersistentCueSplitOutputDir();
        outputDir = persistentDir.path;
      } else {
        outputDir = File(audioPath).parent.path;
      }

      if (!mounted) return;
      _showLongSnackBarMessage(
        context.l10n.cueSplitSplitting(1, tracks.length),
      );

      String? coverPath;
      try {
        final tempDir = await getTemporaryDirectory();
        final coverOutput =
            '${tempDir.path}${Platform.pathSeparator}cue_cover_${DateTime.now().millisecondsSinceEpoch}.jpg';
        final coverResult = await PlatformBridge.extractCoverToFile(
          workingAudioPath,
          coverOutput,
        );
        if (coverResult['error'] == null) {
          coverPath = coverOutput;
        }
      } catch (_) {}

      final albumMetadata = <String, String>{
        'artist': artist,
        'album': album,
        'genre': genre,
        'date': date,
      };

      final outputPaths = await FFmpegConversion.splitCueToTracks(
        audioPath: workingAudioPath,
        outputDir: outputDir,
        tracks: tracks,
        albumMetadata: albumMetadata,
        coverPath: coverPath,
        onProgress: (current, total) {
          if (mounted) {
            ScaffoldMessenger.of(context).hideCurrentSnackBar();
            _showLongSnackBarMessage(
              context.l10n.cueSplitSplitting(current, total),
            );
          }
        },
      );

      var finalOutputPaths = outputPaths;

      if (coverPath != null && finalOutputPaths != null) {
        for (final path in finalOutputPaths) {
          if (path.toLowerCase().endsWith('.flac')) {
            try {
              // Only send the cover_path field — EditFlacFields uses
              // field-presence semantics, so omitting artist/album_artist
              // means those keys won't be rewritten.  This preserves any
              // existing split artist Vorbis Comments.
              await PlatformBridge.editFileMetadata(path, {
                'cover_path': coverPath,
              });
            } catch (e) {
              _log.w('Failed to embed cover to split track: $e');
            }
          }
        }
      }

      if (writeBackToSaf && finalOutputPaths != null) {
        final exportedUris = await _exportCueSplitOutputsToSaf(
          outputPaths: finalOutputPaths,
          treeUri: treeUri,
          relativeDir: relativeDir,
        );
        finalOutputPaths = exportedUris;
      }

      if (coverPath != null) {
        try {
          await File(coverPath).delete();
        } catch (_) {}
      }

      if (mounted) {
        ScaffoldMessenger.of(context).hideCurrentSnackBar();
        if (finalOutputPaths != null && finalOutputPaths.isNotEmpty) {
          _showSnackBarMessage(
            context.l10n.cueSplitSuccess(finalOutputPaths.length),
          );
        } else {
          _showSnackBarMessage(context.l10n.cueSplitFailed);
        }
      }
    } catch (e) {
      _log.e('CUE split failed: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).hideCurrentSnackBar();
        _showSnackBarMessage(context.l10n.cueSplitFailed);
      }
    } finally {
      if (safTempAudioPath != null) {
        try {
          await File(safTempAudioPath).delete();
        } catch (_) {}
      }
      if (tempSplitDir != null) {
        try {
          await tempSplitDir.delete(recursive: true);
        } catch (_) {}
      }
      if (mounted) {
        _setState(() => _isConverting = false);
      }
    }
  }

  void _confirmAndConvert({
    required BuildContext context,
    required String sourceFormat,
    required String targetFormat,
    required String bitrate,
    LosslessConversionQuality losslessQuality =
        const LosslessConversionQuality(),
    LosslessConversionProcessing losslessProcessing =
        const LosslessConversionProcessing(),
    bool keepOriginal = false,
  }) {
    final isLossless = isLosslessConversionTarget(targetFormat);
    showAppDialog<void>(
      context: context,
      builder: (dialogContext) {
        return AppAlertDialog(
          title: Text(dialogContext.l10n.trackConvertConfirmTitle),
          content: Text(
            keepOriginal
                ? dialogContext.l10n.trackConvertConfirmKeepOriginal(
                    sourceFormat,
                    targetFormat,
                  )
                : isLossless && losslessQuality.hasCaps
                ? dialogContext.l10n.trackConvertConfirmMessageLosslessCapped(
                    sourceFormat,
                    targetFormat,
                    losslessQualityLabel(
                      losslessQuality,
                      originalLabel:
                          dialogContext.l10n.losslessConversionLabels.original,
                      originalQualityLabel: dialogContext
                          .l10n
                          .losslessConversionLabels
                          .originalQuality,
                    ),
                  )
                : isLossless
                ? dialogContext.l10n.trackConvertConfirmMessageLossless(
                    sourceFormat,
                    targetFormat,
                  )
                : dialogContext.l10n.trackConvertConfirmMessage(
                    sourceFormat,
                    targetFormat,
                    bitrate,
                  ),
          ),
          actions: [
            AppDialogAction(
              onPressed: () => Navigator.pop(dialogContext),
              child: Text(dialogContext.l10n.dialogCancel),
            ),
            AppDialogAction(
              filled: true,
              onPressed: () {
                Navigator.pop(dialogContext);
                _performConversion(
                  targetFormat: targetFormat,
                  bitrate: bitrate,
                  losslessQuality: losslessQuality,
                  losslessProcessing: losslessProcessing,
                  keepOriginal: keepOriginal,
                );
              },
              child: Text(dialogContext.l10n.trackConvertFormat),
            ),
          ],
        );
      },
    );
  }

  Future<void> _performConversion({
    required String targetFormat,
    required String bitrate,
    LosslessConversionQuality losslessQuality =
        const LosslessConversionQuality(),
    LosslessConversionProcessing losslessProcessing =
        const LosslessConversionProcessing(),
    bool keepOriginal = false,
  }) async {
    if (_isConverting) return;
    _setState(() => _isConverting = true);
    final losslessLabels = context.l10n.losslessConversionLabels;

    try {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.l10n.trackConvertConverting)),
      );

      final settings = ref.read(settingsProvider);
      final shouldEmbedLyrics =
          settings.embedLyrics && settings.lyricsMode != 'external';
      final metadata = _buildFallbackMetadata();
      final localItem = _localLibraryItem;
      final result = await convertLibraryTrack(
        filePath: cleanFilePath,
        metadata: metadata,
        trackName: trackName,
        artistName: artistName,
        spotifyId: _spotifyId ?? '',
        durationMs: (duration ?? 0) * 1000,
        sourceBitDepth: bitDepth,
        sourceSampleRate: sampleRate,
        historyItem: localItem == null ? _downloadItem : null,
        localItem: localItem,
        targetFormat: targetFormat,
        bitrate: bitrate,
        losslessQuality: losslessQuality,
        losslessProcessing: losslessProcessing,
        keepOriginal: keepOriginal,
        shouldEmbedLyrics: shouldEmbedLyrics,
        readArtistTagMode: () => ref.read(settingsProvider).artistTagMode,
        losslessLabels: losslessLabels,
        coverTempPrefix: 'convert_cover_',
        treatEmptySafTempPathAsFailure: false,
        historySafFileNameFallback: _extractFileNameFromPathOrUri(
          cleanFilePath,
        ),
        eagerTempCleanup: true,
        onPersisted: () => localItem == null
            ? ref.read(downloadHistoryProvider.notifier).reloadFromStorage()
            : ref.read(localLibraryProvider.notifier).reloadFromStorage(),
        diagnosticsLog: _log,
        onCleanupFailed: (path, error) =>
            _log.w('Failed to clean conversion temp file $path: $error'),
      );

      if (!result.succeeded && !result.isPipelineFailure) {
        Error.throwWithStackTrace(result.error!, result.stackTrace!);
      }
      if (mounted) {
        _setState(() => _isConverting = false);
        if (!result.succeeded) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(context.l10n.trackConvertFailed)),
          );
          return;
        }
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(context.l10n.trackConvertSuccess(targetFormat)),
          ),
        );
        Navigator.pop(context, true);
      }
    } catch (e) {
      if (mounted) {
        _setState(() => _isConverting = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              context.l10n.trackSaveFailed(context.friendlyError(e)),
            ),
          ),
        );
      }
    }
  }
}
