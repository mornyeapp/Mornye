// ignore_for_file: invalid_use_of_protected_member
part of 'home_tab.dart';

/// Search results once the content is [searchCoverLayoutMinWidth] wide, on
/// tablets and desktop windows: every filter, Songs included, shows a grid
/// of covers, and the All view shows one shelf of covers per kind.
extension _HomeTabSearchWideUI on _HomeTabState {
  List<Widget> _buildWideSearchResults({
    required WidgetRef resultsRef,
    required List<Track> tracks,
    required bool isLoading,
    required String? error,
    required ColorScheme colorScheme,
    required bool hasResults,
    required bool showEmptySearchResult,
    required bool showLocalLibraryIndicator,
    required List<Extension> extensions,
  }) {
    final currentSearchProvider = resultsRef.watch(
      settingsProvider.select((s) => s.searchProvider),
    );
    final defaultSearchTab = resultsRef.watch(
      settingsProvider.select((s) => s.defaultSearchTab),
    );
    final selectedSearchFilter = resultsRef.watch(
      trackProvider.select((s) => s.selectedSearchFilter),
    );
    final displayFilter = HomeSearchProviderPolicy.displayFilterSelection(
      selectedSearchFilter,
      defaultSearchTab,
      currentSearchProvider,
      extensions,
    );
    final overview = displayFilter == 'all';
    final filters = _resolveSearchFilters(
      context,
      currentSearchProvider,
      extensions,
    );
    String? filterFor(String kind) => filters
        .where((filter) => canonicalExtensionSearchFilterId(filter.id) == kind)
        .firstOrNull
        ?.id;

    final hasActualData = tracks.isNotEmpty;
    if (!hasActualData && isLoading) {
      return [
        SliverToBoxAdapter(
          child: HomeSearchSkeleton(
            layout: switch (overview
                ? 'all'
                : canonicalExtensionSearchFilterId(displayFilter)) {
              'all' => HomeSearchSkeletonLayout.overview,
              'artist' => HomeSearchSkeletonLayout.artistGrid,
              'track' ||
              'album' ||
              'playlist' => HomeSearchSkeletonLayout.coverGrid,
              _ => HomeSearchSkeletonLayout.rows,
            },
          ),
        ),
      ];
    }
    if (!hasResults) {
      return [const SliverToBoxAdapter(child: SizedBox.shrink())];
    }

    final buckets = _getSearchResultBuckets(tracks);
    final sortedTrackResults = _sortTrackResults(
      buckets.realTracks,
      buckets.realTrackIndexes,
    );
    final songs = sortedTrackResults.tracks;
    final songIndexes = sortedTrackResults.indexes;

    final slivers = _searchStatusSlivers(
      error: error,
      isLoading: isLoading,
      showEmptyResult: showEmptySearchResult && !hasActualData,
      colorScheme: colorScheme,
    );

    // Songs are covers too, as the other kinds are.
    void addSongs() {
      final isInHistory = _watchSearchHistory(resultsRef, songs);
      final songFilter = overview ? filterFor('track') : null;
      Widget cell(BuildContext context, int index, double extent) =>
          _SearchSongCoverCell(
            // Result ids can repeat; the result index keeps each unique.
            key: ValueKey('track-${songs[index].id}#${songIndexes[index]}'),
            track: songs[index],
            extent: extent,
            isInHistory: isInHistory(index),
            showLocalLibraryIndicator: showLocalLibraryIndicator,
            onDownload: ({bool forceQualityPicker = false}) => _downloadTrack(
              songIndexes[index],
              forceQualityPicker: forceQualityPicker,
            ),
            onSaveCover: () => _saveSearchResultCover(songs[index]),
          );
      slivers
        ..add(
          _buildResultSectionHeader(
            title: context.l10n.searchSongs,
            colorScheme: colorScheme,
            // Sort and the view button sit beside the filters.
            showSortButton: false,
            onShowAll: songFilter == null
                ? null
                : () => _selectSearchFilter(songFilter),
          ),
        )
        ..add(
          overview
              ? _buildSearchCoverShelf(songs.length, 'track', cell)
              : _buildSearchCoverGrid(songs.length, cell),
        );
    }

    if (overview && songs.isNotEmpty) addSongs();

    for (final (items, kind, title, open) in [
      (
        buckets.artistItems,
        'artist',
        context.l10n.searchArtists,
        _navigateToExtensionArtist,
      ),
      (
        buckets.albumItems,
        'album',
        context.l10n.searchAlbums,
        _navigateToExtensionAlbum,
      ),
      (
        buckets.playlistItems,
        'playlist',
        context.l10n.searchPlaylists,
        _navigateToExtensionPlaylist,
      ),
    ]) {
      if (items.isEmpty) continue;
      final sorted = _sortCollectionResults(items);
      final filter = overview ? filterFor(kind) : null;
      Widget cell(BuildContext context, int index, double extent) =>
          _SearchCoverCell(
            key: ValueKey('$kind-${sorted[index].id}'),
            item: sorted[index],
            extent: extent,
            onTap: () => open(sorted[index]),
            onSaveCover: () => _saveSearchResultCover(sorted[index]),
          );
      slivers
        ..add(
          _buildResultSectionHeader(
            title: title,
            colorScheme: colorScheme,
            showSortButton: false,
            onShowAll: filter == null
                ? null
                : () => _selectSearchFilter(filter),
          ),
        )
        ..add(
          overview
              ? _buildSearchCoverShelf(sorted.length, kind, cell)
              : _buildSearchCoverGrid(sorted.length, cell),
        );
    }

    if (!overview && songs.isNotEmpty) addSongs();

    slivers.add(const SliverToBoxAdapter(child: SizedBox(height: 16)));
    return slivers;
  }

  /// [items] in the chosen sort. Collections have no duration, so the
  /// duration sorts keep the provider's order.
  List<Track> _sortCollectionResults(List<Track> items) {
    final option = _searchSortOption;
    if (option == HomeSearchSortOption.defaultOrder ||
        option == HomeSearchSortOption.durationAsc ||
        option == HomeSearchSortOption.durationDesc) {
      return items;
    }
    return sortHomeSearchItems<Track>(
      items: items,
      option: option,
      nameOf: (item) => item.name,
      artistOf: (item) => item.artistName,
      durationOf: (item) => item.duration,
      dateOf: (item) => item.releaseDate,
    );
  }

  /// A filtered kind: [count] covers from [cell] in as many columns as the
  /// pane fits.
  Widget _buildSearchCoverGrid(
    int count,
    Widget Function(BuildContext context, int index, double extent) cell,
  ) {
    final edge = searchCoverEdge(context);
    return SliverPadding(
      padding: EdgeInsetsDirectional.fromSTEB(edge, 0, edge, 8),
      // Rebuilds when the pane is resized, not while it scrolls.
      sliver: SliverLayoutInfoBuilder<double>(
        select: (constraints) => constraints.crossAxisExtent,
        builder: (context, width) {
          final extent = searchCoverGridExtent(width);
          return SliverGrid.builder(
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: searchCoverGridColumns(width),
              mainAxisSpacing: searchCoverGap,
              crossAxisSpacing: searchCoverGap,
              mainAxisExtent: extent + searchCoverTextHeight(context),
            ),
            itemCount: count,
            itemBuilder: (context, index) => cell(context, index, extent),
          );
        },
      ),
    );
  }

  /// One [kind] in the All view: [count] covers from [cell] in a row that
  /// scrolls sideways, with arrows for a mouse on desktop.
  Widget _buildSearchCoverShelf(
    int count,
    String kind,
    Widget Function(BuildContext context, int index, double extent) cell,
  ) {
    final edge = searchCoverEdge(context);
    return SliverToBoxAdapter(
      child: SizedBox(
        height: searchCoverShelfExtent + searchCoverTextHeight(context) + 8,
        child: DesktopScrollArrows(
          key: ValueKey('search-shelf-$kind'),
          builder: (context, controller) => ListView.separated(
            controller: controller,
            scrollDirection: Axis.horizontal,
            padding: EdgeInsets.symmetric(horizontal: edge),
            itemCount: count,
            separatorBuilder: (_, _) => const SizedBox(width: searchCoverGap),
            itemBuilder: (context, index) => SizedBox(
              width: searchCoverShelfExtent,
              child: cell(context, index, searchCoverShelfExtent),
            ),
          ),
        ),
      ),
    );
  }
}

/// A song result on wide screens: its cover over the title and artist, as
/// the other kinds show. A click does what a tap on the phone row does
/// (usually a download); the preview button sits on the cover, In Library
/// marks a song you have, and the right-click menu or a long press opens the
/// song's options. A long press on the cover saves it, as on the phone row.
class _SearchSongCoverCell extends ConsumerWidget {
  const _SearchSongCoverCell({
    super.key,
    required this.track,
    required this.extent,
    required this.isInHistory,
    required this.showLocalLibraryIndicator,
    required this.onDownload,
    required this.onSaveCover,
  });

  final Track track;

  /// The side of the cover.
  final double extent;
  final bool isInHistory;
  final bool showLocalLibraryIndicator;
  final void Function({bool forceQualityPicker}) onDownload;
  final VoidCallback onSaveCover;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final l10n = context.l10n;
    final mornye = context.isMornye;
    final isQueued = ref.watch(
      downloadQueueLookupProvider.select(
        (lookup) => lookup.byTrackId.containsKey(track.id),
      ),
    );
    final isInLocalLibrary =
        showLocalLibraryIndicator &&
        ref.watch(
          localLibraryProvider.select(
            (state) => state.existsInLibrary(
              isrc: track.isrc,
              trackName: track.name,
              artistName: track.artistName,
            ),
          ),
        );
    final hasCover = track.coverUrl?.isNotEmpty == true;
    // The Library grids' cover corners.
    final radius = BorderRadius.circular(mornye ? 8 : 12);

    void showOptions({Offset? position}) =>
        TrackCollectionQuickActions.showTrackOptionsSheet(
          context,
          ref,
          track,
          position: position,
          hasLocalPlaybackCandidate: isInHistory || isInLocalLibrary,
        );

    final placeholder = Container(
      width: extent,
      height: extent,
      color: colorScheme.surfaceContainerHighest,
      child: AppIcon(
        Icons.music_note,
        size: extent * 0.3,
        color: colorScheme.onSurfaceVariant,
      ),
    );
    final image = hasCover
        ? CachedCoverImage(
            imageUrl: track.coverUrl!,
            width: extent,
            height: extent,
            fit: BoxFit.cover,
            errorWidget: (_, _, _) => placeholder,
          )
        : placeholder;
    final cover = Semantics(
      label:
          '${l10n.dialogDownload} '
          '${l10n.editMetadataFieldCover}: ${track.name}',
      button: hasCover,
      onLongPress: hasCover ? onSaveCover : null,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        excludeFromSemantics: true,
        onLongPress: hasCover ? onSaveCover : null,
        child: ClipRRect(borderRadius: radius, child: image),
      ),
    );

    final desktopMaterial = isDesktopPlatform && !mornye;
    return DesktopContextMenuRegion(
      onContextMenu: (position) => showOptions(position: position),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          onTap: () => _TrackItemWithStatus.activate(
            context,
            ref,
            track,
            isQueued: isQueued,
            isInHistory: isInHistory,
            isInLocalLibrary: isInLocalLibrary,
            onDownload: onDownload,
          ),
          onLongPress: showOptions,
          borderRadius: radius,
          // The M3 hover state layer; a pointer press shows as a state
          // layer rather than a ripple.
          hoverColor: mornye
              ? null
              : colorScheme.onSurface.withValues(alpha: 0.08),
          highlightColor: desktopMaterial
              ? colorScheme.onSurface.withValues(alpha: 0.1)
              : null,
          splashFactory: desktopMaterial ? NoSplash.splashFactory : null,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox.square(
                dimension: extent,
                child: Stack(
                  children: [
                    cover,
                    PositionedDirectional(
                      start: 4,
                      bottom: 4,
                      child: PreviewButton(track: track, size: 28, dense: true),
                    ),
                    if (isInLocalLibrary)
                      const PositionedDirectional(
                        end: 8,
                        top: 8,
                        child: InLibraryBadge(),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              Text(
                track.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                track.artistName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// An album, playlist or artist result on wide screens: the cover, or the
/// shaped artist avatar, over the title and subtitle the phone row shows.
/// A click opens it; the right-click menu and a long press on the cover
/// save the cover, as the phone rows do.
class _SearchCoverCell extends StatelessWidget {
  const _SearchCoverCell({
    super.key,
    required this.item,
    required this.extent,
    required this.onTap,
    required this.onSaveCover,
  });

  final Track item;

  /// The side of the cover.
  final double extent;
  final VoidCallback onTap;
  final VoidCallback onSaveCover;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final l10n = context.l10n;
    final mornye = context.isMornye;
    final isArtist = item.isArtistItem;
    final hasCover = item.coverUrl?.isNotEmpty == true;
    // The Library grids' cover corners.
    final radius = BorderRadius.circular(mornye ? 8 : 12);

    final placeholder = Container(
      width: extent,
      height: extent,
      color: colorScheme.surfaceContainerHighest,
      child: AppIcon(
        isArtist
            ? Icons.person
            : item.isPlaylistItem
            ? Icons.playlist_play
            : Icons.album,
        size: extent * 0.3,
        color: colorScheme.onSurfaceVariant,
      ),
    );
    // CachedCoverImage decodes at this size times the pixel ratio, on one
    // axis so a cover that is not square keeps its proportions.
    final image = hasCover
        ? CachedCoverImage(
            imageUrl: item.coverUrl!,
            width: extent,
            height: extent,
            fit: BoxFit.cover,
            errorWidget: (_, _, _) => placeholder,
          )
        : placeholder;
    final cover = Semantics(
      label:
          '${l10n.dialogDownload} '
          '${l10n.editMetadataFieldCover}: ${item.name}',
      button: hasCover,
      onLongPress: hasCover ? onSaveCover : null,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        excludeFromSemantics: true,
        onLongPress: hasCover ? onSaveCover : null,
        child: isArtist
            ? AppShapeClip(
                kind: AppShapes.artist,
                fallbackRadius: BorderRadius.circular(extent / 2),
                child: image,
              )
            : ClipRRect(borderRadius: radius, child: image),
      ),
    );

    final textAlign = isArtist ? TextAlign.center : TextAlign.start;
    final desktopMaterial = isDesktopPlatform && !mornye;
    return DesktopContextMenuRegion(
      onContextMenu: (position) => showContextMenu(
        context,
        position: position,
        groups: [
          [
            ContextMenuAction(
              icon: Icons.open_in_new,
              label: l10n.desktopMenuOpen,
              onSelected: onTap,
            ),
            if (hasCover)
              ContextMenuAction(
                icon: Icons.image_outlined,
                label: l10n.trackSaveCoverArt,
                onSelected: onSaveCover,
              ),
          ],
        ],
      ),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          onTap: onTap,
          borderRadius: radius,
          // The M3 hover state layer; a pointer press shows as a state
          // layer rather than a ripple.
          hoverColor: mornye
              ? null
              : colorScheme.onSurface.withValues(alpha: 0.08),
          highlightColor: desktopMaterial
              ? colorScheme.onSurface.withValues(alpha: 0.1)
              : null,
          splashFactory: desktopMaterial ? NoSplash.splashFactory : null,
          child: Column(
            crossAxisAlignment: isArtist
                ? CrossAxisAlignment.center
                : CrossAxisAlignment.start,
            children: [
              cover,
              const SizedBox(height: 8),
              Text(
                item.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: textAlign,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                _CollectionItemWidget.subtitleOf(context, item),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: textAlign,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
