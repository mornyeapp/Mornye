import 'package:flutter/rendering.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mornye/utils/adaptive_layout.dart';

/// Draws the glass package's surfaces in window coordinates. Its shaders take
/// their place on screen from the viewport's pixel ratio and assume nothing
/// scales them, so under an interface scale they drew away from their own
/// box. Here the scale is undone around the glass and applied again to what
/// sits on it ([content]).
class GlassWindowSpace extends StatelessWidget {
  const GlassWindowSpace({super.key, required this.builder});

  /// Builds the glass. One app pixel takes `scale` window pixels: multiply
  /// the glass's own lengths (radius, blur, thickness) by it.
  final Widget Function(BuildContext context, double scale) builder;

  /// Puts what sits on the glass back into the app's scaled space.
  static Widget content({required Widget child}) => _AppSpace(child: child);

  @override
  Widget build(BuildContext context) {
    final scale = AdaptiveUiScale.of(context);
    final glass = builder(context, scale);
    if (scale == 1) return glass;
    return _Rescale(
      factor: 1 / scale,
      child: _WindowViewport(scale: scale, child: glass),
    );
  }
}

/// Gives the glass the window's size and pixel ratio. Only this and
/// [_AppSpace] follow every viewport change, such as a keyboard inset; the
/// glass rebuilds when the values it reads change.
class _WindowViewport extends StatelessWidget {
  const _WindowViewport({required this.scale, required this.child});

  final double scale;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final viewport = MediaQuery.of(context);
    return _AppViewport(
      data: viewport,
      scale: scale,
      child: MediaQuery(
        data: viewport.copyWith(
          size: viewport.size * scale,
          devicePixelRatio: viewport.devicePixelRatio / scale,
        ),
        child: child,
      ),
    );
  }
}

class _AppViewport extends InheritedWidget {
  const _AppViewport({
    required this.data,
    required this.scale,
    required super.child,
  });

  final MediaQueryData data;
  final double scale;

  @override
  bool updateShouldNotify(_AppViewport oldWidget) =>
      data != oldWidget.data || scale != oldWidget.scale;
}

class _AppSpace extends StatelessWidget {
  const _AppSpace({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final app = context.dependOnInheritedWidgetOfExactType<_AppViewport>();
    if (app == null) return child;
    return _Rescale(
      factor: app.scale,
      child: MediaQuery(data: app.data, child: child),
    );
  }
}

/// Lays its child out in a space where one pixel is [factor] of its own, and
/// paints it scaled to match, so the child takes the same room either way.
class _Rescale extends SingleChildRenderObjectWidget {
  const _Rescale({required this.factor, required super.child});

  final double factor;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderRescale(factor);

  @override
  void updateRenderObject(BuildContext context, _RenderRescale renderObject) {
    renderObject.factor = factor;
  }
}

class _RenderRescale extends RenderProxyBox {
  _RenderRescale(this._factor);

  double _factor;
  set factor(double value) {
    if (value == _factor) return;
    _factor = value;
    markNeedsLayout();
  }

  Matrix4 get _transform => Matrix4.diagonal3Values(_factor, _factor, 1);

  @override
  double computeMinIntrinsicWidth(double height) =>
      (child?.getMinIntrinsicWidth(height / _factor) ?? 0) * _factor;

  @override
  double computeMaxIntrinsicWidth(double height) =>
      (child?.getMaxIntrinsicWidth(height / _factor) ?? 0) * _factor;

  @override
  double computeMinIntrinsicHeight(double width) =>
      (child?.getMinIntrinsicHeight(width / _factor) ?? 0) * _factor;

  @override
  double computeMaxIntrinsicHeight(double width) =>
      (child?.getMaxIntrinsicHeight(width / _factor) ?? 0) * _factor;

  @override
  Size computeDryLayout(BoxConstraints constraints) {
    final child = this.child;
    if (child == null) return constraints.smallest;
    return constraints.constrain(
      child.getDryLayout(constraints / _factor) * _factor,
    );
  }

  @override
  double? computeDryBaseline(
    BoxConstraints constraints,
    TextBaseline baseline,
  ) {
    final distance = child?.getDryBaseline(constraints / _factor, baseline);
    return distance == null ? null : distance * _factor;
  }

  @override
  double? computeDistanceToActualBaseline(TextBaseline baseline) {
    final distance = child?.getDistanceToActualBaseline(baseline);
    return distance == null ? null : distance * _factor;
  }

  @override
  void performLayout() {
    final child = this.child;
    if (child == null) {
      size = constraints.smallest;
      return;
    }
    child.layout(constraints / _factor, parentUsesSize: true);
    size = constraints.constrain(child.size * _factor);
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    if (child == null) {
      layer = null;
      return;
    }
    layer = context.pushTransform(
      needsCompositing,
      offset,
      _transform,
      super.paint,
      oldLayer: layer is TransformLayer ? layer as TransformLayer? : null,
    );
  }

  @override
  void applyPaintTransform(RenderBox child, Matrix4 transform) {
    transform.multiply(_transform);
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      result.addWithPaintTransform(
        transform: _transform,
        position: position,
        hitTest: (result, position) =>
            super.hitTestChildren(result, position: position),
      );
}
