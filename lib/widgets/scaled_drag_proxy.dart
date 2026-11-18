import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// Keeps a reorderable list's dragged row under the finger while the
/// interface is scaled. Flutter places that row by screen positions, which
/// are not the positions of a scaled page. For vertical lists.
class ScaledDragProxy extends SingleChildRenderObjectWidget {
  const ScaledDragProxy({super.key, required this.animation, super.child});

  /// The animation a list hands its `proxyDecorator`.
  final Animation<double> animation;

  /// The `proxyDecorator` of a list that draws the dragged row as it is.
  static Widget plain(Widget child, int index, Animation<double> animation) =>
      ScaledDragProxy(animation: animation, child: child);

  /// Starts following touches: a drag needs where its finger went down.
  static void trackPointers() => _DragPointer.track();

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderScaledDragProxy(animation, _overlayOf(context));

  @override
  void updateRenderObject(BuildContext context, RenderObject renderObject) {
    (renderObject as _RenderScaledDragProxy)
      ..animation = animation
      ..overlay = _overlayOf(context);
  }

  static RenderBox? _overlayOf(BuildContext context) {
    final box = Overlay.maybeOf(context)?.context.findRenderObject();
    return box is RenderBox ? box : null;
  }
}

/// The touch a drag follows. A vertical list keeps the row at the horizontal
/// position where the finger went down.
abstract final class _DragPointer {
  static bool _tracking = false;
  static int? _pointer;
  static Offset? _down;
  static Offset _last = Offset.zero;

  static void track() {
    if (_tracking) return;
    _tracking = true;
    GestureBinding.instance.pointerRouter.addGlobalRoute(_route);
  }

  static void _route(PointerEvent event) {
    if (event is PointerDownEvent) {
      _pointer = event.pointer;
      _down = _last = event.position;
    } else if (event is PointerMoveEvent && event.pointer == _pointer) {
      _last = event.position;
    }
  }

  static Offset? get held => switch (_down) {
    final down? => Offset(down.dx, _last.dy),
    null => null,
  };
}

class _RenderScaledDragProxy extends RenderProxyBox {
  _RenderScaledDragProxy(this._animation, this.overlay);

  /// The overlay the list draws the row in, whose pixels are the page's.
  RenderBox? overlay;

  Animation<double> _animation;
  set animation(Animation<double> value) {
    if (value == _animation) return;
    if (attached) _animation.removeListener(markNeedsPaint);
    _animation = value;
    if (attached) value.addListener(markNeedsPaint);
  }

  // Where the finger holds the row, from the row's corner.
  Offset? _grab;
  Offset _shift = Offset.zero;

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _animation.addListener(markNeedsPaint);
  }

  @override
  void detach() {
    _animation.removeListener(markNeedsPaint);
    super.detach();
  }

  Offset _measureShift() {
    final overlay = this.overlay;
    if (overlay == null || !overlay.attached) return Offset.zero;
    final origin = overlay.localToGlobal(Offset.zero);
    final scale = overlay.localToGlobal(const Offset(1, 0)).dx - origin.dx;
    if (scale <= 0 || (scale - 1).abs() < 0.001) return Offset.zero;
    // Flutter drew the row at the finger's screen position less the grab.
    final drawn = localToGlobal(Offset.zero, ancestor: overlay);
    final grab = _grab ??= switch (_DragPointer.held) {
      final held? => held - origin - drawn,
      null => Offset.zero,
    };
    // A dropped row travels to its place on this curve, the grab with it.
    final held = _animation.status == AnimationStatus.reverse
        ? Curves.easeOut.transform(_animation.value)
        : 1.0;
    return (drawn + grab * held) * (1 / scale - 1);
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final child = this.child;
    if (child == null) return;
    _shift = _measureShift();
    context.paintChild(child, offset + _shift);
  }

  @override
  void applyPaintTransform(RenderBox child, Matrix4 transform) {
    transform.translateByDouble(_shift.dx, _shift.dy, 0, 1);
  }
}
