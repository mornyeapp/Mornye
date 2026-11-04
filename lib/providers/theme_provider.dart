import 'dart:async';

import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart' as material_ui;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mornye/models/theme_settings.dart';

final initialThemeSettingsProvider = Provider<ThemeSettings>(
  (ref) => ThemeSettings(style: defaultAppThemeStyle()),
);

/// The launch request for the system's colors. Without one the theme asks
/// when it first builds.
final initialDynamicColorsProvider = Provider<DynamicColors?>((ref) => null);

typedef DynamicColorSchemes = ({
  material_ui.ColorScheme light,
  material_ui.ColorScheme dark,
});

/// The system's colors: the Android 12+ wallpaper palette, else the desktop
/// accent color. Asked once, in the same order as `DynamicColorBuilder`.
class DynamicColors {
  DynamicColors.request() : future = _read() {
    future.then<void>((schemes) {
      _schemes = schemes;
      _settled = true;
    });
  }

  /// Null when the platform has no dynamic colors.
  final Future<DynamicColorSchemes?> future;
  DynamicColorSchemes? _schemes;
  bool _settled = false;

  bool get isSettled => _settled;
  DynamicColorSchemes? get schemes => _schemes;

  /// Waits at most [timeout] for the answer; never throws.
  Future<void> settle(Duration timeout) => future
      .timeout(timeout, onTimeout: () => null)
      .then<void>((_) {}, onError: (Object _) {});

  static Future<DynamicColorSchemes?> _read() async {
    try {
      final palette = await DynamicColorPlugin.getCorePalette();
      if (palette != null) {
        return (
          light: palette.toColorScheme(),
          dark: palette.toColorScheme(brightness: Brightness.dark),
        );
      }
    } on PlatformException {
      // Falls back to the accent color.
    }
    try {
      final accent = await DynamicColorPlugin.getAccentColor();
      if (accent != null) {
        return (
          light: material_ui.ColorScheme.fromSeed(
            seedColor: accent,
            brightness: Brightness.light,
          ),
          dark: material_ui.ColorScheme.fromSeed(
            seedColor: accent,
            brightness: Brightness.dark,
          ),
        );
      }
    } on PlatformException {
      // No dynamic colors on this platform.
    }
    return null;
  }
}

/// The accent to load, moving an install off the old default once. Every
/// theme save wrote the accent, so a stored red usually only means red was
/// the default. Red picked after this stays.
MornyeAccent _loadMornyeAccent(SharedPreferences prefs) {
  final stored = prefs.getString(kMornyeAccentKey);
  if (prefs.getBool(kMornyeAccentMovedToBlueKey) ?? false) {
    return mornyeAccentFromString(stored);
  }
  unawaited(prefs.setBool(kMornyeAccentMovedToBlueKey, true));
  if (stored == MornyeAccent.red.name) {
    unawaited(prefs.setString(kMornyeAccentKey, MornyeAccent.blue.name));
    return MornyeAccent.blue;
  }
  return mornyeAccentFromString(stored);
}

ThemeSettings loadBootstrapThemeSettings(SharedPreferences prefs) {
  return ThemeSettings(
    themeMode: themeModeFromString(prefs.getString(kThemeModeKey)),
    useDynamicColor: prefs.getBool(kUseDynamicColorKey) ?? true,
    seedColorValue: prefs.getInt(kSeedColorKey) ?? kDefaultSeedColor,
    useAmoled: prefs.getBool(kUseAmoledKey) ?? false,
    style: themeStyleFromString(prefs.getString(kThemeStyleKey)),
    mornyeAccent: _loadMornyeAccent(prefs),
    useSystemFont: prefs.getBool(kUseSystemFontKey) ?? false,
    customFontId: prefs.getString(kCustomFontIdKey) ?? '',
    customFontName: prefs.getString(kCustomFontNameKey) ?? '',
    lyricsTextScale: normalizeLyricsTextScale(
      prefs.getDouble(kLyricsTextScaleKey),
    ),
    lyricsBlur: normalizeLyricsBlur(prefs.getDouble(kLyricsBlurKey)),
    lyricsOffsetMs: normalizeLyricsOffsetMs(prefs.getInt(kLyricsOffsetKey)),
    mornyeGlassClarity: normalizeMornyeGlassClarity(
      prefs.getDouble(kMornyeGlassClarityKey),
    ),
    mornyeGlassOutlines: prefs.getBool(kMornyeGlassOutlinesKey) ?? true,
  );
}

final themeProvider = NotifierProvider<ThemeNotifier, ThemeSettings>(() {
  return ThemeNotifier();
});

class ThemeNotifier extends Notifier<ThemeSettings> {
  ThemeNotifier({Future<SharedPreferences>? preferences})
    : _prefs = preferences ?? SharedPreferences.getInstance();

  final Future<SharedPreferences> _prefs;
  late Future<void> _loadFuture;
  Future<void> _saveChain = Future<void>.value();
  final _loadingEdits = <ThemeSettings Function(ThemeSettings)>[];
  bool _loaded = false;

  @override
  ThemeSettings build() {
    _loadFuture = _loadFromStorage();
    return ref.read(initialThemeSettingsProvider);
  }

  Future<void> _loadFromStorage() async {
    try {
      final prefs = await _prefs;
      var loaded = loadBootstrapThemeSettings(prefs);
      for (final edit in _loadingEdits) {
        loaded = edit(loaded);
      }
      if (ref.mounted) state = loaded;
    } catch (e) {
      debugPrint('Error loading theme settings: $e');
    } finally {
      _loaded = true;
      _loadingEdits.clear();
    }
  }

  void _editState(ThemeSettings Function(ThemeSettings) edit) {
    if (!_loaded) _loadingEdits.add(edit);
    state = edit(state);
  }

  Future<void> _saveToStorage() => _saveChain = _saveChain.then((_) async {
    try {
      await _loadFuture;
      final prefs = await _prefs;
      if (!ref.mounted) return;
      final snapshot = state;
      await prefs.setString(kThemeModeKey, snapshot.themeMode.name);
      await prefs.setBool(kUseDynamicColorKey, snapshot.useDynamicColor);
      await prefs.setInt(kSeedColorKey, snapshot.seedColorValue);
      await prefs.setBool(kUseAmoledKey, snapshot.useAmoled);
      await prefs.setString(kThemeStyleKey, snapshot.style.name);
      await prefs.setString(kMornyeAccentKey, snapshot.mornyeAccent.name);
      await prefs.setBool(kUseSystemFontKey, snapshot.useSystemFont);
      await prefs.setString(kCustomFontIdKey, snapshot.customFontId);
      await prefs.setString(kCustomFontNameKey, snapshot.customFontName);
      await prefs.setDouble(kLyricsTextScaleKey, snapshot.lyricsTextScale);
      await prefs.setDouble(kLyricsBlurKey, snapshot.lyricsBlur);
      await prefs.setInt(kLyricsOffsetKey, snapshot.lyricsOffsetMs);
      await prefs.setDouble(
        kMornyeGlassClarityKey,
        snapshot.mornyeGlassClarity,
      );
      await prefs.setBool(
        kMornyeGlassOutlinesKey,
        snapshot.mornyeGlassOutlines,
      );
    } catch (e) {
      debugPrint('Error saving theme settings: $e');
    }
  });

  Future<void> setThemeMode(ThemeMode mode) async {
    _editState((current) => current.copyWith(themeMode: mode));
    await _saveToStorage();
  }

  Future<void> setStyle(AppThemeStyle style) async {
    _editState((current) => current.copyWith(style: style));
    await _saveToStorage();
  }

  Future<void> setUseDynamicColor(bool value) async {
    _editState((current) => current.copyWith(useDynamicColor: value));
    await _saveToStorage();
  }

  Future<void> setSeedColor(Color color) async {
    _editState((current) => current.copyWith(seedColorValue: color.toARGB32()));
    await _saveToStorage();
  }

  Future<void> setUseAmoled(bool value) async {
    _editState((current) => current.copyWith(useAmoled: value));
    await _saveToStorage();
  }

  Future<void> setMornyeAccent(MornyeAccent accent) async {
    _editState((current) => current.copyWith(mornyeAccent: accent));
    await _saveToStorage();
  }

  Future<void> setUseSystemFont(bool value) async {
    _editState((current) => current.copyWith(useSystemFont: value));
    await _saveToStorage();
  }

  Future<void> setCustomFont(String id, String name) async {
    _editState(
      (current) => current.copyWith(customFontId: id, customFontName: name),
    );
    await _saveToStorage();
  }

  Future<void> setLyricsTextScale(double value, {bool persist = true}) async {
    _editState((current) => current.copyWith(lyricsTextScale: value));
    if (persist) await _saveToStorage();
  }

  Future<void> setLyricsBlur(double value, {bool persist = true}) async {
    _editState((current) => current.copyWith(lyricsBlur: value));
    if (persist) await _saveToStorage();
  }

  Future<void> setLyricsOffsetMs(int value, {bool persist = true}) async {
    _editState((current) => current.copyWith(lyricsOffsetMs: value));
    if (persist) await _saveToStorage();
  }

  Future<void> setMornyeGlassClarity(
    double value, {
    bool persist = true,
  }) async {
    _editState((current) => current.copyWith(mornyeGlassClarity: value));
    if (persist) await _saveToStorage();
  }

  Future<void> setMornyeGlassOutlines(bool value) async {
    _editState((current) => current.copyWith(mornyeGlassOutlines: value));
    await _saveToStorage();
  }
}
