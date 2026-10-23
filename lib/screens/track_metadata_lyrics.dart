part of 'track_metadata_screen.dart';

extension _TrackMetadataLyricsAndSaving on _TrackMetadataScreenState {
  Widget _buildLyricsCard(BuildContext context, ColorScheme colorScheme) {
    final hasDisplayLyrics = _lyrics?.trim().isNotEmpty == true;
    final hasDisplaySource =
        (hasDisplayLyrics || _isInstrumental) &&
        _lyricsSource?.trim().isNotEmpty == true;
    return _metadataSectionSurface(
      context,
      colorScheme,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    context.l10n.trackLyrics,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                      color: colorScheme.onSurface,
                    ),
                  ),
                ),
                if (hasDisplayLyrics)
                  AppIconButton(
                    icon: Icon(
                      context.isMornye ? CupertinoIcons.doc_on_doc : Icons.copy,
                      size: 20,
                    ),
                    onPressed: () => _copyToClipboard(context, _lyrics!),
                    tooltip: context.l10n.trackCopyLyrics,
                  ),
              ],
            ),
            if (hasDisplaySource)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  context.l10n.trackLyricsSource(_lyricsSource!),
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            const SizedBox(height: 12),

            if (_lyricsLoading)
              const Center(
                child: Padding(
                  padding: EdgeInsets.all(20),
                  child: AppLoadingIndicator(),
                ),
              )
            // Status rows sit flat on the lyrics card instead of a second box.
            else if (_lyricsError != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  children: [
                    Icon(
                      Icons.error_outline,
                      color: colorScheme.error,
                      size: 20,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        _lyricsError!,
                        style: TextStyle(color: colorScheme.onSurface),
                      ),
                    ),
                    ExpressiveButton(
                      text: true,
                      onPressed: _fetchOnlineLyrics,
                      child: Text(context.l10n.dialogRetry),
                    ),
                  ],
                ),
              )
            else if (_isInstrumental)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      Icons.music_note,
                      color: colorScheme.onSurfaceVariant,
                      size: 20,
                    ),
                    const SizedBox(width: 12),
                    Text(
                      context.l10n.trackInstrumental,
                      style: TextStyle(
                        color: colorScheme.onSurfaceVariant,
                        fontStyle: FontStyle.italic,
                      ),
                    ),
                  ],
                ),
              )
            else if (hasDisplayLyrics)
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // A visible scrollbar and a fade at the cut show that the
                  // box scrolls, instead of a line clipped in half. Full
                  // width keeps the scrollbar at the card's edge rather than
                  // after the longest line.
                  Container(
                    width: double.infinity,
                    constraints: const BoxConstraints(maxHeight: 300),
                    child: ScrollEdgeFade(
                      size: 48,
                      fadeContent: true,
                      child: Scrollbar(
                        controller: _lyricsScrollController,
                        thumbVisibility: isDesktopPlatform,
                        child: SingleChildScrollView(
                          controller: _lyricsScrollController,
                          child: Text(
                            _lyrics!,
                            style: Theme.of(context).textTheme.bodyMedium
                                ?.copyWith(
                                  color: colorScheme.onSurface,
                                  height: 1.6,
                                ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  if (!_lyricsEmbedded && _fileExists && !_isNetworkItem) ...[
                    const SizedBox(height: 16),
                    Center(
                      child: ExpressiveButton(
                        tonal: true,
                        onPressed: _isEmbedding ? null : _embedLyrics,
                        icon: _isEmbedding
                            ? const AppLoadingIndicator(
                                size: 18,
                                strokeWidth: 2,
                              )
                            : const Icon(Icons.save_alt),
                        child: Text(context.l10n.trackEmbedLyrics),
                      ),
                    ),
                  ],
                ],
              )
            else if (_embeddedLyricsChecked && _fileExists)
              Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(
                      children: [
                        Icon(
                          Icons.lyrics_outlined,
                          color: colorScheme.onSurfaceVariant,
                          size: 20,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            context.l10n.trackLyricsNotInFile,
                            style: TextStyle(
                              color: colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  Center(
                    child: ExpressiveButton(
                      tonal: true,
                      onPressed: _fetchOnlineLyrics,
                      icon: const Icon(Icons.cloud_download_outlined),
                      child: Text(context.l10n.trackFetchOnlineLyrics),
                    ),
                  ),
                ],
              )
            else
              Center(
                child: ExpressiveButton(
                  tonal: true,
                  onPressed: _fetchLyrics,
                  icon: const Icon(Icons.download),
                  child: Text(context.l10n.trackLoadLyrics),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// The lyrics reader can miss files outside the extension file grants.
  /// Fall back to the same local tag reader used by Now Playing before
  /// reporting that a file has no lyrics. Neither call fetches online lyrics.
  Future<Map<String, dynamic>> _readLocalLyrics(String sourcePath) async {
    if (sourcePath.startsWith('network://')) {
      final metadata = await readPlaybackFileMetadataWithRetry(sourcePath);
      return {'lyrics': metadata['lyrics']?.toString() ?? '', 'source': ''};
    }
    try {
      final result = await PlatformBridge.getLyricsLRCWithSource(
        '',
        trackName,
        artistName,
        filePath: sourcePath,
      ).timeout(const Duration(seconds: 5));
      if (hasUsableLyricsContent(result['lyrics']?.toString() ?? '')) {
        return result;
      }
    } catch (e) {
      _log.d('Local lyrics reader failed; trying playback metadata: $e');
    }
    final metadata = await readPlaybackFileMetadataWithRetry(
      sourcePath,
    ).timeout(const Duration(seconds: 5));
    return {'lyrics': metadata['lyrics']?.toString() ?? '', 'source': ''};
  }

  /// Check for lyrics embedded in the audio file only (no network requests).
  /// Called automatically when the screen opens.
  Future<void> _checkEmbeddedLyrics() async {
    if (_lyricsLoading || !_fileExists) return;
    final generation = _metadataLoadGeneration;
    final sourcePath = cleanFilePath;
    if (!mounted) return;

    _setState(() {
      _lyricsLoading = true;
      _lyricsError = null;
      _isInstrumental = false;
      _lyricsSource = null;
    });

    try {
      final embeddedResult = await _readLocalLyrics(sourcePath);

      final embeddedLyrics = embeddedResult['lyrics']?.toString() ?? '';
      final embeddedSource = embeddedResult['source']?.toString() ?? '';

      if (mounted &&
          generation == _metadataLoadGeneration &&
          sourcePath == cleanFilePath) {
        final instrumental = isInstrumentalLyricsMarker(embeddedLyrics);
        final cleanLyrics = cleanLyricsForDisplay(embeddedLyrics);
        if (instrumental || cleanLyrics.isNotEmpty) {
          _setState(() {
            _lyrics = instrumental ? null : cleanLyrics;
            _rawLyrics = instrumental ? null : embeddedLyrics;
            _lyricsSource = embeddedSource.isNotEmpty
                ? embeddedSource
                : context.l10n.trackLyricsEmbeddedSource;
            _lyricsEmbedded = true;
            _isInstrumental = instrumental;
            _lyricsLoading = false;
            _embeddedLyricsChecked = true;
          });
        } else {
          _setState(() {
            _lyrics = null;
            _rawLyrics = null;
            _lyricsSource = null;
            _lyricsEmbedded = false;
            _lyricsLoading = false;
            _embeddedLyricsChecked = true;
          });
        }
      }
    } catch (e) {
      if (mounted &&
          generation == _metadataLoadGeneration &&
          sourcePath == cleanFilePath) {
        _setState(() {
          _lyricsLoading = false;
          _embeddedLyricsChecked = true;
          _lyricsError = context.l10n.trackLyricsLoadFailed;
        });
      }
    }
  }

  /// Fetch lyrics from online providers. Only called by user action.
  Future<void> _fetchOnlineLyrics() async {
    if (_lyricsLoading) return;

    _setState(() {
      _lyricsLoading = true;
      _lyricsError = null;
      _isInstrumental = false;
      _lyricsSource = null;
    });

    try {
      final durationMs = (duration ?? 0) * 1000;

      final result = await PlatformBridge.getLyricsLRCWithSource(
        _spotifyId ?? '',
        trackName,
        artistName,
        filePath: null,
        durationMs: durationMs,
      ).timeout(const Duration(seconds: 20));

      final lrcText = result['lyrics']?.toString() ?? '';
      final source = result['source']?.toString() ?? '';
      final instrumental =
          (result['instrumental'] as bool? ?? false) ||
          isInstrumentalLyricsMarker(lrcText);
      final cleanLyrics = cleanLyricsForDisplay(lrcText);

      if (mounted) {
        if (instrumental) {
          _setState(() {
            _lyrics = null;
            _rawLyrics = null;
            _isInstrumental = true;
            _lyricsSource = source.isNotEmpty ? source : null;
            _lyricsEmbedded = false;
            _lyricsLoading = false;
          });
        } else if (cleanLyrics.isEmpty) {
          _setState(() {
            _lyrics = null;
            _rawLyrics = null;
            _lyricsSource = null;
            _lyricsEmbedded = false;
            _lyricsError = context.l10n.trackLyricsNotAvailable;
            _lyricsLoading = false;
          });
        } else {
          _setState(() {
            _lyrics = cleanLyrics;
            _rawLyrics = lrcText;
            _lyricsSource = source.isNotEmpty ? source : null;
            _lyricsEmbedded = false;
            _lyricsLoading = false;
          });
        }
      }
    } on TimeoutException {
      if (mounted) {
        _setState(() {
          _lyricsError = context.l10n.trackLyricsTimeout;
          _lyricsLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        _setState(() {
          _lyricsError = context.l10n.trackLyricsLoadFailed;
          _lyricsLoading = false;
        });
      }
    }
  }

  /// Full lyrics fetch: check embedded first, then online.
  /// Used by the "Load Lyrics" button when file doesn't exist (non-local items).
  Future<void> _fetchLyrics() async {
    if (_lyricsLoading) return;

    _setState(() {
      _lyricsLoading = true;
      _lyricsError = null;
      _isInstrumental = false;
      _lyricsSource = null;
    });

    try {
      final durationMs = (duration ?? 0) * 1000;

      if (_fileExists) {
        final embeddedResult = await _readLocalLyrics(cleanFilePath);

        final embeddedLyrics = embeddedResult['lyrics']?.toString() ?? '';
        final embeddedSource = embeddedResult['source']?.toString() ?? '';

        final embeddedInstrumental = isInstrumentalLyricsMarker(embeddedLyrics);
        final cleanEmbeddedLyrics = cleanLyricsForDisplay(embeddedLyrics);
        if (embeddedInstrumental || cleanEmbeddedLyrics.isNotEmpty) {
          if (mounted) {
            _setState(() {
              _lyrics = embeddedInstrumental ? null : cleanEmbeddedLyrics;
              _rawLyrics = embeddedInstrumental ? null : embeddedLyrics;
              _lyricsSource = embeddedSource.isNotEmpty
                  ? embeddedSource
                  : context.l10n.trackLyricsEmbeddedSource;
              _lyricsEmbedded = true;
              _isInstrumental = embeddedInstrumental;
              _lyricsLoading = false;
              _embeddedLyricsChecked = true;
            });
          }
          return;
        }
      }

      final result = await PlatformBridge.getLyricsLRCWithSource(
        _spotifyId ?? '',
        trackName,
        artistName,
        filePath: null,
        durationMs: durationMs,
      ).timeout(const Duration(seconds: 20));

      final lrcText = result['lyrics']?.toString() ?? '';
      final source = result['source']?.toString() ?? '';
      final instrumental =
          (result['instrumental'] as bool? ?? false) ||
          isInstrumentalLyricsMarker(lrcText);
      final cleanLyrics = cleanLyricsForDisplay(lrcText);

      if (mounted) {
        if (instrumental) {
          _setState(() {
            _lyrics = null;
            _rawLyrics = null;
            _isInstrumental = true;
            _lyricsSource = source.isNotEmpty ? source : null;
            _lyricsEmbedded = false;
            _lyricsLoading = false;
          });
        } else if (cleanLyrics.isEmpty) {
          _setState(() {
            _lyrics = null;
            _rawLyrics = null;
            _lyricsSource = null;
            _lyricsEmbedded = false;
            _lyricsError = context.l10n.trackLyricsNotAvailable;
            _lyricsLoading = false;
          });
        } else {
          _setState(() {
            _lyrics = cleanLyrics;
            _rawLyrics = lrcText;
            _lyricsSource = source.isNotEmpty ? source : null;
            _lyricsEmbedded = false;
            _lyricsLoading = false;
          });
        }
      }
    } on TimeoutException {
      if (mounted) {
        _setState(() {
          _lyricsError = context.l10n.trackLyricsTimeout;
          _lyricsLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        _setState(() {
          _lyricsError = context.l10n.trackLyricsLoadFailed;
          _lyricsLoading = false;
        });
      }
    }
  }

  Future<void> _embedLyrics() async {
    if (_isEmbedding || _rawLyrics == null || !_fileExists) return;

    _setState(() => _isEmbedding = true);

    final l10nFailedToWriteStorage = context.l10n.snackbarFailedToWriteStorage;
    final l10nFailedToEmbedLyrics = context.l10n.snackbarFailedToEmbedLyrics;
    final l10nUnsupportedFormat = context.l10n.snackbarUnsupportedAudioFormat;

    String? safTempPath;
    String? coverPath;

    try {
      final rawLyrics = _rawLyrics!;
      var workingPath = cleanFilePath;

      if (_isSafFile) {
        safTempPath = await PlatformBridge.copyContentUriToTemp(cleanFilePath);
        if (safTempPath == null || safTempPath.isEmpty) {
          throw Exception('Failed to access SAF file');
        }
        workingPath = safTempPath;
      }

      final lower = workingPath.toLowerCase();
      final isFlac = lower.endsWith('.flac');
      final isMp3 = lower.endsWith('.mp3');
      final isOpus = lower.endsWith('.opus') || lower.endsWith('.ogg');
      final isM4A = lower.endsWith('.m4a') || lower.endsWith('.aac');

      bool success = false;
      String? error;

      if (isFlac) {
        final result = await PlatformBridge.embedLyricsToFile(
          workingPath,
          rawLyrics,
        );
        if (result['success'] == true) {
          if (_isSafFile) {
            final ok = await PlatformBridge.writeTempToSaf(
              workingPath,
              cleanFilePath,
            );
            success = ok;
            if (!ok) {
              error = l10nFailedToWriteStorage;
            }
          } else {
            success = true;
          }
        } else {
          error = userFacingErrorMessage(
            result['error'],
            fallback: l10nFailedToEmbedLyrics,
          );
        }
      } else if (isMp3 || isOpus || isM4A) {
        final metadata = _buildFallbackMetadata();
        try {
          final result = await PlatformBridge.readFileMetadata(workingPath);
          if (result['error'] == null) {
            // Map separately so a non-explicit file keeps the fallback advisory.
            final mapped = <String, String>{};
            mergePlatformMetadataForTagEmbed(target: mapped, source: result);
            metadata.addAll(mapped);
          }
        } catch (e) {
          _log.w('Failed reading file metadata before lyrics embed: $e');
        }

        metadata['LYRICS'] = rawLyrics;
        metadata['UNSYNCEDLYRICS'] = rawLyrics;

        try {
          final tempDir = await getTemporaryDirectory();
          final coverOutput =
              '${tempDir.path}${Platform.pathSeparator}lyrics_cover_${DateTime.now().millisecondsSinceEpoch}.jpg';
          final coverResult = await PlatformBridge.extractCoverToFile(
            workingPath,
            coverOutput,
          );
          if (coverResult['error'] == null) {
            coverPath = coverOutput;
          }
        } catch (_) {}

        // Embedding lyrics rewrites the tags read above; it must not drop
        // existing artist credits, so the primary mode keeps them joined.
        final artistTagMode = artistTagModeForExistingTags(
          ref.read(settingsProvider).artistTagMode,
        );
        String? ffmpegResult;
        if (isMp3) {
          ffmpegResult = await FFmpegMetadata.embedMetadataToMp3(
            mp3Path: workingPath,
            coverPath: coverPath,
            metadata: metadata,
          );
        } else if (isM4A) {
          ffmpegResult = await FFmpegMetadata.embedMetadataToM4a(
            m4aPath: workingPath,
            coverPath: coverPath,
            metadata: metadata,
          );
        } else {
          ffmpegResult = await FFmpegMetadata.embedMetadataToOpus(
            opusPath: workingPath,
            coverPath: coverPath,
            metadata: metadata,
            artistTagMode: artistTagMode,
          );
        }

        if (ffmpegResult == null) {
          error = l10nFailedToEmbedLyrics;
        } else if (_isSafFile) {
          final ok = await PlatformBridge.writeTempToSaf(
            ffmpegResult,
            cleanFilePath,
          );
          success = ok;
          if (!ok) {
            error = l10nFailedToWriteStorage;
          }
        } else {
          success = true;
        }
      } else {
        error = l10nUnsupportedFormat;
      }

      if (mounted) {
        if (success) {
          _setState(() {
            _lyricsEmbedded = true;
            _isEmbedding = false;
          });
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(context.l10n.trackLyricsEmbedded)),
          );
        } else {
          _setState(() => _isEmbedding = false);
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(error ?? context.l10n.snackbarFailedToEmbedLyrics),
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        _setState(() => _isEmbedding = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(context.l10n.snackbarError(context.friendlyError(e))),
          ),
        );
      }
    } finally {
      if (coverPath != null) {
        try {
          await File(coverPath).delete();
        } catch (_) {}
      }
      if (safTempPath != null) {
        try {
          await File(safTempPath).delete();
        } catch (_) {}
      }
    }
  }

  String _sanitizeFileNameSegment(String value) {
    var sanitized = value
        .replaceAll(_TrackMetadataScreenState._invalidFileNameChars, '_')
        .trim();
    sanitized = sanitized.replaceAll(
      _TrackMetadataScreenState._leadingOrTrailingDots,
      '',
    );
    sanitized = sanitized.replaceAll(
      _TrackMetadataScreenState._multiUnderscore,
      '_',
    );
    if (sanitized.isEmpty) {
      return 'untitled';
    }
    return sanitized;
  }

  String _buildSaveBaseName() {
    final artist = _sanitizeFileNameSegment(artistName);
    final track = _sanitizeFileNameSegment(trackName);
    return '$artist - $track';
  }

  String _getFileDirectory() {
    if (isContentUri(cleanFilePath)) {
      // SAF URIs don't have a filesystem parent directory
      return '';
    }
    final file = File(cleanFilePath);
    return file.parent.path;
  }

  bool get _isSafFile => isContentUri(cleanFilePath);

  /// Writes `baseName.extension` as a sidecar of the current track.
  ///
  /// `writeTo` renders the file at the given path and returns the bridge
  /// result, or null when it has already told the user why nothing was
  /// written. SAF tracks are rendered into a temp directory and published to
  /// the download tree; local tracks are written next to the audio file.
  /// Exceptions propagate to the caller.
  Future<void> _publishSidecarFile({
    required String baseName,
    required String tempDirPrefix,
    required String extension,
    required String mimeType,
    required String Function() successMessage,
    required bool hideCurrentSnackBar,
    required Future<Map<String, dynamic>?> Function(String outputPath) writeTo,
  }) async {
    void showMessage(String message) {
      final messenger = ScaffoldMessenger.of(context);
      if (hideCurrentSnackBar) {
        messenger.hideCurrentSnackBar();
      }
      messenger.showSnackBar(SnackBar(content: Text(message)));
    }

    final fileName = '$baseName.$extension';

    if (_isSafFile) {
      final tempDir = await Directory.systemTemp.createTemp(tempDirPrefix);
      final tempOutput = '${tempDir.path}${Platform.pathSeparator}$fileName';

      final result = await writeTo(tempOutput);
      if (result == null) {
        return;
      }

      if (result['error'] != null) {
        if (mounted) {
          showMessage(
            context.l10n.trackSaveFailed(
              context.friendlyError(result['error']),
            ),
          );
        }
        try {
          await Directory(tempDir.path).delete(recursive: true);
        } catch (_) {}
        return;
      }

      final treeUri = _downloadItem?.downloadTreeUri;
      final relativeDir = _downloadItem?.safRelativeDir ?? '';
      if (treeUri != null && treeUri.isNotEmpty) {
        final safUri = await PlatformBridge.createSafFileFromPath(
          treeUri: treeUri,
          relativeDir: relativeDir,
          fileName: fileName,
          mimeType: mimeType,
          srcPath: tempOutput,
        );
        try {
          await Directory(tempDir.path).delete(recursive: true);
        } catch (_) {}
        if (mounted) {
          if (safUri != null) {
            showMessage(successMessage());
          } else {
            showMessage(
              context.l10n.trackSaveFailed('Failed to write to storage'),
            );
          }
        }
      } else {
        try {
          await Directory(tempDir.path).delete(recursive: true);
        } catch (_) {}
        if (mounted) {
          showMessage(context.l10n.trackSaveFailed('No storage access'));
        }
      }
      return;
    }

    final dir = _getFileDirectory();
    final outputPath = '$dir${Platform.pathSeparator}$fileName';

    final result = await writeTo(outputPath);
    if (result == null) {
      return;
    }

    if (mounted) {
      if (result['error'] != null) {
        showMessage(
          context.l10n.trackSaveFailed(context.friendlyError(result['error'])),
        );
      } else {
        showMessage(successMessage());
      }
    }
  }

  Future<void> _saveCoverArt() async {
    try {
      final baseName = _buildSaveBaseName();

      await _publishSidecarFile(
        baseName: baseName,
        tempDirPrefix: 'cover_',
        extension: 'jpg',
        mimeType: 'image/jpeg',
        successMessage: () => context.l10n.trackCoverSaved(baseName),
        hideCurrentSnackBar: false,
        writeTo: (outputPath) async {
          Map<String, dynamic> result;
          if (_fileExists) {
            // Prefer extracting cover from the already-downloaded file to
            // avoid a redundant network request.
            result = await PlatformBridge.extractCoverToFile(
              cleanFilePath,
              outputPath,
            );
            if (result['error'] != null &&
                _coverUrl != null &&
                _coverUrl!.isNotEmpty) {
              result = await PlatformBridge.downloadCoverToFile(
                _coverUrl!,
                outputPath,
              );
            }
          } else if (_coverUrl != null && _coverUrl!.isNotEmpty) {
            result = await PlatformBridge.downloadCoverToFile(
              _coverUrl!,
              outputPath,
            );
          } else {
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text(context.l10n.trackCoverNoSource)),
              );
            }
            return null;
          }
          return result;
        },
      );
    } catch (e) {
      if (mounted) {
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

  Future<void> _saveLyrics() async {
    try {
      final baseName = _buildSaveBaseName();
      final durationMs = (duration ?? 0) * 1000;
      if (mounted) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            SnackBar(content: Text(context.l10n.trackSaveLyricsProgress)),
          );
      }

      await _publishSidecarFile(
        baseName: baseName,
        tempDirPrefix: 'lyrics_',
        extension: 'lrc',
        mimeType: 'application/octet-stream',
        successMessage: () => context.l10n.trackLyricsSaved(baseName),
        hideCurrentSnackBar: true,
        writeTo: (outputPath) => PlatformBridge.fetchAndSaveLyrics(
          trackName: trackName,
          artistName: artistName,
          spotifyId: _spotifyId ?? '',
          durationMs: durationMs,
          outputPath: outputPath,
          audioFilePath: _fileExists ? cleanFilePath : '',
        ),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            SnackBar(
              content: Text(
                context.l10n.trackSaveFailed(context.friendlyError(e)),
              ),
            ),
          );
      }
    }
  }

  Future<void> _reEnrichMetadata() async {
    if (!_fileExists) return;

    try {
      final settings = ref.read(settingsProvider);
      final artistTagMode = settings.artistTagMode;
      final messenger = ScaffoldMessenger.of(context);
      final l10n = context.l10n;
      await ref.read(settingsProvider.notifier).syncLyricsSettingsToBackend();
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(content: Text(l10n.trackReEnrichSearching)),
      );

      final durationMs = (duration ?? 0) * 1000;
      final request = <String, dynamic>{
        'file_path': cleanFilePath,
        'cover_url': _coverUrl ?? '',
        'cover_max_dimension': settings.embeddedCoverMaxDimension,
        'embed_lyrics': settings.embedLyrics,
        'lyrics_mode': settings.lyricsMode,
        'artist_tag_mode': artistTagMode,
        'spotify_id': _spotifyId ?? '',
        'track_name': trackName,
        'artist_name': artistName,
        'album_name': albumName,
        'album_artist': albumArtist ?? '',
        'track_number': trackNumber ?? 0,
        'total_tracks': totalTracks ?? 0,
        'disc_number': discNumber ?? 0,
        'total_discs': totalDiscs ?? 0,
        'release_date': releaseDate ?? '',
        'isrc': isrc ?? '',
        'genre': genre ?? '',
        'label': label ?? '',
        'copyright': copyright ?? '',
        'composer': composer ?? '',
        'duration_ms': durationMs,
        'search_online': true,
        'replace_release_metadata': allowsReleaseIdentityReplacement(
          ReEnrichOperationScope.singleFile,
        ),
      };

      final result = await PlatformBridge.reEnrichFile(request);
      final method = result['method'] as String?;

      final enriched = result['enriched_metadata'] as Map<String, dynamic>?;
      if (enriched != null && mounted) {
        _setState(() {
          _editedMetadata = {
            'title': enriched['track_name'] ?? trackName,
            'artist': enriched['artist_name'] ?? artistName,
            'album': enriched['album_name'] ?? albumName,
            'album_artist': enriched['album_artist'] ?? albumArtist,
            'date': enriched['release_date'] ?? releaseDate,
            'track_number': enriched['track_number'] ?? trackNumber,
            'total_tracks': enriched['total_tracks'] ?? totalTracks,
            'disc_number': enriched['disc_number'] ?? discNumber,
            'total_discs': enriched['total_discs'] ?? totalDiscs,
            'isrc': enriched['isrc'] ?? isrc,
            'genre': enriched['genre'] ?? genre,
            'label': enriched['label'] ?? label,
            'copyright': enriched['copyright'] ?? copyright,
            'composer': enriched['composer'] ?? composer,
          };
        });
      }

      if (method == 'native') {
        // FLAC - handled natively by Go (SAF write-back handled in Kotlin).
        // External .lrc sidecar for filesystem files is written here; SAF
        // sidecars are created natively in the Kotlin reEnrichFile handler.
        await writeReEnrichSidecarLrc(
          audioFilePath: cleanFilePath,
          reEnrichResult: result,
        );
        await _refreshEmbeddedCoverPreview(force: true);
        _markMetadataChanged();
        await _syncDownloadHistoryMetadata(
          hasLyrics: hasUsableLyricsContent(
            (result['lyrics'] ?? result['lyrics_lrc'])?.toString() ?? '',
          ),
        );
        await _checkEmbeddedLyrics();
        if (mounted) {
          messenger.hideCurrentSnackBar();
          await showReEnrichResultDialog(
            context,
            message: reEnrichCompletionMessage(context.l10n, result),
          );
        }
      } else if (method == 'ffmpeg') {
        // MP3/Opus - need FFmpeg from Dart side
        // For SAF files, Kotlin returns temp_path + saf_uri
        final tempPath = result['temp_path'] as String?;
        final safUri = result['saf_uri'] as String?;
        final ffmpegTarget = tempPath ?? cleanFilePath;

        final downloadedCoverPath = result['cover_path'] as String?;
        String? effectiveCoverPath = downloadedCoverPath;
        String? extractedCoverPath;
        try {
          if (!_hasPath(effectiveCoverPath)) {
            try {
              final tempDir = await Directory.systemTemp.createTemp(
                'reenrich_cover_',
              );
              final coverOutput =
                  '${tempDir.path}${Platform.pathSeparator}cover.jpg';
              final extracted = await PlatformBridge.extractCoverToFile(
                ffmpegTarget,
                coverOutput,
              );
              if (extracted['error'] == null) {
                effectiveCoverPath = coverOutput;
                extractedCoverPath = coverOutput;
              } else {
                try {
                  await tempDir.delete(recursive: true);
                } catch (_) {}
              }
            } catch (_) {}
          }
          final metadata = (result['metadata'] as Map<String, dynamic>?)?.map(
            (k, v) => MapEntry(k, v.toString()),
          );
          final lower = cleanFilePath.toLowerCase();

          String? ffmpegResult;
          if (lower.endsWith('.mp3')) {
            ffmpegResult = await FFmpegMetadata.embedMetadataToMp3(
              mp3Path: ffmpegTarget,
              coverPath: effectiveCoverPath,
              metadata: metadata,
              artistTagMode: artistTagMode,
            );
          } else if (lower.endsWith('.m4a') || lower.endsWith('.aac')) {
            ffmpegResult = await FFmpegMetadata.embedMetadataToM4a(
              m4aPath: ffmpegTarget,
              coverPath: effectiveCoverPath,
              metadata: metadata,
              artistTagMode: artistTagMode,
            );
          } else if (lower.endsWith('.opus') || lower.endsWith('.ogg')) {
            ffmpegResult = await FFmpegMetadata.embedMetadataToOpus(
              opusPath: ffmpegTarget,
              coverPath: effectiveCoverPath,
              metadata: metadata,
              artistTagMode: artistTagMode,
            );
          }

          if (ffmpegResult != null && tempPath != null && safUri != null) {
            final ok = await PlatformBridge.writeTempToSaf(
              ffmpegResult,
              safUri,
            );
            if (!ok && mounted) {
              messenger.hideCurrentSnackBar();
              await showReEnrichResultDialog(
                context,
                message: context.l10n.trackSaveFailed(
                  context.l10n.snackbarFailedToWriteStorage,
                ),
              );
              return;
            }
            await writeReEnrichSafSidecarLrc(
              safUri: safUri,
              reEnrichResult: result,
            );
          }

          if (ffmpegResult != null) {
            // Filesystem .lrc sidecar. SAF sidecar is written only after
            // writeTempToSaf succeeds.
            await writeReEnrichSidecarLrc(
              audioFilePath: cleanFilePath,
              reEnrichResult: result,
            );
            await _refreshEmbeddedCoverPreview(force: true);
            _markMetadataChanged();
            await _syncDownloadHistoryMetadata(
              hasLyrics: hasUsableLyricsContent(
                (result['lyrics'] ?? result['lyrics_lrc'])?.toString() ?? '',
              ),
            );
            await _checkEmbeddedLyrics();
            if (mounted) {
              messenger.hideCurrentSnackBar();
              await showReEnrichResultDialog(
                context,
                message: reEnrichCompletionMessage(context.l10n, result),
              );
            }
          } else if (mounted) {
            messenger.hideCurrentSnackBar();
            await showReEnrichResultDialog(
              context,
              message: context.l10n.trackReEnrichFfmpegFailed,
            );
          }
        } finally {
          for (final path in [downloadedCoverPath, tempPath]) {
            if (!_hasPath(path)) continue;
            try {
              await File(path!).delete();
            } catch (_) {}
          }
          if (_hasPath(extractedCoverPath)) {
            await _cleanupTempFileAndParent(extractedCoverPath);
          }
        }
      } else {
        if (mounted) {
          final error = context.friendlyError(
            result['error'],
            fallback: context.l10n.metadataSaveFailedFfmpeg,
          );
          messenger.hideCurrentSnackBar();
          await showReEnrichResultDialog(
            context,
            message: context.l10n.trackSaveFailed(error),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).hideCurrentSnackBar();
        await showReEnrichResultDialog(
          context,
          message: context.l10n.trackSaveFailed(context.friendlyError(e)),
        );
      }
    }
  }

  Future<void> _syncDownloadHistoryMetadata({bool? hasLyrics}) async {
    final resolvedHasLyrics =
        hasLyrics ?? (_embeddedLyricsChecked ? _lyricsEmbedded : null);
    if (_isLocalItem) {
      final item = _localLibraryItem;
      if (item == null) return;
      try {
        await LibraryDatabase.instance.updateAudioMetadata(
          item.id,
          explicit: isExplicit,
          hasLyrics: resolvedHasLyrics,
        );
        if (mounted) {
          _setState(() {
            _currentLocalLibraryItem = item.withAudioMetadata(
              explicit: isExplicit,
              hasLyrics: resolvedHasLyrics,
            );
          });
        }
        await ref.read(localLibraryProvider.notifier).reloadFromStorage();
      } catch (e) {
        _log.w('Failed to sync local library explicit metadata: $e');
      }
      return;
    }
    if (_downloadItem == null) return;

    String? normalizedOrNull(String? value) {
      if (value == null) return null;
      final trimmed = value.trim();
      if (trimmed.isEmpty) return null;
      return trimmed;
    }

    try {
      await ref
          .read(downloadHistoryProvider.notifier)
          .updateMetadataForItem(
            id: _downloadItem!.id,
            trackName: trackName,
            artistName: artistName,
            albumName: albumName,
            albumArtist: normalizedOrNull(albumArtist),
            isrc: normalizedOrNull(isrc),
            trackNumber: trackNumber,
            totalTracks: totalTracks,
            discNumber: discNumber,
            totalDiscs: totalDiscs,
            releaseDate: normalizedOrNull(releaseDate),
            genre: normalizedOrNull(genre),
            composer: normalizedOrNull(composer),
            label: normalizedOrNull(label),
            copyright: normalizedOrNull(copyright),
            explicit: isExplicit,
            hasLyrics: resolvedHasLyrics,
            lyricsMetadataScanVersion: resolvedHasLyrics == null ? null : 1,
          );
    } catch (e) {
      _log.w('Failed to sync download history metadata: $e');
    }
  }
}
