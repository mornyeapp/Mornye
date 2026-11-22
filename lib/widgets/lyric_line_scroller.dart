import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/rendering.dart' show OverflowBoxFit;
import 'package:flutter/widgets.dart';
import 'package:mornye/utils/lyrics_parser.dart';

/// Slides a lyric line too wide for its space so the part being sung stays
/// in view, in place of an ellipsis: the line holds at its start until the
/// singing is [_lead] of the way across, follows it from there, and stops
/// once its end is in view. A line that fits stays still, and nothing moves
/// while playback is paused or the line is offstage. With reduced motion
/// the line moves in half-width steps instead of sliding.
class LyricLineScroller extends StatefulWidget {
  const LyricLineScroller({
    super.key,
    required this.text,
    required this.style,
    required this.start,
    required this.end,
    this.nextStart,
    required this.position,
    required this.advancing,
    required this.child,
    this.words = const [],
    this.speed = 1,
  });

  /// What [child] shows on one line; laid out with [style] to measure it.
  final String text;
  final TextStyle style;

  /// When the line is sung. A line with no [end] lasts until [nextStart],
  /// but no longer than 150 ms a character (an instrumental break may
  /// follow it), or keeps a steady pace when it is the last.
  final Duration start;
  final Duration? end;
  final Duration? nextStart;

  /// The timed words that make up [text], when [child] sweeps them; the
  /// slide then follows the words instead of a steady pace.
  final List<LyricWord> words;

  /// The playback position at this build, and whether it advances at
  /// [speed] from there.
  final Duration position;
  final bool advancing;
  final double speed;

  /// The line on one line. Its ellipsis, if any, never shows while it
  /// slides, since it is laid out at its full width.
  final Widget child;

  @override
  State<LyricLineScroller> createState() => _LyricLineScrollerState();
}

class _LyricLineScrollerState extends State<LyricLineScroller>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  /// How far across its space the singing reaches before the line slides.
  static const _lead = 0.6;

  /// The width of the soft edges where the line runs out of its space.
  static const _fade = 16.0;

  /// The slide follows the mean of the singing over this much song time
  /// either side, so it eases between words of different lengths and in
  /// and out of its stops instead of changing pace at once.
  static const _ease = 250.0;

  /// A reported position this far from the slide's own is a seek, which
  /// the slide follows at once. A smaller difference is how playback
  /// reports time: the slide keeps its place and changes pace instead, so
  /// it never steps back.
  static const _seekThreshold = 750.0;

  /// The pace of a line with no known end, and the slowest pace a line
  /// keeps when the next one starts long after it (an instrumental break).
  static const _paceWithoutEnd = Duration(milliseconds: 70);
  static const _slowestPace = Duration(milliseconds: 150);

  /// The playback position in milliseconds, advanced between builds.
  late final AnimationController _clock = AnimationController.unbounded(
    vsync: this,
  );
  Timer? _wait;
  _LineLayout? _layout;
  bool _tickerEnabled = true;

  /// When the line starts and stops sliding, in milliseconds, or null while
  /// it fits.
  ({double from, double until})? _window;

  bool get _visible =>
      _tickerEnabled &&
      switch (WidgetsBinding.instance.lifecycleState) {
        null || AppLifecycleState.resumed || AppLifecycleState.inactive => true,
        _ => false,
      };

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _clock.value = _ms(widget.position);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final enabled = TickerMode.valuesOf(context).enabled;
    if (enabled != _tickerEnabled) {
      _tickerEnabled = enabled;
      _sync();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _sync();
  }

  @override
  void didUpdateWidget(LyricLineScroller oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text ||
        oldWidget.style != widget.style ||
        oldWidget.start != widget.start ||
        oldWidget.end != widget.end ||
        oldWidget.nextStart != widget.nextStart ||
        !identical(oldWidget.words, widget.words)) {
      _layout = null;
    }
    _sync();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _wait?.cancel();
    _clock.dispose();
    super.dispose();
  }

  static double _ms(Duration duration) => duration.inMicroseconds / 1000;

  /// [milliseconds] of the song as time passes at the playback speed.
  Duration _real(double milliseconds) =>
      Duration(microseconds: (milliseconds * 1000 / widget.speed).ceil());

  /// Moves the clock to the reported position and, while playback
  /// advances, runs it only for the stretch where the line slides.
  void _sync() {
    final now = _ms(widget.position);
    final window = _window;
    final advancing =
        _visible &&
        window != null &&
        widget.advancing &&
        widget.speed.isFinite &&
        widget.speed > 0;
    if (advancing && (now - _clock.value).abs() < _seekThreshold) {
      if (_clock.isAnimating) {
        // Retime the rest of the slide so it ends when playback does.
        _clock.animateTo(
          window.until,
          duration: _real(math.max(window.until - now, 1000 / 60)),
          curve: Curves.linear,
        );
        return;
      }
      // A finished slide stays at its end.
      if (_clock.value >= window.until) return;
    }
    _wait?.cancel();
    _clock.value = now;
    if (!advancing || now >= window.until) return;
    void slide(double from) => _clock.animateTo(
      window.until,
      duration: _real(window.until - from),
      curve: Curves.linear,
    );
    if (now >= window.from) {
      slide(now);
      return;
    }
    _wait = Timer(_real(window.from - now), () {
      if (!mounted) return;
      _clock.value = window.from;
      slide(window.from);
    });
  }

  _LineLayout _layoutFor(TextDirection direction, TextScaler scaler) {
    final cached = _layout;
    if (cached != null &&
        cached.direction == direction &&
        cached.scaler == scaler) {
      return cached;
    }
    final painter = TextPainter(
      text: TextSpan(text: widget.text, style: widget.style),
      textDirection: direction,
      textScaler: scaler,
      maxLines: 1,
    )..layout();
    final width = painter.width;
    double fromStart(int offset) {
      final x = painter
          .getOffsetForCaret(
            TextPosition(offset: math.min(offset, widget.text.length)),
            Rect.zero,
          )
          .dx;
      return direction == TextDirection.rtl ? width - x : x;
    }

    final start = _ms(widget.start);
    final length = widget.text.length;
    final own = widget.end;
    final next = widget.nextStart;
    var end = own != null
        ? _ms(own)
        : next != null
        ? math.min(_ms(next), _ms(widget.start + _slowestPace * length))
        : _ms(widget.start + _paceWithoutEnd * length);
    final words = widget.words;
    final knots = <(double, double)>[];
    if (words.isNotEmpty &&
        words.map((word) => word.text).join() == widget.text) {
      // From each word's start to the next, so a pause between words
      // slows the slide instead of stopping it.
      var offset = 0;
      for (final word in words) {
        knots.add((_ms(word.time), fromStart(offset)));
        offset += word.text.length;
      }
      final lastEnd = words.last.end;
      knots.add((lastEnd == null ? end : _ms(lastEnd), width));
    } else {
      if (end <= start) end = start + 1;
      knots
        ..add((start, 0))
        ..add((end, width));
    }
    painter.dispose();
    // Time and position only move forward along the line.
    for (var index = 1; index < knots.length; index++) {
      final (time, x) = knots[index];
      final (previousTime, previousX) = knots[index - 1];
      knots[index] = (math.max(time, previousTime), math.max(x, previousX));
    }
    return _layout = _LineLayout(
      direction: direction,
      scaler: scaler,
      width: width,
      knots: knots,
    );
  }

  @override
  Widget build(BuildContext context) {
    final direction = Directionality.of(context);
    final scaler = MediaQuery.textScalerOf(context);
    final stepped = MediaQuery.disableAnimationsOf(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final layout = _layoutFor(direction, scaler);
        final viewport = constraints.maxWidth;
        final extent = constraints.hasBoundedWidth
            ? layout.width - viewport
            : 0.0;
        final window = extent > 0.5
            ? (
                from: layout.timeAt(viewport * _lead) - _ease,
                until: layout.timeAt(extent + viewport * _lead) + _ease,
              )
            : null;
        if (window != _window) {
          _window = window;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _sync();
          });
        }
        if (window == null) return widget.child;
        return AnimatedBuilder(
          animation: _clock,
          child: RepaintBoundary(child: widget.child),
          builder: (context, child) {
            var offset =
                (layout.smoothXAt(_clock.value, _ease) - viewport * _lead)
                    .clamp(0.0, extent);
            if (stepped) {
              final step = viewport / 2;
              offset = math.min(extent, (offset / step).round() * step);
            }
            final startFade = offset > 0.5;
            final endFade = offset < extent - 0.5;
            return ClipRect(
              child: ShaderMask(
                blendMode: BlendMode.dstIn,
                shaderCallback: (bounds) {
                  final edge = (_fade / bounds.width).clamp(0.0, 0.5);
                  return LinearGradient(
                    begin: AlignmentDirectional.centerStart,
                    end: AlignmentDirectional.centerEnd,
                    colors: [
                      startFade
                          ? const Color(0x00FFFFFF)
                          : const Color(0xFFFFFFFF),
                      const Color(0xFFFFFFFF),
                      const Color(0xFFFFFFFF),
                      endFade
                          ? const Color(0x00FFFFFF)
                          : const Color(0xFFFFFFFF),
                    ],
                    stops: [0, edge, 1 - edge, 1],
                  ).createShader(bounds, textDirection: direction);
                },
                child: OverflowBox(
                  alignment: AlignmentDirectional.centerStart,
                  maxWidth: double.infinity,
                  fit: OverflowBoxFit.deferToChild,
                  child: Transform.translate(
                    offset: Offset(
                      direction == TextDirection.rtl ? offset : -offset,
                      0,
                    ),
                    child: child,
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }
}

/// A line's width and where its singing is along it over time: pairs of
/// milliseconds and distance from the start of the line, both increasing.
class _LineLayout {
  _LineLayout({
    required this.direction,
    required this.scaler,
    required this.width,
    required this.knots,
  }) : _prefixAreas = _computePrefixAreas(knots);

  final TextDirection direction;
  final TextScaler scaler;
  final double width;
  final List<(double, double)> knots;
  final List<double> _prefixAreas;

  static List<double> _computePrefixAreas(List<(double, double)> knots) {
    final areas = List<double>.filled(knots.length, 0.0);
    for (var i = 1; i < knots.length; i++) {
      final (t1, x1) = knots[i];
      final (t0, x0) = knots[i - 1];
      areas[i] = areas[i - 1] + (t1 - t0) * (x0 + x1) / 2;
    }
    return areas;
  }

  /// First knot index whose time is strictly greater than [ms], or
  /// `knots.length` when [ms] is at or after the last knot.
  int _upperBoundTime(double ms) {
    var low = 1;
    var high = knots.length;
    while (low < high) {
      final mid = (low + high) >> 1;
      if (knots[mid].$1 <= ms) {
        low = mid + 1;
      } else {
        high = mid;
      }
    }
    return low;
  }

  /// How far the singing has come at [ms].
  double xAt(double ms) {
    if (ms <= knots.first.$1) return knots.first.$2;
    final index = _upperBoundTime(ms);
    if (index >= knots.length) return knots.last.$2;
    final (time, x) = knots[index];
    final (previousTime, previousX) = knots[index - 1];
    return previousX +
        (x - previousX) * (ms - previousTime) / (time - previousTime);
  }

  /// The mean of [xAt] over [ms] ± [half].
  double smoothXAt(double ms, double half) =>
      (_area(ms + half) - _area(ms - half)) / (2 * half);

  /// The integral of [xAt] from the first knot to [ms].
  double _area(double ms) {
    final (firstTime, firstX) = knots.first;
    if (ms <= firstTime) return (ms - firstTime) * firstX;
    final index = _upperBoundTime(ms);
    if (index >= knots.length) {
      final (lastTime, lastX) = knots.last;
      return _prefixAreas.last + (ms - lastTime) * lastX;
    }
    final (time, x) = knots[index];
    final (previousTime, previousX) = knots[index - 1];
    final at =
        previousX +
        (x - previousX) * (ms - previousTime) / (time - previousTime);
    return _prefixAreas[index - 1] + (ms - previousTime) * (previousX + at) / 2;
  }

  /// When the singing reaches [x].
  double timeAt(double x) {
    if (x <= knots.first.$2) return knots.first.$1;
    var low = 1;
    var high = knots.length;
    while (low < high) {
      final mid = (low + high) >> 1;
      if (knots[mid].$2 < x) {
        low = mid + 1;
      } else {
        high = mid;
      }
    }
    if (low >= knots.length) return knots.last.$1;
    final (time, position) = knots[low];
    final (previousTime, previousX) = knots[low - 1];
    if (position <= previousX) return time;
    return previousTime +
        (time - previousTime) * (x - previousX) / (position - previousX);
  }
}
