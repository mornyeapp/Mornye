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
  pauseOnMute: json['pauseOnMute'] as bool? ?? true,
  playOnHeadphonesConnected:
      json['playOnHeadphonesConnected'] as bool? ?? false,
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
  discordRichPresenceEnabled:
      json['discordRichPresenceEnabled'] as bool? ?? false,
  usbBitPerfect: json['usbBitPerfect'] as bool? ?? false,
  usbDirect: json['usbDirect'] as bool? ?? false,
  usbDsdOverPcm: json['usbDsdOverPcm'] as bool? ?? false,
  usbAllowFixedVolume: json['usbAllowFixedVolume'] as bool? ?? false,
  dapExclusive: json['dapExclusive'] as bool? ?? false,
  exclusiveOutput: json['exclusiveOutput'] as bool? ?? false,
  exclusiveOutputDevice: json['exclusiveOutputDevice'] as String? ?? '',
  autoplay: json['autoplay'] as bool? ?? false,
  autoplayPersonalization: json['autoplayPersonalization'] as bool? ?? true,
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
  landscapeLyricsArtwork: json['landscapeLyricsArtwork'] as bool? ?? false,
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
  defaultLibraryView: json['defaultLibraryView'] as String? ?? 'last',
  libraryQualityLabelMode:
      json['libraryQualityLabelMode'] as String? ??
      AppSettings.libraryQualityLabelBitDepthOnly,
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
  separateSingles: json['separateSingles'] as bool? ?? false,
  singleFilenameFormat:
      json['singleFilenameFormat'] as String? ?? '{title} - {artist}',
  albumFolderStructure:
      json['albumFolderStructure'] as String? ?? 'artist_album',
  showExtensionStore: json['showExtensionStore'] as bool? ?? true,
  heroAnimationsEnabled: json['heroAnimationsEnabled'] as bool? ?? true,
  forceBackdropBlur: json['forceBackdropBlur'] as bool? ?? false,
  extensionVerificationBrowserMode:
      json['extensionVerificationBrowserMode'] as String? ?? 'in_app_first',
  locale: json['locale'] as String? ?? 'system',
  lyricsMode: json['lyricsMode'] as String? ?? 'embed',
  keepScreenOnLyrics: json['keepScreenOnLyrics'] as bool? ?? true,
  motionArtworkEnabled: json['motionArtworkEnabled'] as bool? ?? true,
  listeningStatisticsEnabled:
      json['listeningStatisticsEnabled'] as bool? ?? true,
  autoConvertDownloads: json['autoConvertDownloads'] as bool? ?? false,
  redownloadFakeHiRes: json['redownloadFakeHiRes'] as bool? ?? false,
  autoConvertFormat: json['autoConvertFormat'] as String? ?? 'mp3',
  autoConvertBitrate: json['autoConvertBitrate'] as String? ?? '320k',
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
  hasCompletedTutorial: json['hasCompletedTutorial'] as bool? ?? false,
  lyricsProviders:
      (json['lyricsProviders'] as List<dynamic>?)
          ?.map((e) => e as String)
          .toList() ??
      const ['apple_music', 'lrcred', 'mornye_lyrics', 'lyricsplus', 'lrclib'],
  lyricsIncludeTranslationNetease:
      json['lyricsIncludeTranslationNetease'] as bool? ?? false,
  lyricsIncludeRomanizationNetease:
      json['lyricsIncludeRomanizationNetease'] as bool? ?? false,
  lyricsMultiPersonWordByWord:
      json['lyricsMultiPersonWordByWord'] as bool? ?? true,
  lyricsAppleElrcWordSync: json['lyricsAppleElrcWordSync'] as bool? ?? true,
  musixmatchLanguage: json['musixmatchLanguage'] as String? ?? '',
  lastSeenVersion: json['lastSeenVersion'] as String? ?? '',
  deduplicateDownloads: json['deduplicateDownloads'] as bool? ?? true,
  allowQualityVariants: json['allowQualityVariants'] as bool? ?? false,
  saveDownloadHistory: json['saveDownloadHistory'] as bool? ?? true,
  playerMode: json['playerMode'] as String? ?? 'internal',
  playerShowPronunciation: json['playerShowPronunciation'] as bool? ?? true,
  playerShowTranslation: json['playerShowTranslation'] as bool? ?? true,
  playerShowVolume: json['playerShowVolume'] as bool? ?? true,
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
  'pauseOnMute': instance.pauseOnMute,
  'playOnHeadphonesConnected': instance.playOnHeadphonesConnected,
  'autoMix': instance.autoMix,
  'autoMixDuration': instance.autoMixDuration,
  'autoMixEffect': _$AutoMixEffectEnumMap[instance.autoMixEffect]!,
  'autoMixSpeed': instance.autoMixSpeed,
  'autoMixPitch': instance.autoMixPitch,
  'autoMixEcho': instance.autoMixEcho,
  'autoMixLowPass': instance.autoMixLowPass,
  'discordRichPresenceEnabled': instance.discordRichPresenceEnabled,
  'usbBitPerfect': instance.usbBitPerfect,
  'usbDirect': instance.usbDirect,
  'usbDsdOverPcm': instance.usbDsdOverPcm,
  'usbAllowFixedVolume': instance.usbAllowFixedVolume,
  'dapExclusive': instance.dapExclusive,
  'exclusiveOutput': instance.exclusiveOutput,
  'exclusiveOutputDevice': instance.exclusiveOutputDevice,
  'autoplay': instance.autoplay,
  'autoplayPersonalization': instance.autoplayPersonalization,
  'songAnalysis': instance.songAnalysis,
  'songAnalysisOnlyWhileCharging': instance.songAnalysisOnlyWhileCharging,
  'musicHaptics': instance.musicHaptics,
  'musicHapticsSensitivity': instance.musicHapticsSensitivity,
  'musicHapticsStrength': instance.musicHapticsStrength,
  'playerCoverStyle': instance.playerCoverStyle,
  'landscapeLyricsArtwork': instance.landscapeLyricsArtwork,
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
  'defaultLibraryView': instance.defaultLibraryView,
  'libraryQualityLabelMode': instance.libraryQualityLabelMode,
  'askQualityBeforeDownload': instance.askQualityBeforeDownload,
  'enableLogging': instance.enableLogging,
  'useExtensionProviders': instance.useExtensionProviders,
  'downloadFallbackExtensionIds': instance.downloadFallbackExtensionIds,
  'searchProvider': instance.searchProvider,
  'defaultSearchTab': instance.defaultSearchTab,
  'searchViewMode': instance.searchViewMode,
  'homeFeedProvider': instance.homeFeedProvider,
  'separateSingles': instance.separateSingles,
  'singleFilenameFormat': instance.singleFilenameFormat,
  'albumFolderStructure': instance.albumFolderStructure,
  'showExtensionStore': instance.showExtensionStore,
  'heroAnimationsEnabled': instance.heroAnimationsEnabled,
  'forceBackdropBlur': instance.forceBackdropBlur,
  'extensionVerificationBrowserMode': instance.extensionVerificationBrowserMode,
  'locale': instance.locale,
  'lyricsMode': instance.lyricsMode,
  'keepScreenOnLyrics': instance.keepScreenOnLyrics,
  'motionArtworkEnabled': instance.motionArtworkEnabled,
  'listeningStatisticsEnabled': instance.listeningStatisticsEnabled,
  'autoConvertDownloads': instance.autoConvertDownloads,
  'redownloadFakeHiRes': instance.redownloadFakeHiRes,
  'autoConvertFormat': instance.autoConvertFormat,
  'autoConvertBitrate': instance.autoConvertBitrate,
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
  'hasCompletedTutorial': instance.hasCompletedTutorial,
  'lyricsProviders': instance.lyricsProviders,
  'lyricsIncludeTranslationNetease': instance.lyricsIncludeTranslationNetease,
  'lyricsIncludeRomanizationNetease': instance.lyricsIncludeRomanizationNetease,
  'lyricsMultiPersonWordByWord': instance.lyricsMultiPersonWordByWord,
  'lyricsAppleElrcWordSync': instance.lyricsAppleElrcWordSync,
  'musixmatchLanguage': instance.musixmatchLanguage,
  'lastSeenVersion': instance.lastSeenVersion,
  'deduplicateDownloads': instance.deduplicateDownloads,
  'allowQualityVariants': instance.allowQualityVariants,
  'saveDownloadHistory': instance.saveDownloadHistory,
  'playerMode': instance.playerMode,
  'playerShowPronunciation': instance.playerShowPronunciation,
  'playerShowTranslation': instance.playerShowTranslation,
  'playerShowVolume': instance.playerShowVolume,
};

const _$AutoMixEffectEnumMap = {
  AutoMixEffect.auto: 'auto',
  AutoMixEffect.crossfade: 'crossfade',
  AutoMixEffect.muffled: 'muffled',
  AutoMixEffect.echo: 'echo',
  AutoMixEffect.pitch: 'pitch',
  AutoMixEffect.custom: 'custom',
};
