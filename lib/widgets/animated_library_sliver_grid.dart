import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:material_ui/material_ui.dart';
import 'package:mornye/theme/app_motion.dart';
import 'package:mornye/theme/mornye_theme.dart';

class AnimatedLibrarySliverGrid extends StatefulWidget {
  final double maxCrossAxisExtent;
  final double mainAxisSpacing;
  final double crossAxisSpacing;
  final double childAspectRatio;
  final SliverChildDelegate delegate;
  final ValueListenable<double>? extentListenable;
  final double extentScale;
  final double? minExtent;
  final double? maxExtent;

  const AnimatedLibrarySliverGrid({
    super.key,
    required this.maxCrossAxisExtent,
    required this.mainAxisSpacing,
    required this.crossAxisSpacing,
    required this.childAspectRatio,
    required this.delegate,
    this.extentListenable,
    this.extentScale = 1,
    this.minExtent,
    this.maxExtent,
  });

  @override
  State<AnimatedLibrarySliverGrid> createState() =>
      _AnimatedLibrarySliverGridState();
}

class _AnimatedLibrarySliverGridState extends State<AnimatedLibrarySliverGrid>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final CurvedAnimation _curve;
  late double _beginExtent;
  late double _endExtent;

  @override
  void initState() {
    super.initState();
    _beginExtent = widget.maxCrossAxisExtent;
    _endExtent = widget.maxCrossAxisExtent;
    _controller = AnimationController(vsync: this, value: 1);
    _curve = CurvedAnimation(parent: _controller, curve: Curves.linear);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      _controller.stop();
      _beginExtent = _endExtent = widget.maxCrossAxisExtent;
      _controller.value = 1;
    }
  }

  @override
  void didUpdateWidget(covariant AnimatedLibrarySliverGrid oldWidget) {
    super.didUpdateWidget(oldWidget);
    if ((widget.maxCrossAxisExtent - _endExtent).abs() < 0.1) return;
    _beginExtent = _currentExtent;
    _endExtent = widget.maxCrossAxisExtent;
    if (widget.extentListenable != null ||
        MediaQuery.disableAnimationsOf(context)) {
      _controller.value = 1;
    } else {
      // The extent sets the column count, so it must not overshoot and
      // flip the columns twice: Material's standard spatial spring and
      // Mornye's fast spring both stop at it. It goes on from the extent on
      // screen.
      final motion = context.isMornye
          ? MornyeMotion.fast
          : AppMotion.materialPage;
      _curve.curve = motion.curve;
      _controller
        ..duration = motion.duration
        ..forward(from: 0);
    }
  }

  double get _currentExtent =>
      _beginExtent + ((_endExtent - _beginExtent) * _curve.value);

  @override
  void dispose() {
    _curve.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final extentListenable = widget.extentListenable;
    if (extentListenable != null) {
      return ValueListenableBuilder<double>(
        valueListenable: extentListenable,
        builder: (context, extent, child) => _grid(
          (extent * widget.extentScale).clamp(
            widget.minExtent ?? 0,
            widget.maxExtent ?? double.infinity,
          ),
        ),
      );
    }
    if (MediaQuery.disableAnimationsOf(context)) {
      return _grid(widget.maxCrossAxisExtent);
    }
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) => _grid(_currentExtent),
    );
  }

  Widget _grid(double extent) => SliverGrid(
    gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
      maxCrossAxisExtent: extent,
      mainAxisSpacing: widget.mainAxisSpacing,
      crossAxisSpacing: widget.crossAxisSpacing,
      childAspectRatio: widget.childAspectRatio,
    ),
    delegate: widget.delegate,
  );
}
