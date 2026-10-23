import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:mornye/widgets/app_snack_bar.dart';
import 'package:mornye/screens/track_history_snapshot.dart';
import 'package:mornye/theme/app_tokens.dart';
import 'package:mornye/theme/cover_palette.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/widgets/app_switch.dart';
import 'package:mornye/widgets/app_checkbox.dart';
import 'package:mornye/widgets/app_content_card.dart';
import 'package:mornye/widgets/app_choice_chip.dart';
import 'package:mornye/widgets/app_loading_indicator.dart';
import 'package:mornye/widgets/app_progress_indicator.dart';
import 'package:mornye/theme/app_motion.dart';
import 'package:mornye/widgets/app_refresh_indicator.dart';
import 'package:mornye/widgets/app_shape.dart';
import 'package:mornye/widgets/expressive_button.dart';
import 'package:mornye/widgets/app_icon_button.dart';
import 'package:mornye/widgets/app_menu_button.dart';
import 'package:mornye/theme/mornye_icons.dart';
import 'package:mornye/widgets/mornye_chrome.dart';
import 'package:mornye/widgets/mornye_context_menu.dart';
import 'package:mornye/widgets/app_icon.dart';
import 'package:mornye/widgets/library_search_results.dart';
import 'package:mornye/screens/mornye_library_screen.dart';
import 'package:mornye/widgets/app_bottom_sheet.dart';
import 'package:mornye/widgets/app_alert_dialog.dart';
import 'package:mornye/widgets/app_sliver_header.dart';
import 'package:mornye/widgets/sliver_layout_info_builder.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:liquid_glass_easy/liquid_glass_easy.dart' show LiquidGlassBatch;
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/track_provider.dart';
import 'package:mornye/providers/download_queue_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/providers/extension_provider.dart';
import 'package:mornye/providers/recent_access_provider.dart';
import 'package:mornye/providers/explore_provider.dart';
import 'package:mornye/providers/user_profile_provider.dart';
import 'package:mornye/widgets/desktop/desktop_scroll_arrows.dart';
import 'package:mornye/widgets/explore_featured_section.dart';
import 'package:mornye/providers/local_library_provider.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/models/unified_library_item.dart';
import 'package:mornye/screens/equalizer_screen.dart';
import 'package:mornye/screens/listening_statistics_screen.dart';
import 'package:mornye/screens/network_storage_screen.dart';
import 'package:mornye/screens/now_playing_screen.dart';
import 'package:mornye/services/library_database.dart';
import 'package:mornye/services/listening_statistics.dart';
import 'package:mornye/services/music_player_service.dart' show PlayableMedia;
import 'package:mornye/screens/track_metadata_screen.dart';
import 'package:mornye/screens/album_screen.dart';
import 'package:mornye/screens/artist_screen.dart';
import 'package:mornye/screens/extension_collection_screens.dart';
import 'package:mornye/controllers/home_search_logic.dart';
import 'package:mornye/services/csv_import_service.dart';
import 'package:mornye/services/cover_download_service.dart';
import 'package:mornye/services/downloaded_embedded_cover_resolver.dart';
import 'package:mornye/services/shell_navigation_service.dart';
import 'package:mornye/utils/adaptive_layout.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:mornye/utils/nav_bar_inset.dart';
import 'package:mornye/widgets/desktop/desktop_commands.dart'
    show openDesktopNowPlaying;
import 'package:mornye/utils/file_access.dart';
import 'package:mornye/utils/home_greeting.dart';
import 'package:mornye/screens/playlist_screen.dart';
import 'package:mornye/screens/downloaded_album_screen.dart';
import 'package:mornye/widgets/download_service_picker.dart';
import 'package:mornye/widgets/track_collection_quick_actions.dart';
import 'package:mornye/widgets/desktop/context_menu.dart';
import 'package:mornye/widgets/animation_utils.dart';
import 'package:mornye/utils/clickable_metadata.dart';
import 'package:mornye/widgets/audio_quality_badges.dart';
import 'package:mornye/widgets/cached_cover_image.dart';
import 'package:mornye/widgets/player_artwork.dart';
import 'package:mornye/widgets/error_card.dart';
import 'package:mornye/widgets/in_library_badge.dart';
import 'package:mornye/widgets/preview_button.dart';
import 'package:mornye/widgets/app_search_field.dart';
import 'package:mornye/widgets/track_detail_actions.dart';
import 'package:mornye/widgets/view_queue_snackbar_action.dart';
import 'package:mornye/widgets/profile_avatar.dart';
import 'package:mornye/widgets/downloadable_cover.dart';
import 'package:mornye/widgets/app_crash_banner.dart';

export 'package:mornye/screens/extension_collection_screens.dart';

part 'home_tab_helpers.dart';
part 'home_tab_explore.dart';
part 'home_tab_recent.dart';
part 'home_tab_import.dart';
part 'home_tab_intro.dart';
part 'home_tab_search_results.dart';
part 'home_tab_widgets.dart';

enum HomeTabMode { combined, browse, search }

class HomeTab extends ConsumerStatefulWidget {
  const HomeTab({super.key, this.mode = HomeTabMode.combined});

  final HomeTabMode mode;

  @override
  ConsumerState<HomeTab> createState() => _HomeTabState();
}

class _HomeTabState extends ConsumerState<HomeTab>
    with AutomaticKeepAliveClientMixin, SingleTickerProviderStateMixin {
  bool get _showsSearch => widget.mode != HomeTabMode.browse;
  bool get _showsHome => widget.mode != HomeTabMode.search;
  final _historySnapshot = TrackHistorySnapshot();
  final _urlController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();
  final _homeScrollController = ScrollController();
  String _lastSearchText = '';
  String? _lastSearchQuery;
  String? _activeSearchInput;
  bool _isResettingSearchSurface = false;
  late final ProviderSubscription<TrackState> _trackStateSub;
  late final ProviderSubscription<bool> _extensionInitSub;
  late final ProviderSubscription<bool> _homeFeedExtSub;

  Timer? _liveSearchDebounce;
  int _searchGeneration = 0;
  static const int _minLiveSearchChars = 3;
  static const Duration _liveSearchDelay = Duration(milliseconds: 800);

  /// The Mornye desktop Search page can search the library instead of the
  /// online provider, as the scope control in Music does.
  bool get _offersLibraryScope =>
      widget.mode == HomeTabMode.search &&
      context.isMornye &&
      isDesktopPlatform;
  bool _searchesLibrary = false;
  String _libraryQuery = '';
  Timer? _libraryQueryDebounce;
  bool get _searchingLibrary => _searchesLibrary && _offersLibraryScope;

  bool _embeddedCoverRefreshScheduled = false;
  List<Extension>? _thumbnailSizesExtensionsCache;
  bool _isCsvImporting = false;
  final Set<String> _activeCoverDownloads = <String>{};

  void _setCsvImporting(bool value) {
    if (_isCsvImporting == value) return;
    if (!mounted) {
      _isCsvImporting = value;
      return;
    }
    setState(() {
      _isCsvImporting = value;
    });
  }

  Map<String, (double, double)>? _thumbnailSizesCache;
  List<Track>? _searchBucketsSourceTracks;
  HomeSearchResultBuckets? _searchBucketsCache;
  HomeSearchSortOption _searchSortOption = HomeSearchSortOption.defaultOrder;
  List<Track>? _sortedTracksSource;
  List<int>? _sortedTrackIndexesSource;
  HomeSearchSortOption? _sortedTracksMode;
  List<Track>? _sortedTracksCache;
  List<int>? _sortedTrackIndexesCache;

  double _exploreCardSize(BuildContext context) {
    // Six phone-sized cards across an iPad made the feed look like a desktop
    // page zoomed out. A higher tablet cap gives roughly five generous cards
    // in portrait while leaving all phone sizes unchanged.
    final scale = responsiveScale(context: context, min: 0.82, max: 1.32);
    final textScale = effectiveTextScale(context);
    final size = 145 * scale * (1 + (textScale - 1) * 0.12);
    // Landscape tablets are short: one carousel row should not take over a
    // third of the screen. Portrait and phone heights never reach this cap.
    final heightCap = MediaQuery.sizeOf(context).height * 0.24;
    return size < heightCap ? size : heightCap;
  }

  /// The square artwork of an explore card. Each card pads 6 on both sides,
  /// so the artwork takes the width that is left rather than the full card.
  double _exploreCoverSize(BuildContext context) =>
      _exploreCardSize(context) - 12;

  double _exploreSectionHeight(BuildContext context) {
    final coverSize = _exploreCoverSize(context);
    final textScale = effectiveTextScale(context);
    return coverSize + 58 + ((textScale - 1) * 12);
  }

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _urlController.addListener(_onSearchChanged);
    _searchFocusNode.addListener(_onSearchFocusChanged);
    ShellNavigationService.searchRequests.addListener(_focusSearchFromShell);

    // Run an initial fetch check in case extensions were already initialized
    // before HomeTab was mounted (e.g. auto-installed during first setup).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _fetchExploreIfNeeded();
    });

    _trackStateSub = ref.listenManual<TrackState>(trackProvider, (
      previous,
      next,
    ) {
      if (!_showsSearch) return;
      _onTrackStateChanged(previous, next);
      if (previous != null &&
          previous.isLoading &&
          !next.isLoading &&
          next.error == null) {
        _navigateToDetailIfNeeded();
      }
    });

    _extensionInitSub = ref.listenManual<bool>(
      extensionProvider.select((s) => s.isInitialized),
      (previous, next) {
        if (next == true && previous != true) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _fetchExploreIfNeeded();
          });
        }
      },
    );

    _homeFeedExtSub = ref.listenManual<bool>(
      extensionProvider.select(
        (s) => s.extensions.any((e) => e.enabled && e.hasHomeFeed),
      ),
      (previous, next) {
        if (next == true && previous != true) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && _showsHome) {
              ref
                  .read(exploreProvider.notifier)
                  .fetchHomeFeed(forceRefresh: true);
            }
          });
        }
      },
    );
  }

  void _fetchExploreIfNeeded() {
    // The desktop Mornye Search page browses the feed too.
    if (!_showsHome && !_offersLibraryScope) return;
    if (ref.read(settingsProvider).homeFeedProvider ==
        AppSettings.homeFeedProviderOff) {
      ref.read(exploreProvider.notifier).clear();
      return;
    }

    final extState = ref.read(extensionProvider);
    final exploreState = ref.read(exploreProvider);
    final hasHomeFeedExtension = extState.extensions.any(
      (e) => e.enabled && e.hasHomeFeed,
    );
    if (hasHomeFeedExtension &&
        !exploreState.hasContent &&
        !exploreState.isLoading) {
      ref.read(exploreProvider.notifier).fetchHomeFeed();
    }
  }

  @override
  void dispose() {
    ShellNavigationService.searchRequests.removeListener(_focusSearchFromShell);
    _homeScrollController.dispose();
    _liveSearchDebounce?.cancel();
    _libraryQueryDebounce?.cancel();
    _trackStateSub.close();
    _extensionInitSub.close();
    _homeFeedExtSub.close();
    _urlController.removeListener(_onSearchChanged);
    _searchFocusNode.removeListener(_onSearchFocusChanged);
    _urlController.dispose();
    _searchFocusNode.dispose();
    super.dispose();
  }

  Map<String, (double, double)> _getThumbnailSizesByExtensionId(
    List<Extension> extensions,
  ) {
    final cached = _thumbnailSizesCache;
    if (cached != null &&
        identical(extensions, _thumbnailSizesExtensionsCache)) {
      return cached;
    }

    final map = <String, (double, double)>{
      for (final extension in extensions)
        if (extension.searchBehavior != null)
          extension.id: extension.searchBehavior!.getThumbnailSize(
            defaultSize: 56,
          ),
    };
    _thumbnailSizesExtensionsCache = extensions;
    _thumbnailSizesCache = map;
    return map;
  }

  List<SearchFilter> _resolveSearchFilters(
    BuildContext context,
    String? currentSearchProvider,
    List<Extension> extensions,
  ) {
    final resolvedSearchProvider = HomeSearchProviderPolicy.resolveProvider(
      currentSearchProvider,
      extensions,
    );
    final isUsingExtensionSearch =
        resolvedSearchProvider != null &&
        resolvedSearchProvider.isNotEmpty &&
        extensions.any((e) => e.id == resolvedSearchProvider && e.enabled);

    if (isUsingExtensionSearch) {
      final currentSearchExtension = extensions
          .where((e) => e.id == resolvedSearchProvider && e.enabled)
          .firstOrNull;
      final filters = currentSearchExtension?.searchBehavior?.filters;
      if (filters != null && filters.isNotEmpty) {
        return filters;
      }
    }

    return [
      SearchFilter(
        id: 'track',
        label: context.l10n.searchTracks,
        icon: 'music',
      ),
      SearchFilter(
        id: 'artist',
        label: context.l10n.searchArtists,
        icon: 'artist',
      ),
      SearchFilter(
        id: 'album',
        label: context.l10n.searchAlbums,
        icon: 'album',
      ),
      SearchFilter(
        id: 'playlist',
        label: context.l10n.searchPlaylists,
        icon: 'playlist',
      ),
    ];
  }

  HomeSearchResultBuckets _getSearchResultBuckets(List<Track> tracks) {
    final cached = _searchBucketsCache;
    if (cached != null && identical(tracks, _searchBucketsSourceTracks)) {
      return cached;
    }

    final buckets = bucketHomeSearchResults(tracks);
    _searchBucketsSourceTracks = tracks;
    _searchBucketsCache = buckets;
    return buckets;
  }

  void _invalidateSearchSortCaches() {
    _sortedTracksSource = null;
    _sortedTrackIndexesSource = null;
    _sortedTracksMode = null;
    _sortedTracksCache = null;
    _sortedTrackIndexesCache = null;
  }

  void _onSearchFocusChanged() {
    // The dedicated Search tab already shows recent items independently of
    // focus. Let TextField handle its cursor/keyboard without rebuilding the
    // entire results page each time navigation focuses or unfocuses it.
    if (widget.mode == HomeTabMode.search) return;
    if (mounted) {
      setState(() {});
    }
    if (_searchFocusNode.hasFocus) {
      ref.read(trackProvider.notifier).setShowingRecentAccess(true);
    }
  }

  void _focusSearchFromShell() {
    if (!_showsSearch) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          !_showsSearch ||
          !TickerMode.getValuesNotifier(context).value.enabled) {
        return;
      }
      if (_homeScrollController.hasClients) _homeScrollController.jumpTo(0);
      _searchFocusNode.requestFocus();
    });
  }

  void _onTrackStateChanged(TrackState? previous, TrackState next) {
    if (next.error != null) {
      // Failed requests must remain retryable without changing the search text.
      _lastSearchQuery = null;
    }
    if (!identical(previous?.tracks, next.tracks)) {
      // Home stays alive across tabs. Empty/loading/error branches can skip
      // result building, so release the previous search's derived lists here.
      _searchBucketsSourceTracks = null;
      _searchBucketsCache = null;
      _invalidateSearchSortCaches();
      _historySnapshot.update(const []);
    }
    if (previous != null &&
        !next.hasContent &&
        !next.hasSearchText &&
        !next.isLoading &&
        _urlController.text.isNotEmpty &&
        !_searchFocusNode.hasFocus) {
      _urlController.clear();
    }
  }

  bool _isLiveSearchEnabled() {
    final settings = ref.read(settingsProvider);
    final extState = ref.read(extensionProvider);
    if (!extState.isInitialized && extState.error == null) return true;

    final searchProvider = HomeSearchProviderPolicy.resolveProvider(
      settings.searchProvider,
      extState.extensions,
    );

    if (searchProvider == null || searchProvider.isEmpty) return false;

    final extension = extState.extensions
        .where((e) => e.id == searchProvider && e.enabled)
        .firstOrNull;
    return extension != null;
  }

  void _onSearchChanged() {
    final text = _urlController.text.trim();
    // Focusing an empty field also changes its selection. Only a text edit
    // should reset results and dismiss focus, not that cursor notification.
    if (text == _lastSearchText) return;
    _lastSearchText = text;

    ref.read(trackProvider.notifier).setSearchText(text.isNotEmpty);

    if (text.isEmpty) {
      _liveSearchDebounce?.cancel();
      _libraryQueryDebounce?.cancel();
      _libraryQuery = '';
      _activeSearchInput = null;
      _lastSearchQuery = null;
      if (!_isResettingSearchSurface) {
        _resetSearchSurface(clearText: false);
      }
      return;
    }

    if (_searchingLibrary) {
      _libraryQueryDebounce?.cancel();
      _libraryQueryDebounce = Timer(const Duration(milliseconds: 300), () {
        if (mounted && _urlController.text.trim() == text) {
          setState(() => _libraryQuery = text);
        }
      });
      return;
    }

    if (_activeSearchInput != null && _activeSearchInput != text) {
      _activeSearchInput = null;
    }

    if (_isLiveSearchEnabled() && text.length >= _minLiveSearchChars) {
      if (looksLikeUrlOrSpotifyUri(text)) return;

      _liveSearchDebounce?.cancel();
      _liveSearchDebounce = Timer(_liveSearchDelay, () {
        if (mounted && _urlController.text.trim() == text) {
          _executeLiveSearch(text);
        }
      });
    }
  }

  Future<void> _executeLiveSearch(String query) async {
    if (!mounted || _urlController.text.trim() != query) return;
    // The provider cancels the preceding native request and rejects stale
    // results. Let the latest debounced input reach that cancellation path.
    await _performSearch(query);
  }

  Future<void> _performSearch(String query, {String? filterOverride}) async {
    final generation = ++_searchGeneration;
    var extState = ref.read(extensionProvider);
    if (!extState.isInitialized && extState.error == null) {
      await ref.read(extensionProvider.notifier).waitForInitialization();
      if (!mounted || generation != _searchGeneration) return;
      extState = ref.read(extensionProvider);
    }
    if (!mounted || generation != _searchGeneration) return;

    final settings = ref.read(settingsProvider);
    final searchProvider = HomeSearchProviderPolicy.resolveProvider(
      settings.searchProvider,
      extState.extensions,
    );
    final storedFilter = ref.read(trackProvider).selectedSearchFilter;
    final selectedFilter = switch (filterOverride) {
      'all' => null,
      final explicit? => HomeSearchProviderPolicy.sanitizeFilter(
        explicit,
        searchProvider,
        extState.extensions,
      ),
      null => switch (storedFilter) {
        'all' => null,
        final stored? => HomeSearchProviderPolicy.sanitizeFilter(
          stored,
          searchProvider,
          extState.extensions,
        ),
        null => HomeSearchProviderPolicy.preferredFilter(
          settings.defaultSearchTab,
          searchProvider,
          extState.extensions,
        ),
      },
    };

    final searchKey =
        '${searchProvider ?? 'default'}:$query:${selectedFilter ?? 'all'}';
    if (_lastSearchQuery == searchKey) {
      _activeSearchInput = query;
      ref.read(trackProvider.notifier).setSearchText(query.trim().isNotEmpty);
      if (mounted) setState(() {});
      return;
    }
    _lastSearchQuery = searchKey;
    _activeSearchInput = query;
    _searchSortOption = HomeSearchSortOption.defaultOrder;
    _invalidateSearchSortCaches();
    ref.read(trackProvider.notifier).setSearchText(query.trim().isNotEmpty);

    final isExtensionEnabled =
        searchProvider != null &&
        searchProvider.isNotEmpty &&
        extState.extensions.any((e) => e.id == searchProvider && e.enabled);

    if (isExtensionEnabled) {
      Map<String, dynamic>? options;
      if (selectedFilter != null) {
        options = {'filter': selectedFilter};
      }
      await ref
          .read(trackProvider.notifier)
          .customSearch(
            searchProvider,
            query,
            options: options,
            selectedFilter: selectedFilter,
          );
    } else {
      if (searchProvider != null &&
          searchProvider.isNotEmpty &&
          !isExtensionEnabled) {
        ref.read(settingsProvider.notifier).setSearchProvider(null);
      }
      await ref
          .read(trackProvider.notifier)
          .search(query, filterOverride: selectedFilter);
    }
    if (mounted && generation == _searchGeneration) {
      ref.read(settingsProvider.notifier).setHasSearchedBefore();
    }
  }

  Future<void> _pasteFromClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (data?.text != null) {
      _urlController.text = data!.text!;
      final text = data.text!.trim();
      if (looksLikeUrlOrSpotifyUri(text)) {
        _fetchMetadata();
      }
    }
  }

  Future<void> _clearAndRefresh() async {
    _resetSearchSurface();
  }

  void _resetSearchSurface({bool clearText = true}) {
    if (_isResettingSearchSurface) return;
    _isResettingSearchSurface = true;
    try {
      _liveSearchDebounce?.cancel();
      _searchGeneration++;
      _lastSearchQuery = null;
      _activeSearchInput = null;
      FocusManager.instance.primaryFocus?.unfocus();
      if (clearText && _urlController.text.isNotEmpty) {
        _urlController.clear();
      }
      ref.read(trackProvider.notifier).clear();
      if (mounted) setState(() {});
    } finally {
      _isResettingSearchSurface = false;
    }
  }

  Future<void> _fetchMetadata() async {
    final url = _urlController.text.trim();
    if (url.isEmpty) return;
    if (looksLikeUrlOrSpotifyUri(url)) {
      await ref.read(trackProvider.notifier).fetchFromUrl(url);
      final trackState = ref.read(trackProvider);
      if (trackState.error != null && mounted) {
        final l10n = context.l10n;
        final errorMsg = trackState.error!;
        final isRateLimit =
            errorMsg.contains('429') ||
            errorMsg.toLowerCase().contains('rate limit') ||
            errorMsg.toLowerCase().contains('too many requests');
        final displayMessage = errorMsg == 'url_not_recognized'
            ? l10n.errorUrlNotRecognizedMessage
            : isRateLimit
            ? l10n.errorRateLimitedMessage
            : l10n.errorUrlFetchFailed;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(displayMessage),
            // Retrying an unrecognized URL is deterministic; skip the action.
            action: errorMsg == 'url_not_recognized'
                ? null
                : SnackBarAction(
                    label: l10n.dialogRetry,
                    onPressed: _fetchMetadata,
                  ),
          ),
        );
        ref.read(trackProvider.notifier).clear();
      } else {
        _navigateToDetailIfNeeded();
      }
    } else {
      await ref.read(trackProvider.notifier).search(url);
    }
    ref.read(settingsProvider.notifier).setHasSearchedBefore();
  }

  void _navigateToDetailIfNeeded() {
    final trackState = ref.read(trackProvider);

    if (trackState.albumId != null &&
        trackState.albumName != null &&
        trackState.tracks.isNotEmpty) {
      final extensionId = trackState.searchExtensionId;
      Navigator.push(
        context,
        MaterialPageRoute<void>(
          builder: (context) => AlbumScreen(
            albumId: trackState.albumId!,
            albumName: trackState.albumName!,
            description: trackState.albumDescription,
            coverUrl: trackState.coverUrl,
            tracks: trackState.tracks,
            extensionId: extensionId,
          ),
        ),
      );
      ref.read(trackProvider.notifier).clear();
      _urlController.clear();
      return;
    }

    if (trackState.playlistName != null && trackState.tracks.isNotEmpty) {
      final playlistProviderId = trackState.searchExtensionId ?? 'spotify';
      ref
          .read(recentAccessProvider.notifier)
          .recordPlaylistAccess(
            id: trackState.playlistId ?? trackState.playlistName!,
            name: trackState.playlistName!,
            imageUrl: trackState.coverUrl,
            providerId: playlistProviderId,
          );

      Navigator.push(
        context,
        MaterialPageRoute<void>(
          builder: (context) => PlaylistScreen(
            playlistName: trackState.playlistName!,
            coverUrl: trackState.coverUrl,
            tracks: trackState.tracks,
            playlistId: trackState.playlistId,
            metadataProviderId: playlistProviderId,
            recommendedService:
                trackState.searchExtensionId ?? trackState.searchSource,
          ),
        ),
      );
      ref.read(trackProvider.notifier).clear();
      _urlController.clear();
      return;
    }

    if (trackState.artistId != null &&
        trackState.artistName != null &&
        trackState.artistAlbums != null) {
      final extensionId = trackState.searchExtensionId;
      Navigator.push(
        context,
        MaterialPageRoute<void>(
          builder: (context) => ArtistScreen(
            artistId: trackState.artistId!,
            artistName: trackState.artistName!,
            coverUrl: trackState.coverUrl,
            headerImageUrl: trackState.headerImageUrl,
            headerVideoUrl: trackState.headerVideoUrl,
            headerLogoUrl: trackState.headerLogoUrl,
            concerts: trackState.artistConcerts,
            albumsNext: trackState.artistAlbumsNext,
            albums: trackState.artistAlbums!,
            topTracks: trackState.artistTopTracks,
            extensionId: extensionId,
          ),
        ),
      );
      ref.read(trackProvider.notifier).clear();
      _urlController.clear();
      return;
    }
  }

  void _downloadTrack(int index, {bool forceQualityPicker = false}) {
    final trackState = ref.read(trackProvider);
    if (index >= 0 && index < trackState.tracks.length) {
      final track = trackState.tracks[index];
      downloadSingleTrack(
        context,
        ref,
        track,
        recommendedService:
            trackState.searchExtensionId ?? trackState.searchSource,
        forceQualityPicker: forceQualityPicker,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);

    final hasActualResults =
        _showsSearch &&
        ref.watch(trackProvider.select((s) => s.tracks.isNotEmpty));
    final isLoading =
        _showsSearch && ref.watch(trackProvider.select((s) => s.isLoading));
    final searchError = _showsSearch
        ? ref.watch(trackProvider.select((s) => s.error))
        : null;
    final explicitSearchProvider = ref.watch(
      settingsProvider.select((s) => s.searchProvider),
    );
    final defaultSearchTab = ref.watch(
      settingsProvider.select((s) => s.defaultSearchTab),
    );
    final extensions = ref.watch(extensionProvider.select((s) => s.extensions));
    final extensionReadiness = ref.watch(
      extensionProvider.select(
        (s) => (isInitialized: s.isInitialized, error: s.error),
      ),
    );

    final hasExploreContent =
        _showsHome &&
        ref.watch(exploreProvider.select((s) => s.sections.isNotEmpty));
    final explorePending =
        _showsHome &&
        ref.watch(
          exploreProvider.select(
            (s) => s.isLoading || (s.lastFetched == null && s.error == null),
          ),
        );
    final hasHomeFeedExtension =
        _showsHome && ref.watch(homeFeedExtensionProvider) != null;
    final homeFeedDisabled =
        _showsHome &&
        ref.watch(
          settingsProvider.select(
            (s) => s.homeFeedProvider == AppSettings.homeFeedProviderOff,
          ),
        );

    final colorScheme = Theme.of(context).colorScheme;
    final searchText = _showsSearch ? _urlController.text.trim() : '';
    final hasSearchInput = searchText.isNotEmpty;
    final isSearchFocused = _showsSearch && _searchFocusNode.hasFocus;
    final hasShortSearchInput =
        hasSearchInput && searchText.length < _minLiveSearchChars;
    final hasSearchError = hasSearchInput && searchError != null;
    final hasActiveSearchSurface =
        hasSearchInput &&
        (_activeSearchInput == searchText ||
            hasActualResults ||
            isLoading ||
            hasSearchError);
    final showEmptySearchResult =
        hasActiveSearchSurface &&
        !hasActualResults &&
        !isLoading &&
        searchError == null;
    final isShowingRecentAccess =
        _showsSearch &&
        ref.watch(trackProvider.select((s) => s.isShowingRecentAccess));
    final screenHeight = MediaQuery.sizeOf(context).height;

    final recentModeRequested =
        widget.mode == HomeTabMode.search ||
        isShowingRecentAccess ||
        isSearchFocused;
    final showRecentAccess =
        recentModeRequested &&
        (!hasSearchInput ||
            hasShortSearchInput ||
            (!hasActualResults &&
                !hasSearchError &&
                !hasActiveSearchSurface)) &&
        !isLoading;
    final isSearchProviderLoading =
        !extensionReadiness.isInitialized && extensionReadiness.error == null;
    final hasSearchProvider = HomeSearchProviderPolicy.hasProvider(
      explicitSearchProvider,
      extensions,
    );
    final showSearchBar =
        _showsSearch &&
        (widget.mode == HomeTabMode.search ||
            HomeSearchProviderPolicy.shouldShowSearchBar(
              hasSearchProvider: hasSearchProvider,
              isSearchProviderLoading: isSearchProviderLoading,
              hasHomeFeedExtension: hasHomeFeedExtension,
              hasExploreContent: hasExploreContent,
              hasSearchInput: hasSearchInput,
            ));
    final hasResults =
        hasSearchInput || hasActualResults || isLoading || showRecentAccess;
    final showExplore =
        _showsHome &&
        !hasActualResults &&
        !isLoading &&
        !hasActiveSearchSurface &&
        !showRecentAccess &&
        !homeFeedDisabled &&
        (hasHomeFeedExtension || hasExploreContent) &&
        hasExploreContent;
    // Unknown extensions and an unresolved first feed are loading states,
    // not evidence that Home should mount its local-only fallback.
    final showExploreLoading =
        _showsHome &&
        !hasActualResults &&
        !isLoading &&
        !hasActiveSearchSurface &&
        !showRecentAccess &&
        !homeFeedDisabled &&
        !hasExploreContent &&
        (isSearchProviderLoading || (hasHomeFeedExtension && explorePending));
    final showFeedSurface = showExplore || showExploreLoading;
    // Only a surface with a search field asks for a search provider. The
    // Mornye Home browses without one, so it never stops at this prompt.
    final showEmptyHomeState =
        _showsSearch &&
        !isSearchProviderLoading &&
        !hasSearchProvider &&
        !hasHomeFeedExtension &&
        !hasExploreContent &&
        !hasResults;
    final searchToolbar = _offersLibraryScope;
    final showLibraryResults = _searchingLibrary && hasSearchInput;
    // As in Music, the library scope waits for words without recents or
    // Browse.
    final showLibraryPrompt = _searchingLibrary && !hasSearchInput;
    final sectionMotion = AppMotion.spatial(
      context,
      const AppMotionSpec(Duration(milliseconds: 250), Curves.easeOut),
    );
    // Without a feed, Home gathers the player, shortcuts and Library shelves.
    final showHomeSections =
        _showsHome && !showFeedSurface && !showEmptyHomeState;
    // The Material Home also greets in its header. A feed brings its own
    // greeting, and the Mornye style keeps its navigation title.
    final greetsInHeader = showHomeSections && !context.isMornye;
    final greeting = greetsInHeader
        ? homeGreeting(
            context.l10n,
            name: ref.watch(
              userProfileProvider.select((p) => p.value?.name ?? ''),
            ),
          )
        : null;

    ref.listen<String>(settingsProvider.select((s) => s.defaultSearchTab), (
      previous,
      next,
    ) {
      if (!_showsSearch || _searchingLibrary || previous == next) return;
      final selectedSearchFilter = ref.read(
        trackProvider.select((s) => s.selectedSearchFilter),
      );
      if (selectedSearchFilter != null && selectedSearchFilter.isNotEmpty) {
        return;
      }

      final text = _urlController.text.trim();
      if (text.isEmpty || text.length < _minLiveSearchChars) return;
      if (looksLikeUrlOrSpotifyUri(text)) return;

      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _lastSearchQuery = null;
        _performSearch(text);
      });
    });

    if (hasActualResults &&
        isShowingRecentAccess &&
        hasSearchInput &&
        !isSearchFocused) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          ref.read(trackProvider.notifier).setShowingRecentAccess(false);
        }
      });
    }

    return GestureDetector(
      onTap: () {
        if (_searchFocusNode.hasFocus) {
          _searchFocusNode.unfocus();
        }
      },
      behavior: HitTestBehavior.translucent,
      child: Scaffold(
        body: AppRefreshIndicator(
          onRefresh: () => ref.read(exploreProvider.notifier).refresh(),
          notificationPredicate: (notification) => showExplore,
          child: CustomScrollView(
            controller: _homeScrollController,
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            slivers: [
              if (searchToolbar)
                _buildDesktopSearchToolbarSliver()
              else
                _buildHeaderSliver(greeting: greeting),
              if (_showsHome) const SliverToBoxAdapter(child: AppCrashBanner()),
              _buildHomeIntroSliver(
                sectionMotion: sectionMotion,
                hasResults: hasResults,
                showExplore: showFeedSurface,
                colorScheme: colorScheme,
                screenHeight: screenHeight,
                showEmptyHomeState: showEmptyHomeState,
              ),
              if (showSearchBar && !searchToolbar)
                _buildSearchBarSliver(
                  hasResults: hasResults,
                  showExplore: showFeedSurface,
                  greetsInHeader: greetsInHeader,
                ),
              if (hasActiveSearchSurface &&
                  !showRecentAccess &&
                  !showEmptySearchResult &&
                  !showLibraryResults)
                _buildSearchFilterSliver(
                  colorScheme: colorScheme,
                  defaultSearchTab: defaultSearchTab,
                ),
              if (showRecentAccess && !showLibraryResults && !showLibraryPrompt)
                _buildRecentAccessSliver(colorScheme: colorScheme),
              if (showLibraryResults) _buildLibrarySearchSliver(),
              if (showLibraryPrompt) _buildLibraryPromptSliver(),
              if (searchToolbar &&
                  !hasSearchInput &&
                  !_searchingLibrary &&
                  !homeFeedDisabled)
                _buildBrowseSliver(),
              _buildHomeSectionsSliver(
                sectionMotion: sectionMotion,
                hasResults: hasResults,
                showRecentAccess: showRecentAccess,
                showExplore: showFeedSurface,
                showEmptyHomeState: showEmptyHomeState,
              ),
              if (showExplore) _buildExploreSliver(colorScheme: colorScheme),
              if (showExploreLoading) _buildExploreLoadingSliver(),
              if (_showsSearch && !showLibraryResults)
                _buildSearchResultsSliver(
                  colorScheme: colorScheme,
                  hasActiveSearchSurface: hasActiveSearchSurface,
                  showEmptySearchResult: showEmptySearchResult,
                ),
              const NavBarSliverSpacer(),
            ],
          ),
        ),
      ),
    );
  }

  void _setSearchScope({required bool library}) {
    if (_searchesLibrary == library) return;
    final text = _urlController.text.trim();
    _liveSearchDebounce?.cancel();
    _libraryQueryDebounce?.cancel();
    setState(() {
      _searchesLibrary = library;
      _libraryQuery = library ? text : '';
    });
    if (library) {
      // Online results for the same words would only flash back later.
      _searchGeneration++;
      _lastSearchQuery = null;
      _activeSearchInput = null;
      ref.read(trackProvider.notifier).clear();
      ref.read(trackProvider.notifier).setSearchText(text.isNotEmpty);
    } else if (text.length >= _minLiveSearchChars &&
        !looksLikeUrlOrSpotifyUri(text)) {
      _performSearch(text);
    }
  }

  /// Music on the Mac keeps its search field centered in the toolbar, with
  /// the scope control at the trailing edge.
  Widget _buildDesktopSearchToolbarSliver() {
    final extensions = ref.watch(extensionProvider.select((s) => s.extensions));
    final providerId = HomeSearchProviderPolicy.resolveProvider(
      ref.watch(settingsProvider.select((s) => s.searchProvider)),
      extensions,
    );
    final online =
        extensions
            .where((e) => e.id == providerId && e.enabled)
            .firstOrNull
            ?.displayName ??
        context.l10n.librarySourceOnline;
    const scopeWidth = 260.0;
    const gap = 16.0;
    final scope = SizedBox(
      width: scopeWidth,
      child: MornyeSegmentedControl(
        key: const ValueKey('search-scope'),
        labels: [online, context.l10n.navLibrary],
        selectedIndex: _searchesLibrary ? 1 : 0,
        onChanged: (index) => _setSearchScope(library: index == 1),
      ),
    );
    return SliverAppBar(
      pinned: true,
      automaticallyImplyLeading: false,
      toolbarHeight: 88,
      backgroundColor: Theme.of(context).colorScheme.surface,
      surfaceTintColor: Colors.transparent,
      titleSpacing: 0,
      title: LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth - 2 * 24;
          final centeredField = math.min(480.0, width - 2 * (scopeWidth + gap));
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: centeredField >= 280
                ? Stack(
                    alignment: Alignment.center,
                    children: [
                      SizedBox(width: centeredField, child: _buildSearchBar()),
                      Align(
                        alignment: AlignmentDirectional.centerEnd,
                        child: scope,
                      ),
                    ],
                  )
                // A narrow window has no room to center the field.
                : Row(
                    children: [
                      Expanded(child: _buildSearchBar()),
                      const SizedBox(width: gap),
                      scope,
                    ],
                  ),
          );
        },
      ),
    );
  }

  Widget _buildLibraryPromptSliver() {
    final colorScheme = Theme.of(context).colorScheme;
    return SliverFillRemaining(
      hasScrollBody: false,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              AppIcon(
                Icons.search,
                size: 64,
                color: colorScheme.onSurfaceVariant,
              ),
              const SizedBox(height: 16),
              Text(
                context.l10n.searchLibraryPrompt,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildLibrarySearchSliver() {
    return LibrarySearchResults(
      query: _libraryQuery,
      shelves: true,
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
    );
  }

  Widget _buildHeaderSliver({required String? greeting}) {
    return AppSliverHeader.tabRoot(
      alignToContent: true,
      title: widget.mode == HomeTabMode.search
          ? context.l10n.mornyeSearch
          : greeting ?? context.l10n.homeTitle,
      // The desktop sidebar's account row already opens the profile.
      actions: context.isMornye && _showsHome && !isDesktopPlatform
          ? const [HomeProfileButton()]
          : null,
    );
  }

  Widget _buildHomeIntroSliver({
    required AppMotionSpec sectionMotion,
    required bool hasResults,
    required bool showExplore,
    required ColorScheme colorScheme,
    required double screenHeight,
    required bool showEmptyHomeState,
  }) {
    return SliverToBoxAdapter(
      child: AnimatedSize(
        // A provider installed offscreen replaces the empty panel without
        // carrying its height into the compact intro on the first frame.
        key: ValueKey(showEmptyHomeState),
        alignment: AlignmentDirectional.topStart,
        duration: sectionMotion.duration,
        curve: sectionMotion.curve,
        child: (hasResults || showExplore || !_showsHome)
            ? const SizedBox.shrink()
            : _buildHomeIntro(
                colorScheme: colorScheme,
                screenHeight: screenHeight,
                showEmptyHomeState: showEmptyHomeState,
              ),
      ),
    );
  }

  Widget _buildSearchBarSliver({
    required bool hasResults,
    required bool showExplore,
    required bool greetsInHeader,
  }) {
    return SliverToBoxAdapter(
      child: Padding(
        // Centered with the search results on tablets.
        padding: EdgeInsets.fromLTRB(
          16 + wideListInset(context),
          (hasResults || showExplore)
              ? 8
              : greetsInHeader
              ? 20
              : 32,
          16 + wideListInset(context),
          (hasResults || showExplore) ? 8 : 16,
        ),
        child: _buildSearchBar(),
      ),
    );
  }

  Widget _buildSearchFilterSliver({
    required ColorScheme colorScheme,
    required String defaultSearchTab,
  }) {
    return Consumer(
      builder: (context, ref, _) {
        final currentSearchProvider = ref.watch(
          settingsProvider.select((s) => s.searchProvider),
        );
        final extensions = ref.watch(
          extensionProvider.select((s) => s.extensions),
        );
        final selectedSearchFilter = ref.watch(
          trackProvider.select((s) => s.selectedSearchFilter),
        );
        final searchFilters = _resolveSearchFilters(
          context,
          currentSearchProvider,
          extensions,
        );
        if (searchFilters.isEmpty) {
          return const SliverToBoxAdapter(child: SizedBox.shrink());
        }
        return SliverToBoxAdapter(
          child: _buildSearchFilterBar(
            searchFilters,
            HomeSearchProviderPolicy.displayFilterSelection(
              selectedSearchFilter,
              defaultSearchTab,
              currentSearchProvider,
              extensions,
            ),
            colorScheme,
          ),
        );
      },
    );
  }

  Widget _buildRecentAccessSliver({required ColorScheme colorScheme}) {
    return Consumer(
      builder: (context, ref, _) {
        final recentAccessView = ref.watch(recentAccessViewProvider);
        return _buildRecentAccess(recentAccessView, colorScheme);
      },
    );
  }

  Widget _buildHomeSectionsSliver({
    required AppMotionSpec sectionMotion,
    required bool hasResults,
    required bool showRecentAccess,
    required bool showExplore,
    required bool showEmptyHomeState,
  }) {
    return SliverToBoxAdapter(
      child: AnimatedSize(
        duration: sectionMotion.duration,
        curve: sectionMotion.curve,
        child:
            (!_showsHome ||
                hasResults ||
                showRecentAccess ||
                showExplore ||
                showEmptyHomeState)
            ? const SizedBox.shrink()
            : _HomeSections(inset: 16 + wideListInset(context)),
      ),
    );
  }

  Widget _buildExploreSliver({required ColorScheme colorScheme}) {
    return Consumer(
      builder: (context, ref, _) {
        final exploreSections = ref.watch(
          exploreProvider.select((s) => s.sections),
        );
        // The feed decides whether a greeting shows; its words
        // are localized here and address the profile name.
        final showGreeting =
            ref.watch(exploreProvider.select((s) => s.greeting)) != null;
        final profileName = ref.watch(
          userProfileProvider.select((p) => p.value?.name ?? ''),
        );
        return SliverMainAxisGroup(
          slivers: _buildExploreSections(
            exploreSections,
            showGreeting ? homeGreeting(context.l10n, name: profileName) : null,
            colorScheme,
          ),
        );
      },
    );
  }

  Widget _buildExploreLoadingSliver() {
    return SliverToBoxAdapter(
      child: ShimmerLoading(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildExploreSectionSkeleton(isArtist: false),
            _buildExploreSectionSkeleton(isArtist: true),
          ],
        ),
      ),
    );
  }

  Widget _buildSearchResultsSliver({
    required ColorScheme colorScheme,
    required bool hasActiveSearchSurface,
    required bool showEmptySearchResult,
  }) {
    return Consumer(
      builder: (context, ref, _) {
        final tracks = ref.watch(trackProvider.select((s) => s.tracks));
        final isLoading = ref.watch(trackProvider.select((s) => s.isLoading));
        final error = ref.watch(trackProvider.select((s) => s.error));
        final searchExtensionId = ref.watch(
          trackProvider.select((s) => s.searchExtensionId),
        );
        final localLibrarySettings = ref.watch(
          settingsProvider.select(
            (s) => (s.localLibraryEnabled, s.localLibraryShowDuplicates),
          ),
        );
        final extensions = ref.watch(
          extensionProvider.select((s) => s.extensions),
        );
        final showLocalLibraryIndicator =
            localLibrarySettings.$1 && localLibrarySettings.$2;
        final thumbnailSizesByExtensionId = _getThumbnailSizesByExtensionId(
          extensions,
        );
        final hasResults =
            tracks.isNotEmpty ||
            isLoading ||
            error != null ||
            hasActiveSearchSurface;

        return SliverMainAxisGroup(
          slivers: _buildSearchResults(
            resultsRef: ref,
            tracks: tracks,
            isLoading: isLoading,
            error: error,
            colorScheme: colorScheme,
            hasResults: hasResults,
            showEmptySearchResult: showEmptySearchResult,
            searchExtensionId: searchExtensionId,
            showLocalLibraryIndicator: showLocalLibraryIndicator,
            thumbnailSizesByExtensionId: thumbnailSizesByExtensionId,
          ),
        );
      },
    );
  }

  Widget _buildHomeIntro({
    required ColorScheme colorScheme,
    required double screenHeight,
    required bool showEmptyHomeState,
  }) {
    if (showEmptyHomeState) {
      final emptyHeight = (screenHeight - 220).clamp(280.0, 520.0).toDouble();
      return SizedBox(
        height: emptyHeight,
        child: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.extension_outlined,
                  size: 56,
                  color: colorScheme.onSurfaceVariant,
                ),
                const SizedBox(height: 16),
                Text(
                  context.l10n.homeEmptyTitle,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  context.l10n.homeEmptySubtitle,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    // The Mornye style uses the navigation title as the page identity. Keep
    // the search surface directly beneath it instead of repeating app branding
    // in the content area.
    if (context.isMornye) return const SizedBox.shrink();

    // The header carries the greeting; prompts take turns beneath it.
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: 24 + wideListInset(context)),
      child: const Align(
        alignment: AlignmentDirectional.centerStart,
        child: _HomeTagline(),
      ),
    );
  }

  void _onEmbeddedCoverChanged() {
    if (!mounted || _embeddedCoverRefreshScheduled) return;
    _embeddedCoverRefreshScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _embeddedCoverRefreshScheduled = false;
      if (mounted) {
        setState(() {});
      }
    });
  }
}
