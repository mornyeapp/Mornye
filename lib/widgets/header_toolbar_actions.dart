import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:mornye/widgets/album_detail_header.dart';
import 'package:mornye/widgets/desktop/context_menu.dart';

/// The most trailing controls a phone page toolbar shows.
const headerToolbarLimit = 2;

/// A phone page toolbar's [sort] and [actions]: all as buttons while they
/// fit [headerToolbarLimit], else [sort] and one More menu with the rest.
///
/// [actions] is built in this widget, so the providers it watches rebuild
/// only the toolbar. Desktop shows every action as a button.
class HeaderToolbarActions extends ConsumerWidget {
  const HeaderToolbarActions({super.key, this.sort, required this.actions});

  final Widget? sort;
  final List<ContextMenuAction> Function(BuildContext context, WidgetRef ref)
  actions;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final all = actions(context, ref);
    final fits =
        isDesktopPlatform ||
        (sort == null ? 0 : 1) + all.length <= headerToolbarLimit;
    return HeaderToolbarGroup(
      children: [
        ?sort,
        if (fits)
          for (final action in all)
            HeaderCircleButton(
              icon: action.icon,
              tooltip: action.label,
              onPressed: action.onSelected,
            ),
        if (!fits) HeaderMoreButton(groups: () => [all]),
      ],
    );
  }
}

/// Trailing toolbar controls that never touch: 8 dp apart in Material, in
/// one glass capsule in Mornye. Desktop lays them out as before.
class HeaderToolbarGroup extends StatelessWidget {
  const HeaderToolbarGroup({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    if (children.isEmpty) return const SizedBox.shrink();
    if (children.length == 1) return children.single;
    if (isDesktopPlatform) {
      return Row(mainAxisSize: MainAxisSize.min, children: children);
    }
    if (context.isMornye) return MornyeActionCapsule(children: children);
    return Row(mainAxisSize: MainAxisSize.min, spacing: 8, children: children);
  }
}
