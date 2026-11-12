part of 'home_tab.dart';

class _SearchProviderDropdown extends ConsumerWidget {
  final VoidCallback? onProviderChanged;

  const _SearchProviderDropdown({this.onProviderChanged});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rawCurrentProvider = ref.watch(
      settingsProvider.select((s) => s.searchProvider),
    );
    final extensions = ref.watch(extensionProvider.select((s) => s.extensions));
    final providerReadiness = ref.watch(
      extensionProvider.select(
        (s) => (isInitialized: s.isInitialized, error: s.error),
      ),
    );
    final colorScheme = Theme.of(context).colorScheme;

    final searchProviders = extensions
        .where((ext) => ext.enabled && ext.hasCustomSearch)
        .toList();
    final hasAnyProvider = searchProviders.isNotEmpty;
    final isProviderLoading =
        !providerReadiness.isInitialized && providerReadiness.error == null;

    if (!hasAnyProvider) {
      return Padding(
        padding: const EdgeInsetsDirectional.only(start: 12, end: 8),
        child: SizedBox(
          width: 28,
          height: 28,
          child: Center(
            child: isProviderLoading
                ? AppLoadingIndicator(size: 18, color: colorScheme.primary)
                : Icon(
                    Icons.search_off,
                    size: 20,
                    color: colorScheme.onSurfaceVariant,
                  ),
          ),
        ),
      );
    }

    final resolvedCurrentProvider =
        rawCurrentProvider != null &&
            rawCurrentProvider.isNotEmpty &&
            searchProviders.any((e) => e.id == rawCurrentProvider)
        ? rawCurrentProvider
        : HomeSearchProviderPolicy.defaultExtension(searchProviders)?.id;
    final currentProvider =
        resolvedCurrentProvider != null && resolvedCurrentProvider.isNotEmpty
        ? resolvedCurrentProvider
        : null;

    Extension? currentExt;
    if (currentProvider != null && currentProvider.isNotEmpty) {
      currentExt = searchProviders
          .where((e) => e.id == currentProvider)
          .firstOrNull;
    }

    IconData displayIcon = Icons.search;
    String? iconPath;
    if (currentExt != null) {
      iconPath = currentExt.iconPath;
      if (currentExt.searchBehavior?.icon != null) {
        displayIcon = _getIconFromName(currentExt.searchBehavior!.icon!);
      }
    }

    return Padding(
      padding: const EdgeInsetsDirectional.only(start: 8),
      child: AppMenuButton<String>(
        icon: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (iconPath != null && iconPath.isNotEmpty)
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: Image(
                  image: ExtensionIconImage(
                    FileImage(File(iconPath)),
                    extent: (20 * MediaQuery.devicePixelRatioOf(context))
                        .ceil(),
                  ),
                  width: 20,
                  height: 20,
                  fit: BoxFit.cover,
                  errorBuilder: (_, e, st) => Icon(displayIcon, size: 20),
                ),
              )
            else
              Icon(displayIcon, size: 20),
            const SizedBox(width: 2),
            Icon(
              Icons.arrow_drop_down,
              size: 16,
              color: colorScheme.onSurfaceVariant,
            ),
          ],
        ),
        tooltip: context.l10n.homeChangeSearchProviderTooltip,
        offset: const Offset(0, 40),
        alignStart: true,
        onSelected: (providerId) {
          ref.read(settingsProvider.notifier).setSearchProvider(providerId);
          onProviderChanged?.call();
        },
        items: [
          for (final ext in searchProviders)
            AppMenuItem(
              value: ext.id,
              label: ext.displayName,
              selected: currentProvider == ext.id,
              leading: ext.iconPath != null && ext.iconPath!.isNotEmpty
                  ? ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: Image(
                        image: ExtensionIconImage(
                          FileImage(File(ext.iconPath!)),
                          extent: (20 * MediaQuery.devicePixelRatioOf(context))
                              .ceil(),
                        ),
                        width: 20,
                        height: 20,
                        fit: BoxFit.cover,
                        errorBuilder: (_, e, st) => Icon(
                          _getIconFromName(ext.searchBehavior?.icon),
                          size: 20,
                        ),
                      ),
                    )
                  : Icon(_getIconFromName(ext.searchBehavior?.icon), size: 20),
            ),
        ],
      ),
    );
  }

  IconData _getIconFromName(String? iconName) {
    switch (iconName) {
      case 'video':
      case 'movie':
        return Icons.video_library;
      case 'music':
        return Icons.music_note;
      case 'podcast':
        return Icons.podcasts;
      case 'book':
      case 'audiobook':
        return Icons.menu_book;
      case 'cloud':
        return Icons.cloud;
      case 'download':
        return Icons.download;
      default:
        return Icons.search;
    }
  }
}

class _TrackItemWithStatus extends ConsumerWidget {
  final Track track;
  final bool showDivider;
  final void Function({bool forceQualityPicker}) onDownload;
  final String? searchExtensionId;
  final bool showLocalLibraryIndicator;
  final Map<String, (double, double)> thumbnailSizesByExtensionId;
  final VoidCallback onSaveCover;

  /// Resolved by the result page via one batch lookup instead of a per-row
  /// exists query (which in SAF mode also costs a bridge call per row).
  final bool isInHistory;

  const _TrackItemWithStatus({
    super.key,
    required this.track,
    required this.showDivider,
    required this.onDownload,
    required this.searchExtensionId,
    required this.showLocalLibraryIndicator,
    required this.thumbnailSizesByExtensionId,
    required this.isInHistory,
    required this.onSaveCover,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colorScheme = Theme.of(context).colorScheme;

    final isQueued = ref.watch(
      downloadQueueLookupProvider.select(
        (lookup) => lookup.byTrackId.containsKey(track.id),
      ),
    );

    final isInLocalLibrary = showLocalLibraryIndicator
        ? ref.watch(
            localLibraryProvider.select(
              (state) => state.existsInLibrary(
                isrc: track.isrc,
                trackName: track.name,
                artistName: track.artistName,
              ),
            ),
          )
        : false;

    double thumbWidth = 56;
    double thumbHeight = 56;

    final extensionId = track.source ?? searchExtensionId;
    final thumbSize = extensionId == null
        ? null
        : thumbnailSizesByExtensionId[extensionId];
    if (thumbSize != null) {
      thumbWidth = thumbSize.$1;
      thumbHeight = thumbSize.$2;
    }

    final hasCover = track.coverUrl?.isNotEmpty == true;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        DesktopContextMenuRegion(
          onContextMenu: (position) =>
              TrackCollectionQuickActions.showTrackOptionsSheet(
                context,
                ref,
                track,
                position: position,
                hasLocalPlaybackCandidate: isInHistory || isInLocalLibrary,
              ),
          child: InkWell(
            onTap: () => activate(
              context,
              ref,
              track,
              isQueued: isQueued,
              isInHistory: isInHistory,
              isInLocalLibrary: isInLocalLibrary,
              onDownload: onDownload,
            ),
            onLongPress: () =>
                TrackCollectionQuickActions.showTrackOptionsSheet(
                  context,
                  ref,
                  track,
                  hasLocalPlaybackCandidate: isInHistory || isInLocalLibrary,
                ),
            splashColor: colorScheme.primary.withValues(alpha: 0.12),
            highlightColor: colorScheme.primary.withValues(alpha: 0.08),
            child: Padding(
              padding: EdgeInsetsDirectional.fromSTEB(
                12,
                context.tokens.trackRowPaddingV,
                6,
                context.tokens.trackRowPaddingV,
              ),
              child: Row(
                children: [
                  Semantics(
                    label:
                        '${context.l10n.dialogDownload} '
                        '${context.l10n.editMetadataFieldCover}: ${track.name}',
                    button: hasCover,
                    onLongPress: hasCover ? onSaveCover : null,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      excludeFromSemantics: true,
                      onLongPress: hasCover ? onSaveCover : null,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(10),
                        child: hasCover
                            ? CachedCoverImage(
                                imageUrl: track.coverUrl!,
                                width: thumbWidth,
                                height: thumbHeight,
                                fit: BoxFit.cover,
                              )
                            : Container(
                                width: thumbWidth,
                                height: thumbHeight,
                                color: colorScheme.surfaceContainerHighest,
                                child: Icon(
                                  Icons.music_note,
                                  color: colorScheme.onSurfaceVariant,
                                ),
                              ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          track.name,
                          style: Theme.of(context).textTheme.bodyMedium
                              ?.copyWith(
                                fontWeight: context.isMornye
                                    ? FontWeight.w600
                                    : FontWeight.w500,
                              ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 2),
                        TrackMetadataBadgesLine(
                          primary: ClickableArtistName(
                            artistName: track.artistName,
                            artistId: track.artistId,
                            coverUrl: track.coverUrl,
                            extensionId: extensionId,
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(color: colorScheme.onSurfaceVariant),
                          ),
                          badges: [
                            ...buildQualityBadges(
                              audioQuality: track.audioQuality,
                              audioModes: track.audioModes,
                              colorScheme: colorScheme,
                              explicit: track.isExplicit,
                            ),
                            if (isInLocalLibrary) const InLibraryBadge(),
                          ],
                        ),
                      ],
                    ),
                  ),
                  OnlinePlayButton(tracks: [track], index: 0),
                  PreviewButton(track: track),
                  TrackCollectionQuickActions(
                    track: track,
                    hasLocalPlaybackCandidate: isInHistory || isInLocalLibrary,
                  ),
                ],
              ),
            ),
          ),
        ),
        if (showDivider)
          Divider(
            height: 1,
            thickness: 1,
            indent: thumbWidth + 24,
            endIndent: 12,
            color: colorScheme.outlineVariant.withValues(alpha: 0.3),
          ),
      ],
    );
  }

  /// A tap on a search song: skip a queued song, refuse a duplicate unless
  /// variants are allowed, otherwise download it. The desktop song table
  /// runs the same on a click, reading the queue and library itself.
  static Future<void> activate(
    BuildContext context,
    WidgetRef ref,
    Track track, {
    required bool isQueued,
    required bool isInHistory,
    required bool isInLocalLibrary,
    required void Function({bool forceQualityPicker}) onDownload,
  }) async {
    if (isQueued) return;

    final settings = ref.read(settingsProvider);
    final allowExistingDownload =
        settings.allowQualityVariants || !settings.deduplicateDownloads;

    if (!allowExistingDownload && isInLocalLibrary) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(context.l10n.snackbarAlreadyInLibrary(track.name)),
          ),
        );
      }
      return;
    }

    if (!allowExistingDownload) {
      final historyNotifier = ref.read(downloadHistoryProvider.notifier);
      final historyItem = await historyNotifier.findExistingTrackAsync(
        historyLookupForTrack(track),
      );
      if (historyItem != null) {
        final exists = await fileExists(historyItem.filePath);
        if (exists) {
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  context.l10n.snackbarAlreadyDownloaded(track.name),
                ),
              ),
            );
          }
          return;
        } else {
          historyNotifier.removeFromHistory(historyItem.id);
        }
      }
    }

    onDownload(
      forceQualityPicker:
          settings.allowQualityVariants && (isInHistory || isInLocalLibrary),
    );
  }
}

class _CollectionItemWidget extends StatelessWidget {
  final Track item;
  final bool showDivider;
  final VoidCallback onTap;
  final VoidCallback onSaveCover;

  const _CollectionItemWidget({
    super.key,
    required this.item,
    required this.showDivider,
    required this.onTap,
    required this.onSaveCover,
  });

  /// The artist or owner of [item], or its kind when the provider gives
  /// none.
  static String subtitleOf(BuildContext context, Track item) {
    if (item.artistName.isNotEmpty) return item.artistName;
    if (item.isPlaylistItem) return context.l10n.recentTypePlaylist;
    if (item.isArtistItem) return context.l10n.recentTypeArtist;
    return context.l10n.recentTypeAlbum;
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isPlaylist = item.isPlaylistItem;
    final isArtist = item.isArtistItem;

    IconData placeholderIcon = Icons.album;
    if (isPlaylist) placeholderIcon = Icons.playlist_play;
    if (isArtist) placeholderIcon = Icons.person;

    final hasCover = item.coverUrl != null && item.coverUrl!.isNotEmpty;
    final image = hasCover
        ? CachedCoverImage(
            imageUrl: item.coverUrl!,
            width: 56,
            height: 56,
            fit: BoxFit.cover,
          )
        : Container(
            width: 56,
            height: 56,
            color: colorScheme.surfaceContainerHighest,
            child: Icon(placeholderIcon, color: colorScheme.onSurfaceVariant),
          );
    final cover = Semantics(
      label:
          '${context.l10n.dialogDownload} '
          '${context.l10n.editMetadataFieldCover}: ${item.name}',
      button: hasCover,
      onLongPress: hasCover ? onSaveCover : null,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        excludeFromSemantics: true,
        onLongPress: hasCover ? onSaveCover : null,
        child: isArtist
            ? AppShapeClip(
                kind: AppShapes.artist,
                fallbackRadius: BorderRadius.circular(28),
                child: image,
              )
            : ClipRRect(borderRadius: BorderRadius.circular(10), child: image),
      ),
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        InkWell(
          onTap: onTap,
          splashColor: colorScheme.primary.withValues(alpha: 0.12),
          highlightColor: colorScheme.primary.withValues(alpha: 0.08),
          child: Padding(
            padding: EdgeInsets.symmetric(
              horizontal: 12,
              vertical: context.tokens.trackRowPaddingV,
            ),
            child: Row(
              children: [
                cover,
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        item.name,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          fontWeight: context.isMornye
                              ? FontWeight.w600
                              : FontWeight.w500,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        subtitleOf(context, item),
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                if (!context.isMornye)
                  Icon(
                    Icons.chevron_right,
                    color: colorScheme.onSurfaceVariant,
                    size: 24,
                  ),
              ],
            ),
          ),
        ),
        if (showDivider)
          Divider(
            height: 1,
            thickness: 1,
            indent: 80,
            endIndent: 12,
            color: colorScheme.outlineVariant.withValues(alpha: 0.3),
          ),
      ],
    );
  }
}

class _DownloadedOrRemoteCover extends StatefulWidget {
  final String? downloadedFilePath;
  final String? imageUrl;
  final double width;
  final double height;
  final BorderRadius borderRadius;
  final IconData fallbackIcon;
  final double fallbackIconSize;
  final ColorScheme colorScheme;

  const _DownloadedOrRemoteCover({
    required this.downloadedFilePath,
    required this.imageUrl,
    required this.width,
    required this.height,
    required this.borderRadius,
    required this.fallbackIcon,
    required this.colorScheme,
    this.fallbackIconSize = 24,
  });

  @override
  State<_DownloadedOrRemoteCover> createState() =>
      _DownloadedOrRemoteCoverState();
}

class _DownloadedOrRemoteCoverState extends State<_DownloadedOrRemoteCover> {
  String? _embeddedCoverPath;
  bool _refreshScheduled = false;

  @override
  void initState() {
    super.initState();
    _embeddedCoverPath = _resolveEmbeddedCoverPath();
  }

  @override
  void didUpdateWidget(covariant _DownloadedOrRemoteCover oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.downloadedFilePath != widget.downloadedFilePath ||
        oldWidget.imageUrl != widget.imageUrl) {
      final nextPath = _resolveEmbeddedCoverPath();
      if (nextPath != _embeddedCoverPath) {
        setState(() => _embeddedCoverPath = nextPath);
      }
    }
  }

  String? _resolveEmbeddedCoverPath() {
    final filePath = widget.downloadedFilePath;
    if (filePath == null || filePath.isEmpty) return null;
    return DownloadedEmbeddedCoverResolver.resolve(
      filePath,
      onChanged: _onEmbeddedCoverChanged,
    );
  }

  void _onEmbeddedCoverChanged() {
    if (!mounted || _refreshScheduled) return;
    _refreshScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _refreshScheduled = false;
      if (!mounted) return;
      final nextPath = _resolveEmbeddedCoverPath();
      if (nextPath != _embeddedCoverPath) {
        setState(() => _embeddedCoverPath = nextPath);
      }
    });
  }

  Widget _fallback() {
    return Container(
      width: widget.width,
      height: widget.height,
      color: widget.colorScheme.surfaceContainerHighest,
      child: Icon(
        widget.fallbackIcon,
        color: widget.colorScheme.onSurfaceVariant,
        size: widget.fallbackIconSize,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cacheWidth = (widget.width * 2).round();
    final cacheHeight = (widget.height * 2).round();

    Widget child;
    if (_embeddedCoverPath != null) {
      child = Image.file(
        File(_embeddedCoverPath!),
        width: widget.width,
        height: widget.height,
        fit: BoxFit.cover,
        cacheWidth: cacheWidth,
        cacheHeight: cacheHeight,
        gaplessPlayback: true,
        filterQuality: FilterQuality.low,
        errorBuilder: (_, _, _) => _fallback(),
      );
    } else if (widget.imageUrl != null && widget.imageUrl!.isNotEmpty) {
      child = CachedCoverImage(
        imageUrl: widget.imageUrl!,
        width: widget.width,
        height: widget.height,
        fit: BoxFit.cover,
        memCacheWidth: cacheWidth,
        memCacheHeight: cacheHeight,
        errorWidget: (_, _, _) => _fallback(),
      );
    } else {
      child = _fallback();
    }

    return ClipRRect(borderRadius: widget.borderRadius, child: child);
  }
}

class _QuickPicksPageView extends StatefulWidget {
  final ExploreSection section;
  final ColorScheme colorScheme;
  final int itemsPerPage;
  final int totalPages;
  final void Function(ExploreItem, BuildContext) onItemTap;
  final void Function(ExploreItem, BuildContext) onItemMenu;

  const _QuickPicksPageView({
    required this.section,
    required this.colorScheme,
    required this.itemsPerPage,
    required this.totalPages,
    required this.onItemTap,
    required this.onItemMenu,
  });

  @override
  State<_QuickPicksPageView> createState() => _QuickPicksPageViewState();
}

class _QuickPicksPageViewState extends State<_QuickPicksPageView> {
  int _currentPage = 0;
  late PageController _pageController;

  @override
  void initState() {
    super.initState();
    _pageController = PageController();
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Text(
            widget.section.title,
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
          ),
        ),
        SizedBox(
          height: widget.itemsPerPage * 64.0,
          child: PageView.builder(
            controller: _pageController,
            itemCount: widget.totalPages,
            onPageChanged: (page) {
              setState(() => _currentPage = page);
            },
            itemBuilder: (context, pageIndex) {
              final startIndex = pageIndex * widget.itemsPerPage;
              final endIndex = (startIndex + widget.itemsPerPage).clamp(
                0,
                widget.section.items.length,
              );
              final pageItemCount = endIndex - startIndex;

              return Column(
                children: List.generate(pageItemCount, (index) {
                  final item = widget.section.items[startIndex + index];
                  return KeyedSubtree(
                    key: ValueKey(
                      'quick-pick-${item.type}-${item.id}-${item.uri}',
                    ),
                    child: Builder(
                      builder: (itemContext) =>
                          _buildQuickPickItem(itemContext, item),
                    ),
                  );
                }),
              );
            },
          ),
        ),
        if (widget.totalPages > 1)
          Padding(
            padding: const EdgeInsets.only(top: 8, bottom: 4),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: List.generate(widget.totalPages, (index) {
                final isActive = index == _currentPage;
                return AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  width: isActive ? 8 : 6,
                  height: isActive ? 8 : 6,
                  margin: const EdgeInsets.symmetric(horizontal: 3),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: isActive
                        ? widget.colorScheme.primary
                        : widget.colorScheme.onSurfaceVariant.withValues(
                            alpha: 0.3,
                          ),
                  ),
                );
              }),
            ),
          ),
      ],
    );
  }

  Widget _buildQuickPickItem(BuildContext itemContext, ExploreItem item) {
    return InkWell(
      onTap: () => widget.onItemTap(item, itemContext),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            DownloadableCover(
              coverUrl: item.coverUrl,
              baseName: '${item.artists} - ${item.name}',
              child: ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: item.coverUrl != null && item.coverUrl!.isNotEmpty
                    ? CachedCoverImage(
                        imageUrl: item.coverUrl!,
                        width: 48,
                        height: 48,
                        fit: BoxFit.cover,
                        errorWidget: (context, url, error) => Container(
                          width: 48,
                          height: 48,
                          color: widget.colorScheme.surfaceContainerHighest,
                          child: Icon(
                            Icons.music_note,
                            color: widget.colorScheme.onSurfaceVariant,
                            size: 24,
                          ),
                        ),
                      )
                    : Container(
                        width: 48,
                        height: 48,
                        color: widget.colorScheme.surfaceContainerHighest,
                        child: Icon(
                          Icons.music_note,
                          color: widget.colorScheme.onSurfaceVariant,
                          size: 24,
                        ),
                      ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  ExplicitTrackTitle(
                    title: item.name,
                    explicit: item.explicit == true,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: widget.colorScheme.onSurface,
                    ),
                  ),
                  if (item.artists.isNotEmpty)
                    ClickableArtistName(
                      artistName: item.artists,
                      coverUrl: item.coverUrl,
                      extensionId: item.providerId,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: widget.colorScheme.onSurfaceVariant,
                      ),
                    ),
                ],
              ),
            ),
            Builder(
              builder: (buttonContext) => AppIconButton(
                tooltip: MaterialLocalizations.of(context).showMenuTooltip,
                icon: Icon(
                  Icons.more_vert,
                  color: widget.colorScheme.onSurfaceVariant,
                  size: 20,
                ),
                onPressed: () => widget.onItemMenu(item, buttonContext),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
