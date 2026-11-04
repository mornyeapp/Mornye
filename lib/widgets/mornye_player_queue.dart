import 'package:audio_service/audio_service.dart';
import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:mornye/widgets/player_queue_artwork.dart';
import 'package:mornye/widgets/player_queue_dismissible.dart';

/// Upcoming tracks share the player's artwork backdrop and transport controls.
class MornyePlayerQueue extends ConsumerWidget {
  const MornyePlayerQueue({super.key, required this.colorScheme});

  final ColorScheme colorScheme;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
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

    return CustomScrollView(
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
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        context.l10n.mornyeContinuePlaying,
                        style: type.titleLarge?.copyWith(color: Colors.white),
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
              itemCount: count,
              onReorderItem: (oldIndex, newIndex) =>
                  controller.moveQueueItem(start + oldIndex, start + newIndex),
              proxyDecorator: (child, index, animation) => Material(
                color: colorScheme.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(12),
                child: child,
              ),
              itemBuilder: (context, index) {
                final item = queue[start + index];
                return PlayerQueueDismissible(
                  key: ObjectKey(item),
                  onRemove: () => controller.removeQueuedItem(item),
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
                    trailing: ReorderableDragStartListener(
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
  }
}
