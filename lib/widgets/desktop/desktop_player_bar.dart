import 'dart:async';
import 'dart:math' as math;

import 'package:audio_service/audio_service.dart';
import 'package:cupertino_ui/cupertino_ui.dart' show CupertinoIcons;
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/controllers/player_metadata_controller.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/providers/song_lyrics_offset_provider.dart';
import 'package:mornye/theme/app_tokens.dart';
import 'package:mornye/theme/material_expressive.dart';
import 'package:mornye/theme/app_motion.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/theme/player_artwork_theme.dart';
import 'package:mornye/services/cast_output.dart';
import 'package:mornye/services/link/desktop/link_desktop_host.dart';
import 'package:mornye/utils/lyrics_parser.dart';
import 'package:mornye/utils/lyrics_timeline.dart';
import 'package:mornye/utils/string_utils.dart';
import 'package:mornye/utils/text_direction.dart';
import 'package:mornye/widgets/app_icon.dart';
import 'package:mornye/widgets/app_icon_button.dart';
import 'package:mornye/widgets/app_loading_indicator.dart';
import 'package:mornye/widgets/audio_quality_badges.dart';
import 'package:mornye/widgets/cast_device_picker.dart';
import 'package:mornye/widgets/desktop/desktop_commands.dart';
import 'package:mornye/widgets/desktop/desktop_cast_button.dart';
import 'package:mornye/widgets/desktop/desktop_downloads_button.dart';
import 'package:mornye/widgets/desktop/desktop_inspector.dart';
import 'package:mornye/widgets/desktop/desktop_link_devices_button.dart';
import 'package:mornye/widgets/desktop/desktop_row_ink.dart';
import 'package:mornye/widgets/desktop/desktop_window.dart';
import 'package:mornye/widgets/desktop/desktop_volume_scroll.dart';
import 'package:mornye/widgets/connected_icon_buttons.dart';
import 'package:mornye/widgets/expressive_playback_transport.dart';
import 'package:mornye/widgets/link/link_devices_sheet.dart';
import 'package:mornye/widgets/mornye_chrome.dart';
import 'package:mornye/widgets/mornye_playback_button.dart';
import 'package:mornye/widgets/mornye_player_background.dart';
import 'package:mornye/widgets/overflow_marquee.dart';
import 'package:mornye/widgets/player_artwork.dart';
import 'package:mornye/widgets/player_lyrics.dart';
import 'package:mornye/widgets/player_playback_controls.dart';
import 'package:mornye/widgets/player_track_crossfade.dart';
import 'package:mornye/widgets/player_volume_control.dart';
import 'package:mornye/widgets/playback_seek_slider.dart';

part 'desktop_mini_player.dart';

/// An explicit dismiss hides the idle bar. Any active track shows it again.
final desktopPlayerDismissed = ValueNotifier<bool>(false);

/// The desktop player. It replaces the mobile mini player: no
/// swipe gestures, with transport, seek, volume, lyrics, Up Next and
/// downloads in reach. Paused local playback offers a dismiss button.
/// Clicking the artwork or title shows Now
/// Playing in the content pane; lyrics and Up Next toggle the trailing
/// inspector.
///
/// Material docks an 80dp bar along the bottom of the window, on the
/// `surfaceContainer` fill of the current artwork's scheme
/// ([PlayerArtworkTheme]). Mornye draws a glass capsule that the shell
/// floats over the bottom of the content pane: shuffle and transport, a
/// center display with the track and its progress, then lyrics, Up Next,
/// downloads and volume.
class DesktopPlayerBar extends ConsumerWidget {
  const DesktopPlayerBar({super.key});

  static const double materialHeight = 80;

  /// Height of the Mornye capsule.
  static const double mornyeHeight = 56;

  /// Space between the Mornye capsule and the bottom of the window.
  static const double floatingMargin = 10;

  /// Bottom padding the content pane gives its pages, so their last rows
  /// scroll clear of the floating capsule with a margin above it.
  static const double floatingInset = mornyeHeight + floatingMargin + 12;

  /// Width of the Mornye capsule in a content pane [paneWidth] wide: about
  /// 70% of it, from 520 to 900 and never closer than 12 to
  /// the pane's sides.
  static double floatingWidth(double paneWidth) => math.min(
    (paneWidth * 0.7).clamp(520.0, 900.0),
    math.max(0.0, paneWidth - 24),
  );

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!ref.watch(playerUiEnabledProvider)) return const SizedBox.shrink();
    final mediaItem = ref.watch(currentMediaItemProvider).value;
    return context.isMornye
        ? _MornyePlayerBar(mediaItem: mediaItem)
        // The bar takes the track's artwork scheme; the downloads popover
        // it hosts keeps the app scheme. Only the fill fades: moving the
        // whole scheme rebuilt the bar on every frame of a song change.
        : PlayerArtworkTheme(
            artUri: mediaItem?.artUri?.toString(),
            fadesSurfaceOnly: true,
            background: _barFill,
            child: _MaterialPlayerBar(
              mediaItem: mediaItem,
              appTheme: Theme.of(context),
            ),
          );
  }
}

/// The fill of the bar and of the mini player, which fades on a song change
/// while the scheme swaps.
Color _barFill(ColorScheme scheme) => scheme.surfaceContainer;

/// Shows Now Playing in the content pane, or returns to the content when it
/// is already showing.
void _toggleNowPlaying() =>
    desktopNowPlayingOpen.value = !desktopNowPlayingOpen.value;

class _MaterialPlayerBar extends StatelessWidget {
  const _MaterialPlayerBar({required this.mediaItem, required this.appTheme});

  // Lyrics, queue, mini player, Link, downloads and dismiss each keep their
  // 48dp target. Reserve both sides equally so transport stays centered.
  static const double _sideControlsMinWidth = 6 * 48;

  final MediaItem? mediaItem;

  /// The theme outside the bar's artwork scope.
  final ThemeData appTheme;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final loaded = mediaItem != null;
    // Made outside the LayoutBuilder, so a resize frame only lays them out.
    final summary = _TrackSummary(mediaItem: mediaItem);
    final center = Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        _MaterialTransportRow(enabled: loaded),
        SizedBox(height: 24, child: _SeekRow(mediaItem: mediaItem)),
      ],
    );
    final trailing = _TrailingControls(enabled: loaded, appTheme: appTheme);
    return PlayerArtworkSurface(
      surface: colorScheme.surfaceContainer,
      child: Material(
        type: MaterialType.transparency,
        child: SafeArea(
          top: false,
          child: SizedBox(
            height: DesktopPlayerBar.materialHeight,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final sideWidth = math.max(
                    _sideControlsMinWidth,
                    (constraints.maxWidth - 32) * 0.3,
                  );
                  return Row(
                    children: [
                      SizedBox(
                        width: sideWidth,
                        child: Align(
                          alignment: AlignmentDirectional.centerStart,
                          child: summary,
                        ),
                      ),
                      const SizedBox(width: 16),
                      Expanded(child: center),
                      const SizedBox(width: 16),
                      SizedBox(width: sideWidth, child: trailing),
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Shuffle and repeat as M3E toggle buttons around the transport, which
/// fill and turn square while on. A narrow center keeps the transport alone.
class _MaterialTransportRow extends StatelessWidget {
  const _MaterialTransportRow({required this.enabled});

  static const double _transportWidth = 192;
  static const double _modeSize = 40;
  static const double _gap = 8;

  final bool enabled;

  @override
  Widget build(BuildContext context) {
    // Made outside the LayoutBuilder, so a resize frame only lays them out.
    final transport = _Transport(enabled: enabled);
    final colorScheme = Theme.of(context).colorScheme;
    Widget mode(PlayerPlaybackMode mode) => PlayerPlaybackModeButton(
      key: ValueKey('desktop-player-${mode.name}'),
      mode: mode,
      colorScheme: colorScheme,
      secondary: true,
      size: _modeSize,
      iconSize: 20,
      enabled: enabled,
    );
    final shuffle = mode(PlayerPlaybackMode.shuffle);
    final repeat = mode(PlayerPlaybackMode.repeat);
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < _transportWidth + 2 * (_modeSize + _gap)) {
          return transport;
        }
        return Directionality(
          textDirection: TextDirection.ltr,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              shuffle,
              const SizedBox(width: _gap),
              transport,
              const SizedBox(width: _gap),
              repeat,
            ],
          ),
        );
      },
    );
  }
}

/// The Mornye capsule: shuffle, transport and repeat, the center display,
/// then downloads, lyrics, Up Next and a volume button whose slider opens in
/// a popover. Its buttons take macOS
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
              iconSize: 19,
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
/// on, and dimmed while nothing is loaded.
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
    final press = desktopRowInk(context);
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: _toggleNowPlaying,
      splashFactory: press.splashFactory,
      highlightColor: press.highlightColor,
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
    return PlayerTrackCrossfade(
      trackKey: mediaItem.id,
      alignment: AlignmentDirectional.topStart,
      child: Column(
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
          // While the desktop follows a phone, the bar shows and drives it.
          LinkPlayingOnText(
            color: colorScheme.primary,
            style: textTheme.labelSmall,
            glyphSize: 14,
          ),
        ],
      ),
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
          crossfade: playerTrackChangeMotion(context),
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
            pointerPress: true,
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
            pointerPress: true,
            onPressed: onPlayPause,
          ),
          MornyePlaybackButton(
            icon: CupertinoIcons.forward_fill,
            tooltip: nextTooltip,
            color: colorScheme.onSurface,
            iconSize: 18,
            padding: const EdgeInsets.all(7),
            pointerPress: true,
            onPressed: enabled ? controller.next : null,
          ),
        ],
      );
    }
    if (materialExpressiveEnabled(context)) {
      return SizedBox(
        width: 192,
        child: ExpressivePlaybackTransport(
          colorScheme: colorScheme,
          playing: isPlaying,
          loading: isLoading,
          dense: true,
          playTooltip: playTooltip,
          previousTooltip: previousTooltip,
          nextTooltip: nextTooltip,
          onPlayPause: onPlayPause,
          onPrevious: enabled ? controller.previous : null,
          onNext: enabled ? controller.next : null,
        ),
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
  Widget build(BuildContext context, WidgetRef ref) => RepaintBoundary(
    child: Directionality(
      textDirection: TextDirection.ltr,
      child: _buildRow(context, ref),
    ),
  );

  Widget _buildRow(BuildContext context, WidgetRef ref) {
    final item = mediaItem;
    final colorScheme = Theme.of(context).colorScheme;
    final mornye = context.isMornye;
    final duration = item?.duration ?? Duration.zero;
    final visible = TickerMode.valuesOf(context).enabled;
    final position = item == null
        ? Duration.zero
        : (visible
              ? ref.watch(playbackPositionProvider)
              : ref.read(playbackPositionProvider));
    final playing =
        (visible
            ? ref.watch(playbackPlayingProvider)
            : ref.read(playbackPlayingProvider)) &&
        !(visible
            ? ref.watch(playbackLoadingProvider)
            : ref.read(playbackLoadingProvider));
    final timeStyle = Theme.of(context).textTheme.labelSmall?.copyWith(
      color: colorScheme.onSurfaceVariant,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    final elapsed = position.inSeconds.clamp(0, duration.inSeconds);
    final slider = SliderTheme(
      data: SliderTheme.of(context).copyWith(
        trackHeight: dense ? 3 : 4,
        activeTrackColor: mornye
            ? colorScheme.onSurface.withValues(alpha: 0.85)
            : colorScheme.primary,
        inactiveTrackColor: mornye
            ? colorScheme.onSurface.withValues(alpha: 0.16)
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

/// The Mornye center display: artwork, then the title and artist aligned
/// over a thin progress bar. Clicking the artwork or text opens Now
/// Playing. With nothing loaded it shows a music glyph.
class _MornyeLcd extends StatelessWidget {
  const _MornyeLcd({required this.mediaItem});

  static const double _artworkSize = 34;

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
    // Made outside the LayoutBuilder, so a resize frame only lays them out.
    final lines = _MornyeLcdLines(mediaItem: item);
    // Artwork and left-aligned lines, with a hairline progress
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
                  _MornyeLcdArtwork(
                    child: _Artwork(
                      mediaItem: item,
                      size: _artworkSize,
                      radius: 5,
                    ),
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
                          child: lines,
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

/// The LCD's artwork, which grows by a tenth under the pointer and shows
/// that a click opens Now Playing.
class _MornyeLcdArtwork extends StatefulWidget {
  const _MornyeLcdArtwork({required this.child});

  final Widget child;

  @override
  State<_MornyeLcdArtwork> createState() => _MornyeLcdArtworkState();
}

class _MornyeLcdArtworkState extends State<_MornyeLcdArtwork> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    // A hover: the fast spring for the lift, the fast effects spring for
    // the overlay.
    final lift = MornyeMotion.fast;
    final fade = reduceMotion
        ? const AppMotionSpec(Duration.zero, Curves.linear)
        : MornyeMotion.effectsFast;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: AnimatedScale(
        scale: _hovered && !reduceMotion ? 1.1 : 1,
        duration: reduceMotion ? Duration.zero : lift.duration,
        curve: lift.curve,
        child: Stack(
          alignment: Alignment.center,
          children: [
            widget.child,
            Positioned.fill(
              child: AnimatedOpacity(
                key: const ValueKey('desktop-player-artwork-overlay'),
                opacity: _hovered ? 1 : 0,
                duration: fade.duration,
                curve: fade.curve,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.45),
                    borderRadius: BorderRadius.circular(
                      context.tokens.radiusThumb - 4,
                    ),
                  ),
                  child: const Icon(
                    CupertinoIcons.arrow_up_left_arrow_down_right,
                    size: 14,
                    color: Colors.white,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The display's title and "artist · album" line, both left-aligned.
/// A line too long for the capsule scrolls twice, then rests at its start.
class _MornyeLcdLines extends ConsumerWidget {
  const _MornyeLcdLines({required this.mediaItem});

  final MediaItem mediaItem;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final textTheme = Theme.of(context).textTheme;
    final colorScheme = Theme.of(context).colorScheme;
    final subtitle = [
      mediaItem.artist,
      mediaItem.album,
    ].where((part) => part != null && part.trim().isNotEmpty).join(' · ');
    final playing = ref.watch(playbackPlayingProvider);
    final style = textTheme.bodyMedium?.copyWith(fontSize: 13, height: 1.25);
    return PlayerTrackCrossfade(
      trackKey: mediaItem.id,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          OverflowMarquee(
            resetKey: (mediaItem.id, mediaItem.title),
            playing: playing,
            maxCycles: 2,
            child: ExplicitTrackTitle(
              title: mediaItem.title,
              explicit:
                  parseExplicitFlag(mediaItem.extras?['explicit']) == true,
              style: style?.copyWith(
                color: colorScheme.onSurface,
                fontWeight: FontWeight.w600,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          // The capsule has two lines: while the desktop follows a phone,
          // the second names it instead.
          if (ref.watch(
            activeRemotePlaybackProvider.select((remote) => remote != null),
          ))
            LinkPlayingOnText(
              color: colorScheme.primary,
              style: style?.copyWith(fontWeight: FontWeight.w600),
              glyphSize: 12,
            )
          else if (subtitle.isNotEmpty)
            OverflowMarquee(
              resetKey: (mediaItem.id, subtitle),
              playing: playing,
              maxCycles: 2,
              child: Text(
                subtitle,
                // Keep the subtitle legible over the capsule's glass.
                style: style?.copyWith(
                  color: colorScheme.onSurface.withValues(alpha: 0.78),
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
        ],
      ),
    );
  }
}

/// Lyrics and Up Next, which toggle the trailing inspector, downloads, and
/// volume. Material fills its third of the bar, with phones and downloads
/// after Up Next and then the volume slider. The Mornye capsule leads with
/// phones and downloads and ends with a volume button whose slider opens in
/// a popover. The phones button shows only while a phone is
/// connected over Mornye Link. Paused local playback adds a dismiss button
/// at the end in both styles.
class _TrailingControls extends ConsumerWidget {
  const _TrailingControls({required this.enabled, this.appTheme});

  /// Narrowest room in which the Material bar keeps its volume slider.
  static const double _materialVolumeMinWidth = 140;

  /// Space between the Material bar's button groups.
  static const double _groupGap = 8;

  final bool enabled;

  /// The Material bar's app theme, for the downloads button and popover.
  final ThemeData? appTheme;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mornye = context.isMornye;
    final canDismiss =
        enabled &&
        !ref.watch(playbackPlayingProvider) &&
        !ref.watch(playbackLoadingProvider) &&
        ref.watch(activeRemotePlaybackProvider) == null;
    if (!mornye) return _buildMaterial(context, ref, canDismiss);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const DesktopLinkDevicesButton(),
        const DesktopDownloadsButton(),
        ValueListenableBuilder<DesktopInspectorPanel?>(
          valueListenable: desktopInspectorPanel,
          builder: (context, panel, _) => Row(
            mainAxisSize: MainAxisSize.min,
            children: _inspectorToggles(context, panel),
          ),
        ),
        if (desktopMiniPlayerSupported) _miniPlayerButton(context),
        const _MornyeVolumeButton(),
        if (canDismiss) _dismissButton(context, ref),
      ],
    );
  }

  /// Material joins the controls into one connected M3E button group, then
  /// the volume slider and dismiss on its own. A narrow window drops the
  /// slider first, then Cast; the volume shortcuts still work.
  Widget _buildMaterial(BuildContext context, WidgetRef ref, bool canDismiss) {
    final colorScheme = Theme.of(context).colorScheme;
    final appTheme = this.appTheme ?? Theme.of(context);
    final link = ref.watch(linkDevicesAvailableProvider);
    final buttons = 3 + (desktopMiniPlayerSupported ? 1 : 0) + (link ? 1 : 0);
    Widget group(bool cast) => ValueListenableBuilder<DesktopInspectorPanel?>(
      valueListenable: desktopInspectorPanel,
      builder: (context, panel, _) => ConnectedIconButtons(
        colorScheme: colorScheme,
        children: [
          ..._inspectorToggles(context, panel),
          if (desktopMiniPlayerSupported) _miniPlayerButton(context),
          // The menus and sheets these open keep the app scheme.
          if (link)
            Theme(data: appTheme, child: const DesktopLinkDevicesButton()),
          Theme(data: appTheme, child: const DesktopDownloadsButton()),
          if (cast) Theme(data: appTheme, child: const DesktopCastButton()),
        ],
      ),
    );
    // Kept across resize frames, which only build the row around them again.
    Widget? withCast;
    Widget? withoutCast;
    Widget? volume;
    final dismiss = canDismiss
        ? ConnectedIconButtons(
            colorScheme: colorScheme,
            children: [_dismissButton(context, ref)],
          )
        : null;
    return LayoutBuilder(
      builder: (context, constraints) {
        double width(int count) => ConnectedIconButtons.widthOf(context, count);
        final fixed = width(buttons) + (canDismiss ? _groupGap + width(1) : 0);
        final castCost = width(buttons + 1) - width(buttons);
        final cast = constraints.maxWidth - fixed >= castCost;
        final slider =
            constraints.maxWidth - fixed - (cast ? castCost : 0) >=
            _groupGap + _materialVolumeMinWidth;
        return Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            cast ? withCast ??= group(true) : withoutCast ??= group(false),
            if (slider) ...[
              const SizedBox(width: _groupGap),
              Flexible(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 220),
                  child: volume ??= PlayerVolumeControl(
                    foreground: colorScheme.onSurface,
                  ),
                ),
              ),
            ],
            if (dismiss != null) ...[const SizedBox(width: _groupGap), dismiss],
          ],
        );
      },
    );
  }

  List<Widget> _inspectorToggles(
    BuildContext context,
    DesktopInspectorPanel? panel,
  ) {
    final mornye = context.isMornye;
    final l10n = context.l10n;
    return [
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
        icon: mornye ? CupertinoIcons.quote_bubble : Icons.lyrics_outlined,
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
    ];
  }

  Widget _miniPlayerButton(BuildContext context) {
    final mornye = context.isMornye;
    return AppIconButton(
      key: const ValueKey('desktop-player-mini'),
      tooltip: desktopTooltip(
        context,
        context.l10n.desktopMenuMiniPlayer,
        DesktopCommand.miniPlayer,
      ),
      color: mornye ? Theme.of(context).colorScheme.onSurface : null,
      icon: AppIcon(
        mornye
            ? CupertinoIcons.rectangle_on_rectangle
            : Icons.picture_in_picture_alt_outlined,
      ),
      onPressed: toggleDesktopMiniPlayer,
    );
  }

  Widget _dismissButton(BuildContext context, WidgetRef ref) => AppIconButton(
    key: const ValueKey('desktop-player-dismiss'),
    tooltip: context.l10n.actionDismiss,
    color: context.isMornye ? Theme.of(context).colorScheme.onSurface : null,
    icon: const AppIcon.adaptive(Icons.close),
    onPressed: () async {
      await ref.read(musicPlayerControllerProvider).dismiss();
      desktopPlayerDismissed.value = true;
      desktopInspectorPanel.value = null;
      closeDesktopNowPlaying();
    },
  );
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
  final _cast = CastOutput.instance;

  @override
  void initState() {
    super.initState();
    _cast.addListener(_castChanged);
  }

  @override
  void dispose() {
    _cast.removeListener(_castChanged);
    super.dispose();
  }

  void _castChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final icon = ref.watch(
      systemVolumeProvider.select(
        (state) => switch (state.value) {
          null => CupertinoIcons.speaker_2_fill,
          <= 0 => CupertinoIcons.speaker_slash_fill,
          < 0.34 => CupertinoIcons.speaker_1_fill,
          < 0.67 => CupertinoIcons.speaker_2_fill,
          _ => CupertinoIcons.speaker_3_fill,
        },
      ),
    );
    final cast = _cast;
    return MenuAnchor(
      controller: _menu,
      consumeOutsideTap: true,
      // The directional default alignment already mirrors dx in RTL.
      alignmentOffset: const Offset(-96, 8),
      style: const MenuStyle(
        padding: WidgetStatePropertyAll(EdgeInsets.zero),
        // The glass panel below is the popover's surface, so it can fade in.
        backgroundColor: WidgetStatePropertyAll(Colors.transparent),
        surfaceTintColor: WidgetStatePropertyAll(Colors.transparent),
        shadowColor: WidgetStatePropertyAll(Colors.transparent),
        elevation: WidgetStatePropertyAll(0),
      ),
      menuChildren: [
        _MornyePopoverEntrance(
          child: MornyeGlassPanel.overlay(
            radius: 14,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  key: const ValueKey('desktop-player-volume-popover'),
                  width: 240,
                  height: 48,
                  child: PlayerVolumeControl(foreground: colorScheme.onSurface),
                ),
                // The capsule has no room for its own Cast button; output
                // sits with volume.
                SizedBox(
                  width: 240,
                  child: MenuItemButton(
                    key: const ValueKey('desktop-player-cast'),
                    leadingIcon: AppIcon.adaptive(
                      cast.connected ? Icons.cast_connected : Icons.cast,
                      size: 18,
                    ),
                    onPressed: () {
                      _menu.close();
                      showCastDevicePicker(context, output: cast);
                    },
                    child: Text(
                      cast.connected
                          ? cast.deviceName ?? context.l10n.audioOutputCast
                          : context.l10n.audioOutputCast,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
      child: DesktopVolumeScroll(
        child: AppIconButton(
          key: const ValueKey('desktop-player-volume'),
          tooltip: context.l10n.nowPlayingVolume,
          color: cast.connected ? colorScheme.primary : colorScheme.onSurface,
          icon: AppIcon.adaptive(cast.connected ? Icons.cast_connected : icon),
          onPressed: () => _menu.isOpen ? _menu.close() : _menu.open(),
        ),
      ),
    );
  }
}

/// The popover entrance: a subtle scale and rise on the effects spring without
/// an opacity layer that would isolate the glass backdrop during entrance.
class _MornyePopoverEntrance extends StatelessWidget {
  const _MornyePopoverEntrance({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: reduceMotion ? Duration.zero : MornyeMotion.effects.duration,
      curve: MornyeMotion.effects.curve,
      builder: (context, progress, child) => Transform.translate(
        offset: Offset(0, 6 * (1 - progress)),
        child: Transform.scale(
          scale: 0.96 + 0.04 * progress,
          alignment: Alignment.bottomCenter,
          child: child,
        ),
      ),
      child: child,
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
    // An open panel can always close, even after playback stops.
    final onPressed = enabled || selected
        ? () => toggleDesktopInspector(panel)
        : null;
    // In Material the button is a group segment that fills and rounds
    // fully while its panel is open.
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
      onPressed: onPressed,
    );
  }
}
