import 'package:json_annotation/json_annotation.dart';
import 'package:mornye/models/automix_options.dart';
import 'package:mornye/models/metadata_separators.dart';
import 'package:mornye/utils/artist_utils.dart';

part 'settings.g.dart';

/// 'default' (a card) or 'fullscreen' once chosen, else empty for the app
/// style's own ([AppSettings.playerCoverStyleFor]).
String playerCoverStyleFromJson(Object? value) =>
    value == 'default' || value == 'fullscreen' ? value as String : '';

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
  // Start the next song the moment one ends; AutoMix replaces it while on.
  final bool gaplessPlayback;
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

  /// Desktop: take the output device for the music player alone, bypassing
  /// the system mixer (WASAPI exclusive on Windows, hog mode on macOS, an
  /// ALSA `hw:` device on Linux). AutoMix and previews stay off while it is
  /// on.
  final bool exclusiveOutput;

  /// Linux: the ALSA device [exclusiveOutput] opens, as an mpv device name
  /// (`alsa/hw:CARD=…,DEV=…`). Empty picks the first card.
  final String exclusiveOutputDevice;

  /// Windows: output mode discriminator ('shared', 'exclusive_event', 'exclusive_push').
  /// Both 'exclusive_event' and 'exclusive_push' set [exclusiveOutput] to true.
  final String windowsOutputMode;

  /// Windows: selected Core Audio render endpoint identifier or mpv device ID.
  /// Empty selects the system default endpoint.
  final String windowsOutputDevice;

  /// Windows: whether to automatically fall back to shared mode if exclusive mode fails.
  final bool windowsExclusiveFallback;

  /// Windows: requested target sample rate (0 = automatic / match source).
  final int windowsOutputSampleRate;

  /// Windows: requested sample format ('auto', 's16', 's24', 's32', 'float').
  final String windowsOutputSampleFormat;

  /// Windows: requested channel configuration ('auto', 'stereo').
  final String windowsOutputChannels;
  final bool autoplay;
  final bool autoplayPersonalization;

  /// Analyze how each Library song sounds, on this device, so Autoplay picks
  /// songs that sound like the session. Off until turned on: decoding songs
  /// is heavy on low-end phones.
  final bool songAnalysis;

  /// Android: analyze the Library only while charging. The song playing is
  /// analyzed either way.
  final bool songAnalysisOnlyWhileCharging;
  final bool musicHaptics;
  @JsonKey(fromJson: musicHapticsLevelFromJson)
  final double musicHapticsSensitivity;
  @JsonKey(fromJson: musicHapticsLevelFromJson)
  final double musicHapticsStrength;
  @JsonKey(fromJson: playerCoverStyleFromJson)
  final String playerCoverStyle; // 'default' (card), 'fullscreen' or ''
  final bool landscapeLyricsArtwork;
  // Material: idle lyrics shrink the player to a slim bar, not hide it.
  final bool compactPlayer;
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
  final String autoConvertFormat; // 'mp3', 'aac' (M4A), 'opus', or 'flac'
  final String autoConvertBitrate; // '128k', '160k', '192k', '256k', or '320k'
  final int autoConvertMaxBitDepth; // 0 retains the source bit depth.
  final int autoConvertMaxSampleRate; // 0 retains the source sample rate.
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

  /// The last `AppInfo.whatsNewRelease` tour shown or skipped. New installs
  /// mark the current one at setup, so only updates show the tour.
  final String whatsNewSeen;

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

  /// AI lyrics translation. The API key lives in secure storage, never here.
  final String lyricsAiProvider;

  /// API root of a custom OpenAI-compatible server.
  final String lyricsAiBaseUrl;

  /// Empty uses the provider's default model.
  final String lyricsAiModel;

  /// BCP-47 target language; empty follows the app language.
  final String lyricsTranslationLanguage;

  /// Optional guidance added to the translation prompt.
  final String lyricsAiInstruction;

  /// Translate lyrics without a translation as they open.
  final bool lyricsAutoTranslate;

  /// Ask the translation for a romanization of lines written outside the
  /// Latin alphabet.
  final bool lyricsAiRomanize;

  final String
  lastSeenVersion; // Last app version the user has acknowledged (e.g. '3.7.0')

  final bool deduplicateDownloads;
  final bool allowQualityVariants;
  final bool saveDownloadHistory;

  final String playerMode;
  final bool playerShowPronunciation;
  final bool playerShowTranslation;

  /// Whether the phone Now Playing screen shows its volume slider.
  final bool playerShowVolume;

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
    this.gaplessPlayback = true,
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
    this.exclusiveOutput = false,
    this.exclusiveOutputDevice = '',
    this.windowsOutputMode = 'exclusive_event',
    this.windowsOutputDevice = '',
    this.windowsExclusiveFallback = true,
    this.windowsOutputSampleRate = 0,
    this.windowsOutputSampleFormat = 'auto',
    this.windowsOutputChannels = 'auto',
    this.autoplay = false,
    this.autoplayPersonalization = true,
    this.songAnalysis = false,
    this.songAnalysisOnlyWhileCharging = true,
    this.musicHaptics = false,
    this.musicHapticsSensitivity = 0.5,
    this.musicHapticsStrength = 0.5,
    this.playerCoverStyle = '',
    this.landscapeLyricsArtwork = false,
    this.compactPlayer = false,
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
    this.autoConvertMaxBitDepth = 16,
    this.autoConvertMaxSampleRate = 48000,
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
    this.whatsNewSeen = '',
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
    this.lyricsAiProvider = 'openai',
    this.lyricsAiBaseUrl = '',
    this.lyricsAiModel = '',
    this.lyricsTranslationLanguage = '',
    this.lyricsAiInstruction = '',
    this.lyricsAutoTranslate = false,
    this.lyricsAiRomanize = true,
    this.lastSeenVersion = '',
    this.deduplicateDownloads = true,
    this.allowQualityVariants = false,
    this.saveDownloadHistory = true,
    this.playerMode = 'internal',
    this.playerShowPronunciation = true,
    this.playerShowTranslation = true,
    this.playerShowVolume = true,
  });

  @JsonKey(includeFromJson: false, includeToJson: false)
  Map<String, dynamic> get lyricsFetchOptions => {
    'include_translation_netease': lyricsIncludeTranslationNetease,
    'include_romanization_netease': lyricsIncludeRomanizationNetease,
    'multi_person_word_by_word': lyricsMultiPersonWordByWord,
    'apple_elrc_word_sync': lyricsAppleElrcWordSync,
    'musixmatch_language': musixmatchLanguage,
  };

  /// The cover art style the player shows: the one chosen, else the app
  /// style's own, full screen in Material and a card in Mornye.
  String playerCoverStyleFor({required bool mornye}) =>
      playerCoverStyle.isNotEmpty
      ? playerCoverStyle
      : mornye
      ? 'default'
      : 'fullscreen';

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
    bool? gaplessPlayback,
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
    bool? exclusiveOutput,
    String? exclusiveOutputDevice,
    String? windowsOutputMode,
    String? windowsOutputDevice,
    bool? windowsExclusiveFallback,
    int? windowsOutputSampleRate,
    String? windowsOutputSampleFormat,
    String? windowsOutputChannels,
    bool? autoplay,
    bool? autoplayPersonalization,
    bool? songAnalysis,
    bool? songAnalysisOnlyWhileCharging,
    bool? musicHaptics,
    double? musicHapticsSensitivity,
    double? musicHapticsStrength,
    String? playerCoverStyle,
    bool? landscapeLyricsArtwork,
    bool? compactPlayer,
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
    int? autoConvertMaxBitDepth,
    int? autoConvertMaxSampleRate,
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
    String? whatsNewSeen,
    List<String>? lyricsProviders,
    bool? lyricsIncludeTranslationNetease,
    bool? lyricsIncludeRomanizationNetease,
    bool? lyricsMultiPersonWordByWord,
    bool? lyricsAppleElrcWordSync,
    String? musixmatchLanguage,
    String? lyricsAiProvider,
    String? lyricsAiBaseUrl,
    String? lyricsAiModel,
    String? lyricsTranslationLanguage,
    String? lyricsAiInstruction,
    bool? lyricsAutoTranslate,
    bool? lyricsAiRomanize,
    String? lastSeenVersion,
    bool? deduplicateDownloads,
    bool? allowQualityVariants,
    bool? saveDownloadHistory,
    String? playerMode,
    bool? playerShowPronunciation,
    bool? playerShowTranslation,
    bool? playerShowVolume,
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
      gaplessPlayback: gaplessPlayback ?? this.gaplessPlayback,
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
      exclusiveOutput: exclusiveOutput ?? this.exclusiveOutput,
      exclusiveOutputDevice:
          exclusiveOutputDevice ?? this.exclusiveOutputDevice,
      windowsOutputMode: windowsOutputMode ?? this.windowsOutputMode,
      windowsOutputDevice: windowsOutputDevice ?? this.windowsOutputDevice,
      windowsExclusiveFallback:
          windowsExclusiveFallback ?? this.windowsExclusiveFallback,
      windowsOutputSampleRate:
          windowsOutputSampleRate ?? this.windowsOutputSampleRate,
      windowsOutputSampleFormat:
          windowsOutputSampleFormat ?? this.windowsOutputSampleFormat,
      windowsOutputChannels:
          windowsOutputChannels ?? this.windowsOutputChannels,
      autoplay: autoplay ?? this.autoplay,
      autoplayPersonalization:
          autoplayPersonalization ?? this.autoplayPersonalization,
      songAnalysis: songAnalysis ?? this.songAnalysis,
      songAnalysisOnlyWhileCharging:
          songAnalysisOnlyWhileCharging ?? this.songAnalysisOnlyWhileCharging,
      musicHaptics: musicHaptics ?? this.musicHaptics,
      musicHapticsSensitivity:
          musicHapticsSensitivity ?? this.musicHapticsSensitivity,
      musicHapticsStrength: musicHapticsStrength ?? this.musicHapticsStrength,
      playerCoverStyle: playerCoverStyle ?? this.playerCoverStyle,
      landscapeLyricsArtwork:
          landscapeLyricsArtwork ?? this.landscapeLyricsArtwork,
      compactPlayer: compactPlayer ?? this.compactPlayer,
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
      autoConvertMaxBitDepth:
          autoConvertMaxBitDepth ?? this.autoConvertMaxBitDepth,
      autoConvertMaxSampleRate:
          autoConvertMaxSampleRate ?? this.autoConvertMaxSampleRate,
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
      whatsNewSeen: whatsNewSeen ?? this.whatsNewSeen,
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
      lyricsAiProvider: lyricsAiProvider ?? this.lyricsAiProvider,
      lyricsAiBaseUrl: lyricsAiBaseUrl ?? this.lyricsAiBaseUrl,
      lyricsAiModel: lyricsAiModel ?? this.lyricsAiModel,
      lyricsTranslationLanguage:
          lyricsTranslationLanguage ?? this.lyricsTranslationLanguage,
      lyricsAiInstruction: lyricsAiInstruction ?? this.lyricsAiInstruction,
      lyricsAutoTranslate: lyricsAutoTranslate ?? this.lyricsAutoTranslate,
      lyricsAiRomanize: lyricsAiRomanize ?? this.lyricsAiRomanize,
      lastSeenVersion: lastSeenVersion ?? this.lastSeenVersion,
      deduplicateDownloads: deduplicateDownloads ?? this.deduplicateDownloads,
      allowQualityVariants: allowQualityVariants ?? this.allowQualityVariants,
      saveDownloadHistory: saveDownloadHistory ?? this.saveDownloadHistory,
      playerMode: playerMode ?? this.playerMode,
      playerShowPronunciation:
          playerShowPronunciation ?? this.playerShowPronunciation,
      playerShowTranslation:
          playerShowTranslation ?? this.playerShowTranslation,
      playerShowVolume: playerShowVolume ?? this.playerShowVolume,
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
