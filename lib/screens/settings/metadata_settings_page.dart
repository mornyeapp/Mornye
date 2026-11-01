import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/controllers/clickable_metadata.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/utils/artist_utils.dart';
import 'package:mornye/utils/nav_bar_inset.dart';
import 'package:mornye/screens/settings/metadata_provider_priority_page.dart';
import 'package:mornye/screens/settings/metadata_separator_settings_page.dart';
import 'package:mornye/widgets/settings_group.dart';
import 'package:mornye/widgets/app_sliver_header.dart';
import 'package:mornye/widgets/app_bottom_sheet.dart';

class MetadataSettingsPage extends ConsumerWidget {
  const MetadataSettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);

    return PopScope(
      canPop: true,
      child: Scaffold(
        body: CustomScrollView(
          slivers: [
            AppSliverHeader.page(title: context.l10n.settingsMetadata),

            ...settingsSectionSlivers(
              title: context.l10n.sectionDownload,
              children: [
                SettingsSwitchItem(
                  icon: Icons.sell_outlined,
                  title: context.l10n.optionsEmbedMetadata,
                  subtitle: settings.embedMetadata
                      ? context.l10n.optionsEmbedMetadataSubtitleOn
                      : context.l10n.optionsEmbedMetadataSubtitleOff,
                  value: settings.embedMetadata,
                  onChanged: (v) =>
                      ref.read(settingsProvider.notifier).setEmbedMetadata(v),
                  showDivider: settings.embedMetadata,
                ),
                if (settings.embedMetadata) ...[
                  SettingsItem(
                    icon: Icons.people_alt_outlined,
                    title: context.l10n.optionsArtistTagMode,
                    subtitle: _getArtistTagModeLabel(
                      context,
                      settings.artistTagMode,
                    ),
                    onTap: () => _showArtistTagModePicker(
                      context,
                      ref,
                      settings.artistTagMode,
                    ),
                  ),
                  SettingsItem(
                    icon: Icons.format_list_bulleted,
                    title: context.l10n.metadataSeparators,
                    onTap: () => pushPage<void>(
                      context,
                      (_) => const MetadataSeparatorSettingsPage(),
                    ),
                  ),
                  SettingsItem(
                    icon: Icons.photo_size_select_large_outlined,
                    title: context.l10n.optionsEmbeddedCoverSize,
                    subtitle: _getEmbeddedCoverSizeLabel(
                      context,
                      settings.embeddedCoverMaxDimension,
                    ),
                    onTap: () => _showEmbeddedCoverSizePicker(
                      context,
                      ref,
                      settings.embeddedCoverMaxDimension,
                    ),
                  ),
                  SettingsSwitchItem(
                    icon: Icons.graphic_eq,
                    title: context.l10n.optionsReplayGain,
                    subtitle: settings.embedReplayGain
                        ? context.l10n.optionsReplayGainSubtitleOn
                        : context.l10n.optionsReplayGainSubtitleOff,
                    value: settings.embedReplayGain,
                    onChanged: (v) => ref
                        .read(settingsProvider.notifier)
                        .setEmbedReplayGain(v),
                    showDivider: false,
                  ),
                ],
              ],
            ),

            ...settingsSectionSlivers(
              title: context.l10n.sectionMetadataProviders,
              children: [
                SettingsItem(
                  icon: Icons.source_outlined,
                  title: context.l10n.metadataProvidersTitle,
                  subtitle: context.l10n.metadataProvidersSubtitle,
                  onTap: () => pushPage<void>(
                    context,
                    (_) => const MetadataProviderPriorityPage(),
                  ),
                  showDivider: false,
                ),
              ],
            ),

            ...settingsSectionSlivers(
              title: context.l10n.sectionDuplicates,
              children: [
                SettingsSwitchItem(
                  icon: Icons.filter_list_outlined,
                  title: context.l10n.downloadDeduplication,
                  subtitle: settings.deduplicateDownloads
                      ? settings.allowQualityVariants
                            ? context
                                  .l10n
                                  .downloadDeduplicationWithQualityVariants
                            : context.l10n.downloadDeduplicationEnabled
                      : context.l10n.downloadDeduplicationDisabled,
                  value: settings.deduplicateDownloads,
                  onChanged: (value) => ref
                      .read(settingsProvider.notifier)
                      .setDeduplicateDownloads(value),
                ),
                SettingsSwitchItem(
                  icon: Icons.library_music_outlined,
                  title: context.l10n.downloadQualityVariants,
                  subtitle: context.l10n.downloadQualityVariantsDescription,
                  value: settings.allowQualityVariants,
                  onChanged: (value) => ref
                      .read(settingsProvider.notifier)
                      .setAllowQualityVariants(value),
                  showDivider: false,
                ),
              ],
            ),

            const SliverToBoxAdapter(child: SizedBox(height: 32)),
            const NavBarSliverSpacer(),
          ],
        ),
      ),
    );
  }

  String _getArtistTagModeLabel(BuildContext context, String mode) {
    switch (mode) {
      case artistTagModeSplitVorbis:
        return context.l10n.optionsArtistTagModeSplitVorbis;
      case artistTagModePrimary:
        return context.l10n.optionsArtistTagModePrimary;
      default:
        return context.l10n.optionsArtistTagModeJoined;
    }
  }

  String _getEmbeddedCoverSizeLabel(BuildContext context, int maxDimension) {
    if (maxDimension <= 0) {
      return context.l10n.optionsEmbeddedCoverSizeOriginal;
    }
    return '$maxDimension × $maxDimension px';
  }

  void _showEmbeddedCoverSizePicker(
    BuildContext context,
    WidgetRef ref,
    int currentMaxDimension,
  ) => showAppChoiceSheet(
    context: context,
    title: context.l10n.optionsEmbeddedCoverSize,
    subtitle: context.l10n.optionsEmbeddedCoverSizeDescription,
    selected: currentMaxDimension,
    choices: [
      for (final maxDimension in const [0, 500, 1000, 1500, 2000])
        AppChoice(
          maxDimension,
          maxDimension == 0 ? Icons.image_outlined : Icons.compress_outlined,
          _getEmbeddedCoverSizeLabel(context, maxDimension),
        ),
    ],
    onSelected: (maxDimension) => ref
        .read(settingsProvider.notifier)
        .setEmbeddedCoverMaxDimension(maxDimension),
  );

  void _showArtistTagModePicker(
    BuildContext context,
    WidgetRef ref,
    String currentMode,
  ) => showAppChoiceSheet(
    context: context,
    title: context.l10n.optionsArtistTagMode,
    subtitle: context.l10n.optionsArtistTagModeDescription,
    selected: currentMode,
    choices: [
      AppChoice(
        artistTagModeJoined,
        Icons.segment_outlined,
        context.l10n.optionsArtistTagModeJoined,
        subtitle: context.l10n.optionsArtistTagModeJoinedSubtitle,
      ),
      AppChoice(
        artistTagModeSplitVorbis,
        Icons.library_music_outlined,
        context.l10n.optionsArtistTagModeSplitVorbis,
        subtitle: context.l10n.optionsArtistTagModeSplitVorbisSubtitle,
      ),
      AppChoice(
        artistTagModePrimary,
        Icons.person_outline,
        context.l10n.optionsArtistTagModePrimary,
        subtitle: context.l10n.optionsArtistTagModePrimarySubtitle,
      ),
    ],
    onSelected: (mode) =>
        ref.read(settingsProvider.notifier).setArtistTagMode(mode),
  );
}
