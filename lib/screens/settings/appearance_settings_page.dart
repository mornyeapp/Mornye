import 'package:flutter/material.dart';
import 'package:mornye/widgets/app_bottom_sheet.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/constants/language_choices.dart';
import 'package:mornye/providers/runtime_profile_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/providers/theme_provider.dart';
import 'package:mornye/models/theme_settings.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/widgets/mornye_chrome.dart';
import 'package:mornye/utils/adaptive_layout.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:mornye/utils/nav_bar_inset.dart';
import 'package:mornye/widgets/settings_group.dart';
import 'package:mornye/widgets/app_icon.dart';
import 'package:mornye/widgets/app_sliver_header.dart';
import 'package:mornye/widgets/custom_font_setting.dart';
import 'package:mornye/widgets/desktop/desktop_window_controls.dart';

part 'appearance_settings_page_widgets.dart';

class AppearanceSettingsPage extends ConsumerWidget {
  const AppearanceSettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeSettings = ref.watch(themeProvider);
    final settings = ref.watch(settingsProvider);

    return PopScope(
      canPop: true,
      child: Scaffold(
        body: CustomScrollView(
          slivers: [
            AppSliverHeader.page(title: context.l10n.appearanceTitle),

            if (isDesktopPlatform)
              const SliverToBoxAdapter(
                child: SettingsGroup(children: [DesktopWindowModeSetting()]),
              ),

            ...settingsSectionSlivers(
              title: context.l10n.appearanceStyle,
              children: [
                for (final style in AppThemeStyle.values)
                  ListTile(
                    title: Wrap(
                      spacing: 8,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text(
                          style == AppThemeStyle.mornye ? 'Mornye' : 'Material',
                        ),
                        if (style == AppThemeStyle.mornye)
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 7,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: Theme.of(
                                context,
                              ).colorScheme.primary.withValues(alpha: 0.12),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              'Beta',
                              style: TextStyle(
                                color: Theme.of(context).colorScheme.primary,
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                      ],
                    ),
                    leading: context.isMornye
                        ? null
                        : AppIcon(
                            style == AppThemeStyle.mornye
                                ? Icons.music_note_outlined
                                : Icons.palette_outlined,
                          ),
                    trailing: themeSettings.style == style
                        ? AppIcon(
                            Icons.check_circle,
                            color: Theme.of(context).colorScheme.primary,
                          )
                        : null,
                    selected: themeSettings.style == style,
                    onTap: () =>
                        ref.read(themeProvider.notifier).setStyle(style),
                  ),
              ],
            ),

            SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.symmetric(
                  horizontal: 16 + wideListInset(context),
                  vertical: 8,
                ),
                child: _ThemePreviewCard(),
              ),
            ),

            if (themeSettings.style == AppThemeStyle.mornye)
              ...settingsSectionSlivers(
                title: context.l10n.sectionColor,
                children: [
                  _MornyeAccentPicker(
                    selected: themeSettings.mornyeAccent,
                    onChanged: ref.read(themeProvider.notifier).setMornyeAccent,
                  ),
                  const _MornyeGlassClaritySlider(),
                  SettingsSwitchItem(
                    key: const ValueKey('mornye-glass-outlines'),
                    icon: Icons.rounded_corner,
                    title: context.l10n.appearanceGlassOutlines,
                    subtitle: context.l10n.appearanceGlassOutlinesSubtitle,
                    value: themeSettings.mornyeGlassOutlines,
                    onChanged: ref
                        .read(themeProvider.notifier)
                        .setMornyeGlassOutlines,
                    showDivider: false,
                  ),
                ],
              )
            else ...[
              ...settingsSectionSlivers(
                title: context.l10n.sectionColor,
                children: [
                  SettingsSwitchItem(
                    icon: Icons.wallpaper,
                    title: context.l10n.appearanceDynamicColor,
                    subtitle: context.l10n.appearanceDynamicColorSubtitle,
                    value: themeSettings.useDynamicColor,
                    onChanged: (value) => ref
                        .read(themeProvider.notifier)
                        .setUseDynamicColor(value),
                    showDivider: false,
                  ),
                ],
              ),
              if (!themeSettings.useDynamicColor)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: EdgeInsets.fromLTRB(
                      16 + wideListInset(context),
                      12,
                      16 + wideListInset(context),
                      0,
                    ),
                    child: _ColorPalettePicker(
                      currentColor: themeSettings.seedColorValue,
                      onColorSelected: (color) =>
                          ref.read(themeProvider.notifier).setSeedColor(color),
                    ),
                  ),
                ),
            ],

            ...settingsSectionSlivers(
              title: context.l10n.sectionTheme,
              connected: true,
              children: [
                _ThemeModeSelector(
                  currentMode: themeSettings.themeMode,
                  onChanged: (mode) =>
                      ref.read(themeProvider.notifier).setThemeMode(mode),
                ),
                if (themeSettings.style == AppThemeStyle.material &&
                    Theme.of(context).brightness == Brightness.dark)
                  SettingsSwitchItem(
                    icon: Icons.brightness_2,
                    title: context.l10n.appearanceAmoledDark,
                    subtitle: context.l10n.appearanceAmoledDarkSubtitle,
                    value: themeSettings.useAmoled,
                    onChanged: (value) =>
                        ref.read(themeProvider.notifier).setUseAmoled(value),
                    showDivider: false,
                  ),
              ],
            ),

            SliverToBoxAdapter(
              child: SettingsGroup(
                connected: true,
                children: [
                  SettingsSwitchItem(
                    icon: Icons.font_download_outlined,
                    title: context.l10n.appearanceUseSystemFont,
                    subtitle: context.l10n.appearanceUseSystemFontSubtitle,
                    value: themeSettings.useSystemFont,
                    onChanged: ref
                        .read(themeProvider.notifier)
                        .setUseSystemFont,
                  ),
                  SettingsSwitchItem(
                    icon: Icons.animation,
                    title: context.l10n.appearanceHeroAnimations,
                    subtitle: context.l10n.appearanceHeroAnimationsSubtitle,
                    value: settings.heroAnimationsEnabled,
                    onChanged: (value) => ref
                        .read(settingsProvider.notifier)
                        .setHeroAnimationsEnabled(value),
                  ),
                  const CustomFontSetting(),
                  SettingsSwitchItem(
                    icon: Icons.blur_on,
                    title: context.l10n.appearanceForceBlur,
                    subtitle: context.l10n.appearanceForceBlurSubtitle,
                    value: settings.forceBackdropBlur,
                    onChanged: (value) => ref
                        .read(settingsProvider.notifier)
                        .setForceBackdropBlur(value),
                    showDivider: false,
                  ),
                ],
              ),
            ),

            ...settingsSectionSlivers(
              title: context.l10n.sectionLanguage,
              connected: true,
              children: [
                _LanguageSelector(
                  currentLocale: settings.locale,
                  onChanged: (locale) =>
                      ref.read(settingsProvider.notifier).setLocale(locale),
                ),
              ],
            ),

            ...settingsSectionSlivers(
              title: context.l10n.sectionLayout,
              connected: true,
              children: [
                _HistoryViewSelector(
                  currentMode: settings.historyViewMode,
                  onChanged: (mode) => ref
                      .read(settingsProvider.notifier)
                      .setHistoryViewMode(mode),
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
}
