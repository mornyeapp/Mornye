import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';

/// Smooths visual progress changes without increasing backend polling.
///
/// The first value is shown immediately so restored downloads never animate
/// from zero. Later monotonic increases are interpolated locally, while
/// resets, completion, and disabled animations snap to the authoritative
/// backend value.
class SmoothedProgressScope extends StatefulWidget {
  final double value;
  final bool animate;
  final Duration duration;
  final Curve curve;
  final Widget child;

  const SmoothedProgressScope({
    super.key,
    required this.value,
    required this.child,
    this.animate = true,
    this.duration = const Duration(milliseconds: 900),
    this.curve = Curves.linear,
  });

  static ValueListenable<double> of(BuildContext context) {
    final scope = context
        .dependOnInheritedWidgetOfExactType<_SmoothedProgressScopeData>();
    assert(scope != null, 'No SmoothedProgressScope found in context');
    return scope!.progress;
  }

  @override
  State<SmoothedProgressScope> createState() => _SmoothedProgressScopeState();
}

class _SmoothedProgressScopeState extends State<SmoothedProgressScope>
    with SingleTickerProviderStateMixin {
  AnimationController? _controller;
  late final ValueNotifier<double> _displayedProgress;
  Animation<double>? _animation;

  double _normalized(double value) => value.clamp(0.0, 1.0).toDouble();

  AnimationController _ensureController() =>
      _controller ??= AnimationController(
        vsync: this,
        duration: widget.duration,
      )..addListener(_updateDisplayedProgress);

  @override
  void initState() {
    super.initState();
    final initialValue = _normalized(widget.value);
    _displayedProgress = ValueNotifier<double>(initialValue);
  }

  @override
  void didUpdateWidget(covariant SmoothedProgressScope oldWidget) {
    super.didUpdateWidget(oldWidget);
    _controller?.duration = widget.duration;

    final target = _normalized(widget.value);
    final current = _displayedProgress.value;
    if ((target - current).abs() < 0.0001) {
      return;
    }

    final shouldSnap =
        !widget.animate ||
        target < _normalized(oldWidget.value) ||
        target <= current ||
        target <= 0 ||
        target >= 1 ||
        widget.duration == Duration.zero;
    if (shouldSnap) {
      _controller?.stop();
      _animation = null;
      _displayedProgress.value = target;
      return;
    }

    final controller = _ensureController();
    _animation = Tween<double>(
      begin: current,
      end: target,
    ).chain(CurveTween(curve: widget.curve)).animate(controller);
    controller.forward(from: 0);
  }

  void _updateDisplayedProgress() {
    final animation = _animation;
    if (animation != null) {
      _displayedProgress.value = animation.value;
    }
  }

  @override
  void dispose() {
    _controller
      ?..removeListener(_updateDisplayedProgress)
      ..dispose();
    _displayedProgress.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return _SmoothedProgressScopeData(
      progress: _displayedProgress,
      child: widget.child,
    );
  }
}

class _SmoothedProgressScopeData extends InheritedWidget {
  final ValueListenable<double> progress;

  const _SmoothedProgressScopeData({
    required this.progress,
    required super.child,
  });

  @override
  bool updateShouldNotify(_SmoothedProgressScopeData oldWidget) =>
      progress != oldWidget.progress;
}

/// Rebuilds only the visual fragment that consumes smoothed progress.
class SmoothedProgressBuilder extends StatelessWidget {
  final Widget? child;
  final Widget Function(BuildContext context, double progress, Widget? child)
  builder;

  const SmoothedProgressBuilder({super.key, required this.builder, this.child});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<double>(
      valueListenable: SmoothedProgressScope.of(context),
      builder: builder,
      child: child,
    );
  }
}
