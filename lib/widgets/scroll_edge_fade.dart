import 'package:material_ui/material_ui.dart';
import 'package:mornye/theme/app_motion.dart';

/// Overlays a gradient on the trailing edge of a scrollable while more
/// content remains beyond it, signalling that the view can scroll.
class ScrollEdgeFade extends StatefulWidget {
  final Widget child;
  final Axis axis;

  /// Thickness of the fade: height for vertical, width for horizontal.
  final double size;

  /// Fades the content itself instead of painting the scaffold background
  /// over it, for scrollables on cards or translucent surfaces.
  final bool fadeContent;

  const ScrollEdgeFade({
    super.key,
    required this.child,
    this.axis = Axis.vertical,
    this.size = 96,
    this.fadeContent = false,
  });

  @override
  State<ScrollEdgeFade> createState() => _ScrollEdgeFadeState();
}

class _ScrollEdgeFadeState extends State<ScrollEdgeFade> {
  bool _hasMore = false;

  bool _onMetrics(ScrollMetrics metrics) {
    if (metrics.axis == widget.axis) {
      final hasMore = metrics.extentAfter > 8;
      if (hasMore != _hasMore) setState(() => _hasMore = hasMore);
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final background = Theme.of(context).scaffoldBackgroundColor;
    final horizontal = widget.axis == Axis.horizontal;
    // The edge dissolves on the effects spring, and with reduced motion as
    // well.
    final fade = AppMotion.effects(
      context,
      const AppMotionSpec(Duration(milliseconds: 200), Curves.linear),
    );
    final scrollable = NotificationListener<ScrollMetricsNotification>(
      onNotification: (notification) => _onMetrics(notification.metrics),
      child: NotificationListener<ScrollUpdateNotification>(
        onNotification: (notification) => _onMetrics(notification.metrics),
        child: widget.child,
      ),
    );
    if (widget.fadeContent) {
      final textDirection = Directionality.of(context);
      return TweenAnimationBuilder<double>(
        tween: Tween(end: _hasMore ? 1 : 0),
        duration: fade.duration,
        curve: fade.curve,
        builder: (context, strength, child) => ShaderMask(
          blendMode: BlendMode.dstIn,
          shaderCallback: (bounds) {
            final extent = horizontal ? bounds.width : bounds.height;
            final start = extent <= 0
                ? 1.0
                : (1 - widget.size / extent).clamp(0.0, 1.0);
            return LinearGradient(
              begin: horizontal
                  ? AlignmentDirectional.centerStart.resolve(textDirection)
                  : Alignment.topCenter,
              end: horizontal
                  ? AlignmentDirectional.centerEnd.resolve(textDirection)
                  : Alignment.bottomCenter,
              stops: [start, 1],
              colors: [
                Colors.white,
                Colors.white.withValues(alpha: 1 - strength),
              ],
            ).createShader(bounds);
          },
          child: child,
        ),
        child: scrollable,
      );
    }
    return Stack(
      children: [
        scrollable,
        PositionedDirectional(
          start: horizontal ? null : 0,
          end: 0,
          top: horizontal ? 0 : null,
          bottom: 0,
          child: IgnorePointer(
            child: AnimatedOpacity(
              opacity: _hasMore ? 1 : 0,
              duration: fade.duration,
              curve: fade.curve,
              child: Container(
                width: horizontal ? widget.size : null,
                height: horizontal ? null : widget.size,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: horizontal
                        ? AlignmentDirectional.centerStart
                        : Alignment.topCenter,
                    end: horizontal
                        ? AlignmentDirectional.centerEnd
                        : Alignment.bottomCenter,
                    colors: [background.withValues(alpha: 0), background],
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
