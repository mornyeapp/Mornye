import 'package:material_ui/material_ui.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:mornye/theme/material_expressive.dart';
import 'package:mornye/theme/mornye_theme.dart';

/// One inline surface, matching the metadata groups and dialog controls.
class AppContentCard extends StatelessWidget {
  const AppContentCard({
    super.key,
    required this.child,
    this.color,
    this.shape,
    this.elevation,
    this.clipBehavior = Clip.none,
    this.preserveColor = false,
    this.margin,
    this.onTap,
    this.onLongPress,
    this.mornyeSurface = true,
  });

  final Widget child;
  final Color? color;
  final ShapeBorder? shape;
  final double? elevation;
  final Clip clipBehavior;
  final bool preserveColor;

  /// Outer margin; Material defaults to its card theme, Mornye to zero.
  final EdgeInsetsGeometry? margin;

  /// Makes the whole card pressable, with the expressive press feedback.
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  /// False keeps a plain [Card] under Mornye for surfaces that carry their
  /// own tinted color (errors, notices) rather than the Mornye control fill.
  final bool mornyeSurface;

  @override
  Widget build(BuildContext context) {
    if (!context.isMornye || !mornyeSurface) {
      if (!context.isMornye &&
          materialExpressiveEnabled(context) &&
          (shape == null || shape is RoundedRectangleBorder)) {
        final radius = shape is RoundedRectangleBorder
            ? (shape as RoundedRectangleBorder).borderRadius.resolve(
                Directionality.of(context),
              )
            : BorderRadius.circular(20);
        return Padding(
          padding:
              margin ?? CardTheme.of(context).margin ?? const EdgeInsets.all(4),
          child: MaterialExpressiveScope(
            child: M3ECard(
              variant: M3ECardVariant.filled,
              padding: EdgeInsets.zero,
              color: color,
              elevation: elevation ?? 0,
              // BorderSide.none would still paint as a hairline.
              border:
                  shape is RoundedRectangleBorder &&
                      (shape as RoundedRectangleBorder).side.style !=
                          BorderStyle.none
                  ? (shape as RoundedRectangleBorder).side
                  : null,
              borderRadius: radius,
              clipBehavior: onTap == null && onLongPress == null
                  ? clipBehavior
                  : Clip.antiAlias,
              onPressed: onTap,
              onLongPress: onLongPress,
              child: Material(color: Colors.transparent, child: child),
            ),
          ),
        );
      }
      final interactive = onTap != null || onLongPress != null;
      return Card(
        color: color,
        shape: shape,
        elevation: elevation,
        margin: margin,
        clipBehavior: interactive ? Clip.antiAlias : clipBehavior,
        child: interactive
            ? InkWell(onTap: onTap, onLongPress: onLongPress, child: child)
            : child,
      );
    }
    final content = DividerTheme(
      data: DividerTheme.of(
        context,
      ).copyWith(color: MornyeTheme.metadataDividerColor(context)),
      child: child,
    );
    final surface = Material(
      color: preserveColor ? color : MornyeTheme.controlFill(context),
      borderRadius: BorderRadius.circular(28),
      clipBehavior: Clip.antiAlias,
      child: onTap != null || onLongPress != null
          ? InkWell(onTap: onTap, onLongPress: onLongPress, child: content)
          : content,
    );
    return margin == null ? surface : Padding(padding: margin!, child: surface);
  }
}
