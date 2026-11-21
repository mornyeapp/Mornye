import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:mornye/utils/android_tv.dart';
import 'package:mornye/utils/desktop_platform.dart';

/// An iOS-style slider: a thin rounded track and a white shadowed knob.
///
/// Unlike [CupertinoSlider], the active track can grow from an [origin]
/// inside the range (gain, balance) and the slider can stand [vertical], with
/// [min] at the bottom. A vertical slider only claims vertical drags, so a
/// row of them still scrolls sideways.
class MornyeLevelSlider extends StatelessWidget {
  const MornyeLevelSlider({
    super.key,
    required this.value,
    required this.onChanged,
    this.min = 0,
    this.max = 1,
    this.origin,
    this.vertical = false,
    this.step,
    this.semanticLabel,
    this.semanticFormatterCallback,
    this.knobRadius = CupertinoThumbPainter.radius,
  });

  final double value, min, max;

  /// Smaller knobs keep a dense row of vertical faders from touching.
  final double knobRadius;
  final ValueChanged<double>? onChanged;

  /// Where the active track starts; [min] when null.
  final double? origin;
  final bool vertical;

  /// Accessibility increment; a hundredth of the range when null.
  final double? step;
  final String? semanticLabel;
  final String Function(double value)? semanticFormatterCallback;

  static const _trackThickness = 4.0;

  double get _origin => (origin ?? min).clamp(min, max);

  void _update(Offset local, Size size, {required bool rtl}) {
    final extent = (vertical ? size.height : size.width) - knobRadius * 2;
    if (extent <= 0) return;
    var fraction = ((vertical ? local.dy : local.dx) - knobRadius) / extent;
    if (vertical || rtl) fraction = 1 - fraction;
    final next = min + fraction.clamp(0.0, 1.0) * (max - min);
    // A light tick when the knob reaches or crosses the origin.
    final at = _origin;
    if ((value - at).sign != (next - at).sign && value != next) {
      HapticFeedback.selectionClick();
    }
    onChanged?.call(next);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final enabled = onChanged != null;
    final active = enabled ? scheme.primary : CupertinoColors.inactiveGray;
    final track = CupertinoColors.systemFill.resolveFrom(context);
    final increment = step ?? (max - min) / 100;
    final rtl = !vertical && Directionality.of(context) == TextDirection.rtl;
    final keyboardFocusable = isAndroidTv || isDesktopPlatform;
    String format(double v) =>
        semanticFormatterCallback?.call(v) ?? v.toStringAsFixed(1);
    return Semantics(
      slider: true,
      enabled: enabled,
      label: semanticLabel,
      value: format(value),
      increasedValue: format((value + increment).clamp(min, max)),
      decreasedValue: format((value - increment).clamp(min, max)),
      onIncrease: enabled
          ? () => onChanged!((value + increment).clamp(min, max))
          : null,
      onDecrease: enabled
          ? () => onChanged!((value - increment).clamp(min, max))
          : null,
      child: Focus(
        canRequestFocus: keyboardFocusable && enabled,
        skipTraversal: !keyboardFocusable,
        onKeyEvent: (node, event) {
          if (!keyboardFocusable || !enabled || !node.hasPrimaryFocus) {
            return KeyEventResult.ignored;
          }
          final increaseKey = vertical
              ? LogicalKeyboardKey.arrowUp
              : rtl
              ? LogicalKeyboardKey.arrowLeft
              : LogicalKeyboardKey.arrowRight;
          final decreaseKey = vertical
              ? LogicalKeyboardKey.arrowDown
              : rtl
              ? LogicalKeyboardKey.arrowRight
              : LogicalKeyboardKey.arrowLeft;
          final increase = event.logicalKey == increaseKey;
          final decrease = event.logicalKey == decreaseKey;
          if (!increase && !decrease) return KeyEventResult.ignored;
          if (event is KeyDownEvent || event is KeyRepeatEvent) {
            onChanged!(
              (value + (increase ? increment : -increment)).clamp(min, max),
            );
          }
          return KeyEventResult.handled;
        },
        child: LayoutBuilder(
          builder: (context, constraints) {
            // A 48 dp touch target across the track.
            final size = Size(
              vertical && !constraints.hasBoundedWidth
                  ? 48
                  : constraints.maxWidth,
              vertical ? constraints.maxHeight : 48,
            );
            void update(Offset local) => _update(local, size, rtl: rtl);
            return GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapDown: enabled ? (d) => update(d.localPosition) : null,
              onHorizontalDragStart: enabled && !vertical
                  ? (d) => update(d.localPosition)
                  : null,
              onHorizontalDragUpdate: enabled && !vertical
                  ? (d) => update(d.localPosition)
                  : null,
              onVerticalDragStart: enabled && vertical
                  ? (d) => update(d.localPosition)
                  : null,
              onVerticalDragUpdate: enabled && vertical
                  ? (d) => update(d.localPosition)
                  : null,
              child: CustomPaint(
                size: size,
                painter: _LevelPainter(
                  fraction: ((value - min) / (max - min)).clamp(0.0, 1.0),
                  origin: (_origin - min) / (max - min),
                  vertical: vertical,
                  rtl: rtl,
                  active: active,
                  track: track,
                  knobRadius: knobRadius,
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _LevelPainter extends CustomPainter {
  const _LevelPainter({
    required this.fraction,
    required this.origin,
    required this.vertical,
    required this.rtl,
    required this.active,
    required this.track,
    required this.knobRadius,
  });

  final double fraction, origin, knobRadius;
  final bool vertical, rtl;
  final Color active, track;

  @override
  void paint(Canvas canvas, Size size) {
    final r = knobRadius;
    const t = MornyeLevelSlider._trackThickness;
    final length = (vertical ? size.height : size.width) - r * 2;
    Offset at(double f) => vertical
        ? Offset(size.width / 2, r + (1 - f) * length)
        : Offset(r + (rtl ? 1 - f : f) * length, size.height / 2);
    Rect span(double a, double b) {
      final p = at(a), q = at(b);
      return vertical
          ? Rect.fromLTRB(p.dx - t / 2, q.dy, p.dx + t / 2, p.dy)
          : Rect.fromLTRB(
              p.dx < q.dx ? p.dx : q.dx,
              p.dy - t / 2,
              p.dx < q.dx ? q.dx : p.dx,
              p.dy + t / 2,
            );
    }

    const radius = Radius.circular(t / 2);
    canvas.drawRRect(
      RRect.fromRectAndRadius(span(0, 1), radius),
      Paint()..color = track,
    );
    final low = fraction < origin ? fraction : origin;
    final high = fraction < origin ? origin : fraction;
    if (high > low) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(span(low, high), radius),
        Paint()..color = active,
      );
    }
    const CupertinoThumbPainter().paint(
      canvas,
      Rect.fromCircle(center: at(fraction), radius: r),
    );
  }

  @override
  bool shouldRepaint(_LevelPainter oldDelegate) =>
      oldDelegate.fraction != fraction ||
      oldDelegate.origin != origin ||
      oldDelegate.vertical != vertical ||
      oldDelegate.rtl != rtl ||
      oldDelegate.active != active ||
      oldDelegate.track != track ||
      oldDelegate.knobRadius != knobRadius;
}
