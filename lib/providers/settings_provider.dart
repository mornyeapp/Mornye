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
    'folders',
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

  Future<void> _commit(AppSettings next) {
    state = next;
    return _saveSettings();
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
    await _commit(state.copyWith(songLinkRegion: normalized));
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
    try {
      final storedSecret = await _secureStorage.read(
        key: _spotifyClientSecretKey,
      );
      if (storedSecret != null && storedSecret.isNotEmpty) {
        await _secureStorage.delete(key: _spotifyClientSecretKey);
      }
    } catch (e) {
      // The retired secret is optional; active credentials share this vault.
      _log.w(
        'Could not clean up retired credentials; continuing settings load: $e',
      );
    }
  }

  void setDefaultService(String service) => _commit(
    state.copyWith(
      defaultService: _sanitizeRetiredBuiltInProviderId(service) ?? '',
    ),
  );

  void setAudioQuality(String quality) =>
      _commit(state.copyWith(audioQuality: quality));

  void setFilenameFormat(String format) =>
      _commit(state.copyWith(filenameFormat: format));

  void setSingleFilenameFormat(String format) =>
      _commit(state.copyWith(singleFilenameFormat: format));

  void setDownloadDirectory(String directory, {String? iosBookmark}) => _commit(
    state.copyWith(
      networkDownloadFolder: '',
      networkDownloadLabel: '',
      downloadDirectory: directory,
      downloadDirectoryBookmark: iosBookmark ?? '',
    ),
  );

  void setStorageMode(String mode) =>
      _commit(state.copyWith(storageMode: mode == 'saf' ? 'saf' : 'app'));

  Future<void> setNetworkDownloadFolder(String source, String label) async {
    await _commit(
      state.copyWith(
        networkDownloadFolder: source,
        networkDownloadLabel: label,
      ),
    );
  }

  /// Atomically leaves SAF and persists a writable app-managed destination.
  ///
  /// Keeping these fields in one update avoids an intermediate saved state
  /// where app-folder mode still points at the SAF display name, or where an
  /// invalid tree URI can switch the mode back to SAF.
  Future<void> useAppFolderStorage(String directory) async {
    await _commit(
      state.copyWith(
        storageMode: 'app',
        downloadDirectory: directory,
        downloadDirectoryBookmark: '',
        downloadTreeUri: '',
      ),
    );
  }

  void setDownloadTreeUri(String uri, {String? displayName}) => _commit(
    state.copyWith(
      networkDownloadFolder: '',
      networkDownloadLabel: '',
      downloadTreeUri: uri,
      storageMode: uri.isNotEmpty ? 'saf' : state.storageMode,
      downloadDirectory: displayName ?? state.downloadDirectory,
      downloadDirectoryBookmark: uri.isNotEmpty
          ? ''
          : state.downloadDirectoryBookmark,
    ),
  );

  void setAutoFallback(bool enabled) =>
      _commit(state.copyWith(autoFallback: enabled));

  void setEmbedLyrics(bool enabled) =>
      _commit(state.copyWith(embedLyrics: enabled));

  void setEmbedReplayGain(bool enabled) =>
      _commit(state.copyWith(embedReplayGain: enabled));

  void setPlaybackNormalization(bool enabled) =>
      _commit(state.copyWith(playbackNormalization: enabled));

  void setPlaybackNormalizationPreamp(double db) => _commit(
    state.copyWith(
      playbackNormalizationPreamp: playbackNormalizationPreampFromJson(db),
    ),
  );

  void setPlaybackNormalizationMode(String mode) => _commit(
    state.copyWith(
      playbackNormalizationMode: playbackNormalizationModeFromJson(mode),
    ),
  );

  void setPauseOnMute(bool enabled) =>
      _commit(state.copyWith(pauseOnMute: enabled));

  void setPlayOnHeadphonesConnected(bool enabled) =>
      _commit(state.copyWith(playOnHeadphonesConnected: enabled));

  void setGaplessPlayback(bool enabled) =>
      _commit(state.copyWith(gaplessPlayback: enabled));

  void setAutoMix(bool enabled) => _commit(state.copyWith(autoMix: enabled));

  void setAutoMixDuration(int seconds) => _commit(
    state.copyWith(autoMixDuration: autoMixDurationFromJson(seconds)),
  );

  void setAutoMixEffect(AutoMixEffect effect) => _commit(
    state.copyWith(
      autoMixEffect: effect,
      autoMixPitch: effect == AutoMixEffect.pitch && state.autoMixPitch == 0
          ? 2
          : state.autoMixPitch,
    ),
  );

  void setAutoMixSpeed(double speed) =>
      _commit(state.copyWith(autoMixSpeed: autoMixSpeedFromJson(speed)));

  void setAutoMixPitch(double semitones) =>
      _commit(state.copyWith(autoMixPitch: autoMixPitchFromJson(semitones)));

  void setAutoMixEcho(bool enabled) =>
      _commit(state.copyWith(autoMixEcho: enabled));

  void setAutoMixLowPass(bool enabled) =>
      _commit(state.copyWith(autoMixLowPass: enabled));

  void setDiscordRichPresenceEnabled(bool enabled) =>
      _commit(state.copyWith(discordRichPresenceEnabled: enabled));

  void setAutoplay(bool enabled) => _commit(state.copyWith(autoplay: enabled));

  void setAutoplayPersonalization(bool enabled) =>
      _commit(state.copyWith(autoplayPersonalization: enabled));

  void setSongAnalysis(bool enabled) =>
      _commit(state.copyWith(songAnalysis: enabled));

  void setSongAnalysisOnlyWhileCharging(bool enabled) =>
      _commit(state.copyWith(songAnalysisOnlyWhileCharging: enabled));

  void setMusicHaptics(bool enabled) =>
      _commit(state.copyWith(musicHaptics: enabled));

  void setMusicHapticsSensitivity(double value) => _commit(
    state.copyWith(musicHapticsSensitivity: musicHapticsLevelFromJson(value)),
  );

  void setMusicHapticsStrength(double value) => _commit(
    state.copyWith(musicHapticsStrength: musicHapticsLevelFromJson(value)),
  );

  void setPlayerCoverStyle(String style) => _commit(
    state.copyWith(playerCoverStyle: playerCoverStyleFromJson(style)),
  );

  void setLandscapeLyricsArtwork(bool enabled) =>
      _commit(state.copyWith(landscapeLyricsArtwork: enabled));

  void setCompactPlayer(bool enabled) =>
      _commit(state.copyWith(compactPlayer: enabled));

  void setUsbBitPerfect(bool enabled) =>
      _commit(state.copyWith(usbBitPerfect: enabled));

  void setUsbDirect(bool enabled) => _commit(
    state.copyWith(usbDirect: enabled, dapExclusive: enabled ? false : null),
  );

  void setUsbDsdOverPcm(bool enabled) =>
      _commit(state.copyWith(usbDsdOverPcm: enabled));

  void setUsbAllowFixedVolume(bool enabled) =>
      _commit(state.copyWith(usbAllowFixedVolume: enabled));

  void setDapExclusive(bool enabled) => _commit(
    state.copyWith(dapExclusive: enabled, usbDirect: enabled ? false : null),
  );

  void setExclusiveOutput(bool enabled) =>
      _commit(state.copyWith(exclusiveOutput: enabled));

  void setExclusiveOutputDevice(String device) =>
      _commit(state.copyWith(exclusiveOutputDevice: device));

  void setEmbedMetadata(bool enabled) =>
      _commit(state.copyWith(embedMetadata: enabled));

  void setEmbeddedCoverMaxDimension(int maxDimension) => _commit(
    state.copyWith(
      embeddedCoverMaxDimension: _normalizeEmbeddedCoverMaxDimension(
        maxDimension,
      ),
    ),
  );

  void setArtistTagMode(String mode) {
    if (artistTagModes.contains(mode)) {
      _commit(state.copyWith(artistTagMode: mode));
    }
  }

  void setMetadataSeparator(String field, String separator) {
    if (!MetadataSeparators.fields.contains(field) ||
        MetadataSeparators.validSeparator(separator) != separator) {
      return;
    }
    _commit(
      state.copyWith(
        metadataSeparators: state.metadataSeparators.withField(
          field,
          separator,
        ),
      ),
    );
  }

  void setKeepScreenOnLyrics(bool enabled) =>
      _commit(state.copyWith(keepScreenOnLyrics: enabled));

  void setMotionArtworkEnabled(bool enabled) =>
      _commit(state.copyWith(motionArtworkEnabled: enabled));

  void setListeningStatisticsEnabled(bool enabled) =>
      _commit(state.copyWith(listeningStatisticsEnabled: enabled));

  void setLyricsMode(String mode) {
    if (mode == 'embed' || mode == 'external' || mode == 'both') {
      _commit(state.copyWith(lyricsMode: mode));
    }
  }

  void setLyricsProviders(List<String> providers) {
    _commit(state.copyWith(lyricsProviders: providers));
    _syncLyricsSettingsToBackend();
  }

  void setLyricsIncludeTranslationNetease(bool enabled) {
    _commit(state.copyWith(lyricsIncludeTranslationNetease: enabled));
    _syncLyricsSettingsToBackend();
  }

  void setLyricsIncludeRomanizationNetease(bool enabled) {
    _commit(state.copyWith(lyricsIncludeRomanizationNetease: enabled));
    _syncLyricsSettingsToBackend();
  }

  void setLyricsMultiPersonWordByWord(bool enabled) {
    _commit(state.copyWith(lyricsMultiPersonWordByWord: enabled));
    _syncLyricsSettingsToBackend();
  }

  void setLyricsAppleElrcWordSync(bool enabled) {
    _commit(state.copyWith(lyricsAppleElrcWordSync: enabled));
    _syncLyricsSettingsToBackend();
  }

  void setMusixmatchLanguage(String languageCode) {
    _commit(
      state.copyWith(musixmatchLanguage: languageCode.trim().toLowerCase()),
    );
    _syncLyricsSettingsToBackend();
  }

  /// Switching provider resets the model to the new provider's default.
  void setLyricsAiProvider(String provider) {
    if (provider == state.lyricsAiProvider) return;
    _commit(state.copyWith(lyricsAiProvider: provider, lyricsAiModel: ''));
  }

  void setLyricsAiBaseUrl(String url) =>
      _commit(state.copyWith(lyricsAiBaseUrl: url.trim()));

  void setLyricsAiModel(String model) =>
      _commit(state.copyWith(lyricsAiModel: model.trim()));

  void setLyricsTranslationLanguage(String code) =>
      _commit(state.copyWith(lyricsTranslationLanguage: code.trim()));

  void setLyricsAiInstruction(String instruction) =>
      _commit(state.copyWith(lyricsAiInstruction: instruction.trim()));

  void setLyricsAutoTranslate(bool enabled) =>
      _commit(state.copyWith(lyricsAutoTranslate: enabled));

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

  void setCheckForUpdates(bool enabled) =>
      _commit(state.copyWith(checkForUpdates: enabled));

  void setUpdateChannel(String channel) =>
      _commit(state.copyWith(updateChannel: channel));

  void setHasSearchedBefore() {
    if (!state.hasSearchedBefore) {
      _commit(state.copyWith(hasSearchedBefore: true));
    }
  }

  void setFolderOrganization(String organization) =>
      _commit(state.copyWith(folderOrganization: organization));

  void setFolderPathTemplate(String template) {
    if (!FolderPathTemplate.isValid(template)) return;
    _commit(
      state.copyWith(
        folderPathTemplate: template.trim(),
        folderOrganization: 'custom',
        separateSingles: false,
      ),
    );
  }

  void setCreatePlaylistFolder(bool enabled) =>
      _commit(state.copyWith(createPlaylistFolder: enabled));

  void setUseAlbumArtistForFolders(bool enabled) =>
      _commit(state.copyWith(useAlbumArtistForFolders: enabled));

  void setUsePrimaryArtistOnly(bool enabled) =>
      _commit(state.copyWith(usePrimaryArtistOnly: enabled));

  void setFilterContributingArtistsInAlbumArtist(bool enabled) =>
      _commit(state.copyWith(filterContributingArtistsInAlbumArtist: enabled));

  void setHistoryViewMode(String mode) =>
      _commit(state.copyWith(historyViewMode: mode));

  void setHistoryFilterMode(String mode) =>
      _commit(state.copyWith(historyFilterMode: mode));

  void setAskQualityBeforeDownload(bool enabled) =>
      _commit(state.copyWith(askQualityBeforeDownload: enabled));

  void setSearchProvider(String? provider) {
    final sanitized = _sanitizeRetiredBuiltInProviderId(provider);
    _commit(
      sanitized == null || sanitized.isEmpty
          ? state.copyWith(clearSearchProvider: true)
          : state.copyWith(searchProvider: sanitized),
    );
  }

  void setDefaultSearchTab(String tab) => _commit(
    state.copyWith(defaultSearchTab: _normalizeDefaultSearchTab(tab)),
  );

  void setSearchViewMode(String mode) =>
      _commit(state.copyWith(searchViewMode: mode));

  void setDefaultLibraryView(String view) => _commit(
    state.copyWith(defaultLibraryView: _normalizeDefaultLibraryView(view)),
  );

  void setLibraryQualityLabelMode(String mode) => _commit(
    state.copyWith(
      libraryQualityLabelMode: normalizeLibraryQualityLabelMode(mode),
    ),
  );

  void setHomeFeedProvider(String? provider) => _commit(
    provider == null || provider.isEmpty
        ? state.copyWith(clearHomeFeedProvider: true)
        : state.copyWith(homeFeedProvider: provider),
  );

  void setEnableLogging(bool enabled) {
    _commit(state.copyWith(enableLogging: enabled));
    LogBuffer.loggingEnabled = enabled;
  }

  void setDownloadFallbackExtensionIds(List<String>? extensionIds) {
    _commit(
      state.copyWith(
        downloadFallbackExtensionIds: _sanitizeDownloadFallbackExtensionIds(
          extensionIds,
        ),
        clearDownloadFallbackExtensionIds:
            extensionIds == null && state.downloadFallbackExtensionIds != null,
      ),
    );
    unawaited(_syncExtensionFallbackSettingsToBackend());
  }

  void setSeparateSingles(bool enabled) =>
      _commit(state.copyWith(separateSingles: enabled));

  void setAlbumFolderStructure(String structure) =>
      _commit(state.copyWith(albumFolderStructure: structure));

  void setShowExtensionStore(bool enabled) =>
      _commit(state.copyWith(showExtensionStore: enabled));

  void setHeroAnimationsEnabled(bool enabled) =>
      _commit(state.copyWith(heroAnimationsEnabled: enabled));

  void setForceBackdropBlur(bool enabled) =>
      _commit(state.copyWith(forceBackdropBlur: enabled));

  void setExtensionVerificationBrowserMode(String mode) => _commit(
    state.copyWith(
      extensionVerificationBrowserMode:
          _normalizeExtensionVerificationBrowserMode(mode),
    ),
  );

  void setLocale(String locale) => _commit(state.copyWith(locale: locale));

  void setAutoConvertDownloads(bool enabled) =>
      _commit(state.copyWith(autoConvertDownloads: enabled));

  void setRedownloadFakeHiRes(bool enabled) =>
      _commit(state.copyWith(redownloadFakeHiRes: enabled));

  void setAutoConvertFormat(String format) => _commit(
    state.copyWith(autoConvertFormat: normalizeAutoConvertFormat(format)),
  );

  void setAutoConvertBitrate(String bitrate) => _commit(
    state.copyWith(autoConvertBitrate: normalizeAutoConvertBitrate(bitrate)),
  );

  void setUseAllFilesAccess(bool enabled) =>
      _commit(state.copyWith(useAllFilesAccess: enabled));

  void setAutoExportFailedDownloads(bool enabled) =>
      _commit(state.copyWith(autoExportFailedDownloads: enabled));

  void setDownloadNetworkMode(String mode) =>
      _commit(state.copyWith(downloadNetworkMode: mode));

  void setConcurrentDownloads(int count) =>
      _commit(state.copyWith(concurrentDownloads: count.clamp(1, 3)));

  void setNetworkCompatibilityMode(bool enabled) {
    _commit(state.copyWith(networkCompatibilityMode: enabled));
    unawaited(_syncNetworkCompatibilitySettingsToBackend());
  }

  void setAllowLocalNetwork(bool enabled) {
    _commit(state.copyWith(allowLocalNetwork: enabled));
    unawaited(_syncNetworkCompatibilitySettingsToBackend());
  }

  void setSongLinkRegion(String region) =>
      _commit(state.copyWith(songLinkRegion: _normalizeSongLinkRegion(region)));

  void setNativeDownloadWorkerEnabled(bool enabled) =>
      _commit(state.copyWith(nativeDownloadWorkerEnabled: enabled));

  void setLocalLibraryEnabled(bool enabled) =>
      _commit(state.copyWith(localLibraryEnabled: enabled));

  void setLocalLibraryPathAndBookmark(String path, String bookmark) => _commit(
    state.copyWith(localLibraryPath: path, localLibraryBookmark: bookmark),
  );

  void setLocalLibraryShowDuplicates(bool show) =>
      _commit(state.copyWith(localLibraryShowDuplicates: show));

  void setLocalLibraryAutoScan(String mode) =>
      _commit(state.copyWith(localLibraryAutoScan: mode));

  void setTutorialComplete() =>
      _commit(state.copyWith(hasCompletedTutorial: true));

  void setDeduplicateDownloads(bool enabled) =>
      _commit(state.copyWith(deduplicateDownloads: enabled));

  void setAllowQualityVariants(bool enabled) =>
      _commit(state.copyWith(allowQualityVariants: enabled));

  void setSaveDownloadHistory(bool enabled) =>
      _commit(state.copyWith(saveDownloadHistory: enabled));

  void setPlayerMode(String mode) => _commit(
    state.copyWith(playerMode: mode == 'internal' ? 'internal' : 'external'),
  );

  void setPlayerShowPronunciation(bool visible) =>
      _commit(state.copyWith(playerShowPronunciation: visible));

  void setPlayerShowTranslation(bool visible) =>
      _commit(state.copyWith(playerShowTranslation: visible));

  void setPlayerShowVolume(bool visible) =>
      _commit(state.copyWith(playerShowVolume: visible));
}

final settingsProvider = NotifierProvider<SettingsNotifier, AppSettings>(
  SettingsNotifier.new,
);
