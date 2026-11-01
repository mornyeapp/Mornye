import 'package:flutter/material.dart';
import 'package:mornye/l10n/app_localizations.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:mornye/utils/exclusive_output_labels.dart';

/// A control or submenu that can be discovered from the root Settings search.
///
/// The catalog contains only presentation metadata. The owning settings page
/// remains responsible for reading and changing the actual setting value.
class SettingsSearchEntry {
  const SettingsSearchEntry({
    required this.icon,
    required this.title,
    this.subtitle,
    this.keywords = const [],
    String? targetLabel,
  }) : targetLabel = targetLabel ?? title;

  final IconData icon;
  final String title;
  final String? subtitle;
  final List<String> keywords;

  /// Label of the actual destination widget. Usually the result title, but a
  /// hidden or toolbar-only action may point at its nearest visible section.
  final String targetLabel;

  bool matches(SettingsSearchQuery query) =>
      query.matches([title, ?subtitle, ...keywords]);
}

/// Normalizes the query once per keystroke, rather than once for every entry.
class SettingsSearchQuery {
  SettingsSearchQuery(String value)
    : terms = value
          .trim()
          .toLowerCase()
          .split(RegExp(r'\s+'))
          .where((term) => term.isNotEmpty)
          .toList(growable: false);

  final List<String> terms;

  bool get isEmpty => terms.isEmpty;

  bool matches(Iterable<String> values) {
    if (isEmpty) return true;
    final haystack = values.join(' ').toLowerCase();
    return terms.every(haystack.contains);
  }
}

/// Localized index of controls found inside every first-level settings page.
class SettingsSearchCatalog {
  SettingsSearchCatalog(AppLocalizations l10n, {bool androidAudio = false})
    : extensions = [
        SettingsSearchEntry(
          icon: Icons.low_priority,
          title: l10n.extensionsDownloadPriority,
          subtitle: l10n.extensionsDownloadPrioritySubtitle,
          keywords: const ['provider order', 'service order'],
        ),
        SettingsSearchEntry(
          icon: Icons.alt_route,
          title: l10n.extensionsFallbackTitle,
          subtitle: l10n.extensionsFallbackSubtitle,
          keywords: const ['provider fallback'],
        ),
        SettingsSearchEntry(
          icon: Icons.manage_search,
          title: l10n.extensionsMetadataPriority,
          subtitle: l10n.extensionsMetadataPrioritySubtitle,
          keywords: const ['metadata provider order'],
        ),
        SettingsSearchEntry(
          icon: Icons.search,
          title: l10n.extensionsSearchProvider,
          subtitle: l10n.extensionsSearchProviderDescription,
          keywords: const ['home search source'],
        ),
        SettingsSearchEntry(
          icon: Icons.explore_outlined,
          title: l10n.extensionsHomeFeedProvider,
          subtitle: l10n.extensionsHomeFeedDescription,
          keywords: const ['home provider', 'feed source'],
        ),
        SettingsSearchEntry(
          icon: Icons.add,
          title: l10n.extensionsInstallButton,
          keywords: const ['add plugin', 'import extension'],
        ),
      ],
      appearance = [
        SettingsSearchEntry(
          icon: Icons.rounded_corner,
          title: l10n.appearanceGlassOutlines,
          subtitle: l10n.appearanceGlassOutlinesSubtitle,
          keywords: const [
            'mornye',
            'liquid glass',
            'border',
            'rim',
            'outline',
          ],
        ),
        SettingsSearchEntry(
          icon: Icons.wallpaper,
          title: l10n.appearanceDynamicColor,
          subtitle: l10n.appearanceDynamicColorSubtitle,
          keywords: const ['material you', 'system color'],
        ),
        SettingsSearchEntry(
          icon: Icons.color_lens_outlined,
          title: l10n.sectionColor,
          keywords: const ['palette', 'seed color', 'accent'],
        ),
        SettingsSearchEntry(
          icon: Icons.contrast,
          title: l10n.sectionTheme,
          subtitle:
              '${l10n.appearanceThemeSystem}, ${l10n.appearanceThemeLight}, '
              '${l10n.appearanceThemeDark}',
          keywords: const ['light mode', 'dark mode'],
        ),
        SettingsSearchEntry(
          icon: Icons.brightness_2,
          title: l10n.appearanceAmoledDark,
          subtitle: l10n.appearanceAmoledDarkSubtitle,
          keywords: const ['black theme', 'oled'],
        ),
        SettingsSearchEntry(
          icon: Icons.font_download_outlined,
          title: l10n.appearanceUseSystemFont,
          subtitle: l10n.appearanceUseSystemFontSubtitle,
          keywords: const [
            'font',
            'typeface',
            'typography',
            'system font',
            'huruf',
          ],
        ),
        SettingsSearchEntry(
          icon: Icons.animation,
          title: l10n.appearanceHeroAnimations,
          subtitle: l10n.appearanceHeroAnimationsSubtitle,
          keywords: const ['transition', 'motion'],
        ),
        SettingsSearchEntry(
          icon: Icons.blur_on,
          title: l10n.appearanceForceBlur,
          subtitle: l10n.appearanceForceBlurSubtitle,
          keywords: const ['backdrop blur', 'performance'],
        ),
        SettingsSearchEntry(
          icon: Icons.language,
          title: l10n.appearanceLanguage,
          keywords: const ['locale', 'translation'],
        ),
        SettingsSearchEntry(
          icon: Icons.grid_view_outlined,
          title: l10n.appearanceHistoryView,
          subtitle:
              '${l10n.appearanceHistoryViewList}, '
              '${l10n.appearanceHistoryViewGrid}',
          keywords: const ['layout', 'list', 'grid'],
        ),
      ],
      library = [
        SettingsSearchEntry(
          icon: Icons.grid_view_rounded,
          title: l10n.libraryDefaultView,
          keywords: const ['library tab', 'default page'],
        ),
        SettingsSearchEntry(
          icon: Icons.graphic_eq_rounded,
          title: l10n.trackAudioQuality,
          keywords: const [
            'quality label',
            'bitrate',
            'bit depth',
            'file format',
            'codec',
            'flac',
            'mp3',
            'kbps',
          ],
        ),
        SettingsSearchEntry(
          icon: Icons.library_music_outlined,
          title: l10n.libraryEnableLocalLibrary,
          subtitle: l10n.libraryEnableLocalLibrarySubtitle,
          keywords: const ['local music'],
        ),
        SettingsSearchEntry(
          icon: Icons.folder_outlined,
          title: l10n.libraryFolder,
          keywords: const ['local path', 'scan folder'],
        ),
        SettingsSearchEntry(
          icon: Icons.content_copy_outlined,
          title: l10n.libraryShowDuplicateIndicator,
          subtitle: l10n.libraryShowDuplicateIndicatorSubtitle,
          keywords: const ['duplicate badge'],
        ),
        SettingsSearchEntry(
          icon: Icons.difference_outlined,
          title: l10n.libraryReviewDuplicates,
          subtitle: l10n.libraryReviewDuplicatesSubtitle,
          keywords: const ['duplicate songs'],
        ),
        SettingsSearchEntry(
          icon: Icons.autorenew_rounded,
          title: l10n.libraryAutoScan,
          keywords: const ['automatic scan', 'daily', 'weekly'],
        ),
        SettingsSearchEntry(
          icon: Icons.refresh,
          title: l10n.libraryScan,
          subtitle: l10n.libraryScanSubtitle,
          keywords: const ['rescan', 'refresh music'],
        ),
        SettingsSearchEntry(
          icon: Icons.sync,
          title: l10n.libraryForceFullScan,
          subtitle: l10n.libraryForceFullScanSubtitle,
          keywords: const ['rescan all'],
        ),
        SettingsSearchEntry(
          icon: Icons.cleaning_services_outlined,
          title: l10n.libraryCleanupMissingFiles,
          subtitle: l10n.libraryCleanupMissingFilesSubtitle,
          keywords: const ['remove missing'],
        ),
        SettingsSearchEntry(
          icon: Icons.delete_outline,
          title: l10n.libraryClear,
          subtitle: l10n.libraryClearSubtitle,
          keywords: const ['reset local library'],
        ),
      ],
      playback = [
        if (isDesktopPlatform)
          SettingsSearchEntry(
            icon: Icons.history_rounded,
            title: 'Last.fm',
            subtitle: l10n.lastfmDescription,
            keywords: const ['lastfm', 'scrobble', 'scrobbling', 'now playing'],
          ),
        SettingsSearchEntry(
          icon: Icons.equalizer,
          title: l10n.equalizerTitle,
          subtitle: l10n.equalizerDescription,
          keywords: const [
            'eq',
            'equalizer',
            'bass',
            'treble',
            'preamp',
            'compressor',
            'limiter',
          ],
        ),
        SettingsSearchEntry(
          icon: Icons.playlist_play_rounded,
          title: l10n.autoplayFromLibrary,
          subtitle: l10n.autoplayDescription,
          keywords: const ['autoplay', 'queue', 'recommendation'],
        ),
        SettingsSearchEntry(
          icon: Icons.auto_awesome_outlined,
          title: l10n.autoplayPersonalization,
          subtitle: l10n.autoplayPersonalizationDescription,
          keywords: const ['machine learning', 'recommendation', 'personal'],
        ),
        SettingsSearchEntry(
          icon: Icons.multitrack_audio,
          title: l10n.songAnalysis,
          subtitle: l10n.songAnalysisDescription,
          keywords: const ['sound', 'tempo', 'bpm', 'key', 'recommendation'],
        ),
        SettingsSearchEntry(
          icon: Icons.insights_outlined,
          title: l10n.listeningStats,
          subtitle: l10n.listeningStatsDescription,
          keywords: const ['wrapped', 'statistics', 'listening', 'stats'],
        ),
        SettingsSearchEntry(
          icon: Icons.motion_photos_on_outlined,
          title: l10n.motionArtwork,
          subtitle: l10n.motionArtworkDescription,
          keywords: const ['canvas', 'video', 'animation'],
        ),
        SettingsSearchEntry(
          icon: Icons.open_in_new,
          title: l10n.libraryExternalPlayer,
          subtitle: l10n.libraryExternalPlayerSubtitle,
          keywords: const ['playback app'],
        ),
        SettingsSearchEntry(
          icon: Icons.play_circle_outline,
          title: l10n.libraryBuiltInPreviewPlayer,
          subtitle: l10n.libraryBuiltInPreviewPlayerSubtitle,
          keywords: const ['internal player'],
        ),
        SettingsSearchEntry(
          icon: Icons.graphic_eq,
          title: l10n.libraryPlaybackNormalization,
          subtitle: l10n.libraryPlaybackNormalizationSubtitle,
          keywords: const [
            'replaygain',
            'volume',
            'loudness',
            'lufs',
            'preamp',
            'album gain',
          ],
        ),
        SettingsSearchEntry(
          icon: Icons.fullscreen,
          title: l10n.playerCoverStyle,
          subtitle: l10n.playerCoverStyleFullScreenDescription,
          keywords: const ['artwork', 'cover', 'full screen', 'immersive'],
        ),
        SettingsSearchEntry(
          icon: Icons.splitscreen_outlined,
          title: l10n.landscapeLyricsArtwork,
          subtitle: l10n.landscapeLyricsArtworkDescription,
          keywords: const ['landscape', 'lyrics', 'album art', 'details'],
        ),
        SettingsSearchEntry(
          icon: Icons.short_text,
          title: l10n.compactPlayer,
          subtitle: l10n.compactPlayerDescription,
          keywords: const ['lyrics', 'compact', 'controls', 'mini', 'larger'],
        ),
        SettingsSearchEntry(
          icon: Icons.vibration,
          title: l10n.musicHaptics,
          subtitle: l10n.musicHapticsDescription,
          keywords: const ['haptic', 'vibrate', 'vibration', 'beat', 'getar'],
        ),
        SettingsSearchEntry(
          icon: Icons.volume_off_outlined,
          title: l10n.playbackPauseOnMute,
          subtitle: l10n.playbackPauseOnMuteDescription,
          keywords: const ['mute', 'volume', 'pause', 'resume'],
        ),
        SettingsSearchEntry(
          icon: Icons.headphones_outlined,
          title: l10n.playbackOnHeadphonesConnected,
          subtitle: l10n.playbackOnHeadphonesConnectedDescription,
          keywords: const ['earphone', 'headphone', 'bluetooth', 'connect'],
        ),
        SettingsSearchEntry(
          icon: Icons.linear_scale,
          title: l10n.gaplessPlayback,
          subtitle: l10n.gaplessPlaybackDescription,
          keywords: const ['gapless', 'gap', 'silence', 'transition', 'album'],
        ),
        SettingsSearchEntry(
          icon: Icons.compare_arrows,
          title: 'AutoMix',
          subtitle: l10n.autoMixDescription,
          keywords: const [
            'crossfade',
            'beat matching',
            'duration',
            'pitch',
            'echo',
            'filter',
            'speed',
          ],
        ),
        if (androidAudio) ...[
          SettingsSearchEntry(
            icon: Icons.usb,
            title: l10n.usbBitPerfect,
            subtitle: l10n.usbBitPerfectDescription,
            keywords: const ['usb', 'dac', 'dsd', 'dop', 'hardware volume'],
          ),
          SettingsSearchEntry(
            icon: Icons.headphones,
            title: l10n.dapExclusive,
            subtitle: l10n.dapExclusiveDescription,
            keywords: const ['oboe', 'aaudio', 'exclusive', 'hi-res'],
            targetLabel: l10n.usbBitPerfect,
          ),
        ],
        if (isDesktopPlatform)
          SettingsSearchEntry(
            icon: Icons.speaker_outlined,
            title: exclusiveOutputLabels(l10n).title,
            subtitle: exclusiveOutputLabels(l10n).description,
            keywords: const [
              'exclusive',
              'wasapi',
              'hog mode',
              'alsa',
              'bit-perfect',
              'mixer',
            ],
          ),
      ],
      metadata = [
        SettingsSearchEntry(
          icon: Icons.format_list_bulleted,
          title: l10n.metadataSeparators,
          keywords: const [
            'separator',
            'delimiter',
            'composer',
            'genre',
            'album artist',
          ],
        ),
        SettingsSearchEntry(
          icon: Icons.sell_outlined,
          title: l10n.optionsEmbedMetadata,
          keywords: const ['tags', 'write metadata'],
        ),
        SettingsSearchEntry(
          icon: Icons.people_alt_outlined,
          title: l10n.optionsArtistTagMode,
          keywords: const [
            'artist separator',
            'multiple artists',
            'primary artist',
          ],
        ),
        SettingsSearchEntry(
          icon: Icons.photo_size_select_large_outlined,
          title: l10n.optionsEmbeddedCoverSize,
          subtitle: l10n.optionsEmbeddedCoverSizeDescription,
          keywords: const ['cover size', 'artwork resolution', 'resize image'],
        ),
        SettingsSearchEntry(
          icon: Icons.graphic_eq,
          title: l10n.optionsReplayGain,
          keywords: const ['volume normalization', 'loudness'],
        ),
        SettingsSearchEntry(
          icon: Icons.source_outlined,
          title: l10n.metadataProvidersTitle,
          subtitle: l10n.metadataProvidersSubtitle,
          keywords: const ['metadata priority', 'tag provider'],
        ),
        SettingsSearchEntry(
          icon: Icons.filter_list_outlined,
          title: l10n.downloadDeduplication,
          keywords: const ['duplicate download', 'same song'],
        ),
        SettingsSearchEntry(
          icon: Icons.library_music_outlined,
          title: l10n.downloadQualityVariants,
          subtitle: l10n.downloadQualityVariantsDescription,
          keywords: const ['different quality', 'multiple versions'],
        ),
      ],
      lyrics = [
        SettingsSearchEntry(
          icon: Icons.light_mode_outlined,
          title: l10n.lyricsKeepScreenOn,
          subtitle: l10n.lyricsKeepScreenOnSubtitle,
          keywords: const ['screen timeout', 'awake', 'sleep', 'layar'],
        ),
        SettingsSearchEntry(
          icon: Icons.auto_awesome_outlined,
          title: l10n.lyricsAiTranslation,
          keywords: const [
            'translate lyrics',
            'api key',
            'openai',
            'gemini',
            'claude',
            'openrouter',
            'ollama',
          ],
        ),
        SettingsSearchEntry(
          icon: Icons.subtitles_outlined,
          title: l10n.optionsEmbedLyrics,
          keywords: const ['write lyrics', 'lrc'],
        ),
        SettingsSearchEntry(
          icon: Icons.lyrics_outlined,
          title: l10n.lyricsMode,
          keywords: const ['synced', 'plain', 'lyrics type'],
        ),
        SettingsSearchEntry(
          icon: Icons.source_outlined,
          title: l10n.lyricsProvidersTitle,
          keywords: const ['lyrics priority', 'lyrics source'],
        ),
        SettingsSearchEntry(
          icon: Icons.translate_outlined,
          title: l10n.downloadNeteaseIncludeTranslation,
          keywords: const ['translated lyrics'],
        ),
        SettingsSearchEntry(
          icon: Icons.text_fields_outlined,
          title: l10n.downloadNeteaseIncludeRomanization,
          keywords: const ['romanized lyrics', 'latin'],
        ),
        SettingsSearchEntry(
          icon: Icons.record_voice_over_outlined,
          title: l10n.downloadAppleQqMultiPerson,
          keywords: const ['duet', 'multi singer'],
        ),
        SettingsSearchEntry(
          icon: Icons.graphic_eq_outlined,
          title: l10n.downloadAppleElrcWordSync,
          keywords: const ['word synced', 'elrc'],
        ),
        SettingsSearchEntry(
          icon: Icons.language_outlined,
          title: l10n.downloadMusixmatchLanguage,
          keywords: const ['lyrics locale'],
        ),
      ],
      download = [
        SettingsSearchEntry(
          icon: Icons.extension_outlined,
          title: l10n.sectionService,
          keywords: const ['download provider', 'default service'],
        ),
        SettingsSearchEntry(
          icon: Icons.tune,
          title: l10n.downloadAskBeforeDownload,
          subtitle: l10n.downloadAskQualitySubtitle,
          keywords: const ['quality picker', 'ask quality'],
        ),
        SettingsSearchEntry(
          icon: Icons.audiotrack,
          title: l10n.downloadLossyFormat,
          keywords: const ['mp3', 'aac', 'opus'],
        ),
        SettingsSearchEntry(
          icon: Icons.verified_outlined,
          title: l10n.downloadRedownloadFakeHiRes,
          subtitle: l10n.downloadRedownloadFakeHiResSubtitle,
          keywords: const ['hi-res', 'hires', 'fake', 'upsampled', '24-bit'],
        ),
        SettingsSearchEntry(
          icon: Icons.auto_fix_high_outlined,
          title: l10n.downloadAutoConvert,
          subtitle: l10n.downloadAutoConvertSubtitle,
          keywords: const [
            'automatic conversion',
            'mp3',
            'm4a',
            'aac',
            'opus',
            'bitrate',
          ],
        ),
        SettingsSearchEntry(
          icon: Icons.wifi,
          title: l10n.settingsDownloadNetwork,
          subtitle: l10n.settingsDownloadNetworkSubtitle,
          keywords: const ['wifi only', 'mobile data'],
        ),
        SettingsSearchEntry(
          icon: Icons.dynamic_feed_outlined,
          title: l10n.settingsConcurrentDownloads,
          subtitle: l10n.settingsConcurrentDownloadsSubtitle,
          keywords: const ['parallel downloads', 'simultaneous'],
        ),
        SettingsSearchEntry(
          icon: Icons.downloading_outlined,
          title: l10n.downloadNativeWorker,
          subtitle: l10n.downloadNativeWorkerSubtitle,
          keywords: const ['background worker', 'android worker'],
        ),
        SettingsSearchEntry(
          icon: Icons.security_outlined,
          title: l10n.downloadNetworkCompatibilityMode,
          keywords: const ['network fallback', 'connection compatibility'],
        ),
        SettingsSearchEntry(
          icon: Icons.lan_outlined,
          title: l10n.downloadAllowLocalNetwork,
          keywords: const ['lan', 'private network'],
        ),
        SettingsSearchEntry(
          icon: Icons.manage_search,
          title: l10n.optionsPrimaryProvider,
          subtitle: l10n.optionsPrimaryProviderSubtitle,
          keywords: const ['search source', 'metadata source'],
        ),
        SettingsSearchEntry(
          icon: Icons.tab_outlined,
          title: l10n.optionsDefaultSearchTab,
          subtitle: l10n.optionsDefaultSearchTabSubtitle,
          keywords: const ['track album artist playlist'],
        ),
        SettingsSearchEntry(
          icon: Icons.sync,
          title: l10n.optionsAutoFallback,
          subtitle: l10n.optionsAutoFallbackSubtitle,
          keywords: const ['automatic provider fallback'],
        ),
        SettingsSearchEntry(
          icon: Icons.extension_outlined,
          title: l10n.downloadFallbackExtensions,
          subtitle: l10n.downloadFallbackExtensionsSubtitle,
          keywords: const ['provider order'],
        ),
        SettingsSearchEntry(
          icon: Icons.public,
          title: l10n.downloadSongLinkRegion,
          keywords: const ['country', 'region'],
        ),
        SettingsSearchEntry(
          icon: Icons.file_download_outlined,
          title: l10n.settingsAutoExportFailed,
          subtitle: l10n.settingsAutoExportFailedSubtitle,
          keywords: const ['failed downloads', 'export errors'],
        ),
      ],
      files = [
        SettingsSearchEntry(
          icon: Icons.folder_outlined,
          title: l10n.downloadDirectory,
          keywords: const ['download folder', 'saf', 'storage path'],
        ),
        SettingsSearchEntry(
          icon: Icons.text_fields,
          title: l10n.downloadFilenameFormat,
          keywords: const ['file naming', 'template'],
        ),
        SettingsSearchEntry(
          icon: Icons.music_note_outlined,
          title: l10n.downloadSingleFilenameFormat,
          keywords: const ['single naming', 'file template'],
        ),
        SettingsSearchEntry(
          icon: Icons.library_music_outlined,
          title: l10n.downloadSeparateSinglesFolder,
          keywords: const ['singles directory'],
        ),
        SettingsSearchEntry(
          icon: Icons.folder_outlined,
          title: l10n.downloadAlbumFolderStructure,
          keywords: const ['album directory', 'folder template'],
        ),
        SettingsSearchEntry(
          icon: Icons.create_new_folder_outlined,
          title: l10n.downloadFolderOrganization,
          keywords: const ['organize folders', 'directory layout'],
        ),
        SettingsSearchEntry(
          icon: Icons.folder_copy_outlined,
          title: l10n.downloadFolderTemplate,
          keywords: const [
            'folder placeholders',
            'custom path',
            'release date',
            'subfolders',
          ],
        ),
        SettingsSearchEntry(
          icon: Icons.playlist_play_outlined,
          title: l10n.downloadCreatePlaylistSourceFolder,
          keywords: const ['playlist directory'],
        ),
        SettingsSearchEntry(
          icon: Icons.person_search_outlined,
          title: l10n.downloadUseAlbumArtistForFolders,
          keywords: const ['album artist directory'],
        ),
        SettingsSearchEntry(
          icon: Icons.filter_alt_outlined,
          title: l10n.downloadArtistNameFilters,
          keywords: const ['artist folder filter'],
        ),
        SettingsSearchEntry(
          icon: Icons.person_outline,
          title: l10n.downloadUsePrimaryArtistOnly,
          keywords: const ['main artist folder'],
        ),
        SettingsSearchEntry(
          icon: Icons.group_remove_outlined,
          title: l10n.downloadFilterContributing,
          keywords: const ['featured artist folder'],
        ),
        SettingsSearchEntry(
          icon: Icons.folder_special_outlined,
          title: l10n.allFilesAccess,
          subtitle: l10n.allFilesAccessDescription,
          keywords: const ['storage permission', 'manage files'],
        ),
      ],
      app = [
        SettingsSearchEntry(
          icon: Icons.extension,
          title: l10n.optionsExtensionStore,
          subtitle: l10n.optionsExtensionStoreSubtitle,
          keywords: const ['repository', 'plugin store'],
        ),
        SettingsSearchEntry(
          icon: Icons.open_in_browser,
          title: l10n.extensionVerificationBrowserTitle,
          keywords: const ['captcha', 'turnstile', 'external browser'],
        ),
        SettingsSearchEntry(
          icon: Icons.system_update,
          title: l10n.optionsCheckUpdates,
          subtitle: l10n.optionsCheckUpdatesSubtitle,
          keywords: const ['app update'],
        ),
        SettingsSearchEntry(
          icon: Icons.new_releases,
          title: l10n.optionsUpdateChannel,
          keywords: const ['stable', 'preview', 'beta'],
        ),
        SettingsSearchEntry(
          icon: Icons.cleaning_services_outlined,
          title: l10n.cleanupOrphanedDownloads,
          subtitle: l10n.cleanupOrphanedDownloadsSubtitle,
          keywords: const ['stale queue', 'missing download'],
        ),
        SettingsSearchEntry(
          icon: Icons.delete_forever,
          title: l10n.optionsClearHistory,
          subtitle: l10n.optionsClearHistorySubtitle,
          keywords: const ['delete history'],
        ),
        SettingsSearchEntry(
          icon: Icons.history_toggle_off_outlined,
          title: l10n.settingsSaveDownloadHistory,
          subtitle: l10n.settingsSaveDownloadHistorySubtitle,
          keywords: const ['remember downloads'],
        ),
        SettingsSearchEntry(
          icon: Icons.bug_report,
          title: l10n.optionsDetailedLogging,
          keywords: const ['debug logs', 'diagnostics'],
        ),
      ],
      cache = [
        SettingsSearchEntry(
          icon: Icons.folder_outlined,
          title: l10n.cacheAppDirectory,
          subtitle: l10n.cacheAppDirectoryDesc,
          keywords: const ['application cache'],
        ),
        SettingsSearchEntry(
          icon: Icons.timer_outlined,
          title: l10n.cacheTempDirectory,
          subtitle: l10n.cacheTempDirectoryDesc,
          keywords: const ['temporary files'],
        ),
        SettingsSearchEntry(
          icon: Icons.image_outlined,
          title: l10n.cacheCoverImage,
          subtitle: l10n.cacheCoverImageDesc,
          keywords: const ['artwork cache'],
        ),
        SettingsSearchEntry(
          icon: Icons.library_music_outlined,
          title: l10n.cacheLibraryCover,
          subtitle: l10n.cacheLibraryCoverDesc,
          keywords: const ['local artwork cache'],
        ),
        SettingsSearchEntry(
          icon: Icons.graphic_eq_outlined,
          title: l10n.cacheAudioAnalysis,
          subtitle: l10n.cacheAudioAnalysisDesc,
          keywords: const ['spectrogram cache'],
        ),
        SettingsSearchEntry(
          icon: Icons.explore_outlined,
          title: l10n.cacheExploreFeed,
          subtitle: l10n.cacheExploreFeedDesc,
          keywords: const ['home feed cache'],
        ),
        SettingsSearchEntry(
          icon: Icons.memory_outlined,
          title: l10n.cacheTrackLookup,
          subtitle: l10n.cacheTrackLookupDesc,
          keywords: const ['search cache'],
        ),
        SettingsSearchEntry(
          icon: Icons.cleaning_services_outlined,
          title: l10n.cacheCleanupUnused,
          subtitle: l10n.cacheCleanupUnusedDesc,
          keywords: const ['clear cache', 'free space'],
        ),
        SettingsSearchEntry(
          icon: Icons.delete_sweep_outlined,
          title: l10n.cacheClearAll,
          targetLabel: l10n.cacheSectionMaintenance,
          keywords: const ['delete all cache'],
        ),
      ],
      backup = [
        SettingsSearchEntry(
          icon: Icons.vpn_key_outlined,
          title: l10n.backupIncludeSecrets,
          subtitle: l10n.backupIncludeSecretsDescription,
          keywords: const ['tokens', 'credentials'],
        ),
        SettingsSearchEntry(
          icon: Icons.ios_share,
          title: l10n.backupExportButton,
          subtitle: l10n.backupExportSectionDescription,
          keywords: const ['create backup', 'save settings'],
        ),
        SettingsSearchEntry(
          icon: Icons.settings_backup_restore,
          title: l10n.backupImportButton,
          subtitle: l10n.backupImportSectionDescription,
          keywords: const ['restore backup', 'load settings'],
        ),
      ],
      logs = [
        SettingsSearchEntry(
          icon: Icons.filter_list,
          title: l10n.logFilterLevel,
          subtitle: l10n.logFilterBySeverity,
          targetLabel: l10n.logFilterSection,
          keywords: const ['severity', 'error warning debug'],
        ),
        SettingsSearchEntry(
          icon: Icons.search,
          title: l10n.logSearchHint,
          targetLabel: l10n.logFilterSection,
          keywords: const ['find logs'],
        ),
        SettingsSearchEntry(
          icon: Icons.copy,
          title: l10n.logCopyLogs,
          targetLabel: l10n.logFilterSection,
          keywords: const ['clipboard'],
        ),
        SettingsSearchEntry(
          icon: Icons.share,
          title: l10n.logShareLogs,
          targetLabel: l10n.logFilterSection,
          keywords: const ['export logs'],
        ),
        SettingsSearchEntry(
          icon: Icons.delete_outline,
          title: l10n.logClearLogs,
          targetLabel: l10n.logFilterSection,
          keywords: const ['delete logs'],
        ),
      ],
      about = [
        SettingsSearchEntry(
          icon: Icons.info_outline,
          title: l10n.aboutVersion,
          keywords: const ['build number', 'app version'],
        ),
        SettingsSearchEntry(
          icon: Icons.people_outline,
          title: l10n.aboutContributors,
          keywords: const ['developers', 'credits'],
        ),
        SettingsSearchEntry(
          icon: Icons.translate,
          title: l10n.aboutTranslators,
          keywords: const ['translation credits'],
        ),
        SettingsSearchEntry(
          icon: Icons.code,
          title: l10n.aboutMobileSource,
          keywords: const ['github', 'source code'],
        ),
        SettingsSearchEntry(
          icon: Icons.bug_report_outlined,
          title: l10n.aboutReportIssue,
          subtitle: l10n.aboutReportIssueSubtitle,
          keywords: const ['bug report'],
        ),
        SettingsSearchEntry(
          icon: Icons.lightbulb_outline,
          title: l10n.aboutFeatureRequest,
          subtitle: l10n.aboutFeatureRequestSubtitle,
          keywords: const ['suggestion', 'idea'],
        ),
        SettingsSearchEntry(
          icon: Icons.telegram,
          title: l10n.aboutTelegramChannel,
          subtitle: l10n.aboutTelegramChannelSubtitle,
          keywords: const ['social'],
        ),
        SettingsSearchEntry(
          icon: Icons.forum_outlined,
          title: l10n.aboutTelegramChat,
          subtitle: l10n.aboutTelegramChatSubtitle,
          keywords: const ['community', 'support chat'],
        ),
      ];

  final List<SettingsSearchEntry> extensions;
  final List<SettingsSearchEntry> appearance;
  final List<SettingsSearchEntry> library;
  final List<SettingsSearchEntry> playback;
  final List<SettingsSearchEntry> metadata;
  final List<SettingsSearchEntry> lyrics;
  final List<SettingsSearchEntry> download;
  final List<SettingsSearchEntry> files;
  final List<SettingsSearchEntry> app;
  final List<SettingsSearchEntry> cache;
  final List<SettingsSearchEntry> backup;
  final List<SettingsSearchEntry> logs;
  final List<SettingsSearchEntry> about;
}
