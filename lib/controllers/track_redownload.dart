import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/providers/download_queue_provider.dart';
import 'package:mornye/providers/extension_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/services/library_database.dart';
import 'package:mornye/services/local_track_redownload_service.dart';
import 'package:mornye/utils/logger.dart';
import 'package:mornye/widgets/app_alert_dialog.dart';
import 'package:mornye/widgets/batch_progress_dialog.dart';
import 'package:mornye/widgets/track_detail_actions.dart';

final _log = AppLogger('TrackRedownload');

/// Confirms, finds [item] online again and queues the match the way a
/// download from search is queued. The existing file is left alone.
Future<void> redownloadTrack(
  BuildContext context,
  WidgetRef ref,
  LocalLibraryItem item, {
  String? sourceTrackId,
}) async {
  final confirmed = await showAppConfirmDialog(
    context,
    title: context.l10n.trackRedownload,
    message: context.l10n.trackRedownloadConfirmMessage,
    confirmLabel: context.l10n.trackRedownload,
  );
  if (!confirmed || !context.mounted) return;

  var cancelled = false;
  BatchProgressDialog.show(
    context: context,
    title: context.l10n.trackRedownload,
    total: 1,
    icon: Icons.download_outlined,
    onCancel: () {
      cancelled = true;
      BatchProgressDialog.dismiss(context);
    },
  );
  BatchProgressDialog.update(current: 1, detail: item.trackName);

  final settings = ref.read(settingsProvider);
  TrackRedownloadPlan plan;
  try {
    plan = await LocalTrackRedownloadService.planRedownload(
      item,
      settings: settings,
      extensionState: ref.read(extensionProvider),
      queue: ref.read(downloadQueueProvider).items,
      sourceTrackId: sourceTrackId,
    );
  } catch (error) {
    _log.w('Re-download lookup failed for ${item.id}: $error');
    plan = const TrackRedownloadPlan(TrackRedownloadStatus.noMatch);
  }
  if (cancelled || !context.mounted) return;
  BatchProgressDialog.dismiss(context);

  final message = switch (plan.status) {
    TrackRedownloadStatus.noService =>
      context.l10n.extensionsNoDownloadProvider,
    TrackRedownloadStatus.noMatch => context.l10n.trackRedownloadNoMatch,
    TrackRedownloadStatus.alreadyQueued =>
      context.l10n.trackRedownloadAlreadyQueued,
    TrackRedownloadStatus.matched => null,
  };
  final match = plan.match;
  if (message != null || match == null) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message ?? context.l10n.trackRedownloadNoMatch)),
    );
    return;
  }
  // The song is in the Library already, so search would offer the picker
  // when quality variants are allowed. The new file never replaces the old.
  downloadSingleTrack(
    context,
    ref,
    match,
    forceQualityPicker: settings.allowQualityVariants,
    keepBoth: true,
  );
}
