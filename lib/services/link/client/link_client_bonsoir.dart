import 'dart:async';

import 'package:bonsoir/bonsoir.dart';
import 'package:flutter/services.dart';
import 'package:mornye/services/link/client/link_client_discovery.dart';
import 'package:mornye/services/link/link_protocol.dart';
import 'package:mornye/services/local_network_access.dart';

/// [LinkServiceBrowser] on Bonsoir (Android NSD, Apple Bonjour). Found
/// services are resolved right away, since the list shows their addresses.
class BonsoirLinkServiceBrowser implements LinkServiceBrowser {
  BonsoirDiscovery? _discovery;
  StreamSubscription<BonsoirDiscoveryEvent>? _subscription;
  StreamController<LinkServiceEvent>? _events;

  @override
  Future<Stream<LinkServiceEvent>> start() async {
    await stop();
    final discovery = _discovery = BonsoirDiscovery(
      type: linkServiceType,
      printLogs: false,
    );
    _events = StreamController<LinkServiceEvent>();
    await discovery.initialize();
    _subscription = discovery.eventStream?.listen(
      (event) {
        switch (event) {
          case BonsoirDiscoveryServiceFoundEvent(:final service):
            unawaited(
              service
                  .resolve(discovery.serviceResolver)
                  .catchError((Object _) {}),
            );
          case BonsoirDiscoveryServiceResolvedEvent(:final service) ||
              BonsoirDiscoveryServiceUpdatedEvent(:final service):
            _events?.add(
              LinkServiceResolved(
                name: service.name,
                port: service.port,
                addresses: service.hostAddresses,
                hostname: service.hostname,
                attributes: service.attributes,
              ),
            );
          case BonsoirDiscoveryServiceLostEvent(:final service):
            _events?.add(LinkServiceLost(service.name));
          case BonsoirDiscoveryStoppedEvent():
            _events?.addError(StateError('Network discovery stopped'));
          default:
            break;
        }
      },
      onError: (Object error) {
        // Bonjour reports kDNSServiceErr_PolicyDenied for local network access.
        _events?.addError(
          error is PlatformException && error.details == -65570
              ? const LocalNetworkPermissionException()
              : error,
        );
      },
      onDone: () => unawaited(_events?.close()),
    );
    await discovery.start();
    return _events!.stream;
  }

  @override
  Future<void> stop() async {
    final discovery = _discovery;
    _discovery = null;
    final cancelling = _subscription?.cancel();
    _subscription = null;
    // Nobody may listen any more, so the close is not awaited.
    unawaited(_events?.close());
    _events = null;
    await cancelling;
    if (discovery != null && discovery.isReady && !discovery.isStopped) {
      await discovery.stop();
    }
  }
}
