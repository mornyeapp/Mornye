import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:mornye/services/link/client/link_client_controller.dart';
import 'package:mornye/services/link/client/link_client_discovery.dart';
import 'package:mornye/services/link/client/link_client_library.dart';
import 'package:mornye/services/link/client/link_client_pairing.dart';
import 'package:mornye/services/link/client/link_client_session.dart';
import 'package:mornye/services/link/client/link_client_store.dart';
import 'package:mornye/services/link/link_client_api.dart';
import 'package:mornye/services/link/link_protocol.dart';
import 'package:mornye/services/local_network_access.dart';
import 'package:mornye/services/network_storage_service.dart';

/// A stable fake certificate fingerprint per server id.
String linkTestFingerprint(String serverId) =>
    serverId.codeUnitAt(0).toRadixString(16).padLeft(2, '0') * 32;

LinkPairingTarget linkTestTarget(
  String serverId, {
  String host = '10.0.0.2',
  bool pairing = true,
}) => LinkPairingTarget(
  address: 'https://$host:47710',
  info: LinkServerInfo(
    serverId: serverId,
    name: 'Desktop $serverId',
    protocol: linkProtocolVersion,
    appVersion: '5.3.0',
    fingerprint: linkTestFingerprint(serverId),
    pairing: pairing,
  ),
);

class FakeLinkSession implements LinkSession {
  FakeLinkSession(this.server, this.apiKey);

  @override
  LinkServerRecord server;
  final String apiKey;
  final _states = StreamController<LinkConnectionState>.broadcast();
  final _messages = StreamController<Map<String, dynamic>>.broadcast();
  final calls = <String>[];
  bool disposed = false;

  @override
  LinkConnectionState connectionState = LinkConnectionState.disconnected;

  @override
  LinkSessionIssue? issue;

  void emit(LinkConnectionState state, [LinkSessionIssue? reason]) {
    connectionState = state;
    issue = reason;
    _states.add(state);
  }

  void push(Map<String, dynamic> message) => _messages.add(message);

  @override
  Stream<LinkConnectionState> get connectionStates => _states.stream;

  @override
  Stream<Map<String, dynamic>> get messages => _messages.stream;

  @override
  void send(Map<String, dynamic> message) => calls.add('send');

  @override
  Future<Object?> get(String op, [Map<String, String> query = const {}]) =>
      throw UnimplementedError();

  @override
  Future<Object?> post(String op, Map<String, dynamic> body) =>
      throw UnimplementedError();

  @override
  Future<void> upload(
    String name,
    File file, {
    void Function(int sent)? onProgress,
  }) => throw UnimplementedError();

  @override
  void start() => calls.add('start');

  @override
  void pause() => calls.add('pause');

  @override
  void resume() => calls.add('resume');

  @override
  void reconnectNow() => calls.add('reconnect');

  @override
  void updateServer(LinkServerRecord server) {
    this.server = server;
    calls.add('update ${server.address}');
  }

  @override
  Future<void> dispose() async {
    disposed = true;
    await _states.close();
    await _messages.close();
  }
}

class FakeLinkBrowser implements LinkServiceBrowser {
  StreamController<LinkServiceEvent>? events;
  int started = 0;
  int stopped = 0;

  @override
  Future<Stream<LinkServiceEvent>> start() async {
    started++;
    events = StreamController<LinkServiceEvent>();
    return events!.stream;
  }

  @override
  Future<void> stop() async {
    stopped++;
    unawaited(events?.close());
    events = null;
  }

  /// A desktop advertising [serverId] at [host].
  void resolve(String serverId, String host, {String? fingerprint}) =>
      events!.add(
        LinkServiceResolved(
          name: 'Desktop $serverId',
          port: 47710,
          addresses: [host],
          attributes: {
            'v': '1',
            'id': serverId,
            'fp': fingerprint ?? linkTestFingerprint(serverId),
          },
        ),
      );
}

class FakeLinkBridge implements LinkLibraryBridge {
  final connections = <String, NetworkConnection>{};
  final calls = <String>[];

  /// The latest reachability reported for each connection.
  final reachable = <String, bool>{};

  @override
  Future<NetworkConnection?> connection(String connectionId) async =>
      connections[connectionId];

  @override
  void setReachable(String connectionId, {required bool reachable}) =>
      this.reachable[connectionId] = reachable;

  @override
  Future<void> saveConnection(NetworkConnection connection) async {
    connections[connection.id] = connection;
    calls.add('save ${connection.id}');
  }

  @override
  Future<void> updateAddress(String connectionId, String address) async =>
      calls.add('address $connectionId $address');

  @override
  Future<void> addLibrarySource(NetworkConnection connection) async =>
      calls.add('source ${connection.id}');

  @override
  Future<void> rescan(String connectionId) async =>
      calls.add('rescan $connectionId');

  @override
  Future<void> removeConnection(String connectionId) async {
    connections.remove(connectionId);
    calls.add('remove $connectionId');
  }
}

class FakeLinkPairing implements LinkPairingApi {
  /// Desktops [probe] finds, by host.
  final targets = <String, LinkPairingTarget>{};
  final probes = <({Uri address, String? expectedFingerprint})>[];
  final pins = <String>[];
  final devices = <LinkDeviceIdentity>[];
  String key = 'key-1';
  LinkPairingError? probeError;
  LinkPairingError? error;

  @override
  Future<LinkPairingTarget> probe(
    Uri address, {
    String? expectedFingerprint,
  }) async {
    probes.add((address: address, expectedFingerprint: expectedFingerprint));
    if (probeError case final error?) throw LinkPairingException(error);
    final target = targets[address.host];
    if (target == null) {
      throw const LinkPairingException(LinkPairingError.unreachable);
    }
    return target;
  }

  @override
  Future<LinkPairingResult> pair(
    LinkPairingTarget target, {
    required String pin,
    required LinkDeviceIdentity device,
  }) async {
    pins.add(pin);
    devices.add(device);
    if (error case final error?) throw LinkPairingException(error);
    return LinkPairingResult(
      apiKey: key,
      serverId: target.info.serverId,
      name: target.info.name,
      fingerprint: target.fingerprint,
    );
  }
}

/// The client's providers wired to fakes. Tests set
/// `SharedPreferences.setMockInitialValues` first.
class LinkClientHarness {
  LinkClientHarness({this.supported = true});

  final bool supported;
  final browser = FakeLinkBrowser();
  final bridge = FakeLinkBridge();
  final pairing = FakeLinkPairing();
  final sessions = <FakeLinkSession>[];
  bool localNetworkAllowed = true;
  bool onWifi = true;

  List<Override> get overrides => [
    linkClientSupportedProvider.overrideWithValue(supported),
    linkClientEnvironmentProvider.overrideWithValue(
      LinkClientEnvironment(
        deviceName: () async => 'Test phone',
        platform: 'android',
        appVersion: '5.3.0',
        createBrowser: () => browser,
        createSession: (server, apiKey, device) {
          final session = FakeLinkSession(server, apiKey);
          sessions.add(session);
          return session;
        },
        ensureLocalNetwork: () async {
          if (!localNetworkAllowed) {
            throw const LocalNetworkPermissionException();
          }
        },
        onLocalNetwork: () async => onWifi,
      ),
    ),
    linkClientStoreProvider.overrideWithValue(LinkClientStore()),
    linkPairingApiProvider.overrideWithValue(pairing),
    linkLibraryBridgeProvider.overrideWithValue(bridge),
  ];

  late final container = ProviderContainer(overrides: overrides);

  LinkClientController get controller =>
      container.read(linkClientControllerProvider.notifier);
  LinkClientState get state => container.read(linkClientControllerProvider);
  LinkClientApi? get active => container.read(linkActiveClientProvider);

  /// Keeps the controller alive, as the app root does, and waits for it to
  /// load.
  Future<void> start() async {
    container.listen(linkClientControllerProvider, (_, _) {});
    await controller.ready;
  }
}
