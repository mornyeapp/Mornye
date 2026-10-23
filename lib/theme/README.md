# Theme Layer

The app has two visual styles, chosen in Appearance settings and stored as
`AppThemeStyle { material, mornye }` (`lib/models/theme_settings.dart`,
preference key `theme_style`, loaded by `lib/providers/theme_provider.dart`):

- **Material**: Material 3 with dynamic color or a seed color, optional AMOLED
  surfaces, and Material 3 Expressive motion and components.
- **Mornye**: the Flutter counterpart of Mornye's iPhone visual system: iOS
  system colors, Cupertino typography and icons, and glass surfaces. Its
  palette is kept independent of wallpaper colors.

Both styles still produce a Flutter `ThemeData` with `useMaterial3: true`, so
widgets read `Theme.of(context).colorScheme` and `textTheme` the same way.
Mornye maps its colors onto Material 3 `ColorScheme` roles instead of
replacing them.

## Files

| File | Role |
| --- | --- |
| `lib/theme/dynamic_color_wrapper.dart` | `DynamicColorWrapper`, used by `lib/app.dart`. Builds the light and dark `ThemeData` for the selected style |
| `lib/theme/app_theme.dart` | `AppTheme.light` and `AppTheme.dark`: Material 3 component themes over a `ColorScheme` |
| `lib/theme/app_tokens.dart` | `AppTokens`, a `ThemeExtension` with the shared radii, spacing, cover sizes and header metrics |
| `lib/theme/mornye_theme.dart` | `MornyeTheme`: the Mornye `ThemeExtension`, its `ThemeData` builder, `context.isMornye`, `MornyeSettingsTheme` |
| `lib/theme/mornye_icons.dart` | `mornyeIconFor` (Material icon to Cupertino icon) and `context.adaptiveIcon` |
| `lib/theme/material_symbols.dart` | Material Symbols Rounded counterparts of `Icons.*` for the Material style |
| `lib/theme/material_expressive.dart` | `materialExpressiveEnabled` and `MaterialExpressiveScope`, the bridge to the Material UI and Material 3 Expressive packages |
| `lib/theme/app_motion.dart` | `AppMotionSpec`, `SpringCurve` and `AppMotion` spring presets |
| `lib/theme/cover_palette.dart` | `CoverPalette`, `HeaderPalette`, `CoverPaletteBuilder` and `CoverSourceColorBuilder`: colors extracted from artwork |
| `lib/theme/player_artwork_theme.dart` | `PlayerArtworkTheme`: the current track's artwork scheme for the Material player surfaces, through a local `Theme` |

## How a Theme Is Built

`DynamicColorWrapper` watches `themeProvider` and the custom font provider.

- Material: `DynamicColorBuilder` supplies the wallpaper scheme when dynamic
  color is on; otherwise `ColorScheme.fromSeed` uses the seed color. AMOLED
  replaces the dark surfaces with black and near-black. `AppTheme` then adds
  component themes and registers `AppTokens.standard`.
- Mornye: `MornyeTheme.build(brightness, ...)` takes the Mornye accent
  (`MornyeAccent`, red by default), the system-font and custom-font choices,
  glass clarity (default 0.75) and glass outlines. It seeds a `ColorScheme`
  from the accent and overrides the roles with iOS grouped colors (for
  example `#F2F2F7` and `#1C1C1E`). Text uses Cupertino styles. The font is
  the custom font when one is set; otherwise the Cupertino system font
  (`CupertinoSystemText`, SF on Apple) on iOS and macOS or when the system
  font is chosen, and Inter elsewhere. It registers its own
  `MornyeTheme.tokens`, a copy of `AppTokens.standard` with different radii
  (smaller for most shapes, larger for sheets) and iOS title sizes, and
  removes ink splashes.

`MornyeTheme.build` caches up to 16 base themes; changing only glass clarity
or outlines reuses the cached theme. Use `MornyeTheme.fromContext` to rebuild
a local surface (another brightness or chrome color) without losing the
user's Mornye preferences.

## Using the Layer in Widgets

- Read tokens with `context.tokens`, not `Theme.of(context).extension`. It
  falls back to `AppTokens.standard` outside a themed subtree.
- Branch on `context.isMornye`, which is true when the nearest `Theme` carries
  a `MornyeTheme` extension. Because it follows the nearest `Theme`, a
  subtree can be switched by wrapping it in another theme.
- Keep `Icons.*` at call sites and pass them through `context.adaptiveIcon`;
  Mornye then shows the Cupertino glyph from `mornyeIconFor`.
- Gate Material 3 Expressive motion with `materialExpressiveEnabled` (false
  for Mornye and when the OS asks for reduced motion). `AppMotion` presets
  return the call site's fallback spec in those cases.
- Wrap settings pages in `MornyeSettingsTheme` for iOS inset grouped
  surfaces; it does nothing in the Material style.

## Mornye Outside This Folder

- Glass rendering level: `MornyeGlassLevel` (`flat`, `frosted`, `liquid`) and
  `mornyeGlassLevelProvider` in `lib/providers/runtime_profile_provider.dart`
  choose how much glass a device renders.
- Mornye widgets live in `lib/widgets/mornye_*.dart`, for example `MornyeGlass`
  in `lib/widgets/mornye_chrome.dart`. Mornye-only screens are
  `lib/screens/mornye_library_screen.dart` and
  `lib/screens/track_metadata_mornye.dart`; most other screens branch on
  `context.isMornye`.

## Tests

`test/design_system_test.dart` checks that `AppTokens` is registered on the
Material themes (`AppTokens.standard`) and on Mornye (`MornyeTheme.tokens`),
the Mornye dark accent, and Mornye's font families and letter spacing. Mornye
widgets have their own `test/mornye_*_test.dart` suites.
