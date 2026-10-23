import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/controllers/player_metadata_controller.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/theme/material_expressive.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/utils/playback_seek_preview.dart';
import 'package:mornye/utils/string_utils.dart';
import 'package:mornye/widgets/app_icon.dart';
import 'package:mornye/widgets/app_loading_indicator.dart';
import 'package:mornye/widgets/audio_info_sheet.dart';
import 'package:mornye/widgets/automix_status_badge.dart';
import 'package:mornye/widgets/expressive_icon_button.dart';
import 'package:mornye/widgets/expressive_playback_transport.dart';
import 'package:mornye/widgets/mornye_playback_button.dart';
import 'package:mornye/widgets/mornye_playback_time.dart';
import 'package:mornye/widgets/mornye_player_slider.dart';
import 'package:mornye/widgets/playback_seek_slider.dart';

const _mornyeTimelinePadding = 28.0;

class PlayerPlaybackControls extends ConsumerWidget {
  final String mediaId;
  final Duration duration;
  final PlaybackSeekPreview seekPreview;
  final ColorScheme colorScheme;
  final PlayerMetadataController metadata;
  final bool compact;
  final double transportTopPadding;

  /// The timeline, its times and the transport span the full width with no
  /// side insets, lining up with the artwork above, as in Music's desktop
  /// player.
  final bool edgeAligned;

  const PlayerPlaybackControls({
    super.key,
    required this.mediaId,
    required this.duration,
    required this.seekPreview,
    required this.colorScheme,
    required this.metadata,
    this.compact = false,
    this.transportTopPadding = 16,
    this.edgeAligned = false,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.read(musicPlayerControllerProvider);
    final mornye = context.isMornye;
    final isPlaying = ref.watch(playbackPlayingProvider);
    final isLoading = ref.watch(playbackLoadingProvider);
    final playPauseSize = compact
        ? (isPlaying ? 44.0 : 40.0)
        : (isPlaying ? 60.0 : 54.0);
    final timeStyle = Theme.of(
      context,
    ).textTheme.bodySmall?.copyWith(color: colorScheme.onSurfaceVariant);
    // Time runs left to right in every language: the timeline and the
    // transport keep their order in right-to-left layouts, as Material and
    // Apple's guidelines ask for media controls.
    return Directionality(
      textDirection: TextDirection.ltr,
      child: Column(
        children: [
          // Position ticks repaint only the timeline.
          RepaintBoundary(
            child: ValueListenableBuilder<Duration?>(
              valueListenable: seekPreview,
              builder: (context, preview, _) => Consumer(
                builder: (context, ref, quality) {
                  final position = ref.watch(playbackPositionProvider);
                  final elapsedSeconds = (preview ?? position).inSeconds;
                  return Padding(
                    padding: EdgeInsets.symmetric(
                      horizontal: edgeAligned
                          ? 0
                          : mornye
                          ? _mornyeTimelinePadding
                          : 16,
                    ),
                    child: Column(
                      children: [
                        SliderTheme(
                          data: SliderThemeData(
                            trackHeight: 4,
                            activeTrackColor: mornye
                                ? colorScheme.onSurface
                                : colorScheme.primary,
                            // Material matches the volume slider's M3 inactive
                            // track below it.
                            inactiveTrackColor: mornye
                                ? colorScheme.onSurface.withValues(alpha: 0.18)
                                : colorScheme.secondaryContainer,
                            thumbColor: mornye
                                ? colorScheme.onSurface
                                : colorScheme.primary,
                            // A 7dp thumb was hard to grab; 10dp with a 24dp overlay
                            // gives the drag gesture a full-size target.
                            thumbShape: const RoundSliderThumbShape(
                              enabledThumbRadius: 10,
                            ),
                            overlayShape: const RoundSliderOverlayShape(
                              overlayRadius: 24,
                            ),
                          ),
                          child: PlaybackSeekSlider(
                            key: ValueKey(mediaId),
                            position: position,
                            duration: duration,
                            onSeek: controller.seek,
                            preview: seekPreview,
                            playing: isPlaying && !isLoading,
                            edgeAligned: edgeAligned,
                          ),
                        ),
                        if (!mornye) const SizedBox(height: 8),
                        Padding(
                          padding: EdgeInsets.symmetric(
                            horizontal: edgeAligned
                                ? 0
                                : mornye
                                ? MornyePlayerSlider.horizontalInset
                                : 12,
                          ),
                          child: Row(
                            children: [
                              if (mornye)
                                MornyePlaybackTime(
                                  key: ValueKey('elapsed:$mediaId'),
                                  seconds: elapsedSeconds,
                                  style: timeStyle,
                                )
                              else
                                Text(
                                  formatClock(elapsedSeconds),
                                  style: timeStyle,
                                ),
                              Expanded(child: Center(child: quality)),
                              if (mornye)
                                MornyePlaybackTime(
                                  key: ValueKey('remaining:$mediaId'),
                                  // Subtract whole seconds so both labels roll together,
                                  // even when the track duration includes milliseconds.
                                  seconds: (duration.inSeconds - elapsedSeconds)
                                      .clamp(0, duration.inSeconds),
                                  remaining: true,
                                  style: timeStyle,
                                )
                              else
                                Text(
                                  formatClock(duration.inSeconds),
                                  style: timeStyle,
                                ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  );
                },
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _QualityBadge(metadata: metadata, colorScheme: colorScheme),
                    const AutoMixStatusBadge(),
                  ],
                ),
              ),
            ),
          ),
          SizedBox(
            height: compact ? 8 : transportTopPadding + (mornye ? 0 : 8),
          ),
          if (!mornye && materialExpressiveEnabled(context))
            Padding(
              padding: EdgeInsets.symmetric(horizontal: edgeAligned ? 0 : 16),
              child: ExpressivePlaybackTransport(
                colorScheme: colorScheme,
                playing: isPlaying,
                loading: isLoading,
                compact: compact,
                // Shuffle and repeat line up with the timeline's ends.
                fill: edgeAligned,
                playTooltip: isPlaying
                    ? context.l10n.actionPause
                    : context.l10n.tooltipPlay,
                previousTooltip: context.l10n.nowPlayingPreviousTrack,
                nextTooltip: context.l10n.nowPlayingNextTrack,
                onPlayPause: () => controller.togglePlayPause(isPlaying),
                onPrevious: controller.previous,
                onNext: controller.next,
                leading: PlayerPlaybackModeButton(
                  mode: PlayerPlaybackMode.shuffle,
                  colorScheme: colorScheme,
                ),
                trailing: PlayerPlaybackModeButton(
                  mode: PlayerPlaybackMode.repeat,
                  colorScheme: colorScheme,
                ),
              ),
            )
          else
            Padding(
              padding: EdgeInsets.symmetric(
                horizontal: mornye && !edgeAligned ? (compact ? 16 : 32) : 0,
              ),
              child: Row(
                // Edge to edge, the shuffle and repeat buttons line up with
                // the timeline's ends.
                mainAxisAlignment: edgeAligned && !mornye
                    ? MainAxisAlignment.spaceBetween
                    : MainAxisAlignment.spaceEvenly,
                children: [
                  if (!mornye)
                    PlayerPlaybackModeButton(
                      mode: PlayerPlaybackMode.shuffle,
                      colorScheme: colorScheme,
                    ),
                  if (mornye)
                    MornyePlaybackButton(
                      icon: CupertinoIcons.backward_fill,
                      color: colorScheme.onSurface,
                      tooltip: context.l10n.nowPlayingPreviousTrack,
                      onPressed: controller.previous,
                    )
                  else
                    ExpressiveIconButton(
                      iconSize: 44,
                      foregroundColor: colorScheme.onSurface,
                      tooltip: context.l10n.nowPlayingPreviousTrack,
                      icon: const Icon(Icons.skip_previous),
                      onPressed: controller.previous,
                    ),
                  if (mornye)
                    MornyePlaybackButton(
                      icon: isPlaying
                          ? CupertinoIcons.pause_fill
                          : CupertinoIcons.play_fill,
                      tooltip: isPlaying
                          ? context.l10n.actionPause
                          : context.l10n.tooltipPlay,
                      color: colorScheme.onSurface,
                      iconSize: playPauseSize,
                      // A smaller play glyph keeps the same 68dp touch target and
                      // does not move the timeline, artwork or adjacent buttons.
                      padding: EdgeInsets.all((68 - playPauseSize) / 2),
                      loading: isLoading,
                      onPressed: () => controller.togglePlayPause(isPlaying),
                    )
                  else
                    ExpressiveIconButton(
                      size: 68,
                      iconSize: 44,
                      selected: isPlaying,
                      backgroundColor: colorScheme.primary,
                      foregroundColor: colorScheme.onPrimary,
                      tooltip: isPlaying
                          ? context.l10n.actionPause
                          : context.l10n.tooltipPlay,
                      icon: isLoading
                          ? AppLoadingIndicator(
                              color: colorScheme.onSurfaceVariant,
                            )
                          : Icon(isPlaying ? Icons.pause : Icons.play_arrow),
                      onPressed: isLoading
                          ? null
                          : () => controller.togglePlayPause(isPlaying),
                    ),
                  if (mornye)
                    MornyePlaybackButton(
                      icon: CupertinoIcons.forward_fill,
                      color: colorScheme.onSurface,
                      tooltip: context.l10n.nowPlayingNextTrack,
                      onPressed: controller.next,
                    )
                  else
                    ExpressiveIconButton(
                      iconSize: 44,
                      foregroundColor: colorScheme.onSurface,
                      tooltip: context.l10n.nowPlayingNextTrack,
                      icon: const Icon(Icons.skip_next),
                      onPressed: controller.next,
                    ),
                  if (!mornye)
                    PlayerPlaybackModeButton(
                      mode: PlayerPlaybackMode.repeat,
                      colorScheme: colorScheme,
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

enum PlayerPlaybackMode { autoplay, repeat, shuffle }

/// Queue and transport buttons share behavior while keeping independent watches.
class PlayerPlaybackModeButton extends ConsumerWidget {
  const PlayerPlaybackModeButton({
    super.key,
    required this.mode,
    required this.colorScheme,
    this.secondary = false,
  });

  final PlayerPlaybackMode mode;
  final ColorScheme colorScheme;
  final bool secondary;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.read(musicPlayerControllerProvider);
    late final bool selected;
    late final IconData icon;
    late final String tooltip;
    late final VoidCallback onPressed;
    switch (mode) {
      case PlayerPlaybackMode.autoplay:
        selected = ref.watch(
          settingsProvider.select((settings) => settings.autoplay),
        );
        icon = Icons.all_inclusive;
        tooltip = selected ? context.l10n.autoplayOn : context.l10n.autoplayOff;
        onPressed = () =>
            ref.read(settingsProvider.notifier).setAutoplay(!selected);
      case PlayerPlaybackMode.shuffle:
        selected = ref.watch(
          playbackStateProvider.select(
            (state) => state.value?.shuffleMode == AudioServiceShuffleMode.all,
          ),
        );
        icon = Icons.shuffle;
        tooltip = selected
            ? context.l10n.nowPlayingShuffleOn
            : context.l10n.nowPlayingPlayInOrder;
        onPressed = () => controller.setShuffle(!selected);
      case PlayerPlaybackMode.repeat:
        final repeatMode = ref.watch(
          playbackStateProvider.select(
            (state) => state.value?.repeatMode ?? AudioServiceRepeatMode.none,
          ),
        );
        selected = repeatMode != AudioServiceRepeatMode.none;
        icon = repeatMode == AudioServiceRepeatMode.one
            ? Icons.repeat_one
            : Icons.repeat;
        tooltip = switch (repeatMode) {
          AudioServiceRepeatMode.one => context.l10n.nowPlayingRepeatOne,
          AudioServiceRepeatMode.none => context.l10n.nowPlayingRepeatOff,
          _ => context.l10n.nowPlayingRepeatAll,
        };
        onPressed = () => controller.setRepeatMode(switch (repeatMode) {
          AudioServiceRepeatMode.none => AudioServiceRepeatMode.all,
          AudioServiceRepeatMode.all => AudioServiceRepeatMode.one,
          _ => AudioServiceRepeatMode.none,
        });
    }
    return ExpressiveIconButton(
      iconSize: 24,
      selected: selected,
      tooltip: tooltip,
      icon: Icon(icon),
      foregroundColor: selected
          ? (secondary ? colorScheme.onSecondaryContainer : colorScheme.primary)
          : colorScheme.onSurfaceVariant,
      backgroundColor: selected
          ? (secondary
                ? colorScheme.secondaryContainer
                : colorScheme.primaryContainer)
          : null,
      onPressed: onPressed,
    );
  }
}

class _QualityBadge extends StatelessWidget {
  final PlayerMetadataController metadata;
  final ColorScheme colorScheme;

  const _QualityBadge({required this.metadata, required this.colorScheme});

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: metadata,
    builder: (context, _) => _buildBadge(context),
  );

  Widget _buildBadge(BuildContext context) {
    final text = metadata.qualityLabel;
    if (text == null || text.isEmpty) return const SizedBox.shrink();
    final mornye = context.isMornye;
    final radius = BorderRadius.circular(20);
    final badge = Container(
      padding: EdgeInsets.symmetric(
        horizontal: mornye ? 8 : 10,
        vertical: mornye ? 2 : 5,
      ),
      decoration: mornye
          ? null
          : BoxDecoration(
              color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
              borderRadius: radius,
            ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          AppIcon(
            Icons.graphic_eq,
            size: mornye ? 11 : 14,
            color: colorScheme.onSurfaceVariant,
          ),
          SizedBox(width: mornye ? 5 : 6),
          Flexible(
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                fontSize: mornye ? 10.5 : 12,
                color: colorScheme.onSurfaceVariant,
                letterSpacing: 0.2,
              ),
            ),
          ),
        ],
      ),
    );
    final label = context.l10n.audioInfoTitle;
    return Semantics(
      button: true,
      label: label,
      child: Tooltip(
        message: label,
        excludeFromSemantics: true,
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            borderRadius: radius,
            onTap: () => showAudioInfoSheet(context, metadata: metadata),
            child: badge,
          ),
        ),
      ),
    );
  }
}
