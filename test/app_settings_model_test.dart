import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/models/theme_settings.dart';
import 'package:mornye/utils/artist_utils.dart';

void main() {
  test('Autoplay randomness defaults to least recent and restores safely', () {
    expect(const AppSettings().autoplayRandomness, 0);
    expect(AppSettings.fromJson({}).autoplayRandomness, 0);
    for (final value in [0.0, 0.5, 1.0]) {
      final settings = const AppSettings().copyWith(autoplayRandomness: value);
      final restored = AppSettings.fromJson(settings.toJson());
      expect(restored.autoplayRandomness, value);
      expect(restored.copyWith(locale: 'id').autoplayRandomness, value);
    }
    for (final invalid in [null, '', double.nan, double.infinity]) {
      expect(
        AppSettings.fromJson({
          'autoplayRandomness': invalid,
        }).autoplayRandomness,
        0,
      );
    }
    expect(
      AppSettings.fromJson({'autoplayRandomness': -5}).autoplayRandomness,
      0,
    );
    expect(
      AppSettings.fromJson({'autoplayRandomness': 5}).autoplayRandomness,
      1,
    );
  });

  test('Interface size defaults to normal and restores within range', () {
    expect(const AppSettings().interfaceScale, 1);
    expect(AppSettings.fromJson({}).interfaceScale, 1);
    for (final value in [0.8, 0.9, 1.25, 1.3]) {
      final settings = const AppSettings().copyWith(interfaceScale: value);
      final restored = AppSettings.fromJson(settings.toJson());
      expect(restored.interfaceScale, value);
      expect(restored.copyWith(locale: 'id').interfaceScale, value);
    }
    for (final invalid in ['', double.nan, double.infinity]) {
      expect(
        AppSettings.fromJson({'interfaceScale': invalid}).interfaceScale,
        1,
      );
    }
    expect(AppSettings.fromJson({'interfaceScale': 0.2}).interfaceScale, 0.8);
    expect(AppSettings.fromJson({'interfaceScale': 3}).interfaceScale, 1.3);
  });

  test('Animation speed defaults to normal and restores within range', () {
    expect(const AppSettings().animationSpeed, 1);
    expect(AppSettings.fromJson({}).animationSpeed, 1);
    for (final value in [0.5, 0.75, 1.5, 2.0]) {
      final settings = const AppSettings().copyWith(animationSpeed: value);
      final restored = AppSettings.fromJson(settings.toJson());
      expect(restored.animationSpeed, value);
      expect(restored.copyWith(locale: 'id').animationSpeed, value);
    }
    for (final invalid in ['', double.nan, double.infinity]) {
      expect(
        AppSettings.fromJson({'animationSpeed': invalid}).animationSpeed,
        1,
      );
    }
    expect(AppSettings.fromJson({'animationSpeed': 0.1}).animationSpeed, 0.5);
    expect(AppSettings.fromJson({'animationSpeed': 9}).animationSpeed, 2);
  });

  test('Playback speed and pitch default to normal and restore in range', () {
    const defaults = AppSettings();
    expect(defaults.playbackSpeed, 1);
    expect(defaults.playbackKeepPitch, isTrue);
    expect(defaults.playbackPitch, 0);
    final empty = AppSettings.fromJson({});
    expect(empty.playbackSpeed, 1);
    expect(empty.playbackKeepPitch, isTrue);
    expect(empty.playbackPitch, 0);

    final changed = defaults.copyWith(
      playbackSpeed: 1.25,
      playbackKeepPitch: false,
      playbackPitch: -3,
    );
    final restored = AppSettings.fromJson(changed.toJson());
    expect(restored.playbackSpeed, 1.25);
    expect(restored.playbackKeepPitch, isFalse);
    expect(restored.playbackPitch, -3);
    // Half semitones from earlier builds restore as whole ones.
    expect(AppSettings.fromJson({'playbackPitch': 2.5}).playbackPitch, 3);
    expect(AppSettings.fromJson({'playbackPitch': -1.4}).playbackPitch, -1);
    expect(restored.copyWith(locale: 'id').playbackSpeed, 1.25);

    for (final invalid in ['', double.nan, double.infinity]) {
      final settings = AppSettings.fromJson({
        'playbackSpeed': invalid,
        'playbackPitch': invalid,
      });
      expect(settings.playbackSpeed, 1);
      expect(settings.playbackPitch, 0);
    }
    final clamped = AppSettings.fromJson({
      'playbackSpeed': 9,
      'playbackPitch': -40,
    });
    expect(clamped.playbackSpeed, maxPlaybackSpeed);
    expect(clamped.playbackPitch, -maxPlaybackPitch);
  });

  test('Link hides disconnected devices by default and remembers off', () {
    expect(const AppSettings().linkHideDisconnectedSongs, isTrue);
    expect(AppSettings.fromJson({}).linkHideDisconnectedSongs, isTrue);
    final off = const AppSettings().copyWith(linkHideDisconnectedSongs: false);
    expect(AppSettings.fromJson(off.toJson()).linkHideDisconnectedSongs, false);
    expect(off.copyWith(locale: 'id').linkHideDisconnectedSongs, isFalse);
  });

  test('Swipe to queue is on by default and remembers off', () {
    expect(const AppSettings().swipeToQueue, isTrue);
    expect(AppSettings.fromJson({}).swipeToQueue, isTrue);
    final off = const AppSettings().copyWith(swipeToQueue: false);
    expect(AppSettings.fromJson(off.toJson()).swipeToQueue, isFalse);
    expect(off.copyWith(locale: 'id').swipeToQueue, isFalse);
  });

  test('A Library song tap opens details by default and remembers play', () {
    expect(
      const AppSettings().librarySongTap,
      AppSettings.librarySongTapDetails,
    );
    // Settings saved before the choice existed keep opening the details.
    expect(
      AppSettings.fromJson({'swipeToQueue': true}).librarySongTap,
      AppSettings.librarySongTapDetails,
    );
    final play = const AppSettings().copyWith(
      librarySongTap: AppSettings.librarySongTapPlay,
    );
    expect(
      AppSettings.fromJson(play.toJson()).librarySongTap,
      AppSettings.librarySongTapPlay,
    );
    expect(
      play.copyWith(locale: 'id').librarySongTap,
      AppSettings.librarySongTapPlay,
    );
  });

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

  test('album sort restores either year order and tolerates old settings', () {
    expect(AppSettings.fromJson({}).libraryAlbumSortMode, 'a-z');
    for (final invalid in [null, '', 'unsupported', 42]) {
      expect(
        AppSettings.fromJson({
          'libraryAlbumSortMode': invalid,
        }).libraryAlbumSortMode,
        'a-z',
      );
    }
    for (final mode in ['year-asc', 'year-desc']) {
      final settings = const AppSettings().copyWith(libraryAlbumSortMode: mode);
      expect(
        AppSettings.fromJson(settings.toJson()).libraryAlbumSortMode,
        mode,
      );
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
      expect(settings.autoConvertSmartDither, isTrue);
      expect(settings.autoConvertSmartDitherHighPass, isFalse);
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
        autoConvertSmartDither: false,
        autoConvertSmartDitherHighPass: true,
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
      expect(decoded.autoConvertSmartDither, isFalse);
      expect(decoded.autoConvertSmartDitherHighPass, isTrue);
      expect(decoded.copyWith(locale: 'id').autoConvertSmartDither, isFalse);
      expect(
        decoded.copyWith(autoConvertSmartDither: true).autoConvertSmartDither,
        isTrue,
      );
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
