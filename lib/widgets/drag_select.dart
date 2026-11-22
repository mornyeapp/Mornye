import 'dart:math' as math;

import 'package:flutter/foundation.dart' show clampDouble;
import 'package:flutter/gestures.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mornye/utils/desktop_platform.dart';

/// Lets a finger that long pressed one row slide over others to select them,
/// as in a photo gallery, scrolling the list while it rests near an edge.
///
/// Rows are wrapped in a [DragSelectItem]. A row's own long press stays where
/// it is and calls [begin]; a won long press already keeps the list from
/// scrolling, so this only follows the pointer until it lifts.
class DragSelectController {
  DragSelectController({required this.onUpdate, this.onEnd});

  /// The finger that began on row [anchor] is now over row [current].
  final void Function(Object anchor, Object current) onUpdate;

  /// The finger lifted.
  final VoidCallback? onEnd;

  /// Height of the band at each end of the list that scrolls it.
  static const double _edgeZone = 96;
  static const double _minSpeed = 240;
  static const double _maxSpeed = 1500;

  final _items = <Object, _DragSelectItemState>{};
  Ticker? _ticker;
  Duration _lastTick = Duration.zero;

  // The finger last put down on a row.
  int? _pointer;
  Offset _position = Offset.zero;
  Object? _anchor;
  Object? _current;

  /// Whether a held finger is selecting rows right now.
  bool get isActive => _anchor != null;

  /// The finger that long pressed row [id] selects the rows it slides over
  /// until it lifts. Does nothing without a finger on a row, as for a long
  /// press from a screen reader, and on desktop.
  void begin(Object id) {
    if (isDesktopPlatform || _pointer == null || _anchor != null) return;
    _anchor = id;
    _current = id;
    _lastTick = Duration.zero;
    GestureBinding.instance.pointerRouter.addGlobalRoute(_onPointer);
    _syncAutoScrollTicker();
  }

  void dispose() {
    _finish(notify: false);
    _items.clear();
  }

  void _finish({bool notify = true}) {
    _pointer = null;
    if (_anchor == null) return;
    _anchor = null;
    _current = null;
    GestureBinding.instance.pointerRouter.removeGlobalRoute(_onPointer);
    _ticker?.dispose();
    _ticker = null;
    if (notify) onEnd?.call();
  }

  void _onPointer(PointerEvent event) {
    if (event.pointer != _pointer) return;
    if (event is PointerMoveEvent) {
      _position = event.position;
      _retarget();
      _syncAutoScrollTicker();
    } else if (event is PointerUpEvent || event is PointerCancelEvent) {
      _finish();
    }
  }

  double _edgeDepth(Rect rect) {
    final up = clampDouble(
      (rect.top + _edgeZone - _position.dy) / _edgeZone,
      0,
      1,
    );
    final down = clampDouble(
      (_position.dy - (rect.bottom - _edgeZone)) / _edgeZone,
      0,
      1,
    );
    return down - up;
  }

  void _syncAutoScrollTicker() {
    final viewport = _viewport();
    final needsScroll = viewport != null && _edgeDepth(viewport.$2) != 0;
    if (needsScroll) {
      if (_ticker == null) {
        _lastTick = Duration.zero;
        _ticker = Ticker(_autoScroll)..start();
      } else if (!_ticker!.isActive) {
        _lastTick = Duration.zero;
        _ticker!.start();
      }
    } else if (_ticker?.isActive ?? false) {
      _ticker!.stop();
    }
  }

  /// The list the rows scroll in, and the part of it a finger can reach.
  /// Measured each time: a collapsing header moves the list mid gesture.
  (ScrollPosition, Rect)? _viewport() {
    final row = _items[_anchor] ?? _items.values.firstOrNull;
    if (row == null) return null;
    final scrollable = Scrollable.maybeOf(row.context);
    final box = scrollable?.context.findRenderObject();
    if (scrollable == null || box is! RenderBox || !box.hasSize) return null;
    if (scrollable.position.axis != Axis.vertical) return null;
    // Bars the list runs under are not part of it. Read without registering a
    // permanent MediaQuery dependency on the row element during pointer moves.
    final media = row.context.getInheritedWidgetOfExactType<MediaQuery>()?.data;
    final rect = box.localToGlobal(Offset.zero) & box.size;
    if (media == null) return (scrollable.position, rect);
    return (
      scrollable.position,
      Rect.fromLTRB(
        rect.left,
        math.max(rect.top, media.padding.top),
        rect.right,
        math.min(rect.bottom, media.size.height - media.padding.bottom),
      ),
    );
  }

  /// Moves the selection to the row nearest the finger.
  void _retarget({bool haptic = true}) {
    final anchor = _anchor;
    if (anchor == null) return;
    var point = _position;
    final rect = _viewport()?.$2;
    if (rect != null && !rect.isEmpty) {
      // Rows built ahead of the list's visible part are out of reach.
      point = Offset(
        clampDouble(point.dx, rect.left, rect.right),
        clampDouble(point.dy, rect.top, rect.bottom),
      );
    }
    Object? nearest;
    var nearestDistance = double.infinity;
    for (final MapEntry(key: id, value: row) in _items.entries) {
      final box = row.context.findRenderObject();
      if (box is! RenderBox || !box.attached || !box.hasSize) continue;
      final bounds = box.localToGlobal(Offset.zero) & box.size;
      // A held row kept alive off screen has no place on it.
      if (!bounds.isFinite) continue;
      final dx = point.dx < bounds.left
          ? bounds.left - point.dx
          : (point.dx > bounds.right ? point.dx - bounds.right : 0.0);
      final dy = point.dy < bounds.top
          ? bounds.top - point.dy
          : (point.dy > bounds.bottom ? point.dy - bounds.bottom : 0.0);
      final distance = dx * dx + dy * dy;
      if (distance < nearestDistance) {
        nearestDistance = distance;
        nearest = id;
      }
    }
    if (nearest == null || nearest == _current) return;
    _current = nearest;
    if (haptic) HapticFeedback.selectionClick();
    onUpdate(anchor, nearest);
  }

  void _autoScroll(Duration elapsed) {
    final dt =
        (elapsed - _lastTick).inMicroseconds / Duration.microsecondsPerSecond;
    _lastTick = elapsed;
    final viewport = _viewport();
    if (viewport == null || dt <= 0) return;
    final (position, rect) = viewport;
    // How far into a band the finger rests: 0 where it starts, 1 at the edge.
    final depth = _edgeDepth(rect);
    if (depth == 0) {
      _ticker?.stop();
      return;
    }
    final speed = _minSpeed + (_maxSpeed - _minSpeed) * depth.abs();
    final target = clampDouble(
      position.pixels + depth.sign * speed * dt,
      position.minScrollExtent,
      position.maxScrollExtent,
    );
    if (target == position.pixels) return;
    position.jumpTo(target);
    // The row under the finger is known once the list has laid out. Rows
    // passing under a resting finger do not each tick.
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _retarget(haptic: false),
    );
  }
}

/// One selectable row of a [DragSelectController], known by its selection
/// [id].
class DragSelectItem extends StatefulWidget {
  const DragSelectItem({
    super.key,
    required this.controller,
    required this.id,
    required this.child,
  });

  final DragSelectController controller;
  final Object id;
  final Widget child;

  @override
  State<DragSelectItem> createState() => _DragSelectItemState();
}

class _DragSelectItemState extends State<DragSelectItem> {
  @override
  void initState() {
    super.initState();
    widget.controller._items[widget.id] = this;
  }

  @override
  void didUpdateWidget(DragSelectItem oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.id == widget.id &&
        oldWidget.controller == widget.controller) {
      return;
    }
    _unregister(oldWidget);
    widget.controller._items[widget.id] = this;
  }

  @override
  void dispose() {
    _unregister(widget);
    super.dispose();
  }

  // A row rebuilt under the same id may already have taken the entry.
  void _unregister(DragSelectItem of) {
    if (of.controller._items[of.id] == this) of.controller._items.remove(of.id);
  }

  @override
  Widget build(BuildContext context) {
    // A row scrolled away still hears its finger lift.
    final controller = widget.controller;
    void lifted(PointerEvent event) {
      if (!controller.isActive && controller._pointer == event.pointer) {
        controller._pointer = null;
      }
    }

    return Listener(
      onPointerDown: (event) {
        if (controller.isActive) return;
        controller._pointer = event.pointer;
        controller._position = event.position;
      },
      onPointerUp: lifted,
      onPointerCancel: lifted,
      child: widget.child,
    );
  }
}
