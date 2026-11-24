import 'dart:async';
import 'dart:math' as math;

import 'package:audio_service/audio_service.dart' show MediaItem;
import 'package:flutter/gestures.dart' show DragStartBehavior;
import 'package:flutter/semantics.dart' show SemanticsRole;
import 'package:material_ui/material_ui.dart';
import 'package:cupertino_ui/cupertino_ui.dart' show CupertinoIcons;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_3_expressive/components/progress_indicators/components/m3e_linear_progress_painter.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/widgets/app_icon.dart';
import 'package:mornye/widgets/app_icon_button.dart';
import 'package:mornye/widgets/app_loading_indicator.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/providers/player_motion_artwork_provider.dart';
import 'package:mornye/providers/player_artwork_video_provider.dart';
import 'package:mornye/providers/runtime_profile_provider.dart';
import 'package:mornye/theme/app_motion.dart';
import 'package:mornye/theme/app_tokens.dart';
import 'package:mornye/theme/cover_palette.dart';
import 'package:mornye/theme/material_expressive.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/theme/player_artwork_theme.dart';
import 'package:mornye/screens/now_playing_screen.dart';
import 'package:mornye/services/link/features/link_phone_client.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:mornye/utils/string_utils.dart';
import 'package:mornye/widgets/audio_quality_badges.dart';
import 'package:mornye/widgets/expressive_playback_transport.dart';
import 'package:mornye/widgets/cached_cover_image.dart';
import 'package:mornye/widgets/decorative_phase.dart';
import 'package:mornye/widgets/link/link_devices_sheet.dart';
import 'package:mornye/widgets/overflow_marquee.dart';
import 'package:mornye/widgets/player_artwork.dart';
import 'package:mornye/widgets/player_track_crossfade.dart';
import 'package:mornye/widgets/player_track_swipe.dart';
import 'package:mornye/widgets/settings_group.dart';
import 'package:mornye/widgets/swipe_commit_haptic.dart';
import 'package:mornye/widgets/mornye_chrome.dart';
import 'package:mornye/widgets/mornye_glass_press.dart';

class MiniPlayer extends ConsumerStatefulWidget {
  const MiniPlayer({super.key, this.compact = false, this.bottomPadding = 8});

  final bool compact;
  final double bottomPadding;

  @override
  ConsumerState<MiniPlayer> createState() => _MiniPlayerState();
}

class _MiniPlayerState extends ConsumerState<MiniPlayer> {
  Uri? _warmedArtUri;
  (Uri, int)? _warmedTransition;

  @override
  void initState() {
    super.initState();
    ref.listenManual(
      currentMediaItemProvider.select((item) => item.value?.artUri),
      (_, artUri) {
        _warmCoverColour(artUri);
        _warmFullScreenArtwork(artUri);
        _warmMiniCover(artUri);
      },
    );
    ref.listenManual(
      settingsProvider.select((settings) => settings.playerCoverStyle),
      (_, _) => _warmFullScreenArtwork(
        ref.read(currentMediaItemProvider).value?.artUri,
      ),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _warmCoverColour(ref.read(currentMediaItemProvider).value?.artUri);
    _warmFullScreenArtwork(ref.read(currentMediaItemProvider).value?.artUri);
  }

  // This listener runs under the full player too, so a song changed there
  // has its cover ready when the player closes onto this bar.
  void _warmMiniCover(Uri? artUri) {
    final provider = coverImageProvider(
      artUri?.toString(),
      cacheWidth: PlayerArtwork.miniCacheWidth,
    );
    if (provider == null) return;
    unawaited(precacheImage(provider, context, onError: (_, _) {}));
  }

  void _warmFullScreenArtwork(Uri? artUri) {
    // Both Mornye cover styles open at this width, Material only its
    // full-screen one.
    if (isDesktopPlatform ||
        artUri == null ||
        (!context.isMornye &&
            ref.read(settingsProvider).playerCoverStyleFor(mornye: false) !=
                'fullscreen') ||
        MediaQuery.orientationOf(context) != Orientation.portrait) {
      _warmedTransition = null;
      return;
    }
    final width = PlayerArtwork.transitionCacheWidth(context);
    final inputs = (artUri, width);
    if (inputs == _warmedTransition) return;
    final provider = coverImageProvider(artUri.toString(), cacheWidth: width);
    if (provider == null) return;
    _warmedTransition = inputs;
    // Failed warm-up uses the artwork widget's existing placeholder.
    unawaited(precacheImage(provider, context, onError: (_, _) {}));
  }

  // The Mornye full player shades itself from the cover's source colour;
  // resolving it with the track lets the player open on its final colour.
  void _warmCoverColour(Uri? artUri) {
    if (!context.isMornye || artUri == _warmedArtUri) return;
    _warmedArtUri = artUri;
    final source = artUri?.toString();
    if (source != null && source.isNotEmpty) {
      unawaited(CoverPalette.resolveSourceColor(source));
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!ref.watch(playerUiEnabledProvider)) return const SizedBox.shrink();
    final body = _MiniPlayerBody(
      compact: widget.compact,
      bottomPadding: widget.bottomPadding,
    );
    if (context.isMornye) return body;
    // Material takes the track's artwork scheme, like the full player.
    final artUri = ref.watch(
      currentMediaItemProvider.select((item) => item.value?.artUri?.toString()),
    );
    // The phone shell already gives the whole bar this cover's scheme; a
    // second scope would only move the same scheme again.
    final enclosing = context
        .findAncestorWidgetOfExactType<PlayerArtworkTheme>();
    if (enclosing != null && enclosing.artUri == artUri) return body;
    return PlayerArtworkTheme(artUri: artUri, child: body);
  }
}

class _MiniPlayerBody extends ConsumerStatefulWidget {
  const _MiniPlayerBody({required this.compact, required this.bottomPadding});

  final bool compact;
  final double bottomPadding;

  @override
  ConsumerState<_MiniPlayerBody> createState() => _MiniPlayerBodyState();
}

class _MiniPlayerBodyState extends ConsumerState<_MiniPlayerBody> {
  final _surfaceKey = GlobalKey();
  final _artworkKey = GlobalKey();

  Rect? _bounds(GlobalKey key) {
    final box = key.currentContext?.findRenderObject();
    if (box is! RenderBox || !box.attached || !box.hasSize) return null;
    final overlay = Navigator.of(
      context,
      rootNavigator: true,
    ).overlay?.context.findRenderObject();
    return MatrixUtils.transformRect(
      box.getTransformTo(overlay),
      Offset.zero & box.size,
    );
  }

  /// Upward travel of the current vertical drag, in logical pixels.
  double _dragUp = 0;
  bool _dragCancelled = false;
  final _openHaptic = SwipeCommitHaptic();

  void _onVerticalDragUpdate(DragUpdateDetails details) {
    _dragUp -= details.primaryDelta ?? 0;
    _openHaptic.update(_dragUp > 48);
  }

  void _openNowPlaying() {
    final mornye = context.isMornye;
    Navigator.of(context, rootNavigator: true).push(
      NowPlayingRoute(
        child: const NowPlayingScreen(),
        miniPlayerGeometry: () {
          if (!mounted) return null;
          final surface = _bounds(_surfaceKey);
          final artwork = _bounds(_artworkKey);
          if (surface == null || artwork == null) return null;
          return (surface: surface, artwork: artwork);
        },
        // The Material player is the mini player expanded: it grows out of
        // this bar and shrinks back into it. Reduced motion opens at once.
        morph: mornye || isDesktopPlatform
            ? null
            : AppMotion.spatial(
                context,
                const AppMotionSpec(Duration.zero, Curves.linear),
              ),
      ),
    );
  }

  // Opens on release rather than under the finger: pushing a route cancels
  // every active pointer, so the drag could not keep steering the page.
  void _onVerticalDragEnd(DragEndDetails details) {
    final travel = _dragUp;
    _dragUp = 0;
    final velocity = -(details.primaryVelocity ?? 0);
    if (!_dragCancelled && (velocity > 300 || (velocity >= 0 && travel > 48))) {
      _openNowPlaying();
    }
  }

  void _onHorizontalRelease(DragEndDetails details, double travel) {
    final velocity = details.primaryVelocity ?? 0;
    if (_dragCancelled ||
        (travel.abs() < PlayerTrackSwipe.followCommitDistance &&
            velocity.abs() < 550)) {
      return;
    }
    final direction = velocity.abs() >= 550 ? velocity : travel;
    final controller = ref.read(musicPlayerControllerProvider);
    if (!ref.read(playbackPlayingProvider) &&
        ref.read(activeRemotePlaybackProvider) == null) {
      if (!ref.read(playbackLoadingProvider)) unawaited(controller.dismiss());
      return;
    }
    if (direction < 0) {
      controller.next();
    } else {
      controller.previous();
    }
  }

  Widget _titles(
    BuildContext context,
    MediaItem mediaItem, {
    required bool remote,
    required int? marqueeCycles,
    required bool playing,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    final mornye = context.isMornye;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        OverflowMarquee(
          resetKey: (mediaItem.id, mediaItem.title),
          maxCycles: marqueeCycles,
          playing: playing,
          child: ExplicitTrackTitle(
            title: mediaItem.title,
            explicit: parseExplicitFlag(mediaItem.extras?['explicit']) == true,
            style: Theme.of(
              context,
            ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        // Where the music plays while the paired desktop plays in this
        // phone's place.
        if (remote)
          LinkPlayingOnText(
            key: const ValueKey('mini-player-playing-on'),
            color: colorScheme.primary,
            style: Theme.of(context).textTheme.bodySmall,
            glyphSize: 14,
          )
        else
          OverflowMarquee(
            resetKey: (mediaItem.id, mediaItem.artist),
            maxCycles: marqueeCycles,
            playing: playing,
            child: Text(
              mediaItem.artist ?? '',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: mornye
                    ? Color.lerp(
                        colorScheme.onSurfaceVariant,
                        colorScheme.onSurface,
                        colorScheme.brightness == Brightness.dark ? 0.7 : 0.6,
                      )
                    : colorScheme.onSurfaceVariant,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final mediaItem = ref.watch(currentMediaItemProvider).value;
    if (mediaItem == null) return const SizedBox.shrink();

    final isPlaying = ref.watch(playbackPlayingProvider);
    final isLoading = ref.watch(playbackLoadingProvider);
    final remote = ref.watch(
      activeRemotePlaybackProvider.select((remote) => remote != null),
    );

    final controller = ref.read(musicPlayerControllerProvider);
    final colorScheme = Theme.of(context).colorScheme;
    final mornye = context.isMornye;
    final expressive = materialExpressiveEnabled(context);
    final compact = mornye && widget.compact;
    // Every marquee frame re-filters the glass chrome around it, so Mornye
    // stops the title after a few passes on every glass level.
    final marqueeCycles = mornye ? 2 : null;
    final surface = KeyedSubtree(
      key: _surfaceKey,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: _openNowPlaying,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (!mornye)
                _MiniPlayerProgress(
                  duration: mediaItem.duration ?? Duration.zero,
                  backgroundColor: colorScheme.surfaceContainerHighest,
                  playing: isPlaying,
                ),
              Padding(
                padding: EdgeInsets.symmetric(
                  horizontal: compact ? 8 : 12,
                  vertical: mornye ? 0 : 8,
                ),
                child: Row(
                  children: [
                    Hero(
                      tag: kNowPlayingArtworkHeroTag,
                      // Back from the Material player the cover keeps step
                      // with the shrinking surface, on a back gesture too.
                      createRectTween: mornye || isDesktopPlatform
                          ? null
                          : NowPlayingRoute.landingFlight,
                      flightShuttleBuilder: mornye || isDesktopPlatform
                          ? null
                          : NowPlayingRoute.coverShuttle,
                      transitionOnUserGestures: !mornye && !isDesktopPlatform,
                      child: ClipRRect(
                        key: _artworkKey,
                        borderRadius: BorderRadius.circular(mornye ? 6 : 12),
                        child: SizedBox(
                          width: context.tokens.coverMini,
                          height: context.tokens.coverMini,
                          // A closing Mornye player lands its own cover here;
                          // two covers would show until it does.
                          child: ValueListenableBuilder<bool>(
                            valueListenable: NowPlayingRoute.coverLanding,
                            builder: (context, landing, cover) =>
                                Opacity(opacity: landing ? 0 : 1, child: cover),
                            child: PlayerArtwork(
                              artUri: mediaItem.artUri?.toString(),
                              colorScheme: colorScheme,
                              cacheWidth: PlayerArtwork.miniCacheWidth,
                              iconSize: 22,
                              crossfade: playerTrackChangeMotion(context),
                            ),
                          ),
                        ),
                      ),
                    ),
                    SizedBox(width: compact ? 8 : 12),
                    Expanded(
                      // The lines follow a sideways swipe; the cover stays.
                      child: PlayerTrackCrossfade(
                        trackKey: mediaItem.id,
                        child: PlayerTrackSwipeTitles(
                          current: mediaItem,
                          builder: (mediaItem) => _titles(
                            context,
                            mediaItem,
                            remote: remote,
                            marqueeCycles: marqueeCycles,
                            playing: isPlaying,
                          ),
                        ),
                      ),
                    ),
                    if (!compact && ref.watch(linkPhoneClientProvider) != null)
                      LinkDevicesButton(
                        color: mornye ? colorScheme.onSurface : null,
                      ),
                    if (expressive) ...[
                      const SizedBox(width: 8),
                      // The full player's transport, collapsed to play-pause
                      // and next.
                      ExpressivePlaybackTransport(
                        colorScheme: colorScheme,
                        playing: isPlaying,
                        loading: isLoading,
                        mini: true,
                        playTooltip: isPlaying
                            ? context.l10n.actionPause
                            : context.l10n.tooltipPlay,
                        previousTooltip: context.l10n.nowPlayingPreviousTrack,
                        nextTooltip: context.l10n.nowPlayingNextTrack,
                        onPlayPause: () =>
                            controller.togglePlayPause(isPlaying),
                        onPrevious: controller.previous,
                        onNext: controller.next,
                      ),
                    ] else ...[
                      Row(
                        textDirection: TextDirection.ltr,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          AppIconButton(
                            color: mornye ? colorScheme.onSurface : null,
                            tooltip: isPlaying
                                ? context.l10n.actionPause
                                : context.l10n.tooltipPlay,
                            icon: isLoading
                                ? const AppLoadingIndicator(
                                    size: 20,
                                    strokeWidth: 2.5,
                                  )
                                : AppIcon(
                                    mornye
                                        ? (isPlaying
                                              ? CupertinoIcons.pause_fill
                                              : CupertinoIcons.play_fill)
                                        : (isPlaying
                                              ? Icons.pause
                                              : Icons.play_arrow),
                                  ),
                            onPressed: isLoading
                                ? null
                                : () => controller.togglePlayPause(isPlaying),
                          ),
                          if (!compact)
                            AppIconButton(
                              color: mornye ? colorScheme.onSurface : null,
                              tooltip: context.l10n.nowPlayingNextTrack,
                              icon: AppIcon(
                                mornye
                                    ? CupertinoIcons.forward_fill
                                    : Icons.skip_next,
                              ),
                              onPressed: controller.next,
                            ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
    // Swiping up opens the full player. Sideways swipes dismiss a paused
    // local player; otherwise they change tracks. The title lines
    // follow the finger and return to rest on release.
    // Desktop has no touch gestures: a click opens the player instead.
    final swipeable = isDesktopPlatform
        ? surface
        : PlayerTrackSwipe.follow(
            onRelease: _onHorizontalRelease,
            child: GestureDetector(
              // Measure from touch-down so the slop counts toward the swipe.
              dragStartBehavior: DragStartBehavior.down,
              onVerticalDragStart: (_) {
                _dragUp = 0;
                _openHaptic.update(false);
              },
              onVerticalDragUpdate: _onVerticalDragUpdate,
              onVerticalDragEnd: _onVerticalDragEnd,
              onVerticalDragCancel: () => _dragUp = 0,
              child: PlayerTrackSwipeRegion(
                child: Listener(
                  // Flutter ends an accepted drag even after a pointer cancel.
                  onPointerDown: (_) => _dragCancelled = false,
                  onPointerCancel: (_) => _dragCancelled = true,
                  child: surface,
                ),
              ),
            ),
          );
    return mornye
        ? Padding(
            padding: EdgeInsets.only(bottom: widget.bottomPadding),
            child: Stack(
              fit: StackFit.passthrough,
              children: [
                _MiniPlayerMotionArtworkPrewarmer(mediaItem: mediaItem),
                MornyeGlassPress(
                  radius: 32,
                  child: MornyeGlass.navigation(
                    tintOpacity: MornyeTheme.chromeOpacity(context),
                    blurEnabled: ref.watch(mornyeBlurEnabledProvider),
                    child: swipeable,
                  ),
                ),
              ],
            ),
          )
        // A shell scope that moves only the surface fades this fill while
        // the rest of the scheme swaps at once.
        : PlayerArtworkSurface(
            surface: colorScheme.surface,
            overlay: settingsGroupOverlay(context),
            opacity: 0.72,
            child: swipeable,
          );
  }
}

/// Pre-warms motion artwork video in its own leaf Consumer so resolving the
/// motion clip does not rebuild the mini player body.
class _MiniPlayerMotionArtworkPrewarmer extends ConsumerWidget {
  const _MiniPlayerMotionArtworkPrewarmer({required this.mediaItem});

  final MediaItem mediaItem;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!ref.watch(mornyeLiquidGlassProvider) ||
        !ref.watch(settingsProvider.select((s) => s.motionArtworkEnabled)) ||
        MediaQuery.disableAnimationsOf(context)) {
      return const SizedBox.shrink();
    }
    final artwork = ref
        .watch(
          songMotionArtworkProvider((
            album: mediaItem.album ?? '',
            artist: mediaItem.artist ?? '',
            source: mediaItem.extras?['source']?.toString() ?? '',
          )),
        )
        .value;
    if (artwork != null) {
      ref.watch(playerArtworkVideoProvider(artwork.source));
    }
    return const SizedBox.shrink();
  }
}

class _MiniPlayerProgress extends StatelessWidget {
  final Duration duration;
  final Color backgroundColor;
  final bool playing;

  const _MiniPlayerProgress({
    required this.duration,
    required this.backgroundColor,
    required this.playing,
  });

  static double _progressFor(Duration position, Duration duration) {
    final durationMs = duration.inMilliseconds;
    return durationMs > 0
        ? (position.inMilliseconds / durationMs).clamp(0.0, 1.0)
        : 0.0;
  }

  // Playback progress fills left to right in right-to-left layouts too.
  @override
  Widget build(BuildContext context) {
    final visible = TickerMode.valuesOf(context).enabled;
    return Directionality(
      textDirection: TextDirection.ltr,
      child: _buildProgress(context, visible),
    );
  }

  Widget _buildProgress(BuildContext context, bool visible) {
    if (!materialExpressiveEnabled(context)) {
      return Consumer(
        builder: (context, ref, _) {
          final position = visible
              ? ref.watch(playbackPositionProvider)
              : ref.read(playbackPositionProvider);
          return LinearProgressIndicator(
            value: _progressFor(position, duration),
            minHeight: 2,
            backgroundColor: backgroundColor,
          );
        },
      );
    }
    final motion = AppMotion.effects(
      context,
      const AppMotionSpec(Duration(milliseconds: 300), Curves.easeOut),
    );
    // The wave settles flat while paused and stops moving once flat.
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
      child: MaterialExpressiveScope(
        child: TweenAnimationBuilder<double>(
          tween: Tween(end: playing ? 1 : 0),
          duration: motion.duration,
          curve: motion.curve,
          builder: (context, amplitude, _) => Consumer(
            builder: (context, ref, _) {
              final position = visible
                  ? ref.watch(playbackPositionProvider)
                  : ref.read(playbackPositionProvider);
              return _MiniPlayerWave(
                progress: _progressFor(position, duration),
                trackColor: backgroundColor,
                amplitude: amplitude,
              );
            },
          ),
        ),
      ),
    );
  }
}

/// `M3EProgressIndicator.linearWavy` at the small size, with the wave moved
/// by a [DecorativePhase] instead of a ticker on every display refresh.
class _MiniPlayerWave extends StatefulWidget {
  const _MiniPlayerWave({
    required this.progress,
    required this.trackColor,
    required this.amplitude,
  });

  final double progress;
  final Color trackColor;
  final double amplitude;

  @override
  State<_MiniPlayerWave> createState() => _MiniPlayerWaveState();
}

/// Paints [painterAt] for each value of [phase] as a repaint only, so the
/// wave's ticks rebuild no widget.
class MiniPlayerPhasePainter extends CustomPainter {
  MiniPlayerPhasePainter(this.phase, this.painterAt) : super(repaint: phase);

  final DecorativePhase phase;
  final CustomPainter Function(double phase) painterAt;

  @override
  void paint(Canvas canvas, Size size) =>
      painterAt(phase.value).paint(canvas, size);

  @override
  bool shouldRepaint(MiniPlayerPhasePainter oldDelegate) => true;
}

class _MiniPlayerWaveState extends State<_MiniPlayerWave>
    with WidgetsBindingObserver {
  // The package's wave travels one wavelength per second.
  final _phase = DecorativePhase(const Duration(seconds: 1));
  bool _visible = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _visible = TickerMode.valuesOf(context).enabled;
    _sync();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _sync();
  }

  @override
  void didUpdateWidget(_MiniPlayerWave oldWidget) {
    super.didUpdateWidget(oldWidget);
    _sync();
  }

  void _sync() {
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    final active =
        lifecycle == null ||
        lifecycle == AppLifecycleState.resumed ||
        lifecycle == AppLifecycleState.inactive;
    if (_visible && active && widget.amplitude > 0) {
      _phase.start();
    } else {
      _phase.stop();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _phase.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = M3ETheme.of(context);
    final linear = theme.progressIndicatorTheme.linear;
    final layout = linear.resolveFlat(M3EProgressIndicatorSize.s);
    final progress = widget.progress;
    // Taper toward both ends instead of the theme's hard cutoff.
    final amplitude =
        (widget.amplitude *
                (math.min(progress, 1 - progress) / 0.05).clamp(0.0, 1.0))
            .clamp(0.0, 1.0);
    return Semantics(
      role: SemanticsRole.progressBar,
      minValue: '0',
      maxValue: '100',
      value: '${(progress * 100).round()}%',
      child: RepaintBoundary(
        child: SizedBox(
          height: math.max(
            layout.trackHeight + 2 * linear.waveAmplitude * amplitude,
            linear.wavyContainerHeight,
          ),
          width: double.infinity,
          child: CustomPaint(
            painter: MiniPlayerPhasePainter(
              _phase,
              (phase) => M3ELinearProgressPainter(
                value: progress,
                active: linear.activeColor(theme.colorScheme),
                track: widget.trackColor,
                strokeWidth: layout.trackHeight,
                trackStrokeWidth: layout.trackHeight,
                gap: layout.gap,
                stopSize: layout.dotDiameter,
                isWavy: true,
                waveAmplitude: linear.waveAmplitude,
                wavelength: linear.determinateWavelength,
                phase: phase * 2 * math.pi,
                amplitudeFactor: amplitude,
                trailingMargin: layout.trailingMargin,
                textDirection: Directionality.of(context),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
