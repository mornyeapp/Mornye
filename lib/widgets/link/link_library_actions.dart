import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/controllers/metadata_editor_controller.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/unified_library_item.dart';
import 'package:mornye/services/batch_metadata_re_enrich.dart';
import 'package:mornye/services/link/features/link_library_jobs_client.dart';
import 'package:mornye/services/link/features/link_phone_client.dart';
import 'package:mornye/services/link/features/link_track_refs.dart';
import 'package:mornye/services/link/link_library_jobs.dart';
import 'package:mornye/services/link/link_client_api.dart';
import 'package:mornye/services/link/link_protocol.dart';
import 'package:mornye/theme/app_tokens.dart';
import 'package:mornye/utils/audio_conversion_utils.dart';
import 'package:mornye/widgets/app_action_button.dart';
import 'package:mornye/widgets/app_alert_dialog.dart';
import 'package:mornye/widgets/app_bottom_sheet.dart';
import 'package:mornye/widgets/app_icon.dart';
import 'package:mornye/widgets/app_progress_indicator.dart';
import 'package:mornye/widgets/app_text_field.dart';
import 'package:mornye/widgets/batch_convert_sheet.dart';
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
  void notify(String message) {
    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
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
      final preview = await controller
          .start(LinkLibraryAction.reEnrichPreview, songIds, {
            'mode': selection.mode.name,
            'fields': selection.fields,
            'manualValues': selection.manualValues,
          });
      if (!context.mounted) return;
      final completed = await _showJob(context, preview.id);
      if (completed == null ||
          completed.active ||
          completed.status == LinkLibraryJobStatus.cancelled ||
          !context.mounted) {
        return;
      }
      final previews = <BatchReEnrichPreview>[];
      final approved = <String>[];
      for (final result in completed.results) {
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
          completed.failed > 0
              ? context.l10n.linkRequestFailed(name)
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
      final read = await controller.start(
        LinkLibraryAction.readMetadata,
        songIds,
        {},
      );
      if (!context.mounted) return;
      final completed = await _showJob(context, read.id);
      if (!context.mounted ||
          completed == null ||
          completed.results.isEmpty ||
          completed.failed > 0) {
        return;
      }
      final initial = linkLibraryMap(
        completed.results.single['metadata'],
      ).map((key, value) => MapEntry(key, value.toString()));
      final metadata = await showAppScrollableBottomSheet<Map<String, String>>(
        context: context,
        title: context.l10n.linkFileActionOn(
          context.l10n.trackEditMetadata,
          name,
        ),
        builder: (context, scroll) =>
            _RemoteMetadataForm(initial: initial, scroll: scroll),
      );
      if (metadata == null || !context.mounted) return;
      options['metadata'] = metadata;
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
    if (context.mounted) await _showJob(context, job.id);
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

Future<LinkLibraryJob?> _showJob(BuildContext context, String id) =>
    showAppScrollableBottomSheet<LinkLibraryJob>(
      context: context,
      title: context.l10n.linkFileJobs,
      builder: (context, scroll) =>
          LinkLibraryJobsView(scrollController: scroll, jobId: id),
    );

Future<void> showLinkLibraryJobs(BuildContext context) =>
    showAppScrollableBottomSheet<void>(
      context: context,
      title: context.l10n.linkFileJobs,
      builder: (context, scroll) =>
          LinkLibraryJobsView(scrollController: scroll),
    );

class LinkLibraryJobsView extends ConsumerWidget {
  const LinkLibraryJobsView({super.key, this.scrollController, this.jobId});

  final ScrollController? scrollController;
  final String? jobId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(linkLibraryJobsProvider);
    final client = ref.watch(linkPhoneClientProvider);
    final connection =
        ref.watch(linkConnectionStateProvider).value ?? client?.connectionState;
    final jobs = state.jobs.reversed
        .where((job) => jobId == null || job.id == jobId)
        .toList();
    final l10n = context.l10n;
    return ListView(
      controller: scrollController,
      shrinkWrap: true,
      padding: EdgeInsets.all(context.tokens.gapMd),
      children: [
        if (client != null)
          Padding(
            padding: EdgeInsets.only(bottom: context.tokens.gapMd),
            child: Text(
              l10n.linkFileActionsDescription(linkDesktopName(client)),
            ),
          ),
        if (!state.loaded) const AppProgressIndicator.circular(),
        if (jobs.isEmpty && state.loaded)
          Text(
            state.supported
                ? l10n.linkFileJobsEmpty
                : connection == LinkConnectionState.connected
                ? l10n.linkFileJobsUnsupported
                : l10n.linkConnectionDisconnected,
          ),
        for (final job in jobs) ...[
          SettingsGroup(
            children: [
              SettingsItem(
                icon: linkLibraryActionIcon(job.action),
                title: linkLibraryActionLabel(context, job.action),
                subtitle:
                    '${job.currentTitle}\n${l10n.linkFileJobSummary(job.finished, job.total, job.failed)}',
                trailing: Text(switch (job.status) {
                  LinkLibraryJobStatus.queued => l10n.linkFileJobQueued,
                  LinkLibraryJobStatus.running => '',
                  LinkLibraryJobStatus.completed => l10n.linkFileJobCompleted,
                  LinkLibraryJobStatus.cancelled => l10n.linkFileJobCancelled,
                }),
              ),
            ],
          ),
          if (job.active) ...[
            AppProgressIndicator.linear(
              value: job.total == 0 ? null : job.finished / job.total,
            ),
            AppActionButton(
              onPressed: () => unawaited(
                ref
                    .read(linkLibraryJobsProvider.notifier)
                    .cancel(job.id)
                    .catchError((Object _) {}),
              ),
              icon: const AppIcon(Icons.stop),
              label: Text(l10n.linkFileCancelHint),
              outlined: true,
            ),
          ],
          for (final result in job.results.where(
            (result) => result['error'] != null,
          ))
            Padding(
              padding: EdgeInsets.symmetric(vertical: context.tokens.gapSm),
              child: Text(
                '${result['title']}: ${_error(context, result['error'])}',
              ),
            ),
          for (final result in job.results.where(
            (result) => result['fileName'] is String,
          ))
            Padding(
              padding: EdgeInsets.symmetric(vertical: context.tokens.gapSm),
              child: Text(
                job.action == LinkLibraryAction.saveCover
                    ? l10n.trackCoverSaved(result['fileName'] as String)
                    : l10n.trackLyricsSaved(result['fileName'] as String),
              ),
            ),
          if (jobId != null && !job.active)
            AppActionButton(
              onPressed: () => Navigator.pop(context, job),
              icon: const AppIcon(Icons.check),
              label: Text(l10n.dialogDone),
            ),
          SizedBox(height: context.tokens.gapMd),
        ],
      ],
    );
  }

  String _error(BuildContext context, Object? code) => switch (code) {
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
}

class _RemoteMetadataForm extends StatefulWidget {
  const _RemoteMetadataForm({required this.initial, required this.scroll});
  final Map<String, String> initial;
  final ScrollController scroll;

  @override
  State<_RemoteMetadataForm> createState() => _RemoteMetadataFormState();
}

class _RemoteMetadataFormState extends State<_RemoteMetadataForm> {
  late final form = MetadataEditorController(widget.initial);

  @override
  void dispose() {
    form.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final labels = {
      'title': l10n.editMetadataFieldTitle,
      'artist': l10n.editMetadataFieldArtist,
      'album': l10n.editMetadataFieldAlbum,
      'album_artist': l10n.editMetadataFieldAlbumArtist,
      'date': l10n.editMetadataFieldDate,
      'track_number': l10n.editMetadataFieldTrackNum,
      'total_tracks': l10n.editMetadataFieldTrackTotal,
      'disc_number': l10n.editMetadataFieldDiscNum,
      'total_discs': l10n.editMetadataFieldDiscTotal,
      'genre': l10n.editMetadataFieldGenre,
      'isrc': l10n.editMetadataFieldIsrc,
      'composer': l10n.editMetadataFieldComposer,
      'label': l10n.editMetadataFieldLabel,
      'copyright': l10n.editMetadataFieldCopyright,
      'comment': l10n.editMetadataFieldComment,
      'album_type': l10n.trackAlbumType,
      'upc': l10n.editMetadataFieldUpc,
      'lyrics': l10n.trackSaveLyrics,
    };
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: ListView(
        controller: widget.scroll,
        shrinkWrap: true,
        padding: EdgeInsets.all(context.tokens.gapMd),
        children: [
          for (final entry in labels.entries)
            Padding(
              padding: EdgeInsets.only(bottom: context.tokens.gapMd),
              child: AppTextField(
                controller: form[entry.key],
                label: entry.value,
                maxLines: entry.key == 'lyrics' ? 5 : 1,
              ),
            ),
          SettingsGroup(
            children: [
              SettingsSwitchItem(
                title: l10n.editMetadataFieldExplicit,
                subtitle: l10n.editMetadataFieldExplicitHint,
                value: form.explicit,
                onChanged: (value) => setState(() => form.explicit = value),
              ),
            ],
          ),
          SizedBox(height: context.tokens.gapMd),
          AppActionButton(
            onPressed: () => Navigator.pop(
              context,
              form.saveMetadata(artistTagMode: 'all')
                ..remove('artist_tag_mode'),
            ),
            icon: const AppIcon(Icons.save_outlined),
            label: Text(l10n.dialogSave),
          ),
        ],
      ),
    );
  }
}
