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
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/providers/equalizer_provider.dart';
import 'package:mornye/services/app_navigation_service.dart';
import 'package:mornye/services/app_orientation.dart';
import 'package:mornye/services/link/client/link_client_controller.dart';
import 'package:mornye/services/link/sync/link_sync_runner.dart';
import 'package:mornye/theme/dynamic_color_wrapper.dart';
import 'package:mornye/l10n/app_localizations.dart';
import 'package:mornye/l10n/supported_locales.dart';
import 'package:mornye/utils/adaptive_layout.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:mornye/widgets/app_snack_bar.dart';
import 'package:mornye/widgets/desktop/desktop_shortcuts.dart';
import 'package:mornye/widgets/desktop/library_drop_target.dart';
import 'package:mornye/widgets/mornye_glass_preparation.dart';
import 'package:mornye/widgets/playback_feedback.dart';

String initialLocationForAppState({
  required bool isFirstLaunch,
  required bool hasCompletedTutorial,
}) {
  if (isFirstLaunch) return '/setup';
  if (!hasCompletedTutorial) return '/tutorial';
  return '/';
}

final _routerProvider = Provider<GoRouter>((ref) {
  final routingSettings = ref.watch(
    settingsProvider.select(
      (settings) => (
        isFirstLaunch: settings.isFirstLaunch,
        hasCompletedTutorial: settings.hasCompletedTutorial,
      ),
    ),
  );

  final initialLocation = initialLocationForAppState(
    isFirstLaunch: routingSettings.isFirstLaunch,
    hasCompletedTutorial: routingSettings.hasCompletedTutorial,
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
    ],
    // Safety net: if a deep link URL (e.g. Spotify/Deezer) somehow reaches
    // GoRouter, redirect to home instead of showing "Page Not Found".
    errorBuilder: (context, state) => const MainShell(),
  );
});

Locale _fallbackLocale(Iterable<Locale> supportedLocales) {
  for (final supportedLocale in supportedLocales) {
    if (supportedLocale.languageCode == 'en') {
      return supportedLocale;
    }
  }
  return supportedLocales.first;
}

Locale _resolveSupportedLocale(
  Locale? requestedLocale,
  Iterable<Locale> supportedLocales,
) {
  if (requestedLocale == null) {
    return _fallbackLocale(supportedLocales);
  }

  for (final supportedLocale in supportedLocales) {
    if (supportedLocale.languageCode == requestedLocale.languageCode &&
        supportedLocale.countryCode == requestedLocale.countryCode) {
      return supportedLocale;
    }
  }

  for (final supportedLocale in supportedLocales) {
    if (supportedLocale.languageCode == requestedLocale.languageCode) {
      return supportedLocale;
    }
  }

  return _fallbackLocale(supportedLocales);
}

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
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: CurvedAnimation(parent: _controller, curve: Curves.easeOut),
      child: widget.child,
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
    // On phones, keeps the link to a paired computer and its sync running.
    if (ref.read(linkClientSupportedProvider)) {
      ref.listen(linkClientControllerProvider, (_, _) {});
      ref.listen(linkSyncRunnerProvider, (_, _) {});
    }
    final router = ref.watch(_routerProvider);
    final localeString = ref.watch(settingsProvider.select((s) => s.locale));
    final heroAnimationsEnabled = ref.watch(
      settingsProvider.select((s) => s.heroAnimationsEnabled),
    );
    final scrollBehavior = appScrollBehavior(
      disableOverscrollEffects: disableOverscrollEffects,
    );

    Locale? locale;
    if (localeString != 'system' && localeString.isNotEmpty) {
      if (localeString.contains('_')) {
        final parts = localeString.split('_');
        if (parts.length == 2) {
          locale = Locale(parts[0], parts[1]);
        } else {
          locale = Locale(parts[0]);
        }
      } else {
        locale = Locale(localeString);
      }
    }

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
          // Treat the display as one continuous surface so bottom sheets and
          // dialogs stay centered on large/foldable devices.
          builder: (context, child) {
            final mediaQuery = MediaQuery.of(context);
            Widget appContent = _OrientationFade(
              child: AppScaffoldMessenger(
                child: PlaybackFeedback(
                  child: DesktopLibraryDropTarget(
                    child: child ?? const SizedBox.shrink(),
                  ),
                ),
              ),
            );
            // HeroMode only affects heroes below a *route* subtree. At this
            // level it sits above the router's Navigator, so the controller
            // never encounters it while collecting heroes. Removing the
            // inherited controller disables flights on the root Navigator.
            if (!heroAnimationsEnabled) {
              appContent = HeroControllerScope.none(child: appContent);
            }
            // Above the root navigator, so shortcuts and the macOS menu bar
            // also reach Now Playing, dialogs and pushed pages. It stays
            // outside every conditional wrapper: remounting it would mount a
            // second macOS menu bar before the first is gone.
            if (isDesktopPlatform) {
              appContent = DesktopShortcuts(child: appContent);
            }
            return MediaQuery(
              data: mediaQuery.copyWith(displayFeatures: const []),
              child: MornyeGlassPreparation(
                child: AdaptiveUiScaler(child: appContent),
              ),
            );
          },
          routerConfig: router,
          locale: locale,
          localeResolutionCallback: (deviceLocale, supportedLocales) {
            return _resolveSupportedLocale(
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
