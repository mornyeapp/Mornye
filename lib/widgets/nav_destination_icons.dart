import 'package:material_ui/material_ui.dart';
import 'package:mornye/theme/app_motion.dart';

/// Plays a selected destination's icon in once: on the fast expressive
/// spatial spring in Material, which overshoots by itself, and on the fast
/// effects spring for a fade. Mornye's tab icons do not move, and reduced
/// motion shows the icon at rest.
abstract class _SelectedIconState<T extends StatefulWidget> extends State<T>
    with SingleTickerProviderStateMixin {
  static const _still = AppMotionSpec(Duration.zero, Curves.linear);

  late final AnimationController _controller = AnimationController(vsync: this);
  late final CurvedAnimation spatial = CurvedAnimation(
    parent: _controller,
    curve: Curves.linear,
  );
  late final CurvedAnimation effects = CurvedAnimation(
    parent: _controller,
    curve: Curves.linear,
  );
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    final move = AppMotion.spatialFast(context, _still);
    final fade = AppMotion.effectsFast(context, _still);
    final length = move.duration > fade.duration
        ? move.duration
        : fade.duration;
    if (length == Duration.zero) {
      _controller.value = 1;
      return;
    }
    double part(Duration duration) =>
        duration.inMicroseconds / length.inMicroseconds;
    spatial.curve = Interval(0, part(move.duration), curve: move.curve);
    effects.curve = Interval(0, part(fade.duration), curve: fade.curve);
    _controller.duration = length;
    _controller.forward();
  }

  @override
  void dispose() {
    spatial.dispose();
    effects.dispose();
    _controller.dispose();
    super.dispose();
  }
}

class BouncingIcon extends StatefulWidget {
  final Widget child;
  const BouncingIcon({super.key, required this.child});

  @override
  State<BouncingIcon> createState() => _BouncingIconState();
}

class _BouncingIconState extends _SelectedIconState<BouncingIcon> {
  late final Animation<double> _scaleAnimation = Tween<double>(
    begin: 0.1,
    end: 1.0,
  ).animate(spatial);

  @override
  Widget build(BuildContext context) {
    return ScaleTransition(scale: _scaleAnimation, child: widget.child);
  }
}

class SlidingIcon extends StatefulWidget {
  final Widget child;
  const SlidingIcon({super.key, required this.child});

  @override
  State<SlidingIcon> createState() => _SlidingIconState();
}

class _SlidingIconState extends _SelectedIconState<SlidingIcon> {
  late final Animation<Offset> _offsetAnimation = Tween<Offset>(
    begin: const Offset(0, 0.5),
    end: Offset.zero,
  ).animate(spatial);

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: effects,
      child: SlideTransition(position: _offsetAnimation, child: widget.child),
    );
  }
}

class SpinIcon extends StatefulWidget {
  final Widget child;
  const SpinIcon({super.key, required this.child});

  @override
  State<SpinIcon> createState() => _SpinIconState();
}

class _SpinIconState extends _SelectedIconState<SpinIcon> {
  late final Animation<double> _rotationAnimation = Tween<double>(
    begin: 0.0,
    end: 0.5,
  ).animate(spatial);

  @override
  Widget build(BuildContext context) {
    return RotationTransition(turns: _rotationAnimation, child: widget.child);
  }
}
