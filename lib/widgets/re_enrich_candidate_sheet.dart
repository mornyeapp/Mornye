import 'package:material_ui/material_ui.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/providers/extension_provider.dart';
import 'package:mornye/services/batch_metadata_re_enrich.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/widgets/app_bottom_sheet.dart';
import 'package:mornye/widgets/app_icon.dart';
import 'package:mornye/widgets/metadata_candidate_tile.dart';
import 'package:mornye/widgets/metadata_editor_fields.dart';
import 'package:mornye/widgets/settings_group.dart';

/// Lets a person pick the online result a song is updated from. Results that
/// fit come first; the rest stay folded under Other results, since a search
/// for a common title also returns other songs.
Future<Map<String, dynamic>?> showReEnrichCandidateSheet(
  BuildContext context, {
  required List<Map<String, dynamic>> candidates,
  required String title,
  String? subtitle,
  required String Function(String providerId) providerName,
}) => showAppBottomSheet<Map<String, dynamic>>(
  context: context,
  useRootNavigator: true,
  backgroundColor: Theme.of(context).colorScheme.surfaceContainerHigh,
  title: title,
  subtitle: subtitle,
  maxHeightFactor: 0.82,
  builder: (sheetContext) => _CandidateList(
    candidates: candidates,
    providerName: providerName,
    onPick: (candidate) => Navigator.pop(sheetContext, candidate),
  ),
);

/// Names a result's source by its extension's display name. Built-in
/// catalogs are not extensions and show their id, capitalized.
String Function(String providerId) reEnrichProviderNames(
  ExtensionState extensions,
) => (providerId) {
  final name = extensions.extensions
      .where((extension) => extension.id == providerId)
      .firstOrNull
      ?.displayName;
  if (name != null && name.trim().isNotEmpty) return name;
  if (providerId.isEmpty) return providerId;
  return providerId[0].toUpperCase() + providerId.substring(1);
};

/// The line naming where [candidate] comes from and how well it fits.
String reEnrichCandidateSource(
  BuildContext context,
  Map<String, dynamic> candidate,
  String Function(String providerId) providerName,
) {
  final provider = candidate['provider_id']?.toString().trim() ?? '';
  final match = switch (reEnrichCandidateMatch(candidate)) {
    ReEnrichMatch.exact => context.l10n.reEnrichMatchExact,
    ReEnrichMatch.strong => context.l10n.reEnrichMatchStrong,
    ReEnrichMatch.weak => context.l10n.reEnrichMatchWeak,
    ReEnrichMatch.other || ReEnrichMatch.none => '',
  };
  return [
    if (provider.isNotEmpty) providerName(provider),
    match,
  ].where((part) => part.isNotEmpty).join(' · ');
}

class _CandidateList extends StatefulWidget {
  final List<Map<String, dynamic>> candidates;
  final String Function(String providerId) providerName;
  final ValueChanged<Map<String, dynamic>> onPick;

  const _CandidateList({
    required this.candidates,
    required this.providerName,
    required this.onPick,
  });

  @override
  State<_CandidateList> createState() => _CandidateListState();
}

class _CandidateListState extends State<_CandidateList> {
  late final List<Map<String, dynamic>> _likely = [
    for (final candidate in widget.candidates)
      if (reEnrichCandidateMatch(candidate).likely) candidate,
  ];
  late final List<Map<String, dynamic>> _others = [
    for (final candidate in widget.candidates)
      if (!reEnrichCandidateMatch(candidate).likely) candidate,
  ];
  late bool _showOthers = _likely.isEmpty;

  List<Widget> _rows(List<Map<String, dynamic>> candidates) {
    final mornye = context.isMornye;
    return [
      for (var index = 0; index < candidates.length; index++) ...[
        // Material groups set rows apart with gaps, Mornye with hairlines.
        if (mornye && index > 0)
          Divider(
            height: 1,
            indent: 88,
            endIndent: 16,
            color: Theme.of(
              context,
            ).colorScheme.outlineVariant.withValues(alpha: 0.3),
          ),
        MetadataCandidateTile(
          candidate: candidates[index],
          source: reEnrichCandidateSource(
            context,
            candidates[index],
            widget.providerName,
          ),
          onTap: () => widget.onPick(candidates[index]),
        ),
      ],
    ];
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return ListView(
      // The sheet is as tall as its results, up to its cap.
      shrinkWrap: true,
      padding: const EdgeInsets.only(bottom: 16),
      children: [
        if (_likely.isNotEmpty) ...[
          SettingsSectionHeader(title: l10n.reEnrichBestMatches),
          MetadataEditorOptions(children: _rows(_likely)),
        ],
        if (_others.isNotEmpty) ...[
          SettingsSectionHeader(
            title: _likely.isEmpty
                ? l10n.reEnrichNoCloseMatch
                : l10n.reEnrichOtherResults,
          ),
          if (_showOthers)
            MetadataEditorOptions(children: _rows(_others))
          else
            MetadataEditorOptions(
              children: [
                ListTile(
                  leading: const AppIcon.adaptive(Icons.expand_more),
                  title: Text(l10n.reEnrichShowOtherResults(_others.length)),
                  onTap: () => setState(() => _showOthers = true),
                ),
              ],
            ),
        ],
      ],
    );
  }
}
