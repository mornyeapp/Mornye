import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/services.dart' show SystemUiOverlayStyle;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';
import 'package:mornye/controllers/clickable_metadata.dart';
import 'package:mornye/controllers/player_metadata_controller.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/providers/download_history_provider.dart';
import 'package:mornye/providers/library_collections_provider.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/routes/now_playing_route.dart';
import 'package:mornye/screens/downloaded_album_screen.dart';
import 'package:mornye/screens/local_album_screen.dart';
import 'package:mornye/screens/equalizer_screen.dart';
import 'package:mornye/screens/lyrics_share_screen.dart';
import 'package:mornye/services/link/features/link_phone_client.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/theme/player_artwork_theme.dart';
import 'package:mornye/utils/file_access.dart';
import 'package:mornye/utils/lyrics_parser.dart';
import 'package:mornye/utils/playback_seek_preview.dart';
import 'package:mornye/utils/logger.dart';
import 'package:mornye/widgets/app_bottom_sheet.dart';
import 'package:mornye/widgets/app_snack_bar.dart';
import 'package:mornye/widgets/app_icon.dart';
import 'package:mornye/widgets/app_icon_button.dart';
import 'package:mornye/widgets/expressive_icon_button.dart';
import 'package:mornye/widgets/audio_output_button.dart';
import 'package:mornye/widgets/desktop/desktop_commands.dart'
    show DesktopCommand, desktopTooltip;
import 'package:mornye/widgets/desktop/desktop_inspector.dart';
import 'package:mornye/widgets/link/link_devices_sheet.dart';
import 'package:mornye/widgets/lyrics_screen_awake.dart';
import 'package:mornye/widgets/player_artwork.dart';
import 'package:mornye/widgets/player_gesture_regions.dart';
import 'package:mornye/widgets/player_playback_controls.dart';
import 'package:mornye/widgets/player_queue_sheet.dart';
import 'package:mornye/widgets/player_details_sheet.dart';
import 'package:mornye/widgets/material_player_backdrop.dart';
import 'package:mornye/widgets/material_player_layout.dart';
import 'package:mornye/widgets/mornye_player_layout.dart';
import 'package:mornye/widgets/player_lyrics_controls.dart';
import 'package:mornye/widgets/player_lyrics_section.dart';
import 'package:mornye/widgets/playlist_picker_sheet.dart';
import 'package:mornye/widgets/settings_group.dart';
import 'package:mornye/widgets/mornye_player_background.dart';
import 'package:mornye/widgets/mornye_artwork_contrast.dart';
import 'package:mornye/widgets/mornye_player_actions_sheet.dart';
import 'package:mornye/widgets/mornye_context_menu.dart';
import 'package:mornye/widgets/mornye_player_artwork.dart';
import 'package:mornye/providers/player_motion_artwork_provider.dart';

export 'package:mornye/routes/now_playing_route.dart';

final _log = AppLogger('NowPlaying');

/// AppBar wrapper that fades with the route transition (see contentOpacity
/// in [_NowPlayingScreenState.build]).
class _FadingAppBar extends StatelessWidget implements PreferredSizeWidget {
  final Animation<double> opacity;
  final AppBar child;

  const _FadingAppBar({required this.opacity, required this.child});

  @override
  Size get preferredSize => child.preferredSize;

  @override
  Widget build(BuildContext context) =>
      FadeTransition(opacity: opacity, child: child);
}

class NowPlayingScreen extends ConsumerStatefulWidget {
  const NowPlayingScreen({
    super.key,
    this.metadataControllerFactory,
    this.initialPage = 0,
    this.embedded = false,
  });

  final PlayerMetadataController Function()? metadataControllerFactory;

  /// The page shown first: 0 is the player, 1 the lyrics and 2 Up Next
  /// (Mornye only).
  final int initialPage;

  /// Shown in the desktop content pane rather than as a route. Minimizing
  /// returns to the content, and lyrics and Up Next open in the desktop
  /// inspector beside the player instead of replacing it.
  final bool embedded;

  @override
  ConsumerState<NowPlayingScreen> createState() => _NowPlayingScreenState();
}

class _NowPlayingScreenState extends ConsumerState<NowPlayingScreen> {
  ProviderSubscription<AsyncValue<MediaItem?>>? _mediaItemSub;
  ProviderSubscription<bool>? _lyricsPlayingSub;
  late final _trackMetadata =
      widget.metadataControllerFactory?.call() ?? PlayerMetadataController();
  late int _currentPage = widget.initialPage;
  bool _landscape = false;
  bool _queueSheetShowing = false;
  String? _measuredMotionSource;
  double? _motionAspectRatio;
  String? _failedMotionSource;
  bool _lyricsControlsHidden = false;
  bool _lyricsOptionsOpen = false;
  bool _audioOutputOpen = false;
  bool _sharingLyrics = false;
  double _lyricsScrollDistance = 0;
  Timer? _lyricsIdleTimer;
  final _lyricsPointers = <int, Offset>{};
  bool _lyricsPointerMoved = false;
  final _artworkHeaderKey = GlobalKey();
  final _artworkControlsKey = GlobalKey();
  final _artworkVolumeKey = GlobalKey();
  final _expandedArtworkKey = GlobalKey();
  final _compactArtworkKey = GlobalKey();
  final _motionArtworkKey = GlobalKey();
  final _artworkForeground = ValueNotifier<Map<String, Color>>({});
  final _seekPreview = PlaybackSeekPreview();
  NowPlayingRoute? _artworkRoute;

  @override
  void initState() {
    super.initState();
    if (widget.embedded) desktopInspectorPanel.addListener(_onInspectorChanged);
    _mediaItemSub = ref.listenManual<AsyncValue<MediaItem?>>(
      currentMediaItemProvider,
      (previous, next) {
        if (previous?.value?.id != next.value?.id) _seekPreview.reset();
        unawaited(
          _trackMetadata.load(
            next.value,
            inspectUnresolvedContentUri: _currentPage == 1,
          ),
        );
      },
    );
    _lyricsPlayingSub = ref.listenManual<bool>(playbackPlayingProvider, (
      previous,
      playing,
    ) {
      if (!playing && _lyricsControlsHidden) {
        setState(() => _lyricsControlsHidden = false);
      }
      _scheduleLyricsControlsHide();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(
        _trackMetadata.load(
          ref.read(currentMediaItemProvider).value,
          inspectUnresolvedContentUri: _currentPage == 1,
        ),
      );
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final size = MediaQuery.sizeOf(context);
    _landscape = context.isMornye && size.width > size.height;
    if (_landscape || MediaQuery.accessibleNavigationOf(context)) {
      _lyricsControlsHidden = false;
    }
    _scheduleLyricsControlsHide();
  }

  void _onInspectorChanged() {
    if (mounted) setState(() {});
  }

  /// Whether the lyrics (1) or Up Next (2) toggle shows as selected. The
  /// embedded player shows them in the desktop inspector instead.
  bool _showsPage(int page) => widget.embedded
      ? desktopInspectorPanel.value ==
            (page == 1
                ? DesktopInspectorPanel.lyrics
                : DesktopInspectorPanel.upNext)
      : _currentPage == page;

  /// Opens lyrics (1) or Up Next (2) in the desktop inspector when embedded.
  /// Returns false when the player should switch pages itself.
  bool _toggleInspector(int page) {
    if (!widget.embedded) return false;
    if (page == 1 || page == 2) {
      toggleDesktopInspector(
        page == 1 ? DesktopInspectorPanel.lyrics : DesktopInspectorPanel.upNext,
      );
    }
    return true;
  }

  String _minimizeTooltip(BuildContext context) => desktopTooltip(
    context,
    context.l10n.nowPlayingMinimize,
    DesktopCommand.dismiss,
  );

  void _minimize() {
    if (widget.embedded) {
      desktopNowPlayingOpen.value = false;
    } else {
      unawaited(Navigator.of(context).maybePop());
    }
  }

  @override
  void dispose() {
    if (widget.embedded) {
      desktopInspectorPanel.removeListener(_onInspectorChanged);
    }
    _artworkRoute?.readArtwork = null;
    _lyricsIdleTimer?.cancel();
    _mediaItemSub?.close();
    _lyricsPlayingSub?.close();
    _trackMetadata.dispose();
    _artworkForeground.dispose();
    _seekPreview.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final mediaItem = ref.watch(currentMediaItemProvider).value;
    final fullScreenCover = ref.watch(
      settingsProvider.select((s) => s.playerCoverStyle == 'fullscreen'),
    );
    return LyricsScreenAwake(
      visible: _currentPage == 1 && mediaItem != null,
      child: context.isMornye
          ? _buildPlayer(context, mediaItem, fullScreenCover: fullScreenCover)
          // Material takes the track's artwork scheme. The providers it needs
          // are read above, so the scoped builder reads none.
          : PlayerArtworkTheme(
              artUri: mediaItem?.artUri?.toString(),
              child: Builder(
                builder: (context) => _buildPlayer(
                  context,
                  mediaItem,
                  fullScreenCover: fullScreenCover,
                ),
              ),
            ),
    );
  }

  Widget _buildPlayer(
    BuildContext context,
    MediaItem? mediaItem, {
    required bool fullScreenCover,
  }) {
    final mornye = context.isMornye;
    final colorScheme = mornye
        ? MornyeTheme.fromContext(
            context,
            brightness: Brightness.dark,
          ).colorScheme
        : Theme.of(context).colorScheme;

    if (mediaItem == null) {
      return Scaffold(
        appBar: AppBar(
          leading: AppIconButton(
            tooltip: _minimizeTooltip(context),
            icon: const AppIcon(Icons.keyboard_arrow_down),
            onPressed: _minimize,
          ),
        ),
        body: Center(child: Text(context.l10n.nowPlayingNothingPlaying)),
      );
    }

    final source = mediaItem.extras?['source']?.toString() ?? '';
    final motionState =
        mornye &&
            ref.watch(settingsProvider.select((s) => s.motionArtworkEnabled)) &&
            !MediaQuery.disableAnimationsOf(context)
        ? ref.watch(
            playerMotionArtworkProvider((
              album: mediaItem.album ?? '',
              artist: mediaItem.artist ?? '',
            )),
          )
        : null;
    final resolvedMotion = motionState?.value;
    final motionArtwork = resolvedMotion?.source == _failedMotionSource
        ? null
        : resolvedMotion;
    final motionRatio =
        motionArtwork?.aspectRatio ??
        (_measuredMotionSource == motionArtwork?.source
            ? _motionAspectRatio
            : null);
    final squareArtwork =
        motionArtwork == null || (motionRatio != null && motionRatio >= 0.95);
    // Motion artwork is always full-bleed in Mornye; still covers follow the
    // cover style setting through the same layout, as a square video would.
    final fullBleed = mornye && (motionArtwork != null || fullScreenCover);
    final screen = MediaQuery.sizeOf(context);
    // A still cover is cropped at the sides to reach down to the title, as
    // in the Material full-screen style; landscape keeps the square card.
    final stillFullBleed = fullBleed && motionArtwork == null;
    final artworkRatio = stillFullBleed
        ? _landscape || screen.height <= 0
              ? 1.0
              : (screen.width / (screen.height * 0.56)).clamp(0.5, 1.0)
        : motionRatio;
    // Two-pane landscape keeps its side-by-side cover.
    final materialFullScreen =
        !mornye &&
        fullScreenCover &&
        MediaQuery.orientationOf(context) == Orientation.portrait;
    final overCover = materialFullScreen && _currentPage != 1;
    if (!fullBleed && _artworkForeground.value.isNotEmpty) {
      _artworkForeground.value = {};
    }
    Widget artwork() => MornyePlayerArtwork(
      mediaItem: mediaItem,
      videoUrl: motionArtwork?.source,
      resolvingVideo: motionState?.isLoading == true,
      onAspectRatioChanged: (ratio) {
        if (!mounted ||
            (_measuredMotionSource == motionArtwork?.source &&
                _motionAspectRatio == ratio)) {
          return;
        }
        setState(() {
          _measuredMotionSource = motionArtwork?.source;
          _motionAspectRatio = ratio;
        });
      },
      onError: () {
        if (mounted) {
          setState(() => _failedMotionSource = motionArtwork?.source);
        }
      },
    );

    // The Mornye route moves the entire player together. A second,
    // delayed content fade would make dismissal appear to pause partway down.
    final route = ModalRoute.of(context);
    final routeAnimation = route?.animation ?? kAlwaysCompleteAnimation;
    if (_artworkRoute != route) {
      _artworkRoute?.readArtwork = null;
      _artworkRoute = null;
    }
    if (mornye && route is NowPlayingRoute) {
      _artworkRoute = route;
      route.readArtwork = () {
        final key = _landscape
            ? _expandedArtworkKey
            : _currentPage != 0
            ? _compactArtworkKey
            : fullBleed
            ? _motionArtworkKey
            : _expandedArtworkKey;
        final box = key.currentContext?.findRenderObject();
        if (box is! RenderBox || !box.attached || !box.hasSize) return null;
        final overlay = route.navigator?.overlay?.context.findRenderObject();
        return (
          bounds: MatrixUtils.transformRect(
            box.getTransformTo(overlay),
            Offset.zero & box.size,
          ),
          fullBleed: key == _motionArtworkKey,
          child: Theme(
            data: MornyeTheme.fromContext(context, brightness: Brightness.dark),
            child: key == _compactArtworkKey
                ? PlayerArtwork(
                    artUri: mediaItem.artUri?.toString(),
                    colorScheme: colorScheme,
                    cacheWidth: PlayerArtwork.transitionCacheWidth(context),
                  )
                : artwork(),
          ),
        );
      };
    }
    final contentOpacity = mornye
        ? kAlwaysCompleteAnimation
        : routeAnimation.drive(
            CurveTween(curve: const Interval(0.4, 1.0, curve: Curves.easeOut)),
          );

    // The embedded desktop player keeps a toolbar for its minimize button,
    // which a route reaches by swiping down instead.
    final double? mornyeToolbarHeight = !mornye
        ? null
        : widget.embedded
        ? 48
        : MediaQuery.orientationOf(context) == Orientation.landscape
        ? 0
        : 36;
    final player = Scaffold(
      backgroundColor: mornye || materialFullScreen
          ? Colors.transparent
          : colorScheme.surface,
      appBar: _FadingAppBar(
        opacity: contentOpacity,
        child: AppBar(
          backgroundColor: mornye || materialFullScreen
              ? Colors.transparent
              : colorScheme.surface,
          foregroundColor: overCover ? Colors.white : colorScheme.onSurface,
          surfaceTintColor: Colors.transparent,
          systemOverlayStyle: mornye || overCover
              ? SystemUiOverlayStyle.light
              : null,
          toolbarHeight: mornyeToolbarHeight ?? kToolbarHeight,
          automaticallyImplyLeading: false,
          title: mornye
              ? MediaQuery.orientationOf(context) == Orientation.landscape ||
                        widget.embedded
                    ? null
                    : IconButton(
                        tooltip: context.l10n.nowPlayingMinimize,
                        onPressed: _minimize,
                        icon: Container(
                          width: 36,
                          height: 5,
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.4),
                            borderRadius: BorderRadius.circular(3),
                          ),
                        ),
                      )
              : Text(
                  context.l10n.nowPlayingTitle,
                  // The app theme's title style carries its own colour.
                  style: overCover
                      ? const TextStyle(color: Colors.white)
                      : null,
                ),
          centerTitle: true,
          leading: mornye && !widget.embedded
              ? null
              : AppIconButton(
                  key: const ValueKey('now-playing-minimize'),
                  tooltip: _minimizeTooltip(context),
                  color: overCover || mornye ? Colors.white : null,
                  icon: const AppIcon(Icons.keyboard_arrow_down),
                  onPressed: _minimize,
                ),
          actions: mornye
              ? null
              : [
                  LinkDevicesButton(color: overCover ? Colors.white : null),
                  AppIconButton(
                    tooltip: context.l10n.nowPlayingUpNext,
                    color: overCover ? Colors.white : null,
                    icon: const AppIcon(Icons.queue_music),
                    onPressed: () => _showQueueSheet(context, colorScheme),
                  ),
                  AppIconButton(
                    color: overCover ? Colors.white : null,
                    tooltip: MaterialLocalizations.of(
                      context,
                    ).moreButtonTooltip,
                    icon: const AppIcon(Icons.more_vert),
                    onPressed: () => _showMoreActions(
                      context: context,
                      mediaItem: mediaItem,
                      source: source,
                      colorScheme: colorScheme,
                    ),
                  ),
                ],
        ),
      ),
      body: FadeTransition(
        opacity: contentOpacity,
        child: SafeArea(
          child: Column(
            children: [
              Expanded(
                child: mornye
                    ? NotificationListener<ScrollUpdateNotification>(
                        onNotification: _onLyricsScroll,
                        child: MornyePlayerLayout(
                          mediaItem: mediaItem,
                          metadata: _trackMetadata,
                          seekPreview: _seekPreview,
                          colorScheme: colorScheme,
                          page: _currentPage,
                          motionArtwork: artwork(),
                          artworkAspectRatio: artworkRatio,
                          insetArtwork: !fullBleed,
                          artworkTopInset:
                              MediaQuery.paddingOf(context).top +
                              (widget.embedded ? mornyeToolbarHeight! : 36),
                          artworkKeys: (
                            header: _artworkHeaderKey,
                            controls: _artworkControlsKey,
                            volume: _artworkVolumeKey,
                            expanded: _expandedArtworkKey,
                            compact: _compactArtworkKey,
                          ),
                          artworkForeground: _artworkForeground,
                          lyricsControlsHidden: _lyricsControlsHidden,
                          lyricsOptionsOpen: _lyricsOptionsOpen,
                          lyricsBuilder: (showOptions) => _lyricsSection(
                            colorScheme,
                            isActive: _currentPage == 1,
                            showOptions: showOptions,
                          ),
                          lyricsOptions: _lyricsOptionsButton(colorScheme),
                          onPageChanged: _setMornyePage,
                          onTrackNavigation: _showTrackNavigationMenu,
                          onMoreActions: (buttonContext, item, anchor) =>
                              _showMoreActions(
                                context: buttonContext,
                                mediaItem: item,
                                source:
                                    item.extras?['source']?.toString() ?? '',
                                colorScheme: colorScheme,
                                anchor: anchor,
                              ),
                        ),
                      )
                    : MaterialPlayerLayout(
                        mediaItem: mediaItem,
                        metadata: _trackMetadata,
                        seekPreview: _seekPreview,
                        colorScheme: colorScheme,
                        showLyrics: _currentPage == 1,
                        fullScreenArtwork: materialFullScreen,
                        lyricsBuilder: (_) =>
                            _lyricsSection(colorScheme, isActive: true),
                        onOpenQueue: () =>
                            _showQueueSheet(context, colorScheme),
                      ),
              ),
              _autoHidingLyricsControls(
                PlayerQueueSwipeRegion(
                  onOpenQueue: () => _showQueueSheet(context, colorScheme),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (mornye && !_landscape)
                        FractionallySizedBox(
                          widthFactor: 0.72,
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              IconButton(
                                tooltip: _currentPage == 1
                                    ? context.l10n.nowPlayingTabPlayer
                                    : context.l10n.nowPlayingTabLyrics,
                                isSelected: _showsPage(1),
                                color: Colors.white,
                                style: IconButton.styleFrom(
                                  backgroundColor: _showsPage(1)
                                      ? Colors.white.withValues(alpha: 0.16)
                                      : Colors.transparent,
                                ),
                                icon: const AppIcon(
                                  CupertinoIcons.quote_bubble,
                                ),
                                onPressed: _toggleMornyeLyrics,
                              ),
                              AudioOutputButton(
                                color: Colors.white,
                                onPickerChanged: (open) {
                                  if (!mounted) return;
                                  setState(() => _audioOutputOpen = open);
                                  _scheduleLyricsControlsHide();
                                },
                              ),
                              // The row spreads its buttons apart, so the
                              // Devices entry only takes a slot when paired.
                              if (ref.watch(linkPhoneClientProvider) != null)
                                const LinkDevicesButton(color: Colors.white),
                              IconButton(
                                tooltip: context.l10n.nowPlayingUpNext,
                                color: Colors.white,
                                isSelected: _showsPage(2),
                                style: IconButton.styleFrom(
                                  backgroundColor: _showsPage(2)
                                      ? Colors.white.withValues(alpha: 0.16)
                                      : Colors.transparent,
                                ),
                                icon: const AppIcon(CupertinoIcons.list_bullet),
                                onPressed: () =>
                                    _setMornyePage(_currentPage == 2 ? 0 : 2),
                              ),
                            ],
                          ),
                        )
                      else if (!mornye)
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 28),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              ExpressiveIconButton(
                                key: const ValueKey('material-lyrics-toggle'),
                                tooltip: _currentPage == 1
                                    ? context.l10n.nowPlayingTabPlayer
                                    : context.l10n.nowPlayingTabLyrics,
                                selected: _showsPage(1),
                                foregroundColor: _showsPage(1)
                                    ? colorScheme.onPrimaryContainer
                                    : colorScheme.onSurfaceVariant,
                                backgroundColor: _showsPage(1)
                                    ? colorScheme.primaryContainer
                                    : null,
                                icon: const AppIcon(Icons.lyrics_outlined),
                                onPressed: _toggleMaterialLyrics,
                              ),
                              PlayerPlaybackModeToolbar(
                                colorScheme: colorScheme,
                              ),
                              AudioOutputButton(
                                color: colorScheme.onSurfaceVariant,
                              ),
                            ],
                          ),
                        ),
                      if (!_landscape)
                        LinkPlayingOnLabel(color: mornye ? Colors.white : null),
                      if (!_landscape) const SizedBox(height: 8),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (!mornye) {
      if (!materialFullScreen) return player;
      return Stack(
        fit: StackFit.expand,
        children: [
          MaterialPlayerBackdrop(
            mediaItem: mediaItem,
            colorScheme: colorScheme,
            showArtwork: _currentPage != 1,
          ),
          player,
        ],
      );
    }
    return HeroMode(
      // A route Hero renders outside the panel's gradient and slide, briefly
      // exposing a detached rectangle. Keep Mornye artwork inside its panel.
      enabled: false,
      child: Theme(
        data: MornyeTheme.fromContext(context, brightness: Brightness.dark),
        child: Stack(
          fit: StackFit.expand,
          children: [
            MornyeArtworkContrast(
              enabled: fullBleed && !_landscape && _currentPage == 0,
              continuous: motionArtwork != null,
              targets: {
                'header': _artworkHeaderKey,
                'controls': _artworkControlsKey,
                'volume': _artworkVolumeKey,
              },
              onChanged: (colors) {
                if (!mounted) return;
                _artworkForeground.value = colors;
              },
              child: MornyePlayerBackground(
                artUri: mediaItem.artUri,
                squareArtwork: squareArtwork,
                artworkAspectRatio: artworkRatio,
                fadeStart: stillFullBleed ? 0.72 : 0.58,
                artwork: fullBleed && !_landscape && _currentPage == 0
                    ? PlayerTransitionArtwork(
                        artworkKey: _motionArtworkKey,
                        child: Hero(
                          tag: kNowPlayingArtworkHeroTag,
                          child: artwork(),
                        ),
                      )
                    : null,
              ),
            ),
            Listener(
              behavior: HitTestBehavior.translucent,
              onPointerDown: (event) {
                if (!_canAutoHideLyricsControls) return;
                if (_lyricsPointers.isEmpty) _lyricsPointerMoved = false;
                _lyricsPointers[event.pointer] = event.position;
                _lyricsIdleTimer?.cancel();
              },
              onPointerMove: (event) {
                final origin = _lyricsPointers[event.pointer];
                if (origin != null && (event.position - origin).distance > 12) {
                  _lyricsPointerMoved = true;
                }
              },
              onPointerUp: (event) => _endLyricsInteraction(event.pointer),
              onPointerCancel: (event) =>
                  _endLyricsInteraction(event.pointer, cancelled: true),
              child: player,
            ),
          ],
        ),
      ),
    );
  }

  void _toggleMaterialLyrics() {
    if (_toggleInspector(1)) return;
    setState(() => _currentPage = _currentPage == 1 ? 0 : 1);
    if (_currentPage == 1) {
      unawaited(
        _trackMetadata.load(
          ref.read(currentMediaItemProvider).value,
          inspectUnresolvedContentUri: true,
        ),
      );
    }
  }

  void _toggleMornyeLyrics() {
    _setMornyePage(_currentPage == 1 ? 0 : 1);
  }

  void _setMornyePage(int page) {
    if (_toggleInspector(page)) return;
    setState(() {
      _currentPage = page;
      _lyricsControlsHidden = false;
      _lyricsScrollDistance = 0;
    });
    _scheduleLyricsControlsHide();
    if (_currentPage == 1) {
      unawaited(
        _trackMetadata.load(
          ref.read(currentMediaItemProvider).value,
          inspectUnresolvedContentUri: true,
        ),
      );
    }
  }

  bool get _canAutoHideLyricsControls =>
      context.isMornye &&
      !_landscape &&
      _currentPage == 1 &&
      ref.read(playbackPlayingProvider) &&
      !MediaQuery.accessibleNavigationOf(context);

  void _scheduleLyricsControlsHide() {
    _lyricsIdleTimer?.cancel();
    if (!_canAutoHideLyricsControls ||
        _lyricsOptionsOpen ||
        _audioOutputOpen ||
        _lyricsControlsHidden ||
        _lyricsPointers.isNotEmpty) {
      return;
    }
    _lyricsIdleTimer = Timer(const Duration(seconds: 5), () {
      if (!mounted || !_canAutoHideLyricsControls) return;
      if (ModalRoute.of(context)?.isCurrent == false) {
        _scheduleLyricsControlsHide();
        return;
      }
      setState(() => _lyricsControlsHidden = true);
    });
  }

  void _endLyricsInteraction(int pointer, {bool cancelled = false}) {
    if (_lyricsPointers.remove(pointer) == null || _lyricsPointers.isNotEmpty) {
      return;
    }
    if (!cancelled && !_lyricsPointerMoved && _lyricsControlsHidden) {
      setState(() => _lyricsControlsHidden = false);
    }
    _scheduleLyricsControlsHide();
  }

  bool _onLyricsScroll(ScrollUpdateNotification notification) {
    if (_currentPage != 1 ||
        _landscape ||
        notification.dragDetails == null ||
        notification.metrics.axis != Axis.vertical) {
      return false;
    }
    final delta = notification.scrollDelta ?? 0;
    if (delta.sign != _lyricsScrollDistance.sign) _lyricsScrollDistance = 0;
    _lyricsScrollDistance += delta;
    if (_lyricsScrollDistance.abs() >= 16) {
      final hidden = _lyricsScrollDistance > 0;
      if (hidden != _lyricsControlsHidden) {
        setState(() => _lyricsControlsHidden = hidden);
      }
      _lyricsScrollDistance = 0;
    }
    return false;
  }

  Widget _autoHidingLyricsControls(Widget child) => context.isMornye
      ? PlayerLyricsControlsVisibility(
          hidden: _currentPage == 1 && _lyricsControlsHidden && !_landscape,
          child: child,
        )
      : child;

  Widget _lyricsSection(
    ColorScheme colorScheme, {
    required bool isActive,
    bool showOptions = true,
  }) => PlayerLyricsSection(
    metadata: _trackMetadata,
    seekPreview: _seekPreview,
    colorScheme: colorScheme,
    isActive: isActive,
    options: showOptions && isActive && !_landscape
        ? _autoHidingLyricsControls(_lyricsOptionsButton(colorScheme))
        : null,
    onShareLyrics: _shareLyrics,
  );

  Future<void> _shareLyrics([LyricLine? line]) async {
    if (_sharingLyrics) return;
    final mediaItem = ref.read(currentMediaItemProvider).value;
    if (mediaItem == null) return;
    _sharingLyrics = true;
    try {
      // The menu offers sharing before the lyrics page has read the file, so
      // read it now (including an unresolved document) and wait for parsing.
      if (_trackMetadata.lyrics.isEmpty) {
        await _trackMetadata.load(mediaItem, inspectUnresolvedContentUri: true);
        await _untilMetadataLoaded();
      }
      if (!mounted ||
          ref.read(currentMediaItemProvider).value?.id != mediaItem.id) {
        return;
      }
      if (_trackMetadata.lyrics.isEmpty) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            SnackBar(content: Text(context.l10n.nowPlayingNoLyrics)),
          );
        return;
      }
      await openLyricsShare(
        context,
        mediaItem: mediaItem,
        lyrics: _trackMetadata.lyrics,
        initial: line,
      );
    } finally {
      _sharingLyrics = false;
    }
  }

  /// Completes once a load already in flight (started elsewhere) finishes.
  Future<void> _untilMetadataLoaded() {
    if (!_trackMetadata.loading) return Future.value();
    final done = Completer<void>();
    void listener() {
      if (_trackMetadata.loading || done.isCompleted) return;
      _trackMetadata.removeListener(listener);
      done.complete();
    }

    _trackMetadata.addListener(listener);
    return done.future.timeout(
      const Duration(seconds: 10),
      onTimeout: () => _trackMetadata.removeListener(listener),
    );
  }

  Widget _lyricsOptionsButton(ColorScheme colorScheme) => ListenableBuilder(
    listenable: _trackMetadata,
    builder: (context, _) =>
        _buildLyricsOptionsButton(colorScheme) ?? const SizedBox.shrink(),
  );

  Widget? _buildLyricsOptionsButton(ColorScheme colorScheme) {
    if (_trackMetadata.loading || !_trackMetadata.lyrics.synced) return null;
    final pronunciation = _trackMetadata.lyrics.lines.any(
      (line) => line.romanization?.trim().isNotEmpty == true,
    );
    final translation = _trackMetadata.lyrics.lines.any(
      (line) => line.translation?.trim().isNotEmpty == true,
    );
    if (!pronunciation && !translation) return null;
    return Builder(
      builder: (buttonContext) => AppIconButton.filledTonal(
        key: const ValueKey('lyrics-language-options'),
        tooltip: context.l10n.nowPlayingLyricsLanguageOptions,
        icon: const AppIcon(Icons.translate_rounded),
        style: IconButton.styleFrom(
          foregroundColor: _lyricsOptionsOpen
              ? colorScheme.surface
              : colorScheme.onSurface,
          backgroundColor: colorScheme.onSurface.withValues(
            alpha: _lyricsOptionsOpen ? 0.85 : 0.16,
          ),
        ),
        onPressed: () => _showLyricsOptions(
          buttonContext,
          pronunciation: pronunciation,
          translation: translation,
        ),
      ),
    );
  }

  Future<void> _showLyricsOptions(
    BuildContext buttonContext, {
    required bool pronunciation,
    required bool translation,
  }) async {
    final settings = ref.read(settingsProvider);
    final l10n = context.l10n;
    final actions = <(String, String, IconData)>[
      if (pronunciation)
        (
          'pronunciation',
          settings.playerShowPronunciation
              ? l10n.nowPlayingHidePronunciation
              : l10n.nowPlayingShowPronunciation,
          settings.playerShowPronunciation
              ? Icons.voice_over_off_outlined
              : Icons.record_voice_over_outlined,
        ),
      if (translation)
        (
          'translation',
          settings.playerShowTranslation
              ? l10n.nowPlayingHideTranslation
              : l10n.nowPlayingShowTranslation,
          Icons.translate_rounded,
        ),
    ];
    _lyricsIdleTimer?.cancel();
    setState(() => _lyricsOptionsOpen = true);
    try {
      final anchor = mornyeMenuAnchor(buttonContext);
      var menuWidth = 240.0;
      for (final (_, label, _) in actions) {
        final painter = TextPainter(
          text: TextSpan(
            text: label,
            style: Theme.of(
              context,
            ).textTheme.bodyLarge?.copyWith(fontSize: 15),
          ),
          textDirection: Directionality.of(context),
          textScaler: MediaQuery.textScalerOf(context),
        )..layout();
        if (painter.width + 80 > menuWidth) menuWidth = painter.width + 80;
        painter.dispose();
      }
      final action = context.isMornye
          ? await showMornyeContextMenu<String>(
              context: buttonContext,
              anchor: anchor,
              preferAbove: true,
              maxWidth: menuWidth,
              builder: (menuContext) => MornyeContextMenu(
                dense: true,
                groups: [
                  [
                    for (final (value, label, icon) in actions)
                      MornyeMenuAction(
                        icon: icon,
                        label: label,
                        onPressed: () => Navigator.of(menuContext).pop(value),
                      ),
                  ],
                ],
              ),
            )
          : await showMenu<String>(
              context: buttonContext,
              position: RelativeRect.fromRect(
                anchor ?? Rect.zero,
                Offset.zero & MediaQuery.sizeOf(context),
              ),
              items: [
                for (final (value, label, icon) in actions)
                  PopupMenuItem(
                    value: value,
                    child: Row(
                      children: [
                        AppIcon(icon),
                        const SizedBox(width: 12),
                        Flexible(child: Text(label)),
                      ],
                    ),
                  ),
              ],
            );
      if (!mounted) return;
      final notifier = ref.read(settingsProvider.notifier);
      if (action == 'pronunciation') {
        notifier.setPlayerShowPronunciation(!settings.playerShowPronunciation);
      } else if (action == 'translation') {
        notifier.setPlayerShowTranslation(!settings.playerShowTranslation);
      }
    } finally {
      if (mounted) {
        setState(() => _lyricsOptionsOpen = false);
        _scheduleLyricsControlsHide();
      }
    }
  }

  Future<void> _openExternally(String source) async {
    if (source.isEmpty) return;
    try {
      await openFile(source);
    } catch (e) {
      if (!mounted) return;
      showCannotOpenFileSnackBar(context, e);
    }
  }

  Future<void> _showTrackNavigationMenu(
    BuildContext titleContext,
    MediaItem mediaItem,
  ) async {
    final action = await showMornyeContextMenu<String>(
      context: titleContext,
      preferAbove: true,
      maxWidth: 280,
      builder: (_) => MornyePlayerNavigationMenu(mediaItem: mediaItem),
    );
    if (!mounted) return;
    if (action == 'album') {
      await _goToCurrentAlbum(
        mediaItem: mediaItem,
        source: mediaItem.extras?['source']?.toString() ?? '',
      );
    } else if (action == 'artist') {
      await _goToCurrentArtist(mediaItem);
    }
  }

  Future<void> _goToCurrentArtist(MediaItem mediaItem) async {
    final track = ref.read(playerCollectionTrackProvider(mediaItem)).value;
    // A downloaded track's source is the service its audio came from, not a
    // metadata catalog; the lookup uses the user's search provider instead.
    await navigateToArtist(
      context,
      artistName: mediaItem.artist ?? '',
      artistId: track?.artistId,
    );
  }

  Future<void> _updatePlayerCollection(
    MediaItem item, {
    required bool favorite,
  }) async {
    try {
      final provider = playerCollectionTrackProvider(item);
      if (ref.read(provider).hasError) ref.invalidate(provider);
      final track = await ref.read(provider.future);
      if (!mounted) return;
      if (favorite) {
        await ref.read(libraryCollectionsProvider.notifier).toggleLoved(track);
      } else {
        await showAddTrackToPlaylistSheet(context, ref, track);
      }
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            context.l10n.snackbarError(context.friendlyError(error)),
          ),
        ),
      );
    }
  }

  Future<void> _showMoreActions({
    required BuildContext context,
    required MediaItem mediaItem,
    required String source,
    required ColorScheme colorScheme,
    Rect? anchor,
  }) async {
    final controller = ref.read(musicPlayerControllerProvider);
    final sleepTimerEndsAt = controller.sleepTimerEndsAt;
    final sleepTimerSubtitle = sleepTimerEndsAt == null
        ? null
        : context.l10n.nowPlayingSleepTimerActive(
            MaterialLocalizations.of(
              context,
            ).formatTimeOfDay(TimeOfDay.fromDateTime(sleepTimerEndsAt)),
          );
    final volumeShown = ref.read(settingsProvider).playerShowVolume;
    final action = context.isMornye
        ? await showMornyeContextMenu<String>(
            context: context,
            anchor: anchor,
            preferAbove: true,
            maxWidth: 280,
            builder: (_) => MornyePlayerActionsSheet(
              mediaItem: mediaItem,
              sleepTimerSubtitle: sleepTimerSubtitle,
              volumeShown: volumeShown,
            ),
          )
        : await showAppBottomSheet<String>(
            context: context,
            useRootNavigator: true,
            backgroundColor: colorScheme.surfaceContainerHigh,
            title: mediaItem.title,
            subtitle: mediaItem.artist,
            builder: (sheetContext) => Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: SettingsGroup(
                children: [
                  if ((mediaItem.album ?? '').trim().isNotEmpty)
                    SettingsItem(
                      icon: Icons.album_outlined,
                      title: sheetContext.l10n.homeGoToAlbum,
                      onTap: () => Navigator.of(sheetContext).pop('album'),
                    ),
                  SettingsItem(
                    icon: Icons.info_outline,
                    title: sheetContext.l10n.nowPlayingDetails,
                    onTap: () => Navigator.of(sheetContext).pop('details'),
                  ),
                  SettingsItem(
                    icon: Icons.format_quote_outlined,
                    title: sheetContext.l10n.lyricsShareTitle,
                    onTap: () => Navigator.of(sheetContext).pop('shareLyrics'),
                  ),
                  SettingsItem(
                    icon: Icons.bedtime_outlined,
                    title: sheetContext.l10n.nowPlayingSleepTimer,
                    subtitle: sleepTimerSubtitle,
                    onTap: () => Navigator.of(sheetContext).pop('sleepTimer'),
                  ),
                  SettingsItem(
                    icon: Icons.equalizer,
                    title: sheetContext.l10n.equalizerTitle,
                    onTap: () => Navigator.of(sheetContext).pop('equalizer'),
                  ),
                  SettingsItem(
                    icon: volumeShown
                        ? Icons.volume_off_outlined
                        : Icons.volume_up_outlined,
                    title: volumeShown
                        ? sheetContext.l10n.nowPlayingHideVolume
                        : sheetContext.l10n.nowPlayingShowVolume,
                    onTap: () => Navigator.of(sheetContext).pop('volume'),
                  ),
                  SettingsItem(
                    icon: Icons.open_in_new,
                    title: sheetContext.l10n.nowPlayingOpenInExternalPlayer,
                    trailing: AppIcon(
                      Icons.open_in_new,
                      size: 18,
                      color: Theme.of(
                        sheetContext,
                      ).colorScheme.onSurfaceVariant,
                    ),
                    showDivider: false,
                    onTap: () => Navigator.of(sheetContext).pop('external'),
                  ),
                ],
              ),
            ),
          );
    if (!mounted || !context.mounted) return;
    switch (action) {
      case 'favorite':
        await _updatePlayerCollection(mediaItem, favorite: true);
        break;
      case 'playlist':
        await _updatePlayerCollection(mediaItem, favorite: false);
        break;
      case 'artist':
        await _goToCurrentArtist(mediaItem);
        break;
      case 'share':
        await SharePlus.instance.share(
          ShareParams(
            text: '${mediaItem.title} — ${mediaItem.artist ?? ''}',
            sharePositionOrigin:
                anchor ??
                Rect.fromCenter(
                  center: MediaQuery.sizeOf(context).center(Offset.zero),
                  width: 1,
                  height: 1,
                ),
          ),
        );
        break;
      case 'album':
        await _goToCurrentAlbum(mediaItem: mediaItem, source: source);
        break;
      case 'shareLyrics':
        await _shareLyrics();
        break;
      case 'details':
        unawaited(
          showPlayerDetailsSheet(
            context,
            colorScheme,
            metadata: _trackMetadata,
            mediaItem: ref.read(currentMediaItemProvider).value,
          ),
        );
        break;
      case 'sleepTimer':
        await _showSleepTimerSheet(context, controller, colorScheme);
        break;
      case 'equalizer':
        await pushPage<void>(context, (_) => const EqualizerScreen());
        break;
      case 'volume':
        ref.read(settingsProvider.notifier).setPlayerShowVolume(!volumeShown);
        break;
      case 'external':
        await _openExternally(source);
        break;
    }
  }

  Future<void> _showSleepTimerSheet(
    BuildContext context,
    MusicPlayerController controller,
    ColorScheme colorScheme,
  ) async {
    const durations = [15, 30, 45, 60];
    final isActive = controller.sleepTimerEndsAt != null;
    final selection = await showAppBottomSheet<String>(
      context: context,
      useRootNavigator: true,
      backgroundColor: colorScheme.surfaceContainerHigh,
      title: context.l10n.nowPlayingSleepTimer,
      builder: (sheetContext) => Padding(
        padding: const EdgeInsets.only(bottom: 16),
        child: SettingsGroup(
          children: [
            for (final minutes in durations)
              SettingsItem(
                icon: Icons.timer_outlined,
                title: sheetContext.l10n.nowPlayingSleepTimerMinutes(minutes),
                showDivider: isActive || minutes != durations.last,
                onTap: () => Navigator.of(sheetContext).pop('$minutes'),
              ),
            if (isActive)
              SettingsItem(
                icon: Icons.timer_off_outlined,
                title: sheetContext.l10n.nowPlayingSleepTimerOff,
                showDivider: false,
                onTap: () => Navigator.of(sheetContext).pop('off'),
              ),
          ],
        ),
      ),
    );
    if (!mounted || !context.mounted || selection == null) return;

    if (selection == 'off') {
      controller.cancelSleepTimer();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.l10n.nowPlayingSleepTimerCancelled)),
      );
      return;
    }

    final minutes = int.tryParse(selection);
    if (minutes == null) return;
    controller.setSleepTimer(Duration(minutes: minutes));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          context.l10n.nowPlayingSleepTimerSet(
            context.l10n.nowPlayingSleepTimerMinutes(minutes),
          ),
        ),
      ),
    );
  }

  Future<void> _goToCurrentAlbum({
    required MediaItem mediaItem,
    required String source,
  }) async {
    final albumName = (mediaItem.album ?? '').trim();
    if (albumName.isEmpty) return;

    // Prefer the stored collection so this action remains useful offline and
    // opens the exact files the user is currently playing.
    try {
      final historyItem = source.isEmpty
          ? null
          : await ref
                .read(downloadHistoryProvider.notifier)
                .getByFilePathAsync(source);
      if (!mounted) return;
      if (historyItem != null) {
        final albumArtist = (historyItem.albumArtist ?? '').trim();
        pushViaPreferredNavigator(
          context,
          (_) => DownloadedAlbumScreen(
            albumName: historyItem.albumName,
            artistName: albumArtist.isNotEmpty
                ? albumArtist
                : historyItem.artistName,
            coverUrl: historyItem.coverUrl,
          ),
        );
        return;
      }
    } catch (e) {
      _log.w('Failed to resolve downloaded album: $e');
    }

    try {
      final album = await ref
          .read(musicPlayerControllerProvider)
          .localAlbumFor(mediaItem.id);
      if (!mounted) return;
      if (album != null) {
        final (:item, :tracks) = album;
        final albumArtist = (item.albumArtist ?? '').trim();
        pushViaPreferredNavigator(
          context,
          (_) => LocalAlbumScreen(
            albumName: item.albumName,
            artistName: albumArtist.isNotEmpty ? albumArtist : item.artistName,
            coverPath: item.coverPath,
            tracks: tracks,
          ),
        );
        return;
      }
    } catch (e) {
      _log.w('Failed to resolve local album: $e');
    }

    if (!mounted) return;
    await navigateToAlbum(
      context,
      albumName: albumName,
      artistName: mediaItem.artist,
      coverUrl: mediaItem.artUri?.toString(),
    );
  }

  /// Opens Up Next. The Material sheet captures the theme of [context], the
  /// player's artwork scope.
  void _showQueueSheet(BuildContext context, ColorScheme colorScheme) {
    if (_toggleInspector(2)) return;
    if (context.isMornye) {
      _setMornyePage(2);
      return;
    }
    if (_queueSheetShowing) return;
    _queueSheetShowing = true;
    showPlayerQueueSheet(
      context,
      colorScheme,
    ).whenComplete(() => _queueSheetShowing = false);
  }
}
