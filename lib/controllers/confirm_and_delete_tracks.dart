import 'package:flutter/material.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/widgets/app_alert_dialog.dart';

String trackDeletionResultMessage(
  AppLocalizations l10n, {
  required int deleted,
  required int requested,
}) => [
  if (deleted > 0 || requested == 0) l10n.snackbarDeletedTracks(deleted),
  if (deleted < requested) l10n.snackbarDeleteTracksFailed(requested - deleted),
].join('\n');

/// Shows a delete-confirmation dialog, deletes the given [ids] one by one via
/// [deleteItem], then shows a "deleted N tracks" snackbar.
/// [onExitSelectionMode] runs after persistence if the screen is still open.
///
/// Returns the number of items [deleteItem] reported deleted, or null if the
/// user cancelled the dialog.
/// [persistDeletedItems] commits successfully deleted IDs once before the UI
/// reports completion, including partial success if a later deletion throws.
Future<int?> confirmAndDeleteTracks({
  required BuildContext context,
  required List<String> ids,
  required Future<bool> Function(String id) deleteItem,
  Future<void> Function(List<String> ids)? persistDeletedItems,
  required VoidCallback onExitSelectionMode,
  String? message,
}) async {
  final confirmed = await showAppConfirmDialog(
    context,
    title: context.l10n.downloadedAlbumDeleteSelected,
    message: message ?? context.l10n.downloadedAlbumDeleteMessage(ids.length),
    confirmLabel: context.l10n.dialogDelete,
    destructive: true,
    cancelIsDefault: true,
    confirmStyle: FilledButton.styleFrom(
      backgroundColor: Theme.of(context).colorScheme.error,
    ),
  );

  if (!confirmed || !context.mounted) return null;

  final deletedIds = <String>[];
  try {
    for (final id in ids) {
      if (await deleteItem(id)) deletedIds.add(id);
    }
  } finally {
    if (deletedIds.isNotEmpty && persistDeletedItems != null) {
      await persistDeletedItems(deletedIds);
    }
  }
  final deletedCount = deletedIds.length;

  if (context.mounted) {
    onExitSelectionMode();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          trackDeletionResultMessage(
            context.l10n,
            deleted: deletedCount,
            requested: ids.length,
          ),
        ),
      ),
    );
  }

  return deletedCount;
}
