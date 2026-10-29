import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:mornye/utils/desktop_platform.dart';

const String kThemeModeKey = 'theme_mode';
const String kUseDynamicColorKey = 'use_dynamic_color';
const String kSeedColorKey = 'seed_color';
const String kUseAmoledKey = 'use_amoled';
const String kThemeStyleKey = 'theme_style';
const String kMornyeAccentKey = 'mornye_accent';
const String kUseSystemFontKey = 'use_system_font';
const String kCustomFontIdKey = 'custom_font_id';
const String kCustomFontNameKey = 'custom_font_name';
const String kLyricsTextScaleKey = 'lyrics_text_scale';

double normalizeLyricsTextScale(num? value) =>
    value != null && value.isFinite ? value.toDouble().clamp(0.8, 1.4) : 1.0;
const String kLyricsBlurKey = 'lyrics_blur';

/// How strongly Mornye blurs the lyric lines around the current one: 0 turns
/// it off, 1 is the default.
double normalizeLyricsBlur(num? value) =>
    value != null && value.isFinite ? value.toDouble().clamp(0.0, 1.5) : 1.0;
const String kLyricsOffsetKey = 'lyrics_offset_ms';
const int kMaxLyricsOffsetMs = 2000;

/// How much later synced lyrics follow playback, in milliseconds, so they
/// match audio that reaches the ears late (such as over Bluetooth). Negative
/// values show them earlier.
int normalizeLyricsOffsetMs(num? value) => value != null && value.isFinite
    ? value.round().clamp(-kMaxLyricsOffsetMs, kMaxLyricsOffsetMs)
    : 0;
const String kMornyeGlassClarityKey = 'mornye_glass_clarity';
const String kMornyeGlassOutlinesKey = 'mornye_glass_outlines';
const double kDefaultMornyeGlassClarity = 0.75;

double normalizeMornyeGlassClarity(num? value) =>
    value != null && value.isFinite
    ? value.toDouble().clamp(0.0, 1.0)
    : kDefaultMornyeGlassClarity;

enum AppThemeStyle { material, mornye }

enum MornyeAccent { red, orange, green, teal, blue, purple, pink }

MornyeAccent mornyeAccentFromString(String? value) =>
    MornyeAccent.values.firstWhere(
      (accent) => accent.name == value,
      orElse: () => MornyeAccent.red,
    );

/// Style used until the person picks one: Mornye on macOS, Material on
/// Windows, Linux and mobile.
AppThemeStyle defaultAppThemeStyle() =>
    isDesktopPlatform && defaultTargetPlatform == TargetPlatform.macOS
    ? AppThemeStyle.mornye
    : AppThemeStyle.material;

AppThemeStyle themeStyleFromString(String? value) => AppThemeStyle.values
    .firstWhere((style) => style.name == value, orElse: defaultAppThemeStyle);

/// Default Spotify green color for fallback
const int kDefaultSeedColor = 0xFF1DB954;

class ThemeSettings {
  final ThemeMode themeMode;
  final bool useDynamicColor;
  final int seedColorValue;
  final bool useAmoled;
  final AppThemeStyle style;
  final MornyeAccent mornyeAccent;
  final bool useSystemFont;
  final String customFontId;
  final String customFontName;
  final double lyricsTextScale;
  final double lyricsBlur;
  final int lyricsOffsetMs;
  final double mornyeGlassClarity;
  final bool mornyeGlassOutlines;

  const ThemeSettings({
    this.themeMode = ThemeMode.system,
    this.useDynamicColor = true,
    this.seedColorValue = kDefaultSeedColor,
    this.useAmoled = false,
    this.style = AppThemeStyle.material,
    this.mornyeAccent = MornyeAccent.red,
    this.useSystemFont = false,
    this.customFontId = '',
    this.customFontName = '',
    this.lyricsTextScale = 1,
    this.lyricsBlur = 1,
    this.lyricsOffsetMs = 0,
    this.mornyeGlassClarity = kDefaultMornyeGlassClarity,
    this.mornyeGlassOutlines = true,
  });

  Color get seedColor => Color(seedColorValue);

  ThemeSettings copyWith({
    ThemeMode? themeMode,
    bool? useDynamicColor,
    int? seedColorValue,
    bool? useAmoled,
    AppThemeStyle? style,
    MornyeAccent? mornyeAccent,
    bool? useSystemFont,
    String? customFontId,
    String? customFontName,
    double? lyricsTextScale,
    double? lyricsBlur,
    int? lyricsOffsetMs,
    double? mornyeGlassClarity,
    bool? mornyeGlassOutlines,
  }) {
    return ThemeSettings(
      themeMode: themeMode ?? this.themeMode,
      useDynamicColor: useDynamicColor ?? this.useDynamicColor,
      seedColorValue: seedColorValue ?? this.seedColorValue,
      useAmoled: useAmoled ?? this.useAmoled,
      style: style ?? this.style,
      mornyeAccent: mornyeAccent ?? this.mornyeAccent,
      useSystemFont: useSystemFont ?? this.useSystemFont,
      customFontId: customFontId ?? this.customFontId,
      customFontName: customFontName ?? this.customFontName,
      lyricsTextScale: normalizeLyricsTextScale(
        lyricsTextScale ?? this.lyricsTextScale,
      ),
      lyricsBlur: normalizeLyricsBlur(lyricsBlur ?? this.lyricsBlur),
      lyricsOffsetMs: normalizeLyricsOffsetMs(
        lyricsOffsetMs ?? this.lyricsOffsetMs,
      ),
      mornyeGlassClarity: normalizeMornyeGlassClarity(
        mornyeGlassClarity ?? this.mornyeGlassClarity,
      ),
      mornyeGlassOutlines: mornyeGlassOutlines ?? this.mornyeGlassOutlines,
    );
  }

  Map<String, dynamic> toJson() => {
    kThemeModeKey: themeMode.name,
    kUseDynamicColorKey: useDynamicColor,
    kSeedColorKey: seedColorValue,
    kUseAmoledKey: useAmoled,
    kThemeStyleKey: style.name,
    kMornyeAccentKey: mornyeAccent.name,
    kUseSystemFontKey: useSystemFont,
    kCustomFontIdKey: customFontId,
    kCustomFontNameKey: customFontName,
    kLyricsTextScaleKey: lyricsTextScale,
    kLyricsBlurKey: lyricsBlur,
    kLyricsOffsetKey: lyricsOffsetMs,
    kMornyeGlassClarityKey: mornyeGlassClarity,
    kMornyeGlassOutlinesKey: mornyeGlassOutlines,
  };

  factory ThemeSettings.fromJson(Map<String, dynamic> json) {
    return ThemeSettings(
      themeMode: themeModeFromString(json[kThemeModeKey] as String?),
      useDynamicColor: json[kUseDynamicColorKey] as bool? ?? true,
      seedColorValue: json[kSeedColorKey] as int? ?? kDefaultSeedColor,
      useAmoled: json[kUseAmoledKey] as bool? ?? false,
      style: themeStyleFromString(json[kThemeStyleKey] as String?),
      mornyeAccent: mornyeAccentFromString(json[kMornyeAccentKey] as String?),
      useSystemFont: json[kUseSystemFontKey] as bool? ?? false,
      customFontId: json[kCustomFontIdKey] as String? ?? '',
      customFontName: json[kCustomFontNameKey] as String? ?? '',
      lyricsTextScale: normalizeLyricsTextScale(
        json[kLyricsTextScaleKey] as num?,
      ),
      lyricsBlur: normalizeLyricsBlur(json[kLyricsBlurKey] as num?),
      lyricsOffsetMs: normalizeLyricsOffsetMs(json[kLyricsOffsetKey] as num?),
      mornyeGlassClarity: normalizeMornyeGlassClarity(
        json[kMornyeGlassClarityKey] as num?,
      ),
      mornyeGlassOutlines: json[kMornyeGlassOutlinesKey] as bool? ?? true,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is ThemeSettings &&
        other.themeMode == themeMode &&
        other.useDynamicColor == useDynamicColor &&
        other.seedColorValue == seedColorValue &&
        other.useAmoled == useAmoled &&
        other.style == style &&
        other.mornyeAccent == mornyeAccent &&
        other.useSystemFont == useSystemFont &&
        other.customFontId == customFontId &&
        other.customFontName == customFontName &&
        other.lyricsTextScale == lyricsTextScale &&
        other.lyricsBlur == lyricsBlur &&
        other.lyricsOffsetMs == lyricsOffsetMs &&
        other.mornyeGlassClarity == mornyeGlassClarity &&
        other.mornyeGlassOutlines == mornyeGlassOutlines;
  }

  @override
  int get hashCode =>
      themeMode.hashCode ^
      useDynamicColor.hashCode ^
      seedColorValue.hashCode ^
      useAmoled.hashCode ^
      style.hashCode ^
      mornyeAccent.hashCode ^
      useSystemFont.hashCode ^
      customFontId.hashCode ^
      customFontName.hashCode ^
      lyricsTextScale.hashCode ^
      lyricsBlur.hashCode ^
      lyricsOffsetMs.hashCode ^
      mornyeGlassClarity.hashCode ^
      mornyeGlassOutlines.hashCode;
}

ThemeMode themeModeFromString(String? value) {
  if (value == null) return ThemeMode.system;
  return ThemeMode.values.firstWhere(
    (e) => e.name == value,
    orElse: () => ThemeMode.system,
  );
}
