import 'package:material_ui/material_ui.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/services/shell_navigation_service.dart';
import 'package:mornye/widgets/app_snack_bar.dart';

SnackBarAction buildViewQueueSnackBarAction(BuildContext context) {
  return SnackBarAction(
    label: context.l10n.snackbarViewQueue,
    onPressed: () {
      ShellNavigationService.requestTab(ShellTab.library);
    },
  );
}

/// Shared "Added to queue" snackbar with a View action jumping to Library.
void showAddedToQueueSnackBar(BuildContext context, String trackName) {
  if (!context.mounted) return;
  showAppSnackBar(
    context,
    content: Text(context.l10n.snackbarAddedToQueue(trackName)),
    action: buildViewQueueSnackBarAction(context),
  );
}
