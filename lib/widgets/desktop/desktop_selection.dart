import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:mornye/utils/ordered_range_selection.dart';

/// How a desktop click changes a list selection.
enum DesktopClick {
  /// A plain click: the item becomes the whole selection.
  replace,

  /// Cmd-click on macOS, Ctrl-click elsewhere: adds or removes the item.
  toggle,

  /// Shift-click: selects the range from the anchor to the item.
  extend,
}

/// Applies a desktop click of [kind] on [target] to [selected] and returns
/// the new range anchor. [orderedIds] lists the visible items in display
/// order. A Shift range replaces the selection and keeps [anchor], as in
/// Finder and Explorer.
T? applyDesktopClickTo<T>(
  Set<T> selected, {
  required T target,
  required DesktopClick kind,
  required List<T> orderedIds,
  required T? anchor,
}) {
  switch (kind) {
    case DesktopClick.replace:
      selected
        ..clear()
        ..add(target);
      return target;
    case DesktopClick.toggle:
      return toggleOrderedSelection(selected: selected, target: target);
    case DesktopClick.extend:
      selected.clear();
      addOrderedSelectionRange(
        selected: selected,
        visibleItems: orderedIds,
        target: target,
        anchor: anchor,
      );
      return anchor ?? target;
  }
}

/// Command on macOS, Control elsewhere.
bool get desktopPrimaryModifierPressed {
  final keyboard = HardwareKeyboard.instance;
  return defaultTargetPlatform == TargetPlatform.macOS
      ? keyboard.isMetaPressed
      : keyboard.isControlPressed;
}

/// The selection change for a click made with the modifiers held right now.
DesktopClick desktopClickKind() {
  if (HardwareKeyboard.instance.isShiftPressed) return DesktopClick.extend;
  if (desktopPrimaryModifierPressed) return DesktopClick.toggle;
  return DesktopClick.replace;
}

/// Whether [event] is Shift+F10 or the Menu key, which open the context menu
/// of the focused item.
bool isContextMenuKey(KeyEvent event) {
  if (event is! KeyDownEvent) return false;
  final key = event.logicalKey;
  if (key == LogicalKeyboardKey.contextMenu) return true;
  return key == LogicalKeyboardKey.f10 &&
      HardwareKeyboard.instance.isShiftPressed;
}

/// Detects double clicks on rows that rebuild between the two clicks, which
/// would reset a per-widget recognizer.
abstract final class DesktopDoubleClick {
  /// The macOS default; Windows uses 500 ms as well.
  static const timeout = Duration(milliseconds: 500);

  static Object? _lastTarget;
  static DateTime? _lastAt;

  /// Records a plain click on [target] and returns true when it completes a
  /// double click on the same target.
  static bool register(Object target) {
    final now = DateTime.now();
    final last = _lastAt;
    final isDouble =
        _lastTarget == target &&
        last != null &&
        now.difference(last) <= timeout;
    _lastTarget = isDouble ? null : target;
    _lastAt = isDouble ? null : now;
    return isDouble;
  }

  /// Forgets the last click, so the next one starts a new sequence.
  static void reset() {
    _lastTarget = null;
    _lastAt = null;
  }
}

/// Applies a desktop click on a row: a plain click runs [activate], as a tap
/// does on a phone, and Cmd/Ctrl-click or Shift-click runs [select] with the
/// click kind. The second click of a double click does nothing, so it never
/// activates the row twice. Returns the click kind, or null for a plain
/// click.
DesktopClick? handleDesktopRowClick(
  Object target, {
  required ValueChanged<DesktopClick> select,
  required VoidCallback activate,
}) {
  final kind = desktopClickKind();
  if (kind == DesktopClick.replace) {
    if (!DesktopDoubleClick.register(target)) activate();
    return null;
  }
  DesktopDoubleClick.reset();
  select(kind);
  return kind;
}

/// An item that can open its context menu from the keyboard.
abstract interface class DesktopContextMenuTarget {
  bool get mounted;

  void openContextMenuFromKeyboard();
}

/// Keyboard handling for a selectable desktop list or grid.
///
/// A click anywhere inside takes keyboard focus for the list (the scope node
/// itself, so Space still toggles playback). While it has focus:
/// Cmd/Ctrl+A runs [onSelectAll], Escape runs [onClearSelection], Delete or
/// Backspace runs [onDelete], Enter runs [onActivate], and Shift+F10 or the
/// Menu key opens the context menu of the item clicked last. Text fields keep
/// their own keys. Phones and tablets get [child] unchanged.
class DesktopListScope extends StatefulWidget {
  const DesktopListScope({
    super.key,
    required this.child,
    this.onSelectAll,
    this.onClearSelection,
    this.onDelete,
    this.onActivate,
  });

  final Widget child;
  final VoidCallback? onSelectAll;

  /// Null while nothing is selected, so Escape falls through and closes the
  /// page.
  final VoidCallback? onClearSelection;

  /// Removes the selection; null where the list has no removal.
  final VoidCallback? onDelete;

  /// Plays or opens the selection anchor.
  final VoidCallback? onActivate;

  /// Records [target] as the item Shift+F10 opens a menu for.
  static void markCurrent(
    BuildContext context,
    DesktopContextMenuTarget target,
  ) {
    context.findAncestorStateOfType<_DesktopListScopeState>()?._current =
        target;
  }

  @override
  State<DesktopListScope> createState() => _DesktopListScopeState();
}

class _DesktopListScopeState extends State<DesktopListScope> {
  final _node = FocusScopeNode(debugLabel: 'DesktopListScope');
  DesktopContextMenuTarget? _current;

  @override
  void dispose() {
    _node.dispose();
    super.dispose();
  }

  bool get _editingText =>
      FocusManager.instance.primaryFocus?.context
          ?.findAncestorStateOfType<EditableTextState>() !=
      null;

  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    if (_editingText) return KeyEventResult.ignored;
    final keyboard = HardwareKeyboard.instance;
    final key = event.logicalKey;
    if (isContextMenuKey(event)) {
      final current = _current;
      if (current == null || !current.mounted) return KeyEventResult.ignored;
      current.openContextMenuFromKeyboard();
      return KeyEventResult.handled;
    }
    final onSelectAll = widget.onSelectAll;
    if (key == LogicalKeyboardKey.keyA &&
        desktopPrimaryModifierPressed &&
        !keyboard.isShiftPressed &&
        !keyboard.isAltPressed &&
        onSelectAll != null) {
      onSelectAll();
      return KeyEventResult.handled;
    }
    final onClear = widget.onClearSelection;
    if (key == LogicalKeyboardKey.escape && onClear != null) {
      onClear();
      return KeyEventResult.handled;
    }
    // A focused button or row keeps Enter and Delete for itself.
    if (FocusManager.instance.primaryFocus != _node) {
      return KeyEventResult.ignored;
    }
    final onDelete = widget.onDelete;
    if ((key == LogicalKeyboardKey.delete ||
            key == LogicalKeyboardKey.backspace) &&
        onDelete != null) {
      onDelete();
      return KeyEventResult.handled;
    }
    final onActivate = widget.onActivate;
    if ((key == LogicalKeyboardKey.enter ||
            key == LogicalKeyboardKey.numpadEnter) &&
        onActivate != null) {
      onActivate();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _claimFocus(PointerDownEvent event) {
    final primary = FocusManager.instance.primaryFocus;
    if (primary == _node) return;
    // Clicking inside a focused text field keeps its focus, so text
    // selection still works.
    if (_editingText) {
      final box = primary?.context?.findRenderObject();
      if (box is RenderBox &&
          box.attached &&
          box.hasSize &&
          (box.localToGlobal(Offset.zero) & box.size).contains(
            event.position,
          )) {
        return;
      }
    }
    _node.requestScopeFocus();
  }

  @override
  Widget build(BuildContext context) {
    if (!isDesktopPlatform) return widget.child;
    return FocusScope(
      node: _node,
      onKeyEvent: _handleKey,
      child: Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: _claimFocus,
        child: widget.child,
      ),
    );
  }
}
