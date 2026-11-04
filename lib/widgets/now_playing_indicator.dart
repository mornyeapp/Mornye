import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:mornye/widgets/decorative_phase.dart';

/// Three equalizer bars that mark the current track in a list.
///
/// The bars move while [playing] and freeze where they are once playback
/// pauses. Reduced motion keeps them still, and the motion stops while a
/// disabled [TickerMode] hides the glyph, such as on a covered route, or
/// while the app's window is not active.
///
/// The glyph is decorative: the row it sits in carries the label, so it
/// adds nothing to the semantics tree.
class NowPlayingIndicator extends StatefulWidget {
  const NowPlayingIndicator({
    super.key,
    required this.playing,
    this.color,
    this.size = 16,
  });

  /// Whether playback is running. False holds the bars in place.
  final bool playing;

  /// Bar color. Defaults to [ColorScheme.onPrimaryContainer], the content
  /// color of the current row.
  final Color? color;

  /// Width and height of the square glyph.
  final double size;

  @override
  State<NowPlayingIndicator> createState() => _NowPlayingIndicatorState();
}

class _NowPlayingIndicatorState extends State<NowPlayingIndicator>
    with WidgetsBindingObserver {
  final _phase = DecorativePhase(const Duration(milliseconds: 2400));
  bool _motionEnabled = false;
  bool _appActive = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    _appActive = lifecycle == null || lifecycle == AppLifecycleState.resumed;
  }

  // A window in the background keeps the glyph but not its animation.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _appActive = state == AppLifecycleState.resumed;
    _syncAnimation();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _motionEnabled =
        !MediaQuery.disableAnimationsOf(context) &&
        TickerMode.valuesOf(context).enabled;
    _syncAnimation();
  }

  @override
  void didUpdateWidget(NowPlayingIndicator oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.playing != widget.playing) _syncAnimation();
  }

  void _syncAnimation() {
    if (_motionEnabled && _appActive && widget.playing) {
      _phase.start();
    } else {
      _phase.stop();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _phase.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color =
        widget.color ?? Theme.of(context).colorScheme.onPrimaryContainer;
    return ExcludeSemantics(
      child: RepaintBoundary(
        child: CustomPaint(
          size: Size.square(widget.size),
          painter: _EqualizerPainter(progress: _phase, color: color),
        ),
      ),
    );
  }
}

class _EqualizerPainter extends CustomPainter {
  _EqualizerPainter({required this.progress, required this.color})
    : super(repaint: progress);

  final ValueListenable<double> progress;
  final Color color;

  /// Two waves per bar, each a whole number of cycles per loop so the loop
  /// has no seam. At rest (progress 0) the bars read tall, taller, short.
  static const _waves = [
    (cycles: (3, 5), phase: (0.0, 0.25)),
    (cycles: (4, 7), phase: (0.4, 0.1)),
    (cycles: (2, 6), phase: (0.7, 0.55)),
  ];
  static const _minFraction = 0.25;

  static double _fraction(int bar, double t) {
    final wave = _waves[bar];
    final primary = math.sin(
      2 * math.pi * (wave.cycles.$1 * t + wave.phase.$1),
    );
    final secondary = math.sin(
      2 * math.pi * (wave.cycles.$2 * t + wave.phase.$2),
    );
    final mix = 0.5 + 0.5 * (0.6 * primary + 0.4 * secondary);
    return _minFraction + (1 - _minFraction) * mix;
  }

  @override
  void paint(Canvas canvas, Size size) {
    // Three bars with two equal gaps, rising from the baseline.
    final barWidth = size.width / 5;
    final paint = Paint()..color = color;
    for (var bar = 0; bar < _waves.length; bar++) {
      final height = size.height * _fraction(bar, progress.value);
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(
            bar * barWidth * 2,
            size.height - height,
            barWidth,
            height,
          ),
          Radius.circular(barWidth / 2),
        ),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_EqualizerPainter oldDelegate) =>
      color != oldDelegate.color || progress != oldDelegate.progress;
}
