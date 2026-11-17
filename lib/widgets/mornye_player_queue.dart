import 'package:audio_service/audio_service.dart';
import 'package:cupertino_ui/cupertino_ui.dart' show CupertinoIcons;
import 'package:material_ui/material_ui.dart';
import 'package:flutter/rendering.dart' show RenderSliverMultiBoxAdaptor;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:mornye/widgets/player_queue_artwork.dart';
import 'package:mornye/widgets/player_queue_dismissible.dart';
import 'package:mornye/widgets/queue_swipe.dart';

/// Upcoming tracks share the player's artwork backdrop and transport controls.
class MornyePlayerQueue extends ConsumerStatefulWidget {
  const MornyePlayerQueue({super.key, required this.colorScheme});

  final ColorScheme colorScheme;

  @override
  ConsumerState<MornyePlayerQueue> createState() => _MornyePlayerQueueState();
}

class _MornyePlayerQueueState extends ConsumerState<MornyePlayerQueue> {
  static const _placeId = ValueKey('mornye-player-queue-rows');
  final _listKey = GlobalKey();

  /// On the frame that opens the list where it was left, the rows above
  /// that place are empty boxes [_passedRowHeight] tall: a list without
  /// fixed row heights builds every row it passes, and none of these reach
  /// the screen.
  int _passedRows = 0;
  double _passedRowHeight = 0;

  @override
  void initState() {
    super.initState();
    final place = PageStorage.maybeOf(
      context,
    )?.readState(context, identifier: _placeId);
    if (place case (
      rows: final int rows,
      height: final double height,
    ) when rows > 0 && height > 0) {
      _passedRows = rows;
      _passedRowHeight = height;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() => _passedRows = 0);
      });
    }
  }

  /// Keeps, next to the scroll offset the list restores by itself, the first
  /// row the list holds there and a row's height.
  bool _rememberPlace(ScrollEndNotification notification) {
    if (notification.depth == 0) {
      // The list lays out for where the scroll ended at the end of the frame.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _savePlace();
      });
    }
    return false;
  }

  void _savePlace() {
    final list = _listKey.currentContext?.findRenderObject();
    ({int rows, double height})? place;
    if (list is RenderSliverMultiBoxAdaptor) {
      final first = list.firstChild;
      if (first != null) {
        place = (rows: list.indexOf(first), height: first.size.height);
      }
    }
    PageStorage.maybeOf(
      context,
    )?.writeState(context, place, identifier: _placeId);
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = widget.colorScheme;
    final queue = ref.watch(playQueueProvider).value ?? const <MediaItem>[];
    final playback = ref.watch(
      playbackStateProvider.select(
        (state) => (
          shuffle: state.value?.shuffleMode == AudioServiceShuffleMode.all,
          repeat: state.value?.repeatMode ?? AudioServiceRepeatMode.none,
        ),
      ),
    );
    final start = ref.watch(currentQueueIndexProvider) + 1;
    final count = queue.length - start;
    final controller = ref.read(musicPlayerControllerProvider);
    final autoMix = ref.watch(settingsProvider.select((s) => s.autoMix));
    final autoplay = ref.watch(settingsProvider.select((s) => s.autoplay));
    // Locked: no reordering or swiping songs away here; adding still works.
    final locked = ref.watch(settingsProvider.select((s) => s.queueLocked));
    final swipeToPlayNext = queueEntrySwipeEnabled(ref);
    final type = Theme.of(context).textTheme;
    final repeatLabel = switch (playback.repeat) {
      AudioServiceRepeatMode.one => context.l10n.nowPlayingRepeatOne,
      AudioServiceRepeatMode.none => context.l10n.nowPlayingRepeatOff,
      _ => context.l10n.nowPlayingRepeatAll,
    };

    Widget modeButton({
      required IconData icon,
      required String label,
      required bool selected,
      required VoidCallback onPressed,
    }) => Expanded(
      child: Semantics(
        selected: selected,
        child: Tooltip(
          message: label,
          child: FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Colors.white.withValues(
                alpha: selected ? 0.3 : 0.12,
              ),
              foregroundColor: Colors.white,
              minimumSize: const Size(0, 44),
              padding: const EdgeInsets.symmetric(horizontal: 8),
              shape: const StadiumBorder(),
            ),
            onPressed: onPressed,
            child: Icon(icon, semanticLabel: label, size: 24),
          ),
        ),
      ),
    );

    // Desktop shuffle and repeat live in the player capsule, so the
    // panel keeps only the two wide queue modes, drawn as their icons.
    Widget desktopModeButton({
      required IconData icon,
      required String label,
      required String stateLabel,
      required bool selected,
      required VoidCallback onPressed,
    }) => Expanded(
      child: Semantics(
        selected: selected,
        label: stateLabel,
        excludeSemantics: true,
        button: true,
        child: FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: Colors.white.withValues(
              alpha: selected ? 0.82 : 0.12,
            ),
            foregroundColor: selected ? Colors.black : Colors.white,
            minimumSize: const Size(0, 36),
            padding: const EdgeInsets.symmetric(horizontal: 12),
            shape: const StadiumBorder(),
            textStyle: Theme.of(context).textTheme.bodyMedium,
          ),
          onPressed: onPressed,
          child: Icon(icon, semanticLabel: label, size: 20),
        ),
      ),
    );

    final list = CustomScrollView(
      key: const PageStorageKey('mornye-player-queue'),
      slivers: [
        SliverPadding(
          padding: EdgeInsets.symmetric(
            horizontal: isDesktopPlatform ? 16 : 28,
          ),
          sliver: SliverToBoxAdapter(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (isDesktopPlatform)
                  Row(
                    children: [
                      desktopModeButton(
                        icon: CupertinoIcons.infinite,
                        label: context.l10n.queueAutoplay,
                        stateLabel: autoplay
                            ? context.l10n.autoplayOn
                            : context.l10n.autoplayOff,
                        selected: autoplay,
                        onPressed: () => ref
                            .read(settingsProvider.notifier)
                            .setAutoplay(!autoplay),
                      ),
                      const SizedBox(width: 12),
                      desktopModeButton(
                        icon: CupertinoIcons.arrow_merge,
                        label: context.l10n.queueAutoMix,
                        stateLabel: autoMix
                            ? context.l10n.autoMixOn
                            : context.l10n.autoMixOff,
                        selected: autoMix,
                        onPressed: () => ref
                            .read(settingsProvider.notifier)
                            .setAutoMix(!autoMix),
                      ),
                    ],
                  )
                else
                  Row(
                    children: [
                      modeButton(
                        icon: CupertinoIcons.arrow_merge,
                        label: autoMix
                            ? context.l10n.autoMixOn
                            : context.l10n.autoMixOff,
                        selected: autoMix,
                        onPressed: () => ref
                            .read(settingsProvider.notifier)
                            .setAutoMix(!autoMix),
                      ),
                      const SizedBox(width: 12),
                      modeButton(
                        icon: CupertinoIcons.shuffle,
                        label: playback.shuffle
                            ? context.l10n.nowPlayingShuffleOn
                            : context.l10n.nowPlayingPlayInOrder,
                        selected: playback.shuffle,
                        onPressed: () =>
                            controller.setShuffle(!playback.shuffle),
                      ),
                      const SizedBox(width: 12),
                      modeButton(
                        icon: playback.repeat == AudioServiceRepeatMode.one
                            ? CupertinoIcons.repeat_1
                            : CupertinoIcons.repeat,
                        label: repeatLabel,
                        selected:
                            playback.repeat != AudioServiceRepeatMode.none,
                        onPressed: () =>
                            controller.setRepeatMode(switch (playback.repeat) {
                              AudioServiceRepeatMode.none =>
                                AudioServiceRepeatMode.all,
                              AudioServiceRepeatMode.all =>
                                AudioServiceRepeatMode.one,
                              _ => AudioServiceRepeatMode.none,
                            }),
                      ),
                      const SizedBox(width: 12),
                      modeButton(
                        icon: CupertinoIcons.infinite,
                        label: autoplay
                            ? context.l10n.autoplayOn
                            : context.l10n.autoplayOff,
                        selected: autoplay,
                        onPressed: () => ref
                            .read(settingsProvider.notifier)
                            .setAutoplay(!autoplay),
                      ),
                    ],
                  ),
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              context.l10n.mornyeContinuePlaying,
                              style: type.titleLarge?.copyWith(
                                color: Colors.white,
                              ),
                            ),
                            if (autoplay &&
                                playback.repeat == AudioServiceRepeatMode.none)
                              Text(
                                context.l10n.autoplayFromLibrary,
                                style: type.bodySmall?.copyWith(
                                  color: Colors.white70,
                                ),
                              ),
                          ],
                        ),
                      ),
                      // A toggle: a fill marks it on, as on the mode buttons.
                      Semantics(
                        toggled: locked,
                        child: IconButton(
                          tooltip: locked
                              ? context.l10n.queueUnlock
                              : context.l10n.queueLock,
                          isSelected: locked,
                          style: IconButton.styleFrom(
                            minimumSize: const Size.square(44),
                            foregroundColor: Colors.white,
                            backgroundColor: Colors.white.withValues(
                              alpha: locked ? 0.3 : 0,
                            ),
                          ),
                          icon: Icon(
                            locked
                                ? CupertinoIcons.lock_fill
                                : CupertinoIcons.lock_open,
                            size: 20,
                          ),
                          onPressed: () => ref
                              .read(settingsProvider.notifier)
                              .setQueueLocked(!locked),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        if (count == 0)
          SliverPadding(
            padding: const EdgeInsets.all(28),
            sliver: SliverToBoxAdapter(
              child: Text(
                context.l10n.nowPlayingQueueEmpty,
                style: type.bodyMedium?.copyWith(color: Colors.white70),
              ),
            ),
          )
        else
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            sliver: SliverReorderableList(
              key: _listKey,
              itemCount: count,
              onReorderItem: (oldIndex, newIndex) {
                if (!locked) {
                  controller.moveQueueItem(start + oldIndex, start + newIndex);
                }
              },
              proxyDecorator: (child, index, animation) => Material(
                color: colorScheme.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(12),
                child: child,
              ),
              itemBuilder: (context, index) {
                final item = queue[start + index];
                if (index < _passedRows) {
                  return SizedBox(
                    key: ObjectKey(item),
                    height: _passedRowHeight,
                  );
                }
                return PlayerQueueDismissible(
                  key: ObjectKey(item),
                  enabled: !locked,
                  onRemove: () => controller.removeQueuedItem(item),
                  playNext: swipeToPlayNext
                      ? queueEntrySwipe(controller, item)
                      : null,
                  child: ListTile(
                    contentPadding: const EdgeInsetsDirectional.only(start: 12),
                    minVerticalPadding: 6,
                    leading: ClipRRect(
                      borderRadius: BorderRadius.circular(5),
                      child: SizedBox.square(
                        dimension: 40,
                        child: PlayerQueueArtwork(
                          item: item,
                          colorScheme: colorScheme,
                          cacheWidth: 120,
                          iconSize: 22,
                        ),
                      ),
                    ),
                    title: Text(
                      item.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: type.bodyLarge?.copyWith(color: Colors.white),
                    ),
                    subtitle: Text(
                      item.artist ?? '',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: type.bodySmall?.copyWith(color: Colors.white70),
                    ),
                    trailing: locked
                        ? null
                        : ReorderableDragStartListener(
                            index: index,
                            child: const ColoredBox(
                              color: Colors.transparent,
                              child: SizedBox.square(
                                dimension: 44,
                                child: Icon(
                                  CupertinoIcons.line_horizontal_3,
                                  color: Colors.white38,
                                ),
                              ),
                            ),
                          ),
                    onTap: () => controller.jumpTo(start + index),
                  ),
                );
              },
            ),
          ),
      ],
    );
    return NotificationListener<ScrollEndNotification>(
      onNotification: _rememberPlace,
      child: list,
    );
  }
}
