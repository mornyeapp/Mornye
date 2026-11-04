import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
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
    RawDialogRoute<T>(
      barrierColor: Colors.black.withValues(alpha: 0.12),
      barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
      transitionDuration: MediaQuery.disableAnimationsOf(context)
          ? Duration.zero
          : const Duration(milliseconds: 320),
      // Opacity layers isolate a BackdropFilter from the underlying artwork.
      transitionBuilder: (_, _, _, child) => child,
      pageBuilder: (context, animation, _) {
        final media = MediaQuery.of(context);
        return Semantics(
          scopesRoute: true,
          namesRoute: true,
          label: MaterialLocalizations.of(context).popupMenuLabel,
          explicitChildNodes: true,
          child: AnimatedBuilder(
            animation: animation,
            child: themes.wrap(Builder(builder: builder)),
            builder: (context, child) {
              // Keep the same glass surface throughout the flight, so its
              // material is already visible as the menu grows from its control.
              final motion = const Interval(
                0,
                0.62,
                curve: Curves.easeOutCubic,
              ).transform(animation.value);
              // Liquid glass runs slightly past its size and settles back.
              final overshoot =
                  animation.status == AnimationStatus.reverse ||
                      MediaQuery.disableAnimationsOf(context)
                  ? 0.0
                  : 0.015 *
                        math.sin(
                          math.pi *
                              const Interval(
                                0.4,
                                0.9,
                              ).transform(animation.value),
                        );
              return CustomSingleChildLayout(
                delegate: _MenuLayout(
                  anchor: target,
                  preferAbove: preferAbove,
                  maxWidth: maxWidth,
                  padding: media.padding.copyWith(
                    bottom: math.max(
                      media.padding.bottom,
                      media.viewInsets.bottom,
                    ),
                  ),
                  progress: motion,
                ),
                child: Transform.scale(
                  scale: (0.16 + 0.84 * motion) * (1 + overshoot),
                  child: IgnorePointer(
                    ignoring:
                        motion < 1 ||
                        animation.status == AnimationStatus.reverse,
                    child: child!,
                  ),
                ),
              );
            },
          ),
        );
      },
    ),
  );
}

class _MenuLayout extends SingleChildLayoutDelegate {
  const _MenuLayout({
    required this.anchor,
    required this.padding,
    required this.preferAbove,
    required this.maxWidth,
    required this.progress,
  });

  final Rect? anchor;
  final EdgeInsets padding;
  final bool preferAbove;
  final double maxWidth;
  final double progress;
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
    final resting = Offset(x.clamp(left, right), y.clamp(top, bottom));
    final origin = anchor?.center;
    return origin == null
        ? resting
        : Offset.lerp(
            origin - childSize.center(Offset.zero),
            resting,
            progress,
          )!;
  }

  @override
  bool shouldRelayout(_MenuLayout oldDelegate) =>
      anchor != oldDelegate.anchor ||
      padding != oldDelegate.padding ||
      maxWidth != oldDelegate.maxWidth ||
      progress != oldDelegate.progress ||
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
    return MornyeGlassPanel.overlay(
      radius: 28,
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
  });

  final IconData icon;
  final String label;
  final String? subtitle;
  final VoidCallback? onPressed;
  final bool selected;
  final bool destructive;
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
    final icon = Icon(action.icon, size: compact ? 24 : 22, color: color);
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
                  icon,
                  SizedBox(height: dense ? 4 : 7),
                  label,
                ],
              )
            : Row(
                children: [
                  icon,
                  SizedBox(width: dense ? 12 : 16),
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
                ],
              ),
      ),
    );
  }
}
