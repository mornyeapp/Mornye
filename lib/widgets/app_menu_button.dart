import 'package:flutter/material.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:mornye/theme/app_motion.dart';
import 'package:mornye/theme/material_expressive.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/widgets/app_icon_button.dart';

/// One row of an [AppMenuButton].
class AppMenuItem<T extends Object> {
  const AppMenuItem({
    required this.value,
    required this.label,
    this.leading,
    this.selected,
    this.destructive = false,
  });

  final T value;
  final String label;
  final Widget? leading;

  /// Non-null for single-select menus: the row shows a check when true.
  final bool? selected;
  final bool destructive;
}

/// Overflow and picker menus. Expressive builds open the M3E menu from an
/// icon button; Mornye and reduced motion keep the popup menu.
class AppMenuButton<T extends Object> extends StatelessWidget {
  const AppMenuButton({
    super.key,
    required this.icon,
    required this.items,
    required this.onSelected,
    this.tooltip,
    this.offset = Offset.zero,
    this.alignStart = false,
  });

  final Widget icon;
  final List<AppMenuItem<T>> items;
  final ValueChanged<T> onSelected;
  final String? tooltip;

  /// Popup offset; the M3E menu places itself below the anchor.
  final Offset offset;

  /// Opens the M3E menu from the anchor's start edge, for anchors near the
  /// leading side; overflow buttons at the trailing edge open from the end.
  final bool alignStart;

  @override
  Widget build(BuildContext context) {
    if (materialExpressiveEnabled(context)) {
      return MaterialExpressiveScope(child: _ExpressiveMenuAnchor<T>(this));
    }
    final colorScheme = Theme.of(context).colorScheme;
    return PopupMenuButton<T>(
      icon: icon,
      tooltip: tooltip,
      offset: offset,
      shape: context.isMornye
          ? RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))
          : null,
      popUpAnimationStyle: AppMotion.surfaceEntrance(context),
      onSelected: onSelected,
      itemBuilder: (context) => [
        for (final item in items)
          PopupMenuItem<T>(
            value: item.value,
            child: Row(
              children: [
                if (item.leading != null) ...[
                  IconTheme.merge(
                    data: IconThemeData(
                      size: 20,
                      color: item.destructive
                          ? colorScheme.error
                          : item.selected == true
                          ? colorScheme.primary
                          : colorScheme.onSurfaceVariant,
                    ),
                    child: item.leading!,
                  ),
                  const SizedBox(width: 12),
                ],
                Expanded(
                  child: Text(
                    item.label,
                    style: TextStyle(
                      color: item.destructive ? colorScheme.error : null,
                      fontWeight: item.selected == true
                          ? FontWeight.w600
                          : null,
                    ),
                  ),
                ),
                if (item.selected == true)
                  Icon(Icons.check, size: 18, color: colorScheme.primary),
              ],
            ),
          ),
      ],
    );
  }
}

/// Icon button that opens the M3E menu popup, one popup at a time.
///
/// [M3EMenu] measures its anchor against the nearest overlay but inserts the
/// popup into the root one; beside the navigation rail those differ by the
/// rail width, so the anchor is measured against the root overlay here.
class _ExpressiveMenuAnchor<T extends Object> extends StatefulWidget {
  const _ExpressiveMenuAnchor(this.menu);

  final AppMenuButton<T> menu;

  @override
  State<_ExpressiveMenuAnchor<T>> createState() =>
      _ExpressiveMenuAnchorState<T>();
}

class _ExpressiveMenuAnchorState<T extends Object>
    extends State<_ExpressiveMenuAnchor<T>> {
  OverlayEntry? _entry;

  @override
  void dispose() {
    _removeMenu();
    super.dispose();
  }

  void _removeMenu() {
    final entry = _entry;
    _entry = null;
    entry?.remove();
    entry?.dispose();
  }

  void _openMenu() {
    if (_entry != null || widget.menu.items.isEmpty) return;
    final overlay = Overlay.of(context, rootOverlay: true);
    final anchorBox = context.findRenderObject();
    final overlayBox = overlay.context.findRenderObject();
    if (anchorBox is! RenderBox ||
        !anchorBox.attached ||
        !anchorBox.hasSize ||
        overlayBox is! RenderBox) {
      return;
    }
    final anchor = MatrixUtils.transformRect(
      anchorBox.getTransformTo(overlayBox),
      Offset.zero & anchorBox.size,
    );
    final menu = widget.menu;
    T? selectedValue;
    for (final item in menu.items) {
      if (item.selected == true) selectedValue = item.value;
    }
    final themes = InheritedTheme.capture(from: context, to: overlay.context);
    final popup = M3EMenuPopup<T>(
      anchor: anchor,
      historyRoute: ModalRoute.of(context),
      position: menu.alignStart
          ? M3EMenuAnchorPosition.bottomStart
          : M3EMenuAnchorPosition.bottomEnd,
      selectedValue: selectedValue,
      children: [
        for (final item in menu.items)
          if (item.selected != null)
            M3EMenuSelectable(
              label: item.label,
              value: item.value,
              leading: item.leading,
              selected: item.selected!,
            )
          else
            M3EMenuEntry(
              label: item.label,
              value: item.value,
              leading: item.leading,
              isDestructive: item.destructive,
            ),
      ],
      onSelected: (value) {
        if (mounted && value is T) menu.onSelected(value);
      },
      onDismiss: () {},
      onRemove: _removeMenu,
    );
    _entry = OverlayEntry(
      builder: (context) => themes.wrap(
        MaterialExpressiveScope(
          // The popup draws its own scrollbar; the app's desktop scroll
          // behavior would stack a second one beside it.
          child: ScrollConfiguration(
            behavior: ScrollConfiguration.of(
              context,
            ).copyWith(scrollbars: false),
            child: popup,
          ),
        ),
      ),
    );
    overlay.insert(_entry!);
  }

  @override
  Widget build(BuildContext context) => AppIconButton(
    icon: widget.menu.icon,
    tooltip: widget.menu.tooltip,
    onPressed: _openMenu,
  );
}
