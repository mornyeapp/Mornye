import 'package:flutter/material.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/services/batch_metadata_re_enrich.dart';
import 'package:mornye/widgets/app_bottom_sheet.dart';
import 'package:mornye/widgets/app_alert_dialog.dart';
import 'package:mornye/widgets/settings_group.dart';
import 'package:mornye/widgets/app_action_button.dart';
import 'package:mornye/widgets/app_content_card.dart';
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

Future<bool> showReEnrichReviewSheet(
  BuildContext context, {
  required List<BatchReEnrichPreview> previews,
}) async {
  final changeCount = previews.fold<int>(
    0,
    (total, preview) => total + preview.changes.length,
  );
  if (changeCount == 0) return false;

  final confirmed = await showAppBottomSheet<bool>(
    context: context,
    useRootNavigator: true,
    title: context.l10n.trackReEnrichReviewTitle,
    subtitle: context.l10n.trackReEnrichReviewSubtitle(
      changeCount,
      previews.length,
    ),
    maxHeightFactor: 0.9,
    dialogSize: AppDialogSize.wide,
    builder: (sheetContext) => _ReEnrichReviewContent(previews: previews),
  );
  return confirmed == true;
}

class _ReEnrichReviewContent extends StatelessWidget {
  final List<BatchReEnrichPreview> previews;

  const _ReEnrichReviewContent({required this.previews});

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
    final visible = previews
        .where((preview) => preview.changes.isNotEmpty)
        .toList(growable: false);

    return SafeArea(
      top: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: ListView.builder(
              shrinkWrap: true,
              padding: const EdgeInsets.only(bottom: 8),
              itemCount: visible.length,
              itemBuilder: (context, index) {
                final preview = visible[index];
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
                onPressed: () => Navigator.pop(context, true),
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
