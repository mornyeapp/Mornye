part of 'queue_tab.dart';

extension _QueueTabSelectionActions on _QueueTabState {
  void _selectDraggedTrack(
    UnifiedLibraryItem item,
    List<UnifiedLibraryItem> visibleItems,
  ) {
    // Holding an already-selected track drags the existing batch without
    // extending the range back to the selection anchor.
    if (_isSelectionMode && _selectedIds.contains(item.id)) return;
    if (_isSelectionMode) {
      _selectRangeTo(item.id, visibleItems);
    } else {
      _enterSelectionMode(item.id);
    }
  }

  void _startLibraryTrackDrag() {
    _setState(() => _isDraggingLibraryTrack = true);
    _hideSelectionOverlay();
  }

  void _endLibraryTrackDrag() {
    if (!mounted) return;
    _setState(() => _isDraggingLibraryTrack = false);
  }

  void _enterSelectionMode(String itemId) {
    HapticFeedback.mediumImpact();
    _setState(() {
      _isPlaylistSelectionMode = false;
      _selectedPlaylistIds.clear();
      _isSelectionMode = true;
      _selectedIds.add(itemId);
      _selectionAnchorId = itemId;
    });
    _hidePlaylistSelectionOverlay();
  }

  void _exitSelectionMode() {
    _setState(() {
      _isSelectionMode = false;
      _selectedIds.clear();
      _selectionAnchorId = null;
    });
    _hideSelectionOverlay();
  }

  void _toggleSelection(String itemId) {
    var shouldHideOverlay = false;
    _setState(() {
      _selectionAnchorId = toggleOrderedSelection(
        selected: _selectedIds,
        target: itemId,
      );
      if (_selectedIds.isEmpty) {
        _isSelectionMode = false;
        shouldHideOverlay = true;
      }
    });
    if (shouldHideOverlay) {
      _hideSelectionOverlay();
    }
  }

  void _selectAll(List<UnifiedLibraryItem> items) {
    _setState(() {
      _selectedIds.addAll(items.map((e) => e.id));
      _selectionAnchorId = items.lastOrNull?.id;
    });
  }

  /// A desktop click of [kind] on a library song; [orderedIds] lists the
  /// songs in the order shown.
  void _applyDesktopClick(
    String itemId,
    DesktopClick kind,
    List<String> orderedIds,
  ) {
    var shouldHideOverlay = false;
    _setState(() {
      _isPlaylistSelectionMode = false;
      _selectedPlaylistIds.clear();
      _selectionAnchorId = applyDesktopClickTo(
        _selectedIds,
        target: itemId,
        kind: kind,
        orderedIds: orderedIds,
        anchor: _selectionAnchorId,
      );
      _isSelectionMode = _selectedIds.isNotEmpty;
      shouldHideOverlay = !_isSelectionMode;
    });
    _hidePlaylistSelectionOverlay();
    if (shouldHideOverlay) _hideSelectionOverlay();
  }

  /// Opens the desktop menu of a library song. A song outside the selection
  /// becomes the selection for this menu only, so the menu acts on the song
  /// clicked: the selection toolbar does not open under the menu, and the
  /// selection ends if the menu closes without a choice.
  Future<void> _showLibraryItemMenu(
    BuildContext context,
    UnifiedLibraryItem item,
    List<UnifiedLibraryItem> libraryItems,
    Offset position, {
    VoidCallback? onOpenDetails,
  }) async {
    final forMenu = !_selectedIds.contains(item.id);
    if (forMenu) {
      _contextMenuSelection = true;
      _applyDesktopClick(item.id, DesktopClick.replace, const []);
      _hideSelectionOverlay();
    }
    final chosen = await showContextMenu(
      context,
      position: position,
      groups: libraryTrackMenuGroups(
        context,
        ref,
        items: _selectedItemsFromAll(libraryItems),
        onPlay: () => _playLibraryItem(item, libraryItems),
        onOpenDetails: onOpenDetails,
        onDone: _exitSelectionMode,
        onReEnrich: () => _reEnrichSelectedFromQueue(libraryItems),
        onConvert: () => _showBatchConvertSheet(this.context, libraryItems),
        onDelete: () => _deleteSelected(libraryItems),
      ),
    );
    if (!forMenu || !mounted) return;
    // A bulk action (re-enrich, convert, delete) kept the selection and
    // shows the toolbar again.
    _setState(() => _contextMenuSelection = false);
    if (!chosen) _exitSelectionMode();
  }

  void _selectRangeTo(String itemId, List<UnifiedLibraryItem> visibleItems) {
    HapticFeedback.selectionClick();
    _setState(() {
      _isSelectionMode = true;
      _selectionAnchorId = addOrderedSelectionRange(
        selected: _selectedIds,
        visibleItems: visibleItems
            .map((item) => item.id)
            .toList(growable: false),
        target: itemId,
        anchor: _selectionAnchorId,
      );
    });
  }

  void _hideSelectionOverlay() {
    _selectionOverlay.hide();
  }

  void _syncSelectionOverlay({
    required List<UnifiedLibraryItem> items,
    required double bottomPadding,
  }) {
    if (!mounted) return;
    if (_suppressSelectionOverlay ||
        _contextMenuSelection ||
        _isDraggingLibraryTrack ||
        !_isSelectionMode ||
        _isPlaylistSelectionMode) {
      _hideSelectionOverlay();
      return;
    }

    _selectionOverlayItems = items;
    _selectionOverlayBottomPadding = bottomPadding;
    _selectionOverlay.show(
      context,
      (_) => _buildSelectionBottomBar(
        context,
        Theme.of(context).colorScheme,
        _selectionOverlayItems,
        _selectionOverlayBottomPadding,
      ),
    );
  }

  void _hidePlaylistSelectionOverlay() {
    _playlistSelectionOverlay.hide();
  }

  void _syncPlaylistSelectionOverlay({
    required List<UserPlaylistCollection> playlists,
    required double bottomPadding,
  }) {
    if (!mounted) return;
    if (_suppressSelectionOverlay ||
        !_isPlaylistSelectionMode ||
        _isSelectionMode) {
      _hidePlaylistSelectionOverlay();
      return;
    }

    _playlistSelectionOverlayItems = playlists;
    _playlistSelectionOverlayBottomPadding = bottomPadding;
    _playlistSelectionOverlay.show(
      context,
      (_) => _buildPlaylistSelectionBottomBar(
        context,
        Theme.of(context).colorScheme,
        _playlistSelectionOverlayItems,
        _playlistSelectionOverlayBottomPadding,
      ),
    );
  }

  void _enterPlaylistSelectionMode(String playlistId) {
    HapticFeedback.mediumImpact();
    _setState(() {
      _isSelectionMode = false;
      _selectedIds.clear();
      _selectionAnchorId = null;
      _isPlaylistSelectionMode = true;
      _selectedPlaylistIds.add(playlistId);
    });
    _hideSelectionOverlay();
  }

  void _exitPlaylistSelectionMode() {
    _setState(() {
      _isPlaylistSelectionMode = false;
      _selectedPlaylistIds.clear();
    });
    _hidePlaylistSelectionOverlay();
  }

  void _togglePlaylistSelection(String playlistId) {
    var shouldHideOverlay = false;
    _setState(() {
      if (_selectedPlaylistIds.contains(playlistId)) {
        _selectedPlaylistIds.remove(playlistId);
        if (_selectedPlaylistIds.isEmpty) {
          _isPlaylistSelectionMode = false;
          shouldHideOverlay = true;
        }
      } else {
        _selectedPlaylistIds.add(playlistId);
      }
    });
    if (shouldHideOverlay) {
      _hidePlaylistSelectionOverlay();
    }
  }

  void _selectAllPlaylists(List<UserPlaylistCollection> playlists) {
    _setState(() {
      _selectedPlaylistIds.addAll(playlists.map((e) => e.id));
    });
  }

  Future<void> _downloadAllSelectedPlaylists(BuildContext context) async {
    final collectionsState = ref.read(libraryCollectionsProvider);
    var selectedPlaylists = collectionsState.playlists
        .where((p) => _selectedPlaylistIds.contains(p.id))
        .toList();

    final totalTracks = selectedPlaylists.fold<int>(
      0,
      (sum, p) => sum + p.trackCount,
    );

    if (totalTracks == 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.l10n.snackbarSelectedPlaylistsEmpty)),
      );
      return;
    }

    final confirmed = await showAppConfirmDialog(
      context,
      title: context.l10n.dialogDownloadAllTitle,
      message: context.l10n.dialogDownloadPlaylistsMessage(
        totalTracks,
        selectedPlaylists.length,
      ),
      confirmLabel: context.l10n.dialogDownload,
    );

    if (!confirmed || !context.mounted) return;

    await ref
        .read(libraryCollectionsProvider.notifier)
        .ensurePlaylistsLoaded(
          selectedPlaylists.map((playlist) => playlist.id),
        );
    if (!context.mounted) return;
    selectedPlaylists = ref
        .read(libraryCollectionsProvider)
        .playlists
        .where((playlist) => _selectedPlaylistIds.contains(playlist.id))
        .toList(growable: false);

    final settings = ref.read(settingsProvider);
    final extensionState = ref.read(extensionProvider);
    final queueNotifier = ref.read(downloadQueueProvider.notifier);

    void enqueueAll({String? qualityOverride, String? service}) {
      final svc =
          service ??
          resolveEffectiveDownloadService(
            settings.defaultService,
            extensionState,
          );
      if (svc.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(context.l10n.extensionsNoDownloadProvider)),
          );
        }
        return;
      }
      queueNotifier.addBatchesToQueue(
        [
          for (final playlist in selectedPlaylists)
            DownloadQueueBatch(
              tracks: playlist.tracks.map((entry) => entry.track).toList(),
              playlistName: playlist.name,
            ),
        ],
        svc,
        qualityOverride: qualityOverride,
      );
    }

    if (settings.askQualityBeforeDownload || settings.allowQualityVariants) {
      DownloadServicePicker.show(
        context,
        trackName: context.l10n.tracksCount(totalTracks),
        artistName: context.l10n.playlistsCount(selectedPlaylists.length),
        onSelect: (quality, service) {
          enqueueAll(qualityOverride: quality, service: service);
          if (!mounted) return;
          _exitPlaylistSelectionMode();
          showAppSnackBar(
            context,
            content: Text(context.l10n.snackbarAddedTracksToQueue(totalTracks)),
          );
        },
      );
    } else {
      enqueueAll();
      _exitPlaylistSelectionMode();
      showAppSnackBar(
        context,
        content: Text(context.l10n.snackbarAddedTracksToQueue(totalTracks)),
      );
    }
  }

  Future<void> _deleteSelectedPlaylists(BuildContext context) async {
    final count = _selectedPlaylistIds.length;
    final confirmed = await showAppConfirmDialog(
      context,
      title: context.l10n.collectionDeletePlaylist,
      message: context.l10n.collectionDeletePlaylistsMessage(count),
      confirmLabel: context.l10n.dialogDelete,
      destructive: true,
      cancelIsDefault: true,
      confirmStyle: FilledButton.styleFrom(
        backgroundColor: Theme.of(context).colorScheme.error,
      ),
    );

    if (!confirmed || !context.mounted) return;

    final notifier = ref.read(libraryCollectionsProvider.notifier);
    await notifier.deletePlaylists(_selectedPlaylistIds);

    if (!context.mounted) return;
    _exitPlaylistSelectionMode();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(context.l10n.collectionPlaylistsDeleted(count))),
    );
  }

  Widget _buildPlaylistSelectionBottomBar(
    BuildContext context,
    ColorScheme colorScheme,
    List<UserPlaylistCollection> playlists,
    double bottomPadding,
  ) {
    final selectedCount = _selectedPlaylistIds.length;
    final allSelected =
        selectedCount == playlists.length && playlists.isNotEmpty;

    return SelectionBottomBar(
      selectedCount: selectedCount,
      allSelected: allSelected,
      onClose: _exitPlaylistSelectionMode,
      onToggleSelectAll: () {
        if (allSelected) {
          _exitPlaylistSelectionMode();
        } else {
          _selectAllPlaylists(playlists);
        }
      },
      bottomPadding: bottomPadding,
      allSelectedLabel: context.l10n.selectionAllPlaylistsSelected,
      tapToSelectLabel: context.l10n.selectionTapPlaylistsToSelect,
      children: [
        SizedBox(
          width: double.infinity,
          child: ExpressiveButton(
            onPressed: selectedCount > 0
                ? () => _downloadAllSelectedPlaylists(context)
                : null,
            icon: const Icon(Icons.download_rounded),
            style: FilledButton.styleFrom(
              backgroundColor: selectedCount > 0
                  ? colorScheme.primary
                  : colorScheme.surfaceContainerHighest,
              foregroundColor: selectedCount > 0
                  ? colorScheme.onPrimary
                  : colorScheme.onSurfaceVariant,
              padding: EdgeInsets.symmetric(
                vertical: isDesktopPlatform ? 8 : 16,
              ),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
            ),
            child: Text(
              selectedCount > 0
                  ? context.l10n.bulkDownloadPlaylistsButton(selectedCount)
                  : context.l10n.bulkDownloadSelectPlaylists,
            ),
          ),
        ),

        const SizedBox(height: 8),

        SizedBox(
          width: double.infinity,
          child: ExpressiveButton(
            onPressed: selectedCount > 0
                ? () => _deleteSelectedPlaylists(context)
                : null,
            icon: const Icon(Icons.delete_outline),
            style: FilledButton.styleFrom(
              backgroundColor: selectedCount > 0
                  ? colorScheme.error
                  : colorScheme.surfaceContainerHighest,
              foregroundColor: selectedCount > 0
                  ? colorScheme.onError
                  : colorScheme.onSurfaceVariant,
              padding: EdgeInsets.symmetric(
                vertical: isDesktopPlatform ? 8 : 16,
              ),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
            ),
            child: Text(
              selectedCount > 0
                  ? context.l10n.selectionDeletePlaylistsCount(selectedCount)
                  : context.l10n.selectionSelectPlaylistsToDelete,
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _deleteSelected(List<UnifiedLibraryItem> allItems) =>
      deleteLibraryTracks(
        context,
        ref,
        _selectedItemsFromAll(allItems),
        isActive: () => mounted,
        onComplete: _exitSelectionMode,
      );

  String _cleanFilePath(String? filePath) {
    return DownloadedEmbeddedCoverResolver.cleanFilePath(filePath);
  }

  Future<int?> _readFileModTimeMillis(String? filePath) async {
    return DownloadedEmbeddedCoverResolver.readFileModTimeMillis(filePath);
  }
}
