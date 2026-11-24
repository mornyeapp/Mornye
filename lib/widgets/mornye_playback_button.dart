import 'package:cupertino_ui/cupertino_ui.dart' show CupertinoIcons;
import 'package:flutter/physics.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mornye/theme/app_motion.dart';

/// How far the pointer press disc grows: from 32 to 38 on the capsule.
const _pressDiscGrowth = 6 / 32;

/// A press highlight is settled once it is within a hundredth of its end.
const _pressTolerance = Tolerance(distance: 0.01, velocity: 0.5);

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
  /// a disc that grows past the button, both on the fast spring.
  final bool pointerPress;

  @override
  State<MornyePlaybackButton> createState() => _MornyePlaybackButtonState();
}

class _MornyePlaybackButtonState extends State<MornyePlaybackButton>
    with TickerProviderStateMixin {
  final _states = WidgetStatesController();

  /// The press highlight, moved by springs: the touch highlight comes in on
  /// the fast effects spring and leaves on the slower one, as a touch
  /// highlight lingers; the capsule's disc grows and shrinks on the fast
  /// spring. Each spring starts from the highlight on screen.
  late final _press = AnimationController(vsync: this);

  /// One advance of the skip glyph, on the fast spring.
  late final _skip = AnimationController(
    vsync: this,
    duration: MornyeMotion.fast.duration,
  );

  /// A skip pressed during an advance runs one more once it ends, so the
  /// glyph never jumps back to its start.
  bool _skipAgain = false;

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
        _pressOut();
      }
    });
    _skip.addStatusListener((status) {
      if (status == AnimationStatus.completed && _skipAgain) {
        _skipAgain = false;
        // The glyph ends where it starts, so the next advance is seamless.
        _skip.forward(from: 0);
      }
    });
  }

  void _pressIn() {
    if (_press.isCompleted ||
        (_press.isAnimating && _press.status == AnimationStatus.forward)) {
      return;
    }
    _press.animateWith(
      SpringSimulation(
        widget.pointerPress
            ? MornyeMotion.fastSpring
            : MornyeMotion.effectsFastSpring,
        _press.value,
        1,
        0,
        tolerance: _pressTolerance,
        snapToEnd: true,
      ),
    );
  }

  void _pressOut() {
    _press.animateBackWith(
      SpringSimulation(
        widget.pointerPress
            ? MornyeMotion.fastSpring
            : MornyeMotion.effectsSpring,
        _press.value,
        0,
        0,
        tolerance: _pressTolerance,
        snapToEnd: true,
      ),
    );
  }

  void _advanceSkip() {
    if (_skip.isAnimating) {
      _skipAgain = true;
    } else {
      _skip.forward(from: 0);
    }
  }

  void _updatePress() {
    if (_states.value.contains(WidgetState.pressed)) {
      _pressIn();
    } else if (_press.isCompleted) {
      _pressOut();
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
      final progress = MornyeMotion.fast.curve.transform(_skip.value);
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
    // The glyph's press scale is a small control moving, on the fast
    // spring; its dim and the loading crossfade are fades, which Reduce
    // Motion keeps.
    final scale = reduceMotion
        ? const AppMotionSpec(Duration.zero, Curves.linear)
        : MornyeMotion.fast;
    final dim = MornyeMotion.effectsFast;
    final crossfade = MornyeMotion.effects;
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
              _pressIn();
              if (_isSkip && !reduceMotion) _advanceSkip();
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
            duration: scale.duration,
            curve: scale.curve,
            child: AnimatedOpacity(
              opacity: pressed && !pointerPress ? 0.72 : 1,
              duration: dim.duration,
              curve: dim.curve,
              child: SizedBox.square(
                dimension: widget.iconSize,
                child: AnimatedSwitcher(
                  duration: crossfade.duration,
                  switchInCurve: crossfade.curve,
                  switchOutCurve: crossfade.leaving,
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
              color: widget.color.withValues(alpha: 0.14 * _press.value),
            ),
            child: child,
          );
        }
        final progress = _press.value;
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
