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
        layoutBuilder: _layoutBuilder,
        transitionBuilder: _transitionBuilder,
        child: _DownloadStateItem(
          key: ValueKey(state),
          fadeCurve: over(fade),
          scaleCurve: over(scale),
          exitCurve: fade.leaving,
          expressive: expressive,
          child: child,
        ),
      ),
    );
  }

  static Widget _layoutBuilder(Widget? current, List<Widget> previous) => Stack(
    alignment: AlignmentDirectional.centerEnd,
    children: [...previous, ?current],
  );

  static Widget _transitionBuilder(Widget child, Animation<double> animation) {
    final item = child as _DownloadStateItem;
    return _DownloadStateTransition(
      key: ValueKey(item.key),
      animation: animation,
      fadeCurve: item.fadeCurve,
      scaleCurve: item.scaleCurve,
      exitCurve: item.exitCurve,
      expressive: item.expressive,
      child: item,
    );
  }
}

class _DownloadStateItem extends StatelessWidget {
  const _DownloadStateItem({
    super.key,
    required this.fadeCurve,
    required this.scaleCurve,
    required this.exitCurve,
    required this.expressive,
    required this.child,
  });

  final Curve fadeCurve;
  final Curve scaleCurve;
  final Curve exitCurve;
  final bool expressive;
  final Widget child;

  @override
  Widget build(BuildContext context) => child;
}

class _DownloadStateTransition extends StatefulWidget {
  const _DownloadStateTransition({
    super.key,
    required this.animation,
    required this.fadeCurve,
    required this.scaleCurve,
    required this.exitCurve,
    required this.expressive,
    required this.child,
  });

  final Animation<double> animation;
  final Curve fadeCurve;
  final Curve scaleCurve;
  final Curve exitCurve;
  final bool expressive;
  final Widget child;

  @override
  State<_DownloadStateTransition> createState() =>
      _DownloadStateTransitionState();
}

class _DownloadStateTransitionState extends State<_DownloadStateTransition> {
  static final _scaleTween = Tween<double>(begin: 0.8, end: 1);

  late CurvedAnimation _fade;
  CurvedAnimation? _scaleCurve;
  Animation<double>? _scale;
  late AnimationStatus _status;

  @override
  void initState() {
    super.initState();
    _initAnimations();
    _status = widget.animation.status;
    widget.animation.addStatusListener(_onStatus);
  }

  // A curve keeps the direction it started in, so an exit that cuts the
  // entrance short starts new curves to leave on the exit curve.
  void _onStatus(AnimationStatus status) {
    final cutShort =
        _status == AnimationStatus.forward && status == AnimationStatus.reverse;
    _status = status;
    if (!cutShort) return;
    setState(() {
      _disposeAnimations();
      _initAnimations();
    });
  }

  void _initAnimations() {
    _fade = CurvedAnimation(
      parent: widget.animation,
      curve: widget.fadeCurve,
      reverseCurve: widget.exitCurve,
    );
    if (widget.expressive) {
      final curve = CurvedAnimation(
        parent: widget.animation,
        curve: widget.scaleCurve,
        reverseCurve: widget.exitCurve,
      );
      _scaleCurve = curve;
      _scale = _scaleTween.animate(curve);
    }
  }

  void _disposeAnimations() {
    _fade.dispose();
    _scaleCurve?.dispose();
    _scaleCurve = null;
    _scale = null;
  }

  @override
  void didUpdateWidget(_DownloadStateTransition oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.animation != widget.animation ||
        oldWidget.expressive != widget.expressive) {
      oldWidget.animation.removeStatusListener(_onStatus);
      _disposeAnimations();
      _initAnimations();
      _status = widget.animation.status;
      widget.animation.addStatusListener(_onStatus);
      return;
    }
    // Every build makes new but equal curves; set them in place.
    _fade
      ..curve = widget.fadeCurve
      ..reverseCurve = widget.exitCurve;
    _scaleCurve
      ?..curve = widget.scaleCurve
      ..reverseCurve = widget.exitCurve;
  }

  @override
  void dispose() {
    widget.animation.removeStatusListener(_onStatus);
    _disposeAnimations();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final opacity = FadeTransition(opacity: _fade, child: widget.child);
    final scale = _scale;
    if (scale == null) return opacity;
    return ScaleTransition(scale: scale, child: opacity);
  }
}
