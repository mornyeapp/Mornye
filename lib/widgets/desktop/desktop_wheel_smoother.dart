import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// Turns desktop mouse wheel smoothing off with
/// `--dart-define=DESKTOP_WHEEL_SMOOTHING=false`.
const bool kDesktopWheelSmoothing = bool.fromEnvironment(
  'DESKTOP_WHEEL_SMOOTHING',
  defaultValue: true,
);

/// Eases discrete mouse wheel notches on desktop.
///
/// Flutter scrolls a notch's full step in one frame. The smoother holds each
/// notch and sends it on as one smaller [PointerScrollEvent] per frame at the
/// notch's position, so every [Scrollable] eases over about 150 ms with no
/// overshoot and lands where the notch alone would have. Notches in the same
/// direction add to what is left; a reversal drops it.
///
/// Touchpads (pan-zoom events), small deltas from high-resolution wheels,
/// sideways deltas, Shift-held wheels (sideways scrolling), reduced motion
/// and wheels over a [DesktopWheelPassThrough] pass through untouched.
class DesktopWheelSmoother {
  DesktopWheelSmoother({
    required this.dispatch,
    required this.scheduleFrame,
    required this.now,
    required this.reducedMotion,
    required this.shiftPressed,
    required this.hitsPassThrough,
  });

  /// Wires the smoother to [binding]. [dispatch] must hand events to the
  /// binding's own pointer handling, past the smoother.
  factory DesktopWheelSmoother.forBinding(
    WidgetsBinding binding, {
    required void Function(PointerEvent event) dispatch,
  }) {
    final clock = Stopwatch()..start();
    return DesktopWheelSmoother(
      dispatch: dispatch,
      scheduleFrame: (onFrame) =>
          binding.scheduleFrameCallback((_) => onFrame()),
      now: () => clock.elapsed,
      reducedMotion: () =>
          binding.platformDispatcher.accessibilityFeatures.disableAnimations,
      shiftPressed: () => HardwareKeyboard.instance.isShiftPressed,
      hitsPassThrough: (event) => hitsDesktopWheelPassThrough(binding, event),
    );
  }

  /// Smallest wheel step that counts as a notch, in logical pixels.
  static const double minNotch = 30;

  // Each frame moves this share of what is left: 1 - exp(-dt / 40 ms), so
  // about 95% of a notch lands within 120 ms and the curve never overshoots.
  static const double _timeConstantMs = 40;

  // The last half pixel goes in one piece.
  static const double _snap = 0.5;

  // Pieces are whole 1/64 px, so their running sum is exact in floating
  // point and the list lands on the offset a direct notch reaches.
  static const double _quantum = 1 / 64;

  // A notch this far from the last one starts over at its own position.
  static const double _moveTolerance = 48;

  final void Function(PointerEvent event) dispatch;
  final void Function(VoidCallback onFrame) scheduleFrame;
  final Duration Function() now;
  final bool Function() reducedMotion;
  final bool Function() shiftPressed;
  final bool Function(PointerScrollEvent event) hitsPassThrough;

  PointerScrollEvent? _notch;
  double _pending = 0;
  Duration _lastFrame = Duration.zero;
  bool _frameScheduled = false;

  /// Returns true when the smoother takes [event] and will send it on in
  /// pieces; false when the caller should handle it as usual.
  bool handlePointerEvent(PointerEvent event) {
    if (event is PointerDownEvent || event is PointerPanZoomStartEvent) {
      // A click, scrollbar drag or touchpad takes over from the wheel.
      _pending = 0;
      _notch = null;
      return false;
    }
    if (event is! PointerScrollEvent || !_smooths(event)) return false;
    final delta = event.scrollDelta.dy;
    final last = _notch;
    if (last != null && _pending != 0) {
      if (last.viewId != event.viewId ||
          (last.position - event.position).distance > _moveTolerance) {
        // Finish the old run where it started before scrolling elsewhere.
        _send(last, _pending);
        _pending = 0;
      } else if (delta.sign != _pending.sign) {
        _pending = 0;
      }
    }
    if (_pending == 0) _lastFrame = now();
    _notch = event;
    _pending += delta;
    if (!_frameScheduled) {
      _frameScheduled = true;
      scheduleFrame(_onFrame);
    }
    return true;
  }

  bool _smooths(PointerScrollEvent event) {
    final delta = event.scrollDelta;
    return event.kind == PointerDeviceKind.mouse &&
        delta.dx == 0 &&
        delta.dy.isFinite &&
        delta.dy.abs() >= minNotch &&
        !reducedMotion() &&
        !shiftPressed() &&
        !hitsPassThrough(event);
  }

  void _onFrame() {
    _frameScheduled = false;
    final notch = _notch;
    if (notch == null || _pending == 0) return;
    if (shiftPressed()) {
      // Scrollable turns a Shift-held vertical delta sideways, so the rest
      // of a vertical notch would scroll a row instead.
      _pending = 0;
      _notch = null;
      return;
    }
    final time = now();
    final elapsedMs = (time - _lastFrame).inMicroseconds / 1000;
    _lastFrame = time;
    var step = _pending * (1 - math.exp(-elapsedMs / _timeConstantMs));
    step = (step / _quantum).roundToDouble() * _quantum;
    if ((_pending - step).abs() < _snap) step = _pending;
    if (step != 0) {
      _pending -= step;
      _send(notch, step);
    }
    if (_pending == 0) {
      _notch = null;
    } else if (!_frameScheduled) {
      _frameScheduled = true;
      scheduleFrame(_onFrame);
    }
  }

  void _send(PointerScrollEvent notch, double step) {
    dispatch(
      PointerScrollEvent(
        viewId: notch.viewId,
        timeStamp: notch.timeStamp,
        kind: notch.kind,
        device: notch.device,
        position: notch.position,
        embedderId: notch.embedderId,
        scrollDelta: Offset(0, step),
      ),
    );
  }
}

/// Whether a wheel event at [event]'s position lands on a
/// [DesktopWheelPassThrough].
bool hitsDesktopWheelPassThrough(GestureBinding binding, PointerEvent event) {
  final result = HitTestResult();
  binding.hitTestInView(result, event.position, event.viewId);
  return result.path.any((entry) => entry.target is _RenderWheelPassThrough);
}

/// Lets mouse wheel notches over [child] through unsmoothed, for controls
/// that step once per notch, such as the desktop volume.
class DesktopWheelPassThrough extends SingleChildRenderObjectWidget {
  const DesktopWheelPassThrough({super.key, super.child});

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderWheelPassThrough();
}

class _RenderWheelPassThrough extends RenderProxyBox {}
