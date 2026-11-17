import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';
import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/scheduler.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:mornye/theme/app_motion.dart';
import 'package:mornye/theme/app_tokens.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:mornye/widgets/desktop/detail_header.dart'
    show desktopDetailBottomInset;
import 'package:mornye/widgets/mornye_chrome.dart';
import 'package:mornye/widgets/app_bottom_sheet.dart';
import 'package:mornye/widgets/expressive_button.dart';
import 'package:mornye/widgets/expressive_icon_button.dart';
import 'package:mornye/l10n/l10n.dart';

/// Hosts selection bars above the shell navigation while keeping modal routes
/// above the bar. A raw entry in the root [Overlay] stays above routes pushed
/// later, which made download pickers appear behind the selection toolbar.
class SelectionOverlayHost extends StatefulWidget {
  const SelectionOverlayHost({super.key, required this.child});

  final Widget child;

  static _SelectionOverlayHostState? _maybeOf(BuildContext context) =>
      context.findAncestorStateOfType<_SelectionOverlayHostState>();

  @override
  State<SelectionOverlayHost> createState() => _SelectionOverlayHostState();
}

class _SelectionOverlayHostState extends State<SelectionOverlayHost> {
  SelectionOverlayController? _owner;
  WidgetBuilder? _builder;

  bool owns(SelectionOverlayController owner) =>
      _owner == owner && _builder != null;

  void show(SelectionOverlayController owner, WidgetBuilder builder) {
    _update(() {
      _owner = owner;
      _builder = builder;
    });
  }

  void hide(SelectionOverlayController owner) {
    if (_owner != owner) return;
    _update(() {
      _owner = null;
      _builder = null;
    });
  }

  /// A screen can remove its bar from dispose while Flutter has locked the
  /// tree. Clear ownership immediately, then rebuild after that frame so the
  /// bar cannot outlive the screen or retain its disposed callbacks.
  void _update(VoidCallback change) {
    if (!mounted) return;
    if (SchedulerBinding.instance.schedulerPhase !=
        SchedulerPhase.persistentCallbacks) {
      setState(change);
      return;
    }
    change();
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  Widget build(BuildContext context) {
    final owner = _owner;
    final builder = _builder;
    // A root modal makes the shell route non-current. Removing the toolbar
    // while that route is covered both prevents visual overlap and avoids the
    // hidden toolbar intercepting taps during the modal transition. The stored
    // builder is kept so the selection returns if the modal is dismissed.
    final routeIsCurrent = ModalRoute.of(context)?.isCurrent ?? true;
    return Stack(
      fit: StackFit.expand,
      children: [
        widget.child,
        if (routeIsCurrent && owner != null && builder != null)
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: KeyedSubtree(
              key: ObjectKey(owner),
              child: AnimatedSelectionBottomBar(
                child: Material(
                  color: Colors.transparent,
                  child: Builder(builder: builder),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// Mounts a selection bar in [SelectionOverlayHost]. Screens rendered outside
/// the main shell (including isolated widget tests) retain a root-overlay
/// fallback.
class SelectionOverlayController {
  OverlayEntry? _entry;
  _SelectionOverlayHostState? _host;
  WidgetBuilder? _builder;

  bool get isVisible => _entry != null || (_host?.owns(this) ?? false);

  /// Shows the bar, or rebuilds it in place when already visible so the
  /// entrance animation does not replay on every selection change.
  void show(BuildContext context, WidgetBuilder builder) {
    if (!TickerMode.valuesOf(context).enabled) {
      hide();
      return;
    }

    _builder = builder;
    final host = SelectionOverlayHost._maybeOf(context);
    if (host != null) {
      _entry?.remove();
      _entry = null;
      if (_host != null && _host != host) {
        _host!.hide(this);
      }
      _host = host;
      host.show(this, builder);
      return;
    }

    _host?.hide(this);
    _host = null;
    if (_entry != null) {
      _entry!.markNeedsBuild();
      return;
    }
    _entry = OverlayEntry(
      builder: (overlayContext) => Positioned(
        left: 0,
        right: 0,
        bottom: 0,
        child: AnimatedSelectionBottomBar(
          child: Material(
            color: Colors.transparent,
            child: _builder!(overlayContext),
          ),
        ),
      ),
    );
    Overlay.of(context, rootOverlay: true).insert(_entry!);
  }

  void hide() {
    _host?.hide(this);
    _host = null;
    _entry?.remove();
    _entry = null;
    _builder = null;
  }

  /// Call from the host `State.dispose`; an entry left in the root overlay
  /// outlives the screen that created it.
  void dispose() => hide();
}

/// Entrance animation shared by selection bars mounted in the root overlay.
class AnimatedSelectionBottomBar extends StatefulWidget {
  const AnimatedSelectionBottomBar({super.key, required this.child});

  final Widget child;

  @override
  State<AnimatedSelectionBottomBar> createState() =>
      _AnimatedSelectionBottomBarState();
}

class _AnimatedSelectionBottomBarState extends State<AnimatedSelectionBottomBar>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<Offset> _slideAnimation;
  late final Animation<double> _fadeAnimation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_controller.duration != null) return;
    // The bar rises into place on the spatial spring while it fades in on
    // the effects spring, each over its own length. Reduced motion keeps
    // the fade alone.
    final slide = AppMotion.spatial(
      context,
      const AppMotionSpec(Duration.zero, Curves.linear),
      mornye: MornyeMotion.standard,
    );
    final fade = AppMotion.effects(
      context,
      const AppMotionSpec(Duration(milliseconds: 240), Curves.easeOutCubic),
    );
    final length = slide.duration > fade.duration
        ? slide.duration
        : fade.duration;
    Curve within(AppMotionSpec motion) => motion.duration == Duration.zero
        ? const Threshold(0)
        : Interval(
            0,
            motion.duration.inMicroseconds / length.inMicroseconds,
            curve: motion.curve,
          );
    _controller.duration = length;
    _slideAnimation = Tween<Offset>(
      begin: slide.duration == Duration.zero
          ? Offset.zero
          : const Offset(0, 0.08),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _controller, curve: within(slide)));
    _fadeAnimation = Tween<double>(
      begin: 0,
      end: 1,
    ).animate(CurvedAnimation(parent: _controller, curve: within(fade)));
    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _fadeAnimation,
      child: SlideTransition(position: _slideAnimation, child: widget.child),
    );
  }
}

/// Shared chrome for the multi-select bottom bar: rounded surface, drag
/// handle, close button, "N selected" header and select-all toggle.
/// The screen-specific action buttons go in [children].
class SelectionBottomBar extends StatelessWidget {
  const SelectionBottomBar({
    super.key,
    required this.selectedCount,
    required this.allSelected,
    required this.onClose,
    required this.onToggleSelectAll,
    required this.bottomPadding,
    required this.children,
    this.allSelectedLabel,
    this.tapToSelectLabel,
  });

  final int selectedCount;
  final bool allSelected;
  final VoidCallback onClose;
  final VoidCallback onToggleSelectAll;
  final double bottomPadding;
  final List<Widget> children;

  /// Overrides the default "All tracks selected" subtitle.
  final String? allSelectedLabel;

  /// Overrides the default "Tap tracks to select" subtitle.
  final String? tapToSelectLabel;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final colorScheme = Theme.of(context).colorScheme;

    final header = LayoutBuilder(
      builder: (context, constraints) => Row(
        children: [
          if (context.isMornye)
            Tooltip(
              message: MaterialLocalizations.of(context).closeButtonTooltip,
              child: CupertinoButton(
                color: MornyeTheme.controlFill(context),
                borderRadius: BorderRadius.circular(28),
                padding: const EdgeInsets.all(12),
                onPressed: onClose,
                child: Icon(
                  CupertinoIcons.xmark,
                  color: colorScheme.onSurface,
                  size: 24,
                ),
              ),
            )
          else
            ExpressiveIconButton(
              onPressed: onClose,
              tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
              icon: const Icon(Icons.close),
              foregroundColor: colorScheme.onSecondaryContainer,
              backgroundColor: colorScheme.surfaceContainerHighest,
            ),
          const SizedBox(width: 12),

          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  context.l10n.selectionSelected(selectedCount),
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                // The tap hint describes touch selection; desktop rows select
                // with the pointer and modifiers, and the toolbar stays short.
                if (!isDesktopPlatform)
                  Text(
                    allSelected
                        ? allSelectedLabel ?? context.l10n.selectionAllSelected
                        : tapToSelectLabel ??
                              context.l10n.downloadedAlbumTapToSelect,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
          ),

          ConstrainedBox(
            constraints: BoxConstraints(maxWidth: constraints.maxWidth * 0.4),
            child: context.isMornye
                ? CupertinoButton(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    onPressed: onToggleSelectAll,
                    child: Text(
                      allSelected
                          ? context.l10n.actionDeselect
                          : context.l10n.actionSelectAll,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: colorScheme.primary,
                      ),
                    ),
                  )
                : ExpressiveButton(
                    text: true,
                    onPressed: onToggleSelectAll,
                    icon: Icon(
                      allSelected ? Icons.deselect : Icons.select_all,
                      size: 20,
                    ),
                    style: TextButton.styleFrom(
                      foregroundColor: colorScheme.primary,
                    ),
                    child: Text(
                      allSelected
                          ? context.l10n.actionDeselect
                          : context.l10n.actionSelectAll,
                    ),
                  ),
          ),
        ],
      ),
    );
    const floatingMargin = 12.0;
    Widget surface(Widget content) {
      if (context.isMornye) {
        return MornyeGlassPanel.overlay(child: content);
      }
      final toolbar = Material(
        color: colorScheme.surfaceContainerHigh,
        surfaceTintColor: Colors.transparent,
        shadowColor: colorScheme.shadow,
        elevation: 3,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(tokens.radiusSheet),
        ),
        clipBehavior: Clip.antiAlias,
        child: MediaQuery.removePadding(
          context: context,
          removeBottom: true,
          child: content,
        ),
      );
      if (isDesktopPlatform) {
        // No navigation bar sits under a desktop page, so the toolbar
        // floats on its own without the backdrop.
        return Padding(
          padding: const EdgeInsets.all(floatingMargin),
          child: toolbar,
        );
      }
      // Expressive floating toolbar: detached from the screen edges and
      // fully rounded. The faded backdrop hides and blocks the navigation
      // bar underneath, so a tap beside the toolbar cannot switch tabs.
      final backdrop = colorScheme.surface;
      return Listener(
        behavior: HitTestBehavior.opaque,
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [backdrop.withValues(alpha: 0), backdrop],
              stops: const [0, 0.4],
            ),
          ),
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              floatingMargin,
              0,
              floatingMargin,
              floatingMargin + MediaQuery.viewPaddingOf(context).bottom,
            ),
            child: toolbar,
          ),
        ),
      );
    }

    if (!isDesktopPlatform) {
      return _SelectionPanelDrag(
        onClose: onClose,
        header: header,
        bottomPadding: bottomPadding,
        floatingMargin: context.isMornye ? 0 : floatingMargin,
        surfaceBuilder: surface,
        children: children,
      );
    }
    // Desktop: a bounded toolbar over the page, clear of Mornye's floating
    // player, rather than a sheet across the whole pane. There is no drag
    // handle, since pointer input has no gesture to tuck the actions away;
    // the close button ends the selection.
    return Align(
      alignment: Alignment.bottomCenter,
      heightFactor: 1,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640),
        child: Padding(
          padding: EdgeInsets.only(
            bottom: context.isMornye ? desktopDetailBottomInset : 0,
          ),
          child: surface(
            ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.sizeOf(context).height * 0.6,
              ),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    header,
                    Flexible(
                      child: SingleChildScrollView(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [const SizedBox(height: 12), ...children],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Keeps selection alive when the actions are tucked away. One downward
/// gesture collapses the actions; only a new gesture on the compact header
/// dismisses selection. Action scrolling never hides the header.
class _SelectionPanelDrag extends StatefulWidget {
  const _SelectionPanelDrag({
    required this.onClose,
    required this.header,
    required this.bottomPadding,
    required this.children,
    required this.surfaceBuilder,
    this.floatingMargin = 0,
  });

  final VoidCallback onClose;
  final Widget header;
  final double bottomPadding;

  /// Bottom margin the surface already places below a floating panel. The
  /// content gives up the same space so the panel keeps its docked height.
  final double floatingMargin;
  final List<Widget> children;
  final Widget Function(Widget) surfaceBuilder;

  @override
  State<_SelectionPanelDrag> createState() => _SelectionPanelDragState();
}

class _SelectionPanelDragState extends State<_SelectionPanelDrag>
    with TickerProviderStateMixin {
  // Bounded below: a panel returning with the finger's velocity stops at
  // its place instead of rising past it.
  late final AnimationController _offset = AnimationController(
    vsync: this,
    upperBound: double.infinity,
    animationBehavior: AnimationBehavior.preserve,
  );
  late final _SelectionPanelScrollController _scroll =
      _SelectionPanelScrollController(_drag, _settle);
  late final AnimationController _expansion = AnimationController(
    vsync: this,
    value: 1,
    duration: const Duration(milliseconds: 220),
  );
  final _actionsKey = GlobalKey();
  bool _expanded = true;
  bool? _dragFromExpanded;
  double _pull = 0;
  double _actionHeight = 1;
  bool _closing = false;

  double _drag(double delta) {
    if (_closing) return 0;
    if (_dragFromExpanded == null) {
      if (_expanded && _expansion.value == 1 && delta <= 0) return delta;
      _dragFromExpanded = _expanded;
      _actionHeight = (_actionsKey.currentContext?.size?.height ?? 1).clamp(
        1.0,
        double.infinity,
      );
      _pull = _expanded
          ? (1 - _expansion.value) * _actionHeight
          : _offset.value - _expansion.value * _actionHeight;
    }
    _offset.stop();
    _expansion.stop();
    if (_dragFromExpanded!) {
      final previous = _pull;
      _pull = (_pull + delta).clamp(0.0, _actionHeight);
      _expansion.value = 1 - _pull / _actionHeight;
      // A single pull can reach the compact state, but cannot cancel it.
      return delta < 0 ? delta - (_pull - previous) : 0;
    }
    _pull = (_pull + delta).clamp(-_actionHeight, double.infinity);
    _expansion.value = (-_pull / _actionHeight).clamp(0.0, 1.0);
    _offset.value = _pull.clamp(0.0, double.infinity);
    return 0;
  }

  bool _settle(double velocity) {
    if (_closing) return true;
    final fromExpanded = _dragFromExpanded;
    if (fromExpanded == null) return false;
    _dragFromExpanded = null;
    final threshold = (_actionHeight * 0.25).clamp(64.0, 120.0);
    if (fromExpanded) {
      final collapse =
          velocity > 700 || (velocity >= -700 && _pull >= threshold);
      _setExpanded(!collapse, velocity: velocity);
      return true;
    }
    if (_pull < 0) {
      final expand =
          velocity < -700 || (velocity <= 700 && -_pull >= threshold);
      _setExpanded(expand, velocity: velocity);
      return true;
    }
    final height = context.size?.height ?? 0;
    _closing =
        velocity > 700 ||
        (velocity >= -700 && _offset.value >= (height * 0.25).clamp(64, 120));
    _animateToRest(_closing ? height : 0, velocity: velocity);
    return true;
  }

  /// The style's slow spatial spring, critically damped in both styles.
  SpringDescription get _spring => context.isMornye
      ? MornyeMotion.slowSpring
      : M3EMotion.expressiveSpatialSlow.toDescription();

  /// Tucks the actions away or brings them back. A drag hands over its
  /// [velocity] in pixels a second, downward positive; otherwise the
  /// expansion goes on from its own velocity.
  void _setExpanded(bool expanded, {double? velocity}) {
    setState(() => _expanded = expanded);
    if (!expanded && _scroll.hasClients) _scroll.jumpTo(0);
    final target = expanded ? 1.0 : 0.0;
    if (MediaQuery.disableAnimationsOf(context)) {
      _expansion.value = target;
    } else {
      _expansion.animateWith(
        SpringSimulation(
          _spring,
          _expansion.value,
          target,
          // A downward drag closes the actions by its share of their height.
          velocity == null ? _expansion.velocity : -velocity / _actionHeight,
          snapToEnd: true,
        ),
      );
    }
    _animateToRest(0);
  }

  void _toggleExpanded() {
    if (_closing) return;
    _dragFromExpanded = null;
    _setExpanded(!_expanded);
  }

  void _cancelDrag() {
    final fromExpanded = _dragFromExpanded;
    _dragFromExpanded = null;
    if (fromExpanded != null) _setExpanded(fromExpanded);
  }

  /// Moves the panel back to its place on the slow spring, from the drag's
  /// [velocity] when one hands over, or off the screen when closing: a
  /// short eased exit, faster than any drag that ends it.
  Future<void> _animateToRest(double target, {double? velocity}) async {
    try {
      if (_closing) {
        await _offset
            .animateTo(
              target,
              duration: const Duration(milliseconds: 180),
              curve: Curves.easeOutCubic,
            )
            .orCancel;
      } else if (MediaQuery.disableAnimationsOf(context)) {
        _offset.value = target;
      } else {
        await _offset
            .animateWith(
              SpringSimulation(
                _spring,
                _offset.value,
                target,
                velocity ?? _offset.velocity,
                snapToEnd: true,
              ),
            )
            .orCancel;
      }
      if (mounted && _closing) widget.onClose();
    } on TickerCanceled {
      // Another drag or route disposal can interrupt the settling animation.
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    _offset.dispose();
    _expansion.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _offset,
    builder: (_, child) =>
        Transform.translate(offset: Offset(0, _offset.value), child: child),
    child: widget.surfaceBuilder(
      ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.72,
        ),
        child: SafeArea(
          top: false,
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              16,
              16,
              16,
              math.max(
                0,
                (widget.bottomPadding > 0 ? 8 : 16) - widget.floatingMargin,
              ),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onVerticalDragUpdate: (details) => _drag(details.delta.dy),
                  onVerticalDragEnd: (details) =>
                      _settle(details.primaryVelocity ?? 0),
                  onVerticalDragCancel: _cancelDrag,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Semantics(
                        container: true,
                        button: true,
                        expanded: _expanded,
                        label: _expanded
                            ? MaterialLocalizations.of(
                                context,
                              ).expandedIconTapHint
                            : MaterialLocalizations.of(
                                context,
                              ).collapsedIconTapHint,
                        onTap: _toggleExpanded,
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          excludeFromSemantics: true,
                          onTap: _toggleExpanded,
                          child: const SizedBox(
                            height: 32,
                            child: AppSheetHandle(margin: EdgeInsets.zero),
                          ),
                        ),
                      ),
                      widget.header,
                    ],
                  ),
                ),
                Flexible(
                  child: ExcludeSemantics(
                    excluding: !_expanded,
                    child: IgnorePointer(
                      ignoring: !_expanded,
                      child: SizeTransition(
                        sizeFactor: _expansion,
                        alignment: Alignment.topCenter,
                        child: SingleChildScrollView(
                          key: _actionsKey,
                          controller: _scroll,
                          physics: const AlwaysScrollableScrollPhysics(
                            parent: ClampingScrollPhysics(),
                          ),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const SizedBox(height: 12),
                              ...widget.children,
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

class _SelectionPanelScrollController extends ScrollController {
  _SelectionPanelScrollController(this.dragPanel, this.settlePanel);

  final double Function(double) dragPanel;
  final bool Function(double) settlePanel;

  @override
  ScrollPosition createScrollPosition(
    ScrollPhysics physics,
    ScrollContext context,
    ScrollPosition? oldPosition,
  ) => _SelectionPanelScrollPosition(
    physics: physics,
    context: context,
    oldPosition: oldPosition,
    dragPanel: dragPanel,
    settlePanel: settlePanel,
  );
}

class _SelectionPanelScrollPosition extends ScrollPositionWithSingleContext {
  _SelectionPanelScrollPosition({
    required super.physics,
    required super.context,
    super.oldPosition,
    required this.dragPanel,
    required this.settlePanel,
  });

  final double Function(double) dragPanel;
  final bool Function(double) settlePanel;

  @override
  void applyUserOffset(double delta) {
    // Scroll back to the top before handing any remaining drag to the panel.
    if (delta > 0 && pixels > minScrollExtent) {
      final scrollDelta = delta.clamp(0.0, pixels - minScrollExtent);
      super.applyUserOffset(scrollDelta);
      delta -= scrollDelta;
    }
    final remaining = dragPanel(delta);
    if (remaining != 0) super.applyUserOffset(remaining);
  }

  @override
  void goBallistic(double velocity) {
    final movingPanel = settlePanel(-velocity);
    super.goBallistic(movingPanel ? 0 : velocity);
  }
}
