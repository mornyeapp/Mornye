// ignore_for_file: invalid_use_of_protected_member
part of 'artist_screen.dart';

extension _ArtistScreenDiscography on _ArtistScreenState {
  void _showDiscographyOptions(
    BuildContext context,
    ColorScheme colorScheme,
    List<ArtistAlbum> albums,
  ) {
    final albumsOnly = albums.where((a) => a.albumType == 'album').toList();
    final singles = albums
        .where((a) => a.albumType == 'single' || a.albumType == 'ep')
        .toList();

    final totalTracks = albums.fold<int>(0, (sum, a) => sum + a.totalTracks);
    final albumTracks = albumsOnly.fold<int>(
      0,
      (sum, a) => sum + a.totalTracks,
    );
    final singleTracks = singles.fold<int>(0, (sum, a) => sum + a.totalTracks);
    final pageContext = context;

    Widget buildSheet(BuildContext context) => AppBottomSheet(
      maxHeightFactor: 0.85,
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
              child: Row(
                children: [
                  if (!context.isMornye) ...[
                    Icon(Icons.download, color: colorScheme.primary),
                    const SizedBox(width: 12),
                  ],
                  Expanded(
                    child: Text(
                      context.l10n.discographyDownload,
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: context.isMornye
                            ? FontWeight.w600
                            : FontWeight.bold,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            // Material sheets separate the header by space; dividers are Mornye's.
            if (context.isMornye) const Divider(height: 1),
            if (albums.isNotEmpty)
              _DiscographyOptionTile(
                icon: Icons.library_music,
                title: context.l10n.discographyDownloadAll,
                subtitle: context.l10n.discographyDownloadAllSubtitle(
                  totalTracks,
                  albums.length,
                ),
                onTap: () {
                  Navigator.pop(context);
                  _downloadAlbums(pageContext, albums);
                },
              ),
            if (albumsOnly.isNotEmpty)
              _DiscographyOptionTile(
                icon: Icons.album,
                title: context.l10n.discographyAlbumsOnly,
                subtitle: context.l10n.discographyAlbumsOnlySubtitle(
                  albumTracks,
                  albumsOnly.length,
                ),
                onTap: () {
                  Navigator.pop(context);
                  _downloadAlbums(pageContext, albumsOnly);
                },
              ),
            if (singles.isNotEmpty)
              _DiscographyOptionTile(
                icon: Icons.music_note,
                title: context.l10n.discographySinglesOnly,
                subtitle: context.l10n.discographySinglesOnlySubtitle(
                  singleTracks,
                  singles.length,
                ),
                onTap: () {
                  Navigator.pop(context);
                  _downloadAlbums(pageContext, singles);
                },
              ),
            _DiscographyOptionTile(
              icon: Icons.checklist,
              title: context.l10n.discographySelectAlbums,
              subtitle: context.l10n.discographySelectAlbumsSubtitle,
              showDivider: false,
              onTap: () {
                Navigator.pop(context);
                enterSelectionMode(albums.first.id);
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );

    showAppModalBottomSheet<void>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      // The sheet forces the dark theme on its own glass.
      mornyeGlass: false,
      builder: (sheetContext) => sheetContext.isMornye
          ? Theme(
              data: MornyeTheme.fromContext(
                sheetContext,
                brightness: Brightness.dark,
              ),
              child: MornyeGlassPanel(
                tintOpacity: 0.78,
                child: Builder(builder: buildSheet),
              ),
            )
          : buildSheet(sheetContext),
    );
  }

  Future<void> _downloadAlbums(
    BuildContext context,
    List<ArtistAlbum> albums,
  ) async {
    final settings = ref.read(settingsProvider);
    if (settings.askQualityBeforeDownload || settings.allowQualityVariants) {
      DownloadServicePicker.show(
        context,
        recommendedService: _recommendedDownloadService(),
        onSelect: (quality, service) {
          _fetchAndQueueAlbums(albums, service, quality);
        },
      );
    } else {
      _fetchAndQueueAlbums(albums, settings.defaultService, null);
    }
  }

  Future<void> _downloadSelectedAlbums(
    BuildContext context,
    List<ArtistAlbum> albums,
  ) async {
    exitSelectionMode();
    await _downloadAlbums(context, albums);
  }

  Future<void> _fetchAndQueueAlbums(
    List<ArtistAlbum> albums,
    String service,
    String? qualityOverride, {
    bool addToPlaylist = false,
  }) async {
    if (!mounted || _isFetchingDiscography) return;

    final generation = ++_discographyFetchGeneration;
    setState(() => _isFetchingDiscography = true);

    final progressDialogKey = GlobalKey<_FetchingProgressDialogState>();
    unawaited(
      showAppDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => _FetchingProgressDialog(
          key: progressDialogKey,
          totalAlbums: albums.length,
          onCancel: () {
            _discographyFetchGeneration++;
            setState(() => _isFetchingDiscography = false);
            Navigator.pop(ctx);
          },
        ),
      ).whenComplete(() {
        if (mounted &&
            generation == _discographyFetchGeneration &&
            _isFetchingDiscography) {
          _discographyFetchGeneration++;
          setState(() => _isFetchingDiscography = false);
        }
      }),
    );

    final allTracks = <Track>[];
    int fetchedCount = 0;
    int failedCount = 0;

    for (final album in albums) {
      if (!mounted ||
          generation != _discographyFetchGeneration ||
          !_isFetchingDiscography) {
        break;
      }

      try {
        final tracks = await _fetchAlbumTracks(album);
        if (!mounted || generation != _discographyFetchGeneration) return;
        allTracks.addAll(tracks);
      } catch (e) {
        failedCount++;
      }
      if (!mounted || generation != _discographyFetchGeneration) return;

      fetchedCount++;

      if (mounted) {
        progressDialogKey.currentState?.updateProgress(
          fetchedCount,
          albums.length,
        );
      }
    }

    if (!mounted || generation != _discographyFetchGeneration) return;
    final cancelled = !_isFetchingDiscography;
    setState(() => _isFetchingDiscography = false);
    if (cancelled) return;

    if (mounted) {
      Navigator.of(context, rootNavigator: true).pop();
    }

    if (failedCount > 0 && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.l10n.discographyFailedToFetch)),
      );
    }

    if (allTracks.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(context.l10n.discographyNoAlbums)),
        );
      }
      return;
    }

    if (addToPlaylist) {
      await showAddTracksToPlaylistSheet(context, ref, allTracks);
      return;
    }

    final settings = ref.read(settingsProvider);
    final skipExisting =
        settings.deduplicateDownloads && !settings.allowQualityVariants;
    final historyLookups = allTracks
        .map(historyLookupForTrack)
        .toList(growable: false);
    final existingHistoryKeys = skipExisting
        ? await ref.read(
            downloadHistoryBatchExistsProvider(
              HistoryBatchLookupRequest(historyLookups),
            ).future,
          )
        : const <String>{};
    final tracksToQueue = <Track>[];
    int skippedCount = 0;

    for (var i = 0; i < allTracks.length; i++) {
      final track = allTracks[i];
      final isDownloaded =
          skipExisting &&
          existingHistoryKeys.contains(historyLookups[i].lookupKey);

      if (!isDownloaded) {
        tracksToQueue.add(track);
      } else {
        skippedCount++;
      }
    }

    if (tracksToQueue.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              context.l10n.discographySkippedDownloaded(0, skippedCount),
            ),
          ),
        );
      }
      return;
    }

    ref
        .read(downloadQueueProvider.notifier)
        .addMultipleToQueue(
          tracksToQueue,
          service,
          qualityOverride: qualityOverride,
        );

    if (mounted) {
      final message = skippedCount > 0
          ? context.l10n.discographySkippedDownloaded(
              tracksToQueue.length,
              skippedCount,
            )
          : context.l10n.discographyAddedToQueue(tracksToQueue.length);

      showAppSnackBar(
        context,
        content: Text(message),
        action: buildViewQueueSnackBarAction(context),
      );
    }
  }

  /// Reads [album]'s metadata from the provider it names, if any.
  Future<Map<String, dynamic>> Function()? _albumMetadataLoader(
    ArtistAlbum album,
  ) {
    final providerId = album.providerId;
    if (providerId == null || providerId.isEmpty) return null;
    return () => PlatformBridge.getProviderMetadata(
      providerId,
      'album',
      stripPrefixedResourceId(album.id),
    );
  }

  Future<List<Track>> _fetchAlbumTracks(ArtistAlbum album) async {
    final providerId = album.providerId;
    if (providerId != null && providerId.isNotEmpty) {
      final resourceId = stripPrefixedResourceId(album.id);
      final metadata = await PlatformBridge.getProviderMetadata(
        providerId,
        'album',
        resourceId,
      );
      if (metadata['track_list'] != null) {
        final tracksList = metadata['track_list'] as List<dynamic>;
        return tracksList
            .map((t) => _parseTrack(t as Map<String, dynamic>, album: album))
            .toList();
      }
    } else {
      final url = 'https://open.spotify.com/album/${album.id}';
      final result = await PlatformBridge.handleURLWithExtension(url);
      if (result != null && result['tracks'] != null) {
        final tracksList = result['tracks'] as List<dynamic>;
        return tracksList
            .map((t) => _parseTrack(t as Map<String, dynamic>, album: album))
            .toList();
      }
    }
    return [];
  }
}

class _DiscographyOptionTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final bool showDivider;

  const _DiscographyOptionTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.showDivider = true,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    if (context.isMornye) {
      final textTheme = Theme.of(context).textTheme;
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CupertinoButton(
              padding: const EdgeInsets.symmetric(vertical: 16),
              onPressed: onTap,
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(title, style: textTheme.bodyLarge),
                        const SizedBox(height: 4),
                        Text(
                          subtitle,
                          style: textTheme.bodyMedium?.copyWith(
                            color: colorScheme.onSurface.withValues(
                              alpha: 0.72,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 16),
                  Icon(
                    mornyeIconFor(icon),
                    size: 22,
                    color: colorScheme.onSurface,
                  ),
                ],
              ),
            ),
            if (showDivider) const Divider(height: 0.5, thickness: 0.5),
          ],
        ),
      );
    }
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 4),
      leading: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: colorScheme.secondaryContainer,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Icon(icon, color: colorScheme.onSecondaryContainer, size: 24),
      ),
      title: Text(title, style: const TextStyle(fontWeight: FontWeight.w500)),
      subtitle: Text(
        subtitle,
        style: TextStyle(color: colorScheme.onSurfaceVariant, fontSize: 12),
      ),
      trailing: Icon(Icons.chevron_right, color: colorScheme.onSurfaceVariant),
      onTap: onTap,
    );
  }
}

class _FetchingProgressDialog extends StatefulWidget {
  final int totalAlbums;
  final VoidCallback onCancel;

  const _FetchingProgressDialog({
    super.key,
    required this.totalAlbums,
    required this.onCancel,
  });

  @override
  State<_FetchingProgressDialog> createState() =>
      _FetchingProgressDialogState();
}

class _FetchingProgressDialogState extends State<_FetchingProgressDialog> {
  int _current = 0;
  int _total = 0;

  @override
  void initState() {
    super.initState();
    _total = widget.totalAlbums;
  }

  void updateProgress(int current, int total) {
    if (mounted) {
      setState(() {
        _current = current;
        _total = total;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final progress = _total > 0 ? _current / _total : 0.0;

    return AppAlertDialog(
      backgroundColor: colorScheme.surfaceContainerHigh,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 8),
          SizedBox(
            width: 64,
            height: 64,
            child: Stack(
              alignment: Alignment.center,
              children: [
                AppProgressIndicator.circular(
                  value: progress > 0 ? progress : null,
                  strokeWidth: 4,
                  trackColor: colorScheme.surfaceContainerHighest,
                ),
                Icon(Icons.library_music, color: colorScheme.primary, size: 24),
              ],
            ),
          ),
          const SizedBox(height: 20),
          Text(
            context.l10n.discographyFetchingTracks,
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          Text(
            context.l10n.discographyFetchingAlbum(_current, _total),
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: AppProgressIndicator.linear(
              value: progress > 0 ? progress : null,
              trackColor: colorScheme.surfaceContainerHighest,
              minHeight: 6,
            ),
          ),
        ],
      ),
      actions: [
        AppDialogAction(
          onPressed: widget.onCancel,
          child: Text(context.l10n.dialogCancel),
        ),
      ],
    );
  }
}
