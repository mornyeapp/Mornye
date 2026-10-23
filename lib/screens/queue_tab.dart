import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart' show ValueListenable, clampDouble;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart'
    show BoxHitTestResult, BoxParentData, RenderShiftedBox;
import 'package:mornye/widgets/app_alert_dialog.dart';
import 'package:mornye/widgets/app_choice_chip.dart';
import 'package:mornye/widgets/app_content_card.dart';
import 'package:mornye/services/local_track_batch_actions.dart';
import 'package:mornye/services/shell_navigation_service.dart';
import 'package:mornye/widgets/error_card.dart';
import 'package:mornye/widgets/settings_group.dart';
import 'package:mornye/widgets/swipe_delete_dismissible.dart';
import 'package:mornye/widgets/track_card.dart';
import 'package:mornye/theme/app_motion.dart';
import 'package:mornye/theme/app_tokens.dart';
import 'package:mornye/theme/material_expressive.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/widgets/app_bottom_sheet.dart';
import 'package:mornye/widgets/app_icon.dart';
import 'package:mornye/widgets/pinned_section_sliver_list.dart';
import 'package:mornye/widgets/app_icon_button.dart';
import 'package:mornye/widgets/app_loading_indicator.dart';
import 'package:mornye/widgets/app_progress_indicator.dart';
import 'package:mornye/widgets/app_sliver_header.dart';
import 'package:mornye/widgets/expressive_button.dart';
import 'package:mornye/widgets/app_search_field.dart';
import 'package:mornye/widgets/app_snack_bar.dart';
import 'package:mornye/widgets/library_search_results.dart';
import 'package:mornye/widgets/library_track_selection_bar.dart';
import 'package:mornye/widgets/library_selection_playback_actions.dart';
import 'package:mornye/widgets/local_library_artwork_builder.dart';
import 'package:mornye/widgets/library_playlist_drag_source.dart';
import 'package:mornye/widgets/playlist_picker_sheet.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart' show DateFormat;
import 'package:material_3_expressive/material_3_expressive.dart'
    show
        M3EButtonGroup,
        M3EButtonGroupAction,
        M3EButtonGroupType,
        M3EButtonSize,
        M3EButtonStyle;
import 'package:mornye/providers/library_browse_provider.dart';
import 'package:mornye/services/platform_bridge.dart';
import 'package:mornye/widgets/app_shape.dart';
import 'package:mornye/widgets/library_fast_scroller.dart';
import 'package:mornye/widgets/player_artwork.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/utils/adaptive_layout.dart';
import 'package:mornye/utils/audio_quality_badge_policy.dart';
import 'package:mornye/utils/nav_bar_inset.dart';
import 'package:mornye/utils/file_access.dart';
import 'package:mornye/utils/library_format_filters.dart';
import 'package:mornye/utils/ordered_range_selection.dart';
import 'package:mornye/utils/saf_download_tree.dart';
import 'package:mornye/models/download_item.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/models/unified_library_item.dart';
import 'package:mornye/providers/download_queue_provider.dart';
import 'package:mornye/providers/extension_provider.dart';
import 'package:mornye/providers/library_collections_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/providers/local_library_provider.dart';
import 'package:mornye/providers/playback_provider.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/services/music_player_service.dart';
import 'package:mornye/services/library_database.dart';
import 'package:mornye/services/album_completeness.dart';
import 'package:mornye/services/local_track_redownload_service.dart';
import 'package:mornye/services/batch_track_actions.dart';
import 'package:mornye/services/downloaded_embedded_cover_resolver.dart';
import 'package:mornye/screens/track_metadata_screen.dart';
import 'package:mornye/screens/listening_rewind_screen.dart';
import 'package:mornye/screens/favorite_artists_screen.dart';
import 'package:mornye/screens/downloaded_album_screen.dart';
import 'package:mornye/widgets/cached_cover_image.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:mornye/services/cover_cache_manager.dart';
import 'package:mornye/screens/library_tracks_folder_screen.dart';
import 'package:mornye/screens/local_album_screen.dart';
import 'package:mornye/screens/mornye_library_screen.dart';
import 'package:mornye/controllers/completion_bridge_tracker.dart';
import 'package:mornye/controllers/queue_library_pager.dart';
import 'package:mornye/controllers/queue_library_refresh_policy.dart';
import 'package:mornye/utils/clickable_metadata.dart';
import 'package:mornye/utils/string_utils.dart';
import 'package:mornye/widgets/download_service_picker.dart';
import 'package:mornye/widgets/animated_library_sliver_grid.dart';
import 'package:mornye/widgets/animation_utils.dart';
import 'package:mornye/widgets/selection_bottom_bar.dart';
import 'package:mornye/widgets/smoothed_progress.dart';
import 'package:mornye/widgets/two_finger_pinch_listener.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:mornye/widgets/desktop/context_menu.dart';
import 'package:mornye/widgets/desktop/desktop_selection.dart';
import 'package:mornye/widgets/desktop/hover_play_button.dart';
import 'package:mornye/widgets/desktop/library_track_menu.dart';
import 'package:mornye/widgets/desktop/track_table.dart';

part 'queue_tab_helpers.dart';
part 'queue_tab_widgets.dart';
part 'queue_tab_selection.dart';
part 'queue_tab_navigation.dart';
part 'queue_tab_collection_items.dart';
part 'queue_tab_filter_widgets.dart';
part 'queue_tab_sections.dart';
part 'queue_tab_batch_actions.dart';
part 'queue_tab_item_widgets.dart';
part 'queue_tab_download_labels.dart';
part 'queue_tab_download_dialogs.dart';
part 'queue_tab_filter_sheet.dart';

const _historyItemForCompletionBridge = CompletionBridgeTracker.historyItemFor;

class QueueTab extends ConsumerStatefulWidget {
  final String? librarySection;
  final bool isTabActive;

  const QueueTab({super.key, this.librarySection, this.isTabActive = true});

  @override
  ConsumerState<QueueTab> createState() => _QueueTabState();
}

class _QueueTabState extends ConsumerState<QueueTab> {
  static const int _libraryPageSize = 300;
  final LibraryFileAvailabilityCache _fileExistsCache =
      LibraryFileAvailabilityCache();
  late final CompletionBridgePlayableProbeCache _completionBridgePlayableProbe;
  // Desktop windows are much wider than a phone, so covers start larger
  // there; pinching (or a trackpad pinch) resizes within the range.
  static double get _libraryGridMinExtent => isDesktopPlatform ? 140 : 92;
  static double get _libraryGridDefaultExtent => isDesktopPlatform ? 180 : 126;
  static double get _libraryGridMaxExtent => isDesktopPlatform ? 260 : 190;
  bool _embeddedCoverRefreshScheduled = false;
  // Version counter to trigger targeted cover image rebuilds
  // without rebuilding the entire widget tree via setState.
  final ValueNotifier<int> _embeddedCoverVersion = ValueNotifier<int>(0);

  bool _isSelectionMode = false;
  bool _isDraggingLibraryTrack = false;
  final Set<String> _selectedIds = {};
  String? _selectionAnchorId;
  final SelectionOverlayController _selectionOverlay =
      SelectionOverlayController();
  List<UnifiedLibraryItem> _selectionOverlayItems = const [];
  double _selectionOverlayBottomPadding = 0;

  /// Keeps the selection overlays hidden while a modal launched from the
  /// selection toolbar is open, so they don't reappear over its animation.
  bool _suppressSelectionOverlay = false;

  /// A right-click selected a song for its menu only. The selection toolbar
  /// stays hidden until the menu and its chosen action have run.
  bool _contextMenuSelection = false;

  bool _isPlaylistSelectionMode = false;
  final Set<String> _selectedPlaylistIds = {};
  final SelectionOverlayController _playlistSelectionOverlay =
      SelectionOverlayController();
  List<UserPlaylistCollection> _playlistSelectionOverlayItems = const [];
  double _playlistSelectionOverlayBottomPadding = 0;

  PageController? _filterPageController;

  /// Pages of the Library pager: Songs, Albums, Artists and Playlists.
  /// Singles share the Albums page behind [_albumsShowSingles].
  final List<String> _filterModes = ['all', 'albums', 'artists', 'playlists'];
  bool _albumsShowSingles = false;

  int _pageIndexFor(String mode) =>
      _filterModes.indexOf(mode == 'singles' ? 'albums' : mode);

  /// Data mode of the page at [index], resolving Albums to Singles when the
  /// Albums page shows singles.
  String _modeForPage(int index) {
    final mode = _filterModes[index];
    return mode == 'albums' && _albumsShowSingles ? 'singles' : mode;
  }

  bool _isPageControllerInitialized = false;
  bool _wasTabVisible = false;
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();
  String _searchQuery = '';
  Timer? _searchDebounce;
  final CompletionBridgeTracker _completionBridgeTracker =
      CompletionBridgeTracker();
  Map<String, DownloadItem> get _completionBridge =>
      _completionBridgeTracker.items;
  Map<String, DateTime> get _completionBridgeAt =>
      _completionBridgeTracker.addedAt;
  Set<String> get _bridgePrecacheStarted =>
      _completionBridgeTracker.precacheStarted;
  String? _filterSource;
  String? _filterQuality;
  String? _filterFormat;
  String? _filterMetadata;
  String _sortMode = 'latest';
  String _libraryQualityLabelMode = AppSettings.libraryQualityLabelBitDepthOnly;
  final _libraryGridExtent = ValueNotifier(_libraryGridDefaultExtent);
  double? _libraryGridPinchStartExtent;
  List<UnifiedLibraryItem>? _sectionItems;
  String? _sectionSort;
  String? _sectionLocale;
  List<_LibrarySection> _cachedTrackSections = const [];

  /// In-memory History snapshots and counts, regrouped only when the
  /// (immutable) History list changes.
  List<DownloadHistoryItem>? _snapshotHistory;
  final Map<(String, int), _QueueLibraryPageData> _historySnapshots = {};
  final Map<int, QueueLibraryCounts> _historySnapshotCountsByTotal = {};

  /// Filter data per mode with the page, collections and totals it came
  /// from, so an unchanged page keeps its filtered rows across rebuilds.
  final Map<
    String,
    (
      _QueueLibraryPageData,
      LibraryCollectionsState,
      int?,
      int?,
      _FilterContentData,
    )
  >
  _filterDataByMode = {};

  final QueueLibraryPager<
    _QueueLibraryCountsRequest,
    _QueueLibraryPageRequest,
    _QueueLibraryPageData
  >
  _pager = QueueLibraryPager(
    pageSize: _libraryPageSize,
    combinePages: _QueueLibraryPageData.combine,
  );

  double _queueCoverSize() {
    final shortestSide = MediaQuery.sizeOf(context).shortestSide;
    final scale = (shortestSide / 390).clamp(0.82, 1.0);
    final textScale = effectiveTextScale(context);
    return (56 * scale * (1 + ((textScale - 1) * 0.12))).clamp(46.0, 56.0);
  }

  /// setState is @protected, so the extension part files route rebuilds
  /// through this forwarder.
  void _setState(VoidCallback fn) => setState(fn);

  void _handleLibraryGridPinchStart() {
    _libraryGridPinchStartExtent = _libraryGridExtent.value;
  }

  void _handleLibraryGridPinchUpdate(double scale) {
    final startExtent = _libraryGridPinchStartExtent;
    if (startExtent == null) return;

    final nextExtent = (startExtent * scale).clamp(
      _libraryGridMinExtent,
      _libraryGridMaxExtent,
    );
    if ((nextExtent - _libraryGridExtent.value).abs() < 0.5) return;
    _libraryGridExtent.value = nextExtent;
  }

  void _handleLibraryGridPinchEnd() {
    _libraryGridPinchStartExtent = null;
  }

  @override
  void initState() {
    super.initState();
    _completionBridgePlayableProbe = CompletionBridgePlayableProbeCache(
      onPlayable: _fileExistsCache.markExists,
    );
  }

  void _initializePageController() {
    if (_isPageControllerInitialized) return;
    _isPageControllerInitialized = true;
    final settings = ref.read(settingsProvider);
    final initialFilter =
        widget.librarySection ??
        (settings.defaultLibraryView == 'last'
            ? settings.historyFilterMode
            : settings.defaultLibraryView);
    final initialPage = _pageIndexFor(
      initialFilter,
    ).clamp(0, _filterModes.length - 1);
    _albumsShowSingles = initialFilter == 'singles';
    final initialMode = _modeForPage(initialPage);
    if (widget.librarySection == null &&
        settings.historyFilterMode != initialMode) {
      Future.microtask(() {
        if (!mounted) return;
        ref.read(settingsProvider.notifier).setHistoryFilterMode(initialMode);
      });
    }
    _filterPageController = PageController(initialPage: initialPage);
  }

  /// When the shell switches back to this tab and a fixed default view is
  /// configured, jump the filter pager to it.
  void _applyDefaultLibraryViewOnTabVisible() {
    if (widget.librarySection != null) return;
    // Route transitions also disable TickerMode. Only a shell tab change
    // should reset the user's current album/single view.
    final isVisible = widget.isTabActive;
    final becameVisible = isVisible && !_wasTabVisible;
    _wasTabVisible = isVisible;
    if (!becameVisible) return;
    final defaultView = ref.read(settingsProvider).defaultLibraryView;
    if (defaultView == 'last') return;
    final index = _pageIndexFor(defaultView);
    if (index < 0) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_filterModes[index] == 'albums') {
        _setState(() => _albumsShowSingles = defaultView == 'singles');
      }
      if (ref.read(settingsProvider).historyFilterMode != defaultView) {
        ref.read(settingsProvider.notifier).setHistoryFilterMode(defaultView);
      }
      final controller = _filterPageController;
      if (controller != null &&
          controller.hasClients &&
          controller.page?.round() != index) {
        controller.jumpToPage(index);
      }
    });
  }

  @override
  void dispose() {
    _hideSelectionOverlay();
    _hidePlaylistSelectionOverlay();
    _fileExistsCache.dispose();
    _completionBridgePlayableProbe.dispose();
    _embeddedCoverVersion.dispose();
    _libraryGridExtent.dispose();
    _filterPageController?.dispose();
    _searchController.dispose();
    _searchFocusNode.dispose();
    _searchDebounce?.cancel();
    super.dispose();
  }

  void _onSearchChanged(String value) {
    _searchDebounce?.cancel();
    final normalized = value.trim().toLowerCase();
    _searchDebounce = Timer(const Duration(milliseconds: 350), () {
      if (!mounted || _searchQuery == normalized) return;
      setState(() {
        _searchQuery = normalized;
        _resetLibraryPaging();
      });
    });
  }

  void _clearSearch() {
    _searchDebounce?.cancel();
    if (_searchQuery.isEmpty) return;
    setState(() {
      _searchQuery = '';
      _resetLibraryPaging();
    });
  }

  void _resetLibraryPaging() => _pager.resetPaging();

  void _scheduleBlankLibraryRepair({
    required bool hasQueueItems,
    required bool hasLibraryContent,
    required bool hasAnyLibraryItems,
    required bool isLibraryPageLoading,
  }) {
    _pager.scheduleBlankLibraryRepair(
      hasQueueItems: hasQueueItems,
      hasLibraryContent: hasLibraryContent,
      hasAnyLibraryItems: hasAnyLibraryItems,
      isLibraryPageLoading: isLibraryPageLoading,
      isMounted: () => mounted,
      repair: () {
        ref.read(downloadHistoryProvider.notifier).reloadFromStorage();
        if (ref.read(settingsProvider).localLibraryEnabled) {
          ref.read(localLibraryProvider.notifier).reloadFromStorage();
        }
        setState(() {});
      },
    );
  }

  bool _handleLibraryScrollNotification({
    required ScrollNotification notification,
    required String filterMode,
    required bool hasMoreLibrary,
    required bool isPageLoading,
  }) {
    return _pager.handleScrollNotification(
      notification: notification,
      filterMode: filterMode,
      hasMoreLibrary: hasMoreLibrary,
      isPageLoading: isPageLoading,
      setState: setState,
    );
  }

  void _onFilterPageChanged(int index) {
    if (widget.librarySection != null) return;
    if (_modeForPage(index) == 'playlists' && _sortMode.startsWith('size-')) {
      setState(() => _sortMode = 'latest');
    }
    HapticFeedback.selectionClick();
    ref
        .read(settingsProvider.notifier)
        .setHistoryFilterMode(_modeForPage(index));
  }

  void _animateToFilterPage(int index) {
    if (index >= 0 && index < _filterModes.length) {
      final filterMode = _modeForPage(index);
      if (ref.read(settingsProvider).historyFilterMode != filterMode) {
        ref.read(settingsProvider.notifier).setHistoryFilterMode(filterMode);
      }
    }
    final motion = AppMotion.spatialSlow(
      context,
      const AppMotionSpec(Duration(milliseconds: 300), Curves.easeOutCubic),
    );
    _filterPageController?.animateToPage(
      index,
      duration: motion.duration,
      curve: motion.curve,
    );
  }

  void _setAlbumsShowSingles(bool singles) {
    if (_albumsShowSingles == singles) return;
    HapticFeedback.selectionClick();
    setState(() => _albumsShowSingles = singles);
    ref
        .read(settingsProvider.notifier)
        .setHistoryFilterMode(singles ? 'singles' : 'albums');
  }

  void _onEmbeddedCoverChanged() {
    if (!mounted || _embeddedCoverRefreshScheduled) return;
    _embeddedCoverRefreshScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _embeddedCoverRefreshScheduled = false;
      if (mounted) {
        _embeddedCoverVersion.value++;
      }
    });
  }

  Future<void> _scheduleDownloadedEmbeddedCoverRefreshForPath(
    String? filePath, {
    int? beforeModTime,
    bool force = false,
  }) async {
    await DownloadedEmbeddedCoverResolver.scheduleRefreshForPath(
      filePath,
      beforeModTime: beforeModTime,
      force: force,
      onChanged: _onEmbeddedCoverChanged,
    );
  }

  String? _resolveDownloadedEmbeddedCoverPath(String? filePath) {
    return DownloadedEmbeddedCoverResolver.resolve(
      filePath,
      onChanged: _onEmbeddedCoverChanged,
    );
  }

  ValueListenable<bool> _fileExistsListenable(String? filePath) {
    return _fileExistsCache.listenable(filePath);
  }

  void _refreshCompletionBridgePath(String? filePath) {
    _fileExistsCache.refreshForPath(filePath);
    _completionBridgePlayableProbe.refreshForPath(filePath);
  }

  int get _activeFilterCount {
    int count = 0;
    if (_filterSource != null) count++;
    if (_filterQuality != null) count++;
    if (_filterFormat != null) count++;
    if (_filterMetadata != null) count++;
    return count;
  }

  void _resetFilters() {
    setState(() {
      _filterSource = null;
      _filterQuality = null;
      _filterFormat = null;
      _filterMetadata = null;
      _sortMode = 'latest';
      _resetLibraryPaging();
    });
  }

  @override
  Widget build(BuildContext context) {
    if (context.isMornye && widget.librarySection == null) {
      return MornyeLibraryScreen(
        onOpenSection: (section) => Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => Scaffold(body: QueueTab(librarySection: section)),
          ),
        ),
      );
    }
    _initializePageController();
    _applyDefaultLibraryViewOnTabVisible();
    final localLibraryEnabled = ref.watch(
      settingsProvider.select((s) => s.localLibraryEnabled),
    );

    ref.listen(downloadQueueLookupProvider, (previous, next) {
      _completionBridgeTracker.onQueueLookupChanged(
        previous,
        next,
        setState: setState,
        refreshPath: _refreshCompletionBridgePath,
      );
    });
    ref.listen<int>(
      downloadHistoryProvider.select((state) => state.loadedIndexVersion),
      (previous, next) {
        if (previous == null || previous == next) return;
        final historyItems = ref.read(downloadHistoryProvider).items;
        _completionBridgeTracker.refreshPaths(
          historyItems,
          refreshPath: _refreshCompletionBridgePath,
        );
        // The family provider already reruns for the new revision. Retain its
        // last successful page while SQLite is loading so metadata backfills
        // and download completions cannot flash the Library as empty.
        _pager.resetOffsets();
        if (mounted) setState(() {});
      },
    );
    if (localLibraryEnabled) {
      ref.listen<int>(
        localLibraryProvider.select((state) => state.loadedIndexVersion),
        (previous, next) {
          if (previous == null || previous == next) return;
          // Keep stale rows visible until the refreshed query replaces them.
          _pager.resetOffsets();
          if (mounted) setState(() {});
        },
      );
    }

    if (widget.librarySection == 'downloads') {
      final ids = ref.watch(
        downloadQueueLookupProvider.select((s) => s.notCompletedItemIds),
      );
      final colors = Theme.of(context).colorScheme;
      return CustomScrollView(
        slivers: [
          AppSliverHeader.page(title: context.l10n.libraryDownloads),
          _buildQueueHeaderSliver(context, colors),
          // The rows share the header's centered column on wide windows.
          SliverPadding(
            padding: EdgeInsets.symmetric(horizontal: wideListInset(context)),
            sliver: SliverList.builder(
              itemCount: ids.length,
              itemBuilder: (context, index) => TrackCardSegment.at(
                key: ValueKey(ids[index]),
                index: index,
                count: ids.length,
                child: _QueueItemSliverRow(
                  itemId: ids[index],
                  colorScheme: colors,
                  itemBuilder: _buildQueueItem,
                ),
              ),
            ),
          ),
          if (ids.isEmpty)
            SliverFillRemaining(
              hasScrollBody: false,
              child: Center(child: Text(context.l10n.libraryNoActiveDownloads)),
            ),
          const NavBarSliverSpacer(),
        ],
      );
    }

    final hasQueueItems = ref.watch(
      downloadQueueLookupProvider.select((lookup) => lookup.itemIds.isNotEmpty),
    );
    final historyTotalCount = ref.watch(
      downloadHistoryProvider.select((state) => state.totalCount),
    );
    // Completion-bridge cells need the finalized in-memory history record
    // immediately, before the database-backed Library page refresh lands.
    final inMemoryHistoryItems = ref.watch(
      downloadHistoryProvider.select((state) => state.items),
    );
    final localLibraryTotalCount = localLibraryEnabled
        ? ref.watch(localLibraryProvider.select((state) => state.totalCount))
        : 0;
    // Watch with selector on key fields to reduce unnecessary rebuilds.
    // LibraryCollectionsState doesn't implement == so watching without
    // selector rebuilds on every provider notification.
    ref.watch(
      libraryCollectionsProvider.select(
        (s) => (
          s.wishlistCount,
          s.lovedCount,
          s.favoriteArtistCount,
          s.playlistCount,
          s.hasPlaylistTracks,
          s.isLoaded,
        ),
      ),
    );
    final collectionState = ref.read(libraryCollectionsProvider);
    final historyViewMode = ref.watch(
      settingsProvider.select((s) => s.historyViewMode),
    );
    final String historyFilterMode =
        widget.librarySection ??
        ref.watch<String>(settingsProvider.select((s) => s.historyFilterMode));
    // Keep this mode out of the page-provider request: changing only badge
    // text must not re-query the database or reset Library pagination.
    _libraryQualityLabelMode = ref.watch(
      settingsProvider.select((s) => s.libraryQualityLabelMode),
    );
    final colorScheme = Theme.of(context).colorScheme;
    final countsRequest = _QueueLibraryCountsRequest(
      searchQuery: _searchQuery,
      filterSource: _filterSource,
      filterQuality: _filterQuality,
      filterFormat: _filterFormat,
      filterMetadata: _filterMetadata,
      localLibraryEnabled: localLibraryEnabled,
    );
    final searchingLibrary =
        _searchQuery.isNotEmpty &&
        !isAlbumCompletenessFilter(_filterMetadata) &&
        !_isSelectionMode &&
        !_isPlaylistSelectionMode;
    final countsValue = searchingLibrary
        ? const AsyncData(
            QueueLibraryCounts(
              allTrackCount: 0,
              albumCount: 0,
              singleTrackCount: 0,
            ),
          )
        : ref.watch(_queueLibraryCountsProvider(countsRequest));
    if (!identical(_snapshotHistory, inMemoryHistoryItems)) {
      _snapshotHistory = inMemoryHistoryItems;
      _historySnapshots.clear();
      _historySnapshotCountsByTotal.clear();
    }
    final historySnapshotFallbackEnabled =
        hasQueueItems &&
        inMemoryHistoryItems.isNotEmpty &&
        countsRequest.allowsInMemoryHistoryFallback;
    final historySnapshotCounts = historySnapshotFallbackEnabled
        ? _historySnapshotCountsByTotal.putIfAbsent(
            historyTotalCount,
            () => _historySnapshotCounts(
              inMemoryHistoryItems,
              persistedTotalCount: historyTotalCount,
            ),
          )
        : null;
    final queueCounts = _pager.resolveCounts(
      countsValue,
      countsRequest,
      nonEmptyFallback: historySnapshotCounts,
    );

    _QueueLibraryPageRequest pageRequest(String filterMode) {
      final offset = _pager.pageOffsetFor(filterMode);
      final baseRequest = _QueueLibraryPageRequest(
        filterMode: filterMode,
        limit: _libraryPageSize,
        offset: offset,
        searchQuery: _searchQuery,
        filterSource: _filterSource,
        filterQuality: _filterQuality,
        filterFormat: _filterFormat,
        filterMetadata: _filterMetadata,
        sortMode: _sortMode,
        localLibraryEnabled: localLibraryEnabled,
      );
      if (offset == 0) return baseRequest;
      final previousPage = _pager.cachedPageAt(
        baseRequest,
        offset - _libraryPageSize,
      );
      return _QueueLibraryPageRequest(
        filterMode: baseRequest.filterMode,
        limit: baseRequest.limit,
        offset: baseRequest.offset,
        searchQuery: baseRequest.searchQuery,
        filterSource: baseRequest.filterSource,
        filterQuality: baseRequest.filterQuality,
        filterFormat: baseRequest.filterFormat,
        filterMetadata: baseRequest.filterMetadata,
        sortMode: baseRequest.sortMode,
        localLibraryEnabled: baseRequest.localLibraryEnabled,
        cursor: previousPage?.nextCursor,
      );
    }

    final activePageRequest = pageRequest(historyFilterMode);
    // The Artists page browses its own query.
    final activePageValue = searchingLibrary || historyFilterMode == 'artists'
        ? const AsyncData(_QueueLibraryPageData())
        : ref.watch(_queueLibraryPageProvider(activePageRequest));

    // The in-memory snapshot regroups every history item. It is only needed
    // when a page is still empty, so build it on demand and at most once per
    // mode for the (immutable) history list. Each mode resolves once per
    // build; the page view and the selection overlay share the result.
    final pageDataByMode = <String, _QueueLibraryPageData>{};
    _QueueLibraryPageData pageData(String filterMode) =>
        pageDataByMode.putIfAbsent(filterMode, () {
          final request = filterMode == historyFilterMode
              ? activePageRequest
              : pageRequest(filterMode);
          final historySnapshotAvailable =
              hasQueueItems &&
              inMemoryHistoryItems.isNotEmpty &&
              request.allowsInMemoryHistoryFallback;
          return _pager.resolvePageData(
            filterMode == historyFilterMode ? activePageValue : null,
            request,
            nonEmptyFallback: historySnapshotAvailable
                ? () => _historySnapshots.putIfAbsent(
                    (request.filterMode, request.limit),
                    () => _QueueLibraryPageData.fromHistorySnapshot(
                      inMemoryHistoryItems,
                      filterMode: request.filterMode,
                      limit: request.limit,
                    ),
                  )
                : null,
          );
        });

    _FilterContentData getFilterData(String filterMode) {
      final page = pageData(filterMode);
      final totalTrackCount = switch (filterMode) {
        'singles' => queueCounts.singleTrackCount,
        'albums' || 'playlists' => 0,
        _ => queueCounts.allTrackCount,
      };
      final totalAlbumCount = filterMode == 'albums'
          ? queueCounts.albumCount
          : null;
      final cached = _filterDataByMode[filterMode];
      if (cached != null &&
          identical(cached.$1, page) &&
          identical(cached.$2, collectionState) &&
          cached.$3 == totalTrackCount &&
          cached.$4 == totalAlbumCount) {
        return cached.$5;
      }
      final data = page.toFilterContentData(
        collectionState,
        totalTrackCount: totalTrackCount,
        totalAlbumCount: totalAlbumCount,
      );
      _filterDataByMode[filterMode] = (
        page,
        collectionState,
        totalTrackCount,
        totalAlbumCount,
        data,
      );
      return data;
    }

    final currentPageData = pageData(historyFilterMode);
    final currentLoadedCount = historyFilterMode == 'albums'
        ? currentPageData.groupedAlbums.length +
              currentPageData.groupedLocalAlbums.length
        : currentPageData.items.length;
    final currentTotalCount = switch (historyFilterMode) {
      'albums' => queueCounts.albumCount,
      'singles' => queueCounts.singleTrackCount,
      'playlists' || 'artists' => 0,
      _ => queueCounts.allTrackCount,
    };
    final hasMoreLibrary = currentLoadedCount < currentTotalCount;
    final isLibraryPageLoading =
        countsValue.isLoading || activePageValue.isLoading;
    final hasAnyLibraryItems =
        queueCounts.allTrackCount > 0 || queueCounts.albumCount > 0;
    final hasLibraryContent =
        historyTotalCount > 0 ||
        inMemoryHistoryItems.isNotEmpty ||
        (localLibraryEnabled && localLibraryTotalCount > 0);
    final hasActiveSearch =
        _searchQuery.isNotEmpty || _searchController.text.trim().isNotEmpty;
    final hasCollections =
        collectionState.playlistCount > 0 ||
        collectionState.wishlistCount > 0 ||
        collectionState.lovedCount > 0 ||
        collectionState.favoriteArtistCount > 0;
    final shouldShowLibraryControls =
        hasLibraryContent ||
        hasAnyLibraryItems ||
        hasCollections ||
        hasActiveSearch;
    final listInset = wideListInset(context);
    if (!searchingLibrary) {
      _scheduleBlankLibraryRepair(
        hasQueueItems: hasQueueItems,
        hasLibraryContent: hasLibraryContent,
        hasAnyLibraryItems: hasAnyLibraryItems,
        isLibraryPageLoading: isLibraryPageLoading,
      );
    }

    final selectionItems = getFilterData(
      historyFilterMode,
    ).filteredUnifiedItems;
    if (_isSelectionMode || _isPlaylistSelectionMode) {
      final bottomPadding = MediaQuery.paddingOf(context).bottom;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_isSelectionMode) {
          _syncSelectionOverlay(
            items: selectionItems,
            bottomPadding: bottomPadding,
          );
        }
        if (_isPlaylistSelectionMode) {
          _syncPlaylistSelectionOverlay(
            playlists: collectionState.playlists,
            bottomPadding: bottomPadding,
          );
        }
      });
    }

    final page = PopScope(
      canPop: !_isSelectionMode && !_isPlaylistSelectionMode,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) {
          if (_isPlaylistSelectionMode) {
            _exitPlaylistSelectionMode();
          } else if (_isSelectionMode) {
            _exitSelectionMode();
          }
        }
      },
      child: Stack(
        children: [
          // ScrollConfiguration disables stretch overscroll to fix _StretchController exception
          // This is a known Flutter issue with NestedScrollView + Material 3 stretch indicator
          ScrollConfiguration(
            behavior: ScrollConfiguration.of(
              context,
            ).copyWith(overscroll: false),
            child: NestedScrollView(
              headerSliverBuilder: (context, innerBoxIsScrolled) => [
                if (widget.librarySection == null)
                  AppSliverHeader.tabRoot(
                    title: context.l10n.navLibrary,
                    alignToContent: true,
                  )
                else
                  AppSliverHeader.page(
                    title: widget.librarySection == 'playlists'
                        ? context.l10n.searchPlaylists
                        : context.l10n.searchSongs,
                  ),

                if (shouldShowLibraryControls || hasQueueItems)
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: EdgeInsets.fromLTRB(
                        16 + listInset,
                        8,
                        16 + listInset,
                        0,
                      ),
                      child: GestureDetector(
                        onTap: () {},
                        child: AppSearchField(
                          controller: _searchController,
                          focusNode: _searchFocusNode,
                          hintText: context.l10n.librarySearchHint,
                          clearTooltip: context.l10n.dialogClear,
                          samplesBackdrop: false,
                          onChanged: _onSearchChanged,
                          onClear: () {
                            _clearSearch();
                            FocusScope.of(context).unfocus();
                          },
                        ),
                      ),
                    ),
                  ),

                // Playlists can contain online tracks or be empty. Navigation
                // must stay reachable before any songs are downloaded or scanned.
                if (!searchingLibrary && widget.librarySection == null)
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: EdgeInsets.fromLTRB(
                        16 + listInset,
                        12,
                        16 + listInset,
                        4,
                      ),
                      child: _LibraryPageTabs(
                        selectedIndex: _pageIndexFor(historyFilterMode),
                        onSelected: _animateToFilterPage,
                        tabs: [
                          (context.l10n.searchSongs, queueCounts.allTrackCount),
                          (
                            context.l10n.historyFilterAlbums,
                            queueCounts.albumCount,
                          ),
                          // Artist totals need a full scan; the tab shows
                          // none rather than a guess.
                          (context.l10n.searchArtists, null),
                          (
                            context.l10n.searchPlaylists,
                            _getVisibleCollectionEntries(
                              collectionState,
                            ).length,
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
              body: searchingLibrary
                  ? CustomScrollView(
                      key: const ValueKey('library-search-results'),
                      slivers: [
                        LibrarySearchResults(
                          query: _searchQuery,
                          onOpenArtist: (artist) => Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (_) => Scaffold(
                                body: MornyeLibraryScreen(
                                  page: MornyeLibraryPage.albums,
                                  artist: artist,
                                  onOpenSection: (_) {},
                                ),
                              ),
                            ),
                          ),
                        ),
                        const NavBarSliverSpacer(),
                      ],
                    )
                  : widget.librarySection != null
                  ? _buildFilterContent(
                      context: context,
                      colorScheme: colorScheme,
                      filterMode: historyFilterMode,
                      historyViewMode: 'list',
                      hasQueueItems: false,
                      filterData: getFilterData(historyFilterMode),
                      collectionState: collectionState,
                      hasMoreLibrary: hasMoreLibrary,
                      isPageLoading: isLibraryPageLoading,
                      inMemoryHistoryItems: inMemoryHistoryItems,
                    )
                  : PageView.builder(
                      controller: _filterPageController!,
                      physics: const ClampingScrollPhysics(),
                      onPageChanged: _onFilterPageChanged,
                      itemCount: _filterModes.length,
                      itemBuilder: (context, index) {
                        if (_filterModes[index] == 'artists') {
                          return _buildArtistsPage(context, colorScheme);
                        }
                        final filterMode = _modeForPage(index);
                        final filterData = getFilterData(filterMode);
                        return _buildFilterContent(
                          context: context,
                          colorScheme: colorScheme,
                          filterMode: filterMode,
                          historyViewMode: historyViewMode,
                          hasQueueItems: hasQueueItems,
                          filterData: filterData,
                          collectionState: collectionState,
                          hasMoreLibrary: filterMode == historyFilterMode
                              ? hasMoreLibrary
                              : false,
                          isPageLoading: isLibraryPageLoading,
                          inMemoryHistoryItems: inMemoryHistoryItems,
                        );
                      },
                    ),
            ),
          ),
        ],
      ),
    );
    return DesktopListScope(
      onSelectAll: selectionItems.isEmpty
          ? null
          : () {
              _applyDesktopClick(
                selectionItems.first.id,
                DesktopClick.replace,
                const [],
              );
              _selectAll(selectionItems);
            },
      onClearSelection: _isPlaylistSelectionMode
          ? _exitPlaylistSelectionMode
          : _isSelectionMode
          ? _exitSelectionMode
          : null,
      onDelete: _isSelectionMode ? () => _deleteSelected(selectionItems) : null,
      onActivate: () {
        final anchor = selectionItems
            .where((item) => item.id == _selectionAnchorId)
            .firstOrNull;
        if (anchor != null) _playLibraryItem(anchor, selectionItems);
      },
      child: page,
    );
  }

  Widget _buildQueueHeaderSliver(
    BuildContext context,
    ColorScheme colorScheme,
  ) {
    return Consumer(
      builder: (context, ref, child) {
        final queueCount = ref.watch(
          downloadQueueLookupProvider.select(
            (lookup) => lookup.notCompletedItemIds.length,
          ),
        );
        final failedCount = ref.watch(
          downloadQueueProvider.select((state) => state.failedCount),
        );
        final isProcessing = ref.watch(
          downloadQueueProvider.select((state) => state.isProcessing),
        );
        final isPaused = ref.watch(
          downloadQueueProvider.select((state) => state.isPaused),
        );
        return SliverToBoxAdapter(
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 260),
            switchInCurve: Curves.easeOut,
            switchOutCurve: Curves.easeIn,
            transitionBuilder: (child, animation) => SizeTransition(
              sizeFactor: animation,
              alignment: Alignment.topCenter,
              child: FadeTransition(opacity: animation, child: child),
            ),
            child: queueCount == 0
                ? const SizedBox(
                    width: double.infinity,
                    key: ValueKey('dl_header_empty'),
                  )
                : Padding(
                    key: const ValueKey('dl_header'),
                    padding: EdgeInsetsDirectional.fromSTEB(
                      16 + wideListInset(context),
                      4,
                      4 + wideListInset(context),
                      4,
                    ),
                    child: Row(
                      children: [
                        AppIcon(
                          Icons.downloading_rounded,
                          size: 16,
                          color: colorScheme.primary,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            context.l10n.queueDownloadingCount(queueCount),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.labelLarge
                                ?.copyWith(
                                  color: colorScheme.onSurfaceVariant,
                                  fontWeight: FontWeight.w600,
                                ),
                          ),
                        ),
                        if (failedCount > 0 && !isProcessing)
                          AppIconButton(
                            onPressed: () => ref
                                .read(downloadQueueProvider.notifier)
                                .retryAllFailed(),
                            icon: const Icon(Icons.replay_rounded, size: 20),
                            tooltip: context.l10n.queueRetryAllFailed(
                              failedCount,
                            ),
                            color: colorScheme.primary,
                            visualDensity: VisualDensity.compact,
                          ),
                        AppIconButton(
                          onPressed: () => ref
                              .read(downloadQueueProvider.notifier)
                              .togglePause(),
                          icon: Icon(
                            isPaused
                                ? Icons.play_arrow_rounded
                                : Icons.pause_rounded,
                            size: 20,
                          ),
                          tooltip: isPaused
                              ? context.l10n.actionResume
                              : context.l10n.actionPause,
                          color: colorScheme.onSurfaceVariant,
                          visualDensity: VisualDensity.compact,
                        ),
                        AppIconButton(
                          onPressed: () =>
                              _showClearAllDialog(context, ref, colorScheme),
                          icon: const Icon(Icons.clear_all_rounded, size: 20),
                          tooltip: context.l10n.queueClearAll,
                          color: colorScheme.error,
                          visualDensity: VisualDensity.compact,
                        ),
                      ],
                    ),
                  ),
          ),
        );
      },
    );
  }
}
