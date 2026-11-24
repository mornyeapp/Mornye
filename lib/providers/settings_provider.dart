import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/models/home_layout.dart';
import 'package:mornye/models/home_shortcut.dart';
import 'package:mornye/models/metadata_separators.dart';
import 'package:mornye/models/automix_options.dart';
import 'package:mornye/constants/app_info.dart';
import 'package:mornye/services/platform_bridge.dart';
import 'package:mornye/services/folder_path_template.dart';
import 'package:mornye/services/download_file_recovery.dart';
import 'package:mornye/services/secure_storage_options.dart';
import 'package:mornye/utils/artist_utils.dart';
import 'package:mornye/utils/audio_format_utils.dart';
import 'package:mornye/utils/audio_conversion_utils.dart';
import 'package:mornye/utils/audio_quality_badge_policy.dart';
import 'package:mornye/utils/file_access.dart';
import 'package:mornye/utils/logger.dart';

const _settingsKey = 'app_settings';
const _settingsCorruptBackupKey = 'app_settings_corrupt_backup';
const _migrationVersionKey = 'settings_migration_version';
const _currentMigrationVersion = 17;

/// Set while someone who had the search field on Home has not yet seen the
/// pointer to the Search tab.
const searchMovedHintOwedKey = 'search_moved_hint_owed';

/// Marked the removed rebrand tour as seen.
const _retiredUpgradeIntroSeenKey = 'upgrade_intro_mornye_seen';
const _legacyDefaultLyricsProviders = ['apple_music', 'lrclib'];
const _spotifyClientSecretKey = 'spotify_client_secret';
const _retiredSpotifyCleanupDoneKey = 'retired_spotify_secret_cleanup_v1';
const _retiredBuiltInProviderIds = {'deezer', 'qobuz', 'tidal', 'youtube'};
final _log = AppLogger('SettingsProvider');

/// Startup override used to render the correct route/locale on the first
/// frame. The notifier still performs migrations and full validation after it
/// mounts.
final initialSettingsProvider = Provider<AppSettings>(
  (ref) => const AppSettings(),
);

/// The startup check of the saved Android SAF tree: true when its grant is
/// lost, null when it gave no answer. MainShell consumes this once.
final initialSafValidationProvider = Provider<Future<bool?>?>((ref) => null);

bool hasPersistedAppSettings(SharedPreferences prefs) {
  final rawSettings = prefs.getString(_settingsKey);
  return rawSettings != null && rawSettings.isNotEmpty;
}

String? _lastBootstrapRawSettings;
AppSettings? _lastBootstrapSettings;

AppSettings _normalizeLoadedSettings(AppSettings loaded) {
  final sanitizedDownloadFallbackExtensionIds =
      SettingsNotifier._sanitizeDownloadFallbackExtensionIds(
        loaded.downloadFallbackExtensionIds,
      );
  final sanitizedDefaultSearchTab = SettingsNotifier._normalizeDefaultSearchTab(
    loaded.defaultSearchTab,
  );
  return loaded.copyWith(
    useExtensionProviders: true,
    downloadFallbackExtensionIds: sanitizedDownloadFallbackExtensionIds,
    clearDownloadFallbackExtensionIds:
        loaded.downloadFallbackExtensionIds != null &&
        sanitizedDownloadFallbackExtensionIds == null,
    defaultSearchTab: sanitizedDefaultSearchTab,
    defaultLibraryView: SettingsNotifier._normalizeDefaultLibraryView(
      loaded.defaultLibraryView,
    ),
    libraryQualityLabelMode: normalizeLibraryQualityLabelMode(
      loaded.libraryQualityLabelMode,
    ),
    autoConvertFormat: normalizeAutoConvertFormat(loaded.autoConvertFormat),
    autoConvertBitrate: normalizeAutoConvertBitrate(loaded.autoConvertBitrate),
    autoConvertMaxBitDepth: normalizeAutoConvertBitDepth(
      loaded.autoConvertMaxBitDepth,
    ),
    autoConvertMaxSampleRate: normalizeAutoConvertSampleRate(
      loaded.autoConvertMaxSampleRate,
    ),
    embeddedCoverMaxDimension:
        SettingsNotifier._normalizeEmbeddedCoverMaxDimension(
          loaded.embeddedCoverMaxDimension,
        ),
    defaultService: loaded.defaultService,
    searchProvider: loaded.searchProvider,
    extensionVerificationBrowserMode:
        SettingsNotifier._normalizeExtensionVerificationBrowserMode(
          loaded.extensionVerificationBrowserMode,
        ),
  );
}

AppSettings loadBootstrapSettings(SharedPreferences prefs) {
  final rawSettings = prefs.getString(_settingsKey);
  if (rawSettings == null || rawSettings.isEmpty) {
    _lastBootstrapRawSettings = null;
    _lastBootstrapSettings = null;
    return const AppSettings();
  }
  try {
    final decoded = jsonDecode(rawSettings);
    if (decoded is! Map) return const AppSettings();
    final normalized = _normalizeLoadedSettings(
      AppSettings.fromJson(Map<String, dynamic>.from(decoded)),
    );
    _lastBootstrapRawSettings = rawSettings;
    _lastBootstrapSettings = normalized;
    return normalized;
  } catch (_) {
    _lastBootstrapRawSettings = null;
    _lastBootstrapSettings = null;
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
    'genres',
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
  final _previousDownloadDirectories = <String>{};
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
    final matchesBootstrap =
        rawSettings != null &&
        rawSettings == _lastBootstrapRawSettings &&
        _lastBootstrapSettings != null &&
        identical(state, _lastBootstrapSettings);
    if (matchesBootstrap) {
      await _runMigrations(prefs);
      await _normalizeIosDownloadDirectoryIfNeeded();
      await _normalizeSongLinkRegionIfNeeded();
    } else if (rawSettings != null) {
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
        state = _normalizeLoadedSettings(loaded);

        await _runMigrations(prefs);
        await _normalizeIosDownloadDirectoryIfNeeded();
        await _normalizeSongLinkRegionIfNeeded();
      }
    }

    await _cleanupRetiredSpotifySettings(prefs);

    LogBuffer.loggingEnabled = state.enableLogging;

    await Future.wait([
      syncLyricsSettingsToBackend(),
      _syncNetworkCompatibilitySettingsToBackend(),
      _syncExtensionFallbackSettingsToBackend(),
    ]);
  }

  void _syncLyricsSettingsToBackend() {
    unawaited(syncLyricsSettingsToBackend());
  }

  Future<void> syncLyricsSettingsToBackend({AppSettings? settings}) async {
    final snapshot = settings ?? state;
    if (!PlatformBridge.supportsCoreBackend) return;

    await Future.wait([
      PlatformBridge.setLyricsProviders(snapshot.lyricsProviders).catchError((
        Object e,
      ) {
        _log.w('Failed to sync lyrics providers to backend: $e');
      }),
      PlatformBridge.setLyricsFetchOptions(
        snapshot.lyricsFetchOptions,
      ).catchError((Object e) {
        _log.w('Failed to sync lyrics fetch options to backend: $e');
      }),
    ]);
  }

  Future<void> _syncNetworkCompatibilitySettingsToBackend() async {
    if (!PlatformBridge.supportsCoreBackend) return;

    final compatibilityMode = state.networkCompatibilityMode;
    await Future.wait([
      PlatformBridge.setNetworkCompatibilityOptions(
        allowHttp: compatibilityMode,
        insecureTls: false,
      ).catchError((Object e) {
        _log.w('Failed to sync network compatibility options to backend: $e');
      }),
      PlatformBridge.setAllowPrivateNetwork(state.allowLocalNetwork).catchError(
        (Object e) {
          _log.w('Failed to sync allow local network option to backend: $e');
        },
      ),
    ]);
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
      // Migration 16: Search left Home for its own tab. An install that ran
      // an earlier build is owed one pointer to it; a new install is not.
      if (lastMigration > 0 && lastMigration < 16 && !state.isFirstLaunch) {
        await prefs.setBool(searchMovedHintOwedKey, true);
      }
      // Migration 17: Off used to mean "show my own Home, not the feed".
      // Home is always that now, so the old choice no longer empties Search.
      if (lastMigration > 0 &&
          lastMigration < 17 &&
          state.homeFeedProvider == AppSettings.homeFeedProviderOff) {
        state = state.copyWith(clearHomeFeedProvider: true);
      }
      await prefs.setInt(_migrationVersionKey, _currentMigrationVersion);
      await _saveSettings();
    }
  }

  Future<void> _commit(AppSettings next) {
    if (isAbsoluteLocalPath(state.downloadDirectory) &&
        state.downloadDirectory != next.downloadDirectory) {
      _previousDownloadDirectories.add(state.downloadDirectory);
    }
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
        if (_previousDownloadDirectories.isNotEmpty) {
          final roots = _previousDownloadDirectories.toList();
          _previousDownloadDirectories.clear();
          try {
            await DownloadFileRecovery.rememberDirectories(prefs, roots);
          } catch (error) {
            _previousDownloadDirectories.addAll(roots);
            _log.w('Could not save previous download folders: $error');
          }
        }
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

  static String _normalizeDefaultSearchTab(String value) {
    final normalized = value.trim().toLowerCase();
    if (_searchTabValues.contains(normalized)) return normalized;
    return 'all';
  }

  static String _normalizeDefaultLibraryView(String value) {
    final normalized = value.trim().toLowerCase();
    if (_libraryViewValues.contains(normalized)) return normalized;
    return 'last';
  }

  static String _normalizeExtensionVerificationBrowserMode(String value) {
    final normalized = value.trim().toLowerCase();
    if (_extensionVerificationBrowserModeValues.contains(normalized)) {
      return normalized;
    }
    return 'in_app_first';
  }

  static int _normalizeEmbeddedCoverMaxDimension(int value) {
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

  static List<String>? _sanitizeDownloadFallbackExtensionIds(
    List<String>? ids,
  ) {
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

  Future<void> _cleanupRetiredSpotifySettings(SharedPreferences prefs) async {
    if (prefs.getBool(_retiredSpotifyCleanupDoneKey) == true) return;
    try {
      final storedSecret = await _secureStorage.read(
        key: _spotifyClientSecretKey,
      );
      if (storedSecret != null && storedSecret.isNotEmpty) {
        await _secureStorage.delete(key: _spotifyClientSecretKey);
      }
      await prefs.setBool(_retiredSpotifyCleanupDoneKey, true);
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

  void setPlaybackNormalizationBoost(bool enabled) =>
      _commit(state.copyWith(playbackNormalizationBoost: enabled));

  void setConfirmLoudVolume(bool enabled) =>
      _commit(state.copyWith(confirmLoudVolume: enabled));

  void setLoudVolumeLevel(int percent) {
    if (!loudVolumeLevels.contains(percent)) return;
    _commit(state.copyWith(loudVolumeLevel: percent));
  }

  void setPauseOnMute(bool enabled) =>
      _commit(state.copyWith(pauseOnMute: enabled));

  void setHeadphoneResume(String mode) {
    if (!headphoneResumeModes.contains(mode)) return;
    _commit(state.copyWith(headphoneResume: mode));
  }

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

  void setAutoMixMatching(AutoMixMatching matching) =>
      _commit(state.copyWith(autoMixMatching: matching));

  void setPlaybackSpeed(double speed) =>
      _commit(state.copyWith(playbackSpeed: playbackSpeedFromJson(speed)));

  void setPlaybackKeepPitch(bool keep) =>
      _commit(state.copyWith(playbackKeepPitch: keep));

  void setPlaybackPitch(double semitones) =>
      _commit(state.copyWith(playbackPitch: playbackPitchFromJson(semitones)));

  void resetPlaybackTempo() => _commit(
    state.copyWith(playbackSpeed: 1, playbackKeepPitch: true, playbackPitch: 0),
  );

  void setDiscordRichPresenceEnabled(bool enabled) =>
      _commit(state.copyWith(discordRichPresenceEnabled: enabled));

  void setAutoplay(bool enabled) => _commit(state.copyWith(autoplay: enabled));

  void setAutoplayPersonalization(bool enabled) =>
      _commit(state.copyWith(autoplayPersonalization: enabled));

  void setAutoplayRandomness(double value) => _commit(
    state.copyWith(autoplayRandomness: autoplayRandomnessFromJson(value)),
  );

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

  void setPlayerCoverFade(String fade) =>
      _commit(state.copyWith(playerCoverFade: playerCoverFadeFromJson(fade)));

  void setPlayerCoverWhole(bool whole) =>
      _commit(state.copyWith(playerCoverWhole: whole));

  void setLandscapeLyricsArtwork(bool enabled) =>
      _commit(state.copyWith(landscapeLyricsArtwork: enabled));

  void setAutoHideLyricsControls(bool enabled) => _commit(
    state.copyWith(
      autoHideLyricsControls: enabled,
      autoHideLyricsControlsWithAccessibility: enabled,
    ),
  );

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

  void setUsbMaxSampleRate(int rate) =>
      _commit(state.copyWith(usbMaxSampleRate: rate));

  void setUsbDitherHighPass(bool enabled) =>
      _commit(state.copyWith(usbDitherHighPass: enabled));

  void setDapExclusive(bool enabled) => _commit(
    state.copyWith(dapExclusive: enabled, usbDirect: enabled ? false : null),
  );

  void setMedia3Engine(bool enabled) =>
      _commit(state.copyWith(media3Engine: enabled));

  void setSkipSilence(bool enabled) =>
      _commit(state.copyWith(skipSilence: enabled));

  void setSpatialAudio(bool enabled) =>
      _commit(state.copyWith(spatialAudio: enabled));

  void setQueueNoDuplicates(bool enabled) =>
      _commit(state.copyWith(queueNoDuplicates: enabled));

  void setQueueLocked(bool locked) =>
      _commit(state.copyWith(queueLocked: locked));

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

  void setLockScreenLyrics(bool enabled) =>
      _commit(state.copyWith(lockScreenLyrics: enabled));

  void setLockScreenLyricsKeepTitle(bool keep) =>
      _commit(state.copyWith(lockScreenLyricsKeepTitle: keep));

  void setMotionArtworkEnabled(bool enabled) =>
      _commit(state.copyWith(motionArtworkEnabled: enabled));

  void setSaveMotionArtworkFile(bool enabled) =>
      _commit(state.copyWith(saveMotionArtworkFile: enabled));

  void setSaveFolderCover(bool enabled) =>
      _commit(state.copyWith(saveFolderCover: enabled));

  void setFolderCoverMaxDimension(int maxDimension) => _commit(
    state.copyWith(
      folderCoverMaxDimension: _normalizeEmbeddedCoverMaxDimension(
        maxDimension,
      ),
    ),
  );

  void setRemoveEmptyFolders(bool enabled) =>
      _commit(state.copyWith(removeEmptyFolders: enabled));

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

  void setLyricsPreferBestTiming(bool enabled) {
    _commit(state.copyWith(lyricsPreferBestTiming: enabled));
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

  void setLyricsTranslationSecondLanguage(String code) =>
      _commit(state.copyWith(lyricsTranslationSecondLanguage: code.trim()));

  void setLyricsAiInstruction(String instruction) =>
      _commit(state.copyWith(lyricsAiInstruction: instruction.trim()));

  void setLyricsAutoTranslate(bool enabled) =>
      _commit(state.copyWith(lyricsAutoTranslate: enabled));

  void setLyricsAiRomanize(bool enabled) =>
      _commit(state.copyWith(lyricsAiRomanize: enabled));

  void setLyricsRomanize(bool enabled) =>
      _commit(state.copyWith(lyricsRomanize: enabled));

  void setLyricsRomanizedMainLine(bool enabled) =>
      _commit(state.copyWith(lyricsRomanizedMainLine: enabled));

  void setLyricsAiWordSync(bool enabled) =>
      _commit(state.copyWith(lyricsAiWordSync: enabled));

  void setLyricsTranslationSaveTo(String target) => _commit(
    state.copyWith(
      lyricsTranslationSaveTo: lyricsTranslationSaveToFromJson(target),
    ),
  );

  void setLyricsTranslationAutoSave(bool enabled) =>
      _commit(state.copyWith(lyricsTranslationAutoSave: enabled));

  void setLyricsTranslateDownloads(bool enabled) =>
      _commit(state.copyWith(lyricsTranslateDownloads: enabled));

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

  void setHistorySortMode(String mode) =>
      _commit(state.copyWith(historySortMode: librarySortModeFromJson(mode)));

  void setLibraryAlbumSortMode(String mode) => _commit(
    state.copyWith(libraryAlbumSortMode: libraryAlbumSortModeFromJson(mode)),
  );

  void setLibraryArtistShowsSongs(bool songs) =>
      _commit(state.copyWith(libraryArtistShowsSongs: songs));

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

  void setHomeShortcuts(List<HomeShortcut> shortcuts) =>
      _commit(state.copyWith(homeShortcuts: HomeShortcut.names(shortcuts)));

  void setHomeContinueListening(bool enabled) =>
      _commit(state.copyWith(homeContinueListening: enabled));

  void setHomeRecommendations(bool enabled) =>
      _commit(state.copyWith(homeRecommendations: enabled));

  void setHomeLayout(HomeLayout layout) =>
      _commit(state.copyWith(homeLayout: layout));

  /// Shows or hides a Home section, through the switch it had before the
  /// layout when it has one.
  void setHomeSectionVisible(HomeSection section, bool visible) =>
      _commit(switch (section) {
        HomeSection.continueListening => state.copyWith(
          homeContinueListening: visible,
        ),
        HomeSection.recommended => state.copyWith(homeRecommendations: visible),
        _ => state.copyWith(
          homeLayout: state.homeLayout.withVisible(section, visible),
        ),
      });

  /// Home's sections as they ship: order and what shows.
  void resetHomeLayout() => _commit(
    state.copyWith(
      homeLayout: const HomeLayout(),
      homeShortcuts: HomeShortcut.names(HomeShortcut.defaults),
      homeContinueListening: true,
      homeRecommendations: true,
    ),
  );

  void setDefaultLibraryView(String view) => _commit(
    state.copyWith(defaultLibraryView: _normalizeDefaultLibraryView(view)),
  );

  void setLibraryQualityLabelMode(String mode) => _commit(
    state.copyWith(
      libraryQualityLabelMode: normalizeLibraryQualityLabelMode(mode),
    ),
  );

  void setSwipeToQueue(bool enabled) =>
      _commit(state.copyWith(swipeToQueue: enabled));

  void setLibrarySongTap(String mode) => _commit(
    state.copyWith(
      librarySongTap: mode == AppSettings.librarySongTapPlay
          ? AppSettings.librarySongTapPlay
          : AppSettings.librarySongTapDetails,
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

  void setAutoUpdateExtensions(bool enabled) =>
      _commit(state.copyWith(autoUpdateExtensions: enabled));

  void setHeroAnimationsEnabled(bool enabled) =>
      _commit(state.copyWith(heroAnimationsEnabled: enabled));

  void setForceBackdropBlur(bool enabled) =>
      _commit(state.copyWith(forceBackdropBlur: enabled));

  void setInterfaceScale(double scale) =>
      _commit(state.copyWith(interfaceScale: interfaceScaleFromJson(scale)));

  void setAnimationSpeed(double speed) =>
      _commit(state.copyWith(animationSpeed: animationSpeedFromJson(speed)));

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

  void setAutoConvertMaxBitDepth(int depth) => _commit(
    state.copyWith(autoConvertMaxBitDepth: normalizeAutoConvertBitDepth(depth)),
  );

  void setAutoConvertMaxSampleRate(int rate) => _commit(
    state.copyWith(
      autoConvertMaxSampleRate: normalizeAutoConvertSampleRate(rate),
    ),
  );

  void setAutoConvertSmartDither(bool enabled) =>
      _commit(state.copyWith(autoConvertSmartDither: enabled));

  void setAutoConvertSmartDitherHighPass(bool enabled) =>
      _commit(state.copyWith(autoConvertSmartDitherHighPass: enabled));

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

  void setLinkHideDisconnectedSongs(bool hide) =>
      _commit(state.copyWith(linkHideDisconnectedSongs: hide));

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

  void setPlayerShowLyricSnippet(bool visible) =>
      _commit(state.copyWith(playerShowLyricSnippet: visible));

  void setPlayerLyricSnippetTranslation(bool visible) =>
      _commit(state.copyWith(playerLyricSnippetTranslation: visible));
}

final settingsProvider = NotifierProvider<SettingsNotifier, AppSettings>(
  SettingsNotifier.new,
);
