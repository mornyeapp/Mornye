import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:material_3_expressive/components/sliders/components/m3e_slider_track_painter.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:mornye/widgets/decorative_phase.dart';

/// Expressive track motion around the native slider's seeking and accessibility.
class ExpressiveSeekTrack extends StatefulWidget {
  const ExpressiveSeekTrack({
    super.key,
    required this.playing,
    required this.child,
  });

  final bool playing;
  final Widget child;

  @override
  State<ExpressiveSeekTrack> createState() => _ExpressiveSeekTrackState();
}

class _ExpressiveSeekTrackState extends State<ExpressiveSeekTrack>
    with SingleTickerProviderStateMixin {
  final _phase = DecorativePhase(const Duration(milliseconds: 1800));
  late final _amplitude =
      AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 300),
      )..addStatusListener((status) {
        if (status == AnimationStatus.dismissed) _phase.stop();
      });
  late final _animation = Listenable.merge([_phase, _amplitude]);
  late final _trackShape = ExpressiveSeekTrackShape(
    phase: _phase,
    amplitude: _amplitude,
  );
  bool _motionEnabled = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _motionEnabled =
        !MediaQuery.disableAnimationsOf(context) &&
        TickerMode.valuesOf(context).enabled;
    _syncAnimation();
  }

  @override
  void didUpdateWidget(ExpressiveSeekTrack oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.playing != widget.playing) _syncAnimation();
  }

  void _syncAnimation() {
    if (!_motionEnabled) {
      _phase.stop();
      _amplitude.value = 0;
    } else if (widget.playing) {
      _phase.start();
      _amplitude.forward();
    } else {
      _amplitude.reverse();
      if (_amplitude.isDismissed) _phase.stop();
    }
  }

  @override
  void dispose() {
    _amplitude.dispose();
    _phase.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => RepaintBoundary(
    child: _AnimatedTrackRepaint(
      repaint: _animation,
      child: SliderTheme(
        data: SliderTheme.of(context).copyWith(
          trackHeight: 4,
          trackShape: _trackShape,
          thumbShape: const HandleThumbShape(),
          thumbSize: const WidgetStatePropertyAll(Size(4, 24)),
        ),
        child: widget.child,
      ),
    ),
  );
}

/// A wave tick changes paint only. In particular it must not invalidate the
/// SliderTheme dependency of the native slider on every tick.
class _AnimatedTrackRepaint extends SingleChildRenderObjectWidget {
  const _AnimatedTrackRepaint({required this.repaint, required super.child});

  final Listenable repaint;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderAnimatedTrackRepaint(repaint);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderAnimatedTrackRepaint renderObject,
  ) => renderObject.repaint = repaint;
}

class _RenderAnimatedTrackRepaint extends RenderProxyBox {
  _RenderAnimatedTrackRepaint(this._repaint);

  Listenable _repaint;

  set repaint(Listenable value) {
    if (identical(value, _repaint)) return;
    if (attached) _repaint.removeListener(markNeedsPaint);
    _repaint = value;
    if (attached) _repaint.addListener(markNeedsPaint);
    markNeedsPaint();
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _repaint.addListener(markNeedsPaint);
  }

  @override
  void detach() {
    _repaint.removeListener(markNeedsPaint);
    super.detach();
  }
}

/// Uses the package's wave renderer without changing the slider gesture cycle.
class ExpressiveSeekTrackShape extends RoundedRectSliderTrackShape {
  const ExpressiveSeekTrackShape({
    required ValueListenable<double> phase,
    required Animation<double> amplitude,
  }) : _phase = phase,
       _amplitude = amplitude;

  final ValueListenable<double> _phase;
  final Animation<double> _amplitude;

  double get phase => _phase.value * 2 * math.pi;
  double get amplitude => Curves.easeInOutCubic.transform(_amplitude.value);

  @override
  void paint(
    PaintingContext context,
    Offset offset, {
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required Animation<double> enableAnimation,
    required TextDirection textDirection,
    required Offset thumbCenter,
    Offset? secondaryOffset,
    bool isDiscrete = false,
    bool isEnabled = false,
    double additionalActiveTrackHeight = 2,
  }) {
    final track = getPreferredRect(
      parentBox: parentBox,
      offset: offset,
      sliderTheme: sliderTheme,
      isEnabled: isEnabled,
      isDiscrete: isDiscrete,
    );
    if (track.isEmpty) return;
    final rtl = textDirection == TextDirection.rtl;
    final fraction =
        ((rtl ? track.right - thumbCenter.dx : thumbCenter.dx - track.left) /
                track.width)
            .clamp(0.0, 1.0);
    final active = Color.lerp(
      sliderTheme.disabledActiveTrackColor,
      sliderTheme.activeTrackColor,
      enableAnimation.value,
    )!;
    final inactive = Color.lerp(
      sliderTheme.disabledInactiveTrackColor,
      sliderTheme.inactiveTrackColor,
      enableAnimation.value,
    )!;
    final painter = M3ESliderTrackPainter(
      mode: M3ESliderPaintMode.single,
      trackKind: M3ESliderTrackKind.standard,
      activeStartFraction: 0,
      activeEndFraction: fraction,
      tickFractions: const [],
      colors: M3ESliderColors(
        thumb: active,
        activeTrack: active,
        inactiveTrack: inactive,
        activeTick: inactive,
        inactiveTick: active,
        stopIndicator: active,
        valueIndicator: active,
        valueIndicatorLabel: inactive,
      ),
      trackHeight: track.height,
      handleGap: 6,
      handleThickness: 4,
      insideCornerSize: 2,
      cornerRadius: 2,
      stopIndicatorSize: 4,
      tickSize: 0,
      edgeInset: 2,
      axis: Axis.horizontal,
      // Mirror the complete logical track, including waves and the end marker.
      textDirection: TextDirection.ltr,
      isWavy: amplitude > 0,
      waveAmplitude: 3,
      wavelength: 40,
      phase: phase,
      amplitudeFactor: amplitude,
    );
    final canvas = context.canvas;
    canvas.save();
    canvas.translate(rtl ? track.right : track.left, track.top);
    if (rtl) canvas.scale(-1, 1);
    painter.paint(canvas, track.size);
    canvas.restore();
  }
}
