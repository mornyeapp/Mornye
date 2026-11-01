import 'package:flutter/material.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/widgets/app_action_button.dart';

/// Full-width delete action for selection-mode bottom bars: destructive
/// (error) styling once at least one item is selected, disabled/neutral
/// otherwise.
class DestructiveSelectionButton extends StatelessWidget {
  const DestructiveSelectionButton({
    super.key,
    required this.count,
    required this.colorScheme,
    required this.onPressed,
    this.label,
  });

  final int count;
  final ColorScheme colorScheme;
  final VoidCallback onPressed;

  /// Replaces the downloaded album delete label.
  final String? label;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: AppActionButton(
        isDestructive: true,
        onPressed: count > 0 ? onPressed : null,
        icon: const Icon(Icons.delete_outline),
        label: Text(
          label ??
              (count > 0
                  ? context.l10n.downloadedAlbumDeleteCount(count)
                  : context.l10n.downloadedAlbumSelectToDelete),
        ),
        style: FilledButton.styleFrom(
          backgroundColor: count > 0
              ? colorScheme.error
              : colorScheme.surfaceContainerHighest,
          foregroundColor: count > 0
              ? colorScheme.onError
              : colorScheme.onSurfaceVariant,
          padding: const EdgeInsets.symmetric(vertical: 16),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
        ),
      ),
    );
  }
}
