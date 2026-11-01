part of 'track_metadata_screen.dart';

extension _TrackMetadataFileActions on _TrackMetadataScreenState {
  void _showEditMetadataSheet(
    BuildContext context,
    WidgetRef ref,
    ColorScheme colorScheme,
  ) async {
    final sourcePath = cleanFilePath;
    Map<String, dynamic>? fileMetadata;
    try {
      final result = await readPlaybackFileMetadataWithRetry(sourcePath);
      if (result['error'] == null) {
        fileMetadata = result;
      }
    } catch (e) {
      if (sourcePath.startsWith('network://')) {
        if (context.mounted && sourcePath == cleanFilePath) {
          showAppSnackBar(context, content: Text(context.friendlyError(e)));
        }
        return;
      }
      debugPrint('readFileMetadata failed, using item data: $e');
    }

    final initialValues = _metadataEditorValues(fileMetadata);

    final initialDurationSeconds =
        readPositiveInt(fileMetadata?['duration']) ?? duration ?? 0;

    if (!context.mounted || sourcePath != cleanFilePath) return;

    final saved = await showAppModalBottomSheet<bool>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      dialogSize: AppDialogSize.wide,
      builder: (sheetContext) => EditMetadataSheet(
        colorScheme: colorScheme,
        initialValues: initialValues,
        filePath: sourcePath,
        sourceTrackId: _spotifyId,
        durationMs: initialDurationSeconds > 0
            ? initialDurationSeconds * 1000
            : 0,
        // Typed artist names are saved as entered, even in primary mode.
        artistTagMode: artistTagModeForExistingTags(
          ref.read(settingsProvider).artistTagMode,
        ),
      ),
    );

    if (saved == true && mounted && sourcePath == cleanFilePath) {
      ScaffoldMessenger.of(this.context).showSnackBar(
        SnackBar(content: Text(this.context.l10n.snackbarMetadataSaved)),
      );
      try {
        final refreshed = await readPlaybackFileMetadataWithRetry(sourcePath);
        if (!mounted || sourcePath != cleanFilePath) return;
        final refreshedLyrics = refreshed['lyrics']?.toString().trim() ?? '';
        final refreshedInstrumental = isInstrumentalLyricsMarker(
          refreshedLyrics,
        );
        final refreshedDisplayLyrics = cleanLyricsForDisplay(refreshedLyrics);
        _setState(() {
          _editedMetadata = refreshed;
          _lyricsError = null;
          _isInstrumental = refreshedInstrumental;
          _embeddedLyricsChecked = true;
          if (refreshedDisplayLyrics.isNotEmpty) {
            _lyrics = refreshedDisplayLyrics;
            _rawLyrics = refreshedLyrics;
            _lyricsSource = context.l10n.trackLyricsEmbeddedSource;
            _lyricsEmbedded = true;
          } else if (refreshedInstrumental) {
            _lyrics = null;
            _rawLyrics = null;
            _lyricsSource = context.l10n.trackLyricsEmbeddedSource;
            _lyricsEmbedded = true;
          } else {
            _lyrics = null;
            _rawLyrics = null;
            _lyricsSource = null;
            _lyricsEmbedded = false;
          }
        });
        if (_isNetworkItem) await _syncNetworkLibraryMetadata(refreshed);
      } catch (_) {
        if (mounted && sourcePath == cleanFilePath) _setState(() {});
      }
      if (!mounted || sourcePath != cleanFilePath) return;
      if (!_isNetworkItem) await _refreshEmbeddedCoverPreview(force: true);
      _markMetadataChanged();
      await _syncDownloadHistoryMetadata();
    }
  }

  Map<String, String> _metadataEditorValues(Map<String, dynamic>? metadata) {
    String val(String key, String? fallback) =>
        metadata?[key]?.toString() ?? fallback ?? '';

    return {
      'title': val('title', trackName),
      'artist': val('artist', artistName),
      'album': val('album', albumName),
      'album_artist': val('album_artist', albumArtist),
      'date': val('date', releaseDate),
      'track_number': val('track_number', trackNumber?.toString()),
      'total_tracks': val('total_tracks', totalTracks?.toString()),
      'disc_number': val('disc_number', discNumber?.toString()),
      'total_discs': val('total_discs', totalDiscs?.toString()),
      'genre': val('genre', genre),
      'isrc': val('isrc', isrc),
      'label': val('label', label),
      'copyright': val('copyright', copyright),
      'composer': val('composer', composer),
      'comment': val('comment', null),
      'album_type': val('album_type', albumType),
      'explicit': (parseExplicitFlag(metadata?['explicit']) ?? isExplicit)
          ? '1'
          : '0',
      'upc': val('upc', upc),
      'lyrics': val('lyrics', null),
    };
  }

  Future<void> _syncNetworkLibraryMetadata(
    Map<String, dynamic> metadata,
  ) async {
    final item = _localLibraryItem;
    if (item == null || !_isNetworkItem) return;
    final name = Uri.parse(item.filePath).pathSegments.last;
    var coverPath = item.coverPath;
    final cover = metadata['cover_path'];
    if (cover is String && cover.isNotEmpty) {
      try {
        coverPath = await promoteNetworkLibraryCover(
          cover,
          '${(await getApplicationSupportDirectory()).path}/library_covers',
        );
      } catch (error) {
        _log.w('Could not retain the edited network cover: $error');
      }
    }
    final row = {
      ...item.toJson(),
      ...networkLibraryRow(item.filePath, NetworkEntry(name, name), metadata),
      'coverPath': coverPath,
      // Force the next scan to verify the newly written remote file.
      'networkFileVersion': null,
    };
    await LibraryDatabase.instance.upsertBatchExcludingHistory([
      row,
    ], sourceId: item.sourceId);
    if (!mounted || cleanFilePath != item.filePath) return;
    _setState(() => _currentLocalLibraryItem = LocalLibraryItem.fromJson(row));
    await ref.read(localLibraryProvider.notifier).reloadFromStorage();
  }

  Future<void> _confirmDelete(
    BuildContext screenContext,
    WidgetRef ref,
    ColorScheme colorScheme,
  ) async {
    if (_isDeleting) return;
    final filePath = cleanFilePath;
    final cueItem = _isCueVirtualTrack ? _localLibraryItem : null;
    final l10n = screenContext.l10n;
    final confirmed = await showAppConfirmDialog(
      screenContext,
      title: l10n.trackDeleteConfirmTitle,
      message: _isNetworkItem
          ? l10n.trackDeleteNetworkConfirmMessage
          : l10n.trackDeleteConfirmMessage,
      confirmLabel: l10n.dialogDelete,
      destructive: true,
      filled: false,
      confirmStyle: TextButton.styleFrom(foregroundColor: colorScheme.error),
    );
    if (!confirmed || !mounted || filePath != cleanFilePath) return;
    _isDeleting = true;
    final container = ProviderScope.containerOf(context, listen: false);
    try {
      if (cueItem != null) {
        await container
            .read(localLibraryProvider.notifier)
            .removeItem(cueItem.id);
      } else {
        if (!await deleteFile(filePath)) {
          if (screenContext.mounted) {
            ScaffoldMessenger.of(screenContext).showSnackBar(
              SnackBar(
                content: Text(screenContext.l10n.snackbarDeleteTracksFailed(1)),
              ),
            );
          }
          return;
        }
        await removeDeletedLibraryFileEntries(container, [filePath]);
      }
      if (!mounted || filePath != cleanFilePath) return;
      if (ModalRoute.of(context)?.isCurrent != true) return;
      final navigator = Navigator.of(context);
      if (navigator.canPop()) navigator.pop(true);
    } finally {
      _isDeleting = false;
    }
  }

  void _closeOptionsMenuAndRun(BuildContext sheetContext, VoidCallback action) {
    Navigator.pop(sheetContext);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      action();
    });
  }

  Future<void> _openFile(BuildContext context, String filePath) async {
    if (isCueVirtualPath(filePath)) {
      _showCueVirtualTrackSnackBar(context);
      return;
    }
    try {
      final playbackCover =
          normalizeOptionalString(_localCoverPath) ??
          normalizeOptionalString(_embeddedCoverPreviewPath) ??
          normalizeOptionalString(_coverUrl) ??
          '';
      final durationSeconds = duration;
      await ref
          .read(playbackProvider.notifier)
          .playLocalPath(
            path: filePath,
            title: trackName,
            artist: artistName,
            album: albumName,
            coverUrl: playbackCover,
            duration: durationSeconds != null && durationSeconds > 0
                ? Duration(seconds: durationSeconds)
                : null,
            bitDepth: bitDepth,
            sampleRate: sampleRate,
            bitrate: _audioBitrate,
            format: _storedAudioFormat,
            explicit: isExplicit,
          );
    } catch (e) {
      if (context.mounted) showCannotOpenFileSnackBar(context, e);
    }
  }

  void _copyToClipboard(BuildContext context, String text) {
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(context.l10n.trackCopiedToClipboard),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  Future<void> _shareFile(BuildContext context) async {
    if (_isCueVirtualTrack) {
      _showCueVirtualTrackSnackBar(context);
      return;
    }

    String sharePath = cleanFilePath;
    if (!await fileExists(sharePath)) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(context.l10n.snackbarFileNotFound)),
        );
      }
      return;
    }

    final shareTitle = '$trackName - $artistName';

    // For SAF content URIs, use native share intent directly (zero-copy)
    if (isContentUri(sharePath)) {
      try {
        await PlatformBridge.shareContentUri(sharePath, title: shareTitle);
      } catch (_) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                context.l10n.snackbarCannotOpenFile('Failed to share file'),
              ),
            ),
          );
        }
      }
      return;
    }

    await SharePlus.instance.share(
      ShareParams(files: [XFile(sharePath)], text: shareTitle),
    );
  }

  String _formatFullDate(DateTime date) {
    return '${date.day} ${shortMonthNames[date.month - 1]} ${date.year}, '
        '${date.hour.toString().padLeft(2, '0')}:'
        '${date.minute.toString().padLeft(2, '0')}';
  }

  IconData _getServiceIcon(String service) {
    switch (service.toLowerCase()) {
      case MusicServices.tidal:
        return Icons.waves;
      case MusicServices.qobuz:
        return Icons.album;
      case MusicServices.amazon:
        return Icons.shopping_cart;
      default:
        return Icons.cloud_download;
    }
  }
}
