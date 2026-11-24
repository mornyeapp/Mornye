import 'package:material_ui/material_ui.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/widgets/settings_group.dart';

/// Corners of row [first] to [last] of a priority list: Material joins the
/// rows into one connected list, Mornye keeps separate rounded rows.
BorderRadius priorityRowRadius(
  BuildContext context, {
  required bool first,
  required bool last,
}) => context.isMornye
    ? BorderRadius.circular(16)
    : connectedRowRadius(context, first: first, last: last);

/// Space under a priority list row: the connected gap between Material rows,
/// the list's own spacing after its last row and between Mornye rows.
double priorityRowGap(BuildContext context, {required bool last}) =>
    context.isMornye || last ? 8 : 2;

/// Shared numbered, draggable row used by provider-priority reorder lists.
class ReorderablePriorityItem extends StatelessWidget {
  final int index;
  final bool isFirst;
  final bool isLast;
  final IconData icon;
  final Color iconColor;
  final String name;
  final String subtitle;
  final Widget? trailing;

  const ReorderablePriorityItem({
    super.key,
    required this.index,
    required this.isFirst,
    required this.isLast,
    required this.icon,
    required this.iconColor,
    required this.name,
    required this.subtitle,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    final backgroundColor = isDark
        ? Color.alphaBlend(
            Colors.white.withValues(alpha: 0.05),
            colorScheme.surface,
          )
        : colorScheme.surfaceContainerHigh;

    return Padding(
      padding: EdgeInsets.only(bottom: priorityRowGap(context, last: isLast)),
      child: Material(
        color: backgroundColor,
        borderRadius: priorityRowRadius(context, first: isFirst, last: isLast),
        child: ReorderableDragStartListener(
          index: index,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(
              children: [
                Container(
                  width: 28,
                  height: 28,
                  decoration: BoxDecoration(
                    color: isFirst
                        ? colorScheme.primaryContainer
                        : colorScheme.surfaceContainerHighest,
                    shape: BoxShape.circle,
                  ),
                  child: Center(
                    child: Text(
                      '${index + 1}',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        color: isFirst
                            ? colorScheme.onPrimaryContainer
                            : colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 16),
                Icon(icon, color: iconColor),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        name,
                        style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      Text(
                        subtitle,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                if (trailing != null) ...[trailing!, const SizedBox(width: 4)],
                Icon(Icons.drag_handle, color: colorScheme.onSurfaceVariant),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
