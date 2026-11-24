import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/providers/theme_provider.dart';
import 'package:mornye/providers/custom_font_provider.dart';
import 'package:mornye/theme/app_theme.dart';
import 'package:mornye/models/theme_settings.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/utils/desktop_platform.dart';

class DynamicColorWrapper extends ConsumerWidget {
  final Widget Function(ThemeData light, ThemeData dark, ThemeMode mode)
  builder;

  const DynamicColorWrapper({super.key, required this.builder});

  static final _materialThemeCache = <Object, (ThemeData, ThemeData)>{};
  static const int _maxMaterialThemeCache = 12;

  static (ThemeData, ThemeData) _buildMaterialThemes({
    required bool useDynamicColor,
    required ColorScheme? lightDynamic,
    required ColorScheme? darkDynamic,
    required Color seedColor,
    required bool useAmoled,
    required bool useSystemFont,
    required String? fontFamily,
  }) {
    // Themes bake in the platform, which tests switch within one run.
    final key = (
      isDesktopPlatform,
      defaultTargetPlatform,
      useDynamicColor,
      useDynamicColor ? lightDynamic : null,
      useDynamicColor ? darkDynamic : null,
      useDynamicColor && lightDynamic != null && darkDynamic != null
          ? null
          : seedColor,
      useAmoled,
      useSystemFont,
      fontFamily,
    );
    final cached = _materialThemeCache[key];
    if (cached != null) return cached;

    ColorScheme lightScheme;
    ColorScheme darkScheme;

    if (useDynamicColor && lightDynamic != null && darkDynamic != null) {
      lightScheme = lightDynamic;
      darkScheme = darkDynamic;
    } else {
      lightScheme = ColorScheme.fromSeed(
        seedColor: seedColor,
        brightness: Brightness.light,
      );
      darkScheme = ColorScheme.fromSeed(
        seedColor: seedColor,
        brightness: Brightness.dark,
      );
    }

    if (useAmoled) {
      darkScheme = _applyAmoledColors(darkScheme);
    }

    final built = (
      AppTheme.light(
        dynamicScheme: lightScheme,
        useSystemFont: useSystemFont,
        fontFamily: fontFamily,
      ),
      AppTheme.dark(
        dynamicScheme: darkScheme,
        isAmoled: useAmoled,
        useSystemFont: useSystemFont,
        fontFamily: fontFamily,
      ),
    );
    if (_materialThemeCache.length >= _maxMaterialThemeCache) {
      _materialThemeCache.remove(_materialThemeCache.keys.first);
    }
    _materialThemeCache[key] = built;
    return built;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Lyrics size and font names live in ThemeSettings but not in ThemeData.
    final themeSettings = ref.watch(
      themeProvider.select(
        (s) => (
          style: s.style,
          themeMode: s.themeMode,
          useDynamicColor: s.useDynamicColor,
          seedColor: s.seedColor,
          useAmoled: s.useAmoled,
          mornyeAccent: s.mornyeAccent,
          useSystemFont: s.useSystemFont,
          mornyeGlassClarity: s.mornyeGlassClarity,
          mornyeGlassOutlines: s.mornyeGlassOutlines,
        ),
      ),
    );
    // Only the family: a rebuild while it loads would animate an equal theme.
    final fontFamily = ref.watch(
      customFontFamilyProvider.select((font) => font.asData?.value),
    );

    // Both styles build below the same _DynamicColorBuilder. Switching styles
    // must update the app in place: a different parent remounted the whole
    // app, losing its state and briefly mounting a second macOS menu bar.
    return _DynamicColorBuilder(
      colors: ref.watch(initialDynamicColorsProvider),
      builder: (lightDynamic, darkDynamic) {
        if (themeSettings.style == AppThemeStyle.mornye) {
          return builder(
            MornyeTheme.build(
              Brightness.light,
              accent: themeSettings.mornyeAccent,
              useSystemFont: themeSettings.useSystemFont,
              fontFamily: fontFamily,
              glassClarity: themeSettings.mornyeGlassClarity,
              glassOutlines: themeSettings.mornyeGlassOutlines,
            ),
            MornyeTheme.build(
              Brightness.dark,
              accent: themeSettings.mornyeAccent,
              useSystemFont: themeSettings.useSystemFont,
              fontFamily: fontFamily,
              glassClarity: themeSettings.mornyeGlassClarity,
              glassOutlines: themeSettings.mornyeGlassOutlines,
            ),
            themeSettings.themeMode,
          );
        }

        final (lightTheme, darkTheme) = _buildMaterialThemes(
          useDynamicColor: themeSettings.useDynamicColor,
          lightDynamic: lightDynamic,
          darkDynamic: darkDynamic,
          seedColor: themeSettings.seedColor,
          useAmoled: themeSettings.useAmoled,
          useSystemFont: themeSettings.useSystemFont,
          fontFamily: fontFamily,
        );

        return builder(lightTheme, darkTheme, themeSettings.themeMode);
      },
    );
  }

  /// Apply AMOLED colors: a pure black page with a neutral container ladder.
  ///
  /// The tiers keep the M3 dark tone steps around the container (low -2,
  /// high +5, highest +10), anchored near tone 7 so the lowest raised tier,
  /// used by menus, still reads against black where shadows do not show.
  static ColorScheme _applyAmoledColors(ColorScheme scheme) {
    return scheme.copyWith(
      surface: Colors.black,
      onSurface: Colors.white,
      surfaceContainerLowest: Colors.black,
      surfaceContainerLow: const Color(0xFF111111),
      surfaceContainer: const Color(0xFF161616),
      surfaceContainerHigh: const Color(0xFF1F1F1F),
      surfaceContainerHighest: const Color(0xFF2A2A2A),
      inverseSurface: Colors.white,
      onInverseSurface: Colors.black,
    );
  }
}

/// Builds with the system's colors. A launch request answered before the
/// first frame builds it with them, so the theme does not fade into them.
class _DynamicColorBuilder extends StatefulWidget {
  const _DynamicColorBuilder({required this.colors, required this.builder});

  final DynamicColors? colors;
  final Widget Function(ColorScheme? lightDynamic, ColorScheme? darkDynamic)
  builder;

  @override
  State<_DynamicColorBuilder> createState() => _DynamicColorBuilderState();
}

class _DynamicColorBuilderState extends State<_DynamicColorBuilder> {
  DynamicColorSchemes? _schemes;

  @override
  void initState() {
    super.initState();
    final colors = widget.colors ?? DynamicColors.request();
    if (colors.isSettled) {
      _schemes = colors.schemes;
      return;
    }
    colors.future.then<void>((schemes) {
      if (mounted && schemes != null) setState(() => _schemes = schemes);
    }, onError: (Object _) {});
  }

  @override
  Widget build(BuildContext context) =>
      widget.builder(_schemes?.light, _schemes?.dark);
}
