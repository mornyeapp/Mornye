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
class PlayerTrackCrossfade extends StatefulWidget {
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
  State<PlayerTrackCrossfade> createState() => _PlayerTrackCrossfadeState();
}

class _PlayerTrackCrossfadeState extends State<PlayerTrackCrossfade> {
  /// Whether the lines showed when they last checked. Lines that change
  /// while hidden, as under the full player, or in the frame they show
  /// again, replace the old ones without a fade.
  bool _onScreen = false;
  int _swaps = 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _onScreen = TickerMode.valuesOf(context).enabled;
  }

  @override
  void didUpdateWidget(PlayerTrackCrossfade oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.trackKey != oldWidget.trackKey && !_onScreen) _swaps++;
  }

  @override
  Widget build(BuildContext context) {
    final motion = playerTrackChangeMotion(context);
    final alignment = widget.alignment;
    // Each half runs its curve: the outgoing lines fade out on the leaving
    // curve over the first half, and the incoming ones fade in over the second.
    return AnimatedSwitcher(
      // A new switcher starts on the new lines, with nothing to fade from.
      key: ValueKey(_swaps),
      duration: motion.duration,
      switchInCurve: Interval(0.5, 1, curve: motion.curve),
      switchOutCurve: Interval(0.5, 1, curve: motion.leaving),
      transitionBuilder: (child, animation) =>
          FadeTransition(opacity: animation, child: child),
      layoutBuilder: (current, previous) => Stack(
        alignment: alignment,
        fit: StackFit.passthrough,
        children: [...previous, ?current],
      ),
      child: KeyedSubtree(key: ValueKey(widget.trackKey), child: widget.child),
    );
  }
}
