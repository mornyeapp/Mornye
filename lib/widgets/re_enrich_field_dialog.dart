import 'package:material_ui/material_ui.dart';
import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:mornye/theme/mornye_icons.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/widgets/app_action_button.dart';
import 'package:mornye/widgets/app_checkbox.dart';
import 'package:mornye/widgets/app_text_field.dart';
import '../l10n/app_localizations.dart';
import 'package:mornye/services/batch_metadata_re_enrich.dart';
import 'package:mornye/widgets/app_bottom_sheet.dart';
import 'package:mornye/widgets/settings_group.dart';

Future<ReEnrichFieldSelection?> showReEnrichFieldDialog(
  BuildContext context, {
  required int selectedCount,
}) {
  return showAppBottomSheet<ReEnrichFieldSelection>(
    context: context,
    useRootNavigator: true,
    title: AppLocalizations.of(context).trackReEnrich,
    subtitle: AppLocalizations.of(context).trackReEnrichBatchSubtitle,
    maxHeightFactor: 0.9,
    builder: (ctx) => _ReEnrichFieldSheet(selectedCount: selectedCount),
  );
}

class _ReEnrichFieldSheet extends StatefulWidget {
  final int selectedCount;
  const _ReEnrichFieldSheet({required this.selectedCount});

  @override
  State<_ReEnrichFieldSheet> createState() => _ReEnrichFieldSheetState();
}

class _ReEnrichFieldSheetState extends State<_ReEnrichFieldSheet> {
  final Set<String> _selected = Set<String>.from(ReEnrichFields.all);
  final Map<String, TextEditingController> _manualControllers = {
    for (final field in manualBatchMetadataFields)
      field: TextEditingController(),
  };
  ReEnrichBatchMode _mode = ReEnrichBatchMode.missingOnly;

  bool get _allSelected => _selected.length == ReEnrichFields.all.length;
  bool get _hasManualValues => _manualControllers.values.any(
    (controller) => controller.text.trim().isNotEmpty,
  );

  Map<String, String> get _manualValues => {
    for (final entry in _manualControllers.entries)
      if (entry.value.text.trim().isNotEmpty)
        entry.key: entry.value.text.trim(),
  };

  @override
  void dispose() {
    for (final controller in _manualControllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  void _toggleAll(bool? value) {
    setState(() {
      if (value == true) {
        _selected.addAll(ReEnrichFields.all);
      } else {
        _selected.clear();
      }
    });
  }

  void _toggle(String field, bool? value) {
    setState(() {
      if (value == true) {
        _selected.add(field);
      } else {
        _selected.remove(field);
      }
    });
  }

  String _labelFor(String field, AppLocalizations l10n) {
    switch (field) {
      case ReEnrichFields.cover:
        return l10n.trackReEnrichFieldCover;
      case ReEnrichFields.lyrics:
        return l10n.trackReEnrichFieldLyrics;
      case ReEnrichFields.basicTags:
        return l10n.trackReEnrichFieldBasicTags;
      case ReEnrichFields.trackInfo:
        return l10n.trackReEnrichFieldTrackInfo;
      case ReEnrichFields.releaseInfo:
        return l10n.trackReEnrichFieldReleaseInfo;
      case ReEnrichFields.extra:
        return l10n.trackReEnrichFieldExtra;
      default:
        return field;
    }
  }

  IconData _iconFor(String field) {
    switch (field) {
      case ReEnrichFields.cover:
        return Icons.image_outlined;
      case ReEnrichFields.lyrics:
        return Icons.lyrics_outlined;
      case ReEnrichFields.basicTags:
        return Icons.album_outlined;
      case ReEnrichFields.trackInfo:
        return Icons.format_list_numbered;
      case ReEnrichFields.releaseInfo:
        return Icons.calendar_today_outlined;
      case ReEnrichFields.extra:
        return Icons.label_outline;
      default:
        return Icons.tag;
    }
  }

  String _manualLabelFor(String field, AppLocalizations l10n) {
    switch (field) {
      case 'artist_name':
        return l10n.trackArtist;
      case 'album_name':
        return l10n.trackAlbum;
      case 'album_artist':
        return l10n.trackAlbumArtist;
      case 'release_date':
        return l10n.trackReleaseDate;
      case 'genre':
        return l10n.trackGenre;
      case 'composer':
        return l10n.editMetadataFieldComposer;
      case 'label':
        return l10n.trackLabel;
      case 'copyright':
        return l10n.trackCopyright;
      default:
        return field;
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final colorScheme = Theme.of(context).colorScheme;

    return SafeArea(
      top: false,
      child: SingleChildScrollView(
        padding: const EdgeInsets.only(bottom: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
              child: Text(
                l10n.downloadedAlbumSelectedCount(widget.selectedCount),
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            _options(
              children: [
                _modeOption(
                  icon: Icons.fingerprint,
                  title: l10n.trackReEnrichModeIsrc,
                  subtitle: l10n.trackReEnrichModeIsrcSubtitle,
                  mode: ReEnrichBatchMode.isrcOnly,
                ),
                const Divider(height: 1, indent: 56),
                _modeOption(
                  icon: Icons.playlist_add_check,
                  title: l10n.trackReEnrichModeMissing,
                  subtitle: l10n.trackReEnrichModeMissingSubtitle,
                  mode: ReEnrichBatchMode.missingOnly,
                ),
                const Divider(height: 1, indent: 56),
                _modeOption(
                  icon: Icons.tune,
                  title: l10n.trackReEnrichModeReplace,
                  subtitle: l10n.trackReEnrichModeReplaceSubtitle,
                  mode: ReEnrichBatchMode.selectedFields,
                ),
                const Divider(height: 1, indent: 56),
                _modeOption(
                  icon: Icons.edit_note,
                  title: l10n.trackReEnrichModeManual,
                  subtitle: l10n.trackReEnrichModeManualSubtitle,
                  mode: ReEnrichBatchMode.manualValues,
                ),
              ],
            ),
            if (_mode == ReEnrichBatchMode.selectedFields) ...[
              const SizedBox(height: 8),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Text(
                  l10n.trackReEnrichFieldsTitle,
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              _options(
                children: [
                  _fieldToggle(
                    title: l10n.trackReEnrichSelectAll,
                    value: _allSelected,
                    onChanged: _toggleAll,
                  ),
                  for (final field in ReEnrichFields.all) ...[
                    const Divider(height: 1, indent: 56),
                    _fieldToggle(
                      icon: _iconFor(field),
                      title: _labelFor(field, l10n),
                      value: _selected.contains(field),
                      onChanged: (value) => _toggle(field, value),
                    ),
                  ],
                ],
              ),
            ],
            if (_mode == ReEnrichBatchMode.manualValues) ...[
              const SizedBox(height: 8),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      l10n.trackReEnrichManualFieldsTitle,
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      l10n.trackReEnrichManualHint,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              _options(
                grouped: false,
                children: [
                  for (
                    var index = 0;
                    index < manualBatchMetadataFields.length;
                    index++
                  ) ...[
                    if (index > 0) const Divider(height: 1),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
                      child: context.isMornye
                          ? Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  _manualLabelFor(
                                    manualBatchMetadataFields[index],
                                    l10n,
                                  ),
                                  style: Theme.of(context).textTheme.bodySmall
                                      ?.copyWith(
                                        color: colorScheme.onSurfaceVariant,
                                      ),
                                ),
                                const SizedBox(height: 6),
                                CupertinoTextField(
                                  controller:
                                      _manualControllers[manualBatchMetadataFields[index]],
                                  onChanged: (_) => setState(() {}),
                                  style: Theme.of(context).textTheme.bodyLarge,
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 12,
                                    vertical: 12,
                                  ),
                                  decoration: BoxDecoration(
                                    color: MornyeTheme.controlFill(context),
                                    borderRadius: BorderRadius.circular(16),
                                  ),
                                ),
                              ],
                            )
                          : AppTextField(
                              controller:
                                  _manualControllers[manualBatchMetadataFields[index]],
                              onChanged: (_) => setState(() {}),
                              outlined: true,
                              label: _manualLabelFor(
                                manualBatchMetadataFields[index],
                                l10n,
                              ),
                              decoration: InputDecoration(
                                labelText: _manualLabelFor(
                                  manualBatchMetadataFields[index],
                                  l10n,
                                ),
                                border: const OutlineInputBorder(),
                                isDense: true,
                              ),
                            ),
                    ),
                  ],
                ],
              ),
            ],
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              child: SizedBox(
                width: double.infinity,
                child: AppActionButton(
                  onPressed:
                      (_mode == ReEnrichBatchMode.selectedFields &&
                              _selected.isEmpty) ||
                          (_mode == ReEnrichBatchMode.manualValues &&
                              !_hasManualValues)
                      ? null
                      : () => Navigator.pop(
                          context,
                          ReEnrichFieldSelection(
                            mode: _mode,
                            fields: _selected.toList(),
                            manualValues: _manualValues,
                          ),
                        ),
                  icon: const Icon(Icons.preview_outlined, size: 18),
                  label: Text(l10n.trackReEnrichReview),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _options({required List<Widget> children, bool grouped = true}) {
    if (!context.isMornye) {
      return SettingsGroup(
        connected: true,
        children: [
          for (final child in children)
            if (child is! Divider) child,
        ],
      );
    }
    final content = Column(mainAxisSize: MainAxisSize.min, children: children);
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: grouped ? 16 : 4, vertical: 4),
      child: grouped
          ? Material(
              color: MornyeTheme.controlFill(context),
              borderRadius: BorderRadius.circular(28),
              clipBehavior: Clip.antiAlias,
              child: content,
            )
          : content,
    );
  }

  Widget _modeOption({
    required IconData icon,
    required String title,
    required String subtitle,
    required ReEnrichBatchMode mode,
  }) {
    void select() => setState(() => _mode = mode);
    final scheme = Theme.of(context).colorScheme;
    if (!context.isMornye) {
      return ListTile(
        leading: Icon(icon),
        title: Text(title),
        subtitle: Text(subtitle),
        selected: _mode == mode,
        selectedColor: scheme.onSurface,
        trailing: _mode == mode
            ? Icon(Icons.check, color: scheme.primary)
            : null,
        onTap: select,
      );
    }
    return Semantics(
      selected: _mode == mode,
      child: CupertinoButton(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
        onPressed: select,
        child: Row(
          children: [
            Icon(mornyeIconFor(icon), color: scheme.primary, size: 24),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: Theme.of(context).textTheme.bodyLarge),
                  const SizedBox(height: 4),
                  Text(
                    subtitle,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            SizedBox(
              width: 20,
              child: _mode == mode
                  ? Icon(
                      CupertinoIcons.checkmark,
                      color: scheme.primary,
                      size: 20,
                    )
                  : null,
            ),
          ],
        ),
      ),
    );
  }

  Widget _fieldToggle({
    required String title,
    required bool value,
    required ValueChanged<bool?> onChanged,
    IconData? icon,
  }) {
    if (!context.isMornye) {
      return AppCheckboxListTile(
        title: Text(title),
        value: value,
        onChanged: onChanged,
        secondary: icon == null ? null : Icon(icon, size: 20),
        controlAffinity: ListTileControlAffinity.leading,
      );
    }
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      checked: value,
      child: CupertinoButton(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        onPressed: () => onChanged(!value),
        child: Row(
          children: [
            Icon(
              value
                  ? CupertinoIcons.check_mark_circled_solid
                  : CupertinoIcons.circle,
              color: value ? scheme.primary : scheme.onSurfaceVariant,
              size: 24,
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Text(title, style: Theme.of(context).textTheme.bodyLarge),
            ),
            if (icon != null)
              Icon(
                mornyeIconFor(icon),
                color: scheme.onSurfaceVariant,
                size: 20,
              ),
          ],
        ),
      ),
    );
  }
}
