import 'package:material_ui/material_ui.dart';

/// Mornye TrackInfoView's vertically stacked label and value.
class MornyeMetadataRow extends StatelessWidget {
  const MornyeMetadataRow({
    super.key,
    required this.label,
    required this.value,
    this.showDivider = true,
    this.trailing,
    this.onTap,
    this.onLongPress,
  });

  final String label;
  final String value;
  final bool showDivider;
  final Widget? trailing;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final content = Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  label,
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontWeight: FontWeight.w500,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              ?trailing,
            ],
          ),
          const SizedBox(height: 5),
          Text(value, style: theme.textTheme.bodyLarge),
          if (showDivider) ...[
            const SizedBox(height: 7),
            const Divider(height: 0.5),
          ],
        ],
      ),
    );
    if (onTap == null && onLongPress == null) return content;
    return InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
      borderRadius: BorderRadius.circular(8),
      child: content,
    );
  }
}
