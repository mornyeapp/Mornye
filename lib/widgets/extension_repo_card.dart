import 'package:material_ui/material_ui.dart';
import 'package:mornye/theme/app_tokens.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/widgets/app_content_card.dart';

/// Repo cards use tonal surfaces in Material and plain grouped fills in Mornye
/// so content-layer cards never draw Liquid Glass.
class ExtensionRepoCard extends StatelessWidget {
  const ExtensionRepoCard({
    super.key,
    required this.child,
    this.color,
    this.radius = 20,
    this.margin = const EdgeInsets.all(4),
  });

  final Widget child;
  final Color? color;
  final double radius;
  final EdgeInsetsGeometry margin;

  @override
  Widget build(BuildContext context) {
    if (!context.isMornye) {
      return AppContentCard(
        elevation: 0,
        color: color,
        margin: margin,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radius),
        ),
        child: child,
      );
    }
    return Padding(
      padding: margin,
      child: Material(
        // Callers' Material tones can match the grouped page background.
        color: Theme.of(context).colorScheme.surfaceContainer,
        borderRadius: BorderRadius.circular(context.tokens.radiusCard),
        clipBehavior: Clip.antiAlias,
        child: child,
      ),
    );
  }
}
