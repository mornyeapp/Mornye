import 'package:material_ui/material_ui.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/theme/app_motion.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/widgets/app_icon.dart';
import 'package:mornye/widgets/app_icon_button.dart';
import 'package:mornye/widgets/mornye_chrome.dart';

/// Applies the same transient-message policy to existing snackbar call sites.
/// A new message replaces the old one instead of building a stale FIFO queue:
/// the visible message plays its short exit and the new one follows it. A
/// message that arrives while another already waits cuts the exit and drops
/// the waiting one, so at most one message is ever queued. Reduced motion
/// cuts the visible message at once.
class AppScaffoldMessenger extends ScaffoldMessenger {
  const AppScaffoldMessenger({super.key, required super.child});

  @override
  ScaffoldMessengerState createState() => _AppScaffoldMessengerState();
}

class _AppScaffoldMessengerState extends ScaffoldMessengerState {
  AnimationStyle _animationStyle({required bool reduced}) {
    if (reduced) {
      return const AnimationStyle(
        duration: Duration.zero,
        reverseDuration: Duration.zero,
      );
    }
    return AnimationStyle(
      duration: MotionPace.duration(const Duration(milliseconds: 250)),
      reverseDuration: MotionPace.duration(const Duration(milliseconds: 150)),
    );
  }

  /// The message on screen (entering, shown or leaving) and the one queued
  /// behind its exit. Both follow the controllers' `closed` futures, which
  /// complete a microtask late; a stale value only shortens an exit.
  ScaffoldFeatureController<SnackBar, SnackBarClosedReason>? _current;
  ScaffoldFeatureController<SnackBar, SnackBarClosedReason>? _waiting;

  @override
  ScaffoldFeatureController<SnackBar, SnackBarClosedReason> showSnackBar(
    SnackBar snackBar, {
    AnimationStyle? snackBarAnimationStyle,
  }) {
    final reduced = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    final queue = !reduced && _waiting == null && _current != null;
    if (queue) {
      hideCurrentSnackBar(reason: SnackBarClosedReason.remove);
    } else {
      // Cut the visible message, then the one waiting behind it.
      if (_waiting != null) removeCurrentSnackBar();
      removeCurrentSnackBar();
    }
    final controller = super.showSnackBar(
      _TransientSnackBar(snackBar),
      snackBarAnimationStyle:
          snackBarAnimationStyle ?? _animationStyle(reduced: reduced),
    );
    if (queue) {
      _waiting = controller;
    } else {
      _current = controller;
      _waiting = null;
    }
    controller.closed.then((_) {
      if (identical(_current, controller)) {
        _current = _waiting;
        _waiting = null;
      } else if (identical(_waiting, controller)) {
        _waiting = null;
      }
    });
    return controller;
  }

  /// Closes [controller] wherever it is. Flutter's own `close` asserts that
  /// the message is the first in the queue and then hides the first one, so
  /// on a message still waiting behind another's exit it would hide the
  /// leaving one again and let the stale message show for its full time.
  void closeSnackBar(
    ScaffoldFeatureController<SnackBar, SnackBarClosedReason> controller,
  ) {
    if (identical(_waiting, controller)) {
      // The leaving message is cut, then the waiting one is cancelled
      // before it appears; both `closed` futures complete.
      removeCurrentSnackBar();
      removeCurrentSnackBar(reason: SnackBarClosedReason.hide);
    } else if (identical(_current, controller)) {
      hideCurrentSnackBar();
    }
    // Otherwise it has already closed.
  }

  /// Flutter drops queued messages without completing their `closed`
  /// futures, which would leave a caller waiting on the message queued
  /// behind an exit (such as a playback notice) waiting forever. Cut both
  /// instead, so each completes with `remove`.
  @override
  void clearSnackBars() {
    if (_waiting == null) {
      super.clearSnackBars();
      return;
    }
    removeCurrentSnackBar();
    removeCurrentSnackBar();
  }
}

/// Closes a message shown through [ScaffoldMessenger.of] at [context], also
/// while it still waits behind another message's exit. Use it instead of
/// [ScaffoldFeatureController.close] for a message that may not be on screen
/// yet. A plain [ScaffoldMessenger] keeps Flutter's `close`.
void closeAppSnackBar(
  BuildContext context,
  ScaffoldFeatureController<SnackBar, SnackBarClosedReason> controller,
) {
  final messenger = ScaffoldMessenger.maybeOf(context);
  if (messenger is _AppScaffoldMessengerState) {
    messenger.closeSnackBar(controller);
  } else {
    controller.close();
  }
}

class _TransientSnackBar extends SnackBar {
  _TransientSnackBar(this.original)
    : super(
        content: original.content,
        duration: original.duration > const Duration(seconds: 3)
            ? const Duration(seconds: 3)
            : original.duration,
        persist: false,
      );

  final SnackBar original;

  @override
  SnackBar withAnimation(Animation<double> newAnimation, {Key? fallbackKey}) {
    // Delegate first so custom glass animations remain intact.
    final animated = original.withAnimation(
      newAnimation,
      fallbackKey: fallbackKey,
    );
    return SnackBar(
      key: animated.key,
      content: animated.content,
      backgroundColor: animated.backgroundColor,
      elevation: animated.elevation,
      margin: animated.margin,
      padding: animated.padding,
      width: animated.width,
      shape: animated.shape,
      hitTestBehavior: animated.hitTestBehavior,
      behavior: animated.behavior,
      action: animated.action,
      actionOverflowThreshold: animated.actionOverflowThreshold,
      showCloseIcon: animated.showCloseIcon ?? true,
      closeIconColor: animated.closeIconColor,
      duration: duration,
      persist: false,
      animation: animated.animation,
      onVisible: animated.onVisible,
      dismissDirection: animated.dismissDirection,
      clipBehavior: animated.clipBehavior,
    );
  }
}

/// Reports a failure to open a local file using the active theme's snackbar.
void showCannotOpenFileSnackBar(BuildContext context, Object error) {
  showAppSnackBar(
    context,
    content: Text(
      context.l10n.snackbarCannotOpenFile(context.friendlyError(error)),
    ),
  );
}

/// Transient messages use the same glass as confirmation dialogs in Mornye.
ScaffoldFeatureController<SnackBar, SnackBarClosedReason> showAppSnackBar(
  BuildContext context, {
  required Widget content,
  Duration duration = const Duration(seconds: 3),
  SnackBarBehavior? behavior,
  SnackBarAction? action,
}) {
  final messenger = ScaffoldMessenger.of(context);
  if (!context.isMornye) {
    return messenger.showSnackBar(
      SnackBar(
        content: content,
        duration: duration,
        behavior: behavior,
        action: action,
        persist: false,
        showCloseIcon: true,
      ),
    );
  }
  final theme = Theme.of(context);
  final reduceMotion = MediaQuery.disableAnimationsOf(context);
  final snackBar = _MornyeSnackBar(
    duration: duration,
    reduceMotion: reduceMotion,
    content: Theme(
      data: theme,
      child: MornyeGlassPanel.overlay(
        radius: 24,
        // Messages have no modal scrim; let more of the page show through.
        tintOpacity: 0.48,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
          child: DefaultTextStyle(
            style: theme.textTheme.bodyMedium!.copyWith(
              color: theme.colorScheme.onSurface,
            ),
            child: LayoutBuilder(
              builder: (context, constraints) {
                final actionBelow =
                    action != null &&
                    (constraints.maxWidth < 280 ||
                        MediaQuery.textScalerOf(context).scale(14) > 18);
                final message = Row(
                  children: [
                    Expanded(child: content),
                    if (!actionBelow) ?action,
                    AppIconButton(
                      tooltip: MaterialLocalizations.of(
                        context,
                      ).closeButtonTooltip,
                      color: theme.colorScheme.onSurface,
                      onPressed: messenger.hideCurrentSnackBar,
                      icon: const AppIcon.adaptive(Icons.close, size: 20),
                    ),
                  ],
                );
                return actionBelow
                    ? Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          message,
                          Align(
                            alignment: AlignmentDirectional.centerEnd,
                            child: action,
                          ),
                        ],
                      )
                    : message;
              },
            ),
          ),
        ),
      ),
    ),
  );
  return messenger.showSnackBar(snackBar);
}

class _MornyeSnackBar extends SnackBar {
  const _MornyeSnackBar({
    required super.content,
    required super.duration,
    required this.reduceMotion,
  }) : super(
         behavior: SnackBarBehavior.floating,
         backgroundColor: Colors.transparent,
         elevation: 0,
         clipBehavior: Clip.none,
         persist: false,
         showCloseIcon: false,
         padding: EdgeInsets.zero,
         margin: const EdgeInsets.fromLTRB(20, 8, 20, 12),
         shape: const RoundedRectangleBorder(
           borderRadius: BorderRadius.all(Radius.circular(24)),
         ),
       );

  final bool reduceMotion;

  @override
  SnackBar withAnimation(Animation<double> newAnimation, {Key? fallbackKey}) {
    // Keep the messenger's controller/timer for queuing and dismissal, but
    // replace Material's opacity layer with movement so blur samples the page.
    return SnackBar(
      key: key ?? fallbackKey,
      duration: duration,
      persist: false,
      showCloseIcon: false,
      behavior: behavior,
      backgroundColor: backgroundColor,
      elevation: elevation,
      clipBehavior: clipBehavior,
      padding: padding,
      margin: margin,
      shape: shape,
      animation: const AlwaysStoppedAnimation(1),
      content: AnimatedBuilder(
        animation: newAnimation,
        child: content,
        builder: (context, child) => Transform.translate(
          offset: Offset(
            0,
            reduceMotion
                ? 0
                : 8 *
                      (1 -
                          MornyeMotion.fast.curve.transform(
                            newAnimation.value,
                          )),
          ),
          child: child,
        ),
      ),
    );
  }
}
