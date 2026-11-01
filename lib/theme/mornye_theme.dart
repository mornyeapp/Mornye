import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:mornye/models/theme_settings.dart';
import 'package:mornye/theme/app_tokens.dart';

/// Flutter counterpart of Mornye's iPhone visual system. Reference values come
/// from AccentColor.colorset, Components.swift, PlayerViews.swift and Motion.md
/// in the Mornye project; keep this palette independent of wallpaper colors.
@immutable
class MornyeTheme extends ThemeExtension<MornyeTheme> {
  const MornyeTheme({
    this.chromeSurface,
    this.accent = MornyeAccent.red,
    this.useSystemFont = false,
    this.fontFamily,
    this.glassClarity = kDefaultMornyeGlassClarity,
    this.glassOutlines = true,
  });

  final Color? chromeSurface;
  final MornyeAccent accent;
  final bool useSystemFont;
  final String? fontFamily;
  final double glassClarity;
  final bool glassOutlines;

  static double glassClarityOf(BuildContext context) =>
      Theme.of(context).extension<MornyeTheme>()?.glassClarity ??
      kDefaultMornyeGlassClarity;

  static bool glassOutlinesOf(BuildContext context) =>
      Theme.of(context).extension<MornyeTheme>()?.glassOutlines ?? true;

  /// A single translucent fill for controls inside an existing glass surface.
  static Color controlFill(BuildContext context, {bool enabled = true}) {
    final theme = Theme.of(context);
    return theme.colorScheme.onSurface.withValues(
      alpha: !enabled
          ? 0.04
          : theme.brightness == Brightness.dark
          ? 0.10
          : 0.07,
    );
  }

  /// Separators blend with their group, keeping definition on pages and sheets.
  static Color metadataDividerColor(BuildContext context) {
    final theme = Theme.of(context);
    return theme.colorScheme.onSurface.withValues(
      alpha: theme.brightness == Brightness.dark ? 0.14 : 0.17,
    );
  }

  static double chromeOpacity(BuildContext context) {
    final theme = Theme.of(context);
    if (theme.extension<MornyeTheme>()?.chromeSurface != null) return 0.36;
    // Light glass needs more fill to keep dark subtitles readable over black.
    return theme.brightness == Brightness.dark ? 0.60 : 0.70;
  }

  static double navigationOpacity(BuildContext context) {
    final theme = Theme.of(context);
    if (theme.extension<MornyeTheme>()?.chromeSurface != null) return 0.24;
    return theme.brightness == Brightness.dark ? 0.36 : 0.49;
  }

  static const lightAccent = Color.fromRGBO(204, 46, 51, 1);
  // iOS dark systemRed: accent text stays readable on #1C1C1E cells.
  static const darkAccent = Color.fromRGBO(255, 69, 58, 1);

  static Color accentColor(MornyeAccent accent, Brightness brightness) {
    final dark = brightness == Brightness.dark;
    final color = switch (accent) {
      MornyeAccent.red => const CupertinoDynamicColor.withBrightness(
        color: lightAccent,
        darkColor: darkAccent,
      ),
      MornyeAccent.orange => CupertinoColors.systemOrange,
      MornyeAccent.green => CupertinoColors.systemGreen,
      MornyeAccent.teal => CupertinoColors.systemTeal,
      MornyeAccent.blue => CupertinoColors.systemBlue,
      MornyeAccent.purple => CupertinoColors.systemPurple,
      MornyeAccent.pink => CupertinoColors.systemPink,
    };
    // Accents also label links and small controls on white surfaces.
    if (!dark && accent == MornyeAccent.green) return const Color(0xff24863d);
    return dark ? color.darkColor : color.highContrastColor;
  }

  static final tokens = AppTokens.standard.copyWith(
    radiusBadge: 5,
    radiusThumb: 6,
    radiusCover: 10,
    radiusControl: 12,
    radiusCard: 12,
    radiusSheet: 32,
    coverMini: 38,
    headerExpandedTitleSize: 34,
    headerCollapsedTitleSize: 17,
    motionFast: const Duration(milliseconds: 180),
    motionMedium: const Duration(milliseconds: 220),
    motionSlow: const Duration(milliseconds: 380),
    rowPaddingH: 16,
    rowPaddingV: 10,
    rowPaddingVCompact: 8,
    rowIconGap: 12,
    rowIconDividerIndent: 52,
    rowChevronSize: 18,
    rowMinHeight: 28,
    trackRowPaddingV: 12,
    headerSubtitleSize: 20,
    lyricsLineHeight: 1.3,
    lyricsLinePaddingV: 16,
    playerControlGap: 12,
    dialogInsetH: 24,
  );

  // Theme construction includes seeded color generation and typography. Reuse
  // identical themes across routes; bound artwork-derived variants so browsing
  // many artists cannot grow the cache indefinitely. Platform is part of the
  // key because it controls fonts and route transitions.
  static final _themeCache =
      <
        (TargetPlatform, Brightness, Color?, MornyeAccent, bool, String?),
        ThemeData
      >{};
  static final _glassVariants = Expando<ThemeData>();

  static ThemeData build(
    Brightness brightness, {
    Color? chromeSurface,
    MornyeAccent accent = MornyeAccent.red,
    bool useSystemFont = false,
    String? fontFamily,
    double glassClarity = kDefaultMornyeGlassClarity,
    bool glassOutlines = true,
  }) {
    final key = (
      defaultTargetPlatform,
      brightness,
      chromeSurface,
      accent,
      useSystemFont,
      fontFamily,
    );
    var theme = _themeCache.remove(key);
    // Artwork chrome only tints a few roles, so derive it from the base theme.
    theme ??= chromeSurface == null
        ? _build(
            brightness,
            selectedAccent: accent,
            useSystemFont: useSystemFont,
            fontFamily: fontFamily,
          )
        : _withChromeSurface(
            build(
              brightness,
              accent: accent,
              useSystemFont: useSystemFont,
              fontFamily: fontFamily,
            ),
            chromeSurface,
          );
    if (_themeCache.length >= 16) {
      _themeCache.remove(_themeCache.keys.first);
    }
    _themeCache[key] = theme;
    return _withGlassPreferences(theme, glassClarity, glassOutlines);
  }

  static ThemeData _withChromeSurface(ThemeData theme, Color chromeSurface) {
    final scheme = theme.colorScheme.copyWith(
      surfaceContainerHigh: Color.lerp(chromeSurface, Colors.black, 0.16),
    );
    return theme.copyWith(
      colorScheme: scheme,
      buttonTheme: theme.buttonTheme.copyWith(colorScheme: scheme),
      snackBarTheme: theme.snackBarTheme.copyWith(
        backgroundColor: scheme.surfaceContainerHigh,
      ),
      extensions: [
        for (final extension in theme.extensions.values)
          if (extension is MornyeTheme)
            extension.copyWith(chromeSurface: chromeSurface)
          else
            extension,
      ],
    );
  }

  // Moving the clarity slider only changes the material, not typography or
  // seeded colors. Keep the expensive base theme cached independently, and
  // reuse the last variant so equal preferences keep the same theme identity.
  static ThemeData _withGlassPreferences(
    ThemeData theme,
    double value,
    bool outlines,
  ) {
    final clarity = normalizeMornyeGlassClarity(value);
    bool matches(ThemeData? candidate) {
      final preferences = candidate?.extension<MornyeTheme>();
      return preferences?.glassClarity == clarity &&
          preferences?.glassOutlines == outlines;
    }

    if (matches(theme)) return theme;
    final variant = _glassVariants[theme];
    if (matches(variant)) return variant!;
    return _glassVariants[theme] = theme.copyWith(
      extensions: [
        for (final extension in theme.extensions.values)
          if (extension is MornyeTheme)
            extension.copyWith(glassClarity: clarity, glassOutlines: outlines)
          else
            extension,
      ],
    );
  }

  /// Rebuild local surfaces without losing the user's Mornye preferences.
  static ThemeData fromContext(
    BuildContext context, {
    Brightness? brightness,
    Color? chromeSurface,
  }) {
    final theme = Theme.of(context);
    final preferences = theme.extension<MornyeTheme>();
    return build(
      brightness ?? theme.brightness,
      chromeSurface: chromeSurface,
      accent: preferences?.accent ?? MornyeAccent.red,
      useSystemFont: preferences?.useSystemFont ?? false,
      fontFamily: preferences?.fontFamily,
      glassClarity: preferences?.glassClarity ?? kDefaultMornyeGlassClarity,
      glassOutlines: preferences?.glassOutlines ?? true,
    );
  }

  static ThemeData _build(
    Brightness brightness, {
    required MornyeAccent selectedAccent,
    required bool useSystemFont,
    String? fontFamily,
  }) {
    final dark = brightness == Brightness.dark;
    final accent = accentColor(selectedAccent, brightness);
    final foreground = dark ? Colors.white : Colors.black;
    final surface = dark ? Colors.black : Colors.white;
    final grouped = dark ? const Color(0xff1c1c1e) : const Color(0xfff2f2f7);
    final secondary = dark ? const Color(0xff98989f) : const Color(0xff6c6c70);
    final scheme =
        ColorScheme.fromSeed(
          seedColor: accent,
          brightness: brightness,
        ).copyWith(
          primary: accent,
          onPrimary: accent.computeLuminance() < 0.179
              ? Colors.white
              : Colors.black,
          primaryContainer: grouped,
          onPrimaryContainer: accent,
          secondary: accent,
          onSecondary: Colors.white,
          secondaryContainer: grouped,
          onSecondaryContainer: foreground,
          surface: surface,
          onSurface: foreground,
          surfaceContainerLowest: surface,
          surfaceContainerLow: grouped,
          surfaceContainer: grouped,
          surfaceContainerHigh: dark ? const Color(0xff2c2c2e) : grouped,
          surfaceContainerHighest: dark
              ? const Color(0xff3a3a3c)
              : const Color(0xffe5e5ea),
          onSurfaceVariant: secondary,
          outline: secondary,
          outlineVariant: dark
              ? const Color(0xff38383a)
              : const Color(0xffc6c6c8),
          surfaceTint: Colors.transparent,
        );
    // Cupertino's font proxies resolve to SF on Apple and the platform fallback
    // elsewhere. Inter remains the default on other platforms unless opted out.
    final apple =
        defaultTargetPlatform == TargetPlatform.iOS ||
        defaultTargetPlatform == TargetPlatform.macOS;
    final type = CupertinoThemeData(brightness: brightness).textTheme;
    final text = type.textStyle.copyWith(
      inherit: true,
      color: foreground,
      fontFamily:
          fontFamily ??
          (apple || useSystemFont ? type.textStyle.fontFamily : 'Inter'),
    );
    final display = type.navLargeTitleTextStyle.copyWith(
      inherit: true,
      color: foreground,
      fontFamily:
          fontFamily ??
          (apple || useSystemFont
              ? type.navLargeTitleTextStyle.fontFamily
              : 'Inter'),
    );
    // Supply complete styles: replacing a Material role with a bare TextStyle
    // loses its system family and retains Material tracking in other roles.
    final typography = TextTheme(
      displayLarge: display.copyWith(fontSize: 57),
      displayMedium: display.copyWith(fontSize: 45),
      displaySmall: display.copyWith(fontSize: 36),
      headlineLarge: display,
      headlineMedium: display.copyWith(fontSize: 28, letterSpacing: 0.36),
      headlineSmall: display.copyWith(fontSize: 22, letterSpacing: 0.35),
      titleLarge: display.copyWith(
        fontSize: 20,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.38,
      ),
      titleMedium: text.copyWith(fontWeight: FontWeight.w500),
      titleSmall: text.copyWith(
        fontSize: 15,
        fontWeight: FontWeight.w600,
        letterSpacing: -0.23,
      ),
      bodyLarge: text,
      bodyMedium: text.copyWith(fontSize: 15, letterSpacing: -0.23),
      bodySmall: text.copyWith(
        fontSize: 13,
        letterSpacing: -0.08,
        color: secondary,
      ),
      labelLarge: text.copyWith(fontWeight: FontWeight.w600),
      labelMedium: text.copyWith(
        fontSize: 13,
        fontWeight: FontWeight.w500,
        letterSpacing: -0.08,
      ),
      labelSmall: text.copyWith(
        fontSize: 11,
        fontWeight: FontWeight.w500,
        letterSpacing: -0.24,
        color: secondary,
      ),
    );
    final base = ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
      scaffoldBackgroundColor: surface,
      fontFamily: text.fontFamily,
      splashFactory: NoSplash.splashFactory,
      extensions: <ThemeExtension<dynamic>>[
        MornyeTheme(
          accent: selectedAccent,
          useSystemFont: useSystemFont,
          fontFamily: fontFamily,
        ),
        tokens,
      ],
    );
    final controlShape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(12),
    );
    return base.copyWith(
      textTheme: typography,
      primaryTextTheme: typography.apply(
        bodyColor: scheme.onPrimary,
        displayColor: scheme.onPrimary,
      ),
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          TargetPlatform.android: FadeForwardsPageTransitionsBuilder(),
          TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
          TargetPlatform.macOS: CupertinoPageTransitionsBuilder(),
        },
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: surface,
        foregroundColor: accent,
        elevation: 0,
        scrolledUnderElevation: 0,
        surfaceTintColor: Colors.transparent,
        centerTitle: true,
        titleTextStyle: text.copyWith(fontWeight: FontWeight.w600),
      ),
      cardTheme: CardThemeData(
        color: grouped,
        elevation: 0,
        shape: controlShape,
      ),
      dividerTheme: DividerThemeData(
        color: scheme.outlineVariant,
        thickness: 0.5,
        space: 0.5,
      ),
      listTileTheme: ListTileThemeData(
        iconColor: accent,
        contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
        shape: controlShape,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          shape: controlShape,
          padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 12),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(shape: controlShape),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(shape: controlShape),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: grouped,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: grouped,
        surfaceTintColor: Colors.transparent,
        constraints: const BoxConstraints(maxWidth: 640),
        shape: tokens.sheetShape,
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: grouped,
        shape: controlShape,
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: scheme.surfaceContainerHigh,
        contentTextStyle: text.copyWith(fontSize: 15, color: foreground),
        actionTextColor: accent,
        disabledActionTextColor: secondary,
        closeIconColor: foreground,
        elevation: 0,
        insetPadding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(24),
          side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.5)),
        ),
      ),
    );
  }

  @override
  MornyeTheme copyWith({
    Color? chromeSurface,
    MornyeAccent? accent,
    bool? useSystemFont,
    String? fontFamily,
    double? glassClarity,
    bool? glassOutlines,
  }) => MornyeTheme(
    chromeSurface: chromeSurface ?? this.chromeSurface,
    accent: accent ?? this.accent,
    useSystemFont: useSystemFont ?? this.useSystemFont,
    fontFamily: fontFamily ?? this.fontFamily,
    glassClarity: glassClarity ?? this.glassClarity,
    glassOutlines: glassOutlines ?? this.glassOutlines,
  );

  @override
  MornyeTheme lerp(covariant MornyeTheme? other, double t) => MornyeTheme(
    chromeSurface: Color.lerp(chromeSurface, other?.chromeSurface, t),
    accent: t < 0.5 ? accent : other?.accent ?? accent,
    fontFamily: t < 0.5 ? fontFamily : other?.fontFamily,
    useSystemFont: t < 0.5
        ? useSystemFont
        : other?.useSystemFont ?? useSystemFont,
    glassClarity:
        glassClarity +
        ((other?.glassClarity ?? glassClarity) - glassClarity) * t,
    glassOutlines: t < 0.5
        ? glassOutlines
        : other?.glassOutlines ?? glassOutlines,
  );

  @override
  bool operator ==(Object other) =>
      other is MornyeTheme &&
      other.chromeSurface == chromeSurface &&
      other.accent == accent &&
      other.useSystemFont == useSystemFont &&
      other.fontFamily == fontFamily &&
      other.glassClarity == glassClarity &&
      other.glassOutlines == glassOutlines;

  @override
  int get hashCode => Object.hash(
    chromeSurface,
    accent,
    useSystemFont,
    fontFamily,
    glassClarity,
    glassOutlines,
  );
}

extension MornyeThemeContext on BuildContext {
  bool get isMornye => Theme.of(this).extension<MornyeTheme>() != null;
}

/// Settings uses iOS's inset grouped surfaces while the music library keeps
/// its artwork-led, plain background.
class MornyeSettingsTheme extends StatelessWidget {
  const MornyeSettingsTheme({super.key, required this.child});

  final Widget child;

  // Reusing the derived theme keeps rebuilds from notifying the whole page.
  static final _themes = Expando<ThemeData>();

  @override
  Widget build(BuildContext context) {
    if (!context.isMornye) return child;
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final background = dark ? Colors.black : const Color(0xfff2f2f7);
    final group = dark ? const Color(0xff1c1c1e) : Colors.white;
    return Theme(
      data: _themes[theme] ??= theme.copyWith(
        scaffoldBackgroundColor: background,
        extensions: [
          for (final extension in theme.extensions.values)
            if (extension is AppTokens)
              extension.copyWith(radiusCard: 24)
            else
              extension,
        ],
        colorScheme: theme.colorScheme.copyWith(
          surface: background,
          surfaceContainer: group,
        ),
        appBarTheme: theme.appBarTheme.copyWith(backgroundColor: background),
      ),
      child: ColoredBox(color: background, child: child),
    );
  }
}
