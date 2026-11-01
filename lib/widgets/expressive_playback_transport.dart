import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:mornye/theme/material_expressive.dart';
import 'package:mornye/widgets/app_icon.dart';
import 'package:mornye/widgets/app_loading_indicator.dart';
import 'package:mornye/widgets/expressive_button_group.dart';
import 'package:mornye/widgets/expressive_icon_button.dart';

/// Material 3 Expressive previous / play-pause / next row.
///
/// Play-pause rests round while paused and square while playing. Pressing a
/// button widens it and squishes its neighbours, keeping the row width fixed.
/// Callers use the standard transport row when expressive motion is off.
class ExpressivePlaybackTransport extends StatefulWidget {
  const ExpressivePlaybackTransport({
    super.key,
    required this.colorScheme,
    required this.playing,
    required this.loading,
    required this.playTooltip,
    required this.previousTooltip,
    required this.nextTooltip,
    required this.onPlayPause,
    required this.onPrevious,
    required this.onNext,
    this.leading,
    this.trailing,
    this.compact = false,
    this.fill = false,
  });

  final ColorScheme colorScheme;
  final bool playing;
  final bool loading;
  final String playTooltip;
  final String previousTooltip;
  final String nextTooltip;
  final VoidCallback onPlayPause;
  final VoidCallback onPrevious;
  final VoidCallback onNext;

  /// 48dp actions beside the group, such as shuffle and repeat.
  final Widget? leading;
  final Widget? trailing;
  final bool compact;

  /// Stretches the group, in its resting proportions, so the row spans the
  /// full width and [leading] and [trailing] line up with its ends.
  final bool fill;

  @override
  State<ExpressivePlaybackTransport> createState() =>
      _ExpressivePlaybackTransportState();
}

class _ExpressivePlaybackTransportState
    extends State<ExpressivePlaybackTransport>
    with ExpressivePressSquish {
  static const _gap = 8.0;
  static const _sideActionWidth = 48.0;
  static const _minTarget = 48.0;

  @override
  Widget build(BuildContext context) {
    final compact = widget.compact;
    final height = compact ? 56.0 : 72.0;
    final restingWidths = compact ? [56.0, 80.0, 56.0] : [68.0, 104.0, 68.0];
    return LayoutBuilder(
      builder: (context, constraints) {
        final sideActions =
            (widget.leading == null ? 0 : 1) +
            (widget.trailing == null ? 0 : 1);
        final groupWidth = restingWidths.reduce((a, b) => a + b);
        final available =
            constraints.maxWidth -
            sideActions * (_sideActionWidth + _gap) -
            2 * _gap;
        var widths = [...restingWidths];
        if (constraints.hasBoundedWidth && available < groupWidth) {
          // Narrow phones: previous/next keep a 48dp target and play-pause
          // absorbs the remaining shortfall.
          final side = math.max(
            _minTarget,
            restingWidths.first * available / groupWidth,
          );
          widths = [side, math.max(_minTarget, available - 2 * side), side];
        } else if (constraints.hasBoundedWidth && widget.fill) {
          final scale = available / groupWidth;
          widths = [for (final width in restingWidths) width * scale];
        }
        final factors = [1.0, 1.0, 1.0];
        final pressed = pressedIndex;
        if (pressed != null) {
          // Neighbours give up exactly what the pressed button gains.
          final growth = restingWidths[pressed] * squishRatio;
          final neighbours = [
            pressed - 1,
            pressed + 1,
          ].where((index) => index >= 0 && index < widths.length).toList();
          factors[pressed] += squishRatio;
          for (final index in neighbours) {
            factors[index] -= growth / neighbours.length / restingWidths[index];
          }
        }
        final scheme = widget.colorScheme;
        final playIcon = widget.loading
            ? AppLoadingIndicator(color: scheme.onSurfaceVariant)
            : null;
        final buttons = [
          _button(
            tooltip: widget.previousTooltip,
            icon: const AppIcon(Icons.skip_previous),
            iconSize: compact ? 28 : 32,
            round: false,
            background: scheme.secondaryContainer,
            foreground: scheme.onSecondaryContainer,
            onPressed: widget.onPrevious,
          ),
          _button(
            tooltip: widget.playTooltip,
            icon: playIcon ?? const AppIcon(Icons.play_arrow),
            selectedIcon: playIcon ?? const AppIcon(Icons.pause),
            selected: widget.playing,
            iconSize: compact ? 32 : 40,
            round: true,
            background: scheme.primary,
            foreground: scheme.onPrimary,
            onPressed: widget.loading ? null : widget.onPlayPause,
          ),
          _button(
            tooltip: widget.nextTooltip,
            icon: const AppIcon(Icons.skip_next),
            iconSize: compact ? 28 : 32,
            round: false,
            background: scheme.secondaryContainer,
            foreground: scheme.onSecondaryContainer,
            onPressed: widget.onNext,
          ),
        ];
        // Spring only the press proportions. Resizing follows the parent
        // directly instead of restarting a width spring on every frame.
        return TweenAnimationBuilder<_SlotWidths>(
          tween: _SlotWidthsTween(end: (factors[0], factors[1], factors[2])),
          duration: pressSpring.duration,
          curve: pressSpring,
          builder: (context, slots, _) {
            var previous = widths[0] * slots.$1;
            var play = widths[1] * slots.$2;
            var next = widths[2] * slots.$3;
            final total = previous + play + next;
            final restingTotal = widths.reduce((a, b) => a + b);
            if (total > 0 && total != restingTotal) {
              final scale = restingTotal / total;
              previous *= scale;
              play *= scale;
              next *= scale;
            }
            return Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (widget.leading case final leading?) ...[
                  leading,
                  const SizedBox(width: _gap),
                ],
                _slot(0, previous, height, buttons[0]),
                const SizedBox(width: _gap),
                _slot(1, play, height, buttons[1]),
                const SizedBox(width: _gap),
                _slot(2, next, height, buttons[2]),
                if (widget.trailing case final trailing?) ...[
                  const SizedBox(width: _gap),
                  trailing,
                ],
              ],
            );
          },
        );
      },
    );
  }

  Widget _slot(int index, double width, double height, Widget child) =>
      pressSlot(
        index,
        SizedBox(width: math.max(0, width), height: height, child: child),
      );

  Widget _button({
    required String tooltip,
    required Widget icon,
    Widget? selectedIcon,
    bool? selected,
    required double iconSize,
    required bool round,
    required Color background,
    required Color foreground,
    required VoidCallback? onPressed,
  }) {
    final scheme = Theme.of(context).colorScheme;
    Widget sized(Widget icon) => IconTheme.merge(
      data: IconThemeData(size: iconSize),
      child: icon,
    );
    return Tooltip(
      message: tooltip,
      excludeFromSemantics: true,
      // One labeled node instead of a label plus an unnamed tap target.
      child: MergeSemantics(
        child: MaterialExpressiveScope(
          child: M3EIconButton(
            icon: sized(icon),
            selectedIcon: selectedIcon == null ? null : sized(selectedIcon),
            isSelected: selected,
            semanticLabel: tooltip,
            onPressed: onPressed,
            size: widget.compact ? M3EIconButtonSize.md : M3EIconButtonSize.lg,
            shape: round
                ? M3EIconButtonShapeVariant.round
                : M3EIconButtonShapeVariant.square,
            variant: M3EIconButtonVariant.filled,
            matchParentConstraints: true,
            inflateHitTarget: false,
            decoration: expressiveFill(scheme, foreground, background),
          ),
        ),
      ),
    );
  }
}

/// Relative widths of the previous, play-pause and next slots while pressed.
typedef _SlotWidths = (double, double, double);

class _SlotWidthsTween extends Tween<_SlotWidths> {
  _SlotWidthsTween({super.end});

  @override
  _SlotWidths lerp(double t) {
    final (b0, b1, b2) = begin!;
    final (e0, e1, e2) = end!;
    return (b0 + (e0 - b0) * t, b1 + (e1 - b1) * t, b2 + (e2 - b2) * t);
  }
}
