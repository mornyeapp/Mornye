import 'package:flutter/material.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:mornye/theme/material_expressive.dart';
import 'package:mornye/widgets/app_icon.dart';

enum _AppIconButtonVariant { standard, filled, tonal }

/// Drop-in [IconButton] with the Material 3 Expressive shape and press motion.
///
/// Mornye, reduced motion and dense buttons ([padding], [constraints],
/// [visualDensity] or a sizing [style]) keep the exact [IconButton] layout.
class AppIconButton extends StatelessWidget {
  const AppIconButton({
    super.key,
    required this.icon,
    required this.onPressed,
    this.tooltip,
    this.color,
    this.iconSize,
    this.isSelected,
    this.selectedIcon,
    this.style,
    this.padding,
    this.constraints,
    this.visualDensity,
  }) : _variant = _AppIconButtonVariant.standard;

  const AppIconButton.filled({
    super.key,
    required this.icon,
    required this.onPressed,
    this.tooltip,
    this.color,
    this.iconSize,
    this.isSelected,
    this.selectedIcon,
    this.style,
    this.padding,
    this.constraints,
    this.visualDensity,
  }) : _variant = _AppIconButtonVariant.filled;

  const AppIconButton.filledTonal({
    super.key,
    required this.icon,
    required this.onPressed,
    this.tooltip,
    this.color,
    this.iconSize,
    this.isSelected,
    this.selectedIcon,
    this.style,
    this.padding,
    this.constraints,
    this.visualDensity,
  }) : _variant = _AppIconButtonVariant.tonal;

  final Widget icon;
  final VoidCallback? onPressed;
  final String? tooltip;
  final Color? color;
  final double? iconSize;
  final bool? isSelected;
  final Widget? selectedIcon;
  final ButtonStyle? style;
  final EdgeInsetsGeometry? padding;
  final BoxConstraints? constraints;
  final VisualDensity? visualDensity;
  final _AppIconButtonVariant _variant;

  bool get _keepsMaterialLayout {
    final style = this.style;
    return padding != null ||
        constraints != null ||
        visualDensity != null ||
        style != null &&
            (style.padding != null ||
                style.minimumSize != null ||
                style.fixedSize != null ||
                style.maximumSize != null ||
                style.visualDensity != null ||
                style.tapTargetSize != null ||
                style.shape != null ||
                style.iconSize != null);
  }

  @override
  Widget build(BuildContext context) {
    final icon = symbolIconWidget(this.icon);
    final selectedIcon = this.selectedIcon == null
        ? null
        : symbolIconWidget(this.selectedIcon!);
    if (!materialExpressiveEnabled(context) || _keepsMaterialLayout) {
      return switch (_variant) {
        _AppIconButtonVariant.standard => IconButton(
          icon: icon,
          selectedIcon: selectedIcon,
          onPressed: onPressed,
          tooltip: tooltip,
          color: color,
          iconSize: iconSize,
          isSelected: isSelected,
          style: style,
          padding: padding,
          constraints: constraints,
          visualDensity: visualDensity,
        ),
        _AppIconButtonVariant.filled => IconButton.filled(
          icon: icon,
          selectedIcon: selectedIcon,
          onPressed: onPressed,
          tooltip: tooltip,
          color: color,
          iconSize: iconSize,
          isSelected: isSelected,
          style: style,
          padding: padding,
          constraints: constraints,
          visualDensity: visualDensity,
        ),
        _AppIconButtonVariant.tonal => IconButton.filledTonal(
          icon: icon,
          selectedIcon: selectedIcon,
          onPressed: onPressed,
          tooltip: tooltip,
          color: color,
          iconSize: iconSize,
          isSelected: isSelected,
          style: style,
          padding: padding,
          constraints: constraints,
          visualDensity: visualDensity,
        ),
      };
    }
    final enabledColor = color;
    final foreground =
        style?.foregroundColor ??
        (enabledColor == null
            ? null
            : WidgetStateProperty.resolveWith<Color?>(
                (states) =>
                    states.contains(WidgetState.disabled) ? null : enabledColor,
              ));
    Widget sized(Widget icon) => iconSize == null
        ? icon
        : IconTheme.merge(
            data: IconThemeData(size: iconSize),
            child: icon,
          );
    // M3EIconButton labels an outer node and leaves its inner tap target
    // unnamed; merge them so screen readers find one labeled button.
    final button = MergeSemantics(
      child: MaterialExpressiveScope(
        child: M3EIconButton(
          icon: sized(icon),
          selectedIcon: selectedIcon == null ? null : sized(selectedIcon),
          semanticLabel: tooltip,
          onPressed: onPressed,
          isSelected: isSelected,
          variant: switch (_variant) {
            _AppIconButtonVariant.standard => M3EIconButtonVariant.standard,
            _AppIconButtonVariant.filled => M3EIconButtonVariant.filled,
            _AppIconButtonVariant.tonal => M3EIconButtonVariant.tonal,
          },
          decoration: M3EIconButtonDecoration(
            foregroundColor: foreground,
            backgroundColor: style?.backgroundColor,
            overlayColor: style?.overlayColor,
            side: style?.side,
          ),
        ),
      ),
    );
    final message = tooltip;
    return message == null
        ? button
        : Tooltip(message: message, excludeFromSemantics: true, child: button);
  }
}
