import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/unified_library_item.dart';
import 'package:mornye/screens/track_metadata_edit_sheet.dart';
import 'package:mornye/services/batch_metadata_re_enrich.dart';
import 'package:mornye/services/link/features/link_library_jobs_client.dart';
import 'package:mornye/services/link/features/link_phone_client.dart';
import 'package:mornye/services/link/features/link_track_refs.dart';
import 'package:mornye/services/link/link_library_jobs.dart';
import 'package:mornye/services/link/link_client_api.dart';
import 'package:mornye/services/link/link_protocol.dart';
import 'package:mornye/theme/app_tokens.dart';
import 'package:mornye/utils/audio_conversion_utils.dart';
import 'package:mornye/widgets/app_alert_dialog.dart';
import 'package:mornye/widgets/app_bottom_sheet.dart';
import 'package:mornye/widgets/app_icon.dart';
import 'package:mornye/widgets/app_icon_button.dart';
import 'package:mornye/widgets/app_loading_indicator.dart';
import 'package:mornye/widgets/app_progress_indicator.dart';
import 'package:mornye/widgets/batch_convert_sheet.dart';
import 'package:mornye/widgets/batch_progress_dialog.dart';
import 'package:mornye/widgets/error_card.dart';
import 'package:mornye/widgets/re_enrich_field_dialog.dart';
import 'package:mornye/widgets/re_enrich_review_sheet.dart';
import 'package:mornye/widgets/settings_group.dart';

String linkLibraryActionLabel(BuildContext context, LinkLibraryAction action) =>
    switch (action) {
      LinkLibraryAction.delete => context.l10n.trackMetadataDelete,
      LinkLibraryAction.readMetadata => context.l10n.desktopMenuShowDetails,
      LinkLibraryAction.editMetadata => context.l10n.trackEditMetadata,
      LinkLibraryAction.reEnrichPreview => context.l10n.trackReEnrichSearching,
      LinkLibraryAction.reEnrich => context.l10n.trackReEnrich,
      LinkLibraryAction.convert => context.l10n.trackConvertFormat,
      LinkLibraryAction.replayGain => context.l10n.trackReplayGain,
      LinkLibraryAction.removeReplayGain => context.l10n.trackRemoveReplayGain,
      LinkLibraryAction.saveCover => context.l10n.trackSaveCoverArt,
      LinkLibraryAction.saveLyrics => context.l10n.trackSaveLyrics,
    };

IconData linkLibraryActionIcon(LinkLibraryAction action) => switch (action) {
  LinkLibraryAction.delete => Icons.delete_outline,
  LinkLibraryAction.readMetadata ||
  LinkLibraryAction.editMetadata => Icons.edit_outlined,
  LinkLibraryAction.reEnrichPreview ||
  LinkLibraryAction.reEnrich => Icons.travel_explore,
  LinkLibraryAction.convert => Icons.swap_horiz,
  LinkLibraryAction.replayGain => Icons.graphic_eq,
  LinkLibraryAction.removeReplayGain => Icons.remove_circle_outline,
  LinkLibraryAction.saveCover => Icons.image_outlined,
  LinkLibraryAction.saveLyrics => Icons.lyrics_outlined,
};

bool hasLinkLibrarySongs(
  ProviderContainer container,
  List<UnifiedLibraryItem> items,
) {
  final client = container.read(linkPhoneClientProvider);
  return client != null &&
      items.any(
        (item) => linkDesktopSongId(item.filePath, client.server) != null,
      );
}

/// Runs [action] on the linked computer's copies of [items] the way the
/// same action runs on this phone's files: the same sheets and confirmation,
/// the batch progress dialog while it works, then a snackbar with the
/// result.
Future<void> runLinkLibraryAction(
  BuildContext context,
  ProviderContainer container,
  List<UnifiedLibraryItem> items,
  LinkLibraryAction action, {
  VoidCallback? onAccepted,
}) async {
  context = Navigator.of(context, rootNavigator: true).context;
  final client = container.read(linkPhoneClientProvider);
  if (client == null || items.isEmpty) return;
  final ids = [
    for (final item in items) linkDesktopSongId(item.filePath, client.server),
  ];
  void notify(String message, {SnackBarAction? action}) {
    if (context.mounted) {
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(SnackBar(content: Text(message), action: action));
    }
  }

  if (items.length > 100 || ids.contains(null)) {
    notify(context.l10n.linkFileSelectionOneDevice);
    return;
  }
  final name = linkDesktopName(client);
  final controller = container.read(linkLibraryJobsProvider.notifier);
  final songIds = ids.cast<String>();
  final options = <String, dynamic>{};
  var manualReEnrich = false;
  Future<LinkLibraryJob?> follow(LinkLibraryJob job) => _followJob(
    context,
    container,
    job,
    title: _progressTitle(context, job.action, manual: manualReEnrich),
    icon: _progressIcon(job.action, manual: manualReEnrich),
    onLost: () => notify(context.l10n.linkFileActionsDescription(name)),
  );

  try {
    if (action == LinkLibraryAction.convert) {
      final formats = audioConversionTargetFormats
          .where(
            (target) => items.any((item) {
              final source = convertibleAudioSourceFormat(
                storedFormat:
                    item.localItem?.format ?? item.historyItem?.format,
                filePath: item.filePath,
              );
              return source != null &&
                  canConvertAudioFormat(
                    sourceFormat: source,
                    targetFormat: target,
                  );
            }),
          )
          .toList();
      if (formats.isEmpty) {
        notify(context.l10n.trackConvertFailed);
        return;
      }
      final chosen = await showAppModalBottomSheet<Map<String, dynamic>>(
        context: context,
        useRootNavigator: true,
        isScrollControlled: true,
        mornyeGlass: false,
        builder: (sheetContext) => BatchConvertSheet(
          formats: formats,
          title: context.l10n.linkFileActionOn(
            context.l10n.trackConvertFormat,
            name,
          ),
          confirmLabel: context.l10n.selectionConvertCount(items.length),
          sourceBitDepth: lowestKnownPositiveInt(
            items.map(
              (item) => item.localItem?.bitDepth ?? item.historyItem?.bitDepth,
            ),
          ),
          sourceSampleRate: lowestKnownPositiveInt(
            items.map(
              (item) =>
                  item.localItem?.sampleRate ?? item.historyItem?.sampleRate,
            ),
          ),
          onConvert: (format, bitrate, quality, processing, keepOriginal) =>
              Navigator.pop(sheetContext, {
                'format': format,
                'bitrate': bitrate,
                'keepOriginal': keepOriginal,
                'maxBitDepth': quality.maxBitDepth,
                'maxSampleRate': quality.maxSampleRate,
                'dither': processing.dither,
                'resampler': processing.resampler,
              }),
        ),
      );
      if (chosen == null || !context.mounted) return;
      options.addAll(chosen);
      final format = chosen['format'] as String;
      final kept = chosen['keepOriginal'] == true;
      final message = kept
          ? context.l10n.selectionBatchConvertConfirmKeepOriginal(
              items.length,
              format,
            )
          : isLosslessConversionTarget(format)
          ? context.l10n.selectionBatchConvertConfirmMessageLossless(
              items.length,
              format,
            )
          : context.l10n.selectionBatchConvertConfirmMessage(
              items.length,
              format,
              chosen['bitrate'] as String,
            );
      if (!await showAppConfirmDialog(
            context,
            title: context.l10n.linkFileActionOn(
              context.l10n.trackConvertFormat,
              name,
            ),
            message: message,
            confirmLabel: context.l10n.trackConvertFormat,
          ) ||
          !context.mounted) {
        return;
      }
    } else if (action == LinkLibraryAction.reEnrich) {
      final selection = await showReEnrichFieldDialog(
        context,
        selectedCount: items.length,
      );
      if (selection == null || !context.mounted) return;
      manualReEnrich = selection.usesManualValues;
      final preview = await follow(
        await controller.start(LinkLibraryAction.reEnrichPreview, songIds, {
          'mode': selection.mode.name,
          'fields': selection.fields,
          'manualValues': selection.manualValues,
        }),
      );
      if (preview == null ||
          preview.status == LinkLibraryJobStatus.cancelled ||
          !context.mounted) {
        return;
      }
      final previews = <BatchReEnrichPreview>[];
      final approved = <String>[];
      for (final result in preview.results) {
        final changes = result['changes'];
        final at = songIds.indexOf(result['songId'] as String);
        if (at < 0 || changes is! List || changes.isEmpty) continue;
        final item = items[at].localItem;
        if (item == null) continue;
        approved.add(songIds[at]);
        previews.add(
          BatchReEnrichPreview(
            item: item,
            updateFields: const [],
            enrichedMetadata: const {},
            changes: [
              for (final raw in changes)
                ReEnrichMetadataChange(
                  field: (raw as Map)['field'] as String,
                  oldValue: raw['oldValue'] as String,
                  newValue: raw['newValue'] as String,
                ),
            ],
          ),
        );
      }
      if (previews.isEmpty) {
        notify(
          preview.failed > 0
              ? _resultError(context, preview.results.first['error'])
              : context.l10n.trackReEnrichNoChanges,
        );
        return;
      }
      if (!await showReEnrichReviewSheet(context, previews: previews) ||
          !context.mounted) {
        return;
      }
      songIds
        ..clear()
        ..addAll(approved);
      options['previewJobId'] = preview.id;
    } else if (action == LinkLibraryAction.editMetadata) {
      if (items.length != 1) {
        notify(context.l10n.linkFileSelectionOneDevice);
        return;
      }
      final read = await follow(
        await controller.start(LinkLibraryAction.readMetadata, songIds, {}),
      );
      if (read == null || read.results.isEmpty || !context.mounted) return;
      if (read.failed > 0) {
        notify(_resultError(context, read.results.single['error']));
        return;
      }
      final initial = linkLibraryMap(
        read.results.single['metadata'],
      ).map((key, value) => MapEntry(key, value.toString()));
      final saved = await showAppModalBottomSheet<bool>(
        context: context,
        useRootNavigator: true,
        isScrollControlled: true,
        dialogSize: AppDialogSize.wide,
        builder: (sheetContext) => EditMetadataSheet(
          colorScheme: Theme.of(sheetContext).colorScheme,
          initialValues: initial,
          filePath: items.single.filePath,
          durationMs: (items.single.localItem?.duration ?? 0) * 1000,
          artistTagMode: 'all',
          saveTags: (metadata) async {
            final l10n = sheetContext.l10n;
            // A pairing change while editing must not redirect the save.
            if (container.read(linkPhoneClientProvider) != client) {
              return l10n.linkRequestFailed(name);
            }
            try {
              final job = await controller.start(
                LinkLibraryAction.editMetadata,
                songIds,
                {'metadata': metadata},
              );
              onAccepted?.call();
              final done = await _awaitJob(container, job.id);
              if (done == null) return l10n.linkRequestFailed(name);
              return done.failed > 0
                  ? (sheetContext.mounted
                        ? _resultError(
                            sheetContext,
                            done.results.first['error'],
                          )
                        : '')
                  : null;
            } on Object {
              return l10n.linkRequestFailed(name);
            }
          },
        ),
      );
      if (saved == true && context.mounted) {
        notify(context.l10n.snackbarMetadataSaved);
      }
      return;
    } else {
      final confirmed = await showAppConfirmDialog(
        context,
        title: context.l10n.linkFileActionOn(
          linkLibraryActionLabel(context, action),
          name,
        ),
        message: action == LinkLibraryAction.delete
            ? context.l10n.linkFileDeleteConfirm(items.length, name)
            : context.l10n.linkFileActionsDescription(name),
        confirmLabel: linkLibraryActionLabel(context, action),
        destructive: action == LinkLibraryAction.delete,
        cancelIsDefault: action == LinkLibraryAction.delete,
      );
      if (!confirmed || !context.mounted) return;
    }
    // A pairing change while a sheet was open must not redirect the operation.
    if (container.read(linkPhoneClientProvider) != client) return;
    final job = await controller.start(action, songIds, options);
    onAccepted?.call();
    if (!context.mounted) return;
    final finished = await follow(job);
    if (finished == null || !context.mounted) return;
    notify(
      _finishedMessage(context, finished, name, options),
      action: finished.failed > 0 && finished.total > 1
          ? SnackBarAction(
              label: context.l10n.linkFileJobsView,
              onPressed: () => unawaited(showLinkLibraryJobs(context)),
            )
          : null,
    );
  } on LinkException catch (error) {
    if (context.mounted) {
      notify(
        error.code == 'not_found'
            ? context.l10n.linkFileJobsUnsupported
            : context.l10n.linkRequestFailed(name),
      );
    }
  } on Object {
    if (context.mounted) notify(context.l10n.linkRequestFailed(name));
  }
}

/// The finished job [id], or null when it is [stop]ped or the phone loses
/// the computer first (the work goes on there). [onProgress] sees every
/// update before that.
Future<LinkLibraryJob?> _awaitJob(
  ProviderContainer container,
  String id, {
  void Function(LinkLibraryJob job)? onProgress,
  Future<void>? stop,
}) {
  final done = Completer<LinkLibraryJob?>();
  final jobs = container.listen(
    linkLibraryJobsProvider.select(
      (state) => state.jobs.where((job) => job.id == id).firstOrNull,
    ),
    (_, job) {
      if (job == null || done.isCompleted) return;
      onProgress?.call(job);
      if (!job.active) done.complete(job);
    },
    fireImmediately: true,
  );
  final connection = container.listen(linkConnectionStateProvider, (_, next) {
    if (next.value == LinkConnectionState.disconnected && !done.isCompleted) {
      done.complete(null);
    }
  });
  unawaited(
    stop?.then((_) {
      if (!done.isCompleted) done.complete(null);
    }),
  );
  return done.future.whenComplete(() {
    jobs.close();
    connection.close();
  });
}

/// Shows [job] in the batch progress dialog local batches use until it
/// ends. Cancel stops the computer after the current song. [onLost] runs
/// when the phone loses the computer while it still works.
Future<LinkLibraryJob?> _followJob(
  BuildContext context,
  ProviderContainer container,
  LinkLibraryJob job, {
  required String title,
  required IconData icon,
  required VoidCallback onLost,
}) async {
  final stopped = Completer<void>();
  var open = true;
  BatchProgressDialog.show(
    context: context,
    title: title,
    total: job.total,
    icon: icon,
    onCancel: () {
      unawaited(
        container
            .read(linkLibraryJobsProvider.notifier)
            .cancel(job.id)
            .catchError((Object _) {}),
      );
      open = false;
      BatchProgressDialog.dismiss(context);
      if (!stopped.isCompleted) stopped.complete();
    },
  );
  final finished = await _awaitJob(
    container,
    job.id,
    stop: stopped.future,
    onProgress: (job) => BatchProgressDialog.update(
      current: math.min(job.finished + 1, job.total),
      detail: job.currentTitle,
    ),
  );
  if (open && context.mounted) BatchProgressDialog.dismiss(context);
  if (finished == null && !stopped.isCompleted) onLost();
  return finished;
}

String _progressTitle(
  BuildContext context,
  LinkLibraryAction action, {
  required bool manual,
}) => switch (action) {
  LinkLibraryAction.delete => context.l10n.linkFileDeleting,
  LinkLibraryAction.readMetadata => context.l10n.linkFileReading,
  LinkLibraryAction.reEnrichPreview =>
    manual
        ? context.l10n.trackReEnrichPreparing
        : context.l10n.trackReEnrichSearching,
  LinkLibraryAction.reEnrich => context.l10n.trackReEnrichProgress,
  LinkLibraryAction.convert => context.l10n.trackConvertConverting,
  LinkLibraryAction.replayGain => context.l10n.replayGainBatchAnalyzing,
  LinkLibraryAction.removeReplayGain => context.l10n.replayGainRemoving,
  LinkLibraryAction.editMetadata => context.l10n.linkFileReading,
  LinkLibraryAction.saveCover => context.l10n.linkFileSavingCover,
  LinkLibraryAction.saveLyrics => context.l10n.trackSaveLyricsProgress,
};

IconData _progressIcon(LinkLibraryAction action, {required bool manual}) =>
    switch (action) {
      LinkLibraryAction.reEnrichPreview =>
        manual ? Icons.edit_note : Icons.manage_search,
      LinkLibraryAction.reEnrich => Icons.auto_fix_high,
      LinkLibraryAction.convert => Icons.transform,
      LinkLibraryAction.readMetadata => Icons.info_outline,
      _ => linkLibraryActionIcon(action),
    };

/// What the snackbar says once [job] ends, in the words of the same action
/// on this phone's files.
String _finishedMessage(
  BuildContext context,
  LinkLibraryJob job,
  String name,
  Map<String, dynamic> options,
) {
  final l10n = context.l10n;
  if (job.total == 1 && job.failed == 1) {
    return _resultError(context, job.results.single['error']);
  }
  final ok = job.succeeded;
  final total = job.total;
  final fileName = job.results.length == 1
      ? job.results.single['fileName']
      : null;
  final message = switch (job.action) {
    LinkLibraryAction.delete => l10n.snackbarDeletedTracks(ok),
    LinkLibraryAction.reEnrich =>
      job.failed > 0
          ? l10n.trackReEnrichSuccessWithFailures(ok, total, job.failed)
          : l10n.trackReEnrichSuccess,
    LinkLibraryAction.convert => l10n.selectionBatchConvertSuccess(
      ok,
      total,
      options['format'] as String? ?? '',
    ),
    LinkLibraryAction.replayGain => l10n.replayGainBatchSuccess(ok, total),
    LinkLibraryAction.removeReplayGain => l10n.replayGainRemoveBatchSuccess(
      ok,
      total,
    ),
    LinkLibraryAction.saveCover when fileName is String => l10n.trackCoverSaved(
      fileName,
    ),
    LinkLibraryAction.saveLyrics when fileName is String =>
      l10n.trackLyricsSaved(fileName),
    _ => l10n.linkFileJobFinished(
      linkLibraryActionLabel(context, job.action),
      name,
    ),
  };
  final counted =
      job.action == LinkLibraryAction.reEnrich ||
      job.action == LinkLibraryAction.convert ||
      job.action == LinkLibraryAction.replayGain ||
      job.action == LinkLibraryAction.removeReplayGain;
  return job.failed > 0 && !counted
      ? '$message. ${l10n.linkFileJobFailedCount(job.failed)}'
      : message;
}

String _resultError(BuildContext context, Object? code) => switch (code) {
  'file_changed' || 'preview_expired' => context.l10n.linkFileChanged,
  'not_found' => context.l10n.trackFileNotFound,
  'read_failed' => context.l10n.trackFileUnavailable,
  'delete_failed' => context.l10n.snackbarDeleteTracksFailed(1),
  'cover_missing' => context.l10n.trackCoverNoEmbeddedArt,
  'lyrics_missing' => context.l10n.trackLyricsNotAvailable,
  'conversion_failed' ||
  'unsupported_format' => context.l10n.trackConvertFailed,
  'replaygain_failed' => context.l10n.trackReplayGainFailed,
  _ => context.l10n.linkFileOperationFailed,
};

Future<void> showLinkLibraryJobs(BuildContext context) =>
    showAppScrollableBottomSheet<void>(
      context: context,
      title: context.l10n.linkFileJobs,
      builder: (context, scroll) =>
          LinkLibraryJobsView(scrollController: scroll),
    );

/// The file changes started from this phone on the linked computer, newest
/// first, in one grouped list. Running changes show their progress and a
/// stop button; finished ones list the songs that failed.
class LinkLibraryJobsView extends ConsumerWidget {
  const LinkLibraryJobsView({super.key, this.scrollController});

  final ScrollController? scrollController;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(linkLibraryJobsProvider);
    final client = ref.watch(linkPhoneClientProvider);
    final connection =
        ref.watch(linkConnectionStateProvider).value ?? client?.connectionState;
    // Reading tags and previewing a re-enrich are steps of another change.
    final jobs = state.jobs.reversed
        .where(
          (job) =>
              job.action != LinkLibraryAction.readMetadata &&
              job.action != LinkLibraryAction.reEnrichPreview,
        )
        .toList();
    final l10n = context.l10n;
    final tokens = context.tokens;
    final theme = Theme.of(context);
    return ListView(
      controller: scrollController,
      shrinkWrap: true,
      padding: EdgeInsets.fromLTRB(tokens.gapMd, 0, tokens.gapMd, tokens.gapLg),
      children: [
        if (!state.loaded)
          Padding(
            padding: EdgeInsets.all(tokens.gapXl),
            child: const Center(child: AppLoadingIndicator()),
          )
        else if (jobs.isEmpty)
          state.supported
              ? EmptyState(
                  icon: Icons.history,
                  title: l10n.linkFileJobsEmpty,
                  message: l10n.linkFileJobsEmptyMessage,
                )
              : connection == LinkConnectionState.connected
              ? EmptyState(
                  icon: Icons.system_update_alt,
                  title: l10n.linkFileJobs,
                  message: l10n.linkFileJobsUnsupported,
                )
              : EmptyState(
                  icon: Icons.link_off,
                  title: l10n.linkConnectionDisconnected,
                )
        else ...[
          if (client != null)
            Padding(
              padding: EdgeInsetsDirectional.fromSTEB(
                tokens.gapSm,
                0,
                tokens.gapSm,
                tokens.gapMd,
              ),
              child: Text(
                l10n.linkFileActionsDescription(linkDesktopName(client)),
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          SettingsGroup(
            children: [
              for (final (i, job) in jobs.indexed)
                _JobRow(job: job, showDivider: i < jobs.length - 1),
            ],
          ),
        ],
      ],
    );
  }
}

class _JobRow extends ConsumerWidget {
  const _JobRow({required this.job, required this.showDivider});

  final LinkLibraryJob job;
  final bool showDivider;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final tokens = context.tokens;
    final progress = l10n.linkFileJobProgress(job.finished, job.total);
    final failures = [
      for (final result in job.results)
        if (result['error'] != null)
          '${result['title']}: ${_resultError(context, result['error'])}',
    ];
    final saved = [
      if (job.action == LinkLibraryAction.saveCover ||
          job.action == LinkLibraryAction.saveLyrics)
        for (final result in job.results)
          if (result['fileName'] case final String fileName)
            job.action == LinkLibraryAction.saveCover
                ? l10n.trackCoverSaved(fileName)
                : l10n.trackLyricsSaved(fileName),
    ];
    final detailStyle = theme.textTheme.bodySmall;
    return SettingsItem(
      icon: linkLibraryActionIcon(job.action),
      title: linkLibraryActionLabel(context, job.action),
      subtitle: [
        if (job.status == LinkLibraryJobStatus.queued)
          l10n.linkFileJobQueued
        else if (job.active && job.currentTitle.isNotEmpty)
          job.currentTitle,
        progress,
        if (job.failed > 0) l10n.linkFileJobFailedCount(job.failed),
      ].join(' · '),
      showDivider: showDivider,
      trailing: job.active
          ? AppIconButton(
              icon: const AppIcon.adaptive(Icons.stop_circle_outlined),
              tooltip: l10n.linkFileCancelHint,
              onPressed: () => unawaited(
                ref
                    .read(linkLibraryJobsProvider.notifier)
                    .cancel(job.id)
                    .catchError((Object _) {}),
              ),
            )
          : Text(
              switch (job.status) {
                LinkLibraryJobStatus.cancelled => l10n.linkFileJobCancelled,
                _ => l10n.linkFileJobCompleted,
              },
              style: theme.textTheme.labelLarge?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
      footer: job.active
          ? Padding(
              padding: EdgeInsets.only(top: tokens.gapSm),
              child: AppProgressIndicator.linear(
                value:
                    job.total == 0 || job.status == LinkLibraryJobStatus.queued
                    ? null
                    : job.finished / job.total,
              ),
            )
          : failures.isEmpty && saved.isEmpty
          ? null
          : Padding(
              padding: EdgeInsets.only(top: tokens.gapXs),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final line in failures)
                    Text(
                      line,
                      style: detailStyle?.copyWith(color: colorScheme.error),
                    ),
                  for (final line in saved)
                    Text(
                      line,
                      style: detailStyle?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                ],
              ),
            ),
    );
  }
}
