import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/widgets/app_alert_dialog.dart';
import 'package:mornye/widgets/app_icon_button.dart';
import 'package:mornye/widgets/app_loading_indicator.dart';
import 'package:mornye/widgets/app_progress_indicator.dart';
import 'package:mornye/widgets/expressive_button.dart';
import 'package:mornye/theme/mornye_icons.dart';
import 'package:mornye/widgets/mornye_artist_header.dart';
import 'package:mornye/widgets/mornye_chrome.dart';
import 'package:mornye/widgets/album_detail_header.dart';
import 'package:mornye/theme/cover_palette.dart';
import 'package:mornye/widgets/app_bottom_sheet.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/models/artist_concert.dart';
import 'package:mornye/widgets/artist_concerts_button.dart';
import 'package:mornye/providers/extension_provider.dart';
import 'package:mornye/providers/track_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/providers/download_queue_provider.dart';
import 'package:mornye/providers/library_collections_provider.dart';
import 'package:mornye/providers/recent_access_provider.dart';
import 'package:mornye/providers/local_library_provider.dart';
import 'package:mornye/services/platform_bridge.dart';
import 'package:mornye/utils/string_utils.dart';
import 'package:mornye/utils/artist_album_sort.dart';
import 'package:mornye/utils/adaptive_layout.dart';
import 'package:mornye/utils/nav_bar_inset.dart';
import 'package:mornye/utils/provider_resource_ids.dart';
import 'package:mornye/utils/ttl_cache.dart';
import 'package:mornye/screens/album_screen.dart';
import 'package:mornye/screens/extension_collection_screens.dart'
    show ExtensionAlbumScreen;
import 'package:mornye/controllers/clickable_metadata.dart';
import 'package:mornye/controllers/local_playback.dart';
import 'package:mornye/controllers/selection_mode_mixin.dart';
import 'package:mornye/controllers/track_history_snapshot.dart';
import 'package:mornye/widgets/download_service_picker.dart';
import 'package:mornye/widgets/error_card.dart';
import 'package:mornye/widgets/selection_bottom_bar.dart';
import 'package:mornye/widgets/in_library_badge.dart';
import 'package:mornye/widgets/track_collection_quick_actions.dart';
import 'package:mornye/widgets/animation_utils.dart';
import 'package:mornye/widgets/cached_cover_image.dart';
import 'package:mornye/widgets/playlist_picker_sheet.dart';
import 'package:mornye/widgets/motion_header_banner.dart';
import 'package:mornye/widgets/cross_extension_share_sheet.dart';
import 'package:mornye/widgets/view_queue_snackbar_action.dart';
import 'package:mornye/widgets/app_snack_bar.dart';
import 'package:mornye/widgets/downloadable_cover.dart';
import 'package:mornye/widgets/expressive_button_group.dart';
import 'package:mornye/widgets/expressive_icon_button.dart';
import 'package:mornye/widgets/desktop/context_menu.dart';
import 'package:mornye/widgets/desktop/desktop_scroll_arrows.dart';
import 'package:mornye/widgets/desktop/desktop_selection.dart';
import 'package:mornye/widgets/desktop/detail_header.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:mornye/theme/app_motion.dart';
import 'package:mornye/theme/material_expressive.dart';

part 'artist_screen_widgets.dart';
part 'artist_screen_discography.dart';

class _ArtistCache {
  static final _cache = TtlCache<_CacheEntry>(
    const Duration(minutes: 10),
    maxEntries: 24,
  );

  static _CacheEntry? get(String artistId) => _cache.get(artistId);

  static void set(
    String artistId, {
    required List<ArtistAlbum> albums,
    List<ArtistAlbum>? releases,
    List<Track>? topTracks,
    List<ArtistConcert> concerts = const [],
    String? headerImageUrl,
    String? headerVideoUrl,
    String? headerLogoUrl,
    String? albumsNext,
    int? monthlyListeners,
  }) {
    _cache.set(
      artistId,
      _CacheEntry(
        albums: albums,
        releases: releases,
        topTracks: topTracks,
        concerts: concerts,
        headerImageUrl: headerImageUrl,
        headerVideoUrl: headerVideoUrl,
        headerLogoUrl: headerLogoUrl,
        albumsNext: albumsNext,
        monthlyListeners: monthlyListeners,
      ),
    );
  }
}

class _CacheEntry {
  final List<ArtistAlbum> albums;
  final List<ArtistAlbum>? releases;
  final List<Track>? topTracks;
  final List<ArtistConcert> concerts;
  final String? headerImageUrl;
  final String? headerVideoUrl;
  final String? headerLogoUrl;
  final String? albumsNext;
  final int? monthlyListeners;

  _CacheEntry({
    required this.albums,
    this.releases,
    this.topTracks,
    this.concerts = const [],
    this.headerImageUrl,
    this.headerVideoUrl,
    this.headerLogoUrl,
    this.albumsNext,
    this.monthlyListeners,
  });
}

class ArtistScreen extends ConsumerStatefulWidget {
  final String artistId;
  final String artistName;
  final String? coverUrl;
  final String? headerImageUrl;
  final String? headerVideoUrl;
  final String? headerLogoUrl;
  final String? albumsNext;
  final int? monthlyListeners;
  final List<ArtistAlbum>? albums;
  final List<Track>? topTracks;
  final List<ArtistConcert> concerts;
  final String? extensionId;

  const ArtistScreen({
    super.key,
    required this.artistId,
    required this.artistName,
    this.coverUrl,
    this.headerImageUrl,
    this.headerVideoUrl,
    this.headerLogoUrl,
    this.albumsNext,
    this.monthlyListeners,
    this.albums,
    this.topTracks,
    this.concerts = const [],
    this.extensionId,
  });

  @override
  ConsumerState<ArtistScreen> createState() => _ArtistScreenState();
}

class _ArtistScreenState extends ConsumerState<ArtistScreen>
    with SelectionModeMixin<ArtistScreen> {
  bool _isLoadingDiscography = false;
  final _historySnapshot = TrackHistorySnapshot();
  List<ArtistAlbum>? _albums;
  List<ArtistAlbum>? _releases;
  List<Track>? _topTracks;
  List<ArtistConcert> _concerts = const [];
  String? _headerImageUrl;
  String? _headerVideoUrl;
  String? _headerLogoUrl;
  String? _albumsNext;
  bool _isLoadingMoreAlbums = false;
  String? _albumsPageError;
  DateTime? _albumPageRetryAfter;
  int? _monthlyListeners;
  String? _error;

  final _showTitleInAppBar = ValueNotifier(false);
  final ScrollController _scrollController = ScrollController();
  final PageController _popularPageController = PageController();
  final SelectionOverlayController _selectionOverlay =
      SelectionOverlayController();
  int _popularCurrentPage = 0;

  bool _isFetchingDiscography = false;
  int _discographyFetchGeneration = 0;
  List<ArtistAlbum>? _albumBucketSource;
  List<ArtistAlbum> _albumsOnlyBucket = const [];
  List<ArtistAlbum> _singlesBucket = const [];
  List<ArtistAlbum> _compilationsBucket = const [];

  String? _recommendedDownloadService() {
    return _directMetadataProviderId();
  }

  String _effectiveMetadataProviderIdFromArtistId() {
    if (widget.extensionId != null && widget.extensionId!.isNotEmpty) {
      return widget.extensionId!;
    }
    return resolveEffectiveMetadataProvider(
      legacyProviderIdFromResourceId(widget.artistId) ?? 'spotify',
      ref.read(extensionProvider),
    );
  }

  String? _directMetadataProviderId() {
    final providerId = _effectiveMetadataProviderIdFromArtistId();
    return providerId.isEmpty ? null : providerId;
  }

  String _metadataResourceId(String providerId) {
    return stripPrefixedResourceId(widget.artistId);
  }

  @override
  void initState() {
    super.initState();
    _concerts = widget.concerts;

    _scrollController.addListener(_onScroll);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      final providerId = _effectiveMetadataProviderIdFromArtistId();
      ref
          .read(recentAccessProvider.notifier)
          .recordArtistAccess(
            id: widget.artistId,
            name: widget.artistName,
            imageUrl: widget.coverUrl,
            providerId: providerId,
          );
    });

    if (widget.extensionId != null) {
      _albums = widget.albums == null
          ? null
          : sortArtistAlbumsNewestFirst(widget.albums!);
      _topTracks = widget.topTracks;
      _headerImageUrl = widget.headerImageUrl;
      _headerVideoUrl = widget.headerVideoUrl;
      _headerLogoUrl = widget.headerLogoUrl;
      _albumsNext = widget.albumsNext;
      _monthlyListeners = widget.monthlyListeners;

      if ((_albums == null || _albums!.isEmpty) ||
          (_topTracks == null || _topTracks!.isEmpty)) {
        _fetchDiscography();
      }
      return;
    }

    final cached = _ArtistCache.get(widget.artistId);

    if (widget.albums != null) {
      _albums = sortArtistAlbumsNewestFirst(widget.albums!);
      _topTracks = widget.topTracks;
      _headerImageUrl = widget.headerImageUrl;
      _headerVideoUrl = widget.headerVideoUrl;
      _headerLogoUrl = widget.headerLogoUrl;
      _albumsNext = widget.albumsNext;
      _monthlyListeners = widget.monthlyListeners;

      if (_topTracks == null || _topTracks!.isEmpty) {
        _fetchDiscography();
      }
    } else if (cached != null) {
      _albums = sortArtistAlbumsNewestFirst(cached.albums);
      _releases = cached.releases == null
          ? null
          : sortArtistAlbumsNewestFirst(cached.releases!);
      _topTracks = cached.topTracks;
      _concerts = cached.concerts;
      _headerImageUrl = cached.headerImageUrl;
      _headerVideoUrl = cached.headerVideoUrl;
      _headerLogoUrl = cached.headerLogoUrl;
      _albumsNext = cached.albumsNext;
      _monthlyListeners = cached.monthlyListeners;

      if (_topTracks == null || _topTracks!.isEmpty) {
        _fetchDiscography();
      }
    } else {
      _fetchDiscography();
    }
  }

  void _onScroll() => _showTitleInAppBar.value = _scrollController.offset > 280;

  @override
  void dispose() {
    _selectionOverlay.dispose();
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    _showTitleInAppBar.dispose();
    _popularPageController.dispose();
    super.dispose();
  }

  Future<void> _fetchDiscography() async {
    setState(() {
      _isLoadingDiscography = true;
      _error = null;
    });
    try {
      List<ArtistAlbum> albums;
      List<ArtistAlbum>? releases;
      List<Track>? topTracks;
      List<ArtistConcert> concerts = const [];
      String? headerImage;
      String? headerVideo;
      String? headerLogo;
      String? albumsNext;
      int? listeners;

      if (_directMetadataProviderId() != null) {
        final providerId = _directMetadataProviderId()!;
        final artistData = await PlatformBridge.getProviderMetadata(
          providerId,
          'artist',
          _metadataResourceId(providerId),
        );
        final albumsList = artistData['albums'] as List<dynamic>? ?? [];
        albums = albumsList
            .map((a) => _parseArtistAlbum(a as Map<String, dynamic>))
            .toList();

        final releasesList = artistData['releases'] as List<dynamic>? ?? [];
        if (releasesList.isNotEmpty) {
          releases = releasesList
              .map((a) => _parseArtistAlbum(a as Map<String, dynamic>))
              .toList();
        }

        final topTracksList = artistData['top_tracks'] as List<dynamic>? ?? [];
        if (topTracksList.isNotEmpty) {
          topTracks = topTracksList
              .map((t) => _parseTrack(t as Map<String, dynamic>))
              .toList();
        }

        final artistInfo = artistData['artist_info'] as Map<String, dynamic>?;
        concerts = ArtistConcert.parseList(
          artistInfo?['concerts'] ?? artistData['concerts'],
        );
        albumsNext =
            (artistInfo?['albums_next'] ?? artistData['albums_next'])
                as String?;
        headerImage =
            artistInfo?['images'] as String? ??
            artistInfo?['header_image'] as String? ??
            artistInfo?['cover_url'] as String? ??
            artistData['header_image'] as String? ??
            artistData['cover_url'] as String? ??
            artistData['image_url'] as String?;
        headerVideo =
            artistInfo?['header_video'] as String? ??
            artistData['header_video'] as String?;
        headerLogo = normalizeRemoteHttpUrl(
          (artistInfo?['header_logo'] ?? artistData['header_logo'])?.toString(),
        );
        listeners =
            artistInfo?['listeners'] as int? ?? artistData['listeners'] as int?;
      } else {
        final url = 'https://open.spotify.com/artist/${widget.artistId}';
        final result = await PlatformBridge.handleURLWithExtension(url);

        if (result != null && result['artist'] != null) {
          final artistData = result['artist'] as Map<String, dynamic>;
          concerts = ArtistConcert.parseList(artistData['concerts']);
          albumsNext = artistData['albums_next'] as String?;
          final albumsList = artistData['albums'] as List<dynamic>? ?? [];
          albums = albumsList
              .map((a) => _parseArtistAlbum(a as Map<String, dynamic>))
              .toList();

          final topTracksList =
              artistData['top_tracks'] as List<dynamic>? ?? [];
          if (topTracksList.isNotEmpty) {
            topTracks = topTracksList
                .map((t) => _parseTrack(t as Map<String, dynamic>))
                .toList();
          }

          headerImage = artistData['header_image'] as String?;
          headerVideo = artistData['header_video'] as String?;
          headerLogo = normalizeRemoteHttpUrl(
            artistData['header_logo']?.toString(),
          );
          listeners = artistData['listeners'] as int?;
        } else {
          throw StateError('Failed to load artist metadata from extension');
        }
      }

      albums = sortArtistAlbumsNewestFirst(albums);
      if (releases != null) {
        releases = sortArtistAlbumsNewestFirst(releases);
      }

      final finalHeaderImage =
          headerImage ?? _headerImageUrl ?? widget.headerImageUrl;
      final finalHeaderVideo =
          headerVideo ?? _headerVideoUrl ?? widget.headerVideoUrl;
      final finalHeaderLogo =
          headerLogo ?? _headerLogoUrl ?? widget.headerLogoUrl;
      final finalListeners =
          listeners ?? _monthlyListeners ?? widget.monthlyListeners;

      _ArtistCache.set(
        widget.artistId,
        albums: albums,
        releases: releases,
        topTracks: topTracks,
        headerImageUrl: finalHeaderImage,
        concerts: concerts,
        headerVideoUrl: finalHeaderVideo,
        headerLogoUrl: finalHeaderLogo,
        albumsNext: albumsNext,
        monthlyListeners: finalListeners,
      );

      if (mounted) {
        setState(() {
          _albums = albums;
          _releases = releases;
          _topTracks = topTracks;
          _concerts = concerts;
          _headerImageUrl = finalHeaderImage;
          _headerVideoUrl = finalHeaderVideo;
          _headerLogoUrl = finalHeaderLogo;
          _albumsNext = albumsNext;
          _albumsPageError = null;
          _monthlyListeners = finalListeners;
          _error = null;
          _isLoadingDiscography = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = context.friendlyError(e);
          _isLoadingDiscography = false;
        });
      }
    }
  }

  bool _onAlbumsScroll(ScrollNotification notification) {
    final advancing = switch (notification) {
      ScrollUpdateNotification() => (notification.scrollDelta ?? 0) > 0,
      OverscrollNotification() => notification.overscroll > 0,
      _ => false,
    };
    if (advancing &&
        notification.metrics.extentAfter < 480 &&
        !_isLoadingDiscography &&
        !isSelectionMode) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _loadMoreAlbums();
      });
    }
    return false;
  }

  Future<void> _loadMoreAlbums() async {
    final next = _albumsNext;
    final provider = _directMetadataProviderId();
    if (_isLoadingMoreAlbums ||
        next == null ||
        next.isEmpty ||
        provider == null ||
        (_albumPageRetryAfter?.isAfter(DateTime.now()) ?? false)) {
      return;
    }
    setState(() {
      _isLoadingMoreAlbums = true;
      _albumsPageError = null;
    });
    try {
      final result = await PlatformBridge.getProviderMetadata(
        provider,
        'artist',
        next,
      );
      if (!mounted) return;
      final info = result['artist_info'] as Map<String, dynamic>? ?? result;
      final page = (result['albums'] as List<dynamic>? ?? []).map(
        (value) => _parseArtistAlbum(value as Map<String, dynamic>),
      );
      final merged = {
        for (final album in _albums ?? <ArtistAlbum>[]) album.id: album,
      };
      for (final album in page) {
        merged[album.id] = album;
      }
      final following = info['albums_next'] as String?;
      setState(() {
        _albums = sortArtistAlbumsNewestFirst(merged.values);
        _albumsNext = following == next ? null : following;
      });
      _ArtistCache.set(
        widget.artistId,
        albums: _albums!,
        releases: _releases,
        topTracks: _topTracks,
        concerts: _concerts,
        headerImageUrl: _headerImageUrl,
        headerVideoUrl: _headerVideoUrl,
        headerLogoUrl: _headerLogoUrl,
        monthlyListeners: _monthlyListeners,
        albumsNext: _albumsNext,
      );
    } catch (error) {
      if (mounted) {
        setState(() {
          _albumsPageError = context.friendlyError(error);
          _albumPageRetryAfter = DateTime.now().add(const Duration(seconds: 3));
        });
      }
    } finally {
      if (mounted) setState(() => _isLoadingMoreAlbums = false);
    }
  }

  Track _parseTrack(Map<String, dynamic> data, {ArtistAlbum? album}) {
    int durationMs = 0;
    final durationValue = data['duration_ms'];
    if (durationValue is int) {
      durationMs = durationValue;
    } else if (durationValue is double) {
      durationMs = durationValue.toInt();
    }

    final spotifyId = (data['spotify_id'] ?? '').toString();
    final nativeId = (data['id'] ?? '').toString();

    return Track(
      id: spotifyId.isNotEmpty ? spotifyId : nativeId,
      name: (data['name'] ?? '').toString(),
      artistName: (data['artists'] ?? data['artist'] ?? '').toString(),
      albumName: (data['album_name'] ?? data['album'] ?? album?.name ?? '')
          .toString(),
      albumArtist: normalizeOptionalString(data['album_artist']?.toString()),
      artistId:
          (data['artist_id'] ?? data['artistId'])?.toString() ??
          widget.artistId,
      albumId: data['album_id']?.toString() ?? album?.id,
      coverUrl: normalizeCoverReference(
        (data['cover_url'] ?? data['images'] ?? album?.coverUrl)?.toString(),
      ),
      isrc: data['isrc']?.toString(),
      duration: (durationMs / 1000).round(),
      trackNumber: data['track_number'] as int?,
      discNumber: data['disc_number'] as int?,
      totalDiscs: data['total_discs'] as int?,
      releaseDate: data['release_date']?.toString(),
      albumType:
          normalizeOptionalString(data['album_type']?.toString()) ??
          album?.albumType,
      totalTracks: data['total_tracks'] as int? ?? album?.totalTracks,
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
      source: data['provider_id']?.toString() ?? widget.extensionId,
      previewUrl: data['preview_url']?.toString(),
      explicit: parseExplicitFlag(data['explicit']),
    );
  }

  ArtistAlbum _parseArtistAlbum(Map<String, dynamic> data) {
    final totalTracksValue = data['total_tracks'];
    final totalTracks = totalTracksValue is int
        ? totalTracksValue
        : int.tryParse(totalTracksValue?.toString() ?? '') ?? 0;

    return ArtistAlbum(
      id: data['id'] as String? ?? '',
      name: (data['name'] ?? data['title'] ?? '').toString(),
      releaseDate: (data['release_date'] ?? '').toString(),
      totalTracks: totalTracks,
      coverUrl: normalizeCoverReference(
        (data['cover_url'] ?? data['images'] ?? data['cover_art'])?.toString(),
      ),
      albumType: (data['album_type'] ?? data['type'] ?? 'album').toString(),
      artists: (data['artists'] ?? data['artist'] ?? widget.artistName)
          .toString(),
      providerId: data['provider_id']?.toString() ?? widget.extensionId,
    );
  }

  void _ensureAlbumBuckets(List<ArtistAlbum> albums) {
    if (identical(albums, _albumBucketSource)) return;
    _albumBucketSource = albums;
    _albumsOnlyBucket = albums
        .where((a) => a.albumType == 'album')
        .toList(growable: false);
    _singlesBucket = albums
        .where((a) => a.albumType == 'single' || a.albumType == 'ep')
        .toList(growable: false);
    _compilationsBucket = albums
        .where((a) => a.albumType == 'compilation')
        .toList(growable: false);
  }

  @override
  Widget build(BuildContext context) {
    if (context.isMornye) {
      return MornyeArtistSurface(
        imageSource:
            _headerImageUrl ?? widget.headerImageUrl ?? widget.coverUrl,
        logoSource: _headerLogoUrl ?? widget.headerLogoUrl,
        child: Builder(builder: _buildPage),
      );
    }
    return _buildPage(context);
  }

  Widget _buildPage(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final albums = _albums ?? [];
    _ensureAlbumBuckets(albums);
    final releases = _releases ?? const <ArtistAlbum>[];
    final albumsOnly = _albumsOnlyBucket;
    final singles = _singlesBucket;
    final compilations = _compilationsBucket;

    final hasDiscography =
        !_isLoadingDiscography && _error == null && albums.isNotEmpty;

    if (isSelectionMode || _selectionOverlay.isVisible) {
      final bottomPadding = MediaQuery.paddingOf(context).bottom;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _syncSelectionOverlay(albums: albums, bottomPadding: bottomPadding);
      });
    }

    return PopScope(
      canPop: !isSelectionMode,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop && isSelectionMode) {
          exitSelectionMode();
        }
      },
      child: Scaffold(
        body: Stack(
          children: [
            NotificationListener<ScrollNotification>(
              onNotification: (notification) => notification.depth == 0
                  ? _onAlbumsScroll(notification)
                  : false,
              child: CustomScrollView(
                controller: _scrollController,
                slivers: [
                  ..._buildHeader(
                    context,
                    colorScheme,
                    albums: albums,
                    hasDiscography: hasDiscography,
                  ),
                  // Desktop keeps the sections in the header's column.
                  SliverPadding(
                    padding: EdgeInsets.symmetric(
                      horizontal: isDesktopPlatform
                          ? wideListInset(context)
                          : 0,
                    ),
                    sliver: SliverMainAxisGroup(
                      slivers: [
                        if (_isLoadingDiscography)
                          SliverToBoxAdapter(
                            child: ArtistScreenSkeleton(
                              showCoverHeader:
                                  !isDesktopPlatform &&
                                  !context.isMornye &&
                                  (_headerImageUrl ??
                                          widget.headerImageUrl ??
                                          widget.coverUrl) ==
                                      null,
                              showPopularSection:
                                  !widget.artistId.startsWith('deezer:') &&
                                  !widget.artistId.startsWith('qobuz:') &&
                                  !widget.artistId.startsWith('tidal:'),
                            ),
                          ),
                        if (_error != null)
                          SliverToBoxAdapter(
                            child: Padding(
                              padding: const EdgeInsets.all(16),
                              child: ErrorCard(
                                error: _error!,
                                colorScheme: colorScheme,
                                onRetry: _fetchDiscography,
                              ),
                            ),
                          ),
                        if (!_isLoadingDiscography && _error == null) ...[
                          if (context.isMornye &&
                              albums.isNotEmpty &&
                              !isSelectionMode)
                            SliverToBoxAdapter(
                              child: _buildMornyeFeaturedAlbum(
                                context,
                                albums.first,
                              ),
                            ),
                          if (_topTracks != null && _topTracks!.isNotEmpty)
                            SliverToBoxAdapter(
                              child: _buildPopularSection(context, colorScheme),
                            ),
                          if (releases.isNotEmpty)
                            SliverToBoxAdapter(
                              key: const ValueKey('artist-releases'),
                              child: _buildAlbumSection(
                                context,
                                context.l10n.artistReleases,
                                releases,
                                colorScheme,
                              ),
                            ),
                          if (albumsOnly.isNotEmpty)
                            SliverToBoxAdapter(
                              key: const ValueKey('artist-albums'),
                              child: _buildAlbumSection(
                                context,
                                context.l10n.artistAlbums,
                                albumsOnly,
                                colorScheme,
                              ),
                            ),
                          if (singles.isNotEmpty)
                            SliverToBoxAdapter(
                              key: const ValueKey('artist-singles'),
                              child: _buildAlbumSection(
                                context,
                                context.l10n.artistSingles,
                                singles,
                                colorScheme,
                                showTypeBadge: true,
                              ),
                            ),
                          if (compilations.isNotEmpty)
                            SliverToBoxAdapter(
                              key: const ValueKey('artist-compilations'),
                              child: _buildAlbumSection(
                                context,
                                context.l10n.artistCompilations,
                                compilations,
                                colorScheme,
                              ),
                            ),
                        ],
                        if (_isLoadingMoreAlbums || _albumsPageError != null)
                          SliverToBoxAdapter(
                            child: Padding(
                              padding: const EdgeInsets.all(16),
                              child: Column(
                                children: [
                                  if (_albumsPageError != null)
                                    Text(
                                      _albumsPageError!,
                                      textAlign: TextAlign.center,
                                    ),
                                  if (_isLoadingMoreAlbums)
                                    const AppLoadingIndicator(),
                                ],
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  SliverToBoxAdapter(
                    child: SizedBox(
                      height: isSelectionMode
                          ? 120
                          : isDesktopPlatform
                          ? desktopDetailBottomInset
                          : 32,
                    ),
                  ),
                  const NavBarSliverSpacer(),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _syncSelectionOverlay({
    required List<ArtistAlbum> albums,
    required double bottomPadding,
  }) {
    if (!showsSelectionBar) {
      _selectionOverlay.hide();
      return;
    }
    _selectionOverlay.show(
      context,
      (overlayContext) => _buildSelectionBar(
        overlayContext,
        Theme.of(overlayContext).colorScheme,
        albums,
        bottomPadding,
      ),
    );
  }

  @override
  void exitSelectionMode() {
    HapticFeedback.lightImpact();
    super.exitSelectionMode();
  }

  @override
  void toggleSelection(String itemId) {
    HapticFeedback.selectionClick();
    super.toggleSelection(itemId);
  }

  Widget _buildSelectionBar(
    BuildContext context,
    ColorScheme colorScheme,
    List<ArtistAlbum> allAlbums,
    double bottomPadding,
  ) {
    final selectedCount = selectedIds.length;
    final selectedAlbums = allAlbums
        .where((a) => selectedIds.contains(a.id))
        .toList();
    final totalTracks = selectedAlbums.fold<int>(
      0,
      (sum, a) => sum + a.totalTracks,
    );

    return buildSelectionBar(
      ids: [for (final album in allAlbums) album.id],
      onDeselectAll: () => setState(selectedIds.clear),
      bottomPadding: bottomPadding,
      allSelectedLabel: context.l10n.tracksCount(totalTracks),
      tapToSelectLabel: selectedCount > 0
          ? context.l10n.tracksCount(totalTracks)
          : context.l10n.discographySelectAlbumsSubtitle,
      children: [
        SizedBox(
          width: double.infinity,
          child: ExpressiveButton(
            onPressed: selectedCount > 0 && !_isFetchingDiscography
                ? () {
                    exitSelectionMode();
                    _fetchAndQueueAlbums(
                      selectedAlbums,
                      ref.read(settingsProvider).defaultService,
                      null,
                      addToPlaylist: true,
                    );
                  }
                : null,
            icon: const Icon(Icons.playlist_add),
            child: Text(context.l10n.collectionAddToPlaylist),
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: ExpressiveButton(
                onPressed: selectedCount > 0
                    ? () => _downloadSelectedAlbums(context, selectedAlbums)
                    : null,
                icon: const Icon(Icons.download, size: 18),
                child: Text(context.l10n.discographyDownloadSelected),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Future<void> _toggleFavoriteArtist(BuildContext context) async {
    final providerId = _directMetadataProviderId();
    final imageUrl =
        _headerImageUrl ?? widget.headerImageUrl ?? widget.coverUrl;
    final added = await ref
        .read(libraryCollectionsProvider.notifier)
        .toggleFavoriteArtist(
          artistId: _metadataResourceId(providerId ?? ''),
          providerId: providerId,
          name: widget.artistName,
          imageUrl: imageUrl,
        );
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          added
              ? context.l10n.collectionAddedToFavoriteArtists(widget.artistName)
              : context.l10n.collectionRemovedFromFavoriteArtists(
                  widget.artistName,
                ),
        ),
      ),
    );
  }
}
