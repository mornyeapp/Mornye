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

    final slivers = <Widget>[
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
      if (showEmptySearchResult && !hasActualData)
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

    bool sortButtonShown = false;

    if (artistItems.isNotEmpty) {
      slivers.addAll(
        _buildVirtualizedResultSection(
          title: context.l10n.searchArtists,
          itemCount: artistItems.length,
          colorScheme: colorScheme,
          showSortButton: !sortButtonShown,
          itemBuilder: (index, showDivider) => _CollectionItemWidget(
            key: ValueKey('artist-${artistItems[index].id}'),
            item: artistItems[index],
            showDivider: showDivider,
            onTap: () => _navigateToExtensionArtist(artistItems[index]),
            onSaveCover: () => _saveSearchResultCover(artistItems[index]),
          ),
        ),
      );
      sortButtonShown = true;
    }

    if (albumItems.isNotEmpty) {
      slivers.addAll(
        _buildVirtualizedResultSection(
          title: context.l10n.searchAlbums,
          itemCount: albumItems.length,
          colorScheme: colorScheme,
          showSortButton: !sortButtonShown,
          itemBuilder: (index, showDivider) => _CollectionItemWidget(
            key: ValueKey('album-${albumItems[index].id}'),
            item: albumItems[index],
            showDivider: showDivider,
            onTap: () => _navigateToExtensionAlbum(albumItems[index]),
            onSaveCover: () => _saveSearchResultCover(albumItems[index]),
          ),
        ),
      );
      sortButtonShown = true;
    }

    if (playlistItems.isNotEmpty) {
      slivers.addAll(
        _buildVirtualizedResultSection(
          title: context.l10n.searchPlaylists,
          itemCount: playlistItems.length,
          colorScheme: colorScheme,
          showSortButton: !sortButtonShown,
          itemBuilder: (index, showDivider) => _CollectionItemWidget(
            key: ValueKey('playlist-${playlistItems[index].id}'),
            item: playlistItems[index],
            showDivider: showDivider,
            onTap: () => _navigateToExtensionPlaylist(playlistItems[index]),
            onSaveCover: () => _saveSearchResultCover(playlistItems[index]),
          ),
        ),
      );
      sortButtonShown = true;
    }

    if (sortedTracks.isNotEmpty) {
      _historySnapshot.update(sortedTracks);
      final historyLookups = _historySnapshot.lookups;
      final existingHistoryKeys = resultsRef.watch(
        downloadHistoryVisibleBatchExistsProvider(_historySnapshot.request),
      );
      slivers.addAll(
        _buildVirtualizedResultSection(
          title: context.l10n.searchSongs,
          itemCount: sortedTracks.length,
          colorScheme: colorScheme,
          showSortButton: !sortButtonShown,
          itemBuilder: (index, showDivider) => _TrackItemWithStatus(
            key: ValueKey(sortedTracks[index].id),
            track: sortedTracks[index],
            index: sortedTrackIndexes[index],
            showDivider: showDivider,
            onDownload: ({bool forceQualityPicker = false}) => _downloadTrack(
              sortedTrackIndexes[index],
              forceQualityPicker: forceQualityPicker,
            ),
            searchExtensionId: searchExtensionId,
            showLocalLibraryIndicator: showLocalLibraryIndicator,
            thumbnailSizesByExtensionId: thumbnailSizesByExtensionId,
            isInHistory: existingHistoryKeys.contains(
              historyLookups[index].lookupKey,
            ),
            onSaveCover: () => _saveSearchResultCover(sortedTracks[index]),
          ),
        ),
      );
    }

    slivers.add(const SliverToBoxAdapter(child: SizedBox(height: 16)));
    return slivers;
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
      SliverToBoxAdapter(
        child: Padding(
          // Aligned with the clamped result list below on wide screens.
          padding:
              (mornye
                      ? const EdgeInsetsDirectional.fromSTEB(20, 16, 12, 10)
                      : const EdgeInsetsDirectional.fromSTEB(16, 8, 8, 8))
                  .add(
                    EdgeInsets.symmetric(horizontal: wideListInset(context)),
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
              // Keeps ExpressiveButton's 48dp minimum touch target.
              if (showSortButton)
                ExpressiveButton(
                  text: true,
                  onPressed: () => _showSortOptions(colorScheme),
                  icon: mornye
                      ? null
                      : Icon(
                          Icons.swap_vert,
                          size: 18,
                          color:
                              _searchSortOption !=
                                  HomeSearchSortOption.defaultOrder
                              ? colorScheme.primary
                              : colorScheme.onSurfaceVariant,
                        ),
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                  ),
                  child: Text(
                    _searchSortOption != HomeSearchSortOption.defaultOrder
                        ? _sortOptionLabel(_searchSortOption)
                        : context.l10n.libraryFilterSort,
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color:
                          _searchSortOption != HomeSearchSortOption.defaultOrder
                          ? colorScheme.primary
                          : colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
      SliverPadding(
        padding: EdgeInsets.symmetric(horizontal: wideListInset(context)),
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

  void _navigateToExtensionAlbum(Track albumItem) async {
    final extensionId = albumItem.source;
    if (extensionId == null || extensionId.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(context.l10n.errorMissingExtensionSource('album')),
        ),
      );
      return;
    }

    ref.read(settingsProvider.notifier).setHasSearchedBefore();

    ref
        .read(recentAccessProvider.notifier)
        .recordAlbumAccess(
          id: albumItem.id,
          name: albumItem.name,
          artistName: albumItem.artistName,
          imageUrl: albumItem.coverUrl,
          providerId: extensionId,
        );

    Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (context) => ExtensionAlbumScreen(
          extensionId: extensionId,
          albumId: albumItem.id,
          albumName: albumItem.name,
          coverUrl: albumItem.coverUrl,
          initialAlbumType: albumItem.albumType,
          initialTotalTracks: albumItem.totalTracks,
        ),
      ),
    );
  }

  void _navigateToExtensionPlaylist(Track playlistItem) async {
    final extensionId = playlistItem.source;
    if (extensionId == null || extensionId.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(context.l10n.errorMissingExtensionSource('playlist')),
        ),
      );
      return;
    }

    ref.read(settingsProvider.notifier).setHasSearchedBefore();

    ref
        .read(recentAccessProvider.notifier)
        .recordPlaylistAccess(
          id: playlistItem.id,
          name: playlistItem.name,
          ownerName: playlistItem.artistName,
          imageUrl: playlistItem.coverUrl,
          providerId: extensionId,
        );

    Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (context) => ExtensionPlaylistScreen(
          extensionId: extensionId,
          playlistId: playlistItem.id,
          playlistName: playlistItem.name,
          coverUrl: playlistItem.coverUrl,
        ),
      ),
    );
  }

  void _navigateToExtensionArtist(Track artistItem) {
    final extensionId = artistItem.source;
    if (extensionId == null || extensionId.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(context.l10n.errorMissingExtensionSource('artist')),
        ),
      );
      return;
    }

    ref.read(settingsProvider.notifier).setHasSearchedBefore();

    ref
        .read(recentAccessProvider.notifier)
        .recordArtistAccess(
          id: artistItem.id,
          name: artistItem.name,
          imageUrl: artistItem.coverUrl,
          providerId: extensionId,
        );

    Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (context) => ExtensionArtistScreen(
          extensionId: extensionId,
          artistId: artistItem.id,
          artistName: artistItem.name,
          coverUrl: artistItem.coverUrl,
        ),
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

  Widget _buildSearchFilterBar(
    List<SearchFilter> filters,
    String? selectedFilter,
    ColorScheme colorScheme,
  ) {
    Widget filterChip(String id, String label, {IconData? icon}) {
      void select() {
        ref.read(trackProvider.notifier).setSearchFilter(id);
        _triggerSearchWithFilter(id);
      }

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
      filterChip('all', context.l10n.historyFilterAll),
      for (final filter in filters)
        filterChip(
          filter.id,
          filter.label ?? filter.id,
          icon: filter.icon == null ? null : _getFilterIcon(filter.icon!),
        ),
    ];
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: 16 + wideListInset(context)),
      // A mouse cannot swipe a clipped row, so desktop windows wrap every
      // filter onto view.
      child: isDesktopPlatform
          ? Wrap(spacing: 8, runSpacing: 8, children: chips)
          : SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(spacing: 8, children: chips),
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
    return AppSearchField(
      controller: _urlController,
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
            AppIconButton(
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
        ],
      ),
      onSubmitted: (_) => _onSearchSubmitted(),
    );
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
