import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/unified_library_item.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:mornye/widgets/link/link_actions.dart';
import 'package:mornye/widgets/playlist_picker_sheet.dart';
import 'package:mornye/widgets/selection_action_button.dart';

/// Collection actions stay separate from actions that modify audio files.
class LibrarySelectionPlaybackActions extends ConsumerWidget {
  const LibrarySelectionPlaybackActions({
    super.key,
    required this.items,
    required this.onClose,
  });

  final List<UnifiedLibraryItem> items;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = Theme.of(context).colorScheme;
    final showPlayer = ref.watch(playerUiEnabledProvider);
    final actions = <Widget>[
      SelectionActionButton(
        icon: Icons.playlist_add,
        label: context.l10n.collectionAddToPlaylist,
        colorScheme: colors,
        onPressed: items.isEmpty
            ? null
            : () {
                final tracks = items.map((item) => item.toTrack()).toList();
                final navigatorContext = Navigator.of(
                  context,
                  rootNavigator: true,
                ).context;
                onClose();
                showAddTracksToPlaylistSheet(navigatorContext, ref, tracks);
              },
      ),
      for (final next in showPlayer ? [true, false] : const <bool>[])
        SelectionActionButton(
          icon: next ? Icons.playlist_play : Icons.queue_music,
          label: next
              ? context.l10n.trackPlayNext
              : context.l10n.trackAddToQueue,
          colorScheme: colors,
          onPressed: items.isEmpty
              ? null
              : () async {
                  final controller = ref.read(musicPlayerControllerProvider);
                  await controller.enqueueLibraryItems(items, playNext: next);
                  if (context.mounted) onClose();
                },
        ),
      // Copying songs to or from the paired computer (Mornye Link).
      ...linkTransferSelectionActions(context, ref, items, onClose: onClose),
    ];
    return LayoutBuilder(
      builder: (context, constraints) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final action in actions)
              if (isDesktopPlatform)
                action
              else
                SizedBox(width: (constraints.maxWidth - 8) / 2, child: action),
          ],
        ),
      ),
    );
  }
}
