import 'package:flutter/widgets.dart';
import 'package:mornye/theme/app_motion.dart';

/// How far into its fade loaded content starts, so the frame that drops the
/// skeleton already shows the content: one frame at 60 Hz.
const loadedFadeFirstFrame = Duration(milliseconds: 16);

/// Fades loaded content in once, when it replaces its skeleton.
///
/// Keep one instance, under a stable key, where the skeleton and the loaded
/// sliver take turns: while [loading] it shows [sliver] (the skeleton) as it
/// is, and the build that turns [loading] off fades the loaded [sliver] in,
/// on the effects spring of the app's style.
/// Content already there on the first build, later rebuilds and scrolling
/// never fade, and nothing staggers. Reduced motion and a false [enabled]
/// cut. Hit testing does not wait for the fade.
class LoadedSliverFadeIn extends StatefulWidget {
  const LoadedSliverFadeIn({
    super.key,
    required this.loading,
    required this.sliver,
    this.enabled = true,
  });

  final bool loading;
  final Widget sliver;
  final bool enabled;

  static const _fallback = AppMotionSpec(
    Duration(milliseconds: 150),
    Curves.easeOut,
  );

  @override
  State<LoadedSliverFadeIn> createState() => _LoadedSliverFadeInState();
}

class _LoadedSliverFadeInState extends State<LoadedSliverFadeIn>
    with SingleTickerProviderStateMixin {
  late final _controller = AnimationController(vsync: this, value: 1);
  late Animation<double> _opacity = _controller;

  @override
  void didUpdateWidget(LoadedSliverFadeIn oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.loading == widget.loading) return;
    if (widget.loading ||
        !widget.enabled ||
        MediaQuery.disableAnimationsOf(context)) {
      _controller.value = 1;
      return;
    }
    final motion = AppMotion.effects(context, LoadedSliverFadeIn._fallback);
    _controller.duration = motion.duration;
    _opacity = _controller.drive(CurveTween(curve: motion.curve));
    // The skeleton is already gone in this frame, so start one frame into
    // the fade instead of drawing an empty frame at opacity 0.
    _controller.forward(
      from:
          loadedFadeFirstFrame.inMicroseconds / motion.duration.inMicroseconds,
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      SliverFadeTransition(opacity: _opacity, sliver: widget.sliver);
}
