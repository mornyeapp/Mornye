import 'dart:async';
import 'dart:math' as math;

import 'package:cupertino_ui/cupertino_ui.dart'
    show CupertinoSliverRefreshControl;
import 'package:material_ui/material_ui.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:mornye/theme/material_expressive.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/utils/desktop_platform.dart';

/// Pull-to-refresh with the expressive shape-morphing indicator on Material.
/// Reduced motion keeps Flutter's [RefreshIndicator].
///
/// Mornye phones, whose lists bounce, use the iOS refresh control instead.
/// It is a sliver, so a [CustomScrollView] under this widget places
/// [AppRefreshIndicator.sliver] right after its large title. Mornye on
/// desktop, or with bouncing off (low-end phones), keeps [RefreshIndicator].
///
/// The page on screen also refreshes through [refreshVisible], which the
/// desktop Refresh command (Cmd/Ctrl+R) runs.
class AppRefreshIndicator extends StatefulWidget {
  const AppRefreshIndicator({
    super.key,
    required this.onRefresh,
    required this.child,
    this.notificationPredicate = defaultScrollNotificationPredicate,
  });

  final RefreshCallback onRefresh;
  final ScrollNotificationPredicate notificationPredicate;
  final Widget child;

  static final _mounted = <_AppRefreshIndicatorState>[];

  /// The iOS refresh control where the enclosing [AppRefreshIndicator]
  /// uses it, and an empty sliver elsewhere. [enabled] false hides it, for
  /// pages whose `notificationPredicate` turns refreshing off.
  static Widget sliver({bool enabled = true}) =>
      _AppRefreshSliver(enabled: enabled);

  /// Refreshes the most recently opened page that is on screen, showing its
  /// indicator. Returns whether one was found.
  static bool refreshVisible() {
    for (final state in _mounted.reversed) {
      if (state._onScreen) {
        unawaited(state._show());
        return true;
      }
    }
    return false;
  }

  @override
  State<AppRefreshIndicator> createState() => _AppRefreshIndicatorState();
}

class _AppRefreshIndicatorState extends State<AppRefreshIndicator> {
  final _materialKey = GlobalKey<RefreshIndicatorState>();
  final _expressive = M3ERefreshIndicatorController();
  bool _usesExpressive = false;

  /// While a pull is under way: its status and how far it has pulled.
  M3ERefreshStatus? _status;
  double _pull = 0;

  bool get _onScreen =>
      mounted &&
      TickerMode.valuesOf(context).enabled &&
      (ModalRoute.of(context)?.isCurrent ?? true);

  /// A pull being pushed back shrinks the indicator first; the list only
  /// scrolls once the pull is gone.
  bool _holdsPull() =>
      (_status == M3ERefreshStatus.drag || _status == M3ERefreshStatus.armed) &&
      _pull > 0;

  @override
  void initState() {
    super.initState();
    AppRefreshIndicator._mounted.add(this);
  }

  @override
  void dispose() {
    AppRefreshIndicator._mounted.remove(this);
    super.dispose();
  }

  // The iOS control has no programmatic show; it only runs on phones, which
  // have no Refresh command.
  Future<void> _show() => _usesExpressive
      ? _expressive.show()
      : _materialKey.currentState?.show() ?? widget.onRefresh();

  static bool _bounces(BuildContext context) {
    ScrollPhysics? physics = ScrollConfiguration.of(
      context,
    ).getScrollPhysics(context);
    while (physics != null) {
      if (physics is BouncingScrollPhysics) return true;
      physics = physics.parent;
    }
    return false;
  }

  bool _trackPull(OverscrollNotification notification) {
    final delta = notification.dragDetails?.delta.dy;
    if (_holdsPull() || _status == M3ERefreshStatus.drag) {
      if (delta != null) _pull = math.max(0, _pull + delta);
    }
    return false;
  }

  void _statusChanged(M3ERefreshStatus? status) {
    // A new pull starts from nothing; falling back from armed keeps it.
    if (status == M3ERefreshStatus.drag && _status != M3ERefreshStatus.armed) {
      _pull = 0;
    }
    _status = status;
  }

  @override
  Widget build(BuildContext context) {
    _usesExpressive = materialExpressiveEnabled(context);
    if (context.isMornye && !isDesktopPlatform && _bounces(context)) {
      return _RefreshScope(onRefresh: widget.onRefresh, child: widget.child);
    }
    if (!_usesExpressive) {
      Widget indicator = RefreshIndicator(
        key: _materialKey,
        onRefresh: widget.onRefresh,
        notificationPredicate: widget.notificationPredicate,
        child: widget.child,
      );
      if (_bounces(context)) {
        final behavior = ScrollConfiguration.of(context);
        indicator = ScrollConfiguration(
          behavior: behavior.copyWith(
            physics: _PullEdgeScrollPhysics(
              holdsPull: () => false,
              parent: behavior.getScrollPhysics(context),
            ),
          ),
          child: indicator,
        );
      }
      return indicator;
    }
    Widget indicator = M3ERefreshIndicator.contained(
      controller: _expressive,
      onRefresh: widget.onRefresh,
      notificationPredicate: widget.notificationPredicate,
      onStatusChange: _statusChanged,
      child: NotificationListener<OverscrollNotification>(
        onNotification: _trackPull,
        child: widget.child,
      ),
    );
    // A bounce past the top opens a gap under a pinned header and skips the
    // overscroll the indicator follows, so bouncing lists hold their top edge.
    if (_bounces(context)) {
      final behavior = ScrollConfiguration.of(context);
      indicator = ScrollConfiguration(
        behavior: behavior.copyWith(
          physics: _PullEdgeScrollPhysics(
            holdsPull: _holdsPull,
            parent: behavior.getScrollPhysics(context),
          ),
        ),
        child: indicator,
      );
    }
    return MaterialExpressiveScope(child: indicator);
  }
}

/// Stops the leading edge instead of bouncing past it, and keeps the list
/// at that edge while [holdsPull]. A refused move is reported as overscroll,
/// so the indicator still follows the pointer.
class _PullEdgeScrollPhysics extends ScrollPhysics {
  const _PullEdgeScrollPhysics({required this.holdsPull, super.parent});

  final bool Function() holdsPull;

  @override
  _PullEdgeScrollPhysics applyTo(ScrollPhysics? ancestor) =>
      _PullEdgeScrollPhysics(
        holdsPull: holdsPull,
        parent: buildParent(ancestor),
      );

  @override
  double applyBoundaryConditions(ScrollMetrics position, double value) {
    final min = position.minScrollExtent;
    if (value < position.pixels && position.pixels <= min) {
      return value - position.pixels;
    }
    if (value < min && min < position.pixels) return value - min;
    if (value > position.pixels && position.pixels <= min && holdsPull()) {
      return value - position.pixels;
    }
    return super.applyBoundaryConditions(position, value);
  }
}

/// Hands the refresh callback to [AppRefreshIndicator.sliver] when the iOS
/// refresh control replaces the indicator.
class _RefreshScope extends InheritedWidget {
  const _RefreshScope({required this.onRefresh, required super.child});

  final RefreshCallback onRefresh;

  @override
  bool updateShouldNotify(_RefreshScope oldWidget) =>
      onRefresh != oldWidget.onRefresh;
}

class _AppRefreshSliver extends StatelessWidget {
  const _AppRefreshSliver({required this.enabled});

  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<_RefreshScope>();
    if (scope == null || !enabled) return const SliverToBoxAdapter();
    return CupertinoSliverRefreshControl(onRefresh: scope.onRefresh);
  }
}
