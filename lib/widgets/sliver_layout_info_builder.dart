import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// A [SliverLayoutBuilder] that calls [builder] only when [select] derives a
/// different value from the sliver constraints.
///
/// [SliverConstraints] change with the scroll offset, so a plain
/// [SliverLayoutBuilder] rebuilds its sliver on every scroll frame. Inherited
/// dependencies read in [builder] still rebuild it.
class SliverLayoutInfoBuilder<T> extends AbstractLayoutBuilder<T> {
  const SliverLayoutInfoBuilder({
    super.key,
    required this.select,
    required this.builder,
  });

  /// The layout value [builder] depends on, compared with `==`.
  final T Function(SliverConstraints constraints) select;

  @override
  final Widget Function(BuildContext context, T info) builder;

  @override
  RenderAbstractLayoutBuilderMixin<T, RenderSliver> createRenderObject(
    BuildContext context,
  ) => _RenderSliverLayoutInfoBuilder<T>(select);

  @override
  void updateRenderObject(
    BuildContext context,
    RenderAbstractLayoutBuilderMixin<T, RenderSliver> renderObject,
  ) => (renderObject as _RenderSliverLayoutInfoBuilder<T>).select = select;
}

class _RenderSliverLayoutInfoBuilder<T> extends RenderProxySliver
    with
        RenderObjectWithLayoutCallbackMixin,
        RenderAbstractLayoutBuilderMixin<T, RenderSliver> {
  _RenderSliverLayoutInfoBuilder(this.select);

  T Function(SliverConstraints constraints) select;

  @override
  T get layoutInfo => select(constraints);

  @override
  void performLayout() {
    runLayoutCallback();
    super.performLayout();
  }
}
