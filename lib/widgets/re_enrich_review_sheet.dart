import 'package:flutter/material.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/services/batch_metadata_re_enrich.dart';
import 'package:mornye/widgets/app_bottom_sheet.dart';
import 'package:mornye/widgets/app_alert_dialog.dart';
import 'package:mornye/widgets/settings_group.dart';
import 'package:mornye/widgets/app_action_button.dart';
import 'package:mornye/widgets/app_content_card.dart';
import 'package:mornye/widgets/app_loading_indicator.dart';
import 'package:mornye/widgets/re_enrich_candidate_sheet.dart';
import 'package:mornye/theme/mornye_theme.dart';

/// Results belong above the Library selection card and metadata sheets.
/// A page snackbar can be painted behind either of those surfaces.
Future<void> showReEnrichResultDialog(
  BuildContext context, {
  required String message,
}) => showAppDialog<void>(
  context: context,
  builder: (dialogContext) => AppAlertDialog(
    title: Text(dialogContext.l10n.trackReEnrich),
    content: Text(message),
    actions: [
      AppDialogAction(
        onPressed: () => Navigator.pop(dialogContext),
        child: Text(MaterialLocalizations.of(dialogContext).okButtonLabel),
      ),
    ],
  ),
);

/// Picks another result for a song in the review, returning its updated
/// preview, or null when that lookup failed.
typedef ReEnrichChoose =
    Future<BatchReEnrichPreview?> Function(
      BatchReEnrichPreview preview,
      Map<String, dynamic> candidate,
    );

/// Shows the proposed changes and returns the previews to apply, with any
/// results picked in the sheet, or null when the person backs out. With
/// [onChoose], each song whose results were listed can be matched by hand.
Future<List<BatchReEnrichPreview>?> showReEnrichReviewSheet(
  BuildContext context, {
  required List<BatchReEnrichPreview> previews,
  ReEnrichChoose? onChoose,
  String Function(String providerId)? providerName,
}) {
  final reviewable = previews.any(
    (preview) =>
        preview.changes.isNotEmpty || (onChoose != null && preview.needsChoice),
  );
  if (!reviewable) return Future.value();

  return showAppBottomSheet<List<BatchReEnrichPreview>>(
    context: context,
    useRootNavigator: true,
    title: context.l10n.trackReEnrichReviewTitle,
    maxHeightFactor: 0.9,
    dialogSize: AppDialogSize.wide,
    builder: (sheetContext) => _ReEnrichReviewContent(
      previews: previews,
      onChoose: onChoose,
      providerName: providerName ?? (providerId) => providerId,
    ),
  );
}

class _ReEnrichReviewContent extends StatefulWidget {
  final List<BatchReEnrichPreview> previews;
  final ReEnrichChoose? onChoose;
  final String Function(String providerId) providerName;

  const _ReEnrichReviewContent({
    required this.previews,
    required this.onChoose,
    required this.providerName,
  });

  @override
  State<_ReEnrichReviewContent> createState() => _ReEnrichReviewContentState();
}

class _ReEnrichReviewContentState extends State<_ReEnrichReviewContent> {
  late final List<BatchReEnrichPreview> _previews = [...widget.previews];

  /// The song whose picked result is being looked up.
  String? _choosing;

  Future<void> _choose(int index) async {
    final onChoose = widget.onChoose;
    final preview = _previews[index];
    if (onChoose == null || _choosing != null) return;
    final candidate = await showReEnrichCandidateSheet(
      context,
      candidates: preview.candidates,
      title: context.l10n.trackReEnrich,
      subtitle: [
        preview.item.trackName,
        preview.item.artistName,
      ].where((value) => value.trim().isNotEmpty).join(' · '),
      providerName: widget.providerName,
    );
    if (candidate == null || !mounted) return;
    setState(() => _choosing = preview.item.id);
    BatchReEnrichPreview? picked;
    try {
      picked = await onChoose(preview, candidate);
    } finally {
      if (mounted) {
        setState(() {
          _choosing = null;
          if (picked != null) _previews[index] = picked;
        });
      }
    }
  }

  /// The row that matches a song by hand, naming the result in use.
  Widget? _matchRow(BuildContext context, int index) {
    final preview = _previews[index];
    if (widget.onChoose == null || preview.candidates.isEmpty) return null;
    final current =
        preview.chosen ??
        (preview.needsChoice ? null : preview.candidates.first);
    final busy = _choosing == preview.item.id;
    return ListTile(
      leading: Icon(
        preview.needsChoice ? Icons.manage_search : Icons.swap_horiz,
      ),
      title: Text(
        preview.needsChoice
            ? context.l10n.reEnrichChooseMatch
            : context.l10n.reEnrichChangeMatch,
      ),
      subtitle: Text(
        current == null
            ? context.l10n.reEnrichChooseMatchSubtitle
            : [
                (current['name'] ?? '').toString().trim(),
                reEnrichCandidateSource(context, current, widget.providerName),
              ].where((part) => part.isNotEmpty).join(' · '),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: busy
          ? const AppLoadingIndicator(size: 24)
          : const Icon(Icons.chevron_right),
      onTap: _choosing == null ? () => _choose(index) : null,
    );
  }

  String _fieldLabel(BuildContext context, String field) {
    switch (field) {
      case 'track_name':
        return context.l10n.editMetadataFieldTitle;
      case 'artist_name':
        return context.l10n.editMetadataFieldArtist;
      case 'album_name':
        return context.l10n.editMetadataFieldAlbum;
      case 'album_artist':
        return context.l10n.editMetadataFieldAlbumArtist;
      case 'track_number':
        return context.l10n.editMetadataFieldTrackNum;
      case 'total_tracks':
        return context.l10n.editMetadataFieldTrackTotal;
      case 'disc_number':
        return context.l10n.editMetadataFieldDiscNum;
      case 'total_discs':
        return context.l10n.editMetadataFieldDiscTotal;
      case 'release_date':
        return context.l10n.editMetadataFieldDate;
      case 'isrc':
        return context.l10n.editMetadataFieldIsrc;
      case 'genre':
        return context.l10n.editMetadataFieldGenre;
      case 'composer':
        return context.l10n.editMetadataFieldComposer;
      case 'label':
        return context.l10n.editMetadataFieldLabel;
      case 'copyright':
        return context.l10n.editMetadataFieldCopyright;
      case 'cover_url':
        return context.l10n.editMetadataFieldCover;
      case 'header_video':
        return context.l10n.motionArtwork;
      case 'lyrics':
        return context.l10n.trackReEnrichFieldLyrics;
      default:
        return field;
    }
  }

  String _oldValue(BuildContext context, ReEnrichMetadataChange change) {
    if (change.field == 'cover_url' && change.oldValue.isNotEmpty) {
      return context.l10n.trackCoverCurrent;
    }
    return change.oldValue.isEmpty ? '-' : change.oldValue;
  }

  String _newValue(BuildContext context, ReEnrichMetadataChange change) {
    if (change.field == 'cover_url') {
      return context.l10n.editMetadataAutoFillCoverAvailable;
    }
    if (change.newValue == '__refresh_online__') {
      return context.l10n.trackReEnrichRefreshOnline;
    }
    return change.newValue;
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final visible = [
      for (var index = 0; index < _previews.length; index++)
        if (_previews[index].changes.isNotEmpty ||
            (widget.onChoose != null && _previews[index].needsChoice))
          index,
    ];
    final changeCount = _previews.fold<int>(
      0,
      (total, preview) => total + preview.changes.length,
    );
    final songCount = _previews
        .where((preview) => preview.changes.isNotEmpty)
        .length;

    return SafeArea(
      top: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // In the content rather than the sheet subtitle, so the counts
          // follow the results picked here.
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
            child: Align(
              alignment: AlignmentDirectional.centerStart,
              child: Text(
                context.l10n.trackReEnrichReviewSubtitle(
                  changeCount,
                  songCount,
                ),
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
          Flexible(
            child: ListView.builder(
              shrinkWrap: visible.length <= 12,
              padding: const EdgeInsets.only(bottom: 8),
              itemCount: visible.length,
              itemBuilder: (context, index) {
                final preview = _previews[visible[index]];
                final matchRow = _matchRow(context, visible[index]);
                final children = <Widget>[
                  ListTile(
                    leading: const Icon(Icons.audio_file_outlined),
                    title: Text(
                      preview.item.trackName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      preview.item.artistName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (matchRow != null) ...[
                    const Divider(height: 1, indent: 56),
                    matchRow,
                  ],
                  for (final change in preview.changes) ...[
                    const Divider(height: 1, indent: 56),
                    // Full width: a connected group centers rows narrower
                    // than itself.
                    Semantics(
                      label:
                          '${_fieldLabel(context, change.field)}: ${_oldValue(context, change)}, ${_newValue(context, change)}',
                      child: Container(
                        width: double.infinity,
                        padding: const EdgeInsetsDirectional.fromSTEB(
                          56,
                          10,
                          16,
                          10,
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              _fieldLabel(context, change.field),
                              style: Theme.of(context).textTheme.labelMedium
                                  ?.copyWith(
                                    color: colorScheme.onSurfaceVariant,
                                  ),
                            ),
                            const SizedBox(height: 3),
                            Text.rich(
                              TextSpan(
                                children: [
                                  TextSpan(
                                    text: _oldValue(context, change),
                                    style: TextStyle(
                                      color: colorScheme.onSurfaceVariant,
                                    ),
                                  ),
                                  TextSpan(
                                    text: '  →  ',
                                    style: TextStyle(
                                      color: colorScheme.primary,
                                    ),
                                  ),
                                  TextSpan(
                                    text: _newValue(context, change),
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ];
                return context.isMornye
                    ? Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 4,
                        ),
                        child: AppContentCard(
                          child: Column(children: children),
                        ),
                      )
                    : SettingsGroup(
                        connected: true,
                        children: [
                          for (final child in children)
                            if (child is! Divider) child,
                        ],
                      );
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            child: SizedBox(
              width: double.infinity,
              child: AppActionButton(
                onPressed: changeCount == 0 || _choosing != null
                    ? null
                    : () => Navigator.pop(context, _previews),
                icon: const Icon(Icons.save_outlined),
                label: Text(context.l10n.trackReEnrichApplyChanges),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
