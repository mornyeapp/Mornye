import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/services/link/link_protocol.dart';

/// A paired desktop as the phone remembers it.
class LinkServerRecord {
  const LinkServerRecord({
    required this.serverId,
    required this.name,
    required this.connectionId,
    required this.address,
    required this.fingerprint,
    this.typedAddress = false,
    this.platform = '',
    this.features,
  });

  final String serverId;
  final String name;

  /// The `NetworkConnection` (Subsonic, API key, pinned certificate) that
  /// browses and streams this desktop's library.
  final String connectionId;

  /// `https://host:port`.
  final String address;
  final String fingerprint;

  /// The person typed [address], so discovery never replaces it: a VPN
  /// address is not one the local network could find.
  final bool typedAddress;

  /// The host's platform as it announced it, empty for an older host.
  final String platform;

  /// The [LinkHostFeatures] the host announced; null for an older host,
  /// which has all of them.
  final List<String>? features;

  /// Whether the host has the optional ability [feature].
  bool supports(String feature) => features?.contains(feature) ?? true;

  /// Whether the host is another phone rather than a computer.
  bool get isPhone => platform == 'android' || platform == 'ios';

  LinkServerRecord copyWith({
    String? name,
    String? address,
    bool? typedAddress,
    String? platform,
    Object? features = _keepFeatures,
  }) => LinkServerRecord(
    serverId: serverId,
    name: name ?? this.name,
    connectionId: connectionId,
    address: address ?? this.address,
    fingerprint: fingerprint,
    typedAddress: typedAddress ?? this.typedAddress,
    platform: platform ?? this.platform,
    features: identical(features, _keepFeatures)
        ? this.features
        : features as List<String>?,
  );

  /// The same record with what the host announced in [info] or a welcome.
  LinkServerRecord announced({
    required String platform,
    required List<String>? features,
  }) => platform == this.platform && listEquals(features, this.features)
      ? this
      : copyWith(platform: platform, features: features);

  Map<String, dynamic> toJson() => {
    'serverId': serverId,
    'name': name,
    'connectionId': connectionId,
    'address': address,
    'fingerprint': fingerprint,
    if (typedAddress) 'typedAddress': true,
    if (platform.isNotEmpty) 'platform': platform,
    'features': ?features,
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
      typedAddress: json['typedAddress'] == true,
      platform: json['platform'] as String? ?? '',
      features: linkHostFeaturesFromJson(json['features']),
    );
  }
}

const Object _keepFeatures = Object();

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

  /// `PUT /mornye/v1/files/<name>` with the bytes of [file], `<name>` being
  /// a [TrackRef.fileId] and an audio extension. [onProgress] gets the bytes
  /// sent so far. Throws [LinkException].
  Future<void> upload(
    String name,
    File file, {
    void Function(int sent)? onProgress,
  });
}

/// The phone's session with the desktop it is linked to, or null when none
/// is paired. The client unit sets it; features and sync watch it.
class LinkActiveClient extends Notifier<LinkClientApi?> {
  @override
  LinkClientApi? build() => null;

  void set(LinkClientApi? client) => state = client;
}

final linkActiveClientProvider =
    NotifierProvider<LinkActiveClient, LinkClientApi?>(LinkActiveClient.new);

/// Requests a background session on platforms that otherwise suspend an idle
/// Link session. Android already keeps paired phones available through its
/// connected-device service. The app root sets this while the desktop plays
/// in the phone's place: the notification shows the desktop's song, and
/// only the session hears when the desktop moves to another one.
final linkKeepConnectedProvider = Provider<bool>((ref) => false);
