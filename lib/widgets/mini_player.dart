import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart' show DragStartBehavior;
import 'package:flutter/semantics.dart' show SemanticsRole;
import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart' show CupertinoIcons;
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
import 'package:mornye/widgets/cached_cover_image.dart';
import 'package:mornye/widgets/decorative_phase.dart';
import 'package:mornye/widgets/link/link_devices_sheet.dart';
import 'package:mornye/widgets/overflow_marquee.dart';
import 'package:mornye/widgets/player_artwork.dart';
import 'package:mornye/widgets/settings_group.dart';
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

  void _warmFullScreenArtwork(Uri? artUri) {
    if (context.isMornye ||
        isDesktopPlatform ||
        artUri == null ||
        ref.read(settingsProvider).playerCoverStyleFor(mornye: false) !=
            'fullscreen' ||
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
      currentMediaItemProvider.select((item) => item.value?.artUri),
    );
    return PlayerArtworkTheme(artUri: artUri?.toString(), child: body);
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
  double _dragAcross = 0;
  bool _dragCancelled = false;

  void _openNowPlaying() {
    Navigator.of(context, rootNavigator: true).push(
      NowPlayingRoute(
        child: const NowPlayingScreen(),
        miniPlayerGeometry: context.isMornye
            ? () {
                if (!mounted) return null;
                final surface = _bounds(_surfaceKey);
                final artwork = _bounds(_artworkKey);
                if (surface == null || artwork == null) return null;
                return (surface: surface, artwork: artwork);
              }
            : null,
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

  void _onHorizontalDragEnd(DragEndDetails details) {
    final travel = _dragAcross;
    _dragAcross = 0;
    final velocity = details.primaryVelocity ?? 0;
    if (_dragCancelled || (travel.abs() < 48 && velocity.abs() < 550)) return;
    final direction = velocity.abs() >= 550 ? velocity : travel;
    final controller = ref.read(musicPlayerControllerProvider);
    if (!context.isMornye &&
        !ref.read(playbackPlayingProvider) &&
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
    // Frosted and flat glass levels run on constrained Android hardware. They
    // skip keeping a paused video decoder for the full player's motion cover.
    final fullEffects = !mornye || ref.watch(mornyeLiquidGlassProvider);
    // Every marquee frame re-filters the glass chrome around it, so Mornye
    // stops the title after a few passes on every glass level.
    final marqueeCycles = mornye ? 2 : null;
    if (mornye &&
        fullEffects &&
        ref.watch(settingsProvider.select((s) => s.motionArtworkEnabled)) &&
        !MediaQuery.disableAnimationsOf(context)) {
      final artwork = ref
          .watch(
            playerMotionArtworkProvider((
              album: mediaItem.album ?? '',
              artist: mediaItem.artist ?? '',
            )),
          )
          .value;
      if (artwork != null) {
        ref.watch(playerArtworkVideoProvider(artwork.source));
      }
    }

    final surface = DecoratedBox(
      key: _surfaceKey,
      position: DecorationPosition.foreground,
      decoration: BoxDecoration(
        border: mornye
            ? null
            : Border(
                top: BorderSide(
                  color: colorScheme.outlineVariant.withValues(alpha: 0.5),
                ),
              ),
      ),
      child: Material(
        color: mornye
            ? Colors.transparent
            : settingsGroupColor(context).withValues(alpha: 0.72),
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
                      child: ClipRRect(
                        key: _artworkKey,
                        borderRadius: BorderRadius.circular(mornye ? 6 : 12),
                        child: SizedBox(
                          width: context.tokens.coverMini,
                          height: context.tokens.coverMini,
                          child: PlayerArtwork(
                            artUri: mediaItem.artUri?.toString(),
                            colorScheme: colorScheme,
                            cacheWidth: PlayerArtwork.miniCacheWidth,
                            iconSize: 22,
                          ),
                        ),
                      ),
                    ),
                    SizedBox(width: compact ? 8 : 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          OverflowMarquee(
                            resetKey: (mediaItem.id, mediaItem.title),
                            maxCycles: marqueeCycles,
                            child: ExplicitTrackTitle(
                              title: mediaItem.title,
                              explicit:
                                  parseExplicitFlag(
                                    mediaItem.extras?['explicit'],
                                  ) ==
                                  true,
                              style: Theme.of(context).textTheme.titleSmall
                                  ?.copyWith(fontWeight: FontWeight.w600),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          // Where the music plays while the paired desktop
                          // plays in this phone's place.
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
                              child: Text(
                                mediaItem.artist ?? '',
                                style: Theme.of(context).textTheme.bodySmall
                                    ?.copyWith(
                                      color: mornye
                                          ? Color.lerp(
                                              colorScheme.onSurfaceVariant,
                                              colorScheme.onSurface,
                                              colorScheme.brightness ==
                                                      Brightness.dark
                                                  ? 0.7
                                                  : 0.6,
                                            )
                                          : colorScheme.onSurfaceVariant,
                                    ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                        ],
                      ),
                    ),
                    if (!compact && ref.watch(linkPhoneClientProvider) != null)
                      LinkDevicesButton(
                        color: mornye ? colorScheme.onSurface : null,
                      ),
                    if (expressive)
                      AppIconButton.filled(
                        tooltip: isPlaying
                            ? context.l10n.actionPause
                            : context.l10n.tooltipPlay,
                        isSelected: isPlaying,
                        style: IconButton.styleFrom(
                          backgroundColor: colorScheme.primary,
                          foregroundColor: colorScheme.onPrimary,
                        ),
                        icon: isLoading
                            ? AppLoadingIndicator(
                                size: 20,
                                color: colorScheme.onPrimary,
                              )
                            : const AppIcon(Icons.play_arrow),
                        selectedIcon: isLoading
                            ? AppLoadingIndicator(
                                size: 20,
                                color: colorScheme.onPrimary,
                              )
                            : const AppIcon(Icons.pause),
                        onPressed: isLoading
                            ? null
                            : () => controller.togglePlayPause(isPlaying),
                      )
                    else
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
              ),
            ],
          ),
        ),
      ),
    );
    // Swiping up opens the full player. Sideways swipes dismiss a paused
    // local Material player; otherwise they change tracks.
    // Desktop has no touch gestures: a click opens the player instead.
    final swipeable = isDesktopPlatform
        ? surface
        : GestureDetector(
            // Measure from touch-down so the slop counts toward the swipe.
            dragStartBehavior: DragStartBehavior.down,
            onVerticalDragStart: (_) => _dragUp = 0,
            onVerticalDragUpdate: (details) =>
                _dragUp -= details.primaryDelta ?? 0,
            onVerticalDragEnd: _onVerticalDragEnd,
            onVerticalDragCancel: () => _dragUp = 0,
            onHorizontalDragStart: (_) => _dragAcross = 0,
            onHorizontalDragUpdate: (details) =>
                _dragAcross += details.primaryDelta ?? 0,
            onHorizontalDragEnd: _onHorizontalDragEnd,
            onHorizontalDragCancel: () => _dragAcross = 0,
            child: Listener(
              // Flutter ends an accepted drag even after a pointer cancel.
              onPointerDown: (_) => _dragCancelled = false,
              onPointerCancel: (_) => _dragCancelled = true,
              child: surface,
            ),
          );
    return mornye
        ? Padding(
            padding: EdgeInsets.only(bottom: widget.bottomPadding),
            child: MornyeGlassPress(
              radius: 32,
              child: MornyeGlass.navigation(
                strongTint: true,
                tintOpacity: MornyeTheme.chromeOpacity(context),
                blurEnabled: ref.watch(mornyeBlurEnabledProvider),
                child: swipeable,
              ),
            ),
          )
        : swipeable;
  }
}

class _MiniPlayerProgress extends ConsumerWidget {
  final Duration duration;
  final Color backgroundColor;
  final bool playing;

  const _MiniPlayerProgress({
    required this.duration,
    required this.backgroundColor,
    required this.playing,
  });

  // Playback progress fills left to right in right-to-left layouts too.
  @override
  Widget build(BuildContext context, WidgetRef ref) => Directionality(
    textDirection: TextDirection.ltr,
    child: _buildProgress(context, ref),
  );

  Widget _buildProgress(BuildContext context, WidgetRef ref) {
    final durationMs = duration.inMilliseconds;
    final positionMs = ref.watch(playbackPositionProvider).inMilliseconds;
    final progress = durationMs > 0
        ? (positionMs / durationMs).clamp(0.0, 1.0)
        : 0.0;
    if (!materialExpressiveEnabled(context)) {
      return LinearProgressIndicator(
        value: progress,
        minHeight: 2,
        backgroundColor: backgroundColor,
      );
    }
    final motion = AppMotion.effects(
      context,
      const AppMotionSpec(Duration(milliseconds: 300), Curves.easeOut),
    );
    // The wave settles flat while paused and stops moving once flat.
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
      child: TweenAnimationBuilder<double>(
        tween: Tween(end: playing ? 1 : 0),
        duration: motion.duration,
        curve: motion.curve,
        builder: (context, amplitude, _) => MaterialExpressiveScope(
          child: _MiniPlayerWave(
            progress: progress,
            trackColor: backgroundColor,
            amplitude: amplitude,
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

class _MiniPlayerWaveState extends State<_MiniPlayerWave> {
  // The package's wave travels one wavelength per second.
  final _phase = DecorativePhase(const Duration(seconds: 1));
  bool _visible = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _visible = TickerMode.valuesOf(context).enabled;
    _sync();
  }

  @override
  void didUpdateWidget(_MiniPlayerWave oldWidget) {
    super.didUpdateWidget(oldWidget);
    _sync();
  }

  void _sync() =>
      _visible && widget.amplitude > 0 ? _phase.start() : _phase.stop();

  @override
  void dispose() {
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
          child: ValueListenableBuilder(
            valueListenable: _phase,
            builder: (context, phase, _) => CustomPaint(
              painter: M3ELinearProgressPainter(
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
