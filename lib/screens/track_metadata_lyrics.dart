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
        padding: const EdgeInsets.all(_trackMetadataSectionPadding),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: _buildSectionTitle(context, context.l10n.trackLyrics),
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
                      onPressed: _fetchLyrics,
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
                  if (!_lyricsEmbedded && _canEditMetadataFile) ...[
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
                      onPressed: _fetchLyrics,
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
                  onPressed: () => _fetchLyrics(checkEmbedded: true),
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
    final lyrics = metadata['lyrics']?.toString() ?? '';
    if (hasUsableLyricsContent(lyrics)) return {'lyrics': lyrics, 'source': ''};
    // An Android document's .lrc file is out of the lyrics reader's reach.
    String? lrc;
    try {
      lrc = await const LyricsSidecarStore(
        extension: lrcExtension,
      ).read(sourcePath).timeout(const Duration(seconds: 5));
    } catch (e) {
      _log.d('Could not read the .lrc lyrics: $e');
    }
    return {
      'lyrics': lrc != null && hasUsableLyricsContent(lrc) ? lrc : lyrics,
      'source': '',
    };
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

  /// Fetches lyrics from online providers. Only called by user action.
  /// With [checkEmbedded], lyrics embedded in an existing file win; the
  /// "Load Lyrics" button uses that.
  Future<void> _fetchLyrics({bool checkEmbedded = false}) async {
    if (_lyricsLoading) return;

    _setState(() {
      _lyricsLoading = true;
      _lyricsError = null;
      _isInstrumental = false;
      _lyricsSource = null;
    });

    try {
      final durationMs = (duration ?? 0) * 1000;

      if (checkEmbedded && _fileExists) {
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
    if (_isNetworkItem) {
      await _embedNetworkLyrics();
      return;
    }

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

  Future<void> _embedNetworkLyrics() async {
    if (!_canEditMetadataFile) return;
    final sourcePath = cleanFilePath;
    final lyrics = _rawLyrics!;
    final artistTagMode = artistTagModeForExistingTags(
      ref.read(settingsProvider).artistTagMode,
    );
    final covers = MetadataCoverResources();
    _setState(() => _isEmbedding = true);
    try {
      final current = await readPlaybackFileMetadataWithRetry(sourcePath);
      if (!mounted || cleanFilePath != sourcePath) return;
      final fields = _metadataEditorValues(current)..['lyrics'] = lyrics;
      fields['track_total'] = fields.remove('total_tracks')!;
      fields['disc_total'] = fields.remove('total_discs')!;
      fields['compilation'] =
          fields['album_type']?.toLowerCase() == 'compilation' ? '1' : '0';
      final saved = await MetadataPersistenceService(covers: covers).save(
        MetadataSaveRequest(
          filePath: sourcePath,
          metadata: fields,
          artistTagMode: artistTagMode,
        ),
      );
      if (saved.failure != null) {
        throw saved.error ??
            StateError('Could not save lyrics to network storage');
      }
      final refreshed = await readPlaybackFileMetadataWithRetry(sourcePath);
      if (!mounted || cleanFilePath != sourcePath) return;
      _setState(() {
        _editedMetadata = refreshed;
        _rawLyrics = lyrics;
        _lyrics = cleanLyricsForDisplay(lyrics);
        _lyricsEmbedded = true;
        _embeddedLyricsChecked = true;
      });
      await _syncNetworkLibraryMetadata(refreshed);
      if (!mounted || cleanFilePath != sourcePath) return;
      _markMetadataChanged();
      showAppSnackBar(context, content: Text(context.l10n.trackLyricsEmbedded));
    } catch (error) {
      if (mounted && cleanFilePath == sourcePath) {
        showAppSnackBar(
          context,
          content: Text(
            context.friendlyError(
              error,
              fallback: context.l10n.snackbarFailedToEmbedLyrics,
            ),
          ),
        );
      }
    } finally {
      await covers.dispose();
      if (mounted && cleanFilePath == sourcePath) {
        _setState(() => _isEmbedding = false);
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

  /// A folder the user chose, as a SAF tree on Android and otherwise a path,
  /// with a security-scoped bookmark on iOS. Null when they cancel.
  Future<({String? treeUri, String? path, String? bookmark})?>
  _pickSidecarFolder() async {
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        final picked = await PlatformBridge.pickSafTree();
        final treeUri = picked?['tree_uri'] as String? ?? '';
        if (treeUri.isEmpty) return null;
        return (treeUri: treeUri, path: null, bookmark: null);
      case TargetPlatform.iOS:
        final picked = await PlatformBridge.pickIosDirectory();
        if (picked == null) return null;
        return (treeUri: null, path: picked.path, bookmark: picked.bookmark);
      default:
        final path = await FilePicker.getDirectoryPath();
        if (path == null) return null;
        return (treeUri: null, path: path, bookmark: null);
    }
  }

  String _networkSidecarSource(String fileName) {
    final uri = Uri.parse(cleanFilePath);
    final folder = uri.pathSegments.take(uri.pathSegments.length - 1);
    return NetworkStorageService.source(
      uri.host,
      [...folder, fileName].join('/'),
    );
  }

  /// Writes `baseName.extension` as a sidecar of the current track.
  ///
  /// `writeTo` renders the file at the given path and returns the bridge
  /// result, or null when it has already told the user why nothing was
  /// written. SAF and network tracks are rendered into a temp directory and
  /// published to the download tree or the scanned audio document's parent,
  /// or uploaded to the song's NAS folder, replacing a file of that name as
  /// a local save does; filesystem tracks are written next to the audio
  /// file. Once the audio file is gone, its old folder says nothing about
  /// where the song went, so the user picks the folder instead.
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
    final hasFile = _fileExists;
    final folder = hasFile ? null : await _pickSidecarFolder();
    if (!mounted) return;
    if (!hasFile && folder == null) {
      if (hideCurrentSnackBar) {
        ScaffoldMessenger.of(context).hideCurrentSnackBar();
      }
      return;
    }

    // Renders the file in a temp directory for `publish`, which says whether
    // it reached its place.
    Future<void> publishFromTemp(
      Future<bool> Function(String tempOutput) publish,
    ) async {
      final tempDir = await Directory.systemTemp.createTemp(tempDirPrefix);
      final tempOutput = '${tempDir.path}${Platform.pathSeparator}$fileName';
      try {
        final result = await writeTo(tempOutput);
        if (result == null) return;
        if (result['error'] != null) {
          if (mounted) {
            showMessage(
              context.l10n.trackSaveFailed(
                context.friendlyError(result['error']),
              ),
            );
          }
          return;
        }
        final published = await publish(tempOutput);
        if (mounted) {
          showMessage(
            published
                ? successMessage()
                : context.l10n.trackSaveFailed('No storage access'),
          );
        }
      } finally {
        try {
          await tempDir.delete(recursive: true);
        } catch (_) {}
      }
    }

    if (folder == null && _isNetworkItem) {
      await publishFromTemp((tempOutput) async {
        await NetworkFileEditor.instance.saveSidecar(
          _networkSidecarSource(fileName),
          File(tempOutput),
        );
        return true;
      });
      return;
    }

    if (folder == null ? _isSafFile : folder.treeUri != null) {
      final audioUri = cleanFilePath;
      final treeUri = folder?.treeUri ?? _downloadItem?.downloadTreeUri;
      final relativeDir = folder == null
          ? _downloadItem?.safRelativeDir ?? ''
          : '';
      await publishFromTemp((tempOutput) async {
        final safUri = treeUri != null && treeUri.isNotEmpty
            ? await PlatformBridge.createSafFileFromPath(
                treeUri: treeUri,
                relativeDir: relativeDir,
                fileName: fileName,
                mimeType: mimeType,
                srcPath: tempOutput,
              )
            : await PlatformBridge.writeSafSidecarFromPath(
                audioUri: audioUri,
                fileName: fileName,
                mimeType: mimeType,
                srcPath: tempOutput,
              );
        return safUri != null && safUri.isNotEmpty;
      });
      return;
    }

    final bookmark = folder?.bookmark;
    final access = bookmark == null
        ? null
        : await PlatformBridge.startAccessingIosBookmark(bookmark);
    if (bookmark != null && access == null) {
      if (mounted) {
        showMessage(context.l10n.trackSaveFailed('No storage access'));
      }
      return;
    }
    final dir = access?.path ?? folder?.path ?? _getFileDirectory();
    final outputPath = '$dir${Platform.pathSeparator}$fileName';

    final Map<String, dynamic>? result;
    try {
      result = await writeTo(outputPath);
    } finally {
      if (access != null) {
        await PlatformBridge.stopAccessingIosBookmark(access);
      }
    }
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
      final audioPath = cleanFilePath;
      final coverUrl = _coverUrl;
      final cachedCover = _embeddedCoverPreviewPath ?? _localCoverPath;
      final hasFile = _fileExists;
      final networkFile = _isNetworkItem;

      Future<bool> copyCover(String? path, String outputPath) async {
        if (path == null || path.isEmpty) return false;
        final uri = Uri.tryParse(path);
        final file = uri?.scheme == 'file' ? File.fromUri(uri!) : File(path);
        if (!await file.exists() || await file.length() == 0) return false;
        if (file.absolute.path != File(outputPath).absolute.path) {
          await file.copy(outputPath);
        }
        return true;
      }

      await _publishSidecarFile(
        baseName: baseName,
        tempDirPrefix: 'cover_',
        extension: 'jpg',
        mimeType: 'image/jpeg',
        successMessage: () => context.l10n.trackCoverSaved(baseName),
        hideCurrentSnackBar: false,
        writeTo: (outputPath) async {
          Map<String, dynamic>? result;
          if (networkFile) {
            // The artwork embedded in the NAS file, as Now Playing reads it.
            try {
              final metadata = await readPlaybackFileMetadataWithRetry(
                audioPath,
              );
              final embedded = metadata['cover_path']?.toString();
              if (await copyCover(embedded, outputPath)) {
                return {'success': true};
              }
            } catch (e) {
              _log.d('Could not read the network cover: $e');
            }
            if (coverUrl != null && coverUrl.isNotEmpty) {
              result = await PlatformBridge.downloadCoverToFile(
                coverUrl,
                outputPath,
              );
            }
          } else if (hasFile) {
            // Imported files carry their own embedded artwork as well.
            result = await PlatformBridge.extractCoverToFile(
              audioPath,
              outputPath,
            );
            if (result['error'] != null &&
                coverUrl != null &&
                coverUrl.isNotEmpty) {
              result = await PlatformBridge.downloadCoverToFile(
                coverUrl,
                outputPath,
              );
            }
          } else if (coverUrl != null && coverUrl.isNotEmpty) {
            result = await PlatformBridge.downloadCoverToFile(
              coverUrl,
              outputPath,
            );
          }
          if ((result == null || result['error'] != null) &&
              await copyCover(cachedCover, outputPath)) {
            return {'success': true};
          }
          if (result == null && mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text(context.l10n.trackCoverNoSource)),
            );
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

      final networkFile = _isNetworkItem;
      await _publishSidecarFile(
        baseName: baseName,
        tempDirPrefix: 'lyrics_',
        extension: 'lrc',
        mimeType: 'application/octet-stream',
        successMessage: () => context.l10n.trackLyricsSaved(baseName),
        hideCurrentSnackBar: true,
        writeTo: (outputPath) async {
          if (networkFile) {
            // The native writer reads only files on this device, so the
            // lyrics the NAS file holds are written here, as it would.
            try {
              final stored = await _readLocalLyrics(cleanFilePath);
              final lyrics = stored['lyrics']?.toString() ?? '';
              if (hasUsableLyricsContent(lyrics)) {
                await File(outputPath).writeAsString(lyrics);
                return {'success': true};
              }
            } catch (e) {
              _log.d('Could not read the network lyrics: $e');
            }
          }
          return PlatformBridge.fetchAndSaveLyrics(
            trackName: trackName,
            artistName: artistName,
            spotifyId: _spotifyId ?? '',
            durationMs: durationMs,
            outputPath: outputPath,
            audioFilePath: _fileExists && !networkFile ? cleanFilePath : '',
          );
        },
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
      final container = ProviderScope.containerOf(context, listen: false);
      final settings = ref.read(settingsProvider);
      final artistTagMode = settings.artistTagMode;
      final messenger = ScaffoldMessenger.of(context);
      final l10n = context.l10n;
      final source = cleanFilePath;
      final item = _reEnrichItem();
      await ref.read(settingsProvider.notifier).syncLyricsSettingsToBackend();
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(content: Text(l10n.trackReEnrichSearching)),
      );

      final durationMs = (duration ?? 0) * 1000;
      final request = <String, dynamic>{
        'file_path': source,
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

      // A common title also finds other songs, so the person picks the
      // result instead of the search guessing for them. The list comes from
      // every provider, unlike a batch, which stops at the first confident
      // one.
      final preview = await PlatformBridge.reEnrichFile({
        ...request,
        'preview_only': true,
        'include_candidates': true,
      });
      if (!mounted) return;
      messenger.hideCurrentSnackBar();
      final candidates = reEnrichCandidates(preview['candidates']);
      if (candidates.isEmpty) {
        await showReEnrichResultDialog(
          context,
          message: l10n.reEnrichNoResults,
        );
        return;
      }
      final chosen = await showReEnrichCandidateSheet(
        context,
        candidates: candidates,
        title: l10n.trackReEnrich,
        subtitle: [
          trackName,
          artistName,
        ].where((value) => value.trim().isNotEmpty).join(' · '),
        providerName: reEnrichProviderNames(ref.read(extensionProvider)),
      );
      if (chosen == null || !mounted) return;
      messenger.showSnackBar(
        SnackBar(content: Text(l10n.trackReEnrichSearching)),
      );

      // The pick is previewed, reviewed change by change and written through
      // the Library's re-enrich path, which saves the song's previous state.
      final runner = BatchReEnrichRunner(
        sourceTrackIds: {item.id: ?_spotifyId},
        saveMotionArtwork: (item, metadata) => saveReEnrichedMotionArtwork(
          container,
          metadata: metadata,
          albumName: item.albumName,
          artistName: item.artistName,
        ),
        beginPhase: () async {
          final settings = ref.read(settingsProvider);
          await ref
              .read(settingsProvider.notifier)
              .syncLyricsSettingsToBackend(settings: settings);
          return settings;
        },
      );
      final picked = await runner.choose(
        BatchReEnrichPreview(
          item: item,
          updateFields: ReEnrichFields.all,
          enrichedMetadata: const {},
          changes: const [],
          candidates: candidates,
        ),
        chosen,
      );
      if (!mounted) return;
      messenger.hideCurrentSnackBar();
      if (picked == null || picked.changes.isEmpty) {
        await showReEnrichResultDialog(
          context,
          message: picked == null
              ? l10n.trackSaveFailed(context.friendlyError(null))
              : l10n.trackReEnrichAlreadyMatches,
        );
        return;
      }

      final covers = MetadataCoverResources();
      final List<BatchReEnrichPreview>? approved;
      try {
        approved = await showReEnrichReviewSheet(
          context,
          previews: [picked],
          onChoose: runner.choose,
          providerName: reEnrichProviderNames(ref.read(extensionProvider)),
          chooseFields: true,
          loadCovers: (preview) => loadReEnrichReviewCovers(
            covers,
            preview,
            maxDimension: settings.embeddedCoverMaxDimension,
          ),
        );
      } finally {
        await covers.dispose();
      }
      final reviewed = approved?.singleOrNull;
      if (reviewed == null || reviewed.changes.isEmpty || !mounted) return;
      messenger.showSnackBar(
        SnackBar(content: Text(l10n.trackReEnrichProgress)),
      );

      var result = const <String, dynamic>{};
      Object? failure;
      final written = await runner.apply(
        [reviewed],
        shouldStop: () => !mounted,
        onProgress: (_, _) {},
        onResult: (value) => result = value,
        onFailed: (_, error) => failure = error,
      );
      if (!mounted) return;
      if (written == 0) {
        messenger.hideCurrentSnackBar();
        await showReEnrichResultDialog(
          context,
          message: l10n.trackSaveFailed(
            context.friendlyError(
              failure,
              fallback: l10n.metadataSaveFailedFfmpeg,
            ),
          ),
        );
        return;
      }
      await _reloadAfterReEnrichWrite(
        source,
        hasLyrics:
            hasUsableLyricsContent(
              (result['lyrics'] ?? result['lyrics_lrc'])?.toString() ?? '',
            )
            ? true
            : null,
      );
      if (!mounted) return;
      messenger.hideCurrentSnackBar();
      final undo = await showReEnrichResultDialog(
        context,
        message: reEnrichCompletionMessage(l10n, result),
        undoLabel: runner.undoSources.isEmpty
            ? null
            : l10n.trackReEnrichUndoAction,
      );
      if (undo && mounted && source == cleanFilePath) {
        await _undoReEnrich(batch: runner.undoBatch, confirm: false);
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

  /// The song as re-enrich compares and writes it: what this page shows.
  LocalLibraryItem _reEnrichItem() => LocalLibraryItem(
    id: _itemId,
    trackName: trackName,
    artistName: artistName,
    albumName: albumName,
    albumArtist: albumArtist,
    filePath: cleanFilePath,
    coverPath: _localCoverPath ?? _coverUrl,
    scannedAt: DateTime.now(),
    isrc: isrc,
    trackNumber: trackNumber,
    totalTracks: totalTracks,
    discNumber: discNumber,
    totalDiscs: totalDiscs,
    duration: duration,
    releaseDate: releaseDate,
    genre: genre,
    composer: composer,
    label: label,
    copyright: copyright,
    hasLyrics: _lyricsEmbedded,
    format: _storedAudioFormat,
  );

  Future<void> _reloadAfterReEnrichWrite(
    String sourcePath, {
    bool? hasLyrics,
  }) async {
    try {
      final refreshed = await readPlaybackFileMetadataWithRetry(sourcePath);
      if (!mounted || sourcePath != cleanFilePath) return;
      if (refreshed['error'] == null) {
        _setState(() => _editedMetadata = refreshed);
        if (_isNetworkItem) await _syncNetworkLibraryMetadata(refreshed);
      }
    } catch (error) {
      _log.w('Could not read the song after re-enrich: $error');
    }
    if (!mounted || sourcePath != cleanFilePath) return;
    if (!_isNetworkItem) await _refreshEmbeddedCoverPreview(force: true);
    if (!mounted || sourcePath != cleanFilePath) return;
    _markMetadataChanged();
    await _checkEmbeddedLyrics();
    await _syncDownloadHistoryMetadata(hasLyrics: hasLyrics);
    await _refreshReEnrichUndo();
  }

  /// Whether this song has a state saved before its last re-enrich.
  Future<void> _refreshReEnrichUndo() async {
    final source = cleanFilePath;
    final available =
        _fileExists && await ReEnrichUndo.instance.canUndo(source);
    if (mounted && source == cleanFilePath) {
      _setState(() => _reEnrichUndoAvailable = available);
    }
  }

  /// Restores the song's metadata from before its last re-enrich. With
  /// [batch], only a state that run saved is restored.
  Future<void> _undoReEnrich({String? batch, bool confirm = true}) async {
    final l10n = context.l10n;
    if (confirm &&
        !await showAppConfirmDialog(
          context,
          title: l10n.trackReEnrichUndoConfirmTitle,
          message: l10n.trackReEnrichUndoConfirmMessage,
          confirmLabel: l10n.trackReEnrichUndoAction,
        )) {
      return;
    }
    if (!mounted) return;
    final source = cleanFilePath;
    final result = await ReEnrichUndo.instance.restore(
      source,
      artistTagMode: artistTagModeForExistingTags(
        ref.read(settingsProvider).artistTagMode,
      ),
      batch: batch,
    );
    if (!mounted) return;
    if (result.restored) {
      await _reloadAfterReEnrichWrite(source);
    } else {
      await _refreshReEnrichUndo();
    }
    if (!mounted) return;
    await showReEnrichResultDialog(
      context,
      message: switch (result.outcome) {
        ReEnrichUndoOutcome.restored => l10n.trackReEnrichUndoDone,
        ReEnrichUndoOutcome.coverKept =>
          '${l10n.trackReEnrichUndoDone}\n${l10n.trackReEnrichUndoCoverKept}',
        _ => l10n.trackSaveFailed(context.friendlyError(result.error)),
      },
    );
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
