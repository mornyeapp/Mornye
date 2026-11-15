import 'package:material_ui/material_ui.dart';

/// A small tonal tag marking a feature that is still in beta.
class BetaBadge extends StatelessWidget {
  const BetaBadge({super.key});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: colors.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        'Beta',
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          // onSurfaceVariant falls under 4.5:1 on Mornye's container tones.
          color: colors.onSurface,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
