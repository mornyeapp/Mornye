import 'package:material_ui/material_ui.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:mornye/theme/app_motion.dart';
import 'package:mornye/theme/material_expressive.dart';
import 'package:mornye/theme/mornye_theme.dart';

/// One inline surface, matching the metadata groups and dialog controls.
class AppContentCard extends StatelessWidget {
  const AppContentCard({
    super.key,
    required this.child,
    this.color,
    this.shape,
    this.elevation,
    this.clipBehavior = Clip.none,
    this.preserveColor = false,
    this.margin,
    this.onTap,
    this.onLongPress,
    this.mornyeSurface = true,
    this.expressiveSurface = true,
  });

  final Widget child;
  final Color? color;
  final ShapeBorder? shape;
  final double? elevation;
  final Clip clipBehavior;
  final bool preserveColor;

  /// Outer margin; Material defaults to its card theme, Mornye to zero.
  final EdgeInsetsGeometry? margin;

  /// Makes the whole card pressable, with the expressive press feedback.
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  /// False keeps a plain [Card] under Mornye for surfaces that carry their
  /// own tinted color (errors, notices) rather than the Mornye control fill.
  final bool mornyeSurface;

  /// False uses a lightweight surface with lazy color fading for high-volume
  /// track rows instead of per-row M3ECard wrappers and tickers.
  final bool expressiveSurface;

  @override
  Widget build(BuildContext context) {
    if (!context.isMornye || !mornyeSurface) {
      if (!context.isMornye &&
          materialExpressiveEnabled(context) &&
          (shape == null || shape is RoundedRectangleBorder)) {
        final radius = shape is RoundedRectangleBorder
            ? (shape as RoundedRectangleBorder).borderRadius.resolve(
                Directionality.of(context),
              )
            : BorderRadius.circular(20);
        final borderSide =
            shape is RoundedRectangleBorder &&
                (shape as RoundedRectangleBorder).side.style != BorderStyle.none
            ? (shape as RoundedRectangleBorder).side
            : null;
        if (!expressiveSurface && (elevation ?? 0) == 0) {
          return Padding(
            padding:
                margin ??
                CardTheme.of(context).margin ??
                const EdgeInsets.all(4),
            child: _LazyFilledCardSurface(
              color:
                  color ??
                  Theme.of(context).colorScheme.surfaceContainerHighest,
              borderRadius: radius,
              borderSide: borderSide,
              clipBehavior: onTap == null && onLongPress == null
                  ? clipBehavior
                  : Clip.antiAlias,
              onTap: onTap,
              onLongPress: onLongPress,
              child: child,
            ),
          );
        }
        return Padding(
          padding:
              margin ?? CardTheme.of(context).margin ?? const EdgeInsets.all(4),
          child: MaterialExpressiveScope(
            child: M3ECard(
              variant: M3ECardVariant.filled,
              padding: EdgeInsets.zero,
              color: color,
              elevation: elevation ?? 0,
              // BorderSide.none would still paint as a hairline.
              border: borderSide,
              borderRadius: radius,
              clipBehavior: onTap == null && onLongPress == null
                  ? clipBehavior
                  : Clip.antiAlias,
              onPressed: onTap,
              onLongPress: onLongPress,
              child: Material(color: Colors.transparent, child: child),
            ),
          ),
        );
      }
      final interactive = onTap != null || onLongPress != null;
      return Card(
        color: color,
        shape: shape,
        elevation: elevation,
        margin: margin,
        clipBehavior: interactive ? Clip.antiAlias : clipBehavior,
        child: interactive
            ? InkWell(onTap: onTap, onLongPress: onLongPress, child: child)
            : child,
      );
    }
    final content = DividerTheme(
      data: DividerTheme.of(
        context,
      ).copyWith(color: MornyeTheme.metadataDividerColor(context)),
      child: child,
    );
    final surface = Material(
      color: preserveColor ? color : MornyeTheme.controlFill(context),
      borderRadius: BorderRadius.circular(28),
      clipBehavior: Clip.antiAlias,
      child: onTap != null || onLongPress != null
          ? InkWell(onTap: onTap, onLongPress: onLongPress, child: content)
          : content,
    );
    return margin == null ? surface : Padding(padding: margin!, child: surface);
  }
}

/// Lightweight filled surface for list rows: allocates no controller or ticker
/// while resting, and smoothly fades its fill color only when [color] changes.
class _LazyFilledCardSurface extends StatefulWidget {
  const _LazyFilledCardSurface({
    required this.color,
    required this.borderRadius,
    required this.borderSide,
    required this.clipBehavior,
    required this.onTap,
    required this.onLongPress,
    required this.child,
  });

  final Color color;
  final BorderRadius borderRadius;
  final BorderSide? borderSide;
  final Clip clipBehavior;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final Widget child;

  @override
  State<_LazyFilledCardSurface> createState() => _LazyFilledCardSurfaceState();
}

class _LazyFilledCardSurfaceState extends State<_LazyFilledCardSurface>
    with TickerProviderStateMixin {
  AnimationController? _controller;
  Curve _curve = Curves.linear;
  Color? _fromColor;
  late Color _currentColor = widget.color;

  @override
  void didUpdateWidget(_LazyFilledCardSurface oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.color == widget.color) return;
    final motion = AppMotion.effects(
      context,
      const AppMotionSpec(Duration.zero, Curves.linear),
    );
    if (motion.duration == Duration.zero) {
      _disposeController();
      _currentColor = widget.color;
      return;
    }
    _fromColor = _currentColor;
    _curve = motion.curve;
    final controller = _controller ??= AnimationController(vsync: this)
      ..addListener(_onTick)
      ..addStatusListener(_onStatus);
    controller
      ..duration = motion.duration
      ..forward(from: 0);
  }

  void _onTick() {
    final controller = _controller;
    if (controller == null) return;
    final t = _curve.transform(controller.value);
    final next = Color.lerp(_fromColor, widget.color, t) ?? widget.color;
    if (next != _currentColor && mounted) {
      setState(() => _currentColor = next);
    }
  }

  void _onStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed) {
      _currentColor = widget.color;
      _fromColor = null;
      _disposeController();
      if (mounted) setState(() {});
    }
  }

  void _disposeController() {
    final controller = _controller;
    if (controller == null) return;
    _controller = null;
    controller
      ..removeListener(_onTick)
      ..removeStatusListener(_onStatus)
      ..dispose();
  }

  @override
  void dispose() {
    _disposeController();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final interactive = widget.onTap != null || widget.onLongPress != null;
    // The same state layers and semantics as the M3ECard rows had.
    final state = Theme.of(context).colorScheme.onSurface;
    final content = Material(
      type: MaterialType.transparency,
      borderRadius: widget.borderRadius,
      clipBehavior: widget.clipBehavior,
      child: interactive
          ? Semantics(
              container: true,
              button: true,
              child: InkWell(
                onTap: widget.onTap,
                onLongPress: widget.onLongPress,
                borderRadius: widget.borderRadius,
                splashFactory: InkSparkle.splashFactory,
                splashColor: M3EStateLayer.splashColor(state),
                highlightColor: Colors.transparent,
                overlayColor: M3EStateLayer.overlayColorHoverFocus(state),
                child: widget.child,
              ),
            )
          : widget.child,
    );
    return DecoratedBox(
      decoration: BoxDecoration(
        color: _controller == null ? widget.color : _currentColor,
        borderRadius: widget.borderRadius,
        border: widget.borderSide == null
            ? null
            : Border.fromBorderSide(widget.borderSide!),
      ),
      child: content,
    );
  }
}
