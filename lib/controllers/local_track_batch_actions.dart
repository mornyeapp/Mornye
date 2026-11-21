import 'package:material_ui/material_ui.dart';
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
import 'package:mornye/providers/player_motion_artwork_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/providers/song_leftovers_provider.dart';
import 'package:mornye/services/batch_metadata_re_enrich.dart';
import 'package:mornye/services/downloaded_embedded_cover_resolver.dart';
import 'package:mornye/services/library_database.dart';
import 'package:mornye/services/metadata_cover_resources.dart';
import 'package:mornye/services/metadata_persistence_service.dart';
import 'package:mornye/services/network_file_editor.dart';
import 'package:mornye/services/local_track_redownload_service.dart';
import 'package:mornye/services/platform_bridge.dart';
import 'package:mornye/services/ffmpeg_reenrich.dart';
import 'package:mornye/services/re_enrich_undo.dart';
import 'package:mornye/utils/artist_utils.dart';
import 'package:mornye/utils/int_utils.dart';
import 'package:mornye/utils/lyrics_metadata_helper.dart';
import 'package:mornye/utils/logger.dart';
import 'package:mornye/utils/string_utils.dart';
import 'package:mornye/widgets/batch_progress_dialog.dart';
import 'package:mornye/widgets/app_snack_bar.dart';
import 'package:mornye/widgets/re_enrich_field_dialog.dart';
import 'package:mornye/widgets/re_enrich_candidate_sheet.dart';
import 'package:mornye/widgets/re_enrich_review_sheet.dart';
import 'package:mornye/widgets/link/link_library_actions.dart';
import 'package:mornye/services/link/link_library_jobs.dart';

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
  final container = ProviderScope.containerOf(context, listen: false);
  if (hasLinkLibrarySongs(container, selected)) {
    final root = Navigator.of(context, rootNavigator: true).context;
    await onSelectionHide();
    if (!root.mounted || !isActive()) return;
    var accepted = false;
    await runLinkLibraryAction(
      root,
      container,
      selected,
      LinkLibraryAction.reEnrich,
      onAccepted: () {
        accepted = true;
        if (isActive()) onComplete();
      },
    );
    if (!accepted && root.mounted && isActive()) onSelectionRestore();
    return;
  }
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
    refreshLibrary: (written) async {
      // Downloaded tracks read history, not the local-scan index. Read back
      // saved tags so failed or unselected fields cannot change history.
      // Only tracks the batch wrote can have changed.
      for (final track in downloads) {
        if (!written.contains(track.id)) continue;
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
      if (isActive() &&
          selected.any(
            (item) =>
                item.localItem != null && written.contains(item.localItem!.id),
          )) {
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

  /// Refreshes the Library after the batch, given the ids of the tracks it
  /// wrote to. Defaults to a scan of the Library folders.
  Future<void> Function(Set<String> written)? refreshLibrary,
  Map<String, String> sourceTrackIds = const {},

  /// Where the songs' previous states are kept; app storage by default.
  ReEnrichUndo? undo,
}) async {
  // A cover picked in the dialog stays until every write has finished.
  final pickedCovers = MetadataCoverResources();
  try {
    await _reEnrichLocalTracks(
      context,
      ref,
      selected,
      isActive: isActive,
      onSelectionHide: onSelectionHide,
      onSelectionRestore: onSelectionRestore,
      onComplete: onComplete,
      refreshLibrary: refreshLibrary,
      sourceTrackIds: sourceTrackIds,
      undo: undo,
      pickedCovers: pickedCovers,
    );
  } finally {
    await pickedCovers.dispose();
  }
}

Future<void> _reEnrichLocalTracks(
  BuildContext context,
  WidgetRef ref,
  List<LocalLibraryItem> selected, {
  required bool Function() isActive,
  required Future<void> Function() onSelectionHide,
  required VoidCallback onSelectionRestore,
  required VoidCallback onComplete,
  required Future<void> Function(Set<String> written)? refreshLibrary,
  required Map<String, String> sourceTrackIds,
  required ReEnrichUndo? undo,
  required MetadataCoverResources pickedCovers,
}) async {
  if (selected.isEmpty) return;
  final container = ProviderScope.containerOf(context, listen: false);
  final items = [
    for (final item in selected) UnifiedLibraryItem.fromLocalLibrary(item),
  ];
  if (hasLinkLibrarySongs(container, items)) {
    final root = Navigator.of(context, rootNavigator: true).context;
    await onSelectionHide();
    if (!root.mounted || !isActive()) return;
    var accepted = false;
    await runLinkLibraryAction(
      root,
      container,
      items,
      LinkLibraryAction.reEnrich,
      onAccepted: () {
        accepted = true;
        if (isActive()) onComplete();
      },
    );
    if (!accepted && root.mounted && isActive()) onSelectionRestore();
    return;
  }
  // Capture a stable route context before a caller removes its overlay.
  context = Navigator.of(context, rootNavigator: true).context;
  await onSelectionHide();
  if (!context.mounted || !isActive()) return;
  final selection = await showReEnrichFieldDialog(
    context,
    selectedCount: selected.length,
    covers: pickedCovers,
  );

  if (selection == null || !context.mounted || !isActive()) {
    if (context.mounted && isActive()) onSelectionRestore();
    return;
  }

  final artworkContainer = ProviderScope.containerOf(context, listen: false);
  final runner = BatchReEnrichRunner(
    undo: undo,
    sourceTrackIds: sourceTrackIds,
    saveMotionArtwork: (item, metadata) => saveReEnrichedMotionArtwork(
      artworkContainer,
      metadata: metadata,
      albumName: item.albumName,
      artistName: item.artistName,
    ),
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

  final providerName = reEnrichProviderNames(ref.read(extensionProvider));
  var reviewed = previews;
  // One song goes straight to its results, as from its own page; the
  // review then shows what the pick changes.
  if (selected.length == 1 &&
      previews.length == 1 &&
      previews.single.candidates.isNotEmpty) {
    final single = previews.single;
    final candidate = await showReEnrichCandidateSheet(
      context,
      candidates: single.candidates,
      title: context.l10n.trackReEnrich,
      subtitle: [
        single.item.trackName,
        single.item.artistName,
      ].where((value) => value.trim().isNotEmpty).join(' · '),
      providerName: providerName,
    );
    if (candidate == null || !context.mounted || !isActive()) {
      if (context.mounted && isActive()) onSelectionRestore();
      return;
    }
    final picked = await runner.choose(single, candidate);
    if (!context.mounted || !isActive()) return;
    if (picked != null && picked.changes.isEmpty) {
      await showReEnrichResultDialog(
        context,
        message: context.l10n.trackReEnrichAlreadyMatches,
      );
      if (context.mounted && isActive()) onSelectionRestore();
      return;
    }
    if (picked != null) reviewed = [picked];
  }

  // One song is reviewed change by change; a batch is approved as a whole.
  final covers = MetadataCoverResources();
  final maxDimension = ref.read(settingsProvider).embeddedCoverMaxDimension;
  final List<BatchReEnrichPreview>? approved;
  try {
    approved = await showReEnrichReviewSheet(
      context,
      previews: reviewed,
      onChoose: runner.choose,
      providerName: providerName,
      chooseFields: selected.length == 1,
      loadCovers: (preview) =>
          loadReEnrichReviewCovers(covers, preview, maxDimension: maxDimension),
    );
  } finally {
    await covers.dispose();
  }
  final toApply = [
    for (final preview in approved ?? const <BatchReEnrichPreview>[])
      if (preview.changes.isNotEmpty) preview,
  ];
  if (toApply.isEmpty || !context.mounted || !isActive()) {
    if (context.mounted && isActive()) onSelectionRestore();
    return;
  }

  final total = toApply.length;
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
  final written = <String>{};
  final successCount = await runner.apply(
    toApply,
    onResult: lyricsSummary.add,
    onWritten: (item) => written.add(item.id),
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
  final undoable = [...runner.undoSources];
  final resultClosed = showReEnrichResultDialog(
    context,
    message: summary,
    undoLabel: undoable.isEmpty
        ? null
        : total == 1
        ? context.l10n.trackReEnrichUndoAction
        : context.l10n.trackReEnrichUndoAll,
  );

  if (refreshLibrary != null) {
    await refreshLibrary(written);
  } else {
    await _refreshReEnrichedLocalLibrary(ref);
  }

  if (!context.mounted || !isActive()) return;
  onComplete();
  if (!await resultClosed || !context.mounted || !isActive()) return;
  await _undoReEnrichRun(
    context,
    ref,
    runner,
    undoable,
    ids: {
      for (final preview in toApply) preview.item.filePath: preview.item.id,
    },
    isActive: isActive,
    refreshLibrary: refreshLibrary,
  );
}

/// Restores the songs [runner] re-enriched, from its result. Only states
/// that run saved are restored, so a song re-enriched again since keeps it.
Future<void> _undoReEnrichRun(
  BuildContext context,
  WidgetRef ref,
  BatchReEnrichRunner runner,
  List<String> sources, {
  required Map<String, String> ids,
  required bool Function() isActive,
  Future<void> Function(Set<String> written)? refreshLibrary,
}) async {
  final artistTagMode = artistTagModeForExistingTags(
    ref.read(settingsProvider).artistTagMode,
  );
  final l10n = context.l10n;
  final many = sources.length > 1;
  var cancelled = false;
  if (many) {
    BatchProgressDialog.show(
      context: context,
      title: l10n.trackReEnrichUndoProgress,
      total: sources.length,
      icon: Icons.undo,
      onCancel: () {
        cancelled = true;
        BatchProgressDialog.dismiss(context);
      },
    );
  }
  final restored = <String>{};
  var coverKept = false;
  Object? error;
  for (var index = 0; index < sources.length; index++) {
    if (cancelled || !context.mounted || !isActive()) break;
    if (many) BatchProgressDialog.update(current: index + 1);
    final result = await runner.undo.restore(
      sources[index],
      artistTagMode: artistTagMode,
      batch: runner.undoBatch,
    );
    if (result.restored) {
      restored.add(ids[sources[index]] ?? sources[index]);
      coverKept |= result.outcome == ReEnrichUndoOutcome.coverKept;
    } else {
      error ??= result.error;
    }
  }
  if (!context.mounted || !isActive()) return;
  if (many && !cancelled) BatchProgressDialog.dismiss(context);
  final message = [
    if (many)
      l10n.trackReEnrichUndoAllDone(restored.length, sources.length)
    else if (restored.isNotEmpty)
      l10n.trackReEnrichUndoDone
    else
      l10n.trackSaveFailed(context.friendlyError(error)),
    if (coverKept) l10n.trackReEnrichUndoCoverKept,
  ].join('\n');
  final closed = showReEnrichResultDialog(context, message: message);
  if (restored.isNotEmpty) {
    if (refreshLibrary != null) {
      await refreshLibrary(restored);
    } else {
      await _refreshReEnrichedLocalLibrary(ref);
    }
  }
  await closed;
}

/// Runs a batch against one settings snapshot per phase. Dependencies are
/// injectable so cancellation, dispatch, and partial failure can be verified
/// without writing media files or opening dialogs.
class BatchReEnrichRunner {
  final NetworkFileEditor? networkEditor;
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
  final Future<void> Function(
    LocalLibraryItem item,
    Map<String, dynamic> metadata,
  )?
  saveMotionArtwork;

  /// The metadata editor's save, which writes a preview with a picked cover.
  final Future<MetadataSaveResult> Function(MetadataSaveRequest request)
  saveMetadata;

  /// Saves what each write replaces, so a song can be restored later.
  final ReEnrichUndo undo;

  /// Marks the states this runner saves, so undoing the run restores only
  /// those.
  final String undoBatch;

  /// The songs whose previous state this runner saved, in write order.
  final List<String> undoSources = [];

  BatchReEnrichRunner({
    required this.beginPhase,
    this.networkEditor,
    this.sourceTrackIds = const {},
    this.reEnrich = PlatformBridge.reEnrichFile,
    this.writeSidecar = writeReEnrichSidecarLrc,
    this.applyFfmpeg = applyFfmpegReEnrichResult,
    this.saveMotionArtwork,
    this.saveMetadata = _saveWithEditor,
    ReEnrichUndo? undo,
  }) : undo = undo ?? ReEnrichUndo.instance,
       undoBatch = 'reenrich-${DateTime.now().microsecondsSinceEpoch}';

  static Future<MetadataSaveResult> _saveWithEditor(
    MetadataSaveRequest request,
  ) async {
    final covers = MetadataCoverResources();
    try {
      return await MetadataPersistenceService(covers: covers).save(request);
    } finally {
      await covers.dispose();
    }
  }

  /// The settings of the last preview, which picks reuse.
  AppSettings? _previewSettings;

  /// [preview] updated from [candidate], picked by hand, or null when the
  /// lookup failed.
  Future<BatchReEnrichPreview?> choose(
    BatchReEnrichPreview preview,
    Map<String, dynamic> candidate,
  ) async {
    final settings = _previewSettings ?? await beginPhase();
    final result = await reEnrich(
      buildBatchReEnrichRequest(
        item: preview.item,
        settings: settings,
        updateFields: preview.updateFields,
        previewOnly: true,
        sourceTrackId: sourceTrackIds[preview.item.id],
        selectedCandidate: candidate,
      ),
    );
    final rawMetadata = result['enriched_metadata'];
    if (result['method'] != 'preview' || rawMetadata is! Map) {
      _reEnrichLog.w(
        'Picked result failed for ${preview.item.id}: ${result['error'] ?? result['method']}',
      );
      return null;
    }
    return preview.withChoice(
      candidate,
      rawMetadata.map((key, value) => MapEntry(key.toString(), value)),
    );
  }

  Future<List<BatchReEnrichPreview>> preview(
    List<LocalLibraryItem> items,
    ReEnrichFieldSelection selection, {
    required bool Function() shouldStop,
    required void Function(int, LocalLibraryItem) onProgress,
  }) async {
    if (shouldStop()) return [];
    final settings = await beginPhase();
    _previewSettings = settings;
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
            includeCandidates: true,
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
        final preview = BatchReEnrichPreview(
          item: item,
          updateFields: fields,
          enrichedMetadata: metadata,
          changes: buildReEnrichMetadataChanges(item, metadata, fields),
          match: ReEnrichMatch.fromWire(result['auto_match']),
          candidates: reEnrichCandidates(result['candidates']),
        );
        // A song nothing fitted well still goes to review when a result
        // can be picked for it by hand.
        if (preview.changes.isEmpty && !preview.needsChoice) continue;
        previews.add(preview);
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
    void Function(LocalLibraryItem)? onWritten,

    /// A song that was not written, with the backend error or exception
    /// when there is one.
    void Function(LocalLibraryItem item, Object? error)? onFailed,
  }) async {
    if (shouldStop()) return 0;
    // Settings may have changed while the review sheet was open.
    final settings = await beginPhase();
    var successes = 0;
    for (var index = 0; index < previews.length; index++) {
      if (shouldStop()) break;
      final preview = previews[index];
      onProgress(index, preview.item);
      ReEnrichUndoDraft? draft;
      Future<({bool written, Map<String, dynamic> result})> write(
        LocalLibraryItem target,
      ) async {
        draft = await _captureUndo(preview, target.filePath, settings);
        return _write(preview, settings, target);
      }

      try {
        final source = preview.item.filePath;
        // A review can keep only what the file does not hold, such as motion
        // artwork. Nothing is written then: the backend reads an empty field
        // list as every field.
        final applied = preview.updateFields.isEmpty
            ? (written: true, result: const <String, dynamic>{})
            : source.startsWith('network://')
            ? await (networkEditor ?? NetworkFileEditor.instance).edit(
                source,
                (path) => write(
                  LocalLibraryItem.fromJson({
                    ...preview.item.toJson(),
                    'filePath': path,
                  }),
                ),
                succeeded: (result) => result.written,
                publishLyricsSidecar: true,
              )
            : await write(preview.item);
        if (applied.written) {
          successes++;
          onWritten?.call(preview.item);
          final saved = draft;
          if (saved != null &&
              await undo.commit(
                saved,
                source,
                applied.result,
                batch: undoBatch,
              )) {
            undoSources.add(source);
          }
          await _saveMotionArtwork(preview, applied.result);
          onResult?.call(applied.result);
        } else {
          onFailed?.call(preview.item, applied.result['error']);
        }
      } catch (error, stack) {
        _reEnrichLog.w('Re-enrich failed for ${preview.item.id}: $error');
        _reEnrichLog.d('$stack');
        onFailed?.call(preview.item, error);
        // Keep successful files and continue with the rest of the selection.
      } finally {
        await draft?.discard();
      }
    }
    return successes;
  }

  /// Reading the previous state never stops the write: a song whose state
  /// could not be read is written without one.
  Future<ReEnrichUndoDraft?> _captureUndo(
    BatchReEnrichPreview preview,
    String path,
    AppSettings settings,
  ) async {
    try {
      return await undo.capture(preview, path, settings);
    } catch (error) {
      _reEnrichLog.w('Could not read ${preview.item.id} before re-enrich');
      return null;
    }
  }

  Future<({bool written, Map<String, dynamic> result})> _write(
    BatchReEnrichPreview preview,
    AppSettings settings,
    LocalLibraryItem target,
  ) async {
    if (preview.coverFile case final cover?) {
      return _writeWithCover(preview, settings, target, cover);
    }
    final result = await reEnrich({
      ...buildBatchReEnrichRequest(
        item: preview.item,
        settings: settings,
        updateFields: preview.updateFields,
        resolvedMetadata: preview.enrichedMetadata,
        sourceTrackId: sourceTrackIds[preview.item.id],
      ),
      // Reviewed provider metadata must never override the staged file path.
      'file_path': target.filePath,
    });
    switch (result['method']) {
      case 'native':
        await writeSidecar(
          audioFilePath: target.filePath,
          reEnrichResult: result,
        );
        return (written: true, result: result);
      case 'ffmpeg':
        final written = await applyFfmpeg(
          item: target,
          result: result,
          artistTagMode: settings.artistTagMode,
        );
        if (!written) {
          _reEnrichLog.w('Metadata write failed for ${preview.item.id}');
        }
        return (written: written, result: result);
      default:
        _reEnrichLog.w(
          'Re-enrich failed for ${preview.item.id}: ${result['error'] ?? result['method']}',
        );
        return (written: false, result: result);
    }
  }

  /// Saves the typed values and the picked [cover] in one write, as the
  /// metadata editor does, so other tags stay as the song has them.
  Future<({bool written, Map<String, dynamic> result})> _writeWithCover(
    BatchReEnrichPreview preview,
    AppSettings settings,
    LocalLibraryItem target,
    String cover,
  ) async {
    final saved = await saveMetadata(
      MetadataSaveRequest(
        filePath: target.filePath,
        metadata: {
          for (final entry in preview.enrichedMetadata.entries)
            ?manualBatchEditorKeys[entry.key]: entry.value.toString(),
        },
        // Typed artist names are saved as entered, as in the editor.
        artistTagMode: artistTagModeForExistingTags(settings.artistTagMode),
        selectedCoverPath: cover,
        preserveUnspecifiedTags: true,
      ),
    );
    if (saved.failure == null) {
      return (
        written: true,
        result: const <String, dynamic>{'method': 'editor'},
      );
    }
    _reEnrichLog.w(
      'Cover write failed for ${preview.item.id}: ${saved.failure!.name}',
    );
    return (
      written: false,
      result: <String, dynamic>{
        'method': 'editor',
        'error': saved.error ?? saved.failure!.name,
      },
    );
  }

  Future<void> _saveMotionArtwork(
    BatchReEnrichPreview preview,
    Map<String, dynamic> result,
  ) async {
    // Listed only with the cover; a review can keep it without the cover.
    if (!preview.changes.any((change) => change.field == 'header_video')) {
      return;
    }
    final applied = result['enriched_metadata'];
    try {
      await saveMotionArtwork?.call(preview.item, {
        ...preview.enrichedMetadata,
        if (applied is Map<String, dynamic>) ...applied,
      });
    } catch (error) {
      _reEnrichLog.w(
        'Optional artwork save failed for ${preview.item.id}: $error',
      );
    }
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
  final actionContainer = ProviderScope.containerOf(context, listen: false);
  if (hasLinkLibrarySongs(actionContainer, selected)) {
    await runLinkLibraryAction(
      context,
      actionContainer,
      selected,
      LinkLibraryAction.delete,
      onAccepted: () {
        if (isActive()) onComplete();
      },
    );
    return;
  }
  final confirmed = await showAppConfirmDialog(
    context,
    title: context.l10n.dialogDeleteSelectedTitle,
    message: selected.every((item) => item.historyItem?.originFilePath != null)
        ? context.l10n.offlineRemoveMessage
        : context.l10n.dialogDeleteSelectedMessage(selected.length),
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
  final leftovers = container.read(songLeftoversProvider);
  var deletedCount = 0;
  for (final item in selected) {
    final cleanPath = DownloadedEmbeddedCoverResolver.cleanFilePath(
      item.filePath,
    );
    if (!await leftovers.delete(cleanPath)) continue;
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
