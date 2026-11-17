import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/rendering.dart';
import 'package:liquid_glass_easy/liquid_glass_easy.dart';
import 'package:mornye/theme/app_motion.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/widgets/mornye_liquid_backdrop.dart';

Future<ui.FragmentProgram>? _selectionMaskProgram;
ui.FragmentProgram? _loadedSelectionMaskProgram;
const _heldWidthGrowth = 0.28;
const _heldHeightGrowth = 0.24;
const _pillRadius = 32.0;

/// Selection with a transient lens over the fixed-size foreground while held.
/// It refracts both the bar's backdrop and its icons, rendered only once.
class MornyeSelectionPill extends StatefulWidget {
  const MornyeSelectionPill({
    super.key,
    required this.labels,
    required this.selectedIndex,
    required this.onChanged,
    required this.itemBuilder,
    this.padding = const EdgeInsets.all(4),
    this.liquidInteraction = false,
    this.contrastBlocked,
    this.selectionColor,
    this.maskItemForeground = true,
    this.interactionBuilder,
  });

  final List<String> labels;
  final int selectedIndex;
  final ValueChanged<int> onChanged;
  final Widget Function(BuildContext context, int index, bool selected)
  itemBuilder;
  final EdgeInsets padding;
  final bool liquidInteraction;

  /// The parent's glass contrast policy, including an explicit user override.
  /// Standalone controls respect the system contrast request by default.
  final bool? contrastBlocked;

  /// Recolors the foreground under the moving pill instead of switching an
  /// entire item at a tab boundary. Builders receive `selected: false` in this
  /// mode so the unmasked foreground retains its normal color.
  final Color? selectionColor;
  final bool maskItemForeground;

  /// Lets the bar animate its glass behind the fixed-size foreground using the
  /// same press/release animation as the selection lens.
  final Widget Function(BuildContext context, double progress, Widget child)?
  interactionBuilder;

  @override
  State<MornyeSelectionPill> createState() => _MornyeSelectionPillState();
}

class _MornyeSelectionPillState extends State<MornyeSelectionPill>
    with TickerProviderStateMixin {
  int? _dragIndex;
  bool _dragCancelled = false;
  bool _pressed = false;
  int? _pressedIndex;
  double? _dragAlignment;
  int? _activePointer;
  final _foregroundKey = GlobalKey();

  /// How far the held lens has swollen, on the fast spring.
  late final AnimationController _press = AnimationController.unbounded(
    vsync: this,
  )..addListener(() => setState(() {}));

  /// Where the pill stands, as a directional alignment. A drag places it
  /// under the finger; otherwise the snappy spring carries it to its slot,
  /// starting from the finger's velocity on release and from its own
  /// velocity when a new selection interrupts it.
  late final AnimationController _slide = AnimationController.unbounded(
    vsync: this,
    value: _slotAlignment(widget.selectedIndex),
  );

  /// The slot the pill is moving to, or null after a drag placed it.
  double? _slideTarget;

  /// The finger's velocity, in alignment units a second, for the next move.
  double? _releaseVelocity;
  bool _slideShown = false;
  ui.FragmentProgram? _maskProgram;
  Widget? _items;
  int? _itemsSelected;

  @override
  void initState() {
    super.initState();
    _slideTarget = _slide.value;
    _slideShown =
        widget.selectedIndex >= 0 &&
        widget.selectedIndex < widget.labels.length;
    if (widget.selectionColor != null) unawaited(_loadMaskProgram());
  }

  double _slotAlignment(int index) {
    final count = widget.labels.length;
    return count <= 1 ? 0 : -1 + 2 * index / (count - 1);
  }

  void _animatePress(double target) {
    _press.animateWith(
      SpringSimulation(
        MornyeMotion.fastSpring,
        _press.value,
        target,
        _press.velocity,
        snapToEnd: true,
      ),
    );
  }

  /// Sends the pill to [selected]'s slot unless a drag holds it. Runs during
  /// build, after the parent has applied a new selection, so a released pill
  /// never heads for the old slot first.
  void _followSelection(int selected, int count) {
    if (_dragAlignment != null) return;
    final shown = selected >= 0 && selected < count;
    final target = _slotAlignment(selected);
    final velocity = _releaseVelocity;
    _releaseVelocity = null;
    if (!shown || !_slideShown || MediaQuery.disableAnimationsOf(context)) {
      _slideShown = shown;
      _slideTarget = target;
      if (_slide.value != target) _slide.value = target;
      return;
    }
    if (target == _slideTarget && velocity == null) return;
    _slideTarget = target;
    _slide.animateWith(
      SpringSimulation(
        MornyeMotion.snappySpring,
        _slide.value,
        target,
        velocity ?? _slide.velocity,
        snapToEnd: true,
      ),
    );
  }

  /// The pill's alignment on screen. It may bounce between slots, but stops
  /// at the ends of the bar rather than running past them.
  double get _shownAlignment => _slide.value.clamp(-1.0, 1.0);

  Future<void> _loadMaskProgram() async {
    try {
      final program =
          _loadedSelectionMaskProgram ??
          await (_selectionMaskProgram ??= ui.FragmentProgram.fromAsset(
            'assets/shaders/mornye_selection_mask.frag',
          ));
      _loadedSelectionMaskProgram = program;
      if (mounted) setState(() => _maskProgram = program);
    } catch (error) {
      debugPrint('Mornye selection mask unavailable: $error');
    }
  }

  @override
  void dispose() {
    _press.dispose();
    _slide.dispose();
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _items = null;
  }

  @override
  void didUpdateWidget(MornyeSelectionPill oldWidget) {
    super.didUpdateWidget(oldWidget);
    _items = null;
    if (oldWidget.selectionColor == null && widget.selectionColor != null) {
      unawaited(_loadMaskProgram());
    }
    if (oldWidget.labels.length != widget.labels.length ||
        oldWidget.selectedIndex != widget.selectedIndex) {
      _dragIndex = null;
      _dragAlignment = null;
      _pressedIndex = null;
    }
  }

  void _preview(double x, double width) {
    if (width <= 0 || widget.labels.isEmpty) return;
    final visual = (x / width * widget.labels.length).floor().clamp(
      0,
      widget.labels.length - 1,
    );
    final logical = Directionality.of(context) == TextDirection.rtl
        ? widget.labels.length - 1 - visual
        : visual;
    final halfItem = width / widget.labels.length / 2;
    final position = width <= halfItem * 2
        ? 0.0
        : ((x.clamp(halfItem, width - halfItem) - halfItem) /
                      (width - 2 * halfItem)) *
                  2 -
              1;
    final alignment = Directionality.of(context) == TextDirection.rtl
        ? -position
        : position;
    setState(() {
      _dragIndex = logical;
      _dragAlignment = alignment;
    });
    _slideTarget = null;
    _slide.value = alignment;
  }

  /// The pill's velocity for a horizontal finger [velocity] in pixels a
  /// second across a bar [width] wide: [_preview] spreads the travel between
  /// the first and last slot centers over two alignment units.
  double _alignmentVelocity(double velocity, double width) {
    final travel = width * (1 - 1 / widget.labels.length);
    if (travel <= 0) return 0;
    final rtl = Directionality.of(context) == TextDirection.rtl;
    return velocity * 2 / travel * (rtl ? -1 : 1);
  }

  @override
  Widget build(BuildContext context) {
    final count = widget.labels.length;
    if (count == 0) return const SizedBox.shrink();
    final selected = _dragIndex ?? _pressedIndex ?? widget.selectedIndex;
    _followSelection(selected, count);
    final scheme = Theme.of(context).colorScheme;
    final lensEnabled =
        widget.liquidInteraction &&
        ui.ImageFilter.isShaderFilterSupported &&
        !MediaQuery.disableAnimationsOf(context) &&
        !(widget.contrastBlocked ?? MediaQuery.highContrastOf(context));
    final pressProgress = lensEnabled ? _press.value.clamp(0.0, 1.0) : 0.0;
    final restingOpacity = 1 - pressProgress;
    final content = Listener(
      // An accepted drag can end with a PointerCancelEvent. Do not navigate
      // when the OS interrupts the gesture (e.g. opening system controls).
      onPointerDown: (event) {
        if (_activePointer != null) return;
        _activePointer = event.pointer;
        _dragCancelled = false;
        if (!lensEnabled || _pressed) return;
        final box = context.findRenderObject()! as RenderBox;
        final width = box.size.width - widget.padding.horizontal;
        if (width <= 0) return;
        final visual =
            ((event.localPosition.dx - widget.padding.left) / width * count)
                .floor()
                .clamp(0, count - 1);
        setState(() {
          _pressed = true;
          _pressedIndex = Directionality.of(context) == TextDirection.rtl
              ? count - visual - 1
              : visual;
        });
        _animatePress(1);
      },
      onPointerUp: (event) {
        if (event.pointer != _activePointer) return;
        _activePointer = null;
        _animatePress(0);
        setState(() {
          _pressed = false;
          _pressedIndex = null;
          _dragAlignment = null;
        });
      },
      onPointerCancel: (event) {
        if (event.pointer != _activePointer) return;
        _activePointer = null;
        _animatePress(0);
        setState(() {
          _dragCancelled = true;
          _pressed = false;
          _pressedIndex = null;
          _dragAlignment = null;
        });
      },
      child: Padding(
        padding: widget.padding,
        child: LayoutBuilder(
          builder: (context, constraints) => GestureDetector(
            behavior: HitTestBehavior.opaque,
            onHorizontalDragStart: (event) =>
                _preview(event.localPosition.dx, constraints.maxWidth),
            onHorizontalDragUpdate: (event) =>
                _preview(event.localPosition.dx, constraints.maxWidth),
            onHorizontalDragEnd: (details) {
              final index = _dragIndex;
              setState(() {
                _dragIndex = null;
                _dragAlignment = null;
                // The pill leaves the finger at the finger's speed.
                _releaseVelocity = _alignmentVelocity(
                  details.velocity.pixelsPerSecond.dx,
                  constraints.maxWidth,
                );
              });
              if (index != null && !_dragCancelled) widget.onChanged(index);
            },
            onHorizontalDragCancel: () => setState(() {
              _dragIndex = null;
              _dragAlignment = null;
            }),
            child: Stack(
              fit: StackFit.passthrough,
              clipBehavior: Clip.none,
              children: [
                if (selected >= 0 && selected < count)
                  Positioned.fill(
                    child: IgnorePointer(
                      child: AnimatedBuilder(
                        animation: _slide,
                        builder: (context, child) => Align(
                          alignment: AlignmentDirectional(_shownAlignment, 0),
                          child: child,
                        ),
                        child: FractionallySizedBox(
                          widthFactor: 1 / count,
                          heightFactor: 1,
                          // Share the lens outline while fading into it. A
                          // fixed resting pill leaves a second capsule inside
                          // the held glass, especially during release.
                          child: Transform.scale(
                            scaleX: 1 + _heldWidthGrowth * pressProgress,
                            scaleY: 1 + _heldHeightGrowth * pressProgress,
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                color: scheme.onSurface.withValues(
                                  alpha:
                                      restingOpacity *
                                      (scheme.brightness == Brightness.dark
                                          ? 0.12
                                          : 0.08),
                                ),
                                borderRadius: BorderRadius.circular(
                                  _pillRadius,
                                ),
                                border: MornyeTheme.glassOutlinesOf(context)
                                    ? Border.all(
                                        color: scheme.onSurface.withValues(
                                          alpha: 0.05 * restingOpacity,
                                        ),
                                        width: 0.5,
                                      )
                                    : null,
                                boxShadow: [
                                  BoxShadow(
                                    color: Colors.black.withValues(
                                      alpha: 0.08 * restingOpacity,
                                    ),
                                    blurRadius: 1,
                                    offset: const Offset(0, 0.5),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                _foreground(
                  selected,
                  count,
                  pressProgress,
                  _buildItems(selected),
                ),
                // The lens must sample the foreground as well as the page.
                // Below the icons it would look like a rim on a flat backdrop.
                if (lensEnabled && selected >= 0 && selected < count)
                  _interactionLens(selected, count, pressProgress),
              ],
            ),
          ),
        ),
      ),
    );
    return widget.interactionBuilder?.call(context, pressProgress, content) ??
        content;
  }

  Widget _buildItems(int selected) {
    // Masked foreground keeps the same icons and labels during a press or
    // drag. Only its shader scope and the lens depend on that animation.
    final itemSelection = widget.selectionColor == null ? selected : null;
    if (_itemsSelected != itemSelection) _items = null;
    _itemsSelected = itemSelection;
    return _items ??= Row(
      key: _foregroundKey,
      children: [
        for (var index = 0; index < widget.labels.length; index++)
          Expanded(
            child: Semantics(
              button: true,
              selected: index == widget.selectedIndex,
              label: widget.labels[index],
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  borderRadius: BorderRadius.circular(_pillRadius),
                  // The moving pill supplies press feedback. An ink highlight
                  // would leave a colored patch where the drag started.
                  splashFactory: widget.selectionColor == null
                      ? null
                      : NoSplash.splashFactory,
                  highlightColor: widget.selectionColor == null
                      ? null
                      : Colors.transparent,
                  onTap: () => widget.onChanged(index),
                  child: ExcludeSemantics(
                    child: _item(context, index, selected),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _item(BuildContext context, int index, int selected) {
    final child = widget.itemBuilder(
      context,
      index,
      widget.selectionColor == null && index == selected,
    );
    return widget.maskItemForeground
        ? MornyeSelectionForeground(child: child)
        : child;
  }

  Widget _foreground(
    int selected,
    int count,
    double pressProgress,
    Widget child,
  ) {
    final color = widget.selectionColor;
    if (color == null) return child;
    return AnimatedBuilder(
      animation: _slide,
      builder: (context, child) => _SelectionForegroundScope(
        rowKey: _foregroundKey,
        alignment: Directionality.of(context) == TextDirection.rtl
            ? -_shownAlignment
            : _shownAlignment,
        count: count,
        scaleX: 1 + _heldWidthGrowth * pressProgress,
        scaleY: 1 + _heldHeightGrowth * pressProgress,
        program: _maskProgram,
        color: selected >= 0 && selected < count
            ? color
            : color.withValues(alpha: 0),
        child: child!,
      ),
      child: child,
    );
  }

  Widget _interactionLens(
    int selected,
    int count,
    double progress,
  ) => Positioned.fill(
    child: IgnorePointer(
      child: AnimatedBuilder(
        animation: _slide,
        builder: (context, child) => Align(
          alignment: AlignmentDirectional(_shownAlignment, 0),
          child: child,
        ),
        child: FractionallySizedBox(
          widthFactor: 1 / count,
          heightFactor: 1,
          child: Transform.scale(
            scaleX: 1 + _heldWidthGrowth * progress,
            scaleY: 1 + _heldHeightGrowth * progress,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(_pillRadius),
              child: LiquidGlassBatch.exclude(
                child: MornyeLiquidBackdrop(
                  borderRadius: BorderRadius.circular(_pillRadius),
                  clarity: 1,
                  interaction: true,
                  progress: progress,
                  blurSigma: 0,
                  // A broader bevel makes the held lens visible as it crosses
                  // the icons, while leaving its center undistorted.
                  refractionDepth: 0.18,
                  refractionWidth: 18,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(_pillRadius),
                      color: Colors.white.withValues(
                        alpha:
                            progress *
                            (Theme.of(context).brightness == Brightness.light
                                ? 0.24
                                : 0.08),
                      ),
                      border: MornyeTheme.glassOutlinesOf(context)
                          ? Border.all(
                              color: Colors.white.withValues(
                                alpha: 0.6 * progress,
                              ),
                              width: 0.75,
                            )
                          : null,
                    ),
                    child: const SizedBox.expand(),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

/// Paint only icons and labels with the sliding selection color. Badge fills
/// and counters can remain outside this widget and retain their own contrast.
class MornyeSelectionForeground extends StatefulWidget {
  const MornyeSelectionForeground({super.key, required this.child});

  final Widget child;

  @override
  State<MornyeSelectionForeground> createState() =>
      _MornyeSelectionForegroundState();
}

class _MornyeSelectionForegroundState extends State<MornyeSelectionForeground> {
  ui.FragmentProgram? _program;
  ui.FragmentShader? _shader;

  @override
  void dispose() {
    _shader?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scope = context
        .dependOnInheritedWidgetOfExactType<_SelectionForegroundScope>();
    if (scope == null) return widget.child;
    if (_program != scope.program) {
      _shader?.dispose();
      _program = scope.program;
      _shader = _program?.fragmentShader();
    }
    late Rect local;
    late double width;
    late double rowHeight;
    return _SelectionShaderMask(
      maskIntersects: (bounds) {
        // A transparent srcATop source leaves the foreground unchanged.
        if (scope.color.a == 0) return false;
        final row =
            scope.rowKey.currentContext!.findRenderObject()! as RenderBox;
        final box = context.findRenderObject()! as RenderBox;
        width = row.size.width / scope.count;
        rowHeight = row.size.height;
        final left = (scope.alignment + 1) * (row.size.width - width) / 2;
        final lens = Rect.fromCenter(
          center: Offset(left + width / 2, rowHeight / 2),
          width: width * scope.scaleX,
          height: rowHeight * scope.scaleY,
        );
        local = Rect.fromPoints(
          box.globalToLocal(row.localToGlobal(lens.topLeft)),
          box.globalToLocal(row.localToGlobal(lens.bottomRight)),
        );
        // Keep generous AA room, including inverse foreground scaling.
        final padX = 2 * math.max(1.0, local.width / width);
        final padY = 2 * math.max(1.0, local.height / rowHeight);
        return bounds.right >= local.left - padX &&
            bounds.left <= local.right + padX &&
            // The gradient fallback is vertically unbounded.
            (_shader == null ||
                (bounds.bottom >= local.top - padY &&
                    bounds.top <= local.bottom + padY));
      },
      shaderCallback: (bounds) {
        // Use the same rounded, expanding bounds as the glass, including the
        // inverse scale of each icon. A one-tab rectangular mask cuts through
        // the foreground before it reaches the held lens's curved edge.
        final shader = _shader;
        if (shader != null) {
          shader
            ..setFloat(0, local.left)
            ..setFloat(1, local.top)
            ..setFloat(2, local.width)
            ..setFloat(3, local.height)
            ..setFloat(4, local.width / width)
            ..setFloat(5, local.height / rowHeight)
            ..setFloat(6, math.min(_pillRadius, math.min(width, rowHeight) / 2))
            ..setFloat(7, scope.color.r)
            ..setFloat(8, scope.color.g)
            ..setFloat(9, scope.color.b)
            ..setFloat(10, scope.color.a);
          return shader;
        }
        return ui.Gradient.linear(
          Offset(local.left, 0),
          Offset(local.right, 0),
          [scope.color, scope.color],
          null,
          TileMode.decal,
        );
      },
      child: widget.child,
    );
  }
}

class _SelectionShaderMask extends ShaderMask {
  const _SelectionShaderMask({
    required this.maskIntersects,
    required super.shaderCallback,
    required super.child,
  }) : super(blendMode: BlendMode.srcATop);

  final bool Function(Rect) maskIntersects;

  @override
  RenderShaderMask createRenderObject(BuildContext context) =>
      _SelectionRenderShaderMask(
        maskIntersects: maskIntersects,
        shaderCallback: shaderCallback,
      );

  @override
  void updateRenderObject(BuildContext context, RenderShaderMask renderObject) {
    super.updateRenderObject(context, renderObject);
    (renderObject as _SelectionRenderShaderMask).maskIntersects =
        maskIntersects;
  }
}

class _SelectionRenderShaderMask extends RenderShaderMask {
  _SelectionRenderShaderMask({
    required this.maskIntersects,
    required super.shaderCallback,
  }) : super(blendMode: BlendMode.srcATop);

  bool Function(Rect) maskIntersects;

  @override
  void paint(PaintingContext context, Offset offset) {
    final foreground = child;
    if (foreground != null && !maskIntersects(foreground.paintBounds)) {
      // Drop any layer retained from a previous intersecting frame.
      layer = null;
      context.paintChild(foreground, offset);
    } else {
      // The predicate prepared this paint's geometry for shaderCallback.
      super.paint(context, offset);
    }
  }
}

class _SelectionForegroundScope extends InheritedWidget {
  const _SelectionForegroundScope({
    required this.rowKey,
    required this.alignment,
    required this.count,
    required this.scaleX,
    required this.scaleY,
    required this.program,
    required this.color,
    required super.child,
  });

  final GlobalKey rowKey;
  final double alignment;
  final int count;
  final double scaleX;
  final double scaleY;
  final ui.FragmentProgram? program;
  final Color color;

  @override
  bool updateShouldNotify(_SelectionForegroundScope oldWidget) =>
      alignment != oldWidget.alignment ||
      count != oldWidget.count ||
      scaleX != oldWidget.scaleX ||
      scaleY != oldWidget.scaleY ||
      program != oldWidget.program ||
      color != oldWidget.color ||
      rowKey != oldWidget.rowKey;
}
