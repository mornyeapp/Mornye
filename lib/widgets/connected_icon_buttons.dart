import 'package:material_ui/material_ui.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:mornye/theme/app_motion.dart';

/// Icon buttons joined into one Material 3 Expressive connected button
/// group: filled segments split by a hairline gap, round outer ends and
/// small inner corners. Each [AppIconButton] among [children] draws as its
/// segment, so buttons with their own menus or rings join unchanged.
class ConnectedIconButtons extends StatelessWidget {
  const ConnectedIconButtons({
    super.key,
    required this.children,
    required this.colorScheme,
    this.segmentWidth = 44,
    this.height = 40,
  });

  final List<Widget> children;

  /// The group's colors, kept for buttons that sit under another theme.
  final ColorScheme colorScheme;
  final double segmentWidth;
  final double height;

  @override
  Widget build(BuildContext context) {
    final gap = M3ETheme.of(context).buttonGroupTheme.connectedGap;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final (index, child) in children.indexed) ...[
          if (index > 0) SizedBox(width: gap),
          ConnectedIconSegment(
            first: index == 0,
            last: index == children.length - 1,
            width: segmentWidth,
            height: height,
            colorScheme: colorScheme,
            child: child,
          ),
        ],
      ],
    );
  }

  /// The width of [count] segments with their gaps.
  static double widthOf(
    BuildContext context,
    int count, {
    double segmentWidth = 44,
  }) => count <= 0
      ? 0
      : count * segmentWidth +
            (count - 1) * M3ETheme.of(context).buttonGroupTheme.connectedGap;
}

/// The place of one button in a [ConnectedIconButtons] row.
class ConnectedIconSegment extends InheritedWidget {
  const ConnectedIconSegment({
    super.key,
    required this.first,
    required this.last,
    required this.width,
    required this.height,
    required ColorScheme this.colorScheme,
    required super.child,
  });

  /// Keeps buttons in [child] plain, such as those of a popover that a
  /// segment's menu opens: an overlay inherits from where it is anchored.
  const ConnectedIconSegment.exclude({super.key, required super.child})
    : first = false,
      last = false,
      width = 0,
      height = 0,
      colorScheme = null;

  final bool first;
  final bool last;
  final double width;
  final double height;
  final ColorScheme? colorScheme;

  static ConnectedIconSegment? maybeOf(BuildContext context) {
    final segment = context
        .dependOnInheritedWidgetOfExactType<ConnectedIconSegment>();
    return segment?.colorScheme == null ? null : segment;
  }

  @override
  bool updateShouldNotify(ConnectedIconSegment oldWidget) =>
      first != oldWidget.first ||
      last != oldWidget.last ||
      width != oldWidget.width ||
      height != oldWidget.height ||
      colorScheme != oldWidget.colorScheme;
}

/// One segment: `surfaceContainerHigh`, or `secondaryContainer` with fully
/// round corners while selected. A press tightens the inner corners.
class ConnectedSegmentButton extends StatefulWidget {
  const ConnectedSegmentButton({
    super.key,
    required this.segment,
    required this.icon,
    required this.onPressed,
    this.selectedIcon,
    this.tooltip,
    this.color,
    this.iconSize,
    this.isSelected,
  });

  final ConnectedIconSegment segment;
  final Widget icon;
  final Widget? selectedIcon;
  final VoidCallback? onPressed;
  final String? tooltip;

  /// Content color while enabled; the segment's role color when null.
  final Color? color;
  final double? iconSize;
  final bool? isSelected;

  @override
  State<ConnectedSegmentButton> createState() => _ConnectedSegmentButtonState();
}

class _ConnectedSegmentButtonState extends State<ConnectedSegmentButton> {
  static const _still = AppMotionSpec(Duration.zero, Curves.linear);
  static const _innerRadius = 8.0;
  static const _pressedInnerRadius = 4.0;

  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final segment = widget.segment;
    final scheme = segment.colorScheme!;
    final selected = widget.isSelected ?? false;
    final enabled = widget.onPressed != null;
    final round = Radius.circular(segment.height / 2);
    final inner = Radius.circular(
      selected
          ? segment.height / 2
          : _pressed
          ? _pressedInnerRadius
          : _innerRadius,
    );
    final radius = BorderRadiusDirectional.horizontal(
      start: segment.first ? round : inner,
      end: segment.last ? round : inner,
    ).resolve(Directionality.of(context));
    final background = !enabled
        ? scheme.onSurface.withValues(alpha: 0.12)
        : selected
        ? scheme.secondaryContainer
        : scheme.surfaceContainerHigh;
    final foreground = !enabled
        ? scheme.onSurface.withValues(alpha: 0.38)
        : widget.color ??
              (selected
                  ? scheme.onSecondaryContainer
                  : scheme.onSurfaceVariant);
    final icon = selected && widget.selectedIcon != null
        ? widget.selectedIcon!
        : widget.icon;
    final motion = AppMotion.spatialFast(context, _still);
    final color = AppMotion.effectsFast(context, _still);
    Widget button = TweenAnimationBuilder<Color?>(
      tween: ColorTween(end: background),
      duration: color.duration,
      curve: color.curve,
      builder: (context, background, child) =>
          TweenAnimationBuilder<BorderRadius?>(
            tween: BorderRadiusTween(end: radius),
            duration: motion.duration,
            curve: motion.curve,
            builder: (context, radius, child) {
              final shape = RoundedRectangleBorder(
                borderRadius: radius ?? BorderRadius.zero,
              );
              // Ink paints under a Material's children, so the fill is the
              // Material's own color.
              return Material(
                color: background,
                shape: shape,
                animationDuration: Duration.zero,
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  customBorder: shape,
                  onTap: widget.onPressed,
                  onHighlightChanged: (pressed) {
                    if (_pressed != pressed) {
                      setState(() => _pressed = pressed);
                    }
                  },
                  child: child,
                ),
              );
            },
            child: child,
          ),
      child: SizedBox(
        width: segment.width,
        height: segment.height,
        child: Center(
          child: IconTheme.merge(
            data: IconThemeData(color: foreground, size: widget.iconSize ?? 24),
            child: icon,
          ),
        ),
      ),
    );
    button = Semantics(
      button: true,
      enabled: enabled,
      selected: widget.isSelected,
      label: widget.tooltip,
      excludeSemantics: true,
      child: button,
    );
    final message = widget.tooltip;
    return message == null
        ? button
        : Tooltip(message: message, excludeFromSemantics: true, child: button);
  }
}
