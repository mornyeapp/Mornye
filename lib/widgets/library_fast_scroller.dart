import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mornye/theme/app_motion.dart';
import 'package:mornye/theme/mornye_theme.dart';

/// A draggable scroll thumb for long library lists, with a bubble naming the
/// section under the thumb (a letter or a month).
///
/// The thumb tracks the scroll position like a scrollbar. Dragging moves the
/// list by the finger's travel rather than jumping to where it touched, so
/// grabbing the thumb never moves the list by itself. Slow drags scrub with
/// finer control in large libraries; quick drags still cover the full range.
/// The thumb shows while scrolling and only for lists several screens long.
class LibraryFastScroller extends StatefulWidget {
  const LibraryFastScroller({
    super.key,
    required this.child,
    required this.labelAt,
    this.topPadding = 0,
    this.bottomPadding = 0,
  });

  /// A scroll view. The scroller drives the [Scrollable] that reports scroll
  /// notifications from it.
  final Widget child;

  /// Label for the row at [fraction] of the scrollable content, or null.
  final String? Function(double fraction) labelAt;

  /// Height of the pinned header. While an outer scroll view is expanded,
  /// only its overlap with this viewport is reserved.
  final double topPadding;
  final double bottomPadding;

  @override
  State<LibraryFastScroller> createState() => _LibraryFastScrollerState();
}

class _LibraryFastScrollerState extends State<LibraryFastScroller> {
  static const _thumbHeight = 52.0;
  static const _hitWidth = 32.0;
  static const _minScreens = 4;

  ScrollPosition? _position;
  ScrollPosition? _outerPosition;
  double _pixels = 0;
  double _maxExtent = 0;
  double _viewport = 0;
  bool _visible = false;
  bool _dragging = false;
  double _lastDragDy = 0;
  Duration? _lastDragTime;
  double _dragTravel = 0;
  double _dragDirection = 0;
  Timer? _hideTimer;

  bool get _long => _maxExtent > _viewport * _minScreens;

  double get _fraction =>
      _maxExtent <= 0 ? 0 : (_pixels / _maxExtent).clamp(0.0, 1.0);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final outer = Scrollable.maybeOf(context, axis: Axis.vertical)?.position;
    if (outer == _outerPosition) return;
    _outerPosition?.removeListener(_onOuterPositionChanged);
    _outerPosition = outer;
    outer?.addListener(_onOuterPositionChanged);
  }

  void _onOuterPositionChanged() {
    if (mounted && _long && widget.topPadding > 0) setState(() {});
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _position?.removeListener(_onPositionChanged);
    _outerPosition?.removeListener(_onOuterPositionChanged);
    super.dispose();
  }

  void _attachPosition(BuildContext? context) {
    if (context == null) return;
    final position = Scrollable.maybeOf(context, axis: Axis.vertical)?.position;
    if (position == null || position == _position) return;
    _position?.removeListener(_onPositionChanged);
    _position = position;
    position.addListener(_onPositionChanged);
  }

  void _onPositionChanged() {
    final position = _position;
    if (!mounted || position == null || !position.hasContentDimensions) return;
    _readMetrics(position, show: true);
  }

  void _readMetrics(ScrollMetrics metrics, {bool show = false}) {
    final wasLong = _long;
    final changed =
        _pixels != metrics.pixels ||
        _maxExtent != metrics.maxScrollExtent ||
        _viewport != metrics.viewportDimension;
    final wasVisible = _visible;
    _pixels = metrics.pixels;
    _maxExtent = metrics.maxScrollExtent;
    _viewport = metrics.viewportDimension;
    if (show && _long) _show();
    if (!_long) {
      _visible = false;
      _hideTimer?.cancel();
    }
    if ((changed && (wasLong || _long)) || wasVisible != _visible) {
      setState(() {});
    }
  }

  bool _onMetricsNotification(ScrollMetricsNotification notification) {
    if (notification.depth != 0 || notification.metrics.axis != Axis.vertical) {
      return false;
    }
    _attachPosition(notification.context);
    _readMetrics(notification.metrics);
    return false;
  }

  bool _onNotification(ScrollNotification notification) {
    if (notification.depth != 0) return false;
    final metrics = notification.metrics;
    if (metrics.axis != Axis.vertical) return false;
    _attachPosition(notification.context);
    _readMetrics(metrics, show: notification is ScrollUpdateNotification);
    if (notification is ScrollStartNotification) _hideTimer?.cancel();
    if (notification is ScrollEndNotification) _scheduleHide();
    return false;
  }

  void _show() {
    _visible = true;
    _hideTimer?.cancel();
  }

  void _scheduleHide() {
    if (!_long || !_visible || _dragging) return;
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(milliseconds: 1500), () {
      if (mounted && !_dragging) setState(() => _visible = false);
    });
  }

  void _startDrag(DragStartDetails details) {
    HapticFeedback.selectionClick();
    _lastDragDy = details.globalPosition.dy;
    _lastDragTime = details.sourceTimeStamp;
    _dragTravel = 0;
    _dragDirection = 0;
    setState(() {
      _dragging = true;
      _show();
    });
  }

  void _updateDrag(DragUpdateDetails details, double trackHeight) {
    final position = _position;
    if (position == null || !position.hasContentDimensions) return;
    final travel = math.max(1.0, trackHeight - _thumbHeight);
    final dy = details.globalPosition.dy - _lastDragDy;
    final timestamp = details.sourceTimeStamp;
    final elapsed = timestamp != null && _lastDragTime != null
        ? (timestamp - _lastDragTime!).inMicroseconds / 1e6
        : 0.0;
    _lastDragDy = details.globalPosition.dy;
    _lastDragTime = timestamp;
    if (dy != 0 && dy.sign != _dragDirection) {
      _dragTravel = 0;
      _dragDirection = dy.sign;
    }
    _dragTravel += dy.abs();
    final speed = dy.abs() / (elapsed > 0 ? elapsed : 1 / 60);
    final coarse = position.maxScrollExtent / travel;
    // Tiny movements must not skip hundreds of rows in a large library.
    // Accelerate to scrollbar speed only for a deliberate, quick sweep.
    final fine = math.min(coarse, 16.0);
    final acceleration =
        Curves.easeIn.transform(((speed - 240) / 720).clamp(0.0, 1.0)) *
        ((_dragTravel - 24) / 96).clamp(0.0, 1.0);
    final scale = fine + (coarse - fine) * acceleration;
    position.jumpTo(
      (position.pixels + dy * scale).clamp(
        position.minScrollExtent,
        position.maxScrollExtent,
      ),
    );
  }

  void _endDrag() {
    if (!_dragging) return;
    setState(() {
      _dragging = false;
      _show();
    });
    _scheduleHide();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final mornye = context.isMornye;
    final reduced = MediaQuery.disableAnimationsOf(context);
    final motion = AppMotion.spatialFast(
      context,
      AppMotionSpec(
        reduced ? Duration.zero : const Duration(milliseconds: 180),
        Curves.easeOutCubic,
      ),
    );
    // NestedScrollView's body slides behind its pinned header. Reserve only
    // the part of that header currently overlapping this body's viewport.
    final remainingHeader = _outerPosition?.hasContentDimensions == true
        ? _outerPosition!.extentAfter
        : 0.0;
    final topPadding = (widget.topPadding - remainingHeader).clamp(
      0.0,
      widget.topPadding,
    );
    return NotificationListener<ScrollMetricsNotification>(
      onNotification: _onMetricsNotification,
      child: NotificationListener<ScrollNotification>(
        onNotification: _onNotification,
        child: Stack(
          children: [
            ScrollConfiguration(
              behavior: ScrollConfiguration.of(
                context,
              ).copyWith(scrollbars: _long ? false : null),
              child: widget.child,
            ),
            if (_long)
              PositionedDirectional(
                top: topPadding,
                bottom: widget.bottomPadding,
                end: 0,
                width: 240,
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final track = constraints.maxHeight;
                    final top = _fraction * math.max(0, track - _thumbHeight);
                    final label = _dragging ? widget.labelAt(_fraction) : null;
                    return Stack(
                      clipBehavior: Clip.hardEdge,
                      children: [
                        PositionedDirectional(
                          top: top,
                          end: 0,
                          width: _hitWidth,
                          height: _thumbHeight,
                          child: Semantics(
                            // Screen readers scroll the list itself.
                            excludeSemantics: true,
                            child: IgnorePointer(
                              // A hidden thumb must not catch edge swipes.
                              ignoring: !_visible && !_dragging,
                              child: GestureDetector(
                                behavior: HitTestBehavior.opaque,
                                onVerticalDragStart: _startDrag,
                                onVerticalDragUpdate: (details) =>
                                    _updateDrag(details, track),
                                onVerticalDragEnd: (_) => _endDrag(),
                                onVerticalDragCancel: _endDrag,
                                child: AnimatedOpacity(
                                  opacity: _visible || _dragging ? 1 : 0,
                                  duration: const Duration(milliseconds: 200),
                                  child: Align(
                                    alignment: AlignmentDirectional.centerEnd,
                                    child: AnimatedContainer(
                                      duration: motion.duration,
                                      curve: motion.curve,
                                      margin: const EdgeInsetsDirectional.only(
                                        end: 4,
                                      ),
                                      width: _dragging ? 10 : 6,
                                      height: _thumbHeight,
                                      decoration: ShapeDecoration(
                                        color: _dragging
                                            ? colors.primary
                                            : colors.onSurfaceVariant
                                                  .withValues(
                                                    alpha: mornye ? 0.45 : 0.6,
                                                  ),
                                        shape: const StadiumBorder(),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                        if (label != null)
                          Positioned.fill(
                            child: IgnorePointer(
                              child: CustomSingleChildLayout(
                                delegate: _BubbleLayout(
                                  center: top + _thumbHeight / 2,
                                  right: _hitWidth + 8,
                                  rtl:
                                      Directionality.of(context) ==
                                      TextDirection.rtl,
                                ),
                                child: _Bubble(
                                  key: const ValueKey('library-scroll-bubble'),
                                  label: label,
                                  mornye: mornye,
                                  motion: motion,
                                ),
                              ),
                            ),
                          ),
                      ],
                    );
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Places the bubble [right] in from the thumb's edge, which is the left
/// edge in right-to-left layouts.
class _BubbleLayout extends SingleChildLayoutDelegate {
  const _BubbleLayout({
    required this.center,
    required this.right,
    this.rtl = false,
  });

  final double center;
  final double right;
  final bool rtl;
  static const _inset = 8.0;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) =>
      BoxConstraints(
        maxWidth: math.max(0, constraints.maxWidth - right - _inset),
        maxHeight: math.max(0, constraints.maxHeight - _inset * 2),
      );

  @override
  Offset getPositionForChild(Size size, Size childSize) => Offset(
    rtl
        ? math.min(right, math.max(0, size.width - childSize.width))
        : math.max(0, size.width - right - childSize.width),
    (center - childSize.height / 2).clamp(
      _inset,
      math.max(_inset, size.height - childSize.height - _inset),
    ),
  );

  @override
  bool shouldRelayout(_BubbleLayout oldDelegate) =>
      center != oldDelegate.center ||
      right != oldDelegate.right ||
      rtl != oldDelegate.rtl;
}

/// The section bubble beside the thumb. Material uses a container-colored
/// shape pointing at the thumb; Mornye a plain rounded tile.
class _Bubble extends StatelessWidget {
  const _Bubble({
    super.key,
    required this.label,
    required this.mornye,
    required this.motion,
  });

  final String label;
  final bool mornye;
  final AppMotionSpec motion;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final short = label.characters.length <= 2;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0.6, end: 1),
      duration: motion.duration,
      curve: motion.curve,
      builder: (context, scale, child) => Transform.scale(
        scale: scale,
        alignment: AlignmentDirectional.centerEnd,
        child: child,
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minWidth: 72, minHeight: 72),
        child: DecoratedBox(
          decoration: ShapeDecoration(
            color: mornye
                ? colors.surfaceContainerHighest
                : colors.primaryContainer,
            shadows: kElevationToShadow[2],
            shape: RoundedRectangleBorder(
              borderRadius: mornye
                  ? BorderRadius.circular(18)
                  // The sharp corner points at the thumb.
                  : const BorderRadiusDirectional.only(
                      topStart: Radius.circular(36),
                      topEnd: Radius.circular(36),
                      bottomStart: Radius.circular(36),
                      bottomEnd: Radius.circular(6),
                    ),
            ),
          ),
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: short ? 0 : 18),
            child: Center(
              widthFactor: short ? null : 1,
              heightFactor: 1,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 16),
                child: Text(
                  label,
                  style:
                      (short
                              ? Theme.of(context).textTheme.headlineMedium
                              : Theme.of(context).textTheme.titleMedium)
                          ?.copyWith(
                            fontWeight: FontWeight.w700,
                            color: mornye
                                ? colors.onSurface
                                : colors.onPrimaryContainer,
                          ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
