// ignore_for_file: invalid_use_of_protected_member
part of 'home_tab.dart';

/// Search results once the content is [searchCoverLayoutMinWidth] wide, on
/// tablets and desktop windows: the album, artist and playlist filters show
/// a grid of covers, and the All view shows the first songs, then one shelf
/// per kind of collection. Songs use the desktop song table on desktop and
/// keep their phone rows, at the reading width, on tablets.
extension _HomeTabSearchWideUI on _HomeTabState {
  /// The songs the All view lists before its Show all.
  static const int _overviewSongCount = 5;

  List<Widget> _buildWideSearchResults({
    required WidgetRef resultsRef,
    required List<Track> tracks,
    required bool isLoading,
    required String? error,
    required ColorScheme colorScheme,
    required bool hasResults,
    required bool showEmptySearchResult,
    required String? searchExtensionId,
    required bool showLocalLibraryIndicator,
    required Map<String, (double, double)> thumbnailSizesByExtensionId,
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
              'track' => HomeSearchSkeletonLayout.songs,
              'artist' => HomeSearchSkeletonLayout.artistGrid,
              'album' || 'playlist' => HomeSearchSkeletonLayout.coverGrid,
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
    var sortButtonShown = false;
    final viewToggle = _buildSearchViewToggle(grid: true);

    void addSongs() {
      final limited =
          overview &&
          !_searchSongsExpanded &&
          songs.length > _overviewSongCount;
      final count = limited ? _overviewSongCount : songs.length;
      slivers.addAll(
        isDesktopPlatform
            ? _buildSearchSongTable(
                resultsRef: resultsRef,
                tracks: songs,
                indexes: songIndexes,
                count: count,
                colorScheme: colorScheme,
                showSortButton: !sortButtonShown,
                viewToggle: sortButtonShown ? null : viewToggle,
              )
            : _buildSearchSongRows(
                resultsRef: resultsRef,
                tracks: songs,
                indexes: songIndexes,
                colorScheme: colorScheme,
                showSortButton: !sortButtonShown,
                viewToggle: sortButtonShown ? null : viewToggle,
                searchExtensionId: searchExtensionId,
                showLocalLibraryIndicator: showLocalLibraryIndicator,
                thumbnailSizesByExtensionId: thumbnailSizesByExtensionId,
                itemCount: count,
              ),
      );
      if (limited) {
        final songFilter = filterFor('track');
        slivers.add(
          SliverToBoxAdapter(
            child: Padding(
              // The button's own padding puts its label on the rows' edge.
              padding: EdgeInsetsDirectional.only(
                start: 8 + wideListInset(context),
                top: 4,
              ),
              child: Align(
                alignment: AlignmentDirectional.centerStart,
                child: _buildShowAllButton(
                  context.l10n.searchSongs,
                  songFilter != null
                      ? () => _selectSearchFilter(songFilter)
                      : () => setState(() => _searchSongsExpanded = true),
                ),
              ),
            ),
          ),
        );
      }
      sortButtonShown = true;
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
      slivers
        ..add(
          _buildResultSectionHeader(
            title: title,
            colorScheme: colorScheme,
            showSortButton: !sortButtonShown,
            viewToggle: sortButtonShown ? null : viewToggle,
            onShowAll: filter == null
                ? null
                : () => _selectSearchFilter(filter),
          ),
        )
        ..add(
          overview
              ? _buildSearchCoverShelf(sorted, kind, open)
              : _buildSearchCoverGrid(sorted, kind, open),
        );
      sortButtonShown = true;
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

  /// The Songs section as the desktop song table, with the first [count] of
  /// [tracks]. A click does what a tap on the phone row does.
  List<Widget> _buildSearchSongTable({
    required WidgetRef resultsRef,
    required List<Track> tracks,
    required List<int> indexes,
    required int count,
    required ColorScheme colorScheme,
    required bool showSortButton,
    Widget? viewToggle,
  }) {
    final isInHistory = _watchSearchHistory(resultsRef, tracks);
    final shown = count < tracks.length ? tracks.sublist(0, count) : tracks;
    final inHistory = [for (var i = 0; i < shown.length; i++) isInHistory(i)];
    return [
      _buildResultSectionHeader(
        title: context.l10n.searchSongs,
        colorScheme: colorScheme,
        showSortButton: showSortButton,
        viewToggle: viewToggle,
      ),
      TrackListTable(
        key: const ValueKey('search-song-table'),
        tracks: shown,
        // Result ids can repeat; the result index keeps each row unique.
        ids: [
          for (var i = 0; i < shown.length; i++) '${shown[i].id}#${indexes[i]}',
        ],
        isInHistory: inHistory,
        // Search has no selection, so modified clicks select nothing.
        selectedIds: const {},
        onSelect: (_, _, _) {},
        onActivate: (index) => _TrackItemWithStatus.activate(
          context,
          ref,
          shown[index],
          isQueued: ref
              .read(downloadQueueLookupProvider)
              .byTrackId
              .containsKey(shown[index].id),
          isInHistory: inHistory[index],
          isInLocalLibrary: _isSearchTrackInLocalLibrary(shown[index]),
          onDownload: ({bool forceQualityPicker = false}) => _downloadTrack(
            indexes[index],
            forceQualityPicker: forceQualityPicker,
          ),
        ),
        onContextMenu: (index, position) =>
            TrackCollectionQuickActions.showTrackOptionsSheet(
              context,
              ref,
              shown[index],
              position: position,
              hasLocalPlaybackCandidate:
                  inHistory[index] ||
                  _isSearchTrackInLocalLibrary(shown[index]),
            ),
        showArtwork: true,
        showAlbum: true,
        showPreview: true,
        onSaveCover: (index) => _saveSearchResultCover(shown[index]),
      ),
    ];
  }

  /// Whether [track] is in the local library, when the rows show it.
  bool _isSearchTrackInLocalLibrary(Track track) {
    final settings = ref.read(settingsProvider);
    return settings.localLibraryEnabled &&
        settings.localLibraryShowDuplicates &&
        ref
            .read(localLibraryProvider)
            .existsInLibrary(
              isrc: track.isrc,
              trackName: track.name,
              artistName: track.artistName,
            );
  }

  /// A filtered collection: covers in as many columns as the pane fits.
  Widget _buildSearchCoverGrid(
    List<Track> items,
    String kind,
    void Function(Track item) open,
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
            itemCount: items.length,
            itemBuilder: (context, index) => _SearchCoverCell(
              key: ValueKey('$kind-${items[index].id}'),
              item: items[index],
              extent: extent,
              onTap: () => open(items[index]),
              onSaveCover: () => _saveSearchResultCover(items[index]),
            ),
          );
        },
      ),
    );
  }

  /// One kind of collection in the All view: a row of covers that scrolls
  /// sideways, with arrows for a mouse on desktop.
  Widget _buildSearchCoverShelf(
    List<Track> items,
    String kind,
    void Function(Track item) open,
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
            itemCount: items.length,
            separatorBuilder: (_, _) => const SizedBox(width: searchCoverGap),
            itemBuilder: (context, index) => SizedBox(
              key: ValueKey('$kind-${items[index].id}'),
              width: searchCoverShelfExtent,
              child: _SearchCoverCell(
                item: items[index],
                extent: searchCoverShelfExtent,
                onTap: () => open(items[index]),
                onSaveCover: () => _saveSearchResultCover(items[index]),
              ),
            ),
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
