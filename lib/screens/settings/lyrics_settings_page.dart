import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/providers/extension_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/screens/settings/lyrics_provider_priority_page.dart';
import 'package:mornye/widgets/settings_group.dart';
import 'package:mornye/widgets/app_text_field.dart';
import 'package:mornye/widgets/app_sliver_header.dart';
import 'package:mornye/widgets/app_bottom_sheet.dart';
import 'package:mornye/widgets/app_alert_dialog.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/utils/lyrics_provider_names.dart';
import 'package:mornye/utils/nav_bar_inset.dart';
import 'package:mornye/widgets/lyrics_size_setting.dart';

class LyricsSettingsPage extends ConsumerWidget {
  const LyricsSettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    final extensionProviderNames = <String, String>{
      for (final extension in ref.watch(extensionProvider).extensions)
        'extension:${extension.id.toLowerCase()}': extension.displayName,
    };

    return PopScope(
      canPop: true,
      child: Scaffold(
        body: CustomScrollView(
          slivers: [
            AppSliverHeader.page(title: context.l10n.settingsLyrics),

            ...settingsSectionSlivers(
              title: context.l10n.sectionLyrics,
              connected: true,
              children: [
                const LyricsSizeSetting(),
                SettingsSwitchItem(
                  icon: Icons.light_mode_outlined,
                  title: context.l10n.lyricsKeepScreenOn,
                  subtitle: context.l10n.lyricsKeepScreenOnSubtitle,
                  value: settings.keepScreenOnLyrics,
                  onChanged: (value) => ref
                      .read(settingsProvider.notifier)
                      .setKeepScreenOnLyrics(value),
                ),
                SettingsSwitchItem(
                  icon: Icons.subtitles_outlined,
                  title: context.l10n.optionsEmbedLyrics,
                  subtitle: settings.embedMetadata
                      ? context.l10n.optionsEmbedLyricsSubtitle
                      : context.l10n.downloadEmbedLyricsDisabled,
                  value: settings.embedLyrics,
                  enabled: settings.embedMetadata,
                  onChanged: (value) =>
                      ref.read(settingsProvider.notifier).setEmbedLyrics(value),
                  showDivider: settings.embedMetadata && settings.embedLyrics,
                ),
                if (settings.embedMetadata && settings.embedLyrics) ...[
                  SettingsItem(
                    icon: Icons.lyrics_outlined,
                    title: context.l10n.lyricsMode,
                    subtitle: _getLyricsModeLabel(context, settings.lyricsMode),
                    onTap: () => _showLyricsModePicker(
                      context,
                      ref,
                      settings.lyricsMode,
                    ),
                  ),
                  SettingsItem(
                    icon: Icons.source_outlined,
                    title: context.l10n.lyricsProvidersTitle,
                    subtitle: _getLyricsProvidersSubtitle(
                      context,
                      settings.lyricsProviders,
                      extensionProviderNames,
                    ),
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute<void>(
                        builder: (_) => const LyricsProviderPriorityPage(),
                      ),
                    ),
                    showDivider: false,
                  ),
                ],
              ],
            ),

            if (settings.embedMetadata && settings.embedLyrics)
              ...settingsSectionSlivers(
                title: context.l10n.sectionLyricsProviderOptions,
                children: [
                  SettingsSwitchItem(
                    icon: Icons.translate_outlined,
                    title: context.l10n.downloadNeteaseIncludeTranslation,
                    subtitle: settings.lyricsIncludeTranslationNetease
                        ? context.l10n.downloadNeteaseIncludeTranslationEnabled
                        : context
                              .l10n
                              .downloadNeteaseIncludeTranslationDisabled,
                    value: settings.lyricsIncludeTranslationNetease,
                    onChanged: (value) => ref
                        .read(settingsProvider.notifier)
                        .setLyricsIncludeTranslationNetease(value),
                  ),
                  SettingsSwitchItem(
                    icon: Icons.text_fields_outlined,
                    title: context.l10n.downloadNeteaseIncludeRomanization,
                    subtitle: settings.lyricsIncludeRomanizationNetease
                        ? context.l10n.downloadNeteaseIncludeRomanizationEnabled
                        : context
                              .l10n
                              .downloadNeteaseIncludeRomanizationDisabled,
                    value: settings.lyricsIncludeRomanizationNetease,
                    onChanged: (value) => ref
                        .read(settingsProvider.notifier)
                        .setLyricsIncludeRomanizationNetease(value),
                  ),
                  SettingsSwitchItem(
                    icon: Icons.record_voice_over_outlined,
                    title: context.l10n.downloadAppleQqMultiPerson,
                    subtitle: settings.lyricsMultiPersonWordByWord
                        ? context.l10n.downloadAppleQqMultiPersonEnabled
                        : context.l10n.downloadAppleQqMultiPersonDisabled,
                    value: settings.lyricsMultiPersonWordByWord,
                    onChanged: (value) => ref
                        .read(settingsProvider.notifier)
                        .setLyricsMultiPersonWordByWord(value),
                  ),
                  SettingsSwitchItem(
                    icon: Icons.graphic_eq_outlined,
                    title: context.l10n.downloadAppleElrcWordSync,
                    subtitle: settings.lyricsAppleElrcWordSync
                        ? context.l10n.downloadAppleElrcWordSyncEnabled
                        : context.l10n.downloadAppleElrcWordSyncDisabled,
                    value: settings.lyricsAppleElrcWordSync,
                    onChanged: (value) => ref
                        .read(settingsProvider.notifier)
                        .setLyricsAppleElrcWordSync(value),
                  ),
                  SettingsItem(
                    icon: Icons.language_outlined,
                    title: context.l10n.downloadMusixmatchLanguage,
                    subtitle: settings.musixmatchLanguage.isEmpty
                        ? context.l10n.downloadMusixmatchLanguageAuto
                        : settings.musixmatchLanguage.toUpperCase(),
                    onTap: () => _showMusixmatchLanguagePicker(
                      context,
                      ref,
                      settings.musixmatchLanguage,
                    ),
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

  String _getLyricsModeLabel(BuildContext context, String mode) {
    switch (mode) {
      case 'external':
        return context.l10n.lyricsModeExternal;
      case 'both':
        return context.l10n.lyricsModeBoth;
      default:
        return context.l10n.lyricsModeEmbed;
    }
  }

  String _getLyricsProvidersSubtitle(
    BuildContext context,
    List<String> providers,
    Map<String, String> extensionProviderNames,
  ) {
    if (providers.isEmpty) return context.l10n.downloadProvidersNoneEnabled;
    return providers
        .map(
          (provider) =>
              lyricsProviderDisplayName(provider, extensionProviderNames),
        )
        .join(' > ');
  }

  void _showLyricsModePicker(
    BuildContext context,
    WidgetRef ref,
    String current,
  ) => showAppChoiceSheet(
    context: context,
    title: context.l10n.lyricsMode,
    subtitle: context.l10n.lyricsModeDescription,
    selected: current,
    choices: [
      AppChoice(
        'embed',
        Icons.audiotrack,
        context.l10n.lyricsModeEmbed,
        subtitle: context.l10n.lyricsModeEmbedSubtitle,
      ),
      AppChoice(
        'external',
        Icons.insert_drive_file_outlined,
        context.l10n.lyricsModeExternal,
        subtitle: context.l10n.lyricsModeExternalSubtitle,
      ),
      AppChoice(
        'both',
        Icons.library_music_outlined,
        context.l10n.lyricsModeBoth,
        subtitle: context.l10n.lyricsModeBothSubtitle,
      ),
    ],
    onSelected: (mode) =>
        ref.read(settingsProvider.notifier).setLyricsMode(mode),
  );

  void _showMusixmatchLanguagePicker(
    BuildContext context,
    WidgetRef ref,
    String currentLanguage,
  ) {
    final controller = TextEditingController(text: currentLanguage);

    showAppScrollableBottomSheet<void>(
      context: context,
      title: context.l10n.downloadMusixmatchLanguage,
      subtitle: context.l10n.downloadMusixmatchLanguageDesc,
      builder: (context, scrollController) => SingleChildScrollView(
        controller: scrollController,
        padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AppTextField(
              controller: controller,
              textInputAction: TextInputAction.done,
              label: context.l10n.downloadMusixmatchLanguageCode,
              hint: context.l10n.downloadMusixmatchLanguageHint,
            ),
            const SizedBox(height: 16),
            Builder(
              builder: (context) {
                final actions = [
                  AppDialogAction(
                    onPressed: () => Navigator.pop(context),
                    child: Text(context.l10n.dialogCancel),
                  ),
                  AppDialogAction(
                    onPressed: () {
                      ref
                          .read(settingsProvider.notifier)
                          .setMusixmatchLanguage('');
                      Navigator.pop(context);
                    },
                    child: Text(context.l10n.downloadMusixmatchAuto),
                  ),
                  AppDialogAction(
                    filled: true,
                    onPressed: () {
                      final normalized = controller.text
                          .trim()
                          .toLowerCase()
                          .replaceAll(RegExp(r'[^a-z0-9\-_]'), '');
                      ref
                          .read(settingsProvider.notifier)
                          .setMusixmatchLanguage(normalized);
                      Navigator.pop(context);
                    },
                    child: Text(context.l10n.dialogSave),
                  ),
                ];
                return context.isMornye
                    ? Wrap(
                        alignment: WrapAlignment.end,
                        spacing: 8,
                        runSpacing: 8,
                        children: actions,
                      )
                    : Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          actions[0],
                          const SizedBox(width: 8),
                          actions[1],
                          const SizedBox(width: 8),
                          actions[2],
                        ],
                      );
              },
            ),
          ],
        ),
      ),
    );
  }
}
