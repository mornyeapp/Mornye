part of 'queue_tab.dart';

extension _QueueTabFilterWidgets on _QueueTabState {
  /// Count text left, action buttons right, always on one line; on narrow
  /// widths the buttons scale down instead of truncating the count.
  Widget _countHeaderRow(
    BuildContext context,
    String countText,
    List<Widget> actions,
  ) {
    final edge = 16 + wideListInset(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(edge, 8, edge, 8),
      child: Row(
        children: [
          Text(
            countText,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: AlignmentDirectional.centerEnd,
              child: Row(mainAxisSize: MainAxisSize.min, children: actions),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFilterContent({
    required BuildContext context,
    required ColorScheme colorScheme,
    required String filterMode,
    required String historyViewMode,
    required bool hasQueueItems,
    required _FilterContentData filterData,
    required LibraryCollectionsState collectionState,
    required bool hasMoreLibrary,
    required bool isPageLoading,
    required List<DownloadHistoryItem> inMemoryHistoryItems,
  }) {
    final showFilteringIndicator = filterData.showFilteringIndicator;
    final filteredGroupedAlbums = filterData.filteredGroupedAlbums;
    final filteredGroupedLocalAlbums = filterData.filteredGroupedLocalAlbums;
    final unifiedItems = filterData.unifiedItems;
    final allFilteredUnifiedItems = filterData.filteredUnifiedItems;
    final totalTrackCount = filterData.totalTrackCount;
    final totalAlbumCount = filterData.totalAlbumCount;
    // Controls and grids share the centered column of the track list.
    final edge = 16 + wideListInset(context);

    final activeDownloadIds = !hasQueueItems || filterMode == 'albums'
        ? const <String>[]
        : ref
              .watch(
                downloadQueueLookupProvider.select(
                  (lookup) => lookup.notCompletedItemIds,
                ),
              )
              .reversed
              .toList(growable: false);

    final bridgeHistoryById = <String, DownloadHistoryItem?>{
      for (final entry in _completionBridge.entries)
        entry.key: _historyItemForCompletionBridge(
          entry.value,
          inMemoryHistoryItems,
        ),
    };
    List<String> bridgeIds = const [];
    if (hasQueueItems &&
        filterMode != 'albums' &&
        _completionBridge.isNotEmpty) {
      final libIdSet = <String>{
        for (final item in allFilteredUnifiedItems) item.id,
      };
      final now = DateTime.now();
      final stale = <String>[];
      final pending = <String>[];
      final hasActiveDownloads = activeDownloadIds.isNotEmpty;
      final queueItems = ref.read(downloadQueueLookupProvider).byItemId;
      _completionBridge.forEach((id, _) {
        final historyItem = bridgeHistoryById[id];
        final historyId = historyItem?.id ?? id;
        final landed = libIdSet.contains('dl_$historyId');
        final addedAt = _completionBridgeAt[id];
        final expired =
            addedAt == null || now.difference(addedAt).inSeconds >= 6;
        if (shouldRetainCompletionBridge(
          queueItemExists: queueItems.containsKey(id),
          isRequeued: activeDownloadIds.contains(id),
          hasActiveDownloads: hasActiveDownloads,
          libraryRowLanded: landed,
          hasHistoryItem: historyItem != null,
          expired: expired,
        )) {
          // Keep completed tracks pinned while their batch is active or their
          // persisted History row is still waiting for the paged Library.
          pending.add(id);
        } else {
          // Re-queued items are represented by the live row; landed items by
          // the normal Library row; unpersisted bridges retain a short grace.
          stale.add(id);
        }
      });
      bridgeIds = pending;
      if (stale.isNotEmpty) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          var changed = false;
          for (final id in stale) {
            if (_completionBridge.remove(id) != null) changed = true;
            _completionBridgeAt.remove(id);
            _bridgePrecacheStarted.remove(id);
          }
          if (changed) _setState(() {});
        });
      }
      final toPrecache = pending
          .where((id) => !_bridgePrecacheStarted.contains(id))
          .toList(growable: false);
      if (toPrecache.isNotEmpty) {
        for (final id in toPrecache) {
          final historyItem = bridgeHistoryById[id];
          if (historyItem == null) continue;
          _bridgePrecacheStarted.add(id);
          final coverUrl = historyItem.coverUrl;
          final embeddedPath = _resolveDownloadedEmbeddedCoverPath(
            historyItem.filePath,
          );
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            try {
              // Decode at the same 200px extent the grid cell renders with
              // (queue_tab_item_widgets cacheSize) so the precache shares the
              // cell's cache entry; embedded covers can be 3000x3000 and a
              // full-res decode evicts the whole low-RAM image cache.
              const targetSize = 200;
              if (embeddedPath != null) {
                precacheImage(
                  ResizeImage(
                    FileImage(File(embeddedPath)),
                    width: targetSize,
                    height: targetSize,
                  ),
                  context,
                );
              }
              if (coverUrl != null && coverUrl.isNotEmpty) {
                precacheImage(
                  ResizeImage(
                    cachedCoverImageProvider(coverUrl),
                    width: targetSize,
                    height: targetSize,
                  ),
                  context,
                );
              }
            } catch (_) {}
          });
        }
      }
    }

    // Tracks pinned as completion-bridge cells render in the lead zone;
    // hide their history rows so they don't appear twice.
    List<UnifiedLibraryItem> filteredUnifiedItems = allFilteredUnifiedItems;
    if (bridgeIds.isNotEmpty) {
      final pinnedHistoryIds = <String>{
        for (final id in bridgeIds) 'dl_${bridgeHistoryById[id]?.id ?? id}',
      };
      filteredUnifiedItems = allFilteredUnifiedItems
          .where((item) => !pinnedHistoryIds.contains(item.id))
          .toList(growable: false);
    }

    final downloadedNavigationItems = <DownloadHistoryItem>[];
    final downloadedNavigationIndexByUnifiedId = <String, int>{};
    final localNavigationItems = <LocalLibraryItem>[];
    final localNavigationIndexByUnifiedId = <String, int>{};

    for (final item in filteredUnifiedItems) {
      final historyItem = item.historyItem;
      if (historyItem != null) {
        downloadedNavigationIndexByUnifiedId[item.id] =
            downloadedNavigationItems.length;
        downloadedNavigationItems.add(historyItem);
      }

      final localItem = item.localItem;
      if (localItem != null) {
        localNavigationIndexByUnifiedId[item.id] = localNavigationItems.length;
        localNavigationItems.add(localItem);
      }
    }

    // Completion-bridge tracks are hidden from filteredUnifiedItems, so weave
    // them into the front of the swipe-navigation list (matching their pinned
    // lead-zone position) — otherwise a just-downloaded track opens with no
    // swipe navigation at all until its row lands in the library query.
    final bridgeNavigationIndexById = <String, int>{};
    if (bridgeIds.isNotEmpty) {
      final bridgeHistoryItems = <DownloadHistoryItem>[];
      for (final id in bridgeIds) {
        final historyItem = bridgeHistoryById[id];
        if (historyItem == null) continue;
        bridgeNavigationIndexById[id] = bridgeHistoryItems.length;
        bridgeHistoryItems.add(historyItem);
      }
      if (bridgeHistoryItems.isNotEmpty) {
        downloadedNavigationItems.insertAll(0, bridgeHistoryItems);
        downloadedNavigationIndexByUnifiedId.updateAll(
          (_, index) => index + bridgeHistoryItems.length,
        );
      }
    }

    final leadCount = activeDownloadIds.length + bridgeIds.length;
    // The tab-root Library keeps Songs to songs: collections live on the
    // Playlists page. Section pages opened from Mornye keep them inline.
    final rootLibrary = widget.librarySection == null;
    final collectionEntries = filterMode == 'all' && !rootLibrary
        ? _getVisibleCollectionEntries(collectionState)
        : const <_CollectionEntry>[];
    final collectionCount = collectionEntries.length;
    final specialEntries = filterMode == 'playlists' && rootLibrary
        ? _getVisibleCollectionEntries(collectionState)
              .where((entry) => entry.type != _CollectionEntryType.playlist)
              .toList(growable: false)
        : const <_CollectionEntry>[];
    // Material lists group rows under pinned sections.
    final sectioned = rootLibrary && !context.isMornye;

    // Indexes into collectionState.playlists, name-filtered by the search
    // query, for the 'playlists' view.
    final playlistIndexes = <int>[];
    if (filterMode == 'playlists') {
      final query = _searchQuery.trim().toLowerCase();
      for (var i = 0; i < collectionState.playlists.length; i++) {
        if (query.isEmpty ||
            collectionState.playlists[i].name.toLowerCase().contains(query)) {
          playlistIndexes.add(i);
        }
      }
      playlistIndexes.sort((a, b) {
        final first = collectionState.playlists[a];
        final second = collectionState.playlists[b];
        return switch (_sortMode) {
          'a-z' => first.name.toLowerCase().compareTo(
            second.name.toLowerCase(),
          ),
          'z-a' => second.name.toLowerCase().compareTo(
            first.name.toLowerCase(),
          ),
          'oldest' => first.createdAt.compareTo(second.createdAt),
          _ => second.updatedAt.compareTo(first.updatedAt),
        };
      });
    }

    Widget leadGridCell(int index) {
      if (index < activeDownloadIds.length) {
        final id = activeDownloadIds[index];
        return _QueueItemSliverRow(
          key: ValueKey('dlgrid_$id'),
          itemId: id,
          colorScheme: colorScheme,
          itemBuilder: _buildDownloadGridItem,
        );
      }
      final bridgeId = bridgeIds[index - activeDownloadIds.length];
      return KeyedSubtree(
        key: ValueKey('dlgrid_bridge_$bridgeId'),
        child: _buildBridgeItem(
          context,
          _completionBridge[bridgeId]!,
          colorScheme,
          bridgeHistoryById[bridgeId],
          grid: true,
          navigationItems: downloadedNavigationItems,
          navigationIndex: bridgeNavigationIndexById[bridgeId],
        ),
      );
    }

    // Active downloads and the library tracks below them form one connected
    // run of rows.
    Widget leadListCell(int index) {
      // Sectioned lists and desktop tables keep the active downloads as
      // their own run.
      final runLength = isDesktopPlatform || (rootLibrary && !context.isMornye)
          ? leadCount
          : leadCount + filteredUnifiedItems.length;
      if (index < activeDownloadIds.length) {
        final id = activeDownloadIds[index];
        return TrackCardSegment.at(
          key: ValueKey('dllist_$id'),
          index: index,
          count: runLength,
          child: _QueueItemSliverRow(
            itemId: id,
            colorScheme: colorScheme,
            itemBuilder: _buildQueueItem,
          ),
        );
      }
      final bridgeId = bridgeIds[index - activeDownloadIds.length];
      return TrackCardSegment.at(
        key: ValueKey('dllist_bridge_$bridgeId'),
        index: index,
        count: runLength,
        child: _buildBridgeItem(
          context,
          _completionBridge[bridgeId]!,
          colorScheme,
          bridgeHistoryById[bridgeId],
          grid: false,
          navigationItems: downloadedNavigationItems,
          navigationIndex: bridgeNavigationIndexById[bridgeId],
        ),
      );
    }

    // Songs drag onto playlists; singles do not.
    final playlistDrag = filterMode == 'all';
    Widget trackTile(UnifiedLibraryItem item, {required bool grid}) {
      final tile = (grid ? _buildUnifiedGridItem : _buildUnifiedLibraryItem)(
        context,
        item,
        colorScheme,
        downloadedNavigationItems: downloadedNavigationItems,
        downloadedNavigationIndex:
            downloadedNavigationIndexByUnifiedId[item.id],
        localNavigationItems: localNavigationItems,
        localNavigationIndex: localNavigationIndexByUnifiedId[item.id],
        libraryItems: filteredUnifiedItems,
        playlistDragEnabled: playlistDrag,
      );
      if (!playlistDrag) return tile;
      return LibraryPlaylistDragSource<UnifiedLibraryItem>(
        data: item,
        onSelect: () => _selectDraggedTrack(item, filteredUnifiedItems),
        onDragStarted: _startLibraryTrackDrag,
        onDragEnd: _endLibraryTrackDrag,
        feedbackBuilder: (context) =>
            _buildDragFeedback(context, item, colorScheme),
        child: tile,
      );
    }

    Widget trackCountHeader() => SliverToBoxAdapter(
      child: _countHeaderRow(
        context,
        context.l10n.queueTrackCount(totalTrackCount),
        [
          if (rootLibrary && !_isSelectionMode)
            ..._buildLibraryTools(context, viewMode: historyViewMode)
          else if (!_isSelectionMode)
            _buildFilterButton(context),
          // The root Library creates playlists from the Playlists page.
          if (!rootLibrary &&
              !_isSelectionMode &&
              filteredUnifiedItems.isNotEmpty)
            ExpressiveButton(
              text: true,
              onPressed: () => _showCreatePlaylistDialog(context),
              icon: const Icon(Icons.add, size: 20),
              style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
              child: Text(context.l10n.collectionCreatePlaylist),
            ),
        ],
      ),
    );

    final content = CustomScrollView(
      slivers: [
        if (rootLibrary && (filterMode == 'albums' || filterMode == 'singles'))
          SliverToBoxAdapter(child: _buildAlbumsModeToggle(context)),

        // Rewind lives with the listening history it replays.
        if (rootLibrary &&
            filterMode == 'all' &&
            _searchQuery.isEmpty &&
            !context.isMornye &&
            !_isSelectionMode &&
            ref.watch(
              settingsProvider.select((s) => s.listeningStatisticsEnabled),
            ))
          SliverToBoxAdapter(
            child: ListeningRewindBanner(
              margin: EdgeInsets.fromLTRB(edge, 8, edge, 4),
            ),
          ),

        if (totalTrackCount > 0 && filterMode == 'all') trackCountHeader(),

        if ((filteredGroupedAlbums.isNotEmpty ||
                filteredGroupedLocalAlbums.isNotEmpty) &&
            filterMode == 'albums')
          SliverToBoxAdapter(
            child: _countHeaderRow(
              context,
              context.l10n.queueAlbumCount(totalAlbumCount),
              [
                if (rootLibrary)
                  ..._buildLibraryTools(context)
                else
                  _buildFilterButton(context),
              ],
            ),
          ),

        if (filteredGroupedAlbums.isEmpty &&
            filteredGroupedLocalAlbums.isEmpty &&
            filterMode == 'albums' &&
            (_activeFilterCount > 0 ||
                ref.read(downloadHistoryProvider).totalCount > 0 ||
                (ref.read(settingsProvider).localLibraryEnabled &&
                    ref.read(localLibraryProvider).totalCount > 0)))
          SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.fromLTRB(edge, 8, edge, 8),
              child: Row(
                children: [const Spacer(), _buildFilterButton(context)],
              ),
            ),
          ),

        if ((filterMode == 'all' || filterMode == 'singles') &&
            totalTrackCount == 0 &&
            !showFilteringIndicator &&
            (_activeFilterCount > 0 || unifiedItems.isNotEmpty))
          SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.fromLTRB(edge, 8, edge, 8),
              child: Row(
                children: [
                  const Spacer(),
                  if (!_isSelectionMode) _buildFilterButton(context),
                ],
              ),
            ),
          ),

        if (showFilteringIndicator)
          SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.fromLTRB(edge, 12, edge, 8),
              child: Row(
                children: [
                  AppLoadingIndicator(
                    size: 18,
                    strokeWidth: 2,
                    color: colorScheme.primary,
                  ),
                  const SizedBox(width: 12),
                  Text(
                    context.l10n.queueFilteringIndicator,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),

        if (filterMode == 'all' && hasQueueItems)
          _buildQueueHeaderSliver(context, colorScheme),

        if (filterMode == 'albums' &&
            (filteredGroupedAlbums.isNotEmpty ||
                filteredGroupedLocalAlbums.isNotEmpty))
          SliverPadding(
            padding: EdgeInsets.symmetric(horizontal: edge),
            sliver: AnimatedLibrarySliverGrid(
              maxCrossAxisExtent: _QueueTabState._libraryGridDefaultExtent,
              extentListenable: _libraryGridExtent,
              extentScale: 1.45,
              minExtent: 150,
              maxExtent: 300,
              mainAxisSpacing: 12,
              crossAxisSpacing: 12,
              childAspectRatio: 0.72,
              delegate: SliverChildBuilderDelegate(
                (context, index) {
                  if (index < filteredGroupedAlbums.length) {
                    final album = filteredGroupedAlbums[index];
                    return KeyedSubtree(
                      key: ValueKey(album.key),
                      child: _buildAlbumGridItem(context, album, colorScheme),
                    );
                  } else {
                    final localIndex = index - filteredGroupedAlbums.length;
                    final album = filteredGroupedLocalAlbums[localIndex];
                    return KeyedSubtree(
                      key: ValueKey('local_${album.key}'),
                      child: _buildLocalAlbumGridItem(
                        context,
                        album,
                        colorScheme,
                      ),
                    );
                  }
                },
                childCount:
                    filteredGroupedAlbums.length +
                    filteredGroupedLocalAlbums.length,
              ),
            ),
          ),

        if (filterMode == 'playlists' &&
            (playlistIndexes.isNotEmpty || specialEntries.isNotEmpty)) ...[
          SliverToBoxAdapter(
            child: _countHeaderRow(
              context,
              context.l10n.queuePlaylistCount(playlistIndexes.length),
              [
                if (!_isPlaylistSelectionMode)
                  ExpressiveButton(
                    text: true,
                    onPressed: () => _showCreatePlaylistDialog(context),
                    icon: const Icon(Icons.add, size: 20),
                    style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                    ),
                    child: Text(context.l10n.collectionCreatePlaylist),
                  ),
              ],
            ),
          ),
          SliverPadding(
            padding: EdgeInsets.symmetric(horizontal: edge),
            sliver: AnimatedLibrarySliverGrid(
              maxCrossAxisExtent: _QueueTabState._libraryGridDefaultExtent,
              extentListenable: _libraryGridExtent,
              extentScale: 1.45,
              minExtent: 150,
              maxExtent: 300,
              mainAxisSpacing: 12,
              crossAxisSpacing: 12,
              childAspectRatio: 0.72,
              delegate: SliverChildBuilderDelegate((context, index) {
                // Wishlist, Loved and Favorite artists lead the grid.
                if (index < specialEntries.length) {
                  final entry = specialEntries[index];
                  return KeyedSubtree(
                    key: ValueKey('plgrid_special_${entry.type.name}'),
                    child: _buildAllTabGridCollectionItem(
                      context: context,
                      colorScheme: colorScheme,
                      entry: entry,
                      collectionState: collectionState,
                    ),
                  );
                }
                final playlistIndex =
                    playlistIndexes[index - specialEntries.length];
                return KeyedSubtree(
                  key: ValueKey(
                    'plgrid_${collectionState.playlists[playlistIndex].id}',
                  ),
                  child: _buildAllTabGridCollectionItem(
                    context: context,
                    colorScheme: colorScheme,
                    entry: _CollectionEntry.playlist(playlistIndex),
                    collectionState: collectionState,
                  ),
                );
              }, childCount: specialEntries.length + playlistIndexes.length),
            ),
          ),
        ],

        if (filterMode == 'singles') ...[
          trackCountHeader(),
          _buildQueueHeaderSliver(context, colorScheme),
        ],

        // Songs list collections first; singles hide an empty track list.
        if (filterMode == 'all' ||
            (filterMode == 'singles' &&
                (filteredUnifiedItems.isNotEmpty || leadCount > 0)))
          if (historyViewMode == 'grid')
            SliverPadding(
              padding: EdgeInsets.symmetric(horizontal: edge),
              sliver: AnimatedLibrarySliverGrid(
                maxCrossAxisExtent: _QueueTabState._libraryGridDefaultExtent,
                extentListenable: _libraryGridExtent,
                mainAxisSpacing: 8,
                crossAxisSpacing: 8,
                childAspectRatio: 0.66,
                delegate: SliverChildBuilderDelegate(
                  (context, index) {
                    if (index < collectionCount) {
                      return _buildAllTabGridCollectionItem(
                        context: context,
                        colorScheme: colorScheme,
                        entry: collectionEntries[index],
                        collectionState: collectionState,
                        filteredUnifiedItems: filteredUnifiedItems,
                      );
                    }
                    final afterCollections = index - collectionCount;
                    if (afterCollections < leadCount) {
                      return leadGridCell(afterCollections);
                    }
                    final trackIndex = afterCollections - leadCount;
                    if (trackIndex < filteredUnifiedItems.length) {
                      final item = filteredUnifiedItems[trackIndex];
                      return KeyedSubtree(
                        key: ValueKey(item.id),
                        child: trackTile(item, grid: true),
                      );
                    }
                    return const SizedBox.shrink();
                  },
                  childCount:
                      leadCount + collectionCount + filteredUnifiedItems.length,
                ),
              ),
            )
          else if (isDesktopPlatform &&
              (filteredUnifiedItems.isNotEmpty ||
                  leadCount > 0 ||
                  collectionCount > 0))
            // Desktop lists songs in the sortable table, with the collections
            // and active downloads leading it.
            _buildLibrarySongTable(
              context,
              items: filteredUnifiedItems,
              leadCount: collectionCount + leadCount,
              leadBuilder: (index) => index < collectionCount
                  ? _buildAllTabListCollectionItem(
                      context: context,
                      colorScheme: colorScheme,
                      entry: collectionEntries[index],
                      collectionState: collectionState,
                      filteredUnifiedItems: filteredUnifiedItems,
                    )
                  : leadListCell(index - collectionCount),
              openAction: (item) => _libraryItemOpenAction(
                item,
                downloadedNavigationItems: downloadedNavigationItems,
                downloadedNavigationIndex:
                    downloadedNavigationIndexByUnifiedId[item.id],
                localNavigationItems: localNavigationItems,
                localNavigationIndex: localNavigationIndexByUnifiedId[item.id],
              ),
            )
          else if (sectioned)
            _buildSectionedTrackSlivers(
              context: context,
              items: filteredUnifiedItems,
              leadCount: leadCount,
              leadBuilder: leadListCell,
              rowBuilder: (index) =>
                  trackTile(filteredUnifiedItems[index], grid: false),
            )
          else
            SliverPadding(
              padding: EdgeInsets.symmetric(horizontal: wideListInset(context)),
              sliver: SliverList(
                delegate: SliverChildBuilderDelegate(
                  (context, index) {
                    if (index < collectionCount) {
                      return _buildAllTabListCollectionItem(
                        context: context,
                        colorScheme: colorScheme,
                        entry: collectionEntries[index],
                        collectionState: collectionState,
                        filteredUnifiedItems: filteredUnifiedItems,
                      );
                    }
                    final afterCollections = index - collectionCount;
                    if (afterCollections < leadCount) {
                      return leadListCell(afterCollections);
                    }
                    final trackIndex = afterCollections - leadCount;
                    if (trackIndex < filteredUnifiedItems.length) {
                      final item = filteredUnifiedItems[trackIndex];
                      return TrackCardSegment.at(
                        key: ValueKey(item.id),
                        index: afterCollections,
                        count: leadCount + filteredUnifiedItems.length,
                        child: trackTile(item, grid: false),
                      );
                    }
                    return const SizedBox.shrink();
                  },
                  childCount:
                      leadCount + collectionCount + filteredUnifiedItems.length,
                ),
              ),
            ),

        if (!hasQueueItems &&
            totalTrackCount == 0 &&
            (filterMode != 'albums' ||
                (filteredGroupedAlbums.isEmpty &&
                    filteredGroupedLocalAlbums.isEmpty)) &&
            (filterMode != 'playlists' ||
                (playlistIndexes.isEmpty && specialEntries.isEmpty)) &&
            !showFilteringIndicator &&
            !isPageLoading)
          SliverFillRemaining(
            hasScrollBody: false,
            child: _buildEmptyState(context, colorScheme, filterMode),
          )
        else if (isPageLoading)
          SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.fromLTRB(edge, 12, edge, 8),
              child: Center(
                child: AppLoadingIndicator(
                  size: 22,
                  strokeWidth: 2,
                  color: colorScheme.primary,
                ),
              ),
            ),
          ),

        if (hasQueueItems ||
            totalTrackCount > 0 ||
            (filterMode == 'albums' &&
                (filteredGroupedAlbums.isNotEmpty ||
                    filteredGroupedLocalAlbums.isNotEmpty)) ||
            (filterMode == 'playlists' &&
                (playlistIndexes.isNotEmpty || specialEntries.isNotEmpty)))
          SliverToBoxAdapter(
            child: SizedBox(height: _isSelectionMode ? 100 : 16),
          ),
        const NavBarSliverSpacer(),
      ],
    );

    // The fast scroller follows the loaded rows. Near-end notifications load
    // the next page while a drag continues.
    final albumCount =
        filteredGroupedAlbums.length + filteredGroupedLocalAlbums.length;
    String? labelAt(double fraction) {
      if (filterMode == 'albums') {
        if (albumCount == 0) return null;
        final index = (fraction * (albumCount - 1)).round();
        if (index < filteredGroupedAlbums.length) {
          final album = filteredGroupedAlbums[index];
          return _albumSectionLabel(
            context,
            album: album.albumName,
            artist: album.artistName,
            added: album.latestDownload,
          );
        }
        final album =
            filteredGroupedLocalAlbums[index - filteredGroupedAlbums.length];
        return _albumSectionLabel(
          context,
          album: album.albumName,
          artist: album.artistName,
          added: album.latestScanned,
        );
      }
      if (filterMode != 'all' && filterMode != 'singles') return null;
      final rows = collectionCount + leadCount + filteredUnifiedItems.length;
      if (rows == 0) return null;
      final itemIndex =
          (fraction * (rows - 1)).round() - collectionCount - leadCount;
      if (itemIndex < 0 || itemIndex >= filteredUnifiedItems.length) {
        return null;
      }
      return _trackSectionLabel(context, filteredUnifiedItems[itemIndex]);
    }

    final scrollAwareContent = NotificationListener<ScrollNotification>(
      onNotification: (notification) => _handleLibraryScrollNotification(
        notification: notification,
        filterMode: filterMode,
        hasMoreLibrary: hasMoreLibrary,
        isPageLoading: isPageLoading,
      ),
      child: LibraryFastScroller(
        topPadding: MediaQuery.paddingOf(context).top + kToolbarHeight,
        bottomPadding: context.navBarBottomInset,
        labelAt: labelAt,
        child: content,
      ),
    );

    if (historyViewMode != 'grid') return scrollAwareContent;
    return TwoFingerPinchListener(
      onStart: _handleLibraryGridPinchStart,
      onUpdate: _handleLibraryGridPinchUpdate,
      onEnd: _handleLibraryGridPinchEnd,
      child: scrollAwareContent,
    );
  }

  Future<void> _showClearAllDialog(
    BuildContext context,
    WidgetRef ref,
    ColorScheme colorScheme,
  ) async {
    final confirmed = await showAppDialog<bool>(
      context: context,
      builder: (ctx) => AppAlertDialog(
        title: Text(context.l10n.queueClearAll),
        content: Text(context.l10n.queueClearAllMessage),
        actions: [
          AppDialogAction(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(context.l10n.dialogCancel),
          ),
          AppDialogAction(
            filled: true,
            isDestructive: true,
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(backgroundColor: colorScheme.error),
            child: Text(context.l10n.dialogClear),
          ),
        ],
      ),
    );

    if (confirmed == true && context.mounted) {
      ref.read(downloadQueueProvider.notifier).clearAll();
    }
  }

  Widget _buildEmptyState(
    BuildContext context,
    ColorScheme colorScheme,
    String filterMode,
  ) {
    String message;
    String subtitle;
    IconData icon;

    switch (filterMode) {
      case 'albums':
        message = context.l10n.queueEmptyAlbums;
        subtitle = context.l10n.queueEmptyAlbumsSubtitle;
        icon = Icons.album;
        break;
      case 'singles':
        message = context.l10n.queueEmptySingles;
        subtitle = context.l10n.queueEmptySinglesSubtitle;
        icon = Icons.music_note;
        break;
      case 'playlists':
        message = context.l10n.collectionNoPlaylistsYet;
        subtitle = context.l10n.queueEmptyPlaylistsSubtitle;
        icon = Icons.queue_music;
        break;
      default:
        message = context.l10n.queueEmptyHistory;
        subtitle = context.l10n.queueEmptyHistorySubtitle;
        icon = Icons.history;
    }

    if (context.isMornye) {
      return EmptyState(
        icon: icon,
        title: message,
        message: subtitle,
        // Every empty branch here means "you have not downloaded anything of
        // this kind yet", so the way forward is always search.
        action: ExpressiveButton(
          onPressed: () => ShellNavigationService.requestTab(ShellTab.home),
          icon: const Icon(Icons.search),
          child: Text(context.l10n.navHome),
        ),
      );
    }

    // Material names the next step in the copy. Home already sits in the
    // navigation bar, so only creating the first playlist, which the empty
    // Playlists page does not otherwise offer, gets a button.
    return EmptyState(
      icon: icon,
      title: message,
      message: subtitle,
      action: filterMode == 'playlists'
          ? ExpressiveButton(
              onPressed: () => _showCreatePlaylistDialog(context),
              icon: const Icon(Icons.add),
              child: Text(context.l10n.collectionCreatePlaylist),
            )
          : null,
    );
  }

  Widget _buildAlbumGridItem(
    BuildContext context,
    _GroupedAlbum album,
    ColorScheme colorScheme,
  ) {
    return ValueListenableBuilder<int>(
      valueListenable: _embeddedCoverVersion,
      builder: (context, _, child) {
        final embeddedCoverPath = _resolveDownloadedEmbeddedCoverPath(
          album.sampleFilePath,
        );
        return _buildAlbumGridItemCore(
          context: context,
          albumName: album.albumName,
          artistName: album.artistName,
          trackCount: album.displayTrackCount,
          completeness: album.completeness,
          colorScheme: colorScheme,
          coverWidget: embeddedCoverPath != null
              ? Image.file(
                  File(embeddedCoverPath),
                  fit: BoxFit.cover,
                  width: double.infinity,
                  height: double.infinity,
                  cacheWidth: 300,
                  cacheHeight: 300,
                  errorBuilder: (context, error, stackTrace) =>
                      _albumPlaceholder(colorScheme),
                )
              : album.coverUrl != null
              ? CachedCoverImage(
                  imageUrl: album.coverUrl!,
                  fit: BoxFit.cover,
                  width: double.infinity,
                  height: double.infinity,
                  memCacheWidth: 300,
                  memCacheHeight: 300,
                )
              : null,
          badgeIcon: Icons.music_note,
          coverUrl: album.coverUrl,
          onTap: () => _navigateToDownloadedAlbum(album),
          onPlay: () => _playDownloadedAlbum(album),
        );
      },
    );
  }

  Widget _buildLocalAlbumGridItem(
    BuildContext context,
    _GroupedLocalAlbum album,
    ColorScheme colorScheme,
  ) {
    return LocalLibraryArtworkBuilder(
      coverPath: album.coverPath,
      filePath: album.sampleFilePath,
      builder: (context, coverPath) => _buildAlbumGridItemCore(
        context: context,
        albumName: album.albumName,
        artistName: album.artistName,
        trackCount: album.displayTrackCount,
        completeness: album.completeness,
        colorScheme: colorScheme,
        coverWidget: coverPath != null
            ? Image.file(
                File(coverPath),
                fit: BoxFit.cover,
                width: double.infinity,
                height: double.infinity,
                cacheWidth: 300,
                cacheHeight: 300,
                errorBuilder: (context, error, stackTrace) =>
                    _albumPlaceholder(colorScheme),
              )
            : null,
        badgeIcon: Icons.folder,
        onTap: () => _navigateToLocalAlbum(album),
        onPlay: () => _playLocalAlbum(album),
      ),
    );
  }

  Widget _albumPlaceholder(ColorScheme colorScheme) {
    return Container(
      color: colorScheme.surfaceContainerHighest,
      child: Center(
        child: AppIcon(
          Icons.album,
          color: colorScheme.onSurfaceVariant,
          size: 48,
        ),
      ),
    );
  }

  Widget _buildAlbumGridItemCore({
    required BuildContext context,
    required String albumName,
    required String artistName,
    required int trackCount,
    required ColorScheme colorScheme,
    required Widget? coverWidget,
    required IconData badgeIcon,
    required VoidCallback onTap,
    VoidCallback? onPlay,
    String? coverUrl,
    AlbumCompleteness? completeness,
  }) {
    final completenessLabel = completeness == null
        ? null
        : completeness.status == 'unknown'
        ? context.l10n.libraryAlbumCompletenessUnknown
        : completeness.expected == null
        ? context.l10n.libraryFilterIncompleteAlbums
        : context.l10n.libraryAlbumMissingTracks(
            completeness.present,
            completeness.expected!,
            completeness.expected! - completeness.present,
          );
    return Semantics(
      button: true,
      label: [
        context.l10n.a11yOpenAlbumByArtistTrackCount(
          albumName,
          artistName,
          trackCount,
        ),
        ?completenessLabel,
      ].join('. '),
      child: DesktopContextMenuRegion(
        onContextMenu: (position) => showContextMenu(
          context,
          position: position,
          groups: [
            [
              ContextMenuAction(
                icon: Icons.open_in_new,
                label: context.l10n.desktopMenuOpen,
                onSelected: onTap,
              ),
              if (onPlay != null)
                ContextMenuAction(
                  icon: Icons.play_arrow_rounded,
                  label: context.l10n.tooltipPlay,
                  onSelected: onPlay,
                ),
            ],
          ],
        ),
        child: GestureDetector(
          onTap: onTap,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Stack(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: coverWidget ?? _albumPlaceholder(colorScheme),
                    ),
                    PositionedDirectional(
                      end: 8,
                      bottom: 8,
                      child: Tooltip(
                        message:
                            completenessLabel ??
                            context.l10n.tracksCount(trackCount),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            color: colorScheme.surfaceContainerHighest,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              AppIcon(
                                badgeIcon,
                                size: 12,
                                color: colorScheme.onSurfaceVariant,
                              ),
                              const SizedBox(width: 4),
                              Text(
                                completeness?.badge ?? '$trackCount',
                                style: TextStyle(
                                  color: colorScheme.onSurfaceVariant,
                                  fontSize: 12,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    DesktopHoverPlayButton(
                      tooltip: context.l10n.tooltipPlay,
                      onPlay: onPlay,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              Text(
                albumName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(
                  context,
                ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
              ),
              ClickableArtistName(
                artistName: artistName,
                coverUrl: coverUrl,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  List<UnifiedLibraryItem> _selectedItemsFromAll(
    List<UnifiedLibraryItem> allItems,
  ) {
    final itemsById = {for (final item in allItems) item.id: item};
    return _selectedIds
        .map((id) => itemsById[id])
        .whereType<UnifiedLibraryItem>()
        .toList(growable: false);
  }

  bool _isLocalOnlySelection(List<UnifiedLibraryItem> allItems) {
    final selectedItems = _selectedItemsFromAll(allItems);
    return selectedItems.isNotEmpty &&
        selectedItems.every((item) => item.localItem != null);
  }
}
