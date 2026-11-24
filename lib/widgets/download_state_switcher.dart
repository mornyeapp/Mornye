import 'package:material_ui/material_ui.dart';
import 'package:mornye/theme/app_motion.dart';
import 'package:mornye/theme/material_expressive.dart';

/// Switches a download row's trailing control when its state changes.
///
/// Material fades on the fast effects spring with a small scale on the fast
/// spatial spring; Mornye plainly fades. The row's width follows the new
/// control instead of jumping. Reduced motion switches in place.
class DownloadStateSwitcher extends StatelessWidget {
  const DownloadStateSwitcher({
    super.key,
    required this.state,
    required this.child,
  });

  /// Identifies the control shown; a new value switches to [child].
  final Object state;
  final Widget child;

  static const _fallback = AppMotionSpec(
    Duration(milliseconds: 200),
    Curves.easeInOut,
  );

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.disableAnimationsOf(context)) return child;
    final expressive = materialExpressiveEnabled(context);
    final fade = AppMotion.effectsFast(context, _fallback);
    final scale = AppMotion.spatialFast(context, _fallback);
    final size = AppMotion.spatial(context, _fallback);
    final duration = fade.duration > scale.duration
        ? fade.duration
        : scale.duration;
    // One switcher clock drives both springs, each over its own length.
    Curve over(AppMotionSpec spec) => Interval(
      0,
      spec.duration.inMicroseconds / duration.inMicroseconds,
      curve: spec.curve,
    );
    return AnimatedSize(
      duration: size.duration,
      curve: size.curve,
      alignment: AlignmentDirectional.centerEnd,
      clipBehavior: Clip.none,
      child: AnimatedSwitcher(
        duration: duration,
        // The outgoing control leaves on the fade alone, without overshoot.
        // Replaying the entrance springs backwards kept it fully opaque on
        // top of the new control for most of the switch.
        reverseDuration: fade.duration,
        layoutBuilder: (current, previous) => Stack(
          alignment: AlignmentDirectional.centerEnd,
          children: [...previous, ?current],
        ),
        transitionBuilder: (child, animation) {
          final exit = fade.leaving;
          final opacity = FadeTransition(
            opacity: CurvedAnimation(
              parent: animation,
              curve: over(fade),
              reverseCurve: exit,
            ),
            child: child,
          );
          if (!expressive) return opacity;
          return ScaleTransition(
            scale: Tween<double>(begin: 0.8, end: 1).animate(
              CurvedAnimation(
                parent: animation,
                curve: over(scale),
                reverseCurve: exit,
              ),
            ),
            child: opacity,
          );
        },
        child: KeyedSubtree(key: ValueKey(state), child: child),
      ),
    );
  }
}
