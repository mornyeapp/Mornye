import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:mornye/services/link/client/link_client_http.dart';
import 'package:mornye/services/link/link_protocol.dart';
import 'package:mornye/services/local_network_access.dart';

/// How this phone introduces itself to a desktop.
@immutable
class LinkDeviceIdentity {
  const LinkDeviceIdentity({
    required this.deviceId,
    required this.name,
    required this.platform,
    required this.appVersion,
  });

  final String deviceId;
  final String name;

  /// `android` or `ios`.
  final String platform;
  final String appVersion;
}

/// A desktop ready for its PIN: its `info`, read over a connection whose
/// certificate matched the fingerprint it claims.
@immutable
class LinkPairingTarget {
  const LinkPairingTarget({required this.address, required this.info});

  /// `https://host:port`.
  final String address;
  final LinkServerInfo info;

  /// The fingerprint seen in the handshake, equal to [LinkServerInfo.fingerprint].
  String get fingerprint => info.fingerprint;

  /// The first 8 hex characters, which the desktop shows next to its PIN.
  String get shortFingerprint => fingerprint.substring(0, 8);
}

@immutable
class LinkPairingResult {
  const LinkPairingResult({
    required this.apiKey,
    required this.serverId,
    required this.name,
    required this.fingerprint,
  });

  final String apiKey;
  final String serverId;
  final String name;
  final String fingerprint;
}

enum LinkPairingError {
  /// The certificate in the handshake differs from the fingerprint the
  /// desktop (or its mDNS record) claims: possibly someone in between.
  certificateMismatch,

  /// Not a Mornye desktop, or another protocol version.
  incompatible,
  invalidAddress,

  /// The desktop answered `bad_proof`: the PIN is wrong.
  badPin,

  /// The desktop answered `pairing_closed`: no pairing window is open.
  pairingClosed,

  /// The desktop answered 429.
  tooManyAttempts,
  localNetworkPermission,
  unreachable,
  timeout,
  failed,
}

class LinkPairingException implements Exception {
  const LinkPairingException(this.error);

  final LinkPairingError error;

  @override
  String toString() => 'LinkPairingException(${error.name})';
}

/// Pairing as the settings page drives it; faked in widget tests.
abstract interface class LinkPairingApi {
  /// Reads `GET /mornye/v1/info` at [address] and checks the certificate.
  /// [expectedFingerprint] is the one mDNS advertised, when known.
  Future<LinkPairingTarget> probe(Uri address, {String? expectedFingerprint});

  /// Sends the PIN proof; returns the device's API key.
  Future<LinkPairingResult> pair(
    LinkPairingTarget target, {
    required String pin,
    required LinkDeviceIdentity device,
  });
}

final _pinPattern = RegExp(r'^\d{6}$');

/// Contract section 3 over HTTPS: first contact records the certificate,
/// then every request is pinned to it.
class LinkPairingClient implements LinkPairingApi {
  LinkPairingClient({
    Future<void> Function(Uri)? ensureAccess,
    HttpClient Function(Uri target)? firstContactClient,
    HttpClient Function(String fingerprint)? pinnedClient,
    Duration timeout = linkRequestTimeout,
  }) : _ensureAccess = ensureAccess ?? LocalNetworkAccess.instance.ensureAccess,
       _firstContactClient = firstContactClient ?? linkFirstContactHttpClient,
       _pinnedClient = pinnedClient ?? linkPinnedHttpClient,
       _timeout = timeout;

  final Future<void> Function(Uri) _ensureAccess;
  final HttpClient Function(Uri target) _firstContactClient;
  final HttpClient Function(String fingerprint) _pinnedClient;
  final Duration _timeout;

  @override
  Future<LinkPairingTarget> probe(
    Uri address, {
    String? expectedFingerprint,
  }) async {
    if (address.scheme != 'https' || address.host.isEmpty) {
      throw const LinkPairingException(LinkPairingError.invalidAddress);
    }
    final origin = Uri(scheme: 'https', host: address.host, port: address.port);
    final client = _firstContactClient(origin);
    try {
      await _ensureAccess(origin);
      final response = await linkHttpSend(
        client,
        'GET',
        origin.replace(path: '$linkApiPath/info'),
        timeout: _timeout,
      );
      if (!response.ok) {
        throw const LinkPairingException(LinkPairingError.incompatible);
      }
      final info =
          LinkServerInfo.fromJson(response.body) ??
          (throw const LinkPairingException(LinkPairingError.incompatible));
      final observed = response.certificateFingerprint;
      if (!linkFingerprintsMatch(
        observed: observed,
        claimed: info.fingerprint,
        advertised: expectedFingerprint,
      )) {
        throw const LinkPairingException(LinkPairingError.certificateMismatch);
      }
      if (info.protocol != linkProtocolVersion) {
        throw const LinkPairingException(LinkPairingError.incompatible);
      }
      return LinkPairingTarget(address: origin.toString(), info: info);
    } catch (error) {
      throw _classify(error);
    } finally {
      client.close(force: true);
    }
  }

  @override
  Future<LinkPairingResult> pair(
    LinkPairingTarget target, {
    required String pin,
    required LinkDeviceIdentity device,
  }) async {
    if (!_pinPattern.hasMatch(pin)) {
      throw const LinkPairingException(LinkPairingError.badPin);
    }
    final origin = Uri.parse(target.address);
    final client = _pinnedClient(target.fingerprint);
    try {
      await _ensureAccess(origin);
      final response = await linkHttpSend(
        client,
        'POST',
        origin.replace(path: '$linkApiPath/pair'),
        json: {
          'deviceId': device.deviceId,
          'name': device.name,
          'platform': device.platform,
          'proof': linkPairingProof(
            pin: pin,
            fingerprint: target.fingerprint,
            deviceId: device.deviceId,
          ),
        },
        timeout: _timeout,
      );
      final observed = response.certificateFingerprint;
      if (observed != null && observed != target.fingerprint) {
        throw const LinkPairingException(LinkPairingError.certificateMismatch);
      }
      final body = response.body;
      if (response.statusCode == 429) {
        throw const LinkPairingException(LinkPairingError.tooManyAttempts);
      }
      if (response.statusCode == 403) {
        throw LinkPairingException(switch (body is Map ? body['error'] : null) {
          'bad_proof' => LinkPairingError.badPin,
          'pairing_closed' => LinkPairingError.pairingClosed,
          _ => LinkPairingError.failed,
        });
      }
      if (!response.ok || body is! Map) {
        throw const LinkPairingException(LinkPairingError.failed);
      }
      final apiKey = body['apiKey'];
      final serverId = body['serverId'];
      final fingerprint = body['fingerprint'];
      if (apiKey is! String || apiKey.isEmpty) {
        throw const LinkPairingException(LinkPairingError.failed);
      }
      if (serverId is String && serverId != target.info.serverId) {
        throw const LinkPairingException(LinkPairingError.incompatible);
      }
      if (fingerprint is String &&
          fingerprint.toLowerCase() != target.fingerprint) {
        throw const LinkPairingException(LinkPairingError.certificateMismatch);
      }
      final name = body['name'];
      return LinkPairingResult(
        apiKey: apiKey,
        serverId: target.info.serverId,
        name: name is String && name.trim().isNotEmpty
            ? name.trim()
            : target.info.name,
        fingerprint: target.fingerprint,
      );
    } catch (error) {
      throw _classify(error);
    } finally {
      client.close(force: true);
    }
  }

  static LinkPairingException _classify(Object error) => switch (error) {
    LinkPairingException() => error,
    LocalNetworkPermissionException() => const LinkPairingException(
      LinkPairingError.localNetworkPermission,
    ),
    // The pinned client refuses any other certificate during the handshake.
    TlsException() => const LinkPairingException(
      LinkPairingError.certificateMismatch,
    ),
    TimeoutException() => const LinkPairingException(LinkPairingError.timeout),
    SocketException() => const LinkPairingException(
      LinkPairingError.unreachable,
    ),
    FormatException() => const LinkPairingException(
      LinkPairingError.invalidAddress,
    ),
    _ => const LinkPairingException(LinkPairingError.failed),
  };
}

/// Whether the certificate seen in the handshake ([observed]) is the one the
/// desktop claims in `info` and, when known, the one its mDNS record
/// advertises. Without an observed certificate nothing can be trusted.
bool linkFingerprintsMatch({
  required String? observed,
  required String claimed,
  String? advertised,
}) {
  if (observed == null || observed.isEmpty) return false;
  final seen = observed.toLowerCase();
  return seen == claimed.toLowerCase() &&
      (advertised == null || advertised.toLowerCase() == seen);
}
