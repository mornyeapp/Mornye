import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/widgets/mornye_chrome.dart';

/// Bounds of the tapped control or row, in the root overlay's coordinates.
Rect? mornyeMenuAnchor(BuildContext context) {
  final box = context.findRenderObject();
  if (box is! RenderBox || !box.hasSize) return null;
  if (box.size.height > MediaQuery.sizeOf(context).height * 0.65) return null;
  return box.localToGlobal(Offset.zero) & box.size;
}

Future<T?> showMornyeContextMenu<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  Rect? anchor,
  bool preferAbove = false,
  double maxWidth = 320,
}) {
  final navigator = Navigator.of(context, rootNavigator: true);
  final themes = InheritedTheme.capture(from: context, to: navigator.context);
  final target = anchor ?? mornyeMenuAnchor(context);
  return navigator.push<T>(
    _MenuRoute<T>(
      barrierColor: Colors.black.withValues(alpha: 0.12),
      barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
      transitionDuration: MediaQuery.disableAnimationsOf(context)
          ? Duration.zero
          : _openDuration,
      closeDuration: MediaQuery.disableAnimationsOf(context)
          ? Duration.zero
          : const Duration(milliseconds: 240),
      // Opacity layers isolate a BackdropFilter from the underlying artwork.
      transitionBuilder: (_, _, _, child) => child,
      pageBuilder: (context, animation, _) {
        final media = MediaQuery.of(context);
        return Semantics(
          scopesRoute: true,
          namesRoute: true,
          label: MaterialLocalizations.of(context).popupMenuLabel,
          explicitChildNodes: true,
          child: CustomSingleChildLayout(
            delegate: _MenuLayout(
              anchor: target,
              preferAbove: preferAbove,
              maxWidth: maxWidth,
              padding: media.padding.copyWith(
                bottom: math.max(media.padding.bottom, media.viewInsets.bottom),
              ),
            ),
            child: _MenuFlight(
              animation: animation,
              anchor: target?.center,
              child: themes.wrap(Builder(builder: builder)),
            ),
          ),
        );
      },
    ),
  );
}

/// Long enough for the spring in [_MenuFlight] to settle.
const _openDuration = Duration(milliseconds: 640);

/// A dialog route that closes faster than it opens.
class _MenuRoute<T> extends RawDialogRoute<T> {
  _MenuRoute({
    required super.pageBuilder,
    required super.barrierColor,
    required super.barrierLabel,
    required super.transitionBuilder,
    required super.transitionDuration,
    required Duration closeDuration,
  }) : _closeDuration = closeDuration;

  final Duration _closeDuration;

  @override
  Duration get reverseTransitionDuration => _closeDuration;
}

/// How far along the opening rows start taking presses.
const double _pressableFrom = 0.38;

/// The route's progress, which the menu's glass follows.
class _MenuFlight extends InheritedWidget {
  const _MenuFlight({
    required this.animation,
    required this.anchor,
    required super.child,
  });

  final Animation<double> animation;

  /// Center of the control the menu pours out of, in global coordinates.
  final Offset? anchor;

  static _MenuFlight? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_MenuFlight>();

  @override
  bool updateShouldNotify(_MenuFlight oldWidget) =>
      animation != oldWidget.animation || anchor != oldWidget.anchor;
}

/// One axis of the opening: an underdamped spring, [delay] seconds late.
double _pour(double seconds, double delay) {
  const damping = 0.62;
  const frequency = 15.0;
  final damped = frequency * math.sqrt(1 - damping * damping);
  double position(double time) {
    final decay = math.exp(-damping * frequency * time);
    return 1 -
        decay *
            (math.cos(damped * time) +
                damping * frequency / damped * math.sin(damped * time));
  }

  final time = math.max(seconds - delay, 0.0);
  final length = _openDuration.inMicroseconds / 1e6 - delay;
  // The spring is still a pixel or two short when the route ends: spread that
  // remainder over the flight so the menu lands on its exact size.
  final spring = position(time) + (1 - position(length)) * (time / length);
  // The size runs just past its target, not by the spring's whole overshoot.
  return spring <= 1 ? spring : 1 + (spring - 1) * 0.35;
}

/// Sizes shared by the two render objects of a morphing menu.
class _MenuGeometry {
  /// What the menu's content asks for, and so the glass at rest.
  BoxConstraints constraints = const BoxConstraints();
  Size resting = Size.zero;

  /// Top left of the glass inside the resting box, changing with the morph.
  Offset position = Offset.zero;
}

/// Pours the glass out of its control like water: a drop at the control runs
/// down into a tall oval, then spreads to the menu's width and settles with a
/// small wobble. The panel really changes size, so its lens, rim and corners
/// stay true on every frame, while the rows wait in place and fade up inside.
class _LiquidMenuGlass extends StatefulWidget {
  const _LiquidMenuGlass({
    required this.flight,
    required this.glass,
    required this.child,
  });

  final _MenuFlight flight;
  final Widget Function(double radius, Widget child) glass;
  final Widget child;

  @override
  State<_LiquidMenuGlass> createState() => _LiquidMenuGlassState();
}

class _LiquidMenuGlassState extends State<_LiquidMenuGlass> {
  static const double _dropSize = 44;
  static const double _restingRadius = 28;

  final _geometry = _MenuGeometry();
  double? _closingFrom;
  double _closingWidth = 1;
  double _closingHeight = 1;

  double get _seconds =>
      widget.flight.animation.value * _openDuration.inMilliseconds / 1000;

  @override
  void initState() {
    super.initState();
    widget.flight.animation.addStatusListener(_onStatus);
  }

  @override
  void didUpdateWidget(_LiquidMenuGlass oldWidget) {
    super.didUpdateWidget(oldWidget);
    final animation = widget.flight.animation;
    if (animation == oldWidget.flight.animation) return;
    oldWidget.flight.animation.removeStatusListener(_onStatus);
    animation.addStatusListener(_onStatus);
  }

  @override
  void dispose() {
    widget.flight.animation.removeStatusListener(_onStatus);
    super.dispose();
  }

  void _onStatus(AnimationStatus status) {
    if (status != AnimationStatus.reverse) return;
    // Closes from wherever the opening had reached.
    _closingFrom = widget.flight.animation.value;
    _closingHeight = _pour(_seconds, 0);
    _closingWidth = _pour(_seconds, 0.05);
  }

  @override
  Widget build(BuildContext context) {
    final animation = widget.flight.animation;
    return AnimatedBuilder(
      animation: animation,
      child: widget.child,
      builder: (context, content) {
        final from = _closingFrom;
        final double width;
        final double height;
        final double fade;
        if (from != null && from > 0) {
          final closing = 1 - (animation.value / from).clamp(0.0, 1.0);
          // Drawn back into the control, width first.
          width =
              _closingWidth *
              (1 -
                  Curves.easeInCubic.transform(
                    (closing * 1.2).clamp(0.0, 1.0),
                  ));
          height = _closingHeight * (1 - Curves.easeInCubic.transform(closing));
          fade = 1 - const Interval(0, 0.45).transform(closing);
        } else {
          width = _pour(_seconds, 0.05);
          height = _pour(_seconds, 0);
          fade = const Interval(
            0.14,
            0.46,
            curve: Curves.easeOut,
          ).transform(animation.value);
        }
        final resting = _geometry.resting;
        final shortest = math.min(
          lerpDouble(_dropSize, resting.width, width)!,
          lerpDouble(_dropSize, resting.height, height)!,
        );
        // A drop is round; the corners tighten as it spreads.
        final radius = math.min(
          shortest / 2,
          lerpDouble(
            shortest / 2,
            _restingRadius,
            Curves.easeInCubic.transform(width.clamp(0.0, 1.0)),
          )!,
        );
        return IgnorePointer(
          ignoring:
              animation.value < _pressableFrom ||
              animation.status == AnimationStatus.reverse,
          child: _MenuFrame(
            geometry: _geometry,
            anchor: widget.flight.anchor,
            width: width,
            height: height,
            dropSize: _dropSize,
            child: widget.glass(
              radius,
              _MenuContent(
                geometry: _geometry,
                width: width,
                height: height,
                dropSize: _dropSize,
                child: Opacity(opacity: fade, child: content),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Takes the menu's resting space and places the glass inside it.
class _MenuFrame extends SingleChildRenderObjectWidget {
  const _MenuFrame({
    required this.geometry,
    required this.anchor,
    required this.width,
    required this.height,
    required this.dropSize,
    required super.child,
  });

  final _MenuGeometry geometry;
  final Offset? anchor;
  final double width;
  final double height;
  final double dropSize;

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderMenuFrame(
    geometry,
    anchor: anchor,
    widthProgress: width,
    heightProgress: height,
    dropSize: dropSize,
  );

  @override
  void updateRenderObject(BuildContext context, _RenderMenuFrame renderObject) {
    renderObject
      ..anchor = anchor
      ..widthProgress = width
      ..heightProgress = height
      ..dropSize = dropSize
      ..markNeedsPaint();
  }
}

class _RenderMenuFrame extends RenderProxyBox {
  _RenderMenuFrame(
    this.geometry, {
    required this.anchor,
    required this.widthProgress,
    required this.heightProgress,
    required this.dropSize,
  });

  final _MenuGeometry geometry;
  Offset? anchor;
  double widthProgress;
  double heightProgress;
  double dropSize;

  @override
  void performLayout() {
    geometry.constraints = constraints;
    final content = child!;
    // Unbounded: the glass takes its size from [_RenderMenuContent].
    content.layout(const BoxConstraints(), parentUsesSize: true);
    size = constraints.constrain(Size.copy(geometry.resting));
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final origin = anchor == null
        ? size.center(Offset.zero)
        : globalToLocal(anchor!);
    final drop = origin - Offset(dropSize, dropSize) / 2;
    geometry.position = Offset(
      drop.dx * (1 - widthProgress),
      drop.dy * (1 - heightProgress),
    );
    context.paintChild(child!, offset + geometry.position);
  }

  @override
  void applyPaintTransform(RenderBox child, Matrix4 transform) {
    transform.translateByDouble(
      geometry.position.dx,
      geometry.position.dy,
      0,
      1,
    );
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      result.addWithPaintOffset(
        offset: geometry.position,
        position: position,
        hitTest: (result, transformed) =>
            child!.hitTest(result, position: transformed),
      );
}

/// Lays the rows out at their resting size inside the morphing glass, and
/// holds them still on screen as the glass moves around them.
class _MenuContent extends SingleChildRenderObjectWidget {
  const _MenuContent({
    required this.geometry,
    required this.width,
    required this.height,
    required this.dropSize,
    required super.child,
  });

  final _MenuGeometry geometry;
  final double width;
  final double height;
  final double dropSize;

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderMenuContent(
    geometry,
    widthProgress: width,
    heightProgress: height,
    dropSize: dropSize,
  );

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderMenuContent renderObject,
  ) {
    renderObject
      ..widthProgress = width
      ..heightProgress = height
      ..dropSize = dropSize
      ..markNeedsLayout();
  }
}

class _RenderMenuContent extends RenderProxyBox {
  _RenderMenuContent(
    this.geometry, {
    required this.widthProgress,
    required this.heightProgress,
    required this.dropSize,
  });

  final _MenuGeometry geometry;
  double widthProgress;
  double heightProgress;
  double dropSize;

  @override
  void performLayout() {
    final content = child!;
    content.layout(geometry.constraints, parentUsesSize: true);
    final resting = content.size;
    geometry.resting = resting;
    size = Size(
      math.max(lerpDouble(dropSize, resting.width, widthProgress)!, 0),
      math.max(lerpDouble(dropSize, resting.height, heightProgress)!, 0),
    );
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    context.paintChild(child!, offset - geometry.position);
  }

  @override
  void applyPaintTransform(RenderBox child, Matrix4 transform) {
    transform.translateByDouble(
      -geometry.position.dx,
      -geometry.position.dy,
      0,
      1,
    );
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      result.addWithPaintOffset(
        offset: -geometry.position,
        position: position,
        hitTest: (result, transformed) =>
            child!.hitTest(result, position: transformed),
      );
}

class _MenuLayout extends SingleChildLayoutDelegate {
  const _MenuLayout({
    required this.anchor,
    required this.padding,
    required this.preferAbove,
    required this.maxWidth,
  });

  final Rect? anchor;
  final EdgeInsets padding;
  final bool preferAbove;
  final double maxWidth;
  static const double _margin = 16;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) {
    final width = math.min(
      maxWidth,
      math.max(0.0, constraints.maxWidth - padding.horizontal - _margin * 2),
    );
    var height = math.max(
      0.0,
      constraints.maxHeight - padding.vertical - _margin * 2,
    );
    final above = (anchor?.top ?? 0) - padding.top - _margin - 8;
    if (preferAbove && above >= 160) height = math.min(height, above);
    return BoxConstraints(minWidth: width, maxWidth: width, maxHeight: height);
  }

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    final left = padding.left + _margin;
    final top = padding.top + _margin;
    final right = math.max(
      left,
      size.width - padding.right - _margin - childSize.width,
    );
    final bottom = math.max(
      top,
      size.height - padding.bottom - _margin - childSize.height,
    );
    final x = anchor == null
        ? (size.width - childSize.width) / 2
        : anchor!.right - childSize.width;
    var y = size.height * 0.18;
    if (anchor != null) {
      final above = anchor!.top - childSize.height - 8;
      final below = anchor!.bottom + 8;
      if (preferAbove) {
        y = above >= top
            ? above
            : below <= bottom
            ? below
            : top;
      } else {
        y = below <= bottom
            ? below
            : above >= top
            ? above
            : bottom;
      }
    }
    return Offset(x.clamp(left, right), y.clamp(top, bottom));
  }

  @override
  bool shouldRelayout(_MenuLayout oldDelegate) =>
      anchor != oldDelegate.anchor ||
      padding != oldDelegate.padding ||
      maxWidth != oldDelegate.maxWidth ||
      preferAbove != oldDelegate.preferAbove;
}

/// The material and rows stay mounted while the route moves the menu.
class _MenuSurface extends StatelessWidget {
  const _MenuSurface({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    Widget glass(double radius, Widget child) => MornyeGlassPanel.overlay(
      radius: radius,
      smoothCorners: true,
      highlightBorder: true,
      highlightIntensity: 0.4,
      tintColor: theme.extension<MornyeTheme>()?.chromeSurface != null
          ? null
          : dark
          ? const Color(0xff414141)
          : Colors.white,
      tintOpacity: dark
          ? 0.80 - 0.20 * (theme.extension<MornyeTheme>()?.glassClarity ?? 0)
          : 0.80,
      child: child,
    );
    final flight = _MenuFlight.maybeOf(context);
    return flight == null
        ? glass(28, child)
        : _LiquidMenuGlass(flight: flight, glass: glass, child: child);
  }
}

class MornyeMenuAction {
  const MornyeMenuAction({
    required this.icon,
    required this.label,
    required this.onPressed,
    this.subtitle,
    this.selected = false,
    this.destructive = false,
    this.disclosure = false,
  });

  /// Null for a text-only row.
  final IconData? icon;
  final String label;
  final String? subtitle;
  final VoidCallback? onPressed;
  final bool selected;
  final bool destructive;

  /// Marks a row that leads to more choices with a trailing chevron.
  final bool disclosure;
}

/// One frosted popover, with compact shortcuts and separated action groups.
class MornyeContextMenu extends StatelessWidget {
  const MornyeContextMenu({
    super.key,
    this.quickActions = const [],
    required this.groups,
    this.inheritSurface = false,
    this.dense = false,
  });

  final List<MornyeMenuAction> quickActions;
  final List<List<MornyeMenuAction>> groups;
  final bool inheritSurface;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final theme = inheritSurface
        ? Theme.of(context)
        : MornyeTheme.fromContext(context);
    final dark = theme.brightness == Brightness.dark;
    final visibleGroups = groups.where((group) => group.isNotEmpty).toList();
    final shortcuts = quickActions.isEmpty
        ? null
        : Padding(
            padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final action in quickActions)
                  Expanded(child: _action(theme, action, compact: true)),
              ],
            ),
          );
    final actions = Padding(
      padding: const EdgeInsets.symmetric(vertical: 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < visibleGroups.length; i++) ...[
            if (i > 0 || quickActions.isNotEmpty)
              Padding(
                padding: EdgeInsets.symmetric(
                  vertical: i == 0
                      ? 0
                      : dense
                      ? 4
                      : 8,
                ),
                child: Divider(
                  height: 0.5,
                  thickness: 0.5,
                  indent: 16,
                  endIndent: 16,
                  color: theme.colorScheme.onSurface.withValues(
                    alpha: dark ? 0.18 : 0.12,
                  ),
                ),
              ),
            for (final action in visibleGroups[i]) _action(theme, action),
          ],
        ],
      ),
    );
    return Theme(
      data: theme,
      child: _MenuSurface(
        child: LayoutBuilder(
          builder: (context, constraints) {
            // Let the entire menu scroll when pinning the shortcuts would
            // leave too little room for a row in landscape or large text.
            if (constraints.maxHeight < 360 ||
                MediaQuery.textScalerOf(context).scale(17) > 28) {
              return SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [?shortcuts, actions],
                ),
              );
            }
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ?shortcuts,
                Flexible(child: SingleChildScrollView(child: actions)),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _action(
    ThemeData theme,
    MornyeMenuAction action, {
    bool compact = false,
  }) {
    final color = action.onPressed == null
        ? theme.colorScheme.onSurfaceVariant
        : action.destructive || action.selected
        ? theme.colorScheme.primary
        : theme.colorScheme.onSurface;
    final icon = action.icon == null
        ? null
        : Icon(action.icon, size: compact ? 24 : 22, color: color);
    final label = Text(
      action.label,
      textAlign: compact ? TextAlign.center : TextAlign.start,
      style: theme.textTheme.bodyLarge?.copyWith(
        color: color,
        fontSize: compact
            ? 14
            : dense
            ? 16
            : 17,
        fontWeight: compact ? FontWeight.w600 : FontWeight.w400,
      ),
    );
    return Semantics(
      selected: action.selected,
      child: CupertinoButton(
        minimumSize: const Size(48, 48),
        padding: compact
            ? EdgeInsets.symmetric(horizontal: 4, vertical: dense ? 6 : 10)
            : EdgeInsets.symmetric(horizontal: 16, vertical: dense ? 8 : 14),
        onPressed: action.onPressed,
        child: compact
            ? Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ?icon,
                  SizedBox(height: dense ? 4 : 7),
                  label,
                ],
              )
            : Row(
                children: [
                  if (icon != null) ...[icon, SizedBox(width: dense ? 12 : 16)],
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        label,
                        if (action.subtitle != null) ...[
                          const SizedBox(height: 3),
                          Text(
                            action.subtitle!,
                            style: theme.textTheme.bodySmall?.copyWith(
                              fontSize: 14,
                              color: theme.colorScheme.onSurface.withValues(
                                alpha: 0.96,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  if (action.disclosure)
                    Icon(
                      CupertinoIcons.chevron_forward,
                      size: 15,
                      color: color,
                    ),
                ],
              ),
      ),
    );
  }
}
