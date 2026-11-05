import 'package:flutter/material.dart';
import 'package:mornye/services/app_orientation.dart';
import 'package:mornye/theme/mornye_theme.dart';

/// Hero tag shared by the mini player artwork and the full player artwork so
/// the cover visually expands when the player opens.
const kNowPlayingArtworkHeroTag = 'now-playing-artwork';

/// Slide-up route for the full player. Supports live drag-to-dismiss: the
/// page follows the finger (via [startDrag]/[updateDrag]/[endDrag]) and
/// settles open or pops based on release position and velocity.
class NowPlayingRoute extends PageRoute<void> {
  NowPlayingRoute({required this.child, this.miniPlayerGeometry})
    : super(
        fullscreenDialog: true,
        settings: const RouteSettings(name: fullPlayerRouteName),
      );

  final Widget child;

  /// Read at dismissal so rotation and collapsing navigation cannot leave a
  /// stale destination from when the player was opened.
  final ({Rect surface, Rect artwork})? Function()? miniPlayerGeometry;
  ({Rect bounds, Widget child, bool fullBleed})? Function()? readArtwork;

  bool get hasDismissArtwork => _dismissArtwork != null;
  ({Rect surface, Rect artwork})? _dismissTarget;
  ({Rect bounds, Widget child, bool fullBleed})? _dismissArtwork;
  Rect? _dismissStart;
  double _dismissStartValue = 1;

  bool _interactiveTransition = false;
  int _dragGeneration = 0;

  // The player paints an opaque surface over the whole screen, including the
  // status bar and bottom safe area. Once settled, the framework therefore
  // keeps the pages below offstage: their glass, marquees and tickers stop
  // compositing. Every drag or dismissal moves the animation off `completed`,
  // which makes this route translucent again before the page is exposed.
  @override
  bool get opaque => true;

  /// Overlay size when the pages below were last laid out, recorded while this
  /// route hides them. A rotation while hidden leaves their geometry stale.
  Size? _coveredOverlaySize;

  Size? get _overlaySize {
    final box = navigator?.overlay?.context.findRenderObject();
    return box is RenderBox && box.hasSize ? box.size : null;
  }

  @override
  void install() {
    // The player ends editing. Clear the saved search focus too, so closing
    // the route cannot reopen the IME and shrink Home behind the bottom bar.
    final focus = FocusManager.instance.primaryFocus;
    if (focus?.context?.findAncestorStateOfType<EditableTextState>() != null) {
      focus?.unfocus();
    }
    super.install();
    animation!.addStatusListener((status) {
      _coveredOverlaySize = status.isCompleted ? _overlaySize : null;
    });
  }

  @override
  Color? get barrierColor => null;

  @override
  String? get barrierLabel => null;

  @override
  bool get maintainState => true;

  @override
  Duration get transitionDuration => const Duration(milliseconds: 400);

  @override
  Duration get reverseTransitionDuration => const Duration(milliseconds: 300);

  void startDrag() {
    _dragGeneration++;
    controller?.stop();
    if (!_interactiveTransition && controller != null) {
      controller!.value = Easing.emphasizedDecelerate.transform(
        controller!.value,
      );
    }
    _interactiveTransition = true;
    changedInternalState();
  }

  void updateDrag(DragUpdateDetails details, double pageHeight) {
    controller?.value -= (details.primaryDelta ?? 0) / pageHeight;
  }

  void endDrag(DragEndDetails details, double pageHeight) {
    final velocity = (details.primaryVelocity ?? 0) / pageHeight;
    final value = controller?.value ?? 1.0;
    if (velocity > 1.0 || (velocity >= 0 && value < 0.7)) {
      navigator?.pop();
    } else {
      _settleOpen();
    }
  }

  void cancelDrag() {
    _settleOpen();
  }

  void _settleOpen() {
    final generation = _dragGeneration;
    // Keep the same linear position mapping until settling finishes. Switching
    // to the entrance curve on release jumps away from the finger's position.
    controller
        ?.animateTo(
          1,
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
        )
        .whenCompleteOrCancel(() {
          if (generation != _dragGeneration || !isCurrent) return;
          _interactiveTransition = false;
          changedInternalState();
        });
  }

  @override
  bool didPop(void result) {
    final context = subtreeContext;
    if (context != null &&
        context.isMornye &&
        !MediaQuery.disableAnimationsOf(context) &&
        (controller?.value ?? 0) > 0) {
      final coveredSize = _coveredOverlaySize;
      final target = coveredSize == null || coveredSize == _overlaySize
          ? miniPlayerGeometry?.call()
          : null;
      if (target != null && !target.surface.isEmpty) {
        final size = MediaQuery.sizeOf(context);
        _dismissStartValue = controller!.value;
        final position = _interactiveTransition
            ? _dismissStartValue
            : Easing.emphasizedDecelerate.transform(_dismissStartValue);
        _dismissStart = Rect.fromLTWH(
          0,
          size.height * (1 - position),
          size.width,
          size.height,
        );
        _dismissTarget = target;
        _dismissArtwork = readArtwork?.call();
      }
    }
    return super.didPop(result);
  }

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) {
    return _RouteDragRegion(route: this, child: child);
  }

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final target = _dismissTarget;
    // Restoring portrait can resize the window during dismissal. Geometry
    // captured in landscape no longer points at the mini player in that case.
    if (target != null && _dismissStart?.size == MediaQuery.sizeOf(context)) {
      final progress = Curves.easeInOutCubic.transform(
        (1 - animation.value / _dismissStartValue).clamp(0.0, 1.0),
      );
      final bounds = Rect.lerp(_dismissStart, target.surface, progress)!;
      final size = MediaQuery.sizeOf(context);
      final cover = _dismissArtwork;
      return Stack(
        fit: StackFit.expand,
        children: [
          Positioned.fromRect(
            rect: bounds,
            child: ClipRRect(
              key: const ValueKey('player-minimize-surface'),
              borderRadius: BorderRadius.circular(28 * progress),
              child: OverflowBox(
                alignment: Alignment.topLeft,
                minWidth: size.width,
                maxWidth: size.width,
                minHeight: size.height,
                maxHeight: size.height,
                child: Transform.scale(
                  scale: bounds.width / size.width,
                  alignment: Alignment.topLeft,
                  child: Opacity(
                    opacity: 1 - const Interval(0.15, 0.85).transform(progress),
                    child: child,
                  ),
                ),
              ),
            ),
          ),
          if (cover != null)
            Positioned.fromRect(
              rect: Rect.lerp(cover.bounds, target.artwork, progress)!,
              child: ClipRRect(
                key: const ValueKey('player-minimize-artwork'),
                borderRadius: BorderRadius.circular(
                  cover.fullBleed ? 6 * progress : 12 - 6 * progress,
                ),
                child: cover.fullBleed
                    ? ShaderMask(
                        blendMode: BlendMode.dstIn,
                        shaderCallback: (bounds) => LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          stops: const [0, 0.58, 1],
                          colors: [
                            Colors.white,
                            Colors.white,
                            Colors.white.withValues(alpha: progress),
                          ],
                        ).createShader(bounds),
                        child: cover.child,
                      )
                    : cover.child,
              ),
            ),
        ],
      );
    }
    final reversing = animation.status == AnimationStatus.reverse;
    // Mornye's full-bleed artwork travels with its panel. Material keeps the
    // independent cover flight back to the mini-player on button/back pop.
    final inPlacePop =
        reversing && !_interactiveTransition && !context.isMornye;
    final slide = _interactiveTransition
        ? animation
        : animation.drive(CurveTween(curve: Easing.emphasizedDecelerate));
    final position = inPlacePop
        ? const AlwaysStoppedAnimation(Offset.zero)
        : slide.drive(Tween(begin: const Offset(0, 1), end: Offset.zero));
    final opacity = inPlacePop ? animation : kAlwaysCompleteAnimation;
    return SlideTransition(
      position: position,
      child: FadeTransition(opacity: opacity, child: child),
    );
  }
}

/// Routes vertical drags to [NowPlayingRoute]. Scrollables inside [child]
/// still win the gesture arena, so this only fires on non-scrolling regions
/// (app bar, artwork, tab bar).
class _RouteDragRegion extends StatelessWidget {
  final NowPlayingRoute route;
  final Widget child;

  const _RouteDragRegion({required this.route, required this.child});

  @override
  Widget build(BuildContext context) {
    final pageHeight = MediaQuery.sizeOf(context).height;
    return GestureDetector(
      onVerticalDragStart: (_) => route.startDrag(),
      onVerticalDragUpdate: (details) => route.updateDrag(details, pageHeight),
      onVerticalDragEnd: (details) => route.endDrag(details, pageHeight),
      onVerticalDragCancel: route.cancelDrag,
      child: child,
    );
  }
}
