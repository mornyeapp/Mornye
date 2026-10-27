import 'package:flutter/material.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:mornye/theme/material_expressive.dart';
import 'package:mornye/widgets/app_icon.dart';
import 'package:mornye/widgets/expressive_button_group.dart';

/// Compact expressive transport/header actions with the same accessible target
/// and tooltip as the standard Material fallback.
class ExpressiveIconButton extends StatelessWidget {
  const ExpressiveIconButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.selected,
    this.size = 48,
    this.width,
    this.iconSize = 24,
    this.foregroundColor,
    this.backgroundColor,
  });

  final Widget icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final bool? selected;
  final double size;

  /// Wider than [size] tall for a pill, as a button group's segments are;
  /// square by default.
  final double? width;
  final double iconSize;
  final Color? foregroundColor;
  final Color? backgroundColor;

  @override
  Widget build(BuildContext context) {
    final icon = symbolIconWidget(this.icon);
    final fill = expressiveFill(
      Theme.of(context).colorScheme,
      foregroundColor,
      backgroundColor,
    );
    if (!materialExpressiveEnabled(context)) {
      return IconButton(
        icon: icon,
        iconSize: iconSize,
        tooltip: tooltip,
        onPressed: onPressed,
        isSelected: selected,
        style: ButtonStyle(
          minimumSize: WidgetStatePropertyAll(Size(width ?? size, size)),
          foregroundColor: fill.foregroundColor,
          backgroundColor: fill.backgroundColor,
        ),
      );
    }
    return Tooltip(
      message: tooltip,
      excludeFromSemantics: true,
      // One labeled node instead of a label plus an unnamed tap target.
      child: MergeSemantics(
        child: MaterialExpressiveScope(
          child: M3EIconButton(
            icon: IconTheme.merge(
              data: IconThemeData(size: iconSize),
              child: icon,
            ),
            semanticLabel: tooltip,
            onPressed: onPressed,
            isSelected: selected,
            // Widens with an expressive button group's squish.
            visualSize: Size(
              ExpressiveButtonGroupSlot.widthOf(context) ?? width ?? size,
              size,
            ),
            variant: backgroundColor == null
                ? M3EIconButtonVariant.standard
                : M3EIconButtonVariant.filled,
            decoration: fill,
          ),
        ),
      ),
    );
  }
}

/// Icon button colors that fade like Material's when disabled. Without a
/// [background] the button stays transparent.
M3EIconButtonDecoration expressiveFill(
  ColorScheme scheme,
  Color? foreground,
  Color? background,
) => M3EIconButtonDecoration(
  foregroundColor: WidgetStateProperty.resolveWith(
    (states) => states.contains(WidgetState.disabled)
        ? scheme.onSurface.withValues(alpha: 0.38)
        : foreground,
  ),
  backgroundColor: WidgetStateProperty.resolveWith(
    (states) => background == null
        ? Colors.transparent
        : states.contains(WidgetState.disabled)
        ? scheme.onSurface.withValues(alpha: 0.12)
        : background,
  ),
);
