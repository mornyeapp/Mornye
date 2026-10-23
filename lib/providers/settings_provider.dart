import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/models/metadata_separators.dart';
import 'package:mornye/models/automix_options.dart';
import 'package:mornye/constants/app_info.dart';
import 'package:mornye/services/platform_bridge.dart';
import 'package:mornye/services/folder_path_template.dart';
import 'package:mornye/services/secure_storage_options.dart';
import 'package:mornye/utils/artist_utils.dart';
import 'package:mornye/utils/audio_format_utils.dart';
import 'package:mornye/utils/audio_quality_badge_policy.dart';
import 'package:mornye/utils/file_access.dart';
import 'package:mornye/utils/logger.dart';

const _settingsKey = 'app_settings';
const _settingsCorruptBackupKey = 'app_settings_corrupt_backup';
const _migrationVersionKey = 'settings_migration_version';
const _currentMigrationVersion = 15;

/// Marked the removed rebrand tour as seen.
const _retiredUpgradeIntroSeenKey = 'upgrade_intro_mornye_seen';
const _legacyDefaultLyricsProviders = ['apple_music', 'lrclib'];
const _spotifyClientSecretKey = 'spotify_client_secret';
const _retiredBuiltInProviderIds = {'deezer', 'qobuz', 'tidal', 'youtube'};
final _log = AppLogger('SettingsProvider');

/// Startup override used to render the correct route/locale on the first
/// frame. The notifier still performs migrations and full validation after it
/// mounts.
final initialSettingsProvider = Provider<AppSettings>(
  (ref) => const AppSettings(),
);

/// Set during bootstrap when the saved Android SAF tree no longer has a valid
/// persisted grant. MainShell consumes this once to block downloads until the
/// user explicitly repairs or changes the destination.
final initialSafAccessLostProvider = Provider<bool>((ref) => false);

bool hasPersistedAppSettings(SharedPreferences prefs) {
  final rawSettings = prefs.getString(_settingsKey);
  return rawSettings != null && rawSettings.isNotEmpty;
}

AppSettings loadBootstrapSettings(SharedPreferences prefs) {
  final rawSettings = prefs.getString(_settingsKey);
  if (rawSettings == null || rawSettings.isEmpty) return const AppSettings();
  try {
    final decoded = jsonDecode(rawSettings);
    if (decoded is! Map) return const AppSettings();
    return AppSettings.fromJson(Map<String, dynamic>.from(decoded));
  } catch (_) {
    return const AppSettings();
  }
}

/// Removes values that are only valid for one OS installation while keeping
/// portable user preferences. This is used when Android restores app data into
/// a fresh package install despite backup being disabled (for example an OEM
/// device-to-device transfer).
AppSettings resetInstallationBoundSettings(AppSettings settings) {
  return settings.copyWith(
    downloadDirectory: '',
    networkDownloadFolder: '',
    networkDownloadLabel: '',
    downloadDirectoryBookmark: '',
    storageMode: 'app',
    downloadTreeUri: '',
    isFirstLaunch: true,
    useAllFilesAccess: false,
    localLibraryEnabled: false,
    localLibraryPath: '',
    localLibraryBookmark: '',
    localLibraryAutoScan: 'off',
    hasCompletedTutorial: false,
  );
}

Future<void> resetRestoredInstallationSettings(SharedPreferences prefs) async {
  final rawSettings = prefs.getString(_settingsKey);
  if (rawSettings == null || rawSettings.isEmpty) return;

  try {
    final decoded = jsonDecode(rawSettings);
    if (decoded is! Map) {
      await prefs.remove(_settingsKey);
      return;
    }
    final restored = AppSettings.fromJson(Map<String, dynamic>.from(decoded));
    final sanitized = resetInstallationBoundSettings(restored);
    await prefs.setString(_settingsKey, jsonEncode(sanitized.toJson()));
  } catch (e) {
    _log.w('Failed to sanitize restored settings; resetting to defaults: $e');
    await prefs.remove(_settingsKey);
  }
}

class SettingsNotifier extends Notifier<AppSettings> {
  SettingsNotifier({Future<SharedPreferences> Function()? preferences})
    : _loadPreferences = preferences ?? SharedPreferences.getInstance;

  static final RegExp _isoRegionPattern = RegExp(r'^[A-Z]{2}$');
  static const Set<String> _searchTabValues = {
    'all',
    'track',
    'artist',
    'album',
    'playlist',
  };
  static const Set<String> _libraryViewValues = {
    'last',
    'all',
    'albums',
    'singles',
    'artists',
    'playlists',
  };
  static const Set<String> _extensionVerificationBrowserModeValues = {
    'external_first',
    'in_app_first',
  };
  static const Set<int> _embeddedCoverMaxDimensionValues = {
    0,
    500,
    1000,
    1500,
    2000,
  };

  final Future<SharedPreferences> Function() _loadPreferences;
  Future<SharedPreferences> get _prefs => _loadPreferences();
  final FlutterSecureStorage _secureStorage = const FlutterSecureStorage(
    aOptions: secureStorageAndroidOptions,
    mOptions: secureStorageMacOsOptions,
  );
  Future<void>? _saveSettingsFuture;
  bool _saveQueued = false;
  String? _pendingSettingsJson;
  Future<void>? _loadSettingsFuture;

  @override
  AppSettings build() {
    unawaited(
      ensureLoaded().catchError((Object error, StackTrace stack) {
        _log.e('Failed to load settings', error, stack);
      }),
    );
    return ref.read(initialSettingsProvider);
  }

  /// Startup and extension actions share loading, including preference migrations.
  Future<void> ensureLoaded() {
    return _loadSettingsFuture ??= _loadSettings().catchError((
      Object error,
      StackTrace stack,
    ) {
      _loadSettingsFuture = null;
      Error.throwWithStackTrace(error, stack);
    });
  }

  Future<void> _loadSettings() async {
    final prefs = await _prefs;
    final rawSettings = prefs.getString(_settingsKey);
    if (rawSettings != null) {
      AppSettings? loaded;
      try {
        final decoded = jsonDecode(rawSettings);
        if (decoded is! Map) {
          throw const FormatException('settings root must be a JSON object');
        }
        loaded = AppSettings.fromJson(Map<String, dynamic>.from(decoded));
      } catch (e, stack) {
        _log.e('Failed to load settings, resetting to defaults: $e', e, stack);
        try {
          await prefs.setString(_settingsCorruptBackupKey, rawSettings);
          await prefs.remove(_settingsKey);
        } catch (backupError) {
          _log.w('Failed to backup corrupt settings: $backupError');
        }
      }

      if (loaded != null) {
        final sanitizedDownloadFallbackExtensionIds =
            _sanitizeDownloadFallbackExtensionIds(
              loaded.downloadFallbackExtensionIds,
            );
        final sanitizedDefaultSearchTab = _normalizeDefaultSearchTab(
          loaded.defaultSearchTab,
        );
        state = loaded.copyWith(
          useExtensionProviders: true,
          downloadFallbackExtensionIds: sanitizedDownloadFallbackExtensionIds,
          clearDownloadFallbackExtensionIds:
              loaded.downloadFallbackExtensionIds != null &&
              sanitizedDownloadFallbackExtensionIds == null,
          defaultSearchTab: sanitizedDefaultSearchTab,
          defaultLibraryView: _normalizeDefaultLibraryView(
            loaded.defaultLibraryView,
          ),
          libraryQualityLabelMode: normalizeLibraryQualityLabelMode(
            loaded.libraryQualityLabelMode,
          ),
          autoConvertFormat: normalizeAutoConvertFormat(
            loaded.autoConvertFormat,
          ),
          autoConvertBitrate: normalizeAutoConvertBitrate(
            loaded.autoConvertBitrate,
          ),
          embeddedCoverMaxDimension: _normalizeEmbeddedCoverMaxDimension(
            loaded.embeddedCoverMaxDimension,
          ),
          defaultService: loaded.defaultService,
          searchProvider: loaded.searchProvider,
          extensionVerificationBrowserMode:
              _normalizeExtensionVerificationBrowserMode(
                loaded.extensionVerificationBrowserMode,
              ),
        );

        await _runMigrations(prefs);
        await _normalizeIosDownloadDirectoryIfNeeded();
        await _normalizeSongLinkRegionIfNeeded();
      }
    }

    await _cleanupRetiredSpotifySettings();

    LogBuffer.loggingEnabled = state.enableLogging;

    await syncLyricsSettingsToBackend();
    await _syncNetworkCompatibilitySettingsToBackend();
    await _syncExtensionFallbackSettingsToBackend();
  }

  void _syncLyricsSettingsToBackend() {
    unawaited(syncLyricsSettingsToBackend());
  }

  Future<void> syncLyricsSettingsToBackend({AppSettings? settings}) async {
    final snapshot = settings ?? state;
    if (!PlatformBridge.supportsCoreBackend) return;

    try {
      await PlatformBridge.setLyricsProviders(snapshot.lyricsProviders);
    } catch (e) {
      _log.w('Failed to sync lyrics providers to backend: $e');
    }

    try {
      await PlatformBridge.setLyricsFetchOptions(snapshot.lyricsFetchOptions);
    } catch (e) {
      _log.w('Failed to sync lyrics fetch options to backend: $e');
    }
  }

  Future<void> _syncNetworkCompatibilitySettingsToBackend() async {
    if (!PlatformBridge.supportsCoreBackend) return;

    final compatibilityMode = state.networkCompatibilityMode;
    await PlatformBridge.setNetworkCompatibilityOptions(
      allowHttp: compatibilityMode,
      insecureTls: false,
    ).catchError((Object e) {
      _log.w('Failed to sync network compatibility options to backend: $e');
    });

    await PlatformBridge.setAllowPrivateNetwork(
      state.allowLocalNetwork,
    ).catchError((Object e) {
      _log.w('Failed to sync allow local network option to backend: $e');
    });
  }

  Future<void> _syncExtensionFallbackSettingsToBackend() async {
    if (!PlatformBridge.supportsCoreBackend) return;

    await PlatformBridge.setDownloadFallbackExtensionIds(
      state.downloadFallbackExtensionIds,
    ).catchError((Object e) {
      _log.w('Failed to sync extension fallback settings to backend: $e');
    });
  }

  Future<void> _runMigrations(SharedPreferences prefs) async {
    final lastMigration = prefs.getInt(_migrationVersionKey) ?? 0;

    if (lastMigration < _currentMigrationVersion) {
      if (state.downloadTreeUri.isNotEmpty && state.storageMode != 'saf') {
        state = state.copyWith(storageMode: 'saf');
      }
      // Migration 2: existing users who already completed setup should skip tutorial
      if (!state.isFirstLaunch && !state.hasCompletedTutorial) {
        state = state.copyWith(hasCompletedTutorial: true);
      }
      if (state.lyricsProviders.contains('spotify_api')) {
        final updatedProviders = state.lyricsProviders
            .where((provider) => provider != 'spotify_api')
            .toList();
        state = state.copyWith(
          lyricsProviders: updatedProviders.isEmpty
              ? const AppSettings().lyricsProviders
              : updatedProviders,
        );
      }
      state = state.copyWith(lastSeenVersion: AppInfo.version);
      // Migration 7/11: retired built-in services are now reconciled after
      // extensions load so manifest-declared replacements can adopt old prefs.
      if (!state.useExtensionProviders) {
        state = state.copyWith(useExtensionProviders: true);
      }
      // Migration 12: Library badges return to bit depth ("24-bit") by
      // default; the bitrate default was persisted for every existing user.
      if (lastMigration < 12 &&
          state.libraryQualityLabelMode ==
              AppSettings.libraryQualityLabelBitrate) {
        state = state.copyWith(
          libraryQualityLabelMode: AppSettings.libraryQualityLabelBitDepthOnly,
        );
      }
      // Migration 13: Zarz-LRC left Apple Music's Paxsenix
      // fallback chain. Untouched defaults move to the new defaults; a custom
      // order keeps the former fallback right after Apple Music.
      if (lastMigration < 13) {
        final providers = state.lyricsProviders;
        if (listEquals(providers, _legacyDefaultLyricsProviders)) {
          state = state.copyWith(
            lyricsProviders: const AppSettings().lyricsProviders,
          );
        } else if (providers.contains('apple_music') &&
            !providers.contains('mornye_lyrics')) {
          state = state.copyWith(
            lyricsProviders: [
              for (final provider in providers) ...[
                provider,
                if (provider == 'apple_music') 'mornye_lyrics',
              ],
            ],
          );
        }
      }
      // Migration 14 persists the legacy lyrics provider alias normalized by
      // AppSettings.fromJson without changing the user's provider order.
      // Migration 15: the rebrand tour is gone, and so is its flag.
      if (lastMigration < 15) {
        await prefs.remove(_retiredUpgradeIntroSeenKey);
      }
      await prefs.setInt(_migrationVersionKey, _currentMigrationVersion);
      await _saveSettings();
    }
  }

  Future<void> _saveSettings() {
    _pendingSettingsJson = jsonEncode(state.toJson());

    final activeSave = _saveSettingsFuture;
    if (activeSave != null) {
      _saveQueued = true;
      return activeSave;
    }

    final saved = Completer<void>();
    _saveSettingsFuture = saved.future;
    unawaited(_drainSettingsSave(saved));
    return saved.future;
  }

  Future<void> _drainSettingsSave(Completer<void> saved) async {
    try {
      final prefs = await _prefs;
      do {
        final jsonToWrite = _pendingSettingsJson;
        _saveQueued = false;
        if (jsonToWrite != null) {
          await prefs.setString(_settingsKey, jsonToWrite);
        }
      } while (_saveQueued);
    } catch (e) {
      _log.e('Failed to save settings: $e');
    } finally {
      _saveSettingsFuture = null;
      saved.complete();
    }
  }

  /// Restores settings from a backup payload (the map produced by
  /// [AppSettings.toJson]). Device-specific storage location fields
  /// (download directory and SAF tree URI) are intentionally preserved from the
  /// current device, because a SAF tree URI from another phone is not valid
  /// here and would break downloads.
  Future<void> restoreFromBackup(Map<String, dynamic> json) async {
    final current = state;
    AppSettings restored;
    try {
      restored = AppSettings.fromJson(Map<String, dynamic>.from(json));
    } catch (e, stack) {
      _log.e('Failed to parse settings from backup: $e', e, stack);
      rethrow;
    }

    state = restored.copyWith(
      // Always keep extension providers enabled (matches _loadSettings).
      useExtensionProviders: true,
      // Preserve this device's storage location; the backup's values point at
      // the original device and would not resolve here.
      downloadDirectory: current.downloadDirectory,
      networkDownloadFolder: current.networkDownloadFolder,
      networkDownloadLabel: current.networkDownloadLabel,
      downloadDirectoryBookmark: current.downloadDirectoryBookmark,
      storageMode: current.storageMode,
      downloadTreeUri: current.downloadTreeUri,
      embeddedCoverMaxDimension: _normalizeEmbeddedCoverMaxDimension(
        restored.embeddedCoverMaxDimension,
      ),
    );

    await _saveSettings();

    LogBuffer.loggingEnabled = state.enableLogging;
    _syncLyricsSettingsToBackend();
    await _syncNetworkCompatibilitySettingsToBackend();
    await _syncExtensionFallbackSettingsToBackend();
  }

  Future<void> _normalizeIosDownloadDirectoryIfNeeded() async {
    if (!Platform.isIOS) return;

    // A security-scoped bookmark is the source of truth for folders picked
    // from Files: its stored path may legitimately point outside the app
    // container, and the download flow re-resolves the real path from the
    // bookmark. "Fixing" the path here would also drop the bookmark and
    // silently revert the user's chosen folder.
    if (state.downloadDirectoryBookmark.isNotEmpty) return;

    final currentDir = state.downloadDirectory.trim();
    if (currentDir.isEmpty) return;

    final normalizedDir = await validateOrFixIosPath(currentDir);
    if (normalizedDir == currentDir) return;

    _log.i('Normalized iOS download directory: $currentDir -> $normalizedDir');
    state = state.copyWith(
      downloadDirectory: normalizedDir,
      downloadDirectoryBookmark: '',
    );
    await _saveSettings();
  }

  String _normalizeSongLinkRegion(String region) {
    final normalized = region.trim().toUpperCase();
    if (_isoRegionPattern.hasMatch(normalized)) return normalized;
    return 'US';
  }

  String _normalizeDefaultSearchTab(String value) {
    final normalized = value.trim().toLowerCase();
    if (_searchTabValues.contains(normalized)) return normalized;
    return 'all';
  }

  String _normalizeDefaultLibraryView(String value) {
    final normalized = value.trim().toLowerCase();
    if (_libraryViewValues.contains(normalized)) return normalized;
    return 'last';
  }

  String _normalizeExtensionVerificationBrowserMode(String value) {
    final normalized = value.trim().toLowerCase();
    if (_extensionVerificationBrowserModeValues.contains(normalized)) {
      return normalized;
    }
    return 'in_app_first';
  }

  int _normalizeEmbeddedCoverMaxDimension(int value) {
    return _embeddedCoverMaxDimensionValues.contains(value) ? value : 0;
  }

  String? _sanitizeRetiredBuiltInProviderId(String? providerId) {
    final normalized = providerId?.trim().toLowerCase();
    if (normalized == null || normalized.isEmpty) return providerId;
    return _retiredBuiltInProviderIds.contains(normalized) ? null : providerId;
  }

  Future<void> _normalizeSongLinkRegionIfNeeded() async {
    final normalized = _normalizeSongLinkRegion(state.songLinkRegion);
    if (normalized == state.songLinkRegion) return;
    state = state.copyWith(songLinkRegion: normalized);
    await _saveSettings();
  }

  List<String>? _sanitizeDownloadFallbackExtensionIds(List<String>? ids) {
    if (ids == null) {
      return null;
    }

    final result = <String>[];
    for (final id in ids) {
      final normalized = id.trim();
      if (normalized.isEmpty || result.contains(normalized)) {
        continue;
      }
      result.add(normalized);
    }
    return result;
  }

  Future<void> _cleanupRetiredSpotifySettings() async {
    final storedSecret = await _secureStorage.read(
      key: _spotifyClientSecretKey,
    );
    if (storedSecret != null && storedSecret.isNotEmpty) {
      await _secureStorage.delete(key: _spotifyClientSecretKey);
    }
  }

  void setDefaultService(String service) {
    state = state.copyWith(
      defaultService: _sanitizeRetiredBuiltInProviderId(service) ?? '',
    );
    _saveSettings();
  }

  void setAudioQuality(String quality) {
    state = state.copyWith(audioQuality: quality);
    _saveSettings();
  }

  void setFilenameFormat(String format) {
    state = state.copyWith(filenameFormat: format);
    _saveSettings();
  }

  void setSingleFilenameFormat(String format) {
    state = state.copyWith(singleFilenameFormat: format);
    _saveSettings();
  }

  void setDownloadDirectory(String directory, {String? iosBookmark}) {
    state = state.copyWith(
      networkDownloadFolder: '',
      networkDownloadLabel: '',
      downloadDirectory: directory,
      downloadDirectoryBookmark: iosBookmark ?? '',
    );
    _saveSettings();
  }

  void setStorageMode(String mode) {
    final normalized = mode == 'saf' ? 'saf' : 'app';
    state = state.copyWith(storageMode: normalized);
    _saveSettings();
  }

  Future<void> setNetworkDownloadFolder(String source, String label) async {
    state = state.copyWith(
      networkDownloadFolder: source,
      networkDownloadLabel: label,
    );
    await _saveSettings();
  }

  /// Atomically leaves SAF and persists a writable app-managed destination.
  ///
  /// Keeping these fields in one update avoids an intermediate saved state
  /// where app-folder mode still points at the SAF display name, or where an
  /// invalid tree URI can switch the mode back to SAF.
  Future<void> useAppFolderStorage(String directory) async {
    state = state.copyWith(
      storageMode: 'app',
      downloadDirectory: directory,
      downloadDirectoryBookmark: '',
      downloadTreeUri: '',
    );
    await _saveSettings();
  }

  void setDownloadTreeUri(String uri, {String? displayName}) {
    final nextDisplay = displayName ?? state.downloadDirectory;
    state = state.copyWith(
      networkDownloadFolder: '',
      networkDownloadLabel: '',
      downloadTreeUri: uri,
      storageMode: uri.isNotEmpty ? 'saf' : state.storageMode,
      downloadDirectory: nextDisplay,
      downloadDirectoryBookmark: uri.isNotEmpty
          ? ''
          : state.downloadDirectoryBookmark,
    );
    _saveSettings();
  }

  void setAutoFallback(bool enabled) {
    state = state.copyWith(autoFallback: enabled);
    _saveSettings();
  }

  void setEmbedLyrics(bool enabled) {
    state = state.copyWith(embedLyrics: enabled);
    _saveSettings();
  }

  void setEmbedReplayGain(bool enabled) {
    state = state.copyWith(embedReplayGain: enabled);
    _saveSettings();
  }

  void setPlaybackNormalization(bool enabled) {
    state = state.copyWith(playbackNormalization: enabled);
    _saveSettings();
  }

  void setPlaybackNormalizationPreamp(double db) {
    state = state.copyWith(
      playbackNormalizationPreamp: playbackNormalizationPreampFromJson(db),
    );
    _saveSettings();
  }

  void setPlaybackNormalizationMode(String mode) {
    state = state.copyWith(
      playbackNormalizationMode: playbackNormalizationModeFromJson(mode),
    );
    _saveSettings();
  }

  void setPauseOnMute(bool enabled) {
    state = state.copyWith(pauseOnMute: enabled);
    _saveSettings();
  }

  void setPlayOnHeadphonesConnected(bool enabled) {
    state = state.copyWith(playOnHeadphonesConnected: enabled);
    _saveSettings();
  }

  void setAutoMix(bool enabled) {
    state = state.copyWith(autoMix: enabled);
    _saveSettings();
  }

  void setAutoMixDuration(int seconds) {
    state = state.copyWith(autoMixDuration: autoMixDurationFromJson(seconds));
    _saveSettings();
  }

  void setAutoMixEffect(AutoMixEffect effect) {
    state = state.copyWith(
      autoMixEffect: effect,
      autoMixPitch: effect == AutoMixEffect.pitch && state.autoMixPitch == 0
          ? 2
          : state.autoMixPitch,
    );
    _saveSettings();
  }

  void setAutoMixSpeed(double speed) {
    state = state.copyWith(autoMixSpeed: autoMixSpeedFromJson(speed));
    _saveSettings();
  }

  void setAutoMixPitch(double semitones) {
    state = state.copyWith(autoMixPitch: autoMixPitchFromJson(semitones));
    _saveSettings();
  }

  void setAutoMixEcho(bool enabled) {
    state = state.copyWith(autoMixEcho: enabled);
    _saveSettings();
  }

  void setAutoMixLowPass(bool enabled) {
    state = state.copyWith(autoMixLowPass: enabled);
    _saveSettings();
  }

  void setDiscordRichPresenceEnabled(bool enabled) {
    state = state.copyWith(discordRichPresenceEnabled: enabled);
    _saveSettings();
  }

  void setAutoplay(bool enabled) {
    state = state.copyWith(autoplay: enabled);
    _saveSettings();
  }

  void setAutoplayPersonalization(bool enabled) {
    state = state.copyWith(autoplayPersonalization: enabled);
    _saveSettings();
  }

  void setMusicHaptics(bool enabled) {
    state = state.copyWith(musicHaptics: enabled);
    _saveSettings();
  }

  void setMusicHapticsSensitivity(double value) {
    state = state.copyWith(
      musicHapticsSensitivity: musicHapticsLevelFromJson(value),
    );
    _saveSettings();
  }

  void setMusicHapticsStrength(double value) {
    state = state.copyWith(
      musicHapticsStrength: musicHapticsLevelFromJson(value),
    );
    _saveSettings();
  }

  void setPlayerCoverStyle(String style) {
    state = state.copyWith(playerCoverStyle: playerCoverStyleFromJson(style));
    _saveSettings();
  }

  void setUsbBitPerfect(bool enabled) {
    state = state.copyWith(usbBitPerfect: enabled);
    _saveSettings();
  }

  void setUsbDirect(bool enabled) {
    state = state.copyWith(
      usbDirect: enabled,
      dapExclusive: enabled ? false : null,
    );
    _saveSettings();
  }

  void setUsbDsdOverPcm(bool enabled) {
    state = state.copyWith(usbDsdOverPcm: enabled);
    _saveSettings();
  }

  void setUsbAllowFixedVolume(bool enabled) {
    state = state.copyWith(usbAllowFixedVolume: enabled);
    _saveSettings();
  }

  void setDapExclusive(bool enabled) {
    state = state.copyWith(
      dapExclusive: enabled,
      usbDirect: enabled ? false : null,
    );
    _saveSettings();
  }

  void setEmbedMetadata(bool enabled) {
    state = state.copyWith(embedMetadata: enabled);
    _saveSettings();
  }

  void setEmbeddedCoverMaxDimension(int maxDimension) {
    state = state.copyWith(
      embeddedCoverMaxDimension: _normalizeEmbeddedCoverMaxDimension(
        maxDimension,
      ),
    );
    _saveSettings();
  }

  void setArtistTagMode(String mode) {
    if (artistTagModes.contains(mode)) {
      state = state.copyWith(artistTagMode: mode);
      _saveSettings();
    }
  }

  void setMetadataSeparator(String field, String separator) {
    if (!MetadataSeparators.fields.contains(field) ||
        MetadataSeparators.validSeparator(separator) != separator) {
      return;
    }
    state = state.copyWith(
      metadataSeparators: state.metadataSeparators.withField(field, separator),
    );
    _saveSettings();
  }

  void setKeepScreenOnLyrics(bool enabled) {
    state = state.copyWith(keepScreenOnLyrics: enabled);
    _saveSettings();
  }

  void setMotionArtworkEnabled(bool enabled) {
    state = state.copyWith(motionArtworkEnabled: enabled);
    _saveSettings();
  }

  void setListeningStatisticsEnabled(bool enabled) {
    state = state.copyWith(listeningStatisticsEnabled: enabled);
    _saveSettings();
  }

  void setLyricsMode(String mode) {
    if (mode == 'embed' || mode == 'external' || mode == 'both') {
      state = state.copyWith(lyricsMode: mode);
      _saveSettings();
    }
  }

  void setLyricsProviders(List<String> providers) {
    state = state.copyWith(lyricsProviders: providers);
    _saveSettings();
    _syncLyricsSettingsToBackend();
  }

  void setLyricsIncludeTranslationNetease(bool enabled) {
    state = state.copyWith(lyricsIncludeTranslationNetease: enabled);
    _saveSettings();
    _syncLyricsSettingsToBackend();
  }

  void setLyricsIncludeRomanizationNetease(bool enabled) {
    state = state.copyWith(lyricsIncludeRomanizationNetease: enabled);
    _saveSettings();
    _syncLyricsSettingsToBackend();
  }

  void setLyricsMultiPersonWordByWord(bool enabled) {
    state = state.copyWith(lyricsMultiPersonWordByWord: enabled);
    _saveSettings();
    _syncLyricsSettingsToBackend();
  }

  void setLyricsAppleElrcWordSync(bool enabled) {
    state = state.copyWith(lyricsAppleElrcWordSync: enabled);
    _saveSettings();
    _syncLyricsSettingsToBackend();
  }

  void setMusixmatchLanguage(String languageCode) {
    state = state.copyWith(
      musixmatchLanguage: languageCode.trim().toLowerCase(),
    );
    _saveSettings();
    _syncLyricsSettingsToBackend();
  }

  Future<void> setFirstLaunchComplete() async {
    // The router leaves setup as soon as this flag changes. Persist the final
    // folder settings first so a restart cannot send the user back to setup.
    await ensureLoaded();
    final prefs = await _prefs;
    while (_saveSettingsFuture != null) {
      await _saveSettingsFuture;
    }
    final saved = Completer<void>();
    _saveSettingsFuture = saved.future;
    try {
      do {
        _saveQueued = false;
        final completed = state.copyWith(isFirstLaunch: false);
        if (!await prefs.setString(
          _settingsKey,
          jsonEncode(completed.toJson()),
        )) {
          throw StateError('Could not save completed setup');
        }
        // Include settings changed during the write before publishing the flag.
        if (!_saveQueued && ref.mounted) state = completed;
      } while (_saveQueued);
    } finally {
      _saveSettingsFuture = null;
      saved.complete();
    }
  }

  void setCheckForUpdates(bool enabled) {
    state = state.copyWith(checkForUpdates: enabled);
    _saveSettings();
  }

  void setUpdateChannel(String channel) {
    state = state.copyWith(updateChannel: channel);
    _saveSettings();
  }

  void setHasSearchedBefore() {
    if (!state.hasSearchedBefore) {
      state = state.copyWith(hasSearchedBefore: true);
      _saveSettings();
    }
  }

  void setFolderOrganization(String organization) {
    state = state.copyWith(folderOrganization: organization);
    _saveSettings();
  }

  void setFolderPathTemplate(String template) {
    if (!FolderPathTemplate.isValid(template)) return;
    state = state.copyWith(
      folderPathTemplate: template.trim(),
      folderOrganization: 'custom',
      separateSingles: false,
    );
    _saveSettings();
  }

  void setCreatePlaylistFolder(bool enabled) {
    state = state.copyWith(createPlaylistFolder: enabled);
    _saveSettings();
  }

  void setUseAlbumArtistForFolders(bool enabled) {
    state = state.copyWith(useAlbumArtistForFolders: enabled);
    _saveSettings();
  }

  void setUsePrimaryArtistOnly(bool enabled) {
    state = state.copyWith(usePrimaryArtistOnly: enabled);
    _saveSettings();
  }

  void setFilterContributingArtistsInAlbumArtist(bool enabled) {
    state = state.copyWith(filterContributingArtistsInAlbumArtist: enabled);
    _saveSettings();
  }

  void setHistoryViewMode(String mode) {
    state = state.copyWith(historyViewMode: mode);
    _saveSettings();
  }

  void setHistoryFilterMode(String mode) {
    state = state.copyWith(historyFilterMode: mode);
    _saveSettings();
  }

  void setAskQualityBeforeDownload(bool enabled) {
    state = state.copyWith(askQualityBeforeDownload: enabled);
    _saveSettings();
  }

  void setSearchProvider(String? provider) {
    final sanitized = _sanitizeRetiredBuiltInProviderId(provider);
    if (sanitized == null || sanitized.isEmpty) {
      state = state.copyWith(clearSearchProvider: true);
    } else {
      state = state.copyWith(searchProvider: sanitized);
    }
    _saveSettings();
  }

  void setDefaultSearchTab(String tab) {
    state = state.copyWith(defaultSearchTab: _normalizeDefaultSearchTab(tab));
    _saveSettings();
  }

  void setDefaultLibraryView(String view) {
    state = state.copyWith(
      defaultLibraryView: _normalizeDefaultLibraryView(view),
    );
    _saveSettings();
  }

  void setLibraryQualityLabelMode(String mode) {
    state = state.copyWith(
      libraryQualityLabelMode: normalizeLibraryQualityLabelMode(mode),
    );
    _saveSettings();
  }

  void setHomeFeedProvider(String? provider) {
    if (provider == null || provider.isEmpty) {
      state = state.copyWith(clearHomeFeedProvider: true);
    } else {
      state = state.copyWith(homeFeedProvider: provider);
    }
    _saveSettings();
  }

  void setEnableLogging(bool enabled) {
    state = state.copyWith(enableLogging: enabled);
    _saveSettings();
    LogBuffer.loggingEnabled = enabled;
  }

  void setUseExtensionProviders(bool enabled) {
    state = state.copyWith(useExtensionProviders: true);
    _saveSettings();
  }

  void setDownloadFallbackExtensionIds(List<String>? extensionIds) {
    final sanitized = _sanitizeDownloadFallbackExtensionIds(extensionIds);
    state = state.copyWith(
      downloadFallbackExtensionIds: sanitized,
      clearDownloadFallbackExtensionIds:
          extensionIds == null && state.downloadFallbackExtensionIds != null,
    );
    _saveSettings();
    unawaited(_syncExtensionFallbackSettingsToBackend());
  }

  void setSeparateSingles(bool enabled) {
    state = state.copyWith(separateSingles: enabled);
    _saveSettings();
  }

  void setAlbumFolderStructure(String structure) {
    state = state.copyWith(albumFolderStructure: structure);
    _saveSettings();
  }

  void setShowExtensionStore(bool enabled) {
    state = state.copyWith(showExtensionStore: enabled);
    _saveSettings();
  }

  void setHeroAnimationsEnabled(bool enabled) {
    state = state.copyWith(heroAnimationsEnabled: enabled);
    _saveSettings();
  }

  void setForceBackdropBlur(bool enabled) {
    state = state.copyWith(forceBackdropBlur: enabled);
    _saveSettings();
  }

  void setExtensionVerificationBrowserMode(String mode) {
    state = state.copyWith(
      extensionVerificationBrowserMode:
          _normalizeExtensionVerificationBrowserMode(mode),
    );
    _saveSettings();
  }

  void setLocale(String locale) {
    state = state.copyWith(locale: locale);
    _saveSettings();
  }

  void setAutoConvertDownloads(bool enabled) {
    state = state.copyWith(autoConvertDownloads: enabled);
    _saveSettings();
  }

  void setRedownloadFakeHiRes(bool enabled) {
    state = state.copyWith(redownloadFakeHiRes: enabled);
    _saveSettings();
  }

  void setAutoConvertFormat(String format) {
    state = state.copyWith(
      autoConvertFormat: normalizeAutoConvertFormat(format),
    );
    _saveSettings();
  }

  void setAutoConvertBitrate(String bitrate) {
    state = state.copyWith(
      autoConvertBitrate: normalizeAutoConvertBitrate(bitrate),
    );
    _saveSettings();
  }

  void setUseAllFilesAccess(bool enabled) {
    state = state.copyWith(useAllFilesAccess: enabled);
    _saveSettings();
  }

  void setAutoExportFailedDownloads(bool enabled) {
    state = state.copyWith(autoExportFailedDownloads: enabled);
    _saveSettings();
  }

  void setDownloadNetworkMode(String mode) {
    state = state.copyWith(downloadNetworkMode: mode);
    _saveSettings();
  }

  void setConcurrentDownloads(int count) {
    state = state.copyWith(concurrentDownloads: count.clamp(1, 3));
    _saveSettings();
  }

  void setNetworkCompatibilityMode(bool enabled) {
    state = state.copyWith(networkCompatibilityMode: enabled);
    _saveSettings();
    unawaited(_syncNetworkCompatibilitySettingsToBackend());
  }

  void setAllowLocalNetwork(bool enabled) {
    state = state.copyWith(allowLocalNetwork: enabled);
    _saveSettings();
    unawaited(_syncNetworkCompatibilitySettingsToBackend());
  }

  void setSongLinkRegion(String region) {
    final normalized = _normalizeSongLinkRegion(region);
    state = state.copyWith(songLinkRegion: normalized);
    _saveSettings();
  }

  void setNativeDownloadWorkerEnabled(bool enabled) {
    state = state.copyWith(nativeDownloadWorkerEnabled: enabled);
    _saveSettings();
  }

  void setLocalLibraryEnabled(bool enabled) {
    state = state.copyWith(localLibraryEnabled: enabled);
    _saveSettings();
  }

  void setLocalLibraryPathAndBookmark(String path, String bookmark) {
    state = state.copyWith(
      localLibraryPath: path,
      localLibraryBookmark: bookmark,
    );
    _saveSettings();
  }

  void setLocalLibraryShowDuplicates(bool show) {
    state = state.copyWith(localLibraryShowDuplicates: show);
    _saveSettings();
  }

  void setLocalLibraryAutoScan(String mode) {
    state = state.copyWith(localLibraryAutoScan: mode);
    _saveSettings();
  }

  void setTutorialComplete() {
    state = state.copyWith(hasCompletedTutorial: true);
    _saveSettings();
  }

  void setDeduplicateDownloads(bool enabled) {
    state = state.copyWith(deduplicateDownloads: enabled);
    _saveSettings();
  }

  void setAllowQualityVariants(bool enabled) {
    state = state.copyWith(allowQualityVariants: enabled);
    _saveSettings();
  }

  void setSaveDownloadHistory(bool enabled) {
    state = state.copyWith(saveDownloadHistory: enabled);
    _saveSettings();
  }

  void setPlayerMode(String mode) {
    final normalized = mode == 'internal' ? 'internal' : 'external';
    state = state.copyWith(playerMode: normalized);
    _saveSettings();
  }

  void setPlayerShowPronunciation(bool visible) {
    state = state.copyWith(playerShowPronunciation: visible);
    _saveSettings();
  }

  void setPlayerShowTranslation(bool visible) {
    state = state.copyWith(playerShowTranslation: visible);
    _saveSettings();
  }
}

final settingsProvider = NotifierProvider<SettingsNotifier, AppSettings>(
  SettingsNotifier.new,
);
