part of 'artist_screen.dart';

/// One artist shelf as a grid of covers. The list stays with the artist page,
/// which keeps loading its pages here while this grid scrolls.
class _ArtistAlbumsPage extends StatelessWidget {
  const _ArtistAlbumsPage({
    required this.title,
    required this.albums,
    required this.loadingMore,
    required this.changes,
    required this.onLoadMore,
    required this.onOpen,
    required this.showTypeBadge,
  });

  final String title;
  final List<ArtistAlbum> Function() albums;
  final bool Function() loadingMore;
  final Listenable changes;
  final VoidCallback onLoadMore;
  final ValueChanged<ArtistAlbum> onOpen;
  final bool showTypeBadge;

  // A grid shorter than its pane never scrolls, so metric changes count too.
  bool _onMetrics(ScrollMetrics metrics) {
    if (metrics.extentAfter < 480) onLoadMore();
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final captionHeight =
        artistAlbumSectionHeight(context) - artistAlbumTileSize(context);
    return Scaffold(
      body: NotificationListener<ScrollMetricsNotification>(
        onNotification: (notification) => _onMetrics(notification.metrics),
        child: NotificationListener<ScrollUpdateNotification>(
          onNotification: (notification) => _onMetrics(notification.metrics),
          child: CustomScrollView(
            slivers: [
              AppSliverHeader.page(title: title),
              ListenableBuilder(
                listenable: changes,
                builder: (context, _) {
                  final items = albums();
                  return SliverMainAxisGroup(
                    slivers: [
                      SliverPadding(
                        padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                        sliver: SliverLayoutInfoBuilder<double>(
                          select: (constraints) => constraints.crossAxisExtent,
                          builder: (context, width) {
                            const gap = 12.0;
                            final fit =
                                (width + gap) ~/ (searchCoverMinExtent + gap);
                            final count = fit < 2 ? 2 : fit;
                            final cover = (width - gap * (count - 1)) / count;
                            return SliverGrid.builder(
                              gridDelegate:
                                  SliverGridDelegateWithFixedCrossAxisCount(
                                    crossAxisCount: count,
                                    crossAxisSpacing: gap,
                                    mainAxisSpacing: gap,
                                    mainAxisExtent: cover + captionHeight,
                                  ),
                              itemCount: items.length,
                              itemBuilder: (context, index) => _ArtistAlbumCell(
                                key: ValueKey(items[index].id),
                                album: items[index],
                                coverSize: cover,
                                showTypeBadge: showTypeBadge,
                                onTap: () => onOpen(items[index]),
                              ),
                            );
                          },
                        ),
                      ),
                      if (loadingMore())
                        const SliverToBoxAdapter(
                          child: Padding(
                            padding: EdgeInsets.all(16),
                            child: Center(child: AppLoadingIndicator(size: 24)),
                          ),
                        ),
                    ],
                  );
                },
              ),
              const NavBarSliverSpacer(),
            ],
          ),
        ),
      ),
    );
  }
}

/// Mornye's shelf title: the title itself opens the grid, marked by a chevron.
class _AlbumShelfChevronHeading extends StatelessWidget {
  const _AlbumShelfChevronHeading({
    required this.label,
    required this.onTap,
    required this.child,
  });

  final String label;
  final VoidCallback onTap;
  final Widget child;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: context.l10n.searchShowAllCategory(label),
    onTap: onTap,
    excludeSemantics: true,
    child: MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 44),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            spacing: 4,
            children: [
              Flexible(child: child),
              Icon(
                mornyeArrowForward,
                size: 15,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

class _ArtistAlbumCell extends StatelessWidget {
  const _ArtistAlbumCell({
    super.key,
    required this.album,
    required this.coverSize,
    required this.showTypeBadge,
    required this.onTap,
  });

  final ArtistAlbum album;
  final double coverSize;
  final bool showTypeBadge;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: context.l10n.a11yOpenAlbum(album.name),
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox.square(
            dimension: coverSize,
            child: Stack(
              fit: StackFit.expand,
              children: [
                _ArtistAlbumCover(album: album, size: coverSize),
                DesktopCoverHover(borderRadius: BorderRadius.circular(8)),
                if (showTypeBadge) _ArtistAlbumTypeBadge(album: album),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Expanded(child: _ArtistAlbumCaption(album: album)),
        ],
      ),
    ),
  );
}

/// The cover of a shelf or grid tile, which saves from its own menu.
class _ArtistAlbumCover extends StatelessWidget {
  const _ArtistAlbumCover({
    required this.album,
    required this.size,
    this.enabled = true,
  });

  final ArtistAlbum album;
  final double size;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final fallback = Container(
      color: colorScheme.surfaceContainerHighest,
      child: Icon(Icons.album, color: colorScheme.onSurfaceVariant, size: 40),
    );
    return DownloadableCover(
      coverUrl: album.coverUrl,
      baseName: '${album.artists} - ${album.name}',
      enabled: enabled,
      child: SizedBox.square(
        dimension: size,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: album.coverUrl != null
              ? CachedCoverImage(
                  imageUrl: album.coverUrl!,
                  fit: BoxFit.cover,
                  placeholder: (context, url) => ShimmerLoading(
                    child: Container(
                      color: colorScheme.surfaceContainerHighest,
                    ),
                  ),
                  errorWidget: (context, url, error) => fallback,
                )
              : fallback,
        ),
      ),
    );
  }
}

class _ArtistAlbumTypeBadge extends StatelessWidget {
  const _ArtistAlbumTypeBadge({required this.album});

  final ArtistAlbum album;

  @override
  Widget build(BuildContext context) => PositionedDirectional(
    start: 6,
    bottom: 6,
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        album.albumType == 'ep'
            ? context.l10n.releaseTypeEp
            : context.l10n.releaseTypeSingle,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 11,
          fontWeight: FontWeight.w600,
        ),
      ),
    ),
  );
}

class _ArtistAlbumCaption extends StatelessWidget {
  const _ArtistAlbumCaption({required this.album});

  final ArtistAlbum album;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final date = album.releaseDate;
    final year = date.length >= 4 ? date.substring(0, 4) : date;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Flexible(
          child: Text(
            album.name,
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w500,
            ),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          album.totalTracks > 0
              ? '$year ${context.l10n.tracksCount(album.totalTracks)}'
              : year,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ],
    );
  }
}
