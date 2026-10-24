import 'package:json_annotation/json_annotation.dart';
import 'package:mornye/models/automix_options.dart';
import 'package:mornye/models/metadata_separators.dart';
import 'package:mornye/utils/artist_utils.dart';

part 'settings.g.dart';

String playerCoverStyleFromJson(Object? value) =>
    value == 'fullscreen' ? 'fullscreen' : 'default';

/// Pre-amp applied on top of ReplayGain during playback, in whole dB.
/// -7 dB targets -25 LUFS from the -18 LUFS tag reference.
double playbackNormalizationPreampFromJson(Object? value) =>
    value is num && value.isFinite
    ? value.toDouble().roundToDouble().clamp(-15, 6)
    : 0;

String playbackNormalizationModeFromJson(Object? value) =>
    value == 'album' ? 'album' : 'track';

double musicHapticsLevelFromJson(Object? value) =>
    value is num && value.isFinite ? value.toDouble().clamp(0, 1) : 0.5;

@JsonSerializable(explicitToJson: true)
class AppSettings {
  static const String homeFeedProviderOff = '__off__';
  static const String libraryQualityLabelBitrate = 'bitrate';
  static const String libraryQualityLabelFileFormat = 'file_format';
  static const String libraryQualityLabelBitDepthOnly = 'bit_depth_only';
  static const String libraryQualityLabelBitDepth = 'bit_depth';
  static const String libraryQualityLabelBitDepthBitrate = 'bit_depth_bitrate';

  final String defaultService;
  final String audioQuality;
  final String filenameFormat;
  final String downloadDirectory;
  final String networkDownloadFolder;
  final String networkDownloadLabel;
  final String downloadDirectoryBookmark;
  final String storageMode; // 'app' or 'saf'
  final String downloadTreeUri; // SAF persistable tree URI
  final bool autoFallback;
  final bool embedMetadata;

  /// Maximum width or height of remotely fetched artwork before embedding.
  /// Zero preserves the provider's original image.
  final int embeddedCoverMaxDimension;
  final String
  artistTagMode; // 'joined', 'split_vorbis' (Vorbis formats), or 'primary'
  final MetadataSeparators metadataSeparators;
  final bool embedLyrics;
  final bool embedReplayGain;
  // Apply ReplayGain/R128 tags as volume normalization in the built-in player.
  final bool playbackNormalization;
  @JsonKey(fromJson: playbackNormalizationPreampFromJson)
  final double playbackNormalizationPreamp;
  @JsonKey(fromJson: playbackNormalizationModeFromJson)
  final String playbackNormalizationMode; // 'track' or 'album'
  final bool pauseOnMute;
  final bool playOnHeadphonesConnected;
  final bool autoMix;
  @JsonKey(fromJson: autoMixDurationFromJson)
  final int autoMixDuration;
  @JsonKey(unknownEnumValue: AutoMixEffect.auto)
  final AutoMixEffect autoMixEffect;
  @JsonKey(fromJson: autoMixSpeedFromJson)
  final double autoMixSpeed;
  @JsonKey(fromJson: autoMixPitchFromJson)
  final double autoMixPitch;
  final bool autoMixEcho;
  final bool autoMixLowPass;
  AutoMixOptions get autoMixOptions => AutoMixOptions(
    durationSeconds: autoMixDuration,
    effect: autoMixEffect,
    speed: autoMixSpeed,
    pitchSemitones: autoMixPitch,
    echo: autoMixEcho,
    lowPass: autoMixLowPass,
  );
  final bool discordRichPresenceEnabled;
  final bool usbBitPerfect;
  final bool usbDirect;
  final bool usbDsdOverPcm;
  final bool usbAllowFixedVolume;
  final bool dapExclusive;
  final bool autoplay;
  final bool autoplayPersonalization;
  final bool musicHaptics;
  @JsonKey(fromJson: musicHapticsLevelFromJson)
  final double musicHapticsSensitivity;
  @JsonKey(fromJson: musicHapticsLevelFromJson)
  final double musicHapticsStrength;
  @JsonKey(fromJson: playerCoverStyleFromJson)
  final String playerCoverStyle; // 'default' or 'fullscreen'
  final bool isFirstLaunch;
  final bool checkForUpdates;
  final String updateChannel;
  final bool hasSearchedBefore;
  final String folderOrganization;
  final String folderPathTemplate;
  final bool createPlaylistFolder;
  final bool useAlbumArtistForFolders;
  final bool usePrimaryArtistOnly; // Strip featured artists from folder name
  final bool filterContributingArtistsInAlbumArtist;
  final String historyViewMode;
  final String historyFilterMode;

  /// Library view opened when switching to the Library tab:
  /// 'last' (keep last used), 'all', 'albums', 'singles', or 'playlists'.
  final String defaultLibraryView;

  /// Library badge text: measured bitrate, file format, bit depth,
  /// bit depth/sample rate, or the combined bit depth/bitrate label.
  final String libraryQualityLabelMode;
  final bool askQualityBeforeDownload;
  final bool enableLogging;
  final bool useExtensionProviders;
  final List<String>? downloadFallbackExtensionIds;
  final String? searchProvider;
  final String defaultSearchTab;

  /// Search results on wide screens: 'list' keeps the phone rows, 'grid'
  /// shows cover grids and shelves.
  final String searchViewMode;
  final String? homeFeedProvider;
  final bool separateSingles;
  final String singleFilenameFormat;
  final String albumFolderStructure;
  final bool showExtensionStore;

  /// Shared-element (Hero) flights, e.g. the mini player artwork expanding
  /// into the full player. Off skips the flights entirely.
  final bool heroAnimationsEnabled;

  /// Forces the shell's backdrop blur on even when the startup runtime
  /// profile disabled it for this device tier. Off means "follow the
  /// device default".
  final bool forceBackdropBlur;
  final String
  extensionVerificationBrowserMode; // 'external_first' or 'in_app_first'
  final String locale;
  final String lyricsMode;
  final bool keepScreenOnLyrics;
  final bool motionArtworkEnabled;
  final bool listeningStatisticsEnabled;
  final bool autoConvertDownloads;
  // Re-download a Hi-Res request at LOSSLESS when the file measures as fake.
  final bool redownloadFakeHiRes;
  final String autoConvertFormat; // 'mp3', 'aac' (M4A), or 'opus'
  final String autoConvertBitrate; // '128k', '192k', '256k', or '320k'
  final bool
  useAllFilesAccess; // Android 13+ only: enable MANAGE_EXTERNAL_STORAGE
  final bool autoExportFailedDownloads;
  final String
  downloadNetworkMode; // 'any' = WiFi + Mobile, 'wifi_only' = WiFi only
  final bool
  networkCompatibilityMode; // Try HTTP + allow invalid TLS cert for API requests
  final bool
  allowLocalNetwork; // Allow requests to private/local network targets (local proxy / custom DNS)
  final String
  songLinkRegion; // SongLink userCountry region code used for platform lookup
  final bool nativeDownloadWorkerEnabled; // Android service-owned worker
  final int
  concurrentDownloads; // Max simultaneous downloads in the Dart queue (1-3)

  final bool localLibraryEnabled;
  final String localLibraryPath;
  final String
  localLibraryBookmark; // Base64-encoded iOS security-scoped bookmark
  final bool localLibraryShowDuplicates;
  final String
  localLibraryAutoScan; // Auto-scan mode: 'off', 'on_open', 'daily', 'weekly'

  final bool hasCompletedTutorial;

  final List<String> lyricsProviders;
  final bool
  lyricsIncludeTranslationNetease; // Append translated lyrics (Netease)
  final bool
  lyricsIncludeRomanizationNetease; // Append romanized lyrics (Netease)
  final bool
  lyricsMultiPersonWordByWord; // Enable v1/v2 + [bg:] tags for Apple/QQ syllable lyrics
  final bool
  lyricsAppleElrcWordSync; // Preserve Apple Music inline word timestamps for eLRC-capable players
  final String
  musixmatchLanguage; // Optional ISO language code for Musixmatch localized lyrics

  final String
  lastSeenVersion; // Last app version the user has acknowledged (e.g. '3.7.0')

  final bool deduplicateDownloads;
  final bool allowQualityVariants;
  final bool saveDownloadHistory;

  final String playerMode;
  final bool playerShowPronunciation;
  final bool playerShowTranslation;

  const AppSettings({
    this.defaultService = '',
    this.audioQuality = 'LOSSLESS',
    this.filenameFormat = '{title} - {artist}',
    this.downloadDirectory = '',
    this.networkDownloadFolder = '',
    this.networkDownloadLabel = '',
    this.downloadDirectoryBookmark = '',
    this.storageMode = 'app',
    this.downloadTreeUri = '',
    this.autoFallback = true,
    this.embedMetadata = true,
    this.embeddedCoverMaxDimension = 0,
    this.artistTagMode = artistTagModeJoined,
    this.metadataSeparators = const MetadataSeparators(),
    this.embedLyrics = true,
    this.embedReplayGain = false,
    this.playbackNormalization = false,
    this.playbackNormalizationPreamp = 0,
    this.playbackNormalizationMode = 'track',
    this.pauseOnMute = true,
    this.playOnHeadphonesConnected = false,
    this.autoMix = false,
    this.autoMixDuration = 0,
    this.autoMixEffect = AutoMixEffect.auto,
    this.autoMixSpeed = 1,
    this.autoMixPitch = 0,
    this.autoMixEcho = false,
    this.autoMixLowPass = false,
    this.discordRichPresenceEnabled = false,
    this.usbBitPerfect = false,
    this.usbDirect = false,
    this.usbDsdOverPcm = false,
    this.usbAllowFixedVolume = false,
    this.dapExclusive = false,
    this.autoplay = false,
    this.autoplayPersonalization = true,
    this.musicHaptics = false,
    this.musicHapticsSensitivity = 0.5,
    this.musicHapticsStrength = 0.5,
    this.playerCoverStyle = 'default',
    this.isFirstLaunch = true,
    this.checkForUpdates = true,
    this.updateChannel = 'stable',
    this.hasSearchedBefore = false,
    this.folderOrganization = 'none',
    this.folderPathTemplate = '{artist}/{album}',
    this.createPlaylistFolder = false,
    this.useAlbumArtistForFolders = true,
    this.usePrimaryArtistOnly = false,
    this.filterContributingArtistsInAlbumArtist = false,
    this.historyViewMode = 'grid',
    this.historyFilterMode = 'all',
    this.defaultLibraryView = 'last',
    this.libraryQualityLabelMode = AppSettings.libraryQualityLabelBitDepthOnly,
    this.askQualityBeforeDownload = true,
    this.enableLogging = false,
    this.useExtensionProviders = true,
    this.downloadFallbackExtensionIds,
    this.searchProvider,
    this.defaultSearchTab = 'all',
    this.searchViewMode = 'list',
    this.homeFeedProvider,
    this.separateSingles = false,
    this.singleFilenameFormat = '{title} - {artist}',
    this.albumFolderStructure = 'artist_album',
    this.showExtensionStore = true,
    this.heroAnimationsEnabled = true,
    this.forceBackdropBlur = false,
    this.extensionVerificationBrowserMode = 'in_app_first',
    this.locale = 'system',
    this.lyricsMode = 'embed',
    this.keepScreenOnLyrics = true,
    this.motionArtworkEnabled = true,
    this.listeningStatisticsEnabled = true,
    this.autoConvertDownloads = false,
    this.redownloadFakeHiRes = false,
    this.autoConvertFormat = 'mp3',
    this.autoConvertBitrate = '320k',
    this.useAllFilesAccess = false,
    this.autoExportFailedDownloads = false,
    this.downloadNetworkMode = 'any',
    this.networkCompatibilityMode = false,
    this.allowLocalNetwork = false,
    this.songLinkRegion = 'US',
    this.nativeDownloadWorkerEnabled = false,
    this.concurrentDownloads = 1,
    this.localLibraryEnabled = false,
    this.localLibraryPath = '',
    this.localLibraryBookmark = '',
    this.localLibraryShowDuplicates = true,
    this.localLibraryAutoScan = 'off',
    this.hasCompletedTutorial = false,
    this.lyricsProviders = const [
      'apple_music',
      'lrcred',
      'mornye_lyrics',
      'lyricsplus',
      'lrclib',
    ],
    this.lyricsIncludeTranslationNetease = false,
    this.lyricsIncludeRomanizationNetease = false,
    this.lyricsMultiPersonWordByWord = true,
    this.lyricsAppleElrcWordSync = true,
    this.musixmatchLanguage = '',
    this.lastSeenVersion = '',
    this.deduplicateDownloads = true,
    this.allowQualityVariants = false,
    this.saveDownloadHistory = true,
    this.playerMode = 'internal',
    this.playerShowPronunciation = true,
    this.playerShowTranslation = true,
  });

  @JsonKey(includeFromJson: false, includeToJson: false)
  Map<String, dynamic> get lyricsFetchOptions => {
    'include_translation_netease': lyricsIncludeTranslationNetease,
    'include_romanization_netease': lyricsIncludeRomanizationNetease,
    'multi_person_word_by_word': lyricsMultiPersonWordByWord,
    'apple_elrc_word_sync': lyricsAppleElrcWordSync,
    'musixmatch_language': musixmatchLanguage,
  };

  AppSettings copyWith({
    String? defaultService,
    String? audioQuality,
    String? filenameFormat,
    String? downloadDirectory,
    String? networkDownloadFolder,
    String? networkDownloadLabel,
    String? downloadDirectoryBookmark,
    String? storageMode,
    String? downloadTreeUri,
    bool? autoFallback,
    bool? embedMetadata,
    int? embeddedCoverMaxDimension,
    String? artistTagMode,
    MetadataSeparators? metadataSeparators,
    bool? embedLyrics,
    bool? embedReplayGain,
    bool? playbackNormalization,
    double? playbackNormalizationPreamp,
    String? playbackNormalizationMode,
    bool? pauseOnMute,
    bool? playOnHeadphonesConnected,
    bool? autoMix,
    int? autoMixDuration,
    AutoMixEffect? autoMixEffect,
    double? autoMixSpeed,
    double? autoMixPitch,
    bool? autoMixEcho,
    bool? autoMixLowPass,
    bool? discordRichPresenceEnabled,
    bool? usbBitPerfect,
    bool? usbDirect,
    bool? usbDsdOverPcm,
    bool? usbAllowFixedVolume,
    bool? dapExclusive,
    bool? autoplay,
    bool? autoplayPersonalization,
    bool? musicHaptics,
    double? musicHapticsSensitivity,
    double? musicHapticsStrength,
    String? playerCoverStyle,
    bool? isFirstLaunch,
    bool? checkForUpdates,
    String? updateChannel,
    bool? hasSearchedBefore,
    String? folderOrganization,
    String? folderPathTemplate,
    bool? createPlaylistFolder,
    bool? useAlbumArtistForFolders,
    bool? usePrimaryArtistOnly,
    bool? filterContributingArtistsInAlbumArtist,
    String? historyViewMode,
    String? historyFilterMode,
    String? defaultLibraryView,
    String? libraryQualityLabelMode,
    bool? askQualityBeforeDownload,
    bool? enableLogging,
    bool? useExtensionProviders,
    List<String>? downloadFallbackExtensionIds,
    bool clearDownloadFallbackExtensionIds = false,
    String? searchProvider,
    bool clearSearchProvider = false,
    String? defaultSearchTab,
    String? searchViewMode,
    String? homeFeedProvider,
    bool clearHomeFeedProvider = false,
    bool? separateSingles,
    String? singleFilenameFormat,
    String? albumFolderStructure,
    bool? showExtensionStore,
    bool? heroAnimationsEnabled,
    bool? forceBackdropBlur,
    String? extensionVerificationBrowserMode,
    String? locale,
    String? lyricsMode,
    bool? keepScreenOnLyrics,
    bool? motionArtworkEnabled,
    bool? listeningStatisticsEnabled,
    bool? autoConvertDownloads,
    bool? redownloadFakeHiRes,
    String? autoConvertFormat,
    String? autoConvertBitrate,
    bool? useAllFilesAccess,
    bool? autoExportFailedDownloads,
    String? downloadNetworkMode,
    bool? networkCompatibilityMode,
    bool? allowLocalNetwork,
    String? songLinkRegion,
    bool? nativeDownloadWorkerEnabled,
    int? concurrentDownloads,
    bool? localLibraryEnabled,
    String? localLibraryPath,
    String? localLibraryBookmark,
    bool? localLibraryShowDuplicates,
    String? localLibraryAutoScan,
    bool? hasCompletedTutorial,
    List<String>? lyricsProviders,
    bool? lyricsIncludeTranslationNetease,
    bool? lyricsIncludeRomanizationNetease,
    bool? lyricsMultiPersonWordByWord,
    bool? lyricsAppleElrcWordSync,
    String? musixmatchLanguage,
    String? lastSeenVersion,
    bool? deduplicateDownloads,
    bool? allowQualityVariants,
    bool? saveDownloadHistory,
    String? playerMode,
    bool? playerShowPronunciation,
    bool? playerShowTranslation,
  }) {
    return AppSettings(
      defaultService: defaultService ?? this.defaultService,
      audioQuality: audioQuality ?? this.audioQuality,
      filenameFormat: filenameFormat ?? this.filenameFormat,
      downloadDirectory: downloadDirectory ?? this.downloadDirectory,
      networkDownloadFolder:
          networkDownloadFolder ?? this.networkDownloadFolder,
      networkDownloadLabel: networkDownloadLabel ?? this.networkDownloadLabel,
      downloadDirectoryBookmark:
          downloadDirectoryBookmark ?? this.downloadDirectoryBookmark,
      storageMode: storageMode ?? this.storageMode,
      downloadTreeUri: downloadTreeUri ?? this.downloadTreeUri,
      autoFallback: autoFallback ?? this.autoFallback,
      embedMetadata: embedMetadata ?? this.embedMetadata,
      embeddedCoverMaxDimension:
          embeddedCoverMaxDimension ?? this.embeddedCoverMaxDimension,
      artistTagMode: artistTagMode ?? this.artistTagMode,
      metadataSeparators: metadataSeparators ?? this.metadataSeparators,
      embedLyrics: embedLyrics ?? this.embedLyrics,
      embedReplayGain: embedReplayGain ?? this.embedReplayGain,
      playbackNormalization:
          playbackNormalization ?? this.playbackNormalization,
      playbackNormalizationPreamp:
          playbackNormalizationPreamp ?? this.playbackNormalizationPreamp,
      playbackNormalizationMode:
          playbackNormalizationMode ?? this.playbackNormalizationMode,
      pauseOnMute: pauseOnMute ?? this.pauseOnMute,
      playOnHeadphonesConnected:
          playOnHeadphonesConnected ?? this.playOnHeadphonesConnected,
      autoMix: autoMix ?? this.autoMix,
      autoMixDuration: autoMixDuration ?? this.autoMixDuration,
      autoMixEffect: autoMixEffect ?? this.autoMixEffect,
      autoMixSpeed: autoMixSpeed ?? this.autoMixSpeed,
      autoMixPitch: autoMixPitch ?? this.autoMixPitch,
      autoMixEcho: autoMixEcho ?? this.autoMixEcho,
      autoMixLowPass: autoMixLowPass ?? this.autoMixLowPass,
      discordRichPresenceEnabled:
          discordRichPresenceEnabled ?? this.discordRichPresenceEnabled,
      usbBitPerfect: usbBitPerfect ?? this.usbBitPerfect,
      usbDirect: usbDirect ?? this.usbDirect,
      usbDsdOverPcm: usbDsdOverPcm ?? this.usbDsdOverPcm,
      usbAllowFixedVolume: usbAllowFixedVolume ?? this.usbAllowFixedVolume,
      dapExclusive: dapExclusive ?? this.dapExclusive,
      autoplay: autoplay ?? this.autoplay,
      autoplayPersonalization:
          autoplayPersonalization ?? this.autoplayPersonalization,
      musicHaptics: musicHaptics ?? this.musicHaptics,
      musicHapticsSensitivity:
          musicHapticsSensitivity ?? this.musicHapticsSensitivity,
      musicHapticsStrength: musicHapticsStrength ?? this.musicHapticsStrength,
      playerCoverStyle: playerCoverStyle ?? this.playerCoverStyle,
      isFirstLaunch: isFirstLaunch ?? this.isFirstLaunch,
      checkForUpdates: checkForUpdates ?? this.checkForUpdates,
      updateChannel: updateChannel ?? this.updateChannel,
      hasSearchedBefore: hasSearchedBefore ?? this.hasSearchedBefore,
      folderOrganization: folderOrganization ?? this.folderOrganization,
      folderPathTemplate: folderPathTemplate ?? this.folderPathTemplate,
      createPlaylistFolder: createPlaylistFolder ?? this.createPlaylistFolder,
      useAlbumArtistForFolders:
          useAlbumArtistForFolders ?? this.useAlbumArtistForFolders,
      usePrimaryArtistOnly: usePrimaryArtistOnly ?? this.usePrimaryArtistOnly,
      filterContributingArtistsInAlbumArtist:
          filterContributingArtistsInAlbumArtist ??
          this.filterContributingArtistsInAlbumArtist,
      historyViewMode: historyViewMode ?? this.historyViewMode,
      historyFilterMode: historyFilterMode ?? this.historyFilterMode,
      defaultLibraryView: defaultLibraryView ?? this.defaultLibraryView,
      libraryQualityLabelMode:
          libraryQualityLabelMode ?? this.libraryQualityLabelMode,
      askQualityBeforeDownload:
          askQualityBeforeDownload ?? this.askQualityBeforeDownload,
      enableLogging: enableLogging ?? this.enableLogging,
      useExtensionProviders:
          useExtensionProviders ?? this.useExtensionProviders,
      downloadFallbackExtensionIds: clearDownloadFallbackExtensionIds
          ? null
          : (downloadFallbackExtensionIds ?? this.downloadFallbackExtensionIds),
      searchProvider: clearSearchProvider
          ? null
          : (searchProvider ?? this.searchProvider),
      defaultSearchTab: defaultSearchTab ?? this.defaultSearchTab,
      searchViewMode: searchViewMode ?? this.searchViewMode,
      homeFeedProvider: clearHomeFeedProvider
          ? null
          : (homeFeedProvider ?? this.homeFeedProvider),
      separateSingles: separateSingles ?? this.separateSingles,
      singleFilenameFormat: singleFilenameFormat ?? this.singleFilenameFormat,
      albumFolderStructure: albumFolderStructure ?? this.albumFolderStructure,
      showExtensionStore: showExtensionStore ?? this.showExtensionStore,
      heroAnimationsEnabled:
          heroAnimationsEnabled ?? this.heroAnimationsEnabled,
      forceBackdropBlur: forceBackdropBlur ?? this.forceBackdropBlur,
      extensionVerificationBrowserMode:
          extensionVerificationBrowserMode ??
          this.extensionVerificationBrowserMode,
      locale: locale ?? this.locale,
      lyricsMode: lyricsMode ?? this.lyricsMode,
      keepScreenOnLyrics: keepScreenOnLyrics ?? this.keepScreenOnLyrics,
      motionArtworkEnabled: motionArtworkEnabled ?? this.motionArtworkEnabled,
      listeningStatisticsEnabled:
          listeningStatisticsEnabled ?? this.listeningStatisticsEnabled,
      autoConvertDownloads: autoConvertDownloads ?? this.autoConvertDownloads,
      redownloadFakeHiRes: redownloadFakeHiRes ?? this.redownloadFakeHiRes,
      autoConvertFormat: autoConvertFormat ?? this.autoConvertFormat,
      autoConvertBitrate: autoConvertBitrate ?? this.autoConvertBitrate,
      useAllFilesAccess: useAllFilesAccess ?? this.useAllFilesAccess,
      autoExportFailedDownloads:
          autoExportFailedDownloads ?? this.autoExportFailedDownloads,
      downloadNetworkMode: downloadNetworkMode ?? this.downloadNetworkMode,
      networkCompatibilityMode:
          networkCompatibilityMode ?? this.networkCompatibilityMode,
      allowLocalNetwork: allowLocalNetwork ?? this.allowLocalNetwork,
      songLinkRegion: songLinkRegion ?? this.songLinkRegion,
      nativeDownloadWorkerEnabled:
          nativeDownloadWorkerEnabled ?? this.nativeDownloadWorkerEnabled,
      concurrentDownloads: concurrentDownloads ?? this.concurrentDownloads,
      localLibraryEnabled: localLibraryEnabled ?? this.localLibraryEnabled,
      localLibraryPath: localLibraryPath ?? this.localLibraryPath,
      localLibraryBookmark: localLibraryBookmark ?? this.localLibraryBookmark,
      localLibraryShowDuplicates:
          localLibraryShowDuplicates ?? this.localLibraryShowDuplicates,
      localLibraryAutoScan: localLibraryAutoScan ?? this.localLibraryAutoScan,
      hasCompletedTutorial: hasCompletedTutorial ?? this.hasCompletedTutorial,
      lyricsProviders: lyricsProviders ?? this.lyricsProviders,
      lyricsIncludeTranslationNetease:
          lyricsIncludeTranslationNetease ??
          this.lyricsIncludeTranslationNetease,
      lyricsIncludeRomanizationNetease:
          lyricsIncludeRomanizationNetease ??
          this.lyricsIncludeRomanizationNetease,
      lyricsMultiPersonWordByWord:
          lyricsMultiPersonWordByWord ?? this.lyricsMultiPersonWordByWord,
      lyricsAppleElrcWordSync:
          lyricsAppleElrcWordSync ?? this.lyricsAppleElrcWordSync,
      musixmatchLanguage: musixmatchLanguage ?? this.musixmatchLanguage,
      lastSeenVersion: lastSeenVersion ?? this.lastSeenVersion,
      deduplicateDownloads: deduplicateDownloads ?? this.deduplicateDownloads,
      allowQualityVariants: allowQualityVariants ?? this.allowQualityVariants,
      saveDownloadHistory: saveDownloadHistory ?? this.saveDownloadHistory,
      playerMode: playerMode ?? this.playerMode,
      playerShowPronunciation:
          playerShowPronunciation ?? this.playerShowPronunciation,
      playerShowTranslation:
          playerShowTranslation ?? this.playerShowTranslation,
    );
  }

  factory AppSettings.fromJson(Map<String, dynamic> json) {
    final settings = _$AppSettingsFromJson(json);
    if (!settings.lyricsProviders.contains('spotiflac_lyrics')) {
      return settings;
    }
    return settings.copyWith(
      lyricsProviders: {
        for (final provider in settings.lyricsProviders)
          provider == 'spotiflac_lyrics' ? 'mornye_lyrics' : provider,
      }.toList(),
    );
  }
  Map<String, dynamic> toJson() => _$AppSettingsToJson(this);
}
