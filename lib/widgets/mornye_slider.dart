import 'package:flutter/physics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart'
    show GlassBackdropGroup;
import 'package:material_ui/material_ui.dart';
import 'package:cupertino_ui/cupertino_ui.dart' show CupertinoColors;
import 'package:mornye/providers/runtime_profile_provider.dart';
import 'package:mornye/theme/app_motion.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/widgets/mornye_chrome.dart';
import 'package:mornye/widgets/mornye_liquid_backdrop.dart';

/// The iOS 27 slider: a thin track, an accent active part and a white
/// capsule thumb that turns into a clear lens while a finger holds it.
///
/// A [Slider] with invisible parts underneath keeps its gestures, keys,
/// semantics and value bubble; this widget draws everything else.
class MornyeSlider extends ConsumerStatefulWidget {
  const MornyeSlider({
    super.key,
    required this.value,
    required this.onChanged,
    this.onChangeEnd,
    this.min = 0,
    this.max = 1,
    this.divisions,
    this.label,
    this.semanticFormatterCallback,
    this.centered = false,
    this.vertical = false,
  });

  final double value;
  final ValueChanged<double>? onChanged;
  final ValueChanged<double>? onChangeEnd;
  final double min;
  final double max;
  final int? divisions;
  final String? label;
  final SemanticFormatterCallback? semanticFormatterCallback;

  /// Grows the active track from the middle of the range.
  final bool centered;

  /// Lays the slider out bottom (min) to top (max).
  final bool vertical;

  // The resting thumb and track of the iOS 27 slider, and how much the
  // thumb swells as it lifts into a lens.
  static const thumbLength = 37.0;
  static const thumbThickness = 24.0;
  static const trackThickness = 6.0;
  static const heldGrowth = 0.55;

  /// The lens bends the track under it less than a bar's selection does.
  static const lensRefractiveIndex = 1.07;

  /// The touch band across the track, as tall as the standard slider's.
  static const touchExtent = 48.0;

  // MornyeGlass draws no lens at or below this clarity.
  static const _lensClarity = 0.2;

  @override
  ConsumerState<MornyeSlider> createState() => _MornyeSliderState();
}

class _MornyeSliderState extends ConsumerState<MornyeSlider>
    with TickerProviderStateMixin {
  /// How far the thumb has lifted into a lens; it may overshoot 1.
  late final AnimationController _hold = AnimationController.unbounded(
    vsync: this,
  );

  /// The thumb's place from 0 (min) to 1 (max). A step of a slider with
  /// divisions glides there; anything else moves it at once.
  late final AnimationController _position = AnimationController.unbounded(
    vsync: this,
    value: _fraction,
  );
  late double _target = _position.value;
  late final Listenable _motion = Listenable.merge([_hold, _position]);
  final _focus = FocusNode(debugLabel: 'MornyeSlider');
  bool _held = false;
  bool _lensAllowed = false;

  double get _fraction {
    final span = widget.max - widget.min;
    if (span <= 0) return 0;
    return ((widget.value - widget.min) / span).clamp(0.0, 1.0);
  }

  bool get _discrete => (widget.divisions ?? 0) > 0;

  @override
  void initState() {
    super.initState();
    _focus.addListener(_focusChanged);
    FocusManager.instance.addHighlightModeListener(_highlightChanged);
  }

  @override
  void didUpdateWidget(MornyeSlider oldWidget) {
    super.didUpdateWidget(oldWidget);
    final target = _fraction;
    if (target == _target) return;
    _target = target;
    if (_discrete && !MediaQuery.disableAnimationsOf(context)) {
      _position.animateWith(
        SpringSimulation(
          MornyeMotion.effectsFastSpring,
          _position.value,
          target,
          _position.velocity,
          snapToEnd: true,
        ),
      );
    } else {
      _position.value = target;
    }
  }

  @override
  void dispose() {
    FocusManager.instance.removeHighlightModeListener(_highlightChanged);
    _focus.dispose();
    _hold.dispose();
    _position.dispose();
    super.dispose();
  }

  void _focusChanged() => setState(() {});

  void _highlightChanged(FocusHighlightMode _) {
    if (_focus.hasFocus) setState(() {});
  }

  bool get _showFocus =>
      _focus.hasFocus &&
      FocusManager.instance.highlightMode == FocusHighlightMode.traditional;

  void _setHeld(bool held) {
    if (held && !_lensAllowed) return;
    if (held == _held) return;
    _held = held;
    _hold.animateWith(
      SpringSimulation(
        MornyeMotion.glassPressSpring,
        _hold.value,
        held ? 1 : 0,
        _hold.velocity,
        snapToEnd: true,
      ),
    );
  }

  void _end(double value) {
    _setHeld(false);
    widget.onChangeEnd?.call(value);
  }

  /// The same conditions under which [MornyeGlass] draws a lens.
  bool _allowsLens(BuildContext context) =>
      ref.watch(mornyeGlassLevelProvider) == MornyeGlassLevel.liquid &&
      ref.watch(mornyeBlurEnabledProvider) &&
      MornyeGlass.shaderFiltersSupported &&
      MornyeTheme.glassClarityOf(context) > MornyeSlider._lensClarity &&
      !MediaQuery.disableAnimationsOf(context) &&
      !ref.watch(
        mornyeGlassContrastBlockedProvider(MediaQuery.highContrastOf(context)),
      );

  @override
  Widget build(BuildContext context) {
    _lensAllowed = _allowsLens(context);
    final enabled = widget.onChanged != null;
    final scheme = Theme.of(context).colorScheme;
    final dark = scheme.brightness == Brightness.dark;
    final colors = _SliderColors(
      active: enabled
          ? scheme.primary
          : CupertinoColors.inactiveGray.resolveFrom(context),
      inactive: dark
          ? Colors.white.withValues(alpha: 0.10)
          : Colors.black.withValues(alpha: 0.10),
      activeStop: scheme.onPrimary.withValues(alpha: 0.6),
      inactiveStop: scheme.onSurface.withValues(alpha: 0.28),
    );
    final rtl =
        !widget.vertical && Directionality.of(context) == TextDirection.rtl;
    Widget engine = SliderTheme(
      data: SliderTheme.of(context).copyWith(
        trackHeight: MornyeSlider.trackThickness,
        trackShape: const _TrackGeometry(),
        thumbShape: const _Space(
          Size(MornyeSlider.thumbLength, MornyeSlider.thumbThickness),
        ),
        overlayShape: const _Space(Size.square(MornyeSlider.touchExtent)),
        tickMarkShape: SliderTickMarkShape.noTickMark,
        valueIndicatorShape: _RaisedIndicator(
          SliderTheme.of(context).valueIndicatorShape ??
              const DropSliderValueIndicatorShape(),
        ),
      ),
      child: Slider(
        value: widget.value,
        min: widget.min,
        max: widget.max,
        divisions: widget.divisions,
        label: widget.label,
        semanticFormatterCallback: widget.semanticFormatterCallback,
        focusNode: _focus,
        onChanged: widget.onChanged,
        onChangeStart: enabled ? (_) => _setHeld(true) : null,
        onChangeEnd: enabled ? _end : null,
      ),
    );
    if (widget.vertical) {
      // Min stays at the bottom in every language.
      engine = Directionality(
        textDirection: TextDirection.ltr,
        child: RotatedBox(quarterTurns: 3, child: engine),
      );
    }
    return Stack(
      clipBehavior: Clip.none,
      children: [
        engine,
        Positioned.fill(
          child: IgnorePointer(
            child: LayoutBuilder(
              builder: (context, constraints) => AnimatedBuilder(
                animation: _motion,
                builder: (context, _) => _visual(
                  constraints.biggest,
                  colors: colors,
                  rtl: rtl,
                  enabled: enabled,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _visual(
    Size size, {
    required _SliderColors colors,
    required bool rtl,
    required bool enabled,
  }) {
    final vertical = widget.vertical;
    final extent = vertical ? size.height : size.width;
    final geometry = _Geometry(
      extent: extent,
      discrete: _discrete,
      reversed: vertical || rtl,
    );
    final fraction = _position.value.clamp(0.0, 1.0);
    final along = geometry.center(fraction);
    final across = (vertical ? size.width : size.height) / 2;
    final center = vertical ? Offset(across, along) : Offset(along, across);
    final held = _lensAllowed && enabled ? _hold.value : 0.0;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Positioned.fill(
          child: CustomPaint(
            painter: _TrackPainter(
              geometry: geometry,
              fraction: fraction,
              centered: widget.centered,
              vertical: vertical,
              divisions: _discrete ? widget.divisions : null,
              colors: colors,
            ),
          ),
        ),
        _thumb(center, held),
      ],
    );
  }

  Widget _thumb(Offset center, double held) {
    final lift = held.clamp(0.0, 1.0);
    // It may swell past its size as it lifts, never shrink below it.
    final scale = 1 + MornyeSlider.heldGrowth * (held < 0 ? 0 : held);
    final length = MornyeSlider.thumbLength * scale;
    final thickness = MornyeSlider.thumbThickness * scale;
    final size = widget.vertical
        ? Size(thickness, length)
        : Size(length, thickness);
    final resting = widget.vertical
        ? const Size(MornyeSlider.thumbThickness, MornyeSlider.thumbLength)
        : const Size(MornyeSlider.thumbLength, MornyeSlider.thumbThickness);
    final radius = BorderRadius.circular(thickness / 2);
    // The white fill clears faster than the lens forms, as on iOS 27.
    final fill = (1 - lift * 1.35).clamp(0.0, 1.0);
    final shadow = (1 - lift) * fill;
    final Widget thumb;
    if (lift <= 0) {
      thumb = DecoratedBox(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: radius,
          boxShadow: _thumbShadow(1),
        ),
        position: DecorationPosition.background,
        child: _showFocus
            ? DecoratedBox(
                decoration: ShapeDecoration(
                  shape: StadiumBorder(
                    side: BorderSide(
                      color: Theme.of(
                        context,
                      ).colorScheme.primary.withValues(alpha: 0.6),
                      width: 3,
                      strokeAlign: BorderSide.strokeAlignOutside,
                    ),
                  ),
                ),
              )
            : const SizedBox.expand(),
      );
    } else {
      thumb = Stack(
        clipBehavior: Clip.none,
        alignment: Alignment.center,
        children: [
          if (shadow > 0)
            SizedBox.fromSize(
              size: resting,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(
                    MornyeSlider.thumbThickness / 2,
                  ),
                  boxShadow: _thumbShadow(shadow),
                ),
              ),
            ),
          Positioned.fill(
            child: CustomPaint(
              painter: _LiftShadowPainter(radius: thickness / 2, amount: lift),
            ),
          ),
          Positioned.fill(
            // The lens lies over the track and reads it, never a group's
            // shared backdrop.
            child: GlassBackdropGroup(
              enabled: false,
              child: MornyeLiquidBackdrop(
                borderRadius: radius,
                interaction: true,
                progress: lift,
                refractiveIndex: MornyeSlider.lensRefractiveIndex,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: fill),
                    borderRadius: radius,
                  ),
                ),
              ),
            ),
          ),
        ],
      );
    }
    return Positioned(
      left: center.dx - size.width / 2,
      top: center.dy - size.height / 2,
      width: size.width,
      height: size.height,
      child: thumb,
    );
  }

  static List<BoxShadow> _thumbShadow(double amount) => [
    BoxShadow(
      color: Colors.black.withValues(alpha: 0.15 * amount),
      blurRadius: 8,
      offset: const Offset(0, 2),
    ),
  ];
}

class _SliderColors {
  const _SliderColors({
    required this.active,
    required this.inactive,
    required this.activeStop,
    required this.inactiveStop,
  });

  final Color active, inactive, activeStop, inactiveStop;

  @override
  bool operator ==(Object other) =>
      other is _SliderColors &&
      other.active == active &&
      other.inactive == inactive &&
      other.activeStop == activeStop &&
      other.inactiveStop == inactiveStop;

  @override
  int get hashCode => Object.hash(active, inactive, activeStop, inactiveStop);
}

/// Where the thumb stands along the slider. It mirrors the hidden [Slider]'s
/// own geometry ([_TrackGeometry]), so a finger and the thumb agree.
class _Geometry {
  const _Geometry({
    required this.extent,
    required this.discrete,
    required this.reversed,
  });

  final double extent;
  final bool discrete;

  /// Max at the start: right-to-left, or bottom to top.
  final bool reversed;

  static const _inset = MornyeSlider.thumbLength / 2;
  static const _track = MornyeSlider.trackThickness;

  double center(double fraction) {
    final width = extent - 2 * _inset;
    final visual = reversed ? 1 - fraction : fraction;
    // The framework keeps half a track of room at each end for stops.
    final offset = discrete
        ? _inset + _track / 2 + visual * (width - _track)
        : _inset + visual * width;
    return offset;
  }

  @override
  bool operator ==(Object other) =>
      other is _Geometry &&
      other.extent == extent &&
      other.discrete == discrete &&
      other.reversed == reversed;

  @override
  int get hashCode => Object.hash(extent, discrete, reversed);
}

class _TrackPainter extends CustomPainter {
  const _TrackPainter({
    required this.geometry,
    required this.fraction,
    required this.centered,
    required this.vertical,
    required this.divisions,
    required this.colors,
  });

  final _Geometry geometry;
  final double fraction;
  final bool centered;
  final bool vertical;
  final int? divisions;
  final _SliderColors colors;

  static const _stopRadius = MornyeSlider.trackThickness / 4;

  @override
  void paint(Canvas canvas, Size size) {
    const thickness = MornyeSlider.trackThickness;
    final across = (vertical ? size.width : size.height) / 2;
    Rect span(double a, double b) {
      final low = a < b ? a : b;
      final high = a < b ? b : a;
      return vertical
          ? Rect.fromLTRB(
              across - thickness / 2,
              low,
              across + thickness / 2,
              high,
            )
          : Rect.fromLTRB(
              low,
              across - thickness / 2,
              high,
              across + thickness / 2,
            );
    }

    const radius = Radius.circular(thickness / 2);
    final extent = geometry.extent;
    canvas.drawRRect(
      RRect.fromRectAndRadius(span(0, extent), radius),
      Paint()..color = colors.inactive,
    );
    final thumb = geometry.center(fraction);
    // The active part runs from the minimum's end of the track, or from its
    // middle, to the thumb.
    final from = centered
        ? geometry.center(0.5)
        : geometry.reversed
        ? extent
        : 0.0;
    if (from != thumb) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(span(from, thumb), radius),
        Paint()..color = colors.active,
      );
    }
    final divisions = this.divisions;
    if (divisions == null) return;
    final first = geometry.center(0);
    final last = geometry.center(1);
    // Stops closer than three dots apart would read as a dotted line.
    if ((last - first).abs() / divisions < 6 * _stopRadius) return;
    final low = from < thumb ? from : thumb;
    final high = from < thumb ? thumb : from;
    final paint = Paint();
    for (var i = 0; i <= divisions; i++) {
      final at = geometry.center(i / divisions);
      paint.color = at >= low && at <= high
          ? colors.activeStop
          : colors.inactiveStop;
      canvas.drawCircle(
        vertical ? Offset(across, at) : Offset(at, across),
        _stopRadius,
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_TrackPainter oldDelegate) =>
      oldDelegate.geometry != geometry ||
      oldDelegate.fraction != fraction ||
      oldDelegate.centered != centered ||
      oldDelegate.vertical != vertical ||
      oldDelegate.divisions != divisions ||
      oldDelegate.colors != colors;
}

/// The lifted lens's soft shadow, drawn only outside its outline.
class _LiftShadowPainter extends CustomPainter {
  const _LiftShadowPainter({required this.radius, required this.amount});

  final double radius;
  final double amount;

  @override
  void paint(Canvas canvas, Size size) {
    final shape = RRect.fromRectAndRadius(
      Offset.zero & size,
      Radius.circular(radius),
    );
    canvas.save();
    canvas.clipPath(
      Path()
        ..fillType = PathFillType.evenOdd
        ..addRect(shape.outerRect.inflate(24))
        ..addRRect(shape),
    );
    canvas.drawRRect(
      shape.shift(const Offset(0, 7)),
      Paint()
        ..color = Colors.black.withValues(alpha: 0.06 * amount)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4.5),
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_LiftShadowPainter oldDelegate) =>
      oldDelegate.radius != radius || oldDelegate.amount != amount;
}

/// The hidden slider's track: only its geometry, inset by half a thumb so
/// the thumb stays inside the slider at both ends.
class _TrackGeometry extends SliderTrackShape {
  const _TrackGeometry();

  @override
  bool get isRounded => true;

  @override
  Rect getPreferredRect({
    required RenderBox parentBox,
    Offset offset = Offset.zero,
    required SliderThemeData sliderTheme,
    bool isEnabled = false,
    bool isDiscrete = false,
  }) {
    const inset = MornyeSlider.thumbLength / 2;
    const thickness = MornyeSlider.trackThickness;
    final size = parentBox.size;
    return Rect.fromLTWH(
      offset.dx + inset,
      offset.dy + (size.height - thickness) / 2,
      (size.width - 2 * inset).clamp(0.0, double.infinity),
      thickness,
    );
  }

  @override
  void paint(
    PaintingContext context,
    Offset offset, {
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required Animation<double> enableAnimation,
    required Offset thumbCenter,
    Offset? secondaryOffset,
    bool isEnabled = false,
    bool isDiscrete = false,
    required TextDirection textDirection,
  }) {}
}

/// The value bubble, raised to clear the lens a held thumb swells into.
class _RaisedIndicator extends SliderComponentShape {
  const _RaisedIndicator(this.shape);

  final SliderComponentShape shape;

  // How far the held lens reaches above the standard round thumb.
  static const _lift =
      MornyeSlider.thumbThickness * (1 + MornyeSlider.heldGrowth) / 2 - 10;

  @override
  Size getPreferredSize(bool isEnabled, bool isDiscrete) =>
      shape.getPreferredSize(isEnabled, isDiscrete);

  @override
  void paint(
    PaintingContext context,
    Offset center, {
    required Animation<double> activationAnimation,
    required Animation<double> enableAnimation,
    required bool isDiscrete,
    required TextPainter labelPainter,
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required TextDirection textDirection,
    required double value,
    required double textScaleFactor,
    required Size sizeWithOverflow,
  }) => shape.paint(
    context,
    center.translate(0, -_lift),
    activationAnimation: activationAnimation,
    enableAnimation: enableAnimation,
    isDiscrete: isDiscrete,
    labelPainter: labelPainter,
    parentBox: parentBox,
    sliderTheme: sliderTheme,
    textDirection: textDirection,
    value: value,
    textScaleFactor: textScaleFactor,
    sizeWithOverflow: sizeWithOverflow,
  );
}

/// A part of the hidden slider that only takes room.
class _Space extends SliderComponentShape {
  const _Space(this.size);

  final Size size;

  @override
  Size getPreferredSize(bool isEnabled, bool isDiscrete) => size;

  @override
  void paint(
    PaintingContext context,
    Offset center, {
    required Animation<double> activationAnimation,
    required Animation<double> enableAnimation,
    required bool isDiscrete,
    required TextPainter labelPainter,
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required TextDirection textDirection,
    required double value,
    required double textScaleFactor,
    required Size sizeWithOverflow,
  }) {}
}
