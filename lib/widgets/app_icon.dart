import 'package:material_ui/material_ui.dart';
import 'package:mornye/theme/material_symbols.dart';
import 'package:mornye/theme/mornye_icons.dart';
import 'package:mornye/theme/mornye_theme.dart';

/// [widget] as an adaptive [AppIcon] when it is a plain [Icon], so shared
/// components draw Material Symbols in Material and Cupertino glyphs in Mornye.
Widget symbolIconWidget(Widget widget) {
  if (widget case Icon(:final icon?)) {
    return AppIcon.adaptive(
      icon,
      key: widget.key,
      size: widget.size,
      color: widget.color,
      fill: widget.fill,
      semanticLabel: widget.semanticLabel,
      shadows: widget.shadows,
      textDirection: widget.textDirection,
    );
  }
  return widget;
}

/// [Icon] that draws the Material theme with rounded Material Symbols.
///
/// Mornye keeps [icon] unchanged, or its Cupertino counterpart with
/// [AppIcon.adaptive]. Icons without a symbol fall back to [icon].
class AppIcon extends StatelessWidget {
  const AppIcon(
    this.icon, {
    super.key,
    this.size,
    this.color,
    this.fill,
    this.semanticLabel,
    this.shadows,
    this.textDirection,
  }) : _adaptive = false;

  /// Uses [mornyeIconFor] when the Mornye theme is on.
  const AppIcon.adaptive(
    this.icon, {
    super.key,
    this.size,
    this.color,
    this.fill,
    this.semanticLabel,
    this.shadows,
    this.textDirection,
  }) : _adaptive = true;

  final IconData? icon;
  final double? size;
  final Color? color;

  /// Overrides the symbol fill; null keeps the legacy glyph's filled state.
  final double? fill;
  final String? semanticLabel;
  final List<Shadow>? shadows;
  final TextDirection? textDirection;
  final bool _adaptive;

  @override
  Widget build(BuildContext context) {
    final icon = this.icon;
    if (context.isMornye) {
      return Icon(
        _adaptive && icon != null ? mornyeIconFor(icon) : icon,
        size: size,
        color: color,
        semanticLabel: semanticLabel,
        shadows: shadows,
        textDirection: textDirection,
      );
    }
    final symbol = materialSymbolFor(icon);
    if (symbol == null) {
      return Icon(
        icon,
        size: size,
        color: color,
        semanticLabel: semanticLabel,
        shadows: shadows,
        textDirection: textDirection,
      );
    }
    final resolvedSize = size ?? IconTheme.of(context).size ?? 24;
    return Icon(
      symbol.icon,
      size: size,
      color: color,
      fill: fill ?? (symbol.filled ? 1 : 0),
      // Material Symbols adjust stroke detail for the drawn size.
      opticalSize: resolvedSize.clamp(20, 48).toDouble(),
      semanticLabel: semanticLabel,
      shadows: shadows,
      textDirection: textDirection,
    );
  }
}
