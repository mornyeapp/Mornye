import 'package:flutter/material.dart';
import 'package:mornye/widgets/app_alert_dialog.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/download_queue_provider.dart';
import 'package:mornye/providers/extension_provider.dart';
import 'package:mornye/providers/library_collections_provider.dart';
import 'package:mornye/providers/local_library_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/utils/adaptive_layout.dart';
import 'package:mornye/utils/logger.dart';
import 'package:mornye/utils/string_utils.dart';
import 'package:mornye/widgets/download_service_picker.dart';
import 'package:mornye/widgets/app_snack_bar.dart';
import 'package:mornye/widgets/view_queue_snackbar_action.dart';

/// Shared single-track "add to queue" flow for detail screens: shows the
/// quality/service picker when the user opted into it, otherwise resolves
/// the default service and enqueues directly.
void downloadSingleTrack(
  BuildContext context,
  WidgetRef ref,
  Track track, {
  String? recommendedService,
  String? playlistName,
  int? playlistPosition,
  bool forceQualityPicker = false,
}) {
  final settings = ref.read(settingsProvider);

  void notifyQueued() {
    showAddedToQueueSnackBar(context, track.name);
  }

  if (settings.askQualityBeforeDownload || forceQualityPicker) {
    // A context menu may be disposed before the quality picker is submitted.
    final container = ProviderScope.containerOf(context, listen: false);
    DownloadServicePicker.show(
      context,
      trackName: track.name,
      artistName: track.artistName,
      // The picker loads its cover over http only.
      coverUrl: normalizeRemoteHttpUrl(track.coverUrl),
      recommendedService: recommendedService,
      onSelect: (quality, service) {
        container
            .read(downloadQueueProvider.notifier)
            .addToQueue(
              track,
              service,
              qualityOverride: quality,
              playlistName: playlistName,
              playlistPosition: playlistPosition,
            );
        notifyQueued();
      },
    );
  } else {
    final extensionState = ref.read(extensionProvider);
    final service = resolveEffectiveDownloadService(
      settings.defaultService,
      extensionState,
    );
    if (service.isEmpty) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.l10n.extensionsNoDownloadProvider)),
      );
      return;
    }
    ref
        .read(downloadQueueProvider.notifier)
        .addToQueue(
          track,
          service,
          playlistName: playlistName,
          playlistPosition: playlistPosition,
        );
    notifyQueued();
  }
}

/// Shared "download all" confirmation dialog for detail screens
/// (album/playlist/library-folder).
void confirmDownloadAllDialog(
  BuildContext context,
  int trackCount,
  VoidCallback onConfirm,
) {
  if (trackCount == 0) return;
  showAppDialog<void>(
    context: context,
    builder: (dialogContext) {
      return AppAlertDialog(
        title: Text(context.l10n.dialogDownloadAllTitle),
        content: Text(context.l10n.dialogDownloadAllMessage(trackCount)),
        actions: [
          AppDialogAction(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text(context.l10n.dialogCancel),
          ),
          AppDialogAction(
            filled: true,
            onPressed: () {
              Navigator.pop(dialogContext);
              onConfirm();
            },
            child: Text(context.l10n.dialogDownload),
          ),
        ],
      );
    },
  );
}

/// Shared "added N / skipped N" snackbar shown after queueing a batch of
/// tracks from album/playlist/library-folder detail screens.
void showQueuedSnackbar(BuildContext context, int added, int skipped) {
  if (!context.mounted) return;
  final message = skipped > 0
      ? context.l10n.discographySkippedDownloaded(added, skipped)
      : context.l10n.snackbarAddedTracksToQueue(added);
  showAppSnackBar(context, content: Text(message));
}

bool shouldShowBatchDownloadPicker({
  required bool forceQualityPicker,
  required bool askQualityBeforeDownload,
  required bool allowQualityVariants,
}) => forceQualityPicker || askQualityBeforeDownload || allowQualityVariants;

/// Shared batch "add to queue" flow for detail screens: skips tracks already
/// present in download history or the local library, then either shows the
/// quality/service picker or resolves a default service, before enqueueing
/// the rest.
///
/// Set [resolveDefaultService] to false to match screens that pass
/// `settings.defaultService` straight through without resolving it against
/// enabled extensions (playlist / library-folder screens do this today).
/// [forceQualityPicker] lets an explicit multi-select action choose one
/// provider and quality for the complete batch. [onQueued] runs only after
/// tracks are actually added, not when the picker is merely opened.
Future<void> queueTracksSkippingDownloaded(
  BuildContext context,
  WidgetRef ref,
  List<Track> tracks, {
  required String artistNameForPicker,
  String? recommendedService,
  String? playlistName,
  bool resolveDefaultService = true,
  bool forceQualityPicker = false,
  VoidCallback? onQueued,
}) async {
  if (tracks.isEmpty) return;

  final settings = ref.read(settingsProvider);
  final skipExisting =
      settings.deduplicateDownloads && !settings.allowQualityVariants;
  final historyLookups = tracks
      .map(historyLookupForTrack)
      .toList(growable: false);
  Set<String> existingHistoryKeys = const {};
  if (skipExisting) {
    try {
      existingHistoryKeys = await ref.read(
        downloadHistoryBatchExistsProvider(
          HistoryBatchLookupRequest(historyLookups),
        ).future,
      );
    } catch (e) {
      // Queueing without the skip beats silently doing nothing: several
      // callers fire this flow unawaited, so a throw here would vanish.
      AppLogger('DownloadFlow').w('Duplicate check failed, queueing all: $e');
    }
  }
  if (!context.mounted) return;
  final localLibState =
      (skipExisting &&
          settings.localLibraryEnabled &&
          settings.localLibraryShowDuplicates)
      ? ref.read(localLibraryProvider)
      : null;
  final tracksToQueue = <Track>[];
  var skippedCount = 0;

  for (var i = 0; i < tracks.length; i++) {
    final track = tracks[i];
    final isInHistory =
        skipExisting &&
        existingHistoryKeys.contains(historyLookups[i].lookupKey);
    final isInLocal =
        localLibState?.existsInLibrary(
          isrc: track.isrc,
          trackName: track.name,
          artistName: track.artistName,
        ) ??
        false;

    if (isInHistory || isInLocal) {
      skippedCount++;
    } else {
      tracksToQueue.add(track);
    }
  }

  if (tracksToQueue.isEmpty) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          context.l10n.discographySkippedDownloaded(0, skippedCount),
        ),
      ),
    );
    return;
  }

  if (shouldShowBatchDownloadPicker(
    forceQualityPicker: forceQualityPicker,
    askQualityBeforeDownload: settings.askQualityBeforeDownload,
    allowQualityVariants: settings.allowQualityVariants,
  )) {
    DownloadServicePicker.show(
      context,
      trackName: '${tracksToQueue.length} tracks',
      artistName: artistNameForPicker,
      recommendedService: recommendedService,
      onSelect: (quality, service) {
        ref
            .read(downloadQueueProvider.notifier)
            .addMultipleToQueue(
              tracksToQueue,
              service,
              qualityOverride: quality,
              playlistName: playlistName,
            );
        onQueued?.call();
        showQueuedSnackbar(context, tracksToQueue.length, skippedCount);
      },
    );
    return;
  }

  String service;
  if (resolveDefaultService) {
    final extensionState = ref.read(extensionProvider);
    service = resolveEffectiveDownloadService(
      settings.defaultService,
      extensionState,
    );
    if (service.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.l10n.extensionsNoDownloadProvider)),
      );
      return;
    }
  } else {
    service = settings.defaultService;
  }
  ref
      .read(downloadQueueProvider.notifier)
      .addMultipleToQueue(tracksToQueue, service, playlistName: playlistName);
  onQueued?.call();
  showQueuedSnackbar(context, tracksToQueue.length, skippedCount);
}

/// "dd/MM/yyyy" or "MM/yyyy" formatting for a backend release date string.
String formatReleaseDate(String date) {
  if (date.length >= 10) {
    final parts = date.substring(0, 10).split('-');
    if (parts.length == 3) {
      return '${parts[2]}/${parts[1]}/${parts[0]}';
    }
  } else if (date.length >= 7) {
    final parts = date.split('-');
    if (parts.length >= 2) {
      return '${parts[1]}/${parts[0]}';
    }
  }
  return date;
}

/// Shared release-date/track-count/duration footer for album/playlist detail
/// screens. Set [excludeEpochReleaseDate] to hide a `1970-...` placeholder
/// release date (playlists can carry one; albums never do).
Widget buildTrackListFooter(
  BuildContext context,
  ColorScheme colorScheme,
  List<Track> tracks, {
  bool excludeEpochReleaseDate = false,
}) {
  if (tracks.isEmpty) {
    return const SliverToBoxAdapter(child: SizedBox.shrink());
  }

  final releaseDate = tracks.first.releaseDate;
  final totalSeconds = tracks.fold<int>(
    0,
    (sum, t) => sum + (t.duration > 0 ? t.duration : 0),
  );
  final totalMinutes = (totalSeconds / 60).round();

  final lines = <String>[];
  final hasReleaseDate =
      releaseDate != null &&
      releaseDate.isNotEmpty &&
      (!excludeEpochReleaseDate || !releaseDate.startsWith('1970'));
  if (hasReleaseDate) {
    lines.add(formatReleaseDate(releaseDate));
  }
  final countText = context.l10n.tracksCount(tracks.length);
  lines.add(totalMinutes > 0 ? '$countText • $totalMinutes min' : countText);

  // Lines up with the track list, which centers on tablets.
  final inset = wideListInset(context);
  return SliverToBoxAdapter(
    child: Padding(
      padding: EdgeInsets.fromLTRB(20 + inset, 8, 20 + inset, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final line in lines)
            Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: Text(
                line,
                style: TextStyle(
                  color: colorScheme.onSurfaceVariant,
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
        ],
      ),
    ),
  );
}

/// Shared "love all / unlove all" batch toggle for album/playlist detail
/// screens.
Future<void> loveAllTracks(
  BuildContext context,
  WidgetRef ref,
  List<Track> tracks,
) async {
  if (tracks.isEmpty) return;
  final result = await ref
      .read(libraryCollectionsProvider.notifier)
      .toggleLovedTracks(tracks);
  if (context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          result.removed
              ? context.l10n.snackbarRemovedTracksFromLoved(result.count)
              : context.l10n.snackbarAddedTracksToLoved(result.count),
        ),
      ),
    );
  }
}
