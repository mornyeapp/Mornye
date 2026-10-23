import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:dynamic_color/dynamic_color.dart';
import 'package:material_ui/material_ui.dart' as material_ui;
import 'package:mornye/providers/theme_provider.dart';
import 'package:mornye/providers/custom_font_provider.dart';
import 'package:mornye/theme/app_theme.dart';
import 'package:mornye/models/theme_settings.dart';
import 'package:mornye/theme/mornye_theme.dart';

class DynamicColorWrapper extends ConsumerWidget {
  final Widget Function(ThemeData light, ThemeData dark, ThemeMode mode)
  builder;

  const DynamicColorWrapper({super.key, required this.builder});

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
    final fontFamily = ref.watch(customFontFamilyProvider).asData?.value;

    // Both styles build below the same DynamicColorBuilder. Switching styles
    // must update the app in place: a different parent remounted the whole
    // app, losing its state and briefly mounting a second macOS menu bar.
    return DynamicColorBuilder(
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

        ColorScheme lightScheme;
        ColorScheme darkScheme;

        if (themeSettings.useDynamicColor &&
            lightDynamic != null &&
            darkDynamic != null) {
          lightScheme = _toFlutterColorScheme(lightDynamic);
          darkScheme = _toFlutterColorScheme(darkDynamic);
        } else {
          final seedColor = themeSettings.seedColor;
          lightScheme = ColorScheme.fromSeed(
            seedColor: seedColor,
            brightness: Brightness.light,
          );
          darkScheme = ColorScheme.fromSeed(
            seedColor: seedColor,
            brightness: Brightness.dark,
          );
        }

        if (themeSettings.useAmoled) {
          darkScheme = _applyAmoledColors(darkScheme);
        }

        final lightTheme = AppTheme.light(
          dynamicScheme: lightScheme,
          useSystemFont: themeSettings.useSystemFont,
          fontFamily: fontFamily,
        );
        final darkTheme = AppTheme.dark(
          dynamicScheme: darkScheme,
          isAmoled: themeSettings.useAmoled,
          useSystemFont: themeSettings.useSystemFont,
          fontFamily: fontFamily,
        );

        return builder(lightTheme, darkTheme, themeSettings.themeMode);
      },
    );
  }

  ColorScheme _toFlutterColorScheme(material_ui.ColorScheme scheme) {
    return ColorScheme.fromSeed(
      seedColor: scheme.primary,
      brightness: scheme.brightness,
    ).copyWith(
      primary: scheme.primary,
      onPrimary: scheme.onPrimary,
      primaryContainer: scheme.primaryContainer,
      onPrimaryContainer: scheme.onPrimaryContainer,
      secondary: scheme.secondary,
      onSecondary: scheme.onSecondary,
      secondaryContainer: scheme.secondaryContainer,
      onSecondaryContainer: scheme.onSecondaryContainer,
      tertiary: scheme.tertiary,
      onTertiary: scheme.onTertiary,
      tertiaryContainer: scheme.tertiaryContainer,
      onTertiaryContainer: scheme.onTertiaryContainer,
      error: scheme.error,
      onError: scheme.onError,
      errorContainer: scheme.errorContainer,
      onErrorContainer: scheme.onErrorContainer,
      outline: scheme.outline,
      outlineVariant: scheme.outlineVariant,
      surface: scheme.surface,
      onSurface: scheme.onSurface,
      surfaceContainerLowest: scheme.surfaceContainerLowest,
      surfaceContainerLow: scheme.surfaceContainerLow,
      surfaceContainer: scheme.surfaceContainer,
      surfaceContainerHigh: scheme.surfaceContainerHigh,
      surfaceContainerHighest: scheme.surfaceContainerHighest,
      onSurfaceVariant: scheme.onSurfaceVariant,
      inverseSurface: scheme.inverseSurface,
      onInverseSurface: scheme.onInverseSurface,
      inversePrimary: scheme.inversePrimary,
      shadow: scheme.shadow,
      surfaceTint: scheme.surfaceTint,
      scrim: scheme.scrim,
    );
  }

  /// Apply AMOLED colors: a pure black page with a neutral container ladder.
  ///
  /// The tiers keep the M3 dark tone steps around the container (low -2,
  /// high +5, highest +10), anchored near tone 7 so the lowest raised tier,
  /// used by menus, still reads against black where shadows do not show.
  ColorScheme _applyAmoledColors(ColorScheme scheme) {
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
