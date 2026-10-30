import 'dart:async';
import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:mornye/services/listening_statistics.dart';
import 'package:mornye/services/network_storage_service.dart';
import 'package:mornye/services/sync/local_folder_sync_driver.dart';
import 'package:mornye/services/sync/partition_serializer.dart';
import 'package:mornye/services/sync/sync_storage_driver.dart';
import 'package:mornye/services/sync/webdav_sync_driver.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:mornye/utils/logger.dart';

final _log = AppLogger('SyncOrchestrator');

const _prefSyncEnabled = 'mornye_sync_enabled';
const _prefSyncLastTimestamp = 'mornye_sync_last_timestamp';
const _prefSyncStorageType = 'mornye_sync_storage_type';
const _prefSyncLocalPath = 'mornye_sync_local_path';
const _prefSyncWebDavUrl = 'mornye_sync_webdav_url';
const _prefSyncWebDavRoot = 'mornye_sync_webdav_root';
const _prefSyncWebDavUser = 'mornye_sync_webdav_user';
const _prefSyncWebDavPass = 'mornye_sync_webdav_pass';
const _prefSyncDeviceName = 'mornye_sync_device_name';
const _prefSyncNetworkConnId = 'mornye_sync_network_conn_id';

class SyncConfig {
  const SyncConfig({
    this.enabled = false,
    this.storageType = 'webdav',
    this.localPath = '',
    this.webDavUrl = '',
    this.webDavRootPath = 'MornyeSync',
    this.webDavUsername = '',
    this.webDavPassword = '',
    this.deviceName = '',
    this.selectedNetworkConnectionId,
  });

  final bool enabled;
  final String storageType; // 'local' or 'webdav'
  final String localPath;
  final String webDavUrl;
  final String webDavRootPath;
  final String webDavUsername;
  final String webDavPassword;
  final String deviceName;
  final String? selectedNetworkConnectionId;

  SyncConfig copyWith({
    bool? enabled,
    String? storageType,
    String? localPath,
    String? webDavUrl,
    String? webDavRootPath,
    String? webDavUsername,
    String? webDavPassword,
    String? deviceName,
    String? selectedNetworkConnectionId,
  }) {
    return SyncConfig(
      enabled: enabled ?? this.enabled,
      storageType: storageType ?? this.storageType,
      localPath: localPath ?? this.localPath,
      webDavUrl: webDavUrl ?? this.webDavUrl,
      webDavRootPath: webDavRootPath ?? this.webDavRootPath,
      webDavUsername: webDavUsername ?? this.webDavUsername,
      webDavPassword: webDavPassword ?? this.webDavPassword,
      deviceName: deviceName ?? this.deviceName,
      selectedNetworkConnectionId:
          selectedNetworkConnectionId ?? this.selectedNetworkConnectionId,
    );
  }
}

enum SyncStatusState { idle, syncing, success, error }

class SyncStatus {
  const SyncStatus({
    this.state = SyncStatusState.idle,
    this.lastSyncTime,
    this.errorMessage,
    this.exportedPartitions = 0,
    this.importedPartitions = 0,
    this.activeDeviceCount = 0,
  });

  final SyncStatusState state;
  final DateTime? lastSyncTime;
  final String? errorMessage;
  final int exportedPartitions;
  final int importedPartitions;
  final int activeDeviceCount;

  SyncStatus copyWith({
    SyncStatusState? state,
    DateTime? lastSyncTime,
    String? errorMessage,
    int? exportedPartitions,
    int? importedPartitions,
    int? activeDeviceCount,
  }) {
    return SyncStatus(
      state: state ?? this.state,
      lastSyncTime: lastSyncTime ?? this.lastSyncTime,
      errorMessage: errorMessage,
      exportedPartitions: exportedPartitions ?? this.exportedPartitions,
      importedPartitions: importedPartitions ?? this.importedPartitions,
      activeDeviceCount: activeDeviceCount ?? this.activeDeviceCount,
    );
  }
}

class SyncOrchestrationService {
  static final instance = SyncOrchestrationService._();
  SyncOrchestrationService._();

  final _store = ListeningStatisticsStore.instance;
  SyncStorageDriver? _customDriver;
  Timer? _periodicTimer;
  final _statusController = StreamController<SyncStatus>.broadcast();
  SyncStatus _currentStatus = const SyncStatus();
  bool _isSyncing = false;

  /// Hook for pre-sync flush (e.g. listeningRecorder.flush()).
  Future<void> Function()? onPreSyncFlush;

  /// Hook for post-sync reactivity (e.g. invalidating Riverpod providers).
  void Function()? onPostSyncInvalidate;

  SyncStatus get currentStatus => _currentStatus;
  Stream<SyncStatus> get statusStream => _statusController.stream;

  void setCustomDriver(SyncStorageDriver? driver) {
    _customDriver = driver;
  }

  /// Resolves the intended WebDAV connection from NetworkStorageService:
  /// 1. If a valid, explicitly saved WebDAV connection ID exists, use that connection.
  /// 2. If exactly one compatible WebDAV connection exists, use it.
  /// 3. If multiple compatible WebDAV connections exist and no valid preference exists,
  ///    returns null (requiring explicit user selection in Settings → Network Storage).
  /// 4. If no compatible WebDAV connection exists, returns null.
  /// 5. If a previously saved connection is deleted or becomes incompatible,
  ///    returns null (never silently selecting another connection).
  static NetworkConnection? findIntendedWebDavConnection(
    List<NetworkConnection> connections, {
    String? preferredId,
  }) {
    final webdavConns = connections
        .where((c) => c.protocol == NetworkProtocol.webdav)
        .toList();

    // 1. Valid, explicitly saved preference ID exists
    if (preferredId != null && preferredId.isNotEmpty) {
      // Must match an existing, compatible WebDAV connection.
      // If deleted or not WebDAV, do NOT silently fallback to another connection.
      return webdavConns.where((c) => c.id == preferredId).firstOrNull;
    }

    // 2. Exactly one compatible WebDAV connection exists unambiguously
    if (webdavConns.length == 1) {
      return webdavConns.single;
    }

    // 3. Multiple compatible connections without preference, or no connections:
    // Requires explicit user selection in Settings → Network Storage.
    return null;
  }

  /// Safely resolves whether cross-device sync is enabled, migrating legacy installations.
  ///
  /// Invariants:
  /// 1. Fresh installations default to OFF.
  /// 2. If user explicitly toggled the preference, respect it unconditionally.
  /// 3. Existing installations with functioning legacy sync retain their enabled behaviour.
  Future<bool> _resolveSyncEnabled(SharedPreferences prefs) async {
    if (prefs.containsKey(_prefSyncEnabled)) {
      return prefs.getBool(_prefSyncEnabled) ?? false;
    }

    // Migration Check 1: Explicitly configured WebDAV sync URL or network connection ID.
    final hasExplicitWebDav =
        prefs.containsKey(_prefSyncWebDavUrl) &&
        (prefs.getString(_prefSyncWebDavUrl)?.trim().isNotEmpty ?? false);
    final hasExplicitConnId =
        prefs.containsKey(_prefSyncNetworkConnId) &&
        (prefs.getString(_prefSyncNetworkConnId)?.trim().isNotEmpty ?? false);
    if (hasExplicitWebDav || hasExplicitConnId) {
      _log.i('Migrating configured WebDAV sync installation: enabling sync');
      await prefs.setBool(_prefSyncEnabled, true);
      return true;
    }

    // Migration Check 2: On Windows, explicitly configured local sync directory that exists.
    final isWin = isDesktopPlatform && Platform.isWindows;
    if (isWin && prefs.containsKey(_prefSyncLocalPath)) {
      final path = prefs.getString(_prefSyncLocalPath);
      if (path != null && Directory(path).existsSync()) {
        _log.i(
          'Migrating configured Windows local sync installation: enabling sync',
        );
        await prefs.setBool(_prefSyncEnabled, true);
        return true;
      }
    }

    // Migration Check 3: Has previous sync timestamp recorded in SharedPreferences.
    final lastSyncMs = prefs.getInt(_prefSyncLastTimestamp);
    if (lastSyncMs != null && lastSyncMs > 0) {
      _log.i(
        'Migrating active sync installation (last sync timestamp in prefs): enabling sync',
      );
      await prefs.setBool(_prefSyncEnabled, true);
      return true;
    }

    // Fresh installation or unconfigured sync: default to local-only mode (OFF).
    _log.i(
      'Fresh installation or unconfigured sync: defaulting to local-only mode (sync OFF)',
    );
    await prefs.setBool(_prefSyncEnabled, false);
    return false;
  }

  /// Loads persisted sync configuration, with intelligent platform & network defaults.
  Future<SyncConfig> loadConfig() async {
    final SharedPreferences prefs;
    try {
      prefs = await SharedPreferences.getInstance().timeout(
        const Duration(milliseconds: 300),
      );
    } catch (_) {
      return const SyncConfig(enabled: false);
    }

    final enabled = await _resolveSyncEnabled(prefs);
    final isWin = isDesktopPlatform && Platform.isWindows;
    const defaultType = 'webdav';

    final savedType = prefs.getString(_prefSyncStorageType) ?? defaultType;
    final savedLocalPath = prefs.getString(_prefSyncLocalPath) ?? '';
    var savedWebDavUrl = prefs.getString(_prefSyncWebDavUrl) ?? '';
    final savedWebDavRoot =
        prefs.getString(_prefSyncWebDavRoot) ?? 'MornyeSync';
    var savedWebDavUser = prefs.getString(_prefSyncWebDavUser) ?? '';
    var savedWebDavPass = prefs.getString(_prefSyncWebDavPass) ?? '';
    var savedDeviceName = prefs.getString(_prefSyncDeviceName) ?? '';
    final savedConnId = prefs.getString(_prefSyncNetworkConnId);

    // Inspect NetworkStorageService if WebDAV URL is unconfigured or storageType is webdav
    if (savedWebDavUrl.isEmpty || savedType == 'webdav') {
      try {
        final connections = await NetworkStorageService.instance.connections();
        final matched = findIntendedWebDavConnection(
          connections,
          preferredId: savedConnId,
        );
        if (matched != null) {
          savedWebDavUrl = matched.address;
          savedWebDavUser = matched.username;
          savedWebDavPass = matched.password;
          _log.i(
            'Discovered intended WebDAV connection "${matched.name}" at ${matched.address}',
          );
        } else {
          // If no connection is deterministically matched, reset WebDAV endpoint fields
          savedWebDavUrl = '';
          savedWebDavUser = '';
          savedWebDavPass = '';
        }
      } catch (e) {
        _log.w('Could not query NetworkStorageService for WebDAV fallback: $e');
      }
    }

    if (savedDeviceName.isEmpty) {
      savedDeviceName = isWin ? 'Windows PC' : 'Mobile Phone';
    }

    // Restore last sync time into status if not loaded yet
    if (_currentStatus.lastSyncTime == null) {
      final lastMs = prefs.getInt(_prefSyncLastTimestamp);
      if (lastMs != null && lastMs > 0) {
        _currentStatus = _currentStatus.copyWith(
          lastSyncTime: DateTime.fromMillisecondsSinceEpoch(lastMs),
        );
      } else {
        try {
          final meta = await _store
              .readMetadata('last_sync_timestamp')
              .timeout(const Duration(milliseconds: 300));
          if (meta != null && int.tryParse(meta) != null) {
            final parsedMs = int.parse(meta);
            _currentStatus = _currentStatus.copyWith(
              lastSyncTime: DateTime.fromMillisecondsSinceEpoch(parsedMs),
            );
          }
        } catch (_) {}
      }
    }

    return SyncConfig(
      enabled: enabled,
      storageType: savedType,
      localPath: savedLocalPath,
      webDavUrl: savedWebDavUrl,
      webDavRootPath: savedWebDavRoot,
      webDavUsername: savedWebDavUser,
      webDavPassword: savedWebDavPass,
      deviceName: savedDeviceName,
      selectedNetworkConnectionId: savedConnId,
    );
  }

  /// Persists sync configuration.
  Future<void> saveConfig(SyncConfig config) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefSyncEnabled, config.enabled);
    await prefs.setString(_prefSyncStorageType, config.storageType);
    await prefs.setString(_prefSyncLocalPath, config.localPath);
    await prefs.setString(_prefSyncWebDavUrl, config.webDavUrl);
    await prefs.setString(_prefSyncWebDavRoot, config.webDavRootPath);
    await prefs.setString(_prefSyncWebDavUser, config.webDavUsername);
    await prefs.setString(_prefSyncWebDavPass, config.webDavPassword);
    await prefs.setString(_prefSyncDeviceName, config.deviceName);
    if (config.selectedNetworkConnectionId != null) {
      await prefs.setString(
        _prefSyncNetworkConnId,
        config.selectedNetworkConnectionId!,
      );
    } else {
      await prefs.remove(_prefSyncNetworkConnId);
    }
  }

  Future<bool> isSyncEnabled() async {
    try {
      final prefs = await SharedPreferences.getInstance().timeout(
        const Duration(milliseconds: 300),
      );
      return await _resolveSyncEnabled(prefs);
    } catch (_) {
      return false;
    }
  }

  Future<void> setSyncEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefSyncEnabled, enabled);
    if (!enabled) {
      stopPeriodicSync();
    }
    _updateStatus(_currentStatus.copyWith(state: SyncStatusState.idle));
  }

  Future<String> getDeviceId() async {
    try {
      final prefs = await SharedPreferences.getInstance().timeout(
        const Duration(milliseconds: 300),
      );
      final devId = prefs.getString('mornye_sync_device_id');
      if (devId != null && devId.isNotEmpty) return devId;
    } catch (_) {}
    return _store.deviceId();
  }

  Future<String> getDeviceName() async {
    final config = await loadConfig();
    return config.deviceName;
  }

  Future<void> setDeviceName(String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefSyncDeviceName, trimmed);
  }

  Future<void> setSelectedNetworkConnection(
    NetworkConnection? connection,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    if (connection != null) {
      await prefs.setString(_prefSyncNetworkConnId, connection.id);
      await prefs.setString(_prefSyncStorageType, 'webdav');
      await prefs.setString(_prefSyncWebDavUrl, connection.address);
      await prefs.setString(_prefSyncWebDavUser, connection.username);
      await prefs.setString(_prefSyncWebDavPass, connection.password);
    } else {
      await prefs.remove(_prefSyncNetworkConnId);
    }
  }

  Future<void> setLocalStorageType({String? localPath}) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefSyncStorageType, 'local');
    if (localPath != null && localPath.isNotEmpty) {
      await prefs.setString(_prefSyncLocalPath, localPath);
    }
    await prefs.remove(_prefSyncNetworkConnId);
  }

  /// Resolves the storage driver based on saved user preferences and environment:
  /// - Direct filesystem folder on Windows Desktop if configured for local storage and path exists.
  /// - WebDAV driver connecting to the user's remote endpoint.
  /// - Actionable error when configuration is missing or invalid.
  Future<SyncStorageDriver> resolveDriver({SyncConfig? configOverride}) async {
    if (_customDriver != null) return _customDriver!;
    final config = configOverride ?? await loadConfig();

    if (config.storageType == 'local' &&
        isDesktopPlatform &&
        Platform.isWindows) {
      if (config.localPath.isNotEmpty &&
          Directory(config.localPath).existsSync()) {
        return LocalFolderSyncDriver(config.localPath);
      }
      throw StateError(
        'The configured local sync folder does not exist or has not been selected. '
        'Please select a valid sync folder in Settings → Network Storage.',
      );
    }

    if (config.storageType == 'webdav') {
      if (config.webDavUrl.isNotEmpty) {
        return WebDavSyncDriver(
          baseUrl: config.webDavUrl,
          rootPath: config.webDavRootPath.isNotEmpty
              ? config.webDavRootPath
              : 'MornyeSync',
          username: config.webDavUsername,
          password: config.webDavPassword,
        );
      }

      // Check specific reason to provide an actionable error message
      try {
        final connections = await NetworkStorageService.instance.connections();
        final webdavConns = connections
            .where((c) => c.protocol == NetworkProtocol.webdav)
            .toList();

        if (config.selectedNetworkConnectionId != null &&
            config.selectedNetworkConnectionId!.isNotEmpty) {
          throw StateError(
            'The selected sync connection is no longer available or is not a WebDAV connection. '
            'Please select an active WebDAV connection in Settings → Network Storage.',
          );
        } else if (webdavConns.length > 1) {
          throw StateError(
            'Multiple WebDAV connections found. '
            'Please select which connection to use for synchronization in Settings → Network Storage.',
          );
        } else {
          throw StateError(
            'No compatible WebDAV connection found. '
            'Please add a WebDAV network connection in Settings → Network Storage to sync.',
          );
        }
      } catch (e) {
        if (e is StateError) rethrow;
        throw StateError(
          'No sync storage backend is available. Please configure a WebDAV network connection in Settings → Network Storage to sync.',
        );
      }
    }

    throw StateError(
      'No sync storage backend is available. Please add your WebDAV network connection in Settings → Network Storage to sync.',
    );
  }

  /// Resolves the default storage driver synchronously (fallback).
  SyncStorageDriver defaultDriver({
    String? webDavUrl,
    String? webDavUser,
    String? webDavPass,
    String? localPath,
  }) {
    if (_customDriver != null) return _customDriver!;

    if (isDesktopPlatform &&
        Platform.isWindows &&
        localPath != null &&
        localPath.isNotEmpty) {
      return LocalFolderSyncDriver(localPath);
    }

    final url = webDavUrl ?? '';
    return WebDavSyncDriver(
      baseUrl: url,
      rootPath: 'MornyeSync',
      username: webDavUser ?? '',
      password: webDavPass ?? '',
    );
  }

  void _updateStatus(SyncStatus next) {
    _currentStatus = next;
    if (!_statusController.isClosed) {
      _statusController.add(next);
    }
  }

  void startPeriodicSync({
    Duration interval = const Duration(minutes: 15),
    SyncStorageDriver? driver,
  }) {
    _periodicTimer?.cancel();
    _periodicTimer = Timer.periodic(interval, (_) async {
      if (await isSyncEnabled()) {
        synchronize(driver: driver);
      }
    });
  }

  void stopPeriodicSync() {
    _periodicTimer?.cancel();
    _periodicTimer = null;
  }

  /// Executes a complete bidirectional synchronization cycle:
  /// 1. Flushes playback recorder.
  /// 2. Verifies backend storage availability.
  /// 3. Checks remote manifest and sync epoch (handling global clears).
  /// 4. Pushes local dirty monthly partitions.
  /// 5. Discovers and transactionally ingests peer device partitions.
  /// 6. Triggers provider invalidation and updates sync status.
  Future<SyncStatus> synchronize({
    SyncStorageDriver? driver,
    String deviceName = '',
  }) async {
    if (_isSyncing) return _currentStatus;

    // Strict Local-Only Mode invariant: if sync is disabled, do nothing!
    final enabled = await isSyncEnabled();
    if (!enabled) {
      _log.i('Cross-device sync is disabled. Skipping synchronization.');
      return _currentStatus;
    }

    _isSyncing = true;
    _updateStatus(_currentStatus.copyWith(state: SyncStatusState.syncing));

    try {
      // 1. Pre-sync recorder flush
      try {
        await listeningRecorder.flush();
      } catch (e) {
        _log.w('Pre-sync listeningRecorder.flush encountered an error: $e');
      }
      if (onPreSyncFlush != null) {
        await onPreSyncFlush!();
      }

      final storage = driver ?? await resolveDriver();
      if (!await storage.isAvailable()) {
        throw StateError(
          'Sync storage backend is unreachable. Please verify your connection or storage path.',
        );
      }

      final resolvedDeviceName = deviceName.isNotEmpty
          ? deviceName
          : (await loadConfig()).deviceName;

      final localDevId = await _store.deviceId();
      var localEpoch = await _store.currentSyncEpoch();
      final nowUtc = DateTime.now().toUtc();
      final nowIso = nowUtc.toIso8601String();
      final nowMs = nowUtc.millisecondsSinceEpoch;

      // 2. Discover remote manifest (fail safely if storage read throws unexpectedly)
      SyncManifest? manifest;
      try {
        final manifestRaw = await storage.readText('manifest.json');
        manifest = SyncManifest.deserialize(manifestRaw);
      } catch (e) {
        try {
          final s = await storage.stat('manifest.json');
          if (s != null) {
            // manifest.json exists on storage but read/parse failed: abort to prevent data loss
            throw StateError('Failed to read existing manifest.json: $e');
          }
        } catch (inner) {
          if (inner is StateError) rethrow;
          _log.w('Storage stat/read for manifest.json failed: $e');
        }
      }

      // 3. Epoch verification (Global Clear History handling)
      if (manifest != null && manifest.syncEpoch > localEpoch) {
        _log.i(
          'Remote epoch (${manifest.syncEpoch}) is newer than local ($localEpoch). Purging pre-epoch history.',
        );
        await _store.clearAllHistory(newEpoch: manifest.syncEpoch);
        localEpoch = manifest.syncEpoch;
      }

      // Check for global tombstone if manifest is missing or equal
      try {
        final tombstoneRaw = await storage.readText('tombstone.json');
        final tombstone = SyncTombstone.deserialize(tombstoneRaw);
        if (tombstone != null && tombstone.newEpoch > localEpoch) {
          _log.i(
            'Observing global tombstone for epoch ${tombstone.newEpoch}. Resetting local database.',
          );
          await _store.clearAllHistory(newEpoch: tombstone.newEpoch);
          localEpoch = tombstone.newEpoch;
        }
      } catch (_) {}

      // Discover existing peer device directories on storage so devices are never dropped
      final discoveredStorageDeviceIds = <String>{};
      try {
        final deviceFolders = await storage.listFiles('listening/devices');
        for (final df in deviceFolders) {
          if (df.isDirectory &&
              df.name.startsWith('dev_') &&
              df.name != localDevId &&
              !df.name.startsWith('.')) {
            discoveredStorageDeviceIds.add(df.name);
          }
        }
      } catch (_) {}

      // Discover devices already known in local SQLite database
      final localKnownIds = await _store.knownDeviceIds();

      // Ensure storage directory structure exists
      await storage.createDirectory('listening/devices/$localDevId');

      // Update / register this device in the manifest
      final currentPlatform = Platform.operatingSystem.toLowerCase();
      final localRegistration = SyncDeviceRegistration(
        id: localDevId,
        platform: currentPlatform,
        deviceName: resolvedDeviceName,
        lastActive: nowIso,
      );

      // Re-read remote manifest before writing to catch concurrent writes from other devices
      SyncManifest? latestRemote;
      try {
        final remoteRaw = await storage.readText('manifest.json');
        latestRemote = SyncManifest.deserialize(remoteRaw);
      } catch (_) {}

      // Epoch guard: do not overwrite a newer remote sync epoch
      if (latestRemote != null && latestRemote.syncEpoch > localEpoch) {
        _log.w(
          'Remote manifest epoch (${latestRemote.syncEpoch}) is newer than local ($localEpoch). Postponing manifest write until epoch is ingested.',
        );
      } else {
        final baseManifest =
            manifest ??
            latestRemote ??
            SyncManifest(
              protocolVersion: 1,
              syncEpoch: localEpoch,
              epochId:
                  'epoch_${nowUtc.year}${nowUtc.month.toString().padLeft(2, '0')}_001',
              app: 'Mornye',
              updatedAt: nowMs,
            );

        // Build list of all valid peer IDs that must be retained in manifest:
        // Remote devices + local known devices + storage partition folders
        final allValidPeerIds = <String>{
          ...baseManifest.devices.map((d) => d.id),
          if (latestRemote != null) ...latestRemote.devices.map((d) => d.id),
          ...localKnownIds.where((id) => id != localDevId),
          ...discoveredStorageDeviceIds,
        };

        final existingRegisteredIds = <String>{
          ...baseManifest.devices.map((d) => d.id),
          if (latestRemote != null) ...latestRemote.devices.map((d) => d.id),
          localDevId,
        };
        final recoveredDevices = <SyncDeviceRegistration>[];
        for (final peerId in allValidPeerIds) {
          if (!existingRegisteredIds.contains(peerId)) {
            final plat = peerId.startsWith('dev_windows_')
                ? 'windows'
                : (peerId.startsWith('dev_android_')
                      ? 'android'
                      : (peerId.startsWith('dev_ios_')
                            ? 'ios'
                            : (peerId.startsWith('dev_linux_')
                                  ? 'linux'
                                  : (peerId.startsWith('dev_macos_')
                                        ? 'macos'
                                        : 'unknown'))));
            final name = plat == 'windows'
                ? 'Windows PC'
                : (plat == 'android' ? 'Mobile Phone' : 'Remote Device');
            recoveredDevices.add(
              SyncDeviceRegistration(
                id: peerId,
                platform: plat,
                deviceName: name,
                lastActive: nowIso,
              ),
            );
          }
        }

        final updatedManifest = baseManifest.mergeWith(
          latestRemote,
          localDevice: localRegistration,
          recoveredDevices: recoveredDevices,
          validPartitionDeviceIds: allValidPeerIds,
          nowMs: nowMs,
        );
        await storage.writeText('manifest.json', updatedManifest.serialize());
        manifest = updatedManifest;
      }

      // 4. Push local dirty months
      var exportedCount = 0;
      final dirtyMonths = await _store.dirtyMonths();
      for (final month in dirtyMonths) {
        final records = await _store.getRecordsForMonth(localDevId, month);
        final partition = MonthlyPartition(
          version: 1,
          syncEpoch: localEpoch,
          deviceId: localDevId,
          devicePlatform: currentPlatform,
          month: month,
          generatedAt: nowIso,
          records: [
            for (final r in records)
              SyncTrackRecord(
                day: r['day'] as String,
                canonicalKey: r['track_key'] as String,
                title: r['title'] as String,
                artist: r['artist'] as String,
                album: r['album'] as String,
                artwork: r['artwork'] as String?,
                milliseconds: r['milliseconds'] as int,
                plays: r['plays'] as int,
                updatedAt: r['updated_at'] as int? ?? nowMs,
              ),
          ],
        );

        final partitionPath = 'listening/devices/$localDevId/$month.json';
        await storage.writeText(partitionPath, partition.serialize());
        await _store.markMonthClean(month);
        exportedCount++;
      }

      // 5. Discover and ingest peer device partitions
      var importedCount = 0;
      final candidatePeerIds = <String>{
        if (manifest != null)
          ...manifest.devices.where((d) => d.id != localDevId).map((d) => d.id),
        ...discoveredStorageDeviceIds,
      };

      for (final peerDeviceId in candidatePeerIds) {
        final partitions = await storage.listFiles(
          'listening/devices/$peerDeviceId',
        );
        for (final file in partitions) {
          if (!file.name.endsWith('.json')) continue;
          final month = file.name.replaceAll('.json', '');
          if (!RegExp(r'^\d{4}-\d{2}$').hasMatch(month)) continue;

          try {
            final jsonRaw = await storage.readText(
              'listening/devices/$peerDeviceId/${file.name}',
            );
            final parsed = MonthlyPartition.deserialize(jsonRaw);
            if (parsed == null) continue;

            // Ingest peer partition records transactionally (idempotent replacement)
            await _store.replaceDeviceMonthRecords(peerDeviceId, month, [
              for (final r in parsed.records)
                {
                  'day': r.day,
                  'track_key': r.canonicalKey,
                  'title': r.title,
                  'artist': r.artist,
                  'album': r.album,
                  'artwork': r.artwork,
                  'milliseconds': r.milliseconds,
                  'plays': r.plays,
                  'updated_at': r.updatedAt,
                },
            ]);
            importedCount++;
          } catch (e) {
            _log.w('Error ingesting partition ${file.path}: $e');
          }
        }
      }

      // 6. Post-sync reactivity
      if (onPostSyncInvalidate != null) {
        onPostSyncInvalidate!();
      }

      // Persist last successful sync timestamp in metadata and prefs
      try {
        await _store.writeMetadata('last_sync_timestamp', nowMs.toString());
        final prefs = await SharedPreferences.getInstance();
        await prefs.setInt(_prefSyncLastTimestamp, nowMs);
      } catch (e) {
        _log.w('Could not record last_sync_timestamp: $e');
      }

      final result = SyncStatus(
        state: SyncStatusState.success,
        lastSyncTime: DateTime.fromMillisecondsSinceEpoch(nowMs),
        exportedPartitions: exportedCount,
        importedPartitions: importedCount,
        activeDeviceCount: (manifest?.countActiveDevices() ?? 1),
      );
      _updateStatus(result);
      return result;
    } catch (error) {
      _log.e('Sync failed: $error');
      final result = _currentStatus.copyWith(
        state: SyncStatusState.error,
        errorMessage: error.toString(),
      );
      _updateStatus(result);
      return result;
    } finally {
      _isSyncing = false;
    }
  }

  /// User action: Clear history on this device only.
  /// Removes local device rows, updates summary table, and publishes an empty partition.
  Future<void> clearThisDeviceOnly({SyncStorageDriver? driver}) async {
    final storage = driver ?? defaultDriver();
    await _store.clearThisDeviceHistory();
    if (await isSyncEnabled()) {
      // Synchronize will upload the pruned/empty dirty months
      await synchronize(driver: storage);
    }
  }

  /// User action: Clear history across all synced devices.
  /// Advances sync epoch, writes global tombstone, and purges local database.
  Future<void> clearAcrossAllDevices({SyncStorageDriver? driver}) async {
    if (!await isSyncEnabled()) {
      _log.w('Cannot clear across all devices: cross-device sync is disabled.');
      return;
    }
    final storage = driver ?? defaultDriver();
    final localDevId = await _store.deviceId();
    final oldEpoch = await _store.currentSyncEpoch();
    final newEpoch = oldEpoch + 1;
    final nowMs = DateTime.now().toUtc().millisecondsSinceEpoch;

    // 1. Purge local database
    await _store.clearAllHistory(newEpoch: newEpoch);

    // 2. Publish tombstone
    final tombstone = SyncTombstone(
      action: 'global_clear_history',
      targetEpoch: oldEpoch,
      newEpoch: newEpoch,
      issuedBy: localDevId,
      issuedAt: nowMs,
      comment: 'User initiated clear across all devices',
    );
    await storage.writeText('tombstone.json', tombstone.serialize());

    // 3. Update manifest with new epoch
    final manifest = SyncManifest(
      protocolVersion: 1,
      syncEpoch: newEpoch,
      epochId: 'epoch_${DateTime.now().year}_$newEpoch',
      app: 'Mornye',
      updatedAt: nowMs,
      devices: [
        SyncDeviceRegistration(
          id: localDevId,
          platform: Platform.operatingSystem.toLowerCase(),
          deviceName: isDesktopPlatform ? 'Windows PC' : 'Mobile Phone',
          lastActive: DateTime.now().toUtc().toIso8601String(),
        ),
      ],
    );
    await storage.writeText('manifest.json', manifest.serialize());

    // 4. Invalidate UI
    if (onPostSyncInvalidate != null) {
      onPostSyncInvalidate!();
    }
  }
}
