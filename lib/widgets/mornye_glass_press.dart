import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';

/// How far the press value rests while a mouse is over the control.
const double _hoverLevel = 0.3;

/// The liquid response of a glass control: it swells under the pointer, leans
/// towards a drag, carries a soft light at the pointer and springs back with a
/// small wobble.
///
/// Everything here is paint: the control's layout and hit target never move,
/// and [Listener] stays out of the gesture arena, so a cancelled press behaves
/// exactly as it does without this widget. No ticker runs at rest.
class MornyeGlassPress extends StatefulWidget {
  const MornyeGlassPress({
    super.key,
    required this.radius,
    required this.child,
    this.enabled = true,
  });

  /// Corner radius of the glass, which bounds the light.
  final double radius;
  final Widget child;

  /// Disabled controls stay still.
  final bool enabled;

  @override
  State<MornyeGlassPress> createState() => _MornyeGlassPressState();
}

class _MornyeGlassPressState extends State<MornyeGlassPress>
    with SingleTickerProviderStateMixin {
  // Underdamped, so a release overshoots a little and settles.
  static const _spring = SpringDescription(
    mass: 1,
    stiffness: 420,
    damping: 24,
  );

  late final AnimationController _press = AnimationController.unbounded(
    vsync: this,
  );
  final _drag = ValueNotifier<Offset>(Offset.zero);
  late final Listenable _motion = Listenable.merge([_press, _drag]);

  /// The pointer in local coordinates, kept after release so the light fades
  /// where it was.
  Offset? _pointer;
  Offset _origin = Offset.zero;
  Size _size = Size.zero;
  int? _activePointer;
  bool _hovered = false;

  @override
  void dispose() {
    _press.dispose();
    _drag.dispose();
    super.dispose();
  }

  void _measure() {
    final box = context.findRenderObject();
    if (box is RenderBox && box.hasSize) _size = box.size;
  }

  void _settle() {
    final target = _activePointer != null
        ? 1.0
        : _hovered
        ? _hoverLevel
        : 0.0;
    if (MediaQuery.disableAnimationsOf(context)) {
      _press.value = target;
      return;
    }
    _press.animateWith(
      SpringSimulation(
        _spring,
        _press.value,
        target,
        _press.velocity,
        snapToEnd: true,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) return widget.child;
    final still = MediaQuery.disableAnimationsOf(context);
    final radius = widget.radius;
    return MouseRegion(
      opaque: false,
      onEnter: (event) {
        _measure();
        _hovered = true;
        _pointer = event.localPosition;
        _settle();
      },
      onHover: (event) => _pointer = event.localPosition,
      onExit: (_) {
        _hovered = false;
        _settle();
      },
      child: Listener(
        onPointerDown: (event) {
          if (_activePointer != null) return;
          _measure();
          _activePointer = event.pointer;
          _origin = event.localPosition;
          _pointer = event.localPosition;
          _drag.value = Offset.zero;
          _settle();
        },
        onPointerMove: (event) {
          if (event.pointer != _activePointer) return;
          _pointer = event.localPosition;
          _drag.value = event.localPosition - _origin;
        },
        onPointerUp: (event) {
          if (event.pointer != _activePointer) return;
          _activePointer = null;
          _settle();
        },
        onPointerCancel: (event) {
          if (event.pointer != _activePointer) return;
          _activePointer = null;
          _settle();
        },
        child: AnimatedBuilder(
          animation: _motion,
          child: widget.child,
          builder: (context, child) {
            final press = _press.value;
            // These stay in the tree at rest: inserting one mid-press would
            // remount the control and lose its gesture.
            return Transform(
              alignment: Alignment.center,
              transform: still || _size.isEmpty || press == 0
                  ? Matrix4.identity()
                  : _deformation(press),
              // The control answers at its resting bounds.
              transformHitTests: false,
              child: CustomPaint(
                foregroundPainter: _GlassLightPainter(
                  center: _pointer,
                  strength: press.clamp(0.0, 1.0),
                  radius: radius,
                ),
                child: child,
              ),
            );
          },
        ),
      ),
    );
  }

  /// A fixed swell in points, so a wide bar moves no more than a small button,
  /// with the shape stretching along a drag and thinning across it.
  Matrix4 _deformation(double press) {
    final swell = (_size.shortestSide * 0.10).clamp(2.0, 5.0) * press;
    var scaleX = 1 + swell / _size.width;
    var scaleY = 1 + swell / _size.height;
    final lean = Offset(
      (_drag.value.dx / 40).clamp(-1.0, 1.0),
      (_drag.value.dy / 40).clamp(-1.0, 1.0),
    );
    final bias = math.max(press, 0.0);
    scaleX += (lean.dx.abs() * 0.05 - lean.dy.abs() * 0.025) * bias;
    scaleY += (lean.dy.abs() * 0.05 - lean.dx.abs() * 0.025) * bias;
    return Matrix4.identity()
      ..translateByDouble(lean.dx * 3 * bias, lean.dy * 3 * bias, 0, 1)
      ..scaleByDouble(scaleX, scaleY, 1, 1);
  }
}

/// A soft light at the pointer, inside the control's shape. It adds no
/// backdrop read, so it costs the same over any page.
class _GlassLightPainter extends CustomPainter {
  const _GlassLightPainter({
    required this.center,
    required this.strength,
    required this.radius,
  });

  final Offset? center;
  final double strength;
  final double radius;

  @override
  void paint(Canvas canvas, Size size) {
    if (strength <= 0) return;
    final bounds = Offset.zero & size;
    final focus = center ?? bounds.center;
    final reach = size.longestSide.clamp(40.0, 180.0);
    canvas.save();
    canvas.clipRRect(RRect.fromRectAndRadius(bounds, Radius.circular(radius)));
    canvas.drawRect(
      bounds,
      Paint()
        ..shader = RadialGradient(
          colors: [
            Colors.white.withValues(alpha: 0.20 * strength),
            Colors.white.withValues(alpha: 0),
          ],
        ).createShader(Rect.fromCircle(center: focus, radius: reach)),
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _GlassLightPainter oldDelegate) =>
      center != oldDelegate.center ||
      strength != oldDelegate.strength ||
      radius != oldDelegate.radius;
}
