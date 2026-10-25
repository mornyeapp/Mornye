import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mornye/models/theme_settings.dart';

final initialThemeSettingsProvider = Provider<ThemeSettings>(
  (ref) => ThemeSettings(style: defaultAppThemeStyle()),
);

ThemeSettings loadBootstrapThemeSettings(SharedPreferences prefs) {
  return ThemeSettings(
    themeMode: themeModeFromString(prefs.getString(kThemeModeKey)),
    useDynamicColor: prefs.getBool(kUseDynamicColorKey) ?? true,
    seedColorValue: prefs.getInt(kSeedColorKey) ?? kDefaultSeedColor,
    useAmoled: prefs.getBool(kUseAmoledKey) ?? false,
    style: themeStyleFromString(prefs.getString(kThemeStyleKey)),
    mornyeAccent: mornyeAccentFromString(prefs.getString(kMornyeAccentKey)),
    useSystemFont: prefs.getBool(kUseSystemFontKey) ?? false,
    customFontId: prefs.getString(kCustomFontIdKey) ?? '',
    customFontName: prefs.getString(kCustomFontNameKey) ?? '',
    lyricsTextScale: normalizeLyricsTextScale(
      prefs.getDouble(kLyricsTextScaleKey),
    ),
    lyricsBlur: normalizeLyricsBlur(prefs.getDouble(kLyricsBlurKey)),
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
