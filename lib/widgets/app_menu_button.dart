import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:mornye/theme/app_motion.dart';
import 'package:mornye/theme/material_expressive.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/widgets/app_icon.dart';
import 'package:mornye/widgets/app_icon_button.dart';
import 'package:mornye/widgets/mornye_context_menu.dart';

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
    if (context.isMornye) {
      return Builder(
        builder: (buttonContext) => AppIconButton(
          icon: icon,
          tooltip: tooltip,
          onPressed: items.isEmpty
              ? null
              : () async {
                  final picked = await showMornyeContextMenu<T>(
                    context: buttonContext,
                    builder: (menuContext) => MornyeContextMenu(
                      dense: true,
                      groups: [
                        [
                          for (final item in items)
                            MornyeMenuAction(
                              icon: switch (item.leading) {
                                Icon(:final icon?) => icon,
                                AppIcon(:final icon?) => icon,
                                _ => null,
                              },
                              label: item.label,
                              selected: item.selected == true,
                              destructive: item.destructive,
                              onPressed: () =>
                                  Navigator.of(menuContext).pop(item.value),
                            ),
                        ],
                      ],
                    ),
                  );
                  if (picked != null) onSelected(picked);
                },
        ),
      );
    }
    if (materialExpressiveEnabled(context)) {
      return MaterialExpressiveScope(child: _ExpressiveMenuAnchor<T>(this));
    }
    final colorScheme = Theme.of(context).colorScheme;
    return PopupMenuButton<T>(
      icon: symbolIconWidget(icon),
      tooltip: tooltip,
      offset: offset,
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
                    child: symbolIconWidget(item.leading!),
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
                  AppIcon.adaptive(
                    Icons.check,
                    size: 18,
                    color: colorScheme.primary,
                  ),
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

/// Opens a Material 3 Expressive menu popup anchored to [context]'s render
/// box, falling back to [showMenu] when expressive motion is off.
Future<T?> showAppMenuPopup<T extends Object>({
  required BuildContext context,
  required List<AppMenuItem<T>> items,
  bool preferAbove = false,
  bool alignStart = false,
  Rect? fallbackAnchor,
}) {
  if (items.isEmpty) return Future<T?>.value();
  if (!materialExpressiveEnabled(context)) {
    final colorScheme = Theme.of(context).colorScheme;
    final box = context.findRenderObject();
    final anchor =
        fallbackAnchor ??
        (box is RenderBox && box.attached && box.hasSize
            ? box.localToGlobal(Offset.zero) & box.size
            : Rect.zero);
    return showMenu<T>(
      context: context,
      position: RelativeRect.fromRect(
        anchor,
        Offset.zero & MediaQuery.sizeOf(context),
      ),
      popUpAnimationStyle: AppMotion.surfaceEntrance(context),
      items: [
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
                    child: symbolIconWidget(item.leading!),
                  ),
                  const SizedBox(width: 12),
                ],
                Flexible(
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
              ],
            ),
          ),
      ],
    );
  }
  final overlay = Overlay.of(context, rootOverlay: true);
  final anchorBox = context.findRenderObject();
  final overlayBox = overlay.context.findRenderObject();
  final anchor =
      anchorBox is RenderBox &&
          anchorBox.attached &&
          anchorBox.hasSize &&
          overlayBox is RenderBox
      ? MatrixUtils.transformRect(
          anchorBox.getTransformTo(overlayBox),
          Offset.zero & anchorBox.size,
        )
      : (fallbackAnchor ?? Rect.zero);
  T? selectedValue;
  for (final item in items) {
    if (item.selected == true) selectedValue = item.value;
  }
  final themes = InheritedTheme.capture(from: context, to: overlay.context);
  final result = Completer<T?>();
  void finish(T? value) {
    if (!result.isCompleted) result.complete(value);
  }

  late final OverlayEntry entry;
  var removed = false;
  void remove() {
    if (removed) return;
    removed = true;
    entry.remove();
    entry.dispose();
    finish(null);
  }

  final popupPosition = switch ((preferAbove, alignStart)) {
    (true, true) => M3EMenuAnchorPosition.topStart,
    (true, false) => M3EMenuAnchorPosition.topEnd,
    (false, true) => M3EMenuAnchorPosition.bottomStart,
    (false, false) => M3EMenuAnchorPosition.bottomEnd,
  };
  final popup = M3EMenuPopup<T>(
    anchor: anchor,
    historyRoute: ModalRoute.of(context),
    position: popupPosition,
    selectedValue: selectedValue,
    children: [
      for (final item in items)
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
    onSelected: (value) => finish(value is T ? value : null),
    onDismiss: () => finish(null),
    onRemove: remove,
  );
  entry = OverlayEntry(
    builder: (context) => themes.wrap(
      MaterialExpressiveScope(
        child: ScrollConfiguration(
          behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
          child: popup,
        ),
      ),
    ),
  );
  overlay.insert(entry);
  return result.future;
}
