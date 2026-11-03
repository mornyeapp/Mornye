import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/services/shell_navigation_service.dart';
import 'package:mornye/theme/mornye_theme.dart';
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
    final tabs = desktopDestinationTabs(
      mornye: context.isMornye,
      showStore: showStore,
    );

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
          if (!tabs.contains(ShellTab.search))
            (l10n.mornyeSearch, keys(DesktopCommand.search)),
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
          (l10n.nowPlayingTabLyrics, keys(DesktopCommand.lyrics)),
          (l10n.nowPlayingUpNext, keys(DesktopCommand.upNext)),
          (
            l10n.desktopShortcutToggleSidebar,
            keys(DesktopCommand.toggleSidebar),
          ),
          (l10n.desktopMenuMiniPlayer, keys(DesktopCommand.miniPlayer)),
          (l10n.desktopWindowFullscreen, keys(DesktopCommand.fullScreen)),
          (l10n.desktopWindowBorderless, keys(DesktopCommand.borderless)),
        ],
      ),
    ];

    return Scaffold(
      body: CustomScrollView(
        slivers: [
          AppSliverHeader.page(title: l10n.settingsKeyboardShortcuts),
          for (final (title, rows) in sections)
            ...settingsSectionSlivers(
              title: title,
              children: [
                for (final (label, activators) in rows)
                  if (activators.isNotEmpty)
                    SettingsItem(
                      title: label,
                      trailing: _ShortcutKeys(
                        activators: activators,
                        platform: platform,
                      ),
                    ),
              ],
            ),
          const SliverToBoxAdapter(child: SizedBox(height: 24)),
        ],
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
