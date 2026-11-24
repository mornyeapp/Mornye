import 'package:material_ui/material_ui.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/widgets/skip_autofocus.dart';

/// Motion-heavy expressive controls use their static Material counterpart when
/// the OS requests reduced motion. Mornye owns its own component system.
bool materialExpressiveEnabled(BuildContext context) =>
    !context.isMornye && !MediaQuery.disableAnimationsOf(context);

/// Bridges the app's Flutter theme to the separate Material UI widget library.
/// Local artwork colors, dynamic colors, fonts and AMOLED surfaces stay intact.
class MaterialExpressiveScope extends StatelessWidget {
  const MaterialExpressiveScope({
    super.key,
    required this.child,
    this.skipAutofocus = false,
  });

  final Widget child;

  /// Keeps [child] from taking keyboard focus as it mounts. `M3EButtonGroup`
  /// autofocuses its first segment, which would take Space from playback on
  /// desktop.
  final bool skipAutofocus;
  static final _themes = Expando<ThemeData>();
  static final _expressiveThemes = Expando<M3EThemeData>();

  static ThemeData _adapt(ThemeData theme) {
    final cached = _themes[theme];
    if (cached != null) return cached;
    final c = theme.colorScheme;
    final t = theme.textTheme;
    final adapted = ThemeData(
      brightness: theme.brightness,
      platform: theme.platform,
      useMaterial3: true,
      scaffoldBackgroundColor: theme.scaffoldBackgroundColor,
      colorScheme: ColorScheme(
        brightness: c.brightness,
        primary: c.primary,
        onPrimary: c.onPrimary,
        primaryContainer: c.primaryContainer,
        onPrimaryContainer: c.onPrimaryContainer,
        primaryFixed: c.primaryFixed,
        primaryFixedDim: c.primaryFixedDim,
        onPrimaryFixed: c.onPrimaryFixed,
        onPrimaryFixedVariant: c.onPrimaryFixedVariant,
        secondary: c.secondary,
        onSecondary: c.onSecondary,
        secondaryContainer: c.secondaryContainer,
        onSecondaryContainer: c.onSecondaryContainer,
        secondaryFixed: c.secondaryFixed,
        secondaryFixedDim: c.secondaryFixedDim,
        onSecondaryFixed: c.onSecondaryFixed,
        onSecondaryFixedVariant: c.onSecondaryFixedVariant,
        tertiary: c.tertiary,
        onTertiary: c.onTertiary,
        tertiaryContainer: c.tertiaryContainer,
        onTertiaryContainer: c.onTertiaryContainer,
        tertiaryFixed: c.tertiaryFixed,
        tertiaryFixedDim: c.tertiaryFixedDim,
        onTertiaryFixed: c.onTertiaryFixed,
        onTertiaryFixedVariant: c.onTertiaryFixedVariant,
        error: c.error,
        onError: c.onError,
        errorContainer: c.errorContainer,
        onErrorContainer: c.onErrorContainer,
        surface: c.surface,
        onSurface: c.onSurface,
        onSurfaceVariant: c.onSurfaceVariant,
        surfaceDim: c.surfaceDim,
        surfaceBright: c.surfaceBright,
        surfaceContainerLowest: c.surfaceContainerLowest,
        surfaceContainerLow: c.surfaceContainerLow,
        surfaceContainer: c.surfaceContainer,
        surfaceContainerHigh: c.surfaceContainerHigh,
        surfaceContainerHighest: c.surfaceContainerHighest,
        outline: c.outline,
        outlineVariant: c.outlineVariant,
        inverseSurface: c.inverseSurface,
        onInverseSurface: c.onInverseSurface,
        inversePrimary: c.inversePrimary,
        shadow: c.shadow,
        scrim: c.scrim,
        surfaceTint: c.surfaceTint,
      ),
      textTheme: TextTheme(
        displayLarge: t.displayLarge,
        displayMedium: t.displayMedium,
        displaySmall: t.displaySmall,
        headlineLarge: t.headlineLarge,
        headlineMedium: t.headlineMedium,
        headlineSmall: t.headlineSmall,
        titleLarge: t.titleLarge,
        titleMedium: t.titleMedium,
        titleSmall: t.titleSmall,
        bodyLarge: t.bodyLarge,
        bodyMedium: t.bodyMedium,
        bodySmall: t.bodySmall,
        labelLarge: t.labelLarge,
        labelMedium: t.labelMedium,
        labelSmall: t.labelSmall,
      ),
    );
    _themes[theme] = adapted;
    return adapted;
  }

  @override
  Widget build(BuildContext context) {
    final host = Theme.of(context);
    final theme = _adapt(host);
    final expressive = _expressiveThemes[theme] ??=
        M3EThemeData.fromMaterial(theme).copyWith(
          fontFamily: theme.textTheme.bodyMedium?.fontFamily,
          navigationBarTheme: const M3ENavigationBarTheme(heightMedium: 72),
        );
    final content = M3ETheme(
      data: expressive,
      // M3E's projection omits fixed color roles. Keep the complete host theme
      // nearest the widgets so it also retains AMOLED, platform typography,
      // component themes and extensions. The app and M3E share one Theme
      // type, so the adapted theme here would hide them from the app widgets.
      child: Theme(
        data: host,
        child: skipAutofocus ? SkipAutofocus(child: child) : child,
      ),
    );
    if (Localizations.of<MaterialLocalizations>(
          context,
          MaterialLocalizations,
        ) !=
        null) {
      return content;
    }
    // Also support isolated sheets/previews hosted by a Flutter MaterialApp.
    return Localizations.override(
      context: context,
      delegates: const [GlobalMaterialLocalizations.delegate],
      child: Directionality(
        textDirection: Directionality.of(context),
        child: content,
      ),
    );
  }
}
