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
    // A compact preview of result types precedes the full shelves. The
    // provider does not supply a relevance ranking across different types.
    final topResults = overview && context.isMornye;

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

    if (topResults) {
      final albums = _sortCollectionResults(buckets.albumItems);
      final playlists = _sortCollectionResults(buckets.playlistItems);
      final isInHistory = _watchSearchHistory(resultsRef, songs);
      final picks = [
        for (final (kind, index) in _topResultPicks(
          songs: songs.length,
          albums: albums.length,
          playlists: playlists.length,
        ))
          switch (kind) {
            'track' => _SearchTopSongCard(
              key: ValueKey('top-track-${songs[index].id}'),
              track: songs[index],
              isInHistory: isInHistory(index),
              showLocalLibraryIndicator: showLocalLibraryIndicator,
              onDownload: ({bool forceQualityPicker = false}) => _downloadTrack(
                songIndexes[index],
                forceQualityPicker: forceQualityPicker,
              ),
            ),
            'album' => _SearchTopCollectionCard(
              key: ValueKey('top-album-${albums[index].id}'),
              item: albums[index],
              kindLabel: context.l10n.recentTypeAlbum,
              onTap: () => _navigateToExtensionAlbum(albums[index]),
              onSaveCover: () => _saveSearchResultCover(albums[index]),
            ),
            _ => _SearchTopCollectionCard(
              key: ValueKey('top-playlist-${playlists[index].id}'),
              item: playlists[index],
              kindLabel: context.l10n.recentTypePlaylist,
              onTap: () => _navigateToExtensionPlaylist(playlists[index]),
              onSaveCover: () => _saveSearchResultCover(playlists[index]),
            ),
          },
      ];
      if (picks.isNotEmpty) {
        slivers
          ..add(
            _buildResultSectionHeader(
              title: context.l10n.searchResults,
              colorScheme: colorScheme,
              showSortButton: false,
            ),
          )
          ..add(_buildSearchTopResults(picks));
      }
    }

    var songsAdded = false;
    if (overview && !topResults && songs.isNotEmpty) {
      addSongs();
      songsAdded = true;
    }

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
      // Songs follow the albums under the mixed preview.
      if (topResults && kind == 'playlist' && songs.isNotEmpty) {
        addSongs();
        songsAdded = true;
      }
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

    if (!songsAdded && songs.isNotEmpty) addSongs();

    slivers.add(const SliverToBoxAdapter(child: SizedBox(height: 16)));
    return slivers;
  }

  /// Which results fill the preview cards: a song first, then the first
  /// album, more songs and the first playlist. A kind that runs out gives its
  /// place to the next one that has results left.
  List<(String, int)> _topResultPicks({
    required int songs,
    required int albums,
    required int playlists,
  }) {
    final counts = {'track': songs, 'album': albums, 'playlist': playlists};
    final used = {'track': 0, 'album': 0, 'playlist': 0};
    bool left(String kind) => used[kind]! < counts[kind]!;
    final picks = <(String, int)>[];
    for (final slot in const [
      'track',
      'album',
      'track',
      'track',
      'track',
      'playlist',
    ]) {
      final kind = left(slot) ? slot : counts.keys.where(left).firstOrNull;
      if (kind == null) break;
      picks.add((kind, used[kind]!));
      used[kind] = used[kind]! + 1;
    }
    return picks;
  }

  Widget _buildSearchTopResults(List<Widget> cards) {
    final edge = searchCoverEdge(context);
    final height = MediaQuery.textScalerOf(
      context,
    ).scale(searchTopResultHeight);
    return SliverPadding(
      padding: EdgeInsetsDirectional.fromSTEB(edge, 0, edge, 8),
      sliver: SliverLayoutInfoBuilder<double>(
        select: (constraints) => constraints.crossAxisExtent,
        builder: (context, width) => SliverGrid.builder(
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: searchTopResultColumns(width),
            mainAxisSpacing: searchCoverGap,
            crossAxisSpacing: searchCoverGap,
            mainAxisExtent: height,
          ),
          itemCount: cards.length,
          itemBuilder: (context, index) => cards[index],
        ),
      ),
    );
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
      child: LayoutBuilder(
        builder: (context, constraints) {
          final extent = searchShelfExtentFor(
            context,
            constraints.maxWidth,
            round: kind == 'artist',
          );
          return SizedBox(
            height: extent + searchCoverTextHeight(context) + 8,
            child: DesktopScrollArrows(
              key: ValueKey('search-shelf-$kind'),
              builder: (context, controller) => ListView.separated(
                controller: controller,
                scrollDirection: Axis.horizontal,
                padding: EdgeInsets.symmetric(horizontal: edge),
                itemCount: count,
                separatorBuilder: (_, _) =>
                    const SizedBox(width: searchCoverGap),
                itemBuilder: (context, index) => SizedBox(
                  width: extent,
                  child: cell(context, index, extent),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// One result preview card: small artwork, title and "Kind · name", with
/// [trailing] at the end, on a tonal rounded rectangle.
class _SearchTopResultCard extends StatelessWidget {
  const _SearchTopResultCard({
    required this.coverUrl,
    required this.placeholderIcon,
    required this.title,
    required this.kindLabel,
    required this.artistName,
    required this.explicit,
    required this.trailing,
    required this.onTap,
    this.onLongPress,
    required this.onContextMenu,
  });

  static const _artwork = 42.0;

  final String? coverUrl;
  final IconData placeholderIcon;
  final String title;
  final String kindLabel;
  final String artistName;
  final bool explicit;
  final Widget trailing;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final ValueChanged<Offset> onContextMenu;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final radius = BorderRadius.circular(10);
    final placeholder = Container(
      width: _artwork,
      height: _artwork,
      color: colorScheme.surfaceContainerHighest,
      child: Icon(
        placeholderIcon,
        size: 20,
        color: colorScheme.onSurfaceVariant,
      ),
    );
    final subtitle = artistName.isEmpty
        ? kindLabel
        : '$kindLabel · $artistName';
    return DesktopContextMenuRegion(
      onContextMenu: onContextMenu,
      child: Material(
        color: colorScheme.onSurface.withValues(alpha: 0.08),
        borderRadius: radius,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          onLongPress: onLongPress,
          hoverColor: colorScheme.onSurface.withValues(alpha: 0.05),
          child: Padding(
            padding: const EdgeInsetsDirectional.only(start: 14, end: 4),
            child: Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(5),
                  child: coverUrl?.isNotEmpty == true
                      ? CachedCoverImage(
                          imageUrl: coverUrl!,
                          width: _artwork,
                          height: _artwork,
                          fit: BoxFit.cover,
                          errorWidget: (_, _, _) => placeholder,
                        )
                      : placeholder,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      ExplicitTrackTitle(
                        title: title,
                        explicit: explicit,
                        maxLines: 1,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontSize: 15,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          fontSize: 13,
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                trailing,
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A song among the Top Results. A click does what the cover shelf's does;
/// the dots open the song's options.
class _SearchTopSongCard extends ConsumerWidget {
  const _SearchTopSongCard({
    super.key,
    required this.track,
    required this.isInHistory,
    required this.showLocalLibraryIndicator,
    required this.onDownload,
  });

  final Track track;
  final bool isInHistory;
  final bool showLocalLibraryIndicator;
  final void Function({bool forceQualityPicker}) onDownload;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
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
    void showOptions({Offset? position}) =>
        TrackCollectionQuickActions.showTrackOptionsSheet(
          context,
          ref,
          track,
          position: position,
          hasLocalPlaybackCandidate: isInHistory || isInLocalLibrary,
        );
    return _SearchTopResultCard(
      coverUrl: track.coverUrl,
      placeholderIcon: Icons.music_note,
      title: track.name,
      kindLabel: l10n.recentTypeSong,
      artistName: track.artistName,
      explicit: track.explicit == true,
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
      onContextMenu: (position) => showOptions(position: position),
      trailing: IconButton(
        tooltip: MaterialLocalizations.of(context).moreButtonTooltip,
        iconSize: 18,
        icon: const Icon(CupertinoIcons.ellipsis),
        onPressed: showOptions,
      ),
    );
  }
}

/// An album or playlist among the Top Results: a click opens it.
class _SearchTopCollectionCard extends StatelessWidget {
  const _SearchTopCollectionCard({
    super.key,
    required this.item,
    required this.kindLabel,
    required this.onTap,
    required this.onSaveCover,
  });

  final Track item;
  final String kindLabel;
  final VoidCallback onTap;
  final VoidCallback onSaveCover;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final hasCover = item.coverUrl?.isNotEmpty == true;
    return _SearchTopResultCard(
      coverUrl: item.coverUrl,
      placeholderIcon: item.isPlaylistItem ? Icons.playlist_play : Icons.album,
      title: item.name,
      kindLabel: kindLabel,
      artistName: item.artistName,
      explicit: item.explicit == true,
      onTap: onTap,
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
      trailing: Padding(
        padding: const EdgeInsetsDirectional.only(end: 12),
        child: Icon(
          CupertinoIcons.chevron_forward,
          size: 14,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
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
              // Artist cards need no repeated artist-name subtitle.
              if (!(mornye && isArtist)) ...[
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
            ],
          ),
        ),
      ),
    );
  }
}
