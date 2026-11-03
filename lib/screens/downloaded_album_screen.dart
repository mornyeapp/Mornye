import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:mornye/theme/app_tokens.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/theme/cover_palette.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:mornye/services/cover_cache_manager.dart';
import 'package:mornye/services/batch_track_actions.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/models/unified_library_item.dart';
import 'package:mornye/models/album_track_order.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/utils/adaptive_layout.dart';
import 'package:mornye/utils/audio_quality_badge_policy.dart';
import 'package:mornye/utils/cover_art_utils.dart';
import 'package:mornye/utils/file_access.dart';
import 'package:mornye/utils/image_cache_utils.dart';
import 'package:mornye/providers/deleted_library_files.dart';
import 'package:mornye/providers/download_queue_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/providers/playback_provider.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/providers/player_motion_artwork_provider.dart';
import 'package:mornye/controllers/collapsing_header_scroll_mixin.dart';
import 'package:mornye/controllers/confirm_and_delete_tracks.dart';
import 'package:mornye/controllers/local_track_batch_actions.dart';
import 'package:mornye/controllers/selection_mode_mixin.dart';
import 'package:mornye/screens/track_metadata_screen.dart';
import 'package:mornye/services/downloaded_embedded_cover_resolver.dart';
import 'package:mornye/widgets/collection_scaffold.dart';
import 'package:mornye/widgets/collection_suggestions_section.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:mornye/widgets/desktop/context_menu.dart';
import 'package:mornye/widgets/desktop/desktop_selection.dart';
import 'package:mornye/widgets/desktop/detail_header.dart';
import 'package:mornye/widgets/desktop/library_track_menu.dart';
import 'package:mornye/widgets/playlist_picker_sheet.dart';
import 'package:mornye/widgets/desktop/track_table.dart';
import 'package:mornye/widgets/cached_cover_image.dart';
import 'package:mornye/widgets/app_snack_bar.dart';
import 'package:mornye/widgets/album_track_tile.dart';
import 'package:mornye/widgets/animation_utils.dart';
import 'package:mornye/widgets/library_track_selection_bar.dart';
import 'package:mornye/widgets/library_selection_playback_actions.dart';
import 'package:mornye/widgets/link/link_actions.dart';
import 'package:mornye/widgets/network_offline_actions.dart';
import 'package:mornye/widgets/network_upload_actions.dart';
import 'package:mornye/widgets/disc_separator_chip.dart';
import 'package:mornye/widgets/album_detail_header.dart';
import 'package:mornye/widgets/mornye_artist_header.dart';
import 'package:mornye/widgets/motion_header_banner.dart';
import 'package:mornye/widgets/app_loading_indicator.dart';

class DownloadedAlbumScreen extends ConsumerStatefulWidget {
  final String albumName;
  final String artistName;
  final String? coverUrl;

  const DownloadedAlbumScreen({
    super.key,
    required this.albumName,
    required this.artistName,
    this.coverUrl,
  });

  @override
  ConsumerState<DownloadedAlbumScreen> createState() =>
      _DownloadedAlbumScreenState();
}

class _DownloadedAlbumScreenState extends ConsumerState<DownloadedAlbumScreen>
    with
        SelectionModeMixin<DownloadedAlbumScreen>,
        CollapsingHeaderScrollMixin<DownloadedAlbumScreen> {
  bool _embeddedCoverRefreshScheduled = false;
  List<DownloadHistoryItem>? _albumTracksSourceCache;
  AlbumTrackOrder<DownloadHistoryItem>? _albumTrackOrderCache;
  List<DownloadHistoryItem>? _commonQualitySourceCache;
  String? _commonQualityCache;
  String? _commonQualityModeCache;
  List<DownloadHistoryItem>? _embeddedCoverSourceCache;
  String? _embeddedCoverPathCache;
  bool _embeddedCoverPathResolved = false;

  String get _albumLookupKey =>
      '${widget.albumName.toLowerCase()}|${widget.artistName.toLowerCase()}';

  @override
  void didUpdateWidget(covariant DownloadedAlbumScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.albumName != widget.albumName ||
        oldWidget.artistName != widget.artistName) {
      _albumTracksSourceCache = null;
      _invalidateDerivedTrackCaches();
    }
  }

  AlbumTrackOrder<DownloadHistoryItem> _getAlbumOrder(
    List<DownloadHistoryItem> allItems,
  ) {
    final cached = _albumTrackOrderCache;
    if (cached != null && identical(allItems, _albumTracksSourceCache)) {
      return cached;
    }

    final order = AlbumTrackOrder(
      allItems.where((item) {
        final itemArtist =
            (item.albumArtist != null && item.albumArtist!.isNotEmpty)
            ? item.albumArtist!
            : item.artistName;
        final itemKey =
            '${item.albumName.toLowerCase()}|${itemArtist.toLowerCase()}';
        return itemKey == _albumLookupKey;
      }),
      discNumber: (track) => track.discNumber,
      trackNumber: (track) => track.trackNumber,
      trackName: (track) => track.trackName,
    );

    _albumTracksSourceCache = allItems;
    _invalidateDerivedTrackCaches();
    _albumTrackOrderCache = order;
    return order;
  }

  void _invalidateDerivedTrackCaches() {
    _albumTrackOrderCache = null;
    _commonQualitySourceCache = null;
    _commonQualityCache = null;
    _commonQualityModeCache = null;
    _embeddedCoverSourceCache = null;
    _embeddedCoverPathCache = null;
    _embeddedCoverPathResolved = false;
  }

  Future<void> _deleteSelected(List<DownloadHistoryItem> currentTracks) async {
    final container = ProviderScope.containerOf(context, listen: false);
    final tracksById = {for (final track in currentTracks) track.id: track};

    await confirmAndDeleteTracks(
      context: context,
      ids: selectedIds.toList(),
      deleteItem: (id) async {
        final item = tracksById[id];
        if (item == null) return false;
        return deleteFile(item.filePath);
      },
      persistDeletedItems: (ids) => removeDeletedLibraryFileEntries(
        container,
        ids.map((id) => tracksById[id]!.filePath),
      ),
      onExitSelectionMode: exitSelectionMode,
    );
  }

  Future<void> _openFile(
    DownloadHistoryItem track, {
    List<DownloadHistoryItem> queueItems = const [],
  }) async {
    try {
      await ref
          .read(playbackProvider.notifier)
          .playHistoryQueue(
            queueItems.isNotEmpty ? queueItems : [track],
            startItem: track,
          );
    } catch (e) {
      if (mounted) showCannotOpenFileSnackBar(context, e);
    }
  }

  /// A row matches the player by its file, whichever queue played it.
  PlaybackRowKey _playbackKey(DownloadHistoryItem track) =>
      (id: track.id, path: track.filePath);

  void _onEmbeddedCoverChanged() {
    if (!mounted || _embeddedCoverRefreshScheduled) return;
    _embeddedCoverRefreshScheduled = true;
    _embeddedCoverPathResolved = false;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _embeddedCoverRefreshScheduled = false;
      if (mounted) {
        setState(() {});
      }
    });
  }

  Future<void> _navigateToMetadataScreen(
    DownloadHistoryItem item, {
    required List<DownloadHistoryItem> navigationItems,
    required int navigationIndex,
  }) async {
    final navigator = Navigator.of(context);
    final embeddedCoverPath = context.isMornye
        ? DownloadedEmbeddedCoverResolver.resolve(item.filePath)
        : await DownloadedEmbeddedCoverResolver.resolveOrExtract(
            item.filePath,
            onChanged: _onEmbeddedCoverChanged,
          );
    if (!mounted) return;
    final artworkSource = embeddedCoverPath ?? item.coverUrl;
    if (embeddedCoverPath == null && !context.isMornye) {
      precacheCoverImage(context, item.coverUrl);
    }
    final backdropReady = context.isMornye
        ? Future<void>.value()
        : precacheMetadataBackdrop(context, artworkSource);
    final beforeModTime =
        await DownloadedEmbeddedCoverResolver.readFileModTimeMillis(
          item.filePath,
        );
    await backdropReady;
    if (!mounted) return;

    final route = slidePageRoute<bool>(
      page: TrackMetadataScreen(
        item: item,
        historyNavigationItems: navigationItems,
        navigationIndex: navigationIndex,
      ),
    );
    final result = await navigator.push(route);
    // Refresh the album after the return animation, not while both pages paint.
    if (route is TransitionRoute<bool>) await route.completed;
    if (!mounted) return;
    await DownloadedEmbeddedCoverResolver.scheduleRefreshForPath(
      item.filePath,
      beforeModTime: beforeModTime,
      force: result == true,
      onChanged: _onEmbeddedCoverChanged,
    );
  }

  @override
  Widget build(BuildContext context) {
    final tracksValue = ref.watch(
      downloadedAlbumTracksProvider(
        DownloadedAlbumTracksRequest(
          albumName: widget.albumName,
          artistName: widget.artistName,
        ),
      ),
    );
    final order = tracksValue.maybeWhen(
      data: (items) => _getAlbumOrder(items),
      orElse: () => null,
    );

    if (order == null || order.tracks.isEmpty) {
      if (tracksValue.isLoading) {
        return Scaffold(
          appBar: AppBar(title: Text(widget.albumName)),
          body: const Center(child: AppLoadingIndicator()),
        );
      }
      return Scaffold(
        appBar: AppBar(title: Text(widget.albumName)),
        body: Center(child: Text(context.l10n.noTracksFoundForAlbum)),
      );
    }

    final tracks = order.tracks;
    pruneSelection(tracks.map((t) => t.id).toSet());

    if (context.isMornye) {
      return MornyeArtistSurface(
        imageSource: _resolveAlbumEmbeddedCoverPath(tracks) ?? widget.coverUrl,
        neutralActions: true,
        child: Builder(builder: (context) => _buildPage(context, order)),
      );
    }
    return _buildPage(context, order);
  }

  Widget _buildPage(
    BuildContext context,
    AlbumTrackOrder<DownloadHistoryItem> order,
  ) {
    final tracks = order.tracks;
    final colorScheme = Theme.of(context).colorScheme;
    final qualityLabelMode = ref.watch(
      settingsProvider.select((s) => s.libraryQualityLabelMode),
    );
    final bottomPadding = isSelectionMode
        ? MediaQuery.paddingOf(context).bottom
        : 0.0;

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
        if (anchor != null) _openFile(anchor, queueItems: tracks);
      },
      child: CollectionScaffold(
        scrollController: scrollController,
        isSelectionMode: showsSelectionBar,
        onExitSelectionMode: exitSelectionMode,
        appBar: _buildAppBar(context, colorScheme, tracks, qualityLabelMode),
        slivers: [
          _buildTrackList(context, colorScheme, order),
          if (!showsSelectionBar)
            CollectionSuggestionsSliver(
              collectionKey:
                  'downloaded-album:${widget.artistName}:${widget.albumName}',
              tracks: [
                for (final item in tracks)
                  // No source: history IDs are not provider IDs, so the
                  // extension looks the songs up.
                  Track(
                    id: item.spotifyId ?? item.id,
                    name: item.trackName,
                    artistName: item.artistName,
                    albumName: item.albumName,
                    duration: item.duration ?? 0,
                    isrc: item.isrc,
                  ),
              ],
            ),
        ],
        selectionBar: _buildSelectionBottomBar(tracks, bottomPadding),
      ),
    );
  }

  String? _resolveAlbumEmbeddedCoverPath(List<DownloadHistoryItem> tracks) {
    if (_embeddedCoverPathResolved &&
        identical(tracks, _embeddedCoverSourceCache)) {
      return _embeddedCoverPathCache;
    }

    _embeddedCoverSourceCache = tracks;
    _embeddedCoverPathResolved = true;

    if (tracks.isEmpty) {
      _embeddedCoverPathCache = null;
      return null;
    }

    _embeddedCoverPathCache = DownloadedEmbeddedCoverResolver.resolve(
      tracks.first.filePath,
      onChanged: _onEmbeddedCoverChanged,
    );
    return _embeddedCoverPathCache;
  }

  Widget _buildAppBar(
    BuildContext context,
    ColorScheme colorScheme,
    List<DownloadHistoryItem> tracks,
    String qualityLabelMode,
  ) {
    final expandedHeight = calculateExpandedHeight(context);
    final embeddedCoverPath = _resolveAlbumEmbeddedCoverPath(tracks);
    final commonQuality = _getCommonQuality(tracks, qualityLabelMode);
    final motion = context.isMornye && !MediaQuery.disableAnimationsOf(context)
        ? ref
              .watch(
                playerMotionArtworkProvider((
                  album: widget.albumName,
                  artist: tracks.isEmpty
                      ? widget.artistName
                      : tracks.first.artistName,
                )),
              )
              .value
        : null;

    final cacheWidth = coverCacheWidthForViewport(context);
    final Widget background = embeddedCoverPath != null
        ? LocalOrNetworkCoverImage(
            url: embeddedCoverPath,
            localCacheWidth: cacheWidth,
            placeholder: (_) => Container(color: colorScheme.surface),
          )
        : widget.coverUrl != null
        ? CachedNetworkImage(
            imageUrl: highResCoverUrl(widget.coverUrl) ?? widget.coverUrl!,
            fit: BoxFit.cover,
            memCacheWidth: cacheWidth,
            cacheManager: CoverCacheManager.instance,
            placeholder: (_, _) => Container(color: colorScheme.surface),
            errorWidget: (_, _, _) => Container(color: colorScheme.surface),
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
      paletteSource: embeddedCoverPath ?? widget.coverUrl,
      blurAndScrimBackground:
          embeddedCoverPath != null || widget.coverUrl != null,
      coverBuilder: (context, coverSize) => _buildSquareCover(
        context,
        colorScheme,
        embeddedCoverPath,
        coverSize,
        cacheWidth,
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
      meta: tracks.isNotEmpty
          ? _buildDownloadedHeaderMeta(context, tracks, commonQuality)
          : null,
      appBarActions: [
        NetworkOfflineButton(
          items: [
            for (final track in tracks)
              UnifiedLibraryItem.fromDownloadHistory(track),
          ],
        ),
        NetworkUploadButton(
          items: [
            for (final track in tracks)
              UnifiedLibraryItem.fromDownloadHistory(track),
          ],
        ),
        if (ref.watch(linkPhoneClientProvider) != null)
          LinkTransferButtons(
            items: [
              for (final track in tracks)
                UnifiedLibraryItem.fromDownloadHistory(track),
            ],
          ),
      ],
      actions: tracks.isNotEmpty
          ? AlbumPlayActions(
              playLabel: context.l10n.tooltipPlay,
              shuffleTooltip: context.l10n.actionShuffle,
              onPlay: () => _playAll(tracks),
              onShuffle: () => _shuffleAll(tracks),
              onAddToPlaylist: () => showAddTracksToPlaylistSheet(
                Navigator.of(context, rootNavigator: true).context,
                ref,
                [
                  for (final track in tracks)
                    UnifiedLibraryItem.fromDownloadHistory(track).toTrack(),
                ],
              ),
            )
          : null,
      moreMenu: tracks.isEmpty
          ? null
          : () => libraryTrackMenuGroups(
              context,
              ref,
              items: [
                for (final track in tracks)
                  UnifiedLibraryItem.fromDownloadHistory(track),
              ],
              onPlay: () => _playAll(tracks),
            ),
    );
  }

  Widget _buildSquareCover(
    BuildContext context,
    ColorScheme colorScheme,
    String? embeddedCoverPath,
    double coverSize,
    int cacheWidth,
  ) {
    Widget placeholder() => Container(
      color: colorScheme.surfaceContainerHighest,
      child: Icon(Icons.album, size: 48, color: colorScheme.onSurfaceVariant),
    );

    if (embeddedCoverPath != null) {
      return Image.file(
        File(embeddedCoverPath),
        fit: BoxFit.cover,
        width: coverSize,
        height: coverSize,
        cacheWidth: cacheWidth,
        gaplessPlayback: true,
        errorBuilder: (_, _, _) => placeholder(),
      );
    }

    final coverUrl = widget.coverUrl;
    if (coverUrl != null && coverUrl.isNotEmpty) {
      return CachedNetworkImage(
        imageUrl: highResCoverUrl(coverUrl) ?? coverUrl,
        fit: BoxFit.cover,
        width: coverSize,
        height: coverSize,
        memCacheWidth: cacheWidth,
        cacheManager: CoverCacheManager.instance,
        placeholder: (_, _) => placeholder(),
        errorWidget: (_, _, _) => placeholder(),
      );
    }

    return placeholder();
  }

  Widget _buildDownloadedHeaderMeta(
    BuildContext context,
    List<DownloadHistoryItem> tracks,
    String? commonQuality,
  ) {
    final totalSeconds = tracks.fold<int>(
      0,
      (sum, t) => sum + ((t.duration ?? 0) > 0 ? t.duration! : 0),
    );
    final totalMinutes = (totalSeconds / 60).round();

    return HeaderMetaRow(
      items: [
        HeaderMetaItem(
          context.l10n.downloadedAlbumDownloadedCount(tracks.length),
        ),
        if (totalMinutes > 0) HeaderMetaItem('$totalMinutes min'),
        if (commonQuality != null && commonQuality.isNotEmpty)
          HeaderMetaItem(commonQuality, icon: Icons.graphic_eq),
      ],
    );
  }

  Future<void> _playAll(List<DownloadHistoryItem> tracks) async {
    if (tracks.isEmpty) return;
    await ref.read(musicPlayerControllerProvider).setShuffle(false);
    await _openFile(tracks.first, queueItems: tracks);
  }

  Future<void> _shuffleAll(List<DownloadHistoryItem> tracks) async {
    if (tracks.isEmpty) return;
    await ref.read(musicPlayerControllerProvider).setShuffle(true);
    await _openFile(
      tracks[Random().nextInt(tracks.length)],
      queueItems: tracks,
    );
  }

  String? _getCommonQuality(List<DownloadHistoryItem> tracks, String mode) {
    if (identical(tracks, _commonQualitySourceCache) &&
        mode == _commonQualityModeCache) {
      return _commonQualityCache;
    }

    if (tracks.isEmpty) {
      _commonQualitySourceCache = tracks;
      _commonQualityModeCache = mode;
      _commonQualityCache = null;
      return null;
    }
    String? label(DownloadHistoryItem track) => buildLibraryAudioQualityLabel(
      mode: mode,
      format: track.format,
      filePath: track.filePath,
      fileName: track.safFileName,
      bitrateKbps: track.bitrate,
      bitDepth: track.bitDepth,
      sampleRate: track.sampleRate,
      storedQuality: track.quality,
    );

    final firstQuality = label(tracks.first);
    if (firstQuality == null) {
      _commonQualitySourceCache = tracks;
      _commonQualityModeCache = mode;
      _commonQualityCache = null;
      return null;
    }
    for (final track in tracks) {
      if (label(track) != firstQuality) {
        _commonQualitySourceCache = tracks;
        _commonQualityModeCache = mode;
        _commonQualityCache = null;
        return null;
      }
    }
    _commonQualitySourceCache = tracks;
    _commonQualityModeCache = mode;
    _commonQualityCache = firstQuality;
    return firstQuality;
  }

  Widget _buildTrackList(
    BuildContext context,
    ColorScheme colorScheme,
    AlbumTrackOrder<DownloadHistoryItem> order,
  ) {
    final tracks = order.tracks;
    final discMap = order.discGroups;

    if (isDesktopPlatform) return _buildDesktopTable(context, tracks);
    if (discMap.length <= 1) {
      return SliverPadding(
        padding: EdgeInsets.symmetric(horizontal: wideListInset(context)),
        sliver: SliverList(
          delegate: SliverChildBuilderDelegate((context, index) {
            final track = tracks[index];
            return KeyedSubtree(
              key: ValueKey(track.id),
              child: StaggeredListItem(
                index: index,
                child: _buildTrackItem(context, track, tracks, index),
              ),
            );
          }, childCount: tracks.length),
        ),
      );
    }

    final discNumbers = order.discNumbers;
    final navigationIndexById = <String, int>{
      for (var index = 0; index < tracks.length; index++)
        tracks[index].id: index,
    };
    final slivers = <Widget>[];
    var revealIndex = 0;

    for (final discNumber in discNumbers) {
      final discTracks = discMap[discNumber];
      if (discTracks == null || discTracks.isEmpty) continue;

      slivers.add(
        SliverToBoxAdapter(child: DiscSeparatorChip(discNumber: discNumber)),
      );
      final discRevealStart = revealIndex;
      revealIndex += discTracks.length;
      slivers.add(
        SliverList(
          delegate: SliverChildBuilderDelegate((context, index) {
            final track = discTracks[index];
            return KeyedSubtree(
              key: ValueKey(track.id),
              child: StaggeredListItem(
                index: discRevealStart + index,
                child: _buildTrackItem(
                  context,
                  track,
                  tracks,
                  navigationIndexById[track.id] ?? 0,
                ),
              ),
            );
          }, childCount: discTracks.length),
        ),
      );
    }

    return SliverPadding(
      padding: EdgeInsets.symmetric(horizontal: wideListInset(context)),
      sliver: SliverMainAxisGroup(slivers: slivers),
    );
  }

  /// The desktop song table: a click plays, right-click opens the
  /// selection's actions.
  Widget _buildDesktopTable(
    BuildContext context,
    List<DownloadHistoryItem> tracks,
  ) {
    final mode = ref.watch(
      settingsProvider.select((s) => s.libraryQualityLabelMode),
    );
    final indexById = {
      for (var index = 0; index < tracks.length; index++)
        tracks[index].id: index,
    };
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
                fileName: track.safFileName,
                bitrateKbps: track.bitrate,
                bitDepth: track.bitDepth,
                sampleRate: track.sampleRate,
                storedQuality: track.quality,
              ),
              duration: track.duration == null
                  ? null
                  : Duration(seconds: track.duration!),
              playback: mediaItemPlaybackUiProvider(_playbackKey(track)),
              trailing: _TrackPlaybackBuilder(
                playbackKey: _playbackKey(track),
                builder: (context, playback, toggle) => AlbumTrackPlayButton(
                  isPlaying: playback.isPlaying,
                  onPlay: playback.isCurrent
                      ? toggle
                      : () => _openFile(track, queueItems: tracks),
                  dense: true,
                ),
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
          final index = indexById[id];
          if (index != null) _openFile(tracks[index], queueItems: tracks);
        },
        onContextMenu: (id, position) {
          final index = indexById[id];
          if (index == null) return;
          showSelectionMenu(id, () {
            final items = _selectedUnifiedItems(tracks);
            return showContextMenu(
              context,
              position: position,
              groups: libraryTrackMenuGroups(
                context,
                ref,
                items: items,
                onPlay: () => _openFile(tracks[index], queueItems: tracks),
                onOpenDetails: () => _navigateToMetadataScreen(
                  tracks[index],
                  navigationItems: tracks,
                  navigationIndex: index,
                ),
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
          });
        },
      ),
    );
  }

  Widget _buildTrackItem(
    BuildContext context,
    DownloadHistoryItem track,
    List<DownloadHistoryItem> navigationItems,
    int navigationIndex,
  ) {
    final subtitle = Text(
      track.artistName,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
    return _TrackPlaybackBuilder(
      playbackKey: _playbackKey(track),
      builder: (context, playback, toggle) => AlbumTrackTile(
        trackNumber: track.trackNumber,
        trackName: track.trackName,
        subtitle: subtitle,
        isSelectionMode: isSelectionMode,
        isSelected: selectedIds.contains(track.id),
        isCurrent: playback.isCurrent,
        isPlaying: playback.isPlaying,
        onToggleSelection: () => toggleSelection(track.id),
        onOpen: () => _navigateToMetadataScreen(
          track,
          navigationItems: navigationItems,
          navigationIndex: navigationIndex,
        ),
        onEnterSelectionMode: () => enterSelectionMode(track.id),
        onPlay: playback.isCurrent
            ? toggle
            : () => _openFile(track, queueItems: navigationItems),
      ),
    );
  }

  Future<void> _reEnrichSelected(List<DownloadHistoryItem> allTracks) async {
    await reEnrichLibraryTracks(
      context,
      ref,
      _selectedUnifiedItems(allTracks),
      isActive: () => mounted,
      onSelectionHide: () async {
        setState(() => isSelectionMode = false);
        await Future<void>.delayed(const Duration(milliseconds: 300));
      },
      onSelectionRestore: () => setState(() => isSelectionMode = true),
      onComplete: () {
        _onEmbeddedCoverChanged();
        exitSelectionMode();
      },
    );
  }

  List<UnifiedLibraryItem> _selectedUnifiedItems(
    List<DownloadHistoryItem> tracks,
  ) {
    final tracksById = {for (final t in tracks) t.id: t};
    return [
      for (final t in selectedIds.map((id) => tracksById[id]))
        if (t != null) UnifiedLibraryItem.fromDownloadHistory(t),
    ];
  }

  Widget _buildSelectionBottomBar(
    List<DownloadHistoryItem> tracks,
    double bottomPadding,
  ) {
    final allSelected =
        selectedIds.length == tracks.length && tracks.isNotEmpty;

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
        items: _selectedUnifiedItems(tracks),
        onClose: exitSelectionMode,
      ),
      onReEnrich: () => _reEnrichSelected(tracks),
      onConvert: () => showBatchConvertSheet(
        context,
        ref,
        _selectedUnifiedItems(tracks),
        onExitSelectionMode: exitSelectionMode,
      ),
      onReplayGain: ({required remove}) => runBatchReplayGain(
        context,
        _selectedUnifiedItems(tracks),
        onExitSelectionMode: exitSelectionMode,
        remove: remove,
      ),
      onDelete: () => _deleteSelected(tracks),
    );
  }
}

/// Builds one track's row from its playback state, so a track change
/// rebuilds only the rows involved. [builder] gets a callback that pauses or
/// resumes the current track.
class _TrackPlaybackBuilder extends ConsumerWidget {
  const _TrackPlaybackBuilder({
    required this.playbackKey,
    required this.builder,
  });

  final PlaybackRowKey playbackKey;
  final Widget Function(
    BuildContext context,
    MediaPlaybackUi playback,
    VoidCallback toggle,
  )
  builder;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final playback = ref.watch(mediaItemPlaybackUiProvider(playbackKey));
    return builder(
      context,
      playback,
      () => ref
          .read(musicPlayerControllerProvider)
          .togglePlayPause(playback.isPlaying),
    );
  }
}
