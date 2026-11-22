import 'package:material_ui/material_ui.dart';
import 'package:liquid_glass_easy/liquid_glass_easy.dart';

/// Uses the same outline as the optical lens, including its continuous corners.
/// The fill, shadow, clip and rim must agree to avoid cutting off the glass edge.
class MornyeSquircleBorder extends ShapeBorder {
  const MornyeSquircleBorder(this.radius);

  final double radius;

  @override
  EdgeInsetsGeometry get dimensions => EdgeInsets.zero;

  @override
  ShapeBorder scale(double t) => MornyeSquircleBorder(radius * t);

  static final _pathCache = <(double, double, double), Path>{};
  static const int _maxCacheEntries = 64;

  static Path _cachedPath(Size size, double radius) {
    final key = (size.width, size.height, radius);
    final existing = _pathCache[key];
    if (existing != null) return existing;
    if (_pathCache.length >= _maxCacheEntries) {
      _pathCache.remove(_pathCache.keys.first);
    }
    final path = liquidGlassSquirclePath(size, radius, 1);
    _pathCache[key] = path;
    return path;
  }

  @override
  Path getOuterPath(Rect rect, {TextDirection? textDirection}) {
    final cached = _cachedPath(rect.size, radius);
    return rect.topLeft == Offset.zero
        ? Path.from(cached)
        : cached.shift(rect.topLeft);
  }

  @override
  Path getInnerPath(Rect rect, {TextDirection? textDirection}) =>
      getOuterPath(rect, textDirection: textDirection);

  @override
  void paint(Canvas canvas, Rect rect, {TextDirection? textDirection}) {}

  @override
  bool operator ==(Object other) =>
      other is MornyeSquircleBorder && other.radius == radius;

  @override
  int get hashCode => radius.hashCode;
}
