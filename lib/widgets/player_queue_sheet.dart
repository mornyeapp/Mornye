import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/theme/app_motion.dart';
import 'package:mornye/theme/material_expressive.dart';
import 'package:mornye/widgets/app_bottom_sheet.dart';
import 'package:mornye/widgets/app_icon.dart';
import 'package:mornye/widgets/expressive_button.dart';
import 'package:mornye/widgets/player_playback_controls.dart';
import 'package:mornye/widgets/player_queue_artwork.dart';
import 'package:mornye/widgets/player_queue_dismissible.dart';

Future<void> showPlayerQueueSheet(
  BuildContext context,
  ColorScheme colorScheme,
) => showAppModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  backgroundColor: colorScheme.surfaceContainerHigh,
  builder: (context) => DraggableScrollableSheet(
    expand: false,
    initialChildSize: 0.6,
    maxChildSize: 0.9,
    minChildSize: 0.4,
    builder: (context, scrollController) => PlayerQueueSheet(
      colorScheme: colorScheme,
      scrollController: scrollController,
    ),
  ),
);

class PlayerQueueSheet extends ConsumerWidget {
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

  static const _rowRadius = 16.0;
  static final _liftSpring = SpringCurve(M3EMotion.expressiveSpatialFast);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final queue = ref.watch(playQueueProvider).value ?? const [];
    final current = ref.watch(currentMediaItemProvider).value;
    final controller = ref.read(musicPlayerControllerProvider);
    final textTheme = Theme.of(context).textTheme;
    final expressive = materialExpressiveEnabled(context);
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
              scrollController: scrollController,
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 24),
              itemCount: queue.length,
              onReorderItem: (oldIndex, newIndex) {
                controller.moveQueueItem(oldIndex, newIndex);
              },
              proxyDecorator: (child, index, animation) {
                if (!expressive) {
                  return Material(
                    elevation: 4,
                    color: colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(12),
                    child: child,
                  );
                }
                return AnimatedBuilder(
                  animation: animation,
                  child: child,
                  builder: (context, child) {
                    final t = _liftSpring.transform(animation.value);
                    return Transform.scale(
                      scale: 1 + 0.03 * t,
                      child: Material(
                        elevation: 6 * t.clamp(0.0, 1.0),
                        color: colorScheme.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(_rowRadius + 8 * t),
                        clipBehavior: Clip.antiAlias,
                        child: child,
                      ),
                    );
                  },
                );
              },
              itemBuilder: (context, i) {
                final item = queue[i];
                final isCurrent = current?.id == item.id;
                return PlayerQueueDismissible(
                  key: ObjectKey(item),
                  enabled: !isCurrent,
                  onRemove: () => controller.removeQueuedItem(item),
                  child: ListTile(
                    selected: isCurrent,
                    selectedTileColor: colorScheme.secondaryContainer
                        .withValues(alpha: 0.55),
                    shape: expressive
                        ? RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(_rowRadius),
                          )
                        : null,
                    contentPadding: const EdgeInsetsDirectional.only(
                      start: 16,
                      end: 4,
                    ),
                    leading: TweenAnimationBuilder<double>(
                      tween: Tween(end: expressive && isCurrent ? 22 : 8),
                      duration: artworkMotion.duration,
                      curve: artworkMotion.curve,
                      builder: (context, radius, child) => ClipRRect(
                        borderRadius: BorderRadius.circular(
                          radius.clamp(0.0, 22.0),
                        ),
                        child: child,
                      ),
                      child: SizedBox.square(
                        dimension: 44,
                        child: PlayerQueueArtwork(
                          item: item,
                          colorScheme: colorScheme,
                          cacheWidth: 132,
                          iconSize: 22,
                        ),
                      ),
                    ),
                    title: Text(
                      item.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: textTheme.bodyLarge?.copyWith(
                        fontWeight: isCurrent
                            ? FontWeight.bold
                            : FontWeight.normal,
                        color: isCurrent
                            ? colorScheme.primary
                            : colorScheme.onSurface,
                      ),
                    ),
                    subtitle: Text(
                      item.artist ?? '',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: textTheme.bodySmall?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                    trailing: ReorderableDragStartListener(
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
      if (context.mounted && !embedded) Navigator.of(context).maybePop();
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
