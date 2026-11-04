import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/models/theme_settings.dart';
import 'package:mornye/utils/artist_utils.dart';

void main() {
  test('AI translation defaults to Fast and remembers either mode', () {
    expect(const AppSettings().lyricsAiWordSync, isFalse);
    expect(AppSettings.fromJson({}).lyricsAiWordSync, isFalse);
    for (final wordSync in [false, true]) {
      final settings = const AppSettings().copyWith(lyricsAiWordSync: wordSync);
      final restored = AppSettings.fromJson(settings.toJson());
      expect(restored.lyricsAiWordSync, wordSync);
      expect(restored.copyWith(locale: 'id').lyricsAiWordSync, wordSync);
    }
  });

  test('Library sort restores every choice and tolerates old settings', () {
    expect(AppSettings.fromJson({}).historySortMode, 'latest');
    for (final invalid in [null, '', 'unsupported', 42]) {
      expect(
        AppSettings.fromJson({'historySortMode': invalid}).historySortMode,
        'latest',
      );
    }
    for (final sort in librarySortModes) {
      final settings = const AppSettings().copyWith(historySortMode: sort);
      final restored = AppSettings.fromJson(settings.toJson());
      expect(restored.historySortMode, sort);
      expect(restored.copyWith(historyViewMode: 'list').historySortMode, sort);
    }
  });

  test(
    'retired quality conversion settings do not enable automatic conversion',
    () {
      for (final format in ['mp3_320', 'aac_320', 'opus_256', 'opus_128']) {
        final settings = AppSettings.fromJson({
          'audioQuality': 'HIGH',
          'tidalHighFormat': format,
        });
        expect(settings.audioQuality, 'HIGH');
        expect(settings.autoConvertDownloads, isFalse);
        expect(settings.toJson().containsKey('tidalHighFormat'), isFalse);
      }
      final settings = AppSettings.fromJson({
        'tidalHighFormat': 'mp3_320',
        'autoConvertDownloads': true,
        'autoConvertFormat': 'opus',
        'autoConvertBitrate': '192k',
      });
      expect(settings.autoConvertDownloads, isTrue);
      expect(settings.autoConvertFormat, 'opus');
      expect(settings.autoConvertBitrate, '192k');
    },
  );

  group('AppSettings', () {
    test('provides stable defaults', () {
      const settings = AppSettings();

      expect(settings.audioQuality, 'LOSSLESS');
      expect(settings.filenameFormat, '{title} - {artist}');
      expect(settings.artistTagMode, artistTagModeJoined);
      expect(settings.embeddedCoverMaxDimension, 0);
      expect(settings.autoFallback, isTrue);
      expect(settings.lyricsProviders, [
        'apple_music',
        'lrcred',
        'mornye_lyrics',
        'lyricsplus',
        'lrclib',
      ]);
      expect(settings.playerMode, 'internal');
      expect(settings.lyricsMultiPersonWordByWord, isTrue);
      expect(settings.lyricsAppleElrcWordSync, isTrue);
      expect(settings.deduplicateDownloads, isTrue);
      expect(settings.allowQualityVariants, isFalse);
      expect(settings.nativeDownloadWorkerEnabled, isFalse);
      expect(settings.autoConvertDownloads, isFalse);
      expect(settings.autoConvertFormat, 'mp3');
      expect(settings.autoConvertBitrate, '320k');
      expect(settings.autoConvertMaxBitDepth, 16);
      expect(settings.autoConvertMaxSampleRate, 48000);
      expect(
        settings.libraryQualityLabelMode,
        AppSettings.libraryQualityLabelBitDepthOnly,
      );
    });

    test('normalizes the old lyrics provider without duplicating it', () {
      final settings = AppSettings.fromJson({
        'lyricsProviders': [
          'lrclib',
          'spotiflac_lyrics',
          'apple_music',
          'mornye_lyrics',
        ],
      });
      expect(settings.lyricsProviders, [
        'lrclib',
        'mornye_lyrics',
        'apple_music',
      ]);
    });

    test('copyWith updates values and can clear nullable provider fields', () {
      const settings = AppSettings(
        downloadFallbackExtensionIds: ['fallback.ext'],
        searchProvider: 'search.ext',
        homeFeedProvider: 'feed.ext',
      );

      final updated = settings.copyWith(
        defaultService: 'provider-a',
        embedReplayGain: true,
        embeddedCoverMaxDimension: 1000,
        lyricsProviders: ['apple_music'],
        lyricsAppleElrcWordSync: true,
        deduplicateDownloads: false,
        allowQualityVariants: true,
        libraryQualityLabelMode: AppSettings.libraryQualityLabelBitDepthOnly,
        clearDownloadFallbackExtensionIds: true,
        clearSearchProvider: true,
        clearHomeFeedProvider: true,
      );

      expect(updated.defaultService, 'provider-a');
      expect(updated.embedReplayGain, isTrue);
      expect(updated.embeddedCoverMaxDimension, 1000);
      expect(updated.lyricsProviders, ['apple_music']);
      expect(updated.lyricsAppleElrcWordSync, isTrue);
      expect(updated.deduplicateDownloads, isFalse);
      expect(updated.allowQualityVariants, isTrue);
      expect(
        updated.libraryQualityLabelMode,
        AppSettings.libraryQualityLabelBitDepthOnly,
      );
      expect(updated.downloadFallbackExtensionIds, isNull);
      expect(updated.searchProvider, isNull);
      expect(updated.homeFeedProvider, isNull);
      expect(updated.audioQuality, settings.audioQuality);
    });

    test('round-trips json including recently added settings', () {
      const settings = AppSettings(
        defaultService: 'provider-b',
        storageMode: 'saf',
        downloadTreeUri: 'content://tree/music',
        downloadFallbackExtensionIds: ['ext.a', 'ext.b'],
        searchProvider: 'search.ext',
        homeFeedProvider: AppSettings.homeFeedProviderOff,
        useAllFilesAccess: true,
        networkCompatibilityMode: true,
        songLinkRegion: 'ID',
        localLibraryEnabled: true,
        localLibraryPath: '/music',
        hasCompletedTutorial: true,
        musixmatchLanguage: 'id',
        lyricsAppleElrcWordSync: true,
        lastSeenVersion: '4.5.0',
        deduplicateDownloads: false,
        allowQualityVariants: true,
        nativeDownloadWorkerEnabled: true,
        autoConvertDownloads: true,
        autoConvertFormat: 'opus',
        autoConvertBitrate: '192k',
        autoConvertMaxBitDepth: 24,
        autoConvertMaxSampleRate: 96000,
        libraryQualityLabelMode: AppSettings.libraryQualityLabelBitDepthOnly,
        embeddedCoverMaxDimension: 1500,
      );

      final decoded = AppSettings.fromJson(settings.toJson());

      expect(decoded.defaultService, 'provider-b');
      expect(decoded.storageMode, 'saf');
      expect(decoded.downloadTreeUri, 'content://tree/music');
      expect(decoded.downloadFallbackExtensionIds, ['ext.a', 'ext.b']);
      expect(decoded.searchProvider, 'search.ext');
      expect(decoded.homeFeedProvider, AppSettings.homeFeedProviderOff);
      expect(decoded.useAllFilesAccess, isTrue);
      expect(decoded.networkCompatibilityMode, isTrue);
      expect(decoded.songLinkRegion, 'ID');
      expect(decoded.localLibraryEnabled, isTrue);
      expect(decoded.localLibraryPath, '/music');
      expect(decoded.hasCompletedTutorial, isTrue);
      expect(decoded.musixmatchLanguage, 'id');
      expect(decoded.lyricsAppleElrcWordSync, isTrue);
      expect(decoded.lastSeenVersion, '4.5.0');
      expect(
        decoded.libraryQualityLabelMode,
        AppSettings.libraryQualityLabelBitDepthOnly,
      );
      expect(decoded.deduplicateDownloads, isFalse);
      expect(decoded.allowQualityVariants, isTrue);
      expect(decoded.nativeDownloadWorkerEnabled, isTrue);
      expect(decoded.autoConvertDownloads, isTrue);
      expect(decoded.autoConvertFormat, 'opus');
      expect(decoded.autoConvertBitrate, '192k');
      expect(decoded.autoConvertMaxBitDepth, 24);
      expect(decoded.autoConvertMaxSampleRate, 96000);
      expect(decoded.embeddedCoverMaxDimension, 1500);
    });
  });

  group('ThemeSettings', () {
    test('serializes, deserializes, copies, and compares values', () {
      const settings = ThemeSettings(
        themeMode: ThemeMode.dark,
        useDynamicColor: false,
        seedColorValue: 0xff123456,
        useAmoled: true,
        style: AppThemeStyle.mornye,
        mornyeAccent: MornyeAccent.blue,
        useSystemFont: true,
      );

      final decoded = ThemeSettings.fromJson(settings.toJson());
      final copied = decoded.copyWith(themeMode: ThemeMode.light);

      expect(decoded, settings);
      expect(decoded.hashCode, settings.hashCode);
      expect(decoded.seedColor, const Color(0xff123456));
      expect(copied.themeMode, ThemeMode.light);
      expect(copied.useAmoled, isTrue);
      expect(decoded.style, AppThemeStyle.mornye);
      expect(decoded.mornyeAccent, MornyeAccent.blue);
      expect(copied.mornyeAccent, MornyeAccent.blue);
      expect(decoded.useSystemFont, isTrue);
      expect(copied.useSystemFont, isTrue);
      expect(ThemeSettings.fromJson({}).useSystemFont, isFalse);
      expect(ThemeSettings.fromJson({}).mornyeAccent, MornyeAccent.blue);
      expect(
        ThemeSettings.fromJson({kMornyeAccentKey: 'unknown'}).mornyeAccent,
        MornyeAccent.blue,
      );
      expect(
        ThemeSettings.fromJson({kMornyeAccentKey: 'red'}).mornyeAccent,
        MornyeAccent.red,
        reason: 'a saved choice stays',
      );
      expect(
        ThemeSettings.fromJson({'theme_mode': 'invalid'}).themeMode,
        ThemeMode.system,
      );
      expect(
        ThemeSettings.fromJson({'theme_style': 'invalid'}).style,
        AppThemeStyle.material,
      );
    });
  });
}
