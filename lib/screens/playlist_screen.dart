import 'package:flutter/material.dart';
import 'package:mornye/screens/track_history_snapshot.dart';
import 'package:mornye/widgets/album_detail_header.dart';
import 'package:mornye/widgets/collection_header_actions.dart';
import 'package:mornye/screens/selection_mode_mixin.dart';
import 'package:mornye/widgets/collection_scaffold.dart';
import 'package:mornye/widgets/selection_bottom_bar.dart';
import 'package:mornye/widgets/selection_action_button.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/services/platform_bridge.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/download_queue_provider.dart';
import 'package:mornye/providers/extension_provider.dart';
import 'package:mornye/utils/image_cache_utils.dart';
import 'package:mornye/utils/cover_art_utils.dart';
import 'package:mornye/utils/adaptive_layout.dart';
import 'package:mornye/utils/provider_resource_ids.dart';
import 'package:mornye/widgets/playlist_picker_sheet.dart';
import 'package:mornye/widgets/animation_utils.dart';
import 'package:mornye/widgets/cached_cover_image.dart';
import 'package:mornye/widgets/motion_header_banner.dart';
import 'package:mornye/widgets/track_list_tile.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:mornye/widgets/desktop/desktop_selection.dart';
import 'package:mornye/widgets/desktop/track_list_table.dart';
import 'package:mornye/widgets/track_detail_actions.dart';
import 'package:mornye/controllers/collapsing_header_scroll_mixin.dart';
import 'package:mornye/widgets/error_card.dart';
import 'package:mornye/widgets/downloadable_cover.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/widgets/mornye_artist_header.dart';

class PlaylistScreen extends ConsumerStatefulWidget {
  final String playlistName;
  final String? coverUrl;
  final String? headerVideoUrl;
  final List<Track> tracks;
  final String? playlistId;
  final String? metadataProviderId;
  final String? recommendedService;

  const PlaylistScreen({
    super.key,
    required this.playlistName,
    this.coverUrl,
    this.headerVideoUrl,
    required this.tracks,
    this.playlistId,
    this.metadataProviderId,
    this.recommendedService,
  });

  @override
  ConsumerState<PlaylistScreen> createState() => _PlaylistScreenState();
}

class _PlaylistScreenState extends ConsumerState<PlaylistScreen>
    with
        SelectionModeMixin<PlaylistScreen>,
        CollapsingHeaderScrollMixin<PlaylistScreen> {
  final _historySnapshot = TrackHistorySnapshot();

  /// Double click and Enter actions of the desktop table rows, by row id.
  final Map<String, VoidCallback> _desktopActivations = {};
  List<Track>? _fetchedTracks;
  bool _isLoading = false;
  String? _error;
  String? _resolvedPlaylistName;
  String? _resolvedCoverUrl;
  String? _resolvedHeaderVideoUrl;

  List<Track> get _tracks => _fetchedTracks ?? widget.tracks;
  String get _playlistName => _resolvedPlaylistName ?? widget.playlistName;
  String? get _coverUrl => _resolvedCoverUrl ?? widget.coverUrl;
  String? get _headerVideoUrl =>
      _resolvedHeaderVideoUrl ?? widget.headerVideoUrl;

  /// Playlists can legitimately contain the same track twice, so selection is
  /// keyed by position as well as id (matching the album screen).
  String _trackSelectionId(Track track, int index) => '${track.id}#$index';

  List<Track> get _selectedTracks => [
    for (var index = 0; index < _tracks.length; index++)
      if (selectedIds.contains(_trackSelectionId(_tracks[index], index)))
        _tracks[index],
  ];

  Widget _buildSelectionBottomBar(
    BuildContext context,
    ColorScheme colorScheme,
    double bottomPadding,
  ) {
    final selectedCount = selectedIds.length;
    final allSelected = _tracks.isNotEmpty && selectedCount == _tracks.length;

    return SelectionBottomBar(
      selectedCount: selectedCount,
      allSelected: allSelected,
      onClose: exitSelectionMode,
      onToggleSelectAll: () {
        if (allSelected) {
          exitSelectionMode();
        } else {
          selectAll([
            for (var index = 0; index < _tracks.length; index++)
              _trackSelectionId(_tracks[index], index),
          ]);
        }
      },
      bottomPadding: bottomPadding,
      children: [
        SizedBox(
          width: double.infinity,
          child: SelectionActionButton(
            icon: Icons.download_rounded,
            label: '${context.l10n.dialogDownload} ($selectedCount)',
            onPressed: selectedCount == 0 ? null : _downloadSelected,
            colorScheme: colorScheme,
          ),
        ),
      ],
    );
  }

  Future<void> _downloadSelected() async {
    final selected = _selectedTracks;
    if (selected.isEmpty) return;
    await queueTracksSkippingDownloaded(
      context,
      ref,
      selected,
      artistNameForPicker: _playlistName,
      recommendedService: widget.recommendedService,
      forceQualityPicker: true,
      onQueued: exitSelectionMode,
    );
  }

  String? _metadataProviderId(String playlistId) {
    final providerId = resolvePreferredMetadataProviderId(
      widget.metadataProviderId,
      playlistId,
    );
    if (providerId == null) return null;
    final effective = resolveEffectiveMetadataProvider(
      providerId,
      ref.read(extensionProvider),
    );
    return effective.isEmpty ? null : effective;
  }

  String _metadataResourceId(String providerId, String playlistId) {
    return stripPrefixedResourceId(playlistId);
  }

  String? _recommendedDownloadService() {
    final explicit = widget.recommendedService;
    if (explicit != null && explicit.isNotEmpty) {
      return explicit;
    }

    final playlistId = widget.playlistId;
    if (playlistId != null) {
      final providerId = _metadataProviderId(playlistId);
      if (providerId != null && providerId.isNotEmpty) {
        return resolveEffectiveDownloadService(
          providerId,
          ref.read(extensionProvider),
        );
      }
    }

    final source = _tracks.firstOrNull?.source;
    if (source != null && source.isNotEmpty) {
      return source;
    }

    final trackId = _tracks.firstOrNull?.id ?? '';
    final trackProviderId = legacyProviderIdFromResourceId(trackId);
    if (trackProviderId != null) {
      return resolveEffectiveDownloadService(
        trackProviderId,
        ref.read(extensionProvider),
      );
    }
    return null;
  }

  @override
  bool get rebuildsOnTitleFlip => false;

  @override
  void initState() {
    super.initState();
    _fetchTracksIfNeeded();
  }

  Future<void> _fetchTracksIfNeeded() async {
    if (widget.tracks.isNotEmpty || widget.playlistId == null) return;

    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      String playlistId = widget.playlistId!;
      late final Map<String, dynamic> result;
      final providerId = _metadataProviderId(playlistId);
      if (providerId != null) {
        result = await PlatformBridge.getProviderMetadata(
          providerId,
          'playlist',
          _metadataResourceId(providerId, playlistId),
        );
      } else {
        result = await PlatformBridge.getProviderMetadata(
          'deezer',
          'playlist',
          playlistId,
        );
      }
      if (!mounted) return;

      final playlistInfo = result['playlist_info'] as Map<String, dynamic>?;
      final owner = playlistInfo?['owner'] as Map<String, dynamic>?;
      final resolvedPlaylistName =
          (playlistInfo?['name'] ?? owner?['name'])?.toString() ??
          _playlistName;

      final trackList = result['track_list'] as List<dynamic>? ?? [];
      final tracks = trackList
          .map(
            (t) => Track.fromBackendMap(
              t as Map<String, dynamic>,
              playlistName: resolvedPlaylistName,
            ),
          )
          .toList();

      final headerVideo = playlistInfo?['header_video']?.toString();

      setState(() {
        _fetchedTracks = tracks;
        _resolvedPlaylistName = resolvedPlaylistName;
        _resolvedCoverUrl = (playlistInfo?['images'] ?? owner?['images'])
            ?.toString();
        _resolvedHeaderVideoUrl =
            (headerVideo != null && headerVideo.isNotEmpty)
            ? headerVideo
            : _resolvedHeaderVideoUrl;
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = context.friendlyError(e);
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (context.isMornye) {
      return MornyeArtistSurface(
        imageSource: _coverUrl,
        neutralActions: true,
        child: Builder(builder: _buildPage),
      );
    }
    return _buildPage(context);
  }

  Widget _buildPage(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final bottomPadding = isSelectionMode
        ? MediaQuery.paddingOf(context).bottom
        : 0.0;

    pruneSelection({
      for (var index = 0; index < _tracks.length; index++)
        _trackSelectionId(_tracks[index], index),
    });

    return DesktopListScope(
      onSelectAll: _tracks.isEmpty
          ? null
          : () => selectAll([
              for (var index = 0; index < _tracks.length; index++)
                _trackSelectionId(_tracks[index], index),
            ]),
      onClearSelection: isSelectionMode ? exitSelectionMode : null,
      onActivate: () => _desktopActivations[selectionAnchorId]?.call(),
      child: CollectionScaffold(
        scrollController: scrollController,
        isSelectionMode: isSelectionMode,
        onExitSelectionMode: exitSelectionMode,
        selectionBar: _buildSelectionBottomBar(
          context,
          colorScheme,
          bottomPadding,
        ),
        appBar: _buildAppBar(context, colorScheme),
        slivers: [
          _buildTrackList(context, colorScheme),
          _buildPlaylistFooter(context, colorScheme),
        ],
      ),
    );
  }

  Widget _buildAppBar(BuildContext context, ColorScheme colorScheme) {
    final expandedHeight = calculateExpandedHeight(context);
    final cacheWidth = coverCacheWidthForViewport(context);
    final motionUrl = _headerVideoUrl;
    final hasMotion =
        motionUrl != null &&
        motionUrl.trim().isNotEmpty &&
        Uri.tryParse(motionUrl)?.hasAuthority == true;
    Widget playlistPlaceholder({double? size}) {
      return Container(
        color: colorScheme.surfaceContainerHighest,
        child: Icon(
          Icons.playlist_play,
          size: size ?? 80,
          color: colorScheme.onSurfaceVariant,
        ),
      );
    }

    final Widget coverImage = _coverUrl != null
        ? CachedCoverImage(
            imageUrl: highResCoverUrl(_coverUrl) ?? _coverUrl!,
            fit: BoxFit.cover,
            memCacheWidth: cacheWidth,
            placeholder: (_, _) => Container(color: colorScheme.surface),
            errorWidget: (_, _, _) => Container(color: colorScheme.surface),
          )
        : playlistPlaceholder();

    return AlbumDetailHeader(
      title: _playlistName,
      immersive: context.isMornye,
      squareArtwork: !hasMotion,
      expandedHeight: expandedHeight,
      showTitleInAppBar: false,
      showTitleListenable: showTitleNotifier,
      background: hasMotion
          ? MotionHeaderBanner(videoUrl: motionUrl, fallback: coverImage)
          : coverImage,
      paletteSource: _coverUrl,
      blurAndScrimBackground: !hasMotion && _coverUrl != null,
      coverBuilder: hasMotion
          ? null
          : (context, coverSize) => _coverUrl != null
                ? DownloadableCover(
                    coverUrl: highResCoverUrl(_coverUrl) ?? _coverUrl,
                    baseName: _playlistName,
                    child: CachedCoverImage(
                      imageUrl: highResCoverUrl(_coverUrl) ?? _coverUrl!,
                      fit: BoxFit.cover,
                      memCacheWidth: cacheWidth,
                      placeholder: (_, _) => playlistPlaceholder(),
                      errorWidget: (_, _, _) => playlistPlaceholder(size: 48),
                    ),
                  )
                : playlistPlaceholder(size: 48),
      meta: HeaderMetaRow(
        items: [
          HeaderMetaItem(
            context.l10n.tracksCount(_tracks.length),
            icon: Icons.playlist_play,
          ),
        ],
      ),
      actions: CollectionHeaderActions(
        tracks: _tracks,
        onLoveAll: () => loveAllTracks(this.context, ref, _tracks),
        downloadIcon: Icons.download_rounded,
        tonalDownload: true,
        onDownloadAll: () => confirmDownloadAllDialog(
          context,
          _tracks.length,
          () => _downloadAll(context),
        ),
        addToPlaylistIcon: Icons.playlist_add,
        onAddToPlaylist: () => showAddTracksToPlaylistSheet(
          context,
          ref,
          _tracks,
          playlistNamePrefill: widget.playlistName,
          preserveOccurrences: true,
        ),
      ),
    );
  }

  Widget _buildPlaylistFooter(BuildContext context, ColorScheme colorScheme) =>
      buildTrackListFooter(
        context,
        colorScheme,
        _tracks,
        excludeEpochReleaseDate: true,
      );

  Widget _buildTrackList(BuildContext context, ColorScheme colorScheme) {
    if (_isLoading) {
      // The skeleton rows carry the list's own inset.
      return const SliverToBoxAdapter(child: TrackListSkeleton(itemCount: 8));
    }

    if (_error != null) {
      return SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: ErrorCard(
            error: _error!,
            colorScheme: colorScheme,
            onRetry: _fetchTracksIfNeeded,
          ),
        ),
      );
    }

    if (_tracks.isEmpty) {
      return SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Center(
            child: Text(
              context.l10n.errorNoTracksFound,
              style: TextStyle(color: colorScheme.onSurfaceVariant),
            ),
          ),
        ),
      );
    }

    _historySnapshot.update(_tracks);
    final historyLookups = _historySnapshot.lookups;
    final existingHistoryKeys = ref.watch(
      downloadHistoryVisibleBatchExistsProvider(_historySnapshot.request),
    );
    if (isDesktopPlatform) {
      final ids = [
        for (var i = 0; i < _tracks.length; i++)
          _trackSelectionId(_tracks[i], i),
      ];
      final inHistory = [
        for (final lookup in historyLookups)
          existingHistoryKeys.contains(lookup.lookupKey),
      ];
      final tracks = _tracks;
      void activate(int index) => TrackListTile.activate(
        context,
        ref,
        tracks[index],
        isInHistory: inHistory[index],
        onDownload: ({bool forceQualityPicker = false}) => _downloadTrack(
          context,
          tracks[index],
          playlistPosition: index + 1,
          forceQualityPicker: forceQualityPicker,
        ),
      );
      _desktopActivations
        ..clear()
        ..addAll({
          for (var i = 0; i < ids.length; i++) ids[i]: () => activate(i),
        });
      return TrackListTable(
        tracks: tracks,
        ids: ids,
        isInHistory: inHistory,
        selectedIds: selectedIds,
        onSelect: applyDesktopClick,
        onActivate: activate,
        showArtwork: true,
        showAlbum: true,
      );
    }
    return SliverPadding(
      padding: EdgeInsets.symmetric(horizontal: wideListInset(context)),
      sliver: SliverList(
        delegate: SliverChildBuilderDelegate((context, index) {
          final track = _tracks[index];
          final selectionId = _trackSelectionId(track, index);
          final isInHistory = existingHistoryKeys.contains(
            historyLookups[index].lookupKey,
          );
          return KeyedSubtree(
            key: ValueKey(track.id),
            child: StaggeredListItem(
              index: index,
              child: TrackListTile(
                track: track,
                isInHistory: isInHistory,
                isSelectionMode: isSelectionMode,
                isSelected: selectedIds.contains(selectionId),
                onToggleSelection: () => toggleSelection(selectionId),
                onEnterSelectionMode: () => enterSelectionMode(selectionId),
                onDownload: ({bool forceQualityPicker = false}) =>
                    _downloadTrack(
                      context,
                      track,
                      playlistPosition: index + 1,
                      forceQualityPicker: forceQualityPicker,
                    ),
                leadingArtwork: true,
                leading: track.coverUrl != null
                    ? DownloadableCover(
                        coverUrl: track.coverUrl,
                        baseName: '${track.artistName} - ${track.name}',
                        enabled: !isSelectionMode,
                        child: CachedCoverImage(
                          imageUrl: track.coverUrl!,
                          width: 48,
                          height: 48,
                          borderRadius: BorderRadius.circular(8),
                        ),
                      )
                    : Container(
                        width: 48,
                        height: 48,
                        decoration: BoxDecoration(
                          color: Theme.of(
                            context,
                          ).colorScheme.surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Icon(
                          Icons.music_note,
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
              ),
            ),
          );
        }, childCount: _tracks.length),
      ),
    );
  }

  void _downloadTrack(
    BuildContext context,
    Track track, {
    int? playlistPosition,
    bool forceQualityPicker = false,
  }) {
    downloadSingleTrack(
      context,
      ref,
      track,
      recommendedService: _recommendedDownloadService(),
      playlistName: _playlistName,
      playlistPosition: playlistPosition,
      forceQualityPicker: forceQualityPicker,
    );
  }

  Future<void> _downloadAll(BuildContext context) async {
    await queueTracksSkippingDownloaded(
      context,
      ref,
      _tracks,
      artistNameForPicker: _playlistName,
      recommendedService: _recommendedDownloadService(),
      playlistName: _playlistName,
      resolveDefaultService: false,
    );
  }
}
