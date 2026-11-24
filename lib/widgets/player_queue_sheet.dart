import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/theme/app_motion.dart';
import 'package:mornye/theme/material_expressive.dart';
import 'package:mornye/widgets/app_bottom_sheet.dart';
import 'package:mornye/widgets/settings_group.dart';
import 'package:mornye/widgets/app_icon.dart';
import 'package:mornye/widgets/app_snack_bar.dart';
import 'package:mornye/widgets/expressive_button.dart';
import 'package:mornye/widgets/expressive_icon_button.dart';
import 'package:mornye/widgets/now_playing_indicator.dart';
import 'package:mornye/widgets/player_playback_controls.dart';
import 'package:mornye/widgets/player_queue_artwork.dart';
import 'package:mornye/widgets/player_queue_dismissible.dart';
import 'package:mornye/widgets/queue_save_playlist.dart';
import 'package:mornye/widgets/queue_swipe.dart';
import 'package:mornye/widgets/scaled_drag_proxy.dart';

Future<void> showPlayerQueueSheet(
  BuildContext context,
  ColorScheme colorScheme,
) => showAppModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  backgroundColor: colorScheme.surfaceContainerHigh,
  // A short queue gets a sheet as tall as its songs.
  builder: (context) => AppScrollableSheet(
    initialSize: 0.6,
    maxSize: 0.9,
    // The sheet's own messenger, so a swipe's confirmation shows over the
    // sheet instead of behind it.
    builder: (context, scrollController) => AppScaffoldMessenger(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        resizeToAvoidBottomInset: false,
        body: PlayerQueueSheet(
          colorScheme: colorScheme,
          scrollController: scrollController,
        ),
      ),
    ),
  ),
);

class PlayerQueueSheet extends ConsumerStatefulWidget {
  const PlayerQueueSheet({
    super.key,
    required this.colorScheme,
    required this.scrollController,
    this.embedded = false,
  });

  final ColorScheme colorScheme;
  final ScrollController scrollController;

  /// Shown in a panel that has its own title, such as the desktop
  /// inspector, rather than in a sheet: no title, and shuffling the library
  /// keeps the panel open.
  final bool embedded;

  @override
  ConsumerState<PlayerQueueSheet> createState() => _PlayerQueueSheetState();
}

class _PlayerQueueSheetState extends ConsumerState<PlayerQueueSheet> {
  static const _rowRadius = 16.0;

  /// The songs are one connected group: each row its own surface, this far
  /// from the next.
  static const _rowGap = 2.0;
  static final _liftSpring = SpringCurve(M3EMotion.expressiveSpatialFast);

  /// Measures the first row until the list has opened at the playing song.
  GlobalKey? _firstRowKey = GlobalKey();
  bool _openScheduled = false;

  /// While the list jumps to the playing song, the rows before this index
  /// are empty boxes [_passedRowHeight] tall: a list without fixed row
  /// heights builds every row it passes, and none of these reach the screen.
  int _passedRows = 0;
  double _passedRowHeight = 0;

  /// Opens the list at the playing song, with the song before it still in
  /// view, once and without motion, so a later song change never moves it.
  void _openAtPlayingSong() {
    if (_openScheduled) return;
    _openScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final tileHeight = _firstRowKey?.currentContext?.size?.height;
      final rowHeight = tileHeight == null ? null : tileHeight + _rowGap;
      final index = ref.read(currentQueueIndexProvider);
      final scroll = widget.scrollController;
      if (rowHeight != null && index > 1 && scroll.hasClients) {
        final position = scroll.position;
        final offset = ((index - 1) * rowHeight).clamp(
          0.0,
          position.maxScrollExtent,
        );
        if (offset > position.pixels) {
          // One row of margin above the first one the jump shows.
          _passedRows = (offset / rowHeight).floor() - 1;
          _passedRowHeight = rowHeight;
          scroll.jumpTo(offset);
          WidgetsBinding.instance.addPostFrameCallback((_) {
            _passedRows = 0;
            // Rows kept just above the viewport become real ones.
            if (mounted) setState(() {});
          });
        }
      }
      setState(() => _firstRowKey = null);
    });
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = widget.colorScheme;
    final embedded = widget.embedded;
    final queue = ref.watch(playQueueProvider).value ?? const [];
    final currentId = ref.watch(
      currentMediaItemProvider.select((s) => s.value?.id),
    );
    if (queue.isNotEmpty && currentId != null) _openAtPlayingSong();
    // A queue that got shorter leaves room its sheet gives back.
    ref.listen(playQueueProvider.select((state) => state.value?.length), (
      _,
      _,
    ) {
      if (!embedded) const SizeChangedLayoutNotification().dispatch(context);
    });
    final controller = ref.read(musicPlayerControllerProvider);
    // Locked: no reordering or swiping songs away here; adding still works.
    final locked = ref.watch(settingsProvider.select((s) => s.queueLocked));
    final swipeToPlayNext = queueEntrySwipeEnabled(ref);
    final textTheme = Theme.of(context).textTheme;
    final expressive = materialExpressiveEnabled(context);
    final rowColor = settingsGroupColor(context);
    final artworkMotion = AppMotion.spatial(
      context,
      const AppMotionSpec(Duration.zero, Curves.linear),
    );
    return Column(
      children: [
        Padding(
          padding: const EdgeInsetsDirectional.fromSTEB(24, 4, 16, 8),
          child: Row(
            children: [
              Expanded(
                child: embedded
                    ? const SizedBox.shrink()
                    : Text(
                        context.l10n.nowPlayingUpNext,
                        style: textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                          color: colorScheme.onSurface,
                        ),
                      ),
              ),
              ExpressiveIconButton(
                tooltip: context.l10n.queueSaveAsPlaylist,
                icon: const Icon(Icons.playlist_add),
                foregroundColor: colorScheme.onSurfaceVariant,
                onPressed: queue.isEmpty
                    ? null
                    : () => saveQueueAsPlaylist(context, ref),
              ),
              const SizedBox(width: 4),
              ExpressiveIconButton(
                selected: locked,
                tooltip: locked
                    ? context.l10n.queueUnlock
                    : context.l10n.queueLock,
                icon: Icon(locked ? Icons.lock : Icons.lock_open),
                foregroundColor: locked
                    ? colorScheme.onSecondaryContainer
                    : colorScheme.onSurfaceVariant,
                backgroundColor: locked ? colorScheme.secondaryContainer : null,
                onPressed: () =>
                    ref.read(settingsProvider.notifier).setQueueLocked(!locked),
              ),
              const SizedBox(width: 4),
              PlayerPlaybackModeButton(
                mode: PlayerPlaybackMode.autoplay,
                colorScheme: colorScheme,
                secondary: true,
              ),
              const SizedBox(width: 4),
              PlayerPlaybackModeButton(
                mode: PlayerPlaybackMode.repeat,
                colorScheme: colorScheme,
                secondary: true,
              ),
              const SizedBox(width: 4),
              PlayerPlaybackModeButton(
                mode: PlayerPlaybackMode.shuffle,
                colorScheme: colorScheme,
                secondary: true,
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
          child: SizedBox(
            width: double.infinity,
            child: ExpressiveButton(
              tonal: true,
              onPressed: () => _shuffleLibrary(context, controller),
              icon: const Icon(Icons.shuffle, size: 18),
              child: Text(context.l10n.nowPlayingShuffleLibrary),
            ),
          ),
        ),
        if (queue.isEmpty)
          Expanded(
            child: Center(
              child: Text(
                context.l10n.nowPlayingQueueEmpty,
                style: textTheme.bodyMedium?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          )
        else
          Expanded(
            child: ReorderableListView.builder(
              scrollController: widget.scrollController,
              // The last row's own gap is part of the 24 below the songs.
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 24 - _rowGap),
              itemCount: queue.length,
              buildDefaultDragHandles: !locked,
              onReorderItem: (oldIndex, newIndex) {
                if (!locked) controller.moveQueueItem(oldIndex, newIndex);
              },
              proxyDecorator: (child, index, animation) => ScaledDragProxy(
                animation: animation,
                child: !expressive
                    ? Material(
                        elevation: 4,
                        color: rowColor,
                        borderRadius: BorderRadius.circular(12),
                        child: child,
                      )
                    : AnimatedBuilder(
                        animation: animation,
                        child: child,
                        builder: (context, child) {
                          final t = _liftSpring.transform(animation.value);
                          return Transform.scale(
                            scale: 1 + 0.03 * t,
                            child: Material(
                              elevation: 6 * t.clamp(0.0, 1.0),
                              color: rowColor,
                              borderRadius: BorderRadius.circular(
                                _rowRadius + 8 * t,
                              ),
                              clipBehavior: Clip.antiAlias,
                              child: child,
                            ),
                          );
                        },
                      ),
              ),
              itemBuilder: (context, i) {
                final item = queue[i];
                if (i < _passedRows) {
                  return SizedBox(
                    key: ObjectKey(item),
                    height: _passedRowHeight,
                  );
                }
                final isCurrent = currentId == item.id;
                final radius = connectedRowRadius(
                  context,
                  first: i == 0,
                  last: i == queue.length - 1,
                );
                return Padding(
                  key: ObjectKey(item),
                  padding: const EdgeInsets.only(bottom: _rowGap),
                  child: PlayerQueueDismissible(
                    enabled: !isCurrent && !locked,
                    onRemove: () => controller.removeQueuedItem(item),
                    playNext: swipeToPlayNext
                        ? queueEntrySwipe(controller, item)
                        : null,
                    materialRadius: radius,
                    child: Material(
                      color: isCurrent
                          ? colorScheme.primaryContainer
                          : rowColor,
                      shape: RoundedRectangleBorder(borderRadius: radius),
                      clipBehavior: Clip.antiAlias,
                      child: ListTile(
                        key: i == 0 ? _firstRowKey : null,
                        selected: isCurrent,
                        contentPadding: const EdgeInsetsDirectional.only(
                          start: 16,
                          end: 4,
                        ),
                        leading: _LazyArtworkRadiusMorph(
                          active: expressive && isCurrent,
                          motion: artworkMotion,
                          restingRadius: 8,
                          activeRadius: 22,
                          child: SizedBox.square(
                            dimension: 44,
                            child: Stack(
                              fit: StackFit.expand,
                              children: [
                                PlayerQueueArtwork(
                                  item: item,
                                  colorScheme: colorScheme,
                                  cacheWidth: 132,
                                  iconSize: 22,
                                ),
                                if (isCurrent)
                                  ColoredBox(
                                    color: Colors.black.withValues(alpha: 0.45),
                                    child: Center(
                                      // Rows build after the sheet's build, so
                                      // the playing state is watched here.
                                      child: Consumer(
                                        builder: (context, ref, _) =>
                                            NowPlayingIndicator(
                                              color: Colors.white,
                                              playing: ref.watch(
                                                playbackPlayingProvider,
                                              ),
                                            ),
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ),
                        title: Text(
                          item.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: textTheme.bodyLarge?.copyWith(
                            fontWeight: isCurrent
                                ? FontWeight.w600
                                : FontWeight.normal,
                            color: isCurrent
                                ? colorScheme.onPrimaryContainer
                                : colorScheme.onSurface,
                          ),
                        ),
                        subtitle: Text(
                          item.artist ?? '',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: textTheme.bodySmall?.copyWith(
                            color: isCurrent
                                ? colorScheme.onPrimaryContainer
                                : colorScheme.onSurfaceVariant,
                          ),
                        ),
                        trailing: locked
                            ? null
                            : ReorderableDragStartListener(
                                index: i,
                                // 24dp glyph plus padding gives a 48dp drag target.
                                child: Padding(
                                  padding: const EdgeInsets.all(12),
                                  child: AppIcon(
                                    Icons.drag_handle,
                                    color: colorScheme.onSurfaceVariant,
                                  ),
                                ),
                              ),
                        onTap: () => controller.jumpTo(i),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
      ],
    );
  }

  Future<void> _shuffleLibrary(
    BuildContext context,
    MusicPlayerController controller,
  ) async {
    try {
      if (!await controller.shuffleLibrary()) {
        if (!context.mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(context.l10n.nowPlayingLibraryEmpty)),
        );
        return;
      }
      if (context.mounted && !widget.embedded) {
        Navigator.of(context).maybePop();
      }
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            context.l10n.nowPlayingShuffleLibraryFailed(
              context.friendlyError(e),
            ),
          ),
        ),
      );
    }
  }
}

/// Morphs a queue row's artwork corner radius lazily so non-current rows avoid
/// allocating an [AnimationController] or [Ticker].
class _LazyArtworkRadiusMorph extends StatefulWidget {
  const _LazyArtworkRadiusMorph({
    required this.active,
    required this.motion,
    required this.restingRadius,
    required this.activeRadius,
    required this.child,
  });

  final bool active;
  final AppMotionSpec motion;
  final double restingRadius;
  final double activeRadius;
  final Widget child;

  @override
  State<_LazyArtworkRadiusMorph> createState() =>
      _LazyArtworkRadiusMorphState();
}

// Each morph makes a new controller, so this provides more than one ticker.
class _LazyArtworkRadiusMorphState extends State<_LazyArtworkRadiusMorph>
    with TickerProviderStateMixin {
  AnimationController? _controller;
  late double _resting = widget.active ? 1.0 : 0.0;

  @override
  void didUpdateWidget(_LazyArtworkRadiusMorph oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.active == widget.active) return;
    final target = widget.active ? 1.0 : 0.0;
    if (widget.motion.duration == Duration.zero) {
      _disposeController();
      _resting = target;
      return;
    }
    final controller = _controller ??= AnimationController(
      vsync: this,
      value: _resting,
    )..addStatusListener(_onStatus);
    controller.animateTo(
      target,
      duration: widget.motion.duration,
      curve: widget.motion.curve,
    );
  }

  void _onStatus(AnimationStatus status) {
    if (status == AnimationStatus.dismissed && !widget.active) {
      _resting = 0.0;
      _disposeController();
      if (mounted) setState(() {});
    } else if (status == AnimationStatus.completed && widget.active) {
      _resting = 1.0;
      _disposeController();
      if (mounted) setState(() {});
    }
  }

  void _disposeController() {
    final controller = _controller;
    if (controller == null) return;
    _controller = null;
    controller
      ..removeStatusListener(_onStatus)
      ..dispose();
  }

  @override
  void dispose() {
    _disposeController();
    super.dispose();
  }

  Widget _clip(double progress) {
    final radius =
        widget.restingRadius +
        (widget.activeRadius - widget.restingRadius) * progress;
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius.clamp(0.0, 22.0)),
      child: widget.child,
    );
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    if (controller == null) return _clip(_resting);
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) => _clip(controller.value.clamp(0.0, 1.0)),
    );
  }
}
