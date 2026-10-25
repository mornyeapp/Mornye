import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart' show kPrimaryButton;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:mornye/theme/mornye_icons.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:mornye/utils/android_tv.dart';
import 'package:mornye/widgets/app_icon.dart';
import 'package:mornye/widgets/desktop/desktop_selection.dart';
import 'package:mornye/widgets/mornye_context_menu.dart';

/// One row of a desktop context menu. Use `Icons.*`; Mornye swaps in the
/// Cupertino glyph.
class ContextMenuAction {
  const ContextMenuAction({
    required this.icon,
    required this.label,
    required this.onSelected,
    this.destructive = false,
    this.checked = false,
  });

  final IconData icon;
  final String label;

  /// Runs after the menu has closed. Null shows the row disabled.
  final VoidCallback? onSelected;

  /// Draws the row in the error color. Put destructive rows in the last
  /// group, where the divider sets them apart.
  final bool destructive;

  /// Marks the active choice of a toggle, such as Favorite.
  final bool checked;
}

/// Mornye menus are as wide as the iOS popover, minus its touch padding.
const double _mornyeMenuWidth = 280;

/// Shows [groups] as a context menu at [position], in global coordinates.
///
/// Material opens a [MenuAnchor] with the M3 Expressive menu container;
/// Mornye opens the dense [MornyeContextMenu]. Empty groups are dropped and
/// the remaining ones are separated by dividers. The chosen action runs after
/// the menu closes, so it can open its own dialog or sheet. The future
/// completes after that action has started, with whether a row was chosen.
Future<bool> showContextMenu(
  BuildContext context, {
  required Offset position,
  required List<List<ContextMenuAction>> groups,
}) async {
  final visible = [
    for (final group in groups)
      if (group.isNotEmpty) group,
  ];
  if (visible.isEmpty) return false;
  final navigator = Navigator.of(context, rootNavigator: true);
  final themes = InheritedTheme.capture(from: context, to: navigator.context);
  if (context.isMornye) {
    final chosen = await showMornyeContextMenu<ContextMenuAction>(
      context: context,
      // The layout aligns the menu's trailing edge with the anchor's, so a
      // menu-wide anchor puts its leading edge at the pointer.
      anchor: Rect.fromLTWH(position.dx, position.dy - 8, _mornyeMenuWidth, 0),
      maxWidth: _mornyeMenuWidth,
      builder: (menuContext) => MornyeContextMenu(
        dense: true,
        groups: [
          for (final group in visible)
            [
              for (final action in group)
                MornyeMenuAction(
                  icon: mornyeIconFor(action.icon),
                  label: action.label,
                  selected: action.checked,
                  destructive: action.destructive,
                  onPressed: action.onSelected == null
                      ? null
                      : () => Navigator.pop(menuContext, action),
                ),
            ],
        ],
      ),
    );
    chosen?.onSelected?.call();
    return chosen != null;
  }
  var chosen = false;
  await navigator.push(
    _MaterialContextMenuRoute(
      position: position,
      groups: visible,
      themes: themes,
      barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
      onChosen: () => chosen = true,
    ),
  );
  // The menu pops first and runs the chosen row after that frame.
  await SchedulerBinding.instance.endOfFrame;
  return chosen;
}

/// The center of [context]'s render box, where keyboard-opened menus appear.
Offset? contextMenuOriginOf(BuildContext context) {
  final box = context.findRenderObject();
  if (box is! RenderBox || !box.attached || !box.hasSize) return null;
  return box.localToGlobal(box.size.center(Offset.zero));
}

/// The bottom-left corner of [context]'s render box, where a menu opened
/// from a button appears.
Offset? contextMenuPositionBelow(BuildContext context) {
  final box = context.findRenderObject();
  if (box is! RenderBox || !box.attached || !box.hasSize) return null;
  return box.localToGlobal(box.size.bottomLeft(Offset.zero));
}

/// Opens [onContextMenu] on desktop on a right-click, a Control-click on
/// macOS, or Shift+F10 and the Menu key while the item or its
/// [DesktopListScope] has focus. Phones and tablets get [child] unchanged;
/// their long press keeps the same actions.
class DesktopContextMenuRegion extends StatefulWidget {
  const DesktopContextMenuRegion({
    super.key,
    required this.onContextMenu,
    required this.child,
  });

  /// Opens the item's menu at a global position. Null turns the region off.
  final ValueChanged<Offset>? onContextMenu;
  final Widget child;

  @override
  State<DesktopContextMenuRegion> createState() =>
      _DesktopContextMenuRegionState();
}

class _DesktopContextMenuRegionState extends State<DesktopContextMenuRegion>
    implements DesktopContextMenuTarget {
  @override
  void openContextMenuFromKeyboard() {
    final origin = contextMenuOriginOf(context);
    if (origin != null) widget.onContextMenu?.call(origin);
  }

  void _handlePointerDown(PointerDownEvent event) {
    DesktopListScope.markCurrent(context, this);
    final controlClick =
        defaultTargetPlatform == TargetPlatform.macOS &&
        event.buttons == kPrimaryButton &&
        HardwareKeyboard.instance.isControlPressed;
    if (controlClick) widget.onContextMenu?.call(event.position);
  }

  @override
  Widget build(BuildContext context) {
    final onContextMenu = widget.onContextMenu;
    if ((!isDesktopPlatform && !isAndroidTv) || onContextMenu == null) {
      return widget.child;
    }
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: (_, event) {
        if (!isContextMenuKey(event)) return KeyEventResult.ignored;
        openContextMenuFromKeyboard();
        return KeyEventResult.handled;
      },
      child: Listener(
        onPointerDown: _handlePointerDown,
        child: GestureDetector(
          onSecondaryTapUp: (details) => onContextMenu(details.globalPosition),
          child: widget.child,
        ),
      ),
    );
  }
}

/// A full-window route that hosts a [MenuAnchor] opened at a point, so a
/// menu can open from any item without an anchor of its own.
class _MaterialContextMenuRoute extends PopupRoute<void> {
  _MaterialContextMenuRoute({
    required this.position,
    required this.groups,
    required this.themes,
    required this.barrierLabel,
    required this.onChosen,
  });

  final Offset position;
  final List<List<ContextMenuAction>> groups;
  final CapturedThemes themes;
  final VoidCallback onChosen;

  @override
  final String barrierLabel;

  @override
  Color? get barrierColor => null;

  // The menu closes itself on an outside tap and then pops this route.
  @override
  bool get barrierDismissible => false;

  @override
  Duration get transitionDuration => Duration.zero;

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) => themes.wrap(
    _MaterialContextMenu(
      position: position,
      groups: groups,
      onChosen: onChosen,
    ),
  );
}

class _MaterialContextMenu extends StatefulWidget {
  const _MaterialContextMenu({
    required this.position,
    required this.groups,
    required this.onChosen,
  });

  final Offset position;
  final List<List<ContextMenuAction>> groups;
  final VoidCallback onChosen;

  @override
  State<_MaterialContextMenu> createState() => _MaterialContextMenuState();
}

class _MaterialContextMenuState extends State<_MaterialContextMenu> {
  final _controller = MenuController();
  ModalRoute<Object?>? _route;
  bool _closed = false;

  @override
  void initState() {
    super.initState();
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final box = context.findRenderObject();
      final local = box is RenderBox
          ? box.globalToLocal(widget.position)
          : widget.position;
      _controller.open(position: local);
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _route = ModalRoute.of(context);
  }

  /// The menu closed itself (a choice, Escape or an outside click); remove
  /// the host route unless something else already popped it.
  void _handleClose() {
    if (_closed) return;
    _closed = true;
    final route = _route;
    if (route == null || !route.isActive) return;
    final navigator = route.navigator;
    if (route.isCurrent) {
      navigator?.pop();
    } else {
      navigator?.removeRoute(route);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    // The container, its radius and the item shape come from the app theme's
    // menu skin, shared with popup menus; rows keep the pointer density.
    final itemStyle = MenuItemButton.styleFrom(
      minimumSize: const Size(180, 40),
      padding: const EdgeInsets.symmetric(horizontal: 12),
    );
    // A checked row takes the selected item fill of the M3 Expressive
    // standard menu, as in M3EMenuPopup, and keeps its check.
    final checkedStyle = MenuItemButton.styleFrom(
      minimumSize: const Size(180, 40),
      padding: const EdgeInsets.symmetric(horizontal: 12),
      backgroundColor: colorScheme.tertiaryContainer,
      foregroundColor: colorScheme.onTertiaryContainer,
      iconColor: colorScheme.onTertiaryContainer,
      overlayColor: colorScheme.onTertiaryContainer,
    );
    // Focus the first enabled row so arrow keys and Escape work at once.
    final firstEnabled = widget.groups
        .expand((group) => group)
        .where((action) => action.onSelected != null)
        .firstOrNull;
    return MenuAnchor(
      controller: _controller,
      onClose: _handleClose,
      menuChildren: [
        for (var i = 0; i < widget.groups.length; i++) ...[
          if (i > 0) const Divider(height: 9, indent: 12, endIndent: 12),
          for (final action in widget.groups[i])
            MenuItemButton(
              autofocus: identical(action, firstEnabled),
              style: action.checked ? checkedStyle : itemStyle,
              leadingIcon: AppIcon(
                action.icon,
                size: 20,
                color: action.destructive ? colorScheme.error : null,
              ),
              trailingIcon: action.checked
                  ? const AppIcon(Icons.check, size: 20)
                  : null,
              onPressed: action.onSelected == null
                  ? null
                  : () {
                      widget.onChosen();
                      action.onSelected!();
                    },
              child: Text(
                action.label,
                style: action.destructive
                    ? TextStyle(color: colorScheme.error)
                    : null,
              ),
            ),
        ],
      ],
      child: const SizedBox.expand(),
    );
  }
}
