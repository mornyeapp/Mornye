import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/services/link/link_protocol.dart';
import 'package:mornye/services/platform_bridge.dart';

String _string(Object? value) => value is String ? value.trim() : '';

int _int(Object? value) => value is num ? value.toInt() : 0;

List<String> _strings(Object? value) => [
  if (value is List)
    for (final item in value)
      if (item is String && item.trim().isNotEmpty) item.trim(),
];

/// The running server as `linkStart` and `linkStatus` report it.
class LinkHostServer {
  const LinkHostServer({
    required this.port,
    required this.fingerprint,
    required this.serverId,
    required this.name,
    this.addresses = const [],
    this.receivedDir = '',
  });

  factory LinkHostServer.fromJson(Map<String, dynamic> json) => LinkHostServer(
    port: _int(json['port']),
    fingerprint: _string(json['fingerprint']).toLowerCase(),
    serverId: _string(json['serverId']),
    name: _string(json['name']),
    addresses: _strings(json['addresses']),
    receivedDir: _string(json['receivedDir']),
  );

  final int port;

  /// Lowercase hex SHA-256 of the certificate.
  final String fingerprint;
  final String serverId;
  final String name;

  /// Local addresses phones can reach. The server sends full
  /// `https://<ip>:<port>` URLs; a bare IP is also accepted.
  final List<String> addresses;

  /// Where song files phones upload (`PUT files/<name>`) land, or empty.
  final String receivedDir;

  /// The first 8 hex characters phones show while pairing.
  String get shortFingerprint => linkShortFingerprint(fingerprint);

  /// `https://<address>:<port>` for each address.
  List<String> get urls => [
    for (final address in addresses)
      if (address.startsWith('https://'))
        address
      else
        'https://${address.contains(':') ? '[$address]' : address}:$port',
  ];
}

/// The fingerprint prefix shown beside a pairing PIN.
String linkShortFingerprint(String fingerprint) =>
    fingerprint.length <= 8 ? fingerprint : fingerprint.substring(0, 8);

/// A device that owns a key: a paired phone or a Subsonic app.
class LinkPairedDevice {
  const LinkPairedDevice({
    required this.deviceId,
    required this.name,
    required this.platform,
    this.pairedMs = 0,
    this.lastSeenMs = 0,
    this.connected = false,
  });

  factory LinkPairedDevice.fromJson(Map<String, dynamic> json) =>
      LinkPairedDevice(
        deviceId: _string(json['deviceId']),
        name: _string(json['name']),
        platform: _string(json['platform']),
        pairedMs: _int(json['pairedMs']),
        lastSeenMs: _int(json['lastSeenMs']),
        connected: json['connected'] == true,
      );

  final String deviceId;
  final String name;

  /// `android`, `ios`, `macos`, `windows`, `linux` or `subsonic`.
  final String platform;
  final int pairedMs;
  final int lastSeenMs;
  final bool connected;

  bool get isSubsonicApp => platform == 'subsonic';
}

/// An open pairing window.
class LinkPairingWindow {
  const LinkPairingWindow({
    required this.pin,
    required this.expiresMs,
    required this.fingerprint,
  });

  factory LinkPairingWindow.fromJson(Map<String, dynamic> json) =>
      LinkPairingWindow(
        pin: _string(json['pin']),
        expiresMs: _int(json['expiresMs']),
        fingerprint: _string(json['fingerprint']).toLowerCase(),
      );

  final String pin;

  /// When the window closes, in Unix milliseconds.
  final int expiresMs;
  final String fingerprint;
}

/// A key minted for a third-party Subsonic app.
class LinkAppKey {
  const LinkAppKey({required this.deviceId, required this.apiKey});

  factory LinkAppKey.fromJson(Map<String, dynamic> json) => LinkAppKey(
    deviceId: _string(json['deviceId']),
    apiKey: _string(json['apiKey']),
  );

  final String deviceId;
  final String apiKey;
}

/// Why a pairing window closed (`linkPairingEnded`).
enum LinkPairingEndReason { paired, expired, attempts, cancelled }

/// How a pairing window ended, as the pairing dialog reports it.
sealed class LinkPairingEvent {
  const LinkPairingEvent();
}

/// A phone paired (`linkPaired`).
class LinkPairedEvent extends LinkPairingEvent {
  const LinkPairedEvent({
    required this.deviceId,
    required this.name,
    required this.platform,
  });

  final String deviceId;
  final String name;
  final String platform;
}

/// The window closed (`linkPairingEnded`).
class LinkPairingEndedEvent extends LinkPairingEvent {
  const LinkPairingEndedEvent(this.reason);

  final LinkPairingEndReason reason;
}

/// The desktop server calls of the link contract (section 6) and its
/// inbound events. [PlatformLinkDesktopBackend] goes through
/// [PlatformBridge]; tests fake it.
abstract interface class LinkDesktopBackend {
  Future<LinkHostServer> start({required String name, int? port});
  Future<void> stop();

  /// The server as it runs now, or null while stopped.
  Future<({LinkHostServer? server, List<LinkClientInfo> clients})> status();

  /// Returns the number of songs the server loaded.
  Future<int> setCatalog(String path);
  Future<LinkPairingWindow> beginPairing();
  Future<void> endPairing();
  Future<List<LinkPairedDevice>> devices();
  Future<void> revoke(String deviceId);
  Future<LinkAppKey> createKey(String name);
  Future<void> reply(String requestId, {Object? result, LinkException? error});

  /// Sends [message] to [deviceId], or to every connected phone.
  Future<int> send(Map<String, dynamic> message, {String? deviceId});

  Stream<LinkRequestEvent> get requests;
  Stream<LinkMessageEvent> get messages;
  Stream<List<LinkClientInfo>> get clients;
  Stream<LinkPairingEvent> get pairing;
}

/// A forwarded request before routing (`linkRequest`).
class LinkRequestEvent {
  const LinkRequestEvent({
    required this.requestId,
    required this.op,
    required this.deviceId,
    required this.args,
  });

  final String requestId;
  final String op;
  final String deviceId;
  final Map<String, dynamic> args;
}

/// A phone's WebSocket message (`linkMessage`).
class LinkMessageEvent {
  const LinkMessageEvent({required this.deviceId, required this.message});

  final String deviceId;
  final Map<String, dynamic> message;

  String get type => message['type'] as String? ?? '';
}

Map<String, dynamic> _map(Object? value) => value is Map
    ? value.map((key, value) => MapEntry(key.toString(), value))
    : <String, dynamic>{};

List<LinkClientInfo> linkClientsFromJson(Object? value) => [
  if (value is List)
    for (final client in value) ?LinkClientInfo.fromJson(client),
];

class PlatformLinkDesktopBackend implements LinkDesktopBackend {
  const PlatformLinkDesktopBackend();

  @override
  Future<LinkHostServer> start({required String name, int? port}) async =>
      LinkHostServer.fromJson(
        await PlatformBridge.linkStart(name: name, port: port),
      );

  @override
  Future<void> stop() => PlatformBridge.linkStop();

  @override
  Future<({LinkHostServer? server, List<LinkClientInfo> clients})>
  status() async {
    final json = await PlatformBridge.linkStatus();
    return (
      server: json['running'] == true ? LinkHostServer.fromJson(json) : null,
      clients: linkClientsFromJson(json['clients']),
    );
  }

  @override
  Future<int> setCatalog(String path) async =>
      _int((await PlatformBridge.linkSetCatalog(path))['songs']);

  @override
  Future<LinkPairingWindow> beginPairing() async =>
      LinkPairingWindow.fromJson(await PlatformBridge.linkBeginPairing());

  @override
  Future<void> endPairing() => PlatformBridge.linkEndPairing();

  @override
  Future<List<LinkPairedDevice>> devices() async => [
    for (final device in await PlatformBridge.linkDevices())
      LinkPairedDevice.fromJson(device),
  ];

  @override
  Future<void> revoke(String deviceId) => PlatformBridge.linkRevoke(deviceId);

  @override
  Future<LinkAppKey> createKey(String name) async =>
      LinkAppKey.fromJson(await PlatformBridge.linkCreateKey(name));

  @override
  Future<void> reply(
    String requestId, {
    Object? result,
    LinkException? error,
  }) => PlatformBridge.linkReply(
    requestId,
    result: result,
    error: error?.toJson(),
  );

  @override
  Future<int> send(Map<String, dynamic> message, {String? deviceId}) =>
      PlatformBridge.linkSend(message, deviceId: deviceId);

  @override
  Stream<LinkRequestEvent> get requests =>
      PlatformBridge.linkRequestEvents().map(
        (json) => LinkRequestEvent(
          requestId: _string(json['requestId']),
          op: _string(json['op']),
          deviceId: _string(json['deviceId']),
          args: _map(json['args']),
        ),
      );

  @override
  Stream<LinkMessageEvent> get messages =>
      PlatformBridge.linkMessageEvents().map(
        (json) => LinkMessageEvent(
          deviceId: _string(json['deviceId']),
          message: _map(json['message']),
        ),
      );

  @override
  Stream<List<LinkClientInfo>> get clients => PlatformBridge.linkClientEvents()
      .map((json) => linkClientsFromJson(json['clients']));

  @override
  Stream<LinkPairingEvent> get pairing => _mergePairing(
    PlatformBridge.linkPairedEvents().map(
      (json) => LinkPairedEvent(
        deviceId: _string(json['deviceId']),
        name: _string(json['name']),
        platform: _string(json['platform']),
      ),
    ),
    PlatformBridge.linkPairingEndedEvents().map(
      (reason) => LinkPairingEndedEvent(
        LinkPairingEndReason.values.asNameMap()[reason] ??
            LinkPairingEndReason.cancelled,
      ),
    ),
  );
}

Stream<LinkPairingEvent> _mergePairing(
  Stream<LinkPairingEvent> paired,
  Stream<LinkPairingEvent> ended,
) => Stream.multi((listener) {
  final subscriptions = [
    paired.listen(listener.addSync, onError: listener.addErrorSync),
    ended.listen(listener.addSync, onError: listener.addErrorSync),
  ];
  listener.onCancel = () async {
    for (final subscription in subscriptions) {
      await subscription.cancel();
    }
  };
}, isBroadcast: true);

/// The server calls the desktop host uses. Tests override it.
final linkDesktopBackendProvider = Provider<LinkDesktopBackend>(
  (ref) => const PlatformLinkDesktopBackend(),
);
