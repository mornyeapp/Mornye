import 'dart:async';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/services/batch_metadata_re_enrich.dart';
import 'package:mornye/services/metadata_cover_resources.dart';
import 'package:mornye/theme/app_tokens.dart';
import 'package:mornye/theme/mornye_icons.dart' show mornyeArrowForward;
import 'package:mornye/utils/desktop_platform.dart';
import 'package:mornye/widgets/app_bottom_sheet.dart';
import 'package:mornye/widgets/app_alert_dialog.dart';
import 'package:mornye/widgets/app_icon.dart';
import 'package:mornye/widgets/app_switch.dart';
import 'package:mornye/widgets/cached_cover_image.dart';
import 'package:mornye/widgets/expressive_button.dart';
import 'package:mornye/widgets/settings_group.dart';
import 'package:mornye/widgets/app_action_button.dart';
import 'package:mornye/widgets/app_content_card.dart';
import 'package:mornye/widgets/app_loading_indicator.dart';
import 'package:mornye/widgets/re_enrich_candidate_sheet.dart';
import 'package:mornye/theme/mornye_theme.dart';

/// Results belong above the Library selection card and metadata sheets.
/// A page snackbar can be painted behind either of those surfaces. With
/// [undoLabel], the dialog offers to undo what it reports and completes
/// with true when that is chosen.
Future<bool> showReEnrichResultDialog(
  BuildContext context, {
  required String message,
  String? undoLabel,
}) async =>
    await showAppDialog<bool>(
      context: context,
      builder: (dialogContext) => AppAlertDialog(
        title: Text(dialogContext.l10n.trackReEnrich),
        content: Text(message),
        actions: [
          if (undoLabel != null)
            AppDialogAction(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: Text(undoLabel),
            ),
          AppDialogAction(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(MaterialLocalizations.of(dialogContext).okButtonLabel),
          ),
        ],
      ),
    ) ==
    true;

/// A song's current cover and the one its result would embed, as local
/// files with their sizes when those could be read.
class ReEnrichReviewCovers {
  const ReEnrichReviewCovers({this.current, this.proposed});

  final MetadataCoverPreview? current;
  final MetadataCoverPreview? proposed;
}

typedef ReEnrichCoverLoader =
    Future<ReEnrichReviewCovers?> Function(BatchReEnrichPreview preview);

/// Reads the cover the song has and downloads the one its result proposes,
/// scaled to [maxDimension] as it would be embedded. The files belong to
/// [covers].
Future<ReEnrichReviewCovers?> loadReEnrichReviewCovers(
  MetadataCoverResources covers,
  BatchReEnrichPreview preview, {
  int maxDimension = 0,
}) async {
  final change = preview.changes
      .where((change) => change.field == 'cover_url')
      .firstOrNull;
  if (change == null) return null;
  final file = preview.coverFile;
  final (current, proposed) = await (
    covers.extract(preview.item.filePath),
    // A picked image is embedded as it is; the caller owns its file.
    file != null
        ? covers
              .readDetails(file)
              .then(
                (details) => MetadataCoverPreview(
                  path: file,
                  tempDir: '',
                  details: details,
                ),
              )
        : covers.download(change.newValue, maxDimension: maxDimension),
  ).wait;
  return ReEnrichReviewCovers(current: current, proposed: proposed);
}

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
///
/// With [chooseFields], meant for one song, each change has its own switch
/// and the previews come back with only the changes left on. Likely
/// downgrades start off: a cover smaller than the current one, compared
/// through [loadCovers], and an empty value over one the song has.
Future<List<BatchReEnrichPreview>?> showReEnrichReviewSheet(
  BuildContext context, {
  required List<BatchReEnrichPreview> previews,
  ReEnrichChoose? onChoose,
  String Function(String providerId)? providerName,
  bool chooseFields = false,
  ReEnrichCoverLoader? loadCovers,
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
      chooseFields: chooseFields,
      loadCovers: chooseFields ? loadCovers : null,
    ),
  );
}

class _ReEnrichReviewContent extends StatefulWidget {
  final List<BatchReEnrichPreview> previews;
  final ReEnrichChoose? onChoose;
  final String Function(String providerId) providerName;
  final bool chooseFields;
  final ReEnrichCoverLoader? loadCovers;

  const _ReEnrichReviewContent({
    required this.previews,
    required this.onChoose,
    required this.providerName,
    required this.chooseFields,
    required this.loadCovers,
  });

  @override
  State<_ReEnrichReviewContent> createState() => _ReEnrichReviewContentState();
}

class _ReEnrichReviewContentState extends State<_ReEnrichReviewContent> {
  late final List<BatchReEnrichPreview> _previews = [...widget.previews];

  /// The song whose picked result is being looked up.
  String? _choosing;

  /// The changes switched on for each song, when changes are chosen one by
  /// one.
  final Map<String, Set<String>> _selected = {};
  final Map<String, ReEnrichReviewCovers> _covers = {};

  /// The cover comparison loading for each song; a newer pick replaces it.
  final Map<String, Object> _coverLoads = {};

  @override
  void initState() {
    super.initState();
    if (widget.chooseFields) _previews.forEach(_prepare);
  }

  /// Switches [preview]'s changes to their defaults, then compares its
  /// covers, which can turn the cover change off.
  void _prepare(BatchReEnrichPreview preview) {
    final id = preview.item.id;
    _covers.remove(id);
    _coverLoads.remove(id);
    _selected[id] = {
      for (final change in preview.changes)
        if (!_downgrade(preview, change)) change.field,
    };
    final load = widget.loadCovers;
    final cover = preview.changes
        .where((change) => change.field == 'cover_url')
        .firstOrNull;
    if (load == null || cover == null) return;
    final token = Object();
    _coverLoads[id] = token;
    unawaited(() async {
      ReEnrichReviewCovers? covers;
      try {
        covers = await load(preview);
      } catch (_) {
        // Without sizes the cover change keeps its default.
      }
      if (!mounted || !identical(_coverLoads[id], token)) return;
      setState(() {
        _coverLoads.remove(id);
        if (covers == null) return;
        _covers[id] = covers;
        if (_downgrade(preview, cover)) _selected[id]?.remove(cover.field);
      });
    }());
  }

  bool _downgrade(BatchReEnrichPreview preview, ReEnrichMetadataChange change) {
    // A cover picked by hand is wanted whatever its size.
    if (change.field == 'cover_url' && preview.coverFile != null) return false;
    final covers = _covers[preview.item.id];
    return reEnrichChangeIsDowngrade(
      change,
      currentCover: _size(covers?.current),
      newCover: _size(covers?.proposed),
    );
  }

  static ReEnrichCoverSize? _size(MetadataCoverPreview? cover) {
    final details = cover?.details;
    return details == null
        ? null
        : (width: details.width, height: details.height);
  }

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
          if (picked != null) {
            _previews[index] = picked;
            if (widget.chooseFields) _prepare(picked);
          }
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
    if (change.oldValue == reEnrichHasLyricsValue) {
      return context.l10n.trackReEnrichHasLyrics;
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

  IconData get _arrow =>
      context.isMornye ? mornyeArrowForward : Icons.arrow_forward_rounded;

  /// A change with its own switch: the current value beside the new one,
  /// or above it when the row is narrow.
  Widget _choiceRow(
    BuildContext context,
    BatchReEnrichPreview preview,
    ReEnrichMetadataChange change,
  ) {
    final theme = Theme.of(context);
    final id = preview.item.id;
    final on = _selected[id]?.contains(change.field) ?? false;
    final waiting = change.field == 'cover_url' && _coverLoads.containsKey(id);
    void toggle(bool value) => setState(() {
      final selected = _selected.putIfAbsent(id, () => {});
      value ? selected.add(change.field) : selected.remove(change.field);
    });

    return MergeSemantics(
      child: InkWell(
        onTap: waiting ? null : () => toggle(!on),
        child: Padding(
          padding: const EdgeInsetsDirectional.fromSTEB(56, 10, 12, 10),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _fieldLabel(context, change.field),
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 4),
                    if (change.field == 'cover_url')
                      _coverValues(context, preview, change)
                    else
                      _values(context, change),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              AppSwitch(value: on, onChanged: waiting ? null : toggle),
            ],
          ),
        ),
      ),
    );
  }

  Widget _values(BuildContext context, ReEnrichMetadataChange change) {
    final theme = Theme.of(context);
    final current = Text(
      _oldValue(context, change),
      style: theme.textTheme.bodyMedium?.copyWith(
        color: theme.colorScheme.onSurfaceVariant,
      ),
    );
    final proposed = Text(
      _newValue(context, change),
      style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
    );
    final arrow = AppIcon(_arrow, size: 16, color: theme.colorScheme.primary);
    return LayoutBuilder(
      builder: (context, constraints) => constraints.maxWidth >= 320
          ? Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: current),
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 2, 8, 0),
                  child: arrow,
                ),
                Expanded(child: proposed),
              ],
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                current,
                const SizedBox(height: 2),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsetsDirectional.only(top: 2, end: 6),
                      child: arrow,
                    ),
                    Expanded(child: proposed),
                  ],
                ),
              ],
            ),
    );
  }

  Widget _coverValues(
    BuildContext context,
    BatchReEnrichPreview preview,
    ReEnrichMetadataChange change,
  ) {
    final theme = Theme.of(context);
    final covers = _covers[preview.item.id];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Wraps the new cover below the current one when the row is narrow.
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            _thumbnail(context, covers?.current),
            AppIcon(_arrow, size: 16, color: theme.colorScheme.primary),
            _thumbnail(context, covers?.proposed, url: change.newValue),
            if (_coverLoads.containsKey(preview.item.id))
              const AppLoadingIndicator(size: 20),
          ],
        ),
        if (_downgrade(preview, change))
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              context.l10n.trackReEnrichSmallerCover,
              // A caution, not an error: the change is only off by default.
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.tertiary,
              ),
            ),
          ),
      ],
    );
  }

  Widget _thumbnail(
    BuildContext context,
    MetadataCoverPreview? cover, {
    String? url,
  }) {
    const size = 64.0;
    final theme = Theme.of(context);
    final empty = ColoredBox(
      color: theme.colorScheme.surfaceContainerHighest,
      child: Center(
        child: AppIcon.adaptive(
          Icons.music_note,
          size: 24,
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
    final details = cover?.details;
    final image = cover != null
        ? Image.file(
            File(cover.path),
            fit: BoxFit.cover,
            cacheWidth: 128,
            errorBuilder: (_, _, _) => empty,
          )
        : url != null && url.startsWith('http')
        ? CachedCoverImage(
            imageUrl: url,
            width: size,
            height: size,
            memCacheWidth: 128,
            errorWidget: (_, _, _) => empty,
          )
        : empty;
    return Column(
      children: [
        ClipRRect(
          borderRadius: context.tokens.borderRadiusThumb,
          child: SizedBox.square(dimension: size, child: image),
        ),
        const SizedBox(height: 4),
        Text(
          details == null ? '-' : '${details.width} × ${details.height} px',
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }

  Widget _footer(BuildContext context, {required VoidCallback? onApply}) {
    final l10n = context.l10n;
    final mornye = context.isMornye;
    final cancel = mornye
        ? AppActionButton(
            outlined: true,
            glass: false,
            onPressed: () => Navigator.pop(context),
            icon: const SizedBox.shrink(),
            label: Text(l10n.dialogCancel),
          )
        : ExpressiveButton(
            text: true,
            onPressed: () => Navigator.pop(context),
            child: Text(l10n.dialogCancel),
          );
    final apply = AppActionButton(
      onPressed: onApply,
      icon: const AppIcon(Icons.save_outlined),
      label: Text(l10n.trackReEnrichApplyChanges),
    );
    // A desktop dialog ends with text Cancel and the filled verb; a phone
    // sheet keeps the verb wide beside Cancel.
    return Row(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        cancel,
        const SizedBox(width: 8),
        isDesktopPlatform ? apply : Expanded(child: apply),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final choosing = widget.chooseFields;
    final visible = [
      for (var index = 0; index < _previews.length; index++)
        if (choosing ||
            _previews[index].changes.isNotEmpty ||
            (widget.onChoose != null && _previews[index].needsChoice))
          index,
    ];
    final totalChanges = _previews.fold<int>(
      0,
      (total, preview) => total + preview.changes.length,
    );
    final changeCount = choosing
        ? _previews.fold<int>(
            0,
            (total, preview) =>
                total +
                preview.changes
                    .where(
                      (change) =>
                          _selected[preview.item.id]?.contains(change.field) ??
                          false,
                    )
                    .length,
          )
        : totalChanges;
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
                choosing
                    ? context.l10n.trackReEnrichReviewSelected(
                        changeCount,
                        totalChanges,
                      )
                    : context.l10n.trackReEnrichReviewSubtitle(
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
                  if (choosing && preview.changes.isEmpty) ...[
                    const Divider(height: 1, indent: 56),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsetsDirectional.fromSTEB(
                        56,
                        12,
                        16,
                        12,
                      ),
                      child: Text(
                        context.l10n.trackReEnrichAlreadyMatches,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                  if (choosing)
                    for (final change in preview.changes) ...[
                      const Divider(height: 1, indent: 56),
                      _choiceRow(context, preview, change),
                    ],
                  for (final change
                      in choosing
                          ? const <ReEnrichMetadataChange>[]
                          : preview.changes) ...[
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
            child: _footer(
              context,
              onApply:
                  changeCount == 0 ||
                      _choosing != null ||
                      _coverLoads.isNotEmpty
                  ? null
                  : () => Navigator.pop(
                      context,
                      choosing
                          ? [
                              for (final preview in _previews)
                                preview.selecting(
                                  _selected[preview.item.id] ?? const {},
                                ),
                            ]
                          : _previews,
                    ),
            ),
          ),
        ],
      ),
    );
  }
}
