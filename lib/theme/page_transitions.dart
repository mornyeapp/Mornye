import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:mornye/theme/app_motion.dart';

// Every map avoids Flutter's Android default,
// PredictiveBackPageTransitionsBuilder: its gesture detector mis-routes the
// predictive-back gesture to a nested Navigator instead of the topmost route
// (flutter#152323), which pops the page behind a root modal, sheet or dialog
// instead of closing the modal first. The builders used here register no back
// gesture observer, so system back keeps closing the topmost route first.

/// Material page transitions: phones keep the Android fade forwards, and the
/// desktops share one light builder.
const PageTransitionsTheme materialPageTransitionsTheme = PageTransitionsTheme(
  builders: <TargetPlatform, PageTransitionsBuilder>{
    TargetPlatform.android: ReducedMotionPageTransitionsBuilder(
      FadeForwardsPageTransitionsBuilder(),
    ),
    TargetPlatform.iOS: ReducedMotionPageTransitionsBuilder(
      CupertinoPageTransitionsBuilder(),
    ),
    TargetPlatform.macOS: ReducedMotionPageTransitionsBuilder(
      DesktopPageTransitionsBuilder(),
    ),
    TargetPlatform.windows: ReducedMotionPageTransitionsBuilder(
      DesktopPageTransitionsBuilder(),
    ),
    TargetPlatform.linux: ReducedMotionPageTransitionsBuilder(
      DesktopPageTransitionsBuilder(),
    ),
  },
);

/// Mornye pushes the iOS way on every platform. Desktops drop the edge
/// back-drag, which would otherwise start under a mouse.
const PageTransitionsTheme mornyePageTransitionsTheme = PageTransitionsTheme(
  builders: <TargetPlatform, PageTransitionsBuilder>{
    TargetPlatform.android: ReducedMotionPageTransitionsBuilder(
      CupertinoPageTransitionsBuilder(),
    ),
    TargetPlatform.iOS: ReducedMotionPageTransitionsBuilder(
      CupertinoPageTransitionsBuilder(),
    ),
    TargetPlatform.macOS: ReducedMotionPageTransitionsBuilder(
      DesktopCupertinoPageTransitionsBuilder(),
    ),
    TargetPlatform.windows: ReducedMotionPageTransitionsBuilder(
      DesktopCupertinoPageTransitionsBuilder(),
    ),
    TargetPlatform.linux: ReducedMotionPageTransitionsBuilder(
      DesktopCupertinoPageTransitionsBuilder(),
    ),
  },
);

/// Shows [builder]'s transition, or none when the OS asks for reduced
/// motion. Flutter routes never read `MediaQuery.disableAnimations`.
///
/// Under reduced motion the pushed page is drawn at rest from the first
/// frame and a popped page leaves at once. The wrapped transition stays in
/// the tree at rest, so a back swipe that the finger drives still works and
/// still moves with the finger.
class ReducedMotionPageTransitionsBuilder extends PageTransitionsBuilder {
  const ReducedMotionPageTransitionsBuilder(this.builder);

  final PageTransitionsBuilder builder;

  @override
  Duration get transitionDuration => builder.transitionDuration;

  @override
  Duration get reverseTransitionDuration => builder.reverseTransitionDuration;

  @override
  DelegatedTransitionBuilder? get delegatedTransition {
    final delegated = builder.delegatedTransition;
    if (delegated == null) return null;
    return (context, animation, secondaryAnimation, allowSnapshotting, child) {
      if (_reduced(context, Navigator.maybeOf(context))) return child;
      return delegated(
        context,
        animation,
        secondaryAnimation,
        allowSnapshotting,
        child,
      );
    };
  }

  static bool _reduced(BuildContext context, NavigatorState? navigator) =>
      MediaQuery.maybeDisableAnimationsOf(context) == true &&
      !(navigator?.userGestureInProgress ?? false);

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final reduced = _reduced(context, route.navigator);
    // The Offstage is always present, so switching in and out of a gesture
    // keeps the wrapped transition's state (and its drag recognizer).
    return Offstage(
      offstage: reduced && animation.status == AnimationStatus.reverse,
      child: builder.buildTransitions<T>(
        route,
        context,
        reduced ? kAlwaysCompleteAnimation : animation,
        reduced ? kAlwaysDismissedAnimation : secondaryAnimation,
        child,
      ),
    );
  }
}

/// The iOS push without its edge back-drag. Flutter's drag recognizer
/// accepts every pointer kind, so on a desktop a mouse press in the
/// leftmost 20dp of a page would drag it away. Desktops go back with the
/// toolbar button, Esc and the Back shortcut instead.
class DesktopCupertinoPageTransitionsBuilder extends PageTransitionsBuilder {
  const DesktopCupertinoPageTransitionsBuilder();

  @override
  Duration get transitionDuration =>
      CupertinoRouteTransitionMixin.kTransitionDuration;

  @override
  DelegatedTransitionBuilder? get delegatedTransition =>
      CupertinoPageTransition.delegatedTransition;

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final linear = route.popGestureInProgress;
    if (route.fullscreenDialog) {
      return CupertinoFullscreenDialogTransition(
        primaryRouteAnimation: animation,
        secondaryRouteAnimation: secondaryAnimation,
        linearTransition: linear,
        child: child,
      );
    }
    return CupertinoPageTransition(
      primaryRouteAnimation: animation,
      secondaryRouteAnimation: secondaryAnimation,
      linearTransition: linear,
      child: child,
    );
  }
}

/// The Material desktop push: the new page slides 32dp in from the trailing
/// side on the fast spatial spring and fades in on the fast effects spring,
/// over the page it covers, which stays still. A pop slides and fades the
/// page out in a shorter eased exit.
///
/// It uses only a [FadeTransition] and a translation: no snapshot (the Zoom
/// builder's cost), and the one opacity layer lasts as long as the fade, not
/// the whole push. The covered page keeps no layer at all, unlike fade
/// forwards, which also fades and slides it by a quarter of the pane.
class DesktopPageTransitionsBuilder extends PageTransitionsBuilder {
  const DesktopPageTransitionsBuilder();

  static const double _distance = 32;

  static final SpringCurve _slide = SpringCurve(
    M3EMotion.expressiveSpatialFast,
  );
  static final SpringCurve _fade = SpringCurve(M3EMotion.effectsFast);

  static final Duration _duration = _slide.duration > _fade.duration
      ? _slide.duration
      : _fade.duration;

  static const Duration _reverseDuration = Duration(milliseconds: 200);

  static double _fraction(Duration part) =>
      part.inMicroseconds / _duration.inMicroseconds;

  static final Animatable<double> _slideIn = Tween<double>(begin: 1, end: 0)
      .chain(
        CurveTween(
          curve: Interval(0, _fraction(_slide.duration), curve: _slide),
        ),
      );

  static final Animatable<double> _fadeIn = CurveTween(
    curve: Interval(0, _fraction(_fade.duration), curve: _fade),
  );

  static final Animatable<double> _slideOut = CurveTween(
    curve: Curves.easeInCubic,
  );

  static final Animatable<double> _fadeOut = Tween<double>(
    begin: 1,
    end: 0,
  ).chain(CurveTween(curve: const Interval(0, 0.75, curve: Curves.easeIn)));

  @override
  Duration get transitionDuration => _duration;

  @override
  Duration get reverseTransitionDuration => _reverseDuration;

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    return DualTransitionBuilder(
      animation: animation,
      forwardBuilder: (context, animation, child) => FadeTransition(
        opacity: _fadeIn.animate(animation),
        child: _PageShift(offset: _slideIn.animate(animation), child: child),
      ),
      reverseBuilder: (context, animation, child) => IgnorePointer(
        ignoring: animation.status == AnimationStatus.forward,
        child: FadeTransition(
          opacity: _fadeOut.animate(animation),
          child: _PageShift(offset: _slideOut.animate(animation), child: child),
        ),
      ),
      child: child,
    );
  }
}

/// Moves [child] toward the trailing side by [offset] times
/// [DesktopPageTransitionsBuilder._distance].
class _PageShift extends AnimatedWidget {
  const _PageShift({required Animation<double> offset, required this.child})
    : super(listenable: offset);

  final Widget? child;

  @override
  Widget build(BuildContext context) {
    final value = (listenable as Animation<double>).value;
    final direction = Directionality.of(context) == TextDirection.rtl ? -1 : 1;
    return Transform.translate(
      offset: Offset(
        value * direction * DesktopPageTransitionsBuilder._distance,
        0,
      ),
      child: child,
    );
  }
}
