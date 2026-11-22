part of 'queue_tab.dart';

extension _QueueTabBatchActions on _QueueTabState {
  List<LocalLibraryItem> _selectedFlacEligibleLocalItems(
    List<UnifiedLibraryItem> allItems,
  ) {
    final selectedItems = _selectedItemsFromAll(allItems);
    return selectedItems
        .map((item) => item.localItem)
        .whereType<LocalLibraryItem>()
        .where(LocalTrackRedownloadService.isFlacUpgradeEligible)
        .toList(growable: false);
  }

  Future<void> _queueSelectedLocalAsFlac(List<UnifiedLibraryItem> allItems) =>
      queueLocalTracksAsFlac(
        context,
        ref,
        _selectedFlacEligibleLocalItems(allItems),
        isActive: () => mounted,
        onComplete: _exitSelectionMode,
      );

  Future<void> _reEnrichSelectedFromQueue(List<UnifiedLibraryItem> allItems) =>
      reEnrichLibraryTracks(
        context,
        ref,
        _selectedItemsFromAll(allItems),
        isActive: () => mounted,
        onSelectionHide: () async {
          _setState(() => _isSelectionMode = false);
          _hideSelectionOverlay();
        },
        onSelectionRestore: () => _setState(() => _isSelectionMode = true),
        onComplete: () {
          _onEmbeddedCoverChanged();
          _exitSelectionMode();
        },
      );

  Future<void> _showBatchConvertSheet(
    BuildContext context,
    List<UnifiedLibraryItem> allItems,
  ) {
    return showBatchConvertSheet(
      context,
      ref,
      _selectedItemsFromAll(allItems),
      onExitSelectionMode: _exitSelectionMode,
      onSheetOpen: () {
        _suppressSelectionOverlay = true;
        _hideSelectionOverlay();
        _hidePlaylistSelectionOverlay();
      },
      onSheetClosed: (didStartConversion) async {
        // Wait out the sheet's exit animation before restoring the toolbar so
        // it doesn't pop in front of the still-closing sheet.
        await Future<void>.delayed(const Duration(milliseconds: 260));
        if (!mounted) {
          _suppressSelectionOverlay = false;
          return;
        }
        _suppressSelectionOverlay = false;
        if (didStartConversion) return;
        final bottomPadding =
            this.context
                .getInheritedWidgetOfExactType<MediaQuery>()
                ?.data
                .padding
                .bottom ??
            0;
        if (_isSelectionMode) {
          _syncSelectionOverlay(items: allItems, bottomPadding: bottomPadding);
        } else if (_isPlaylistSelectionMode) {
          _syncPlaylistSelectionOverlay(
            playlists: ref.read(libraryCollectionsProvider).playlists,
            bottomPadding: bottomPadding,
          );
        }
      },
    );
  }

  Future<void> _runBatchReplayGain(
    List<UnifiedLibraryItem> allItems, {
    bool remove = false,
  }) {
    return runBatchReplayGain(
      context,
      _selectedItemsFromAll(allItems),
      onExitSelectionMode: _exitSelectionMode,
      remove: remove,
      onConfirmOpen: () {
        _suppressSelectionOverlay = true;
        _hideSelectionOverlay();
        _hidePlaylistSelectionOverlay();
      },
      onConfirmClosed: (confirmed) async {
        if (!mounted) {
          _suppressSelectionOverlay = false;
          return;
        }
        if (confirmed) {
          _suppressSelectionOverlay = false;
          return;
        }
        // Restore after the dialog's exit animation.
        await Future<void>.delayed(const Duration(milliseconds: 220));
        _suppressSelectionOverlay = false;
        if (!mounted) return;
        if (_isSelectionMode) {
          _syncSelectionOverlay(
            items: allItems,
            bottomPadding: MediaQuery.paddingOf(context).bottom,
          );
        }
      },
    );
  }
}
