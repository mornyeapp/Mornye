import 'package:flutter/foundation.dart' show clampDouble;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:material_3_expressive/material_3_expressive.dart'
    show
        M3EButtonGroup,
        M3EButtonGroupAction,
        M3EButtonGroupType,
        M3EButtonSize,
        M3EButtonStyle;
import 'package:mornye/theme/app_tokens.dart';
import 'package:mornye/theme/material_expressive.dart';
import 'package:mornye/utils/desktop_platform.dart';

/// One tool in a [ToolButtonGroup].
class ToolButton {
  const ToolButton({
    required this.icon,
    required this.onPressed,
    this.label,
    this.tooltip,
    this.onLongPress,
  });

  final Widget icon;
  final String? label;
  final String? tooltip;

  /// Receives the tool button's own context, which a menu can anchor below.
  final ValueChanged<BuildContext> onPressed;
  final VoidCallback? onLongPress;
}

/// A page's tools (sort, filter, view) as one connected Material 3
/// Expressive button group, so the related controls read as one object, as
/// on Library pages and search results. The group is 44dp tall on phones
/// and 40dp for desktop pointer input; both keep the 48dp touch target.
class ToolButtonGroup extends StatefulWidget {
  const ToolButtonGroup({super.key, required this.tools});

  final List<ToolButton> tools;

  @override
  State<ToolButtonGroup> createState() => _ToolButtonGroupState();
}

class _ToolButtonGroupState extends State<ToolButtonGroup> {
  // The button group attaches each node to its tool's button, which makes
  // the node's context the button's own.
  final _focusNodes = <FocusNode>[];

  FocusNode _focusNodeAt(int index) {
    while (_focusNodes.length <= index) {
      _focusNodes.add(FocusNode(debugLabel: 'Tool $index'));
    }
    return _focusNodes[index];
  }

  BuildContext _toolContext(int index) =>
      _focusNodeAt(index).context ?? context;

  /// Runs the long press of the tool under the pointer, if it has one.
  void _handleLongPress(LongPressStartDetails details) {
    for (final (index, tool) in widget.tools.indexed) {
      final box = _focusNodeAt(index).context?.findRenderObject();
      if (box is! RenderBox || !box.hasSize) continue;
      final x = box.globalToLocal(details.globalPosition).dx;
      if (x >= 0 && x < box.size.width) {
        tool.onLongPress?.call();
        return;
      }
    }
  }

  @override
  void dispose() {
    for (final node in _focusNodes) {
      node.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tools = widget.tools;
    final height = isDesktopPlatform ? 40.0 : 44.0;
    return GestureDetector(
      onLongPressStart: tools.any((tool) => tool.onLongPress != null)
          ? _handleLongPress
          : null,
      excludeFromSemantics: true,
      child: _TouchTargetPadding(
        minHeight: context.tokens.minTouchTarget,
        child: MaterialExpressiveScope(
          skipAutofocus: true,
          child: M3EButtonGroup(
            type: M3EButtonGroupType.connected,
            style: M3EButtonStyle.filled,
            size: M3EButtonSize.sm.copyWith(height: height),
            // Tools are actions, not options: nothing stays selected, and a
            // press reports the tool through the selection callback.
            onSelectedIndexChanged: (index) {
              if (index != null) tools[index].onPressed(_toolContext(index));
            },
            actions: [
              for (final (index, tool) in tools.indexed)
                M3EButtonGroupAction(
                  icon: tool.icon,
                  label: tool.label == null ? null : Text(tool.label!),
                  tooltip: tool.tooltip,
                  focusNode: _focusNodeAt(index),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Grows [child] to [minHeight] and sends a touch above or below it to the
/// nearest point of [child], so a compact control keeps its full touch
/// target.
class _TouchTargetPadding extends SingleChildRenderObjectWidget {
  const _TouchTargetPadding({required this.minHeight, required super.child});

  final double minHeight;

  @override
  _RenderTouchTargetPadding createRenderObject(BuildContext context) =>
      _RenderTouchTargetPadding(minHeight);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderTouchTargetPadding renderObject,
  ) {
    renderObject.minHeight = minHeight;
  }
}

class _RenderTouchTargetPadding extends RenderShiftedBox {
  _RenderTouchTargetPadding(this._minHeight) : super(null);

  double _minHeight;

  set minHeight(double value) {
    if (value == _minHeight) return;
    _minHeight = value;
    markNeedsLayout();
  }

  Size _paddedSize(BoxConstraints constraints, Size childSize) =>
      constraints.constrain(
        Size(
          childSize.width,
          childSize.height < _minHeight ? _minHeight : childSize.height,
        ),
      );

  @override
  Size computeDryLayout(covariant BoxConstraints constraints) => _paddedSize(
    constraints,
    child?.getDryLayout(constraints.loosen()) ?? Size.zero,
  );

  @override
  void performLayout() {
    final child = this.child;
    if (child == null) {
      size = _paddedSize(constraints, Size.zero);
      return;
    }
    child.layout(constraints.loosen(), parentUsesSize: true);
    size = _paddedSize(constraints, child.size);
    (child.parentData! as BoxParentData).offset = Offset(
      0,
      (size.height - child.size.height) / 2,
    );
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    final child = this.child;
    if (child == null) return false;
    final offset = (child.parentData! as BoxParentData).offset;
    final bottom = child.size.height - 1;
    final local = Offset(
      position.dx - offset.dx,
      clampDouble(position.dy - offset.dy, 0, bottom < 0 ? 0 : bottom),
    );
    return result.addWithPaintOffset(
      offset: position - local,
      position: position,
      hitTest: (result, transformed) =>
          child.hitTest(result, position: transformed),
    );
  }
}
