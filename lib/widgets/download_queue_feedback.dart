import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/providers/download_queue_provider.dart';

/// Presents live queue effects while the application shell is mounted.
class DownloadQueueFeedback extends ConsumerWidget {
  const DownloadQueueFeedback({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.listen(downloadQueueProvider.select((queue) => queue.reconnectRetry), (
      _,
      retry,
    ) {
      if (retry == null ||
          !context.mounted ||
          WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) {
        return;
      }
      final queue = ref.read(downloadQueueProvider.notifier);
      final l10n = context.l10n;
      ScaffoldMessenger.of(context)
        ..removeCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(l10n.queueNetworkFailedOffline(retry.failedCount)),
            action: SnackBarAction(
              label: l10n.dialogRetry,
              onPressed: () => queue.retryAllFailed(networkOnly: true),
            ),
          ),
        );
    });
    return child;
  }
}
