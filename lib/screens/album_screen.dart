import 'package:flutter/material.dart';
import 'package:mornye/theme/app_tokens.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/theme/cover_palette.dart';
import 'package:mornye/widgets/collection_scaffold.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:mornye/services/cover_cache_manager.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/download_queue_provider.dart';
import 'package:mornye/providers/extension_provider.dart';
import 'package:mornye/providers/recent_access_provider.dart';
import 'package:mornye/services/platform_bridge.dart';
import 'package:mornye/utils/image_cache_utils.dart';
import 'package:mornye/utils/string_utils.dart';
import 'package:mornye/utils/cover_art_utils.dart';
import 'package:mornye/controllers/clickable_metadata.dart';
import 'package:mornye/controllers/collapsing_header_scroll_mixin.dart';
import 'package:mornye/controllers/selection_mode_mixin.dart';
import 'package:mornye/controllers/track_history_snapshot.dart';
import 'package:mornye/widgets/error_card.dart';
import 'package:mornye/widgets/album_detail_header.dart';
import 'package:mornye/widgets/collection_header_actions.dart';
import 'package:mornye/widgets/album_description.dart';
import 'package:mornye/utils/editorial_notes.dart';
import 'package:mornye/utils/adaptive_layout.dart';
import 'package:mornye/utils/provider_resource_ids.dart';
import 'package:mornye/utils/ttl_cache.dart';
import 'package:mornye/widgets/animation_utils.dart';
import 'package:mornye/widgets/playlist_picker_sheet.dart';
import 'package:mornye/widgets/cross_extension_share_sheet.dart';
import 'package:mornye/widgets/link/link_actions.dart';
import 'package:mornye/widgets/track_list_tile.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:mornye/widgets/desktop/detail_header.dart';
import 'package:mornye/widgets/desktop/desktop_selection.dart';
import 'package:mornye/widgets/desktop/track_list_table.dart';
import 'package:mornye/widgets/audio_quality_badges.dart';
import 'package:mornye/widgets/motion_header_banner.dart';
import 'package:mornye/widgets/track_detail_actions.dart';
import 'package:mornye/widgets/selection_action_button.dart';
import 'package:mornye/widgets/collection_suggestions_section.dart';
import 'package:mornye/widgets/downloadable_cover.dart';
import 'package:mornye/widgets/disc_separator_chip.dart';
import 'package:mornye/widgets/mornye_artist_header.dart';

class _AlbumCache {
  static final _cache = TtlCache<({List<Track> tracks, String? description})>(
    const Duration(minutes: 10),
    maxEntries: 40,
  );

  static ({List<Track> tracks, String? description})? get(String key) =>
      _cache.get(key);

  static void set(String key, List<Track> tracks, String? description) =>
      _cache.set(key, (tracks: tracks, description: description));
}

class AlbumScreen extends ConsumerStatefulWidget {
  final String albumId;
  final String albumName;
  final String? coverUrl;
  final String? headerVideoUrl;
  final String? headerImageUrl;
  final List<String>? audioTraits;
  final List<Track>? tracks;
  final String? extensionId;
  final String? artistId;
  final String? artistName;
  final String? description;

  const AlbumScreen({
    super.key,
    required this.albumId,
    required this.albumName,
    this.coverUrl,
    this.headerVideoUrl,
    this.headerImageUrl,
    this.audioTraits,
    this.tracks,
    this.extensionId,
    this.artistId,
    this.artistName,
    this.description,
  });

  @override
  ConsumerState<AlbumScreen> createState() => _AlbumScreenState();
}

class _AlbumScreenState extends ConsumerState<AlbumScreen>
    with
        SelectionModeMixin<AlbumScreen>,
        CollapsingHeaderScrollMixin<AlbumScreen> {
  final _historySnapshot = TrackHistorySnapshot();
  List<Track>? _tracks;
  bool _isLoading = false;
  String? _error;
  String? _artistId;
  String? _albumType;
  int? _albumTotalTracks;
  String? _headerVideoUrl;
  String? _headerImageUrl;
  List<String> _audioTraits = const [];
  String? _description;

  /// Double click and Enter actions of the desktop table rows, by row id.
  final Map<String, VoidCallback> _desktopActivations = {};

  String get _cacheKey =>
      '${_effectiveMetadataProviderIdFromAlbumId()}:${widget.albumId}';

  String _effectiveMetadataProviderIdFromAlbumId() {
    if (widget.extensionId != null && widget.extensionId!.isNotEmpty) {
      return widget.extensionId!;
    }
    return resolveEffectiveMetadataProvider(
      legacyProviderIdFromResourceId(widget.albumId) ?? 'spotify',
      ref.read(extensionProvider),
    );
  }

  @override
  void initState() {
    super.initState();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      final providerId = _effectiveMetadataProviderIdFromAlbumId();
      ref
          .read(recentAccessProvider.notifier)
          .recordAlbumAccess(
            id: widget.albumId,
            name: widget.albumName,
            artistName:
                widget.artistName ??
                widget.tracks?.firstOrNull?.albumArtist ??
                widget.tracks?.firstOrNull?.artistName,
            imageUrl: widget.coverUrl,
            providerId: providerId,
          );
    });

    final cached = _AlbumCache.get(_cacheKey);
    _description = widget.description ?? cached?.description;
    if (widget.tracks != null && widget.tracks!.isNotEmpty) {
      _tracks = widget.tracks;
    } else {
      _tracks = cached?.tracks;
    }
    _artistId = widget.artistId;
    _albumType = _tracks?.firstOrNull?.albumType;
    _albumTotalTracks = _tracks?.firstOrNull?.totalTracks;
    _headerVideoUrl = widget.headerVideoUrl;
    _headerImageUrl = widget.headerImageUrl;
    _audioTraits = widget.audioTraits ?? const [];

    if (_tracks == null || _tracks!.isEmpty) {
      _fetchTracks();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    DetailPage.mark(
      context,
      DetailPage.album(widget.albumId, providerId: widget.extensionId),
    );
  }

  Future<void> _fetchTracks() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      final directProviderId = _directMetadataProviderId();
      if (directProviderId != null) {
        final metadata = await PlatformBridge.getProviderMetadata(
          directProviderId,
          'album',
          _metadataResourceId(directProviderId),
        );
        _applyAlbumMetadata(
          (metadata['track_list'] ?? metadata['tracks']) as List<dynamic>,
          metadata['album_info'] as Map<String, dynamic>? ?? metadata,
        );
        return;
      } else {
        final url = 'https://open.spotify.com/album/${widget.albumId}';
        final result = await PlatformBridge.handleURLWithExtension(url);
        if (result == null || result['tracks'] == null) {
          throw StateError('Failed to load album metadata from extension');
        }

        _applyAlbumMetadata(
          result['tracks'] as List<dynamic>,
          result['album'] as Map<String, dynamic>?,
          fallbackSource: result,
        );
        return;
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = context.friendlyError(e);
          _isLoading = false;
        });
      }
    }
  }

  /// Parses tracks + header metadata from either the direct-provider payload
  /// (`albumInfo` only) or the extension payload (`albumInfo` falling back to
  /// top-level [fallbackSource] keys), then updates state and the TTL cache.
  void _applyAlbumMetadata(
    List<dynamic> trackList,
    Map<String, dynamic>? albumInfo, {
    Map<String, dynamic>? fallbackSource,
  }) {
    final artistId = (albumInfo?['artist_id'] ?? albumInfo?['artistId'])
        ?.toString();
    final albumType = normalizeOptionalString(
      albumInfo?['album_type']?.toString(),
    );
    final totalTracks = albumInfo?['total_tracks'] as int?;
    final headerVideo =
        (albumInfo?['header_video'] ?? fallbackSource?['header_video'])
            ?.toString();
    final headerImage =
        (albumInfo?['header_image'] ?? fallbackSource?['header_image'])
            ?.toString();
    final audioTraits =
        ((albumInfo?['audio_traits'] ?? fallbackSource?['audio_traits'])
                as List?)
            ?.map((e) => e.toString())
            .toList();
    final tracks = trackList
        .map(
          (t) => _parseTrack(
            t as Map<String, dynamic>,
            albumTypeFallback: albumType,
            totalTracksFallback: totalTracks,
          ).copyWith(headerVideoUrl: normalizeRemoteHttpUrl(headerVideo)),
        )
        .toList();

    final description =
        albumDescriptionFromMetadata(albumInfo) ??
        albumDescriptionFromMetadata(fallbackSource);
    _AlbumCache.set(_cacheKey, tracks, description);

    if (mounted) {
      setState(() {
        _tracks = tracks;
        _description = description;
        _artistId = artistId;
        _albumType = albumType;
        _albumTotalTracks = totalTracks;
        _headerVideoUrl = (headerVideo != null && headerVideo.isNotEmpty)
            ? headerVideo
            : _headerVideoUrl;
        _headerImageUrl = (headerImage != null && headerImage.isNotEmpty)
            ? headerImage
            : _headerImageUrl;
        _audioTraits = (audioTraits != null && audioTraits.isNotEmpty)
            ? audioTraits
            : _audioTraits;
        _error = null;
        _isLoading = false;
      });
    }
  }

  String? _directMetadataProviderId() {
    final providerId = _effectiveMetadataProviderIdFromAlbumId();
    return providerId.isEmpty ? null : providerId;
  }

  String _metadataResourceId(String providerId) {
    return stripPrefixedResourceId(widget.albumId);
  }

  static final _qualitySeparators = RegExp(r'[\s_-]+');
  static final _releaseYearPattern = RegExp(r'(\d{4})');

  static (String, bool?) _qualitySignature(Track track) => (
    (track.audioQuality ?? '').trim().toLowerCase().replaceAll(
      _qualitySeparators,
      '',
    ),
    (track.audioModes?.trim().isEmpty ?? true) ? null : track.isDolbyAtmos,
  );

  Track? _commonQualityTrack(List<Track> tracks) {
    final counts = <(String, bool?), int>{};
    for (final track in tracks) {
      final signature = _qualitySignature(track);
      if (signature.$1.isEmpty && signature.$2 != true) continue;
      counts.update(signature, (count) => count + 1, ifAbsent: () => 1);
    }
    // A strict majority avoids choosing an arbitrary baseline for mixed albums.
    // Unknown metadata counts towards the total, but never implies a quality.
    for (final track in tracks) {
      if ((counts[_qualitySignature(track)] ?? 0) > tracks.length / 2) {
        return track;
      }
    }
    return null;
  }

  List<Widget> _audioTraitInline({Track? commonQualityTrack}) {
    final traits = _audioTraits
        .map((t) => t.toLowerCase().trim())
        .where((t) => t.isNotEmpty)
        .toSet();
    bool has(List<String> keys) => keys.any(traits.contains);

    final items = <Widget>[];
    if ((commonQualityTrack == null
            ? null
            : _qualitySignature(commonQualityTrack).$2) ??
        has(['atmos', 'dolby_atmos', 'dolby-atmos'])) {
      items.add(
        Builder(
          builder: (context) => DolbyAtmosLogo(
            color: HeaderPalette.of(context).onSurface,
            size: const Size(18, 12),
          ),
        ),
      );
    } else if (has(['spatial'])) {
      items.add(HeaderMetaItem('Spatial Audio', icon: Icons.surround_sound));
    }

    if (has(['hi-res-lossless', 'hi_res_lossless', 'hires-lossless'])) {
      items.add(HeaderMetaItem('Hi-Res Lossless', icon: Icons.graphic_eq));
    } else if (has(['lossless'])) {
      items.add(HeaderMetaItem('Lossless', icon: Icons.graphic_eq));
    }

    final quality = commonQualityTrack?.audioQuality?.trim();
    if (quality != null &&
        quality.isNotEmpty &&
        !items.whereType<HeaderMetaItem>().any(
          (item) => item.label.toLowerCase() == quality.toLowerCase(),
        )) {
      items.add(HeaderMetaItem(quality));
    }

    return items;
  }

  Widget _buildHeaderMeta(
    BuildContext context,
    String? releaseDate,
    Track? commonQualityTrack,
  ) {
    final items = <Widget>[];

    final genre = _tracks?.firstOrNull?.genre?.trim();
    if (context.isMornye && genre != null && genre.isNotEmpty) {
      items.add(HeaderMetaItem(genre));
    }
    final year = _releaseYear(releaseDate);
    if (year != null) items.add(HeaderMetaItem(year));
    items.addAll(_audioTraitInline(commonQualityTrack: commonQualityTrack));

    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 20),
      child: HeaderMetaRow(items: items),
    );
  }

  String? _releaseYear(String? date) {
    if (date == null || date.isEmpty) return null;
    final match = _releaseYearPattern.firstMatch(date);
    return match?.group(1);
  }

  Track _parseTrack(
    Map<String, dynamic> data, {
    String? albumTypeFallback,
    int? totalTracksFallback,
  }) {
    return Track(
      id: data['spotify_id'] as String? ?? '',
      name: data['name'] as String? ?? '',
      artistName: data['artists'] as String? ?? '',
      albumName: data['album_name'] as String? ?? '',
      albumArtist: data['album_artist'] as String?,
      artistId:
          (data['artist_id'] ?? data['artistId'])?.toString() ?? _artistId,
      albumId: data['album_id']?.toString() ?? widget.albumId,
      coverUrl: normalizeCoverReference(data['images']?.toString()),
      isrc: data['isrc'] as String?,
      duration: ((data['duration_ms'] as int? ?? 0) / 1000).round(),
      trackNumber: data['track_number'] as int?,
      discNumber: data['disc_number'] as int?,
      totalDiscs: data['total_discs'] as int?,
      releaseDate: data['release_date'] as String?,
      albumType:
          normalizeOptionalString(data['album_type']?.toString()) ??
          albumTypeFallback ??
          _albumType,
      totalTracks:
          data['total_tracks'] as int? ??
          totalTracksFallback ??
          _albumTotalTracks,
      composer: data['composer']?.toString(),
      genre: data['genre']?.toString(),
      label: data['label']?.toString(),
      copyright: data['copyright']?.toString(),
      comment: data['comment']?.toString(),
      upc: normalizeOptionalString(
        (data['upc'] ?? data['barcode'])?.toString(),
      ),
      audioQuality: data['audio_quality']?.toString(),
      audioModes: data['audio_modes']?.toString(),
      previewUrl: data['preview_url']?.toString(),
      explicit: parseExplicitFlag(data['explicit']),
    );
  }

  String? _recommendedDownloadService() {
    return _directMetadataProviderId();
  }

  @override
  Widget build(BuildContext context) {
    if (context.isMornye) {
      return MornyeArtistSurface(
        imageSource:
            widget.coverUrl ?? _headerImageUrl ?? widget.headerImageUrl,
        neutralActions: true,
        child: Builder(builder: _buildPage),
      );
    }
    return _buildPage(context);
  }

  Widget _buildPage(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final tracks = _tracks ?? [];
    final commonQualityTrack = context.isMornye
        ? null
        : _commonQualityTrack(tracks);
    final pageBackgroundColor = colorScheme.surface;
    final bottomPadding = isSelectionMode
        ? MediaQuery.paddingOf(context).bottom
        : 0.0;

    final ids = [
      for (var index = 0; index < tracks.length; index++)
        _trackSelectionId(tracks[index], index),
    ];
    pruneSelection(ids.toSet());

    final scaffold = CollectionScaffold(
      scrollController: scrollController,
      isSelectionMode: isSelectionMode,
      onExitSelectionMode: exitSelectionMode,
      backgroundColor: pageBackgroundColor,
      selectionBar: _buildSelectionBottomBar(
        context,
        colorScheme,
        tracks,
        ids,
        bottomPadding,
      ),
      appBar: _buildAppBar(
        context,
        colorScheme,
        pageBackgroundColor,
        commonQualityTrack,
      ),
      slivers: [
        if (_description != null)
          SliverToBoxAdapter(
            child: AlbumDescription(
              title: widget.albumName,
              description: _description!,
            ),
          ),
        if (_isLoading)
          // The skeleton rows carry the list's own inset.
          const SliverToBoxAdapter(
            child: AlbumTrackListSkeleton(itemCount: 10),
          ),
        if (_error != null)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: ErrorCard(
                error: _error!,
                colorScheme: colorScheme,
                onRetry: _fetchTracks,
              ),
            ),
          ),
        if (!_isLoading && _error == null && tracks.isNotEmpty) ...[
          _buildTrackList(context, colorScheme, tracks, commonQualityTrack),
          _buildAlbumFooter(context, colorScheme, tracks),
          if (!isSelectionMode)
            CollectionSuggestionsSliver(
              collectionKey: 'album:${widget.extensionId}:${widget.albumId}',
              tracks: tracks,
            ),
        ],
      ],
    );
    return DesktopListScope(
      onSelectAll: ids.isEmpty ? null : () => selectAll(ids),
      onClearSelection: isSelectionMode ? exitSelectionMode : null,
      onActivate: () => _desktopActivations[selectionAnchorId]?.call(),
      child: scaffold,
    );
  }

  Widget _buildAppBar(
    BuildContext context,
    ColorScheme colorScheme,
    Color pageBackgroundColor,
    Track? commonQualityTrack,
  ) {
    final tracks = _tracks ?? [];
    final artistName =
        widget.artistName ??
        (tracks.isNotEmpty
            ? (tracks.first.albumArtist ?? tracks.first.artistName)
            : null);
    final releaseDate = tracks.isNotEmpty ? tracks.first.releaseDate : null;

    final motionUrl = _headerVideoUrl ?? widget.headerVideoUrl;
    final hasMotion =
        motionUrl != null &&
        motionUrl.trim().isNotEmpty &&
        Uri.tryParse(motionUrl)?.hasAuthority == true;
    final coverThumbUrl = widget.coverUrl ?? _headerImageUrl;
    final showSquareCover = context.isMornye || !hasMotion;
    final expandedHeight = calculateExpandedHeight(context);
    final cacheWidth = coverCacheWidthForViewport(context);
    final headerBgUrl =
        _headerImageUrl ?? widget.headerImageUrl ?? widget.coverUrl;
    Widget headerBgImage() => headerBgUrl != null
        ? CachedNetworkImage(
            imageUrl: highResCoverUrl(headerBgUrl) ?? headerBgUrl,
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

    final Widget background = hasMotion
        ? MotionHeaderBanner(videoUrl: motionUrl, fallback: headerBgImage())
        : headerBgImage();

    return AlbumDetailHeader(
      title: widget.albumName,
      immersive: context.isMornye,
      squareArtwork: !hasMotion && headerBgUrl == coverThumbUrl,
      expandedHeight: expandedHeight,
      showTitleInAppBar: false,
      showTitleListenable: showTitleNotifier,
      backgroundColor: pageBackgroundColor,
      background: background,
      paletteSource: coverThumbUrl,
      blurAndScrimBackground: showSquareCover,
      coverBuilder: showSquareCover
          ? (context, coverSize) => context.isMornye && hasMotion
                ? background
                : coverThumbUrl != null
                ? DownloadableCover(
                    coverUrl: highResCoverUrl(coverThumbUrl) ?? coverThumbUrl,
                    baseName: [
                      if (artistName != null && artistName.isNotEmpty)
                        artistName,
                      widget.albumName,
                    ].join(' - '),
                    child: CachedNetworkImage(
                      imageUrl: highResCoverUrl(coverThumbUrl) ?? coverThumbUrl,
                      fit: BoxFit.cover,
                      width: coverSize,
                      height: coverSize,
                      memCacheWidth: cacheWidth,
                      cacheManager: CoverCacheManager.instance,
                      placeholder: (_, _) =>
                          Container(color: colorScheme.surfaceContainerHighest),
                      errorWidget: (_, _, _) => Container(
                        color: colorScheme.surfaceContainerHighest,
                        child: Icon(
                          Icons.album,
                          size: 48,
                          color: colorScheme.onSurfaceVariant,
                        ),
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
                  )
          : null,
      subtitle: (artistName != null && artistName.isNotEmpty)
          // Built inside the header, so desktop reads its artwork scheme.
          ? Builder(
              builder: (header) => ClickableArtistName(
                artistName: artistName,
                artistId: _artistId,
                coverUrl: widget.coverUrl,
                extensionId: widget.extensionId,
                style: isDesktopPlatform
                    ? desktopDetailSubtitleStyle(header)
                    : TextStyle(
                        color: colorScheme.primary,
                        fontSize: context.tokens.headerSubtitleSize,
                        fontWeight: context.isMornye
                            ? FontWeight.w400
                            : FontWeight.w600,
                      ),
                textAlign: TextAlign.center,
              ),
            )
          : null,
      meta: _buildHeaderMeta(context, releaseDate, commonQualityTrack),
      actions: isSelectionMode
          ? null
          : CollectionHeaderActions(
              tracks: tracks,
              onLoveAll: () => loveAllTracks(this.context, ref, tracks),
              downloadIcon: Icons.download,
              onDownloadAll: () => _downloadAll(context),
              addToPlaylistIcon: Icons.add,
              onAddToPlaylist: () =>
                  showAddTracksToPlaylistSheet(context, ref, tracks),
            ),
      appBarTitle: isSelectionMode
          ? context.l10n.selectionSelected(selectedIds.length)
          : null,
      leading: isSelectionMode
          ? HeaderCircleButton(
              icon: Icons.close,
              tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
              onPressed: exitSelectionMode,
            )
          : null,
      appBarActions: isSelectionMode
          ? const []
          : [
              if (ref.watch(linkPhoneClientProvider) != null)
                LinkDownloadOnDesktopButton(
                  tracks: tracks,
                  service: _recommendedDownloadService(),
                ),
              HeaderCircleButton(
                icon: Icons.open_in_new_rounded,
                tooltip: context.l10n.openInOtherServices,
                onPressed: () => _showShareSheet(context, tracks, artistName),
              ),
            ],
    );
  }

  Widget _buildAlbumFooter(
    BuildContext context,
    ColorScheme colorScheme,
    List<Track> tracks,
  ) => buildTrackListFooter(context, colorScheme, tracks);

  Widget _buildTrackList(
    BuildContext context,
    ColorScheme colorScheme,
    List<Track> tracks,
    Track? commonQualityTrack,
  ) {
    _historySnapshot.update(tracks);
    final historyLookups = _historySnapshot.lookups;
    final existingHistoryKeys = ref.watch(
      downloadHistoryVisibleBatchExistsProvider(_historySnapshot.request),
    );
    int discNumber(Track track) {
      final number = track.discNumber ?? 1;
      return number > 0 ? number : 1;
    }

    final hasMultipleDiscs = tracks.any(
      (track) => discNumber(track) > 1 || (track.totalDiscs ?? 1) > 1,
    );
    if (isDesktopPlatform) {
      final ids = [
        for (var i = 0; i < tracks.length; i++) _trackSelectionId(tracks[i], i),
      ];
      final inHistory = [
        for (final lookup in historyLookups)
          existingHistoryKeys.contains(lookup.lookupKey),
      ];
      void activate(int index) => TrackListTile.activate(
        context,
        ref,
        tracks[index],
        isInHistory: inHistory[index],
        onDownload: ({bool forceQualityPicker = false}) => _downloadTrack(
          context,
          tracks[index],
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
        albumLayout: context.isMornye,
        albumArtist:
            widget.artistName ??
            (tracks.isEmpty
                ? null
                : (tracks.first.albumArtist ?? tracks.first.artistName)),
      );
    }
    return SliverPadding(
      padding: EdgeInsets.symmetric(horizontal: wideListInset(context)),
      sliver: SliverList(
        delegate: SliverChildBuilderDelegate((context, index) {
          final track = tracks[index];
          final selectionId = _trackSelectionId(track, index);
          final isInHistory = existingHistoryKeys.contains(
            historyLookups[index].lookupKey,
          );
          final row = KeyedSubtree(
            key: ValueKey(selectionId),
            child: StaggeredListItem(
              index: index,
              child: TrackListTile(
                track: track,
                isInHistory: isInHistory,
                onDownload: ({bool forceQualityPicker = false}) =>
                    _downloadTrack(
                      context,
                      track,
                      forceQualityPicker: forceQualityPicker,
                    ),
                clickableArtist: true,
                showQualityBadges: context.isMornye
                    ? !_audioTraits.any(
                        (trait) => trait.toLowerCase().contains('lossless'),
                      )
                    : commonQualityTrack == null ||
                          _qualitySignature(track) !=
                              _qualitySignature(commonQualityTrack),
                isSelectionMode: isSelectionMode,
                isSelected: selectedIds.contains(selectionId),
                onToggleSelection: () => toggleSelection(selectionId),
                onEnterSelectionMode: () => enterSelectionMode(selectionId),
                leading: SizedBox(
                  width: 32,
                  child: Center(
                    child: Text(
                      '${track.trackNumber ?? 0}',
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
          final disc = discNumber(track);
          if (hasMultipleDiscs &&
              (index == 0 || discNumber(tracks[index - 1]) != disc)) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                DiscSeparatorChip(discNumber: disc),
                row,
              ],
            );
          }
          return row;
        }, childCount: tracks.length),
      ),
    );
  }

  String _trackSelectionId(Track track, int index) =>
      '$index|${track.discNumber ?? 0}|${track.trackNumber ?? 0}|'
      '${track.id}|${track.name}';

  List<Track> _selectedTracks(List<Track> tracks) => [
    for (var index = 0; index < tracks.length; index++)
      if (selectedIds.contains(_trackSelectionId(tracks[index], index)))
        tracks[index],
  ];

  Widget _buildSelectionBottomBar(
    BuildContext barContext,
    ColorScheme colorScheme,
    List<Track> tracks,
    List<String> ids,
    double bottomPadding,
  ) {
    final selectedCount = selectedIds.length;
    return buildSelectionBar(
      ids: ids,
      bottomPadding: bottomPadding,
      children: [
        SizedBox(
          width: double.infinity,
          child: SelectionActionButton(
            icon: Icons.playlist_add,
            label: barContext.l10n.collectionAddToPlaylist,
            colorScheme: colorScheme,
            onPressed: selectedCount == 0
                ? null
                : () {
                    final selected = _selectedTracks(tracks);
                    exitSelectionMode();
                    showAddTracksToPlaylistSheet(context, ref, selected);
                  },
          ),
        ),
        const SizedBox(height: 8),
        SizedBox(
          width: double.infinity,
          child: SelectionActionButton(
            icon: Icons.download_rounded,
            label: '${barContext.l10n.dialogDownload} ($selectedCount)',
            onPressed: selectedCount == 0
                ? null
                : () => _downloadSelected(context, tracks),
            colorScheme: colorScheme,
          ),
        ),
      ],
    );
  }

  Future<void> _downloadSelected(
    BuildContext context,
    List<Track> tracks,
  ) async {
    final selectedTracks = _selectedTracks(tracks);
    if (selectedTracks.isEmpty) return;

    await queueTracksSkippingDownloaded(
      context,
      ref,
      selectedTracks,
      artistNameForPicker: widget.albumName,
      recommendedService: _recommendedDownloadService(),
      forceQualityPicker: true,
      onQueued: exitSelectionMode,
    );
  }

  void _downloadTrack(
    BuildContext context,
    Track track, {
    bool forceQualityPicker = false,
  }) {
    downloadSingleTrack(
      context,
      ref,
      track,
      recommendedService: _recommendedDownloadService(),
      forceQualityPicker: forceQualityPicker,
    );
  }

  Future<void> _downloadAll(BuildContext context) async {
    final tracks = _tracks;
    if (tracks == null || tracks.isEmpty) return;
    await queueTracksSkippingDownloaded(
      context,
      ref,
      tracks,
      artistNameForPicker: widget.albumName,
      recommendedService: _recommendedDownloadService(),
    );
  }

  void _showShareSheet(
    BuildContext context,
    List<Track> tracks,
    String? artistName,
  ) {
    final sourceExtensionId = _directMetadataProviderId() ?? '';
    final resolvedArtists =
        artistName ??
        tracks.firstOrNull?.albumArtist ??
        tracks.firstOrNull?.artistName ??
        '';

    CrossExtensionShareSheet.show(
      context,
      name: widget.albumName,
      artists: resolvedArtists,
      type: 'album',
      sourceExtensionId: sourceExtensionId,
    );
  }
}
