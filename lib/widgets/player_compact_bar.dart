import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/theme/material_expressive.dart';
import 'package:mornye/utils/playback_seek_preview.dart';
import 'package:mornye/utils/string_utils.dart';
import 'package:mornye/widgets/app_icon.dart';
import 'package:mornye/widgets/app_icon_button.dart';
import 'package:mornye/widgets/app_loading_indicator.dart';
import 'package:mornye/widgets/audio_quality_badges.dart';
import 'package:mornye/widgets/expressive_icon_button.dart';
import 'package:mornye/widgets/expressive_playback_transport.dart';
import 'package:mornye/widgets/playback_seek_slider.dart';

/// Material's compact player: idle lyrics shrink the full player to this
/// smaller one (title, timeline and transport, with the times beside the
/// transport) instead of hiding it, so the lyrics take the room the full
/// player leaves while skipping and seeking stay at hand. A tap elsewhere
/// brings the full player back.
class PlayerCompactBar extends ConsumerWidget {
  const PlayerCompactBar({
    super.key,
    required this.mediaItem,
    required this.seekPreview,
    required this.colorScheme,
    required this.onOpenQueue,
  });

  final MediaItem mediaItem;
  final PlaybackSeekPreview seekPreview;
  final ColorScheme colorScheme;

  /// The app bar's queue button fades with the full player, so the compact
  /// one carries its own.
  final VoidCallback onOpenQueue;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.read(musicPlayerControllerProvider);
    final playing = ref.watch(playbackPlayingProvider);
    final loading = ref.watch(playbackLoadingProvider);
    final textTheme = Theme.of(context).textTheme;
    final duration = mediaItem.duration ?? Duration.zero;
    final timeStyle = textTheme.bodySmall?.copyWith(
      color: colorScheme.onSurfaceVariant,
    );
    final playTooltip = playing
        ? context.l10n.actionPause
        : context.l10n.tooltipPlay;
    final transport = materialExpressiveEnabled(context)
        ? ExpressivePlaybackTransport(
            colorScheme: colorScheme,
            playing: playing,
            loading: loading,
            compact: true,
            playTooltip: playTooltip,
            previousTooltip: context.l10n.nowPlayingPreviousTrack,
            nextTooltip: context.l10n.nowPlayingNextTrack,
            onPlayPause: () => controller.togglePlayPause(playing),
            onPrevious: controller.previous,
            onNext: controller.next,
          )
        : Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              ExpressiveIconButton(
                iconSize: 32,
                foregroundColor: colorScheme.onSurface,
                tooltip: context.l10n.nowPlayingPreviousTrack,
                icon: const Icon(Icons.skip_previous),
                onPressed: controller.previous,
              ),
              const SizedBox(width: 8),
              ExpressiveIconButton(
                size: 56,
                iconSize: 32,
                selected: playing,
                backgroundColor: colorScheme.primary,
                foregroundColor: colorScheme.onPrimary,
                tooltip: playTooltip,
                icon: loading
                    ? AppLoadingIndicator(color: colorScheme.onPrimary)
                    : Icon(playing ? Icons.pause : Icons.play_arrow),
                onPressed: loading
                    ? null
                    : () => controller.togglePlayPause(playing),
              ),
              const SizedBox(width: 8),
              ExpressiveIconButton(
                iconSize: 32,
                foregroundColor: colorScheme.onSurface,
                tooltip: context.l10n.nowPlayingNextTrack,
                icon: const Icon(Icons.skip_next),
                onPressed: controller.next,
              ),
            ],
          );
    // Time runs left to right in every language, as in the full player.
    return Directionality(
      textDirection: TextDirection.ltr,
      child: Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsetsDirectional.only(start: 28, end: 16),
              child: Directionality(
                textDirection: Directionality.of(context),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          ExplicitTrackTitle(
                            title: mediaItem.title,
                            explicit:
                                parseExplicitFlag(
                                  mediaItem.extras?['explicit'],
                                ) ==
                                true,
                            style: textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.bold,
                              color: colorScheme.onSurface,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          Text(
                            mediaItem.artist ?? '',
                            style: textTheme.bodyMedium?.copyWith(
                              color: colorScheme.onSurfaceVariant,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                    AppIconButton(
                      tooltip: context.l10n.nowPlayingUpNext,
                      color: colorScheme.onSurfaceVariant,
                      icon: const AppIcon(Icons.queue_music),
                      onPressed: onOpenQueue,
                    ),
                  ],
                ),
              ),
            ),
            // Position ticks repaint only the timeline and the elapsed time.
            RepaintBoundary(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: SliderTheme(
                  data: SliderThemeData(
                    trackHeight: 4,
                    activeTrackColor: colorScheme.primary,
                    inactiveTrackColor: colorScheme.secondaryContainer,
                    thumbColor: colorScheme.primary,
                    thumbShape: const RoundSliderThumbShape(
                      enabledThumbRadius: 8,
                    ),
                    overlayShape: const RoundSliderOverlayShape(
                      overlayRadius: 20,
                    ),
                  ),
                  child: Consumer(
                    builder: (context, ref, _) => PlaybackSeekSlider(
                      key: ValueKey(mediaItem.id),
                      position: ref.watch(playbackPositionProvider),
                      duration: duration,
                      onSeek: controller.seek,
                      preview: seekPreview,
                      playing: playing && !loading,
                    ),
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 28),
              child: Row(
                children: [
                  Expanded(
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: RepaintBoundary(
                        child: ValueListenableBuilder<Duration?>(
                          valueListenable: seekPreview,
                          builder: (context, preview, _) => Consumer(
                            builder: (context, ref, _) {
                              final position = ref.watch(
                                playbackPositionProvider,
                              );
                              return Text(
                                formatClock((preview ?? position).inSeconds),
                                style: timeStyle,
                              );
                            },
                          ),
                        ),
                      ),
                    ),
                  ),
                  transport,
                  Expanded(
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: Text(
                        formatClock(duration.inSeconds),
                        style: timeStyle,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
