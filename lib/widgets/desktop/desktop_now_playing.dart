import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:audio_service/audio_service.dart';
import 'package:flutter/cupertino.dart' show CupertinoButton, CupertinoIcons;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/controllers/player_metadata_controller.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/providers/lyrics_translation_provider.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/theme/app_motion.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/theme/player_artwork_theme.dart';
import 'package:mornye/utils/playback_seek_preview.dart';
import 'package:mornye/widgets/app_icon.dart';
import 'package:mornye/widgets/desktop/desktop_inspector.dart';
import 'package:mornye/widgets/desktop/desktop_window.dart';
import 'package:mornye/widgets/lyrics_options_button.dart';
import 'package:mornye/widgets/material_player_backdrop.dart';
import 'package:mornye/widgets/mornye_player_background.dart';
import 'package:mornye/widgets/mornye_player_favorite_button.dart';
import 'package:mornye/widgets/mornye_player_queue.dart';
import 'package:mornye/widgets/no_scrollbars.dart';
import 'package:mornye/widgets/player_artwork.dart';
import 'package:mornye/widgets/player_lyrics_section.dart';
import 'package:mornye/widgets/player_metadata_title.dart';
import 'package:mornye/widgets/playback_source_label.dart';
import 'package:mornye/widgets/player_playback_controls.dart';
import 'package:mornye/widgets/player_volume_control.dart';

/// Now Playing on the desktop, covering the whole window as Music's player
/// does: the cover, title and transport on the leading side, lyrics or Up
/// Next ([desktopInspectorPanel]) on the trailing side, the volume at the
/// top and the panel toggles at the bottom. With no panel the cover column
/// stands alone in the middle. Close or Escape return to the shell
/// ([desktopNowPlayingOpen]).
class DesktopNowPlaying extends ConsumerStatefulWidget {
  const DesktopNowPlaying({super.key, this.metadataControllerFactory});

  final PlayerMetadataController Function()? metadataControllerFactory;

  @override
  ConsumerState<DesktopNowPlaying> createState() => _DesktopNowPlayingState();
}

class _DesktopNowPlayingState extends ConsumerState<DesktopNowPlaying> {
  late final _metadata =
      widget.metadataControllerFactory?.call() ?? PlayerMetadataController();
  final _seekPreview = PlaybackSeekPreview();
  ProviderSubscription<AsyncValue<MediaItem?>>? _mediaItemSub;
  late final LyricsTranslationController _lyricsTranslation;

  /// The panel on the trailing side, kept while it animates closed.
  DesktopInspectorPanel? _lastPanel;

  @override
  void initState() {
    super.initState();
    _lyricsTranslation = ref.read(lyricsTranslationProvider.notifier);
    _mediaItemSub = ref.listenManual<AsyncValue<MediaItem?>>(
      currentMediaItemProvider,
      (previous, next) {
        if (previous?.value?.id != next.value?.id) _seekPreview.reset();
        if (previous?.value?.id == next.value?.id && previous != null) return;
        unawaited(
          _metadata.load(next.value, inspectUnresolvedContentUri: true),
        );
      },
      fireImmediately: true,
    );
  }

  @override
  void dispose() {
    _mediaItemSub?.close();
    _lyricsTranslation.cancel(owner: this);
    _metadata.dispose();
    _seekPreview.dispose();
    super.dispose();
  }

  /// Centers the top buttons on the traffic lights' row.
  static const double _controlsTop = (desktopTitleBarHeight - 36) / 2;

  @override
  Widget build(BuildContext context) {
    final mediaItem = ref.watch(currentMediaItemProvider).value;
    if (context.isMornye) return _buildPlayer(context, mediaItem);
    // Material takes the track's artwork scheme. Providers are read above,
    // so the scoped builder reads none.
    return PlayerArtworkTheme(
      artUri: mediaItem?.artUri?.toString(),
      child: Builder(builder: (context) => _buildPlayer(context, mediaItem)),
    );
  }

  Widget _buildPlayer(BuildContext context, MediaItem? mediaItem) {
    final mornye = context.isMornye;
    final theme = mornye
        ? MornyeTheme.fromContext(context, brightness: Brightness.dark)
        : Theme.of(context);
    final colorScheme = theme.colorScheme;
    return Theme(
      data: theme,
      child: Material(
        type: MaterialType.transparency,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (mornye)
              MornyePlayerBackground(artUri: mediaItem?.artUri)
            else if (mediaItem != null)
              MaterialPlayerBackdrop(
                mediaItem: mediaItem,
                colorScheme: colorScheme,
                showArtwork: false,
              )
            else
              ColoredBox(color: colorScheme.surface),
            ValueListenableBuilder<DesktopInspectorPanel?>(
              valueListenable: desktopInspectorPanel,
              builder: (context, panel, _) => mediaItem == null
                  ? Center(
                      child: Text(
                        context.l10n.nowPlayingNothingPlaying,
                        style: theme.textTheme.titleMedium?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                    )
                  : _layout(context, mediaItem, colorScheme, panel),
            ),
            // The player covers the title bar row, so it drags the window.
            const Positioned(
              top: 0,
              left: 0,
              right: 0,
              height: desktopTitleBarHeight,
              child: DesktopWindowDragArea(zoomOnDoubleClick: true),
            ),
            // The close button follows the traffic lights, which hide in
            // full screen.
            ValueListenableBuilder<bool>(
              valueListenable: desktopWindowFullScreen,
              builder: (context, fullScreen, button) => PositionedDirectional(
                top: _controlsTop,
                start: desktopTitleBarInContentFor(context) && !fullScreen
                    ? desktopWindowControlsWidth + 12
                    : 20,
                child: button!,
              ),
              child: _RoundButton(
                key: const ValueKey('desktop-now-playing-close'),
                tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
                icon: mornye ? CupertinoIcons.xmark : Icons.close,
                onPressed: closeDesktopNowPlaying,
              ),
            ),
            PositionedDirectional(
              top: _controlsTop,
              end: 20,
              width: 260,
              child: _Capsule(
                child: PlayerVolumeControl(
                  foreground: mornye ? Colors.white : colorScheme.onSurface,
                ),
              ),
            ),
            PositionedDirectional(
              bottom: 20,
              end: 20,
              child: ValueListenableBuilder<DesktopInspectorPanel?>(
                valueListenable: desktopInspectorPanel,
                builder: (context, panel, _) => _Capsule(
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _RoundButton(
                        tooltip: context.l10n.nowPlayingTabLyrics,
                        icon: mornye
                            ? CupertinoIcons.quote_bubble
                            : Icons.lyrics_outlined,
                        selected: panel == DesktopInspectorPanel.lyrics,
                        onPressed: () => toggleDesktopInspector(
                          DesktopInspectorPanel.lyrics,
                        ),
                      ),
                      const SizedBox(width: 4),
                      _RoundButton(
                        tooltip: context.l10n.nowPlayingUpNext,
                        icon: mornye
                            ? CupertinoIcons.list_bullet
                            : Icons.queue_music,
                        selected: panel == DesktopInspectorPanel.upNext,
                        onPressed: () => toggleDesktopInspector(
                          DesktopInspectorPanel.upNext,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _layout(
    BuildContext context,
    MediaItem mediaItem,
    ColorScheme colorScheme,
    DesktopInspectorPanel? panel,
  ) {
    if (panel != null) _lastPanel = panel;
    final reduce = MediaQuery.disableAnimationsOf(context);
    // Opening follows the panel motion; closing eases out without
    // overshoot.
    final motion = panel != null
        ? desktopInspectorMotion(context)
        : const AppMotionSpec(Duration(milliseconds: 260), Curves.easeInCubic);
    return LayoutBuilder(
      builder: (context, constraints) => TweenAnimationBuilder<double>(
        tween: Tween(end: panel != null ? 1 : 0),
        duration: reduce ? Duration.zero : motion.duration,
        curve: motion.curve,
        onEnd: () {
          if (panel == null && mounted) setState(() => _lastPanel = null);
        },
        builder: (context, progress, _) =>
            _sideLayout(context, constraints, mediaItem, colorScheme, progress),
      ),
    );
  }

  /// The cover column moves from the middle to the leading 5/11 of the
  /// window as [progress] goes from 0 to 1, while the last panel fades in
  /// on the trailing 6/11.
  Widget _sideLayout(
    BuildContext context,
    BoxConstraints constraints,
    MediaItem mediaItem,
    ColorScheme colorScheme,
    double progress,
  ) {
    final width = constraints.maxWidth;
    final size = progress.clamp(0.0, 1.0);
    // The cover column leaves room for the title and transport below.
    double columnWidthFor(double limit) =>
        math.max(240.0, math.min(limit, constraints.maxHeight - 340));
    final columnWidth = lerpDouble(
      columnWidthFor(520),
      columnWidthFor(math.min(440.0, width * 0.34)),
      size,
    )!;
    final leading = width * 5 / 11;
    final centerX = lerpDouble(width / 2, leading / 2, progress)!;
    final rtl = Directionality.of(context) == TextDirection.rtl;
    // Whole device pixels, so the fading lyrics never land between pixels
    // and shimmer as they slide.
    final pixelRatio = MediaQuery.devicePixelRatioOf(context);
    final slide = ((1 - size) * 48 * pixelRatio).roundToDouble() / pixelRatio;
    final player = SizedBox(
      width: columnWidth,
      child: _PlayerColumn(
        mediaItem: mediaItem,
        metadata: _metadata,
        seekPreview: _seekPreview,
        colorScheme: colorScheme,
        artworkSize: columnWidth,
        // The cover decodes once at its largest size rather than on every
        // frame of the resize.
        decodeSize: columnWidthFor(520),
      ),
    );
    final panel = _lastPanel;
    final showsLyrics = panel == DesktopInspectorPanel.lyrics;
    // Panels cross-fade only when one replaces another; a panel that opens
    // shows at once and fades with the panel side.
    final switchDuration = MediaQuery.disableAnimationsOf(context) || size < 0.5
        ? Duration.zero
        : const Duration(milliseconds: 180);
    return Stack(
      children: [
        Positioned.directional(
          textDirection: Directionality.of(context),
          start: centerX - columnWidth / 2,
          top: 0,
          bottom: 0,
          width: columnWidth,
          child: Center(child: player),
        ),
        PositionedDirectional(
          start: leading,
          end: 0,
          top: 0,
          bottom: 0,
          // A leaving panel stops taking clicks once it is mostly gone.
          child: IgnorePointer(
            ignoring: size < 0.5,
            child: ExcludeFocus(
              excluding: size == 0,
              child: Opacity(
                opacity: size,
                child: Transform.translate(
                  offset: Offset(slide * (rtl ? -1 : 1), 0),
                  child: Padding(
                    padding: const EdgeInsetsDirectional.fromSTEB(
                      0,
                      72,
                      48,
                      80,
                    ),
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        // Hidden lyrics follow line positions so they reopen
                        // centered, without running word animations off screen.
                        IgnorePointer(
                          key: const ValueKey('desktop-now-playing-lyrics'),
                          ignoring: !showsLyrics,
                          child: ExcludeFocus(
                            excluding: !showsLyrics,
                            child: AnimatedOpacity(
                              opacity: showsLyrics ? 1 : 0,
                              duration: switchDuration,
                              child: NoScrollbars(
                                child: PlayerLyricsSection(
                                  metadata: _metadata,
                                  seekPreview: _seekPreview,
                                  colorScheme: colorScheme,
                                  isActive: true,
                                  animateWords: showsLyrics,
                                  options: LyricsOptionsButton(
                                    metadata: _metadata,
                                    colorScheme: colorScheme,
                                    translationOwner: this,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                        AnimatedSwitcher(
                          duration: switchDuration,
                          child: panel == DesktopInspectorPanel.upNext
                              ? KeyedSubtree(
                                  key: const ValueKey(
                                    'desktop-now-playing-upNext',
                                  ),
                                  child: NoScrollbars(
                                    child: context.isMornye
                                        ? MornyePlayerQueue(
                                            colorScheme: colorScheme,
                                          )
                                        : DesktopMaterialQueue(
                                            colorScheme: colorScheme,
                                          ),
                                  ),
                                )
                              : const SizedBox.shrink(),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _PlayerColumn extends StatelessWidget {
  const _PlayerColumn({
    required this.mediaItem,
    required this.metadata,
    required this.seekPreview,
    required this.colorScheme,
    required this.artworkSize,
    required this.decodeSize,
  });

  final MediaItem mediaItem;
  final PlayerMetadataController metadata;
  final PlaybackSeekPreview seekPreview;
  final ColorScheme colorScheme;
  final double artworkSize;

  /// The width the cover is decoded at, at least [artworkSize].
  final double decodeSize;

  @override
  Widget build(BuildContext context) {
    final mornye = context.isMornye;
    final textTheme = Theme.of(context).textTheme;
    final corners = BorderRadius.circular(mornye ? 12 : 28);
    final artwork = PlayerArtwork(
      artUri: mediaItem.artUri?.toString(),
      colorScheme: colorScheme,
      iconSize: 96,
      cacheWidth: (decodeSize * MediaQuery.devicePixelRatioOf(context)).round(),
    );
    final subtitle = [
      mediaItem.artist,
      mediaItem.album,
    ].whereType<String>().where((part) => part.trim().isNotEmpty).join(' · ');
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox.square(
          dimension: artworkSize,
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: corners,
              boxShadow: const [
                BoxShadow(
                  color: Color(0x40000000),
                  blurRadius: 28,
                  offset: Offset(0, 16),
                ),
              ],
            ),
            child: mornye
                ? ClipRSuperellipse(borderRadius: corners, child: artwork)
                : ClipRRect(borderRadius: corners, child: artwork),
          ),
        ),
        const SizedBox(height: 28),
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  PlayerMetadataTitle(
                    mediaItem: mediaItem,
                    metadata: metadata,
                    style:
                        (mornye ? textTheme.titleMedium : textTheme.titleLarge)
                            ?.copyWith(
                              fontWeight: FontWeight.w600,
                              color: colorScheme.onSurface,
                            ),
                    maxLines: 1,
                  ),
                  if (subtitle.isNotEmpty)
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style:
                          (mornye ? textTheme.bodyMedium : textTheme.titleSmall)
                              ?.copyWith(color: colorScheme.onSurfaceVariant),
                    ),
                  PlaybackSourceLabel(
                    item: mediaItem,
                    color: colorScheme.onSurfaceVariant,
                  ),
                ],
              ),
            ),
            if (mornye)
              MornyePlayerFavoriteButton(
                mediaItem: mediaItem,
                color: colorScheme.onSurface,
                iconSize: 20,
              ),
          ],
        ),
        PlayerPlaybackControls(
          key: ValueKey(mediaItem.id),
          mediaId: mediaItem.id,
          duration: mediaItem.duration ?? Duration.zero,
          seekPreview: seekPreview,
          colorScheme: colorScheme,
          metadata: metadata,
          compact: true,
          edgeAligned: true,
        ),
      ],
    );
  }
}

class _Capsule extends StatelessWidget {
  const _Capsule({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final fill = context.isMornye
        ? Colors.white.withValues(alpha: 0.12)
        : scheme.surfaceContainerHigh.withValues(alpha: 0.72);
    return DecoratedBox(
      decoration: ShapeDecoration(color: fill, shape: const StadiumBorder()),
      child: Padding(padding: const EdgeInsets.all(4), child: child),
    );
  }
}

/// A round icon button over the artwork backdrop; [selected] fills it.
class _RoundButton extends StatelessWidget {
  const _RoundButton({
    super.key,
    required this.tooltip,
    required this.icon,
    required this.onPressed,
    this.selected = false,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback onPressed;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (context.isMornye) {
      return Tooltip(
        message: tooltip,
        child: Semantics(
          button: true,
          selected: selected,
          child: CupertinoButton(
            minimumSize: const Size.square(36),
            padding: EdgeInsets.zero,
            borderRadius: BorderRadius.circular(18),
            color: selected
                ? Colors.white.withValues(alpha: 0.9)
                : Colors.white.withValues(alpha: 0.12),
            onPressed: onPressed,
            child: AppIcon(
              icon,
              size: 18,
              color: selected ? Colors.black : Colors.white,
            ),
          ),
        ),
      );
    }
    return IconButton(
      tooltip: tooltip,
      isSelected: selected,
      style: IconButton.styleFrom(
        backgroundColor: selected
            ? scheme.secondaryContainer
            : scheme.surfaceContainerHighest,
        foregroundColor: selected
            ? scheme.onSecondaryContainer
            : scheme.onSurfaceVariant,
      ),
      icon: AppIcon(icon),
      onPressed: onPressed,
    );
  }
}
