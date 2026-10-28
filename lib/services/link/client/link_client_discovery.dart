import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:mornye/services/link/link_protocol.dart';
import 'package:mornye/services/local_network_access.dart';
import 'package:mornye/utils/logger.dart';

final _log = AppLogger('LinkDiscovery');

/// One mDNS event for [linkServiceType], independent of the plugin.
sealed class LinkServiceEvent {
  const LinkServiceEvent(this.name);

  /// The mDNS instance name, which the desktop sets to its server name.
  final String name;
}

/// A service was resolved, or its record changed.
class LinkServiceResolved extends LinkServiceEvent {
  const LinkServiceResolved({
    required String name,
    required this.port,
    this.addresses = const [],
    this.hostname,
    this.attributes = const {},
  }) : super(name);

  final int port;

  /// Addresses as the platform reports them, IPv4 or IPv6.
  final List<String> addresses;

  /// The SRV target, usually `<name>.local`, when the platform reports it.
  final String? hostname;

  /// TXT record: `v`, `id` and `fp`.
  final Map<String, String> attributes;
}

/// A service left the network.
class LinkServiceLost extends LinkServiceEvent {
  const LinkServiceLost(super.name);
}

/// Browses the local network for desktops. The app uses Bonsoir; tests feed
/// events by hand.
abstract interface class LinkServiceBrowser {
  /// Starts browsing; resolved and lost services arrive until [stop].
  Future<Stream<LinkServiceEvent>> start();

  Future<void> stop();
}

/// A desktop found on the local network.
@immutable
class LinkDiscoveredServer {
  const LinkDiscoveredServer({
    required this.serviceName,
    required this.serverId,
    required this.name,
    required this.host,
    required this.port,
    required this.fingerprint,
  });

  /// The mDNS instance name, which identifies the service in lost events.
  final String serviceName;
  final String serverId;
  final String name;
  final String host;
  final int port;

  /// The certificate fingerprint the desktop advertises (TXT `fp`). Pairing
  /// still checks it against the certificate it actually sees.
  final String fingerprint;

  /// `https://host:port`, the form of [LinkServerRecord.address].
  String get address => Uri(scheme: 'https', host: host, port: port).toString();

  @override
  bool operator ==(Object other) =>
      other is LinkDiscoveredServer &&
      other.serviceName == serviceName &&
      other.serverId == serverId &&
      other.name == name &&
      other.host == host &&
      other.port == port &&
      other.fingerprint == fingerprint;

  @override
  int get hashCode =>
      Object.hash(serviceName, serverId, name, host, port, fingerprint);

  @override
  String toString() => 'LinkDiscoveredServer($name, $serverId, $address)';
}

final _fingerprintPattern = RegExp(r'^[0-9a-f]{64}$');

/// The desktop behind a resolved service, or null when it is not a Mornye
/// Link server of this protocol or has no usable address.
LinkDiscoveredServer? linkDiscoveredServerFrom(LinkServiceResolved service) {
  final attributes = service.attributes;
  if (attributes['v']?.trim() != '$linkProtocolVersion') return null;
  final serverId = attributes['id']?.trim() ?? '';
  final fingerprint = attributes['fp']?.trim().toLowerCase() ?? '';
  if (serverId.isEmpty || !_fingerprintPattern.hasMatch(fingerprint)) {
    return null;
  }
  if (service.port < 1 || service.port > 65535) return null;
  final host = linkPreferredHost(service.addresses, service.hostname);
  if (host == null) return null;
  final name = service.name.trim();
  return LinkDiscoveredServer(
    serviceName: service.name,
    serverId: serverId,
    name: name.isEmpty ? host : name,
    host: host,
    port: service.port,
    fingerprint: fingerprint,
  );
}

/// The address to reach a desktop at: IPv4 first, since it needs no zone,
/// then a routable IPv6 address, then the mDNS host name. Link-local IPv6
/// is skipped because a URL cannot carry its interface reliably.
@visibleForTesting
String? linkPreferredHost(List<String> addresses, String? hostname) {
  final parsed = [
    for (final address in addresses)
      ?InternetAddress.tryParse(address.split('%').first.trim()),
  ];
  for (final address in parsed) {
    if (address.type == InternetAddressType.IPv4 && !address.isLoopback) {
      return address.address;
    }
  }
  for (final address in parsed) {
    if (address.type == InternetAddressType.IPv6 &&
        !address.isLoopback &&
        !address.isLinkLocal) {
      return address.address;
    }
  }
  final name = hostname?.trim().replaceFirst(RegExp(r'\.$'), '') ?? '';
  return name.isEmpty ? null : name;
}

enum LinkDiscoveryStatus { idle, searching, permissionDenied, failed }

/// Keeps the list of desktops on the network while browsing runs.
class LinkDiscovery {
  LinkDiscovery({
    required LinkServiceBrowser Function() createBrowser,
    required void Function() onChanged,
    Future<void> Function()? ensureAccess,
  }) : _createBrowser = createBrowser,
       _onChanged = onChanged,
       _ensureAccess =
           ensureAccess ?? LocalNetworkAccess.instance.ensureGranted;

  final LinkServiceBrowser Function() _createBrowser;
  final void Function() _onChanged;
  final Future<void> Function() _ensureAccess;
  final _byService = <String, LinkDiscoveredServer>{};
  LinkServiceBrowser? _browser;
  StreamSubscription<LinkServiceEvent>? _subscription;
  var _generation = 0;
  var _status = LinkDiscoveryStatus.idle;

  LinkDiscoveryStatus get status => _status;

  /// Whether browsing was asked for and has not stopped or failed.
  bool get running => _status == LinkDiscoveryStatus.searching;

  /// Desktops on the network, one per server id, sorted by name.
  List<LinkDiscoveredServer> get servers {
    final byServer = <String, LinkDiscoveredServer>{};
    for (final server in _byService.values) {
      byServer[server.serverId] = server;
    }
    return byServer.values.toList()
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  }

  Future<void> start() async {
    if (running) return;
    final generation = ++_generation;
    _status = LinkDiscoveryStatus.searching;
    _onChanged();
    try {
      await _ensureAccess();
      if (generation != _generation) return;
      final browser = _browser = _createBrowser();
      final events = await browser.start();
      if (generation != _generation) {
        await browser.stop();
        return;
      }
      _subscription = events.listen(
        (event) => _handle(generation, event),
        onError: (Object error) => _fail(generation, error),
        onDone: () => _fail(generation, StateError('Discovery stream ended')),
      );
    } catch (error) {
      _fail(generation, error);
    }
  }

  Future<void> stop() async {
    _generation++;
    final subscription = _subscription;
    final browser = _browser;
    _subscription = null;
    _browser = null;
    final changed =
        _byService.isNotEmpty || _status == LinkDiscoveryStatus.searching;
    _byService.clear();
    if (_status == LinkDiscoveryStatus.searching) {
      _status = LinkDiscoveryStatus.idle;
    }
    if (changed) _onChanged();
    await subscription?.cancel();
    try {
      await browser?.stop();
    } catch (error) {
      _log.w('Stopping discovery failed: $error');
    }
  }

  void _handle(int generation, LinkServiceEvent event) {
    if (generation != _generation) return;
    switch (event) {
      case LinkServiceResolved():
        final server = linkDiscoveredServerFrom(event);
        // An update without addresses keeps the last resolved entry.
        if (server == null || _byService[event.name] == server) return;
        _byService[event.name] = server;
      case LinkServiceLost():
        if (_byService.remove(event.name) == null) return;
    }
    _onChanged();
  }

  void _fail(int generation, Object error) {
    if (generation != _generation) return;
    _generation++;
    final browser = _browser;
    _browser = null;
    unawaited(_subscription?.cancel());
    _subscription = null;
    unawaited(browser?.stop().catchError((Object _) {}));
    _byService.clear();
    _status = error is LocalNetworkPermissionException
        ? LinkDiscoveryStatus.permissionDenied
        : LinkDiscoveryStatus.failed;
    if (_status == LinkDiscoveryStatus.failed) {
      _log.w('Discovery failed: $error');
    }
    _onChanged();
  }
}
