import 'dart:io' show Platform;

/// Set with `--dart-define=MORNYE_MOBILE=true` on Android and iOS release
/// builds so Dart AOT can tree-shake desktop-only dependencies and UI paths.
const bool kMornyeMobileBuild = bool.fromEnvironment('MORNYE_MOBILE');

/// Overrides [isDesktopPlatform] in tests.
bool? debugDesktopPlatformOverride;

// `flutter test` runs on a desktop host; tests see a mobile app unless they
// opt in through [debugDesktopPlatformOverride].
final bool _hostIsDesktop =
    !Platform.environment.containsKey('FLUTTER_TEST') &&
    (Platform.isMacOS || Platform.isWindows || Platform.isLinux);

/// True in Windows, Linux and macOS builds of the app.
bool get isDesktopPlatform => kMornyeMobileBuild
    ? false
    : (debugDesktopPlatformOverride ?? _hostIsDesktop);
