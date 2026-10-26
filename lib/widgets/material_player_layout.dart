import 'dart:math' as math;

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/controllers/clickable_metadata.dart';
import 'package:mornye/controllers/player_metadata_controller.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/routes/now_playing_route.dart';
import 'package:mornye/theme/app_motion.dart';
import 'package:mornye/utils/playback_seek_preview.dart';
import 'package:mornye/widgets/player_artwork.dart';
import 'package:mornye/widgets/player_compact_bar.dart';
import 'package:mornye/widgets/player_gesture_regions.dart';
import 'package:mornye/widgets/player_lyrics_controls.dart';
import 'package:mornye/widgets/player_metadata_title.dart';
import 'package:mornye/widgets/player_playback_controls.dart';
import 'package:mornye/widgets/player_volume_control.dart';

class MaterialPlayerLayout extends StatelessWidget {
  const MaterialPlayerLayout({
    super.key,
    required this.mediaItem,
    required this.metadata,
    required this.seekPreview,
    required this.colorScheme,
    required this.showLyrics,
    required this.lyricsBuilder,
    required this.onOpenQueue,
    this.fullScreenArtwork = false,
    this.landscapeLyricsArtwork = false,
    this.immersive = false,
    this.compactPlayer = false,
    this.onCompactPlayerTouch,
  });

  final MediaItem mediaItem;
  final PlayerMetadataController metadata;
  final PlaybackSeekPreview seekPreview;
  final ColorScheme colorScheme;
  final bool showLyrics;
  final WidgetBuilder lyricsBuilder;
  final VoidCallback onOpenQueue;

  /// The page backdrop paints the cover; this area only keeps its gestures.
  final bool fullScreenArtwork;

  /// Replaces landscape track details with artwork alongside the lyrics.
  final bool landscapeLyricsArtwork;

  /// Lyrics left idle while playing: the title and controls fold away so
  /// the lyrics fill the column.
  final bool immersive;

  /// Immersive portrait lyrics shrink the title and controls to a smaller
  /// player instead of folding them away entirely.
  final bool compactPlayer;

  /// A touch landed on the compact player, before the page's own listener
  /// sees it.
  final VoidCallback? onCompactPlayerTouch;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        Widget artworkAt(double artSize) => fullScreenArtwork
            ? const PlayerArtworkDragRegion(
                child: ColoredBox(
                  color: Colors.transparent,
                  child: SizedBox.expand(),
                ),
              )
            : Center(
                child: PlayerArtworkDragRegion(
                  child: Hero(
                    tag: kNowPlayingArtworkHeroTag,
                    child: Consumer(
                      builder: (context, ref, artwork) {
                        final resting =
                            !ref.watch(playbackPlayingProvider) &&
                            !ref.watch(playbackLoadingProvider);
                        final motion = AppMotion.spatialSlow(
                          context,
                          AppMotionSpec(
                            MediaQuery.disableAnimationsOf(context)
                                ? Duration.zero
                                : const Duration(milliseconds: 500),
                            Curves.easeOutBack,
                          ),
                        );
                        return AnimatedScale(
                          scale: resting ? 0.9 : 1,
                          duration: motion.duration,
                          curve: motion.curve,
                          child: TweenAnimationBuilder<double>(
                            tween: Tween(end: resting ? 40 : 20),
                            duration: motion.duration,
                            curve: motion.curve,
                            builder: (context, radius, artwork) => ClipRRect(
                              borderRadius: BorderRadius.circular(radius),
                              child: artwork,
                            ),
                            child: artwork,
                          ),
                        );
                      },
                      child: SizedBox(
                        width: artSize,
                        height: artSize,
                        child: AnimatedSwitcher(
                          duration: MediaQuery.disableAnimationsOf(context)
                              ? Duration.zero
                              : const Duration(milliseconds: 450),
                          switchInCurve: Curves.easeOutCubic,
                          switchOutCurve: Curves.easeInCubic,
                          transitionBuilder: (child, animation) =>
                              FadeTransition(
                                opacity: animation,
                                child: ScaleTransition(
                                  scale: Tween(
                                    begin: 0.94,
                                    end: 1.0,
                                  ).animate(animation),
                                  child: child,
                                ),
                              ),
                          child: PlayerArtwork(
                            key: ValueKey(
                              mediaItem.artUri?.toString() ?? mediaItem.id,
                            ),
                            artUri: mediaItem.artUri?.toString(),
                            colorScheme: colorScheme,
                            cacheWidth:
                                (artSize *
                                        MediaQuery.devicePixelRatioOf(context))
                                    .round(),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              );

        Widget cover() => LayoutBuilder(
          key: const ValueKey('material-player-cover'),
          builder: (context, area) => artworkAt(
            math.max(
              0.0,
              math.min(
                360.0,
                math.min(area.maxWidth - 64, area.maxHeight - 24),
              ),
            ),
          ),
        );

        Widget visual() => AnimatedSwitcher(
          duration: MediaQuery.disableAnimationsOf(context)
              ? Duration.zero
              : const Duration(milliseconds: 300),
          switchInCurve: Curves.easeInOutCubic,
          switchOutCurve: Curves.easeInOutCubic,
          child: showLyrics
              ? KeyedSubtree(
                  key: const ValueKey('material-player-lyrics'),
                  child: lyricsBuilder(context),
                )
              : cover(),
        );

        // Tablet/landscape: artwork pane left, metadata and controls right,
        // instead of one narrow column in a sea of empty space.
        final landscape =
            MediaQuery.orientationOf(context) == Orientation.landscape;
        final artworkBesideLyrics = landscapeLyricsArtwork && landscape;
        final twoPane =
            landscape ||
            (constraints.maxWidth >= 720 &&
                constraints.maxWidth > constraints.maxHeight);
        if (twoPane) {
          if (artworkBesideLyrics) {
            return Row(
              key: const ValueKey('material-landscape-artwork-lyrics'),
              children: [
                Expanded(child: cover()),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    child: Column(
                      children: [
                        ..._metadataAndControls(
                          context,
                          compact: true,
                          showControls: false,
                        ),
                        Expanded(
                          child: AnimatedSwitcher(
                            duration: MediaQuery.disableAnimationsOf(context)
                                ? Duration.zero
                                : const Duration(milliseconds: 300),
                            child: showLyrics
                                ? KeyedSubtree(
                                    key: const ValueKey('landscape-lyrics'),
                                    child: lyricsBuilder(context),
                                  )
                                : LayoutBuilder(
                                    key: const ValueKey('landscape-controls'),
                                    builder: (context, area) =>
                                        SingleChildScrollView(
                                          child: ConstrainedBox(
                                            constraints: BoxConstraints(
                                              minHeight: area.maxHeight,
                                            ),
                                            child: Column(
                                              mainAxisAlignment:
                                                  MainAxisAlignment.center,
                                              children: _metadataAndControls(
                                                context,
                                                compact: true,
                                                showMetadata: false,
                                              ),
                                            ),
                                          ),
                                        ),
                                  ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            );
          }
          return Row(
            children: [
              Expanded(child: visual()),
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      minHeight: constraints.maxHeight - 32,
                    ),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: _metadataAndControls(context, compact: true),
                    ),
                  ),
                ),
              ),
            ],
          );
        }

        return Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Column(
            children: [
              Expanded(child: visual()),
              PlayerLyricsControlsCollapse(
                hidden: immersive && showLyrics,
                child: Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: PlayerQueueSwipeRegion(
                    onOpenQueue: onOpenQueue,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      // Short phones keep the room for artwork and lyrics;
                      // the hardware buttons still set the volume there.
                      children: _metadataAndControls(
                        context,
                        showVolume: constraints.maxHeight >= 600,
                      ),
                    ),
                  ),
                ),
              ),
              // Unfolds as the full controls fold, in the same motion. Its
              // timeline rests while folded, and touches on it keep it
              // compact instead of restoring the full player.
              if (compactPlayer)
                PlayerLyricsControlsCollapse(
                  hidden: !(immersive && showLyrics),
                  child: TickerMode(
                    enabled: immersive && showLyrics,
                    child: Listener(
                      onPointerDown: (_) => onCompactPlayerTouch?.call(),
                      child: PlayerQueueSwipeRegion(
                        onOpenQueue: onOpenQueue,
                        child: PlayerCompactBar(
                          mediaItem: mediaItem,
                          seekPreview: seekPreview,
                          colorScheme: colorScheme,
                          onOpenQueue: onOpenQueue,
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  /// Title/artist, seek slider, transport buttons and volume, shared by the
  /// portrait column and the landscape right pane.
  List<Widget> _metadataAndControls(
    BuildContext context, {
    bool compact = false,
    bool showVolume = true,
    bool showMetadata = true,
    bool showControls = true,
  }) {
    final fallback = AppMotionSpec(
      MediaQuery.disableAnimationsOf(context)
          ? Duration.zero
          : const Duration(milliseconds: 350),
      Curves.linear,
    );
    final slide = AppMotion.spatial(context, fallback);
    final fade = AppMotion.effects(context, fallback);
    return [
      if (showMetadata) ...[
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 28),
          child: ClipRect(
            child: AnimatedSwitcher(
              duration: slide.duration,
              // Finish fading the old title before revealing the next one. This
              // also keeps rapid skips from stacking several readable titles.
              transitionBuilder: (child, animation) => FadeTransition(
                opacity: animation.drive(
                  CurveTween(curve: Interval(0.5, 1, curve: fade.curve)),
                ),
                child: SlideTransition(
                  position: Tween(begin: const Offset(0, 0.4), end: Offset.zero)
                      .chain(
                        CurveTween(curve: Interval(0.5, 1, curve: slide.curve)),
                      )
                      .animate(animation),
                  child: child,
                ),
              ),
              child: Row(
                key: ValueKey(mediaItem.id),
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        PlayerMetadataTitle(
                          mediaItem: mediaItem,
                          metadata: metadata,
                          style:
                              (compact
                                      ? Theme.of(context).textTheme.titleLarge
                                      : Theme.of(
                                          context,
                                        ).textTheme.headlineSmall)
                                  ?.copyWith(
                                    fontWeight: FontWeight.bold,
                                    color: colorScheme.onSurface,
                                  ),
                          textAlign: TextAlign.start,
                          maxLines: compact ? 1 : 2,
                        ),
                        SizedBox(height: compact ? 4 : 6),
                        Consumer(
                          builder: (context, ref, _) {
                            final track = ref
                                .watch(playerCollectionTrackProvider(mediaItem))
                                .value;
                            // No extensionId: a downloaded track's source is
                            // its download service, not a metadata catalog.
                            return ClickableArtistName(
                              artistName: mediaItem.artist ?? '',
                              artistId: track?.artistId,
                              style: Theme.of(context).textTheme.titleMedium
                                  ?.copyWith(
                                    color: colorScheme.onSurfaceVariant,
                                  ),
                              textAlign: TextAlign.start,
                            );
                          },
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        SizedBox(height: compact ? 12 : 24),
      ],
      if (showControls) ...[
        PlayerPlaybackControls(
          key: ValueKey(mediaItem.id),
          mediaId: mediaItem.id,
          duration: mediaItem.duration ?? Duration.zero,
          seekPreview: seekPreview,
          colorScheme: colorScheme,
          metadata: metadata,
          compact: compact,
          // The footer's toolbar holds shuffle and repeat.
          showPlaybackModes: false,
        ),
        if (showVolume)
          // The player menu can hide it; the hardware buttons still apply. The
          // gap stays so the transport keeps its room above the footer.
          Consumer(
            builder: (context, ref, _) => Padding(
              padding: EdgeInsets.only(top: compact ? 8 : 12),
              child:
                  ref.watch(settingsProvider.select((s) => s.playerShowVolume))
                  ? const PlayerVolumeControl()
                  : null,
            ),
          ),
      ],
    ];
  }
}
