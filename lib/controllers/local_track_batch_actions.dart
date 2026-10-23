import 'package:flutter/material.dart';
import 'package:mornye/widgets/app_alert_dialog.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/controllers/confirm_and_delete_tracks.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/utils/re_enrich_result.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/models/unified_library_item.dart';
import 'package:mornye/providers/deleted_library_files.dart';
import 'package:mornye/providers/download_queue_provider.dart';
import 'package:mornye/providers/extension_provider.dart';
import 'package:mornye/providers/local_library_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/services/batch_metadata_re_enrich.dart';
import 'package:mornye/services/downloaded_embedded_cover_resolver.dart';
import 'package:mornye/services/library_database.dart';
import 'package:mornye/services/local_track_redownload_service.dart';
import 'package:mornye/services/platform_bridge.dart';
import 'package:mornye/services/ffmpeg_reenrich.dart';
import 'package:mornye/utils/file_access.dart';
import 'package:mornye/utils/int_utils.dart';
import 'package:mornye/utils/lyrics_metadata_helper.dart';
import 'package:mornye/utils/logger.dart';
import 'package:mornye/utils/string_utils.dart';
import 'package:mornye/widgets/batch_progress_dialog.dart';
import 'package:mornye/widgets/app_snack_bar.dart';
import 'package:mornye/widgets/re_enrich_field_dialog.dart';
import 'package:mornye/widgets/re_enrich_review_sheet.dart';

final _reEnrichLog = AppLogger('BatchReEnrich');

Future<void> queueLocalTracksAsFlac(
  BuildContext context,
  WidgetRef ref,
  List<LocalLibraryItem> selected, {
  required bool Function() isActive,
  required VoidCallback onComplete,
}) async {
  if (selected.isEmpty) {
    return;
  }

  final confirmed = await showAppConfirmDialog(
    context,
    title: context.l10n.queueFlacAction,
    message: context.l10n.queueFlacConfirmMessage(selected.length),
    confirmLabel: context.l10n.queueFlacAction,
  );

  if (!confirmed || !context.mounted || !isActive()) {
    return;
  }

  final settings = ref.read(settingsProvider);
  final extensionState = ref.read(extensionProvider);
  final includeExtensions =
      settings.useExtensionProviders &&
      extensionState.extensions.any(
        (ext) => ext.enabled && ext.hasMetadataProvider,
      );
  final targetService = LocalTrackRedownloadService.preferredFlacService(
    settings,
    extensionState,
  );
  if (targetService.isEmpty) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(context.l10n.extensionsNoDownloadProvider)),
    );
    return;
  }
  final targetQuality =
      LocalTrackRedownloadService.preferredFlacQualityForService(
        targetService,
        extensionState,
      );

  final total = selected.length;

  var cancelled = false;
  BatchProgressDialog.show(
    context: context,
    title: context.l10n.queueFlacAction,
    total: total,
    icon: Icons.queue_music,
    onCancel: () {
      cancelled = true;
      BatchProgressDialog.dismiss(context);
    },
  );

  final matches = await matchLocalTracksForFlac(
    selected,
    resolve: (item) => LocalTrackRedownloadService.resolveBestMatch(
      item,
      includeExtensions: includeExtensions,
    ),
    shouldStop: () => cancelled || !context.mounted || !isActive(),
    onProgress: (index, item) =>
        BatchProgressDialog.update(current: index + 1, detail: item.trackName),
  );
  final matchedTracks = matches.tracks;
  final skippedCount = matches.skipped;

  if (!context.mounted || !isActive()) {
    return;
  }

  if (!cancelled) {
    BatchProgressDialog.dismiss(context);
  }

  if (matchedTracks.isEmpty) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(context.l10n.queueFlacNoReliableMatches)),
    );
    return;
  }

  ref
      .read(downloadQueueProvider.notifier)
      .addMultipleToQueue(
        matchedTracks,
        targetService,
        qualityOverride: targetQuality,
      );

  final summary = skippedCount == 0
      ? context.l10n.snackbarAddedTracksToQueue(matchedTracks.length)
      : context.l10n.queueFlacQueuedWithSkipped(
          matchedTracks.length,
          skippedCount,
        );

  showAppSnackBar(context, content: Text(summary));
  onComplete();
}

Future<void> reEnrichLibraryTracks(
  BuildContext context,
  WidgetRef ref,
  List<UnifiedLibraryItem> selected, {
  required bool Function() isActive,
  required Future<void> Function() onSelectionHide,
  required VoidCallback onSelectionRestore,
  required VoidCallback onComplete,
}) async {
  if (selected.isEmpty) return;
  final downloads = selected
      .map((item) => item.historyItem)
      .whereType<DownloadHistoryItem>()
      .toList(growable: false);
  final history = downloads.isEmpty
      ? null
      : ref.read(downloadHistoryProvider.notifier);
  await reEnrichLocalTracks(
    context,
    ref,
    [
      for (final item in selected)
        if (item.localItem != null)
          item.localItem!
        else if (item.historyItem case final track?)
          LocalLibraryItem.fromJson({
            ...track.toJson(),
            'scannedAt': track.downloadedAt.toIso8601String(),
          }),
    ],
    isActive: isActive,
    onSelectionHide: onSelectionHide,
    onSelectionRestore: onSelectionRestore,
    onComplete: onComplete,
    sourceTrackIds: {
      for (final track in downloads)
        if (track.spotifyId?.trim().isNotEmpty == true)
          track.id: track.spotifyId!,
    },
    refreshLibrary: () async {
      // Downloaded tracks read history, not the local-scan index. Read back
      // saved tags so failed or unselected fields cannot change history.
      for (final track in downloads) {
        try {
          await DownloadedEmbeddedCoverResolver.invalidate(track.filePath);
          final metadata = await PlatformBridge.readDisplayAudioMetadata(
            track.filePath,
          );
          if (metadata['error'] != null) continue;
          await history!.updateMetadataForItem(
            id: track.id,
            trackName: metadata['title'] as String? ?? track.trackName,
            artistName: metadata['artist'] as String? ?? track.artistName,
            albumName: metadata['album'] as String? ?? track.albumName,
            albumArtist: metadata['album_artist'] as String?,
            isrc: metadata['isrc'] as String?,
            trackNumber: readPositiveInt(metadata['track_number']),
            totalTracks: readPositiveInt(metadata['total_tracks']),
            discNumber: readPositiveInt(metadata['disc_number']),
            totalDiscs: readPositiveInt(metadata['total_discs']),
            releaseDate: metadata['date'] as String?,
            genre: metadata['genre'] as String?,
            composer: metadata['composer'] as String?,
            label: metadata['label'] as String?,
            copyright: metadata['copyright'] as String?,
            explicit: parseExplicitFlag(metadata['explicit']),
            hasLyrics:
                metadata.containsKey('hasLyrics') ||
                    metadata.containsKey('lyrics')
                ? metadata['hasLyrics'] == true ||
                      hasUsableLyricsContent(
                        metadata['lyrics']?.toString() ?? '',
                      )
                : null,
          );
        } catch (error) {
          debugPrint('Could not refresh re-enriched download: $error');
        }
      }
      if (isActive() && selected.any((item) => item.localItem != null)) {
        await _refreshReEnrichedLocalLibrary(ref);
      }
    },
  );
}

Future<void> _refreshReEnrichedLocalLibrary(WidgetRef ref) async {
  final library = ref.read(localLibraryProvider.notifier);
  try {
    if (!ref.read(localLibraryProvider).isScanning) {
      await library.scanAllSources();
    } else {
      await library.reloadFromStorage();
    }
  } catch (_) {
    await library.reloadFromStorage();
  }
}

Future<void> reEnrichLocalTracks(
  BuildContext context,
  WidgetRef ref,
  List<LocalLibraryItem> selected, {
  required bool Function() isActive,
  required Future<void> Function() onSelectionHide,
  required VoidCallback onSelectionRestore,
  required VoidCallback onComplete,
  Future<void> Function()? refreshLibrary,
  Map<String, String> sourceTrackIds = const {},
}) async {
  if (selected.isEmpty) return;
  // Capture a stable route context before a caller removes its overlay.
  context = Navigator.of(context, rootNavigator: true).context;
  await onSelectionHide();
  if (!context.mounted || !isActive()) return;
  final selection = await showReEnrichFieldDialog(
    context,
    selectedCount: selected.length,
  );

  if (selection == null || !context.mounted || !isActive()) {
    if (context.mounted && isActive()) onSelectionRestore();
    return;
  }

  final runner = BatchReEnrichRunner(
    sourceTrackIds: sourceTrackIds,
    beginPhase: () async {
      final settings = ref.read(settingsProvider);
      await ref
          .read(settingsProvider.notifier)
          .syncLyricsSettingsToBackend(settings: settings);
      return settings;
    },
  );
  var cancelled = false;
  BatchProgressDialog.show(
    context: context,
    title: selection.usesManualValues
        ? context.l10n.trackReEnrichPreparing
        : context.l10n.trackReEnrichSearching,
    total: selected.length,
    icon: selection.usesManualValues ? Icons.edit_note : Icons.manage_search,
    onCancel: () {
      cancelled = true;
      BatchProgressDialog.dismiss(context);
    },
  );

  final previews = await runner.preview(
    selected,
    selection,
    shouldStop: () => cancelled || !context.mounted || !isActive(),
    onProgress: (index, item) => BatchProgressDialog.update(
      current: index + 1,
      detail: '${item.trackName} - ${item.artistName}',
    ),
  );

  if (!context.mounted || !isActive()) return;
  if (!cancelled) BatchProgressDialog.dismiss(context);
  if (cancelled) {
    onSelectionRestore();
    return;
  }

  if (previews.isEmpty) {
    await showReEnrichResultDialog(
      context,
      message: context.l10n.trackReEnrichNoChanges,
    );
    // Restore after the result closes so root-overlay fallback bars cannot
    // cover this dialog either. Selected IDs remain intact throughout.
    if (context.mounted && isActive()) onSelectionRestore();
    return;
  }

  final confirmed = await showReEnrichReviewSheet(context, previews: previews);
  if (!confirmed || !context.mounted || !isActive()) {
    if (context.mounted && isActive()) onSelectionRestore();
    return;
  }

  final total = previews.length;
  cancelled = false;
  BatchProgressDialog.show(
    context: context,
    title: context.l10n.trackReEnrichProgress,
    total: total,
    icon: Icons.auto_fix_high,
    onCancel: () {
      cancelled = true;
      BatchProgressDialog.dismiss(context);
    },
  );

  final lyricsSummary = ReEnrichLyricsSummary();
  final successCount = await runner.apply(
    previews,
    onResult: lyricsSummary.add,
    shouldStop: () => cancelled || !context.mounted || !isActive(),
    onProgress: (index, item) => BatchProgressDialog.update(
      current: index + 1,
      detail: '${item.trackName} - ${item.artistName}',
    ),
  );

  if (!context.mounted || !isActive()) return;
  if (!cancelled) BatchProgressDialog.dismiss(context);

  // Report file-write outcomes immediately. A scan of a large Library can
  // take much longer than the batch and must not hide its completed result.
  ScaffoldMessenger.of(context).clearSnackBars();
  final summary = lyricsSummary.message(context.l10n, successCount, total);
  final resultClosed = showReEnrichResultDialog(context, message: summary);

  if (refreshLibrary != null) {
    await refreshLibrary();
  } else {
    await _refreshReEnrichedLocalLibrary(ref);
  }

  if (!context.mounted || !isActive()) return;
  onComplete();
  await resultClosed;
}

/// Runs a batch against one settings snapshot per phase. Dependencies are
/// injectable so cancellation, dispatch, and partial failure can be verified
/// without writing media files or opening dialogs.
class BatchReEnrichRunner {
  final Map<String, String> sourceTrackIds;
  final Future<AppSettings> Function() beginPhase;
  final Future<Map<String, dynamic>> Function(Map<String, dynamic>) reEnrich;
  final Future<void> Function({
    required String audioFilePath,
    required Map<String, dynamic> reEnrichResult,
  })
  writeSidecar;
  final Future<bool> Function({
    required LocalLibraryItem item,
    required Map<String, dynamic> result,
    required String artistTagMode,
  })
  applyFfmpeg;

  BatchReEnrichRunner({
    required this.beginPhase,
    this.sourceTrackIds = const {},
    this.reEnrich = PlatformBridge.reEnrichFile,
    this.writeSidecar = writeReEnrichSidecarLrc,
    this.applyFfmpeg = applyFfmpegReEnrichResult,
  });

  Future<List<BatchReEnrichPreview>> preview(
    List<LocalLibraryItem> items,
    ReEnrichFieldSelection selection, {
    required bool Function() shouldStop,
    required void Function(int, LocalLibraryItem) onProgress,
  }) async {
    if (shouldStop()) return [];
    final settings = await beginPhase();
    final previews = <BatchReEnrichPreview>[];
    for (var index = 0; index < items.length; index++) {
      if (shouldStop()) break;
      final item = items[index];
      onProgress(index, item);
      final fields = selection.updateFieldsFor(item);
      if (fields.isEmpty) continue;
      if (selection.usesManualValues) {
        final preview = buildManualBatchReEnrichPreview(item, selection);
        if (preview != null) previews.add(preview);
        continue;
      }
      try {
        final result = await reEnrich(
          buildBatchReEnrichRequest(
            item: item,
            settings: settings,
            updateFields: fields,
            previewOnly: true,
            sourceTrackId: sourceTrackIds[item.id],
          ),
        );
        final rawMetadata = result['enriched_metadata'];
        if (result['method'] != 'preview' || rawMetadata is! Map) {
          _reEnrichLog.w(
            'Metadata lookup failed for ${item.id}: ${result['error'] ?? result['method']}',
          );
          continue;
        }
        final metadata = rawMetadata.map(
          (key, value) => MapEntry(key.toString(), value),
        );
        final changes = buildReEnrichMetadataChanges(item, metadata, fields);
        if (changes.isEmpty) continue;
        previews.add(
          BatchReEnrichPreview(
            item: item,
            updateFields: fields,
            enrichedMetadata: metadata,
            changes: changes,
          ),
        );
      } catch (error, stack) {
        _reEnrichLog.w('Metadata lookup failed for ${item.id}: $error');
        _reEnrichLog.d('$stack');
        // A failed lookup must not prevent review of other tracks.
      }
    }
    return previews;
  }

  Future<int> apply(
    List<BatchReEnrichPreview> previews, {
    required bool Function() shouldStop,
    required void Function(int, LocalLibraryItem) onProgress,
    void Function(Map<String, dynamic>)? onResult,
  }) async {
    if (shouldStop()) return 0;
    // Settings may have changed while the review sheet was open.
    final settings = await beginPhase();
    var successes = 0;
    for (var index = 0; index < previews.length; index++) {
      if (shouldStop()) break;
      final preview = previews[index];
      onProgress(index, preview.item);
      try {
        final result = await reEnrich(
          buildBatchReEnrichRequest(
            item: preview.item,
            settings: settings,
            updateFields: preview.updateFields,
            resolvedMetadata: preview.enrichedMetadata,
            sourceTrackId: sourceTrackIds[preview.item.id],
          ),
        );
        switch (result['method']) {
          case 'native':
            await writeSidecar(
              audioFilePath: preview.item.filePath,
              reEnrichResult: result,
            );
            successes++;
            onResult?.call(result);
          case 'ffmpeg':
            if (await applyFfmpeg(
              item: preview.item,
              result: result,
              artistTagMode: settings.artistTagMode,
            )) {
              successes++;
              onResult?.call(result);
            } else {
              _reEnrichLog.w('Metadata write failed for ${preview.item.id}');
            }
          default:
            _reEnrichLog.w(
              'Re-enrich failed for ${preview.item.id}: ${result['error'] ?? result['method']}',
            );
        }
      } catch (error, stack) {
        _reEnrichLog.w('Re-enrich failed for ${preview.item.id}: $error');
        _reEnrichLog.d('$stack');
        // Keep successful files and continue with the rest of the selection.
      }
    }
    return successes;
  }
}

/// Cancellation stops further matching and retains reliable matches already
/// resolved, matching the queue action's existing partial-completion behavior.
Future<({List<Track> tracks, int skipped})> matchLocalTracksForFlac(
  List<LocalLibraryItem> items, {
  required Future<LocalTrackRedownloadResolution> Function(LocalLibraryItem)
  resolve,
  required bool Function() shouldStop,
  required void Function(int, LocalLibraryItem) onProgress,
}) async {
  final tracks = <Track>[];
  var skipped = 0;
  for (var index = 0; index < items.length; index++) {
    if (shouldStop()) break;
    onProgress(index, items[index]);
    try {
      final resolution = await resolve(items[index]);
      if (resolution.canQueue && resolution.match != null) {
        tracks.add(resolution.match!);
      } else {
        skipped++;
      }
    } catch (_) {
      skipped++;
    }
  }
  return (tracks: tracks, skipped: skipped);
}

/// Confirms, then deletes the files behind [selected] and removes their
/// history or local-index rows. Files that cannot be deleted keep their rows.
Future<void> deleteLibraryTracks(
  BuildContext context,
  WidgetRef ref,
  List<UnifiedLibraryItem> selected, {
  required bool Function() isActive,
  required VoidCallback onComplete,
}) async {
  if (selected.isEmpty) return;
  final confirmed = await showAppConfirmDialog(
    context,
    title: context.l10n.dialogDeleteSelectedTitle,
    message: context.l10n.dialogDeleteSelectedMessage(selected.length),
    confirmLabel: context.l10n.dialogDelete,
    destructive: true,
    cancelIsDefault: true,
    confirmStyle: FilledButton.styleFrom(
      backgroundColor: Theme.of(context).colorScheme.error,
    ),
  );
  if (!confirmed || !isActive() || !context.mounted) return;

  final container = ProviderScope.containerOf(context, listen: false);
  final messenger = ScaffoldMessenger.of(context);
  final l10n = context.l10n;
  final deletedPaths = <String>{};
  var deletedCount = 0;
  for (final item in selected) {
    final cleanPath = DownloadedEmbeddedCoverResolver.cleanFilePath(
      item.filePath,
    );
    if (!await deleteFile(cleanPath)) continue;
    deletedPaths.add(cleanPath);
    deletedCount++;
  }
  await removeDeletedLibraryFileEntries(container, deletedPaths);
  if (!isActive() || !context.mounted) return;
  onComplete();
  messenger.showSnackBar(
    SnackBar(
      content: Text(
        trackDeletionResultMessage(
          l10n,
          deleted: deletedCount,
          requested: selected.length,
        ),
      ),
    ),
  );
}
