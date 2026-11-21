import 'package:cupertino_ui/cupertino_ui.dart' show CupertinoButton;
import 'package:material_ui/material_ui.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:mornye/theme/app_tokens.dart';
import 'package:mornye/theme/material_expressive.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/widgets/app_icon.dart';

/// Expressive actions retain caller colors, disabled states and flexible labels.
class ExpressiveButton extends StatelessWidget {
  const ExpressiveButton({
    super.key,
    required this.onPressed,
    required this.child,
    this.icon,
    this.style,
    this.outlined = false,
    this.tonal = false,
    this.text = false,
  });

  final VoidCallback? onPressed;
  final Widget child;
  final Widget? icon;
  final ButtonStyle? style;
  final bool outlined;
  final bool tonal;

  /// Low-emphasis action without a container, like [TextButton].
  final bool text;

  /// [style] with its text style in the theme's font: a button's own text
  /// style replaces the theme's label style whole, family included.
  static ButtonStyle? _inThemeFont(BuildContext context, ButtonStyle? style) {
    final text = style?.textStyle;
    final family = Theme.of(context).textTheme.labelLarge?.fontFamily;
    if (style == null || text == null || family == null) return style;
    return style.copyWith(
      textStyle: WidgetStateProperty.resolveWith((states) {
        final resolved = text.resolve(states);
        return resolved == null || resolved.fontFamily != null
            ? resolved
            : resolved.copyWith(fontFamily: family);
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    final icon = this.icon == null ? null : symbolIconWidget(this.icon!);
    final style = _inThemeFont(context, this.style);
    if (context.isMornye) {
      return _buildMornye(context, icon: icon, style: style);
    }
    if (!materialExpressiveEnabled(context)) {
      if (icon != null) {
        // Keep the standard icon spacing and asymmetric padding.
        if (text) {
          return TextButton.icon(
            onPressed: onPressed,
            style: style,
            icon: icon,
            label: child,
          );
        }
        if (outlined) {
          return OutlinedButton.icon(
            onPressed: onPressed,
            style: style,
            icon: icon,
            label: child,
          );
        }
        if (tonal) {
          return FilledButton.tonalIcon(
            onPressed: onPressed,
            style: style,
            icon: icon,
            label: child,
          );
        }
        return FilledButton.icon(
          onPressed: onPressed,
          style: style,
          icon: icon,
          label: child,
        );
      }
      if (text) {
        return TextButton(onPressed: onPressed, style: style, child: child);
      }
      if (outlined) {
        return OutlinedButton(onPressed: onPressed, style: style, child: child);
      }
      if (tonal) {
        return FilledButton.tonal(
          onPressed: onPressed,
          style: style,
          child: child,
        );
      }
      return FilledButton(onPressed: onPressed, style: style, child: child);
    }
    final content = Row(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        if (icon != null) ...[icon, const SizedBox(width: 8)],
        Flexible(child: child),
      ],
    );
    final states = <WidgetState>{if (onPressed == null) WidgetState.disabled};
    return MaterialExpressiveScope(
      child: M3EButton(
        onPressed: onPressed,
        style: text
            ? M3EButtonStyle.text
            : outlined
            ? M3EButtonStyle.outlined
            : tonal
            ? M3EButtonStyle.tonal
            : M3EButtonStyle.filled,
        decoration: M3EButtonDecoration(
          backgroundColor: style?.backgroundColor,
          foregroundColor: style?.foregroundColor,
          overlayColor: style?.overlayColor,
          side: style?.side,
          minimumSize:
              style?.minimumSize?.resolve(states) ?? const Size(48, 48),
          maximumSize: style?.maximumSize?.resolve(states),
          fixedSize: style?.fixedSize?.resolve(states),
          padding: style?.padding?.resolve(states),
          textStyle: style?.textStyle?.resolve(states),
          iconSize: style?.iconSize?.resolve(states),
        ),
        child: content,
      ),
    );
  }

  Widget _buildMornye(
    BuildContext context, {
    required Widget? icon,
    required ButtonStyle? style,
  }) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final states = <WidgetState>{if (onPressed == null) WidgetState.disabled};
    final customBg = style?.backgroundColor?.resolve(states);
    final customFg = style?.foregroundColor?.resolve(states);
    final Color background;
    final Color foreground;
    if (text) {
      background = customBg ?? Colors.transparent;
      foreground =
          customFg ??
          (onPressed == null
              ? scheme.onSurfaceVariant.withValues(alpha: 0.5)
              : scheme.primary);
    } else if (outlined) {
      background = customBg ?? Colors.transparent;
      foreground =
          customFg ??
          (onPressed == null
              ? scheme.onSurfaceVariant.withValues(alpha: 0.5)
              : scheme.primary);
    } else if (tonal) {
      background =
          customBg ??
          MornyeTheme.controlFill(context, enabled: onPressed != null);
      foreground =
          customFg ??
          (onPressed == null
              ? scheme.onSurfaceVariant.withValues(alpha: 0.5)
              : scheme.onSurface);
    } else {
      background =
          customBg ??
          (onPressed == null
              ? MornyeTheme.controlFill(context, enabled: false)
              : scheme.primary);
      foreground =
          customFg ??
          (onPressed == null
              ? scheme.onSurfaceVariant.withValues(alpha: 0.5)
              : scheme.onPrimary);
    }
    final radius = context.tokens.radiusControl;
    final minSize = style?.minimumSize?.resolve(states);
    final padding =
        style?.padding?.resolve(states) ??
        EdgeInsets.symmetric(
          horizontal: text ? 12 : 18,
          vertical: text ? 10 : 12,
        );
    final row = Row(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        if (icon != null) ...[icon, const SizedBox(width: 8)],
        Flexible(child: child),
      ],
    );
    Widget button = CupertinoButton(
      onPressed: onPressed,
      color: background == Colors.transparent ? null : background,
      disabledColor: text || outlined
          ? Colors.transparent
          : MornyeTheme.controlFill(context, enabled: false),
      padding: padding,
      borderRadius: BorderRadius.circular(radius),
      minimumSize: minSize == null || minSize == Size.zero
          ? const Size(44, 44)
          : minSize,
      child: DefaultTextStyle(
        style:
            (style?.textStyle?.resolve(states) ?? theme.textTheme.labelLarge!)
                .copyWith(color: foreground, fontWeight: FontWeight.w600),
        child: IconTheme(
          data: IconThemeData(color: foreground, size: 20),
          child: row,
        ),
      ),
    );
    if (outlined) {
      final side =
          style?.side?.resolve(states) ??
          BorderSide(color: scheme.outlineVariant);
      button = DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(radius),
          border: Border.fromBorderSide(side),
        ),
        child: button,
      );
    }
    if (minSize != null && (minSize.width > 0 || minSize.height > 0)) {
      button = ConstrainedBox(
        constraints: BoxConstraints(
          minWidth: minSize.width,
          minHeight: minSize.height,
        ),
        child: button,
      );
    }
    return button;
  }
}
