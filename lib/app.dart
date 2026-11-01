import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:material_ui/material_ui.dart' as material_ui;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:go_router/go_router.dart';
import 'package:mornye/constants/app_info.dart';
import 'package:mornye/screens/main_shell.dart';
import 'package:mornye/screens/setup_screen.dart';
import 'package:mornye/screens/tutorial_screen.dart';
import 'package:mornye/screens/whats_new_screen.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/providers/equalizer_provider.dart';
import 'package:mornye/services/app_navigation_service.dart';
import 'package:mornye/services/app_orientation.dart';
import 'package:mornye/services/link/client/link_client_controller.dart';
import 'package:mornye/services/link/features/link_phone_features.dart';
import 'package:mornye/services/link/sync/link_sync_runner.dart';
import 'package:mornye/theme/dynamic_color_wrapper.dart';
import 'package:mornye/l10n/app_localizations.dart';
import 'package:mornye/l10n/supported_locales.dart';
import 'package:mornye/utils/adaptive_layout.dart';
import 'package:mornye/utils/android_tv.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:mornye/widgets/app_snack_bar.dart';
import 'package:mornye/widgets/desktop/desktop_shortcuts.dart';
import 'package:mornye/widgets/desktop/library_drop_target.dart';
import 'package:mornye/widgets/link/link_actions.dart';
import 'package:mornye/widgets/mornye_glass_preparation.dart';
import 'package:mornye/widgets/playback_feedback.dart';
import 'package:mornye/widgets/tv_navigation.dart';

String initialLocationForAppState({
  required bool isFirstLaunch,
  required bool hasCompletedTutorial,
  bool hasSeenWhatsNew = true,
}) {
  if (isFirstLaunch) return '/setup';
  if (!hasCompletedTutorial) return '/tutorial';
  if (!hasSeenWhatsNew) return '/whats-new';
  return '/';
}

final _routerProvider = Provider<GoRouter>((ref) {
  final routingSettings = ref.watch(
    settingsProvider.select(
      (settings) => (
        isFirstLaunch: settings.isFirstLaunch,
        hasCompletedTutorial: settings.hasCompletedTutorial,
        // Desktop shows the tour as a dialog over the shell instead.
        hasSeenWhatsNew:
            isDesktopPlatform ||
            settings.whatsNewSeen == AppInfo.whatsNewRelease,
      ),
    ),
  );

  final initialLocation = initialLocationForAppState(
    isFirstLaunch: routingSettings.isFirstLaunch,
    hasCompletedTutorial: routingSettings.hasCompletedTutorial,
    hasSeenWhatsNew: routingSettings.hasSeenWhatsNew,
  );

  return GoRouter(
    navigatorKey: AppNavigationService.rootNavigatorKey,
    observers: [AppOrientationObserver()],
    initialLocation: initialLocation,
    routes: [
      GoRoute(path: '/', builder: (context, state) => const MainShell()),
      GoRoute(path: '/setup', builder: (context, state) => const SetupScreen()),
      GoRoute(
        path: '/tutorial',
        builder: (context, state) => const TutorialScreen(),
      ),
      GoRoute(
        path: '/whats-new',
        builder: (context, state) => const WhatsNewScreen(),
      ),
    ],
    // Safety net: if a deep link URL (e.g. Spotify/Deezer) somehow reaches
    // GoRouter, redirect to home instead of showing "Page Not Found".
    errorBuilder: (context, state) => const MainShell(),
  );
});

/// iOS-style fluid scroll on mobile and macOS: momentum glide + bounce instead
/// of the Android clamping stop. Widgets that set explicit physics (queue filter
/// PageView, bottom sheets) are unaffected.
class _FluidScrollBehavior extends _VerticalScrollbarBehavior {
  const _FluidScrollBehavior();

  @override
  ScrollPhysics getScrollPhysics(BuildContext context) =>
      const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics());
}

/// Desktop scrollbars mark long vertical content only. Rows that scroll
/// sideways (carousels, shelves, recent cards) already show arrows and read
/// cleaner without a bar.
class _VerticalScrollbarBehavior extends MaterialScrollBehavior {
  const _VerticalScrollbarBehavior();

  @override
  Widget buildScrollbar(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) => axisDirectionToAxis(details.direction) == Axis.horizontal
      ? child
      : super.buildScrollbar(context, child, details);
}

/// Mobile and macOS use the fluid bounce. Windows and Linux keep Material's
/// desktop behavior: clamping physics with scrollbars.
@visibleForTesting
ScrollBehavior appScrollBehavior({required bool disableOverscrollEffects}) {
  if (disableOverscrollEffects) {
    return const _VerticalScrollbarBehavior().copyWith(overscroll: false);
  }
  if (isDesktopPlatform && defaultTargetPlatform != TargetPlatform.macOS) {
    return const _VerticalScrollbarBehavior();
  }
  return const _FluidScrollBehavior();
}

/// Fades the app content in after an orientation change or a width change
/// across the shell's rail breakpoint (fold/unfold, split-screen resize) —
/// Flutter reflows the layout in a single frame, so without this the new
/// layout pops in.
class _OrientationFade extends StatefulWidget {
  final Widget child;

  const _OrientationFade({required this.child});

  @override
  State<_OrientationFade> createState() => _OrientationFadeState();
}

class _OrientationFadeState extends State<_OrientationFade>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 300),
    value: 1,
  );
  late final _opacity = CurvedAnimation(
    parent: _controller,
    curve: Curves.easeOut,
  );
  Orientation? _lastOrientation;
  double? _lastWidth;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final orientation = MediaQuery.orientationOf(context);
    final width = MediaQuery.sizeOf(context).width;
    final orientationChanged =
        _lastOrientation != null && orientation != _lastOrientation;
    final crossedRailBreakpoint =
        _lastWidth != null &&
        useNavigationRailForWidth(_lastWidth!) !=
            useNavigationRailForWidth(width);
    if (orientationChanged || crossedRailBreakpoint) {
      _controller.forward(from: 0);
    }
    _lastOrientation = orientation;
    _lastWidth = width;
  }

  @override
  void dispose() {
    _opacity.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(opacity: _opacity, child: widget.child);
  }
}

/// The [MaterialApp.builder] of [MornyeApp]: the app-wide layers around the
/// router's [child].
@visibleForTesting
Widget buildAppContent(
  BuildContext context,
  Widget? child, {
  required bool heroAnimationsEnabled,
}) {
  Widget appContent = _OrientationFade(
    child: AppScaffoldMessenger(
      child: PlaybackFeedback(
        child: DesktopLibraryDropTarget(
          child: child ?? const SizedBox.shrink(),
        ),
      ),
    ),
  );
  // HeroMode only affects heroes below a *route* subtree. At this level it
  // sits above the router's Navigator, so the controller never encounters it
  // while collecting heroes. Removing the inherited controller disables
  // flights on the root Navigator.
  if (!heroAnimationsEnabled) {
    appContent = HeroControllerScope.none(child: appContent);
  }
  // Above the root navigator, so shortcuts and the macOS menu bar also reach
  // Now Playing, dialogs and pushed pages. It stays outside every conditional
  // wrapper: remounting it would mount a second macOS menu bar before the
  // first is gone.
  if (isDesktopPlatform) {
    appContent = DesktopShortcuts(child: appContent);
  }
  if (isAndroidTv) {
    appContent = ColoredBox(
      color: Theme.of(context).scaffoldBackgroundColor,
      child: SafeArea(
        minimum: const EdgeInsets.symmetric(horizontal: 40, vertical: 24),
        child: TvNavigation(child: appContent),
      ),
    );
  }
  return _AppMediaQuery(child: appContent);
}

/// Treats the display as one continuous surface so bottom sheets and dialogs
/// stay centered on large/foldable devices. The window metrics are read here
/// rather than in [buildAppContent], so a resize rebuilds only these layers
/// and passes the app content through unchanged.
class _AppMediaQuery extends StatelessWidget {
  final Widget child;

  const _AppMediaQuery({required this.child});

  @override
  Widget build(BuildContext context) {
    final mediaQuery = MediaQuery.of(context);
    return MediaQuery(
      data: mediaQuery.copyWith(
        displayFeatures: const [],
        navigationMode: isAndroidTv
            ? NavigationMode.directional
            : mediaQuery.navigationMode,
      ),
      child: MornyeGlassPreparation(child: AdaptiveUiScaler(child: child)),
    );
  }
}

class MornyeApp extends ConsumerWidget {
  final bool disableOverscrollEffects;

  const MornyeApp({super.key, this.disableOverscrollEffects = false});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Keeps the equalizer loaded for the app's lifetime without rebuilding.
    ref.listen(equalizerProvider, (_, _) {});
    // On phones, keeps the link to a paired computer, its sync and the
    // remote control features running.
    if (ref.read(linkClientSupportedProvider)) {
      ref.listen(linkClientControllerProvider, (_, _) {});
      ref.listen(linkSyncRunnerProvider, (_, _) {});
      ref.listen(linkPhoneFeaturesProvider, (_, _) {});
      ref.listen(linkTransferOfferNoticesProvider, (_, _) {});
    }
    final router = ref.watch(_routerProvider);
    final localeString = ref.watch(settingsProvider.select((s) => s.locale));
    final heroAnimationsEnabled = ref.watch(
      settingsProvider.select((s) => s.heroAnimationsEnabled),
    );
    final scrollBehavior = appScrollBehavior(
      disableOverscrollEffects: disableOverscrollEffects,
    );

    final locale = localeFromSetting(localeString);

    return DynamicColorWrapper(
      builder: (lightTheme, darkTheme, themeMode) {
        return MaterialApp.router(
          title: AppInfo.appName,
          debugShowCheckedModeBanner: false,
          theme: lightTheme,
          darkTheme: darkTheme,
          themeMode: themeMode,
          scrollBehavior: scrollBehavior,
          themeAnimationDuration: const Duration(milliseconds: 300),
          themeAnimationCurve: Curves.easeInOut,
          builder: (context, child) => buildAppContent(
            context,
            child,
            heroAnimationsEnabled: heroAnimationsEnabled,
          ),
          routerConfig: router,
          locale: locale,
          localeResolutionCallback: (deviceLocale, supportedLocales) {
            return resolveSupportedLocale(
              locale ?? deviceLocale,
              supportedLocales,
            );
          },
          localizationsDelegates: const [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            material_ui.GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          // ARB files below the translation threshold remain bundled so
          // translators can test them, but production users should only be
          // offered locales selected by the completion checker.
          supportedLocales: filteredSupportedLocales,
        );
      },
    );
  }
}
