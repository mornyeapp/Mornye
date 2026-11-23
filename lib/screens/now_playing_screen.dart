import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:material_ui/material_ui.dart';
import 'package:cupertino_ui/cupertino_ui.dart' show CupertinoIcons;
import 'package:flutter/services.dart' show SystemUiOverlayStyle;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/controllers/clickable_metadata.dart';
import 'package:mornye/controllers/player_track_navigation.dart';
import 'package:mornye/controllers/player_metadata_controller.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/settings.dart' show playerCoverFadeStart;
import 'package:mornye/providers/library_collections_provider.dart';
import 'package:mornye/providers/lyrics_translation_provider.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/providers/song_lyrics_offset_provider.dart';
import 'package:mornye/routes/now_playing_route.dart';
import 'package:mornye/screens/equalizer_screen.dart';
import 'package:mornye/screens/lyrics_share_screen.dart';
import 'package:mornye/theme/cover_palette.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/theme/player_artwork_theme.dart';
import 'package:mornye/utils/file_access.dart';
import 'package:mornye/utils/logger.dart';
import 'package:mornye/utils/lyrics_parser.dart';
import 'package:mornye/utils/playback_seek_preview.dart';
import 'package:mornye/utils/synced_lyrics_scroll.dart';
import 'package:mornye/utils/view_display.dart';
import 'package:mornye/widgets/app_bottom_sheet.dart';
import 'package:mornye/widgets/app_snack_bar.dart';
import 'package:mornye/widgets/app_icon.dart';
import 'package:mornye/widgets/app_icon_button.dart';
import 'package:mornye/widgets/expressive_icon_button.dart';
import 'package:mornye/widgets/audio_output_button.dart';
import 'package:mornye/widgets/desktop/desktop_commands.dart'
    show DesktopCommand, desktopTooltip;
import 'package:mornye/widgets/desktop/desktop_inspector.dart';
import 'package:mornye/widgets/link/link_actions.dart';
import 'package:mornye/widgets/network_offline_actions.dart';
import 'package:mornye/widgets/link/link_devices_sheet.dart';
import 'package:mornye/widgets/playback_source_label.dart';
import 'package:mornye/widgets/playback_tempo_sheet.dart';
import 'package:mornye/widgets/lyrics_options_button.dart';
import 'package:mornye/widgets/lyrics_options_activity.dart';
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
import 'package:mornye/widgets/song_share_sheet.dart';
import 'package:mornye/widgets/mornye_player_background.dart';
import 'package:mornye/widgets/mornye_artwork_contrast.dart';
import 'package:mornye/widgets/mornye_player_actions_sheet.dart';
import 'package:mornye/widgets/mornye_context_menu.dart';
import 'package:mornye/widgets/mornye_cover_glow.dart';
import 'package:mornye/widgets/mornye_motion_glow.dart';
import 'package:mornye/widgets/mornye_player_artwork.dart';
import 'package:mornye/providers/player_motion_artwork_provider.dart';
import 'package:mornye/services/motion_artwork_store.dart';

export 'package:mornye/routes/now_playing_route.dart';

final _log = AppLogger('NowPlaying');

/// Portrait's "Playing on" row, kept while empty.
/// Light bar icons over the player. `SystemUiOverlayStyle.light` would also
/// paint Android's navigation bar black, cutting the background off above it.
const _overCoverBars = SystemUiOverlayStyle(
  statusBarBrightness: Brightness.dark,
  statusBarIconBrightness: Brightness.light,
  systemNavigationBarColor: Colors.transparent,
  systemNavigationBarDividerColor: Colors.transparent,
  systemNavigationBarIconBrightness: Brightness.light,
  systemNavigationBarContrastEnforced: false,
);

const _playingOnRowHeight = 36.0;

/// Screens shorter than this keep Mornye's volume row clear by leaving the
/// empty row out; its cover and controls need the height.
const _mornyePlayingOnMinScreenHeight = 720.0;

/// What Mornye holds back above its volume row, so the toolbar reaches
/// Material's height while the track header stays level with Material's.
const _mornyeControlsHeadroom = 20.0;

/// How much of an iPhone's home indicator inset stays under that row. The
/// indicator sits in the screen's bottom 13pt, and the label's text ends 8pt
/// above the row's bottom, so it still clears the indicator.
const _homeIndicatorBelowRow = 12.0;

/// AppBar wrapper that fades with the route transition (see contentOpacity
/// in [_NowPlayingScreenState.build]).
class _FadingAppBar extends StatelessWidget implements PreferredSizeWidget {
  final Animation<double> opacity;
  final AppBar child;

  /// Material's immersive lyrics fade the bar's buttons away too.
  final bool hidden;

  const _FadingAppBar({
    required this.opacity,
    required this.child,
    this.hidden = false,
  });

  @override
  Size get preferredSize => child.preferredSize;

  @override
  Widget build(BuildContext context) => FadeTransition(
    opacity: opacity,
    child: PlayerLyricsControlsVisibility(hidden: hidden, child: child),
  );
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
  ProviderSubscription<(bool, bool)>? _lyricsAutoHideSub;
  ProviderSubscription<bool>? _lyricsLayoutSub;
  ProviderSubscription<String?>? _nextColoursSub;
  ProviderSubscription<bool>? _lyricLineSub;

  /// Whether to read the song file itself, even an SAF document playback
  /// plays directly (it publishes no resolved copy then): only while lyrics
  /// show, on the lyrics page or in the lyric line under the title.
  bool get _readsSongFile =>
      _currentPage == 1 || ref.read(settingsProvider).playerShowLyricSnippet;
  late final _trackMetadata =
      widget.metadataControllerFactory?.call() ?? PlayerMetadataController();
  late final LyricsTranslationController _lyricsTranslation;
  late int _currentPage = widget.initialPage;
  bool _landscape = false;
  bool _queueSheetShowing = false;
  String? _measuredMotionSource;
  double? _motionAspectRatio;
  String? _failedMotionSource;

  /// The motion artwork last shown, kept while the next song's is looked up,
  /// and the shape its layout used.
  MotionArtwork? _shownMotionArtwork;
  double? _shownMotionRatio;
  bool _lyricsControlsHidden = false;
  bool _lyricsControlsHiddenManually = false;
  bool _lyricsOptionsOpen = false;
  bool _audioOutputOpen = false;
  bool _sharingLyrics = false;
  double _lyricsScrollDistance = 0;
  Timer? _lyricsIdleTimer;
  String? _lastLyricsControlsStatus;
  final _lyricsPointers = <int, Offset>{};
  bool _lyricsPointerMoved = false;
  // Skipping, seeking or opening the queue from the compact player keeps it
  // compact; only a touch elsewhere restores the full player.
  bool _compactPlayerTouched = false;
  final _artworkHeaderKey = GlobalKey();
  final _artworkControlsKey = GlobalKey();
  final _artworkVolumeKey = GlobalKey();
  final _expandedArtworkKey = GlobalKey();
  final _compactArtworkKey = GlobalKey();
  final _motionArtworkKey = GlobalKey();
  final _artworkDim = ValueNotifier(0.0);

  /// The still cover [_artworkDim] belongs to, and what was read for the
  /// covers shown before: a cover seen again starts with its layer, so the
  /// player does not open bright and darken once the first reading lands.
  String? _artworkDimCover;
  static final _coverDim = <String, double>{};
  final _seekPreview = PlaybackSeekPreview();
  NowPlayingRoute? _artworkRoute;

  @override
  void initState() {
    super.initState();
    _lyricsTranslation = ref.read(lyricsTranslationProvider.notifier);
    if (widget.embedded) desktopInspectorPanel.addListener(_onInspectorChanged);
    _mediaItemSub = ref.listenManual<AsyncValue<MediaItem?>>(
      currentMediaItemProvider,
      (previous, next) {
        if (previous?.value?.id != next.value?.id) _seekPreview.reset();
        unawaited(
          _trackMetadata.load(
            next.value,
            inspectUnresolvedContentUri: _readsSongFile,
          ),
        );
      },
    );
    _lyricLineSub = ref.listenManual<bool>(
      settingsProvider.select((settings) => settings.playerShowLyricSnippet),
      (_, enabled) {
        if (!enabled) return;
        unawaited(
          _trackMetadata.load(
            ref.read(currentMediaItemProvider).value,
            inspectUnresolvedContentUri: true,
          ),
        );
      },
    );
    _lyricsPlayingSub = ref.listenManual<bool>(playbackPlayingProvider, (
      previous,
      playing,
    ) {
      if (!playing && _lyricsControlsHidden) {
        setState(_showLyricsControls);
      }
      _scheduleLyricsControlsHide();
    });
    _lyricsAutoHideSub = ref.listenManual<(bool, bool)>(
      settingsProvider.select(
        (settings) => (
          settings.autoHideLyricsControls,
          settings.autoHideLyricsControlsWithAccessibility,
        ),
      ),
      (_, _) {
        if (!_lyricsAutoHideEnabled) {
          _lyricsPointers.clear();
          _lyricsScrollDistance = 0;
          if (_lyricsControlsHidden) {
            setState(_showLyricsControls);
          }
        }
        _scheduleLyricsControlsHide();
      },
    );
    _lyricsLayoutSub = ref.listenManual<bool>(
      settingsProvider.select((settings) => settings.landscapeLyricsArtwork),
      (_, _) {
        if (!_lyricsAutoHideLayout && _lyricsControlsHidden) {
          setState(_showLyricsControls);
        }
        _scheduleLyricsControlsHide(restart: false);
      },
    );
    // The next song's colours are ready when it starts, so they move with
    // its cover instead of rebuilding the player again a moment later.
    _nextColoursSub = ref.listenManual<String?>(
      nextQueueArtUriProvider,
      (_, next) => _warmColours(next),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _warmColours(ref.read(nextQueueArtUriProvider));
      unawaited(
        _trackMetadata.load(
          ref.read(currentMediaItemProvider).value,
          inspectUnresolvedContentUri: _readsSongFile,
        ),
      );
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final size = MediaQuery.sizeOf(context);
    _landscape = context.isMornye && size.width > size.height;
    if (!_lyricsAutoHideLayout ||
        (!_lyricsAutoHideEnabled && !_lyricsControlsHiddenManually)) {
      _showLyricsControls();
    }
    _scheduleLyricsControlsHide(restart: false);
  }

  void _onInspectorChanged() {
    if (mounted) setState(() {});
  }

  void _warmColours(String? artUri) {
    if (!mounted || artUri == null) return;
    if (context.isMornye) {
      unawaited(CoverPalette.resolveSourceColor(artUri));
    } else {
      PlayerArtworkTheme.warm(artUri, Theme.of(context).brightness);
    }
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
    _lyricsAutoHideSub?.close();
    _lyricsLayoutSub?.close();
    _nextColoursSub?.close();
    _lyricLineSub?.close();
    _lyricsTranslation.cancel(owner: this);
    _trackMetadata.dispose();
    _artworkDim.dispose();
    _seekPreview.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!ref.watch(playerUiEnabledProvider)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && ModalRoute.of(context)?.isCurrent == true) {
          Navigator.of(context).maybePop();
        }
      });
      return const SizedBox.shrink();
    }
    final mediaItem = ref.watch(currentMediaItemProvider).value;
    final mornye = context.isMornye;
    final fullScreenCover = ref.watch(
      settingsProvider.select(
        (s) => s.playerCoverStyleFor(mornye: mornye) == 'fullscreen',
      ),
    );
    final coverFade = ref.watch(
      settingsProvider.select((s) => s.playerCoverFade),
    );
    final wholeCover = ref.watch(
      settingsProvider.select((s) => s.playerCoverWhole),
    );
    return LyricsScreenAwake(
      visible: _currentPage == 1 && mediaItem != null,
      child: mornye
          ? _buildPlayer(
              context,
              mediaItem,
              fullScreenCover: fullScreenCover,
              coverFade: coverFade,
              wholeCover: wholeCover,
            )
          // Material takes the track's artwork scheme. The providers it needs
          // are read above, so the scoped builder reads none. A skip moves
          // only the page background, so the whole player is not rebuilt
          // on every frame of the colour change.
          : PlayerArtworkTheme(
              artUri: mediaItem?.artUri?.toString(),
              fadesSurfaceOnly: true,
              child: Builder(
                builder: (context) => _buildPlayer(
                  context,
                  mediaItem,
                  fullScreenCover: fullScreenCover,
                  coverFade: coverFade,
                  wholeCover: wholeCover,
                ),
              ),
            ),
    );
  }

  Widget _buildPlayer(
    BuildContext context,
    MediaItem? mediaItem, {
    required bool fullScreenCover,
    required String coverFade,
    required bool wholeCover,
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
    final materialBackdrop = !mornye && fullScreenCover;
    // Two-pane landscape keeps its side-by-side cover over the blurred surface.
    final materialFullScreen =
        materialBackdrop &&
        MediaQuery.orientationOf(context) == Orientation.portrait;
    final motionSong = (
      album: mediaItem.album ?? '',
      artist: mediaItem.artist ?? '',
      source: source,
    );
    // Material plays motion artwork only as the full-screen cover, which its
    // backdrop looks up itself; the card cover stays still.
    final motion = mornye
        ? _watchShownMotion(context, ref, motionSong)
        : (artwork: _shownMotion(null), resolving: false);
    final motionArtwork = motion.artwork;
    final motionRatio = motionArtwork == null
        ? null
        : motionArtwork.aspectRatio ??
              (_measuredMotionSource == motionArtwork.source
                  ? _motionAspectRatio
                  : null) ??
              // The outgoing video stays on screen until the next one
              // measures itself, so its shape keeps the layout until then.
              _shownMotionRatio;
    _shownMotionRatio = motionRatio;
    final squareArtwork =
        motionArtwork == null || (motionRatio != null && motionRatio >= 0.95);
    // Motion artwork is always full-bleed in Mornye; still covers follow the
    // cover style setting through the same layout, as a square video would.
    final fullBleed = mornye && (motionArtwork != null || fullScreenCover);
    final screen = MediaQuery.sizeOf(context);
    // A still cover is cropped at the sides to reach down to the title, as
    // in the Material full-screen style; landscape keeps the square card,
    // and so does the whole cover setting.
    final stillFullBleed = fullBleed && motionArtwork == null;
    final artworkRatio = stillFullBleed
        ? _landscape || wholeCover || screen.height <= 0
              ? 1.0
              : (screen.width / (screen.height * 0.56)).clamp(0.5, 1.0)
        : motionRatio;
    final overCover = materialFullScreen && _currentPage != 1;
    // Portrait keeps the "Playing on" row while empty, so the controls stay
    // put when a computer takes over playback. On an iPhone the row reaches
    // into the home indicator's inset rather than stacking a second empty
    // band on top of it.
    final reservesPlayingOnRow =
        MediaQuery.orientationOf(context) == Orientation.portrait &&
        screen.height >= (mornye ? _mornyePlayingOnMinScreenHeight : 640);
    final bottomInset = MediaQuery.paddingOf(context).bottom;
    final homeIndicatorBelowRow =
        reservesPlayingOnRow && Theme.of(context).platform == TargetPlatform.iOS
        ? bottomInset.clamp(0.0, _homeIndicatorBelowRow)
        : null;
    // Labels stay white. Moving artwork is always dimmed behind them; a still
    // cover is sampled to decide by how much.
    final samplesArtwork = fullBleed && motionArtwork == null;
    final dimCover = samplesArtwork ? mediaItem.artUri?.toString() : null;
    if (!samplesArtwork) {
      _artworkDim.value = 0;
    } else if (dimCover != _artworkDimCover) {
      // An unread cover keeps the layer it follows until its reading.
      _artworkDim.value = _coverDim[dimCover] ?? _artworkDim.value;
    }
    _artworkDimCover = dimCover;
    Widget artwork() => MornyePlayerArtwork(
      mediaItem: mediaItem,
      videoUrl: motionArtwork?.source,
      resolvingVideo: motion.resolving,
      onAspectRatioChanged: (ratio) {
        // A saved ratio already shapes the layout; the measured one is unused.
        if (!mounted ||
            motionArtwork?.aspectRatio != null ||
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
        // Every artwork placement reports the same failure.
        if (mounted && _failedMotionSource != motionArtwork?.source) {
          setState(() => _failedMotionSource = motionArtwork?.source);
        }
      },
    );

    // The Mornye route moves the entire player together. A second,
    // delayed content fade would make dismissal appear to pause partway down.
    final route = NowPlayingRoute.routeOf(context);
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
    final contentFade = CurveTween(
      curve: const Interval(0.4, 1.0, curve: Curves.easeOut),
    );
    final contentOpacity = mornye
        ? kAlwaysCompleteAnimation
        : route is NowPlayingRoute
        // Follows the surface of a player that grows out of the mini player.
        ? route.contentOpacity(contentFade)
        : routeAnimation.drive(contentFade);

    // The embedded desktop player keeps a toolbar for its minimize button,
    // which a route reaches by swiping down instead.
    final double? mornyeToolbarHeight = !mornye
        ? null
        : widget.embedded
        ? 48
        : MediaQuery.orientationOf(context) == Orientation.landscape
        ? 0
        : 36;
    final materialLandscapeArtwork =
        !mornye &&
        !widget.embedded &&
        MediaQuery.orientationOf(context) == Orientation.landscape &&
        ref.watch(settingsProvider.select((s) => s.landscapeLyricsArtwork));
    // The Material page background is painted below the scaffold, where it
    // moves to the next track's colour on its own.
    final player = Scaffold(
      extendBodyBehindAppBar: materialLandscapeArtwork,
      backgroundColor: Colors.transparent,
      appBar: _FadingAppBar(
        opacity: contentOpacity,
        hidden: !mornye && _lyricsImmersive,
        child: AppBar(
          backgroundColor: Colors.transparent,
          foregroundColor: overCover ? Colors.white : colorScheme.onSurface,
          surfaceTintColor: Colors.transparent,
          systemOverlayStyle: mornye
              ? _overCoverBars
              : overCover
              // The Material player ends on the app's surface, which can be
              // light, while its status bar stays over the cover.
              ? _overCoverBars.copyWith(
                  systemNavigationBarIconBrightness:
                      colorScheme.brightness == Brightness.dark
                      ? Brightness.light
                      : Brightness.dark,
                )
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
          top: !materialLandscapeArtwork,
          bottom: homeIndicatorBelowRow == null,
          child: Column(
            children: [
              if (materialLandscapeArtwork) ...[
                SizedBox(height: MediaQuery.viewPaddingOf(context).top),
                PlayerLyricsControlsCollapse(
                  key: const ValueKey('material-landscape-toolbar-space'),
                  hidden: _lyricsImmersive,
                  child: const SizedBox(height: kToolbarHeight),
                ),
              ],
              Expanded(
                child: mornye
                    ? NotificationListener<ScrollUpdateNotification>(
                        onNotification: _onLyricsScroll,
                        child: MornyePlayerLayout(
                          mediaItem: mediaItem,
                          showSourceLabel: !reservesPlayingOnRow,
                          metadata: _trackMetadata,
                          seekPreview: _seekPreview,
                          colorScheme: colorScheme,
                          page: _currentPage,
                          motionArtwork: artwork(),
                          artworkAspectRatio: artworkRatio,
                          controlsHeadroom: reservesPlayingOnRow
                              ? _mornyeControlsHeadroom
                              : 0,
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
                        showSourceLabel: !reservesPlayingOnRow,
                        metadata: _trackMetadata,
                        seekPreview: _seekPreview,
                        colorScheme: colorScheme,
                        showLyrics: _currentPage == 1,
                        immersive: _lyricsImmersive,
                        compactPlayer: ref.watch(
                          settingsProvider.select((s) => s.compactPlayer),
                        ),
                        onCompactPlayerTouch: () =>
                            _compactPlayerTouched = true,
                        fullScreenArtwork: materialFullScreen,
                        landscapeLyricsArtwork: ref.watch(
                          settingsProvider.select(
                            (s) => s.landscapeLyricsArtwork,
                          ),
                        ),
                        lyricsBuilder: (_) =>
                            _lyricsSection(colorScheme, isActive: true),
                        onOpenLyrics: _toggleMaterialLyrics,
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
                              // Filled pills like the shuffle and repeat
                              // segments between them.
                              ExpressiveIconButton(
                                key: const ValueKey('material-lyrics-toggle'),
                                tooltip: _currentPage == 1
                                    ? context.l10n.nowPlayingTabPlayer
                                    : context.l10n.nowPlayingTabLyrics,
                                selected: _showsPage(1),
                                width: PlayerPlaybackModeToolbar.segmentWidth,
                                foregroundColor: _showsPage(1)
                                    ? colorScheme.onPrimaryContainer
                                    : colorScheme.onSurfaceVariant,
                                backgroundColor: _showsPage(1)
                                    ? colorScheme.primaryContainer
                                    : colorScheme.surfaceContainerHigh,
                                icon: const AppIcon(Icons.lyrics_outlined),
                                onPressed: _toggleMaterialLyrics,
                              ),
                              PlayerPlaybackModeToolbar(
                                colorScheme: colorScheme,
                              ),
                              AudioOutputButton(
                                color: colorScheme.onSurfaceVariant,
                                backgroundColor:
                                    colorScheme.surfaceContainerHigh,
                                width: PlayerPlaybackModeToolbar.segmentWidth,
                              ),
                            ],
                          ),
                        ),
                      // Landscape has no row to spare; the toolbar's devices
                      // button shows the device there. Short phones' lyrics
                      // keep the room an empty row would take.
                      if (MediaQuery.orientationOf(context) ==
                          Orientation.portrait) ...[
                        if (!reservesPlayingOnRow) ...[
                          LinkPlayingOnLabel(
                            color: mornye ? Colors.white : null,
                          ),
                          const SizedBox(height: 8),
                        ] else
                          SizedBox(
                            key: const ValueKey('link-playing-on-row'),
                            height: _playingOnRowHeight,
                            child: Center(
                              child: LinkPlayingOnLabel(
                                color: mornye ? Colors.white : null,
                                height: _playingOnRowHeight,
                                // Where the music plays and where it comes
                                // from read from one place.
                                idle: PlaybackSourceLabel(
                                  item: mediaItem,
                                  color: mornye
                                      ? Colors.white
                                      : colorScheme.primary,
                                  style: mornye
                                      ? Theme.of(
                                          context,
                                        ).textTheme.labelMedium?.copyWith(
                                          fontWeight: FontWeight.w600,
                                        )
                                      : Theme.of(context).textTheme.labelLarge,
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 12,
                                  ),
                                ),
                              ),
                            ),
                          ),
                      ],
                    ],
                  ),
                ),
                collapse: true,
              ),
              if (homeIndicatorBelowRow != null)
                SizedBox(height: homeIndicatorBelowRow),
            ],
          ),
        ),
      ),
    );
    if (!mornye) {
      if (!materialBackdrop) {
        return _lyricsPointerListener(
          PlayerArtworkSurface(surface: colorScheme.surface, child: player),
        );
      }
      return Stack(
        fit: StackFit.expand,
        children: [
          RepaintBoundary(
            // Its answer, a few frames into the open or a song, rebuilds
            // only the backdrop.
            child: Consumer(
              builder: (context, ref, _) {
                final state = materialFullScreen
                    ? _watchMotionArtwork(context, ref, motionSong)
                    : null;
                final motionArtwork = _shownMotion(state);
                return MaterialPlayerBackdrop(
                  mediaItem: mediaItem,
                  colorScheme: colorScheme,
                  showArtwork: materialFullScreen && _currentPage != 1,
                  fadeStart: playerCoverFadeStart(
                    MaterialPlayerBackdrop.mediumFadeStart,
                    coverFade,
                  ),
                  wholeCover: wholeCover,
                  playsMotionArtwork: true,
                  videoUrl: motionArtwork?.source,
                  resolvingVideo: state?.isLoading == true,
                  onVideoError: () {
                    if (mounted) {
                      setState(
                        () => _failedMotionSource = motionArtwork?.source,
                      );
                    }
                  },
                );
              },
            ),
          ),
          _lyricsPointerListener(player),
        ],
      );
    }
    final showsFullArtwork = fullBleed && !_landscape && _currentPage == 0;
    final fadeStart = playerCoverFadeStart(
      stillFullBleed ? 0.72 : 0.58,
      coverFade,
    );
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
              enabled: samplesArtwork && !_landscape && _currentPage == 0,
              targets: {
                'header': _artworkHeaderKey,
                'controls': _artworkControlsKey,
                'volume': _artworkVolumeKey,
              },
              onDim: (dim) {
                if (!mounted) return;
                _artworkDim.value = dim;
                final cover = _artworkDimCover;
                if (cover == null) return;
                if (_coverDim.length >= 64 && !_coverDim.containsKey(cover)) {
                  _coverDim.remove(_coverDim.keys.first);
                }
                _coverDim[cover] = dim;
              },
              child: Stack(
                fit: StackFit.expand,
                children: [
                  MornyePlayerBackground(
                    artUri: mediaItem.artUri,
                    squareArtwork: squareArtwork,
                    artworkAspectRatio: artworkRatio,
                    fadeStart: fadeStart,
                    artwork: showsFullArtwork
                        ? PlayerTransitionArtwork(
                            artworkKey: _motionArtworkKey,
                            child: Hero(
                              tag: kNowPlayingArtworkHeroTag,
                              child: artwork(),
                            ),
                          )
                        : null,
                  ),
                  // Inside the sample: the labels sit on its colour.
                  MornyeCoverGlow(
                    artUri: mediaItem.artUri?.toString(),
                    visible: showsFullArtwork && stillFullBleed,
                    squareArtwork: squareArtwork,
                    artworkAspectRatio: artworkRatio,
                    fadeStart: fadeStart,
                  ),
                ],
              ),
            ),
            MornyeMotionGlow(
              videoUrl: motionArtwork?.source,
              visible: showsFullArtwork,
              resolvingVideo: motion.resolving,
              squareArtwork: squareArtwork,
              artworkAspectRatio: artworkRatio,
              fadeStart: fadeStart,
            ),
            ValueListenableBuilder<double>(
              valueListenable: _artworkDim,
              builder: (context, dim, _) => MornyeControlsDim(
                strength: !showsFullArtwork
                    ? 0
                    : motionArtwork != null
                    ? 1
                    : dim,
                squareArtwork: squareArtwork,
                artworkAspectRatio: artworkRatio,
                fadeStart: fadeStart,
              ),
            ),
            _lyricsPointerListener(player),
          ],
        ),
      ),
    );
  }

  static AsyncValue<MotionArtwork?>? _watchMotionArtwork(
    BuildContext context,
    WidgetRef ref,
    PlayerArtworkSong song,
  ) =>
      ref.watch(settingsProvider.select((s) => s.motionArtworkEnabled)) &&
          !MediaQuery.disableAnimationsOf(context)
      ? ref.watch(songMotionArtworkProvider(song))
      : null;

  /// The Mornye player's motion cover, as [_shownMotion] picks it, and
  /// whether the next one is still looked up. An answer that changes
  /// neither, as for most songs, does not rebuild the player.
  ({MotionArtwork? artwork, bool resolving}) _watchShownMotion(
    BuildContext context,
    WidgetRef ref,
    PlayerArtworkSong song,
  ) {
    if (!ref.watch(settingsProvider.select((s) => s.motionArtworkEnabled)) ||
        MediaQuery.disableAnimationsOf(context)) {
      return (artwork: _shownMotion(null), resolving: false);
    }
    final shown = _shownMotionArtwork;
    final (:artwork, :resolving) = ref.watch(
      songMotionArtworkProvider(song).select((state) {
        final lookingUp = state.isLoading && !state.hasValue;
        final artwork = lookingUp ? shown : state.value;
        // A lookup only holds a video that is on screen, and only matters
        // while no usable video shows, so the same video again is no change.
        final usable = artwork != null && artwork.source != _failedMotionSource;
        return (
          artwork: artwork,
          resolving: !usable && shown != null && state.isLoading,
        );
      }),
    );
    _shownMotionArtwork = artwork;
    return (
      artwork: artwork?.source == _failedMotionSource ? null : artwork,
      resolving: resolving,
    );
  }

  /// A new song looks up its artwork for a few frames. The outgoing motion
  /// cover keeps its layout meanwhile, so the gradient and its fade do not
  /// drop to the still cover's layout and come back.
  MotionArtwork? _shownMotion(AsyncValue<MotionArtwork?>? state) {
    final lookingUp = state != null && state.isLoading && !state.hasValue;
    final resolved = lookingUp ? _shownMotionArtwork : state?.value;
    _shownMotionArtwork = resolved;
    return resolved?.source == _failedMotionSource ? null : resolved;
  }

  /// A touch on the lyrics page holds the controls; a tap brings hidden
  /// ones back.
  Widget _lyricsPointerListener(Widget child) => LyricsOptionsActivity(
    child: Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (event) {
        if (_currentPage != 1 || !_lyricsAutoHideLayout) return;
        if (_lyricsPointers.isEmpty) _lyricsPointerMoved = false;
        _lyricsPointers[event.pointer] = event.position;
        _lyricsIdleTimer?.cancel();
        if (!_lyricsControlsHidden) _logLyricsAutoHideBlockers();
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
      child: child,
    ),
  );

  void _toggleMaterialLyrics() {
    if (_toggleInspector(1)) return;
    setState(() {
      _currentPage = _currentPage == 1 ? 0 : 1;
      _showLyricsControls();
      _lastLyricsControlsStatus = null;
    });
    _scheduleLyricsControlsHide();
    if (_currentPage == 1) {
      _logLyricsAutoHideBlockers();
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
      _showLyricsControls();
      _lastLyricsControlsStatus = null;
      _lyricsScrollDistance = 0;
    });
    _scheduleLyricsControlsHide();
    if (_currentPage == 1) {
      _logLyricsAutoHideBlockers();
      unawaited(
        _trackMetadata.load(
          ref.read(currentMediaItemProvider).value,
          inspectUnresolvedContentUri: true,
        ),
      );
    }
  }

  /// Lyrics fill the column, so idle controls can hide: Mornye in portrait
  /// (its landscape player hides its own actions), and Material's portrait
  /// column or its landscape artwork beside lyrics, which shows no transport
  /// either, like Mornye's. Two plain panes keep the transport beside the
  /// lyrics, and the desktop opens lyrics in the inspector.
  bool get _lyricsAutoHideLayout => context.isMornye
      ? !_landscape
      : !widget.embedded &&
            (MediaQuery.orientationOf(context) == Orientation.portrait ||
                ref.read(settingsProvider).landscapeLyricsArtwork);

  bool get _lyricsAutoHideEnabled => ref
      .read(settingsProvider)
      .shouldAutoHideLyricsControls(
        accessibleNavigation: MediaQuery.accessibleNavigationOf(context),
      );

  bool get _canAutoHideLyricsControls =>
      _lyricsAutoHideLayout &&
      _lyricsAutoHideEnabled &&
      _currentPage == 1 &&
      ref.read(playbackPlayingProvider);

  /// Names what keeps the controls from hiding when lyrics open, so a log
  /// from a device where automatic fullscreen lyrics never starts says why.
  void _logLyricsAutoHideBlockers() {
    // The desktop player has no automatic fullscreen lyrics.
    if (widget.embedded) return;
    final size = MediaQuery.sizeOf(context);
    final blockers = [
      if (!_lyricsAutoHideLayout)
        'layout ${size.width.round()}x${size.height.round()}',
      if (!ref.read(settingsProvider).autoHideLyricsControls) 'setting off',
      if (!ref.read(playbackPlayingProvider)) 'not playing',
      if (MediaQuery.accessibleNavigationOf(context) &&
          !ref.read(settingsProvider).autoHideLyricsControlsWithAccessibility)
        'accessible navigation',
      if (_lyricsPointers.isNotEmpty) 'touch held',
      if (_lyricsOptionsOpen) 'lyrics menu open',
      if (_audioOutputOpen) 'audio output menu open',
    ];
    if (blockers.isEmpty) return;
    _logLyricsControlsStatus(
      'Lyrics controls stay visible: ${blockers.join(', ')}',
    );
  }

  void _logLyricsControlsStatus(String status) {
    if (_lastLyricsControlsStatus == status) return;
    _lastLyricsControlsStatus = status;
    _log.i(status);
  }

  void _scheduleLyricsControlsHide({bool restart = true}) {
    if (!_canAutoHideLyricsControls ||
        _lyricsOptionsOpen ||
        _audioOutputOpen ||
        _lyricsControlsHidden ||
        _lyricsPointers.isNotEmpty ||
        !TickerMode.valuesOf(context).enabled) {
      _lyricsIdleTimer?.cancel();
      if (_currentPage == 1 && !_lyricsControlsHidden) {
        _logLyricsAutoHideBlockers();
      }
      return;
    }
    // Viewport and inherited-widget updates are not user activity. Keep an
    // eligible countdown running while system chrome or window metrics change.
    if (!restart && (_lyricsIdleTimer?.isActive ?? false)) return;
    _lyricsIdleTimer?.cancel();
    _lyricsIdleTimer = Timer(const Duration(seconds: 5), () {
      if (!mounted) return;
      if (!TickerMode.valuesOf(context).enabled) return;
      if (!_canAutoHideLyricsControls) {
        _logLyricsAutoHideBlockers();
        return;
      }
      if (NowPlayingRoute.routeOf(context)?.isCurrent == false) {
        _logLyricsControlsStatus(
          'Lyrics controls stay visible: another route is active',
        );
        _scheduleLyricsControlsHide();
        return;
      }
      setState(() {
        _lyricsControlsHidden = true;
        _lyricsControlsHiddenManually = false;
      });
      _logLyricsControlsStatus('Lyrics controls hidden automatically');
    });
    _logLyricsControlsStatus(
      'Lyrics controls auto-hide timer started: 5 seconds',
    );
  }

  void _endLyricsInteraction(int pointer, {bool cancelled = false}) {
    if (_lyricsPointers.remove(pointer) == null || _lyricsPointers.isNotEmpty) {
      return;
    }
    final compactTouch = _compactPlayerTouched;
    _compactPlayerTouched = false;
    if (!cancelled &&
        !_lyricsPointerMoved &&
        !compactTouch &&
        _lyricsControlsHidden) {
      setState(_showLyricsControls);
    }
    _scheduleLyricsControlsHide();
  }

  bool _onLyricsScroll(ScrollUpdateNotification notification) {
    if (_currentPage != 1 ||
        !_lyricsAutoHideLayout ||
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
        setState(() {
          _lyricsControlsHidden = hidden;
          _lyricsControlsHiddenManually = hidden;
        });
        _logLyricsControlsStatus(
          'Lyrics controls ${hidden ? 'hidden' : 'shown'} by scrolling',
        );
      }
      _lyricsScrollDistance = 0;
    }
    return false;
  }

  void _showLyricsControls() {
    _lyricsControlsHidden = false;
    _lyricsControlsHiddenManually = false;
  }

  bool get _lyricsImmersive =>
      _currentPage == 1 && _lyricsControlsHidden && _lyricsAutoHideLayout;

  /// Mornye fades the controls in place; Material folds a [collapse] row
  /// away so the lyrics take its room.
  Widget _autoHidingLyricsControls(Widget child, {bool collapse = false}) =>
      !context.isMornye && collapse
      ? PlayerLyricsControlsCollapse(hidden: _lyricsImmersive, child: child)
      : PlayerLyricsControlsVisibility(hidden: _lyricsImmersive, child: child);

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
        position: line == null ? _lyricsDrawnPosition() : null,
        offset: Duration(
          milliseconds: ref.read(
            lyricsOffsetMsForSongProvider(songLyricsOffsetKeyOf(mediaItem)),
          ),
        ),
      );
    } finally {
      _sharingLyrics = false;
    }
  }

  /// The position synced lyrics are drawn for, as [SyncedLyricsView] reads
  /// it: the scrub preview, else the audio position plus the display lead
  /// while playing. Null while Mornye shows no line yet (loading, or not
  /// started), so sharing then opens with nothing selected.
  Duration? _lyricsDrawnPosition() {
    final preview = _seekPreview.value;
    if (preview != null) return preview;
    final state = ref.read(playbackStateProvider).value;
    if (state == null) return null;
    final loading =
        state.processingState == AudioProcessingState.loading ||
        state.processingState == AudioProcessingState.buffering;
    if (context.isMornye &&
        (loading || (!state.playing && state.position <= Duration.zero))) {
      return null;
    }
    if (!state.playing ||
        loading ||
        !state.speed.isFinite ||
        state.speed <= 0) {
      return state.position;
    }
    final lead = lyricsDisplayLead(
      displayOf(View.maybeOf(context))?.refreshRate,
    );
    return state.position + lead * state.speed;
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

  Widget _lyricsOptionsButton(ColorScheme colorScheme) => LyricsOptionsButton(
    metadata: _trackMetadata,
    colorScheme: colorScheme,
    translationOwner: this,
    onOpenChanged: _onLyricsOptionsOpenChanged,
  );

  void _onLyricsOptionsOpenChanged(bool open) {
    if (!mounted) return;
    if (open) _lyricsIdleTimer?.cancel();
    setState(() => _lyricsOptionsOpen = open);
    if (!open) _scheduleLyricsControlsHide();
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

  Future<void> _goToCurrentArtist(MediaItem mediaItem) =>
      openPlayingArtist(context, ref, mediaItem);

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
    final sleepTimerSubtitle = controller.sleepAtEndOfSong
        ? context.l10n.nowPlayingSleepTimerEndOfSongActive
        : sleepTimerEndsAt == null
        ? null
        : context.l10n.nowPlayingSleepTimerActive(
            MaterialLocalizations.of(
              context,
            ).formatTimeOfDay(TimeOfDay.fromDateTime(sleepTimerEndsAt)),
          );
    final settings = ref.read(settingsProvider);
    final volumeShown = settings.playerShowVolume;
    final tempoSubtitle = playbackTempoSettingsSummary(context.l10n, settings);
    final linkClient = ref.read(linkPhoneClientProvider);
    final transfer = await linkTransferSongsOfPlaying(
      ref,
      mediaId: mediaItem.id,
      source: source,
    );
    if (!mounted || !context.mounted) return;
    final sendToDesktop = transfer.phone.isEmpty || linkClient == null
        ? null
        : linkDesktopName(linkClient);
    final saveToPhone = transfer.desktop.isNotEmpty;
    final action = context.isMornye
        ? await showMornyeContextMenu<String>(
            context: context,
            anchor: anchor,
            preferAbove: true,
            maxWidth: 280,
            builder: (_) => MornyePlayerActionsSheet(
              mediaItem: mediaItem,
              sleepTimerSubtitle: sleepTimerSubtitle,
              tempoSubtitle: tempoSubtitle,
              volumeShown: volumeShown,
              sendToDesktop: sendToDesktop,
              sendToPhoneHost: linkClient?.server.isPhone ?? false,
              saveToPhone: saveToPhone,
            ),
          )
        : await showAppBottomSheet<String>(
            context: context,
            useRootNavigator: true,
            backgroundColor: colorScheme.surfaceContainerHigh,
            title: mediaItem.title,
            subtitle: mediaItem.artist,
            maxHeightFactor: 0.85,
            // The list scrolls under its fixed title on a short screen.
            builder: (sheetContext) => SingleChildScrollView(
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
                    icon: Icons.share_outlined,
                    title: sheetContext.l10n.trackMetadataShare,
                    onTap: () => Navigator.of(sheetContext).pop('share'),
                  ),
                  SettingsItem(
                    icon: Icons.format_quote_outlined,
                    title: sheetContext.l10n.lyricsShareTitle,
                    onTap: () => Navigator.of(sheetContext).pop('shareLyrics'),
                  ),
                  if (sendToDesktop != null && linkClient != null)
                    SettingsItem(
                      icon: linkSendToHostIcon(linkClient),
                      title: sheetContext.l10n.linkSendToDesktop(sendToDesktop),
                      onTap: () => Navigator.of(sheetContext).pop('linkSend'),
                    ),
                  if (saveToPhone)
                    SettingsItem(
                      icon: Icons.phone_android,
                      title: sheetContext.l10n.linkSaveToPhone,
                      onTap: () => Navigator.of(sheetContext).pop('linkSave'),
                    ),
                  if (!saveToPhone && canSaveNetworkOfflineSource(source))
                    SettingsItem(
                      icon: Icons.download_for_offline_outlined,
                      title: sheetContext.l10n.offlineSave,
                      onTap: () =>
                          Navigator.of(sheetContext).pop('networkOffline'),
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
                    icon: Icons.speed,
                    title: sheetContext.l10n.playbackTempoTitle,
                    subtitle: tempoSubtitle,
                    onTap: () => Navigator.of(sheetContext).pop('tempo'),
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
        await showSongShare(
          context,
          title: mediaItem.title,
          artist: mediaItem.artist ?? '',
        );
        break;
      case 'album':
        await _goToCurrentAlbum(mediaItem: mediaItem, source: source);
        break;
      case 'shareLyrics':
        await _shareLyrics();
        break;
      case 'linkSend':
        await linkSendSongsToDesktop(context, ref, transfer.phone);
        break;
      case 'linkSave':
        linkSaveSongsToPhone(context, ref, transfer.desktop);
        break;
      case 'networkOffline':
        await savePlayingNetworkOffline(context, ref, mediaItem);
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
      case 'tempo':
        await showPlaybackTempoSheet(context);
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
    final endOfSong = controller.sleepAtEndOfSong;
    final isActive = controller.sleepTimerEndsAt != null || endOfSong;
    final selection = await showAppBottomSheet<String>(
      context: context,
      useRootNavigator: true,
      backgroundColor: colorScheme.surfaceContainerHigh,
      title: context.l10n.nowPlayingSleepTimer,
      maxHeightFactor: 0.85,
      builder: (sheetContext) => SingleChildScrollView(
        padding: const EdgeInsets.only(bottom: 16),
        child: SettingsGroup(
          children: [
            for (final minutes in durations)
              SettingsItem(
                icon: Icons.timer_outlined,
                title: sheetContext.l10n.nowPlayingSleepTimerMinutes(minutes),
                onTap: () => Navigator.of(sheetContext).pop('$minutes'),
              ),
            SettingsItem(
              icon: Icons.music_note_outlined,
              title: sheetContext.l10n.nowPlayingSleepTimerEndOfSong,
              selected: endOfSong,
              trailing: endOfSong
                  ? AppIcon(Icons.check, color: colorScheme.primary)
                  : null,
              showDivider: isActive,
              onTap: () => Navigator.of(sheetContext).pop('endOfSong'),
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

    if (selection == 'endOfSong') {
      controller.setSleepTimerEndOfSong();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.l10n.nowPlayingSleepTimerEndOfSongSet)),
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
  }) => openPlayingAlbum(context, ref, mediaItem: mediaItem, source: source);

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
