import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/material.dart';

/// How far the pointer press disc grows: from 32 to 38 on the capsule.
const _pressDiscGrowth = 6 / 32;

/// The press response and advancing skip glyphs used by Mornye's transport.
class MornyePlaybackButton extends StatefulWidget {
  const MornyePlaybackButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.color,
    required this.onPressed,
    this.iconSize = 40,
    this.padding = const EdgeInsets.all(8),
    this.loading = false,
    this.pointerPress = false,
  });

  final IconData icon;
  final String tooltip;
  final Color color;
  final VoidCallback? onPressed;
  final double iconSize;
  final EdgeInsetsGeometry padding;
  final bool loading;

  /// The desktop capsule's press: the glyph shrinks to 90% over
  /// a disc that grows past the button, both 200ms easing out.
  final bool pointerPress;

  @override
  State<MornyePlaybackButton> createState() => _MornyePlaybackButtonState();
}

class _MornyePlaybackButtonState extends State<MornyePlaybackButton>
    with TickerProviderStateMixin {
  final _states = WidgetStatesController();
  late final _press = AnimationController(
    vsync: this,
    duration: Duration(milliseconds: widget.pointerPress ? 200 : 100),
    reverseDuration: Duration(milliseconds: widget.pointerPress ? 200 : 320),
  );
  late final _skip = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 300),
  );

  bool get _isSkip =>
      widget.icon == CupertinoIcons.forward_fill ||
      widget.icon == CupertinoIcons.backward_fill;

  @override
  void initState() {
    super.initState();
    _states.addListener(_updatePress);
    _press.addStatusListener((status) {
      if (status == AnimationStatus.completed &&
          !_states.value.contains(WidgetState.pressed)) {
        _press.reverse();
      }
    });
  }

  void _updatePress() {
    if (_states.value.contains(WidgetState.pressed)) {
      _press.forward();
    } else if (_press.isCompleted) {
      _press.reverse();
    }
    // A quick tap still finishes its fade-in before fading back out.
  }

  @override
  void dispose() {
    _states.removeListener(_updatePress);
    _states.dispose();
    _press.dispose();
    _skip.dispose();
    super.dispose();
  }

  Widget _skipGlyph(bool reduceMotion) => AnimatedBuilder(
    animation: _skip,
    builder: (context, _) {
      if (!_skip.isAnimating || reduceMotion) return Icon(widget.icon);
      final progress = Curves.easeInOut.transform(_skip.value);
      final size = widget.iconSize;
      Widget triangle(double position, double scale) => Positioned(
        left: size * (position - 0.26),
        top: 0,
        width: size * 0.52,
        height: size,
        child: Transform.scale(
          scale: scale,
          child: const FittedBox(
            fit: BoxFit.fill,
            child: Icon(CupertinoIcons.play_fill),
          ),
        ),
      );
      return Transform.flip(
        flipX: widget.icon == CupertinoIcons.backward_fill,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            triangle(0.25, progress),
            triangle(0.25 + progress * 0.5, 1),
            triangle(0.75, 1 - progress),
          ],
        ),
      );
    },
  );

  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final pointerPress = widget.pointerPress;
    final motion = Duration(
      milliseconds: reduceMotion
          ? 120
          : pointerPress
          ? 200
          : 180,
    );
    final enabled = widget.onPressed != null && !widget.loading;
    final button = IconButton(
      statesController: _states,
      tooltip: widget.tooltip,
      color: widget.color,
      iconSize: widget.iconSize,
      padding: widget.padding,
      style: ButtonStyle(
        shape: const WidgetStatePropertyAll(CircleBorder()),
        splashFactory: NoSplash.splashFactory,
        overlayColor: WidgetStateProperty.resolveWith((states) {
          return states.contains(WidgetState.focused) ||
                  states.contains(WidgetState.hovered)
              ? widget.color.withValues(alpha: 0.08)
              : Colors.transparent;
        }),
      ),
      onPressed: enabled
          ? () {
              _press.forward();
              if (_isSkip && !reduceMotion) _skip.forward(from: 0);
              widget.onPressed!();
            }
          : null,
      icon: ValueListenableBuilder<Set<WidgetState>>(
        valueListenable: _states,
        builder: (context, states, _) {
          final pressed = states.contains(WidgetState.pressed);
          return AnimatedScale(
            scale: !pressed || reduceMotion
                ? 1
                : pointerPress
                ? 0.9
                : 0.95,
            duration: motion,
            curve: pointerPress ? Curves.easeOut : Curves.easeOutCubic,
            child: AnimatedOpacity(
              opacity: pressed && !pointerPress ? 0.72 : 1,
              duration: motion,
              child: SizedBox.square(
                dimension: widget.iconSize,
                child: AnimatedSwitcher(
                  duration: Duration(milliseconds: reduceMotion ? 120 : 200),
                  child: widget.loading
                      ? const Center(
                          child: SizedBox.square(
                            dimension: 32,
                            child: CircularProgressIndicator(strokeWidth: 3),
                          ),
                        )
                      : KeyedSubtree(
                          key: ValueKey(widget.icon),
                          child: _isSkip
                              ? _skipGlyph(reduceMotion)
                              : Icon(widget.icon),
                        ),
                ),
              ),
            ),
          );
        },
      ),
    );
    return AnimatedBuilder(
      animation: _press,
      child: button,
      builder: (context, child) {
        if (!pointerPress) {
          return DecoratedBox(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: widget.color.withValues(
                alpha: 0.14 * Curves.easeOutCubic.transform(_press.value),
              ),
            ),
            child: child,
          );
        }
        final progress = Curves.easeOut.transform(_press.value);
        return Stack(
          clipBehavior: Clip.none,
          children: [
            Positioned.fill(
              child: Transform.scale(
                key: const ValueKey('mornye-playback-press-disc'),
                scale: reduceMotion ? 1 : 1 + _pressDiscGrowth * progress,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: widget.color.withValues(alpha: 0.2 * progress),
                  ),
                ),
              ),
            ),
            child!,
          ],
        );
      },
    );
  }
}
