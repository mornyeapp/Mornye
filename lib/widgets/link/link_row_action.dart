import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/widgets/expressive_icon_button.dart';

/// The trailing action of a device row on the phone's Link page, such as
/// Forget or Remove: an expressive icon button, or in the Mornye style a
/// plain Cupertino button with its SF-style glyph.
class LinkRowAction extends StatelessWidget {
  const LinkRowAction({
    super.key,
    required this.tooltip,
    required this.icon,
    required this.cupertinoIcon,
    required this.onPressed,
  });

  final String tooltip;
  final IconData icon;
  final IconData cupertinoIcon;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => context.isMornye
      ? Tooltip(
          message: tooltip,
          child: CupertinoButton(
            onPressed: onPressed,
            padding: const EdgeInsets.all(12),
            child: Icon(
              cupertinoIcon,
              size: 24,
              semanticLabel: tooltip,
              color: onPressed == null
                  ? Theme.of(context).disabledColor
                  : Theme.of(context).colorScheme.primary,
            ),
          ),
        )
      : ExpressiveIconButton(
          icon: Icon(icon),
          tooltip: tooltip,
          onPressed: onPressed,
        );
}
