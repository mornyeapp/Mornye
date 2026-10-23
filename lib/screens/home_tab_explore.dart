part of 'home_tab.dart';

extension _HomeTabExploreUI on _HomeTabState {
  List<Widget> _buildExploreSections(
    List<ExploreSection> sections,
    String? greeting,
    ColorScheme colorScheme,
  ) {
    final hasGreeting =
        !context.isMornye && greeting != null && greeting.isNotEmpty;
    final isTablet = MediaQuery.sizeOf(context).shortestSide >= 600;
    final sectionOffset = hasGreeting ? 1 : 0;
    final totalCount = sections.length + sectionOffset + 1;

    return [
      SliverList(
        delegate: SliverChildBuilderDelegate((context, index) {
          if (hasGreeting && index == 0) {
            return Padding(
              padding: EdgeInsets.fromLTRB(
                16 + wideListInset(context),
                12,
                16 + wideListInset(context),
                4,
              ),
              child: Text(
                greeting,
                style:
                    (isTablet
                            ? Theme.of(context).textTheme.headlineMedium
                            : Theme.of(context).textTheme.headlineSmall)
                        ?.copyWith(fontWeight: FontWeight.bold),
              ),
            );
          }

          final sectionIndex = index - sectionOffset;
          if (sectionIndex < sections.length) {
            final section = sections[sectionIndex];
            return KeyedSubtree(
              key: ValueKey('explore-section-${section.uri}-${section.title}'),
              child: _buildExploreSection(section, colorScheme),
            );
          }

          return const SizedBox(height: 24);
        }, childCount: totalCount),
      ),
    ];
  }

  Widget _buildExploreSection(ExploreSection section, ColorScheme colorScheme) {
    if (section.isFeatured) {
      return ExploreFeaturedSection(
        section: section,
        onItemTap: _navigateToExploreItem,
      );
    }
    final sectionHeight = _exploreSectionHeight(context);
    final isTablet = MediaQuery.sizeOf(context).shortestSide >= 600;
    if (section.isYTMusicQuickPicks) {
      return _buildYTMusicQuickPicksSection(section, colorScheme);
    }

    // Titles and the first card line up with the centered column on tablets;
    // the carousel itself still scrolls edge to edge.
    final inset = wideListInset(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(16 + inset, 20, 16 + inset, 12),
          child: Text(
            section.title,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
              fontSize: isTablet ? 20 : null,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
        SizedBox(
          height: sectionHeight,
          child: DesktopScrollArrows(
            builder: (context, controller) => ListView.builder(
              controller: controller,
              scrollDirection: Axis.horizontal,
              padding: EdgeInsets.symmetric(horizontal: 12 + inset),
              itemCount: section.items.length,
              itemBuilder: (context, index) {
                final item = section.items[index];
                return StaggeredListItem(
                  key: ValueKey(
                    'explore-item-${item.type}-${item.id}-${item.uri}',
                  ),
                  index: index,
                  staggerDelay: const Duration(milliseconds: 50),
                  child: Builder(
                    builder: (itemContext) =>
                        _buildExploreItem(itemContext, item, colorScheme),
                  ),
                );
              },
            ),
          ),
        ),
      ],
    );
  }

  /// Skeleton mirroring [_buildExploreSection]'s layout — album cards or
  /// artist circles — shown while the home feed loads. Wrap in
  /// [ShimmerLoading] for the sweep effect.
  Widget _buildExploreSectionSkeleton({required bool isArtist}) {
    final cardSize = _exploreCardSize(context);
    final coverSize = _exploreCoverSize(context);
    final inset = wideListInset(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(16 + inset, 20, 16 + inset, 12),
          child: const SkeletonBox(width: 140, height: 20, borderRadius: 4),
        ),
        SizedBox(
          height: _exploreSectionHeight(context),
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            physics: const NeverScrollableScrollPhysics(),
            padding: EdgeInsets.symmetric(horizontal: 12 + inset),
            itemCount: 6,
            itemBuilder: (context, index) => SizedBox(
              width: cardSize,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                child: Column(
                  crossAxisAlignment: isArtist
                      ? CrossAxisAlignment.center
                      : CrossAxisAlignment.start,
                  children: [
                    SkeletonBox(
                      width: coverSize,
                      height: coverSize,
                      borderRadius: isArtist ? coverSize / 2 : 10,
                    ),
                    const SizedBox(height: 8),
                    SkeletonBox(
                      width: cardSize * (isArtist ? 0.6 : 0.85),
                      height: 14,
                      borderRadius: 4,
                    ),
                    if (!isArtist) ...[
                      const SizedBox(height: 6),
                      SkeletonBox(
                        width: cardSize * 0.5,
                        height: 12,
                        borderRadius: 4,
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildYTMusicQuickPicksSection(
    ExploreSection section,
    ColorScheme colorScheme,
  ) {
    const itemsPerPage = 5;
    final totalPages = (section.items.length / itemsPerPage).ceil();

    return _QuickPicksPageView(
      section: section,
      colorScheme: colorScheme,
      itemsPerPage: itemsPerPage,
      totalPages: totalPages,
      onItemTap: _navigateToExploreItem,
      onItemMenu: _showTrackBottomSheet,
    );
  }

  Widget _buildExploreItem(
    BuildContext itemContext,
    ExploreItem item,
    ColorScheme colorScheme,
  ) {
    final isArtist = item.type == 'artist';
    final isTablet = MediaQuery.sizeOf(context).shortestSide >= 600;
    final cardSize = _exploreCardSize(context);
    final coverSize = _exploreCoverSize(context);
    final iconSize = cardSize * 0.3;

    return Semantics(
      button: true,
      label: context.l10n.a11yOpenItem(item.type, item.name),
      child: GestureDetector(
        onTap: () => _navigateToExploreItem(item, itemContext),
        child: SizedBox(
          width: cardSize,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: Column(
              crossAxisAlignment: isArtist
                  ? CrossAxisAlignment.center
                  : CrossAxisAlignment.start,
              children: [
                DownloadableCover(
                  coverUrl: item.coverUrl,
                  baseName: item.artists.isEmpty
                      ? item.name
                      : '${item.artists} - ${item.name}',
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(
                      isArtist ? coverSize / 2 : 10,
                    ),
                    child: item.coverUrl != null && item.coverUrl!.isNotEmpty
                        ? CachedCoverImage(
                            imageUrl: item.coverUrl!,
                            width: coverSize,
                            height: coverSize,
                            fit: BoxFit.cover,
                            placeholder: (context, url) => ShimmerLoading(
                              child: Container(
                                width: coverSize,
                                height: coverSize,
                                color: colorScheme.surfaceContainerHighest,
                              ),
                            ),
                            errorWidget: (context, url, error) => Container(
                              width: coverSize,
                              height: coverSize,
                              color: colorScheme.surfaceContainerHighest,
                              child: Icon(
                                _getIconForType(item.type),
                                color: colorScheme.onSurfaceVariant,
                                size: iconSize,
                              ),
                            ),
                          )
                        : Container(
                            width: coverSize,
                            height: coverSize,
                            color: colorScheme.surfaceContainerHighest,
                            child: Icon(
                              _getIconForType(item.type),
                              color: colorScheme.onSurfaceVariant,
                              size: iconSize,
                            ),
                          ),
                  ),
                ),
                const SizedBox(height: 8),
                ExplicitTrackTitle(
                  title: item.name,
                  explicit: item.explicit == true,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: isArtist ? TextAlign.center : TextAlign.start,
                  style:
                      (isTablet
                              ? Theme.of(context).textTheme.titleMedium
                              : Theme.of(context).textTheme.bodyMedium)
                          ?.copyWith(
                            fontWeight: FontWeight.w600,
                            color: colorScheme.onSurface,
                          ),
                ),
                if (item.artists.isNotEmpty && !isArtist)
                  ClickableArtistName(
                    artistName: item.artists,
                    coverUrl: item.coverUrl,
                    extensionId: item.providerId,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                      fontSize: isTablet ? 14 : 12,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  IconData _getIconForType(String type) {
    switch (type) {
      case 'track':
        return Icons.music_note;
      case 'album':
        return Icons.album;
      case 'playlist':
        return Icons.playlist_play;
      case 'artist':
        return Icons.person;
      case 'station':
        return Icons.radio;
      default:
        return Icons.music_note;
    }
  }

  String? _providerIdForExploreItem(ExploreItem item) {
    final itemProviderId = item.providerId?.trim();
    if (itemProviderId != null && itemProviderId.isNotEmpty) {
      return itemProviderId;
    }

    final feedProviderId = ref.read(exploreProvider).providerId?.trim();
    if (feedProviderId != null && feedProviderId.isNotEmpty) {
      return feedProviderId;
    }

    return null;
  }

  void _showMissingExploreProviderMessage() {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(context.l10n.extensionsNoHomeFeedExtensions)),
    );
  }

  void _navigateToExploreItem(
    ExploreItem item,
    BuildContext itemContext,
  ) async {
    final extensionId = _providerIdForExploreItem(item);

    switch (item.type) {
      case 'track':
        _showTrackBottomSheet(item, itemContext);
        return;
      case 'album':
        if (extensionId == null) {
          _showMissingExploreProviderMessage();
          return;
        }
        Navigator.push(
          context,
          MaterialPageRoute<void>(
            builder: (context) => ExtensionAlbumScreen(
              extensionId: extensionId,
              albumId: item.id,
              albumName: item.name,
              coverUrl: item.coverUrl,
            ),
          ),
        );
        return;
      case 'playlist':
        if (extensionId == null) {
          _showMissingExploreProviderMessage();
          return;
        }
        Navigator.push(
          context,
          MaterialPageRoute<void>(
            builder: (context) => ExtensionPlaylistScreen(
              extensionId: extensionId,
              playlistId: item.id,
              playlistName: item.name,
              coverUrl: item.coverUrl,
            ),
          ),
        );
        return;
      case 'artist':
        if (extensionId == null) {
          _showMissingExploreProviderMessage();
          return;
        }
        Navigator.push(
          context,
          MaterialPageRoute<void>(
            builder: (context) => ExtensionArtistScreen(
              extensionId: extensionId,
              artistId: item.id,
              artistName: item.name,
              coverUrl: item.coverUrl,
            ),
          ),
        );
        return;
      default:
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('${item.type}: ${item.name}')));
        return;
    }
  }

  void _showTrackBottomSheet(ExploreItem item, BuildContext itemContext) {
    if (context.isMornye) {
      final box = itemContext.findRenderObject();
      final anchor = box is RenderBox && box.hasSize
          ? box.localToGlobal(Offset.zero) & box.size
          : null;
      showMornyeContextMenu<void>(
        context: itemContext,
        // Featured cards can exceed the menu helper's page-size heuristic.
        anchor: anchor,
        builder: (menuContext) => MornyeContextMenu(
          groups: [
            [
              MornyeMenuAction(
                icon: mornyeIconFor(Icons.download),
                label: menuContext.l10n.downloadTitle,
                onPressed: () {
                  Navigator.pop(menuContext);
                  _handleExploreTrackPrimaryAction(item);
                },
              ),
              MornyeMenuAction(
                icon: mornyeIconFor(Icons.album),
                label: menuContext.l10n.homeGoToAlbum,
                onPressed: () {
                  Navigator.pop(menuContext);
                  _navigateToTrackAlbum(item);
                },
              ),
            ],
          ],
        ),
      );
      return;
    }

    final colorScheme = Theme.of(context).colorScheme;

    showAppModalBottomSheet<void>(
      context: context,
      useRootNavigator: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const AppSheetHandle(),
            Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  DownloadableCover(
                    coverUrl: item.coverUrl,
                    baseName: '${item.artists} - ${item.name}',
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: item.coverUrl != null && item.coverUrl!.isNotEmpty
                          ? CachedCoverImage(
                              imageUrl: item.coverUrl!,
                              width: 64,
                              height: 64,
                              fit: BoxFit.cover,
                            )
                          : Container(
                              width: 64,
                              height: 64,
                              color: colorScheme.surfaceContainerHighest,
                              child: Icon(
                                Icons.music_note,
                                color: colorScheme.onSurfaceVariant,
                              ),
                            ),
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        ExplicitTrackTitle(
                          title: item.name,
                          explicit: item.explicit == true,
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(fontWeight: FontWeight.w600),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 4),
                        ClickableArtistName(
                          artistName: item.artists,
                          coverUrl: item.coverUrl,
                          extensionId: item.providerId,
                          style: Theme.of(context).textTheme.bodyMedium
                              ?.copyWith(color: colorScheme.onSurfaceVariant),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            // Material sheets separate the header by space alone.
            if (context.isMornye) const Divider(height: 1),
            ListTile(
              leading: Icon(Icons.download, color: colorScheme.primary),
              title: Text(context.l10n.downloadTitle),
              onTap: () {
                Navigator.pop(context);
                _handleExploreTrackPrimaryAction(item);
              },
            ),
            ListTile(
              leading: Icon(Icons.album, color: colorScheme.onSurfaceVariant),
              title: Text(context.l10n.homeGoToAlbum),
              onTap: () {
                Navigator.pop(context);
                _navigateToTrackAlbum(item);
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Future<void> _handleExploreTrackPrimaryAction(ExploreItem item) async {
    final settings = ref.read(settingsProvider);

    final track = Track(
      id: item.id,
      name: item.name,
      artistName: item.artists,
      albumName: item.albumName ?? '',
      albumId: item.albumId,
      duration: item.durationMs ~/ 1000,
      trackNumber: null,
      discNumber: null,
      totalDiscs: null,
      isrc: null,
      releaseDate: item.releaseDate,
      coverUrl: item.coverUrl,
      source: _providerIdForExploreItem(item),
      explicit: item.explicit,
    );

    if (settings.askQualityBeforeDownload || settings.allowQualityVariants) {
      DownloadServicePicker.show(
        context,
        trackName: track.name,
        artistName: track.artistName,
        coverUrl: track.coverUrl,
        onSelect: (quality, service) {
          ref
              .read(downloadQueueProvider.notifier)
              .addToQueue(track, service, qualityOverride: quality);
          showAddedToQueueSnackBar(context, track.name);
        },
      );
    } else {
      final extensionState = ref.read(extensionProvider);
      final service = resolveEffectiveDownloadService(
        settings.defaultService,
        extensionState,
      );
      if (service.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(context.l10n.extensionsNoDownloadProvider)),
        );
        return;
      }
      ref.read(downloadQueueProvider.notifier).addToQueue(track, service);
      showAddedToQueueSnackBar(context, track.name);
    }
  }

  /// Music's Search page closes with Browse Categories. Mornye has no genre
  /// catalog, so each section of the home feed stands in as one tile.
  Widget _buildBrowseSliver() {
    return Consumer(
      builder: (context, ref, _) {
        final sections = ref
            .watch(exploreProvider.select((s) => s.sections))
            .where((section) => section.items.isNotEmpty)
            .toList();
        if (sections.isEmpty) {
          return const SliverToBoxAdapter(child: SizedBox.shrink());
        }
        // Sections often lead with the same playlist; each tile shows a cover
        // no earlier tile used. Square covers come first, since the tile
        // shows its artwork uncropped. Feeds send empty strings for missing
        // covers.
        final used = <String>{};
        final covers = [
          for (final section in sections)
            section.items
                .expand((item) => [item.coverUrl, item.featuredCoverUrl])
                .whereType<String>()
                .where((url) => url.isNotEmpty)
                .firstWhere(used.add, orElse: () => ''),
        ];
        final inset = 16 + wideListInset(context);
        return SliverMainAxisGroup(
          slivers: [
            SliverPadding(
              padding: EdgeInsets.fromLTRB(inset, 16, inset, 12),
              sliver: SliverToBoxAdapter(
                child: Semantics(
                  header: true,
                  child: Text(
                    context.l10n.searchBrowse,
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
            ),
            SliverPadding(
              padding: EdgeInsets.fromLTRB(inset, 0, inset, 24),
              sliver: SliverGrid.builder(
                gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                  maxCrossAxisExtent: 260,
                  childAspectRatio: 16 / 10,
                  mainAxisSpacing: 16,
                  crossAxisSpacing: 16,
                ),
                itemCount: sections.length,
                itemBuilder: (context, index) => KeyedSubtree(
                  key: ValueKey('browse-${sections[index].uri}'),
                  child: _buildBrowseTile(
                    sections[index],
                    covers[index].isEmpty ? null : covers[index],
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  /// A tile in the cover's own color, with the title on that flat fill and
  /// the square cover whole in the corner: nothing is cropped, and the
  /// title never lands on the artwork's own lettering.
  Widget _buildBrowseTile(ExploreSection section, String? cover) {
    final appScheme = Theme.of(context).colorScheme;
    final tokens = context.tokens;
    return CoverPaletteBuilder(
      imageSource: cover,
      builder: (context, scheme) {
        // Until the palette arrives the builder hands back the app scheme;
        // a neutral fill avoids flashing the accent color first.
        final resolved = !identical(scheme, appScheme);
        final fill = resolved
            ? scheme.primaryContainer
            : appScheme.surfaceContainerHighest;
        final onFill = resolved
            ? scheme.onPrimaryContainer
            : appScheme.onSurface;
        return Semantics(
          button: true,
          label: section.title,
          excludeSemantics: true,
          child: Material(
            color: fill,
            borderRadius: BorderRadius.circular(tokens.radiusCard),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: () => _openExploreSection(section),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final coverSize = constraints.maxHeight * 0.5;
                  return Stack(
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(14, 12, 14, 0),
                        child: Text(
                          section.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(
                                color: onFill,
                                fontWeight: FontWeight.w700,
                              ),
                        ),
                      ),
                      if (cover != null)
                        PositionedDirectional(
                          end: 12,
                          bottom: 12,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(
                                tokens.radiusThumb,
                              ),
                              boxShadow: const [
                                BoxShadow(
                                  color: Color(0x40000000),
                                  blurRadius: 12,
                                  offset: Offset(0, 4),
                                ),
                              ],
                            ),
                            child: CachedCoverImage(
                              imageUrl: cover,
                              width: coverSize,
                              height: coverSize,
                              borderRadius: BorderRadius.circular(
                                tokens.radiusThumb,
                              ),
                              errorWidget: (context, url, error) =>
                                  const SizedBox.shrink(),
                            ),
                          ),
                        ),
                    ],
                  );
                },
              ),
            ),
          ),
        );
      },
    );
  }

  void _openExploreSection(ExploreSection section) {
    final colorScheme = Theme.of(context).colorScheme;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => _ExploreSectionPage(
          section: section,
          itemExtent: _exploreCardSize(context),
          itemHeight: _exploreSectionHeight(context),
          itemBuilder: (itemContext, item) =>
              _buildExploreItem(itemContext, item, colorScheme),
          onOpen: _navigateToExploreItem,
        ),
      ),
    );
  }

  Future<void> _navigateToTrackAlbum(ExploreItem item) async {
    if (item.albumId != null && item.albumId!.isNotEmpty) {
      final extensionId = _providerIdForExploreItem(item);
      if (extensionId == null) {
        _showMissingExploreProviderMessage();
        return;
      }

      Navigator.push(
        context,
        MaterialPageRoute<void>(
          builder: (context) => ExtensionAlbumScreen(
            extensionId: extensionId,
            albumId: item.albumId!,
            albumName: item.albumName ?? 'Album',
            coverUrl: item.coverUrl,
          ),
        ),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.l10n.homeAlbumInfoUnavailable)),
      );
    }
  }
}

/// Every item of one home feed section, opened from a Browse tile. Laid out
/// like a Music category page: featured items as wide editorial cards, songs
/// as rows in columns, and the rest as square artwork.
class _ExploreSectionPage extends StatelessWidget {
  const _ExploreSectionPage({
    required this.section,
    required this.itemExtent,
    required this.itemHeight,
    required this.itemBuilder,
    required this.onOpen,
  });

  final ExploreSection section;
  final double itemExtent;
  final double itemHeight;
  final Widget Function(BuildContext context, ExploreItem item) itemBuilder;
  final void Function(ExploreItem item, BuildContext itemContext) onOpen;

  static const double _gap = 24;

  static bool _isFeatured(ExploreItem item) =>
      item.featuredCoverUrl?.isNotEmpty == true;

  /// Columns of at least [minWidth], at most [maxCount].
  static int _columns(double width, double minWidth, int maxCount) =>
      ((width + _gap) / (minWidth + _gap)).floor().clamp(1, maxCount);

  String _typeLabel(BuildContext context, String type) => switch (type) {
    'album' => context.l10n.recentTypeAlbum,
    'playlist' => context.l10n.recentTypePlaylist,
    'artist' => context.l10n.recentTypeArtist,
    'track' => context.l10n.recentTypeSong,
    _ => '',
  };

  Widget _featuredCard(BuildContext context, ExploreItem item, double width) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final radius = BorderRadius.circular(context.tokens.radiusThumb);
    final cover = item.coverUrl;
    final description = item.description?.trim() ?? '';
    return Builder(
      builder: (itemContext) => InkWell(
        borderRadius: radius,
        onTap: () => onOpen(item, itemContext),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _typeLabel(context, item.type).toUpperCase(),
              maxLines: 1,
              style: theme.textTheme.labelSmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.4,
              ),
            ),
            Text(
              item.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyLarge,
            ),
            Text(
              item.artists,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyLarge?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: radius,
              child: SizedBox(
                width: width,
                height: width * 2 / 3,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    CachedCoverImage(
                      imageUrl: item.featuredCoverUrl!,
                      errorWidget: (context, url, error) => ColoredBox(
                        color: colorScheme.surfaceContainerHighest,
                      ),
                    ),
                    if (description.isNotEmpty)
                      // The caption sits on artwork; dim its lower edge.
                      const DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [Color(0x00000000), Color(0x99000000)],
                            stops: [0.55, 1],
                          ),
                        ),
                      ),
                    Positioned(
                      left: 16,
                      right: 16,
                      bottom: 14,
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Expanded(
                            child: Text(
                              description,
                              maxLines: 3,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: Colors.white,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ),
                          if (item.type == 'album' &&
                              cover != null &&
                              cover.isNotEmpty &&
                              cover != item.featuredCoverUrl) ...[
                            const SizedBox(width: 12),
                            CachedCoverImage(
                              imageUrl: cover,
                              width: width * 0.16,
                              height: width * 0.16,
                              borderRadius: radius,
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _songRow(BuildContext context, ExploreItem item) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final coverSize = context.tokens.coverList;
    final cover = item.coverUrl;
    Widget fallback() => ColoredBox(
      color: colorScheme.surfaceContainerHighest,
      child: Icon(Icons.music_note, color: colorScheme.onSurfaceVariant),
    );
    return Builder(
      builder: (itemContext) => InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () => onOpen(item, itemContext),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(context.tokens.radiusThumb),
              child: SizedBox.square(
                dimension: coverSize,
                child: cover != null && cover.isNotEmpty
                    ? CachedCoverImage(
                        imageUrl: cover,
                        width: coverSize,
                        height: coverSize,
                        errorWidget: (context, url, error) => fallback(),
                      )
                    : fallback(),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  border: Border(
                    bottom: BorderSide(
                      color: colorScheme.outlineVariant.withValues(alpha: 0.6),
                      width: 0.5,
                    ),
                  ),
                ),
                child: SizedBox(
                  height: coverSize + 12,
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            ExplicitTrackTitle(
                              title: item.name,
                              explicit: item.explicit == true,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodyLarge,
                            ),
                            Text(
                              item.artists,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Builder(
                        builder: (buttonContext) => AppIconButton(
                          tooltip: MaterialLocalizations.of(
                            context,
                          ).moreButtonTooltip,
                          icon: Icon(
                            Icons.more_horiz,
                            color: colorScheme.onSurfaceVariant,
                          ),
                          onPressed: () => onOpen(item, buttonContext),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final inset = 18 + wideListInset(context);
    final featured = section.items.where(_isFeatured).toList();
    final songs = section.items
        .where((item) => !_isFeatured(item) && item.type == 'track')
        .toList();
    final artwork = section.items
        .where((item) => !_isFeatured(item) && item.type != 'track')
        .toList();
    final scaler = MediaQuery.textScalerOf(context);
    final textTheme = Theme.of(context).textTheme;
    // Label, title and subtitle above each featured image.
    final featuredText =
        scaler.scale(textTheme.labelSmall?.fontSize ?? 11) * 1.4 +
        2 * scaler.scale(textTheme.bodyLarge?.fontSize ?? 17) * 1.3 +
        8;
    final songRowHeight = context.tokens.coverList + 12;
    return Scaffold(
      body: CustomScrollView(
        slivers: [
          AppSliverHeader.page(title: section.title),
          SliverPadding(
            padding: EdgeInsets.fromLTRB(inset, 8, inset, 24),
            sliver: SliverLayoutInfoBuilder(
              select: (constraints) => constraints.crossAxisExtent,
              builder: (context, width) {
                final featuredColumns = _columns(width, 360, 3);
                final featuredWidth =
                    (width - _gap * (featuredColumns - 1)) / featuredColumns;
                return SliverMainAxisGroup(
                  slivers: [
                    if (featured.isNotEmpty)
                      SliverPadding(
                        padding: const EdgeInsets.only(bottom: _gap),
                        sliver: SliverGrid.builder(
                          gridDelegate:
                              SliverGridDelegateWithFixedCrossAxisCount(
                                crossAxisCount: featuredColumns,
                                crossAxisSpacing: _gap,
                                mainAxisSpacing: _gap,
                                mainAxisExtent:
                                    featuredText + featuredWidth * 2 / 3,
                              ),
                          itemCount: featured.length,
                          itemBuilder: (context, index) => KeyedSubtree(
                            key: ValueKey(
                              'section-featured-${featured[index].uri}',
                            ),
                            child: _featuredCard(
                              context,
                              featured[index],
                              featuredWidth,
                            ),
                          ),
                        ),
                      ),
                    if (songs.isNotEmpty)
                      SliverPadding(
                        padding: const EdgeInsets.only(bottom: _gap),
                        sliver: SliverGrid.builder(
                          gridDelegate:
                              SliverGridDelegateWithFixedCrossAxisCount(
                                crossAxisCount: _columns(width, 320, 3),
                                crossAxisSpacing: _gap,
                                mainAxisExtent: songRowHeight,
                              ),
                          itemCount: songs.length,
                          itemBuilder: (context, index) => KeyedSubtree(
                            key: ValueKey('section-song-${songs[index].uri}'),
                            child: _songRow(context, songs[index]),
                          ),
                        ),
                      ),
                    if (artwork.isNotEmpty)
                      // Cards keep their fixed width, so a cell narrower than
                      // a card would crop its cover. Fit whole cards per row
                      // and center each one in its cell instead.
                      SliverGrid.builder(
                        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: math.max(
                            1,
                            (width / itemExtent).floor(),
                          ),
                          mainAxisExtent: itemHeight,
                          mainAxisSpacing: 12,
                        ),
                        itemCount: artwork.length,
                        itemBuilder: (context, index) => Align(
                          key: ValueKey('section-item-${artwork[index].uri}'),
                          alignment: Alignment.topCenter,
                          child: Builder(
                            builder: (itemContext) =>
                                itemBuilder(itemContext, artwork[index]),
                          ),
                        ),
                      ),
                  ],
                );
              },
            ),
          ),
          const NavBarSliverSpacer(),
        ],
      ),
    );
  }
}
