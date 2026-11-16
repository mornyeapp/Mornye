import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';
import 'package:mornye/utils/string_utils.dart';
import 'package:mornye/widgets/decorative_phase.dart';

/// Rolls only the changed digits, keeping the timeline labels steady in width.
///
/// The roll advances on the shared [DecorativePhase] clock, at most 30 times
/// a second, like the other continuous playback decorations.
class MornyePlaybackTime extends StatefulWidget {
  const MornyePlaybackTime({
    super.key,
    required this.seconds,
    required this.style,
    this.remaining = false,
  });

  final int seconds;
  final TextStyle? style;
  final bool remaining;

  @override
  State<MornyePlaybackTime> createState() => _MornyePlaybackTimeState();
}

/// One digit in a slot, moving like an [AnimatedSwitcher] entry: a linear
/// value toward 1 (entering) or 0 (leaving), shaped by the curve it started
/// from rest with.
class _RollingDigit {
  _RollingDigit(this.digit, {required this.start})
    : from = 0,
      curve = Curves.easeOutCubic;

  _RollingDigit.resting(this.digit) : start = 0, from = 1, curve = null;

  final String digit;
  double start;
  double from;
  bool entering = true;
  Curve? curve;

  double valueAfter(double rolls) =>
      entering ? math.min(1, from + rolls) : math.max(0, from - rolls);
}

class _MornyePlaybackTimeState extends State<MornyePlaybackTime> {
  static const _roll = Duration(milliseconds: 280);

  // Measures roll time; a loop far longer than a roll never wraps within one.
  final _clock = DecorativePhase(const Duration(minutes: 1));

  /// Digit slots keyed from the seconds end, so they hold when minutes grow.
  final _slots = <int, List<_RollingDigit>>{};
  bool _increasing = true;
  bool _reduceMotion = false;
  bool _motionEnabled = false;

  @override
  void initState() {
    super.initState();
    _clock.addListener(_tick);
    _syncSlots(animate: false);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduceMotion = MediaQuery.disableAnimationsOf(context);
    _motionEnabled = !_reduceMotion && TickerMode.valuesOf(context).enabled;
    if (!_motionEnabled) _settle();
  }

  @override
  void didUpdateWidget(MornyePlaybackTime oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.seconds != oldWidget.seconds) {
      _increasing = widget.seconds > oldWidget.seconds;
      _syncSlots(animate: _motionEnabled);
    }
  }

  @override
  void dispose() {
    _clock.dispose();
    super.dispose();
  }

  String get _label => formatClock(widget.seconds);

  /// Roll time since [start] in multiples of [_roll].
  double _rollsSince(double start) =>
      ((_clock.value - start) % 1) *
      _clock.loop.inMicroseconds /
      _roll.inMicroseconds;

  double _valueOf(_RollingDigit digit) =>
      digit.valueAfter(_rollsSince(digit.start));

  void _syncSlots({required bool animate}) {
    final clock = _label;
    final keys = <int>{};
    for (var index = 0; index < clock.length; index++) {
      final key = clock.length - index;
      final digit = clock[index];
      keys.add(key);
      final slot = _slots[key];
      if (slot == null) {
        _slots[key] = [_RollingDigit.resting(digit)];
        continue;
      }
      final current = slot.last;
      if (current.digit == digit) continue;
      if (!animate) {
        _slots[key] = [_RollingDigit.resting(digit)];
        continue;
      }
      final value = _valueOf(current);
      // A digit that finished entering leaves on the exit curve; one still
      // entering reverses on its entry curve.
      if (value == 1) current.curve = Curves.easeInCubic;
      current
        ..from = value
        ..start = _clock.value
        ..entering = false;
      slot.add(_RollingDigit(digit, start: _clock.value));
      _clock.start();
    }
    _slots.removeWhere((key, _) => !keys.contains(key));
  }

  void _settle() {
    _clock.stop();
    final clock = _label;
    for (final key in _slots.keys) {
      _slots[key] = [_RollingDigit.resting(clock[clock.length - key])];
    }
  }

  void _tick() {
    var rolling = false;
    for (final slot in _slots.values) {
      slot.removeWhere((digit) => !digit.entering && _valueOf(digit) == 0);
      rolling |= slot.any((digit) => !digit.entering || _valueOf(digit) < 1);
    }
    if (!rolling) _clock.stop();
    setState(() {});
  }

  Widget _digit(_RollingDigit digit, String current, TextStyle style) {
    final value = _valueOf(digit);
    final curved = value == 0 || value == 1
        ? value
        : digit.curve!.transform(value);
    final direction = _increasing ? 0.7 : -0.7;
    final begin = digit.digit == current ? direction : -direction;
    return Opacity(
      key: ObjectKey(digit),
      opacity: curved,
      child: FractionalTranslation(
        translation: Offset(0, begin * (1 - curved)),
        child: Text(digit.digit, style: style),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final clock = _label;
    final label = '${widget.remaining ? '-' : ''}$clock';
    final style = (widget.style ?? const TextStyle()).copyWith(
      fontFeatures: [
        ...?widget.style?.fontFeatures,
        const FontFeature.tabularFigures(),
      ],
    );
    if (_reduceMotion) {
      return Text(label, style: style);
    }

    return Semantics(
      label: label,
      excludeSemantics: true,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        textDirection: TextDirection.ltr,
        children: [
          if (widget.remaining) Text('-', style: style),
          for (var index = 0; index < clock.length; index++)
            ClipRect(
              key: ValueKey(clock.length - index),
              child: Stack(
                alignment: Alignment.center,
                children: [
                  for (final digit in _slots[clock.length - index]!)
                    _digit(digit, clock[index], style),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
