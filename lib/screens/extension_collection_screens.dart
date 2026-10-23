import 'dart:async';
import 'package:flutter/material.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/widgets/error_card.dart';
import 'package:mornye/widgets/mornye_artist_header.dart';
import 'package:mornye/widgets/album_detail_header.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/models/artist_concert.dart';
import 'package:mornye/providers/track_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/screens/album_screen.dart';
import 'package:mornye/controllers/clickable_metadata.dart';
import 'package:mornye/controllers/collapsing_header_scroll_mixin.dart';
import 'package:mornye/controllers/extension_auth_launcher.dart';
import 'package:mornye/screens/artist_screen.dart';
import 'package:mornye/services/platform_bridge.dart';
import 'package:mornye/utils/adaptive_layout.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:mornye/widgets/desktop/detail_header.dart';
import 'package:mornye/utils/string_utils.dart';
import 'package:mornye/utils/editorial_notes.dart';
import 'package:mornye/screens/playlist_screen.dart';
import 'package:mornye/widgets/animation_utils.dart';
import 'package:mornye/widgets/cached_cover_image.dart';

/// Legacy `duration_ms` parsing used by extension album/playlist/artist track
/// parsing, kept separate from [extractDurationMs] which also falls back to
/// a `duration` (seconds) field these call sites intentionally ignore.
int _legacyTrackDurationMs(Map<String, dynamic> data) {
  final durationValue = data['duration_ms'];
  if (durationValue is int) return durationValue;
  if (durationValue is double) return durationValue.toInt();
  return 0;
}

/// Prefers the track's own cover, falling back to the parent
/// album/playlist cover, without URL validation.
String? _resolveTrackCoverUrl(String? trackCover, String? fallbackCover) {
  if (trackCover != null && trackCover.isNotEmpty) return trackCover;
  return fallbackCover;
}

/// Shared loading/error+retry scaffold for extension album/playlist/artist
/// detail screens.
class _LoadingOrErrorScaffold extends StatelessWidget {
  final String title;
  final bool isLoading;
  final String? error;
  final Widget loadingBody;
  final VoidCallback onRetry;
  final bool collectionHeader;
  final String? coverUrl;

  const _LoadingOrErrorScaffold({
    required this.title,
    required this.isLoading,
    required this.error,
    required this.loadingBody,
    required this.onRetry,
    this.collectionHeader = false,
    this.coverUrl,
  });

  @override
  Widget build(BuildContext context) {
    if (isLoading) {
      if (context.isMornye && collectionHeader && !isDesktopPlatform) {
        return MornyeArtistSurface(
          imageSource: coverUrl,
          neutralActions: true,
          child: Builder(
            builder: (context) => Scaffold(
              extendBodyBehindAppBar: true,
              appBar: AppBar(
                backgroundColor: Colors.transparent,
                surfaceTintColor: Colors.transparent,
                elevation: 0,
                leadingWidth: 68,
                leading: Padding(
                  padding: const EdgeInsetsDirectional.only(start: 12),
                  child: HeaderCircleButton(
                    icon: Icons.arrow_back,
                    tooltip: MaterialLocalizations.of(
                      context,
                    ).backButtonTooltip,
                    onPressed: () => Navigator.pop(context),
                  ),
                ),
              ),
              body: MediaQuery.removePadding(
                context: context,
                removeTop: true,
                child: loadingBody,
              ),
            ),
          ),
        );
      }
      // Desktop shows its compact header in both styles.
      if ((isDesktopPlatform || !context.isMornye) && collectionHeader) {
        // The real header with the title and cover already known; only the
        // rows that wait for the tracks are skeletons.
        final cover = coverUrl;
        final hasCover = cover != null && cover.isNotEmpty;
        final colors = Theme.of(context).colorScheme;
        return Scaffold(
          body: CustomScrollView(
            physics: const NeverScrollableScrollPhysics(),
            slivers: [
              AlbumDetailHeader(
                title: title,
                expandedHeight: collectionHeaderExpandedHeight(context),
                showTitleInAppBar: false,
                paletteSource: hasCover ? cover : null,
                blurAndScrimBackground: hasCover,
                background: hasCover
                    ? CachedCoverImage(imageUrl: cover, fit: BoxFit.cover)
                    : ColoredBox(color: colors.surfaceContainerHighest),
                coverBuilder: (context, size) => hasCover
                    ? CachedCoverImage(
                        imageUrl: cover,
                        width: size,
                        height: size,
                        fit: BoxFit.cover,
                      )
                    : ShimmerLoading(
                        child: SkeletonBox(
                          width: size,
                          height: size,
                          borderRadius: 0,
                        ),
                      ),
                subtitle: CollectionHeaderSkeletonRows.subtitle(context),
                meta: CollectionHeaderSkeletonRows.meta(),
                actions: CollectionHeaderSkeletonRows.actions(context),
              ),
              SliverToBoxAdapter(child: loadingBody),
            ],
          ),
        );
      }
      return Scaffold(
        appBar: AppBar(
          title: Text(title),
          leadingWidth: context.isMornye ? 68 : null,
          leading: context.isMornye
              ? Padding(
                  padding: const EdgeInsetsDirectional.only(start: 12),
                  child: HeaderCircleButton(
                    icon: Icons.arrow_back,
                    tooltip: MaterialLocalizations.of(
                      context,
                    ).backButtonTooltip,
                    onPressed: () => Navigator.pop(context),
                  ),
                )
              : null,
        ),
        body: loadingBody,
      );
    }

    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: ErrorCard(
            error: error ?? '',
            colorScheme: Theme.of(context).colorScheme,
            onRetry: onRetry,
          ),
        ),
      ),
    );
  }
}

/// Defers swapping the loading scaffold for the loaded screen until the push
/// transition (and its Hero flight) has finished. Swapping mid-flight puts a
/// second hero with the same tag on screen; the flight doesn't adopt it, so
/// the user sees a static cover next to the flying one.
mixin _RouteSettled<T extends StatefulWidget> on State<T> {
  bool _routeSettled = false;
  Animation<double>? _routeAnimation;

  bool get routeSettled => _routeSettled;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_routeSettled) return;
    final animation = ModalRoute.of(context)?.animation;
    if (animation == null || animation.isCompleted) {
      _routeSettled = true;
      return;
    }
    if (!identical(animation, _routeAnimation)) {
      _routeAnimation?.removeStatusListener(_onRouteStatus);
      _routeAnimation = animation;
      animation.addStatusListener(_onRouteStatus);
    }
  }

  void _onRouteStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed) {
      _routeAnimation?.removeStatusListener(_onRouteStatus);
      _routeAnimation = null;
      setState(() => _routeSettled = true);
    }
  }

  @override
  void dispose() {
    _routeAnimation?.removeStatusListener(_onRouteStatus);
    super.dispose();
  }
}

/// Loading state for [ExtensionArtistScreen]: the real full-bleed header with
/// the cover and artist name above the discography skeleton.
class _ArtistLoadingScaffold extends StatelessWidget {
  final String artistName;
  final String? coverUrl;

  const _ArtistLoadingScaffold({
    required this.artistName,
    required this.coverUrl,
  });

  @override
  Widget build(BuildContext context) {
    // Mornye keeps the Apple Music hero on desktop too.
    if (isDesktopPlatform && !context.isMornye) {
      final url = coverUrl;
      return Scaffold(
        body: CustomScrollView(
          physics: const NeverScrollableScrollPhysics(),
          slivers: [
            ...desktopDetailHeaderSlivers(
              context,
              title: artistName,
              circularArtwork: true,
              artwork: (context, size) => url != null && url.isNotEmpty
                  ? CachedCoverImage(imageUrl: url, fit: BoxFit.cover)
                  : ShimmerLoading(
                      child: SkeletonBox(
                        width: size,
                        height: size,
                        borderRadius: 0,
                      ),
                    ),
            ),
            SliverPadding(
              padding: EdgeInsets.symmetric(horizontal: wideListInset(context)),
              sliver: const SliverToBoxAdapter(
                child: ArtistScreenSkeleton(showCoverHeader: false),
              ),
            ),
          ],
        ),
      );
    }
    if (context.isMornye) {
      return MornyeArtistSurface(
        imageSource: coverUrl,
        child: Builder(
          builder: (context) => Scaffold(
            body: CustomScrollView(
              slivers: [
                ...MornyeArtistHeader(
                  name: artistName,
                  showTitle: false,
                  artwork: coverUrl != null && coverUrl!.isNotEmpty
                      ? CachedCoverImage(
                          imageUrl: coverUrl!,
                          fit: BoxFit.cover,
                          alignment: Alignment.topCenter,
                          memCacheWidth: isDesktopPlatform ? 1600 : 800,
                        )
                      : const ShimmerLoading(
                          child: SkeletonBox(
                            width: double.infinity,
                            height: double.infinity,
                            borderRadius: 0,
                          ),
                        ),
                  actions: const [
                    ShimmerLoading(child: ArtistHeaderActionsSkeleton()),
                  ],
                ).buildSlivers(context),
                const SliverToBoxAdapter(
                  child: ArtistScreenSkeleton(showCoverHeader: false),
                ),
              ],
            ),
          ),
        ),
      );
    }
    final colorScheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final edgeInset = detailHeaderEdgeInset(context);
    final url = coverUrl;
    final hasImage =
        url != null &&
        url.isNotEmpty &&
        Uri.tryParse(url)?.hasAuthority == true;

    final Widget image = hasImage
        ? CachedCoverImage(
            imageUrl: url,
            fit: BoxFit.cover,
            alignment: Alignment.topCenter,
            memCacheWidth: 800,
          )
        : Container(
            color: colorScheme.surfaceContainerHighest,
            child: Icon(
              Icons.person,
              size: 80,
              color: colorScheme.onSurfaceVariant,
            ),
          );

    return Scaffold(
      body: CustomScrollView(
        slivers: [
          SliverAppBar(
            expandedHeight: 420,
            pinned: true,
            backgroundColor: colorScheme.surface,
            surfaceTintColor: Colors.transparent,
            flexibleSpace: FlexibleSpaceBar(
              collapseMode: CollapseMode.none,
              background: Stack(
                fit: StackFit.expand,
                children: [
                  image,
                  Container(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Colors.transparent,
                          Colors.black.withValues(alpha: 0.3),
                          Colors.black.withValues(alpha: 0.7),
                          isDark
                              ? colorScheme.surface
                              : Colors.black.withValues(alpha: 0.85),
                        ],
                        stops: const [0.0, 0.5, 0.75, 1.0],
                      ),
                    ),
                  ),
                  Positioned(
                    left: 16 + edgeInset,
                    right: 16 + edgeInset,
                    bottom: 16,
                    child: Text(
                      artistName,
                      style: Theme.of(context).textTheme.headlineLarge
                          ?.copyWith(
                            fontWeight: FontWeight.bold,
                            color: Colors.white,
                            shadows: [
                              Shadow(
                                offset: const Offset(0, 1),
                                blurRadius: 4,
                                color: Colors.black.withValues(alpha: 0.5),
                              ),
                            ],
                          ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
            leadingWidth: kToolbarHeight + edgeInset,
            leading: Padding(
              padding: EdgeInsetsDirectional.only(start: edgeInset),
              // Centered so the tight leading slot cannot stretch it.
              child: Center(
                child: HeaderCircleButton(
                  icon: Icons.arrow_back,
                  tooltip: MaterialLocalizations.of(context).backButtonTooltip,
                  onPressed: () => Navigator.pop(context),
                ),
              ),
            ),
          ),
          const SliverToBoxAdapter(
            child: ArtistScreenSkeleton(showCoverHeader: false),
          ),
        ],
      ),
    );
  }
}

class ExtensionAlbumScreen extends ConsumerStatefulWidget {
  final String extensionId;
  final String albumId;
  final String albumName;
  final String? coverUrl;
  final String? initialAlbumType;
  final int? initialTotalTracks;

  const ExtensionAlbumScreen({
    super.key,
    required this.extensionId,
    required this.albumId,
    required this.albumName,
    this.coverUrl,
    this.initialAlbumType,
    this.initialTotalTracks,
  });

  @override
  ConsumerState<ExtensionAlbumScreen> createState() =>
      _ExtensionAlbumScreenState();
}

class _ExtensionAlbumScreenState extends ConsumerState<ExtensionAlbumScreen> {
  List<Track>? _tracks;
  String? _albumName;
  String? _description;
  bool _isLoading = true;
  String? _error;
  String? _artistId;
  String? _artistName;
  String? _albumType;
  int? _albumTotalTracks;
  String? _headerVideoUrl;
  String? _headerImageUrl;
  List<String> _audioTraits = const [];

  @override
  void initState() {
    super.initState();
    _albumType = normalizeOptionalString(widget.initialAlbumType);
    _albumTotalTracks = widget.initialTotalTracks;
    _fetchTracks();
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
      final result = await runExtensionOperationWithVerificationRetry(
        extensionId: widget.extensionId,
        browserMode: ref
            .read(settingsProvider)
            .extensionVerificationBrowserMode,
        operation: () => PlatformBridge.getProviderMetadata(
          widget.extensionId,
          'album',
          widget.albumId,
        ),
      );
      if (!mounted) return;

      final albumInfo = result['album_info'] as Map<String, dynamic>? ?? result;
      final trackList =
          result['track_list'] as List<dynamic>? ??
          result['tracks'] as List<dynamic>?;
      if (trackList == null) {
        setState(() {
          _error = context.l10n.errorNoTracksFound;
          _isLoading = false;
        });
        return;
      }

      final artistId = (albumInfo['artist_id'] ?? albumInfo['artistId'])
          ?.toString();
      final albumName =
          normalizeOptionalString(albumInfo['name']?.toString()) ??
          widget.albumName;
      final artistName = (albumInfo['artists'] ?? albumInfo['artist'])
          ?.toString();
      final albumType =
          normalizeOptionalString(albumInfo['album_type']?.toString()) ??
          _albumType;
      final totalTracks =
          albumInfo['total_tracks'] as int? ?? _albumTotalTracks;
      final headerVideo = albumInfo['header_video']?.toString();
      final headerImage = albumInfo['header_image']?.toString();
      final audioTraits = (albumInfo['audio_traits'] as List?)
          ?.map((e) => e.toString())
          .toList();
      final tracks = trackList
          .map(
            (t) => _parseTrack(
              t as Map<String, dynamic>,
              albumNameFallback: albumName,
              albumTypeFallback: albumType,
              totalTracksFallback: totalTracks,
            ),
          )
          .toList();

      setState(() {
        _tracks = tracks;
        _albumName = albumName;
        _description = albumDescriptionFromMetadata(albumInfo);
        _artistId = artistId;
        _artistName = artistName;
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
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = context.l10n.snackbarError(context.friendlyError(e));
        _isLoading = false;
      });
    }
  }

  Track _parseTrack(
    Map<String, dynamic> data, {
    String? albumNameFallback,
    String? albumTypeFallback,
    int? totalTracksFallback,
  }) {
    final base = Track.fromBackendMap(data, source: widget.extensionId);
    return base.copyWith(
      id: (data['id'] ?? '').toString(),
      albumName:
          normalizeOptionalString(data['album_name']?.toString()) ??
          albumNameFallback ??
          widget.albumName,
      albumArtist: normalizeOptionalString(data['album_artist']?.toString()),
      artistId: base.artistId ?? _artistId,
      albumId: base.albumId ?? widget.albumId,
      coverUrl: _resolveTrackCoverUrl(
        data['cover_url']?.toString(),
        widget.coverUrl,
      ),
      duration: (_legacyTrackDurationMs(data) / 1000).round(),
      albumType: base.albumType ?? albumTypeFallback ?? _albumType,
      totalTracks: base.totalTracks ?? totalTracksFallback ?? _albumTotalTracks,
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading || _error != null) {
      return _LoadingOrErrorScaffold(
        title: widget.albumName,
        collectionHeader: true,
        coverUrl: widget.coverUrl,
        isLoading: _isLoading,
        error: _error,
        loadingBody: const AlbumTrackListSkeleton(
          itemCount: 10,
          showCoverHeader: true,
        ),
        onRetry: _fetchTracks,
      );
    }

    return AlbumScreen(
      albumId: widget.albumId,
      albumName: _albumName ?? widget.albumName,
      description: _description,
      coverUrl: widget.coverUrl,
      headerVideoUrl: _headerVideoUrl,
      headerImageUrl: _headerImageUrl,
      audioTraits: _audioTraits,
      tracks: _tracks,
      extensionId: widget.extensionId,
      artistId: _artistId,
      artistName: _artistName,
    );
  }
}

class ExtensionPlaylistScreen extends ConsumerStatefulWidget {
  final String extensionId;
  final String playlistId;
  final String playlistName;
  final String? coverUrl;

  const ExtensionPlaylistScreen({
    super.key,
    required this.extensionId,
    required this.playlistId,
    required this.playlistName,
    this.coverUrl,
  });

  @override
  ConsumerState<ExtensionPlaylistScreen> createState() =>
      _ExtensionPlaylistScreenState();
}

class _ExtensionPlaylistScreenState
    extends ConsumerState<ExtensionPlaylistScreen> {
  List<Track>? _tracks;
  bool _isLoading = true;
  String? _error;
  String? _headerVideoUrl;

  @override
  void initState() {
    super.initState();
    _fetchTracks();
  }

  Future<void> _fetchTracks() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final result = await runExtensionOperationWithVerificationRetry(
        extensionId: widget.extensionId,
        browserMode: ref
            .read(settingsProvider)
            .extensionVerificationBrowserMode,
        operation: () => PlatformBridge.getProviderMetadata(
          widget.extensionId,
          'playlist',
          widget.playlistId,
        ),
      );
      if (!mounted) return;

      final trackList =
          result['track_list'] as List<dynamic>? ??
          result['tracks'] as List<dynamic>?;
      if (trackList == null) {
        setState(() {
          _error = context.l10n.errorNoTracksFound;
          _isLoading = false;
        });
        return;
      }

      final tracks = trackList
          .map((t) => _parseTrack(t as Map<String, dynamic>))
          .toList();

      final playlistInfo = result['playlist_info'] as Map<String, dynamic>?;
      final headerVideo = playlistInfo?['header_video']?.toString();

      setState(() {
        _tracks = tracks;
        _headerVideoUrl = (headerVideo != null && headerVideo.isNotEmpty)
            ? headerVideo
            : _headerVideoUrl;
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = context.l10n.snackbarError(context.friendlyError(e));
        _isLoading = false;
      });
    }
  }

  Track _parseTrack(Map<String, dynamic> data) {
    final base = Track.fromBackendMap(
      data,
      source: widget.extensionId,
      playlistName: widget.playlistName,
    );
    return base.copyWith(
      id: (data['id'] ?? '').toString(),
      coverUrl: _resolveTrackCoverUrl(
        data['cover_url']?.toString(),
        widget.coverUrl,
      ),
      duration: (_legacyTrackDurationMs(data) / 1000).round(),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading || _error != null) {
      return SkeletonCrossfade(
        child: _LoadingOrErrorScaffold(
          title: widget.playlistName,
          collectionHeader: true,
          coverUrl: widget.coverUrl,
          isLoading: _isLoading,
          error: _error,
          loadingBody: const TrackListSkeleton(
            itemCount: 8,
            showCoverHeader: true,
          ),
          onRetry: _fetchTracks,
        ),
      );
    }

    return SkeletonCrossfade(
      child: PlaylistScreen(
        playlistName: widget.playlistName,
        coverUrl: widget.coverUrl,
        headerVideoUrl: _headerVideoUrl,
        tracks: _tracks!,
        recommendedService: widget.extensionId,
      ),
    );
  }
}

class ExtensionArtistScreen extends ConsumerStatefulWidget {
  final String extensionId;
  final String artistId;
  final String artistName;
  final String? coverUrl;

  const ExtensionArtistScreen({
    super.key,
    required this.extensionId,
    required this.artistId,
    required this.artistName,
    this.coverUrl,
  });

  @override
  ConsumerState<ExtensionArtistScreen> createState() =>
      _ExtensionArtistScreenState();
}

class _ExtensionArtistScreenState extends ConsumerState<ExtensionArtistScreen>
    with _RouteSettled<ExtensionArtistScreen> {
  List<ArtistAlbum>? _albums;
  List<Track>? _topTracks;
  String? _headerImageUrl;
  String? _headerVideoUrl;
  String? _headerLogoUrl;
  List<ArtistConcert> _concerts = const [];
  String? _albumsNext;
  int? _monthlyListeners;
  bool _isLoading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _fetchArtist();
  }

  Future<void> _fetchArtist() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final result = await runExtensionOperationWithVerificationRetry(
        extensionId: widget.extensionId,
        browserMode: ref
            .read(settingsProvider)
            .extensionVerificationBrowserMode,
        operation: () => PlatformBridge.getProviderMetadata(
          widget.extensionId,
          'artist',
          widget.artistId,
        ),
      );
      if (!mounted) return;

      final artistInfo =
          result['artist_info'] as Map<String, dynamic>? ?? result;
      final albumList = result['albums'] as List<dynamic>?;
      final albums =
          albumList
              ?.map((a) => _parseAlbum(a as Map<String, dynamic>))
              .toList() ??
          [];

      final topTracksList = result['top_tracks'] as List<dynamic>?;
      List<Track>? topTracks;
      if (topTracksList != null && topTracksList.isNotEmpty) {
        topTracks = topTracksList
            .map((t) => _parseTrack(t as Map<String, dynamic>))
            .toList();
      }

      final headerImage =
          artistInfo['images'] as String? ??
          artistInfo['header_image'] as String? ??
          artistInfo['cover_url'] as String? ??
          result['header_image'] as String?;
      final headerVideo =
          artistInfo['header_video'] as String? ??
          result['header_video'] as String?;
      final listeners =
          artistInfo['listeners'] as int? ?? result['listeners'] as int?;
      final headerLogo = normalizeRemoteHttpUrl(
        (artistInfo['header_logo'] ?? result['header_logo'])?.toString(),
      );

      setState(() {
        _albums = albums;
        _topTracks = topTracks;
        _headerImageUrl = headerImage;
        _headerVideoUrl = headerVideo;
        _headerLogoUrl = headerLogo;
        _concerts = ArtistConcert.parseList(
          artistInfo['concerts'] ?? result['concerts'],
        );
        _albumsNext = artistInfo['albums_next'] as String?;
        _monthlyListeners = listeners;
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = context.l10n.snackbarError(context.friendlyError(e));
        _isLoading = false;
      });
    }
  }

  ArtistAlbum _parseAlbum(Map<String, dynamic> data) {
    return ArtistAlbum(
      id: (data['id'] ?? '').toString(),
      name: (data['name'] ?? '').toString(),
      artists: (data['artists'] ?? '').toString(),
      releaseDate: (data['release_date'] ?? '').toString(),
      totalTracks: int.tryParse(data['total_tracks']?.toString() ?? '') ?? 0,
      coverUrl: normalizeCoverReference(data['cover_url']?.toString()),
      albumType: (data['album_type'] ?? 'album').toString(),
      providerId: (data['provider_id'] ?? widget.extensionId).toString(),
    );
  }

  Track _parseTrack(Map<String, dynamic> data) {
    final base = Track.fromBackendMap(data);
    return base.copyWith(
      id: (data['id'] ?? data['spotify_id'] ?? '').toString(),
      artistId: base.artistId ?? widget.artistId,
      duration: (_legacyTrackDurationMs(data) / 1000).round(),
      source: (data['provider_id'] ?? widget.extensionId).toString(),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return SkeletonCrossfade(
        child: _LoadingOrErrorScaffold(
          title: widget.artistName,
          isLoading: false,
          error: _error,
          loadingBody: const SizedBox.shrink(),
          onRetry: _fetchArtist,
        ),
      );
    }

    if (_isLoading || !routeSettled) {
      return SkeletonCrossfade(
        child: _ArtistLoadingScaffold(
          artistName: widget.artistName,
          coverUrl: widget.coverUrl,
        ),
      );
    }

    return SkeletonCrossfade(
      child: ArtistScreen(
        artistId: widget.artistId,
        artistName: widget.artistName,
        coverUrl: widget.coverUrl,
        headerImageUrl: _headerImageUrl,
        headerVideoUrl: _headerVideoUrl,
        headerLogoUrl: _headerLogoUrl,
        concerts: _concerts,
        albumsNext: _albumsNext,
        monthlyListeners: _monthlyListeners,
        albums: _albums,
        topTracks: _topTracks,
        extensionId: widget.extensionId, // Skip Spotify/Deezer fetch
      ),
    );
  }
}
