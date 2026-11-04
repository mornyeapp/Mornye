// ignore_for_file: invalid_use_of_protected_member
part of 'home_tab.dart';

extension _HomeTabSearchResultsUI on _HomeTabState {
  Future<void> _saveSearchResultCover(Track item) async {
    final coverUrl = item.coverUrl?.trim() ?? '';
    if (coverUrl.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(context.l10n.trackCoverNoSource)));
      return;
    }
    if (!_activeCoverDownloads.add(coverUrl)) return;

    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(context.l10n.updateDownloading)));

    final baseName = item.isCollection || item.artistName.trim().isEmpty
        ? item.name
        : '${item.artistName} - ${item.name}';
    try {
      final saved = await CoverDownloadService.saveRemoteCover(
        coverUrl: coverUrl,
        baseName: baseName,
        settings: ref.read(settingsProvider),
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(content: Text(context.l10n.trackCoverSaved(saved.fileName))),
        );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(
              context.l10n.trackSaveFailed(context.friendlyError(error)),
            ),
          ),
        );
    } finally {
      _activeCoverDownloads.remove(coverUrl);
    }
  }

  Widget _buildErrorWidget(String error, ColorScheme colorScheme) {
    final l10n = context.l10n;
    final isRateLimit =
        error.contains('429') ||
        error.toLowerCase().contains('rate limit') ||
        error.toLowerCase().contains('too many requests');
    final isUrlNotRecognized = error == 'url_not_recognized';
    // Re-runs the current query. Skipped for an unrecognized URL, where the
    // outcome is deterministic and retrying would just fail again.
    final retry = _urlController.text.trim().isEmpty
        ? null
        : () => _performSearch(_urlController.text.trim());

    if (isRateLimit) {
      return ErrorCard(error: error, colorScheme: colorScheme, onRetry: retry);
    }

    if (isUrlNotRecognized) {
      return AppContentCard(
        elevation: 0,
        mornyeSurface: false,
        // Matches ErrorCard: a solid container with its paired on-color.
        color: colorScheme.errorContainer,
        shape: RoundedRectangleBorder(
          borderRadius: context.tokens.borderRadiusCard,
        ),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Icon(Icons.link_off, color: colorScheme.onErrorContainer),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      l10n.errorUrlNotRecognized,
                      style: TextStyle(
                        color: colorScheme.onErrorContainer,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      l10n.errorUrlNotRecognizedMessage,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: colorScheme.onErrorContainer,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    }

    return ErrorCard(
      error: l10n.errorUrlFetchFailed,
      colorScheme: colorScheme,
      onRetry: retry,
    );
  }

  Widget _buildEmptySearchResultWidget(ColorScheme colorScheme) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 340),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          AppShapeBadge(
            kind: AppShapes.badge,
            size: 86,
            color: colorScheme.surfaceContainerHighest,
            child: Icon(
              Icons.manage_search,
              size: 46,
              color: colorScheme.primary,
            ),
          ),
          const SizedBox(height: 16),
          Text(
            context.l10n.errorNoTracksFound,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
              color: colorScheme.onSurface,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            context.l10n.searchEmptyResultSubtitle,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
            ),
          ),
        ],
      ),
    );
  }

  String _sortOptionLabel(HomeSearchSortOption option) {
    switch (option) {
      case HomeSearchSortOption.defaultOrder:
        return context.l10n.searchSortDefault;
      case HomeSearchSortOption.titleAsc:
        return context.l10n.searchSortTitleAZ;
      case HomeSearchSortOption.titleDesc:
        return context.l10n.searchSortTitleZA;
      case HomeSearchSortOption.artistAsc:
        return context.l10n.searchSortArtistAZ;
      case HomeSearchSortOption.artistDesc:
        return context.l10n.searchSortArtistZA;
      case HomeSearchSortOption.durationAsc:
        return context.l10n.searchSortDurationShort;
      case HomeSearchSortOption.durationDesc:
        return context.l10n.searchSortDurationLong;
      case HomeSearchSortOption.dateAsc:
        return context.l10n.searchSortDateOldest;
      case HomeSearchSortOption.dateDesc:
        return context.l10n.searchSortDateNewest;
    }
  }

  void _showSortOptions(ColorScheme colorScheme) {
    var tempSort = _searchSortOption;
    final mornye = context.isMornye;
    showAppModalBottomSheet<void>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      backgroundColor: mornye ? null : colorScheme.surfaceContainerLow,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) {
          final content = SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const AppSheetHandle(),
                  Row(
                    children: [
                      Text(
                        context.l10n.searchSortTitle,
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const Spacer(),
                      ExpressiveButton(
                        text: true,
                        onPressed: () => setSheetState(
                          () => tempSort = HomeSearchSortOption.defaultOrder,
                        ),
                        child: Text(context.l10n.libraryFilterReset),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: HomeSearchSortOption.values.map((option) {
                      if (context.isMornye) {
                        return MornyeFilterChip(
                          label: _sortOptionLabel(option),
                          selected: tempSort == option,
                          onTap: () => setSheetState(() => tempSort = option),
                        );
                      }
                      return AppChoiceChip(
                        label: Text(_sortOptionLabel(option)),
                        selected: tempSort == option,
                        singleChoice: true,
                        onSelected: (_) =>
                            setSheetState(() => tempSort = option),
                      );
                    }).toList(),
                  ),
                  const SizedBox(height: 24),
                  SizedBox(
                    width: double.infinity,
                    child: ExpressiveButton(
                      onPressed: () {
                        Navigator.pop(ctx);
                        if (_searchSortOption != tempSort) {
                          setState(() {
                            _searchSortOption = tempSort;
                          });
                        }
                      },
                      child: Text(context.l10n.libraryFilterApply),
                    ),
                  ),
                ],
              ),
            ),
          );
          return content;
        },
      ),
    );
  }

  ({List<Track> tracks, List<int> indexes}) _sortTrackResults(
    List<Track> tracks,
    List<int> indexes,
  ) {
    if (tracks.isEmpty ||
        _searchSortOption == HomeSearchSortOption.defaultOrder) {
      return (tracks: tracks, indexes: indexes);
    }
    if (identical(tracks, _sortedTracksSource) &&
        identical(indexes, _sortedTrackIndexesSource) &&
        _sortedTracksMode == _searchSortOption &&
        _sortedTracksCache != null &&
        _sortedTrackIndexesCache != null) {
      return (tracks: _sortedTracksCache!, indexes: _sortedTrackIndexesCache!);
    }
    final paired = List.generate(
      tracks.length,
      (i) => (tracks[i], indexes[i]),
      growable: false,
    );
    final sortedPairs = sortHomeSearchItems<(Track, int)>(
      items: paired,
      option: _searchSortOption,
      nameOf: (p) => p.$1.name,
      artistOf: (p) => p.$1.artistName,
      durationOf: (p) => p.$1.duration,
      dateOf: (p) => p.$1.releaseDate,
    );
    final sortedTracks = sortedPairs.map((p) => p.$1).toList(growable: false);
    final sortedIndexes = sortedPairs.map((p) => p.$2).toList(growable: false);
    _sortedTracksSource = tracks;
    _sortedTrackIndexesSource = indexes;
    _sortedTracksMode = _searchSortOption;
    _sortedTracksCache = sortedTracks;
    _sortedTrackIndexesCache = sortedIndexes;
    return (tracks: sortedTracks, indexes: sortedIndexes);
  }

  List<Widget> _buildSearchResults({
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
    bool toolsBesideFilters = false,
  }) {
    final hasActualData = tracks.isNotEmpty;

    if (!hasActualData && isLoading) {
      return [const SliverToBoxAdapter(child: HomeSearchSkeleton())];
    }
    if (!hasResults) {
      return [const SliverToBoxAdapter(child: SizedBox.shrink())];
    }

    final buckets = _getSearchResultBuckets(tracks);
    final realTracks = buckets.realTracks;
    final realTrackIndexes = buckets.realTrackIndexes;
    final albumItems = buckets.albumItems;
    final playlistItems = buckets.playlistItems;
    final artistItems = buckets.artistItems;

    final sortedTrackResults = _sortTrackResults(realTracks, realTrackIndexes);
    final sortedTracks = sortedTrackResults.tracks;
    final sortedTrackIndexes = sortedTrackResults.indexes;

    final slivers = _searchStatusSlivers(
      error: error,
      isLoading: isLoading,
      showEmptyResult: showEmptySearchResult && !hasActualData,
      colorScheme: colorScheme,
    );

    // Phone results sort from the first section.
    bool sortButtonShown = toolsBesideFilters;

    for (final (items, kind, title, open) in [
      (
        artistItems,
        'artist',
        context.l10n.searchArtists,
        _navigateToExtensionArtist,
      ),
      (
        albumItems,
        'album',
        context.l10n.searchAlbums,
        _navigateToExtensionAlbum,
      ),
      (
        playlistItems,
        'playlist',
        context.l10n.searchPlaylists,
        _navigateToExtensionPlaylist,
      ),
    ]) {
      if (items.isEmpty) continue;
      slivers.addAll(
        _buildVirtualizedResultSection(
          title: title,
          itemCount: items.length,
          colorScheme: colorScheme,
          showSortButton: !sortButtonShown,
          itemBuilder: (index, showDivider) => _CollectionItemWidget(
            key: ValueKey('$kind-${items[index].id}'),
            item: items[index],
            showDivider: showDivider,
            onTap: () => open(items[index]),
            onSaveCover: () => _saveSearchResultCover(items[index]),
          ),
        ),
      );
      sortButtonShown = true;
    }

    if (sortedTracks.isNotEmpty) {
      slivers.addAll(
        _buildSearchSongRows(
          resultsRef: resultsRef,
          tracks: sortedTracks,
          indexes: sortedTrackIndexes,
          colorScheme: colorScheme,
          showSortButton: !sortButtonShown,
          searchExtensionId: searchExtensionId,
          showLocalLibraryIndicator: showLocalLibraryIndicator,
          thumbnailSizesByExtensionId: thumbnailSizesByExtensionId,
        ),
      );
    }

    slivers.add(const SliverToBoxAdapter(child: SizedBox(height: 16)));
    return slivers;
  }

  /// The error, the progress bar of a refresh, and the empty result, above
  /// the result sections.
  List<Widget> _searchStatusSlivers({
    required String? error,
    required bool isLoading,
    required bool showEmptyResult,
    required ColorScheme colorScheme,
  }) {
    return <Widget>[
      if (error != null)
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: _buildErrorWidget(error, colorScheme),
          ),
        ),
      if (isLoading)
        const SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: AppProgressIndicator.linear(),
          ),
        ),
      if (showEmptyResult)
        SliverFillRemaining(
          hasScrollBody: false,
          child: Center(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 24, 24, 96),
              child: _buildEmptySearchResultWidget(colorScheme),
            ),
          ),
        ),
    ];
  }

  /// Whether each of [tracks], by index, is in the download history, from
  /// one batch lookup instead of a query per row.
  bool Function(int index) _watchSearchHistory(
    WidgetRef resultsRef,
    List<Track> tracks,
  ) {
    _historySnapshot.update(tracks);
    final historyLookups = _historySnapshot.lookups;
    final existingHistoryKeys = resultsRef.watch(
      downloadHistoryVisibleBatchExistsProvider(_historySnapshot.request),
    );
    return (index) =>
        existingHistoryKeys.contains(historyLookups[index].lookupKey);
  }

  /// The Songs section as phone rows, limited to the first [itemCount] of
  /// [tracks] when given.
  List<Widget> _buildSearchSongRows({
    required WidgetRef resultsRef,
    required List<Track> tracks,
    required List<int> indexes,
    required ColorScheme colorScheme,
    required bool showSortButton,
    required String? searchExtensionId,
    required bool showLocalLibraryIndicator,
    required Map<String, (double, double)> thumbnailSizesByExtensionId,
    int? itemCount,
  }) {
    final isInHistory = _watchSearchHistory(resultsRef, tracks);
    return _buildVirtualizedResultSection(
      title: context.l10n.searchSongs,
      itemCount: itemCount ?? tracks.length,
      colorScheme: colorScheme,
      showSortButton: showSortButton,
      itemBuilder: (index, showDivider) => _TrackItemWithStatus(
        key: ValueKey(tracks[index].id),
        track: tracks[index],
        showDivider: showDivider,
        onDownload: ({bool forceQualityPicker = false}) => _downloadTrack(
          indexes[index],
          forceQualityPicker: forceQualityPicker,
        ),
        searchExtensionId: searchExtensionId,
        showLocalLibraryIndicator: showLocalLibraryIndicator,
        thumbnailSizesByExtensionId: thumbnailSizesByExtensionId,
        isInHistory: isInHistory(index),
        onSaveCover: () => _saveSearchResultCover(tracks[index]),
      ),
    );
  }

  List<Widget> _buildVirtualizedResultSection({
    required String title,
    required int itemCount,
    required ColorScheme colorScheme,
    required Widget Function(int index, bool showDivider) itemBuilder,
    bool showSortButton = false,
  }) {
    // Material result groups are grouped rows, on the settings group tier.
    final sectionColor = colorScheme.surfaceContainer;
    final mornye = context.isMornye;

    return [
      _buildResultSectionHeader(
        title: title,
        colorScheme: colorScheme,
        showSortButton: showSortButton,
      ),
      SliverPadding(
        padding: EdgeInsets.symmetric(horizontal: homeContentInset(context)),
        sliver: SliverList(
          delegate: SliverChildBuilderDelegate((context, index) {
            final isFirst = index == 0;
            final isLast = index == itemCount - 1;
            if (mornye) {
              return Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: MornyeGlassPanel.overlay(
                  blurEnabled: false,
                  radius: 24,
                  firstInGroup: isFirst,
                  lastInGroup: isLast,
                  child: itemBuilder(index, !isLast),
                ),
              );
            }
            // Connected list: each result is its own surface, separated by a
            // 2dp gap with tight inner corners instead of row dividers.
            const inner = Radius.circular(4);
            return StaggeredListItem(
              index: index,
              child: Container(
                margin: EdgeInsets.fromLTRB(16, 0, 16, isLast ? 0 : 2),
                decoration: BoxDecoration(
                  color: sectionColor,
                  borderRadius: BorderRadius.vertical(
                    top: isFirst ? const Radius.circular(20) : inner,
                    bottom: isLast ? const Radius.circular(20) : inner,
                  ),
                ),
                clipBehavior: Clip.antiAlias,
                child: Material(
                  color: Colors.transparent,
                  child: itemBuilder(index, false),
                ),
              ),
            );
          }, childCount: itemCount),
        ),
      ),
    ];
  }

  /// Sort, then the [viewToggle] when given. Material groups them as Library
  /// pages do; Mornye keeps a text Sort and an icon button.
  List<Widget> _buildSearchResultTools(
    ColorScheme colorScheme, {
    required bool showSortButton,
    ToolButton? viewToggle,
  }) {
    final mornye = context.isMornye;
    final sorted = _searchSortOption != HomeSearchSortOption.defaultOrder;
    final sortLabel = sorted
        ? _sortOptionLabel(_searchSortOption)
        : context.l10n.libraryFilterSort;
    return [
      if (!mornye && (showSortButton || viewToggle != null))
        ToolButtonGroup(
          tools: [
            if (showSortButton)
              ToolButton(
                icon: const AppIcon(Icons.sort),
                label: sortLabel,
                onPressed: (_) => _showSortOptions(colorScheme),
              ),
            ?viewToggle,
          ],
        ),
      // Keeps ExpressiveButton's 48dp minimum touch target.
      if (mornye && showSortButton)
        ExpressiveButton(
          text: true,
          onPressed: () => _showSortOptions(colorScheme),
          style: TextButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 8),
          ),
          child: Text(
            sortLabel,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: sorted
                  ? colorScheme.primary
                  : colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      if (mornye && viewToggle != null)
        AppIconButton(
          tooltip: viewToggle.tooltip,
          icon: IconTheme(
            data: IconThemeData(size: 20, color: colorScheme.onSurfaceVariant),
            child: viewToggle.icon,
          ),
          onPressed: () => viewToggle.onPressed(context),
        ),
    ];
  }

  /// A result section's title, with Sort on the first section of phone
  /// results and, on wide screens, the [onShowAll] that switches to the
  /// section's own filter.
  Widget _buildResultSectionHeader({
    required String title,
    required ColorScheme colorScheme,
    required bool showSortButton,
    VoidCallback? onShowAll,
  }) {
    final mornye = context.isMornye;
    // The title and chevron both open the section's complete results.
    if (mornye && onShowAll != null) {
      return SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsetsDirectional.fromSTEB(
            20,
            22,
            12,
            12,
          ).add(EdgeInsets.symmetric(horizontal: homeContentInset(context))),
          child: Align(
            alignment: AlignmentDirectional.centerStart,
            child: Semantics(
              button: true,
              label: context.l10n.searchShowAllCategory(title),
              onTap: onShowAll,
              excludeSemantics: true,
              child: MouseRegion(
                cursor: SystemMouseCursors.click,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: onShowAll,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    spacing: 6,
                    children: [
                      Flexible(
                        child: Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(
                                fontWeight: FontWeight.w700,
                                color: colorScheme.onSurface,
                              ),
                        ),
                      ),
                      Icon(
                        CupertinoIcons.chevron_forward,
                        size: 14,
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    }
    return SliverToBoxAdapter(
      child: Padding(
        // Aligned with the clamped result list below on wide screens.
        padding:
            (mornye
                    ? const EdgeInsetsDirectional.fromSTEB(20, 16, 12, 10)
                    : const EdgeInsetsDirectional.fromSTEB(16, 8, 8, 8))
                .add(
                  EdgeInsets.symmetric(horizontal: homeContentInset(context)),
                ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                title,
                style: mornye
                    ? Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontSize: 20,
                        fontWeight: FontWeight.w700,
                        color: colorScheme.onSurface,
                      )
                    : Theme.of(context).textTheme.titleSmall?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
              ),
            ),
            if (onShowAll != null) _buildShowAllButton(title, onShowAll),
            ..._buildSearchResultTools(
              colorScheme,
              showSortButton: showSortButton,
            ),
          ],
        ),
      ),
    );
  }

  /// Switches wide results between the phone rows and the cover layout, as
  /// the Library's view button does. [grid] is the layout on screen.
  ToolButton _buildSearchViewToggle({required bool grid}) {
    return ToolButton(
      tooltip: grid
          ? context.l10n.appearanceHistoryViewList
          : context.l10n.appearanceHistoryViewGrid,
      icon: AppIcon(grid ? Icons.view_list : Icons.grid_view),
      onPressed: (_) => ref
          .read(settingsProvider.notifier)
          .setSearchViewMode(grid ? 'list' : 'grid'),
    );
  }

  /// Show all, read out with the section it belongs to.
  Widget _buildShowAllButton(String title, VoidCallback onPressed) {
    return ExpressiveButton(
      text: true,
      onPressed: onPressed,
      style: TextButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 8),
      ),
      child: Text(
        context.l10n.searchShowAll,
        semanticsLabel: context.l10n.searchShowAllCategory(title),
      ),
    );
  }

  String? _extensionSourceOrWarn(Track item, String kind) {
    final extensionId = item.source;
    if (extensionId == null || extensionId.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.l10n.errorMissingExtensionSource(kind))),
      );
      return null;
    }

    ref.read(settingsProvider.notifier).setHasSearchedBefore();
    return extensionId;
  }

  void _navigateToExtensionAlbum(Track albumItem) async {
    final extensionId = _extensionSourceOrWarn(albumItem, 'album');
    if (extensionId == null) return;

    ref
        .read(recentAccessProvider.notifier)
        .recordAlbumAccess(
          id: albumItem.id,
          name: albumItem.name,
          artistName: albumItem.artistName,
          imageUrl: albumItem.coverUrl,
          providerId: extensionId,
        );

    pushPage<void>(
      context,
      (context) => ExtensionAlbumScreen(
        extensionId: extensionId,
        albumId: albumItem.id,
        albumName: albumItem.name,
        coverUrl: albumItem.coverUrl,
        initialAlbumType: albumItem.albumType,
        initialTotalTracks: albumItem.totalTracks,
      ),
    );
  }

  void _navigateToExtensionPlaylist(Track playlistItem) async {
    final extensionId = _extensionSourceOrWarn(playlistItem, 'playlist');
    if (extensionId == null) return;

    ref
        .read(recentAccessProvider.notifier)
        .recordPlaylistAccess(
          id: playlistItem.id,
          name: playlistItem.name,
          ownerName: playlistItem.artistName,
          imageUrl: playlistItem.coverUrl,
          providerId: extensionId,
        );

    pushPage<void>(
      context,
      (context) => ExtensionPlaylistScreen(
        extensionId: extensionId,
        playlistId: playlistItem.id,
        playlistName: playlistItem.name,
        coverUrl: playlistItem.coverUrl,
      ),
    );
  }

  void _navigateToExtensionArtist(Track artistItem) {
    final extensionId = _extensionSourceOrWarn(artistItem, 'artist');
    if (extensionId == null) return;

    ref
        .read(recentAccessProvider.notifier)
        .recordArtistAccess(
          id: artistItem.id,
          name: artistItem.name,
          imageUrl: artistItem.coverUrl,
          providerId: extensionId,
        );

    pushPage<void>(
      context,
      (context) => ExtensionArtistScreen(
        extensionId: extensionId,
        artistId: artistItem.id,
        artistName: artistItem.name,
        coverUrl: artistItem.coverUrl,
      ),
    );
  }

  String _getSearchHint() {
    final settings = ref.read(settingsProvider);
    final extState = ref.read(extensionProvider);
    final searchProvider = HomeSearchProviderPolicy.resolveProvider(
      settings.searchProvider,
      extState.extensions,
    );

    if (!extState.isInitialized) {
      return context.l10n.homeSearchHintDefault;
    }

    if (searchProvider != null && searchProvider.isNotEmpty) {
      final ext = extState.extensions
          .where((e) => e.id == searchProvider)
          .firstOrNull;
      if (ext != null && ext.enabled) {
        if (ext.searchBehavior?.placeholder != null) {
          return ext.searchBehavior!.placeholder!;
        }
        return context.l10n.homeSearchHintProvider(ext.displayName);
      }
    }
    return context.l10n.homeSearchHintDefault;
  }

  /// The filter chips, with [tools] at the end of the row. Without
  /// [filters] only the tools show.
  Widget _buildSearchFilterBar(
    List<SearchFilter> filters,
    String? selectedFilter,
    ColorScheme colorScheme, {
    Widget? tools,
  }) {
    Widget filterChip(String id, String label, {IconData? icon}) {
      void select() => _selectSearchFilter(id);

      return context.isMornye
          ? MornyeGlassPanel.overlay(
              radius: 24,
              child: MornyeFilterChip(
                label: label,
                selected: selectedFilter == id,
                icon: icon == null ? null : mornyeIconFor(icon),
                tonal: selectedFilter == id,
                onTap: select,
              ),
            )
          : AppChoiceChip(
              label: Text(label),
              selected: selectedFilter == id,
              onSelected: (_) => select(),
              singleChoice: true,
              icon: icon == null ? null : Icon(icon, size: 18),
            );
    }

    final chips = [
      if (filters.isNotEmpty) filterChip('all', context.l10n.historyFilterAll),
      for (final filter in filters)
        filterChip(
          filter.id,
          filter.label ?? filter.id,
          icon: filter.icon == null ? null : _getFilterIcon(filter.icon!),
        ),
    ];
    // The chips never overlap, so their glass shares one backdrop read.
    final chipRow = LiquidGlassBatch(
      // A mouse cannot swipe a clipped row, so desktop windows wrap every
      // filter onto view.
      child: isDesktopPlatform
          ? Wrap(spacing: 8, runSpacing: 8, children: chips)
          : SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(spacing: 8, children: chips),
            ),
    );
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: 16 + homeContentInset(context)),
      child: tools == null
          ? chipRow
          : Row(
              spacing: 8,
              children: [
                Expanded(child: chipRow),
                tools,
              ],
            ),
    );
  }

  /// Compact desktop navigation with a back action and the provider's full
  /// filter list. Section headings alone cannot expose filters with no results.
  Widget _buildSearchBackBar(
    ColorScheme colorScheme, {
    required bool showBack,
    required List<SearchFilter> filters,
    required String? selectedFilter,
    Widget? tools,
  }) {
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: 20 + homeContentInset(context)),
      child: Row(
        children: [
          if (showBack)
            CupertinoButton(
              padding: EdgeInsets.zero,
              minimumSize: const Size(0, 36),
              onPressed: () => _selectSearchFilter('all'),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                spacing: 4,
                children: [
                  Icon(
                    CupertinoIcons.back,
                    size: 14,
                    color: colorScheme.primary,
                  ),
                  Text(
                    context.l10n.historyFilterAll,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: colorScheme.primary,
                    ),
                  ),
                ],
              ),
            ),
          const Spacer(),
          if (filters.isNotEmpty)
            Builder(
              builder: (buttonContext) => AppIconButton(
                tooltip: context.l10n.libraryFilterTitle,
                icon: const Icon(CupertinoIcons.line_horizontal_3_decrease),
                onPressed: () async {
                  final selected = await showMornyeContextMenu<String>(
                    context: buttonContext,
                    builder: (menuContext) => MornyeContextMenu(
                      dense: true,
                      groups: [
                        [
                          MornyeMenuAction(
                            icon: null,
                            label: context.l10n.historyFilterAll,
                            selected: selectedFilter == 'all',
                            onPressed: () => Navigator.pop(menuContext, 'all'),
                          ),
                          for (final filter in filters.where(
                            (filter) =>
                                canonicalExtensionSearchFilterId(filter.id) !=
                                'all',
                          ))
                            MornyeMenuAction(
                              icon: filter.icon == null
                                  ? null
                                  : mornyeIconFor(_getFilterIcon(filter.icon!)),
                              label: filter.label ?? filter.id,
                              selected: selectedFilter == filter.id,
                              onPressed: () =>
                                  Navigator.pop(menuContext, filter.id),
                            ),
                        ],
                      ],
                    ),
                  );
                  if (selected != null && mounted) {
                    _selectSearchFilter(selected);
                  }
                },
              ),
            ),
          ?tools,
        ],
      ),
    );
  }

  IconData _getFilterIcon(String iconName) {
    switch (iconName.toLowerCase()) {
      case 'music':
      case 'track':
      case 'song':
        return Icons.music_note;
      case 'album':
        return Icons.album;
      case 'artist':
        return Icons.person;
      case 'playlist':
        return Icons.playlist_play;
      case 'video':
        return Icons.video_library;
      case 'podcast':
        return Icons.podcasts;
      default:
        return Icons.search;
    }
  }

  /// Selects the filter chip [id] and searches again with it.
  void _selectSearchFilter(String id) {
    ref.read(trackProvider.notifier).setSearchFilter(id);
    _triggerSearchWithFilter(id);
  }

  void _triggerSearchWithFilter(String? filter) {
    final text = _urlController.text.trim();
    if (text.isEmpty || text.length < _HomeTabState._minLiveSearchChars) return;
    if (looksLikeUrlOrSpotifyUri(text)) return;

    _lastSearchQuery = null;
    _performSearch(text, filterOverride: filter);
  }

  Widget _buildSearchBar() {
    final hasText = _urlController.text.isNotEmpty;
    // The Material Home keeps the resting field clean; import and paste
    // appear once it is focused.
    final showInputActions =
        context.isMornye ||
        widget.mode == HomeTabMode.search ||
        _searchFocusNode.hasFocus;

    final searchingLibrary = _searchingLibrary;
    final compact = _compactSearchField;
    return AppSearchField(
      controller: _urlController,
      compact: compact,
      samplesBackdrop: false,
      focusNode: _searchFocusNode,
      hintText: searchingLibrary
          ? context.l10n.librarySearchHint
          : _getSearchHint(),
      clearTooltip: context.l10n.dialogClear,
      onClear: _clearAndRefresh,
      // Filtering the library needs neither the provider picker nor the
      // import actions.
      prefixIcon: searchingLibrary
          ? null
          : _SearchProviderDropdown(
              onProviderChanged: () {
                _lastSearchQuery = null;
                ref.read(trackProvider.notifier).setSearchFilter(null);
                setState(() {});
                final text = _urlController.text.trim();
                if (text.isNotEmpty &&
                    text.length >= _HomeTabState._minLiveSearchChars) {
                  _performSearch(text);
                }
              },
            ),
      suffixIcon: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (hasText)
            compact
                ? IconButton(
                    icon: const Icon(CupertinoIcons.clear_circled_solid),
                    iconSize: 17,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints.tightFor(
                      width: 30,
                      height: 30,
                    ),
                    onPressed: _clearAndRefresh,
                    tooltip: context.l10n.dialogClear,
                  )
                : AppIconButton(
                    icon: const Icon(Icons.clear),
                    onPressed: _clearAndRefresh,
                    tooltip: context.l10n.dialogClear,
                  )
          else if (showInputActions && !searchingLibrary) ...[
            AppIconButton(
              icon: const Icon(Icons.file_upload_outlined),
              onPressed: _isCsvImporting
                  ? null
                  : () => _importCsv(context, ref),
              tooltip: context.l10n.homeImportCsvTooltip,
            ),
            AppIconButton(
              icon: const Icon(Icons.paste),
              onPressed: _pasteFromClipboard,
              tooltip: context.l10n.actionPaste,
            ),
          ],
          if (!hasText)
            AppIconButton(
              icon: const AppIcon.adaptive(Icons.mic),
              onPressed: _openMusicRecognition,
              tooltip: context.l10n.recognizeSearchTooltip,
            ),
        ],
      ),
      onSubmitted: (_) => _onSearchSubmitted(),
    );
  }

  /// Identifies a song nearby; searches for it when it is not in Mornye.
  Future<void> _openMusicRecognition() async {
    _searchFocusNode.unfocus();
    final query = await pushPage<String>(
      context,
      (_) => const MusicRecognitionScreen(),
    );
    if (!mounted || query == null || query.trim().isEmpty) return;
    _urlController.text = query;
    // The song is not in the library, so the search goes online.
    if (_searchesLibrary) {
      _setSearchScope(library: false);
    } else {
      _onSearchSubmitted();
    }
  }

  void _onSearchSubmitted() {
    _liveSearchDebounce?.cancel();
    _searchGeneration++;

    final text = _urlController.text.trim();
    if (text.isEmpty) return;

    if (_searchingLibrary) {
      _libraryQueryDebounce?.cancel();
      setState(() => _libraryQuery = text);
      _searchFocusNode.unfocus();
      return;
    }

    if (looksLikeUrlOrSpotifyUri(text)) {
      _fetchMetadata();
      _searchFocusNode.unfocus();
      return;
    }

    if (text.length >= 2) {
      _performSearch(text);
    }
    _searchFocusNode.unfocus();
  }
}
