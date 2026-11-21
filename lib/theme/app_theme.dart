import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:mornye/models/theme_settings.dart';
import 'package:mornye/theme/app_tokens.dart';
import 'package:mornye/theme/page_transitions.dart';
import 'package:mornye/utils/desktop_platform.dart';

class AppTheme {
  static const Color defaultSeedColor = Color(kDefaultSeedColor);

  /// Shared surfaces use one radius scale; actions use round Material shapes.
  static const AppTokens _tokens = AppTokens.standard;

  /// The bundled variable face; its wght and ROND axes stay variable.
  static const String bundledFontFamily = 'Google Sans Flex';

  /// Full ROND for the Expressive brand roles of [bundledFontFamily].
  static const double brandRoundness = 100;

  static ThemeData light({
    ColorScheme? dynamicScheme,
    Color? seedColor,
    bool useSystemFont = false,
    String? fontFamily,
  }) {
    final scheme =
        dynamicScheme ??
        ColorScheme.fromSeed(
          seedColor: seedColor ?? defaultSeedColor,
          brightness: Brightness.light,
        );
    final family = fontFamily ?? (useSystemFont ? null : bundledFontFamily);
    final textTheme = _expressiveTextTheme(family);

    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      pageTransitionsTheme: materialPageTransitionsTheme,
      appBarTheme: _appBarTheme(scheme, family),
      cardTheme: _cardTheme(scheme),
      elevatedButtonTheme: _elevatedButtonTheme(scheme),
      filledButtonTheme: _filledButtonTheme(scheme),
      outlinedButtonTheme: _outlinedButtonTheme(scheme),
      textButtonTheme: _textButtonTheme(scheme),
      floatingActionButtonTheme: _fabTheme(scheme),
      inputDecorationTheme: _inputDecorationTheme(scheme),
      listTileTheme: _listTileTheme(scheme),
      dialogTheme: _dialogTheme(scheme),
      bottomSheetTheme: _bottomSheetTheme,
      navigationBarTheme: _navigationBarTheme(scheme),
      snackBarTheme: _snackBarTheme(scheme, family),
      progressIndicatorTheme: _progressIndicatorTheme(scheme),
      sliderTheme: _sliderTheme(scheme),
      switchTheme: _switchTheme(scheme),
      chipTheme: _chipTheme(scheme),
      popupMenuTheme: _popupMenuTheme(scheme),
      menuTheme: _menuTheme(scheme),
      menuButtonTheme: _menuButtonTheme,
      tabBarTheme: _tabBarTheme(scheme, family),
      dividerTheme: _dividerTheme(scheme),
      tooltipTheme: _tooltipTheme,
      extensions: <ThemeExtension<dynamic>>[
        isDesktopPlatform ? AppTokens.desktop : AppTokens.standard,
      ],
      fontFamily: family,
      textTheme: textTheme,
      primaryTextTheme: textTheme,
    );
  }

  static ThemeData dark({
    ColorScheme? dynamicScheme,
    Color? seedColor,
    bool isAmoled = false,
    bool useSystemFont = false,
    String? fontFamily,
  }) {
    final scheme =
        dynamicScheme ??
        ColorScheme.fromSeed(
          seedColor: seedColor ?? defaultSeedColor,
          brightness: Brightness.dark,
        );
    final family = fontFamily ?? (useSystemFont ? null : bundledFontFamily);
    final textTheme = _expressiveTextTheme(family);

    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      pageTransitionsTheme: materialPageTransitionsTheme,
      scaffoldBackgroundColor: isAmoled ? Colors.black : null,
      appBarTheme: _appBarTheme(scheme, family, isAmoled: isAmoled),
      cardTheme: _cardTheme(scheme),
      elevatedButtonTheme: _elevatedButtonTheme(scheme),
      filledButtonTheme: _filledButtonTheme(scheme),
      outlinedButtonTheme: _outlinedButtonTheme(scheme),
      textButtonTheme: _textButtonTheme(scheme),
      floatingActionButtonTheme: _fabTheme(scheme),
      inputDecorationTheme: _inputDecorationTheme(scheme),
      listTileTheme: _listTileTheme(scheme),
      dialogTheme: _dialogTheme(scheme),
      bottomSheetTheme: _bottomSheetTheme,
      navigationBarTheme: _navigationBarTheme(scheme, isAmoled: isAmoled),
      snackBarTheme: _snackBarTheme(scheme, family),
      progressIndicatorTheme: _progressIndicatorTheme(scheme),
      sliderTheme: _sliderTheme(scheme),
      switchTheme: _switchTheme(scheme),
      chipTheme: _chipTheme(scheme),
      popupMenuTheme: _popupMenuTheme(scheme),
      menuTheme: _menuTheme(scheme),
      menuButtonTheme: _menuButtonTheme,
      tabBarTheme: _tabBarTheme(scheme, family),
      dividerTheme: _dividerTheme(scheme),
      tooltipTheme: _tooltipTheme,
      extensions: <ThemeExtension<dynamic>>[
        isDesktopPlatform ? AppTokens.desktop : AppTokens.standard,
      ],
      fontFamily: family,
      textTheme: textTheme,
      primaryTextTheme: textTheme,
    );
  }

  // Display, headline and title roles are the Expressive brand roles, so they
  // take Google Sans Flex's rounded terminals. Body and label roles carry long
  // reading text and small UI labels, where the default cut terminals stay
  // crisper; they keep ROND 0, the M3 Expressive brand and plain split.
  // Only ROND is set: with no wght entry the engine still takes the weight
  // from fontWeight, so a later copyWith(fontWeight: ...) keeps working.
  // Imported and system fonts get no axes.
  static TextTheme? _expressiveTextTheme(String? family) {
    if (family != bundledFontFamily) return null;
    const rounded = TextStyle(
      fontVariations: [FontVariation('ROND', brandRoundness)],
    );
    return const TextTheme(
      displayLarge: rounded,
      displayMedium: rounded,
      displaySmall: rounded,
      headlineLarge: rounded,
      headlineMedium: rounded,
      headlineSmall: rounded,
      titleLarge: rounded,
      titleMedium: rounded,
      titleSmall: rounded,
    );
  }

  // A component given its own text style takes nothing from the text theme,
  // so each style below names the family, and a title role its roundness.
  static List<FontVariation>? _brandVariations(String? family) =>
      family == bundledFontFamily
      ? const [FontVariation('ROND', brandRoundness)]
      : null;

  static AppBarTheme _appBarTheme(
    ColorScheme scheme,
    String? family, {
    bool isAmoled = false,
  }) => AppBarTheme(
    elevation: 0,
    scrolledUnderElevation: isAmoled ? 0 : 3,
    backgroundColor: isAmoled ? Colors.black : scheme.surface,
    foregroundColor: scheme.onSurface,
    surfaceTintColor: isAmoled ? Colors.transparent : scheme.surfaceTint,
    centerTitle: true,
    titleTextStyle: TextStyle(
      color: scheme.onSurface,
      fontSize: 22,
      fontWeight: FontWeight.w500,
      fontFamily: family,
      fontVariations: _brandVariations(family),
    ),
    systemOverlayStyle: SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: scheme.brightness == Brightness.dark
          ? Brightness.light
          : Brightness.dark,
      systemNavigationBarColor: isAmoled
          ? Colors.black
          : scheme.surfaceContainer,
      systemNavigationBarIconBrightness: scheme.brightness == Brightness.dark
          ? Brightness.light
          : Brightness.dark,
    ),
  );

  static CardThemeData _cardTheme(ColorScheme scheme) => CardThemeData(
    elevation: 0,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(_tokens.radiusCard),
    ),
    color: scheme.surfaceContainerLow,
    surfaceTintColor: scheme.surfaceTint,
  );

  static ElevatedButtonThemeData _elevatedButtonTheme(ColorScheme scheme) =>
      ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          elevation: 1,
          shape: const StadiumBorder(),
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
        ),
      );

  static FilledButtonThemeData _filledButtonTheme(ColorScheme scheme) =>
      FilledButtonThemeData(
        style: FilledButton.styleFrom(
          shape: const StadiumBorder(),
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
        ),
      );

  static OutlinedButtonThemeData _outlinedButtonTheme(ColorScheme scheme) =>
      OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          shape: const StadiumBorder(),
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
        ),
      );

  static TextButtonThemeData _textButtonTheme(ColorScheme scheme) =>
      TextButtonThemeData(
        style: TextButton.styleFrom(
          shape: const StadiumBorder(),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        ),
      );

  static FloatingActionButtonThemeData _fabTheme(ColorScheme scheme) =>
      FloatingActionButtonThemeData(
        elevation: 3,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(_tokens.radiusControl),
        ),
        backgroundColor: scheme.primaryContainer,
        foregroundColor: scheme.onPrimaryContainer,
      );

  static InputDecorationTheme _inputDecorationTheme(ColorScheme scheme) =>
      InputDecorationTheme(
        filled: true,
        fillColor: scheme.surfaceContainerHigh,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(_tokens.radiusControl),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(_tokens.radiusControl),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(_tokens.radiusControl),
          borderSide: BorderSide(color: scheme.primary, width: 2),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(_tokens.radiusControl),
          borderSide: BorderSide(color: scheme.error, width: 1),
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 20,
          vertical: 16,
        ),
      );

  static ListTileThemeData _listTileTheme(ColorScheme scheme) =>
      ListTileThemeData(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(_tokens.radiusControl),
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      );

  // Caps modal sheet width on tablets/landscape (no effect on phones, whose
  // screens are narrower); Flutter centers the sheet when narrower than the
  // screen. The shape is set here so no call site has to repeat it — every
  // sheet inherits the token radius.
  static final BottomSheetThemeData _bottomSheetTheme = BottomSheetThemeData(
    constraints: const BoxConstraints(maxWidth: 640),
    shape: _tokens.sheetShape,
  );

  static DialogThemeData _dialogTheme(ColorScheme scheme) => DialogThemeData(
    elevation: 6,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(_tokens.radiusSheet),
    ),
    backgroundColor: scheme.surfaceContainerHigh,
    surfaceTintColor: scheme.surfaceTint,
  );

  static NavigationBarThemeData _navigationBarTheme(
    ColorScheme scheme, {
    bool isAmoled = false,
  }) => NavigationBarThemeData(
    elevation: 0,
    // Navigation keeps its container tier on AMOLED too, so the bar stays
    // apart from the black page.
    backgroundColor: scheme.surfaceContainer,
    indicatorColor: scheme.secondaryContainer,
    surfaceTintColor: isAmoled ? Colors.transparent : scheme.surfaceTint,
    labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
  );

  static SnackBarThemeData _snackBarTheme(ColorScheme scheme, String? family) =>
      SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(_tokens.radiusControl),
        ),
        backgroundColor: scheme.inverseSurface,
        contentTextStyle: TextStyle(
          color: scheme.onInverseSurface,
          fontFamily: family,
        ),
      );

  static ProgressIndicatorThemeData _progressIndicatorTheme(
    ColorScheme scheme,
  ) => ProgressIndicatorThemeData(
    color: scheme.primary,
    linearTrackColor: scheme.surfaceContainerHighest,
    circularTrackColor: scheme.surfaceContainerHighest,
  );

  static SliderThemeData _sliderTheme(ColorScheme scheme) => SliderThemeData(
    activeTrackColor: scheme.primary,
    inactiveTrackColor: scheme.secondaryContainer,
    thumbColor: scheme.primary,
  );

  static SwitchThemeData _switchTheme(ColorScheme scheme) => SwitchThemeData(
    thumbColor: WidgetStateProperty.resolveWith((states) {
      if (states.contains(WidgetState.selected)) {
        return scheme.onPrimary;
      }
      return scheme.outline;
    }),
    trackColor: WidgetStateProperty.resolveWith((states) {
      if (states.contains(WidgetState.selected)) {
        return scheme.primary;
      }
      return scheme.surfaceContainerHighest;
    }),
    thumbIcon: WidgetStateProperty.resolveWith((states) {
      if (states.contains(WidgetState.selected)) {
        return Icon(Icons.check, color: scheme.primary);
      }
      return null;
    }),
  );

  // Every menu wears the M3 Expressive standard menu skin, as M3EMenuPopup
  // does: the low container tier, the control radius and a level 2 lift.
  static PopupMenuThemeData _popupMenuTheme(ColorScheme scheme) =>
      PopupMenuThemeData(
        color: scheme.surfaceContainerLow,
        surfaceTintColor: Colors.transparent,
        elevation: 3,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(_tokens.radiusControl),
        ),
        menuPadding: const EdgeInsets.symmetric(vertical: 8),
      );

  // Anchored menus share the popup skin; items sit 4dp in from the edge with
  // rounded corners.
  static MenuThemeData _menuTheme(ColorScheme scheme) => MenuThemeData(
    style: MenuStyle(
      backgroundColor: WidgetStatePropertyAll(scheme.surfaceContainerLow),
      surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
      elevation: const WidgetStatePropertyAll(3),
      padding: const WidgetStatePropertyAll(EdgeInsets.all(4)),
      shape: WidgetStatePropertyAll(
        RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(_tokens.radiusControl),
        ),
      ),
    ),
  );

  static final MenuButtonThemeData _menuButtonTheme = MenuButtonThemeData(
    style: MenuItemButton.styleFrom(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(_tokens.radiusCover),
      ),
    ),
  );

  static TabBarThemeData _tabBarTheme(ColorScheme scheme, String? family) =>
      TabBarThemeData(
        indicatorSize: TabBarIndicatorSize.label,
        indicator: UnderlineTabIndicator(
          borderRadius: const BorderRadius.vertical(top: Radius.circular(3)),
          borderSide: BorderSide(color: scheme.primary, width: 3),
        ),
        labelStyle: TextStyle(
          fontWeight: FontWeight.w600,
          fontFamily: family,
          fontVariations: _brandVariations(family),
        ),
      );

  static ChipThemeData _chipTheme(ColorScheme scheme) => ChipThemeData(
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(_tokens.radiusCard),
    ),
    backgroundColor: scheme.surfaceContainerLow,
    selectedColor: scheme.secondaryContainer,
  );

  static DividerThemeData _dividerTheme(ColorScheme scheme) =>
      DividerThemeData(color: scheme.outlineVariant, thickness: 1, space: 1);

  /// Desktop hover waits half a second before a tooltip shows, the initial
  /// tooltip delay of the Windows and Linux toolkits, so sweeping across the
  /// rail or the player bar does not flash a string of labels.
  static TooltipThemeData? get _tooltipTheme => isDesktopPlatform
      ? const TooltipThemeData(waitDuration: Duration(milliseconds: 500))
      : null;
}
