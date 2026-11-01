import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mornye/models/extension.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/services/platform_bridge.dart';
import 'package:mornye/services/extension_storage_service.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:mornye/utils/logger.dart';
import 'package:mornye/providers/settings_provider.dart';

export 'package:mornye/models/extension.dart';

part 'extension_provider_priority.dart';

final _log = AppLogger('ExtensionProvider');

const _metadataProviderPriorityKey = 'metadata_provider_priority';
const _providerPriorityKey = 'provider_priority';
const _storeRegistryUrlPrefKey = 'store_registry_url';

final extensionSettingsProvider = FutureProvider.autoDispose
    .family<Map<String, dynamic>, String>((ref, extensionId) {
      return PlatformBridge.getExtensionSettings(extensionId);
    });

/// Result of restoring extensions from a backup.
class ExtensionNotifier extends Notifier<ExtensionState> {
  static const _extensionHealthDefaultCacheTtl = Duration(minutes: 10);
  static const _extensionHealthMinimumCacheTtl = Duration(minutes: 1);
  static const _extensionHealthUnknownCacheTtl = Duration(minutes: 2);
  AppLifecycleListener? _appLifecycleListener;
  bool _cleanupInFlight = false;
  Completer<void>? _initializationCompleter;
  Future<void>? _ensureInitializationFuture;
  Future<void> _downloadDirectorySync = Future<void>.value();
  final Map<String, DateTime> _healthExpiresAt = {};
  final Map<String, Future<ExtensionHealthStatus?>> _healthInFlight = {};
  final Map<String, int> _healthRequestSerial = {};

  @override
  ExtensionState build() {
    ref.listen<AppSettings>(settingsProvider, (previous, next) {
      if (state.isInitialized &&
          (previous?.downloadDirectory != next.downloadDirectory ||
              previous?.downloadDirectoryBookmark !=
                  next.downloadDirectoryBookmark ||
              previous?.storageMode != next.storageMode)) {
        unawaited(_syncDownloadDirectory(next));
      }
    });
    _appLifecycleListener ??= AppLifecycleListener(
      onDetach: _scheduleLifecycleCleanup,
    );
    ref.onDispose(() {
      _appLifecycleListener?.dispose();
      _appLifecycleListener = null;
      _healthExpiresAt.clear();
      _healthInFlight.clear();
      _healthRequestSerial.clear();
    });
    return const ExtensionState();
  }

  Future<void> _syncDownloadDirectory(AppSettings settings) {
    _downloadDirectorySync = _downloadDirectorySync
        .then((_) async {
          if (!PlatformBridge.supportsCoreBackend) return;
          final candidate = settings.downloadDirectory.trim();
          final path =
              settings.storageMode == 'app' &&
                  settings.downloadDirectoryBookmark.isEmpty &&
                  candidate.startsWith('/') &&
                  await Directory(candidate).exists()
              ? candidate
              : '';
          try {
            await PlatformBridge.setDownloadDirectory(path);
          } catch (_) {
            // An invalid new selection must not leave the old permanent grant.
            await PlatformBridge.setDownloadDirectory('');
            rethrow;
          }
        })
        .catchError((Object error) {
          _log.w('Failed to sync output directory access: $error');
        });
    return _downloadDirectorySync;
  }

  void _scheduleLifecycleCleanup() {
    if (_cleanupInFlight) return;
    _cleanupInFlight = true;
    unawaited(_cleanupExtensions(reason: 'lifecycle detach'));
  }

  Future<void> _cleanupExtensions({required String reason}) async {
    try {
      // Android may detach/recreate its Activity while the cached engine and
      // browser verification remain alive. Keep the process-owned backend.
      await PlatformBridge.releaseNativeMemory();
      _log.d('Released idle extension resources ($reason)');
    } catch (e) {
      _log.w('Extension cleanup failed ($reason): $e');
    } finally {
      _cleanupInFlight = false;
    }
  }

  /// Startup and install/update actions share initialization, including the
  /// private storage preparation that happens before the native call.
  Future<void> ensureInitialized() {
    if (state.isInitialized) return Future<void>.value();
    return _ensureInitializationFuture ??= _initializeFromStorage()
        .whenComplete(() {
          _ensureInitializationFuture = null;
        });
  }

  Future<void> _initializeFromStorage() async {
    final pending = _initializationCompleter?.future;
    if (pending != null) {
      await pending;
    } else {
      try {
        await ref.read(settingsProvider.notifier).ensureLoaded();
        final storage = await ExtensionStorageService.prepare();
        await initialize(
          storage.extensionsDir,
          storage.dataDir,
          masterKey: storage.masterKey,
        );
      } catch (error) {
        state = state.copyWith(isLoading: false, error: error.toString());
        rethrow;
      }
    }
    if (!state.isInitialized) {
      throw StateError(state.error ?? 'Extension system initialization failed');
    }
  }

  Future<void> initialize(
    String extensionsDir,
    String dataDir, {
    required String masterKey,
  }) async {
    if (state.isInitialized) return;
    if (_initializationCompleter != null) {
      await _initializationCompleter!.future;
      return;
    }

    final completer = Completer<void>();
    _initializationCompleter = completer;

    state = state.copyWith(isLoading: true, error: null);

    if (!PlatformBridge.supportsExtensionSystem) {
      state = state.copyWith(
        isInitialized: true,
        isLoading: false,
        extensions: const [],
        error: null,
      );
      _log.i('Extension system disabled on this platform');
      completer.complete();
      _initializationCompleter = null;
      return;
    }

    try {
      final settings = ref.read(settingsProvider.notifier);
      await settings.ensureLoaded();
      final snapshot = ref.read(settingsProvider);
      final outputDirectory = snapshot.downloadDirectory.trim();
      final allowedDirectories = <String>[];
      // External scopes are acquired by the file/download operation. Missing
      // output folders are resolved by the queue and must not prevent startup.
      if (snapshot.storageMode == 'app' &&
          snapshot.downloadDirectoryBookmark.isEmpty &&
          outputDirectory.startsWith('/')) {
        final directory = Directory(outputDirectory);
        if (await directory.exists()) {
          allowedDirectories.add(directory.path);
        }
      }
      if (Platform.isAndroid) {
        try {
          await PlatformBridge.prepareRuntimeState(dataDir);
        } catch (e) {
          _log.w('Runtime state restore unavailable: $e');
        }
      }
      await PlatformBridge.initExtensionSystem(
        extensionsDir,
        dataDir,
        masterKey: masterKey,
        lyricsProviders: snapshot.lyricsProviders,
        lyricsFetchOptions: snapshot.lyricsFetchOptions,
        allowedDirectories: allowedDirectories,
      );
      final loaded = await loadExtensions(extensionsDir);
      final loadError = state.error;
      if (!loaded) {
        throw StateError(loadError ?? 'Failed to load installed extensions');
      }
      await loadProviderPriority();
      await loadMetadataProviderPriority();
      if (Platform.isAndroid || isDesktopPlatform) {
        // Exchange a cold-start browser callback before restored downloads can
        // bootstrap a replacement challenge and invalidate its original state.
        // Desktop queues a launch URL in the backend before this point.
        await PlatformBridge.processPendingExtensionCallbacks();
      }
      state = state.copyWith(
        isInitialized: true,
        isLoading: false,
        error: loadError,
      );
      await _syncDownloadDirectory(ref.read(settingsProvider));
      _log.i('Extension system initialized');
    } catch (e) {
      _log.e('Failed to initialize extension system: $e');
      state = state.copyWith(isLoading: false, error: e.toString());
    } finally {
      if (!completer.isCompleted) {
        completer.complete();
      }
      if (identical(_initializationCompleter, completer)) {
        _initializationCompleter = null;
      }
    }
  }

  Future<void> waitForInitialization({
    Duration timeout = const Duration(seconds: 30),
  }) async {
    if (state.isInitialized || !PlatformBridge.supportsExtensionSystem) {
      return;
    }

    final future = _initializationCompleter?.future;
    if (future == null) {
      return;
    }

    try {
      await future.timeout(timeout);
    } on TimeoutException {
      _log.w('Timed out waiting for extension initialization after $timeout');
    }
  }

  Future<bool> loadExtensions(String dirPath) async {
    state = state.copyWith(isLoading: true, error: null);

    try {
      final result = await PlatformBridge.loadExtensionsFromDir(dirPath);
      _log.d('Load extensions result: $result');
      final loadErrors = (result['errors'] as List<dynamic>? ?? const [])
          .whereType<String>()
          .where((error) => error.trim().isNotEmpty)
          .toList();
      await refreshExtensions();
      final refreshError = state.error;
      state = state.copyWith(
        isLoading: false,
        error:
            refreshError ?? (loadErrors.isEmpty ? null : loadErrors.join('\n')),
      );
      // Native loading can succeed overall while individual packages fail.
      // Keep working extensions usable, but do not treat an unreadable install
      // directory as an empty, successfully initialized extension system.
      return refreshError == null &&
          (loadErrors.isEmpty || state.extensions.isNotEmpty);
    } catch (e) {
      _log.e('Failed to load extensions: $e');
      state = state.copyWith(isLoading: false, error: e.toString());
      return false;
    }
  }

  Future<void> refreshExtensions() async {
    try {
      final list = await PlatformBridge.getInstalledExtensions();
      final extensions = list.map((e) => Extension.fromJson(e)).toList();
      state = state.copyWith(extensions: extensions);
      await _reconcileDownloadProviderPriority();
      await _reconcileDefaultDownloadService();
      await _reconcileMetadataProviderPriority();
      _reconcileSearchProvider();
      _scheduleExtensionHealthRefresh(extensions);
      _log.d('Loaded ${extensions.length} extensions');

      for (final ext in extensions) {
        if (ext.searchBehavior != null) {
          _log.d(
            'Extension ${ext.id}: thumbnailRatio=${ext.searchBehavior!.thumbnailRatio}',
          );
        }
      }
    } catch (e) {
      _log.e('Failed to refresh extensions: $e');
      state = state.copyWith(error: e.toString());
    }
  }

  void _scheduleExtensionHealthRefresh(
    List<Extension> extensions, {
    bool force = false,
  }) {
    for (final ext in extensions) {
      if (!ext.enabled || !ext.hasServiceHealth) continue;
      unawaited(checkExtensionHealth(ext.id, force: force));
    }
  }

  void refreshEnabledExtensionHealth({bool force = false}) {
    _scheduleExtensionHealthRefresh(state.extensions, force: force);
  }

  Duration _extensionHealthCacheTtlFor(Extension extension) {
    var ttl = _extensionHealthDefaultCacheTtl;
    for (final check in extension.serviceHealth) {
      final seconds = check.cacheTtlSeconds;
      if (seconds == null || seconds <= 0) continue;

      var checkTtl = Duration(seconds: seconds);
      if (checkTtl < _extensionHealthMinimumCacheTtl) {
        checkTtl = _extensionHealthMinimumCacheTtl;
      }
      if (checkTtl < ttl) {
        ttl = checkTtl;
      }
    }
    return ttl;
  }

  Duration _extensionHealthCacheTtlForStatus(
    Extension extension,
    String status,
  ) {
    final ttl = _extensionHealthCacheTtlFor(extension);
    if (status == 'unknown' && ttl > _extensionHealthUnknownCacheTtl) {
      return _extensionHealthUnknownCacheTtl;
    }
    return ttl;
  }

  Future<ExtensionHealthStatus?> checkExtensionHealth(
    String extensionId, {
    bool force = false,
  }) async {
    final ext = state.extensions
        .where((extension) => extension.id == extensionId)
        .firstOrNull;
    if (ext == null || !ext.hasServiceHealth) {
      return null;
    }

    final expiresAt = _healthExpiresAt[extensionId];
    final cached = state.healthStatuses[extensionId];
    if (!force &&
        cached != null &&
        expiresAt != null &&
        DateTime.now().isBefore(expiresAt)) {
      return cached;
    }

    final inFlight = _healthInFlight[extensionId];
    if (!force && inFlight != null) {
      return inFlight;
    }

    final requestSerial = (_healthRequestSerial[extensionId] ?? 0) + 1;
    _healthRequestSerial[extensionId] = requestSerial;

    final future = () async {
      try {
        final result = await PlatformBridge.checkExtensionHealth(extensionId);
        final status = ExtensionHealthStatus.fromJson(result);
        if (_healthRequestSerial[extensionId] == requestSerial) {
          final updated = Map<String, ExtensionHealthStatus>.of(
            state.healthStatuses,
          )..[extensionId] = status;
          _healthExpiresAt[extensionId] = DateTime.now().add(
            _extensionHealthCacheTtlForStatus(ext, status.status),
          );
          state = state.copyWith(healthStatuses: updated);
        }
        return status;
      } catch (e) {
        _log.w('Failed to check extension health for $extensionId: $e');
        final status = ExtensionHealthStatus(
          status: 'unknown',
          checkedAt: DateTime.now(),
          checks: const [],
        );
        if (_healthRequestSerial[extensionId] == requestSerial) {
          final updated = Map<String, ExtensionHealthStatus>.of(
            state.healthStatuses,
          )..[extensionId] = status;
          _healthExpiresAt[extensionId] = DateTime.now().add(
            _extensionHealthUnknownCacheTtl,
          );
          state = state.copyWith(healthStatuses: updated);
        }
        return status;
      } finally {
        if (_healthRequestSerial[extensionId] == requestSerial) {
          _healthInFlight.remove(extensionId);
        }
      }
    }();

    _healthInFlight[extensionId] = future;
    return future;
  }

  void clearError() {
    state = state.copyWith(error: null);
  }

  Future<bool> installExtension(String filePath) async {
    state = state.copyWith(isLoading: true, error: null);

    try {
      await ensureInitialized();
      final result = await PlatformBridge.loadExtensionFromPath(filePath);
      _log.i('Installed extension: ${result['name']}');
      await refreshExtensions();
      state = state.copyWith(isLoading: false);
      return true;
    } catch (e) {
      _log.e('Failed to install extension: $e');
      state = state.copyWith(isLoading: false, error: e.toString());
      return false;
    }
  }

  Future<ExtensionInstallBatchResult> installExtensions(
    List<String> filePaths,
  ) async {
    final uniquePaths = <String>[];
    for (final path in filePaths) {
      final trimmed = path.trim();
      if (trimmed.isEmpty || uniquePaths.contains(trimmed)) continue;
      uniquePaths.add(trimmed);
    }

    if (uniquePaths.isEmpty) {
      return const ExtensionInstallBatchResult(attempted: 0, installed: 0);
    }

    state = state.copyWith(isLoading: true, error: null);

    var installed = 0;
    final failures = <String, String>{};

    try {
      await ensureInitialized();
    } catch (e) {
      state = state.copyWith(isLoading: false, error: e.toString());
      return ExtensionInstallBatchResult(
        attempted: uniquePaths.length,
        installed: 0,
        failures: {for (final path in uniquePaths) path: e.toString()},
      );
    }

    for (final path in uniquePaths) {
      try {
        final result = await PlatformBridge.loadExtensionFromPath(path);
        installed++;
        _log.i('Installed extension: ${result['name']}');
      } catch (e) {
        _log.e('Failed to install extension from $path: $e');
        failures[path] = e.toString();
      }
    }

    if (installed > 0) {
      await refreshExtensions();
    }

    final firstError = failures.values.firstOrNull;
    state = state.copyWith(isLoading: false, error: firstError);

    return ExtensionInstallBatchResult(
      attempted: uniquePaths.length,
      installed: installed,
      failures: failures,
    );
  }

  Future<Map<String, dynamic>> checkExtensionUpgrade(String filePath) async {
    try {
      await ensureInitialized();
      return await PlatformBridge.checkExtensionUpgrade(filePath);
    } catch (e) {
      _log.e('Failed to check extension upgrade: $e');
      return {'error': e.toString()};
    }
  }

  Future<bool> upgradeExtension(String filePath) async {
    state = state.copyWith(isLoading: true, error: null);

    try {
      await ensureInitialized();
      final result = await PlatformBridge.upgradeExtension(filePath);
      _log.i(
        'Upgraded extension: ${result['display_name']} to v${result['version']}',
      );
      await refreshExtensions();
      state = state.copyWith(isLoading: false);
      return true;
    } catch (e) {
      _log.e('Failed to upgrade extension: $e');
      state = state.copyWith(isLoading: false, error: e.toString());
      return false;
    }
  }

  Future<bool> removeExtension(String extensionId) async {
    state = state.copyWith(isLoading: true, error: null);

    try {
      await PlatformBridge.removeExtension(extensionId);
      _log.i('Removed extension: $extensionId');
      await refreshExtensions();
      state = state.copyWith(isLoading: false);
      return true;
    } catch (e) {
      _log.e('Failed to remove extension: $e');
      state = state.copyWith(isLoading: false, error: e.toString());
      return false;
    }
  }

  Future<void> setExtensionEnabled(String extensionId, bool enabled) async {
    try {
      await PlatformBridge.setExtensionEnabled(extensionId, enabled);
      _log.d('Set extension $extensionId enabled: $enabled');

      final ext = state.extensions
          .where((e) => e.id == extensionId)
          .firstOrNull;

      final extensions = state.extensions.map((e) {
        if (e.id == extensionId) {
          return e.copyWith(enabled: enabled);
        }
        return e;
      }).toList();

      state = state.copyWith(extensions: extensions);
      await _reconcileDownloadProviderPriority();
      await _reconcileDefaultDownloadService();
      await _reconcileMetadataProviderPriority();
      _reconcileSearchProvider();

      final updatedExt = extensions
          .where((extension) => extension.id == extensionId)
          .firstOrNull;
      if (enabled && updatedExt?.hasServiceHealth == true) {
        unawaited(checkExtensionHealth(extensionId, force: true));
      }

      if (!enabled && ext != null) {
        final settings = ref.read(settingsProvider);

        if (settings.searchProvider == extensionId) {
          ref.read(settingsProvider.notifier).setSearchProvider(null);
          _log.d(
            'Cleared search provider because extension $extensionId was disabled',
          );
        }

        if (ext.hasDownloadProvider && settings.defaultService == extensionId) {
          final fallbackService =
              _firstEnabledExtensionDownloadProviderId() ?? '';
          ref
              .read(settingsProvider.notifier)
              .setDefaultService(fallbackService);
          _log.d(
            fallbackService.isEmpty
                ? 'Cleared default service because extension $extensionId was disabled'
                : 'Reset default service to $fallbackService because extension $extensionId was disabled',
          );
        }
      }
    } catch (e) {
      _log.e('Failed to set extension enabled: $e');
      state = state.copyWith(error: e.toString());
    }
  }

  /// Collects the keys flagged as `secret` in an extension's manifest schema
  /// (top-level settings and quality-specific settings).
  Set<String> _secretKeysFromManifest(Map<String, dynamic> raw) {
    final keys = <String>{};

    void scan(Object? settingsList) {
      if (settingsList is! List) return;
      for (final entry in settingsList) {
        if (entry is Map && entry['secret'] == true && entry['key'] is String) {
          keys.add(entry['key'] as String);
        }
      }
    }

    scan(raw['settings']);
    final quality = raw['quality_options'];
    if (quality is List) {
      for (final option in quality) {
        if (option is Map) {
          scan(option['settings']);
        }
      }
    }
    return keys;
  }

  /// Builds the extensions section of a backup: the store registry URL, the
  /// installed extensions with their id, version, enabled flag and settings,
  /// and the download and metadata provider priority order.
  /// Secret-flagged settings (tokens, API keys) are only included when
  /// [includeSecrets] is true.
  Future<Map<String, dynamic>> exportBackup({
    required bool includeSecrets,
  }) async {
    if (!PlatformBridge.supportsExtensionSystem) {
      return {'registry_url': '', 'items': const <Map<String, dynamic>>[]};
    }

    final prefs = await SharedPreferences.getInstance();
    // The native repository is initialized lazily when Repo is opened. Keep
    // its persisted URL in backups made before that first visit.
    var registryUrl = (prefs.getString(_storeRegistryUrlPrefKey) ?? '').trim();
    try {
      final activeUrl = (await PlatformBridge.getRepoRegistryUrl()).trim();
      if (activeUrl.isNotEmpty) registryUrl = activeUrl;
    } catch (_) {}

    List<Map<String, dynamic>> installed;
    try {
      installed = await PlatformBridge.getInstalledExtensions();
    } catch (e) {
      _log.w('Backup: failed to list extensions: $e');
      installed = const [];
    }

    final items = <Map<String, dynamic>>[];
    for (final raw in installed) {
      final id = raw['id'] as String?;
      if (id == null || id.isEmpty) continue;
      final secretKeys = _secretKeysFromManifest(raw);

      Map<String, dynamic> settings = {};
      try {
        settings = await PlatformBridge.getExtensionSettings(id);
      } catch (_) {}

      final filtered = <String, dynamic>{};
      var omittedSecret = false;
      settings.forEach((key, value) {
        if (secretKeys.contains(key)) {
          if (!includeSecrets) {
            omittedSecret = true;
            return;
          }
        }
        filtered[key] = value;
      });

      items.add({
        'id': id,
        'version': raw['version']?.toString() ?? '',
        'enabled': raw['enabled'] == true,
        'settings': filtered,
        if (omittedSecret) 'secrets_omitted': true,
      });
    }

    return {
      'registry_url': registryUrl,
      'items': items,
      ...providerPriorityBackup(),
    };
  }

  /// Restores extensions from a backup section produced by [exportBackup]:
  /// re-applies the store registry URL, reinstalls each extension from the
  /// store when missing, then merges settings and restores the enabled flag.
  /// Missing settings (e.g. omitted secrets) are merged with the current values
  /// so they are not wiped.
  Future<ExtensionRestoreResult> restoreFromBackup(
    Map<String, dynamic> data,
  ) async {
    if (!PlatformBridge.supportsExtensionSystem) {
      return const ExtensionRestoreResult();
    }

    await ensureInitialized();

    final prefs = await SharedPreferences.getInstance();
    final backupUrl = (data['registry_url'] as String?)?.trim() ?? '';
    // Older backups may have omitted the URL when Repo had not been opened.
    final registryUrl = backupUrl.isNotEmpty
        ? backupUrl
        : (prefs.getString(_storeRegistryUrlPrefKey) ?? '').trim();
    final itemsRaw = data['items'];
    final items = itemsRaw is List
        ? itemsRaw
              .whereType<Map<Object?, Object?>>()
              .map((e) => Map<String, dynamic>.from(e))
              .toList()
        : <Map<String, dynamic>>[];

    Directory? destDir;
    try {
      final tmp = await getTemporaryDirectory();
      destDir = await Directory(
        '${tmp.path}/mornye_restore_ext',
      ).create(recursive: true);
      await PlatformBridge.initExtensionRepo(destDir.path);
      if (registryUrl.isNotEmpty) {
        await PlatformBridge.setRepoRegistryUrl(registryUrl);
        await prefs.setString(_storeRegistryUrlPrefKey, registryUrl);
      }
    } catch (e) {
      _log.w('Restore: failed to prepare extension store: $e');
    }

    await refreshExtensions();
    final installedIds = state.extensions
        .map((e) => e.id.toLowerCase())
        .toSet();

    var installedCount = 0;
    var alreadyPresent = 0;
    var failed = 0;
    final failedIds = <String>[];

    for (final item in items) {
      final id = item['id'] as String?;
      if (id == null || id.isEmpty) continue;
      final enabled = item['enabled'] != false;
      var present = installedIds.contains(id.toLowerCase());

      if (!present) {
        if (destDir == null) {
          failed++;
          failedIds.add(id);
          continue;
        }
        try {
          final path = await PlatformBridge.downloadRepoExtension(
            id,
            destDir.path,
          );
          final ok = await installExtension(path);
          if (ok) {
            installedCount++;
            present = true;
          } else {
            failed++;
            failedIds.add(id);
          }
        } catch (e) {
          _log.w('Restore: failed to install extension $id: $e');
          failed++;
          failedIds.add(id);
        }
      } else {
        alreadyPresent++;
      }

      if (!present) continue;

      final settings = item['settings'];
      if (settings is Map && settings.isNotEmpty) {
        try {
          final current = await PlatformBridge.getExtensionSettings(id);
          final merged = <String, dynamic>{
            ...current,
            ...Map<String, dynamic>.from(settings),
          };
          await setExtensionSettings(id, merged);
        } catch (e) {
          _log.w('Restore: failed to apply settings for $id: $e');
        }
      }

      try {
        await setExtensionEnabled(id, enabled);
      } catch (_) {}
    }

    await refreshExtensions();
    // Reinstalled and re-enabled extensions now exist, so the saved order can
    // be applied in full instead of defaults winning.
    await restoreProviderPriorityBackup(data);

    return ExtensionRestoreResult(
      installed: installedCount,
      alreadyPresent: alreadyPresent,
      failed: failed,
      failedIds: failedIds,
    );
  }
}

final extensionProvider = NotifierProvider<ExtensionNotifier, ExtensionState>(
  ExtensionNotifier.new,
);
