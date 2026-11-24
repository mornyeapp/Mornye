// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'settings.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

AppSettings _$AppSettingsFromJson(Map<String, dynamic> json) => AppSettings(
  defaultService: json['defaultService'] as String? ?? '',
  audioQuality: json['audioQuality'] as String? ?? 'LOSSLESS',
  filenameFormat: json['filenameFormat'] as String? ?? '{title} - {artist}',
  downloadDirectory: json['downloadDirectory'] as String? ?? '',
  networkDownloadFolder: json['networkDownloadFolder'] as String? ?? '',
  networkDownloadLabel: json['networkDownloadLabel'] as String? ?? '',
  downloadDirectoryBookmark: json['downloadDirectoryBookmark'] as String? ?? '',
  storageMode: json['storageMode'] as String? ?? 'app',
  downloadTreeUri: json['downloadTreeUri'] as String? ?? '',
  autoFallback: json['autoFallback'] as bool? ?? true,
  embedMetadata: json['embedMetadata'] as bool? ?? true,
  embeddedCoverMaxDimension:
      (json['embeddedCoverMaxDimension'] as num?)?.toInt() ?? 0,
  artistTagMode: json['artistTagMode'] as String? ?? artistTagModeJoined,
  metadataSeparators: json['metadataSeparators'] == null
      ? const MetadataSeparators()
      : MetadataSeparators.fromJson(
          json['metadataSeparators'] as Map<String, dynamic>,
        ),
  embedLyrics: json['embedLyrics'] as bool? ?? true,
  embedReplayGain: json['embedReplayGain'] as bool? ?? false,
  playbackNormalization: json['playbackNormalization'] as bool? ?? false,
  playbackNormalizationPreamp: json['playbackNormalizationPreamp'] == null
      ? 0
      : playbackNormalizationPreampFromJson(
          json['playbackNormalizationPreamp'],
        ),
  playbackNormalizationMode: json['playbackNormalizationMode'] == null
      ? 'track'
      : playbackNormalizationModeFromJson(json['playbackNormalizationMode']),
  playbackNormalizationBoost:
      json['playbackNormalizationBoost'] as bool? ?? false,
  confirmLoudVolume: json['confirmLoudVolume'] as bool? ?? true,
  loudVolumeLevel: json['loudVolumeLevel'] == null
      ? 80
      : loudVolumeLevelFromJson(json['loudVolumeLevel']),
  pauseOnMute: json['pauseOnMute'] as bool? ?? true,
  headphoneResume: readHeadphoneResume(json, 'headphoneResume') == null
      ? 'off'
      : headphoneResumeFromJson(readHeadphoneResume(json, 'headphoneResume')),
  gaplessPlayback: json['gaplessPlayback'] as bool? ?? true,
  autoMix: json['autoMix'] as bool? ?? false,
  autoMixDuration: json['autoMixDuration'] == null
      ? 0
      : autoMixDurationFromJson(json['autoMixDuration']),
  autoMixEffect:
      $enumDecodeNullable(
        _$AutoMixEffectEnumMap,
        json['autoMixEffect'],
        unknownValue: AutoMixEffect.auto,
      ) ??
      AutoMixEffect.auto,
  autoMixSpeed: json['autoMixSpeed'] == null
      ? 1
      : autoMixSpeedFromJson(json['autoMixSpeed']),
  autoMixPitch: json['autoMixPitch'] == null
      ? 0
      : autoMixPitchFromJson(json['autoMixPitch']),
  autoMixEcho: json['autoMixEcho'] as bool? ?? false,
  autoMixLowPass: json['autoMixLowPass'] as bool? ?? false,
  autoMixMatching:
      $enumDecodeNullable(
        _$AutoMixMatchingEnumMap,
        json['autoMixMatching'],
        unknownValue: AutoMixMatching.standard,
      ) ??
      AutoMixMatching.standard,
  playbackSpeed: json['playbackSpeed'] == null
      ? 1
      : playbackSpeedFromJson(json['playbackSpeed']),
  playbackKeepPitch: json['playbackKeepPitch'] as bool? ?? true,
  playbackPitch: json['playbackPitch'] == null
      ? 0
      : playbackPitchFromJson(json['playbackPitch']),
  discordRichPresenceEnabled:
      json['discordRichPresenceEnabled'] as bool? ?? false,
  usbBitPerfect: json['usbBitPerfect'] as bool? ?? false,
  usbDirect: json['usbDirect'] as bool? ?? false,
  usbDsdOverPcm: json['usbDsdOverPcm'] as bool? ?? false,
  usbAllowFixedVolume: json['usbAllowFixedVolume'] as bool? ?? false,
  usbMaxSampleRate: (json['usbMaxSampleRate'] as num?)?.toInt() ?? 0,
  usbDitherHighPass: json['usbDitherHighPass'] as bool? ?? false,
  dapExclusive: json['dapExclusive'] as bool? ?? false,
  media3Engine: json['media3Engine'] as bool? ?? false,
  skipSilence: json['skipSilence'] as bool? ?? false,
  spatialAudio: json['spatialAudio'] as bool? ?? true,
  queueNoDuplicates: json['queueNoDuplicates'] as bool? ?? false,
  queueLocked: json['queueLocked'] as bool? ?? false,
  exclusiveOutput: json['exclusiveOutput'] as bool? ?? false,
  exclusiveOutputDevice: json['exclusiveOutputDevice'] as String? ?? '',
  autoplay: json['autoplay'] as bool? ?? false,
  autoplayPersonalization: json['autoplayPersonalization'] as bool? ?? true,
  autoplayRandomness: json['autoplayRandomness'] == null
      ? 0
      : autoplayRandomnessFromJson(json['autoplayRandomness']),
  songAnalysis: json['songAnalysis'] as bool? ?? false,
  songAnalysisOnlyWhileCharging:
      json['songAnalysisOnlyWhileCharging'] as bool? ?? true,
  musicHaptics: json['musicHaptics'] as bool? ?? false,
  musicHapticsSensitivity: json['musicHapticsSensitivity'] == null
      ? 0.5
      : musicHapticsLevelFromJson(json['musicHapticsSensitivity']),
  musicHapticsStrength: json['musicHapticsStrength'] == null
      ? 0.5
      : musicHapticsLevelFromJson(json['musicHapticsStrength']),
  playerCoverStyle: json['playerCoverStyle'] == null
      ? ''
      : playerCoverStyleFromJson(json['playerCoverStyle']),
  playerCoverFade: json['playerCoverFade'] == null
      ? 'medium'
      : playerCoverFadeFromJson(json['playerCoverFade']),
  playerCoverWhole: json['playerCoverWhole'] as bool? ?? false,
  landscapeLyricsArtwork: json['landscapeLyricsArtwork'] as bool? ?? false,
  autoHideLyricsControls: json['autoHideLyricsControls'] as bool? ?? true,
  autoHideLyricsControlsWithAccessibility:
      json['autoHideLyricsControlsWithAccessibility'] as bool? ?? false,
  compactPlayer: json['compactPlayer'] as bool? ?? false,
  isFirstLaunch: json['isFirstLaunch'] as bool? ?? true,
  checkForUpdates: json['checkForUpdates'] as bool? ?? true,
  updateChannel: json['updateChannel'] as String? ?? 'stable',
  hasSearchedBefore: json['hasSearchedBefore'] as bool? ?? false,
  folderOrganization: json['folderOrganization'] as String? ?? 'none',
  folderPathTemplate:
      json['folderPathTemplate'] as String? ?? '{artist}/{album}',
  createPlaylistFolder: json['createPlaylistFolder'] as bool? ?? false,
  useAlbumArtistForFolders: json['useAlbumArtistForFolders'] as bool? ?? true,
  usePrimaryArtistOnly: json['usePrimaryArtistOnly'] as bool? ?? false,
  filterContributingArtistsInAlbumArtist:
      json['filterContributingArtistsInAlbumArtist'] as bool? ?? false,
  historyViewMode: json['historyViewMode'] as String? ?? 'grid',
  historyFilterMode: json['historyFilterMode'] as String? ?? 'all',
  historySortMode: json['historySortMode'] == null
      ? 'latest'
      : librarySortModeFromJson(json['historySortMode']),
  libraryAlbumSortMode: json['libraryAlbumSortMode'] == null
      ? 'a-z'
      : libraryAlbumSortModeFromJson(json['libraryAlbumSortMode']),
  libraryArtistShowsSongs: json['libraryArtistShowsSongs'] as bool? ?? false,
  defaultLibraryView: json['defaultLibraryView'] as String? ?? 'last',
  libraryQualityLabelMode:
      json['libraryQualityLabelMode'] as String? ??
      AppSettings.libraryQualityLabelBitDepthOnly,
  swipeToQueue: json['swipeToQueue'] as bool? ?? true,
  librarySongTap:
      json['librarySongTap'] as String? ?? AppSettings.librarySongTapDetails,
  askQualityBeforeDownload: json['askQualityBeforeDownload'] as bool? ?? true,
  enableLogging: json['enableLogging'] as bool? ?? false,
  useExtensionProviders: json['useExtensionProviders'] as bool? ?? true,
  downloadFallbackExtensionIds:
      (json['downloadFallbackExtensionIds'] as List<dynamic>?)
          ?.map((e) => e as String)
          .toList(),
  searchProvider: json['searchProvider'] as String?,
  defaultSearchTab: json['defaultSearchTab'] as String? ?? 'all',
  searchViewMode: json['searchViewMode'] as String? ?? 'list',
  homeFeedProvider: json['homeFeedProvider'] as String?,
  homeShortcuts:
      (json['homeShortcuts'] as List<dynamic>?)
          ?.map((e) => e as String)
          .toList() ??
      const ['shuffle', 'equalizer', 'listeningStats', 'networkStorage'],
  homeContinueListening: json['homeContinueListening'] as bool? ?? true,
  homeRecommendations: json['homeRecommendations'] as bool? ?? true,
  homeLayout: json['homeLayout'] == null
      ? const HomeLayout()
      : homeLayoutFromJson(json['homeLayout']),
  separateSingles: json['separateSingles'] as bool? ?? false,
  singleFilenameFormat:
      json['singleFilenameFormat'] as String? ?? '{title} - {artist}',
  albumFolderStructure:
      json['albumFolderStructure'] as String? ?? 'artist_album',
  showExtensionStore: json['showExtensionStore'] as bool? ?? true,
  autoUpdateExtensions: json['autoUpdateExtensions'] as bool? ?? true,
  heroAnimationsEnabled: json['heroAnimationsEnabled'] as bool? ?? true,
  forceBackdropBlur: json['forceBackdropBlur'] as bool? ?? false,
  interfaceScale: json['interfaceScale'] == null
      ? 1
      : interfaceScaleFromJson(json['interfaceScale']),
  animationSpeed: json['animationSpeed'] == null
      ? 1
      : animationSpeedFromJson(json['animationSpeed']),
  extensionVerificationBrowserMode:
      json['extensionVerificationBrowserMode'] as String? ?? 'in_app_first',
  locale: json['locale'] as String? ?? 'system',
  lyricsMode: json['lyricsMode'] as String? ?? 'embed',
  keepScreenOnLyrics: json['keepScreenOnLyrics'] as bool? ?? true,
  lockScreenLyrics: json['lockScreenLyrics'] as bool? ?? false,
  lockScreenLyricsKeepTitle:
      json['lockScreenLyricsKeepTitle'] as bool? ?? false,
  motionArtworkEnabled: json['motionArtworkEnabled'] as bool? ?? true,
  saveMotionArtworkFile: json['saveMotionArtworkFile'] as bool? ?? false,
  saveFolderCover: json['saveFolderCover'] as bool? ?? false,
  folderCoverMaxDimension:
      (json['folderCoverMaxDimension'] as num?)?.toInt() ?? 0,
  removeEmptyFolders: json['removeEmptyFolders'] as bool? ?? true,
  listeningStatisticsEnabled:
      json['listeningStatisticsEnabled'] as bool? ?? true,
  autoConvertDownloads: json['autoConvertDownloads'] as bool? ?? false,
  redownloadFakeHiRes: json['redownloadFakeHiRes'] as bool? ?? false,
  autoConvertFormat: json['autoConvertFormat'] as String? ?? 'mp3',
  autoConvertBitrate: json['autoConvertBitrate'] as String? ?? '320k',
  autoConvertMaxBitDepth:
      (json['autoConvertMaxBitDepth'] as num?)?.toInt() ?? 16,
  autoConvertMaxSampleRate:
      (json['autoConvertMaxSampleRate'] as num?)?.toInt() ?? 48000,
  autoConvertSmartDither: json['autoConvertSmartDither'] as bool? ?? true,
  autoConvertSmartDitherHighPass:
      json['autoConvertSmartDitherHighPass'] as bool? ?? false,
  useAllFilesAccess: json['useAllFilesAccess'] as bool? ?? false,
  autoExportFailedDownloads:
      json['autoExportFailedDownloads'] as bool? ?? false,
  downloadNetworkMode: json['downloadNetworkMode'] as String? ?? 'any',
  networkCompatibilityMode: json['networkCompatibilityMode'] as bool? ?? false,
  allowLocalNetwork: json['allowLocalNetwork'] as bool? ?? false,
  songLinkRegion: json['songLinkRegion'] as String? ?? 'US',
  nativeDownloadWorkerEnabled:
      json['nativeDownloadWorkerEnabled'] as bool? ?? false,
  concurrentDownloads: (json['concurrentDownloads'] as num?)?.toInt() ?? 1,
  localLibraryEnabled: json['localLibraryEnabled'] as bool? ?? false,
  localLibraryPath: json['localLibraryPath'] as String? ?? '',
  localLibraryBookmark: json['localLibraryBookmark'] as String? ?? '',
  localLibraryShowDuplicates:
      json['localLibraryShowDuplicates'] as bool? ?? true,
  localLibraryAutoScan: json['localLibraryAutoScan'] as String? ?? 'off',
  linkHideDisconnectedSongs: json['linkHideDisconnectedSongs'] as bool? ?? true,
  hasCompletedTutorial: json['hasCompletedTutorial'] as bool? ?? false,
  lyricsProviders:
      (json['lyricsProviders'] as List<dynamic>?)
          ?.map((e) => e as String)
          .toList() ??
      const ['apple_music', 'lrcred', 'mornye_lyrics', 'lyricsplus', 'lrclib'],
  lyricsPreferBestTiming: json['lyricsPreferBestTiming'] as bool? ?? true,
  lyricsIncludeTranslationNetease:
      json['lyricsIncludeTranslationNetease'] as bool? ?? false,
  lyricsIncludeRomanizationNetease:
      json['lyricsIncludeRomanizationNetease'] as bool? ?? false,
  lyricsMultiPersonWordByWord:
      json['lyricsMultiPersonWordByWord'] as bool? ?? true,
  lyricsAppleElrcWordSync: json['lyricsAppleElrcWordSync'] as bool? ?? true,
  musixmatchLanguage: json['musixmatchLanguage'] as String? ?? '',
  lyricsAiProvider: json['lyricsAiProvider'] as String? ?? 'openai',
  lyricsAiBaseUrl: json['lyricsAiBaseUrl'] as String? ?? '',
  lyricsAiModel: json['lyricsAiModel'] as String? ?? '',
  lyricsTranslationLanguage: json['lyricsTranslationLanguage'] as String? ?? '',
  lyricsTranslationSecondLanguage:
      json['lyricsTranslationSecondLanguage'] as String? ?? '',
  lyricsAiInstruction: json['lyricsAiInstruction'] as String? ?? '',
  lyricsAutoTranslate: json['lyricsAutoTranslate'] as bool? ?? false,
  lyricsAiRomanize: json['lyricsAiRomanize'] as bool? ?? true,
  lyricsRomanize: readLyricsRomanize(json, 'lyricsRomanize') as bool? ?? true,
  lyricsRomanizedMainLine: json['lyricsRomanizedMainLine'] as bool? ?? false,
  lyricsAiWordSync: json['lyricsAiWordSync'] as bool? ?? false,
  lyricsTranslationSaveTo: json['lyricsTranslationSaveTo'] == null
      ? lyricsTranslationSaveToSongFile
      : lyricsTranslationSaveToFromJson(json['lyricsTranslationSaveTo']),
  lyricsTranslationAutoSave:
      json['lyricsTranslationAutoSave'] as bool? ?? false,
  lyricsTranslateDownloads: json['lyricsTranslateDownloads'] as bool? ?? false,
  lastSeenVersion: json['lastSeenVersion'] as String? ?? '',
  deduplicateDownloads: json['deduplicateDownloads'] as bool? ?? true,
  allowQualityVariants: json['allowQualityVariants'] as bool? ?? false,
  saveDownloadHistory: json['saveDownloadHistory'] as bool? ?? true,
  playerMode: json['playerMode'] as String? ?? 'internal',
  playerShowPronunciation: json['playerShowPronunciation'] as bool? ?? true,
  playerShowTranslation: json['playerShowTranslation'] as bool? ?? true,
  playerShowVolume: json['playerShowVolume'] as bool? ?? true,
  playerShowLyricSnippet: json['playerShowLyricSnippet'] as bool? ?? false,
  playerLyricSnippetTranslation:
      json['playerLyricSnippetTranslation'] as bool? ?? false,
);

Map<String, dynamic> _$AppSettingsToJson(
  AppSettings instance,
) => <String, dynamic>{
  'defaultService': instance.defaultService,
  'audioQuality': instance.audioQuality,
  'filenameFormat': instance.filenameFormat,
  'downloadDirectory': instance.downloadDirectory,
  'networkDownloadFolder': instance.networkDownloadFolder,
  'networkDownloadLabel': instance.networkDownloadLabel,
  'downloadDirectoryBookmark': instance.downloadDirectoryBookmark,
  'storageMode': instance.storageMode,
  'downloadTreeUri': instance.downloadTreeUri,
  'autoFallback': instance.autoFallback,
  'embedMetadata': instance.embedMetadata,
  'embeddedCoverMaxDimension': instance.embeddedCoverMaxDimension,
  'artistTagMode': instance.artistTagMode,
  'metadataSeparators': instance.metadataSeparators.toJson(),
  'embedLyrics': instance.embedLyrics,
  'embedReplayGain': instance.embedReplayGain,
  'playbackNormalization': instance.playbackNormalization,
  'playbackNormalizationPreamp': instance.playbackNormalizationPreamp,
  'playbackNormalizationMode': instance.playbackNormalizationMode,
  'playbackNormalizationBoost': instance.playbackNormalizationBoost,
  'confirmLoudVolume': instance.confirmLoudVolume,
  'loudVolumeLevel': instance.loudVolumeLevel,
  'pauseOnMute': instance.pauseOnMute,
  'headphoneResume': instance.headphoneResume,
  'gaplessPlayback': instance.gaplessPlayback,
  'autoMix': instance.autoMix,
  'autoMixDuration': instance.autoMixDuration,
  'autoMixEffect': _$AutoMixEffectEnumMap[instance.autoMixEffect]!,
  'autoMixSpeed': instance.autoMixSpeed,
  'autoMixPitch': instance.autoMixPitch,
  'autoMixEcho': instance.autoMixEcho,
  'autoMixLowPass': instance.autoMixLowPass,
  'autoMixMatching': _$AutoMixMatchingEnumMap[instance.autoMixMatching]!,
  'playbackSpeed': instance.playbackSpeed,
  'playbackKeepPitch': instance.playbackKeepPitch,
  'playbackPitch': instance.playbackPitch,
  'discordRichPresenceEnabled': instance.discordRichPresenceEnabled,
  'usbBitPerfect': instance.usbBitPerfect,
  'usbDirect': instance.usbDirect,
  'usbDsdOverPcm': instance.usbDsdOverPcm,
  'usbAllowFixedVolume': instance.usbAllowFixedVolume,
  'usbMaxSampleRate': instance.usbMaxSampleRate,
  'usbDitherHighPass': instance.usbDitherHighPass,
  'dapExclusive': instance.dapExclusive,
  'media3Engine': instance.media3Engine,
  'skipSilence': instance.skipSilence,
  'spatialAudio': instance.spatialAudio,
  'queueNoDuplicates': instance.queueNoDuplicates,
  'queueLocked': instance.queueLocked,
  'exclusiveOutput': instance.exclusiveOutput,
  'exclusiveOutputDevice': instance.exclusiveOutputDevice,
  'autoplay': instance.autoplay,
  'autoplayPersonalization': instance.autoplayPersonalization,
  'autoplayRandomness': instance.autoplayRandomness,
  'songAnalysis': instance.songAnalysis,
  'songAnalysisOnlyWhileCharging': instance.songAnalysisOnlyWhileCharging,
  'musicHaptics': instance.musicHaptics,
  'musicHapticsSensitivity': instance.musicHapticsSensitivity,
  'musicHapticsStrength': instance.musicHapticsStrength,
  'playerCoverStyle': instance.playerCoverStyle,
  'playerCoverFade': instance.playerCoverFade,
  'playerCoverWhole': instance.playerCoverWhole,
  'landscapeLyricsArtwork': instance.landscapeLyricsArtwork,
  'autoHideLyricsControls': instance.autoHideLyricsControls,
  'autoHideLyricsControlsWithAccessibility':
      instance.autoHideLyricsControlsWithAccessibility,
  'compactPlayer': instance.compactPlayer,
  'isFirstLaunch': instance.isFirstLaunch,
  'checkForUpdates': instance.checkForUpdates,
  'updateChannel': instance.updateChannel,
  'hasSearchedBefore': instance.hasSearchedBefore,
  'folderOrganization': instance.folderOrganization,
  'folderPathTemplate': instance.folderPathTemplate,
  'createPlaylistFolder': instance.createPlaylistFolder,
  'useAlbumArtistForFolders': instance.useAlbumArtistForFolders,
  'usePrimaryArtistOnly': instance.usePrimaryArtistOnly,
  'filterContributingArtistsInAlbumArtist':
      instance.filterContributingArtistsInAlbumArtist,
  'historyViewMode': instance.historyViewMode,
  'historyFilterMode': instance.historyFilterMode,
  'historySortMode': instance.historySortMode,
  'libraryAlbumSortMode': instance.libraryAlbumSortMode,
  'libraryArtistShowsSongs': instance.libraryArtistShowsSongs,
  'defaultLibraryView': instance.defaultLibraryView,
  'libraryQualityLabelMode': instance.libraryQualityLabelMode,
  'swipeToQueue': instance.swipeToQueue,
  'librarySongTap': instance.librarySongTap,
  'askQualityBeforeDownload': instance.askQualityBeforeDownload,
  'enableLogging': instance.enableLogging,
  'useExtensionProviders': instance.useExtensionProviders,
  'downloadFallbackExtensionIds': instance.downloadFallbackExtensionIds,
  'searchProvider': instance.searchProvider,
  'defaultSearchTab': instance.defaultSearchTab,
  'searchViewMode': instance.searchViewMode,
  'homeFeedProvider': instance.homeFeedProvider,
  'homeShortcuts': instance.homeShortcuts,
  'homeContinueListening': instance.homeContinueListening,
  'homeRecommendations': instance.homeRecommendations,
  'homeLayout': instance.homeLayout.toJson(),
  'separateSingles': instance.separateSingles,
  'singleFilenameFormat': instance.singleFilenameFormat,
  'albumFolderStructure': instance.albumFolderStructure,
  'showExtensionStore': instance.showExtensionStore,
  'autoUpdateExtensions': instance.autoUpdateExtensions,
  'heroAnimationsEnabled': instance.heroAnimationsEnabled,
  'forceBackdropBlur': instance.forceBackdropBlur,
  'interfaceScale': instance.interfaceScale,
  'animationSpeed': instance.animationSpeed,
  'extensionVerificationBrowserMode': instance.extensionVerificationBrowserMode,
  'locale': instance.locale,
  'lyricsMode': instance.lyricsMode,
  'keepScreenOnLyrics': instance.keepScreenOnLyrics,
  'lockScreenLyrics': instance.lockScreenLyrics,
  'lockScreenLyricsKeepTitle': instance.lockScreenLyricsKeepTitle,
  'motionArtworkEnabled': instance.motionArtworkEnabled,
  'saveMotionArtworkFile': instance.saveMotionArtworkFile,
  'saveFolderCover': instance.saveFolderCover,
  'folderCoverMaxDimension': instance.folderCoverMaxDimension,
  'removeEmptyFolders': instance.removeEmptyFolders,
  'listeningStatisticsEnabled': instance.listeningStatisticsEnabled,
  'autoConvertDownloads': instance.autoConvertDownloads,
  'redownloadFakeHiRes': instance.redownloadFakeHiRes,
  'autoConvertFormat': instance.autoConvertFormat,
  'autoConvertBitrate': instance.autoConvertBitrate,
  'autoConvertMaxBitDepth': instance.autoConvertMaxBitDepth,
  'autoConvertMaxSampleRate': instance.autoConvertMaxSampleRate,
  'autoConvertSmartDither': instance.autoConvertSmartDither,
  'autoConvertSmartDitherHighPass': instance.autoConvertSmartDitherHighPass,
  'useAllFilesAccess': instance.useAllFilesAccess,
  'autoExportFailedDownloads': instance.autoExportFailedDownloads,
  'downloadNetworkMode': instance.downloadNetworkMode,
  'networkCompatibilityMode': instance.networkCompatibilityMode,
  'allowLocalNetwork': instance.allowLocalNetwork,
  'songLinkRegion': instance.songLinkRegion,
  'nativeDownloadWorkerEnabled': instance.nativeDownloadWorkerEnabled,
  'concurrentDownloads': instance.concurrentDownloads,
  'localLibraryEnabled': instance.localLibraryEnabled,
  'localLibraryPath': instance.localLibraryPath,
  'localLibraryBookmark': instance.localLibraryBookmark,
  'localLibraryShowDuplicates': instance.localLibraryShowDuplicates,
  'localLibraryAutoScan': instance.localLibraryAutoScan,
  'linkHideDisconnectedSongs': instance.linkHideDisconnectedSongs,
  'hasCompletedTutorial': instance.hasCompletedTutorial,
  'lyricsProviders': instance.lyricsProviders,
  'lyricsPreferBestTiming': instance.lyricsPreferBestTiming,
  'lyricsIncludeTranslationNetease': instance.lyricsIncludeTranslationNetease,
  'lyricsIncludeRomanizationNetease': instance.lyricsIncludeRomanizationNetease,
  'lyricsMultiPersonWordByWord': instance.lyricsMultiPersonWordByWord,
  'lyricsAppleElrcWordSync': instance.lyricsAppleElrcWordSync,
  'musixmatchLanguage': instance.musixmatchLanguage,
  'lyricsAiProvider': instance.lyricsAiProvider,
  'lyricsAiBaseUrl': instance.lyricsAiBaseUrl,
  'lyricsAiModel': instance.lyricsAiModel,
  'lyricsTranslationLanguage': instance.lyricsTranslationLanguage,
  'lyricsTranslationSecondLanguage': instance.lyricsTranslationSecondLanguage,
  'lyricsAiInstruction': instance.lyricsAiInstruction,
  'lyricsAutoTranslate': instance.lyricsAutoTranslate,
  'lyricsAiRomanize': instance.lyricsAiRomanize,
  'lyricsRomanize': instance.lyricsRomanize,
  'lyricsRomanizedMainLine': instance.lyricsRomanizedMainLine,
  'lyricsAiWordSync': instance.lyricsAiWordSync,
  'lyricsTranslationSaveTo': instance.lyricsTranslationSaveTo,
  'lyricsTranslationAutoSave': instance.lyricsTranslationAutoSave,
  'lyricsTranslateDownloads': instance.lyricsTranslateDownloads,
  'lastSeenVersion': instance.lastSeenVersion,
  'deduplicateDownloads': instance.deduplicateDownloads,
  'allowQualityVariants': instance.allowQualityVariants,
  'saveDownloadHistory': instance.saveDownloadHistory,
  'playerMode': instance.playerMode,
  'playerShowPronunciation': instance.playerShowPronunciation,
  'playerShowTranslation': instance.playerShowTranslation,
  'playerShowVolume': instance.playerShowVolume,
  'playerShowLyricSnippet': instance.playerShowLyricSnippet,
  'playerLyricSnippetTranslation': instance.playerLyricSnippetTranslation,
};

const _$AutoMixEffectEnumMap = {
  AutoMixEffect.auto: 'auto',
  AutoMixEffect.crossfade: 'crossfade',
  AutoMixEffect.muffled: 'muffled',
  AutoMixEffect.echo: 'echo',
  AutoMixEffect.pitch: 'pitch',
  AutoMixEffect.custom: 'custom',
};

const _$AutoMixMatchingEnumMap = {
  AutoMixMatching.standard: 'standard',
  AutoMixMatching.more: 'more',
  AutoMixMatching.most: 'most',
};
