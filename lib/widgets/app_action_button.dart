import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mornye/theme/mornye_icons.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/widgets/app_icon.dart';
import 'package:mornye/widgets/mornye_chrome.dart';
import 'package:mornye/widgets/expressive_button.dart';

/// Shared sheet actions follow the selected design on every platform.
class AppActionButton extends StatelessWidget {
  const AppActionButton({
    super.key,
    required this.onPressed,
    required this.icon,
    required this.label,
    this.style,
    this.outlined = false,
    this.glass = true,
    this.tonal = false,
    this.isDestructive = false,
    this.fontSize = 17,
  });

  final VoidCallback? onPressed;
  final Widget icon;
  final Widget label;
  final ButtonStyle? style;
  final bool outlined;
  final bool glass;
  final bool tonal;
  final bool isDestructive;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (!context.isMornye) {
      final resolvedStyle =
          style ??
          (!isDestructive
              ? null
              : outlined
              ? OutlinedButton.styleFrom(
                  foregroundColor: scheme.error,
                  side: BorderSide(color: scheme.error),
                )
              : FilledButton.styleFrom(
                  backgroundColor: scheme.error,
                  foregroundColor: scheme.onError,
                ));
      return ExpressiveButton(
        onPressed: onPressed,
        icon: icon,
        style: resolvedStyle,
        outlined: outlined,
        tonal: tonal && !isDestructive,
        child: label,
      );
    }
    final destructiveColor = Theme.of(context).brightness == Brightness.dark
        ? CupertinoColors.systemRed.darkColor
        : CupertinoColors.systemRed.highContrastColor;
    final prominent = isDestructive || !outlined;
    final foreground = onPressed == null
        ? scheme.onSurfaceVariant.withValues(alpha: 0.5)
        : isDestructive
        ? Colors.white
        : prominent
        ? scheme.onPrimary
        : scheme.primary;
    final action = CupertinoButton(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      borderRadius: BorderRadius.circular(28),
      color: isDestructive
          ? destructiveColor
          : prominent
          ? scheme.primary
          : tonal
          ? MornyeTheme.controlFill(context)
          : Colors.transparent,
      disabledColor: !prominent && !tonal && !glass
          ? Colors.transparent
          : tonal && !prominent
          ? MornyeTheme.controlFill(context, enabled: false)
          : scheme.surfaceContainerHighest,
      onPressed: onPressed,
      child: DefaultTextStyle(
        style: Theme.of(context).textTheme.bodyLarge!.copyWith(
          color: foreground,
          fontSize: fontSize,
          fontWeight: FontWeight.w600,
        ),
        child: IconTheme(
          data: IconThemeData(color: foreground, size: 20),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (icon case Icon(:final icon?) || AppIcon(:final icon?))
                Icon(mornyeIconFor(icon), size: 20)
              else
                icon,
              const SizedBox(width: 8),
              Flexible(child: label),
            ],
          ),
        ),
      ),
    );
    // These buttons sit inside glass sheets/groups; avoid another blur pass.
    return prominent || tonal || !glass
        ? action
        : MornyeGlass.navigation(radius: 28, blurEnabled: false, child: action);
  }
}
