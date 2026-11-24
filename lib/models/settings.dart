import 'package:json_annotation/json_annotation.dart';
import 'package:mornye/models/automix_options.dart';
import 'package:mornye/models/home_layout.dart';
import 'package:mornye/models/metadata_separators.dart';
import 'package:mornye/utils/artist_utils.dart';

part 'settings.g.dart';

/// A saved Home layout, or the shipped one when there is none to read.
HomeLayout homeLayoutFromJson(Object? value) => value is Map
    ? HomeLayout.fromJson(Map<String, dynamic>.from(value))
    : const HomeLayout();

/// 'default' (a card) or 'fullscreen' once chosen, else empty for the app
/// style's own ([AppSettings.playerCoverStyleFor]).
String playerCoverStyleFromJson(Object? value) =>
    value == 'default' || value == 'fullscreen' ? value as String : '';

/// How far up a full screen cover its fade reaches: 'short', 'medium' or
/// 'long'.
String playerCoverFadeFromJson(Object? value) =>
    value == 'short' || value == 'long' ? value as String : 'medium';

/// Where a full screen cover starts to fade, as a share of its height, when
/// it starts at [medium] for the medium [fade].
double playerCoverFadeStart(double medium, String fade) =>
    1 -
    (1 - medium) *
        switch (fade) {
          'short' => 0.65,
          'long' => 1.4,
          _ => 1.0,
        };

/// Pre-amp applied on top of ReplayGain during playback, in whole dB.
/// -7 dB targets -25 LUFS from the -18 LUFS tag reference.
double playbackNormalizationPreampFromJson(Object? value) =>
    value is num && value.isFinite
    ? value.toDouble().roundToDouble().clamp(-15, 6)
    : 0;

String playbackNormalizationModeFromJson(Object? value) =>
    value == 'album' ? 'album' : 'track';

/// Volume levels, in percent, above which the volume bar can ask first.
const loudVolumeLevels = [60, 70, 80, 90];

int loudVolumeLevelFromJson(Object? value) =>
    value is int && loudVolumeLevels.contains(value) ? value : 80;

/// When connecting headphones resumes playback: never, only a recent pause
/// caused by headphones or Bluetooth going away, or on every connection
/// (which also pauses on disconnect).
const headphoneResumeModes = ['off', 'after_disconnect', 'always'];

/// Older builds stored two switches. The broad one wins, then the narrow
/// one; an unknown value reads as off.
Object? readHeadphoneResume(Map<dynamic, dynamic> json, String key) {
  final value = json[key];
  if (headphoneResumeModes.contains(value)) return value;
  if (json['playOnHeadphonesConnected'] == true) return 'always';
  if (json['resumeOnOutputReconnect'] == true) return 'after_disconnect';
  return 'off';
}

String headphoneResumeFromJson(Object? value) =>
    headphoneResumeModes.contains(value) ? value! as String : 'off';

double musicHapticsLevelFromJson(Object? value) =>
    value is num && value.isFinite ? value.toDouble().clamp(0, 1) : 0.5;

double autoplayRandomnessFromJson(Object? value) =>
    value is num && value.isFinite ? value.toDouble().clamp(0, 1) : 0;

/// Slowest and fastest playback speed, as a factor of the normal speed.
const double minPlaybackSpeed = 0.5;
const double maxPlaybackSpeed = 2;

double playbackSpeedFromJson(Object? value) => value is num && value.isFinite
    ? value.toDouble().clamp(minPlaybackSpeed, maxPlaybackSpeed)
    : 1;

/// Largest pitch shift either way, in semitones.
const double maxPlaybackPitch = 12;

/// The pitch shift in whole semitones, the steps a key changes by.
double playbackPitchFromJson(Object? value) => value is num && value.isFinite
    ? value.toDouble().roundToDouble().clamp(
        -maxPlaybackPitch,
        maxPlaybackPitch,
      )
    : 0;

/// Smallest and largest Interface size, as a factor of the normal size.
const double minInterfaceScale = 0.8;
const double maxInterfaceScale = 1.3;

double interfaceScaleFromJson(Object? value) => value is num && value.isFinite
    ? value.toDouble().clamp(minInterfaceScale, maxInterfaceScale)
    : 1;

/// Slowest and fastest Animation speed, as a factor of the designed speed.
const double minAnimationSpeed = 0.5;
const double maxAnimationSpeed = 2;

double animationSpeedFromJson(Object? value) => value is num && value.isFinite
    ? value.toDouble().clamp(minAnimationSpeed, maxAnimationSpeed)
    : 1;

/// Sort choices offered by the Library, in display order.
const librarySortModes = [
  'latest',
  'oldest',
  'size-desc',
  'size-asc',
  'a-z',
  'z-a',
  'artist-asc',
  'artist-desc',
  'album-asc',
  'album-desc',
  'year-asc',
  'year-desc',
  'release-newest',
  'release-oldest',
  'genre-asc',
  'genre-desc',
];

String librarySortModeFromJson(Object? value) =>
    value is String && librarySortModes.contains(value) ? value : 'latest';

String libraryAlbumSortModeFromJson(Object? value) =>
    const [
      'a-z',
      'latest',
      'size-desc',
      'size-asc',
      'year-asc',
      'year-desc',
    ].contains(value)
    ? value as String
    : 'a-z';

const lyricsTranslationSaveToSongFile = 'songFile';
const lyricsTranslationSaveToMlrc = 'mlrc';

String lyricsTranslationSaveToFromJson(Object? value) =>
    value == lyricsTranslationSaveToMlrc
    ? lyricsTranslationSaveToMlrc
    : lyricsTranslationSaveToSongFile;

/// Offline romanization starts as the AI romanization switch was, so a
/// user who turned that off is not shown romanization they did not want.
Object? readLyricsRomanize(Map<dynamic, dynamic> json, String key) =>
    json[key] ?? json['lyricsAiRomanize'];

@JsonSerializable(explicitToJson: true)
class AppSettings {
  static const String homeFeedProviderOff = '__off__';
  static const String libraryQualityLabelBitrate = 'bitrate';
  static const String libraryQualityLabelFileFormat = 'file_format';
  static const String libraryQualityLabelBitDepthOnly = 'bit_depth_only';
  static const String libraryQualityLabelBitDepth = 'bit_depth';
  static const String libraryQualityLabelBitDepthBitrate = 'bit_depth_bitrate';
  static const String libraryQualityLabelSimple = 'simple';
  static const String librarySongTapPlay = 'play';
  static const String librarySongTapDetails = 'details';

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
  // Also turn up songs whose tags ask for more gain, not only turn down.
  final bool playbackNormalizationBoost;
  // Ask before the app's volume bar goes above [loudVolumeLevel] percent.
  final bool confirmLoudVolume;
  @JsonKey(fromJson: loudVolumeLevelFromJson)
  final int loudVolumeLevel; // One of [loudVolumeLevels].
  final bool pauseOnMute;
  // One of [headphoneResumeModes].
  @JsonKey(readValue: readHeadphoneResume, fromJson: headphoneResumeFromJson)
  final String headphoneResume;
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

  /// How readily AutoMix mixes two songs on their beats.
  @JsonKey(unknownEnumValue: AutoMixMatching.standard)
  final AutoMixMatching autoMixMatching;

  /// Playback speed for every song, from [minPlaybackSpeed] to
  /// [maxPlaybackSpeed]; 1 is normal.
  @JsonKey(fromJson: playbackSpeedFromJson)
  final double playbackSpeed;

  /// True keeps the pitch while the speed changes; false lets the pitch
  /// follow the speed, as a record played faster or slower.
  final bool playbackKeepPitch;

  /// Pitch shift in whole semitones on top of [playbackKeepPitch], from
  /// -[maxPlaybackPitch] to [maxPlaybackPitch]; 0 is the original key.
  @JsonKey(fromJson: playbackPitchFromJson)
  final double playbackPitch;
  AutoMixOptions get autoMixOptions => AutoMixOptions(
    durationSeconds: autoMixDuration,
    effect: autoMixEffect,
    speed: autoMixSpeed,
    pitchSemitones: autoMixPitch,
    echo: autoMixEcho,
    lowPass: autoMixLowPass,
    matching: autoMixMatching,
  );
  final bool discordRichPresenceEnabled;
  final bool usbBitPerfect;
  final bool usbDirect;
  final bool usbDsdOverPcm;
  final bool usbAllowFixedVolume;

  /// The highest sample rate the direct USB driver sets on the DAC, in Hz;
  /// a song above it is converted. 0 leaves the choice to the DAC.
  final int usbMaxSampleRate;

  /// High-pass TPDF instead of plain TPDF when the direct USB driver
  /// converts a song for a 16-bit output.
  final bool usbDitherHighPass;
  final bool dapExclusive;

  /// Android beta, off by default: play the music player and AutoMix through
  /// the app's own media3 engine instead of the platform MediaPlayer, which
  /// turning it off restores. Songs for the USB and AAudio outputs
  /// ([usbBitPerfect]) stay on the platform player. Applies from the next
  /// song.
  final bool media3Engine;

  /// Android, through [media3Engine] only: jump over silent passages. Off
  /// while AutoMix is on, whose fades follow the clock. While on, media3
  /// decodes to 16-bit, which its silence detection needs.
  final bool skipSilence;

  /// Android, iOS and macOS: let the system spatialize songs (Android
  /// spatialization behavior auto, Apple mono, stereo and multichannel).
  /// Off asks the system never to spatialize them. The app renders nothing.
  final bool spatialAudio;

  /// Adding a song already coming up in the queue moves that entry instead
  /// of queueing a second copy. The current and played entries stay.
  final bool queueNoDuplicates;

  /// The queue UIs stop reordering and swiping songs away; adding songs
  /// from elsewhere still works. Toggled from the queue header too.
  final bool queueLocked;

  /// Desktop: take the output device for the music player alone, bypassing
  /// the system mixer (WASAPI exclusive on Windows, hog mode on macOS, an
  /// ALSA `hw:` device on Linux). AutoMix and previews stay off while it is
  /// on.
  final bool exclusiveOutput;

  /// Linux: the ALSA device [exclusiveOutput] opens, as an mpv device name
  /// (`alsa/hw:CARD=…,DEV=…`). Empty picks the first card.
  final String exclusiveOutputDevice;
  final bool autoplay;
  final bool autoplayPersonalization;
  @JsonKey(fromJson: autoplayRandomnessFromJson)
  final double autoplayRandomness;

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
  @JsonKey(fromJson: playerCoverFadeFromJson)
  final String playerCoverFade; // 'short', 'medium' or 'long'
  /// A full screen cover keeps its sides, and so ends above the title.
  final bool playerCoverWhole;
  final bool landscapeLyricsArtwork;
  final bool autoHideLyricsControls;

  /// An explicit auto-hide choice also applies if accessibility changes later.
  /// The default keeps playback controls available to assistive navigation.
  final bool autoHideLyricsControlsWithAccessibility;
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
  @JsonKey(fromJson: librarySortModeFromJson)
  final String historySortMode;
  @JsonKey(fromJson: libraryAlbumSortModeFromJson)
  final String libraryAlbumSortMode;

  /// A Library artist opens on all their songs instead of their albums:
  /// the view chosen last on an artist.
  final bool libraryArtistShowsSongs;

  /// Library view opened when switching to the Library tab:
  /// 'last' (keep last used), 'all', 'albums', 'singles', or 'playlists'.
  final String defaultLibraryView;

  /// Library badge text: measured bitrate, file format, bit depth,
  /// bit depth/sample rate, or the combined bit depth/bitrate label.
  final String libraryQualityLabelMode;

  /// Phones and tablets: a horizontal swipe on a song row plays it next or
  /// adds it to the queue.
  final bool swipeToQueue;

  /// What a tap on a Library song row with a play button does:
  /// [librarySongTapDetails], the default, opens its details and the button
  /// plays; [librarySongTapPlay] plays it and the button opens its details.
  final String librarySongTap;
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

  /// The Material Home's shortcuts, in order, by `HomeShortcut` name. Read
  /// them through `HomeShortcut.resolve`, which fills in unknown names.
  final List<String> homeShortcuts;

  /// Whether Home offers the last song again ("Continue listening").
  final bool homeContinueListening;

  /// Whether Home recommends songs outside the Library, asked from an
  /// extension with a few Library songs as the example.
  final bool homeRecommendations;

  /// The order of Home's sections and the ones turned off. Read what shows
  /// through [homeShows].
  @JsonKey(fromJson: homeLayoutFromJson)
  final HomeLayout homeLayout;
  final bool separateSingles;
  final String singleFilenameFormat;
  final String albumFolderStructure;
  final bool showExtensionStore;

  /// Installs store updates for enabled extensions after each background
  /// store check, but only while no download is queued or running.
  final bool autoUpdateExtensions;

  /// Shared-element (Hero) flights, e.g. the mini player artwork expanding
  /// into the full player. Off skips the flights entirely.
  final bool heroAnimationsEnabled;

  /// Forces the shell's backdrop blur on even when the startup runtime
  /// profile disabled it for this device tier. Off means "follow the
  /// device default".
  final bool forceBackdropBlur;

  /// Interface size: scales the whole app, on top of the automatic tablet
  /// and TV scale. 1 is the normal size.
  @JsonKey(fromJson: interfaceScaleFromJson)
  final double interfaceScale;

  /// Animation speed: how fast the app's own motion plays. 1 is the
  /// designed speed, 2 twice as fast.
  @JsonKey(fromJson: animationSpeedFromJson)
  final double animationSpeed;
  final String
  extensionVerificationBrowserMode; // 'external_first' or 'in_app_first'
  final String locale;
  final String lyricsMode;
  final bool keepScreenOnLyrics;

  /// Show the line being sung in place of the song title on the lock screen.
  final bool lockScreenLyrics;

  /// The lock screen line takes the artist's place and the title stays.
  final bool lockScreenLyricsKeepTitle;
  final bool motionArtworkEnabled;

  /// Copy a download's animated cover into its album folder as `cover.mp4`.
  final bool saveMotionArtworkFile;

  /// Save a download's cover into its album folder as `folder.jpg`, for
  /// players that do not read the cover inside a song.
  final bool saveFolderCover;

  /// The longest side of that cover in pixels; 0 keeps the original.
  final int folderCoverMaxDimension;

  /// Delete the album and artist folders a deleted song leaves empty, inside
  /// the download and Local Library folders.
  final bool removeEmptyFolders;
  final bool listeningStatisticsEnabled;
  final bool autoConvertDownloads;
  // Re-download a Hi-Res request at LOSSLESS when the file measures as fake.
  final bool redownloadFakeHiRes;
  final String autoConvertFormat; // 'mp3', 'aac'/'alac' (M4A), 'opus', 'flac'
  final String autoConvertBitrate; // '128k', '160k', '192k', '256k', or '320k'
  final int autoConvertMaxBitDepth; // 0 retains the source bit depth.
  final int autoConvertMaxSampleRate; // 0 retains the source sample rate.
  final bool autoConvertSmartDither;
  // Smart Dither uses high-pass TPDF instead of plain TPDF.
  final bool autoConvertSmartDitherHighPass;
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

  /// Hide a Mornye Link device's songs from the Library while it is not
  /// connected: a phone's on the desktop, a computer's on a phone.
  final bool linkHideDisconnectedSongs;

  final bool hasCompletedTutorial;

  final List<String> lyricsProviders;

  /// Take the best-timed lyrics any enabled provider has (word-synced, then
  /// line-synced, then plain) instead of the first provider's lyrics.
  /// [lyricsProviders] order still decides between equals.
  final bool lyricsPreferBestTiming;
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

  /// BCP-47 language for songs already in the target; empty leaves them
  /// untranslated.
  final String lyricsTranslationSecondLanguage;

  /// Optional guidance added to the translation prompt.
  final String lyricsAiInstruction;

  /// Translate lyrics without a translation as they open.
  final bool lyricsAutoTranslate;

  /// Ask the translation for a romanization of the lines written outside
  /// the Latin alphabet that offline romanization cannot give, while
  /// [lyricsRomanize] is on.
  final bool lyricsAiRomanize;

  /// Romanize lyrics written outside the Latin alphabet on the device,
  /// where their script allows it.
  @JsonKey(readValue: readLyricsRomanize)
  final bool lyricsRomanize;

  /// Show a line's romanization as the line, with the original under it.
  final bool lyricsRomanizedMainLine;

  /// Align AI translations and readings to sung words instead of whole lines.
  final bool lyricsAiWordSync;

  /// Where saved lyrics translations go: [lyricsTranslationSaveToSongFile],
  /// the song's own lyrics where they can carry them, or
  /// [lyricsTranslationSaveToMlrc], a `.mlrc` file next to the song.
  @JsonKey(fromJson: lyricsTranslationSaveToFromJson)
  final String lyricsTranslationSaveTo;

  /// Save each lyrics translation once the player shows it.
  final bool lyricsTranslationAutoSave;

  /// Translate the lyrics of each finished download and save them with the
  /// song, so they show offline. Off by default: every download is a
  /// request on the user's API key.
  final bool lyricsTranslateDownloads;

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

  /// Whether the Now Playing screen shows the synced line being sung under
  /// the track title. Off by default; Lyrics settings turns it on.
  final bool playerShowLyricSnippet;

  /// Whether that line shows the song's translation instead of the sung
  /// line. Off by default, so the line reads as sung.
  final bool playerLyricSnippetTranslation;

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
    this.playbackNormalizationBoost = false,
    this.confirmLoudVolume = true,
    this.loudVolumeLevel = 80,
    this.pauseOnMute = true,
    this.headphoneResume = 'off',
    this.gaplessPlayback = true,
    this.autoMix = false,
    this.autoMixDuration = 0,
    this.autoMixEffect = AutoMixEffect.auto,
    this.autoMixSpeed = 1,
    this.autoMixPitch = 0,
    this.autoMixEcho = false,
    this.autoMixLowPass = false,
    this.autoMixMatching = AutoMixMatching.standard,
    this.playbackSpeed = 1,
    this.playbackKeepPitch = true,
    this.playbackPitch = 0,
    this.discordRichPresenceEnabled = false,
    this.usbBitPerfect = false,
    this.usbDirect = false,
    this.usbDsdOverPcm = false,
    this.usbAllowFixedVolume = false,
    this.usbMaxSampleRate = 0,
    this.usbDitherHighPass = false,
    this.dapExclusive = false,
    this.media3Engine = false,
    this.skipSilence = false,
    this.spatialAudio = true,
    this.queueNoDuplicates = false,
    this.queueLocked = false,
    this.exclusiveOutput = false,
    this.exclusiveOutputDevice = '',
    this.autoplay = false,
    this.autoplayPersonalization = true,
    this.autoplayRandomness = 0,
    this.songAnalysis = false,
    this.songAnalysisOnlyWhileCharging = true,
    this.musicHaptics = false,
    this.musicHapticsSensitivity = 0.5,
    this.musicHapticsStrength = 0.5,
    this.playerCoverStyle = '',
    this.playerCoverFade = 'medium',
    this.playerCoverWhole = false,
    this.landscapeLyricsArtwork = false,
    this.autoHideLyricsControls = true,
    this.autoHideLyricsControlsWithAccessibility = false,
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
    this.historySortMode = 'latest',
    this.libraryAlbumSortMode = 'a-z',
    this.libraryArtistShowsSongs = false,
    this.defaultLibraryView = 'last',
    this.libraryQualityLabelMode = AppSettings.libraryQualityLabelBitDepthOnly,
    this.swipeToQueue = true,
    this.librarySongTap = AppSettings.librarySongTapDetails,
    this.askQualityBeforeDownload = true,
    this.enableLogging = false,
    this.useExtensionProviders = true,
    this.downloadFallbackExtensionIds,
    this.searchProvider,
    this.defaultSearchTab = 'all',
    this.searchViewMode = 'list',
    this.homeFeedProvider,
    this.homeShortcuts = const [
      'shuffle',
      'equalizer',
      'listeningStats',
      'networkStorage',
    ],
    this.homeContinueListening = true,
    this.homeRecommendations = true,
    this.homeLayout = const HomeLayout(),
    this.separateSingles = false,
    this.singleFilenameFormat = '{title} - {artist}',
    this.albumFolderStructure = 'artist_album',
    this.showExtensionStore = true,
    this.autoUpdateExtensions = true,
    this.heroAnimationsEnabled = true,
    this.forceBackdropBlur = false,
    this.interfaceScale = 1,
    this.animationSpeed = 1,
    this.extensionVerificationBrowserMode = 'in_app_first',
    this.locale = 'system',
    this.lyricsMode = 'embed',
    this.keepScreenOnLyrics = true,
    this.lockScreenLyrics = false,
    this.lockScreenLyricsKeepTitle = false,
    this.motionArtworkEnabled = true,
    this.saveMotionArtworkFile = false,
    this.saveFolderCover = false,
    this.folderCoverMaxDimension = 0,
    this.removeEmptyFolders = true,
    this.listeningStatisticsEnabled = true,
    this.autoConvertDownloads = false,
    this.redownloadFakeHiRes = false,
    this.autoConvertFormat = 'mp3',
    this.autoConvertBitrate = '320k',
    this.autoConvertMaxBitDepth = 16,
    this.autoConvertMaxSampleRate = 48000,
    this.autoConvertSmartDither = true,
    this.autoConvertSmartDitherHighPass = false,
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
    this.linkHideDisconnectedSongs = true,
    this.hasCompletedTutorial = false,
    this.lyricsProviders = const [
      'apple_music',
      'lrcred',
      'mornye_lyrics',
      'lyricsplus',
      'lrclib',
    ],
    this.lyricsPreferBestTiming = true,
    this.lyricsIncludeTranslationNetease = false,
    this.lyricsIncludeRomanizationNetease = false,
    this.lyricsMultiPersonWordByWord = true,
    this.lyricsAppleElrcWordSync = true,
    this.musixmatchLanguage = '',
    this.lyricsAiProvider = 'openai',
    this.lyricsAiBaseUrl = '',
    this.lyricsAiModel = '',
    this.lyricsTranslationLanguage = '',
    this.lyricsTranslationSecondLanguage = '',
    this.lyricsAiInstruction = '',
    this.lyricsAutoTranslate = false,
    this.lyricsAiRomanize = true,
    this.lyricsRomanize = true,
    this.lyricsRomanizedMainLine = false,
    this.lyricsAiWordSync = false,
    this.lyricsTranslationSaveTo = lyricsTranslationSaveToSongFile,
    this.lyricsTranslationAutoSave = false,
    this.lyricsTranslateDownloads = false,
    this.lastSeenVersion = '',
    this.deduplicateDownloads = true,
    this.allowQualityVariants = false,
    this.saveDownloadHistory = true,
    this.playerMode = 'internal',
    this.playerShowPronunciation = true,
    this.playerShowTranslation = true,
    this.playerShowVolume = true,
    this.playerShowLyricSnippet = false,
    this.playerLyricSnippetTranslation = false,
  });

  @JsonKey(includeFromJson: false, includeToJson: false)
  Map<String, dynamic> get lyricsFetchOptions => {
    'include_translation_netease': lyricsIncludeTranslationNetease,
    'include_romanization_netease': lyricsIncludeRomanizationNetease,
    'multi_person_word_by_word': lyricsMultiPersonWordByWord,
    'apple_elrc_word_sync': lyricsAppleElrcWordSync,
    'musixmatch_language': musixmatchLanguage,
    'prefer_best_timing': lyricsPreferBestTiming,
  };

  /// Whether this app plays the music. With another app chosen, settings
  /// that only shape the built-in player are hidden.
  bool get usesBuiltInPlayer => playerMode == 'internal';

  /// The cover art style the player shows: the one chosen, else the app
  /// style's own, full screen in Material and a card in Mornye.
  String playerCoverStyleFor({required bool mornye}) =>
      playerCoverStyle.isNotEmpty
      ? playerCoverStyle
      : mornye
      ? 'default'
      : 'fullscreen';

  bool shouldAutoHideLyricsControls({required bool accessibleNavigation}) =>
      autoHideLyricsControls &&
      (!accessibleNavigation || autoHideLyricsControlsWithAccessibility);

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
    bool? playbackNormalizationBoost,
    bool? confirmLoudVolume,
    int? loudVolumeLevel,
    bool? pauseOnMute,
    String? headphoneResume,
    bool? gaplessPlayback,
    bool? autoMix,
    int? autoMixDuration,
    AutoMixEffect? autoMixEffect,
    double? autoMixSpeed,
    double? autoMixPitch,
    bool? autoMixEcho,
    bool? autoMixLowPass,
    AutoMixMatching? autoMixMatching,
    double? playbackSpeed,
    bool? playbackKeepPitch,
    double? playbackPitch,
    bool? discordRichPresenceEnabled,
    bool? usbBitPerfect,
    bool? usbDirect,
    bool? usbDsdOverPcm,
    bool? usbAllowFixedVolume,
    int? usbMaxSampleRate,
    bool? usbDitherHighPass,
    bool? dapExclusive,
    bool? media3Engine,
    bool? skipSilence,
    bool? spatialAudio,
    bool? queueNoDuplicates,
    bool? queueLocked,
    bool? exclusiveOutput,
    String? exclusiveOutputDevice,
    bool? autoplay,
    bool? autoplayPersonalization,
    double? autoplayRandomness,
    bool? songAnalysis,
    bool? songAnalysisOnlyWhileCharging,
    bool? musicHaptics,
    double? musicHapticsSensitivity,
    double? musicHapticsStrength,
    String? playerCoverStyle,
    String? playerCoverFade,
    bool? playerCoverWhole,
    bool? landscapeLyricsArtwork,
    bool? autoHideLyricsControls,
    bool? autoHideLyricsControlsWithAccessibility,
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
    String? historySortMode,
    String? libraryAlbumSortMode,
    bool? libraryArtistShowsSongs,
    String? defaultLibraryView,
    String? libraryQualityLabelMode,
    bool? swipeToQueue,
    String? librarySongTap,
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
    List<String>? homeShortcuts,
    bool? homeContinueListening,
    bool? homeRecommendations,
    HomeLayout? homeLayout,
    bool? separateSingles,
    String? singleFilenameFormat,
    String? albumFolderStructure,
    bool? showExtensionStore,
    bool? autoUpdateExtensions,
    bool? heroAnimationsEnabled,
    bool? forceBackdropBlur,
    double? interfaceScale,
    double? animationSpeed,
    String? extensionVerificationBrowserMode,
    String? locale,
    String? lyricsMode,
    bool? keepScreenOnLyrics,
    bool? lockScreenLyrics,
    bool? lockScreenLyricsKeepTitle,
    bool? motionArtworkEnabled,
    bool? saveMotionArtworkFile,
    bool? saveFolderCover,
    int? folderCoverMaxDimension,
    bool? removeEmptyFolders,
    bool? listeningStatisticsEnabled,
    bool? autoConvertDownloads,
    bool? redownloadFakeHiRes,
    String? autoConvertFormat,
    String? autoConvertBitrate,
    int? autoConvertMaxBitDepth,
    int? autoConvertMaxSampleRate,
    bool? autoConvertSmartDither,
    bool? autoConvertSmartDitherHighPass,
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
    bool? linkHideDisconnectedSongs,
    bool? hasCompletedTutorial,
    List<String>? lyricsProviders,
    bool? lyricsPreferBestTiming,
    bool? lyricsIncludeTranslationNetease,
    bool? lyricsIncludeRomanizationNetease,
    bool? lyricsMultiPersonWordByWord,
    bool? lyricsAppleElrcWordSync,
    String? musixmatchLanguage,
    String? lyricsAiProvider,
    String? lyricsAiBaseUrl,
    String? lyricsAiModel,
    String? lyricsTranslationLanguage,
    String? lyricsTranslationSecondLanguage,
    String? lyricsAiInstruction,
    bool? lyricsAutoTranslate,
    bool? lyricsAiRomanize,
    bool? lyricsRomanize,
    bool? lyricsRomanizedMainLine,
    bool? lyricsAiWordSync,
    String? lyricsTranslationSaveTo,
    bool? lyricsTranslationAutoSave,
    bool? lyricsTranslateDownloads,
    String? lastSeenVersion,
    bool? deduplicateDownloads,
    bool? allowQualityVariants,
    bool? saveDownloadHistory,
    String? playerMode,
    bool? playerShowPronunciation,
    bool? playerShowTranslation,
    bool? playerShowVolume,
    bool? playerShowLyricSnippet,
    bool? playerLyricSnippetTranslation,
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
      playbackNormalizationBoost:
          playbackNormalizationBoost ?? this.playbackNormalizationBoost,
      confirmLoudVolume: confirmLoudVolume ?? this.confirmLoudVolume,
      loudVolumeLevel: loudVolumeLevel ?? this.loudVolumeLevel,
      pauseOnMute: pauseOnMute ?? this.pauseOnMute,
      headphoneResume: headphoneResume ?? this.headphoneResume,
      gaplessPlayback: gaplessPlayback ?? this.gaplessPlayback,
      autoMix: autoMix ?? this.autoMix,
      autoMixDuration: autoMixDuration ?? this.autoMixDuration,
      autoMixEffect: autoMixEffect ?? this.autoMixEffect,
      autoMixSpeed: autoMixSpeed ?? this.autoMixSpeed,
      autoMixPitch: autoMixPitch ?? this.autoMixPitch,
      autoMixEcho: autoMixEcho ?? this.autoMixEcho,
      autoMixLowPass: autoMixLowPass ?? this.autoMixLowPass,
      autoMixMatching: autoMixMatching ?? this.autoMixMatching,
      playbackSpeed: playbackSpeed ?? this.playbackSpeed,
      playbackKeepPitch: playbackKeepPitch ?? this.playbackKeepPitch,
      playbackPitch: playbackPitch ?? this.playbackPitch,
      discordRichPresenceEnabled:
          discordRichPresenceEnabled ?? this.discordRichPresenceEnabled,
      usbBitPerfect: usbBitPerfect ?? this.usbBitPerfect,
      usbDirect: usbDirect ?? this.usbDirect,
      usbDsdOverPcm: usbDsdOverPcm ?? this.usbDsdOverPcm,
      usbAllowFixedVolume: usbAllowFixedVolume ?? this.usbAllowFixedVolume,
      usbMaxSampleRate: usbMaxSampleRate ?? this.usbMaxSampleRate,
      usbDitherHighPass: usbDitherHighPass ?? this.usbDitherHighPass,
      dapExclusive: dapExclusive ?? this.dapExclusive,
      media3Engine: media3Engine ?? this.media3Engine,
      skipSilence: skipSilence ?? this.skipSilence,
      spatialAudio: spatialAudio ?? this.spatialAudio,
      queueNoDuplicates: queueNoDuplicates ?? this.queueNoDuplicates,
      queueLocked: queueLocked ?? this.queueLocked,
      exclusiveOutput: exclusiveOutput ?? this.exclusiveOutput,
      exclusiveOutputDevice:
          exclusiveOutputDevice ?? this.exclusiveOutputDevice,
      autoplay: autoplay ?? this.autoplay,
      autoplayPersonalization:
          autoplayPersonalization ?? this.autoplayPersonalization,
      autoplayRandomness: autoplayRandomness ?? this.autoplayRandomness,
      songAnalysis: songAnalysis ?? this.songAnalysis,
      songAnalysisOnlyWhileCharging:
          songAnalysisOnlyWhileCharging ?? this.songAnalysisOnlyWhileCharging,
      musicHaptics: musicHaptics ?? this.musicHaptics,
      musicHapticsSensitivity:
          musicHapticsSensitivity ?? this.musicHapticsSensitivity,
      musicHapticsStrength: musicHapticsStrength ?? this.musicHapticsStrength,
      playerCoverStyle: playerCoverStyle ?? this.playerCoverStyle,
      playerCoverFade: playerCoverFade ?? this.playerCoverFade,
      playerCoverWhole: playerCoverWhole ?? this.playerCoverWhole,
      landscapeLyricsArtwork:
          landscapeLyricsArtwork ?? this.landscapeLyricsArtwork,
      autoHideLyricsControls:
          autoHideLyricsControls ?? this.autoHideLyricsControls,
      autoHideLyricsControlsWithAccessibility:
          autoHideLyricsControlsWithAccessibility ??
          this.autoHideLyricsControlsWithAccessibility,
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
      historySortMode: historySortMode ?? this.historySortMode,
      libraryAlbumSortMode: libraryAlbumSortMode ?? this.libraryAlbumSortMode,
      libraryArtistShowsSongs:
          libraryArtistShowsSongs ?? this.libraryArtistShowsSongs,
      defaultLibraryView: defaultLibraryView ?? this.defaultLibraryView,
      libraryQualityLabelMode:
          libraryQualityLabelMode ?? this.libraryQualityLabelMode,
      swipeToQueue: swipeToQueue ?? this.swipeToQueue,
      librarySongTap: librarySongTap ?? this.librarySongTap,
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
      homeShortcuts: homeShortcuts ?? this.homeShortcuts,
      homeContinueListening:
          homeContinueListening ?? this.homeContinueListening,
      homeRecommendations: homeRecommendations ?? this.homeRecommendations,
      homeLayout: homeLayout ?? this.homeLayout,
      separateSingles: separateSingles ?? this.separateSingles,
      singleFilenameFormat: singleFilenameFormat ?? this.singleFilenameFormat,
      albumFolderStructure: albumFolderStructure ?? this.albumFolderStructure,
      showExtensionStore: showExtensionStore ?? this.showExtensionStore,
      autoUpdateExtensions: autoUpdateExtensions ?? this.autoUpdateExtensions,
      heroAnimationsEnabled:
          heroAnimationsEnabled ?? this.heroAnimationsEnabled,
      forceBackdropBlur: forceBackdropBlur ?? this.forceBackdropBlur,
      interfaceScale: interfaceScale ?? this.interfaceScale,
      animationSpeed: animationSpeed ?? this.animationSpeed,
      extensionVerificationBrowserMode:
          extensionVerificationBrowserMode ??
          this.extensionVerificationBrowserMode,
      locale: locale ?? this.locale,
      lyricsMode: lyricsMode ?? this.lyricsMode,
      keepScreenOnLyrics: keepScreenOnLyrics ?? this.keepScreenOnLyrics,
      lockScreenLyrics: lockScreenLyrics ?? this.lockScreenLyrics,
      lockScreenLyricsKeepTitle:
          lockScreenLyricsKeepTitle ?? this.lockScreenLyricsKeepTitle,
      motionArtworkEnabled: motionArtworkEnabled ?? this.motionArtworkEnabled,
      saveMotionArtworkFile:
          saveMotionArtworkFile ?? this.saveMotionArtworkFile,
      saveFolderCover: saveFolderCover ?? this.saveFolderCover,
      folderCoverMaxDimension:
          folderCoverMaxDimension ?? this.folderCoverMaxDimension,
      removeEmptyFolders: removeEmptyFolders ?? this.removeEmptyFolders,
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
      autoConvertSmartDither:
          autoConvertSmartDither ?? this.autoConvertSmartDither,
      autoConvertSmartDitherHighPass:
          autoConvertSmartDitherHighPass ?? this.autoConvertSmartDitherHighPass,
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
      linkHideDisconnectedSongs:
          linkHideDisconnectedSongs ?? this.linkHideDisconnectedSongs,
      hasCompletedTutorial: hasCompletedTutorial ?? this.hasCompletedTutorial,
      lyricsProviders: lyricsProviders ?? this.lyricsProviders,
      lyricsPreferBestTiming:
          lyricsPreferBestTiming ?? this.lyricsPreferBestTiming,
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
      lyricsTranslationSecondLanguage:
          lyricsTranslationSecondLanguage ??
          this.lyricsTranslationSecondLanguage,
      lyricsAiInstruction: lyricsAiInstruction ?? this.lyricsAiInstruction,
      lyricsAutoTranslate: lyricsAutoTranslate ?? this.lyricsAutoTranslate,
      lyricsAiRomanize: lyricsAiRomanize ?? this.lyricsAiRomanize,
      lyricsRomanize: lyricsRomanize ?? this.lyricsRomanize,
      lyricsRomanizedMainLine:
          lyricsRomanizedMainLine ?? this.lyricsRomanizedMainLine,
      lyricsAiWordSync: lyricsAiWordSync ?? this.lyricsAiWordSync,
      lyricsTranslationSaveTo:
          lyricsTranslationSaveTo ?? this.lyricsTranslationSaveTo,
      lyricsTranslationAutoSave:
          lyricsTranslationAutoSave ?? this.lyricsTranslationAutoSave,
      lyricsTranslateDownloads:
          lyricsTranslateDownloads ?? this.lyricsTranslateDownloads,
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
      playerShowLyricSnippet:
          playerShowLyricSnippet ?? this.playerShowLyricSnippet,
      playerLyricSnippetTranslation:
          playerLyricSnippetTranslation ?? this.playerLyricSnippetTranslation,
    );
  }

  /// Whether Home shows [section]. Continue listening and Recommended for
  /// you keep the switches they had before the layout.
  bool homeShows(HomeSection section) => switch (section) {
    HomeSection.continueListening => homeContinueListening,
    HomeSection.recommended => homeRecommendations,
    _ => homeLayout.shows(section),
  };

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
  Map<String, dynamic> toJson() => {
    ..._$AppSettingsToJson(this),
    // Builds before [headphoneResume] read this switch, so a downgrade or
    // a backup opened by one keeps Always.
    'playOnHeadphonesConnected': headphoneResume == 'always',
  };
}
