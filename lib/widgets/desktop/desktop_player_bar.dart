import 'dart:async';
import 'dart:math' as math;

import 'package:audio_service/audio_service.dart';
import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/controllers/player_metadata_controller.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/theme/app_tokens.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/theme/player_artwork_theme.dart';
import 'package:mornye/utils/lyrics_parser.dart';
import 'package:mornye/utils/string_utils.dart';
import 'package:mornye/widgets/app_icon.dart';
import 'package:mornye/widgets/app_icon_button.dart';
import 'package:mornye/widgets/app_loading_indicator.dart';
import 'package:mornye/widgets/audio_quality_badges.dart';
import 'package:mornye/widgets/desktop/desktop_commands.dart';
import 'package:mornye/widgets/desktop/desktop_downloads_button.dart';
import 'package:mornye/widgets/desktop/desktop_inspector.dart';
import 'package:mornye/widgets/desktop/desktop_link_devices_button.dart';
import 'package:mornye/widgets/desktop/desktop_window.dart';
import 'package:mornye/widgets/desktop/desktop_volume_scroll.dart';
import 'package:mornye/widgets/mornye_chrome.dart';
import 'package:mornye/widgets/mornye_playback_button.dart';
import 'package:mornye/widgets/mornye_player_background.dart';
import 'package:mornye/widgets/player_artwork.dart';
import 'package:mornye/widgets/player_lyrics.dart';
import 'package:mornye/widgets/player_volume_control.dart';
import 'package:mornye/widgets/playback_seek_slider.dart';

part 'desktop_mini_player.dart';

/// The persistent desktop player. It replaces the mobile mini player: no
/// swipe gestures, with transport, seek, volume, lyrics, Up Next and
/// downloads always in reach. Clicking the artwork or title shows Now
/// Playing in the content pane; lyrics and Up Next toggle the trailing
/// inspector.
///
/// Material docks an 80dp bar along the bottom of the window, on the
/// `surfaceContainer` fill of the current artwork's scheme
/// ([PlayerArtworkTheme]). Mornye draws a glass capsule that the shell
/// floats over the bottom of the content pane, laid out like the Music
/// player: shuffle and the transport, a center "LCD" with the track and its
/// progress, then lyrics, Up Next, downloads and volume.
class DesktopPlayerBar extends ConsumerWidget {
  const DesktopPlayerBar({super.key});

  static const double materialHeight = 80;

  /// Height of the Mornye capsule.
  static const double mornyeHeight = 48;

  /// Space between the Mornye capsule and the bottom of the window.
  static const double floatingMargin = 10;

  /// Bottom padding the content pane gives its pages, so their last rows
  /// scroll clear of the floating capsule with a margin above it.
  static const double floatingInset = mornyeHeight + floatingMargin + 12;

  /// Width of the Mornye capsule in a content pane [paneWidth] wide: about
  /// 70% of it, as in Music, from 520 to 900 and never closer than 12 to
  /// the pane's sides.
  static double floatingWidth(double paneWidth) => math.min(
    (paneWidth * 0.7).clamp(520.0, 900.0),
    math.max(0.0, paneWidth - 24),
  );

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mediaItem = ref.watch(currentMediaItemProvider).value;
    return context.isMornye
        ? _MornyePlayerBar(mediaItem: mediaItem)
        // The bar takes the track's artwork scheme; the downloads popover
        // it hosts keeps the app scheme.
        : PlayerArtworkTheme(
            artUri: mediaItem?.artUri?.toString(),
            child: _MaterialPlayerBar(
              mediaItem: mediaItem,
              appTheme: Theme.of(context),
            ),
          );
  }
}

/// Shows Now Playing in the content pane, or returns to the content when it
/// is already showing.
void _toggleNowPlaying() =>
    desktopNowPlayingOpen.value = !desktopNowPlayingOpen.value;

class _MaterialPlayerBar extends StatelessWidget {
  const _MaterialPlayerBar({required this.mediaItem, required this.appTheme});

  final MediaItem? mediaItem;

  /// The theme outside the bar's artwork scope.
  final ThemeData appTheme;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final loaded = mediaItem != null;
    return Material(
      color: colorScheme.surfaceContainer,
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: DesktopPlayerBar.materialHeight,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                Expanded(
                  flex: 3,
                  child: Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: _TrackSummary(mediaItem: mediaItem),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  flex: 4,
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      _Transport(enabled: loaded),
                      SizedBox(
                        height: 24,
                        child: _SeekRow(mediaItem: mediaItem),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  flex: 3,
                  child: _TrailingControls(enabled: loaded, appTheme: appTheme),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The Mornye capsule, laid out like the Music player: shuffle, the
/// transport and repeat, the LCD, then downloads, lyrics, Up Next and a
/// volume button whose slider opens in a popover. Its buttons take macOS
/// toolbar sizes rather than touch sizes.
class _MornyePlayerBar extends StatelessWidget {
  const _MornyePlayerBar({required this.mediaItem});

  final MediaItem? mediaItem;

  @override
  Widget build(BuildContext context) {
    final loaded = mediaItem != null;
    return SizedBox(
      height: DesktopPlayerBar.mornyeHeight,
      child: MornyeGlassPanel(
        radius: DesktopPlayerBar.mornyeHeight / 2,
        highlightBorder: true,
        child: IconButtonTheme(
          data: IconButtonThemeData(
            style: IconButton.styleFrom(
              minimumSize: const Size.square(32),
              fixedSize: const Size.square(32),
              padding: EdgeInsets.zero,
              iconSize: 17,
              visualDensity: VisualDensity.compact,
            ),
          ),
          child: Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(8, 4, 8, 4),
            child: Row(
              children: [
                _MornyeModeButton(mode: _MornyeMode.shuffle, enabled: loaded),
                _Transport(enabled: loaded),
                _MornyeModeButton(mode: _MornyeMode.repeat, enabled: loaded),
                const SizedBox(width: 8),
                Expanded(child: _MornyeLcd(mediaItem: mediaItem)),
                const SizedBox(width: 8),
                _TrailingControls(enabled: loaded),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

enum _MornyeMode { shuffle, repeat }

/// Shuffle or repeat in the capsule: small secondary glyphs, accent while
/// on, as in Music, and dimmed while nothing is loaded.
class _MornyeModeButton extends ConsumerWidget {
  const _MornyeModeButton({required this.mode, required this.enabled});

  final _MornyeMode mode;
  final bool enabled;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.read(musicPlayerControllerProvider);
    final l10n = context.l10n;
    final colorScheme = Theme.of(context).colorScheme;
    late final bool selected;
    late final IconData icon;
    late final String tooltip;
    late final VoidCallback onPressed;
    switch (mode) {
      case _MornyeMode.shuffle:
        selected = ref.watch(
          playbackStateProvider.select(
            (state) => state.value?.shuffleMode == AudioServiceShuffleMode.all,
          ),
        );
        icon = CupertinoIcons.shuffle;
        tooltip = selected
            ? l10n.nowPlayingShuffleOn
            : l10n.nowPlayingPlayInOrder;
        onPressed = () => controller.setShuffle(!selected);
      case _MornyeMode.repeat:
        final repeatMode = ref.watch(
          playbackStateProvider.select(
            (state) => state.value?.repeatMode ?? AudioServiceRepeatMode.none,
          ),
        );
        selected = repeatMode != AudioServiceRepeatMode.none;
        icon = repeatMode == AudioServiceRepeatMode.one
            ? CupertinoIcons.repeat_1
            : CupertinoIcons.repeat;
        tooltip = switch (repeatMode) {
          AudioServiceRepeatMode.one => l10n.nowPlayingRepeatOne,
          AudioServiceRepeatMode.none => l10n.nowPlayingRepeatOff,
          _ => l10n.nowPlayingRepeatAll,
        };
        onPressed = () => controller.setRepeatMode(switch (repeatMode) {
          AudioServiceRepeatMode.none => AudioServiceRepeatMode.all,
          AudioServiceRepeatMode.all => AudioServiceRepeatMode.one,
          _ => AudioServiceRepeatMode.none,
        });
    }
    return Semantics(
      toggled: selected,
      child: AppIconButton(
        key: ValueKey('desktop-player-${mode.name}'),
        tooltip: tooltip,
        iconSize: 15,
        isSelected: selected,
        color: selected ? colorScheme.primary : colorScheme.onSurfaceVariant,
        // A fill marks the active mode by more than its color.
        style: selected
            ? IconButton.styleFrom(
                backgroundColor: MornyeTheme.controlFill(context),
              )
            : null,
        icon: AppIcon(icon),
        onPressed: enabled ? onPressed : null,
      ),
    );
  }
}

/// Artwork, title and artist for the Material bar. The whole group opens
/// Now Playing, like tapping the mobile mini player.
class _TrackSummary extends StatelessWidget {
  const _TrackSummary({required this.mediaItem});

  final MediaItem? mediaItem;

  @override
  Widget build(BuildContext context) {
    final item = mediaItem;
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final content = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _Artwork(mediaItem: item, size: 56, radius: 12),
        const SizedBox(width: 12),
        Flexible(
          child: item == null
              ? Text(
                  context.l10n.desktopPlayerIdle,
                  style: textTheme.titleSmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                )
              : _TitleAndArtist(mediaItem: item),
        ),
        const SizedBox(width: 8),
      ],
    );
    if (item == null) return content;
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: _toggleNowPlaying,
      child: Padding(padding: const EdgeInsets.all(4), child: content),
    );
  }
}

class _TitleAndArtist extends StatelessWidget {
  const _TitleAndArtist({required this.mediaItem});

  final MediaItem mediaItem;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final colorScheme = Theme.of(context).colorScheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ExplicitTrackTitle(
          title: mediaItem.title,
          explicit: parseExplicitFlag(mediaItem.extras?['explicit']) == true,
          style: textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        Text(
          mediaItem.artist ?? '',
          style: textTheme.bodySmall?.copyWith(
            color: colorScheme.onSurfaceVariant,
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ],
    );
  }
}

class _Artwork extends StatelessWidget {
  const _Artwork({
    required this.mediaItem,
    required this.size,
    required this.radius,
  });

  final MediaItem? mediaItem;
  final double size;
  final double radius;

  @override
  Widget build(BuildContext context) {
    // Now Playing opens in the content pane rather than as a route, so the
    // artwork has no route transition to fly in.
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: SizedBox.square(
        dimension: size,
        child: PlayerArtwork(
          artUri: mediaItem?.artUri?.toString(),
          colorScheme: Theme.of(context).colorScheme,
          cacheWidth: (size * 2).round(),
          iconSize: size * 0.4,
        ),
      ),
    );
  }
}

/// Previous, play/pause and next. Material keeps the mini player's filled
/// play button, round while paused and square while playing.
class _Transport extends ConsumerWidget {
  const _Transport({required this.enabled});

  final bool enabled;

  // Media controls keep their order in right-to-left layouts.
  @override
  Widget build(BuildContext context, WidgetRef ref) => Directionality(
    textDirection: TextDirection.ltr,
    child: _buildControls(context, ref),
  );

  Widget _buildControls(BuildContext context, WidgetRef ref) {
    final controller = ref.read(musicPlayerControllerProvider);
    final isPlaying = ref.watch(playbackPlayingProvider);
    final isLoading = ref.watch(playbackLoadingProvider);
    final colorScheme = Theme.of(context).colorScheme;
    final l10n = context.l10n;
    final playTooltip = desktopTooltip(
      context,
      isPlaying ? l10n.actionPause : l10n.tooltipPlay,
      DesktopCommand.playPause,
    );
    final previousTooltip = desktopTooltip(
      context,
      l10n.nowPlayingPreviousTrack,
      DesktopCommand.previous,
    );
    final nextTooltip = desktopTooltip(
      context,
      l10n.nowPlayingNextTrack,
      DesktopCommand.next,
    );
    final onPlayPause = enabled && !isLoading
        ? () => controller.togglePlayPause(isPlaying)
        : null;

    if (context.isMornye) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          MornyePlaybackButton(
            icon: CupertinoIcons.backward_fill,
            tooltip: previousTooltip,
            color: colorScheme.onSurface,
            iconSize: 18,
            padding: const EdgeInsets.all(7),
            onPressed: enabled ? controller.previous : null,
          ),
          MornyePlaybackButton(
            icon: isPlaying
                ? CupertinoIcons.pause_fill
                : CupertinoIcons.play_fill,
            tooltip: playTooltip,
            color: colorScheme.onSurface,
            iconSize: 22,
            padding: const EdgeInsets.all(5),
            loading: isLoading,
            onPressed: onPlayPause,
          ),
          MornyePlaybackButton(
            icon: CupertinoIcons.forward_fill,
            tooltip: nextTooltip,
            color: colorScheme.onSurface,
            iconSize: 18,
            padding: const EdgeInsets.all(7),
            onPressed: enabled ? controller.next : null,
          ),
        ],
      );
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        AppIconButton(
          tooltip: previousTooltip,
          icon: const AppIcon(Icons.skip_previous),
          onPressed: enabled ? controller.previous : null,
        ),
        const SizedBox(width: 8),
        AppIconButton.filled(
          tooltip: playTooltip,
          isSelected: isPlaying,
          style: IconButton.styleFrom(
            backgroundColor: colorScheme.primary,
            foregroundColor: colorScheme.onPrimary,
          ),
          icon: isLoading
              ? AppLoadingIndicator(size: 20, color: colorScheme.onPrimary)
              : const AppIcon(Icons.play_arrow),
          selectedIcon: isLoading
              ? AppLoadingIndicator(size: 20, color: colorScheme.onPrimary)
              : const AppIcon(Icons.pause),
          onPressed: onPlayPause,
        ),
        const SizedBox(width: 8),
        AppIconButton(
          tooltip: nextTooltip,
          icon: const AppIcon(Icons.skip_next),
          onPressed: enabled ? controller.next : null,
        ),
      ],
    );
  }
}

/// Elapsed time, seek track and duration. Watches the playback position on
/// its own so the rest of the bar does not rebuild every tick.
class _SeekRow extends ConsumerWidget {
  const _SeekRow({required this.mediaItem, this.dense = false});

  final MediaItem? mediaItem;

  /// The Mornye LCD's thin bar with a small thumb.
  final bool dense;

  // Time runs left to right in right-to-left layouts too.
  @override
  Widget build(BuildContext context, WidgetRef ref) => Directionality(
    textDirection: TextDirection.ltr,
    child: _buildRow(context, ref),
  );

  Widget _buildRow(BuildContext context, WidgetRef ref) {
    final item = mediaItem;
    final colorScheme = Theme.of(context).colorScheme;
    final mornye = context.isMornye;
    final duration = item?.duration ?? Duration.zero;
    final position = item == null
        ? Duration.zero
        : ref.watch(playbackPositionProvider);
    final playing =
        ref.watch(playbackPlayingProvider) &&
        !ref.watch(playbackLoadingProvider);
    final timeStyle = Theme.of(context).textTheme.labelSmall?.copyWith(
      color: colorScheme.onSurfaceVariant,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    final elapsed = position.inSeconds.clamp(0, duration.inSeconds);
    final slider = SliderTheme(
      data: SliderTheme.of(context).copyWith(
        trackHeight: dense ? 3 : 4,
        activeTrackColor: mornye
            ? colorScheme.onSurface.withValues(alpha: 0.6)
            : colorScheme.primary,
        inactiveTrackColor: mornye
            ? colorScheme.onSurface.withValues(alpha: 0.12)
            : colorScheme.secondaryContainer,
        thumbColor: dense ? colorScheme.onSurface : colorScheme.primary,
        thumbShape: RoundSliderThumbShape(enabledThumbRadius: dense ? 4 : 6),
        overlayShape: RoundSliderOverlayShape(overlayRadius: dense ? 8 : 12),
      ),
      child: PlaybackSeekSlider(
        key: ValueKey(item?.id),
        position: position,
        duration: duration,
        playing: playing,
        hairline: dense,
        onSeek: ref.read(musicPlayerControllerProvider).seek,
      ),
    );
    // The LCD has room for the bar alone; Now Playing shows the times.
    if (dense) return slider;
    return Row(
      children: [
        Text(formatClock(elapsed), style: timeStyle),
        const SizedBox(width: 8),
        Expanded(child: slider),
        const SizedBox(width: 8),
        Text(
          mornye
              ? '-${formatClock(duration.inSeconds - elapsed)}'
              : formatClock(duration.inSeconds),
          style: timeStyle,
        ),
      ],
    );
  }
}

/// The Mornye center display: artwork, then the title and artist centered
/// over a thin progress bar. Clicking the artwork or text opens Now
/// Playing. With nothing loaded it shows a music glyph, like Music's idle
/// display.
class _MornyeLcd extends StatelessWidget {
  const _MornyeLcd({required this.mediaItem});

  static const double _artworkSize = 32;

  final MediaItem? mediaItem;

  @override
  Widget build(BuildContext context) {
    final item = mediaItem;
    final colorScheme = Theme.of(context).colorScheme;
    if (item == null) {
      return Semantics(
        label: context.l10n.desktopPlayerIdle,
        excludeSemantics: true,
        child: Center(
          child: AppIcon(
            CupertinoIcons.music_note,
            size: 22,
            color: colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }
    // As in Music: artwork and left-aligned lines, with a hairline progress
    // track along the bottom from the artwork's edge.
    return Column(
      children: [
        Expanded(
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _toggleNowPlaying,
              child: Row(
                children: [
                  _Artwork(
                    mediaItem: item,
                    size: _artworkSize,
                    radius: context.tokens.radiusThumb - 4,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    // Larger text sizes shrink the lines to the capsule
                    // rather than clip them.
                    child: LayoutBuilder(
                      builder: (context, constraints) => FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: AlignmentDirectional.centerStart,
                        child: SizedBox(
                          width: constraints.maxWidth,
                          child: _MornyeLcdLines(mediaItem: item),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        SizedBox(
          height: 6,
          child: OverflowBox(
            maxHeight: 10,
            child: _SeekRow(mediaItem: item, dense: true),
          ),
        ),
      ],
    );
  }
}

/// The LCD's title and "artist · album" line, left-aligned like Music's.
class _MornyeLcdLines extends StatelessWidget {
  const _MornyeLcdLines({required this.mediaItem});

  final MediaItem mediaItem;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final colorScheme = Theme.of(context).colorScheme;
    final subtitle = [
      mediaItem.artist,
      mediaItem.album,
    ].where((part) => part != null && part.trim().isNotEmpty).join(' · ');
    final style = textTheme.bodyMedium?.copyWith(fontSize: 13, height: 1.25);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ExplicitTrackTitle(
          title: mediaItem.title,
          explicit: parseExplicitFlag(mediaItem.extras?['explicit']) == true,
          style: style?.copyWith(fontWeight: FontWeight.w600),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        if (subtitle.isNotEmpty)
          Text(
            subtitle,
            style: style?.copyWith(color: colorScheme.onSurfaceVariant),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
      ],
    );
  }
}

/// Lyrics and Up Next, which toggle the trailing inspector, downloads, and
/// volume. Material fills its third of the bar, with phones and downloads
/// after Up Next and the volume slider last. The Mornye capsule leads with
/// phones and downloads and ends with a volume button whose slider opens in
/// a popover, as Music does. The phones button shows only while a phone is
/// connected over Mornye Link.
class _TrailingControls extends StatelessWidget {
  const _TrailingControls({required this.enabled, this.appTheme});

  /// Narrowest room in which the Material bar keeps its volume slider.
  static const double _materialVolumeMinWidth = 140;

  final bool enabled;

  /// The Material bar's app theme, for the downloads button and popover.
  final ThemeData? appTheme;

  @override
  Widget build(BuildContext context) {
    final mornye = context.isMornye;
    final colorScheme = Theme.of(context).colorScheme;
    final l10n = context.l10n;
    return Row(
      mainAxisAlignment: MainAxisAlignment.end,
      mainAxisSize: mornye ? MainAxisSize.min : MainAxisSize.max,
      children: [
        if (mornye) ...[
          const DesktopLinkDevicesButton(),
          const DesktopDownloadsButton(),
        ],
        ValueListenableBuilder<DesktopInspectorPanel?>(
          valueListenable: desktopInspectorPanel,
          builder: (context, panel, _) => Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _InspectorToggle(
                key: const ValueKey('desktop-player-lyrics'),
                panel: DesktopInspectorPanel.lyrics,
                selected: panel == DesktopInspectorPanel.lyrics,
                enabled: enabled,
                tooltip: desktopTooltip(
                  context,
                  l10n.nowPlayingTabLyrics,
                  DesktopCommand.lyrics,
                ),
                icon: mornye
                    ? CupertinoIcons.quote_bubble
                    : Icons.lyrics_outlined,
              ),
              _InspectorToggle(
                key: const ValueKey('desktop-player-up-next'),
                panel: DesktopInspectorPanel.upNext,
                selected: panel == DesktopInspectorPanel.upNext,
                enabled: enabled,
                tooltip: desktopTooltip(
                  context,
                  l10n.nowPlayingUpNext,
                  DesktopCommand.upNext,
                ),
                icon: mornye ? CupertinoIcons.list_bullet : Icons.queue_music,
              ),
            ],
          ),
        ),
        if (desktopMiniPlayerSupported)
          AppIconButton(
            key: const ValueKey('desktop-player-mini'),
            tooltip: desktopTooltip(
              context,
              l10n.desktopMenuMiniPlayer,
              DesktopCommand.miniPlayer,
            ),
            color: mornye ? colorScheme.onSurface : null,
            icon: AppIcon(
              mornye
                  ? CupertinoIcons.rectangle_on_rectangle
                  : Icons.picture_in_picture_alt_outlined,
            ),
            onPressed: toggleDesktopMiniPlayer,
          ),
        if (mornye)
          const _MornyeVolumeButton()
        else ...[
          Theme(
            data: appTheme ?? Theme.of(context),
            child: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [DesktopLinkDevicesButton(), DesktopDownloadsButton()],
            ),
          ),
          // A narrow window leaves too little room for a usable slider;
          // the volume shortcuts still work there.
          Flexible(
            child: LayoutBuilder(
              builder: (context, constraints) =>
                  constraints.maxWidth < _materialVolumeMinWidth
                  ? const SizedBox.shrink()
                  : ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 220),
                      child: PlayerVolumeControl(
                        foreground: colorScheme.onSurface,
                      ),
                    ),
            ),
          ),
        ],
      ],
    );
  }
}

/// The Mornye capsule's volume button. Its glyph follows the level, and a
/// click opens the slider in a popover above the capsule.
class _MornyeVolumeButton extends ConsumerStatefulWidget {
  const _MornyeVolumeButton();

  @override
  ConsumerState<_MornyeVolumeButton> createState() =>
      _MornyeVolumeButtonState();
}

class _MornyeVolumeButtonState extends ConsumerState<_MornyeVolumeButton> {
  final _menu = MenuController();

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final volume = ref.watch(systemVolumeProvider).value;
    final icon = switch (volume) {
      null => CupertinoIcons.speaker_2_fill,
      <= 0 => CupertinoIcons.speaker_slash_fill,
      < 0.34 => CupertinoIcons.speaker_1_fill,
      < 0.67 => CupertinoIcons.speaker_2_fill,
      _ => CupertinoIcons.speaker_3_fill,
    };
    return MenuAnchor(
      controller: _menu,
      consumeOutsideTap: true,
      alignmentOffset: const Offset(-96, 8),
      style: MenuStyle(
        padding: const WidgetStatePropertyAll(EdgeInsets.zero),
        backgroundColor: WidgetStatePropertyAll(
          colorScheme.surfaceContainerHigh,
        ),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        ),
      ),
      menuChildren: [
        SizedBox(
          key: const ValueKey('desktop-player-volume-popover'),
          width: 240,
          height: 48,
          child: PlayerVolumeControl(foreground: colorScheme.onSurface),
        ),
      ],
      child: DesktopVolumeScroll(
        child: AppIconButton(
          key: const ValueKey('desktop-player-volume'),
          tooltip: context.l10n.nowPlayingVolume,
          color: colorScheme.onSurface,
          icon: AppIcon(icon),
          onPressed: () => _menu.isOpen ? _menu.close() : _menu.open(),
        ),
      ),
    );
  }
}

/// A toggle for one inspector panel. Mornye marks the open panel with a
/// fill as well as the accent color, so the state differs by more than
/// color; Material uses the selected standard icon button.
class _InspectorToggle extends StatelessWidget {
  const _InspectorToggle({
    super.key,
    required this.panel,
    required this.selected,
    required this.enabled,
    required this.tooltip,
    required this.icon,
  });

  final DesktopInspectorPanel panel;
  final bool selected;
  final bool enabled;
  final String tooltip;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final mornye = context.isMornye;
    final colorScheme = Theme.of(context).colorScheme;
    return AppIconButton(
      tooltip: tooltip,
      isSelected: selected,
      color: mornye
          ? (selected ? colorScheme.primary : colorScheme.onSurface)
          : null,
      style: mornye && selected
          ? IconButton.styleFrom(
              backgroundColor: MornyeTheme.controlFill(context),
            )
          : null,
      icon: AppIcon(icon),
      // An open panel can always close, even after playback stops.
      onPressed: enabled || selected
          ? () => toggleDesktopInspector(panel)
          : null,
    );
  }
}
