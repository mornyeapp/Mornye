import 'package:material_ui/material_ui.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:mornye/theme/mornye_theme.dart';

/// Expressive shapes used across the Material theme.
abstract final class AppShapes {
  /// Artist portraits, from list thumbnails to profile headers.
  static const artist = M3EShapeKind.cookie9Sided;

  /// Decorative badges behind empty-state and branding glyphs.
  static const badge = M3EShapeKind.softBurst;
  static const brand = M3EShapeKind.cookie12Sided;
}

/// Clips [child] to an expressive [kind] on the Material theme.
///
/// Mornye keeps its own geometry: [fallbackRadius], or an oval when null.
class AppShapeClip extends StatelessWidget {
  const AppShapeClip({
    super.key,
    required this.kind,
    required this.child,
    this.fallbackRadius,
  });

  final M3EShapeKind kind;
  final BorderRadius? fallbackRadius;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!context.isMornye) {
      return ClipPath(clipper: M3EShapeClipper(kind), child: child);
    }
    final fallbackRadius = this.fallbackRadius;
    return fallbackRadius == null
        ? ClipOval(child: child)
        : ClipRRect(borderRadius: fallbackRadius, child: child);
  }
}

/// A filled expressive [kind] behind a centered icon or logo.
///
/// Mornye draws the same fill as a circle.
class AppShapeBadge extends StatelessWidget {
  const AppShapeBadge({
    super.key,
    required this.kind,
    required this.size,
    required this.color,
    required this.child,
  });

  final M3EShapeKind kind;
  final double size;
  final Color color;
  final Widget child;

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: size,
    child: AppShapeClip(
      kind: kind,
      child: ColoredBox(
        color: color,
        child: Center(child: child),
      ),
    ),
  );
}
