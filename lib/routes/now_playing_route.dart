import 'package:material_ui/material_ui.dart';
import 'package:flutter/physics.dart' show SpringSimulation, Tolerance;
import 'package:flutter/services.dart' show PredictiveBackEvent;
import 'package:material_3_expressive/material_3_expressive.dart'
    show M3EMotion;
import 'package:mornye/services/app_orientation.dart';
import 'package:mornye/theme/app_motion.dart';
import 'package:mornye/theme/mornye_theme.dart';

/// Hero tag shared by the mini player artwork and the full player artwork so
/// the cover visually expands when the player opens.
const kNowPlayingArtworkHeroTag = 'now-playing-artwork';

/// Slide-up route for the full player. Supports live drag-to-dismiss: the
/// page follows the finger (via [startDrag]/[updateDrag]/[endDrag]) and
/// settles open or pops based on release position and velocity. Either way
/// a spring finishes the move from the finger's velocity.
///
/// With [morph], the player instead grows out of the mini player's bounds
/// and shrinks back into them on close, and Android's predictive back
/// previews that shrink.
class NowPlayingRoute extends PageRoute<void> {
  NowPlayingRoute({required this.child, this.miniPlayerGeometry, this.morph})
    : super(
        fullscreenDialog: true,
        settings: const RouteSettings(name: fullPlayerRouteName),
      );

  final Widget child;

  /// Read at dismissal so rotation and collapsing navigation cannot leave a
  /// stale destination from when the player was opened.
  final ({Rect surface, Rect artwork})? Function()? miniPlayerGeometry;

  /// The Material opening motion. A zero duration (reduced motion) opens
  /// and closes at once. Null keeps the slide up and, for Mornye, the
  /// shrink on close.
  final AppMotionSpec? morph;

  /// How far a full predictive back swipe shrinks the player toward the
  /// mini player before the person lets go.
  static const _backGesturePreview = 0.25;

  /// The mini player's bounds while the player grows out of them.
  ({Rect surface, Rect artwork})? _openFrom;
  Size? _openSize;
  _PlayerBackGesture? _backGesture;
  bool _backGestureActive = false;
  ({Rect bounds, Widget child, bool fullBleed})? Function()? readArtwork;

  bool get hasDismissArtwork => _dismissArtwork != null;
  ({Rect surface, Rect artwork})? _dismissTarget;
  ({Rect bounds, Widget child, bool fullBleed})? _dismissArtwork;
  Rect? _dismissStart;
  Size? _dismissSize;
  double _dismissStartValue = 1;

  bool _interactiveTransition = false;
  int _dragGeneration = 0;

  /// The finger's speed when the last drag was let go, in controller units
  /// a second (positive opens). The spring that finishes the move starts
  /// from it, once.
  double _releaseVelocity = 0;

  double _takeReleaseVelocity() {
    final velocity = _releaseVelocity;
    _releaseVelocity = 0;
    return velocity;
  }

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
    // The controller, not [animation]: the Hero controller's measuring frame
    // shows the route offstage, where [animation] reads as completed.
    controller!.addStatusListener((status) {
      if (status.isCompleted) _openFrom = null;
    });
    if (morph != null) {
      WidgetsBinding.instance.addObserver(
        _backGesture = _PlayerBackGesture(this),
      );
    }
  }

  @override
  TickerFuture didPush() {
    // Reduced motion opens every style at once, without the slide.
    if (_reduceMotion) controller!.duration = Duration.zero;
    if (morph case final morph? when morph.duration > Duration.zero) {
      final from = miniPlayerGeometry?.call();
      if (from != null && !from.surface.isEmpty) {
        _openFrom = from;
        _openSize = _overlaySize;
      }
    }
    return super.didPush();
  }

  @override
  void dispose() {
    if (_backGesture case final observer?) {
      WidgetsBinding.instance.removeObserver(observer);
    }
    super.dispose();
  }

  @override
  Color? get barrierColor => null;

  @override
  String? get barrierLabel => null;

  @override
  bool get maintainState => true;

  @override
  Duration get transitionDuration =>
      morph?.duration ?? const Duration(milliseconds: 400);

  @override
  Duration get reverseTransitionDuration => morph?.duration == Duration.zero
      ? Duration.zero
      : const Duration(milliseconds: 300);

  /// Moves the Material shrink on the spring of the entrance, the slow
  /// spatial one for full-screen surfaces, kept critically damped so the
  /// surface never passes the mini player. It settles in about 520ms. A
  /// spring more than twice as stiff had the player gone in an eighth of a
  /// second, in a handful of frames.
  static final _exitSpring = SpringDescription.withDampingRatio(
    mass: 1,
    stiffness: M3EMotion.expressiveSpatialSlow.stiffness,
    ratio: 1,
  );

  /// Settled once within a fraction of a pixel per screen, as [SpringCurve]
  /// judges the app's other springs.
  static const _exitTolerance = Tolerance(distance: 0.002, velocity: 0.02);

  /// Mornye moves the page on its own springs, which shape the motion
  /// themselves: the controller's value is then the page's position, as it
  /// is while a finger moves the page. Material's slide keeps its curve.
  bool _mornyeSprings(BuildContext? context) =>
      morph == null && context != null && context.isMornye;

  /// Where the page sits for a controller [value].
  double _slideAt(double value) =>
      _interactiveTransition || _mornyeSprings(navigator?.context)
      ? value
      : Easing.emphasizedDecelerate.transform(value);

  SpringSimulation _spring(
    SpringDescription spring,
    double end,
    double velocity,
  ) => SpringSimulation(
    spring,
    controller!.value,
    end,
    velocity,
    tolerance: _exitTolerance,
    snapToEnd: true,
  );

  /// Mornye opens and closes on its full-screen spring, as a system sheet
  /// does. The Material shrink runs on [_exitSpring], and so does a
  /// Material slide a finger let go. Each starts from wherever the page is
  /// and from the finger's velocity, so a released drag or back gesture
  /// carries on without a seam.
  @override
  Simulation? createSimulation({required bool forward}) {
    final velocity = _takeReleaseVelocity();
    if (_reduceMotion) return null;
    final mornye = _mornyeSprings(navigator?.context);
    if (forward) {
      return mornye ? _spring(MornyeMotion.slowSpring, 1, velocity) : null;
    }
    if (mornye) return _spring(MornyeMotion.slowSpring, 0, velocity);
    final shrinks =
        _dismissTarget != null &&
        (morph?.duration ?? Duration.zero) > Duration.zero;
    if (!shrinks && !_interactiveTransition) return null;
    return _spring(_exitSpring, 0, velocity);
  }

  Rect _openRect(Size size, double value) => Rect.lerp(
    _openFrom!.surface,
    Offset.zero & size,
    morph!.curve.transform(value),
  )!;

  void startDrag() {
    _dragGeneration++;
    _releaseVelocity = 0;
    // A drag takes over a cancelled back gesture still settling open.
    if (isCurrent) _clearDismiss();
    if (_openFrom != null) {
      // A drag takes over a player still growing: it continues as the slide.
      _openFrom = null;
      controller?.value = 1;
    }
    controller?.stop();
    // The page stays where it is drawn while the drag takes over.
    if (controller case final controller?) {
      controller.value = _slideAt(controller.value);
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
    // The finger moves down, the controller toward zero.
    _releaseVelocity = -velocity;
    if (velocity > 1.0 || (velocity >= 0 && value < 0.7)) {
      navigator?.pop();
    } else {
      _settleOpen();
    }
  }

  void cancelDrag() {
    _releaseVelocity = 0;
    _settleOpen();
  }

  /// Returns the page to open on the style's page spring, from the finger's
  /// velocity: Material's standard spatial spring, which stops at the top,
  /// or Mornye's standard spring. Reduced motion puts it back at once.
  void _settleOpen() {
    final generation = _dragGeneration;
    final velocity = _takeReleaseVelocity();
    final controller = this.controller;
    if (controller == null) return;
    void settled() {
      if (generation != _dragGeneration || !isCurrent) return;
      _interactiveTransition = false;
      changedInternalState();
    }

    if (_reduceMotion) {
      controller.value = 1;
      settled();
      return;
    }
    // Keep the same linear position mapping until settling finishes. Switching
    // to the entrance curve on release jumps away from the finger's position.
    final spring = (navigator?.context.isMornye ?? false)
        ? MornyeMotion.standardSpring
        : M3EMotion.spatialDefault.toDescription();
    controller
        .animateWith(_spring(spring, 1, velocity))
        .whenCompleteOrCancel(settled);
  }

  @override
  bool didPop(void result) {
    // A committed back gesture already shrinks toward the mini player.
    if (_dismissTarget == null) _captureDismiss();
    if (_reduceMotion) controller!.reverseDuration = Duration.zero;
    _poppedAt = controller!.value;
    return super.didPop(result);
  }

  /// Where the route was when it was popped, from a finger or settled.
  double? _poppedAt;

  /// The player's own [fade] over the route's animation: it comes in behind
  /// the growing surface and follows a finger. Once the route is popped it
  /// holds where it was, because the page fades as a whole on the way out;
  /// left on the closing spring, which covers most of its way early, the
  /// content was gone in a tenth of a second.
  Animation<double> contentOpacity(Animatable<double> fade) =>
      animation!.drive(_HeldAfterPop(this, fade));

  bool get _reduceMotion {
    final context = navigator?.context;
    return context != null &&
        (MediaQuery.maybeDisableAnimationsOf(context) ?? false);
  }

  bool _captureDismiss() {
    final context = subtreeContext;
    if (context == null ||
        !(context.isMornye || morph != null) ||
        MediaQuery.disableAnimationsOf(context) ||
        (controller?.value ?? 0) <= 0) {
      return false;
    }
    final coveredSize = _coveredOverlaySize;
    final target = coveredSize == null || coveredSize == _overlaySize
        ? miniPlayerGeometry?.call()
        : null;
    if (target == null || target.surface.isEmpty) return false;
    final size = MediaQuery.sizeOf(context);
    _dismissStartValue = controller!.value;
    final opening = _openFrom != null && _openSize == size
        ? _openRect(size, _dismissStartValue)
        : null;
    _openFrom = null;
    if (opening != null) {
      _dismissStart = opening;
    } else {
      final position = _slideAt(_dismissStartValue);
      _dismissStart = Rect.fromLTWH(
        0,
        size.height * (1 - position),
        size.width,
        size.height,
      );
    }
    _dismissSize = size;
    _dismissTarget = target;
    _dismissArtwork = readArtwork?.call();
    return true;
  }

  bool _startBackGesture(PredictiveBackEvent event) {
    if (event.isButtonEvent ||
        !isCurrent ||
        popDisposition != RoutePopDisposition.pop ||
        !(controller?.isCompleted ?? false) ||
        !_captureDismiss()) {
      return false;
    }
    _dragGeneration++;
    _backGestureActive = true;
    _interactiveTransition = true;
    navigator?.didStartUserGesture();
    _updateBackGesture(event);
    changedInternalState();
    return true;
  }

  void _updateBackGesture(PredictiveBackEvent event) {
    if (!_backGestureActive || !isCurrent) return;
    controller?.value = 1 - _backGesturePreview * event.progress;
  }

  void _commitBackGesture() {
    if (!_backGestureActive) return;
    _backGestureActive = false;
    // Popping inside the gesture skips the cover's Hero flight, which would
    // jump from where the preview left it: the cover shrinks with the page.
    final navigator = this.navigator;
    if (isCurrent) {
      navigator?.pop();
    } else {
      // Another route arrived during the gesture; the player stays open.
      _clearDismiss();
      _interactiveTransition = false;
      controller?.value = 1;
    }
    navigator?.didStopUserGesture();
  }

  void _clearDismiss() {
    _dismissTarget = null;
    _dismissStart = null;
    _dismissSize = null;
    _dismissArtwork = null;
  }

  void _cancelBackGesture() {
    if (!_backGestureActive) return;
    _backGestureActive = false;
    navigator?.didStopUserGesture();
    final generation = _dragGeneration;
    const fallback = AppMotionSpec(
      Duration(milliseconds: 220),
      Curves.easeOutCubic,
    );
    final context = subtreeContext;
    final settle = context == null
        ? fallback
        : AppMotion.spatialSlow(context, fallback);
    controller
        ?.animateTo(1, duration: settle.duration, curve: settle.curve)
        .whenCompleteOrCancel(() {
          if (generation != _dragGeneration || !isCurrent) return;
          _clearDismiss();
          _interactiveTransition = false;
          changedInternalState();
        });
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
    final size = MediaQuery.sizeOf(context);
    // The Mornye mini player is a rounded capsule; the Material one is a
    // square bar, which the shrinking surface keeps square. Material dims
    // the page behind while the player covers it.
    final radius = context.isMornye ? 28.0 : 0.0;
    final scrim = context.isMornye ? 0.0 : 0.32;
    // Restoring portrait can resize the window during dismissal. Geometry
    // captured in landscape no longer points at the mini player in that case.
    if (target != null && _dismissSize == size) {
      // The shrink runs on a spring simulation in both styles.
      final progress = (1 - animation.value / _dismissStartValue).clamp(
        0.0,
        1.0,
      );
      final cover = _dismissArtwork;
      return Stack(
        fit: StackFit.expand,
        children: [
          if (scrim > 0) _scrim(scrim * (1 - progress)),
          _surface(
            key: const ValueKey('player-minimize-surface'),
            bounds: Rect.lerp(_dismissStart, target.surface, progress)!,
            size: size,
            radius: radius * progress,
            // Gone only as it reaches the mini player: fading out sooner
            // hides most of the spring's travel and reads as a cut.
            opacity: 1 - const Interval(0.3, 1).transform(progress),
            child: child,
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
    // A rotation while opening leaves the mini player's bounds stale.
    if (_openFrom != null &&
        _openSize == size &&
        animation.status == AnimationStatus.forward) {
      final morph = this.morph!;
      final progress = morph.curve.transform(animation.value);
      // The surface moves on the spatial spring; it fades in on the effects
      // spring, over that spring's own settle time from the start.
      final fade = AppMotion.effects(
        context,
        const AppMotionSpec(Duration(milliseconds: 200), Curves.easeOut),
      );
      final fadeShare = morph.duration > Duration.zero
          ? (fade.duration.inMicroseconds / morph.duration.inMicroseconds)
                .clamp(0.0, 1.0)
          : 1.0;
      return Stack(
        fit: StackFit.expand,
        children: [
          _scrim(scrim * progress),
          _surface(
            key: const ValueKey('player-expand-surface'),
            bounds: _openRect(size, animation.value),
            size: size,
            radius: radius * (1 - progress),
            // The mini player shows through until the surface covers it.
            opacity: Interval(
              0,
              fadeShare,
              curve: fade.curve,
            ).transform(animation.value),
            child: child,
          ),
        ],
      );
    }
    final reversing = animation.status == AnimationStatus.reverse;
    // Mornye's full-bleed artwork travels with its panel. Material keeps the
    // independent cover flight back to the mini-player on button/back pop.
    final inPlacePop =
        reversing && !_interactiveTransition && !context.isMornye;
    final slide = _interactiveTransition || _mornyeSprings(context)
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

  Widget _scrim(double opacity) => IgnorePointer(
    child: ColoredBox(color: Colors.black.withValues(alpha: opacity)),
  );

  /// The full-size page at [bounds], scaled to their width and clipped to
  /// their height, so its layout never changes while the surface moves.
  Widget _surface({
    required Key key,
    required Rect bounds,
    required Size size,
    required double radius,
    required double opacity,
    required Widget child,
  }) => Positioned.fromRect(
    rect: bounds,
    child: ClipRRect(
      key: key,
      borderRadius: BorderRadius.circular(radius),
      child: OverflowBox(
        alignment: Alignment.topLeft,
        minWidth: size.width,
        maxWidth: size.width,
        minHeight: size.height,
        maxHeight: size.height,
        child: Transform.scale(
          scale: bounds.width / size.width,
          alignment: Alignment.topLeft,
          child: Opacity(opacity: opacity, child: child),
        ),
      ),
    ),
  );
}

class _HeldAfterPop extends Animatable<double> {
  _HeldAfterPop(this.route, this.fade);

  final NowPlayingRoute route;
  final Animatable<double> fade;

  @override
  double transform(double t) => fade.transform(route._poppedAt ?? t);
}

/// Feeds Android's predictive back to the player route while it is the
/// current route of the root navigator. The app keeps the general
/// predictive back page transition off (flutter#152323), so only this
/// route previews its pop.
class _PlayerBackGesture with WidgetsBindingObserver {
  _PlayerBackGesture(this.route);

  final NowPlayingRoute route;

  @override
  bool handleStartBackGesture(PredictiveBackEvent backEvent) =>
      route._startBackGesture(backEvent);

  @override
  void handleUpdateBackGestureProgress(PredictiveBackEvent backEvent) =>
      route._updateBackGesture(backEvent);

  @override
  void handleCommitBackGesture() => route._commitBackGesture();

  @override
  void handleCancelBackGesture() => route._cancelBackGesture();
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
