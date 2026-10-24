import 'package:mornye/services/link/link_protocol.dart';

/// A paired desktop as the phone remembers it.
class LinkServerRecord {
  const LinkServerRecord({
    required this.serverId,
    required this.name,
    required this.connectionId,
    required this.address,
    required this.fingerprint,
  });

  final String serverId;
  final String name;

  /// The `NetworkConnection` (Subsonic, API key, pinned certificate) that
  /// browses and streams this desktop's library.
  final String connectionId;

  /// `https://host:port`.
  final String address;
  final String fingerprint;

  Map<String, dynamic> toJson() => {
    'serverId': serverId,
    'name': name,
    'connectionId': connectionId,
    'address': address,
    'fingerprint': fingerprint,
  };

  static LinkServerRecord? fromJson(Object? json) {
    if (json is! Map) return null;
    final serverId = json['serverId'];
    final connectionId = json['connectionId'];
    final address = json['address'];
    final fingerprint = json['fingerprint'];
    if (serverId is! String ||
        connectionId is! String ||
        address is! String ||
        fingerprint is! String) {
      return null;
    }
    return LinkServerRecord(
      serverId: serverId,
      name: json['name'] as String? ?? '',
      connectionId: connectionId,
      address: address,
      fingerprint: fingerprint,
    );
  }
}

enum LinkConnectionState { disconnected, connecting, connected }

/// The phone's session with one paired desktop. Implemented by the client
/// unit; features and sync use only this interface and fake it in tests.
abstract interface class LinkClientApi {
  LinkServerRecord get server;

  LinkConnectionState get connectionState;
  Stream<LinkConnectionState> get connectionStates;

  /// Messages the desktop pushed over the WebSocket (`player.state`,
  /// `command`, `open`, `downloads.changed`, `collections.changed`,
  /// `catalog.changed`), each a decoded JSON map with a `type`.
  Stream<Map<String, dynamic>> get messages;

  /// Sends one message over the WebSocket; dropped while disconnected.
  void send(Map<String, dynamic> message);

  /// `GET /mornye/v1/<op>` with [query]; throws [LinkException].
  Future<Object?> get(String op, [Map<String, String> query = const {}]);

  /// `POST /mornye/v1/<op>` with a JSON [body]; throws [LinkException].
  Future<Object?> post(String op, Map<String, dynamic> body);
}
