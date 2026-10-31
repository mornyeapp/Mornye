import 'dart:async';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/constants/app_info.dart';
import 'package:mornye/services/link/client/link_client_bonsoir.dart';
import 'package:mornye/services/link/client/link_client_discovery.dart';
import 'package:mornye/services/link/client/link_client_http.dart';
import 'package:mornye/services/link/client/link_client_library.dart';
import 'package:mornye/services/link/client/link_client_pairing.dart';
import 'package:mornye/services/link/client/link_client_session.dart';
import 'package:mornye/services/link/client/link_client_store.dart';
import 'package:mornye/services/link/link_client_api.dart';
import 'package:mornye/services/link/link_protocol.dart';
import 'package:mornye/services/local_network_access.dart';
import 'package:mornye/services/network_storage_service.dart';
import 'package:mornye/utils/logger.dart';

final _log = AppLogger('LinkClient');

/// Whether this device runs the phone side of Mornye Link.
final linkClientSupportedProvider = Provider<bool>(
  (ref) => Platform.isAndroid || Platform.isIOS,
);

/// Device inputs of the client, replaced in tests.
class LinkClientEnvironment {
  const LinkClientEnvironment({
    required this.deviceName,
    required this.platform,
    required this.appVersion,
    required this.createBrowser,
    required this.createSession,
    required this.ensureLocalNetwork,
    required this.onLocalNetwork,
    this.networkChanges = const Stream<void>.empty(),
  });

  /// The name desktops list this phone under.
  final Future<String> Function() deviceName;

  /// `android` or `ios`.
  final String platform;
  final String appVersion;
  final LinkServiceBrowser Function() createBrowser;
  final LinkSession Function(
    LinkServerRecord server,
    String apiKey,
    LinkDeviceIdentity device,
  )
  createSession;

  /// Asks for local network access where the OS gates it; throws
  /// [LocalNetworkPermissionException] when refused.
  final Future<void> Function() ensureLocalNetwork;

  /// Whether Wi-Fi or Ethernet is connected.
  final Future<bool> Function() onLocalNetwork;

  /// Interface changes can invalidate discovery even when Wi-Fi stays on.
  final Stream<void> networkChanges;

  factory LinkClientEnvironment.device() => LinkClientEnvironment(
    deviceName: _deviceName,
    platform: Platform.isIOS ? 'ios' : 'android',
    appVersion: AppInfo.version,
    createBrowser: BonsoirLinkServiceBrowser.new,
    createSession: (server, apiKey, device) =>
        LinkClientSession(server: server, apiKey: apiKey, device: device),
    ensureLocalNetwork: LocalNetworkAccess.instance.ensureGranted,
    onLocalNetwork: _onLocalNetwork,
    networkChanges: Connectivity().onConnectivityChanged.map((_) {}),
  );

  static Future<String> _deviceName() async {
    try {
      final info = DeviceInfoPlugin();
      if (Platform.isAndroid) {
        final android = await info.androidInfo;
        final name = android.name.trim();
        return name.isNotEmpty ? name : android.model;
      }
      if (Platform.isIOS) {
        final ios = await info.iosInfo;
        return ios.name.trim().isNotEmpty ? ios.name.trim() : ios.model;
      }
    } catch (error) {
      _log.w('Reading the device name failed: $error');
    }
    return Platform.isIOS ? 'iPhone' : 'Android';
  }

  static Future<bool> _onLocalNetwork() async {
    try {
      final results = await Connectivity().checkConnectivity();
      return results.contains(ConnectivityResult.wifi) ||
          results.contains(ConnectivityResult.ethernet);
    } catch (_) {
      // Unknown: do not warn about something we could not check.
      return true;
    }
  }
}

final linkClientEnvironmentProvider = Provider<LinkClientEnvironment>(
  (ref) => LinkClientEnvironment.device(),
);

final linkClientStoreProvider = Provider<LinkClientStore>(
  (ref) => LinkClientStore(),
);

final linkPairingApiProvider = Provider<LinkPairingApi>(
  (ref) => LinkPairingClient(),
);

final linkLibraryBridgeProvider = Provider<LinkLibraryBridge>(
  LinkNetworkLibraryBridge.new,
);

@immutable
class LinkClientState {
  const LinkClientState({
    this.loaded = false,
    this.servers = const [],
    this.activeServerId,
    this.connection = LinkConnectionState.disconnected,
    this.issue,
    this.discovered = const [],
    this.discovery = LinkDiscoveryStatus.idle,
    this.localNetworkAvailable = true,
  });

  final bool loaded;

  /// Paired desktops, in pairing order.
  final List<LinkServerRecord> servers;

  /// The desktop [linkActiveClientProvider] talks to.
  final String? activeServerId;

  /// The active session's connection.
  final LinkConnectionState connection;

  /// Why the active session last failed, cleared once it connects.
  final LinkSessionIssue? issue;

  /// Desktops on the network while discovery runs.
  final List<LinkDiscoveredServer> discovered;
  final LinkDiscoveryStatus discovery;

  /// False when neither Wi-Fi nor Ethernet is connected.
  final bool localNetworkAvailable;

  LinkServerRecord? get activeServer =>
      servers.where((s) => s.serverId == activeServerId).firstOrNull;

  /// Discovered desktops this phone is not paired with.
  List<LinkDiscoveredServer> get unpaired => [
    for (final server in discovered)
      if (!servers.any((s) => s.serverId == server.serverId)) server,
  ];

  LinkDiscoveredServer? discoveredServer(String serverId) =>
      discovered.where((s) => s.serverId == serverId).firstOrNull;

  /// Whether discovery sees [server] with another certificate than the one
  /// it was paired with.
  bool certificateChanged(LinkServerRecord server) {
    final found = discoveredServer(server.serverId);
    return found != null && found.fingerprint != server.fingerprint;
  }

  LinkClientState copyWith({
    bool? loaded,
    List<LinkServerRecord>? servers,
    String? activeServerId,
    bool clearActiveServer = false,
    LinkConnectionState? connection,
    LinkSessionIssue? issue,
    bool clearIssue = false,
    List<LinkDiscoveredServer>? discovered,
    LinkDiscoveryStatus? discovery,
    bool? localNetworkAvailable,
  }) => LinkClientState(
    loaded: loaded ?? this.loaded,
    servers: servers ?? this.servers,
    activeServerId: clearActiveServer
        ? null
        : activeServerId ?? this.activeServerId,
    connection: connection ?? this.connection,
    issue: clearIssue ? null : issue ?? this.issue,
    discovered: discovered ?? this.discovered,
    discovery: discovery ?? this.discovery,
    localNetworkAvailable: localNetworkAvailable ?? this.localNetworkAvailable,
  );
}

/// The phone side of Mornye Link: paired desktops, discovery, pairing and
/// the active session it publishes through [linkActiveClientProvider].
/// The app root keeps it alive on phones; it does nothing elsewhere.
class LinkClientController extends Notifier<LinkClientState> {
  /// How long `catalog.changed` bursts settle before a rescan.
  static const rescanDelay = Duration(seconds: 2);
  static const discoveryRetryDelay = Duration(seconds: 2);
  static const discoveryRefreshInterval = Duration(seconds: 15);
  static const networkDiscoveryDuration = Duration(seconds: 30);

  LinkSession? _session;
  StreamSubscription<LinkConnectionState>? _stateSubscription;
  StreamSubscription<Map<String, dynamic>>? _messageSubscription;
  LinkDiscovery? _discovery;
  AppLifecycleListener? _lifecycle;
  StreamSubscription<void>? _networkSubscription;
  Timer? _discoveryRetry;
  Timer? _discoveryRefresh;
  Timer? _networkDiscovery;
  var _discoveryFailures = 0;
  var _restartingDiscovery = false;
  Timer? _rescan;
  Future<void> _mutation = Future.value();
  Future<void>? _loading;
  LinkDeviceIdentity? _device;
  var _foreground = true;

  /// [linkKeepConnectedProvider]: the session stays connected in the
  /// background too.
  var _keepConnected = false;
  var _discoveryHolds = 0;
  var _discoveryBlocked = false;

  /// True until a supported build starts the client and after disposal, so
  /// every entry point is inert on desktops.
  var _disposed = true;

  LinkClientEnvironment get _environment =>
      ref.read(linkClientEnvironmentProvider);
  LinkClientStore get _store => ref.read(linkClientStoreProvider);
  LinkLibraryBridge get _library => ref.read(linkLibraryBridgeProvider);

  /// The active session, as [linkActiveClientProvider] publishes it.
  LinkSession? get session => _session;

  /// Completes once paired desktops are loaded and the session started.
  Future<void> get ready => _loading ?? Future.value();

  @override
  LinkClientState build() {
    if (!ref.watch(linkClientSupportedProvider)) {
      return const LinkClientState(loaded: true);
    }
    _disposed = false;
    _lifecycle = AppLifecycleListener(onStateChange: _onLifecycle);
    _networkSubscription = _environment.networkChanges.listen(
      (_) => unawaited(_refreshNetworkConnection()),
      onError: (Object error) =>
          _log.w('Watching local network failed: $error'),
    );
    ref.listen(
      linkKeepConnectedProvider,
      (_, keep) => _updateConnected(() => _keepConnected = keep),
      fireImmediately: true,
    );
    ref.onDispose(_dispose);
    _loading = Future<void>.microtask(
      () => _serial(_load).catchError(
        (Object error, StackTrace stack) =>
            _log.e('Loading paired computers failed', error, stack),
      ),
    );
    return const LinkClientState();
  }

  Future<T> _serial<T>(Future<T> Function() action) {
    final result = _mutation.then((_) => action());
    _mutation = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  Future<void> _load() async {
    final store = _store;
    final servers = await store.servers();
    var active = await store.activeServerId();
    if (_disposed) return;
    if (!servers.any((s) => s.serverId == active)) {
      active = servers.firstOrNull?.serverId;
    }
    state = state.copyWith(
      loaded: true,
      servers: servers,
      activeServerId: active,
      clearActiveServer: active == null,
    );
    await _restartSession();
  }

  Future<LinkDeviceIdentity> _identity() async {
    final known = _device;
    if (known != null) return known;
    final environment = _environment;
    final deviceId = await _store.deviceId();
    final name = await environment.deviceName();
    return _device = LinkDeviceIdentity(
      deviceId: deviceId,
      name: name,
      platform: environment.platform,
      appVersion: environment.appVersion,
    );
  }

  /// Replaces the session with one for the active desktop. Runs serialized.
  Future<void> _restartSession() async {
    final previous = _session;
    _session = null;
    await _stateSubscription?.cancel();
    await _messageSubscription?.cancel();
    _stateSubscription = null;
    _messageSubscription = null;
    _rescan?.cancel();
    final record = state.activeServer;
    LinkSession? next;
    LinkSessionIssue? issue;
    if (record != null) {
      final connection = await _library.connection(record.connectionId);
      if (_disposed) {
        await previous?.dispose();
        return;
      }
      if (connection == null || connection.apiKey.isEmpty) {
        // The network connection was removed elsewhere: pair again.
        issue = LinkSessionIssue.unauthorized;
      } else {
        next = _environment.createSession(
          record,
          connection.apiKey,
          await _identity(),
        );
      }
    }
    if (_disposed) {
      await previous?.dispose();
      await next?.dispose();
      return;
    }
    _session = next;
    if (next != null) {
      final session = next;
      _stateSubscription = session.connectionStates.listen(
        (_) => _onConnection(session),
      );
      _messageSubscription = session.messages.listen(
        (message) => _onMessage(session, message),
      );
    }
    ref.read(linkActiveClientProvider.notifier).set(next);
    state = state.copyWith(
      connection: next?.connectionState ?? LinkConnectionState.disconnected,
      issue: issue,
      clearIssue: issue == null,
    );
    await previous?.dispose();
    if (next != null) {
      if (!_connected) next.pause();
      next.start();
    }
    _updateDiscovery();
  }

  void _onConnection(LinkSession session) {
    if (_disposed || !identical(session, _session)) return;
    state = state.copyWith(
      connection: session.connectionState,
      issue: session.issue,
      clearIssue: session.issue == null,
    );
    _library.setReachable(
      session.server.connectionId,
      reachable: session.issue != LinkSessionIssue.unreachable,
    );
    _updateDiscovery();
  }

  void _onMessage(LinkSession session, Map<String, dynamic> message) {
    if (_disposed || !identical(session, _session)) return;
    if (message['type'] != LinkMessageTypes.catalogChanged) return;
    final connectionId = session.server.connectionId;
    _rescan?.cancel();
    _rescan = Timer(rescanDelay, () {
      _rescan = null;
      unawaited(
        _library
            .rescan(connectionId)
            .catchError(
              (Object error) =>
                  _log.w('Rescanning the computer failed: $error'),
            ),
      );
    });
  }

  void _onLifecycle(AppLifecycleState lifecycle) {
    // Inactive covers the iOS control centre and app switcher; keep going.
    if (lifecycle == AppLifecycleState.inactive || _disposed) return;
    final foreground = lifecycle == AppLifecycleState.resumed;
    if (foreground == _foreground && !foreground) return;
    _updateConnected(() => _foreground = foreground);
    if (foreground) {
      // Control Centre and permission dialogs can change the network without
      // ever putting the app into the paused lifecycle state.
      unawaited(_refreshNetworkConnection());
    } else {
      _updateDiscovery();
    }
  }

  /// Whether the session is connected rather than paused.
  bool get _connected => _foreground || _keepConnected;

  /// Applies [change], then pauses or resumes the session when that changed
  /// [_connected].
  void _updateConnected(void Function() change) {
    final was = _connected;
    change();
    if (_connected == was || _disposed) return;
    if (_connected) {
      _session?.resume();
    } else {
      _session?.pause();
    }
    if (!_foreground) _updateDiscovery();
  }

  /// Keeps discovery running while the returned callback is not called, for
  /// the settings page. Discovery also runs on its own while the active
  /// desktop is unreachable, to follow it to a new address.
  ///
  /// Pages call it from `initState` and release it from `dispose`, so the
  /// state changes it causes wait for a microtask, after the frame.
  VoidCallback acquireDiscovery() {
    _discoveryHolds++;
    _discoveryBlocked = false;
    scheduleMicrotask(_updateDiscovery);
    unawaited(Future<void>.microtask(refreshLocalNetwork));
    var released = false;
    return () {
      if (released) return;
      released = true;
      _discoveryHolds--;
      scheduleMicrotask(_updateDiscovery);
    };
  }

  void _updateDiscovery() {
    if (_disposed || _restartingDiscovery) return;
    if (!_connected || !state.localNetworkAvailable || _session == null) {
      _networkDiscovery?.cancel();
      _networkDiscovery = null;
    }
    final reconnecting =
        _session != null && state.connection != LinkConnectionState.connected;
    final wanted =
        _connected &&
        state.localNetworkAvailable &&
        !_discoveryBlocked &&
        ((_foreground && _discoveryHolds > 0) ||
            reconnecting ||
            _networkDiscovery != null);
    final discovery = _discovery ??= LinkDiscovery(
      createBrowser: _environment.createBrowser,
      ensureAccess: _environment.ensureLocalNetwork,
      onChanged: _onDiscoveryChanged,
    );
    if (!wanted) {
      _discoveryRetry?.cancel();
      _discoveryRetry = null;
      _discoveryFailures = 0;
    }
    if (wanted &&
        _discoveryRetry == null &&
        discovery.status != LinkDiscoveryStatus.searching) {
      unawaited(discovery.start());
    } else if (!wanted && discovery.status == LinkDiscoveryStatus.searching) {
      unawaited(discovery.stop());
    }
    // Older NSD/Bonjour resolvers can keep the first IP indefinitely without
    // emitting an update. Recreate them only while a session needs recovery.
    if (wanted && reconnecting && discovery.running) {
      _discoveryRefresh ??= Timer(discoveryRefreshInterval, () {
        _discoveryRefresh = null;
        unawaited(_restartDiscovery());
      });
    } else {
      _discoveryRefresh?.cancel();
      _discoveryRefresh = null;
    }
  }

  void _onDiscoveryChanged() {
    final discovery = _discovery;
    if (_disposed || discovery == null) return;
    final before = {for (final s in state.discovered) s.serverId};
    final found = discovery.servers;
    if (!discovery.running) {
      _discoveryRefresh?.cancel();
      _discoveryRefresh = null;
    }
    if (discovery.status == LinkDiscoveryStatus.permissionDenied) {
      // Do not ask again on every reconnect; the page offers a button.
      _discoveryBlocked = true;
    }
    state = state.copyWith(discovered: found, discovery: discovery.status);
    if (discovery.status == LinkDiscoveryStatus.failed &&
        _connected &&
        state.localNetworkAvailable &&
        !_discoveryBlocked &&
        _discoveryRetry == null) {
      final delay = discoveryRetryDelay * (1 << _discoveryFailures.clamp(0, 4));
      _discoveryFailures++;
      _discoveryRetry = Timer(delay, () {
        _discoveryRetry = null;
        _updateDiscovery();
      });
    } else if (found.isNotEmpty) {
      _discoveryFailures = 0;
    }
    for (final server in found) {
      final record = state.servers
          .where((s) => s.serverId == server.serverId)
          .firstOrNull;
      // Another certificate under a known id is not followed anywhere.
      if (record == null || record.fingerprint != server.fingerprint) continue;
      if (record.address != server.address) {
        unawaited(
          _serial(
            () => _move(
              record.serverId,
              server.address,
              fingerprint: server.fingerprint,
            ),
          ).catchError(
            (Object error) =>
                _log.w('Updating the computer address failed: $error'),
          ),
        );
      } else if (!before.contains(server.serverId) &&
          record.serverId == state.activeServerId) {
        _session?.reconnectNow();
      }
    }
  }

  Future<void> _move(
    String serverId,
    String address, {
    required String fingerprint,
  }) async {
    final record = state.servers
        .where((s) => s.serverId == serverId)
        .firstOrNull;
    if (record == null ||
        record.fingerprint != fingerprint ||
        record.address == address ||
        _disposed) {
      return;
    }
    _log.i('Computer ${record.name} moved to a new address');
    final servers = await _store.updateAddress(serverId, address);
    await _library.updateAddress(record.connectionId, address);
    if (_disposed) return;
    state = state.copyWith(servers: servers);
    final updated = servers.where((s) => s.serverId == serverId).firstOrNull;
    final session = _session;
    if (updated != null &&
        session != null &&
        serverId == state.activeServerId) {
      session.updateServer(updated);
    }
  }

  /// Rechecks Wi-Fi for the page's warning.
  Future<void> refreshLocalNetwork() async {
    if (_disposed) return;
    final available = await _environment.onLocalNetwork();
    if (_disposed || available == state.localNetworkAvailable) return;
    state = state.copyWith(localNetworkAvailable: available);
    _updateDiscovery();
  }

  Future<void> _refreshNetworkConnection() async {
    await refreshLocalNetwork();
    if (_disposed) return;
    _networkDiscovery?.cancel();
    _networkDiscovery = null;
    if (_connected && state.localNetworkAvailable && _session != null) {
      // TCP may still look connected after changing Wi-Fi or waking the app.
      // Resolve the desktop again without interrupting a healthy socket.
      _networkDiscovery = Timer(networkDiscoveryDuration, () {
        _networkDiscovery = null;
        _updateDiscovery();
      });
    }
    await _restartDiscovery();
    if (!_disposed &&
        _connected &&
        state.localNetworkAvailable &&
        state.connection != LinkConnectionState.connected) {
      _session?.reconnectNow();
    }
  }

  Future<void> _restartDiscovery() async {
    if (_disposed || _restartingDiscovery) return;
    _restartingDiscovery = true;
    _discoveryRetry?.cancel();
    _discoveryRetry = null;
    _discoveryRefresh?.cancel();
    _discoveryRefresh = null;
    _discoveryFailures = 0;
    try {
      await _discovery?.stop();
    } finally {
      _restartingDiscovery = false;
      _updateDiscovery();
    }
  }

  /// Asks for local network access again, then retries discovery and the
  /// session. Throws [LocalNetworkPermissionException] when refused.
  Future<void> requestLocalNetworkAccess() async {
    if (_disposed) return;
    await _environment.ensureLocalNetwork();
    if (_disposed) return;
    _discoveryBlocked = false;
    await _restartDiscovery();
    _session?.reconnectNow();
  }

  /// Retries the active desktop now.
  void retry() {
    unawaited(_restartDiscovery());
    _session?.reconnectNow();
  }

  /// Reads a desktop's `info` before asking for its PIN.
  Future<LinkPairingTarget> probe(
    String host,
    int port, {
    String? expectedFingerprint,
  }) {
    final address = linkServerAddress(host, port);
    if (address == null) {
      return Future.error(
        const LinkPairingException(LinkPairingError.invalidAddress),
      );
    }
    return ref
        .read(linkPairingApiProvider)
        .probe(address, expectedFingerprint: expectedFingerprint);
  }

  /// Reuses a paired computer after a certificate-checked [probe], including
  /// a manually entered new IP. A missing or refused key still needs a PIN.
  Future<bool> reconnectPaired(LinkPairingTarget target) => _serial(() async {
    if (_disposed) return false;
    final record = state.servers
        .where((server) => server.serverId == target.info.serverId)
        .firstOrNull;
    if (record == null) return false;
    if (record.fingerprint != target.fingerprint) {
      throw const LinkPairingException(LinkPairingError.certificateMismatch);
    }
    final connection = await _library.connection(record.connectionId);
    if (_disposed || connection == null || connection.apiKey.isEmpty) {
      return false;
    }
    final active = state.activeServerId == record.serverId;
    if (active && state.issue == LinkSessionIssue.unauthorized) return false;
    await _move(
      record.serverId,
      target.address,
      fingerprint: target.fingerprint,
    );
    if (_disposed) return false;
    if (!active) {
      await _store.setActiveServerId(record.serverId);
      if (_disposed) return false;
      state = state.copyWith(activeServerId: record.serverId);
      await _restartSession();
    } else {
      _session?.reconnectNow();
    }
    return true;
  });

  /// Pairs with [target] using [pin]. On success the desktop is saved as a
  /// Subsonic network connection, added to Library and scanned; re-pairing
  /// replaces the stored key. Throws [LinkPairingException].
  Future<LinkServerRecord> pair(LinkPairingTarget target, String pin) async {
    final result = await ref
        .read(linkPairingApiProvider)
        .pair(target, pin: pin, device: await _identity());
    final (record, connection) = await _serial(() async {
      final existing = state.servers
          .where((s) => s.serverId == result.serverId)
          .firstOrNull;
      final name = result.name.isNotEmpty
          ? result.name
          : Uri.parse(target.address).host;
      final connection = NetworkConnection(
        id: existing?.connectionId ?? NetworkStorageService.newId(),
        name: name,
        protocol: NetworkProtocol.subsonic,
        address: target.address,
        subsonicAuth: SubsonicAuth.apiKey,
        apiKey: result.apiKey,
        trustedCertificateSha256: result.fingerprint,
      );
      await _library.saveConnection(connection);
      final record = LinkServerRecord(
        serverId: result.serverId,
        name: name,
        connectionId: connection.id,
        address: target.address,
        fingerprint: result.fingerprint,
      );
      final servers = await _store.upsert(record);
      var active = state.activeServerId;
      if (active == null || !servers.any((s) => s.serverId == active)) {
        active = record.serverId;
        await _store.setActiveServerId(active);
      }
      if (!_disposed) {
        state = state.copyWith(servers: servers, activeServerId: active);
        if (active == record.serverId) await _restartSession();
      }
      return (record, connection);
    });
    unawaited(
      _library
          .addLibrarySource(connection)
          .catchError(
            (Object error) =>
                _log.w('Adding the computer to Library failed: $error'),
          ),
    );
    return record;
  }

  /// Makes [serverId] the desktop features talk to.
  Future<void> setActive(String serverId) => _serial(() async {
    if (state.activeServerId == serverId ||
        !state.servers.any((s) => s.serverId == serverId)) {
      return;
    }
    await _store.setActiveServerId(serverId);
    if (_disposed) return;
    state = state.copyWith(activeServerId: serverId);
    await _restartSession();
  });

  /// Forgets a paired desktop. With [removeLibrary] its network connection
  /// and Library source go too; otherwise its music stays browsable.
  Future<void> forget(String serverId, {required bool removeLibrary}) =>
      _serial(() async {
        final record = state.servers
            .where((s) => s.serverId == serverId)
            .firstOrNull;
        if (record == null) return;
        final servers = await _store.remove(serverId);
        final wasActive = state.activeServerId == serverId;
        final active = wasActive
            ? servers.firstOrNull?.serverId
            : state.activeServerId;
        if (wasActive) await _store.setActiveServerId(active);
        if (!_disposed) {
          state = state.copyWith(
            servers: servers,
            activeServerId: active,
            clearActiveServer: active == null,
          );
          if (wasActive) await _restartSession();
        }
        if (removeLibrary) await _library.removeConnection(record.connectionId);
      });

  void _dispose() {
    _disposed = true;
    _lifecycle?.dispose();
    _lifecycle = null;
    unawaited(_networkSubscription?.cancel());
    _networkSubscription = null;
    _discoveryRetry?.cancel();
    _discoveryRefresh?.cancel();
    _networkDiscovery?.cancel();
    _rescan?.cancel();
    unawaited(_stateSubscription?.cancel());
    unawaited(_messageSubscription?.cancel());
    final discovery = _discovery;
    _discovery = null;
    unawaited(discovery?.stop());
    final session = _session;
    _session = null;
    unawaited(session?.dispose());
  }
}

final linkClientControllerProvider =
    NotifierProvider<LinkClientController, LinkClientState>(
      LinkClientController.new,
    );
