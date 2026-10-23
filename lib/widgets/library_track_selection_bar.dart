import 'package:flutter/material.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:mornye/widgets/destructive_selection_button.dart';
import 'package:mornye/widgets/selection_action_button.dart';
import 'package:mornye/widgets/selection_bottom_bar.dart';

/// Shared Library toolbar for playlist/queue actions and audio file operations.
/// FLAC upgrade applies only to eligible local selections.
class LibraryTrackSelectionBar extends StatelessWidget {
  const LibraryTrackSelectionBar({
    super.key,
    required this.selectedCount,
    required this.allSelected,
    required this.onClose,
    required this.onToggleSelectAll,
    required this.bottomPadding,
    required this.onReEnrich,
    required this.onConvert,
    required this.onReplayGain,
    required this.onDelete,
    this.flacEligibleCount = 0,
    this.onQueueFlac,
    this.playbackActions,
    this.albumDelete = false,
  });

  final int selectedCount;
  final bool allSelected;
  final VoidCallback onClose;
  final VoidCallback onToggleSelectAll;
  final double bottomPadding;
  final VoidCallback onReEnrich;
  final VoidCallback onConvert;
  final void Function({required bool remove}) onReplayGain;
  final VoidCallback onDelete;

  /// FLAC upgrade is offered when this is positive and [onQueueFlac] is set.
  final int flacEligibleCount;
  final VoidCallback? onQueueFlac;
  final Widget? playbackActions;

  /// Album pages keep delete the full-width button on desktop too, with the
  /// downloaded album labels.
  final bool albumDelete;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final inlineDelete = isDesktopPlatform && !albumDelete;
    final hasSelection = selectedCount > 0;
    final deleteLabel = hasSelection
        ? context.l10n.selectionDeleteTracksCount(selectedCount)
        : context.l10n.selectionSelectToDelete;
    Widget replayGain({required bool remove}) => SelectionActionButton(
      icon: remove ? Icons.remove_circle_outline : Icons.graphic_eq,
      label: remove
          ? context.l10n.selectionRemoveReplayGainCount(selectedCount)
          : context.l10n.selectionReplayGainCount(selectedCount),
      onPressed: hasSelection ? () => onReplayGain(remove: remove) : null,
      colorScheme: colorScheme,
    );
    return SelectionBottomBar(
      selectedCount: selectedCount,
      allSelected: allSelected,
      onClose: onClose,
      onToggleSelectAll: onToggleSelectAll,
      bottomPadding: bottomPadding,
      children: [
        ?playbackActions,
        if (playbackActions != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(context.l10n.trackEditMetadata),
          ),
        SelectionActionGrid(
          children: [
            if (onQueueFlac != null && flacEligibleCount > 0)
              SelectionActionButton(
                icon: Icons.download_for_offline_outlined,
                label: '${context.l10n.queueFlacAction} ($flacEligibleCount)',
                onPressed: onQueueFlac,
                colorScheme: colorScheme,
              ),
            SelectionActionButton(
              icon: Icons.auto_fix_high_outlined,
              label: '${context.l10n.trackReEnrich} ($selectedCount)',
              onPressed: hasSelection ? onReEnrich : null,
              colorScheme: colorScheme,
            ),
            SelectionActionButton(
              icon: Icons.swap_horiz,
              label: context.l10n.selectionConvertCount(selectedCount),
              onPressed: hasSelection ? onConvert : null,
              colorScheme: colorScheme,
            ),
            replayGain(remove: false),
            // Desktop keeps delete a toolbar button. It shares a row with
            // the other removal, delete first, so neither wraps onto a row
            // of its own.
            if (inlineDelete)
              Row(
                mainAxisSize: MainAxisSize.min,
                spacing: 8,
                children: [
                  SelectionActionButton(
                    icon: Icons.delete_outline,
                    label: deleteLabel,
                    onPressed: hasSelection ? onDelete : null,
                    colorScheme: colorScheme,
                    destructive: true,
                  ),
                  replayGain(remove: true),
                ],
              )
            else
              replayGain(remove: true),
          ],
        ),
        if (!inlineDelete) ...[
          const SizedBox(height: 8),
          DestructiveSelectionButton(
            count: selectedCount,
            colorScheme: colorScheme,
            onPressed: onDelete,
            label: albumDelete ? null : deleteLabel,
          ),
        ],
      ],
    );
  }
}
