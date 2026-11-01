import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/utils/android_tv.dart';

/// Keeps the touch behavior while making cover tiles reachable by a remote.
class TvTapTarget extends StatelessWidget {
  const TvTapTarget({
    super.key,
    required this.child,
    this.onTap,
    this.onLongPress,
    this.behavior,
  });

  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final HitTestBehavior? behavior;

  @override
  Widget build(BuildContext context) => TvFocusable(
    onPressed: onTap,
    onMenu: onLongPress,
    child: GestureDetector(
      onTap: onTap,
      onLongPress: onLongPress,
      behavior: behavior,
      child: child,
    ),
  );
}

/// Adds remote activation to a surface that already owns its touch gestures.
class TvFocusable extends StatelessWidget {
  const TvFocusable({
    super.key,
    required this.onPressed,
    required this.child,
    this.onMenu,
  });

  final VoidCallback? onPressed;
  final VoidCallback? onMenu;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!isAndroidTv || onPressed == null) return child;
    return Focus(
      onKeyEvent: (node, event) {
        // A nested play/menu button keeps its own action.
        if (!node.hasPrimaryFocus) return KeyEventResult.ignored;
        final key = event.logicalKey;
        final activate =
            key == LogicalKeyboardKey.select ||
            key == LogicalKeyboardKey.enter ||
            key == LogicalKeyboardKey.gameButtonA ||
            key == LogicalKeyboardKey.space;
        final menu = key == LogicalKeyboardKey.contextMenu && onMenu != null;
        if (!activate && !menu) return KeyEventResult.ignored;
        if (event is KeyDownEvent) (menu ? onMenu : onPressed)?.call();
        return KeyEventResult.handled;
      },
      child: child,
    );
  }
}

/// Shared by every route, including setup, sheets and the full player.
class TvNavigation extends ConsumerStatefulWidget {
  const TvNavigation({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<TvNavigation> createState() => _TvNavigationState();
}

class _TvNavigationState extends ConsumerState<TvNavigation> {
  final _viewportKey = GlobalKey();
  final _idle = FocusNode(debugLabel: 'TV remote', skipTraversal: true);
  final _repaint = ValueNotifier<int>(0);
  bool _repaintPending = false;
  Timer? _focusRecovery;
  Listenable? _routeMotion;

  @override
  void initState() {
    super.initState();
    FocusManager.instance.addListener(_focusChanged);
    _focusChanged();
  }

  void _focusChanged() {
    _scheduleRepaint();
    final focused = FocusManager.instance.primaryFocus;
    final focusedContext = focused?.context;
    _routeMotion?.removeListener(_scheduleRepaint);
    final route = focusedContext == null ? null : ModalRoute.of(focusedContext);
    _routeMotion = Listenable.merge([
      route?.animation,
      route?.secondaryAnimation,
    ]);
    _routeMotion!.addListener(_scheduleRepaint);
    if (focused is FocusScopeNode ||
        focusedContext == null ||
        focused == _idle) {
      _focusRecovery ??= Timer.periodic(const Duration(milliseconds: 100), (_) {
        final primary = FocusManager.instance.primaryFocus;
        if (primary != _idle && primary is! FocusScopeNode && primary != null) {
          _focusRecovery?.cancel();
          _focusRecovery = null;
          return;
        }
        final scope = primary is FocusScopeNode
            ? primary
            : primary?.nearestScope;
        final candidates = scope?.traversalDescendants;
        if (candidates == null) return;
        for (final candidate in candidates) {
          final context = candidate.context;
          if (candidate is FocusScopeNode ||
              candidate == _idle ||
              context == null ||
              context.widget is EditableText ||
              context.findAncestorWidgetOfExactType<EditableText>() != null) {
            continue;
          }
          candidate.requestFocus();
          break;
        }
      });
      return;
    }
    _focusRecovery?.cancel();
    _focusRecovery = null;
    // Directional traversal also requests this for most built-in controls;
    // this covers custom focusable covers and the first item after a route.
    unawaited(
      Scrollable.ensureVisible(
        focusedContext,
        alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
      ),
    );
  }

  void _scheduleRepaint() {
    if (_repaintPending) return;
    _repaintPending = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _repaintPending = false;
      if (mounted) _repaint.value++;
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    final key = event.logicalKey;
    final mediaKey =
        key == LogicalKeyboardKey.mediaPlayPause ||
        key == LogicalKeyboardKey.mediaPlay ||
        key == LogicalKeyboardKey.mediaPause ||
        key == LogicalKeyboardKey.mediaTrackNext ||
        key == LogicalKeyboardKey.mediaTrackPrevious;
    if (mediaKey) {
      if (!ref.read(playerUiEnabledProvider)) return KeyEventResult.ignored;
      if (event is KeyDownEvent) {
        final controller = ref.read(musicPlayerControllerProvider);
        final playing = ref.read(playbackPlayingProvider);
        if (key == LogicalKeyboardKey.mediaTrackNext) {
          unawaited(controller.next());
        } else if (key == LogicalKeyboardKey.mediaTrackPrevious) {
          unawaited(controller.previous());
        } else if (key == LogicalKeyboardKey.mediaPlayPause ||
            key == LogicalKeyboardKey.mediaPlay && !playing ||
            key == LogicalKeyboardKey.mediaPause && playing) {
          unawaited(controller.togglePlayPause(playing));
        }
      }
      return KeyEventResult.handled;
    }

    final directional =
        key == LogicalKeyboardKey.arrowUp ||
        key == LogicalKeyboardKey.arrowDown ||
        key == LogicalKeyboardKey.arrowLeft ||
        key == LogicalKeyboardKey.arrowRight ||
        key == LogicalKeyboardKey.select;
    final focused = FocusManager.instance.primaryFocus;
    if (directional &&
        event is KeyDownEvent &&
        (focused == _idle || focused is FocusScopeNode)) {
      // A page can contain only gesture surfaces, or its previously focused
      // item can have been removed. Recover in the active route's scope.
      final scope = focused is FocusScopeNode ? focused : focused?.nearestScope;
      scope?.nextFocus();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  void dispose() {
    FocusManager.instance.removeListener(_focusChanged);
    _focusRecovery?.cancel();
    _routeMotion?.removeListener(_scheduleRepaint);
    _idle.dispose();
    _repaint.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FocusTraversalGroup(
    policy: ReadingOrderTraversalPolicy(),
    child: Focus(
      focusNode: _idle,
      autofocus: true,
      onKeyEvent: _handleKey,
      child: NotificationListener<ScrollNotification>(
        onNotification: (_) {
          _scheduleRepaint();
          return false;
        },
        child: CustomPaint(
          key: _viewportKey,
          foregroundPainter: _TvFocusPainter(
            viewportKey: _viewportKey,
            idle: _idle,
            color: Theme.of(context).colorScheme.primary,
            repaint: _repaint,
          ),
          child: widget.child,
        ),
      ),
    ),
  );
}

class _TvFocusPainter extends CustomPainter {
  _TvFocusPainter({
    required this.viewportKey,
    required this.idle,
    required this.color,
    required Listenable repaint,
  }) : super(repaint: repaint);

  final GlobalKey viewportKey;
  final FocusNode idle;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final focus = FocusManager.instance.primaryFocus;
    if (focus == null || focus == idle || focus is FocusScopeNode) return;
    final target = focus.context?.findRenderObject();
    final viewport = viewportKey.currentContext?.findRenderObject();
    if (target is! RenderBox ||
        viewport is! RenderBox ||
        !target.attached ||
        !target.hasSize) {
      return;
    }
    final rect = MatrixUtils.transformRect(
      target.getTransformTo(viewport),
      Offset.zero & target.size,
    ).intersect(Offset.zero & size);
    if (rect.isEmpty || !rect.isFinite) return;
    final border = RRect.fromRectAndRadius(
      rect.deflate(2),
      const Radius.circular(12),
    );
    canvas.drawRRect(
      border,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 5
        ..color = Colors.black,
    );
    canvas.drawRRect(
      border,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..color = color,
    );
  }

  @override
  bool shouldRepaint(_TvFocusPainter oldDelegate) => color != oldDelegate.color;
}
