import 'package:flutter/material.dart';
import 'package:mornye/theme/app_motion.dart';

/// Material's immersive lyrics: fades the controls and folds their height
/// away, sliding them down, so the lyrics take the room they leave. The
/// controls stay mounted, keeping their state.
class PlayerLyricsControlsCollapse extends StatelessWidget {
  const PlayerLyricsControlsCollapse({
    super.key,
    required this.hidden,
    required this.child,
  });

  final bool hidden;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    // The slow spatial spring is critically damped: the fold never
    // overshoots into a gap below the controls.
    final motion = AppMotion.spatialSlow(
      context,
      AppMotionSpec(
        MediaQuery.disableAnimationsOf(context)
            ? Duration.zero
            : const Duration(milliseconds: 350),
        Curves.easeInOutCubic,
      ),
    );
    return IgnorePointer(
      ignoring: hidden,
      child: ExcludeSemantics(
        excluding: hidden,
        child: TweenAnimationBuilder<double>(
          tween: Tween(end: hidden ? 0 : 1),
          duration: motion.duration,
          curve: motion.curve,
          builder: (context, shown, child) => ClipRect(
            child: Align(
              alignment: Alignment.topCenter,
              heightFactor: shown.clamp(0, 1),
              child: Opacity(opacity: shown.clamp(0, 1), child: child),
            ),
          ),
          child: child,
        ),
      ),
    );
  }
}

/// Fades controls without changing the lyric viewport or active scroll gesture.
class PlayerLyricsControlsVisibility extends StatelessWidget {
  const PlayerLyricsControlsVisibility({
    super.key,
    required this.hidden,
    required this.child,
  });

  final bool hidden;
  final Widget child;

  @override
  Widget build(BuildContext context) => IgnorePointer(
    ignoring: hidden,
    child: ExcludeSemantics(
      excluding: hidden,
      child: AnimatedOpacity(
        opacity: hidden ? 0 : 1,
        duration: MediaQuery.disableAnimationsOf(context)
            ? Duration.zero
            : const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
        child: child,
      ),
    ),
  );
}
