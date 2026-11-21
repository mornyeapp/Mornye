import 'package:cupertino_ui/cupertino_ui.dart' show CupertinoActivityIndicator;
import 'package:material_ui/material_ui.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:mornye/theme/material_expressive.dart';
import 'package:mornye/theme/mornye_theme.dart';

/// Indeterminate loading only. Downloads/analysis keep their real progress.
class AppLoadingIndicator extends StatelessWidget {
  const AppLoadingIndicator({
    super.key,
    this.size = 32,
    this.color,
    this.semanticLabel,
    this.strokeWidth = 3,
  });

  final double size;
  final Color? color;
  final String? semanticLabel;

  /// Stroke of the fallback circular indicator.
  final double strokeWidth;

  @override
  Widget build(BuildContext context) {
    final animate =
        !MediaQuery.disableAnimationsOf(context) &&
        TickerMode.valuesOf(context).enabled;
    return SizedBox.square(
      dimension: size,
      child: !context.isMornye
          ? MaterialExpressiveScope(
              child: FittedBox(
                child: M3ELoadingIndicator(
                  size: 48,
                  color: color,
                  rotationTurns: animate ? null : 0,
                  semanticLabel: semanticLabel,
                ),
              ),
            )
          : Semantics(
              label: semanticLabel,
              child: CupertinoActivityIndicator(
                radius: (size / 2).clamp(5.0, 20.0),
                color: color,
                animating: animate,
              ),
            ),
    );
  }
}
