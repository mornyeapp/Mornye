import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/link/client/link_client_discovery.dart';
import 'package:mornye/services/local_network_access.dart';

final _fp = 'ab' * 32;

LinkServiceResolved _service({
  String name = 'Studio PC',
  int port = 47710,
  List<String> addresses = const ['192.168.1.20'],
  String? hostname,
  Map<String, String>? attributes,
}) => LinkServiceResolved(
  name: name,
  port: port,
  addresses: addresses,
  hostname: hostname,
  attributes: attributes ?? {'v': '1', 'id': 'server-1', 'fp': _fp},
);

class _FakeBrowser implements LinkServiceBrowser {
  _FakeBrowser() {
    // Stays open across stop() so late events can be checked. Not awaited:
    // a stream nobody listened to never reports done.
    addTearDown(() => unawaited(events.close()));
  }

  final events = StreamController<LinkServiceEvent>();
  int started = 0;
  int stopped = 0;

  @override
  Future<Stream<LinkServiceEvent>> start() async {
    started++;
    return events.stream;
  }

  @override
  Future<void> stop() async => stopped++;
}

void main() {
  group('service mapping', () {
    test('reads id, fingerprint, host and port from the record', () {
      final server = linkDiscoveredServerFrom(
        _service(
          attributes: {'v': '1', 'id': ' server-1 ', 'fp': _fp.toUpperCase()},
        ),
      )!;
      expect(server.serverId, 'server-1');
      expect(server.fingerprint, _fp);
      expect(server.name, 'Studio PC');
      expect(server.address, 'https://192.168.1.20:47710');
    });

    test('ignores services of another version or without identity', () {
      for (final attributes in [
        {'v': '2', 'id': 'server-1', 'fp': _fp},
        {'id': 'server-1', 'fp': _fp},
        {'v': '1', 'fp': _fp},
        {'v': '1', 'id': 'server-1', 'fp': 'not-hex'},
        {'v': '1', 'id': 'server-1'},
      ]) {
        expect(
          linkDiscoveredServerFrom(_service(attributes: attributes)),
          isNull,
          reason: '$attributes',
        );
      }
      expect(linkDiscoveredServerFrom(_service(port: 0)), isNull);
      expect(linkDiscoveredServerFrom(_service(addresses: const [])), isNull);
    });

    test('prefers IPv4, then routable IPv6, then the host name', () {
      expect(
        linkPreferredHost(['fe80::1%wlan0', '2001:db8::5', '10.0.0.4'], null),
        '10.0.0.4',
      );
      expect(
        linkPreferredHost(['fe80::1', '2001:db8::5'], null),
        '2001:db8::5',
      );
      expect(linkPreferredHost(['fe80::1'], 'studio.local.'), 'studio.local');
      expect(linkPreferredHost(['127.0.0.1'], null), isNull);
      expect(
        linkDiscoveredServerFrom(
          _service(addresses: const ['2001:db8::5']),
        )!.address,
        'https://[2001:db8::5]:47710',
      );
    });
  });

  group('LinkDiscovery', () {
    test('an unexpectedly closed browser can be retried', () async {
      final browser = _FakeBrowser();
      final discovery = LinkDiscovery(
        createBrowser: () => browser,
        ensureAccess: () async {},
        onChanged: () {},
      );
      await discovery.start();
      await browser.events.close();
      await pumpEventQueue();
      expect(discovery.running, isFalse);
      expect(discovery.status, LinkDiscoveryStatus.failed);
      expect(browser.stopped, 1);
    });

    test('tracks resolved and lost desktops', () async {
      final browser = _FakeBrowser();
      var changes = 0;
      final discovery = LinkDiscovery(
        createBrowser: () => browser,
        ensureAccess: () async {},
        onChanged: () => changes++,
      );
      await discovery.start();
      expect(discovery.status, LinkDiscoveryStatus.searching);
      expect(browser.started, 1);

      browser.events.add(_service());
      browser.events.add(
        _service(
          name: 'Laptop',
          addresses: const ['192.168.1.30'],
          attributes: {'v': '1', 'id': 'server-2', 'fp': 'cd' * 32},
        ),
      );
      await pumpEventQueue();
      expect(discovery.servers.map((s) => s.name), ['Laptop', 'Studio PC']);

      // An update without addresses keeps the resolved entry.
      final before = changes;
      browser.events.add(_service(addresses: const []));
      await pumpEventQueue();
      expect(changes, before);
      expect(discovery.servers, hasLength(2));

      // A move to another address replaces the entry.
      browser.events.add(_service(addresses: const ['192.168.1.21']));
      await pumpEventQueue();
      expect(
        discovery.servers.firstWhere((s) => s.serverId == 'server-1').host,
        '192.168.1.21',
      );

      browser.events.add(const LinkServiceLost('Laptop'));
      await pumpEventQueue();
      expect(discovery.servers.map((s) => s.serverId), ['server-1']);

      await discovery.stop();
      expect(discovery.status, LinkDiscoveryStatus.idle);
      expect(discovery.servers, isEmpty);
      expect(browser.stopped, 1);
    });

    test('events after stop are ignored', () async {
      final browser = _FakeBrowser();
      final discovery = LinkDiscovery(
        createBrowser: () => browser,
        ensureAccess: () async {},
        onChanged: () {},
      );
      await discovery.start();
      await discovery.stop();
      browser.events.add(_service());
      await pumpEventQueue();
      expect(discovery.servers, isEmpty);
    });

    test('a refused permission is reported, not retried', () async {
      final browser = _FakeBrowser();
      final discovery = LinkDiscovery(
        createBrowser: () => browser,
        ensureAccess: () async => throw const LocalNetworkPermissionException(),
        onChanged: () {},
      );
      await discovery.start();
      expect(discovery.status, LinkDiscoveryStatus.permissionDenied);
      expect(discovery.running, isFalse);
      expect(browser.started, 0);
    });

    test('a browser error stops discovery', () async {
      final browser = _FakeBrowser();
      final discovery = LinkDiscovery(
        createBrowser: () => browser,
        ensureAccess: () async {},
        onChanged: () {},
      );
      await discovery.start();
      browser.events.add(_service());
      browser.events.addError(StateError('nsd failed'));
      await pumpEventQueue();
      expect(discovery.status, LinkDiscoveryStatus.failed);
      expect(discovery.servers, isEmpty);
      expect(browser.stopped, 1);
    });
  });
}
