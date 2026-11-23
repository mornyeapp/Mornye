import 'dart:io';
import 'dart:math';
import 'package:audio_service/audio_service.dart' show MediaItem;
import 'package:flutter/foundation.dart' show mapEquals;
import 'package:material_ui/material_ui.dart';
import 'package:mornye/theme/app_tokens.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/theme/cover_palette.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/providers/album_track_sort_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/widgets/album_track_sort_button.dart';
import 'package:mornye/utils/adaptive_layout.dart';
import 'package:mornye/utils/audio_quality_badge_policy.dart';
import 'package:mornye/utils/file_access.dart';
import 'package:mornye/utils/image_cache_utils.dart';
import 'package:mornye/services/library_album_artwork.dart';
import 'package:mornye/services/library_database.dart';
import 'package:mornye/services/batch_track_actions.dart';
import 'package:mornye/models/album_track_order.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/models/unified_library_item.dart';
import 'package:mornye/services/local_track_redownload_service.dart';
import 'package:mornye/providers/deleted_library_files.dart';
import 'package:mornye/providers/library_album_artwork_provider.dart';
import 'package:mornye/providers/local_library_provider.dart';
import 'package:mornye/providers/playback_provider.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/providers/player_motion_artwork_provider.dart';
import 'package:mornye/providers/song_leftovers_provider.dart';
import 'package:mornye/controllers/collapsing_header_scroll_mixin.dart';
import 'package:mornye/controllers/confirm_and_delete_tracks.dart';
import 'package:mornye/controllers/local_track_batch_actions.dart';
import 'package:mornye/controllers/selection_mode_mixin.dart';
import 'package:mornye/screens/track_metadata_screen.dart';
import 'package:mornye/widgets/cached_cover_image.dart';
import 'package:mornye/widgets/collection_scaffold.dart';
import 'package:mornye/widgets/collection_suggestions_section.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:mornye/widgets/desktop/context_menu.dart';
import 'package:mornye/widgets/desktop/desktop_selection.dart';
import 'package:mornye/widgets/desktop/detail_header.dart';
import 'package:mornye/widgets/desktop/library_track_menu.dart';
import 'package:mornye/widgets/link/link_library_actions.dart';
import 'package:mornye/services/link/link_library_jobs.dart';
import 'package:mornye/widgets/playlist_picker_sheet.dart';
import 'package:mornye/widgets/desktop/track_table.dart';
import 'package:mornye/widgets/expressive_button.dart';
import 'package:mornye/widgets/album_track_tile.dart';
import 'package:mornye/widgets/animation_utils.dart';
import 'package:mornye/widgets/loaded_sliver_fade_in.dart';
import 'package:mornye/widgets/app_snack_bar.dart';
import 'package:mornye/widgets/library_track_selection_bar.dart';
import 'package:mornye/widgets/link/link_actions.dart';
import 'package:mornye/widgets/network_offline_actions.dart';
import 'package:mornye/widgets/network_upload_actions.dart';
import 'package:mornye/widgets/library_selection_playback_actions.dart';
import 'package:mornye/widgets/local_library_artwork_builder.dart';
import 'package:mornye/widgets/disc_separator_chip.dart';
import 'package:mornye/widgets/album_detail_header.dart';
import 'package:mornye/widgets/header_toolbar_actions.dart';
import 'package:mornye/widgets/mornye_artist_header.dart';
import 'package:mornye/widgets/motion_header_banner.dart';
import 'package:mornye/widgets/queue_swipe.dart';
import 'package:mornye/widgets/track_card.dart';

class LocalAlbumScreen extends ConsumerStatefulWidget {
  final String albumName;
  final String artistName;
  final String? coverPath;
  final List<LocalLibraryItem> tracks;
  final Future<List<LocalLibraryItem>> Function()? loadTracks;

  const LocalAlbumScreen({
    super.key,
    required this.albumName,
    required this.artistName,
    this.coverPath,
    this.tracks = const [],
    this.loadTracks,
  });

  @override
  ConsumerState<LocalAlbumScreen> createState() => _LocalAlbumScreenState();
}

class _LocalAlbumScreenState extends ConsumerState<LocalAlbumScreen>
    with
        SelectionModeMixin<LocalAlbumScreen>,
        CollapsingHeaderScrollMixin<LocalAlbumScreen> {
  late AlbumTrackOrder<LocalLibraryItem> _trackOrder;
  Map<String, int>? _trackRanks;
  List<LocalLibraryItem> get _sortedTracksCache => _trackOrder.tracks;
  Map<int, List<LocalLibraryItem>> get _discGroupsCache =>
      _trackOrder.discGroups;
  List<LocalLibraryItem>? _loadedTracks;
  bool _loadingTracks = false;
  Object? _loadError;
  int _loadGeneration = 0;

  void _showCueVirtualTrackSnackBar() {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text(cueVirtualTrackRequiresSplitMessage)),
    );
  }

  List<int> get _sortedDiscNumbersCache => _trackOrder.discNumbers;
  bool get _hasMultipleDiscsCache => _trackOrder.discGroups.length > 1;
  String? _commonQualityCache;
  String? _commonQualityModeCache;

  @override
  void initState() {
    super.initState();
    _rebuildTrackCaches();
    _loadTracks();
  }

  Future<void> _loadTracks() async {
    final loader = widget.loadTracks;
    if (loader == null) return;
    final generation = ++_loadGeneration;
    _loadingTracks = true;
    _loadError = null;
    try {
      final tracks = await loader();
      if (!mounted || generation != _loadGeneration) return;
      _loadedTracks = tracks;
    } catch (error) {
      if (!mounted || generation != _loadGeneration) return;
      _loadError = error;
    }
    _loadingTracks = false;
    setState(_rebuildTrackCaches);
  }

  @override
  void didUpdateWidget(covariant LocalAlbumScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.tracks, widget.tracks) ||
        oldWidget.tracks.length != widget.tracks.length ||
        oldWidget.loadTracks != widget.loadTracks) {
      _loadGeneration++;
      _loadedTracks = null;
      _loadingTracks = false;
      _loadError = null;
      _rebuildTrackCaches();
      _loadTracks();
    }
  }

  void _rebuildTrackCaches() {
    _trackOrder = AlbumTrackOrder(
      _loadedTracks ?? widget.tracks,
      discNumber: (track) => track.discNumber,
      trackNumber: (track) => track.trackNumber,
      trackName: (track) => track.trackName,
      ranks: _trackRanks,
    );
    _commonQualityCache = null;
    _commonQualityModeCache = null;
  }

  Future<void> _deleteSelected(List<LocalLibraryItem> currentTracks) async {
    final container = ProviderScope.containerOf(context, listen: false);
    final selected = _selectedUnifiedItems(currentTracks);
    if (hasLinkLibrarySongs(container, selected)) {
      await runLinkLibraryAction(
        context,
        container,
        selected,
        LinkLibraryAction.delete,
        onAccepted: () {
          if (mounted) exitSelectionMode();
        },
      );
      return;
    }
    final libraryNotifier = ref.read(localLibraryProvider.notifier);
    final tracksById = {for (final track in currentTracks) track.id: track};

    final deletedCount = await confirmAndDeleteTracks(
      context: context,
      ids: selectedIds.toList(),
      deleteItem: (id) async {
        final item = tracksById[id];
        if (item == null) return false;
        if (!isCueVirtualPath(item.filePath)) {
          final deleted = await ref
              .read(songLeftoversProvider)
              .delete(item.filePath);
          if (!deleted) return false;
        }
        return true;
      },
      persistDeletedItems: (ids) async {
        final items = ids.map((id) => tracksById[id]!);
        await removeDeletedLibraryFileEntries(
          container,
          items
              .where((item) => !isCueVirtualPath(item.filePath))
              .map((item) => item.filePath),
        );
        await libraryNotifier.removeItems(
          items
              .where((item) => isCueVirtualPath(item.filePath))
              .map((item) => item.id),
        );
      },
      onExitSelectionMode: exitSelectionMode,
    );

    if (deletedCount == currentTracks.length && mounted) {
      Navigator.pop(context);
    }
  }

  Future<void> _openFile(LocalLibraryItem track) async {
    if (isCueVirtualPath(track.filePath)) {
      _showCueVirtualTrackSnackBar();
      return;
    }
    try {
      await ref
          .read(playbackProvider.notifier)
          .playLocalLibraryQueue(_sortedTracksCache, startItem: track);
    } catch (e) {
      if (mounted) showCannotOpenFileSnackBar(context, e);
    }
  }

  Future<void> _openMetadata(LocalLibraryItem track) async {
    final tracks = _sortedTracksCache;
    await prepareTrackDetailsCover(
      context,
      track.filePath,
      fallback: track.coverPath,
    );
    if (!mounted) return;
    await Navigator.of(context).push(
      slidePageRoute<void>(
        page: TrackMetadataScreen(
          localItem: track,
          localNavigationItems: tracks,
          navigationIndex: tracks.indexWhere((item) => item.id == track.id),
        ),
      ),
    );
  }

  /// A row matches the player by its file, so playlist playback, which uses
  /// the file path rather than the Library row ID, marks it too.
  PlaybackRowKey _playbackKey(LocalLibraryItem track) =>
      (id: track.id, path: track.filePath);

  bool _isCurrentTrack(MediaItem? item, LocalLibraryItem track) =>
      mediaItemPlaysRow(item, _playbackKey(track));

  @override
  Widget build(BuildContext context) {
    final albumCover = widget.coverPath?.trim();
    final artworkTrack =
        _sortedTracksCache
            .where(
              (track) => albumCover?.isNotEmpty == true
                  ? track.coverPath == albumCover
                  : track.coverPath?.isNotEmpty == true,
            )
            .firstOrNull ??
        _sortedTracksCache.firstOrNull;
    // Songs handed to the page keep the covers they had when it opened, so
    // a cover found from here shows from its record.
    final foundCover = _foundCover();
    return LocalLibraryArtworkBuilder(
      coverPath: albumCover?.isNotEmpty == true
          ? albumCover
          : artworkTrack?.coverPath ?? foundCover,
      filePath: artworkTrack?.filePath,
      builder: (context, coverPath) => context.isMornye
          ? MornyeArtistSurface(
              imageSource: coverPath,
              neutralActions: true,
              child: Builder(
                builder: (context) => _buildPage(context, coverPath),
              ),
            )
          : _buildPage(context, coverPath),
    );
  }

  Widget _buildPage(BuildContext context, String? coverPath) {
    final colorScheme = Theme.of(context).colorScheme;
    final qualityLabelMode = ref.watch(
      settingsProvider.select((s) => s.libraryQualityLabelMode),
    );
    final bottomPadding = isSelectionMode
        ? MediaQuery.paddingOf(context).bottom
        : 0.0;
    final ranks = ref.watch(albumTrackRanksProvider(_sortKey));
    if (!mapEquals(ranks, _trackRanks)) {
      _trackRanks = ranks;
      _rebuildTrackCaches();
    }
    final tracks = _sortedTracksCache;

    if (tracks.isEmpty && !_loadingTracks && _loadError == null) {
      return Scaffold(
        appBar: AppBar(title: Text(widget.albumName)),
        body: Center(child: Text(context.l10n.noTracksFoundForAlbum)),
      );
    }

    slideSelectIds = [for (final track in tracks) track.id];
    pruneSelection(slideSelectIds.toSet());

    final scaffold = CollectionScaffold(
      scrollController: scrollController,
      isSelectionMode: showsSelectionBar,
      onExitSelectionMode: exitSelectionMode,
      appBar: _buildAppBar(context, colorScheme, qualityLabelMode, coverPath),
      slivers: [
        if (_loadError != null)
          SliverToBoxAdapter(
            child: Center(
              child: ExpressiveButton(
                text: true,
                onPressed: () => setState(() {
                  _loadTracks();
                }),
                icon: const Icon(Icons.refresh),
                child: Text(context.l10n.dialogRetry),
              ),
            ),
          )
        else ...[
          // Loaded songs fade in once over the skeleton's place where their
          // rows do not stagger in: the desktop table, and phone rows that
          // load after the page opens.
          LoadedSliverFadeIn(
            key: const ValueKey('local-album-tracks'),
            loading: _loadingTracks,
            enabled: isDesktopPlatform || widget.loadTracks != null,
            sliver: _loadingTracks
                ? const SliverToBoxAdapter(
                    child: RepaintBoundary(
                      child: AlbumTrackListSkeleton(
                        itemCount: 8,
                        showQuality: true,
                      ),
                    ),
                  )
                : _buildTrackList(context, colorScheme, tracks),
          ),
          if (!_loadingTracks && !showsSelectionBar)
            CollectionSuggestionsSliver(
              collectionKey:
                  'local-album:${widget.artistName}:${widget.albumName}',
              tracks: [
                for (final item in tracks)
                  Track(
                    id: item.id,
                    name: item.trackName,
                    artistName: item.artistName,
                    albumName: item.albumName,
                    duration: item.duration ?? 0,
                    isrc: item.isrc,
                  ),
              ],
            ),
        ],
      ],
      selectionBar: _buildSelectionBottomBar(tracks, bottomPadding),
    );
    return DesktopListScope(
      onSelectAll: tracks.isEmpty
          ? null
          : () => selectAll(tracks.map((track) => track.id)),
      onClearSelection: isSelectionMode ? exitSelectionMode : null,
      onDelete: isSelectionMode ? () => _deleteSelected(tracks) : null,
      onActivate: () {
        final anchor = tracks
            .where((track) => track.id == selectionAnchorId)
            .firstOrNull;
        if (anchor != null) _openFile(anchor);
      },
      child: scaffold,
    );
  }

  Widget _buildAppBar(
    BuildContext context,
    ColorScheme colorScheme,
    String qualityLabelMode,
    String? coverPath,
  ) {
    final expandedHeight = calculateExpandedHeight(context);
    // Only a found cover changes the header, not the lookup finishing.
    final motion = context.isMornye && !MediaQuery.disableAnimationsOf(context)
        ? ref.watch(
            songMotionArtworkProvider((
              album: widget.albumName,
              artist:
                  _sortedTracksCache.firstOrNull?.artistName ??
                  widget.artistName,
              source: _sortedTracksCache.firstOrNull?.filePath ?? '',
            )).select((lookup) => lookup.value),
          )
        : null;

    final cacheWidth = detailHeaderCoverCacheWidth(context);
    final bgCacheWidth = !context.isMornye
        ? metadataBackdropCacheExtent(context)
        : cacheWidth;
    final Widget background = coverPath != null
        ? LocalOrNetworkCoverImage(
            url: coverPath,
            localCacheWidth: bgCacheWidth,
            placeholder: (_) => Container(color: colorScheme.surface),
          )
        : Container(
            color: colorScheme.surfaceContainerHighest,
            child: Icon(
              Icons.album,
              size: 80,
              color: colorScheme.onSurfaceVariant,
            ),
          );

    return AlbumDetailHeader(
      title: widget.albumName,
      immersive: context.isMornye,
      squareArtwork: motion == null,
      expandedHeight: expandedHeight,
      showTitleInAppBar: false,
      showTitleListenable: showTitleNotifier,
      background: motion == null
          ? background
          : MotionHeaderBanner(videoUrl: motion.source, fallback: background),
      paletteSource: coverPath,
      blurAndScrimBackground: coverPath != null,
      coverBuilder: (context, coverSize) => coverPath != null
          ? Image.file(
              File(coverPath),
              fit: BoxFit.cover,
              width: coverSize,
              height: coverSize,
              cacheWidth: cacheWidth,
              gaplessPlayback: true,
              errorBuilder: (_, _, _) => Container(
                color: colorScheme.surfaceContainerHighest,
                child: Icon(
                  Icons.album,
                  size: 48,
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            )
          : Container(
              color: colorScheme.surfaceContainerHighest,
              child: Icon(
                Icons.album,
                size: 48,
                color: colorScheme.onSurfaceVariant,
              ),
            ),
      // Built inside the header, so desktop reads its artwork scheme.
      subtitle: Builder(
        builder: (header) => Text(
          widget.artistName,
          style: isDesktopPlatform
              ? desktopDetailSubtitleStyle(header)
              : TextStyle(
                  color: context.isMornye
                      ? colorScheme.primary
                      : HeaderPalette.of(context).onSurfaceVariant,
                  fontSize: context.tokens.headerSubtitleSize,
                  fontWeight: context.isMornye
                      ? FontWeight.w400
                      : FontWeight.w600,
                ),
          textAlign: TextAlign.center,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      meta: _buildLocalHeaderMeta(context, qualityLabelMode),
      appBarActions: [
        HeaderToolbarActions(
          sort: AlbumTrackSortButton(
            albumKey: _sortKey,
            songs: [for (final track in _sortedTracksCache) track.trackName],
          ),
          actions: (context, ref) {
            final items = _albumItems();
            return [
              ?networkOfflineItemsAction(context, ref, items),
              ?networkUploadAction(context, ref, items),
              ...linkTransferActions(context, ref, items),
            ];
          },
        ),
      ],
      actions: Consumer(
        builder: (context, ref, _) {
          final isCurrent = ref.watch(
            currentMediaItemProvider.select(
              (state) => _sortedTracksCache.any(
                (track) => _isCurrentTrack(state.value, track),
              ),
            ),
          );
          final isPlaying = isCurrent && ref.watch(playbackPlayingProvider);
          return AlbumPlayActions(
            isPlaying: isPlaying,
            playLabel: isPlaying
                ? context.l10n.actionPause
                : context.l10n.tooltipPlay,
            shuffleTooltip: context.l10n.actionShuffle,
            onPlay: isCurrent
                ? () => ref
                      .read(musicPlayerControllerProvider)
                      .togglePlayPause(isPlaying)
                : _playAll,
            onShuffle: _shuffleAll,
            showShuffle: ref.watch(playerUiEnabledProvider),
            onAddToPlaylist: () => showAddTracksToPlaylistSheet(
              Navigator.of(context, rootNavigator: true).context,
              ref,
              [for (final item in _albumItems()) item.toTrack()],
            ),
          );
        },
      ),
      moreMenu: () => _withArtworkActions(
        libraryTrackMenuGroups(
          context,
          ref,
          items: _albumItems(),
          onPlay: _playAll,
        ),
        hasCover: coverPath != null,
        hasMotion:
            motion != null ||
            !context.isMornye ||
            MediaQuery.disableAnimationsOf(context),
      ),
    );
  }

  /// The album's key and what Find Missing Artwork found for it. Null for
  /// songs from a network connection, which keep their server's covers.
  ({String albumKey, AlbumArtworkRecord? record})? _albumArtwork() {
    final path = _artworkLookupPath;
    if (path == null) return null;
    return ref.read(libraryAlbumArtworkForSongProvider(path)).value;
  }

  String? get _artworkLookupPath {
    final path = _sortedTracksCache.firstOrNull?.filePath;
    return path == null || path.startsWith('network://') ? null : path;
  }

  /// The cover Find Missing Artwork found. A lookup that finds none does not
  /// build the page again.
  String? _foundCover() {
    final path = _artworkLookupPath;
    if (path == null) return null;
    return ref.watch(
      libraryAlbumArtworkForSongProvider(
        path,
      ).select((artwork) => artwork.value?.record?.coverFile),
    );
  }

  /// [groups] with Find Artwork, while the album lacks a cover or an
  /// animated cover it could show, and Remove Found Artwork, once something
  /// was found. They go before a last group of destructive actions.
  List<List<ContextMenuAction>> _withArtworkActions(
    List<List<ContextMenuAction>> groups, {
    required bool hasCover,
    required bool hasMotion,
  }) {
    final artwork = _albumArtwork();
    if (artwork == null) return groups;
    final record = artwork.record;
    final busy = ref.read(libraryAlbumArtworkProvider).running;
    final wantsMotion =
        !hasMotion && ref.read(settingsProvider).motionArtworkEnabled;
    final actions = [
      if (!hasCover || wantsMotion)
        ContextMenuAction(
          icon: Icons.image_search_outlined,
          label: context.l10n.albumFindArtwork,
          onSelected: busy
              ? null
              : () => _findArtwork(artwork.albumKey, motion: wantsMotion),
        ),
      if (record?.coverFile != null || record?.motionSaved == true)
        ContextMenuAction(
          icon: Icons.hide_image_outlined,
          label: context.l10n.albumRemoveFoundArtwork,
          onSelected: busy ? null : () => _removeFoundArtwork(artwork.albumKey),
        ),
    ];
    if (actions.isEmpty) return groups;
    final destructiveLast =
        groups.isNotEmpty && groups.last.every((action) => action.destructive);
    return [
      ...destructiveLast ? groups.take(groups.length - 1) : groups,
      actions,
      if (destructiveLast) groups.last,
    ];
  }

  Future<void> _findArtwork(String albumKey, {required bool motion}) async {
    final artwork = ref.read(libraryAlbumArtworkProvider.notifier);
    final l10n = context.l10n;
    if (!artwork.canLookUp()) {
      showAppSnackBar(
        context,
        content: Text(l10n.libraryFindArtworkNoProvider),
      );
      return;
    }
    try {
      final summary = await artwork.findForAlbum(albumKey, motion: motion);
      if (summary == null || !mounted) return;
      final found =
          summary.covers > 0 || summary.motion > 0 || summary.failed > 0;
      showAppSnackBar(
        context,
        content: Text(
          found
              ? l10n.libraryFindArtworkResult(
                  summary.covers,
                  summary.motion,
                  summary.failed,
                )
              : l10n.albumFindArtworkNotFound,
        ),
      );
      if (summary.songs > 0) _loadTracks();
    } catch (error) {
      if (!mounted) return;
      showAppSnackBar(
        context,
        content: Text(l10n.snackbarError(context.friendlyError(error))),
      );
    }
  }

  Future<void> _removeFoundArtwork(String albumKey) async {
    final l10n = context.l10n;
    await ref
        .read(libraryAlbumArtworkProvider.notifier)
        .removeForAlbum(albumKey);
    if (!mounted) return;
    showAppSnackBar(context, content: Text(l10n.albumRemoveFoundArtworkDone));
    _loadTracks();
  }

  AlbumTrackSortKey get _sortKey =>
      (album: widget.albumName, artist: widget.artistName);

  /// Every song of the album, for the header's album-wide actions.
  List<UnifiedLibraryItem> _albumItems() => [
    for (final track in _sortedTracksCache)
      UnifiedLibraryItem.fromLocalLibrary(track),
  ];

  Widget _buildLocalHeaderMeta(BuildContext context, String qualityLabelMode) {
    final tracks = _sortedTracksCache;
    final totalSeconds = tracks.fold<int>(
      0,
      (sum, t) => sum + ((t.duration ?? 0) > 0 ? t.duration! : 0),
    );
    final totalMinutes = (totalSeconds / 60).round();
    final quality = _getCommonQuality(qualityLabelMode);

    return HeaderMetaRow(
      items: [
        HeaderMetaItem(context.l10n.queueTrackCount(tracks.length)),
        if (totalMinutes > 0) HeaderMetaItem('$totalMinutes min'),
        if (quality != null && quality.isNotEmpty)
          HeaderMetaItem(quality, icon: Icons.graphic_eq),
      ],
    );
  }

  Future<void> _playAll() async {
    final tracks = _sortedTracksCache;
    if (tracks.isEmpty) return;
    await ref.read(musicPlayerControllerProvider).setShuffle(false);
    await _openFile(tracks.first);
  }

  Future<void> _shuffleAll() async {
    final tracks = _sortedTracksCache
        .where((t) => !isCueVirtualPath(t.filePath))
        .toList();
    if (tracks.isEmpty) return;
    await ref.read(musicPlayerControllerProvider).setShuffle(true);
    await _openFile(tracks[Random().nextInt(tracks.length)]);
  }

  String? _getCommonQuality(String mode) {
    if (_commonQualityModeCache == mode) return _commonQualityCache;
    _commonQualityModeCache = mode;
    _commonQualityCache = _computeCommonQuality(_sortedTracksCache, mode);
    return _commonQualityCache;
  }

  String? _computeCommonQuality(List<LocalLibraryItem> tracks, String mode) {
    if (tracks.isEmpty) return null;
    String? label(LocalLibraryItem track) => buildLibraryAudioQualityLabel(
      mode: mode,
      format: track.format,
      filePath: track.filePath,
      bitrateKbps: track.bitrate,
      bitDepth: track.bitDepth,
      sampleRate: track.sampleRate,
    );

    final firstQuality = label(tracks.first);
    if (firstQuality == null) return null;
    for (final track in tracks) {
      if (label(track) != firstQuality) return null;
    }
    return firstQuality;
  }

  Widget _buildTrackList(
    BuildContext context,
    ColorScheme colorScheme,
    List<LocalLibraryItem> tracks,
  ) {
    if (isDesktopPlatform) return _buildDesktopTable(context, tracks);
    final discGroups = _discGroupsCache;
    final hasMultipleDiscs = _hasMultipleDiscsCache;

    final slivers = <Widget>[];

    for (final discNumber in _sortedDiscNumbersCache) {
      final discTracks = discGroups[discNumber]!;

      if (hasMultipleDiscs) {
        slivers.add(
          SliverToBoxAdapter(child: DiscSeparatorChip(discNumber: discNumber)),
        );
      }

      slivers.add(
        SliverList(
          delegate: SliverChildBuilderDelegate((context, index) {
            final track = discTracks[index];
            // Material joins the rows of a disc into one connected list.
            return TrackCardSegment.at(
              key: ValueKey(track.id),
              index: index,
              count: discTracks.length,
              child: StaggeredListItem(
                index: index,
                animate: widget.loadTracks == null,
                child: _buildTrackItem(context, track),
              ),
            );
          }, childCount: discTracks.length),
        ),
      );
    }

    return SliverPadding(
      // A disc label brings its own space above the first run.
      padding: EdgeInsets.symmetric(
        horizontal: wideListInset(context),
      ).copyWith(top: hasMultipleDiscs ? 0 : collectionRunTopGap(context)),
      sliver: SliverMainAxisGroup(slivers: slivers),
    );
  }

  /// The desktop song table: a click plays, right-click opens the
  /// selection's actions.
  Widget _buildDesktopTable(
    BuildContext context,
    List<LocalLibraryItem> tracks,
  ) {
    final mode = ref.watch(
      settingsProvider.select((s) => s.libraryQualityLabelMode),
    );
    final byId = {for (final track in tracks) track.id: track};
    return SliverPadding(
      padding: EdgeInsets.symmetric(horizontal: wideListInset(context)),
      sliver: SliverTrackTable(
        rows: [
          for (final track in tracks)
            TrackTableRow(
              id: track.id,
              number: track.trackNumber,
              title: track.trackName,
              artist: track.artistName,
              album: track.albumName,
              quality: buildLibraryAudioQualityLabel(
                mode: mode,
                format: track.format,
                filePath: track.filePath,
                bitrateKbps: track.bitrate,
                bitDepth: track.bitDepth,
                sampleRate: track.sampleRate,
              ),
              duration: track.duration == null
                  ? null
                  : Duration(seconds: track.duration!),
              playback: mediaItemPlaybackUiProvider(_playbackKey(track)),
              trailing: Consumer(
                builder: (context, ref, _) {
                  final isCurrent = ref.watch(
                    currentMediaItemProvider.select(
                      (state) => _isCurrentTrack(state.value, track),
                    ),
                  );
                  final isPlaying =
                      isCurrent && ref.watch(playbackPlayingProvider);
                  return AlbumTrackPlayButton(
                    isPlaying: isPlaying,
                    onPlay: isCurrent
                        ? () => ref
                              .read(musicPlayerControllerProvider)
                              .togglePlayPause(isPlaying)
                        : () => _openFile(track),
                    dense: true,
                  );
                },
              ),
            ),
        ],
        columns: const [
          TrackTableColumn.number,
          TrackTableColumn.title,
          TrackTableColumn.artist,
          TrackTableColumn.quality,
          TrackTableColumn.duration,
        ],
        selectedIds: selectedIds,
        albumLayout: context.isMornye,
        albumArtist: widget.artistName,
        onSelect: applyDesktopClick,
        onActivate: (id) {
          final track = byId[id];
          if (track != null) _openFile(track);
        },
        onContextMenu: (id, position) {
          final track = byId[id];
          if (track == null) return;
          showSelectionMenu(
            id,
            () => _showDesktopMenu(context, tracks, track, position),
          );
        },
      ),
    );
  }

  Future<bool> _showDesktopMenu(
    BuildContext context,
    List<LocalLibraryItem> tracks,
    LocalLibraryItem track,
    Offset position,
  ) {
    final items = _selectedUnifiedItems(tracks);
    return showContextMenu(
      context,
      position: position,
      groups: libraryTrackMenuGroups(
        context,
        ref,
        items: items,
        onPlay: () => _openFile(track),
        onOpenDetails: () => _openMetadata(track),
        onDone: exitSelectionMode,
        onReEnrich: () => _reEnrichSelected(tracks),
        onConvert: () => showBatchConvertSheet(
          this.context,
          ref,
          items,
          onExitSelectionMode: exitSelectionMode,
        ),
        onDelete: () => _deleteSelected(tracks),
      ),
    );
  }

  Widget _buildTrackItem(BuildContext context, LocalLibraryItem track) {
    return slideSelectRow(
      track.id,
      Consumer(
        builder: (context, ref, _) {
          final isCurrent = ref.watch(
            currentMediaItemProvider.select(
              (state) => _isCurrentTrack(state.value, track),
            ),
          );
          final isPlaying = isCurrent && ref.watch(playbackPlayingProvider);
          return AlbumTrackTile(
            filePath: track.filePath,
            isCurrent: isCurrent,
            isPlaying: isPlaying,
            trackNumber: track.trackNumber,
            trackName: track.trackName,
            subtitle: Row(
              children: [
                Flexible(
                  child: Text(
                    track.artistName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (track.format != null) ...[
                  const Text(' • ', style: TextStyle(fontSize: 12)),
                  Text(
                    track.format!.toUpperCase(),
                    style: const TextStyle(fontSize: 12),
                  ),
                ],
              ],
            ),
            isSelectionMode: isSelectionMode,
            isSelected: selectedIds.contains(track.id),
            onToggleSelection: () => toggleSelection(track.id),
            onOpen: () => _openMetadata(track),
            onEnterSelectionMode: () => holdToSelect(track.id),
            onPlay: isCurrent
                ? () => ref
                      .read(musicPlayerControllerProvider)
                      .togglePlayPause(isPlaying)
                : () => _openFile(track),
            queueSwipe: libraryItemQueueSwipe(
              ref,
              UnifiedLibraryItem.fromLocalLibrary(track),
            ),
          );
        },
      ),
    );
  }

  List<LocalLibraryItem> _selectedFlacEligibleItems(
    List<LocalLibraryItem> allTracks,
  ) {
    final tracksById = {for (final t in allTracks) t.id: t};
    return selectedIds
        .map((id) => tracksById[id])
        .whereType<LocalLibraryItem>()
        .where(LocalTrackRedownloadService.isFlacUpgradeEligible)
        .toList(growable: false);
  }

  Future<void> _queueSelectedAsFlac(List<LocalLibraryItem> allTracks) =>
      queueLocalTracksAsFlac(
        context,
        ref,
        _selectedFlacEligibleItems(allTracks),
        isActive: () => mounted,
        onComplete: exitSelectionMode,
      );

  Future<void> _reEnrichSelected(List<LocalLibraryItem> allTracks) async {
    final tracksById = {for (final track in allTracks) track.id: track};
    final selected = [for (final id in selectedIds) ?tracksById[id]];
    await reEnrichLocalTracks(
      context,
      ref,
      selected,
      isActive: () => mounted,
      onSelectionHide: () async {
        setState(() => isSelectionMode = false);
        // Allow the selection bar's 250 ms slide-out to finish.
        await Future<void>.delayed(const Duration(milliseconds: 300));
      },
      onSelectionRestore: () => setState(() => isSelectionMode = true),
      onComplete: exitSelectionMode,
    );
  }

  List<UnifiedLibraryItem> _selectedUnifiedItems(
    List<LocalLibraryItem> tracks,
  ) {
    final tracksById = {for (final t in tracks) t.id: t};
    return [
      for (final t in selectedIds.map((id) => tracksById[id]))
        if (t != null) UnifiedLibraryItem.fromLocalLibrary(t),
    ];
  }

  Widget _buildSelectionBottomBar(
    List<LocalLibraryItem> tracks,
    double bottomPadding,
  ) {
    final allSelected =
        selectedIds.length == tracks.length && tracks.isNotEmpty;
    final selectedUnified = _selectedUnifiedItems(tracks);

    return LibraryTrackSelectionBar(
      selectedCount: selectedIds.length,
      allSelected: allSelected,
      onClose: exitSelectionMode,
      onToggleSelectAll: allSelected
          ? exitSelectionMode
          : () => selectAll(tracks.map((e) => e.id)),
      bottomPadding: bottomPadding,
      albumDelete: true,
      playbackActions: LibrarySelectionPlaybackActions(
        items: selectedUnified,
        onClose: exitSelectionMode,
      ),
      flacEligibleCount: _selectedFlacEligibleItems(tracks).length,
      onQueueFlac: () => _queueSelectedAsFlac(tracks),
      onReEnrich: () => _reEnrichSelected(tracks),
      onConvert: () => showBatchConvertSheet(
        context,
        ref,
        selectedUnified,
        onExitSelectionMode: exitSelectionMode,
      ),
      onReplayGain: ({required remove}) => runBatchReplayGain(
        context,
        selectedUnified,
        onExitSelectionMode: exitSelectionMode,
        remove: remove,
      ),
      onDelete: () => _deleteSelected(tracks),
    );
  }
}
