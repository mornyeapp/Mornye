import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mornye/services/backend/backend_channel.dart';
import 'package:mornye/services/desktop_diagnostics.dart';
import 'package:mornye/services/download_request_payload.dart';
import 'package:mornye/utils/audio_format_utils.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:mornye/utils/file_access.dart';
import 'package:mornye/utils/hash_utils.dart';
import 'package:mornye/utils/logger.dart';

part 'platform_bridge/bridge_codec.dart';
part 'platform_bridge/bridge_events.dart';
part 'platform_bridge/bridge_library_scan.dart';
part 'platform_bridge/bridge_lookup_cache.dart';
part 'platform_bridge/bridge_native_worker.dart';
part 'platform_bridge/bridge_saf.dart';

final _log = AppLogger('PlatformBridge');

const foregroundServiceStartNotAllowedCode =
    'foreground_service_start_not_allowed';

bool isForegroundServiceStartNotAllowed(Object error) {
  return error is PlatformException &&
      error.code == foregroundServiceStartNotAllowedCode;
}

class InstallationState {
  final bool markerExisted;
  final bool markerCreated;
  final bool freshPackageInstall;

  const InstallationState({
    required this.markerExisted,
    required this.markerCreated,
    required this.freshPackageInstall,
  });

  const InstallationState.unsupported()
    : markerExisted = true,
      markerCreated = true,
      freshPackageInstall = false;

  factory InstallationState.fromMap(Map<String, dynamic> map) {
    return InstallationState(
      markerExisted: map['marker_existed'] == true,
      markerCreated: map['marker_created'] == true,
      freshPackageInstall: map['fresh_package_install'] == true,
    );
  }
}

bool shouldResetRestoredInstallation({
  required bool hasPersistedSettings,
  required InstallationState installState,
}) {
  return hasPersistedSettings &&
      !installState.markerExisted &&
      installState.markerCreated &&
      installState.freshPackageInstall;
}

class PlatformBridge {
  /// Sentinel shared with Android's foreground service for progress reports
  /// that contain a percentage but no byte counts.
  static const int notificationPercentTotal = 10000;

  /// MethodChannel on Android and iOS, the Rust library on desktop.
  static BackendChannel get _channel => backendChannel;

  static int _nativeDataJobSerial = 0;
  static final _nativeDataJobs = <String, Set<_NativeDataJobState>>{};

  /// A single background native operation. Binary inputs never become base64
  /// JSON, and large request/result codecs stay off the UI isolate.
  static Future<Map<String, dynamic>> runNativeDataJob(
    Map<String, dynamic> request, {
    Uint8List? bytes,
    String? requestId,
  }) async {
    final id =
        requestId ??
        'data_${DateTime.now().microsecondsSinceEpoch}_${_nativeDataJobSerial++}';
    final state = _NativeDataJobState();
    final states = _nativeDataJobs.putIfAbsent(id, () => {});
    states.add(state);
    try {
      final encoded = await compute(_encodeJsonInBackground, request);
      if (state.cancelled) {
        throw PlatformException(
          code: 'CANCELLED',
          message: 'Native data job cancelled',
        );
      }
      state.dispatched = true;
      Object? result;
      try {
        result = await _channel.invokeMethod('runNativeDataJob', {
          'request_json': encoded,
          'request_id': id,
          'bytes': ?bytes,
        });
      } finally {
        state.dispatched = false;
      }
      return await _decodeRequiredMapResultAsync(result, 'runNativeDataJob');
    } finally {
      states.remove(state);
      if (states.isEmpty) _nativeDataJobs.remove(id);
    }
  }

  static Future<void> cancelNativeDataJob(String requestId) async {
    final states = _nativeDataJobs[requestId];
    if (states == null) return;
    for (final state in states) {
      state.cancelled = true;
    }
    if (states.any((state) => state.dispatched)) {
      await _channel.invokeMethod<void>('cancelNativeDataJob', {
        'request_id': requestId,
      });
    }
  }

  static Future<void> setScreenAwake(bool enabled) async {
    if (defaultTargetPlatform != TargetPlatform.android &&
        defaultTargetPlatform != TargetPlatform.iOS) {
      return;
    }
    await _channel.invokeMethod<void>('setScreenAwake', {'enabled': enabled});
  }

  /// Whether this Android device is on external power; false elsewhere.
  static Future<bool> isCharging() async {
    if (!Platform.isAndroid) return false;
    return await _channel.invokeMethod<bool>('isCharging') ?? false;
  }

  static const _jsonResultFileKey = '__json_file';
  static const _backgroundJsonDecodeThresholdBytes = 128 * 1024;
  static const _metadataCacheTtl = Duration(minutes: 20);
  static const _urlHandleCacheTtl = Duration(minutes: 5);
  static const _customSearchCacheTtl = Duration(minutes: 2);
  static const _bridgeCacheMaxEntries = 256;
  // Bound retained JSON containers as well as strings. Entry counts alone do
  // not bound album/playlist responses, which can contain thousands of tracks.
  static const _bridgeCacheMaxEntryBytes = 4 * 1024 * 1024;
  static const _bridgeCacheMaxBytes = 8 * 1024 * 1024;
  static const _persistentCacheMaxEntryBytes = 1024 * 1024;
  static const _persistentCacheMaxBytes = 2 * 1024 * 1024;
  static const _defaultLookupCachePersistDebounce = Duration(milliseconds: 500);
  static Duration _lookupCachePersistDebounce =
      _defaultLookupCachePersistDebounce;
  static const _metadataPersistentCacheKey = 'bridge_metadata_lookup_cache_v1';
  static final Map<String, _BridgeCacheEntry<Map<String, dynamic>>>
  _metadataCache = {};
  static final Map<String, _BridgeCacheEntry<Map<String, dynamic>>>
  _urlHandleCache = {};
  static final Map<String, _BridgeCacheEntry<List<Map<String, dynamic>>>>
  _customSearchCache = {};
  static final Map<String, Future<Map<String, dynamic>>> _metadataInFlight = {};
  static final Map<String, Future<Map<String, dynamic>?>> _urlHandleInFlight =
      {};
  static final Map<String, _BridgeInFlight<List<Map<String, dynamic>>>>
  _customSearchInFlight = {};
  static final Map<String, _BridgeInFlight<Map<String, dynamic>?>>
  _homeFeedInFlight = {};
  static Future<void>? _persistentLookupCacheLoadFuture;
  static int _lookupCacheGeneration = 0;
  static Timer? _lookupCachePersistTimer;
  static Future<void>? _lookupCachePersistInFlight;
  static bool _lookupCachePersistDirty = false;
  static int _extensionRequestSequence = 0;
  static final StreamController<ExtensionSessionGrantEvent>
  _extensionSessionGrantEvents =
      StreamController<ExtensionSessionGrantEvent>.broadcast();
  static final StreamController<void> _libraryStorageEvents =
      StreamController<void>.broadcast();
  static final StreamController<void> _verificationNotificationEvents =
      StreamController<void>.broadcast();
  static final StreamController<void> _setupFolderSelectionEvents =
      StreamController<void>.broadcast();
  static final StreamController<void> _extensionAuthCallbackEvents =
      StreamController<void>.broadcast();
  static final StreamController<List<String>>
  _iosBackgroundDownloadExpirationEvents =
      StreamController<List<String>>.broadcast();
  static final StreamController<String> _discordPresenceStatusEvents =
      StreamController<String>.broadcast();
  static final StreamController<String> _libraryFolderChangeEvents =
      StreamController<String>.broadcast();
  static final StreamController<Map<String, dynamic>> _linkRequestEvents =
      StreamController<Map<String, dynamic>>.broadcast();
  static final StreamController<Map<String, dynamic>> _linkMessageEvents =
      StreamController<Map<String, dynamic>>.broadcast();
  static final StreamController<Map<String, dynamic>> _linkClientEvents =
      StreamController<Map<String, dynamic>>.broadcast();
  static final StreamController<Map<String, dynamic>> _linkPairedEvents =
      StreamController<Map<String, dynamic>>.broadcast();
  static final StreamController<String> _linkPairingEndedEvents =
      StreamController<String>.broadcast();
  static bool _backendEventHandlerInstalled = false;

  /// The Rust backend answers on Android and iOS through the MethodChannel
  /// and on desktop through dart:ffi, with plain filesystem paths.
  static bool get supportsCoreBackend =>
      Platform.isAndroid || Platform.isIOS || isDesktopPlatform;

  static bool get supportsExtensionSystem => supportsCoreBackend;

  static Stream<T> _events<T>(StreamController<T> controller) {
    _ensureBackendEventHandler();
    return controller.stream;
  }

  static Stream<ExtensionSessionGrantEvent> extensionSessionGrantEvents() =>
      _events(_extensionSessionGrantEvents);

  static Stream<void> libraryStorageEvents() => _events(_libraryStorageEvents);

  static Stream<void> verificationNotificationEvents() =>
      _events(_verificationNotificationEvents);

  static Stream<void> setupFolderSelectionEvents() =>
      _events(_setupFolderSelectionEvents);

  static Stream<void> extensionAuthCallbackEvents() =>
      _events(_extensionAuthCallbackEvents);

  static Future<void> processPendingExtensionCallbacks() =>
      _channel.invokeMethod<void>('processPendingExtensionCallbacks');

  /// Desktop only: hands a `mornye://` URL the OS delivered to the backend.
  /// Returns false when it is not an extension callback. The backend then
  /// raises `extensionAuthCallbackReceived`, as the mobile hosts do.
  static Future<bool> queueExtensionCallbackUrl(String url) async {
    if (!isDesktopPlatform) return false;
    final queued = await _channel.invokeMethod<bool>(
      'queueExtensionCallbackUrl',
      {'url': url},
    );
    return queued == true;
  }

  /// Desktop only: keeps the computer from idle sleeping while downloads
  /// run. Idempotent; returns whether the OS granted the request.
  static Future<bool> beginKeepAwake({
    String reason = 'Downloading music',
  }) async {
    if (!isDesktopPlatform) return false;
    final granted = await _channel.invokeMethod<bool>('beginKeepAwake', {
      'reason': reason,
    });
    return granted == true;
  }

  /// Desktop only: releases [beginKeepAwake]. Safe without a prior begin.
  static Future<void> endKeepAwake() async {
    if (!isDesktopPlatform) return;
    await _channel.invokeMethod<bool>('endKeepAwake');
  }

  /// Desktop Discord Rich Presence (`discordPresenceInitialize`, `Update`,
  /// `Clear`, `Shutdown`) over Discord's local IPC in the Rust backend.
  static Future<T?> invokeDiscordPresence<T>(
    String method, [
    Object? arguments,
  ]) => _channel.invokeMethod<T>(method, arguments);

  /// Desktop Discord status changes: `active` or `unavailable`.
  static Stream<String> discordPresenceStatusEvents() =>
      _events(_discordPresenceStatusEvents);

  /// Desktop only: replaces the watched library folders. Returns the folders
  /// that are being watched.
  static Future<List<String>> watchLibraryFolders(List<String> paths) async {
    if (!isDesktopPlatform) return const [];
    final watched = await _channel.invokeMethod<List<dynamic>>(
      'watchLibraryFolders',
      {'paths': paths},
    );
    return [for (final path in watched ?? const []) path.toString()];
  }

  static Future<void> unwatchLibraryFolders() async {
    if (!isDesktopPlatform) return;
    await _channel.invokeMethod<void>('unwatchLibraryFolders');
  }

  /// Desktop watched library roots whose content changed (throttled).
  static Stream<String> libraryFolderChangeEvents() =>
      _events(_libraryFolderChangeEvents);

  static Future<String?> consumeVerificationNotification() =>
      _channel.invokeMethod<String>('consumeVerificationNotification');

  static Stream<List<String>> iosBackgroundDownloadExpirationEvents() =>
      _events(_iosBackgroundDownloadExpirationEvents);

  // Mornye Link, the desktop server phones connect to. The Rust backend owns
  // the server; these calls and events follow the bridge table of the link
  // contract.

  /// Starts the server as [name]; returns `port`, `fingerprint`, `serverId`,
  /// `name` and `addresses`.
  static Future<Map<String, dynamic>> linkStart({
    required String name,
    int? port,
  }) async => _linkMap(
    await _channel.invokeMethod('linkStart', {'name': name, 'port': ?port}),
  );

  static Future<void> linkStop() => _invokeVoid('linkStop');

  /// `running`, `port`, `fingerprint`, `serverId`, `name`, `addresses` and
  /// the connected `clients`.
  static Future<Map<String, dynamic>> linkStatus() async =>
      _linkMap(await _channel.invokeMethod('linkStatus'));

  /// Hands the NDJSON catalog at [path] to the server; returns `songs` and
  /// `version`.
  static Future<Map<String, dynamic>> linkSetCatalog(String path) async =>
      _linkMap(await _channel.invokeMethod('linkSetCatalog', {'path': path}));

  /// Opens a pairing window: `pin`, `expiresMs` and `fingerprint`.
  static Future<Map<String, dynamic>> linkBeginPairing() async =>
      _linkMap(await _channel.invokeMethod('linkBeginPairing'));

  static Future<void> linkEndPairing() => _invokeVoid('linkEndPairing');

  /// Paired devices and Subsonic app keys.
  static Future<List<Map<String, dynamic>>> linkDevices() async {
    final result = await _channel.invokeMethod<List<dynamic>>('linkDevices');
    return [
      for (final device in result ?? const [])
        if (device is Map) _linkMap(device),
    ];
  }

  static Future<void> linkRevoke(String deviceId) =>
      _invokeVoid('linkRevoke', {'deviceId': deviceId});

  /// Mints a key for a third-party Subsonic app: `deviceId` and `apiKey`.
  static Future<Map<String, dynamic>> linkCreateKey(String name) async =>
      _linkMap(await _channel.invokeMethod('linkCreateKey', {'name': name}));

  /// Answers a `linkRequest` with [result], or with [error] (`code`,
  /// `message`).
  static Future<void> linkReply(
    String requestId, {
    Object? result,
    Map<String, dynamic>? error,
  }) => _invokeVoid('linkReply', {
    'requestId': requestId,
    if (error != null) 'error': error else 'result': result,
  });

  /// Sends [message] over the WebSocket of [deviceId], or of every connected
  /// phone when null. Returns how many received it.
  static Future<int> linkSend(
    Map<String, dynamic> message, {
    String? deviceId,
  }) async {
    final result = _linkMap(
      await _channel.invokeMethod('linkSend', {
        'deviceId': ?deviceId,
        'message': message,
      }),
    );
    return (result['delivered'] as num?)?.toInt() ?? 0;
  }

  /// Forwarded requests: `requestId`, `op`, `deviceId` and `args`.
  static Stream<Map<String, dynamic>> linkRequestEvents() =>
      _events(_linkRequestEvents);

  /// WebSocket messages from phones: `deviceId` and `message`.
  static Stream<Map<String, dynamic>> linkMessageEvents() =>
      _events(_linkMessageEvents);

  /// The connected phones whenever one connects or disconnects: `clients`.
  static Stream<Map<String, dynamic>> linkClientEvents() =>
      _events(_linkClientEvents);

  /// A phone finished pairing: `deviceId`, `name` and `platform`.
  static Stream<Map<String, dynamic>> linkPairedEvents() =>
      _events(_linkPairedEvents);

  /// Why a pairing window closed: `paired`, `expired`, `attempts` or
  /// `cancelled`.
  static Stream<String> linkPairingEndedEvents() =>
      _events(_linkPairingEndedEvents);

  static Map<String, dynamic> _linkMap(Object? value) => value is Map
      ? value.map((key, value) => MapEntry(key.toString(), value))
      : <String, dynamic>{};

  static void _ensureBackendEventHandler() {
    if (_backendEventHandlerInstalled) return;
    _backendEventHandlerInstalled = true;
    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'extensionAuthCallbackReceived':
          _extensionAuthCallbackEvents.add(null);
          return null;
        case 'setupFolderSelectionChanged':
          _setupFolderSelectionEvents.add(null);
          return null;
        case 'libraryScanError':
          final args = call.arguments;
          if (args is Map) {
            final path = args['path']?.toString() ?? '';
            final operation = args['operation']?.toString() ?? 'scan';
            final message = args['message']?.toString() ?? 'Unknown error';
            AppLogger('LocalLibrary').e('$operation [$path]: $message');
          }
          return null;
        case 'extensionSessionGrantCompleted':
          final args = call.arguments;
          if (args is Map) {
            final extensionId = args['extension_id']?.toString().trim() ?? '';
            if (extensionId.isNotEmpty) {
              _extensionSessionGrantEvents.add(
                ExtensionSessionGrantEvent(
                  extensionId: extensionId,
                  success: args['success'] != false,
                ),
              );
            }
          }
          return null;
        case 'libraryStorageChanged':
          _libraryStorageEvents.add(null);
          return null;
        case 'discordPresenceStatus':
          final status = call.arguments;
          if (status is String) _discordPresenceStatusEvents.add(status);
          return null;
        case 'libraryFolderChanged':
          final args = call.arguments;
          final root = args is Map ? args['root']?.toString() ?? '' : '';
          if (root.isNotEmpty) _libraryFolderChangeEvents.add(root);
          return null;
        case 'linkRequest':
          if (call.arguments is Map) {
            _linkRequestEvents.add(_linkMap(call.arguments));
          }
          return null;
        case 'linkMessage':
          if (call.arguments is Map) {
            _linkMessageEvents.add(_linkMap(call.arguments));
          }
          return null;
        case 'linkClients':
          if (call.arguments is Map) {
            _linkClientEvents.add(_linkMap(call.arguments));
          }
          return null;
        case 'linkPaired':
          if (call.arguments is Map) {
            _linkPairedEvents.add(_linkMap(call.arguments));
          }
          return null;
        case 'linkPairingEnded':
          final args = call.arguments;
          final reason = args is Map ? args['reason']?.toString() : null;
          _linkPairingEndedEvents.add(reason ?? 'cancelled');
          return null;
        case 'extensionVerificationNotificationTapped':
          _verificationNotificationEvents.add(null);
          return null;
        case 'iosBackgroundDownloadExpired':
          final raw = call.arguments;
          var itemIds = const <String>[];
          try {
            final decoded = raw is String ? jsonDecode(raw) : raw;
            if (decoded is List) {
              itemIds = decoded
                  .map((value) => value.toString().trim())
                  .where((value) => value.isNotEmpty)
                  .toSet()
                  .toList(growable: false);
            }
          } catch (_) {
            // Older/native-mismatched builds may send no payload. The queue
            // still pauses its currently visible active items below.
          }
          _iosBackgroundDownloadExpirationEvents.add(itemIds);
          return null;
        default:
          return null;
      }
    });
  }

  static Future<Map<String, dynamic>> _invokeMap(
    String method, [
    dynamic args,
  ]) async {
    final result = await _channel.invokeMethod(method, args);
    return _decodeRequiredMapResultAsync(result, method);
  }

  static Future<void> _invokeVoid(String method, [dynamic args]) async {
    await _channel.invokeMethod(method, args);
  }

  static Future<T> _invokeAs<T>(String method, [dynamic args]) async =>
      (await _channel.invokeMethod(method, args)) as T;

  static Future<T> _invokeDecoded<T>(
    FutureOr<T> Function(dynamic result, String method) decode,
    String method, [
    dynamic args,
  ]) async => decode(await _channel.invokeMethod(method, args), method);

  static Future<InstallationState> ensureInstallMarker() async {
    if (!Platform.isAndroid) return const InstallationState.unsupported();
    final result = await _invokeMap('ensureInstallMarker');
    return InstallationState.fromMap(result);
  }

  static Future<void> prepareRuntimeState(String dataDir) async {
    if (!Platform.isAndroid) return;
    await _invokeMap('prepareRuntimeState', {'data_dir': dataDir});
  }

  static Future<Map<String, dynamic>> _cachedInvoke(
    String cacheKey,
    Map<String, _BridgeCacheEntry<Map<String, dynamic>>> cache,
    Map<String, Future<Map<String, dynamic>>> inFlight,
    Duration ttl,
    String persistentCacheKey,
    Future<Map<String, dynamic>> Function() loader,
  ) async {
    await _ensurePersistentLookupCachesLoaded();
    final cached = _getCachedMap(cache, cacheKey);
    if (cached != null) return cached;

    final pending = inFlight[cacheKey];
    if (pending != null) return _copyStringMap(await pending);

    final generation = _lookupCacheGeneration;
    final future = () async {
      final value = await loader();
      if (generation == _lookupCacheGeneration) {
        _putCachedMap(cache, cacheKey, value, ttl, persistentCacheKey);
      }
      return value;
    }();
    inFlight[cacheKey] = future;
    try {
      return _copyStringMap(await future);
    } finally {
      if (identical(inFlight[cacheKey], future)) {
        inFlight.remove(cacheKey);
      }
    }
  }

  static String _providerMetadataCacheKey(
    String providerId,
    String resourceType,
    String resourceId,
  ) {
    return [
      providerId.trim().toLowerCase(),
      resourceType.trim().toLowerCase(),
      resourceId.trim(),
    ].join(':');
  }

  static Map<String, dynamic>? _getCachedMap(
    Map<String, _BridgeCacheEntry<Map<String, dynamic>>> cache,
    String key,
  ) {
    _pruneExpiredBridgeCache(cache);
    final entry = cache[key];
    if (entry == null) return null;
    if (entry.isExpired) {
      cache.remove(key);
      return null;
    }
    return _copyStringMap(entry.value);
  }

  static void _putCachedMap(
    Map<String, _BridgeCacheEntry<Map<String, dynamic>>> cache,
    String key,
    Map<String, dynamic> value,
    Duration ttl,
    String persistentCacheKey,
  ) {
    _putMemoryCached<Map<String, dynamic>>(cache, key, value, ttl);
    _scheduleLookupCachePersist(
      cache,
      persistentCacheKey,
      _lookupCacheGeneration,
    );
  }

  /// Conservative retained-size estimate, with early exit for oversized JSON.
  /// Avoids allocating another encoded response just to decide cache admission.
  static int _payloadBytes(Object? value) {
    var bytes = 0;
    void visit(Object? item) {
      if (bytes > _bridgeCacheMaxEntryBytes) return;
      if (item is String) {
        bytes += 32 + item.length * 2;
      } else if (item is Map) {
        bytes += 64;
        for (final entry in item.entries) {
          bytes += 48;
          visit(entry.key);
          visit(entry.value);
          if (bytes > _bridgeCacheMaxEntryBytes) break;
        }
      } else if (item is List) {
        bytes += 32 + item.length * 8;
        for (final entry in item) {
          visit(entry);
          if (bytes > _bridgeCacheMaxEntryBytes) break;
        }
      } else {
        bytes += 16;
      }
    }

    visit(value);
    return bytes;
  }

  static void _pruneExpiredBridgeCache<T>(
    Map<String, _BridgeCacheEntry<T>> cache,
  ) {
    if (cache.isEmpty) return;
    final now = DateTime.now();
    cache.removeWhere((_, entry) => now.isAfter(entry.expiresAt));
  }

  static dynamic _copyJsonLike(dynamic value) {
    if (value is Map) {
      return <String, dynamic>{
        for (final entry in value.entries)
          entry.key.toString(): _copyJsonLike(entry.value),
      };
    }
    if (value is List) {
      return value.map(_copyJsonLike).toList(growable: false);
    }
    return value;
  }

  static Map<String, dynamic> _copyStringMap(Map<String, dynamic> value) {
    return <String, dynamic>{
      for (final entry in value.entries) entry.key: _copyJsonLike(entry.value),
    };
  }

  static Map<String, dynamic>? _copyNullableStringMap(
    Map<String, dynamic>? value,
  ) {
    if (value == null) return null;
    return _copyStringMap(value);
  }

  static List<Map<String, dynamic>> _copyMapList(
    List<Map<String, dynamic>> value,
  ) {
    return value.map(_copyStringMap).toList(growable: false);
  }

  static dynamic _canonicalizeJsonLike(dynamic value) {
    if (value is Map) {
      final entries = value.entries.toList()
        ..sort((a, b) => a.key.toString().compareTo(b.key.toString()));
      return <String, dynamic>{
        for (final entry in entries)
          entry.key.toString(): _canonicalizeJsonLike(entry.value),
      };
    }
    if (value is List) {
      return value.map(_canonicalizeJsonLike).toList(growable: false);
    }
    return value;
  }

  static Future<void> _ensurePersistentLookupCachesLoaded() {
    return _persistentLookupCacheLoadFuture ??= _loadPersistentLookupCaches(
      _lookupCacheGeneration,
    );
  }

  static Future<void> _loadPersistentLookupCaches(int generation) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (generation != _lookupCacheGeneration) return;
      await _restorePersistentCache(
        prefs,
        _metadataPersistentCacheKey,
        _metadataCache,
        generation,
      );
    } catch (e) {
      _log.w('Failed to load bridge lookup cache: $e');
    }
  }

  static Future<void> _restorePersistentCache(
    SharedPreferences prefs,
    String prefsKey,
    Map<String, _BridgeCacheEntry<Map<String, dynamic>>> target,
    int generation,
  ) async {
    final raw = prefs.getString(prefsKey);
    if (raw == null || raw.isEmpty) return;
    if (raw.length > _persistentCacheMaxBytes) {
      await prefs.remove(prefsKey);
      return;
    }

    final decoded = await _decodeJsonStringAsync(raw);
    if (generation != _lookupCacheGeneration) return;
    if (decoded is! Map) return;

    final now = DateTime.now();
    for (final entry in decoded.entries) {
      if (target.length >= _bridgeCacheMaxEntries) break;
      final key = entry.key.toString();
      final rawEntry = entry.value;
      if (key.isEmpty || rawEntry is! Map) continue;

      final expiresAtMs = rawEntry['expires_at'];
      final value = rawEntry['value'];
      if (expiresAtMs is! int || value is! Map) continue;

      final expiresAt = DateTime.fromMillisecondsSinceEpoch(expiresAtMs);
      if (!expiresAt.isAfter(now)) continue;

      final map = Map<String, dynamic>.from(value);
      final bytes = _payloadBytes(map) + key.length * 2;
      if (bytes > _bridgeCacheMaxEntryBytes) continue;
      if (target.values.fold<int>(0, (sum, item) => sum + item.bytes) + bytes >
          _bridgeCacheMaxBytes) {
        break;
      }
      target[key] = _BridgeCacheEntry(
        value: map,
        expiresAt: expiresAt,
        bytes: bytes,
      );
    }
  }

  static Future<void> _persistLookupCache(
    Map<String, _BridgeCacheEntry<Map<String, dynamic>>> cache,
    String prefsKey,
    int generation,
  ) async {
    try {
      _pruneExpiredBridgeCache(cache);
      final data = <String, dynamic>{};
      var bytes = 64;
      for (final entry in cache.entries.toList().reversed) {
        final cost = entry.value.bytes + 128;
        if (cost > _persistentCacheMaxEntryBytes ||
            bytes + cost > _persistentCacheMaxBytes) {
          continue;
        }
        bytes += cost;
        data[entry.key] = {
          'expires_at': entry.value.expiresAt.millisecondsSinceEpoch,
          'value': entry.value.value,
        };
      }
      // Escaping and multibyte UTF-8 can outgrow the retained-size estimate.
      // Enforce both encoded limits in the isolate, without UI-side encoding.
      final encoded = bytes >= _backgroundJsonDecodeThresholdBytes
          ? await compute(_encodeBoundedLookupCacheInBackground, data)
          : _encodeBoundedLookupCacheInBackground(data);
      if (generation != _lookupCacheGeneration) return;
      final prefs = await SharedPreferences.getInstance();
      if (generation != _lookupCacheGeneration) return;
      await prefs.setString(prefsKey, encoded);
    } catch (e) {
      _log.w('Failed to persist bridge lookup cache: $e');
    }
  }

  /// Shortens the lookup cache persist debounce so tests need not wait the
  /// production delay. Null restores the default.
  @visibleForTesting
  static set lookupCachePersistDebounceForTesting(Duration? value) {
    _lookupCachePersistDebounce = value ?? _defaultLookupCachePersistDebounce;
  }

  static void _scheduleLookupCachePersist(
    Map<String, _BridgeCacheEntry<Map<String, dynamic>>> cache,
    String prefsKey,
    int generation,
  ) {
    _lookupCachePersistDirty = true;
    if (_lookupCachePersistInFlight != null) return;
    _lookupCachePersistTimer?.cancel();
    _lookupCachePersistTimer = Timer(_lookupCachePersistDebounce, () {
      _lookupCachePersistTimer = null;
      unawaited(_flushLookupCachePersist(cache, prefsKey, generation));
    });
  }

  static Future<void> _flushLookupCachePersist(
    Map<String, _BridgeCacheEntry<Map<String, dynamic>>> cache,
    String prefsKey,
    int generation,
  ) {
    final active = _lookupCachePersistInFlight;
    if (active != null) {
      _lookupCachePersistDirty = true;
      return active;
    }

    late final Future<void> flush;
    flush =
        () async {
          do {
            _lookupCachePersistDirty = false;
            if (generation != _lookupCacheGeneration) return;
            await _persistLookupCache(cache, prefsKey, generation);
          } while (_lookupCachePersistDirty &&
              generation == _lookupCacheGeneration);
        }().whenComplete(() {
          if (identical(_lookupCachePersistInFlight, flush)) {
            _lookupCachePersistInFlight = null;
          }
        });
    _lookupCachePersistInFlight = flush;
    return flush;
  }

  static Future<void> _cancelLookupCachePersistence() async {
    _lookupCachePersistTimer?.cancel();
    _lookupCachePersistTimer = null;
    _lookupCachePersistDirty = false;
    final active = _lookupCachePersistInFlight;
    if (active != null) await active;
  }

  static Future<void> _clearPersistentLookupCaches() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_metadataPersistentCacheKey);
      // Legacy key from the removed availability-check feature.
      await prefs.remove('bridge_availability_lookup_cache_v1');
    } catch (e) {
      _log.w('Failed to clear bridge lookup cache: $e');
    }
  }

  static Future<void> _clearLookupCaches() async {
    _lookupCacheGeneration++;
    await _cancelLookupCachePersistence();
    _persistentLookupCacheLoadFuture = null;
    _metadataCache.clear();
    _urlHandleCache.clear();
    _customSearchCache.clear();
    _metadataInFlight.clear();
    _urlHandleInFlight.clear();
    for (final inFlight in _customSearchInFlight.values) {
      _cancelExtensionRequestUnawaited(inFlight.requestId);
    }
    for (final inFlight in _homeFeedInFlight.values) {
      _cancelExtensionRequestUnawaited(inFlight.requestId);
    }
    _customSearchInFlight.clear();
    _homeFeedInFlight.clear();
    await _clearPersistentLookupCaches();
  }

  static String _nextExtensionRequestId(String kind, String extensionId) {
    _extensionRequestSequence++;
    return [
      kind,
      DateTime.now().microsecondsSinceEpoch,
      _extensionRequestSequence,
      extensionId.trim(),
    ].join(':');
  }

  static void _cancelExtensionRequestUnawaited(String requestId) {
    if (requestId.isEmpty) return;
    unawaited(
      cancelExtensionRequest(requestId).catchError((Object e) {
        _log.w('Failed to cancel extension request $requestId: $e');
      }),
    );
  }

  static Future<void> cancelExtensionRequest(String requestId) async {
    if (requestId.isEmpty) return;
    await _invokeVoid('cancelExtensionRequest', {'request_id': requestId});
  }

  static void _cancelCustomSearchInFlightForScope(
    String scopeKey, {
    String? exceptKey,
  }) {
    for (final entry in _customSearchInFlight.entries.toList()) {
      if (entry.key == exceptKey || entry.value.scopeKey != scopeKey) continue;
      // A cancelled request must not be reused if the user types its query
      // again before the native cancellation finishes.
      _customSearchInFlight.remove(entry.key);
      _cancelExtensionRequestUnawaited(entry.value.requestId);
    }
  }

  static void cancelExtensionHomeFeedRequests() {
    for (final inFlight in _homeFeedInFlight.values) {
      _cancelExtensionRequestUnawaited(inFlight.requestId);
    }
    _homeFeedInFlight.clear();
  }

  static int _lookupCacheSize() {
    _pruneExpiredBridgeCache(_metadataCache);
    return _metadataCache.length;
  }

  static Future<Map<String, dynamic>> _invokeDownloadMethod(
    String method,
    DownloadRequestPayload payload,
  ) {
    return _invokeMap(method, jsonEncode(payload.toJson()));
  }

  static Future<Map<String, dynamic>> downloadByStrategy({
    required DownloadRequestPayload payload,
    bool? useExtensions,
    bool? useFallback,
  }) async {
    final routedPayload = payload.withStrategy(
      useExtensions: useExtensions,
      useFallback: useFallback,
    );
    final response = await _invokeDownloadMethod(
      'downloadByStrategy',
      routedPayload,
    );
    if (response['success'] != true) {
      final error = response['error'] ?? 'Unknown error';
      final errorType = response['error_type'] ?? '';
      _log.e('Download failed: $error (type: $errorType)');
    }
    return response;
  }

  static Future<Map<String, dynamic>> getAllDownloadProgress() async =>
      _decodeMapResult(await _channel.invokeMethod('getAllDownloadProgress'));

  static Stream<Map<String, dynamic>> downloadProgressStream() {
    return _channel.downloadProgressEvents().map(_decodeMapResult);
  }

  static Future<void> exitApp() => _invokeVoid('exitApp');

  static Future<void> clearItemProgress(String itemId) =>
      _invokeVoid('clearItemProgress', {'item_id': itemId});

  static Future<void> cancelDownload(String itemId) =>
      _invokeVoid('cancelDownload', {'item_id': itemId});

  /// Cancels the selected attempts and clears their native progress. Failures
  /// are best effort, as for individual queue cancellation; later chunks still
  /// run, without issuing thousands of concurrent channel requests.
  static Future<void> cancelDownloads(Iterable<String> itemIds) async {
    final ids = itemIds.toSet().toList(growable: false);
    for (var start = 0; start < ids.length; start += 256) {
      final end = start + 256 < ids.length ? start + 256 : ids.length;
      try {
        await _channel.invokeMethod('cancelDownloads', {
          'item_ids': ids.sublist(start, end),
        });
      } catch (error) {
        _log.w('Failed to cancel ${end - start} downloads: $error');
      }
    }
  }

  /// Drops a stale pre-registered cancel flag for an item with no active
  /// download, so a user-initiated retry does not abort instantly.
  static Future<void> resetDownloadCancel(String itemId) =>
      _invokeVoid('resetDownloadCancel', {'item_id': itemId});

  /// Returns only IDs whose native reset succeeded. Bound each request so a
  /// large retry selection does not flood the channel or hold the native lock.
  static Future<Set<String>> resetDownloadCancels(
    Iterable<String> itemIds,
  ) async {
    final ids = itemIds.toSet().toList(growable: false);
    final reset = <String>{};
    for (var start = 0; start < ids.length; start += 256) {
      final end = start + 256 < ids.length ? start + 256 : ids.length;
      final chunk = ids.sublist(start, end);
      try {
        await _channel.invokeMethod('resetDownloadCancels', {
          'item_ids': chunk,
        });
        reset.addAll(chunk);
      } catch (error) {
        _log.w(
          'Failed to reset cancel flags for ${chunk.length} downloads: $error',
        );
      }
    }
    return reset;
  }

  /// iOS only: run a verification/OAuth page inside ASWebAuthenticationSession.
  /// The session intercepts the callback scheme in-process, so the flow
  /// completes even where the app's URL scheme is not registered with the OS
  /// (e.g. sideload containers like LiveContainer). Returns true when the
  /// session was presented; the callback is delivered through the native side
  /// exactly like an OS deep link.
  static Future<bool> startIosWebAuthSession(
    String url, {
    String callbackScheme = 'mornye',
  }) async {
    final result = await _channel.invokeMethod('startWebAuthSession', {
      'url': url,
      'callback_scheme': callbackScheme,
    });
    return result == true;
  }

  static Future<void> setDownloadDirectory(String path) =>
      _invokeVoid('setDownloadDirectory', {'path': path});

  /// Holds backend access through download and finalization, including folder changes.
  static Future<String> acquireDownloadDirectory(String path) async {
    if (!supportsCoreBackend) return '';
    return await _channel.invokeMethod<String>('acquireDownloadDirectory', {
          'path': path,
        }) ??
        '';
  }

  static Future<void> releaseDownloadDirectory(String token) async {
    if (!supportsCoreBackend || token.isEmpty) return;
    await _invokeVoid('releaseDownloadDirectory', {'token': token});
  }

  static Future<void> setNetworkCompatibilityOptions({
    required bool allowHttp,
    required bool insecureTls,
  }) => _invokeVoid('setNetworkCompatibilityOptions', {
    'allow_http': allowHttp,
    'insecure_tls': insecureTls,
  });

  static Future<void> setAllowPrivateNetwork(bool allowed) =>
      _invokeVoid('setAllowPrivateNetwork', {'allowed': allowed});

  /// Reports domain ownership during native backend migration.
  static Future<Map<String, String>> getBackendImplementations({
    String? filePath,
  }) async {
    final result = await _channel.invokeMapMethod<String, String>(
      'getBackendImplementations',
      filePath == null ? null : {'file_path': filePath},
    );
    return result ?? const {};
  }

  static Future<String> buildFilename(
    String template,
    Map<String, dynamic> metadata,
  ) async => _invokeAs('buildFilename', {
    'template': template,
    'metadata': jsonEncode(metadata),
  });

  static Future<String> sanitizeFilename(String filename) =>
      _invokeAs('sanitizeFilename', {'filename': filename});

  static Future<Map<String, dynamic>?> pickSafTree({bool forSetup = false}) =>
      _invokeDecoded(
        _decodeNullableMapResult,
        'pickSafTree',
        forSetup ? {'for_setup': true} : null,
      );

  static Future<String?> readSetupFolderSelection() =>
      _channel.invokeMethod<String>('readSetupFolderSelection');

  static Future<void> acknowledgeSetupFolderSelection(String payload) =>
      _channel.invokeMethod<void>('acknowledgeSetupFolderSelection', {
        'payload': payload,
      });

  static Future<bool> safExists(String uri) =>
      _invokeAs('safExists', {'uri': uri});

  /// Exact-path checks. Only explicit `missing` results authorize cleanup;
  /// absent responses and permission/provider failures remain unknown.
  static Future<Map<String, bool?>> safExistsBatch(List<String> uris) async {
    if (uris.isEmpty) return const {};
    final result = await _invokeMap('safExistsBatch', {
      'uris_json': jsonEncode(uris),
    });
    return {
      for (final uri in uris)
        uri: switch (result[uri]) {
          'found' => true,
          'missing' => false,
          _ => null,
        },
    };
  }

  /// Read access for a Library source, independent of download write access.
  /// Null means the provider could not confirm access (loading/query failure).
  static Future<bool?> probeSafTreeReadAccess(String treeUri) async {
    try {
      Future<bool?> probe() => _channel.invokeMethod<bool>(
        'probeSafTreeReadAccess',
        {'tree_uri': treeUri},
      );
      final readable = await probe();
      if (readable != false) return readable;
      // A busy provider can briefly return an empty root after a write.
      // Confirm a negative before hiding all tracks from this source.
      await Future<void>.delayed(const Duration(milliseconds: 200));
      return await probe();
    } catch (e) {
      _log.w('Failed to probe SAF library read access: $e');
      return null;
    }
  }

  /// Whether the persisted SAF grant for [treeUri] is still usable: the
  /// permission is present in the system's persisted list and the tree
  /// document still exists and is writable. Returns true on channel errors
  /// so a bridge problem never raises a false "access lost" alarm.
  static Future<bool> isSafTreeAccessible(String treeUri) async {
    try {
      return await validateSafTreeAccess(treeUri);
    } catch (e) {
      _log.w('Failed to check SAF tree accessibility: $e');
      return true;
    }
  }

  /// Strict SAF validation for startup and download preflight. Unlike
  /// [isSafTreeAccessible], channel failures are surfaced to the caller so a
  /// write cannot proceed on an unverified destination.
  static Future<bool> validateSafTreeAccess(String treeUri) async =>
      await _invokeAs<bool?>('isSafTreeAccessible', {'tree_uri': treeUri}) ??
      false;

  static Future<bool> safDelete(String uri) =>
      _invokeAs('safDelete', {'uri': uri});

  static Future<Map<String, dynamic>> safStat(String uri) {
    return _invokeMap('safStat', {'uri': uri});
  }

  static Future<Map<String, dynamic>> resolveSafFile({
    required String treeUri,
    required String fileName,
    String relativeDir = '',
  }) {
    return _invokeMap('resolveSafFile', {
      'tree_uri': treeUri,
      'relative_dir': relativeDir,
      'file_name': fileName,
    });
  }

  /// Checks and repairs many SAF file references in a single native pass.
  /// Android groups requests by tree and scans each tree no more than once.
  static Future<List<Map<String, dynamic>>> inspectSafFiles(
    List<Map<String, dynamic>> requests,
  ) async {
    if (requests.isEmpty) return const [];
    final response = await _invokeMap('inspectSafFiles', {
      'requests_json': jsonEncode(requests),
    });
    final results = response['results'];
    if (results is! List) return const [];
    return results
        .whereType<Map<Object?, Object?>>()
        .map((result) => result.map((key, value) => MapEntry('$key', value)))
        .toList(growable: false);
  }

  static Future<String?> copyContentUriToTemp(String uri) =>
      _invokeAs('safCopyToTemp', {'uri': uri});

  static Future<ContentUriPlaybackLease?> openContentUriPlaybackLease(
    String uri,
  ) async {
    if (!Platform.isAndroid || !isContentUri(uri)) return null;
    final result = await _channel.invokeMethod('safOpenPlaybackLease', {
      'uri': uri,
    });
    if (result is! Map) return null;
    final map = Map<String, dynamic>.from(result);
    final path = map['path']?.toString() ?? '';
    final token = map['token']?.toString() ?? '';
    if (path.isEmpty || token.isEmpty) return null;
    return ContentUriPlaybackLease(
      path: path,
      token: token,
      displayName: result['display_name'] as String?,
    );
  }

  static Future<void> closeContentUriPlaybackLease(String token) async {
    if (!Platform.isAndroid || token.isEmpty) return;
    try {
      await _channel.invokeMethod('safClosePlaybackLease', {'token': token});
    } catch (e) {
      _log.w('Failed to close SAF playback lease: $e');
    }
  }

  static Future<String?> createSafFileFromPath({
    required String treeUri,
    required String relativeDir,
    required String fileName,
    required String mimeType,
    required String srcPath,
  }) => _invokeAs('safCreateFromPath', {
    'tree_uri': treeUri,
    'relative_dir': relativeDir,
    'file_name': fileName,
    'mime_type': mimeType,
    'src_path': srcPath,
  });

  static Future<String?> writeSafSidecarFromPath({
    required String audioUri,
    required String fileName,
    required String mimeType,
    required String srcPath,
  }) => _invokeAs('safWriteSidecarFromPath', {
    'audio_uri': audioUri,
    'file_name': fileName,
    'mime_type': mimeType,
    'src_path': srcPath,
  });

  static Future<Map<String, dynamic>> createSafFileIfAbsentFromPath({
    required String treeUri,
    required String relativeDir,
    required String fileName,
    required String mimeType,
    required String srcPath,
  }) {
    return _invokeMap('safCreateIfAbsentFromPath', {
      'tree_uri': treeUri,
      'relative_dir': relativeDir,
      'file_name': fileName,
      'mime_type': mimeType,
      'src_path': srcPath,
    });
  }

  static Future<Map<String, dynamic>> createUniqueSafFileFromPath({
    required String treeUri,
    required String relativeDir,
    required String fileName,
    required String mimeType,
    required String srcPath,
    String preservedSuffix = '',
  }) {
    return _invokeMap('safCreateUniqueFromPath', {
      'tree_uri': treeUri,
      'relative_dir': relativeDir,
      'file_name': fileName,
      'mime_type': mimeType,
      'src_path': srcPath,
      'preserved_suffix': preservedSuffix,
    });
  }

  static Future<Map<String, dynamic>> createCollisionAwareSafFileFromPath({
    required String treeUri,
    required String relativeDir,
    required String cleanFileName,
    required String variantFileName,
    required String mimeType,
    required String srcPath,
    String preservedSuffix = '',
  }) {
    return _invokeMap('safCreateCollisionAwareFromPath', {
      'tree_uri': treeUri,
      'relative_dir': relativeDir,
      'clean_file_name': cleanFileName,
      'variant_file_name': variantFileName,
      'mime_type': mimeType,
      'src_path': srcPath,
      'preserved_suffix': preservedSuffix,
    });
  }

  static Future<void> openContentUri(String uri, {String mimeType = ''}) =>
      _invokeVoid('openContentUri', {'uri': uri, 'mime_type': mimeType});

  static Future<bool> shareContentUri(String uri, {String title = ''}) async =>
      await _invokeAs<bool?>('shareContentUri', {'uri': uri, 'title': title}) ??
      false;

  static Future<String> getLyricsLRC(
    String spotifyId,
    String trackName,
    String artistName, {
    String? filePath,
    int durationMs = 0,
  }) => _invokeAs('getLyricsLRC', {
    'spotify_id': spotifyId,
    'track_name': trackName,
    'artist_name': artistName,
    'file_path': filePath ?? '',
    'duration_ms': durationMs,
  });

  static Future<Map<String, dynamic>> getLyricsLRCWithSource(
    String spotifyId,
    String trackName,
    String artistName, {
    String? filePath,
    int durationMs = 0,
  }) {
    return _invokeMap('getLyricsLRCWithSource', {
      'spotify_id': spotifyId,
      'track_name': trackName,
      'artist_name': artistName,
      'file_path': filePath ?? '',
      'duration_ms': durationMs,
    });
  }

  /// Lyrics from one enabled provider only, in the shape of
  /// [getLyricsLRCWithSource]. Throws when that provider has none.
  static Future<Map<String, dynamic>> getLyricsFromProvider(
    String provider, {
    required String trackName,
    required String artistName,
    String spotifyId = '',
    int durationMs = 0,
  }) {
    return _invokeMap('getLyricsFromProvider', {
      'provider': provider,
      'spotify_id': spotifyId,
      'track_name': trackName,
      'artist_name': artistName,
      'duration_ms': durationMs,
    });
  }

  /// The enabled lyrics providers in priority order, including installed
  /// lyrics extensions as `extension:<id>`.
  static Future<List<String>> getEnabledLyricsProviders() =>
      _invokeDecoded(_decodeStringListResult, 'getEnabledLyricsProviders');

  static Future<Map<String, dynamic>> embedLyricsToFile(
    String filePath,
    String lyrics,
  ) {
    return _invokeMap('embedLyricsToFile', {
      'file_path': filePath,
      'lyrics': lyrics,
    });
  }

  static Future<void> cleanupConnections() => _invokeVoid('cleanupConnections');

  static Future<Map<String, dynamic>> downloadCoverToFile(
    String coverUrl,
    String outputPath, {
    int maxDimension = 0,
  }) {
    return _withMediaFileAccess([outputPath], () {
      return _invokeMap('downloadCoverToFile', {
        'cover_url': coverUrl,
        'output_path': outputPath,
        'max_dimension': maxDimension,
      });
    });
  }

  static Future<Map<String, dynamic>> extractCoverToFile(
    String audioPath,
    String outputPath,
  ) {
    return _withMediaFileAccess([audioPath, outputPath], () {
      return _invokeMap('extractCoverToFile', {
        'audio_path': audioPath,
        'output_path': outputPath,
      });
    });
  }

  static Future<Map<String, dynamic>> fetchAndSaveLyrics({
    required String trackName,
    required String artistName,
    required String spotifyId,
    required int durationMs,
    required String outputPath,
    String audioFilePath = '',
  }) {
    return _invokeMap('fetchAndSaveLyrics', {
      'track_name': trackName,
      'artist_name': artistName,
      'spotify_id': spotifyId,
      'duration_ms': durationMs,
      'output_path': outputPath,
      'audio_file_path': audioFilePath,
    });
  }

  /// Providers not in the list are disabled.
  static Future<void> setLyricsProviders(List<String> providers) async =>
      _invokeVoid('setLyricsProviders', {
        'providers_json': jsonEncode(providers),
      });

  /// Sets advanced lyrics fetch options used by provider-specific integrations.
  static Future<void> setLyricsFetchOptions(
    Map<String, dynamic> options,
  ) async => _invokeVoid('setLyricsFetchOptions', {
    'options_json': jsonEncode(options),
  });

  static Future<Map<String, dynamic>> reEnrichFile(
    Map<String, dynamic> request,
  ) {
    Future<Map<String, dynamic>> invoke() =>
        _invokeMap('reEnrichFile', {'request_json': jsonEncode(request)});
    if (request['preview_only'] == true) return invoke();
    return _withMediaFileAccess([
      request['file_path'] as String? ?? '',
    ], invoke);
  }

  static Future<Map<String, dynamic>> readFileMetadata(
    String filePath, {
    String? displayName,
  }) {
    return _invokeMap('readFileMetadata', {
      'file_path': filePath,
      'display_name': ?displayName,
    });
  }

  /// Runs the Rust Hi-Res check (spectral cutoff + padded bit depth) on
  /// a FLAC or WAV file. Returns `{"supported": false}` for other formats.
  static Future<Map<String, dynamic>> checkHiResAuthenticity(
    String filePath, {
    Map<String, dynamic>? options,
  }) {
    return _invokeMap('checkHiResAuthenticity', {
      'file_path': filePath,
      'options_json': options == null ? '' : jsonEncode(options),
    });
  }

  /// Reads the tags and quality fields used for automatic Library display.
  ///
  /// Android's readAudioMetadata implementation can inspect most SAF files
  /// through /proc/self/fd, avoiding the full-file cache copy required by tag
  /// editing. Keep the complete reader as a compatibility fallback for
  /// malformed or incorrectly named files that the lightweight scanner could
  /// only identify from their filename.
  static Future<Map<String, dynamic>> readDisplayAudioMetadata(
    String filePath,
  ) async {
    final scanned = await readAudioMetadata(filePath);
    if (scanned != null &&
        scanned['error'] == null &&
        scanned['metadataFromFilename'] != true) {
      return normalizeScannedAudioMetadata(scanned);
    }
    return readFileMetadata(filePath);
  }

  static Future<Map<String, dynamic>> editFileMetadata(
    String filePath,
    Map<String, String> metadata,
  ) {
    return _withMediaFileAccess([filePath, metadata['cover_path'] ?? ''], () {
      return _invokeMap('editFileMetadata', {
        'file_path': filePath,
        'metadata_json': jsonEncode(metadata),
      });
    });
  }

  static Future<T> _withMediaFileAccess<T>(
    Iterable<String> paths,
    Future<T> Function() operation,
  ) async {
    // A user-selected library file or cover can live outside the download
    // folder. Hold only this operation's backend grants; SAF is staged natively.
    final scopes = <String>[];
    try {
      final directories = <String>{
        for (final path in paths)
          if (path.startsWith('/')) File(path).parent.path,
      };
      for (final directory in directories) {
        scopes.add(await acquireDownloadDirectory(directory));
      }
      return await operation();
    } finally {
      for (final scope in scopes.reversed) {
        try {
          await releaseDownloadDirectory(scope);
        } catch (e) {
          _log.w('Failed to release media file access: $e');
        }
      }
    }
  }

  /// Writes ISRC and label into an M4A/MP4 file as iTunes freeform atoms.
  /// FFmpeg's MP4 muxer drops these keys, so they must be written natively
  /// after the FFmpeg metadata pass. [filePath] must be a local file path.
  /// Only the keys present in [fields] are touched; an empty value clears it.
  static Future<Map<String, dynamic>> writeM4AFreeformTags(
    String filePath,
    Map<String, String> fields,
  ) {
    return _withMediaFileAccess([filePath], () {
      return _invokeMap('writeM4AFreeformTags', {
        'file_path': filePath,
        'metadata_json': jsonEncode(fields),
      });
    });
  }

  /// Normalizes a decrypted AC-4 file to a standards-compliant ISO MP4 and
  /// injects the dac4 configuration box from the encrypted [sourcePath]. The
  /// FFmpeg mov muxer drops dac4 and writes a QuickTime-flavored container that
  /// players reject, so this repair is required for AC-4 to be playable.
  static Future<Map<String, dynamic>> ensureAC4Config(
    String filePath,
    String sourcePath,
  ) {
    return _withMediaFileAccess([filePath, sourcePath], () {
      return _invokeMap('ensureAC4Config', {
        'file_path': filePath,
        'source_path': sourcePath,
      });
    });
  }

  /// Writes iTunes-style metadata (and cover art) into an AC-4 MP4. Returns a
  /// map whose `handled` flag is `true` when the file was AC-4 and metadata was
  /// written natively, signalling the caller to skip the FFmpeg metadata pass
  /// (which would re-wrap the file as QuickTime).
  static Future<Map<String, dynamic>> writeAC4Metadata(
    String filePath,
    Map<String, String> metadata,
    String coverPath,
  ) {
    return _withMediaFileAccess([filePath, coverPath], () {
      return _invokeMap('writeAC4Metadata', {
        'file_path': filePath,
        'metadata_json': jsonEncode(metadata),
        'cover_path': coverPath,
      });
    });
  }

  /// Rewrites ARTIST/ALBUMARTIST Vorbis comments as multiple split entries
  /// using the selected native FLAC writer, fixing FFmpeg's tag deduplication.
  static Future<Map<String, dynamic>> rewriteSplitArtistTags(
    String filePath,
    String artist,
    String albumArtist,
  ) {
    return _withMediaFileAccess([filePath], () {
      return _invokeMap('rewriteSplitArtistTags', {
        'file_path': filePath,
        'artist': artist,
        'album_artist': albumArtist,
      });
    });
  }

  static Future<bool> writeTempToSaf(String tempPath, String safUri) async {
    final map = await _invokeMap('writeTempToSaf', {
      'temp_path': tempPath,
      'saf_uri': safUri,
    });
    return map['success'] == true;
  }

  static Future<bool> writeSafSidecarLrc(String safUri, String lyrics) async {
    final map = await _invokeMap('writeSafSidecarLrc', {
      'saf_uri': safUri,
      'lyrics': lyrics,
    });
    return map['success'] == true;
  }

  static Future<void> startDownloadService({
    String trackName = '',
    String artistName = '',
    int queueCount = 0,
  }) => _invokeVoid('startDownloadService', {
    'track_name': trackName,
    'artist_name': artistName,
    'queue_count': queueCount,
  });

  static Future<void> stopDownloadService() =>
      _invokeVoid('stopDownloadService');

  /// Keeps user-started work of [kind] alive with the screen off: an Android
  /// foreground service, or an iOS background-task grace period. Returns
  /// whether the platform accepted it.
  static Future<bool> startBackgroundWork(
    String kind, {
    required String title,
    String text = '',
  }) async {
    final started = await _channel.invokeMethod<bool>('startBackgroundWork', {
      'kind': kind,
      'title': title,
      'text': text,
    });
    return started ?? false;
  }

  /// Updates the Android work notification; [progress] is a percentage, or
  /// negative while indeterminate.
  static Future<void> updateBackgroundWork(
    String kind, {
    required String title,
    String text = '',
    int progress = -1,
  }) => _invokeVoid('updateBackgroundWork', {
    'kind': kind,
    'title': title,
    'text': text,
    'progress': progress,
  });

  static Future<void> stopBackgroundWork(String kind) =>
      _invokeVoid('stopBackgroundWork', {'kind': kind});

  static Future<void> updateDownloadServiceProgress({
    required String trackName,
    required String artistName,
    required int progress,
    required int total,
    required int queueCount,
    String status = 'downloading',
  }) => _invokeVoid('updateDownloadServiceProgress', {
    'track_name': trackName,
    'artist_name': artistName,
    'progress': progress,
    'total': total,
    'queue_count': queueCount,
    'status': status,
  });

  static Future<bool> isDownloadServiceRunning() =>
      _invokeAs('isDownloadServiceRunning');

  /// iOS only: keep in-flight downloads running briefly after backgrounding.
  static Future<void> beginBackgroundDownloadTask() async {
    if (!Platform.isIOS) return;
    try {
      await _channel.invokeMethod('beginBackgroundDownloadTask');
    } catch (_) {}
  }

  /// iOS only: stop the background-time extension (queue finished or paused).
  static Future<void> endBackgroundDownloadTask() async {
    if (!Platform.isIOS) return;
    try {
      await _channel.invokeMethod('endBackgroundDownloadTask');
    } catch (_) {}
  }

  static Future<void> startNativeDownloadWorker({
    required List<Map<String, dynamic>> requests,
    Map<String, dynamic> settings = const {},
  }) async {
    final requestsJson = jsonEncode(requests);
    final settingsJson = jsonEncode(settings);
    final payloadDir = await _nativeWorkerPayloadDir();
    await _cleanupNativeWorkerPayloads(payloadDir);
    final stamp = DateTime.now().microsecondsSinceEpoch;
    final requestPath = '${payloadDir.path}/requests_$stamp.json';
    final settingsPath = '${payloadDir.path}/settings_$stamp.json';
    await File(requestPath).writeAsString(requestsJson, flush: true);
    await File(settingsPath).writeAsString(settingsJson, flush: true);
    try {
      await _channel.invokeMethod('startNativeDownloadWorker', {
        'requests_path': requestPath,
        'settings_path': settingsPath,
      });
    } catch (_) {
      unawaited(_deleteFileIfExists(requestPath));
      unawaited(_deleteFileIfExists(settingsPath));
      rethrow;
    }
  }

  static Future<void> appendNativeDownloadWorkerRequests({
    required String runId,
    required List<Map<String, dynamic>> requests,
  }) async {
    if (requests.isEmpty) return;
    final payloadDir = await _nativeWorkerPayloadDir();
    final stamp = DateTime.now().microsecondsSinceEpoch;
    final requestPath = '${payloadDir.path}/append_$stamp.json';
    await File(requestPath).writeAsString(jsonEncode(requests), flush: true);
    try {
      await _channel.invokeMethod('appendNativeDownloadWorkerRequests', {
        'run_id': runId,
        'requests_path': requestPath,
      });
    } catch (_) {
      unawaited(_deleteFileIfExists(requestPath));
      rethrow;
    }
  }

  static Future<void> finishNativeDownloadWorkerPreparation({
    required String runId,
  }) => _invokeVoid('finishNativeDownloadWorkerPreparation', {'run_id': runId});

  static Future<void> acknowledgeNativeDownloadWorkerItems({
    required String runId,
    required List<String> itemIds,
  }) async {
    if (runId.isEmpty || itemIds.isEmpty) return;
    await _invokeVoid('acknowledgeNativeDownloadWorkerItems', {
      'run_id': runId,
      'item_ids_json': jsonEncode(itemIds),
    });
  }

  static Future<void> _deleteFileIfExists(String path) async {
    await deleteFileQuietly(File(path));
  }

  static Future<Directory> _nativeWorkerPayloadDir() async {
    final tempDir = await getTemporaryDirectory();
    final payloadDir = Directory('${tempDir.path}/native_worker_payloads');
    if (!await payloadDir.exists()) {
      await payloadDir.create(recursive: true);
    }
    return payloadDir;
  }

  static Future<void> _cleanupNativeWorkerPayloads(Directory payloadDir) async {
    final cutoff = DateTime.now().subtract(const Duration(days: 1));
    try {
      await for (final entity in payloadDir.list(followLinks: false)) {
        if (entity is! File || !entity.path.endsWith('.json')) continue;
        final stat = await entity.stat();
        if (stat.modified.isBefore(cutoff)) {
          try {
            await entity.delete();
          } catch (_) {}
        }
      }
    } catch (_) {}
  }

  static Future<void> pauseNativeDownloadWorker() =>
      _invokeVoid('pauseNativeDownloadWorker');

  static Future<void> resumeNativeDownloadWorker() =>
      _invokeVoid('resumeNativeDownloadWorker');

  static Future<void> cancelNativeDownloadWorker() =>
      _invokeVoid('cancelNativeDownloadWorker');

  /// [sinceStateSerial]: pass the `state_serial` of the last fully-processed
  /// snapshot; when the native state hasn't advanced past it, the heavy
  /// per-item payload (which grows with every completed item) is omitted and
  /// only compact progress fields are returned.
  static Future<Map<String, dynamic>> getNativeDownloadWorkerSnapshot({
    int sinceStateSerial = 0,
  }) async => _decodeMapResult(
    await _channel.invokeMethod('getNativeDownloadWorkerSnapshot', {
      'since_state_serial': sinceStateSerial,
    }),
  );

  static Future<int> getTrackCacheSize() async {
    await _ensurePersistentLookupCachesLoaded();
    return await _invokeAs<int>('getTrackCacheSize') + _lookupCacheSize();
  }

  static Future<void> clearTrackCache() async {
    await _clearLookupCaches();
    await _channel.invokeMethod('clearTrackCache');
  }

  static Future<Map<String, dynamic>> getProviderMetadata(
    String providerId,
    String resourceType,
    String resourceId,
  ) {
    return _cachedInvoke(
      _providerMetadataCacheKey(providerId, resourceType, resourceId),
      _metadataCache,
      _metadataInFlight,
      _metadataCacheTtl,
      _metadataPersistentCacheKey,
      () async {
        final result = await _channel.invokeMethod('getProviderMetadata', {
          'provider_id': providerId,
          'resource_type': resourceType,
          'resource_id': resourceId,
        });
        if (result == null) {
          throw Exception(
            'getProviderMetadata returned null for $providerId:$resourceType:$resourceId',
          );
        }
        return _decodeRequiredMapResultAsync(result, 'getProviderMetadata');
      },
    );
  }

  static Future<Map<String, dynamic>> searchDeezerByISRC(
    String isrc, {
    String? itemId,
  }) {
    return _invokeMap('searchDeezerByISRC', {
      'isrc': isrc,
      'item_id': itemId ?? '',
    });
  }

  static Future<Map<String, String>?> getDeezerExtendedMetadata(
    String trackId,
  ) async {
    try {
      final result = await _channel.invokeMethod('getDeezerExtendedMetadata', {
        'track_id': trackId,
      });
      if (result == null) return null;
      final data = _decodeRequiredMapResult(
        result,
        'getDeezerExtendedMetadata',
      );
      return {
        'genre': data['genre'] as String? ?? '',
        'label': data['label'] as String? ?? '',
        'copyright': data['copyright'] as String? ?? '',
      };
    } catch (e) {
      _log.w('Failed to get Deezer extended metadata for $trackId: $e');
      return null;
    }
  }

  static Future<Map<String, dynamic>> convertSpotifyToDeezer(
    String resourceType,
    String spotifyId,
  ) {
    return _cachedInvoke(
      _providerMetadataCacheKey('spotify-to-deezer', resourceType, spotifyId),
      _metadataCache,
      _metadataInFlight,
      _metadataCacheTtl,
      _metadataPersistentCacheKey,
      () => _invokeMap('convertSpotifyToDeezer', {
        'resource_type': resourceType,
        'spotify_id': spotifyId,
      }),
    );
  }

  /// Ask the native backend to release unused memory. Best-effort:
  /// safe to call on memory pressure or when the app is backgrounded.
  static Future<void> releaseNativeMemory({bool underPressure = false}) async {
    try {
      await _channel.invokeMethod(
        underPressure ? 'releaseMemoryUnderPressure' : 'releaseMemory',
      );
    } catch (_) {}
  }

  /// Tells the backend the app's display language so metadata providers
  /// localize by it instead of IP geolocation. Best-effort.
  static Future<void> setMetadataLanguage(String tag) async {
    try {
      await _channel.invokeMethod('setMetadataLanguage', {'tag': tag});
    } catch (_) {}
  }

  static Future<void> initExtensionSystem(
    String extensionsDir,
    String dataDir, {
    required String masterKey,
    required List<String> lyricsProviders,
    required Map<String, dynamic> lyricsFetchOptions,
    List<String> allowedDirectories = const [],
  }) async {
    _log.d('initExtensionSystem: $extensionsDir, $dataDir');
    await _channel.invokeMethod('initExtensionSystem', {
      'extensions_dir': extensionsDir,
      'data_dir': dataDir,
      'master_key': masterKey,
      'lyrics_providers_json': jsonEncode(lyricsProviders),
      'lyrics_options_json': jsonEncode(lyricsFetchOptions),
      'allowed_directories': allowedDirectories,
    });
  }

  static Future<Map<String, dynamic>> loadExtensionsFromDir(String dirPath) {
    _log.d('loadExtensionsFromDir: $dirPath');
    return _invokeMap('loadExtensionsFromDir', {'dir_path': dirPath});
  }

  static Future<Map<String, dynamic>> loadExtensionFromPath(
    String filePath,
  ) async {
    _log.d('loadExtensionFromPath: $filePath');
    await _clearLookupCaches();
    return _invokeMap('loadExtensionFromPath', {'file_path': filePath});
  }

  static Future<void> removeExtension(String extensionId) async {
    _log.d('removeExtension: $extensionId');
    await _clearLookupCaches();
    await _invokeVoid('removeExtension', {'extension_id': extensionId});
  }

  static Future<Map<String, dynamic>> upgradeExtension(String filePath) async {
    _log.d('upgradeExtension: $filePath');
    await _clearLookupCaches();
    return _invokeMap('upgradeExtension', {'file_path': filePath});
  }

  static Future<Map<String, dynamic>> checkExtensionUpgrade(String filePath) {
    _log.d('checkExtensionUpgrade: $filePath');
    return _invokeMap('checkExtensionUpgrade', {'file_path': filePath});
  }

  static Future<List<Map<String, dynamic>>> getInstalledExtensions() =>
      _invokeDecoded(_decodeMapListResultAsync, 'getInstalledExtensions');

  static Future<void> setExtensionEnabled(
    String extensionId,
    bool enabled,
  ) async {
    _log.d('setExtensionEnabled: $extensionId = $enabled');
    await _clearLookupCaches();
    await _invokeVoid('setExtensionEnabled', {
      'extension_id': extensionId,
      'enabled': enabled,
    });
  }

  static Future<void> setProviderPriority(List<String> providerIds) async {
    _log.d('setProviderPriority: $providerIds');
    await _clearLookupCaches();
    await _invokeVoid('setProviderPriority', {
      'priority': jsonEncode(providerIds),
    });
  }

  static Future<List<String>> getProviderPriority() =>
      _invokeDecoded(_decodeStringListResult, 'getProviderPriority');

  static Future<void> setDownloadFallbackExtensionIds(
    List<String>? extensionIds,
  ) async {
    _log.d('setDownloadFallbackExtensionIds: $extensionIds');
    await _clearLookupCaches();
    await _invokeVoid('setDownloadFallbackExtensionIds', {
      'extension_ids': extensionIds == null ? '' : jsonEncode(extensionIds),
    });
  }

  static Future<void> setMetadataProviderPriority(
    List<String> providerIds,
  ) async {
    _log.d('setMetadataProviderPriority: $providerIds');
    await _clearLookupCaches();
    await _invokeVoid('setMetadataProviderPriority', {
      'priority': jsonEncode(providerIds),
    });
  }

  static Future<List<String>> getMetadataProviderPriority() =>
      _invokeDecoded(_decodeStringListResult, 'getMetadataProviderPriority');

  static Future<Map<String, dynamic>> getExtensionSettings(String extensionId) {
    return _invokeMap('getExtensionSettings', {'extension_id': extensionId});
  }

  static Future<Map<String, dynamic>> checkExtensionHealth(String extensionId) {
    return _invokeMap('checkExtensionHealth', {'extension_id': extensionId});
  }

  static Future<void> setExtensionSettings(
    String extensionId,
    Map<String, dynamic> settings,
  ) async {
    _log.d('setExtensionSettings: $extensionId');
    await _clearLookupCaches();
    await _invokeVoid('setExtensionSettings', {
      'extension_id': extensionId,
      'settings': jsonEncode(settings),
    });
  }

  static Future<Map<String, dynamic>> invokeExtensionAction(
    String extensionId,
    String actionName, {
    Map<String, dynamic>? input,
  }) async {
    // Log action identity only. Input may contain account credentials or OTP.
    _log.d('invokeExtensionAction: $extensionId.$actionName');
    final result = await _channel.invokeMethod('invokeExtensionAction', {
      'extension_id': extensionId,
      'action': actionName,
      if (input != null) 'arguments_json': jsonEncode([input]),
    });
    if (result == null || (result as String).isEmpty) {
      return {'success': true};
    }
    return _decodeRequiredMapResultAsync(result, 'invokeExtensionAction');
  }

  static Future<List<Map<String, dynamic>>> searchTracksWithMetadataProviders(
    String query, {
    int limit = 20,
    bool includeExtensions = true,
  }) async {
    _log.d(
      'searchTracksWithMetadataProviders: "$query", includeExtensions=$includeExtensions',
    );
    return _invokeDecoded(
      _decodeMapListResultAsync,
      'searchTracksWithMetadataProviders',
      {'query': query, 'limit': limit, 'include_extensions': includeExtensions},
    );
  }

  static Future<List<Map<String, dynamic>>> searchTracksWithMetadataProvider(
    String extensionId,
    String query, {
    int limit = 20,
  }) async {
    _log.d('searchTracksWithMetadataProvider: $extensionId, query="$query"');
    return _invokeDecoded(
      _decodeMapListResultAsync,
      'searchTracksWithMetadataProvider',
      {'extension_id': extensionId, 'query': query, 'limit': limit},
    );
  }

  static Future<List<Map<String, dynamic>>> findCollectionAcrossExtensions({
    required String name,
    required String artists,
    required String type,
    required String sourceExtensionId,
  }) async {
    final requestJson = jsonEncode({
      'name': name,
      'artists': artists,
      'type': type,
      'source_extension_id': sourceExtensionId,
    });
    return _invokeDecoded(
      _decodeMapListResultAsync,
      'findCollectionAcrossExtensions',
      requestJson,
    );
  }

  static Future<void> cleanupExtensions() async {
    _log.d('cleanupExtensions');
    await _channel.invokeMethod('cleanupExtensions');
  }

  static Future<Map<String, dynamic>?> getExtensionPendingAuth(
    String extensionId,
  ) => _invokeDecoded(_decodeNullableMapResult, 'getExtensionPendingAuth', {
    'extension_id': extensionId,
  });

  static final Map<String, Future<bool>> _extensionSessionGrantCompletions =
      <String, Future<bool>>{};

  static Future<bool> completeExtensionSessionGrant(
    String extensionId,
    String grant,
  ) {
    final normalizedExtensionId = extensionId.trim();
    final key = normalizedExtensionId.toLowerCase();
    final activeCompletion = _extensionSessionGrantCompletions[key];
    if (activeCompletion != null) {
      _log.d(
        'Joining active completeExtensionSessionGrant: $normalizedExtensionId',
      );
      return activeCompletion;
    }

    late final Future<bool> completion;
    completion = _completeExtensionSessionGrant(normalizedExtensionId, grant)
        .whenComplete(() {
          if (identical(_extensionSessionGrantCompletions[key], completion)) {
            _extensionSessionGrantCompletions.remove(key);
          }
        });
    _extensionSessionGrantCompletions[key] = completion;
    return completion;
  }

  static Future<bool> _completeExtensionSessionGrant(
    String extensionId,
    String grant,
  ) async {
    _log.d('completeExtensionSessionGrant: $extensionId');
    final result = await _channel.invokeMethod(
      'completeExtensionSessionGrant',
      {'extension_id': extensionId, 'grant': grant},
    );
    final success = result != false;
    _extensionSessionGrantEvents.add(
      ExtensionSessionGrantEvent(extensionId: extensionId, success: success),
    );
    return success;
  }

  static Future<List<Map<String, dynamic>>> customSearchWithExtension(
    String extensionId,
    String query, {
    Map<String, dynamic>? options,
    bool cancelPrevious = false,
  }) async {
    final optionsJson = options != null ? jsonEncode(options) : '';
    final scopeKey = 'customSearch:${extensionId.trim()}';
    final cacheKey = [
      scopeKey,
      query,
      jsonEncode(_canonicalizeJsonLike(options ?? const <String, dynamic>{})),
    ].join('\n');
    final inFlight = _customSearchInFlight[cacheKey];
    if (inFlight != null) return _copyMapList(await inFlight.future);
    if (cancelPrevious) {
      _cancelCustomSearchInFlightForScope(scopeKey, exceptKey: cacheKey);
    }

    final cached = _getCachedMapList(_customSearchCache, cacheKey);
    if (cached != null) return cached;

    final requestId = _nextExtensionRequestId('customSearch', extensionId);
    final generation = _lookupCacheGeneration;
    final future = (() async {
      final result = await _channel.invokeMethod('customSearchWithExtension', {
        'extension_id': extensionId,
        'query': query,
        'options': optionsJson,
        'request_id': requestId,
      });
      final decoded = await _decodeMapListResultAsync(
        result,
        'customSearchWithExtension',
      );
      if (generation == _lookupCacheGeneration &&
          _customSearchInFlight[cacheKey]?.requestId == requestId) {
        _putMemoryCached<List<Map<String, dynamic>>>(
          _customSearchCache,
          cacheKey,
          decoded,
          _customSearchCacheTtl,
        );
      }
      return decoded;
    })();

    final entry = _BridgeInFlight<List<Map<String, dynamic>>>(
      requestId: requestId,
      scopeKey: scopeKey,
      future: future,
    );
    _customSearchInFlight[cacheKey] = entry;
    try {
      return _copyMapList(await future);
    } finally {
      if (identical(_customSearchInFlight[cacheKey], entry)) {
        _customSearchInFlight.remove(cacheKey);
      }
    }
  }

  /// Songs like [seeds] (track maps, most important first) from an extension
  /// with the `relatedTracks` capability, normalized like search results.
  static Future<List<Map<String, dynamic>>> getExtensionRelatedTracks(
    String extensionId,
    List<Map<String, dynamic>> seeds, {
    int limit = 25,
  }) async {
    final requestId = _nextExtensionRequestId('relatedTracks', extensionId);
    final result = await _channel.invokeMethod('getExtensionRelatedTracks', {
      'extension_id': extensionId,
      'seeds': jsonEncode(seeds),
      'options': jsonEncode({'limit': limit}),
      'request_id': requestId,
    });
    return _decodeMapListResultAsync(result, 'getExtensionRelatedTracks');
  }

  static Future<Map<String, dynamic>?> handleURLWithExtension(
    String url,
  ) async {
    final cacheKey = url.trim();
    if (cacheKey.isEmpty) return null;

    final cached = _getCachedMap(_urlHandleCache, cacheKey);
    if (cached != null) return cached;

    final inFlight = _urlHandleInFlight[cacheKey];
    if (inFlight != null) return _copyNullableStringMap(await inFlight);

    final generation = _lookupCacheGeneration;
    final future = (() async {
      try {
        final result = await _channel.invokeMethod('handleURLWithExtension', {
          'url': url,
        });
        final decoded = await _decodeNullableMapResultAsync(
          result,
          'handleURLWithExtension',
        );
        if (generation == _lookupCacheGeneration &&
            decoded != null &&
            _isCacheableURLHandleResult(decoded)) {
          _putMemoryCached<Map<String, dynamic>>(
            _urlHandleCache,
            cacheKey,
            decoded,
            _urlHandleCacheTtl,
          );
        }
        return decoded;
      } catch (e) {
        return null;
      }
    })();

    _urlHandleInFlight[cacheKey] = future;
    try {
      return _copyNullableStringMap(await future);
    } finally {
      if (identical(_urlHandleInFlight[cacheKey], future)) {
        _urlHandleInFlight.remove(cacheKey);
      }
    }
  }

  static bool _isCacheableURLHandleResult(Map<String, dynamic> result) {
    final type = result['type']?.toString();
    if (type == null || type.isEmpty) return false;
    if (type == 'track') {
      final track = result['track'];
      if (track is! Map) return false;
      final name = track['name']?.toString().trim() ?? '';
      return name.isNotEmpty;
    }
    return type == 'album' || type == 'playlist' || type == 'artist';
  }

  /// Admits [value] under the shared per-entry and per-cache budgets,
  /// evicting the oldest entries first. Each cache map is budgeted on its own.
  static void _putMemoryCached<T>(
    Map<String, _BridgeCacheEntry<T>> cache,
    String key,
    T value,
    Duration ttl,
  ) {
    _pruneExpiredBridgeCache(cache);
    cache.remove(key);
    final bytes = _payloadBytes(value) + key.length * 2;
    if (bytes > _bridgeCacheMaxEntryBytes) return;
    var retained = cache.values.fold<int>(0, (sum, item) => sum + item.bytes);
    while (cache.isNotEmpty &&
        (cache.length >= _bridgeCacheMaxEntries ||
            retained + bytes > _bridgeCacheMaxBytes)) {
      retained -= cache.remove(cache.keys.first)!.bytes;
    }
    cache[key] = _BridgeCacheEntry<T>(
      value: value,
      expiresAt: DateTime.now().add(ttl),
      bytes: bytes,
    );
  }

  static List<Map<String, dynamic>>? _getCachedMapList(
    Map<String, _BridgeCacheEntry<List<Map<String, dynamic>>>> cache,
    String key,
  ) {
    _pruneExpiredBridgeCache(cache);
    final entry = cache[key];
    if (entry == null) return null;
    if (entry.isExpired) {
      cache.remove(key);
      return null;
    }
    return _copyMapList(entry.value);
  }

  static Future<String?> findURLHandler(String url) async {
    final result = await _channel.invokeMethod('findURLHandler', {'url': url});
    if (result == null || result == '') return null;
    return result as String;
  }

  /// MusicBrainz genre and album artist for an ISRC; empty strings when a
  /// lookup finds nothing. One channel call covers both fields to spare
  /// MusicBrainz's 1 req/s budget.
  static Future<({String genre, String albumArtist})> fetchMusicBrainzTags({
    required String isrc,
    String albumName = '',
  }) async {
    final result = await _channel.invokeMethod('fetchMusicBrainzTags', {
      'isrc': isrc,
      'album_name': albumName,
    });
    final decoded = _decodeMapResult(result);
    return (
      genre: decoded['genre']?.toString() ?? '',
      albumArtist: decoded['album_artist']?.toString() ?? '',
    );
  }

  /// Streaming-platform links for a track, keyed by song.link platform ID.
  /// Served from the native backend's memory cache; throws when the lookup fails.
  static Future<Map<String, String>> getTrackPlatformLinks({
    String spotifyId = '',
    String isrc = '',
  }) async {
    final result = await _channel.invokeMethod('getTrackPlatformLinks', {
      'spotify_id': spotifyId,
      'isrc': isrc,
    });
    final decoded = _decodeMapResult(result);
    final platforms = decoded['platforms'];
    if (platforms is! Map) return const {};
    return platforms.map(
      (key, value) => MapEntry(key.toString(), value.toString()),
    );
  }

  static Future<Map<String, dynamic>?> getExtensionHomeFeed(
    String extensionId, {
    bool cancelPrevious = false,
  }) async {
    final cacheKey = 'homeFeed:${extensionId.trim()}';
    final inFlight = _homeFeedInFlight[cacheKey];
    if (inFlight != null) {
      if (!cancelPrevious) {
        return _copyNullableStringMap(await inFlight.future);
      }
      _cancelExtensionRequestUnawaited(inFlight.requestId);
      _homeFeedInFlight.remove(cacheKey);
    }

    final requestId = _nextExtensionRequestId('homeFeed', extensionId);
    final future = (() async {
      try {
        final result = await _channel.invokeMethod('getExtensionHomeFeed', {
          'extension_id': extensionId,
          'request_id': requestId,
        });
        return await _decodeNullableMapResultAsync(
          result,
          'getExtensionHomeFeed',
        );
      } catch (e) {
        _log.e('getExtensionHomeFeed failed: $e');
        return null;
      }
    })();
    final entry = _BridgeInFlight<Map<String, dynamic>?>(
      requestId: requestId,
      scopeKey: cacheKey,
      future: future,
    );
    _homeFeedInFlight[cacheKey] = entry;
    try {
      return _copyNullableStringMap(await future);
    } finally {
      if (identical(_homeFeedInFlight[cacheKey], entry)) {
        _homeFeedInFlight.remove(cacheKey);
      }
    }
  }

  // Android reports process exits natively; desktop uses the session marker
  // in DesktopDiagnostics.

  static Future<Map<String, dynamic>?> getPendingAppCrash() async {
    if (isDesktopPlatform) return DesktopDiagnostics.instance?.pendingCrash();
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return null;
    return _invokeDecoded(_decodeNullableMapResult, 'getPendingAppCrash');
  }

  static Future<void> dismissAppCrash(String id) async {
    if (isDesktopPlatform) return DesktopDiagnostics.instance?.dismiss(id);
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    await _channel.invokeMethod<void>('dismissAppCrash', {'id': id});
  }

  static Future<Map<String, dynamic>?> getLatestAppCrash() async {
    if (isDesktopPlatform) return DesktopDiagnostics.instance?.latestCrash();
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return null;
    return _invokeDecoded(_decodeNullableMapResult, 'getLatestAppCrash');
  }

  static Future<void> markAppCrashShown(String id) async {
    if (isDesktopPlatform) return DesktopDiagnostics.instance?.markShown(id);
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    await _channel.invokeMethod<void>('markAppCrashShown', {'id': id});
  }

  static Future<void> recordAppRuntimeError({
    required String error,
    required String stack,
    required String logs,
  }) async {
    if (isDesktopPlatform) {
      return DesktopDiagnostics.instance?.recordRuntimeError(
        error: error,
        stack: stack,
        logs: logs,
      );
    }
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    await _channel.invokeMethod<void>('recordAppRuntimeError', {
      'error': error,
      'stack': stack,
      'logs': logs,
    });
  }

  static Future<Map<String, dynamic>?> getLibraryScanExitInfo({
    required int startedAfter,
  }) async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return null;
    return _invokeDecoded(_decodeNullableMapResult, 'getLibraryScanExitInfo', {
      'started_after': startedAfter,
    });
  }

  static Future<void> setLibraryCoverCacheDir(String cacheDir) =>
      _invokeVoid('setLibraryCoverCacheDir', {'cache_dir': cacheDir});

  static Future<LibraryScanNDJSONFile> scanLibraryFolderToNDJSONFile(
    String folderPath, {
    bool forceFullScan = false,
    bool Function()? isCancelled,
  }) {
    return _scanToNDJSONFile(
      method: 'scanLibraryFolderToNDJSONFile',
      arguments: {'folder_path': folderPath},
      forceFullScan: forceFullScan,
      isCancelled: isCancelled,
    );
  }

  static Future<Map<String, dynamic>> scanLibraryFolderIncremental(
    String folderPath,
    Map<String, int> existingFiles,
  ) async => _invokeMap('scanLibraryFolderIncremental', {
    'folder_path': folderPath,
    'existing_files': jsonEncode(existingFiles),
  });

  static Future<LibraryScanNDJSONFile> scanSafTreeToNDJSONFile(
    String treeUri, {
    bool forceFullScan = false,
    bool Function()? isCancelled,
  }) {
    return _scanToNDJSONFile(
      method: 'scanSafTreeToNDJSONFile',
      arguments: {'tree_uri': treeUri},
      forceFullScan: forceFullScan,
      isCancelled: isCancelled,
    );
  }

  static Future<LibraryScanNDJSONFile> _scanToNDJSONFile({
    required String method,
    required Map<String, dynamic> arguments,
    required bool forceFullScan,
    bool Function()? isCancelled,
  }) async {
    // Stable support-directory path lets native SAF scans resume after process death.
    _ensureBackendEventHandler();
    final scanDir = await getApplicationSupportDirectory();
    await scanDir.create(recursive: true);
    final identity = jsonEncode(<String, dynamic>{
      'method': method,
      'arguments': arguments,
    });
    final hash = fnv1a32(utf8.encode(identity));
    final output = File(
      '${scanDir.path}${Platform.pathSeparator}'
      'library_scan_${hash.toRadixString(16).padLeft(8, '0')}.ndjson',
    );
    // Partial output is kept on failure; native SAF scan resumes from its sidecar.
    if (isCancelled?.call() == true) {
      throw StateError('Library scan cancelled before native scan');
    }
    if (forceFullScan) {
      // An explicit rescan must not resume metadata from an earlier attempt.
      for (final file in [output, File('${output.path}.state')]) {
        if (await file.exists()) await file.delete();
      }
      // Preserve covers referenced by the current DB until ingestion succeeds.
      // Fresh paths bypass native disk and Flutter image caches together.
      final covers = Directory('${scanDir.path}/library_covers');
      await covers.create(recursive: true);
      final freshCovers = await covers.createTemp('full_scan_');
      await setLibraryCoverCacheDir(freshCovers.path);
    }
    if (isCancelled?.call() == true) {
      throw StateError('Library scan cancelled before native scan');
    }
    final result = await _channel.invokeMethod(method, {
      ...arguments,
      'output_path': output.path,
    });
    if (result is! Map) {
      throw FormatException('$method returned ${result.runtimeType}');
    }
    if (result['cancelled'] == true) {
      throw FormatException('$method returned a cancelled partial scan');
    }
    final errors = result['error_count'];
    if (errors is! num ||
        !errors.isFinite ||
        errors < 0 ||
        errors != errors.toInt()) {
      throw FormatException('$method returned an invalid error count');
    }
    final pathValue = result['path'];
    final countValue = result['count'];
    if (pathValue is! String || pathValue.trim().isEmpty) {
      throw FormatException('$method returned an invalid output path');
    }
    if (countValue is! num ||
        !countValue.isFinite ||
        countValue < 0 ||
        countValue != countValue.toInt()) {
      throw FormatException('$method returned an invalid row count');
    }
    final path = pathValue;
    final count = countValue.toInt();
    final file = File(path);
    if (!await file.exists()) {
      throw FormatException('$method did not create its output file');
    }
    return LibraryScanNDJSONFile(
      file: file,
      expectedCount: count,
      errorCount: errors.toInt(),
    );
  }

  static Future<Map<String, dynamic>> scanSafTreeIncremental(
    String treeUri,
    Map<String, int> existingFiles,
  ) async {
    _ensureBackendEventHandler();
    return _invokeMap('scanSafTreeIncremental', {
      'tree_uri': treeUri,
      'existing_files': jsonEncode(existingFiles),
    });
  }

  static Future<Map<String, int>> getSafFileModTimes(List<String> uris) async {
    final map = await _invokeMap('getSafFileModTimes', {
      'uris': jsonEncode(uris),
    });
    return map.map((key, value) => MapEntry(key, (value as num).toInt()));
  }

  static Future<Map<String, dynamic>> getLibraryScanProgress() async =>
      _decodeMapResult(await _channel.invokeMethod('getLibraryScanProgress'));

  static Stream<Map<String, dynamic>> libraryScanProgressStream() {
    return _channel.libraryScanProgressEvents().map(_decodeMapResult);
  }

  static Future<void> cancelLibraryScan() => _invokeVoid('cancelLibraryScan');

  /// Holds the running native scan at its next file; it keeps its position.
  static Future<void> pauseLibraryScan() => _invokeVoid('pauseLibraryScan');

  static Future<void> resumeLibraryScan() => _invokeVoid('resumeLibraryScan');

  static Object? _decodeJsonResult(dynamic result) {
    if (result is String) {
      if (result.isEmpty) return null;
      return jsonDecode(result);
    }
    return result;
  }

  static Future<Object?> _decodeJsonResultAsync(dynamic result) async {
    if (result is Map && result[_jsonResultFileKey] is String) {
      final file = File(result[_jsonResultFileKey] as String);
      try {
        // Read and decode where the result is built, so the UI isolate never
        // retains a second copy of the entire spill file's text.
        return await compute(_decodeJsonFileInBackground, file.path);
      } finally {
        try {
          await file.delete();
        } catch (_) {}
      }
    }
    if (result is String &&
        result.length >= _backgroundJsonDecodeThresholdBytes) {
      return _decodeJsonStringAsync(result);
    }
    return _decodeJsonResult(result);
  }

  static Future<Object?> _decodeJsonStringAsync(String json) {
    if (json.length < _backgroundJsonDecodeThresholdBytes) {
      return Future<Object?>.value(jsonDecode(json));
    }
    return compute(_decodeJsonInBackground, json);
  }

  static Map<String, dynamic> _decodeRequiredMapResult(
    dynamic result,
    String method,
  ) {
    final decoded = _decodeJsonResult(result);
    if (decoded is Map) {
      return decoded.cast<String, dynamic>();
    }
    throw FormatException(
      'Expected map result from $method, got ${decoded.runtimeType}',
    );
  }

  static Map<String, dynamic>? _decodeNullableMapResult(
    dynamic result,
    String method,
  ) {
    final decoded = _decodeJsonResult(result);
    if (decoded == null) return null;
    if (decoded is Map) {
      return decoded.cast<String, dynamic>();
    }
    throw FormatException(
      'Expected nullable map result from $method, got ${decoded.runtimeType}',
    );
  }

  static Future<Map<String, dynamic>> _decodeRequiredMapResultAsync(
    dynamic result,
    String method,
  ) async {
    final decoded = await _decodeJsonResultAsync(result);
    if (decoded is Map) {
      return decoded.cast<String, dynamic>();
    }
    throw FormatException(
      'Expected map result from $method, got ${decoded.runtimeType}',
    );
  }

  static Future<Map<String, dynamic>?> _decodeNullableMapResultAsync(
    dynamic result,
    String method,
  ) async {
    final decoded = await _decodeJsonResultAsync(result);
    if (decoded == null) return null;
    if (decoded is Map) return decoded.cast<String, dynamic>();
    throw FormatException(
      'Expected nullable map result from $method, got ${decoded.runtimeType}',
    );
  }

  static List<dynamic> _decodeRequiredListResult(
    dynamic result,
    String method,
  ) {
    final decoded = _decodeJsonResult(result);
    if (decoded is List) return decoded;
    throw FormatException(
      'Expected list result from $method, got ${decoded.runtimeType}',
    );
  }

  static Future<List<dynamic>> _decodeRequiredListResultAsync(
    dynamic result,
    String method,
  ) async {
    final decoded = await _decodeJsonResultAsync(result);
    if (decoded is List) return decoded;
    throw FormatException(
      'Expected list result from $method, got ${decoded.runtimeType}',
    );
  }

  static Future<List<Map<String, dynamic>>> _decodeMapListResultAsync(
    dynamic result,
    String method,
  ) async {
    final decoded = await _decodeRequiredListResultAsync(result, method);
    return decoded.map((entry) {
      if (entry is Map) return entry.cast<String, dynamic>();
      throw FormatException(
        'Expected map entry from $method, got ${entry.runtimeType}',
      );
    }).toList();
  }

  static List<String> _decodeStringListResult(dynamic result, String method) {
    return _decodeRequiredListResult(result, method).map((entry) {
      if (entry is String) return entry;
      throw FormatException(
        'Expected string entry from $method, got ${entry.runtimeType}',
      );
    }).toList();
  }

  static Map<String, dynamic> _decodeMapResult(dynamic result) {
    if (result is Map) {
      return result.cast<String, dynamic>();
    }
    if (result is String) {
      if (result.isEmpty) return const <String, dynamic>{};
      final decoded = jsonDecode(result);
      if (decoded is Map) {
        return decoded.cast<String, dynamic>();
      }
    }
    return const <String, dynamic>{};
  }

  /// Present the native iOS folder picker. The security-scoped bookmark is
  /// created inside the picker callback while its access grant is still
  /// active; creating it later from a bare path loses the grant.
  /// Returns null when the user cancels; throws on picker/bookmark failure.
  static Future<IosPickedDirectory?> pickIosDirectory() async {
    _log.i('Opening iOS folder picker');
    try {
      final result = await _channel.invokeMethod('pickIosDirectory');
      final map = _decodeNullableMapResult(result, 'pickIosDirectory');
      if (map == null) {
        _log.i('iOS folder selection cancelled');
        return null;
      }
      final path = map['path'] as String? ?? '';
      final bookmark = map['bookmark'] as String? ?? '';
      if (!path.startsWith('/') || bookmark.trim().isEmpty) {
        throw const FormatException('Invalid iOS folder selection');
      }
      _log.i('iOS folder selected with an access bookmark');
      return IosPickedDirectory(path: path, bookmark: bookmark);
    } catch (error, stack) {
      _log.e('iOS folder selection failed', error, stack);
      rethrow;
    }
  }

  /// Resolve a base64-encoded iOS security-scoped bookmark and start accessing
  /// the resource. The returned lease must be passed to
  /// [stopAccessingIosBookmark] by the operation that acquired it.
  static Future<IosSecurityScopedAccess?> startAccessingIosBookmark(
    String bookmark,
  ) async {
    try {
      final result = await _channel.invokeMethod('startAccessingIosBookmark', {
        'bookmark': bookmark,
      });
      if (result is! Map) {
        throw FormatException(
          'startAccessingIosBookmark returned ${result.runtimeType}',
        );
      }
      final path = result['path'];
      final token = result['token'];
      if (path is! String ||
          path.trim().isEmpty ||
          token is! String ||
          token.trim().isEmpty) {
        throw const FormatException('Invalid iOS bookmark access lease');
      }
      return IosSecurityScopedAccess(path: path, token: token);
    } catch (e) {
      _log.w('Failed to start accessing iOS bookmark: $e');
      return null;
    }
  }

  /// Releases exactly the security-scoped lease acquired by the caller.
  static Future<void> stopAccessingIosBookmark(
    IosSecurityScopedAccess access,
  ) async {
    try {
      await _channel.invokeMethod('stopAccessingIosBookmark', {
        'token': access.token,
      });
    } catch (e) {
      _log.w('Failed to stop accessing iOS bookmark: $e');
    }
  }

  static Future<Map<String, dynamic>?> readAudioMetadata(
    String filePath,
  ) async {
    try {
      final result = await _channel.invokeMethod('readAudioMetadata', {
        'file_path': filePath,
      });
      return _decodeNullableMapResult(result, 'readAudioMetadata');
    } catch (e) {
      _log.w('Failed to read audio metadata: $e');
      return null;
    }
  }

  static Future<Map<String, dynamic>> runPostProcessingV2(
    String filePath, {
    Map<String, dynamic>? metadata,
    String? itemId,
  }) async {
    final input = <String, dynamic>{};
    if (itemId != null && itemId.isNotEmpty) input['item_id'] = itemId;
    if (isContentUri(filePath)) {
      input['uri'] = filePath;
    } else {
      input['path'] = filePath;
    }
    final result = await _invokeMap('runPostProcessingV2', {
      'input': jsonEncode(input),
      'metadata': metadata != null ? jsonEncode(metadata) : '',
    });
    if (result['success'] != true) return result;

    // The native result uses new_file_path; the queue consumes file_path.
    // SAF publishes back to its document URI after processing a temporary file.
    final uri = result['new_file_uri'];
    final path = result['new_file_path'];
    final legacyPath = result['file_path'];
    if (isContentUri(filePath) && uri is String && uri.isNotEmpty) {
      result['file_path'] = uri;
    } else if (path is String && path.isNotEmpty) {
      result['file_path'] = path;
    } else if (legacyPath is! String || legacyPath.isEmpty) {
      result['file_path'] = filePath;
    }
    return result;
  }

  static Future<void> initExtensionRepo(String cacheDir) async {
    _log.d('initExtensionRepo: $cacheDir');
    await _invokeVoid('initExtensionRepo', {'cache_dir': cacheDir});
  }

  static Future<void> setRepoRegistryUrl(String registryUrl) async {
    _log.d('setRepoRegistryUrl: $registryUrl');
    await _invokeVoid('setRepoRegistryUrl', {'registry_url': registryUrl});
  }

  static Future<String> getRepoRegistryUrl() async {
    _log.d('getRepoRegistryUrl');
    return await _invokeAs<String?>('getRepoRegistryUrl') ?? '';
  }

  static Future<void> clearRepoRegistryUrl() async {
    _log.d('clearRepoRegistryUrl');
    await _invokeVoid('clearRepoRegistryUrl');
  }

  static Future<List<Map<String, dynamic>>> getRepoExtensions({
    bool forceRefresh = false,
  }) async {
    _log.d('getRepoExtensions (forceRefresh: $forceRefresh)');
    return _invokeDecoded(_decodeMapListResultAsync, 'getRepoExtensions', {
      'force_refresh': forceRefresh,
    });
  }

  static Future<String> downloadRepoExtension(
    String extensionId,
    String destDir,
  ) async {
    _log.i('downloadRepoExtension: $extensionId to $destDir');
    return _invokeAs('downloadRepoExtension', {
      'extension_id': extensionId,
      'dest_dir': destDir,
    });
  }

  static Future<Map<String, dynamic>> parseCueSheet(
    String cuePath, {
    String audioDir = '',
  }) {
    _log.i('parseCueSheet: $cuePath (audioDir: $audioDir)');
    return _invokeMap('parseCueSheet', {
      'cue_path': cuePath,
      'audio_dir': audioDir,
    });
  }
}
