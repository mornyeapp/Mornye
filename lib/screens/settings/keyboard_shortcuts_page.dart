import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/services/shell_navigation_service.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/utils/nav_bar_inset.dart';
import 'package:mornye/widgets/app_sliver_header.dart';
import 'package:mornye/widgets/desktop/desktop_commands.dart';
import 'package:mornye/widgets/settings_group.dart';

/// Lists the desktop keyboard shortcuts, read from the same bindings the app
/// registers, so the page cannot drift from what the keys do.
class KeyboardShortcutsPage extends ConsumerWidget {
  const KeyboardShortcutsPage({super.key, this.platform});

  /// Overrides the host platform, which decides Command or Control.
  final TargetPlatform? platform;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final showStore = ref.watch(
      settingsProvider.select((s) => s.showExtensionStore),
    );
    final tabs = desktopDestinationTabs(showStore: showStore);
    // With an external player the player's keys do nothing; leave them out.
    final player = ref.watch(playerUiEnabledProvider);

    List<SingleActivator> keys(DesktopCommand command) =>
        desktopCommandShortcuts(command, platform);
    // Search and Settings also have their own command, listed in one row
    // with the destination's number.
    List<SingleActivator> tabKeys(ShellTab tab) => [
      if (tab == ShellTab.search) ...keys(DesktopCommand.search),
      if (tab == ShellTab.settings) ...keys(DesktopCommand.settings),
      if (tabs.indexOf(tab) < 5)
        desktopDestinationShortcut(tabs.indexOf(tab) + 1, platform),
    ];
    String tabLabel(ShellTab tab) => switch (tab) {
      ShellTab.home => l10n.navHome,
      ShellTab.library => l10n.navLibrary,
      ShellTab.repository => l10n.navStore,
      ShellTab.search => l10n.mornyeSearch,
      ShellTab.settings => l10n.navSettings,
    };

    final sections = <(String, List<(String, List<SingleActivator>)>)>[
      (
        l10n.desktopMenuFile,
        [
          (l10n.openAudioFiles, keys(DesktopCommand.openAudioFiles)),
          (l10n.openAudioFolder, keys(DesktopCommand.openAudioFolder)),
        ],
      ),
      if (player)
        (
          l10n.desktopMenuControls,
          [
            (l10n.desktopMenuPlayPause, keys(DesktopCommand.playPause)),
            (l10n.nowPlayingNextTrack, keys(DesktopCommand.next)),
            (l10n.nowPlayingPreviousTrack, keys(DesktopCommand.previous)),
            (l10n.desktopVolumeUp, keys(DesktopCommand.volumeUp)),
            (l10n.desktopVolumeDown, keys(DesktopCommand.volumeDown)),
          ],
        ),
      (
        l10n.desktopShortcutsNavigation,
        [
          for (final tab in tabs) (tabLabel(tab), tabKeys(tab)),
          (
            MaterialLocalizations.of(context).backButtonTooltip,
            keys(DesktopCommand.back),
          ),
          (l10n.desktopShortcutForward, keys(DesktopCommand.forward)),
          (l10n.desktopMenuRefresh, keys(DesktopCommand.refresh)),
          (l10n.desktopShortcutDismiss, keys(DesktopCommand.dismiss)),
        ],
      ),
      (
        l10n.desktopMenuView,
        [
          if (player) ...[
            (l10n.nowPlayingTabLyrics, keys(DesktopCommand.lyrics)),
            (l10n.nowPlayingUpNext, keys(DesktopCommand.upNext)),
          ],
          (
            l10n.desktopShortcutToggleSidebar,
            keys(DesktopCommand.toggleSidebar),
          ),
          if (player)
            (l10n.desktopMenuMiniPlayer, keys(DesktopCommand.miniPlayer)),
          (l10n.desktopWindowFullscreen, keys(DesktopCommand.fullScreen)),
          (l10n.desktopWindowBorderless, keys(DesktopCommand.borderless)),
        ],
      ),
    ];

    return MornyeSettingsTheme(
      child: Scaffold(
        body: CustomScrollView(
          slivers: [
            AppSliverHeader.page(title: l10n.settingsKeyboardShortcuts),
            for (final (title, rows) in sections) ...[
              () {
                final active = [
                  for (final row in rows)
                    if (row.$2.isNotEmpty) row,
                ];
                return SliverMainAxisGroup(
                  slivers: settingsSectionSlivers(
                    title: title,
                    children: [
                      for (var i = 0; i < active.length; i++)
                        SettingsItem(
                          title: active[i].$1,
                          showDivider: i < active.length - 1,
                          trailing: _ShortcutKeys(
                            activators: active[i].$2,
                            platform: platform,
                          ),
                        ),
                    ],
                  ),
                );
              }(),
            ],
            const NavBarSliverSpacer(),
          ],
        ),
      ),
    );
  }
}

class _ShortcutKeys extends StatelessWidget {
  const _ShortcutKeys({required this.activators, this.platform});

  final List<SingleActivator> activators;
  final TargetPlatform? platform;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Text(
      activators
          .map((activator) => desktopShortcutLabel(activator, platform))
          .join('  ·  '),
      style: theme.textTheme.bodyMedium?.copyWith(
        color: theme.colorScheme.onSurfaceVariant,
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
    );
  }
}
