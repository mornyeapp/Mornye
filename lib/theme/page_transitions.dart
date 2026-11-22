import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter/services.dart' show PredictiveBackEvent;
import 'package:material_ui/material_ui.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:mornye/theme/app_motion.dart';
import 'package:mornye/theme/mornye_theme.dart';

// Every map avoids Flutter's Android default,
// PredictiveBackPageTransitionsBuilder: its gesture detector mis-routes the
// predictive-back gesture to a nested Navigator instead of the topmost route
// (flutter#152323), which pops the page behind a root modal, sheet or dialog
// instead of closing the modal first. The builders used here register no back
// gesture observer; [PageBackSwipe] is the one observer, and it asks the
// navigators in the order a back press does.

/// The material route the app pushes its pages on: its transition waits out
/// the page's slow first frames instead of leaping in.
class SteadyPageRoute<T> extends MaterialPageRoute<T> with SteadyStartRoute<T> {
  SteadyPageRoute({
    required super.builder,
    super.settings,
    super.requestFocus,
    super.fullscreenDialog,
  });
}

/// A scale that moves its child as a picture. Text at a new size every frame
/// is drawn again glyph by glyph, which costs the raster thread its frames;
/// at rest, a scale of one, the child is drawn as itself.
class PictureScaleTransition extends AnimatedWidget {
  const PictureScaleTransition({
    super.key,
    required Animation<double> scale,
    this.child,
  }) : super(listenable: scale);

  final Widget? child;

  @override
  Widget build(BuildContext context) {
    final scale = (listenable as Animation<double>).value;
    return Transform.scale(
      scale: scale,
      filterQuality: scale == 1 ? null : FilterQuality.low,
      child: child,
    );
  }
}

/// Material page transitions: Android phones push a solid page and pop it as
/// a card, and the desktops share one light builder.
const PageTransitionsTheme materialPageTransitionsTheme = PageTransitionsTheme(
  builders: <TargetPlatform, PageTransitionsBuilder>{
    TargetPlatform.android: ReducedMotionPageTransitionsBuilder(
      MaterialPhonePageTransitionsBuilder(),
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

  // Read at every push and pop, so a changed Animation speed applies from
  // the next page.
  @override
  Duration get transitionDuration =>
      MotionPace.duration(builder.transitionDuration);

  @override
  Duration get reverseTransitionDuration =>
      MotionPace.duration(builder.reverseTransitionDuration);

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

/// The opacity of the arriving phone page: it follows the page's own way in,
/// so the page is faint while it moves fastest and solid before it lands.
class _ArrivingFade extends Curve {
  const _ArrivingFade();

  @override
  double transformInternal(double t) {
    final way = Easing.standard.transform(t);
    final opacity = way / MaterialPhonePageTransitionsBuilder._solidAt;
    return opacity < 1 ? opacity : 1;
  }
}

/// The Material phone push. The new page comes from a third of the width
/// away, fading in with its own way in: solid within an eighth of a second,
/// so two pages are not read through each other for long. The page it covers
/// moves aside under a scrim.
///
/// Going back, the page leaves as a card: it draws in and rounds its corners
/// first, then slides off over the page below, which is already back.
class MaterialPhonePageTransitionsBuilder extends PageTransitionsBuilder {
  const MaterialPhonePageTransitionsBuilder();

  static const Duration _duration = Duration(milliseconds: 350);

  /// Where the arriving page starts and how far the covered page moves, as
  /// fractions of the width.
  static const double _enterShift = 1 / 3;
  static const double _coveredShift = 0.25;

  /// The leaving card at the moment it slides away.
  static const double _cardScale = 0.88;
  static const double _cardRadius = 28;

  static const double _scrim = 0.32;

  static final Animatable<double> _move = CurveTween(curve: Easing.standard);

  static final Animatable<Offset> _slideIn = Tween<Offset>(
    begin: const Offset(_enterShift, 0),
    end: Offset.zero,
  ).chain(_move);

  /// How much of its way in the arriving page has made when it is solid.
  static const double _solidAt = 0.75;

  static final Animatable<double> _solid = CurveTween(
    curve: const _ArrivingFade(),
  );

  static final Animatable<double> _uncover = Tween<double>(
    begin: 1,
    end: 0,
  ).chain(_move);

  /// How far a full back swipe draws the page in as a card.
  static const double _backPreview = 0.8;

  static final Expando<bool> _pages = Expando<bool>();

  /// Whether [route] moves by this builder, so a back swipe can seek its pop.
  static bool moves(Route<dynamic> route) => _pages[route] ?? false;

  /// The value of a page's animation for a back swipe at [progress]: the
  /// card draws in evenly under the finger.
  static double backSwipeValue(double progress) =>
      1 - curveTimeFor(Easing.standard, _backPreview * progress.clamp(0, 1));

  @override
  Duration get transitionDuration => _duration;

  @override
  Duration get reverseTransitionDuration => _duration;

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    _pages[route] = true;
    return _PhonePageTransition(
      animation: animation,
      secondaryAnimation: secondaryAnimation,
      child: child,
    );
  }
}

/// A phone page between the page it covers and the page that covers it.
///
/// Which way each animation plays is read from the end it left and held
/// until it rests: a back swipe seeks the pop while the animation still
/// reports forward, and a cancelled one returns the way it came.
class _PhonePageTransition extends StatefulWidget {
  const _PhonePageTransition({
    required this.animation,
    required this.secondaryAnimation,
    required this.child,
  });

  final Animation<double> animation;
  final Animation<double> secondaryAnimation;
  final Widget child;

  @override
  State<_PhonePageTransition> createState() => _PhonePageTransitionState();
}

class _PhonePageTransitionState extends State<_PhonePageTransition> {
  final ProxyAnimation _enter = ProxyAnimation();
  final ProxyAnimation _leave = ProxyAnimation();
  final ProxyAnimation _covered = ProxyAnimation();
  late final Animation<double> _opacity = MaterialPhonePageTransitionsBuilder
      ._solid
      .animate(_enter);
  late final Animation<Offset> _position = MaterialPhonePageTransitionsBuilder
      ._slideIn
      .animate(_enter);

  late AnimationStatus _pageStatus = widget.animation.status;
  late AnimationStatus _coverStatus = widget.secondaryAnimation.status;
  late bool _leaving = _pageStatus == AnimationStatus.reverse;
  late bool _uncovering = _coverStatus == AnimationStatus.reverse;

  @override
  void initState() {
    super.initState();
    widget.animation.addStatusListener(_pageChanged);
    widget.secondaryAnimation.addStatusListener(_coverChanged);
    _connect();
  }

  @override
  void didUpdateWidget(_PhonePageTransition oldWidget) {
    super.didUpdateWidget(oldWidget);
    final page = !identical(oldWidget.animation, widget.animation);
    final cover = !identical(
      oldWidget.secondaryAnimation,
      widget.secondaryAnimation,
    );
    if (!page && !cover) return;
    // Reduced motion swaps a resting animation for the live one when a
    // back swipe starts: the swap is where the live one left rest.
    if (page) {
      oldWidget.animation.removeStatusListener(_pageChanged);
      widget.animation.addStatusListener(_pageChanged);
      _leaving = _fromTop(widget.animation, _pageStatus, _leaving);
      _pageStatus = widget.animation.status;
    }
    if (cover) {
      oldWidget.secondaryAnimation.removeStatusListener(_coverChanged);
      widget.secondaryAnimation.addStatusListener(_coverChanged);
      _uncovering = _fromTop(
        widget.secondaryAnimation,
        _coverStatus,
        _uncovering,
      );
      _coverStatus = widget.secondaryAnimation.status;
    }
    _connect();
  }

  @override
  void dispose() {
    widget.animation.removeStatusListener(_pageChanged);
    widget.secondaryAnimation.removeStatusListener(_coverChanged);
    super.dispose();
  }

  /// Whether [animation], [held] so far, plays from its completed end. Read
  /// where it leaves rest, from the end it is nearer: a route laid out
  /// offstage for its first frame reports completed before it has moved.
  static bool _fromTop(
    Animation<double> animation,
    AnimationStatus last,
    bool held,
  ) => animation.status.isAnimating && !last.isAnimating
      ? animation.value > 0.5
      : held;

  void _pageChanged(AnimationStatus status) {
    final leaving = _fromTop(widget.animation, _pageStatus, _leaving);
    _pageStatus = status;
    if (leaving == _leaving) return;
    _leaving = leaving;
    _connect();
  }

  void _coverChanged(AnimationStatus status) {
    final uncovering = _fromTop(
      widget.secondaryAnimation,
      _coverStatus,
      _uncovering,
    );
    _coverStatus = status;
    if (uncovering == _uncovering) return;
    _uncovering = uncovering;
    _connect();
  }

  // Parents are swapped under widgets that stay, so the page keeps its state.
  void _connect() {
    final page = widget.animation;
    _enter.parent = _leaving ? kAlwaysCompleteAnimation : page;
    _leave.parent = _leaving
        ? ReverseAnimation(page)
        : kAlwaysDismissedAnimation;
    // Each direction starts fast: the covered page is back in place while
    // the card above it is still leaving.
    final cover = widget.secondaryAnimation;
    _covered.parent = _uncovering
        ? MaterialPhonePageTransitionsBuilder._uncover.animate(
            ReverseAnimation(cover),
          )
        : MaterialPhonePageTransitionsBuilder._move.animate(cover);
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _opacity,
      child: SlideTransition(
        position: _position,
        textDirection: Directionality.of(context),
        child: _LeavingCard(
          progress: _leave,
          child: _CoveredPage(amount: _covered, child: widget.child),
        ),
      ),
    );
  }
}

/// Whether a cover's Hero flies on a back swipe as it does on a back press.
/// A Material page follows the swipe, and a Hero that sat the swipe out
/// would ride off with the page instead of going back to its row.
bool heroFollowsBackSwipe(BuildContext context) => !context.isMornye;

/// Lets a Material phone page follow the system back swipe: the swipe seeks
/// the page's own pop, and letting go finishes it or puts the page back.
///
/// One observer for the app, given the navigators a back press pops from in
/// order, so the swipe reaches the route a press would (flutter#152323).
class PageBackSwipe with WidgetsBindingObserver {
  PageBackSwipe(this._navigators);

  final Iterable<NavigatorState?> Function() _navigators;
  PageRoute<dynamic>? _page;

  PageRoute<dynamic>? _target() {
    for (final navigator in _navigators()) {
      if (navigator == null) continue;
      Route<dynamic>? top;
      navigator.popUntil((route) {
        top = route;
        return true;
      });
      final route = top;
      // A first route with no objection passes the press on, as maybePop
      // does; any other answer ends the search at this navigator.
      if (route == null || route.popDisposition == RoutePopDisposition.bubble) {
        continue;
      }
      return route is PageRoute &&
              MaterialPhonePageTransitionsBuilder.moves(route) &&
              route.popGestureEnabled
          ? route
          : null;
    }
    return null;
  }

  @override
  bool handleStartBackGesture(PredictiveBackEvent backEvent) {
    _page = backEvent.isButtonEvent ? null : _target();
    _page?.handleStartBackGesture(
      progress: MaterialPhonePageTransitionsBuilder.backSwipeValue(
        backEvent.progress,
      ),
    );
    return _page != null;
  }

  @override
  void handleUpdateBackGestureProgress(PredictiveBackEvent backEvent) {
    _page?.handleUpdateBackGestureProgress(
      progress: MaterialPhonePageTransitionsBuilder.backSwipeValue(
        backEvent.progress,
      ),
    );
  }

  @override
  void handleCommitBackGesture() {
    final page = _page;
    _page = null;
    if (page == null) return;
    if (!page.isCurrent) {
      page.handleCancelBackGesture();
      return;
    }
    // Popped inside the gesture, the page leaves from where the finger
    // left it; the framework's own commit starts over from the full page.
    final navigator = page.navigator;
    navigator?.pop();
    navigator?.didStopUserGesture();
  }

  @override
  void handleCancelBackGesture() {
    _page?.handleCancelBackGesture();
    _page = null;
  }
}

/// A page on its way out: smaller and rounder on the standard curve, and
/// off to the trailing side on a cubic one, which barely moves at first.
class _LeavingCard extends AnimatedWidget {
  const _LeavingCard({required Animation<double> progress, required this.child})
    : super(listenable: progress);

  final Widget? child;

  @override
  Widget build(BuildContext context) {
    final time = (listenable as Animation<double>).value;
    final drawnIn = Easing.standard.transform(time);
    final direction = Directionality.of(context) == TextDirection.rtl ? -1 : 1;
    return FractionalTranslation(
      translation: Offset(Curves.easeInCubic.transform(time) * direction, 0),
      child: Transform.scale(
        scale:
            1 - (1 - MaterialPhonePageTransitionsBuilder._cardScale) * drawnIn,
        // Scaled as a picture: text at a new size every frame is drawn
        // again glyph by glyph, which costs the raster thread its frames.
        filterQuality: drawnIn > 0 ? FilterQuality.low : null,
        // Always in the tree, so the page keeps its state when it leaves.
        child: ClipRRect(
          clipBehavior: drawnIn > 0 ? Clip.antiAlias : Clip.none,
          borderRadius: BorderRadius.circular(
            MaterialPhonePageTransitionsBuilder._cardRadius * drawnIn,
          ),
          child: child,
        ),
      ),
    );
  }
}

/// A page under the one above it: moved toward the leading side and dimmed
/// by [amount], over the app's surface so no gap opens beside it.
class _CoveredPage extends AnimatedWidget {
  const _CoveredPage({required Animation<double> amount, required this.child})
    : super(listenable: amount);

  final Widget? child;

  @override
  Widget build(BuildContext context) {
    final amount = (listenable as Animation<double>).value;
    final direction = Directionality.of(context) == TextDirection.rtl ? -1 : 1;
    return ColoredBox(
      color: amount > 0
          ? Theme.of(context).scaffoldBackgroundColor
          : Colors.transparent,
      child: DecoratedBox(
        position: DecorationPosition.foreground,
        decoration: BoxDecoration(
          color: Colors.black.withValues(
            alpha: MaterialPhonePageTransitionsBuilder._scrim * amount,
          ),
        ),
        child: FractionalTranslation(
          translation: Offset(
            -MaterialPhonePageTransitionsBuilder._coveredShift *
                amount *
                direction,
            0,
          ),
          child: child,
        ),
      ),
    );
  }
}

/// The Material desktop push: the new page slides 32dp in from the trailing
/// side on the standard spatial spring (no visible page-edge overshoot) and
/// fades in on the fast effects spring, over the page it covers, which stays
/// still. A pop slides and fades the page out on M3's standard accelerate
/// curve in a shorter exit.
///
/// It uses only a [FadeTransition] and a translation: no snapshot (the Zoom
/// builder's cost), and the one opacity layer lasts as long as the fade, not
/// the whole push. The covered page keeps no layer at all, unlike fade
/// forwards, which also fades and slides it by a quarter of the pane.
class DesktopPageTransitionsBuilder extends PageTransitionsBuilder {
  const DesktopPageTransitionsBuilder();

  static const double _distance = 32;

  static final SpringCurve _slide = SpringCurve(M3EMotion.spatialDefault);
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
    curve: Easing.standardAccelerate,
  );

  static final Animatable<double> _fadeOut = Tween<double>(begin: 1, end: 0)
      .chain(
        CurveTween(
          curve: const Interval(0, 0.75, curve: Easing.standardAccelerate),
        ),
      );

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
