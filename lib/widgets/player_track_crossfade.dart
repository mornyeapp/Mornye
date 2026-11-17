import 'package:material_ui/material_ui.dart';
import 'package:mornye/theme/app_motion.dart';

/// Timing for a track change the app started (a skip button, a headset key,
/// autoplay): an opacity crossfade that never moves or overshoots. Each
/// style uses its effects spring, and reduced motion cuts.
AppMotionSpec playerTrackChangeMotion(BuildContext context) {
  if (MediaQuery.disableAnimationsOf(context)) {
    return const AppMotionSpec(Duration.zero, Curves.linear);
  }
  return AppMotion.effects(
    context,
    const AppMotionSpec(Duration(milliseconds: 200), Curves.easeInOut),
  );
}

/// Fades the title and artist lines through when [trackKey] changes: the old
/// lines fade out before the new ones fade in, so rapid skips never stack
/// two readable titles. The lines stay stacked at [alignment] and keep the
/// parent's constraints, so the layout around them does not move.
class PlayerTrackCrossfade extends StatelessWidget {
  const PlayerTrackCrossfade({
    super.key,
    required this.trackKey,
    required this.child,
    this.alignment = AlignmentDirectional.centerStart,
  });

  final Object? trackKey;
  final AlignmentGeometry alignment;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final motion = playerTrackChangeMotion(context);
    // Each half runs the curve: the outgoing lines over the first half, the
    // incoming ones over the second.
    final half = CurveTween(curve: Interval(0.5, 1, curve: motion.curve));
    return AnimatedSwitcher(
      duration: motion.duration,
      transitionBuilder: (child, animation) =>
          FadeTransition(opacity: animation.drive(half), child: child),
      layoutBuilder: (current, previous) => Stack(
        alignment: alignment,
        fit: StackFit.passthrough,
        children: [...previous, ?current],
      ),
      child: KeyedSubtree(key: ValueKey(trackKey), child: child),
    );
  }
}
