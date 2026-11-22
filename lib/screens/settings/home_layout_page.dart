import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/home_layout.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/utils/adaptive_layout.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:mornye/utils/home_sections.dart';
import 'package:mornye/utils/nav_bar_inset.dart';
import 'package:mornye/widgets/app_alert_dialog.dart';
import 'package:mornye/widgets/app_icon.dart';
import 'package:mornye/widgets/app_sliver_header.dart';
import 'package:mornye/widgets/app_switch.dart';
import 'package:mornye/widgets/reorderable_priority_item.dart';
import 'package:mornye/widgets/scaled_drag_proxy.dart';
import 'package:mornye/widgets/settings_group.dart';

/// Where the person arranges Home: which sections show and in what order.
/// Every change applies at once.
class HomeLayoutPage extends ConsumerWidget {
  const HomeLayoutPage({super.key});

  /// Moves a section among the ones this style has. The other style's
  /// sections keep their places in the saved order.
  void _reorder(
    WidgetRef ref,
    bool Function(HomeSection) available,
    int from,
    int to,
  ) {
    final layout = ref.read(settingsProvider).homeLayout;
    final all = layout.sections;
    final listed = all.where(available).toList();
    listed.insert(to, listed.removeAt(from));
    var next = 0;
    ref
        .read(settingsProvider.notifier)
        .setHomeLayout(
          layout.withOrder([
            for (final section in all)
              available(section) ? listed[next++] : section,
          ]),
        );
  }

  Future<void> _reset(BuildContext context, WidgetRef ref) async {
    final l10n = context.l10n;
    final confirmed = await showAppDialog<bool>(
      context: context,
      builder: (context) => AppAlertDialog(
        title: Text(l10n.homeReset),
        content: Text(l10n.homeResetMessage),
        actions: [
          AppDialogAction(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l10n.dialogCancel),
          ),
          AppDialogAction(
            isDestructive: true,
            onPressed: () => Navigator.pop(context, true),
            child: Text(l10n.libraryFilterReset),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      ref.read(settingsProvider.notifier).resetHomeLayout();
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final mornye = context.isMornye;
    final settings = ref.watch(settingsProvider);
    final player = ref.watch(playerUiEnabledProvider);
    bool available(HomeSection section) => section.availableIn(
      mornye: mornye,
      player: player,
      desktop: isDesktopPlatform,
    );
    final sections = settings.homeLayout.sections.where(available).toList();
    final side = wideListInset(context);
    return Scaffold(
      body: CustomScrollView(
        slivers: [
          AppSliverHeader.page(title: l10n.homeEdit),
          SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.fromLTRB(32 + side, 8, 32 + side, 16),
              child: Text(
                l10n.homeEditHint,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
          SliverPadding(
            padding: EdgeInsets.symmetric(horizontal: 16 + side),
            sliver: SliverReorderableList(
              proxyDecorator: ScaledDragProxy.plain,
              itemCount: sections.length,
              onReorderItem: (from, to) => _reorder(ref, available, from, to),
              itemBuilder: (context, index) {
                final section = sections[index];
                return _SectionRow(
                  key: ValueKey(section),
                  index: index,
                  first: index == 0,
                  last: index == sections.length - 1,
                  icon: homeSectionIcon(section),
                  title: homeSectionName(l10n, section),
                  subtitle: homeSectionAbout(l10n, section),
                  shown: settings.homeShows(section),
                  onShown: (shown) => ref
                      .read(settingsProvider.notifier)
                      .setHomeSectionVisible(section, shown),
                );
              },
            ),
          ),
          const SliverToBoxAdapter(child: SizedBox(height: 16)),
          SliverToBoxAdapter(
            child: SettingsGroup(
              children: [
                SettingsItem(
                  key: const ValueKey('home-reset'),
                  icon: Icons.restart_alt,
                  title: l10n.homeReset,
                  titleColor: theme.colorScheme.error,
                  // An action, not a way to another page: no chevron.
                  trailing: const SizedBox.shrink(),
                  onTap: () => _reset(context, ref),
                  showDivider: false,
                ),
              ],
            ),
          ),
          const SliverToBoxAdapter(child: SizedBox(height: 32)),
          const NavBarSliverSpacer(),
        ],
      ),
    );
  }
}

/// A section as one row of the connected list: its switch, and a handle to
/// drag it by. A long press anywhere on the row drags it too.
class _SectionRow extends StatelessWidget {
  const _SectionRow({
    super.key,
    required this.index,
    required this.first,
    required this.last,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.shown,
    required this.onShown,
  });

  final int index;
  final bool first;
  final bool last;
  final IconData icon;
  final String title;
  final String subtitle;
  final bool shown;
  final ValueChanged<bool> onShown;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    // A hidden section reads as set aside.
    final onRow = shown ? colorScheme.onSurface : colorScheme.onSurfaceVariant;
    return Padding(
      padding: EdgeInsets.only(bottom: priorityRowGap(context, last: last)),
      child: Material(
        color: settingsGroupColor(context),
        borderRadius: priorityRowRadius(context, first: first, last: last),
        clipBehavior: Clip.antiAlias,
        child: ReorderableDelayedDragStartListener(
          index: index,
          child: Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(16, 10, 4, 10),
            child: Row(
              children: [
                if (!context.isMornye) ...[
                  AppIcon(
                    icon,
                    color: shown
                        ? colorScheme.primary
                        : colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 16),
                ],
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyLarge?.copyWith(
                          color: onRow,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      Text(
                        subtitle,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                AppSwitch(
                  value: shown,
                  semanticLabel: title,
                  onChanged: onShown,
                ),
                ReorderableDragStartListener(
                  index: index,
                  child: SizedBox.square(
                    dimension: 48,
                    child: Icon(
                      Icons.drag_handle,
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
